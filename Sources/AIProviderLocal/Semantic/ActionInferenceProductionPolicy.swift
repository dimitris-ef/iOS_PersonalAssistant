import AssistantAI
import AssistantDomain
import Foundation

/// What an action model is opened with, and why it is not what a chat model is
/// opened with.
///
/// ## The two jobs are not the same size
///
/// Sections 23, 24, 25, 29 and 30. A chat turn carries a system prompt, the
/// retrieved memories, a conversation and room for a paragraph back; it wants
/// the largest context the phone can hold. An action turn carries one sentence
/// and six intent descriptions, and produces one JSON object of maybe forty
/// tokens.
///
/// Opening the action model at 4096 or 8192 would allocate a KV cache sized for
/// a conversation that cannot happen — the action path sends no history, by
/// construction (section 19) — on a phone that is already holding a chat model.
/// The context here is sized for the work: the protocol, the sentence, and the
/// answer.
///
/// ## Why a separate type rather than a tweak to the chat configuration
///
/// Because the two must be able to move independently. Raising the chat context
/// on a future device tier should not quietly raise the action model's, and
/// `LocalInferenceConfiguration.forDevice` is written to spend what the device
/// has — which is the right instinct for the model somebody is talking to and
/// the wrong one for a classifier.
public struct ActionInferenceProductionPolicy: Hashable, Sendable {

    /// Tokens the action model is opened with.
    ///
    /// The measured shape of the work, with room to spare: the protocol block
    /// is a few hundred tokens, a user request is rarely more than fifty, and
    /// the repair adds one short instruction. 1024 leaves roughly a factor of
    /// two of headroom and still costs a fraction of a chat context's KV cache.
    public var contextLength: Int
    /// Tokens per `llama_decode`. The action prompt fits inside one batch at
    /// this size, so chunking is available but rarely exercised here.
    public var batchSize: Int
    public var microBatchSize: Int
    public var threadCount: Int
    /// Section 25. One semantic action, and nothing after it.
    public var maximumGenerationTokens: Int
    /// Section 27. The production default, and it is the one the app ships:
    /// GPU requested, CPU-only off. The action model inherits the *policy*, not
    /// any diagnostic residue — the settings-migration work that cleared
    /// crash-investigation CPU-only defaults applies here too, and this type
    /// starts from the production answer rather than from stored state.
    public var requestsGPUOffload: Bool

    public init(
        contextLength: Int = 1024,
        batchSize: Int = 128,
        microBatchSize: Int = 64,
        threadCount: Int = 2,
        maximumGenerationTokens: Int = 192,
        requestsGPUOffload: Bool = true
    ) {
        self.contextLength = contextLength
        self.batchSize = batchSize
        self.microBatchSize = microBatchSize
        self.threadCount = threadCount
        self.maximumGenerationTokens = maximumGenerationTokens
        self.requestsGPUOffload = requestsGPUOffload
    }

    /// What the app ships.
    public static let production = ActionInferenceProductionPolicy()

    /// The inference configuration this policy implies.
    ///
    /// Deliberately *not* `LocalInferenceConfiguration.forDevice`: that scales
    /// with the phone's memory, which is what a chat model should do and what
    /// an extractor should not. A bigger phone does not make this job bigger.
    public var configuration: LocalInferenceConfiguration {
        LocalInferenceConfiguration(
            contextLength: contextLength,
            batchSize: batchSize,
            microBatchSize: microBatchSize,
            threadCount: threadCount,
            maximumGenerationTokens: maximumGenerationTokens,
            // A quarter of the context held back for the answer. The action
            // model's answer is small, so this is generous rather than tight —
            // and generous here means the prompt budget refuses early rather
            // than the decode running out of context natively.
            generationReserveTokens: max(128, contextLength / 4)
        )
    }

    /// What the runtime is asked to open, for a model at `fileURL`.
    ///
    /// The GPU request is carried explicitly, the way the chat path carries it,
    /// so the log can record what was asked for separately from what the
    /// runtime managed (section 46).
    public func loadRequest(
        modelID: AIModelIdentifier,
        fileURL: URL,
        overrides: LocalInferenceDiagnosticOverrides = .none
    ) -> LocalModelLoadRequest {
        let applied = overrides.apply(to: configuration)
        return LocalModelLoadRequest(
            modelID: modelID,
            fileURL: fileURL,
            contextLength: applied.contextLength,
            threadCount: applied.threadCount,
            batchSize: applied.batchSize,
            microBatchSize: applied.microBatchSize,
            // Section 28: an explicit diagnostic override still applies, so
            // "does this still fail on the CPU" remains answerable from a
            // device. Absence of an override is not an override.
            gpuOffloadRequested: requestsGPUOffload
                && LocalInferenceProductionPolicy.production.wantsGPUOffload(with: overrides)
        )
    }

    /// Whether this load ran the product's own configuration rather than a
    /// diagnostic handicap (section 46).
    public func isProductionProfile(with overrides: LocalInferenceDiagnosticOverrides) -> Bool {
        requestsGPUOffload
            && LocalInferenceProductionPolicy.production.isProductionProfile(with: overrides)
    }
}
