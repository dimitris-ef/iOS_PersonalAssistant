import AssistantAI
import AssistantDomain
import AssistantPersistence
import AssistantPlatform
import AssistantTools
import ExecutiveSupport
import Foundation

/// Everything one turn produced.
public struct AssistantTurnResult: Sendable {
    public let conversation: Conversation
    public let assistantMessage: Message
    public let plan: AssistantActionPlan
    public let results: [ToolResult]
    public let providerID: AIProviderIdentifier

    public init(
        conversation: Conversation,
        assistantMessage: Message,
        plan: AssistantActionPlan,
        results: [ToolResult],
        providerID: AIProviderIdentifier
    ) {
        self.conversation = conversation
        self.assistantMessage = assistantMessage
        self.plan = plan
        self.results = results
        self.providerID = providerID
    }
}

public enum AssistantEngineError: Error, Sendable {
    case conversationNotFound(Conversation.ID)
}

/// Orchestrates a turn: assemble context, ask a provider, decode what it asked
/// for, plan, execute, record.
///
/// The engine owns no state of its own — everything lives in the repositories —
/// which is what makes provider swapping safe and the whole pipeline testable
/// with a scripted provider and mock platform services.
public final class AssistantEngine: Sendable {
    private let providers: AIProviderRegistry
    private let router: ModelRouter
    private let repositories: AssistantRepositories
    private let services: PlatformServices
    private let planner: any ActionPlanner
    private let executor: any ToolExecutor
    private let contextAssembler: ContextAssembler
    private let promptBuilder: SystemPromptBuilder
    private let decoder: ToolRequestDecoder
    private let dateProvider: any DateProvider

    public init(
        providers: AIProviderRegistry,
        repositories: AssistantRepositories,
        services: PlatformServices,
        dateProvider: any DateProvider = SystemDateProvider(),
        router: ModelRouter = ModelRouter(),
        planner: (any ActionPlanner)? = nil,
        executor: (any ToolExecutor)? = nil,
        promptBuilder: SystemPromptBuilder = SystemPromptBuilder()
    ) {
        self.providers = providers
        self.repositories = repositories
        self.services = services
        self.dateProvider = dateProvider
        self.router = router
        self.planner = planner ?? DefaultActionPlanner()
        self.executor = executor ?? DefaultToolExecutor(services: services, repositories: repositories)
        self.promptBuilder = promptBuilder
        self.decoder = ToolRequestDecoder(dateProvider: dateProvider)
        self.contextAssembler = ContextAssembler(
            repositories: repositories,
            dateProvider: dateProvider
        )
    }

    /// Starts a new conversation and persists it.
    public func startConversation(title: String? = nil) async throws -> Conversation {
        let conversation = Conversation(title: title, createdAt: dateProvider.now)
        try await repositories.conversations.save(conversation)
        return conversation
    }

    public func send(_ text: String, in conversationID: Conversation.ID) async throws -> AssistantTurnResult {
        guard var conversation = try await repositories.conversations.conversation(id: conversationID) else {
            throw AssistantEngineError.conversationNotFound(conversationID)
        }

        let now = dateProvider.now
        conversation.append(Message(role: .user, text: text, createdAt: now))
        try await repositories.conversations.save(conversation)

        // 1. What is relevant right now.
        let upcoming = try await services.calendar.events(in: contextAssembler.window)
        let context = try await contextAssembler.assemble(
            conversation: conversation,
            query: text,
            calendarEvents: upcoming
        )

        // 2. Ask whichever provider settings point at.
        let provider = try await router.selectProvider(from: providers, settings: context.settings)
        let turn = try await runTurn(with: provider, context: context)

        // 3. Record the turn.
        let assistantMessage = Message(
            role: .assistant,
            text: turn.text,
            createdAt: dateProvider.now,
            actionPlanID: turn.plan.id
        )
        conversation.append(assistantMessage)
        try await repositories.conversations.save(conversation)

        // The message carries the plan's id; store the plan itself so that
        // pointer still resolves after a relaunch and the reply keeps the cards
        // beneath it. Saved after the conversation because the plan is attached
        // to it.
        try await repositories.actionPlans.save(
            ActionPlanRecord(
                plan: turn.plan,
                results: turn.results,
                conversationID: conversation.id
            )
        )

        try await linkReminderPlans(turn.reminderPlans)

        return AssistantTurnResult(
            conversation: conversation,
            assistantMessage: assistantMessage,
            plan: turn.plan,
            results: turn.results,
            providerID: turn.providerID
        )
    }

    /// What one turn produced, possibly across more than one provider round.
    private struct TurnOutcome {
        var text: String
        var plan: AssistantActionPlan
        var results: [ToolResult]
        var reminderPlans: [ReminderPlan]
        var providerID: AIProviderIdentifier
    }

    /// Asks the provider, executes what it proposed, and — for providers that
    /// support it — shows it the results and asks for a closing reply.
    ///
    /// The loop is bounded by `maximumToolRounds` and by the provider's own
    /// `supportsToolResultContinuation` flag. A provider that cannot read tool
    /// results gets exactly one round, so it can never be re-asked the same
    /// question and duplicate the actions it already proposed.
    private func runTurn(
        with provider: any AIProvider,
        context: AssistantContext
    ) async throws -> TurnOutcome {
        let options = AIGenerationOptions()
        var messages = promptBuilder.messages(for: context)

        var text = ""
        var actions: [AssistantAction] = []
        var rejected: [RejectedToolCall] = []
        var results: [ToolResult] = []
        var reminderPlans: [ReminderPlan] = []
        var providerID = provider.metadata.id
        var round = 0

        while true {
            round += 1

            let request = AIRequest(
                model: context.settings.preferredModelID,
                systemPrompt: promptBuilder.systemPrompt(for: context),
                messages: messages,
                tools: promptBuilder.toolSchemas(),
                options: options
            )

            let response: AIResponse
            if round == 1 {
                response = try await provider.respond(to: request)
            } else {
                // A failure while asking for the closing remark must not lose
                // the actions already taken — keep what we have and stop.
                do {
                    response = try await provider.respond(to: request)
                } catch {
                    break
                }
            }

            providerID = response.providerID
            if !response.text.isEmpty { text = response.text }

            // Type and validate everything it asked for, discarding the rest.
            let calls = Array(response.toolCalls.prefix(options.maximumToolCalls))
            let decoded = decoder.decode(
                calls.map { AIToolCallEnvelope(id: $0.id, name: $0.name, arguments: $0.arguments) }
            )
            rejected.append(contentsOf: decoded.rejected)

            guard !decoded.accepted.isEmpty else { break }

            // Plan, including the reminder support the app adds itself.
            let planning = planner.makePlan(from: decoded, context: context)
            for reminderPlan in planning.reminderPlans {
                try await repositories.reminderPlans.save(reminderPlan)
            }
            reminderPlans.append(contentsOf: planning.reminderPlans)

            // Execute what is authorized.
            let roundResults = await executor.execute(planning.plan, context: context)
            actions.append(contentsOf: planning.plan.actions)
            results.append(contentsOf: roundResults)

            guard
                provider.metadata.supportsToolResultContinuation,
                round < options.maximumToolRounds
            else { break }

            // Show the model what it asked for, then what happened.
            messages.append(
                AIMessage(role: .assistant, content: response.text, toolCalls: calls)
            )
            messages.append(
                contentsOf: toolResultMessages(
                    for: calls,
                    plan: planning.plan,
                    results: roundResults
                )
            )
        }

        return TurnOutcome(
            text: text,
            plan: AssistantActionPlan(
                actions: actions,
                rejected: rejected,
                createdAt: dateProvider.now
            ),
            results: results,
            reminderPlans: reminderPlans,
            providerID: providerID
        )
    }

    /// One `.tool` message per call, so the model sees the outcome of each.
    private func toolResultMessages(
        for calls: [AIToolCall],
        plan: AssistantActionPlan,
        results: [ToolResult]
    ) -> [AIMessage] {
        calls.map { call in
            let content: String
            if let action = plan.actions.first(where: { $0.sourceCallID == call.id }),
               let result = results.first(where: { $0.actionID == action.id }) {
                content = Self.describe(result)
            } else if let rejection = plan.rejected.first(where: { $0.callID == call.id }) {
                // Telling the model why it was rejected is how it corrects
                // itself; it still cannot bypass the rejection.
                content = "Rejected. \(rejection.error)"
            } else {
                content = "No result was produced."
            }
            return AIMessage(role: .tool, content: content, toolCallID: call.id)
        }
    }

    /// Describes an outcome for the model — including, plainly, when the work
    /// was only simulated, so it cannot tell the user their phone did something.
    private static func describe(_ result: ToolResult) -> String {
        switch result.outcome {
        case .executed:
            return "Done. \(result.message)"
        case .simulated(let platform):
            return "Recorded by the app's \(platform). This is simulated — nothing was scheduled on the device. \(result.message)"
        case .awaitingConfirmation:
            return "Prepared, but waiting for the user to approve it. \(result.message)"
        case .denied(let reason):
            return "Not permitted: \(reason)"
        case .failed(let reason):
            return "Failed: \(reason)"
        case .unsupported(let reason):
            return "Not supported: \(reason)"
        }
    }

    /// Applies an engagement event (notification dismissed, snoozed, confirmed)
    /// to a task.
    ///
    /// This is the entry point the notification handlers on iOS will call, and
    /// it is where "dismissed is not done" is enforced for real.
    @discardableResult
    public func record(
        _ event: EngagementEvent,
        for taskID: TaskItem.ID,
        statusMachine: TaskStatusMachine = TaskStatusMachine()
    ) async throws -> TaskItem {
        guard let task = try await repositories.tasks.task(id: taskID) else {
            throw RepositoryError.notFound(taskID.description)
        }
        var plan: ReminderPlan?
        if let planID = task.reminderPlanID {
            plan = try await repositories.reminderPlans.plan(id: planID)
        }
        let transition = statusMachine.apply(event, to: task, plan: plan)
        let updated = statusMachine.updated(task, with: transition, at: dateProvider.now)
        try await repositories.tasks.save(updated)
        return updated
    }

    /// Points newly created tasks at the reminder plan generated for them, so
    /// follow-up logic can later consult the policies that were in force.
    private func linkReminderPlans(_ reminderPlans: [ReminderPlan]) async throws {
        for reminderPlan in reminderPlans {
            guard case .task(let taskID) = reminderPlan.subject.reference else { continue }
            guard var task = try await repositories.tasks.task(id: taskID) else { continue }
            guard task.reminderPlanID == nil else { continue }
            task.reminderPlanID = reminderPlan.id
            try await repositories.tasks.save(task)
        }
    }
}
