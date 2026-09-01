import AssistantAI
import AssistantDomain
import Foundation

/// A runtime that behaves like an inference engine without being one.
///
/// ## Why this ships rather than living in a test target
///
/// Three reasons, the same ones that put `MockPlatform` in the package:
///
/// 1. Several test targets need it, and a type duplicated per target is a type
///    that drifts per target.
/// 2. SwiftUI previews and the deterministic screenshot run need a Local AI
///    that answers, on a machine with no model file and no GPU.
/// 3. Section 88 and section 89: CI must exercise load, generation, tool
///    calling, cancellation and out-of-memory without downloading gigabytes,
///    and every one of those is a *scripted* response here.
///
/// ## What it does not do
///
/// It does not infer anything. It replays what it was told to, which is the
/// point — a test asserting that a tool call reaches the authorization layer
/// should fail when the *plumbing* breaks, not when a 1B model has an off day.
/// Real generation quality is a real-device question (section 121).
public actor MockLocalModelRuntime: LocalModelRuntime {
    /// What the next generation should do.
    public enum Response: Sendable {
        /// Return this text.
        case text(String)
        /// Return the app's structured envelope proposing these calls.
        case toolCalls(names: [String], arguments: [[String: JSONValue]], message: String)
        /// Return raw output verbatim, however malformed.
        case raw(String)
        /// Fail with this error.
        case failure(LocalRuntimeError)
        /// Block until cancelled, then report cancellation.
        case hangUntilCancelled
    }

    /// What loading should do.
    public enum LoadBehaviour: Sendable {
        case succeed
        case fail(LocalRuntimeError)
    }

    public nonisolated let runtimeCapabilities = LocalRuntimeCapabilities(
        supportedFormats: [.gguf],
        usesHardwareAcceleration: false,
        supportsLoadCancellation: true,
        runtimeName: "Mock",
        runtimeVersion: "test"
    )

    private var availability: LocalRuntimeAvailability
    private var loaded: LoadedModelInfo?
    private var loadBehaviour: LoadBehaviour = .succeed
    /// Queued responses, consumed one per generation. The last one repeats,
    /// so a multi-round test does not have to script a turn it does not care
    /// about.
    private var responses: [Response] = []
    private var lastResponse: Response = .text("Ready.")
    private var isCancelled = false

    // Counters, for tests that assert a model was not loaded twice or that
    // switching really did unload the first one.
    public private(set) var loadCount = 0
    public private(set) var unloadCount = 0
    public private(set) var generateCount = 0
    /// The prompt the last generation was given. How a test checks the system
    /// prompt and the memory context actually arrived.
    public private(set) var lastPrompt: LocalPrompt?
    public private(set) var lastOptions: LocalGenerationOptions?
    /// How many scripted responses the grammar refused to let through.
    ///
    /// See `generate(_:options:)` for why the mock enforces a grammar at all.
    public private(set) var constrainedRejections = 0

    public init(availability: LocalRuntimeAvailability = .idle) {
        self.availability = availability
    }

    // MARK: Scripting

    public func setAvailability(_ value: LocalRuntimeAvailability) {
        availability = value
    }

    public func setLoadBehaviour(_ value: LoadBehaviour) {
        loadBehaviour = value
    }

    /// Queues responses, consumed in order.
    public func enqueue(_ responses: Response...) {
        self.responses.append(contentsOf: responses)
    }

    /// Sets the response every generation returns.
    public func alwaysRespond(_ response: Response) {
        responses.removeAll()
        lastResponse = response
    }

    // MARK: LocalModelRuntime

    public func runtimeAvailability() async -> LocalRuntimeAvailability {
        if loaded != nil, case .idle = availability { return .available }
        return availability
    }

    public func loadedModel() async -> LoadedModelInfo? { loaded }

    public func loadModel(_ request: LocalModelLoadRequest) async throws -> LoadedModelInfo {
        loadCount += 1
        if case .fail(let error) = loadBehaviour {
            loaded = nil
            throw error
        }
        let info = LoadedModelInfo(
            modelID: request.modelID,
            architecture: "mock",
            contextLength: request.contextLength,
            trainedContextLength: request.contextLength,
            parameterCount: 1_000_000_000,
            hasEmbeddedChatTemplate: true
        )
        loaded = info
        return info
    }

    public func unloadModel() async {
        // Counted only when there was something to release, so a test can
        // assert "switching models unloaded the old one" without every
        // defensive unload inflating the number.
        if loaded != nil { unloadCount += 1 }
        loaded = nil
    }

    public func generate(
        _ prompt: LocalPrompt,
        options: LocalGenerationOptions
    ) async throws -> LocalGenerationOutput {
        guard loaded != nil else { throw LocalRuntimeError.noModelLoaded }
        generateCount += 1
        lastPrompt = prompt
        lastOptions = options
        isCancelled = false

        let response = responses.isEmpty ? lastResponse : responses.removeFirst()

        // ## Why a mock enforces the grammar
        //
        // A scripted runtime that ignored `options.grammar` would let every
        // constrained-generation test pass by assertion rather than by
        // construction: "the model returned prose" would prove nothing, because
        // a real constrained model *cannot* return prose. CI has no llama.cpp —
        // there is no simulator slice and no model file — so the only way for
        // these tests to mean anything is for the mock to apply the same
        // constraint llama.cpp would.
        //
        // A response the grammar cannot express comes back as empty output,
        // which is what a real sampler produces when every continuation it
        // would have chosen is masked: nothing usable, and the classifier
        // upstream treats it as a malformed attempt.
        if let grammar = options.grammar,
            let compiled = try? GBNFGrammar.validate(
                grammar, root: SemanticActionGrammar.rootRule
            ) {
            let candidate = Self.text(of: response)
            if let candidate, !compiled.matches(candidate) {
                constrainedRejections += 1
                return LocalGenerationOutput(text: "", stop: .maximumTokens)
            }
        }

        switch response {
        case .text(let text):
            return LocalGenerationOutput(
                text: text,
                stop: .endOfText,
                promptTokens: prompt.turns.reduce(0) { $0 + $1.content.count / 4 },
                generatedTokens: text.count / 4
            )

        case .raw(let text):
            return LocalGenerationOutput(text: text, stop: .endOfText)

        case .toolCalls(let names, let arguments, let message):
            return LocalGenerationOutput(
                text: Self.envelope(names: names, arguments: arguments, message: message),
                stop: .endOfText
            )

        case .failure(let error):
            throw error

        case .hangUntilCancelled:
            // Polls rather than sleeping for a fixed time, so a cancellation
            // test finishes in milliseconds instead of waiting out a timeout.
            for _ in 0..<10_000 {
                if isCancelled {
                    return LocalGenerationOutput(text: "", stop: .cancelled)
                }
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            return LocalGenerationOutput(text: "", stop: .maximumTokens)
        }
    }

    public func cancelGeneration() async {
        isCancelled = true
    }

    /// What a scripted response would put on the wire, for the grammar check.
    ///
    /// Nil for the cases that produce no text at all — a thrown error and a
    /// cancellation are not things a grammar has an opinion about.
    static func text(of response: Response) -> String? {
        switch response {
        case .text(let value), .raw(let value):
            return value
        case .toolCalls(let names, let arguments, let message):
            return envelope(names: names, arguments: arguments, message: message)
        case .failure, .hangUntilCancelled:
            return nil
        }
    }

    /// Renders the same envelope a real model is asked to produce.
    ///
    /// Deliberately the adapter's own renderer, so a test that scripts a tool
    /// call goes through the actual parser rather than around it. A mock that
    /// hand-rolled its own JSON would keep passing after the format changed.
    static func envelope(
        names: [String],
        arguments: [[String: JSONValue]],
        message: String
    ) -> String {
        let calls = names.enumerated().map { index, name in
            AIToolCall(
                name: name,
                arguments: .object(index < arguments.count ? arguments[index] : [:])
            )
        }
        return LocalToolPromptAdapter.renderEnvelope(calls: calls, message: message)
    }
}
