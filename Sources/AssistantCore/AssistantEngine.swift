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
        let request = AIRequest(
            model: context.settings.preferredModelID,
            systemPrompt: promptBuilder.systemPrompt(for: context),
            messages: promptBuilder.messages(for: context),
            tools: promptBuilder.toolSchemas()
        )
        let response = try await provider.respond(to: request)

        // 3. Type and validate everything it asked for, discarding the rest.
        let limitedCalls = Array(response.toolCalls.prefix(request.options.maximumToolCalls))
        let decoded = decoder.decode(
            limitedCalls.map { AIToolCallEnvelope(id: $0.id, name: $0.name, arguments: $0.arguments) }
        )

        // 4. Plan, including the reminder support the app adds itself.
        let planning = planner.makePlan(from: decoded, context: context)
        for reminderPlan in planning.reminderPlans {
            try await repositories.reminderPlans.save(reminderPlan)
        }

        // 5. Execute what is authorized.
        let results = await executor.execute(planning.plan, context: context)

        // 6. Record the turn.
        let assistantMessage = Message(
            role: .assistant,
            text: response.text,
            createdAt: dateProvider.now,
            actionPlanID: planning.plan.id
        )
        conversation.append(assistantMessage)
        try await repositories.conversations.save(conversation)

        try await linkReminderPlans(planning)

        return AssistantTurnResult(
            conversation: conversation,
            assistantMessage: assistantMessage,
            plan: planning.plan,
            results: results,
            providerID: response.providerID
        )
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
    private func linkReminderPlans(_ planning: PlanningOutput) async throws {
        for reminderPlan in planning.reminderPlans {
            guard case .task(let taskID) = reminderPlan.subject.reference else { continue }
            guard var task = try await repositories.tasks.task(id: taskID) else { continue }
            guard task.reminderPlanID == nil else { continue }
            task.reminderPlanID = reminderPlan.id
            try await repositories.tasks.save(task)
        }
    }
}
