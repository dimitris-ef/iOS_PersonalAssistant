import AssistantDomain
import Foundation

/// The action system, wearing the one interface the agent loop understands.
///
/// ## Why an `AIProvider`
///
/// Section 19 asks for routing to be integrated "at the correct point in the
/// existing message submission flow" without duplicating the rest of
/// `AssistantEngine`. `AgentRunner` already takes an `AIProvider` and does
/// everything after it: decode, validate, order, claim in the ledger, plan,
/// authorize, confirm, execute, record and summarize. All of that must happen
/// for an action turn exactly as it does today.
///
/// So the action path is not a second pipeline. It is the same pipeline with a
/// different provider at the front — and this is that provider. `respond(to:)`
/// asks the action model for a semantic action and hands back the resolved
/// `AIToolCall`; every check downstream is untouched and still runs.
///
/// ## Why the reply is empty
///
/// It proposes calls with no accompanying text. An action model is not a
/// conversationalist, and a sentence it wrote before anything ran would be a
/// claim about something that has not happened — the exact failure the
/// Universal Local Action Protocol was built to stop. `TurnSummarizer` writes
/// the user's confirmation afterwards, from the real `ToolResult`s.
///
/// `supportsToolResultContinuation` is false for the same reason: there is
/// nothing useful to ask an action model once the work is done.
public struct ActionTurnProvider: AIProvider {
    public static let providerID: AIProviderIdentifier = "metis.action-model"

    public let metadata: AIProviderMetadata
    private let backend: any ActionModelProvider
    private let resolver: any SemanticActionResolving
    private let dateProvider: any DateProvider
    private let category: LocalActionCategory
    private let diagnostics: any ActionSystemDiagnosticSink

    public init(
        backend: any ActionModelProvider,
        resolver: any SemanticActionResolving,
        dateProvider: any DateProvider,
        category: LocalActionCategory = .other,
        diagnostics: any ActionSystemDiagnosticSink = NullActionSystemDiagnosticSink()
    ) {
        self.backend = backend
        self.resolver = resolver
        self.dateProvider = dateProvider
        self.category = category
        self.diagnostics = diagnostics
        self.metadata = AIProviderMetadata(
            id: Self.providerID,
            displayName: "Metis Actions",
            kind: .actionModel,
            requiresNetwork: false,
            requiresCredentials: false,
            capabilityRank: 0,
            supportsToolResultContinuation: false
        )
    }

    public func availability() async -> AIProviderAvailability {
        switch await backend.availability() {
        case .available: return .available
        case .unavailable(let reason): return .unsupported(reason: reason)
        }
    }

    /// None. Which model interprets actions is not a thing the user picks from
    /// the assistant's model list (section 14).
    public func availableModels() async throws -> [AIModel] { [] }

    public func respond(to request: AIRequest) async throws -> AIResponse {
        guard
            let userRequest = request.messages.last(where: { $0.role == .user })?.content,
            !userRequest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw AIProviderError.invalidResponse("There was nothing to interpret.")
        }

        diagnostics.record(
            .semanticProcessingStarted(backendID: backend.id, category: category.rawValue)
        )

        // Section 8 and 21: the sentence, the clock, the protocol. Not the
        // system prompt, not the memories, not the conversation, and not one
        // tool schema.
        let actionRequest = ActionModelRequest(
            userRequest: userRequest,
            now: dateProvider.now,
            timeZoneIdentifier: dateProvider.calendar.timeZone.identifier,
            detectedCategory: category
        )

        // Section 1 and 2: the constraint travels with the request, and only on
        // this path. Nothing that answers a chat message is ever given one.
        //
        // The full protocol on the first attempt — the router's family is a
        // hint, not a verdict, and narrowing the *first* try to it would let a
        // misrouted message produce a confidently wrong action instead of a
        // rejected one. The backend narrows the single repair (section 15),
        // where the evidence has had a chance to be wrong once already.
        let constraints = ActionGenerationConstraints.universal
        diagnostics.record(
            .constrainedGeneration(
                backendID: backend.id,
                active: true,
                constraintType: Self.constraintKind,
                reason: nil
            )
        )

        let produced: LocalSemanticActionResult
        do {
            produced = try await backend.generateSemanticAction(
                request: actionRequest, constraints: constraints
            )
        } catch let error as ActionModelError {
            if case .constraintInitializationFailed = error {
                // Section 17 and 26. The constraint could not be built, so the
                // request is refused. There is deliberately no branch here that
                // retries without it.
                diagnostics.record(
                    .constrainedGeneration(
                        backendID: backend.id,
                        active: false,
                        constraintType: Self.constraintKind,
                        reason: error.symbol
                    )
                )
            }
            diagnostics.record(
                .actionBackendFailure(backendID: backend.id, reason: error.symbol)
            )
            diagnostics.record(
                .semanticParse(backendID: backend.id, success: false, generatedIntent: nil)
            )
            return failure()
        } catch {
            diagnostics.record(
                .actionBackendFailure(backendID: backend.id, reason: "generationFailed")
            )
            diagnostics.record(
                .semanticParse(backendID: backend.id, success: false, generatedIntent: nil)
            )
            return failure()
        }

        switch produced {
        case .noActionNeeded(let message):
            // The action model read the request and found nothing to do. That
            // is its answer, not a handoff: section 16 forbids passing an
            // ACTION request to the chat model to be answered as if it had
            // acted. A backend with nothing to say gets the concise sentence.
            diagnostics.record(
                .semanticParse(backendID: backend.id, success: false, generatedIntent: nil)
            )
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return AIResponse(
                text: trimmed.isEmpty ? Self.noActionMessage : trimmed,
                stopReason: .endTurn,
                providerID: metadata.id
            )

        case .action(let action):
            diagnostics.record(
                .semanticParse(
                    backendID: backend.id,
                    success: true,
                    generatedIntent: action.intent.rawValue
                )
            )
            switch await resolver.resolve(action) {
            case .resolved(let call):
                return AIResponse(
                    text: "",
                    toolCalls: [call],
                    stopReason: .toolCalls,
                    providerID: metadata.id
                )
            case .needsClarification(let question, _):
                return AIResponse(
                    text: question, stopReason: .endTurn, providerID: metadata.id
                )
            case .failed:
                diagnostics.record(
                    .actionBackendFailure(
                        backendID: backend.id, reason: "semanticValidationFailed"
                    )
                )
                return failure()
            }
        }
    }

    private func failure() -> AIResponse {
        AIResponse(text: Self.failureMessage, stopReason: .other, providerID: metadata.id)
    }

    /// What this layer requires of a backend, as a symbol for the log.
    ///
    /// Not `gbnf`: that is one backend's mechanism, and this layer does not
    /// know or care which. The backend logs its own concrete kind.
    static let constraintKind = "semanticActionSchema"

    /// Section 26: no router internals, no protocol JSON, no parser error.
    public static let failureMessage =
        "I couldn't turn that into an action. Could you say it another way?"

    static let noActionMessage = "I didn't find anything to do there."
}
