import AssistantAI
import AssistantDomain
import AssistantPersistence
import AssistantPlatform
import AssistantTools
import ExecutiveSupport
import MockPlatform
import XCTest
@testable import AssistantCore

/// What Siri, Shortcuts and the Action Button actually run.
///
/// An `AppIntent` cannot be instantiated in a unit test — it needs the App
/// Intents runtime — so the logic lives in `AssistantCommandService` and the
/// intent is a shell around it. These tests are therefore the real coverage of
/// the system-surface behaviour, and the intents add no behaviour of their own
/// to miss.
final class AssistantCommandServiceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    private struct Stack {
        let commands: AssistantCommandService
        let repositories: AssistantRepositories
        let services: PlatformServices
        let provider: StubAIProvider
    }

    private func makeStack(
        provider: (any AIProvider)? = nil,
        stub: StubAIProvider? = nil
    ) async throws -> Stack {
        let repositories = AssistantRepositories.ephemeral()
        let services = PlatformServices.mock()
        let stubProvider = stub ?? StubAIProvider(id: "test.commands", text: "All right.")
        let selected: any AIProvider = provider ?? stubProvider

        var settings = try await repositories.settings.settings()
        settings.preferredProviderID = selected.metadata.id
        settings.routingPolicy = .explicit
        try await repositories.settings.update(settings)

        let dateProvider = FixedDateProvider(now: now)
        let engine = AssistantEngine(
            providers: AIProviderRegistry(providers: [selected]),
            repositories: repositories,
            services: services,
            dateProvider: dateProvider
        )

        return Stack(
            commands: AssistantCommandService(
                engine: engine,
                repositories: repositories,
                memory: MemoryService(
                    repository: repositories.memories,
                    dateProvider: dateProvider
                ),
                dateProvider: dateProvider
            ),
            repositories: repositories,
            services: services,
            provider: stubProvider
        )
    }

    // MARK: Ask

    /// The architecture test: a Siri question goes through the engine, which
    /// means context assembly, memory retrieval and provider routing.
    func testAskingReachesTheAssistantEngineAndItsMemory() async throws {
        let stack = try await makeStack()
        try await stack.repositories.memories.store(
            MemoryItem(
                kind: .routine,
                content: "Needs 30 minutes to get ready",
                createdAt: now,
                source: .user
            )
        )

        let outcome = try await stack.commands.ask("How long do I need to get ready?")

        XCTAssertEqual(outcome.message, "All right.")
        XCTAssertEqual(stack.provider.receivedRequests.count, 1)

        let prompt = try XCTUnwrap(stack.provider.lastSystemPrompt)
        XCTAssertTrue(
            prompt.contains("Needs 30 minutes to get ready"),
            "ContextAssembler and MemoryRetrievalService must run for Siri too"
        )
    }

    /// A tool call from a Siri question runs the whole pipeline. The intent
    /// never interprets "tomorrow at 7" or touches AlarmKit.
    func testAskingRunsToolCallsThroughValidationAndExecution() async throws {
        let alarmCall = try ToolCallFactory.make(
            .createAlarm,
            CreateAlarmInput(label: "Wake up", fireDate: now.addingTimeInterval(TimeSpan.hours(12)))
        )
        let provider = StubAIProvider(
            id: "test.commands",
            responses: [
                AIResponse(
                    text: "Alarm set.",
                    toolCalls: [alarmCall],
                    stopReason: .toolCalls,
                    providerID: "test.commands"
                )
            ]
        )
        let stack = try await makeStack(provider: provider, stub: provider)

        _ = try await stack.commands.ask("Set an alarm for tomorrow at 7.")

        let alarms = try await stack.services.alarms.scheduledAlarms()
        XCTAssertEqual(alarms.count, 1)
        XCTAssertEqual(alarms.first?.label, "Wake up")
    }

    /// Siri questions are ordinary conversation, visible in the app afterwards.
    func testAskingIsRecordedInTheNormalConversation() async throws {
        let stack = try await makeStack()

        _ = try await stack.commands.ask("What's left today?")

        let conversations = try await stack.repositories.conversations.allConversations()
        XCTAssertEqual(conversations.count, 1, "No hidden Siri-only history")

        let messages = try XCTUnwrap(conversations.first?.messages)
        XCTAssertEqual(messages.first(where: { $0.role == .user })?.text, "What's left today?")
    }

    /// Repeated Siri questions continue one conversation rather than creating a
    /// new one each time.
    func testRepeatedQuestionsStayInOneConversation() async throws {
        let stack = try await makeStack()

        _ = try await stack.commands.ask("First question")
        _ = try await stack.commands.ask("Second question")

        let conversations = try await stack.repositories.conversations.allConversations()
        XCTAssertEqual(conversations.count, 1)
    }

    func testAnEmptyQuestionIsRefusedWithoutAskingAModel() async throws {
        let stack = try await makeStack()

        await assertThrows(.validationFailed(reason: "There was nothing to ask.")) {
            _ = try await stack.commands.ask("   ")
        }
        XCTAssertEqual(stack.provider.receivedRequests.count, 0)
    }

    /// An unavailable provider is reported, not worked around. Substituting a
    /// different model than the one the user chose is what `.explicit` routing
    /// exists to prevent.
    func testAnUnavailableProviderIsReportedRatherThanSubstituted() async throws {
        let unavailable = UnavailableProvider(id: "test.unavailable")
        let other = StubAIProvider(id: "test.other", text: "Should never run.")

        let repositories = AssistantRepositories.ephemeral()
        var settings = try await repositories.settings.settings()
        settings.preferredProviderID = unavailable.metadata.id
        settings.routingPolicy = .explicit
        try await repositories.settings.update(settings)

        let dateProvider = FixedDateProvider(now: now)
        let engine = AssistantEngine(
            providers: AIProviderRegistry(providers: [unavailable, other]),
            repositories: repositories,
            services: PlatformServices.mock(),
            dateProvider: dateProvider
        )
        let commands = AssistantCommandService(
            engine: engine,
            repositories: repositories,
            memory: MemoryService(repository: repositories.memories, dateProvider: dateProvider),
            dateProvider: dateProvider
        )

        do {
            _ = try await commands.ask("Anything")
            XCTFail("Expected the unavailable provider to be reported")
        } catch let error as AssistantCommandError {
            guard case .providerUnavailable(let reason) = error else {
                return XCTFail("Wrong error: \(error)")
            }
            XCTAssertFalse(reason.isEmpty)
            XCTAssertFalse(
                reason.contains("test.unavailable"),
                "A provider identifier means nothing to someone talking to Siri"
            )
        }

        XCTAssertEqual(other.receivedRequests.count, 0, "No silent substitution")
    }

    // MARK: Create a task

    /// The important one: a structured Shortcuts action still gets the full
    /// support treatment, and costs no model call.
    func testCreatingATaskUsesTheRealPipelineWithoutAnyModel() async throws {
        let stack = try await makeStack()

        let outcome = try await stack.commands.createTask(
            title: "Pay the electricity bill",
            dueDate: now.addingTimeInterval(TimeSpan.hours(6)),
            importance: .high
        )

        XCTAssertTrue(outcome.didSucceed)
        XCTAssertTrue(outcome.message.contains("Pay the electricity bill"))

        // No AI involved. Structured parameters have nothing to interpret.
        XCTAssertEqual(
            stack.provider.receivedRequests.count, 0,
            "A task with a title and a date needs no language model"
        )

        // Persisted through the ordinary repository.
        let tasks = try await stack.repositories.tasks.tasks(matching: .outstanding)
        XCTAssertEqual(tasks.map(\.title), ["Pay the electricity bill"])
    }

    /// §13: a Siri-created task is chased exactly as hard as a spoken one.
    func testATaskCreatedThroughAShortcutStillGetsAReminderPlan() async throws {
        let stack = try await makeStack()

        _ = try await stack.commands.createTask(
            title: "Renew the passport",
            dueDate: now.addingTimeInterval(TimeSpan.days(3)),
            importance: .high
        )

        let outstanding = try await stack.repositories.tasks.tasks(matching: .outstanding)
        let task = try XCTUnwrap(outstanding.first)
        XCTAssertNotNil(
            task.reminderPlanID,
            "SupportPlanner must run for structured intents, or Siri tasks are never followed up"
        )

        let plans = try await stack.repositories.reminderPlans.plans(for: .task(task.id))
        XCTAssertFalse(plans.isEmpty, "The plan itself must be persisted, not just referenced")
    }

    func testATaskWithNoTitleIsRefused() async throws {
        let stack = try await makeStack()

        await assertThrows(.validationFailed(reason: "A task needs a title.")) {
            _ = try await stack.commands.createTask(title: "  ")
        }

        let tasks = try await stack.repositories.tasks.tasks(matching: TaskFilter())
        XCTAssertTrue(tasks.isEmpty)
    }

    // MARK: Remember something

    func testRememberingUsesTheMemoryServiceAndItsMetadata() async throws {
        let stack = try await makeStack()

        let outcome = try await stack.commands.storeMemory("My commute takes 30 minutes")

        XCTAssertTrue(outcome.didSucceed)
        let stored = try await stack.repositories.memories.all()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(
            stored.first?.source, .user,
            "A Shortcut called Remember Something is the user saying it explicitly"
        )
        XCTAssertEqual(stack.provider.receivedRequests.count, 0, "No model needed")
    }

    /// §16: the duplicate protections apply to Siri exactly as they do in the
    /// app. Saying the same thing twice must not produce two memories.
    func testRememberingTheSameThingTwiceDoesNotStoreItTwice() async throws {
        let stack = try await makeStack()

        _ = try await stack.commands.storeMemory("My commute takes 30 minutes")
        _ = try await stack.commands.storeMemory("My commute takes 30 minutes")

        let stored = try await stack.repositories.memories.all()
        XCTAssertEqual(stored.count, 1, "Duplicate detection must run for system surfaces too")
    }

    func testRememberingNothingIsRefused() async throws {
        let stack = try await makeStack()

        await assertThrows(.validationFailed(reason: "There was nothing to remember.")) {
            _ = try await stack.commands.storeMemory("\n  ")
        }
        let stored = try await stack.repositories.memories.all()
        XCTAssertTrue(stored.isEmpty)
    }

    // MARK: Today

    func testTodayReportsStoredWorkWithoutAskingAModel() async throws {
        let stack = try await makeStack()

        try await stack.repositories.tasks.save(
            TaskItem(
                title: "Pay the electricity bill",
                timing: .fixed(now.addingTimeInterval(TimeSpan.hours(2))),
                createdAt: now
            )
        )
        try await stack.repositories.tasks.save(
            TaskItem(
                title: "Something next week",
                timing: .fixed(now.addingTimeInterval(TimeSpan.days(7))),
                createdAt: now
            )
        )

        let briefing = try await stack.commands.today()

        XCTAssertEqual(briefing.items.map(\.title), ["Pay the electricity bill"])
        XCTAssertTrue(briefing.spokenSummary().contains("Pay the electricity bill"))
        XCTAssertEqual(
            stack.provider.receivedRequests.count, 0,
            "Reciting stored data must not depend on a model being reachable"
        )
    }

    func testAnEmptyDaySaysSoRatherThanReturningNothing() async throws {
        let stack = try await makeStack()

        let briefing = try await stack.commands.today()

        XCTAssertTrue(briefing.items.isEmpty)
        XCTAssertFalse(briefing.spokenSummary().isEmpty)
    }

    // MARK: Complete a task

    /// §24: completion goes through the lifecycle, which is what withdraws the
    /// reminders still waiting.
    func testCompletingATaskRunsTheLifecycleAndCancelsFollowUps() async throws {
        let stack = try await makeStack()
        let (task, _) = try await seedTaskWithPendingReminder(into: stack)

        let before = try await stack.services.notifications.pendingNotifications()
        XCTAssertEqual(before.count, 1, "Precondition: a reminder is waiting")

        let outcome = try await stack.commands.completeTask(id: task.id)

        XCTAssertTrue(outcome.didSucceed)
        let stored = try await stack.repositories.tasks.task(id: task.id)
        XCTAssertEqual(stored?.status, .completed)

        let after = try await stack.services.notifications.pendingNotifications()
        XCTAssertTrue(
            after.isEmpty,
            "Finishing a task must withdraw the reminders that were still waiting"
        )
    }

    func testCompletingAMissingTaskSaysSoAndCreatesNothing() async throws {
        let stack = try await makeStack()

        await assertThrows(.itemNotFound) {
            _ = try await stack.commands.completeTask(id: TaskItem.ID())
        }

        let tasks = try await stack.repositories.tasks.tasks(matching: TaskFilter())
        XCTAssertTrue(tasks.isEmpty, "A missing task must not be invented")
    }

    /// §25 and §48: a retried Shortcut must not look like it did the work
    /// twice.
    func testCompletingAnAlreadyCompletedTaskIsTruthful() async throws {
        let stack = try await makeStack()
        var task = TaskItem(title: "Already done", createdAt: now)
        task.status = .completed
        try await stack.repositories.tasks.save(task)

        let outcome = try await stack.commands.completeTask(id: task.id)

        XCTAssertFalse(outcome.didSucceed)
        XCTAssertTrue(outcome.message.contains("already"))
    }

    func testCompletingACancelledTaskDoesNotReopenIt() async throws {
        let stack = try await makeStack()
        var task = TaskItem(title: "Called off", createdAt: now)
        task.status = .cancelled
        try await stack.repositories.tasks.save(task)

        let outcome = try await stack.commands.completeTask(id: task.id)

        XCTAssertFalse(outcome.didSucceed)
        let stored = try await stack.repositories.tasks.task(id: task.id)
        XCTAssertEqual(stored?.status, .cancelled, "Cancelled must stay cancelled")
    }

    // MARK: Task selection

    func testOnlyOutstandingTasksAreOfferedForCompletion() async throws {
        let stack = try await makeStack()

        try await stack.repositories.tasks.save(TaskItem(title: "Still open", createdAt: now))
        var done = TaskItem(title: "Finished already", createdAt: now)
        done.status = .completed
        try await stack.repositories.tasks.save(done)

        let offered = try await stack.commands.selectableTasks()

        XCTAssertEqual(offered.map(\.title), ["Still open"])
    }

    func testTaskSearchMatchesOnTitle() async throws {
        let stack = try await makeStack()
        try await stack.repositories.tasks.save(TaskItem(title: "Call the dentist", createdAt: now))
        try await stack.repositories.tasks.save(TaskItem(title: "Buy milk", createdAt: now))

        let matched = try await stack.commands.selectableTasks(matching: "dent")

        XCTAssertEqual(matched.map(\.title), ["Call the dentist"])
    }

    // MARK: Provider independence

    /// §68: switching model changes who answers and nothing else.
    func testSwitchingProviderPreservesEverythingCreatedThroughCommands() async throws {
        let stack = try await makeStack()

        _ = try await stack.commands.createTask(title: "Survives the swap")
        _ = try await stack.commands.storeMemory("Also survives the swap")

        var settings = try await stack.repositories.settings.settings()
        settings.preferredProviderID = "some.other.provider"
        try await stack.repositories.settings.update(settings)

        let tasks = try await stack.repositories.tasks.tasks(matching: .outstanding)
        let memories = try await stack.repositories.memories.all()
        XCTAssertEqual(tasks.map(\.title), ["Survives the swap"])
        XCTAssertEqual(memories.map(\.content), ["Also survives the swap"])
    }

    // MARK: Wording

    func testALongAnswerIsShortenedForSiriButCutAtASentence() {
        let long = String(repeating: "This is a sentence about the day. ", count: 30)
        let short = AssistantCommandService.concise(long, results: [])

        XCTAssertLessThanOrEqual(short.count, 321)
        XCTAssertTrue(short.hasSuffix("."), "Siri should not be handed half a word")
    }

    func testAnActionOnlyTurnStillProducesASentence() {
        let result = ToolResult(
            actionID: AssistantAction.ID(),
            kind: .createTask,
            outcome: .executed,
            message: "Task tracked: Buy milk",
            producedAt: Date()
        )

        XCTAssertEqual(
            AssistantCommandService.concise("", results: [result]),
            "Task tracked: Buy milk"
        )
    }

    // MARK: Helpers

    private func assertThrows(
        _ expected: AssistantCommandError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ work: () async throws -> Void
    ) async {
        do {
            try await work()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch let error as AssistantCommandError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    /// A task with a reminder already scheduled at the platform layer, so
    /// completion has something real to withdraw.
    private func seedTaskWithPendingReminder(
        into stack: Stack
    ) async throws -> (TaskItem, ReminderPlan) {
        var task = TaskItem(
            title: "Pay the electricity bill",
            status: .reminded,
            importance: .normal,
            deadline: now.addingTimeInterval(TimeSpan.hours(2)),
            createdAt: now
        )

        let stage = ReminderStage(
            kind: .finalCall,
            offset: .absolute(now),
            message: "Pay the electricity bill",
            requiresConfirmation: true,
            state: .delivered,
            stateChangedAt: now,
            scheduledFor: now
        )
        let plan = ReminderPlan(
            subject: ReminderSubject(
                reference: .task(task.id),
                title: task.title,
                anchor: .deadline(now.addingTimeInterval(TimeSpan.hours(2))),
                importance: .normal
            ),
            stages: [stage],
            createdAt: now,
            generatedBy: "test"
        )

        task.reminderPlanID = plan.id
        try await stack.repositories.reminderPlans.save(plan)
        try await stack.repositories.tasks.save(task)

        // A real pending notification for that stage, as the follow-up service
        // would have scheduled.
        _ = try await stack.services.notifications.schedule(
            NotificationRequest(
                id: NotificationRequest.ID(stage.id.rawValue),
                title: task.title,
                body: "Still open?",
                fireDate: now,
                relatedTaskID: task.id,
                stageID: stage.id
            )
        )

        return (task, plan)
    }
}
