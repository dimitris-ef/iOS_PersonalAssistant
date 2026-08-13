import AssistantAI
import AssistantDomain
import Foundation

/// How a downloaded model's weights are packaged.
///
/// Left open on purpose: the inference runtime has not been chosen, and this
/// list is expected to grow or shrink once it is.
public enum LocalModelFormat: String, Hashable, Codable, Sendable, CaseIterable {
    case gguf
    case mlx
    case coreML
    case executorch
    case other
}

/// Metadata about a model the user has (or could) download.
///
/// Deliberately runtime-agnostic — nothing here assumes llama.cpp, MLX, Core ML
/// or ExecuTorch. Picking a runtime later means implementing
/// ``LocalModelRuntime``, not changing this type or anything above it.
public struct LocalModelDescriptor: Identifiable, Hashable, Codable, Sendable {
    public var id: AIModelIdentifier
    public var displayName: String
    public var format: LocalModelFormat
    public var sizeBytes: Int64?
    public var quantization: String?
    public var contextWindow: Int?
    /// Where the weights come from. Never a credential-bearing URL.
    public var downloadURL: URL?
    public var checksumSHA256: String?
    public var supportsNativeToolCalling: Bool

    public init(
        id: AIModelIdentifier,
        displayName: String,
        format: LocalModelFormat,
        sizeBytes: Int64? = nil,
        quantization: String? = nil,
        contextWindow: Int? = nil,
        downloadURL: URL? = nil,
        checksumSHA256: String? = nil,
        supportsNativeToolCalling: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.format = format
        self.sizeBytes = sizeBytes
        self.quantization = quantization
        self.contextWindow = contextWindow
        self.downloadURL = downloadURL
        self.checksumSHA256 = checksumSHA256
        self.supportsNativeToolCalling = supportsNativeToolCalling
    }
}

public enum LocalModelState: Hashable, Sendable {
    case notDownloaded
    case downloading(fractionComplete: Double)
    case ready
    case failed(reason: String)
}

/// The seam a concrete inference engine will implement.
///
/// No implementation ships today, and that is intentional — committing to a
/// runtime now would be the hardest decision to reverse. Whatever is chosen
/// (llama.cpp, MLX, Core ML, ExecuTorch, something else) implements this and
/// nothing above it changes.
public protocol LocalModelRuntime: Sendable {
    var supportedFormats: [LocalModelFormat] { get }

    func state(of model: LocalModelDescriptor) async -> LocalModelState
    func load(_ model: LocalModelDescriptor) async throws
    func unload(_ model: LocalModelDescriptor) async

    /// Runs one turn. Implementations that lack native tool calling are
    /// responsible for producing `AIToolCall`s from whatever structured output
    /// mechanism they do have (grammar constraints, JSON mode, …) — the
    /// application never parses prose.
    func generate(_ request: AIRequest, model: LocalModelDescriptor) async throws -> AIResponse
}

/// Tracks which local models the user has.
public actor LocalModelCatalog {
    private var descriptors: [AIModelIdentifier: LocalModelDescriptor] = [:]

    public init(descriptors: [LocalModelDescriptor] = []) {
        for descriptor in descriptors {
            self.descriptors[descriptor.id] = descriptor
        }
    }

    public func add(_ descriptor: LocalModelDescriptor) {
        descriptors[descriptor.id] = descriptor
    }

    public func remove(_ id: AIModelIdentifier) {
        descriptors.removeValue(forKey: id)
    }

    public func all() -> [LocalModelDescriptor] {
        descriptors.values.sorted { $0.displayName < $1.displayName }
    }

    public func descriptor(for id: AIModelIdentifier) -> LocalModelDescriptor? {
        descriptors[id]
    }
}
