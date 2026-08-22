import AssistantAI
import AssistantDomain
import Foundation

/// One turn as a runtime is given it.
///
/// Roles are strings rather than an enum because this is what goes into a chat
/// template, and templates are written in the vocabulary of whoever trained the
/// model — "system", "user", "assistant", occasionally "tool". A closed enum
/// here would be an enum the app has to widen every time a model family invents
/// a role, for no benefit: nothing branches on the value except the template.
public struct LocalChatTurn: Hashable, Codable, Sendable {
    public var role: String
    public var content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }

    public static func system(_ content: String) -> LocalChatTurn {
        LocalChatTurn(role: "system", content: content)
    }

    public static func user(_ content: String) -> LocalChatTurn {
        LocalChatTurn(role: "user", content: content)
    }

    public static func assistant(_ content: String) -> LocalChatTurn {
        LocalChatTurn(role: "assistant", content: content)
    }
}

/// A prompt in the form a runtime can template.
///
/// Structured rather than pre-rendered, so the runtime can use the chat
/// template baked into the model file — which is the only way a Qwen model and
/// a Gemma model both get a prompt they recognise (section 39). `fallback` is
/// what to render if the file has no template of its own.
public struct LocalPrompt: Hashable, Codable, Sendable {
    public var turns: [LocalChatTurn]
    public var fallback: LocalChatTemplate

    public init(turns: [LocalChatTurn], fallback: LocalChatTemplate = .chatML) {
        self.turns = turns
        self.fallback = fallback
    }
}

/// Sampling and length limits for one generation.
///
/// Centrally defaulted (section 46) so the numbers live in one place instead of
/// being sprinkled through the provider, the runtime and the UI.
public struct LocalGenerationOptions: Hashable, Codable, Sendable {
    public var maximumOutputTokens: Int
    public var temperature: Double
    public var topP: Double
    public var topK: Int
    /// Fixed so a test that asks the same question twice gets the same answer.
    public var seed: UInt32?
    /// Strings that end generation early, beyond the model's own end token.
    public var stopSequences: [String]

    public init(
        maximumOutputTokens: Int = 512,
        temperature: Double = 0.7,
        topP: Double = 0.9,
        topK: Int = 40,
        seed: UInt32? = nil,
        stopSequences: [String] = []
    ) {
        self.maximumOutputTokens = maximumOutputTokens
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.seed = seed
        self.stopSequences = stopSequences
    }

    /// What the assistant asks for when it wants a structured answer.
    ///
    /// Colder than conversation on purpose: a tool call is a piece of syntax,
    /// and creativity in syntax is called a parse error.
    public static let structured = LocalGenerationOptions(
        maximumOutputTokens: 640,
        temperature: 0.2,
        topP: 0.9,
        topK: 40
    )

    public static let conversational = LocalGenerationOptions()
}

/// Why generation stopped.
public enum LocalGenerationStop: String, Hashable, Codable, Sendable {
    case endOfText
    case maximumTokens
    case stopSequence
    case cancelled
}

/// The result of one local generation.
///
/// Text and counts. No tokens, no logits, no context pointer — a provider that
/// could see those would be a provider coupled to a runtime.
public struct LocalGenerationOutput: Hashable, Codable, Sendable {
    public var text: String
    public var stop: LocalGenerationStop
    public var promptTokens: Int
    public var generatedTokens: Int

    public init(
        text: String,
        stop: LocalGenerationStop = .endOfText,
        promptTokens: Int = 0,
        generatedTokens: Int = 0
    ) {
        self.text = text
        self.stop = stop
        self.promptTokens = promptTokens
        self.generatedTokens = generatedTokens
    }
}

/// What a particular runtime can do on this build and this device.
public struct LocalRuntimeCapabilities: Hashable, Sendable {
    /// Weight formats it can open.
    public var supportedFormats: [LocalModelFormat]
    /// True when the runtime offloads to the GPU on this device.
    public var usesHardwareAcceleration: Bool
    /// True when a long load can be interrupted (section 118).
    public var supportsLoadCancellation: Bool
    /// Human-readable, for the debug screen only.
    public var runtimeName: String
    /// The pinned upstream version this build was made against.
    public var runtimeVersion: String

    public init(
        supportedFormats: [LocalModelFormat] = [.gguf],
        usesHardwareAcceleration: Bool = false,
        supportsLoadCancellation: Bool = false,
        runtimeName: String,
        runtimeVersion: String
    ) {
        self.supportedFormats = supportedFormats
        self.usesHardwareAcceleration = usesHardwareAcceleration
        self.supportsLoadCancellation = supportsLoadCancellation
        self.runtimeName = runtimeName
        self.runtimeVersion = runtimeVersion
    }
}

/// What actually got loaded, read back from the file rather than the catalog.
///
/// Section 116: the catalog is a claim, and this is the model. When they
/// disagree the app believes this one and says the catalog was wrong.
public struct LoadedModelInfo: Hashable, Sendable {
    public var modelID: AIModelIdentifier
    /// The architecture string the weights declare.
    public var architecture: String
    /// The context the runtime actually opened, after clamping.
    public var contextLength: Int
    /// The context the weights were trained for.
    public var trainedContextLength: Int?
    public var parameterCount: Int64?
    /// True when the weights carry their own chat template.
    public var hasEmbeddedChatTemplate: Bool

    public init(
        modelID: AIModelIdentifier,
        architecture: String,
        contextLength: Int,
        trainedContextLength: Int? = nil,
        parameterCount: Int64? = nil,
        hasEmbeddedChatTemplate: Bool = false
    ) {
        self.modelID = modelID
        self.architecture = architecture
        self.contextLength = contextLength
        self.trainedContextLength = trainedContextLength
        self.parameterCount = parameterCount
        self.hasEmbeddedChatTemplate = hasEmbeddedChatTemplate
    }
}

/// Everything a runtime needs to open one model.
public struct LocalModelLoadRequest: Hashable, Sendable {
    public var modelID: AIModelIdentifier
    /// An absolute URL resolved *now*, from a stored relative path. Never
    /// persisted in this form — see ``LocalModelRecord``.
    public var fileURL: URL
    public var contextLength: Int
    /// Threads for prompt processing and generation. Nil lets the runtime pick.
    public var threadCount: Int?

    public init(
        modelID: AIModelIdentifier,
        fileURL: URL,
        contextLength: Int,
        threadCount: Int? = nil
    ) {
        self.modelID = modelID
        self.fileURL = fileURL
        self.contextLength = contextLength
        self.threadCount = threadCount
    }
}

/// Why a runtime could not do something.
///
/// Provider-neutral, and mapped onto ``AIProviderError`` by
/// ``LocalModelProvider``. `insufficientMemory` exists as its own case because
/// it is the one failure the user can actually act on: pick a smaller model.
public enum LocalRuntimeError: Error, Hashable, Sendable, CustomStringConvertible {
    /// This build has no inference runtime linked.
    case runtimeUnavailable(reason: String)
    case modelFileMissing(URL)
    case unsupportedFormat(reason: String)
    case unsupportedArchitecture(String)
    case loadFailed(reason: String)
    /// Allocation failed, or preflight said it would.
    case insufficientMemory(reason: String)
    case noModelLoaded
    case generationFailed(reason: String)
    case cancelled

    public var description: String {
        switch self {
        case .runtimeUnavailable(let reason): return "Local inference is unavailable: \(reason)"
        case .modelFileMissing(let url): return "The model file is missing: \(url.lastPathComponent)"
        case .unsupportedFormat(let reason): return "Unsupported model format: \(reason)"
        case .unsupportedArchitecture(let name): return "Unsupported model architecture: \(name)"
        case .loadFailed(let reason): return "The model failed to load: \(reason)"
        case .insufficientMemory(let reason): return "Not enough memory: \(reason)"
        case .noModelLoaded: return "No model is loaded."
        case .generationFailed(let reason): return "Generation failed: \(reason)"
        case .cancelled: return "Cancelled."
        }
    }
}

/// The seam between the assistant and whatever performs inference.
///
/// ## What is on each side
///
/// Above it: ``LocalModelProvider``, and above that `AssistantEngine`, the tool
/// pipeline, memory and everything the user owns. None of them knows what GGUF
/// is, what a KV cache is, or that llama.cpp exists.
///
/// Below it: exactly one implementation per runtime. `LlamaCppRuntime` owns the
/// native pointers, the Metal configuration, the tokenizer and the sampler
/// chain, and hands back a `String`.
///
/// ## Why the vocabulary is this small
///
/// Six members, all of which a runtime that is not llama.cpp could also
/// implement. That is the test the protocol has to pass: MLX, ExecuTorch or a
/// Core ML pipeline should be able to conform without the protocol growing a
/// case that only makes sense for one of them. Anything llama.cpp-specific —
/// GPU layer counts, batch sizes, flash attention — is configured inside the
/// adapter and never appears here.
///
/// ## One model, one generation
///
/// Implementations hold at most one loaded model (section 31) and serialize
/// generation (section 49). Two turns racing one context is not a performance
/// problem, it is a corrupted KV cache, so conformers are actors or wrap one.
public protocol LocalModelRuntime: Sendable {
    var runtimeCapabilities: LocalRuntimeCapabilities { get }

    /// Whether inference could run at all on this build and device. Cheap:
    /// called before every turn, so no loading and no allocation.
    func runtimeAvailability() async -> LocalRuntimeAvailability

    /// The model currently in memory, if any.
    func loadedModel() async -> LoadedModelInfo?

    /// Opens a model, replacing whatever was loaded before.
    func loadModel(_ request: LocalModelLoadRequest) async throws -> LoadedModelInfo

    /// Releases the model and every native resource behind it.
    func unloadModel() async

    func generate(
        _ prompt: LocalPrompt,
        options: LocalGenerationOptions
    ) async throws -> LocalGenerationOutput

    /// Asks the in-flight generation to stop. Returns once the request is
    /// recorded, not once generation has finished.
    func cancelGeneration() async
}

/// Whether local inference can run right now.
public enum LocalRuntimeAvailability: Hashable, Sendable {
    case available
    /// The runtime works but nothing is loaded yet.
    case idle
    /// No runtime is linked into this build, or the device cannot run it.
    case unavailable(reason: String)

    public var canRun: Bool {
        switch self {
        case .available, .idle: return true
        case .unavailable: return false
        }
    }
}
