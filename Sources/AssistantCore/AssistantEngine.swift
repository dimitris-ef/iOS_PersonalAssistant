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
    /// What the turn amounted to, read off the results rather than off intent.
    ///
    /// `partialSuccess` is the one that earns its keep: a compound request where
    /// the calendar was refused and the task was created is neither a success
    /// nor a failure, and the UI needs to be able to say so.
    public let status: AgentTurnStatus
    /// Set when the assistant asked something instead of acting. The question is
    /// also the assistant message, so a UI that ignores this still shows it.
    public let clarification: ClarificationRequest?
    /// Rounds, tool names, statuses, retries. No arguments and no prose — see
    /// ``AgentDiagnostics``.
    public let diagnostics: AgentDiagnostics

    public init(
        conversation: Conversation,
        assistantMessage: Message,
        plan: AssistantActionPlan,
        results: [ToolResult],
        providerID: AIProviderIdentifier,
        status: AgentTurnStatus = .success,
        clarification: ClarificationRequest? = nil,
        diagnostics: AgentDiagnostics = AgentDiagnostics()
    ) {
        self.conversation = conversation
        self.assistantMessage = assistantMessage
        self.plan = plan
        self.results = results
        self.providerID = providerID
        self.status = status
        self.clarification = clarification
        self.diagnostics = diagnostics
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
    /// The bounds on one turn: rounds, tool calls, retries, repetition.
    private let limits: AgentLimits
    /// What has already been executed, and the reason it cannot happen twice.
    /// Owned by the engine rather than made per turn, so a confirmation
    /// answered just after the turn that proposed it still finds its entry.
    private let ledger: ToolExecutionLedger
    private let summarizer = TurnSummarizer()
    private let logger: any AgentLogger

    /// The support lifecycle: what happens after a reminder is shown.
    ///
    /// Exposed so the UI and the tool layer share one route into it. Nothing
    /// else in the app is allowed to change a task's status directly.
    public let followUp: FollowUpService

    /// Recurring responsibilities: generating occurrences, recovering the late
    /// ones, expiring the ones whose window closed.
    ///
    /// Exposed for the same reason `followUp` is. The app calls `reconcileAll()`
    /// on foreground beside `followUp.reconcile()`, and both are deterministic
    /// and offline — a cold launch in a tunnel still knows what today owes.
    public let routines: RoutineService

    /// "Help me start", shared by the Today screen, Siri and the tool layer.
    public let startSupport: StartSupportService

    public init(
        providers: AIProviderRegistry,
        repositories: AssistantRepositories,
        services: PlatformServices,
        dateProvider: any DateProvider = SystemDateProvider(),
        router: ModelRouter = ModelRouter(),
        planner: (any ActionPlanner)? = nil,
        executor: (any ToolExecutor)? = nil,
        promptBuilder: SystemPromptBuilder = SystemPromptBuilder(),
        timing: FollowUpTiming = .default,
        limits: AgentLimits = .default,
        logger: any AgentLogger = SilentAgentLogger()
    ) {
        self.providers = providers
        self.repositories = repositories
        self.services = services
        self.dateProvider = dateProvider
        self.router = router
        self.limits = limits
        self.logger = logger
        self.ledger = ToolExecutionLedger()
        self.planner = planner ?? DefaultActionPlanner()
        let followUp = FollowUpService(
            repositories: repositories,
            services: services,
            dateProvider: dateProvider,
            timing: timing
        )
        self.followUp = followUp
        self.routines = RoutineService(
            repositories: repositories,
            services: services,
            dateProvider: dateProvider
        )
        self.startSupport = StartSupportService(
            repositories: repositories,
            followUp: followUp,
            dateProvider: dateProvider
        )
        self.executor = executor
            ?? DefaultToolExecutor(
                services: services,
                repositories: repositories,
                followUp: followUp,
                dateProvider: dateProvider
            )
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
        //
        // The calendar read is deliberately not `try`. Once these services
        // became real Apple ones this line acquired a failure mode it never had
        // against mocks: a user who has not granted calendar access, or granted
        // add-only access, makes `events(in:)` throw — and propagating that
        // would mean the assistant refused to answer *anything*, including the
        // many questions that have nothing to do with a calendar. Losing the
        // schedule degrades an answer; losing the turn ends the conversation.
        //
        // What is not done here is pretending the calendar was empty. The
        // context records that it could not be read, and the prompt says so.
        let schedule = await upcomingEvents()
        let context = try await contextAssembler.assemble(
            conversation: conversation,
            query: text,
            calendarEvents: schedule.events,
            calendarIsReadable: schedule.isReadable
        )

        // 2. Ask whichever provider settings point at, and let the agent loop
        //    run for as many rounds as the request needs — bounded, and with
        //    every round's proposals validated and authorized from scratch.
        let provider = try await router.selectProvider(from: providers, settings: context.settings)
        let turn = try await agentRunner().run(
            provider: provider,
            context: context,
            conversationID: conversation.id
        )

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
            providerID: turn.providerID,
            status: turn.status,
            clarification: turn.clarification,
            diagnostics: turn.diagnostics
        )
    }

    /// The loop, built from the pieces the engine already owns.
    ///
    /// Made per turn and thrown away; the one thing it does not own is the
    /// ledger, which outlives the turn so that a repeated call cannot be a
    /// duplicate to one runner and a novelty to the next.
    private func agentRunner() -> AgentRunner {
        AgentRunner(
            repositories: repositories,
            planner: planner,
            executor: executor,
            promptBuilder: promptBuilder,
            decoder: decoder,
            dateProvider: dateProvider,
            ledger: ledger,
            limits: limits,
            summarizer: summarizer,
            logger: logger
        )
    }

    /// Runs one tool request the app already decided on, with no model involved.
    ///
    /// ## Why this exists
    ///
    /// Some requests arrive already structured. A Shortcuts action called
    /// "Add a Task" with a title and a due date has nothing left to interpret,
    /// and sending it to a language model to be turned back into the
    /// `createTask` call it already is would cost latency, money and accuracy
    /// for no gain.
    ///
    /// What it must **not** skip is everything after interpretation. This runs
    /// the engine's own planner and executor — the same instances `send`
    /// uses — so authorization, support expansion, reminder-plan generation,
    /// persistence and platform routing all happen exactly as they would for a
    /// call the model made. The only thing missing is the model.
    ///
    /// `origin` records who asked. A structured request from a person is
    /// `.user`, which is what distinguishes it in the action history from
    /// something a model proposed.
    ///
    /// `idempotencyKey` makes the call safe to deliver twice. A confirmation tap
    /// that reaches the app twice, a Shortcut that fires on a double press, an
    /// intent the system replays — all of them arrive as a second call with the
    /// same key, and all of them should produce one calendar event. Given a key,
    /// the request goes through the same execution ledger the agent loop uses:
    /// the first call runs, and a repeat returns a `.duplicate` result without
    /// executing anything. Callers that genuinely want a second copy simply pass
    /// no key, which is the default.
    @discardableResult
    public func perform(
        _ request: ToolRequest,
        origin: ActionOrigin = .user,
        idempotencyKey: String? = nil
    ) async throws -> (plan: AssistantActionPlan, results: [ToolResult]) {
        let callID = ToolCallID()

        if let idempotencyKey {
            let claim = await ledger.claim(
                callID: callID,
                toolName: request.kind.rawValue,
                fingerprint: ToolFingerprint(scope: idempotencyKey, request: request),
                scope: idempotencyKey,
                now: dateProvider.now
            )
            if case .granted = claim {
                // Ours to run.
            } else {
                // Somebody already has it. Report that truthfully rather than
                // doing it a second time — the plan says what was asked for and
                // the result says it had already happened.
                let action = AssistantAction(
                    request: request,
                    origin: origin,
                    authorization: .allowed,
                    sourceCallID: callID
                )
                return (
                    AssistantActionPlan(actions: [action], createdAt: dateProvider.now),
                    [
                        ToolResult(
                            actionID: action.id,
                            kind: request.kind,
                            outcome: .failed(reason: "already performed"),
                            message: "Already done — this request had been carried out already.",
                            producedAt: dateProvider.now,
                            failure: .duplicate
                        ),
                    ]
                )
            }
        }

        let calendar = await upcomingEvents()
        let context = try await contextAssembler.assemble(
            conversation: Conversation(createdAt: dateProvider.now),
            // No query text: nothing here is being interpreted, so there is
            // nothing for memory retrieval to be relevant *to*. Structured
            // actions do not need remembered context to be carried out.
            query: "",
            calendarEvents: calendar.events,
            calendarIsReadable: calendar.isReadable
        )

        let decoded = ToolDecodingOutcome(
            accepted: [DecodedToolCall(callID: callID, request: request)]
        )
        let planning = planner.makePlan(from: decoded, context: context)

        // Reminder plans are persisted before execution, exactly as in `send`:
        // the plan is what the follow-up ladder reads, and a crash between the
        // two should leave support in place rather than an action with no
        // support behind it.
        for reminderPlan in planning.reminderPlans {
            try await repositories.reminderPlans.save(reminderPlan)
        }

        var plan = planning.plan
        plan.actions = plan.actions.map { action in
            var action = action
            action.origin = origin
            return action
        }

        let results = await executor.execute(plan, context: context)

        // Linked **after** execution, and the order is not cosmetic.
        // `linkReminderPlans` writes the plan's id onto the task, so the task
        // has to exist first — and the task is created by the executor. Doing
        // this before, as an earlier version did, silently left
        // `reminderPlanID` nil: the plan was saved, the task was saved, and
        // nothing joined them, so the follow-up ladder had no plan to read and
        // a task created from Shortcuts was never chased. `send` has always
        // linked after its turn for the same reason.
        try await linkReminderPlans(planning.reminderPlans)

        if idempotencyKey != nil,
           let action = plan.actions.first(where: { $0.sourceCallID == callID }),
           let result = results.first(where: { $0.actionID == action.id }) {
            await ledger.finish(
                callID: callID,
                status: result.outcome.didChangeAnything ? .succeeded : .failed,
                result: AgentRunner.toolResult(
                    for: action,
                    result: result,
                    callID: callID,
                    supportActions: 0
                ),
                now: dateProvider.now
            )
        }

        return (plan, results)
    }

    /// The user's calendar, through the platform layer the engine already
    /// holds.
    ///
    /// Exposed so `AssistantCommandService` can build a Today briefing without
    /// being handed a second reference to `PlatformServices` — one composition
    /// owns the platform layer, and everything else asks it.
    public func calendarEvents(in window: TimeWindow) async throws -> [CalendarItem] {
        try await services.calendar.events(in: window)
    }

    /// The next fortnight, and whether it could be read at all.
    ///
    /// The distinction is the whole reason this returns a pair rather than an
    /// array. "No events" and "no access" both produce an empty list, and only
    /// one of them means the user is free.
    private func upcomingEvents() async -> (events: [CalendarItem], isReadable: Bool) {
        do {
            return (try await services.calendar.events(in: contextAssembler.window), true)
        } catch {
            // Not logged with the error's description: a platform error can
            // quote calendar or account state.
            return ([], false)
        }
    }

    /// Applies an engagement event (notification dismissed, snoozed, confirmed)
    /// to a task.
    ///
    /// This is the entry point the notification handlers on iOS will call, and
    /// it is where "dismissed is not done" is enforced for real.
    ///
    /// It now runs the full support lifecycle rather than only the status
    /// change: the reminder's own outcome is recorded, and — unless the task
    /// has been resolved — the planner schedules the next intervention. Before,
    /// this method updated a status and stopped, which is precisely how support
    /// ended at the first dismissal.
    ///
    /// `stageID` names the reminder the event came from, when there is one.
    @discardableResult
    public func record(
        _ event: EngagementEvent,
        for taskID: TaskItem.ID,
        stageID: ReminderStage.ID? = nil
    ) async throws -> TaskItem {
        guard let outcome = ReminderOutcome(event) else {
            // An event with no reminder-lifecycle meaning — `deferred`,
            // `anchorPassed`. Handled by the status machine alone, as before.
            return try await applyStatusOnly(event, for: taskID)
        }
        return try await followUp.handle(
            outcome: outcome,
            forTask: taskID,
            stageID: stageID
        ).task
    }

    private func applyStatusOnly(
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
