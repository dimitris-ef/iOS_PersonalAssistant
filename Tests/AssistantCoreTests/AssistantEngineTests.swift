import AssistantAI
import AssistantDomain
import AssistantPersistence
import AssistantPlatform
import AssistantTools
import DevSupport
import MockPlatform
import XCTest
@testable import AssistantCore

final class AssistantEngineTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private struct Harness {
        let engine: AssistantEngine
        let repositories: AssistantRepositories
        let services: PlatformServices
        let log: PlatformEventLog
        let conversationID: Conversation.ID
    }

    private func makeHarness(
        providers: [any AIProvider],
        preferred: AIProviderIdentifier? = nil,
        settingsMutation: ((inout AssistantSettings) -> Void)? = nil
    ) async throws -> Harness {
        let dateProvider = FixedDateProvider(now: now)
        let repositories = AssistantRepositories.ephemeral()

        var settings = try await repositories.settings.settings()
        settings.preferredProviderID = preferred ?? providers.first?.metadata.id
        settingsMutation?(&settings)
        try await repositories.settings.update(settings)

        var profile = try await repositories.profile.profile()
        profile.defaultPreparationDuration = Duration.minutes(30)
        profile.defaultTravelDuration = Duration.minutes(20)
        try await repositories.profile.update(profile)

        let log = PlatformEventLog()
        let services = PlatformServices.mock(log: log)
        let engine = AssistantEngine(
            providers: AIProviderRegistry(providers: providers),
            repositories: repositories,
            services: services,
            dateProvider: dateProvider
        )
        let conversation = try await engine.startConversation(title: "Test")

        return Harness(
            engine: engine,
            repositories: repositories,
            services: services,
            log: log,
            conversationID: conversation.id
        )
    }

    // MARK: End-to-end

    func testAppointmentProducesAnEventPlusItsSupportingReminders() async throws {
        let call = try ToolCallFactory.make(
            .createCalendarEvent,
            CreateCalendarEventInput(
                title: "Haircut",
                start: now.addingTimeInterval(Duration.days(7)),
                location: "Barber",
                importance: .normal
            )
        )
        let harness = try await makeHarness(
            providers: [StubAIProvider(text: "I've added your haircut.", toolCalls: [call])]
        )

        let result = try await harness.engine.send("I have a haircut", in: harness.conversationID)

        XCTAssertEqual(result.assistantMessage.text, "I've added your haircut.")

        let kinds = result.plan.actions.map(\.kind)
        XCTAssertEqual(kinds.filter { $0 == .createCalendarEvent }.count, 1)
        XCTAssertGreaterThan(
            kinds.filter { $0 == .scheduleNotification }.count,
            1,
            "One calendar event should produce several staged reminders"
        )

        // The extra actions must be attributed to the app, not to the model.
        let plannerActions = result.plan.actions.filter { $0.origin == .supportPlanner }
        XCTAssertFalse(plannerActions.isEmpty)
        XCTAssertTrue(plannerActions.allSatisfy { $0.rationale != nil })

        let events = try await harness.services.calendar.events(
            in: TimeWindow(start: now, end: now.addingTimeInterval(Duration.days(30)))
        )
        XCTAssertEqual(events.map(\.title), ["Haircut"])

        let notifications = try await harness.services.notifications.pendingNotifications()
        XCTAssertGreaterThan(notifications.count, 1)
    }

    func testMockExecutionIsReportedAsSimulatedNotExecuted() async throws {
        let call = try ToolCallFactory.make(
            .createCalendarEvent,
            CreateCalendarEventInput(title: "Haircut", start: now.addingTimeInterval(Duration.days(2)))
        )
        let harness = try await makeHarness(providers: [StubAIProvider(toolCalls: [call])])

        let result = try await harness.engine.send("hi", in: harness.conversationID)

        let calendarResult = try XCTUnwrap(result.results.first { $0.kind == .createCalendarEvent })
        guard case .simulated(let platform) = calendarResult.outcome else {
            return XCTFail("Mock platform must never report .executed, got \(calendarResult.outcome)")
        }
        XCTAssertEqual(platform, "MockCalendar")

        let entries = await harness.log.allEntries()
        XCTAssertTrue(entries.allSatisfy { $0.fidelity == .simulated })
    }

    func testReminderPlansArePersistedAndLinkedToTheirTask() async throws {
        let call = try ToolCallFactory.make(
            .createTask,
            CreateTaskInput(
                title: "Pay the electricity bill",
                fixedDate: now.addingTimeInterval(Duration.days(3))
            )
        )
        let harness = try await makeHarness(providers: [StubAIProvider(toolCalls: [call])])

        _ = try await harness.engine.send("remind me", in: harness.conversationID)

        let tasks = try await harness.repositories.tasks.tasks(matching: .outstanding)
        let task = try XCTUnwrap(tasks.first)
        let planID = try XCTUnwrap(task.reminderPlanID)
        let plan = try await harness.repositories.reminderPlans.plan(id: planID)

        XCTAssertNotNil(plan)
        XCTAssertEqual(plan?.subject.reference, .task(task.id))
    }

    // MARK: Authorization

    func testDeniedToolsAreNeverExecuted() async throws {
        let call = try ToolCallFactory.make(
            .createAlarm,
            CreateAlarmInput(label: "Wake up", fireDate: now.addingTimeInterval(Duration.hours(8)))
        )
        let harness = try await makeHarness(
            providers: [StubAIProvider(toolCalls: [call])],
            settingsMutation: { $0.toolAuthorizations[.createAlarm] = .denied }
        )

        let result = try await harness.engine.send("wake me", in: harness.conversationID)

        let alarmResult = try XCTUnwrap(result.results.first { $0.kind == .createAlarm })
        guard case .denied = alarmResult.outcome else {
            return XCTFail("Expected the alarm to be denied, got \(alarmResult.outcome)")
        }
        let alarms = try await harness.services.alarms.scheduledAlarms()
        XCTAssertTrue(alarms.isEmpty)
    }

    func testActionsNeedingConfirmationAreHeldBack() async throws {
        let call = try ToolCallFactory.make(
            .deleteCalendarEvent,
            DeleteCalendarEventInput(eventID: CalendarItem.ID())
        )
        let harness = try await makeHarness(providers: [StubAIProvider(toolCalls: [call])])

        let result = try await harness.engine.send("delete it", in: harness.conversationID)

        let deletion = try XCTUnwrap(result.results.first { $0.kind == .deleteCalendarEvent })
        XCTAssertEqual(deletion.outcome, .awaitingConfirmation)
        XCTAssertEqual(result.plan.actionsAwaitingConfirmation.count, 1)
        XCTAssertTrue(result.plan.executableActions.isEmpty)
    }

    func testMissingPermissionBlocksExecution() async throws {
        let call = try ToolCallFactory.make(
            .createCalendarEvent,
            CreateCalendarEventInput(
                title: "Haircut",
                start: now.addingTimeInterval(Duration.days(2)),
                wantsReminderSupport: false
            )
        )
        let dateProvider = FixedDateProvider(now: now)
        let repositories = AssistantRepositories.ephemeral()
        var settings = try await repositories.settings.settings()
        settings.preferredProviderID = "test.stub"
        try await repositories.settings.update(settings)

        let permissions = MockPermissionService()
        await permissions.setStatus(.denied, for: .calendar)
        let services = PlatformServices(
            calendar: MockCalendarService(),
            reminders: MockReminderService(),
            notifications: MockNotificationService(),
            alarms: MockAlarmService(),
            permissions: permissions
        )
        let engine = AssistantEngine(
            providers: AIProviderRegistry(providers: [StubAIProvider(toolCalls: [call])]),
            repositories: repositories,
            services: services,
            dateProvider: dateProvider
        )
        let conversation = try await engine.startConversation()

        let result = try await engine.send("add it", in: conversation.id)

        let calendarResult = try XCTUnwrap(result.results.first { $0.kind == .createCalendarEvent })
        guard case .denied = calendarResult.outcome else {
            return XCTFail("Expected denial without calendar permission, got \(calendarResult.outcome)")
        }
    }

    func testCompletingATaskRequiresExplicitConfirmation() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let task = TaskItem(title: "Pay the bill", status: .reminded, createdAt: now)
        try await repositories.tasks.save(task)

        let call = try ToolCallFactory.make(
            .completeTask,
            CompleteTaskInput(taskID: task.id, confirmedByUser: false)
        )
        var settings = try await repositories.settings.settings()
        settings.preferredProviderID = "test.stub"
        try await repositories.settings.update(settings)

        let engine = AssistantEngine(
            providers: AIProviderRegistry(providers: [StubAIProvider(toolCalls: [call])]),
            repositories: repositories,
            services: PlatformServices.mock(),
            dateProvider: FixedDateProvider(now: now)
        )
        let conversation = try await engine.startConversation()

        let result = try await engine.send("I think that's handled", in: conversation.id)

        let completion = try XCTUnwrap(result.results.first { $0.kind == .completeTask })
        guard case .denied = completion.outcome else {
            return XCTFail("Unconfirmed completion must not close a task, got \(completion.outcome)")
        }
        let stored = try await repositories.tasks.task(id: task.id)
        XCTAssertEqual(stored?.status, .reminded)
    }

    // MARK: Malformed model output

    func testInvalidToolCallsAreRejectedWithoutDerailingTheTurn() async throws {
        let good = try ToolCallFactory.make(
            .storeMemory,
            StoreMemoryInput(content: "Needs 30 minutes to get ready", kind: .routine)
        )
        let bad = AIToolCall(name: "definitelyNotATool", arguments: .object([:]))
        let harness = try await makeHarness(
            providers: [StubAIProvider(text: "Noted.", toolCalls: [good, bad])]
        )

        let result = try await harness.engine.send("remember that", in: harness.conversationID)

        XCTAssertEqual(result.plan.rejected.count, 1)
        XCTAssertEqual(result.plan.actions.map(\.kind), [.storeMemory])
        XCTAssertEqual(result.assistantMessage.text, "Noted.")

        let memories = try await harness.repositories.memories.all()
        XCTAssertEqual(memories.count, 1)
    }

    // MARK: Engagement

    func testDismissingAReminderLeavesTheTaskOpen() async throws {
        let harness = try await makeHarness(providers: [StubAIProvider()])
        let task = TaskItem(title: "Pay the bill", status: .reminded, createdAt: now)
        try await harness.repositories.tasks.save(task)

        let updated = try await harness.engine.record(.reminderDismissed(at: now), for: task.id)

        XCTAssertNotEqual(updated.status, .completed)
        XCTAssertTrue(updated.status.isOutstanding)
    }

    func testConfirmingCompletionClosesTheTask() async throws {
        let harness = try await makeHarness(providers: [StubAIProvider()])
        let task = TaskItem(title: "Pay the bill", status: .reminded, createdAt: now)
        try await harness.repositories.tasks.save(task)

        let updated = try await harness.engine.record(.confirmedComplete(at: now), for: task.id)

        XCTAssertEqual(updated.status, .completed)
        XCTAssertEqual(updated.completedAt, now)
    }

    // MARK: The scripted development provider

    func testScriptedProviderDrivesTheWholePipeline() async throws {
        let dateProvider = FixedDateProvider(now: now)
        let harness = try await makeHarness(
            providers: [ScriptedDevProvider(dateProvider: dateProvider)],
            preferred: ScriptedDevProvider.providerID
        )

        let result = try await harness.engine.send(
            "I have a haircut next Sunday at 10 PM",
            in: harness.conversationID
        )

        XCTAssertTrue(result.plan.actions.contains { $0.kind == .createCalendarEvent })
        XCTAssertTrue(result.plan.actions.contains { $0.origin == .supportPlanner })

        let events = try await harness.services.calendar.events(
            in: TimeWindow(start: now, end: now.addingTimeInterval(Duration.days(30)))
        )
        XCTAssertEqual(events.first?.title.lowercased(), "haircut")
    }
}
