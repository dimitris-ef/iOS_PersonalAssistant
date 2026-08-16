#if canImport(SwiftData)

import AssistantDomain
import AssistantPersistence
import AssistantPersistenceSwiftData
import AssistantTools
import XCTest

/// The milestone's actual objective, tested end to end.
///
/// Each test writes through one set of repositories, throws away the container
/// that wrote them, opens a new container over the same file, and reads through
/// fresh repositories. That sequence is what a user does when they close the
/// app and open it again; anything that only works while the first container is
/// alive fails here.
@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
final class RelaunchPersistenceTests: PersistenceTestCase {

    func testEverythingTheUserCreatedSurvivesARelaunch() async throws {
        // Steps 1–6 of the manual validation scenario, in order.
        let task = TaskItem(
            title: "Call dentist tomorrow",
            status: .notStarted,
            importance: .high,
            timing: .fixed(Self.referenceDate.addingTimeInterval(TimeSpan.days(1))),
            createdAt: Self.referenceDate
        )
        try await repositories.tasks.save(task)

        let memory = MemoryItem(
            kind: .routine,
            content: "It takes me 30 minutes to drive to work",
            salience: 0.7,
            createdAt: Self.referenceDate
        )
        try await repositories.memories.store(memory)

        let conversation = Conversation(
            title: "Assistant",
            messages: [
                Message(
                    role: .user,
                    text: "Remind me to call the dentist",
                    createdAt: Self.referenceDate
                ),
                Message(
                    role: .assistant,
                    text: "Done — I'll nudge you tomorrow morning.",
                    createdAt: Self.referenceDate.addingTimeInterval(1)
                ),
            ],
            createdAt: Self.referenceDate
        )
        try await repositories.conversations.save(conversation)

        let plan = ReminderPlan(
            subject: ReminderSubject(
                reference: .task(task.id),
                title: task.title,
                anchor: .moment(Self.referenceDate.addingTimeInterval(TimeSpan.days(1))),
                importance: .high
            ),
            stages: [
                ReminderStage(
                    kind: .morningOf,
                    offset: .morningOf(TimeOfDay(hour: 8)),
                    message: "You have a dentist call today."
                ),
                ReminderStage(
                    kind: .finalCall,
                    offset: .beforeAnchor(TimeSpan.minutes(10)),
                    message: "In ten minutes.",
                    requiresConfirmation: true
                ),
            ],
            createdAt: Self.referenceDate,
            generatedBy: "test"
        )
        try await repositories.reminderPlans.save(plan)

        var profile = try await repositories.profile.profile()
        profile.displayName = "Sam"
        profile.wakeTime = TimeOfDay(hour: 6, minute: 30)
        try await repositories.profile.update(profile)

        var settings = try await repositories.settings.settings()
        settings.preferredProviderID = "remote.openai-compatible"
        settings.memoryContextLimit = 15
        try await repositories.settings.update(settings)

        // Steps 7–8. Close the app.
        try relaunch()

        // Step 9. Everything is still there.
        let reloadedTask = try await repositories.tasks.task(id: task.id)
        XCTAssertEqual(reloadedTask, task)

        let reloadedMemory = try await repositories.memories.item(id: memory.id)
        XCTAssertEqual(reloadedMemory, memory)

        let reloadedConversation = try await repositories.conversations
            .conversation(id: conversation.id)
        XCTAssertEqual(
            reloadedConversation?.messages.map(\.text),
            conversation.messages.map(\.text)
        )

        let reloadedPlan = try await repositories.reminderPlans.plan(id: plan.id)
        XCTAssertEqual(reloadedPlan, plan)

        let reloadedProfile = try await repositories.profile.profile()
        XCTAssertEqual(reloadedProfile.displayName, "Sam")
        XCTAssertEqual(reloadedProfile.wakeTime, TimeOfDay(hour: 6, minute: 30))

        let reloadedSettings = try await repositories.settings.settings()
        XCTAssertEqual(reloadedSettings.preferredProviderID, "remote.openai-compatible")
        XCTAssertEqual(reloadedSettings.memoryContextLimit, 15)
    }

    func testUpdatesSurviveARelaunch() async throws {
        var task = TaskItem(title: "Draft title", createdAt: Self.referenceDate)
        try await repositories.tasks.save(task)

        var memory = MemoryItem(kind: .fact, content: "original", createdAt: Self.referenceDate)
        try await repositories.memories.store(memory)

        try relaunch()

        task.title = "Call the dentist"
        task.status = .completed
        try await repositories.tasks.save(task)

        memory.content = "corrected"
        try await repositories.memories.store(memory)

        try relaunch()

        let reloadedTask = try await repositories.tasks.task(id: task.id)
        XCTAssertEqual(reloadedTask?.title, "Call the dentist")
        XCTAssertEqual(reloadedTask?.status, .completed)

        let reloadedMemory = try await repositories.memories.item(id: memory.id)
        XCTAssertEqual(reloadedMemory?.content, "corrected")

        // Edits must overwrite. An insert-only implementation would pass every
        // assertion above and still be wrong.
        let allTasks = try await repositories.tasks.tasks(matching: TaskFilter())
        let allMemories = try await repositories.memories.all()
        XCTAssertEqual(allTasks.count, 1)
        XCTAssertEqual(allMemories.count, 1)
    }

    func testDeletesSurviveARelaunch() async throws {
        let task = TaskItem(title: "Temporary", createdAt: Self.referenceDate)
        let memory = MemoryItem(kind: .fact, content: "temporary", createdAt: Self.referenceDate)
        let conversation = Conversation(
            messages: [Message(role: .user, text: "hi", createdAt: Self.referenceDate)],
            createdAt: Self.referenceDate
        )

        try await repositories.tasks.save(task)
        try await repositories.memories.store(memory)
        try await repositories.conversations.save(conversation)

        try relaunch()

        try await repositories.tasks.delete(id: task.id)
        try await repositories.memories.delete(id: memory.id)
        try await repositories.conversations.delete(id: conversation.id)

        try relaunch()

        // A delete that only removed the row from an in-memory cache would let
        // all three of these come back.
        let reloadedTask = try await repositories.tasks.task(id: task.id)
        let reloadedMemory = try await repositories.memories.item(id: memory.id)
        let reloadedConversation = try await repositories.conversations
            .conversation(id: conversation.id)

        XCTAssertNil(reloadedTask)
        XCTAssertNil(reloadedMemory)
        XCTAssertNil(reloadedConversation)
    }

    /// Switching model does not touch user data.
    ///
    /// Providers are interchangeable reasoning engines. They do not own
    /// conversations, tasks, memories or the profile, and there is no
    /// per-provider store for any of it — so changing one identifier in
    /// settings must leave every byte of the rest alone.
    func testSwitchingProviderKeepsEveryPieceOfUserData() async throws {
        let task = TaskItem(title: "Call the dentist", createdAt: Self.referenceDate)
        let memory = MemoryItem(
            kind: .routine,
            content: "Thirty minutes to get ready",
            createdAt: Self.referenceDate
        )
        let conversation = Conversation(
            title: "Assistant",
            messages: [
                Message(role: .user, text: "hello", createdAt: Self.referenceDate),
                Message(
                    role: .assistant,
                    text: "hello back",
                    createdAt: Self.referenceDate.addingTimeInterval(1)
                ),
            ],
            createdAt: Self.referenceDate
        )
        try await repositories.tasks.save(task)
        try await repositories.memories.store(memory)
        try await repositories.conversations.save(conversation)

        var profile = try await repositories.profile.profile()
        profile.displayName = "Sam"
        try await repositories.profile.update(profile)

        // Remote, then relaunch, then something else, then relaunch again.
        for provider: AIProviderIdentifier in ["remote.openai-compatible", "dev.scripted"] {
            var settings = try await repositories.settings.settings()
            settings.preferredProviderID = provider
            try await repositories.settings.update(settings)

            try relaunch()

            let reloadedSettings = try await repositories.settings.settings()
            XCTAssertEqual(reloadedSettings.preferredProviderID, provider)

            let reloadedTask = try await repositories.tasks.task(id: task.id)
            XCTAssertEqual(reloadedTask, task)

            let reloadedMemory = try await repositories.memories.item(id: memory.id)
            XCTAssertEqual(reloadedMemory, memory)

            let reloadedProfile = try await repositories.profile.profile()
            XCTAssertEqual(reloadedProfile.displayName, "Sam")

            let reloadedConversation = try await repositories.conversations
                .conversation(id: conversation.id)
            XCTAssertEqual(reloadedConversation?.messages.map(\.text), ["hello", "hello back"])
        }
    }

    /// A store is one store, not one per provider.
    func testThereIsExactlyOneConversationAfterSwitchingProviders() async throws {
        let conversation = Conversation(title: "Only", createdAt: Self.referenceDate)
        try await repositories.conversations.save(conversation)

        for provider: AIProviderIdentifier in ["a", "b", "c"] {
            var settings = try await repositories.settings.settings()
            settings.preferredProviderID = provider
            try await repositories.settings.update(settings)
            try relaunch()
        }

        let all = try await repositories.conversations.allConversations()
        XCTAssertEqual(all.count, 1)
    }
}

#endif
