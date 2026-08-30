import AssistantAI
import AssistantDomain
import Foundation

/// How a downloadable model's weights are packaged.
///
/// GGUF is the only format Part 10 can actually run, because llama.cpp is the
/// runtime that ships. The other cases exist so the catalog can *describe* a
/// model it cannot load and say so honestly, rather than the app pretending an
/// MLX checkpoint is simply missing.
public enum LocalModelFormat: String, Hashable, Codable, Sendable, CaseIterable {
    case gguf
    case mlx
    case coreML
    case executorch
    case other

    public var displayName: String {
        switch self {
        case .gguf: return "GGUF"
        case .mlx: return "MLX"
        case .coreML: return "Core ML"
        case .executorch: return "ExecuTorch"
        case .other: return "Unknown"
        }
    }
}

/// A GGUF quantization, as llama.cpp names it.
///
/// Deliberately a wrapper around a string rather than a closed enum. llama.cpp
/// adds quantization types faster than this app will be rebuilt, and a closed
/// enum would turn "a new quantization exists" into "the catalog fails to
/// decode". The named constants below are the ones worth recommending on a
/// phone; anything else round-trips as itself and is judged on its file size
/// like everything else.
public struct LocalModelQuantization: Hashable, Codable, Sendable,
                                      CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue.uppercased()
    }

    public init(stringLiteral value: String) { self.init(value) }

    public var description: String { rawValue }

    // Coded as a bare string rather than as `{"rawValue": "Q4_K_M"}`.
    // The catalog is a file a person edits, and the synthesized form would make
    // every entry noisier for no benefit.
    public init(from decoder: Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    // The families that make sense on an iPhone: small enough to fit, good
    // enough to be worth running. Q4_K_M is the usual default.
    public static let q4KM: LocalModelQuantization = "Q4_K_M"
    public static let q4KS: LocalModelQuantization = "Q4_K_S"
    public static let q5KM: LocalModelQuantization = "Q5_K_M"
    public static let q5KS: LocalModelQuantization = "Q5_K_S"
    public static let q6K: LocalModelQuantization = "Q6_K"
    public static let q8: LocalModelQuantization = "Q8_0"

    /// Quantizations this app is willing to recommend without a warning.
    ///
    /// Not a compatibility gate. llama.cpp reads far more than these, and a
    /// model quantized some other way still loads — it simply does not get a
    /// "recommended" badge from a list that was written before it existed.
    public static let recommended: Set<LocalModelQuantization> = [
        q4KM, q4KS, q5KM, q5KS, q6K, q8,
    ]

    public var isRecommended: Bool { Self.recommended.contains(self) }

    /// Roughly how many bits per weight this quantization spends.
    ///
    /// Used only to sanity-check a catalog entry's declared file size against
    /// its declared parameter count. Approximate by nature — the K-quants mix
    /// precisions per tensor — so callers treat a mismatch as a warning, never
    /// as a rejection.
    public var approximateBitsPerWeight: Double? {
        let name = rawValue
        if name.hasPrefix("F32") { return 32 }
        if name.hasPrefix("F16") || name.hasPrefix("BF16") { return 16 }
        if name.hasPrefix("Q8") { return 8.5 }
        if name.hasPrefix("Q6") { return 6.6 }
        if name.hasPrefix("Q5") { return 5.6 }
        if name.hasPrefix("Q4") || name.hasPrefix("IQ4") { return 4.8 }
        if name.hasPrefix("Q3") || name.hasPrefix("IQ3") { return 3.9 }
        if name.hasPrefix("Q2") || name.hasPrefix("IQ2") { return 2.9 }
        if name.hasPrefix("IQ1") { return 1.9 }
        return nil
    }
}

/// How much of the assistant a model can actually do.
///
/// Section 55. A 0.5B model can hold a conversation and cannot reliably emit a
/// well-formed tool call, and the honest thing is to say which is which rather
/// than let someone discover it when a reminder silently fails to be created.
public enum LocalModelToolSupport: String, Hashable, Codable, Sendable, CaseIterable {
    /// Emits structured calls dependably enough to run the assistant.
    case supported
    /// Sometimes gets it right. Offered, with a warning.
    case experimental
    /// Chat only. The app will not ask it for actions.
    case unsupported

    /// Whether the provider offers tools to this model at all.
    public var offersTools: Bool { self != .unsupported }

    public var label: String {
        switch self {
        case .supported: return "Assistant actions: supported"
        case .experimental: return "Assistant actions: experimental"
        case .unsupported: return "Chat only — assistant actions unavailable"
        }
    }

    /// The short form, for a list row and the model picker (section 7).
    ///
    /// A badge rather than a sentence because it sits next to the model name in
    /// two places where there is one line to spend — and because the thing a
    /// person needs to know before choosing is binary: will "remind me in ten
    /// minutes" work, or not. Section 7 is explicit that the app must not stay
    /// quiet about this and let them find out by being told an action failed.
    public var badge: String {
        switch self {
        case .supported: return "Supports actions"
        case .experimental: return "Experimental actions"
        case .unsupported: return "Chat only"
        }
    }

    /// SF Symbol for the badge.
    public var symbolName: String {
        switch self {
        case .supported: return "bolt.badge.checkmark"
        case .experimental: return "bolt.badge.clock"
        case .unsupported: return "bubble.left.and.bubble.right"
        }
    }
}

/// What a model is allowed to be used for, in the words of whoever made it.
///
/// Recorded, shown, and never interpreted by code. The app does not decide
/// whether a licence permits something; it shows the user what the licence is
/// and links to it. Section 16 and section 84 — this is the *model's* licence,
/// which has nothing to do with llama.cpp's.
public struct LocalModelLicense: Hashable, Codable, Sendable {
    /// SPDX identifier where there is one ("Apache-2.0", "MIT"), otherwise the
    /// licence's own name.
    public var identifier: String
    public var displayName: String
    /// Where to read it.
    public var url: URL?
    /// True when the weights can be fetched without accepting terms on a web
    /// page first. A gated model cannot be downloaded by this app at all — the
    /// request would need a credential the app deliberately does not have.
    public var isRedistributable: Bool

    public init(
        identifier: String,
        displayName: String,
        url: URL? = nil,
        isRedistributable: Bool = true
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.url = url
        self.isRedistributable = isRedistributable
    }
}

/// Everything the app knows about a model before it has one byte of it.
///
/// Runtime-agnostic by construction: nothing here mentions llama.cpp, GGML,
/// Metal or a context pointer. Swapping the runtime later means writing another
/// ``LocalModelRuntime``, not editing this type or anything above it.
///
/// The identifier is *logical* — "qwen3-1.7b-q4-k-m", not a path. Sandbox
/// containers are relocated by iOS between launches, so a filesystem path is
/// the one thing that cannot be an identity (section 27).
public struct LocalModelDescriptor: Identifiable, Hashable, Codable, Sendable {
    public var id: AIModelIdentifier
    public var displayName: String
    /// The model family as GGUF records it: "qwen3", "llama", "gemma3",
    /// "phi3". Compared against the downloaded file's own metadata after
    /// download (section 116).
    public var architecture: String
    /// Total parameters, e.g. 1_700_000_000. Used for size expectations and for
    /// the "1.7B" the list shows.
    public var parameterCount: Int64?
    public var quantization: LocalModelQuantization?
    public var format: LocalModelFormat
    /// Bytes on disk, from the catalog. Checked against what actually arrives.
    public var fileSizeBytes: Int64?
    /// Strong checksum, when the catalog has one. Optional on purpose — see
    /// ``LocalModelInstaller`` for what verification does without it.
    public var checksumSHA256: String?
    public var downloadURL: URL?
    /// The context length this app will actually open the model with, which is
    /// not the model's theoretical maximum (section 45).
    public var defaultContextLength: Int
    /// The largest context the weights support, for display and clamping.
    public var maximumContextLength: Int?
    /// Bytes of KV cache per token, when the catalog knows. Dominates memory at
    /// long contexts and is the number a generic estimate gets most wrong.
    public var kvCacheBytesPerToken: Int?
    public var toolSupport: LocalModelToolSupport
    /// Which prompt shape the weights expect, when the file does not say.
    public var chatTemplate: LocalChatTemplate
    public var license: LocalModelLicense?
    /// One line for the model list.
    public var summary: String?

    public init(
        id: AIModelIdentifier,
        displayName: String,
        architecture: String,
        parameterCount: Int64? = nil,
        quantization: LocalModelQuantization? = nil,
        format: LocalModelFormat = .gguf,
        fileSizeBytes: Int64? = nil,
        checksumSHA256: String? = nil,
        downloadURL: URL? = nil,
        defaultContextLength: Int = 4096,
        maximumContextLength: Int? = nil,
        kvCacheBytesPerToken: Int? = nil,
        toolSupport: LocalModelToolSupport = .experimental,
        chatTemplate: LocalChatTemplate = .modelDefault,
        license: LocalModelLicense? = nil,
        summary: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.architecture = architecture
        self.parameterCount = parameterCount
        self.quantization = quantization
        self.format = format
        self.fileSizeBytes = fileSizeBytes
        self.checksumSHA256 = checksumSHA256
        self.downloadURL = downloadURL
        self.defaultContextLength = defaultContextLength
        self.maximumContextLength = maximumContextLength
        self.kvCacheBytesPerToken = kvCacheBytesPerToken
        self.toolSupport = toolSupport
        self.chatTemplate = chatTemplate
        self.license = license
        self.summary = summary
    }

    /// "1.7B", "3B", "494M" — the number people actually compare models by.
    public var parameterLabel: String? {
        guard let parameterCount, parameterCount > 0 else { return nil }
        let billions = Double(parameterCount) / 1_000_000_000
        if billions >= 1 {
            return billions < 10
                ? String(format: "%.1fB", billions).replacingOccurrences(of: ".0B", with: "B")
                : String(format: "%.0fB", billions)
        }
        return "\(Int((Double(parameterCount) / 1_000_000).rounded()))M"
    }

    /// Whether this app can run the file at all, format-wise.
    public var isRunnableFormat: Bool { format == .gguf }

    /// A file name derived from the logical id, so the same model always lands
    /// in the same place and two catalog entries cannot collide.
    public var suggestedFileName: String {
        let safe = id.rawValue
            .lowercased()
            .map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." ? $0 : "-" }
        return String(safe) + ".gguf"
    }
}

extension LocalModelDescriptor {
    /// Hand-written coding, so the catalog file reads like something a person
    /// wrote.
    ///
    /// The one thing this buys over the synthesized version: `id` is a bare
    /// string. `AIModelIdentifier` wraps a `String` and synthesizes to
    /// `{"rawValue": "qwen3-1.7b"}`, which is correct and unreadable. The
    /// catalog is edited by hand and reviewed in diffs, so it is worth the
    /// twenty lines.
    ///
    /// Every optional field really is optional here: an entry may omit a size,
    /// a checksum or a KV figure and the app degrades in a documented way,
    /// which is what keeps adding a model to the list a small job.
    private enum CodingKeys: String, CodingKey {
        case id, displayName, architecture, parameterCount, quantization, format
        case fileSizeBytes, checksumSHA256, downloadURL
        case defaultContextLength, maximumContextLength, kvCacheBytesPerToken
        case toolSupport, chatTemplate, license, summary
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: AIModelIdentifier(try container.decode(String.self, forKey: .id)),
            displayName: try container.decode(String.self, forKey: .displayName),
            architecture: try container.decode(String.self, forKey: .architecture),
            parameterCount: try container.decodeIfPresent(Int64.self, forKey: .parameterCount),
            quantization: try container.decodeIfPresent(
                LocalModelQuantization.self, forKey: .quantization
            ),
            format: try container.decodeIfPresent(LocalModelFormat.self, forKey: .format) ?? .gguf,
            fileSizeBytes: try container.decodeIfPresent(Int64.self, forKey: .fileSizeBytes),
            checksumSHA256: try container.decodeIfPresent(String.self, forKey: .checksumSHA256),
            downloadURL: try container.decodeIfPresent(URL.self, forKey: .downloadURL),
            defaultContextLength: try container.decodeIfPresent(
                Int.self, forKey: .defaultContextLength
            ) ?? 4096,
            maximumContextLength: try container.decodeIfPresent(
                Int.self, forKey: .maximumContextLength
            ),
            kvCacheBytesPerToken: try container.decodeIfPresent(
                Int.self, forKey: .kvCacheBytesPerToken
            ),
            toolSupport: try container.decodeIfPresent(
                LocalModelToolSupport.self, forKey: .toolSupport
            ) ?? .experimental,
            chatTemplate: try container.decodeIfPresent(
                LocalChatTemplate.self, forKey: .chatTemplate
            ) ?? .modelDefault,
            license: try container.decodeIfPresent(LocalModelLicense.self, forKey: .license),
            summary: try container.decodeIfPresent(String.self, forKey: .summary)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id.rawValue, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(architecture, forKey: .architecture)
        try container.encodeIfPresent(parameterCount, forKey: .parameterCount)
        try container.encodeIfPresent(quantization, forKey: .quantization)
        try container.encode(format, forKey: .format)
        try container.encodeIfPresent(fileSizeBytes, forKey: .fileSizeBytes)
        try container.encodeIfPresent(checksumSHA256, forKey: .checksumSHA256)
        try container.encodeIfPresent(downloadURL, forKey: .downloadURL)
        try container.encode(defaultContextLength, forKey: .defaultContextLength)
        try container.encodeIfPresent(maximumContextLength, forKey: .maximumContextLength)
        try container.encodeIfPresent(kvCacheBytesPerToken, forKey: .kvCacheBytesPerToken)
        try container.encode(toolSupport, forKey: .toolSupport)
        try container.encode(chatTemplate, forKey: .chatTemplate)
        try container.encodeIfPresent(license, forKey: .license)
        try container.encodeIfPresent(summary, forKey: .summary)
    }
}
