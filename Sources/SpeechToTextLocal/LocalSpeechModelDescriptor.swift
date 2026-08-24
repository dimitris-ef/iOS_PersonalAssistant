import Foundation
import SpeechToText

/// Which Whisper build a model file is.
///
/// Whisper ships in a fixed family of sizes and the tradeoff between them is
/// the whole decision a user is making, so they are named rather than left as
/// a number of parameters nobody can interpret.
public enum WhisperModelVariant: String, Hashable, Sendable, Codable, CaseIterable {
    case tiny
    case base
    case small
    /// Present so the type is honest about what whisper.cpp supports. Not in
    /// the curated catalog — section 25 asks that very large models not be the
    /// default, and on a phone `medium` is a poor trade even when it fits.
    case medium
    case large

    /// Roughly how much slower than real time this is on a recent iPhone,
    /// with Metal. Indicative only, and never shown as a promise (section 80).
    public var relativeCost: Int {
        switch self {
        case .tiny: return 1
        case .base: return 2
        case .small: return 6
        case .medium: return 18
        case .large: return 36
        }
    }

    public var displayName: String {
        switch self {
        case .tiny: return "Tiny"
        case .base: return "Base"
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }
}

/// How the weights were compressed.
///
/// Section 26. whisper.cpp's `quantize` tool produces these; the catalog
/// records which one a file is so the RAM estimate can account for it, rather
/// than inferring it from the filename — which is exactly the "looks correct"
/// trap that section warns about.
public enum WhisperQuantization: String, Hashable, Sendable, Codable, CaseIterable {
    /// 16-bit floats. What the published models are by default.
    case f16
    case q8_0
    case q5_1
    case q5_0
    case q4_1
    case q4_0

    /// Approximate bits per weight, for the memory estimate.
    public var bitsPerWeight: Double {
        switch self {
        case .f16: return 16
        case .q8_0: return 8.5
        case .q5_1: return 6
        case .q5_0: return 5.5
        case .q4_1: return 5
        case .q4_0: return 4.5
        }
    }

    public var displayName: String {
        switch self {
        case .f16: return "16-bit"
        default: return rawValue.uppercased().replacingOccurrences(of: "_", with: "-")
        }
    }
}

/// One downloadable speech model.
///
/// ## Why this is not `LocalModelDescriptor`
///
/// Section 27. They would share about six field names and nothing else that
/// matters: a chat model has a context length, a chat template, a tool-calling
/// convention and an architecture the runtime must implement; a Whisper model
/// has none of those and has a language set and an encoder/decoder split
/// instead. Merging them would have produced a type where most fields are
/// meaningless for most instances, and — worse — would have let a Whisper model
/// be offered in the assistant's model picker, which section 4 forbids.
///
/// The generic *infrastructure* is shared (section 28): the download, the
/// checksum, the storage, the progress. Only the domain types are separate.
public struct LocalSpeechModelDescriptor: Hashable, Sendable, Identifiable, Codable {
    public var id: SpeechModelIdentifier
    public var displayName: String
    /// One line for the picker: what this trades for what.
    public var summary: String

    public var variant: WhisperModelVariant
    public var quantization: WhisperQuantization
    /// True for the `.en` builds, which are more accurate on English and
    /// useless on anything else.
    public var isEnglishOnly: Bool

    /// Bytes on disk, from the publisher.
    public var fileSize: Int64
    /// SHA-256 of the file, where the publisher provides one.
    ///
    /// Optional because not every mirror publishes a digest, and refusing every
    /// model that lacks one would leave an empty catalog. When it is present it
    /// is enforced (section 32); when it is absent the file's own header is
    /// still validated, and the descriptor says so.
    public var checksum: String?
    public var downloadURL: URL?

    /// The filename the model is stored under, relative to the speech models
    /// directory.
    public var fileName: String

    public init(
        id: SpeechModelIdentifier,
        displayName: String,
        summary: String,
        variant: WhisperModelVariant,
        quantization: WhisperQuantization,
        isEnglishOnly: Bool,
        fileSize: Int64,
        checksum: String? = nil,
        downloadURL: URL? = nil,
        fileName: String
    ) {
        self.id = id
        self.displayName = displayName
        self.summary = summary
        self.variant = variant
        self.quantization = quantization
        self.isEnglishOnly = isEnglishOnly
        self.fileSize = fileSize
        self.checksum = checksum
        self.downloadURL = downloadURL
        self.fileName = fileName
    }

    /// Languages this model handles, or nil for the multilingual builds.
    public var supportedLanguages: [String]? {
        isEnglishOnly ? ["en"] : nil
    }

    /// Whether this model can transcribe a locale.
    public func supports(_ locale: Locale) -> Bool {
        guard isEnglishOnly else { return true }
        let identifier = locale.identifier
        let head = identifier
            .components(separatedBy: CharacterSet(charactersIn: "-_"))
            .first ?? identifier
        return head.lowercased() == "en"
    }

    /// The provider-neutral form, for the shared model picker.
    public func asSpeechModel(estimatedRAM: Int64?) -> SpeechToTextModelDescriptor {
        SpeechToTextModelDescriptor(
            id: id,
            providerID: .localWhisper,
            displayName: displayName,
            summary: summary,
            downloadRequired: true,
            downloadSize: fileSize,
            estimatedRAM: estimatedRAM,
            supportsPartialResults: false,
            supportsOffline: true,
            supportedLanguages: supportedLanguages
        )
    }
}

/// Where a speech model has got to.
///
/// Section 30. One value rather than several booleans, for the reason Part 8
/// gave about voice state: `isDownloading` plus `isInstalled` plus `isLoaded`
/// plus `hasFailed` has sixteen combinations and about six of them mean
/// anything. "Downloading and installed" is not a state, it is a bug.
public enum LocalSpeechModelLifecycle: Hashable, Sendable {
    case notDownloaded
    case downloading(NativeProgressSnapshot)
    /// Downloaded; the checksum and header are being checked.
    case verifying
    /// On disk and verified, but not in memory.
    case downloaded
    /// Being read into memory by the runtime.
    case loading
    /// In memory and able to transcribe.
    case ready
    case failed(reason: String)
    /// On disk, but this device cannot run it.
    case incompatible(reason: String)

    public var isInstalled: Bool {
        switch self {
        case .downloaded, .loading, .ready, .incompatible: return true
        case .notDownloaded, .downloading, .verifying, .failed: return false
        }
    }

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    /// Whether something is happening that a spinner should represent.
    public var isBusy: Bool {
        switch self {
        case .downloading, .verifying, .loading: return true
        case .notDownloaded, .downloaded, .ready, .failed, .incompatible: return false
        }
    }

    public var label: String {
        switch self {
        case .notDownloaded: return "Not downloaded"
        case .downloading(let progress): return "Downloading… \(progress.label)"
        case .verifying: return "Verifying…"
        case .downloaded: return "Downloaded"
        case .loading: return "Loading…"
        case .ready: return "Ready"
        case .failed(let reason): return reason
        case .incompatible(let reason): return reason
        }
    }
}

/// Download progress, as the speech layer reports it.
///
/// A small mirror of the download layer's own progress type rather than a
/// re-export, so `SpeechToTextLocal`'s public surface does not oblige every
/// consumer — including the SwiftUI views — to import the download
/// infrastructure to render a percentage.
public struct NativeProgressSnapshot: Hashable, Sendable {
    public var bytesReceived: Int64
    public var bytesExpected: Int64?

    public init(bytesReceived: Int64, bytesExpected: Int64?) {
        self.bytesReceived = bytesReceived
        self.bytesExpected = bytesExpected
    }

    public var fractionComplete: Double? {
        guard let bytesExpected, bytesExpected > 0 else { return nil }
        return min(1, max(0, Double(bytesReceived) / Double(bytesExpected)))
    }

    /// Section 31: "118 MB / 142 MB · 83%".
    public var label: String {
        let received = SpeechModelByteFormat.string(bytesReceived)
        guard let bytesExpected, bytesExpected > 0 else { return received }
        let total = SpeechModelByteFormat.string(bytesExpected)
        let percent = Int((fractionComplete ?? 0) * 100)
        return "\(received) / \(total) · \(percent)%"
    }

    public static let zero = NativeProgressSnapshot(bytesReceived: 0, bytesExpected: nil)
}
