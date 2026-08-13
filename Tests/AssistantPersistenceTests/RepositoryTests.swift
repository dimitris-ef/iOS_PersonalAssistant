import AssistantDomain
import XCTest
@testable import AssistantPersistence

final class RepositoryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testConversationsRoundTripThroughTheStore() async throws {
        let store = EphemeralSnapshotStore()
        let repository = SnapshotConversationRepository(store: store)

        var conversation = Conversation(title: "First", createdAt: now)
        conversation.append(Message(role: .user, text: "Hello", createdAt: now))
        try await repository.save(conversation)

        // A second repository over the same store proves the data was written,
        // not merely cached in the first instance.
        let reloaded = SnapshotConversationRepository(store: store)
        let fetched = try await reloaded.conversation(id: conversation.id)

        XCTAssertEqual(fetched?.title, "First")
        XCTAssertEqual(fetched?.messages.count, 1)
        XCTAssertEqual(fetched?.messages.first?.text, "Hello")
    }

    func testMemorySearchRanksByKeywordOverlap() async throws {
        let repository = SnapshotMemoryRepository(store: EphemeralSnapshotStore())
        try await repository.store(
            MemoryItem(kind: .routine, content: "Needs thirty minutes to get ready", createdAt: now)
        )
        try await repository.store(
            MemoryItem(kind: .person, content: "Barber is called Marco", createdAt: now)
        )

        let results = try await repository.search(MemoryQuery(text: "how long to get ready"))

        XCTAssertEqual(results.first?.kind, .routine)
    }

    func testMemorySearchFiltersByKind() async throws {
        let repository = SnapshotMemoryRepository(store: EphemeralSnapshotStore())
        try await repository.store(MemoryItem(kind: .routine, content: "Wakes at seven", createdAt: now))
        try await repository.store(MemoryItem(kind: .person, content: "Wakes the dog", createdAt: now))

        let results = try await repository.search(MemoryQuery(text: "wakes", kinds: [.person]))

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.kind, .person)
    }

    func testTaskFilteringByStatusAndLimit() async throws {
        let repository = SnapshotTaskRepository(store: EphemeralSnapshotStore())
        try await repository.save(
            TaskItem(title: "Open", status: .reminded, timing: .fixed(now), createdAt: now)
        )
        try await repository.save(
            TaskItem(title: "Done", status: .completed, timing: .fixed(now), createdAt: now)
        )

        let outstanding = try await repository.tasks(matching: .outstanding)

        XCTAssertEqual(outstanding.map(\.title), ["Open"])
    }

    func testSettingsDefaultWhenNothingIsStored() async throws {
        let repository = SnapshotSettingsRepository(store: EphemeralSnapshotStore())
        let settings = try await repository.settings()

        XCTAssertEqual(settings.routingPolicy, .preferOnDevice)
        XCTAssertEqual(settings.authorization(for: .deleteCalendarEvent), .requiresConfirmation)
        XCTAssertEqual(settings.authorization(for: .createReminder), .allowed)
    }

    func testSettingsSurviveAReload() async throws {
        let store = EphemeralSnapshotStore()
        let repository = SnapshotSettingsRepository(store: store)

        var settings = try await repository.settings()
        settings.preferredProviderID = "remote.example"
        settings.support.advanceNoticeDays = [7, 1]
        try await repository.update(settings)

        let reloaded = try await SnapshotSettingsRepository(store: store).settings()

        XCTAssertEqual(reloaded.preferredProviderID, "remote.example")
        XCTAssertEqual(reloaded.support.advanceNoticeDays, [7, 1])
    }

    func testReminderPlansAreFoundByTheirSubject() async throws {
        let repository = SnapshotReminderPlanRepository(store: EphemeralSnapshotStore())
        let taskID = TaskItem.ID()
        let plan = ReminderPlan(
            subject: ReminderSubject(
                reference: .task(taskID),
                title: "Pay bill",
                anchor: .deadline(now)
            ),
            stages: [],
            createdAt: now,
            generatedBy: "test"
        )
        try await repository.save(plan)

        let found = try await repository.plans(for: .task(taskID))
        XCTAssertEqual(found.map(\.id), [plan.id])

        let missing = try await repository.plans(for: .task(TaskItem.ID()))
        XCTAssertTrue(missing.isEmpty)
    }
}
