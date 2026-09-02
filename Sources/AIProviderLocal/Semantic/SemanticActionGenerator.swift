import AssistantAI
import AssistantDomain
import Foundation

/// One constrained semantic action, from a loaded model.
///
/// ## Why this is its own type as of Part 3
///
/// Two things now generate semantic actions: the chat model, used as the
/// temporary action backend, and the *dedicated* action model with its own
/// lifecycle and its own small context. Section 4 says to share low-level
/// infrastructure and keep the lifecycles apart — so everything from "build the
/// grammar" to "classify what came back" lives here, once, and the two callers
/// differ only in which runtime and which loaded model they hand it.
///
/// What it deliberately does not own: loading, unloading, selection,
/// availability, or which model this is. Those are lifecycle, and the whole
/// point of Part 3 is that the action model has its own.
///
/// ## What it guarantees
///
/// Constrained or nothing. The grammar is built and validated before a prompt
/// is assembled, and a grammar that will not build throws rather than
/// generating freely (Part 2, sections 17 and 18). There is no branch here that
/// reaches `runtime.generate` without `options.grammar` set.
struct SemanticActionGenerator: Sendable {

    let diagnostics: any LocalInferenceDiagnosticSink
    private let parser = LocalSemanticActionParser()

    init(diagnostics: any LocalInferenceDiagnosticSink) {
        self.diagnostics = diagnostics
    }

    /// What this backend constrains with. A symbol for the log, not a claim
    /// about any other backend.
    static let constraintType = "gbnf"

    /// Enough for one envelope with a couple of fields.
    static let outputTokenLimit = 192

    /// Everything a generation needs that is not the request itself.
    struct Environment: Sendable {
        var runtime: any LocalModelRuntime
        var loaded: LoadedModelInfo
        var descriptor: LocalModelDescriptor?
        var configuration: LocalInferenceConfiguration
    }

    // MARK: The flow

    func generate(
        request: ActionModelRequest,
        constraints: ActionGenerationConstraints,
        environment: Environment
    ) async throws -> LocalSemanticActionResult {
        // Section 18 of Part 2: the grammar is built and *checked* before a
        // prompt is assembled. `llama_sampler_init_grammar` would catch a
        // broken grammar too, but only as a null pointer with nothing to say
        // about what was wrong.
        let grammar = try validatedGrammar(for: constraints.semanticSchema)

        var recovery = LocalActionRecoveryPolicy()
        var outcome = try await interpret(
            request: request,
            grammar: grammar,
            repairInstruction: nil,
            environment: environment
        )
        diagnostics.info(
            .semanticActionParsed,
            category: .generation,
            metadata: Self.outcomeMetadata(outcome)
                .setting(.repairAttempt, 0)
                .setting(.semanticProtocolActive, true)
                .setting(.constrainedGenerationActive, true)
        )

        if outcome.isRepairable, recovery.consume() {
            // Part 2, section 15. The retry is constrained *more* tightly, not
            // less: if the router was confident about the family, the repair
            // grammar can only express that family, so "answered a reminder
            // with a memory" is not a mistake the second attempt can repeat.
            let narrowed = ActionGenerationConstraints.narrowed(to: request.detectedCategory)
            let repairSchema = narrowed.semanticSchema.intents.isEmpty
                ? constraints.semanticSchema
                : narrowed.semanticSchema
            let repairGrammar = try validatedGrammar(for: repairSchema)

            outcome = try await interpret(
                request: request,
                grammar: repairGrammar,
                repairInstruction: LocalSemanticPrompt.repairInstruction(for: outcome),
                environment: environment
            )
            diagnostics.info(
                .semanticActionRepaired,
                category: .generation,
                metadata: Self.outcomeMetadata(outcome)
                    .setting(.repairAttempt, 1)
                    .setting(.repairResult, outcome.symbol)
                    .setting(.constrainedGenerationActive, true)
                    .setting(.constraintIntentCount, repairSchema.intents.count)
            )
        }

        switch outcome {
        case .validSemanticAction(let action):
            return .action(action)
        case .normalChat(let message):
            return .noActionNeeded(message: message)
        case .forbiddenImplementationDetails(let failure):
            throw ActionModelError.semanticValidationFailed(failure.symbol)
        case .malformedSemanticAction(let reason):
            throw ActionModelError.semanticParsingFailed(reason)
        case .protocolLeak, .internalToolProtocolLeak, .unsupportedSemanticIntent,
             .failedActionAttempt:
            throw ActionModelError.semanticParsingFailed(outcome.symbol)
        }
    }

    // MARK: The grammar

    /// Builds the grammar for a schema and refuses to proceed without one.
    ///
    /// Part 2, sections 17, 18 and 26. There is no branch here that returns "no
    /// grammar, carry on": a constraint that cannot be built is a failed action
    /// request, full stop.
    func validatedGrammar(for schema: LocalSemanticActionSchema) throws -> String {
        let grammar = SemanticActionGrammar.gbnf(for: schema)
        do {
            _ = try GBNFGrammar.validate(grammar, root: SemanticActionGrammar.rootRule)
        } catch {
            let symbol = (error as? GBNFGrammar.ValidationFailure)?.symbol ?? "invalidGrammar"
            diagnostics.problem(
                .actionConstrainedGeneration,
                category: .generation,
                metadata: LocalInferenceMetadata()
                    .setting(.constrainedGenerationActive, false)
                    .setting(.constraintType, Self.constraintType)
                    .setting(.errorReason, SemanticActionGrammar.initializationFailureReason)
                    .setting(.validationResult, symbol)
            )
            throw ActionModelError.constraintInitializationFailed(symbol)
        }

        diagnostics.info(
            .actionConstrainedGeneration,
            category: .generation,
            metadata: LocalInferenceMetadata()
                .setting(.constrainedGenerationActive, true)
                .setting(.constraintType, Self.constraintType)
                .setting(.constraintIntentCount, schema.intents.count)
        )
        return grammar
    }

    // MARK: One generation

    /// One generation, classified. Shared by the first attempt and the repair.
    private func interpret(
        request: ActionModelRequest,
        grammar: String,
        repairInstruction: String?,
        environment: Environment
    ) async throws -> LocalSemanticOutcome {
        let prompt = Self.actionPrompt(
            for: request,
            repairInstruction: repairInstruction,
            descriptor: environment.descriptor,
            loaded: environment.loaded
        )
        let fitted = LocalPromptBudget.fit(prompt, configuration: environment.configuration)

        // Section 24: the budget is checked rather than assumed. An action
        // prompt that does not fit the action context is a configuration bug,
        // and failing here says so — where the alternative is llama.cpp being
        // asked to decode more tokens than the context holds.
        let promptTokens = LocalPromptBudget.estimatedTokens(in: fitted.prompt)
        diagnostics.info(
            .actionModelInference,
            category: .generation,
            metadata: LocalInferenceMetadata()
                .setting(.estimatedTokenCount, promptTokens)
                .setting(.contextBudget, environment.configuration.maximumPromptTokens)
                .setting(.actualContextSize, environment.configuration.contextLength)
                .setting(.promptWasTrimmed, fitted.wasTrimmed)
                .setting(.constraintIntentCount, 0)
        )

        // Part 2, section 22: greedy, extraction-shaped sampling — there is one
        // right answer to "which intent is this", and sampling among near-ties
        // is how the same sentence becomes a reminder today and a memory
        // tomorrow. Chat sampling is untouched; this profile exists only here.
        var options = LocalGenerationOptions.semanticAction
        options.maximumOutputTokens = min(
            Self.outputTokenLimit, environment.configuration.maximumGenerationTokens
        )
        options.stopSequences = (environment.descriptor?.chatTemplate ?? .modelDefault)
            .stopSequences
        // The grammar goes on this generation and only this generation: nothing
        // answering a chat message ever carries one, and once the object is
        // complete the grammar has no production left, so there is no path to
        // prose after the action.
        options.grammar = grammar

        let output: LocalGenerationOutput
        do {
            output = try await environment.runtime.generate(fitted.prompt, options: options)
        } catch let error as LocalRuntimeError {
            throw ActionModelError.generationFailed(Self.errorKind(of: error))
        } catch {
            throw ActionModelError.generationFailed("unknown")
        }
        if output.stop == .cancelled { throw AIProviderError.cancelled }

        return parser.classify(
            output.text, expectsAction: true, detectedCategory: request.detectedCategory
        )
    }

    // MARK: The prompt

    /// The whole prompt an action turn gets.
    ///
    /// Sections 18 and 19: the protocol, the sentence, and — for a repair — one
    /// short instruction. No history, no memories, no personality, no tool
    /// schemas, and no date. `ActionModelPromptTests` asserts the turn count.
    static func actionPrompt(
        for request: ActionModelRequest,
        repairInstruction: String?,
        descriptor: LocalModelDescriptor?,
        loaded: LoadedModelInfo?
    ) -> LocalPrompt {
        var turns: [LocalChatTurn] = [
            .system(actionSystemPrompt),
            .user(request.userRequest),
        ]
        if let repairInstruction { turns.append(.user(repairInstruction)) }
        return LocalPrompt(
            turns: turns, fallback: resolvedTemplate(descriptor: descriptor, loaded: loaded)
        )
    }

    static let actionSystemPrompt: String =
        "You turn a person's request into one action for the app to carry out. "
        + "Reply with the JSON object and nothing else.\n\n"
        + LocalSemanticPrompt.instructions()

    /// Which chat template to fall back to when the file carries none.
    static func resolvedTemplate(
        descriptor: LocalModelDescriptor?,
        loaded: LoadedModelInfo?
    ) -> LocalChatTemplate {
        let fallback = descriptor?.chatTemplate ?? .modelDefault
        guard fallback == .modelDefault, loaded?.hasEmbeddedChatTemplate != true else {
            return fallback
        }
        return LocalChatTemplate.inferred(
            fromArchitecture: loaded?.architecture ?? descriptor?.architecture ?? ""
        )
    }

    // MARK: Diagnostics

    /// Everything about a classified outcome that is safe to write down.
    static func outcomeMetadata(_ outcome: LocalSemanticOutcome) -> LocalInferenceMetadata {
        var metadata = LocalInferenceMetadata()
            .setting(.semanticOutcome, outcome.symbol)
            .setting(.semanticParseSuccess, outcome.isUsable)
        switch outcome {
        case .validSemanticAction(let action):
            metadata = metadata
                .setting(.semanticIntent, action.intent.rawValue)
                .setting(.semanticFieldCount, action.arguments.count)
        case .unsupportedSemanticIntent:
            metadata = metadata.setting(.semanticValidation, "unsupportedIntent")
        case .forbiddenImplementationDetails(let failure):
            metadata = metadata.setting(.semanticValidation, failure.symbol)
            if case .forbiddenImplementationDetail(let field, let kind) = failure {
                metadata = metadata
                    .setting(.semanticRejectedField, field)
                    .setting(.semanticRejectedFieldCategory, kind)
            }
            if case .unknownArgument(let field) = failure {
                metadata = metadata.setting(.semanticRejectedField, field)
            }
        default:
            break
        }
        return metadata
    }

    /// A short symbolic name for a runtime failure.
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
}

extension LocalSemanticOutcome {
    /// Whether this outcome produced something the app can act on.
    ///
    /// Section 25's `semanticParseSuccess`, as a property of the outcome rather
    /// than a boolean computed at each call site.
    var isUsable: Bool {
        switch self {
        case .validSemanticAction, .normalChat: return true
        default: return false
        }
    }
}
