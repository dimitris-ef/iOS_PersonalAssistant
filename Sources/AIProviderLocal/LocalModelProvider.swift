import AssistantAI
import AssistantDomain
import Foundation

/// The assistant, running on a model the user downloaded onto their phone.
///
/// ## Where this sits
///
/// ```
/// AssistantEngine
///     ↓  AIProvider
/// LocalModelProvider          ← here
///     ↓  LocalModelRuntime
/// LlamaCppRuntime
///     ↓
/// the downloaded GGUF
/// ```
///
/// Everything above this type is unchanged from the cloud and Apple paths: the
/// same system prompt, the same assembled context, the same semantic memory,
/// the same tool schemas, the same agent loop, the same validation and
/// authorization. That is the claim Part 10 makes, and it is visible in what
/// this file does *not* contain — no repositories, no platform services, no
/// memory lookup, no execution.
///
/// ## What it does contain
///
/// Translation, in both directions. An `AIRequest` becomes chat turns plus tool
/// instructions; raw generated text becomes an `AIResponse` with `AIToolCall`s.
/// Both halves are somebody else's code — ``LocalToolPromptAdapter`` — called
/// from here.
///
/// ## Never a cloud fallback
///
/// Section 128. If local inference fails, this returns a local failure. It does
/// not quietly route the user's message to a remote service: someone who chose
/// an on-device model chose it for a reason, and silently uploading the request
/// they wanted kept on the phone would be the single worst thing this file
/// could do.
public struct LocalModelProvider: AIProvider {
    public static let providerID: AIProviderIdentifier = "local.downloaded-model"

    public let metadata: AIProviderMetadata
    private let manager: LocalModelManager
    private let runtime: (any LocalModelRuntime)?
    private let adapter: LocalToolPromptAdapter
    private let diagnostics: any LocalInferenceDiagnosticSink

    public init(
        manager: LocalModelManager,
        runtime: (any LocalModelRuntime)? = nil,
        adapter: LocalToolPromptAdapter = LocalToolPromptAdapter(),
        diagnostics: any LocalInferenceDiagnosticSink = NullLocalInferenceDiagnosticSink()
    ) {
        self.manager = manager
        self.runtime = runtime
        self.adapter = adapter
        self.diagnostics = diagnostics
        self.metadata = AIProviderMetadata(
            id: Self.providerID,
            displayName: "Local AI",
            kind: .downloadedLocalModel,
            requiresNetwork: false,
            requiresCredentials: false,
            capabilityRank: 40,
            // Section 59: the engine may send tool results back and ask for a
            // continuation. True for the provider as a whole; whether a given
            // model is *good* at it is what `toolSupport` in the catalog is
            // for, and a model marked chat-only is never offered tools at all.
            supportsToolResultContinuation: true
        )
    }

    // MARK: Availability

    /// Cheap, and honest.
    ///
    /// Section 63: with nothing downloaded this is `configurationRequired`, not
    /// `unsupported` — the difference is a Settings screen that offers a way
    /// forward rather than a dead end.
    public func availability() async -> AIProviderAvailability {
        switch await manager.availability() {
        case .ready, .modelDownloaded:
            // `modelDownloaded` counts as available: the model is on disk,
            // verified, and loading it is this provider's job at the start of a
            // turn. Reporting it unavailable would mean the user had to load it
            // by hand before they could type anything.
            return .available
        case .modelLoading:
            return .temporarilyUnavailable(reason: "The local model is still loading.")
        case .noModelInstalled:
            return .configurationRequired(reason: "Download a model to use Local AI.")
        case .modelIncompatible(let reason):
            return .unsupported(reason: reason)
        case .insufficientMemory(let reason):
            return .unsupported(reason: reason)
        case .corruptedModel(let reason):
            return .configurationRequired(reason: reason)
        case .runtimeUnavailable(let reason):
            return .unsupported(reason: reason)
        }
    }

    public func availableModels() async throws -> [AIModel] {
        let statuses = await manager.statuses()
        return statuses
            .filter { $0.lifecycle.isInstalled }
            .map { status in
                AIModel(
                    id: status.descriptor.id,
                    displayName: status.descriptor.displayName,
                    contextWindow: status.installed?.contextLength
                        ?? status.descriptor.defaultContextLength,
                    supportsNativeToolCalling: false,
                    isOnDevice: true
                )
            }
    }

    // MARK: Generation

    public func respond(to request: AIRequest) async throws -> AIResponse {
        guard let runtime else {
            throw AIProviderError.unavailable(LocalModelManager.noRuntimeReason)
        }

        let modelID = try await resolveModel(request.model)
        let descriptor = await manager.catalogModels().first { $0.id == modelID }

        // Section 98: one diagnostic inference session per attempted user
        // generation, opened here because this is the single door every local
        // turn goes through — including the lazy load that follows.
        let inferenceOperation = diagnostics.criticalEnter(
            .inference,
            metadata: LocalInferenceMetadata()
                .setting(.providerID, Self.providerID.rawValue)
                .setting(.modelID, modelID.rawValue)
        )
        var completed = false
        defer {
            if !completed {
                diagnostics.criticalFailure(
                    .inference, operation: inferenceOperation,
                    metadata: LocalInferenceMetadata().setting(.errorKind, "threw")
                )
            }
        }

        let loaded: LoadedModelInfo
        do {
            loaded = try await manager.load(modelID)
        } catch let error as LocalRuntimeError {
            // Section 47: a native failure is recorded before it is mapped, so
            // the log keeps the runtime's own vocabulary rather than only the
            // sentence the user was shown.
            diagnostics.problem(
                .nativeError,
                category: .runtime,
                stage: .modelLoad,
                metadata: LocalInferenceMetadata()
                    .setting(.modelID, modelID.rawValue)
                    .setting(.errorKind, Self.errorKind(of: error))
                    .setting(.errorReason, error.description)
            )
            throw Self.providerError(from: error)
        }

        // A model the catalog marks chat-only is never shown the tool
        // instructions (sections 55 and 56). Offering tools to a model that
        // cannot form them produces malformed envelopes, which become parse
        // errors, which become a turn that failed for no reason the user can
        // see — where the honest behaviour is a normal conversational reply.
        let toolSupport = descriptor?.toolSupport ?? .experimental
        let tools = toolSupport.offersTools ? request.tools : []

        // Section 34. The ENTER carries only shapes and counts; the EXIT carries
        // the size of what was built. Section 35 is absolute and this is where
        // it would be broken if it were going to be: the prompt object exists
        // right here, in scope, and nothing below writes a character of it.
        let promptOperation = diagnostics.criticalEnter(
            .promptConstruct,
            metadata: Self.promptMetadata(for: request, tools: tools)
        )
        let unbounded = makePrompt(
            for: request,
            tools: tools,
            descriptor: descriptor,
            loaded: loaded
        )
        var options = makeOptions(for: request, tools: tools, descriptor: descriptor)

        // Sections 52 and 53. The context the runtime was opened with, not the
        // one the catalog advertises: `LocalModelManager` shrinks it to fit
        // memory, so a model whose record says 4096 may be running at 1024, and
        // sending it 3000 tokens is one of the ways this crashes natively
        // rather than returning an error anything can catch.
        let configuration = await manager.activeConfiguration()
            ?? LocalInferenceConfiguration.conservative.withContextLength(loaded.contextLength)
        let fitted = LocalPromptBudget.fit(unbounded, configuration: configuration)
        let promptTokens = LocalPromptBudget.estimatedTokens(in: fitted.prompt)
        options.maximumOutputTokens = LocalPromptBudget.generationLimit(
            promptTokens: promptTokens,
            requested: min(options.maximumOutputTokens, configuration.maximumGenerationTokens),
            configuration: configuration
        )

        diagnostics.criticalExit(
            .promptConstruct,
            operation: promptOperation,
            metadata: LocalInferenceMetadata()
                .setting(.estimatedTokenCount, promptTokens)
                .setting(.characterCount, fitted.prompt.turns.reduce(0) { $0 + $1.content.count })
                .setting(.contextBudget, configuration.maximumPromptTokens)
                .setting(.generationReserve, options.maximumOutputTokens)
                .setting(.actualContextSize, configuration.contextLength)
                .setting(.promptWasTrimmed, fitted.wasTrimmed)
                .setting(.droppedTurnCount, fitted.droppedTurns)
        )

        let output: LocalGenerationOutput
        do {
            output = try await runtime.generate(fitted.prompt, options: options)
        } catch let error as LocalRuntimeError {
            diagnostics.problem(
                .generationFailed,
                category: .generation,
                metadata: LocalInferenceMetadata()
                    .setting(.modelID, modelID.rawValue)
                    .setting(.errorKind, Self.errorKind(of: error))
                    .setting(.errorReason, error.description)
                    .setting(.generatedTokenCount, 0)
            )
            throw Self.providerError(from: error)
        }
        completed = true
        diagnostics.criticalExit(
            .inference,
            operation: inferenceOperation,
            metadata: LocalInferenceMetadata()
                .setting(.generatedTokenCount, output.generatedTokens)
                .setting(.promptTokenCount, output.promptTokens)
                .setting(.stopReason, output.stop.rawValue)
        )

        if output.stop == .cancelled {
            throw AIProviderError.cancelled
        }

        let parsed: LocalModelOutput
        do {
            parsed = try adapter.parse(
                output.text,
                offeredTools: tools,
                maximumCalls: request.options.maximumToolCalls
            )
        } catch let error as LocalToolParseError {
            // Section 57: a structured-output failure, reported as one. Not a
            // partial execution, and not prose passed off as an answer.
            throw AIProviderError.invalidResponse(error.description)
        }

        return AIResponse(
            text: parsed.text,
            toolCalls: parsed.toolCalls,
            stopReason: stopReason(for: output, hasToolCalls: !parsed.toolCalls.isEmpty),
            usage: AIUsage(
                inputTokens: output.promptTokens,
                outputTokens: output.generatedTokens
            ),
            providerID: metadata.id,
            modelID: modelID
        )
    }

    /// Stops the generation in flight.
    ///
    /// Section 48: the model stays loaded. Unloading gigabytes to abandon one
    /// reply would make cancelling cost more than waiting.
    public func cancelGeneration() async {
        await runtime?.cancelGeneration()
    }

    // MARK: Prompt construction

    /// Turns the provider-neutral request into chat turns.
    ///
    /// Section 41: the app's system prompt goes in unchanged. There is no
    /// separate "local AI personality" — the assistant is the same assistant,
    /// and the only thing appended is the protocol for proposing actions.
    func makePrompt(
        for request: AIRequest,
        tools: [AIToolSchema],
        descriptor: LocalModelDescriptor?,
        loaded: LoadedModelInfo?
    ) -> LocalPrompt {
        var turns: [LocalChatTurn] = []

        var system = request.systemPrompt
        let instructions = adapter.instructions(for: tools)
        if !instructions.isEmpty {
            system += "\n\n" + instructions
        }
        if !system.isEmpty {
            turns.append(.system(system))
        }

        for message in request.messages {
            switch message.role {
            case .system:
                turns.append(.system(message.content))
            case .user:
                turns.append(.user(message.content))
            case .assistant:
                // An assistant turn that proposed actions is replayed as the
                // envelope it produced, so the continuation round sees its own
                // previous output in the form it was trained to produce.
                if !message.toolCalls.isEmpty {
                    turns.append(.assistant(Self.replay(message)))
                } else {
                    turns.append(.assistant(message.content))
                }
            case .tool:
                // Section 60. Results come back as a compact, structured line —
                // the same `renderedForModel` every other provider gets — and
                // never as a serialized platform object. A small model given an
                // `EKEvent` dump would spend its whole context on it.
                turns.append(
                    LocalChatTurn(
                        role: "tool",
                        content: message.toolResult?.renderedForModel ?? message.content
                    )
                )
            }
        }

        let fallback = descriptor?.chatTemplate ?? .modelDefault
        let resolved: LocalChatTemplate
        if fallback == .modelDefault, loaded?.hasEmbeddedChatTemplate != true {
            // The file has no template of its own and the catalog deferred to
            // it, so guess from the architecture rather than emitting labelled
            // plain text at a model trained on markers.
            resolved = LocalChatTemplate.inferred(
                fromArchitecture: loaded?.architecture ?? descriptor?.architecture ?? ""
            )
        } else {
            resolved = fallback
        }

        return LocalPrompt(turns: turns, fallback: resolved)
    }

    /// How a previous assistant turn's proposed actions are shown back to it.
    static func replay(_ message: AIMessage) -> String {
        LocalToolPromptAdapter.renderEnvelope(
            calls: message.toolCalls,
            message: message.content
        )
    }

    func makeOptions(
        for request: AIRequest,
        tools: [AIToolSchema],
        descriptor: LocalModelDescriptor?
    ) -> LocalGenerationOptions {
        var options = tools.isEmpty
            ? LocalGenerationOptions.conversational
            : LocalGenerationOptions.structured
        if let temperature = request.options.temperature {
            options.temperature = temperature
        }
        if let maximum = request.options.maximumOutputTokens {
            options.maximumOutputTokens = maximum
        }
        options.stopSequences = (descriptor?.chatTemplate ?? .modelDefault).stopSequences
        return options
    }

    private func stopReason(
        for output: LocalGenerationOutput,
        hasToolCalls: Bool
    ) -> AIStopReason {
        if hasToolCalls { return .toolCalls }
        switch output.stop {
        case .maximumTokens: return .maximumTokens
        case .cancelled: return .other
        case .endOfText, .stopSequence: return .endTurn
        }
    }

    private func resolveModel(_ requested: AIModelIdentifier?) async throws -> AIModelIdentifier {
        if let requested, await manager.status(of: requested)?.lifecycle.isInstalled == true {
            return requested
        }
        guard let selected = await manager.selectedModelID() else {
            throw AIProviderError.modelNotFound(requested ?? "no local model selected")
        }
        return selected
    }

    /// Everything about a prompt that is safe to write down.
    ///
    /// Sections 34, 87, 88 and 89 — counts and nothing else. Read it against
    /// section 35: the request in scope holds the user's message, the system
    /// prompt, the retrieved memories and every tool result, and the only thing
    /// that leaves this function is how many of each there were.
    static func promptMetadata(
        for request: AIRequest,
        tools: [AIToolSchema]
    ) -> LocalInferenceMetadata {
        var system = request.systemPrompt.isEmpty ? 0 : 1
        var user = 0
        var assistant = 0
        var tool = 0
        var characters = request.systemPrompt.count

        for message in request.messages {
            characters += message.content.count
            switch message.role {
            case .system: system += 1
            case .user: user += 1
            case .assistant: assistant += 1
            case .tool: tool += 1
            }
        }

        return LocalInferenceMetadata()
            .setting(.messageCount, request.messages.count)
            .setting(.systemMessageCount, system)
            .setting(.userMessageCount, user)
            .setting(.assistantMessageCount, assistant)
            .setting(.toolMessageCount, tool)
            .setting(.characterCount, characters)
            .setting(.toolCount, tools.count)
        // Section 89 asks for a retrieved-memory count, and this layer honestly
        // does not have one: `ContextAssembler` folds the selected memories into
        // the system prompt before an `AIRequest` exists, so from here they are
        // indistinguishable from the rest of the instructions. The key stays in
        // the allowlist for whoever wires it from the engine; inventing a number
        // to fill the field would be worse than leaving it empty.
    }

    /// A short symbolic name for a runtime failure (section 47).
    static func errorKind(of error: LocalRuntimeError) -> String {
        switch error {
        case .runtimeUnavailable: return "runtimeUnavailable"
        case .modelFileMissing: return "modelFileMissing"
        case .unsupportedFormat: return "unsupportedFormat"
        case .unsupportedArchitecture: return "unsupportedArchitecture"
        case .loadFailed: return "loadFailed"
        case .insufficientMemory: return "insufficientMemory"
        case .noModelLoaded: return "noModelLoaded"
        case .generationFailed: return "generationFailed"
        case .cancelled: return "cancelled"
        }
    }

    /// Maps a runtime failure onto the vocabulary every provider shares.
    ///
    /// Section 35: an allocation failure the runtime *reported* becomes a
    /// meaningful error rather than a crash. What cannot be mapped is the
    /// process being terminated by iOS for memory pressure, which no code
    /// catches — which is why the conservative preflight in
    /// ``LocalModelManager`` exists at all.
    static func providerError(from error: LocalRuntimeError) -> AIProviderError {
        switch error {
        case .runtimeUnavailable(let reason),
             .unsupportedFormat(let reason),
             .loadFailed(let reason),
             .insufficientMemory(let reason):
            return .unavailable(reason)
        case .unsupportedArchitecture(let name):
            return .unavailable("This build cannot run \(name) models.")
        case .modelFileMissing(let url):
            return .unavailable("The model file is missing: \(url.lastPathComponent)")
        case .noModelLoaded:
            return .unavailable("No local model is loaded.")
        case .generationFailed(let reason):
            return .invalidResponse(reason)
        case .cancelled:
            return .cancelled
        }
    }
}
