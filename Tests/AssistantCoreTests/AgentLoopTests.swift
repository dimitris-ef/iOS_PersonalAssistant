import AssistantAI
import AssistantDomain
import AssistantPersistence
import AssistantPlatform
import AssistantTools
import MockPlatform
import XCTest
@testable import AssistantCore

/// The multi-round agent loop.
///
/// Every test here builds the real stack — real decoder, real planner, real
/// authorizer, real executor, real repositories — and replaces exactly two
/// things: the model, which is scripted, and the platform, which is mocked. So
/// what these assert about is the application's own behaviour, not a mock's.
final class AgentLoopTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private struct Harness {
        let engine: AssistantEngine
        let repositories: AssistantRepositories
        let services: PlatformServices
        let conversationID: Conversation.ID
    }

    private func makeHarness(
        provider: any AIProvider,
        services: PlatformServices = PlatformServices.mock(),
        executor: (any ToolExecutor)? = nil,
        limits: AgentLimits = .default,
        settingsMutation: ((inout AssistantSettings) -> Void)? = nil
    ) async throws -> Harness {
        let repositories = AssistantRepositories.ephemeral()
        var settings = try await repositories.settings.settings()
        settings.preferredProviderID = provider.metadata.id
        settingsMutation?(&settings)
        try await repositories.settings.update(settings)

        let engine = AssistantEngine(
            providers: AIProviderRegistry(providers: [provider]),
            repositories: repositories,
            services: services,
            dateProvider: FixedDateProvider(now: now),
            executor: executor,
            limits: limits
        )
        let conversation = try await engine.startConversation()
        return Harness(
            engine: engine,
            repositories: repositories,
            services: services,
            conversationID: conversation.id
        )
    }

    // MARK: Calls

    private func eventCall(
        title: String = "Dentist",
        inDays: Double = 3,
        id: CalendarItem.ID? = nil,
        support: Bool? = nil
    ) throws -> AIToolCall {
        try ToolCallFactory.make(
            .createCalendarEvent,
            CreateCalendarEventInput(
                eventID: id,
                title: title,
                start: now.addingTimeInterval(TimeSpan.days(inDays)),
                wantsReminderSupport: support
            )
        )
    }

    private func taskCall(
        title: String,
        id: TaskItem.ID? = nil,
        support: Bool? = false
    ) throws -> AIToolCall {
        try ToolCallFactory.make(
            .createTask,
            CreateTaskInput(taskID: id, title: title, wantsReminderSupport: support)
        )
    }

    private func memoryCall(_ content: String) throws -> AIToolCall {
        try ToolCallFactory.make(
            .storeMemory,
            StoreMemoryInput(content: content, kind: .fact)
        )
    }

    // MARK: 69 — sequential calls across rounds

    func testASecondActionIsProposedAfterSeeingTheFirstResult() async throws {
        let provider = ScriptedRoundsProvider(
            id: "test.sequential",
            rounds: [
                .init(toolCalls: [try eventCall(support: false)]),
                .init(toolCalls: [try taskCall(title: "Bring documents")]),
                .init(text: "Done — the appointment and the document task are set."),
            ]
        )
        let harness = try await makeHarness(provider: provider)

        let result = try await harness.engine.send("Dentist Friday, remind me to bring documents", in: harness.conversationID)

        XCTAssertEqual(provider.requestCount, 3)
        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(
            result.plan.actions.map(\.kind).filter { $0 != .scheduleNotification },
            [.createCalendarEvent, .createTask]
        )

        // The model saw the first result before it decided on the second: the
        // request that carried the task call already contained the calendar
        // outcome.
        let secondRequest = provider.receivedRequests[1]
        let toolMessage = try XCTUnwrap(secondRequest.messages.last { $0.role == .tool })
        XCTAssertEqual(toolMessage.toolResult?.toolName, "createCalendarEvent")
        XCTAssertTrue(toolMessage.toolResult?.status.didAct == true)

        // And the closing text is the model's, because by then it had them all.
        XCTAssertEqual(result.assistantMessage.text, "Done — the appointment and the document task are set.")

        let events = try await harness.services.calendar.events(
            in: TimeWindow(start: now, end: now.addingTimeInterval(TimeSpan.days(30)))
        )
        XCTAssertEqual(events.count, 1)
        let tasks = try await harness.repositories.tasks.tasks(matching: TaskFilter())
        XCTAssertEqual(tasks.map(\.title), ["Bring documents"])
    }

    // MARK: 70 — several calls in one response

    func testSeveralCallsInOneResponseAllRun() async throws {
        let provider = ScriptedRoundsProvider(
            id: "test.multi",
            rounds: [
                .init(toolCalls: [
                    try taskCall(title: "Call the dentist"),
                    try taskCall(title: "Buy shampoo"),
                    try memoryCall("Their dentist is Dr Smith"),
                ]),
                .init(text: "All three are set."),
            ]
        )
        let harness = try await makeHarness(provider: provider)

        let result = try await harness.engine.send(
            "Call the dentist, buy shampoo, and remember my dentist is Dr Smith",
            in: harness.conversationID
        )

        XCTAssertEqual(result.status, .success)

        let tasks = try await harness.repositories.tasks.tasks(matching: TaskFilter())
        XCTAssertEqual(Set(tasks.map(\.title)), ["Call the dentist", "Buy shampoo"])
        let memories = try await harness.repositories.memories.all()
        XCTAssertEqual(memories.count, 1)

        // Three calls, three results, no duplicates and nothing lost.
        XCTAssertEqual(result.results.filter { $0.kind == .createTask }.count, 2)
        XCTAssertEqual(result.results.filter { $0.kind == .storeMemory }.count, 1)
        XCTAssertEqual(result.diagnostics.duplicateCount, 0)
    }

    // MARK: 71 — dependency ordering

    func testADependentCallRunsAfterTheOneThatCreatesWhatItNeeds() async throws {
        let taskID = TaskItem.ID()
        let log = ExecutionLog()

        // Proposed in the wrong order on purpose: the follow-up is named first,
        // and refers to a task the second call creates.
        let provider = ScriptedRoundsProvider(
            id: "test.ordering",
            rounds: [
                .init(toolCalls: [
                    try ToolCallFactory.make(
                        .createFollowUp,
                        CreateFollowUpInput(taskID: taskID, checkBackAt: now.addingTimeInterval(TimeSpan.hours(4)))
                    ),
                    try taskCall(title: "Send the paperwork", id: taskID),
                ]),
                .init(text: "Done."),
            ]
        )
        let services = PlatformServices.mock()
        let repositories = AssistantRepositories.ephemeral()
        var settings = try await repositories.settings.settings()
        settings.preferredProviderID = provider.metadata.id
        try await repositories.settings.update(settings)
        let engine = AssistantEngine(
            providers: AIProviderRegistry(providers: [provider]),
            repositories: repositories,
            services: services,
            dateProvider: FixedDateProvider(now: now),
            executor: RecordingToolExecutor(
                inner: DefaultToolExecutor(
                    services: services,
                    repositories: repositories,
                    dateProvider: FixedDateProvider(now: now)
                ),
                log: log
            )
        )
        let conversation = try await engine.startConversation()

        let result = try await engine.send("Send the paperwork and check on me later", in: conversation.id)

        let order = await log.all()
        let taskIndex = try XCTUnwrap(order.firstIndex(of: .createTask))
        let followUpIndex = try XCTUnwrap(order.firstIndex(of: .createFollowUp))
        XCTAssertLessThan(taskIndex, followUpIndex, "The task has to exist before it can be chased")

        XCTAssertEqual(result.status, .success)
        let followUp = try XCTUnwrap(result.results.first { $0.kind == .createFollowUp })
        XCTAssertTrue(followUp.outcome.didChangeAnything)
    }

    func testADependentCallIsSkippedWhenItsProducerFails() async throws {
        let taskID = TaskItem.ID()
        let provider = ScriptedRoundsProvider(
            id: "test.broken-dependency",
            rounds: [
                .init(toolCalls: [
                    // An empty title fails validation, so the task is never
                    // created — and the follow-up must not run against an id
                    // that does not exist.
                    try ToolCallFactory.make(
                        .createTask,
                        CreateTaskInput(taskID: taskID, title: "Send the paperwork")
                    ),
                    try ToolCallFactory.make(
                        .createFollowUp,
                        CreateFollowUpInput(taskID: taskID, checkBackAt: now.addingTimeInterval(TimeSpan.hours(4)))
                    ),
                ]),
                .init(text: "Done."),
            ],
            failAfterRounds: nil
        )
        // Task creation is denied by settings, which is a failure the model
        // could not have predicted from its arguments.
        let harness = try await makeHarness(
            provider: provider,
            settingsMutation: { $0.toolAuthorizations[.createTask] = .denied }
        )

        let result = try await harness.engine.send("Send the paperwork", in: harness.conversationID)

        let followUp = try XCTUnwrap(result.results.first { $0.kind == .createFollowUp })
        XCTAssertEqual(followUp.failure, .dependencyFailed)
        XCTAssertFalse(followUp.outcome.didChangeAnything)

        // Nothing was scheduled against a task that does not exist.
        let notifications = try await harness.services.notifications.pendingNotifications()
        XCTAssertTrue(notifications.isEmpty)
        XCTAssertEqual(result.status, .failed)
    }

    // MARK: 72 — partial failure

    func testPartialSuccessIsReportedTruthfully() async throws {
        let permissions = MockPermissionService()
        await permissions.setStatus(.denied, for: .calendar)
        let services = PlatformServices(
            calendar: MockCalendarService(),
            reminders: MockReminderService(),
            notifications: MockNotificationService(),
            alarms: MockAlarmService(),
            permissions: permissions
        )

        let provider = ScriptedRoundsProvider(
            id: "test.partial",
            rounds: [
                .init(toolCalls: [
                    try eventCall(support: false),
                    try taskCall(title: "Bring documents"),
                ]),
                .init(text: "I saved the document task but couldn't add the appointment."),
            ]
        )
        let harness = try await makeHarness(provider: provider, services: services)

        let result = try await harness.engine.send("Dentist Friday, remind me about documents", in: harness.conversationID)

        XCTAssertEqual(result.status, .partialSuccess)

        let calendarResult = try XCTUnwrap(result.results.first { $0.kind == .createCalendarEvent })
        XCTAssertEqual(calendarResult.failure, .permissionDenied)
        let taskResult = try XCTUnwrap(result.results.first { $0.kind == .createTask })
        XCTAssertTrue(taskResult.outcome.didChangeAnything)

        // The task really is in the store and the event really is not.
        let tasks = try await harness.repositories.tasks.tasks(matching: TaskFilter())
        XCTAssertEqual(tasks.map(\.title), ["Bring documents"])
        let events = try await harness.services.calendar.events(
            in: TimeWindow(start: now, end: now.addingTimeInterval(TimeSpan.days(30)))
        )
        XCTAssertTrue(events.isEmpty)

        // And the model was told the truth before it wrote its reply.
        let closing = provider.receivedRequests[1]
        let calendarMessage = try XCTUnwrap(
            closing.messages.first { $0.toolResult?.toolName == "createCalendarEvent" }
        )
        XCTAssertEqual(calendarMessage.toolResult?.failure, .permissionDenied)
        XCTAssertTrue(calendarMessage.content.contains("permissionDenied"))
    }

    // MARK: 73 — recovery after a failure

    func testTheTurnContinuesAfterAFailureSoAnAlternativeCanBeTried() async throws {
        let permissions = MockPermissionService()
        await permissions.setStatus(.denied, for: .calendar)
        let services = PlatformServices(
            calendar: MockCalendarService(),
            reminders: MockReminderService(),
            notifications: MockNotificationService(),
            alarms: MockAlarmService(),
            permissions: permissions
        )

        let provider = ScriptedRoundsProvider(
            id: "test.recovering",
            rounds: [
                .init(toolCalls: [try eventCall(support: false)]),
                // Having seen the refusal, the model does the next best thing.
                .init(toolCalls: [try taskCall(title: "Dentist at 10")]),
                .init(text: "Calendar access is off, so I tracked it as a task instead."),
            ]
        )
        let harness = try await makeHarness(provider: provider, services: services)

        let result = try await harness.engine.send("Add my dentist appointment", in: harness.conversationID)

        XCTAssertEqual(provider.requestCount, 3, "A failure must not end the turn")
        let tasks = try await harness.repositories.tasks.tasks(matching: TaskFilter())
        XCTAssertEqual(tasks.map(\.title), ["Dentist at 10"])
        XCTAssertEqual(result.status, .partialSuccess)
    }

    // MARK: 74 — authorization failure beside independent work

    func testADeniedToolDoesNotStopAnIndependentOne() async throws {
        let provider = ScriptedRoundsProvider(
            id: "test.denied",
            rounds: [
                .init(toolCalls: [
                    try ToolCallFactory.make(
                        .createAlarm,
                        CreateAlarmInput(label: "Wake up", fireDate: now.addingTimeInterval(TimeSpan.hours(8)))
                    ),
                    try memoryCall("They wake at seven"),
                ]),
                .init(text: "Alarms are switched off in settings, but I noted the wake time."),
            ]
        )
        let harness = try await makeHarness(
            provider: provider,
            settingsMutation: { $0.toolAuthorizations[.createAlarm] = .denied }
        )

        let result = try await harness.engine.send("Wake me at seven", in: harness.conversationID)

        let alarms = try await harness.services.alarms.scheduledAlarms()
        XCTAssertTrue(alarms.isEmpty, "A denied tool must not execute")
        let memories = try await harness.repositories.memories.all()
        XCTAssertEqual(memories.count, 1, "The independent action must still run")

        let alarmResult = try XCTUnwrap(result.results.first { $0.kind == .createAlarm })
        XCTAssertEqual(alarmResult.failure, .authorizationDenied)

        // The model is told which one was refused and why.
        let closing = provider.receivedRequests[1]
        let denied = try XCTUnwrap(closing.messages.first { $0.toolResult?.toolName == "createAlarm" })
        XCTAssertEqual(denied.toolResult?.failure, .authorizationDenied)
        XCTAssertEqual(result.status, .partialSuccess)
    }

    // MARK: 75 — the same call id twice

    func testTheSameCallProposedTwiceExecutesOnce() async throws {
        let call = try taskCall(title: "Call the dentist")
        let provider = ScriptedRoundsProvider(
            id: "test.duplicate-id",
            rounds: [
                // Identical call *object*: same id, same arguments.
                .init(toolCalls: [call, call]),
                .init(text: "Done."),
            ]
        )
        let harness = try await makeHarness(provider: provider)

        let result = try await harness.engine.send("Call the dentist", in: harness.conversationID)

        let tasks = try await harness.repositories.tasks.tasks(matching: TaskFilter())
        XCTAssertEqual(tasks.count, 1, "One logical action, one task")
        XCTAssertEqual(result.diagnostics.duplicateCount, 1)
    }

    // MARK: 76 — the same action under a new call id

    func testTheSameActionWithAFreshCallIDExecutesOnce() async throws {
        let provider = ScriptedRoundsProvider(
            id: "test.duplicate-fingerprint",
            rounds: [
                .init(toolCalls: [try taskCall(title: "Call the dentist")]),
                // A retry that regenerated the call id. Same arguments, so the
                // fingerprint matches and it is not done twice.
                .init(toolCalls: [try taskCall(title: "Call the dentist")]),
                .init(text: "Done."),
            ]
        )
        let harness = try await makeHarness(provider: provider)

        let result = try await harness.engine.send("Call the dentist", in: harness.conversationID)

        let tasks = try await harness.repositories.tasks.tasks(matching: TaskFilter())
        XCTAssertEqual(tasks.count, 1)
        XCTAssertGreaterThan(result.diagnostics.duplicateCount, 0)

        // And the model is told it was already done rather than being left to
        // assume the second call did nothing.
        let reused = provider.receivedRequests
            .flatMap(\.messages)
            .compactMap(\.toolResult)
            .first { $0.wasAlreadyPerformed }
        XCTAssertNotNil(reused)
    }

    func testADifferentActionIsNotSuppressedAsADuplicate() async throws {
        let provider = ScriptedRoundsProvider(
            id: "test.not-a-duplicate",
            rounds: [
                .init(toolCalls: [
                    try taskCall(title: "Call the dentist"),
                    try taskCall(title: "Call the optician"),
                ]),
                .init(text: "Both are set."),
            ]
        )
        let harness = try await makeHarness(provider: provider)

        _ = try await harness.engine.send("Two calls to make", in: harness.conversationID)

        let tasks = try await harness.repositories.tasks.tasks(matching: TaskFilter())
        XCTAssertEqual(tasks.count, 2, "Suppressing genuinely different actions would be worse than a duplicate")
    }

    // MARK: 77 — replay after a provider failure

    func testAProviderRetryThatRepeatsAToolCallDoesNotRepeatTheAction() async throws {
        // Round 2 stands in for the retried continuation: the same request, so
        // the same proposal comes back.
        let provider = ScriptedRoundsProvider(
            id: "test.replay",
            rounds: [
                .init(toolCalls: [try eventCall(support: false)]),
                .init(toolCalls: [try eventCall(support: false)]),
                .init(text: "Added."),
            ]
        )
        let harness = try await makeHarness(provider: provider)

        _ = try await harness.engine.send("Dentist Friday", in: harness.conversationID)

        let events = try await harness.services.calendar.events(
            in: TimeWindow(start: now, end: now.addingTimeInterval(TimeSpan.days(30)))
        )
        XCTAssertEqual(events.count, 1, "A replayed continuation must not create a second event")
    }

    // MARK: 78 — bounded tool retry

    func testATemporaryFailureIsRetriedOnceAndThenSucceeds() async throws {
        let calendar = FlakyCalendarService(failuresBeforeSuccess: 1)
        let services = PlatformServices(
            calendar: calendar,
            reminders: MockReminderService(),
            notifications: MockNotificationService(),
            alarms: MockAlarmService(),
            permissions: MockPermissionService()
        )
        let provider = ScriptedRoundsProvider(
            id: "test.retry",
            rounds: [
                .init(toolCalls: [try eventCall(support: false)]),
                .init(text: "Added."),
            ]
        )
        let harness = try await makeHarness(provider: provider, services: services)

        let result = try await harness.engine.send("Dentist Friday", in: harness.conversationID)

        XCTAssertEqual(calendar.createAttempts, 2, "One failure, one retry")
        XCTAssertEqual(result.diagnostics.retryCount, 1)
        let calendarResult = try XCTUnwrap(result.results.first { $0.kind == .createCalendarEvent })
        XCTAssertTrue(calendarResult.outcome.didChangeAnything)
        XCTAssertEqual(result.status, .success)
    }

    func testRetriesAreBoundedAndTheFailureIsReported() async throws {
        let calendar = FlakyCalendarService(failuresBeforeSuccess: 99)
        let services = PlatformServices(
            calendar: calendar,
            reminders: MockReminderService(),
            notifications: MockNotificationService(),
            alarms: MockAlarmService(),
            permissions: MockPermissionService()
        )
        let provider = ScriptedRoundsProvider(
            id: "test.retry-bounded",
            rounds: [
                .init(toolCalls: [try eventCall(support: false)]),
                .init(text: "I couldn't add it."),
            ]
        )
        let harness = try await makeHarness(provider: provider, services: services)

        let result = try await harness.engine.send("Dentist Friday", in: harness.conversationID)

        XCTAssertEqual(
            calendar.createAttempts,
            AgentLimits.default.maximumToolRetries + 1,
            "Retrying is bounded by policy, not by how long the service stays broken"
        )
        let calendarResult = try XCTUnwrap(result.results.first { $0.kind == .createCalendarEvent })
        XCTAssertEqual(calendarResult.failure, .temporaryFailure)
        XCTAssertEqual(result.status, .failed)
    }

    // MARK: 79 — what is never retried

    func testAPermissionDenialIsNeverRetried() async throws {
        let calendar = FlakyCalendarService(failuresBeforeSuccess: 0)
        let permissions = MockPermissionService()
        await permissions.setStatus(.denied, for: .calendar)
        let services = PlatformServices(
            calendar: calendar,
            reminders: MockReminderService(),
            notifications: MockNotificationService(),
            alarms: MockAlarmService(),
            permissions: permissions
        )
        let provider = ScriptedRoundsProvider(
            id: "test.no-retry",
            rounds: [
                .init(toolCalls: [try eventCall(support: false)]),
                .init(text: "Calendar access is off."),
            ]
        )
        let harness = try await makeHarness(provider: provider, services: services)

        let result = try await harness.engine.send("Dentist Friday", in: harness.conversationID)

        XCTAssertEqual(calendar.createAttempts, 0, "A denied capability is never even reached")
        XCTAssertEqual(result.diagnostics.retryCount, 0)
        XCTAssertEqual(
            result.results.first { $0.kind == .createCalendarEvent }?.failure,
            .permissionDenied
        )
    }

    // MARK: 80 — the round ceiling

    func testTheLoopStopsAtTheRoundLimit() async throws {
        // A model that proposes a *different* action every round, so duplicate
        // detection cannot end the turn and only the ceiling can.
        var rounds: [ScriptedRoundsProvider.Round] = []
        for index in 0..<20 {
            rounds.append(.init(toolCalls: [try taskCall(title: "Task \(index)")]))
        }
        let provider = ScriptedRoundsProvider(id: "test.endless", rounds: rounds)
        let limits = AgentLimits(maximumRounds: 3)
        let harness = try await makeHarness(provider: provider, limits: limits)

        let result = try await harness.engine.send("Keep going", in: harness.conversationID)

        XCTAssertEqual(provider.requestCount, 3)
        XCTAssertEqual(result.diagnostics.stopReason, .agentRoundLimitExceeded)

        // Bounded, and honest: the three tasks it did create are still there
        // and the reply says the request did not finish cleanly.
        let tasks = try await harness.repositories.tasks.tasks(matching: TaskFilter())
        XCTAssertEqual(tasks.count, 3)
        XCTAssertTrue(result.assistantMessage.text.contains("couldn't finish"))
    }

    func testThePerTurnToolBudgetIsEnforced() async throws {
        var rounds: [ScriptedRoundsProvider.Round] = []
        for index in 0..<10 {
            rounds.append(.init(toolCalls: [try taskCall(title: "Task \(index)")]))
        }
        let provider = ScriptedRoundsProvider(id: "test.budget", rounds: rounds)
        let harness = try await makeHarness(
            provider: provider,
            limits: AgentLimits(maximumRounds: 6, maximumToolCallsPerTurn: 2)
        )

        let result = try await harness.engine.send("Keep going", in: harness.conversationID)

        let tasks = try await harness.repositories.tasks.tasks(matching: TaskFilter())
        XCTAssertEqual(tasks.count, 2)
        XCTAssertEqual(result.diagnostics.stopReason, .toolBudgetExhausted)
    }

    // MARK: 81 / 82 — clarification

    func testAClarificationStopsEverythingElseInThatRound() async throws {
        let provider = ScriptedRoundsProvider(
            id: "test.clarifying",
            rounds: [
                .init(toolCalls: [
                    try ToolCallFactory.make(
                        .askClarification,
                        AskClarificationInput(
                            question: "Which appointment do you mean?",
                            options: ["Dentist at 10", "Haircut at 6"]
                        )
                    ),
                    // Proposed alongside the question, and therefore not run:
                    // moving one of them *and* asking which one is the failure
                    // the clarification exists to prevent.
                    try ToolCallFactory.make(
                        .updateCalendarEvent,
                        UpdateCalendarEventInput(
                            eventID: CalendarItem.ID(),
                            start: now.addingTimeInterval(TimeSpan.days(2))
                        )
                    ),
                ]),
            ]
        )
        let harness = try await makeHarness(provider: provider)

        let result = try await harness.engine.send("Move my appointment to Friday", in: harness.conversationID)

        XCTAssertEqual(result.status, .requiresClarification)
        XCTAssertEqual(result.clarification?.question, "Which appointment do you mean?")
        XCTAssertEqual(result.clarification?.options.count, 2)
        XCTAssertTrue(result.plan.actions.isEmpty, "Nothing may be executed while the assistant is still asking")
        XCTAssertTrue(result.assistantMessage.text.contains("Which appointment"))
        XCTAssertTrue(result.assistantMessage.text.contains("Dentist at 10"))

        // Resumable: the question is in the transcript, so the user's answer
        // arrives in a conversation that still contains what was asked.
        let stored = try await harness.repositories.conversations.conversation(id: harness.conversationID)
        XCTAssertEqual(stored?.messages.last?.role, .assistant)
        XCTAssertTrue(stored?.messages.last?.text.contains("Which appointment") == true)
    }

    func testTheAnswerToAClarificationContinuesTheSameConversation() async throws {
        let provider = ScriptedRoundsProvider(
            id: "test.resuming",
            rounds: [
                .init(toolCalls: [
                    try ToolCallFactory.make(
                        .askClarification,
                        AskClarificationInput(question: "Which appointment do you mean?")
                    ),
                ]),
                .init(toolCalls: [try taskCall(title: "Move the dentist appointment")]),
                .init(text: "Moved the dentist one."),
            ]
        )
        let harness = try await makeHarness(provider: provider)

        _ = try await harness.engine.send("Move my appointment", in: harness.conversationID)
        let second = try await harness.engine.send("The dentist one", in: harness.conversationID)

        // The second turn's request carried the question and the answer, which
        // is what "resumable" means here — no separate agent-chain blob.
        let texts = provider.receivedRequests.last?.messages.map(\.content) ?? []
        XCTAssertTrue(texts.contains { $0.contains("Which appointment do you mean?") })
        XCTAssertTrue(texts.contains { $0.contains("The dentist one") })
        XCTAssertEqual(second.status, .success)
    }

    func testNothingIsAskedWhenThePlannerAlreadyHasAPolicy() async throws {
        // "Remind me beforehand" with a time given. The support planner owns
        // how far beforehand, so the assistant has nothing to ask about.
        let provider = ScriptedRoundsProvider(
            id: "test.no-question",
            rounds: [
                .init(toolCalls: [try eventCall()]),
                .init(text: "Added, and I'll remind you beforehand."),
            ]
        )
        let harness = try await makeHarness(provider: provider)

        let result = try await harness.engine.send(
            "I have a dentist appointment Friday at 10. Remind me beforehand.",
            in: harness.conversationID
        )

        XCTAssertNil(result.clarification)
        XCTAssertEqual(result.status, .success)

        // The reminders came from the app's policy, not from the model asking
        // the user or scheduling each one itself.
        let planned = result.plan.actions.filter { $0.origin == .supportPlanner }
        XCTAssertGreaterThan(planned.count, 1)
        let notifications = try await harness.services.notifications.pendingNotifications()
        XCTAssertGreaterThan(notifications.count, 1)
    }

    // MARK: 83 — the compound appointment

    func testTheCompoundAppointmentRequestIsCoordinated() async throws {
        let provider = ScriptedRoundsProvider(
            id: "test.compound",
            rounds: [
                .init(toolCalls: [
                    try ToolCallFactory.make(
                        .createCalendarEvent,
                        CreateCalendarEventInput(
                            title: "Appointment",
                            start: now.addingTimeInterval(TimeSpan.days(2)),
                            location: "The clinic",
                            travelDurationMinutes: 30
                        )
                    ),
                ]),
                .init(toolCalls: [try taskCall(title: "Bring my documents")]),
                .init(text: "Done. The appointment is in, you'll be reminded beforehand and in time to leave, and there's a task to bring your documents."),
            ]
        )
        let harness = try await makeHarness(provider: provider)

        let result = try await harness.engine.send(
            "I have an appointment Friday at 10, remind me beforehand, make sure I leave on time, and tell me to bring my documents.",
            in: harness.conversationID
        )

        XCTAssertEqual(result.status, .success)

        // 1. The appointment.
        let events = try await harness.services.calendar.events(
            in: TimeWindow(start: now, end: now.addingTimeInterval(TimeSpan.days(30)))
        )
        XCTAssertEqual(events.map(\.title), ["Appointment"])

        // 2 and 3. The support plan, including a leave-in-time intervention —
        // generated by the SupportPlanner from the travel time, not by the model.
        let eventAction = try XCTUnwrap(result.plan.actions.first { $0.kind == .createCalendarEvent })
        guard case .createCalendarEvent(let eventInput) = eventAction.request else {
            return XCTFail("The calendar action lost its request")
        }
        let eventID = try XCTUnwrap(eventInput.eventID, "The planner assigns the event id")
        let plans = try await harness.repositories.reminderPlans.plans(for: .calendarItem(eventID))
        XCTAssertFalse(plans.isEmpty)
        XCTAssertGreaterThan(plans[0].stages.count, 1, "One appointment, several staged interventions")
        let notifications = try await harness.services.notifications.pendingNotifications()
        XCTAssertGreaterThan(notifications.count, 1)
        XCTAssertTrue(
            notifications.contains { $0.fireDate < events[0].start },
            "Something has to fire before the appointment starts"
        )

        // 4. The preparation task.
        let tasks = try await harness.repositories.tasks.tasks(matching: TaskFilter())
        XCTAssertEqual(tasks.map(\.title), ["Bring my documents"])

        // And none of it twice.
        XCTAssertEqual(result.results.filter { $0.kind == .createCalendarEvent }.count, 1)
        XCTAssertEqual(result.results.filter { $0.kind == .createTask }.count, 1)
        XCTAssertEqual(result.diagnostics.duplicateCount, 0)
    }

    // MARK: 84 — provider switching

    func testWorkSurvivesSwitchingProviderAfterwards() async throws {
        let first = ScriptedRoundsProvider(
            id: "test.first",
            rounds: [
                .init(toolCalls: [try taskCall(title: "Send the paperwork")]),
                .init(text: "Tracked."),
            ]
        )
        let second = ScriptedRoundsProvider(
            id: "test.second",
            rounds: [.init(text: "Yes, it's still on your list.")]
        )

        let repositories = AssistantRepositories.ephemeral()
        var settings = try await repositories.settings.settings()
        settings.preferredProviderID = first.metadata.id
        try await repositories.settings.update(settings)

        let engine = AssistantEngine(
            providers: AIProviderRegistry(providers: [first, second]),
            repositories: repositories,
            services: PlatformServices.mock(),
            dateProvider: FixedDateProvider(now: now)
        )
        let conversation = try await engine.startConversation()

        _ = try await engine.send("Send the paperwork", in: conversation.id)

        settings = try await repositories.settings.settings()
        settings.preferredProviderID = second.metadata.id
        try await repositories.settings.update(settings)

        let result = try await engine.send("Is that still on my list?", in: conversation.id)

        XCTAssertEqual(result.providerID, "test.second")
        let tasks = try await repositories.tasks.tasks(matching: TaskFilter())
        XCTAssertEqual(tasks.map(\.title), ["Send the paperwork"], "State belongs to the app, not to a provider")

        // The new provider was told about the task by the app's own context
        // assembly, having never seen the turn that created it.
        let prompt = try XCTUnwrap(second.receivedRequests.last?.systemPrompt)
        XCTAssertTrue(prompt.contains("Send the paperwork"))
    }

    // MARK: 85 — the fallback summary

    func testTheFallbackSummaryReportsWhatReallyHappened() async throws {
        let provider = ScriptedRoundsProvider(
            id: "test.fallback",
            rounds: [.init(text: "On it.", toolCalls: [try taskCall(title: "Send the paperwork")])],
            failAfterRounds: 1
        )
        let harness = try await makeHarness(provider: provider)

        let result = try await harness.engine.send("Send the paperwork", in: harness.conversationID)

        XCTAssertEqual(result.diagnostics.stopReason, .providerFailed)
        XCTAssertEqual(result.status, .success, "The action succeeded; only the closing sentence failed")

        // Written by the app, not by another model call, and it names what was
        // actually done rather than what was planned.
        XCTAssertTrue(result.assistantMessage.text.contains("1 action completed"))
        XCTAssertTrue(result.assistantMessage.text.contains("createTask"))

        let tasks = try await harness.repositories.tasks.tasks(matching: TaskFilter())
        XCTAssertEqual(tasks.count, 1, "A failed continuation must not undo what happened")
    }

    func testTheFallbackSummaryNamesTheFailureWhenThereIsOne() async throws {
        let permissions = MockPermissionService()
        await permissions.setStatus(.denied, for: .calendar)
        let services = PlatformServices(
            calendar: MockCalendarService(),
            reminders: MockReminderService(),
            notifications: MockNotificationService(),
            alarms: MockAlarmService(),
            permissions: permissions
        )
        let provider = ScriptedRoundsProvider(
            id: "test.fallback-failure",
            rounds: [
                .init(text: "On it.", toolCalls: [try eventCall(support: false), try taskCall(title: "Bring documents")]),
            ],
            failAfterRounds: 1
        )
        let harness = try await makeHarness(provider: provider, services: services)

        let result = try await harness.engine.send("Add the appointment and the task", in: harness.conversationID)

        XCTAssertEqual(result.status, .partialSuccess)
        XCTAssertTrue(result.assistantMessage.text.contains("createCalendarEvent did not happen"))
        XCTAssertTrue(result.assistantMessage.text.contains("createTask"))
    }

    // MARK: 87 — the safety pipeline, in every round

    func testEveryRoundIsValidatedAndAuthorizedIndependently() async throws {
        // Round one does something allowed. Round two proposes a destructive
        // action that settings hold for confirmation, plus one that fails
        // validation. Neither may ride on round one's success.
        let provider = ScriptedRoundsProvider(
            id: "test.pipeline",
            rounds: [
                .init(toolCalls: [try memoryCall("They live in Athens")]),
                .init(toolCalls: [
                    try ToolCallFactory.make(
                        .deleteCalendarEvent,
                        DeleteCalendarEventInput(eventID: CalendarItem.ID())
                    ),
                    try ToolCallFactory.make(
                        .createAlarm,
                        // In the past: rejected by validation, in round two just
                        // as it would be in round one.
                        CreateAlarmInput(label: "Too late", fireDate: now.addingTimeInterval(-TimeSpan.hours(2)))
                    ),
                ]),
                .init(text: "Noted."),
            ]
        )
        let harness = try await makeHarness(provider: provider)

        let result = try await harness.engine.send("Remember where I live", in: harness.conversationID)

        // Validation ran in round two.
        XCTAssertEqual(result.plan.rejected.map(\.name), ["createAlarm"])

        // Authorization ran in round two: the deletion is held, not performed.
        let deletion = try XCTUnwrap(result.results.first { $0.kind == .deleteCalendarEvent })
        XCTAssertEqual(deletion.outcome, .awaitingConfirmation)
        XCTAssertEqual(deletion.failure, .confirmationRequired)

        // And nothing escalated: a memory written in round one grants a later
        // round no authority at all.
        let alarms = try await harness.services.alarms.scheduledAlarms()
        XCTAssertTrue(alarms.isEmpty)
    }

    // MARK: 44 — cancellation

    func testCancellingTheTurnKeepsWhatAlreadyHappened() async throws {
        // The turn is cancelled from inside the second round, after the first
        // action has really happened.
        let handle = TurnHandle()
        let provider = CancellingProvider(
            id: "test.cancelled",
            handle: handle,
            cancelBeforeRound: 2,
            rounds: [
                .init(toolCalls: [try taskCall(title: "Send the paperwork")]),
                .init(toolCalls: [try taskCall(title: "Second task")]),
                .init(text: "Done."),
            ]
        )
        let harness = try await makeHarness(provider: provider)

        let turn = Task {
            try await harness.engine.send("Do the thing", in: harness.conversationID)
        }
        await handle.set(turn)
        let result = try await turn.value

        XCTAssertEqual(result.status, .cancelled)

        // The first task really happened and is still there. Section 44: a
        // cancelled chat turn does not un-create things that exist.
        let tasks = try await harness.repositories.tasks.tasks(matching: TaskFilter())
        XCTAssertEqual(tasks.map(\.title), ["Send the paperwork"])

        // And the second never started.
        XCTAssertFalse(tasks.contains { $0.title == "Second task" })
    }
}
