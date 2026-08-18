import AssistantCore
import AssistantDomain
import AssistantPersistence
import AssistantPlatform
import AssistantTools
import ExecutiveSupport
import Foundation

/// Writes demo content into the repositories and platform services.
///
/// It goes through the same interfaces the app uses at runtime — the calendar
/// events are created through `CalendarService`, not injected behind its back —
/// so seeding exercises the real path and the mock platform log stays accurate.
struct DemoDataSeeder {
    struct Seeded {
        let conversation: Conversation
        let actionPlans: [ActionPlanID: AssistantActionPlan]
        let toolResults: [ActionPlanID: [ToolResult]]
    }

    let environment: AppEnvironment

    /// Seeds only if the store is empty, so a reload does not duplicate data.
    func seedIfNeeded() async throws -> Seeded {
        let existing = try await environment.repositories.conversations.allConversations()
        if let conversation = existing.first, !conversation.messages.isEmpty {
            return Seeded(conversation: conversation, actionPlans: [:], toolResults: [:])
        }
        return try await seed()
    }

    func reseed() async throws -> Seeded {
        for conversation in try await environment.repositories.conversations.allConversations() {
            try await environment.repositories.conversations.delete(id: conversation.id)
        }
        for task in try await environment.repositories.tasks.tasks(matching: TaskFilter()) {
            try await environment.repositories.tasks.delete(id: task.id)
        }
        for memory in try await environment.repositories.memories.all() {
            try await environment.repositories.memories.delete(id: memory.id)
        }

        // The mock calendar keeps its own store, so events have to be cleared
        // there too or a reset doubles them up.
        let window = TimeWindow(
            start: environment.dateProvider.now.addingTimeInterval(-TimeSpan.days(365)),
            end: environment.dateProvider.now.addingTimeInterval(TimeSpan.days(365))
        )
        for event in try await environment.services.calendar.events(in: window) {
            _ = try? await environment.services.calendar.deleteEvent(id: event.id)
        }

        // Reminder plans and action plans are left in place: neither repository
        // has a delete, and both become unreachable once the things that index
        // them are gone — reminder plans are only ever found through a task or
        // event id, action plans only through a conversation. On the SwiftData
        // backend the conversation delete above cascades to its action plans
        // anyway.
        return try await seed()
    }

    private func seed() async throws -> Seeded {
        let now = environment.dateProvider.now
        let calendar = environment.dateProvider.calendar
        let demo = DemoData.make(now: now, calendar: calendar)

        try await environment.repositories.profile.update(demo.profile)
        try await environment.repositories.settings.update(demo.settings)

        for task in demo.tasks {
            try await environment.repositories.tasks.save(task)
        }
        // Through the memory service like every other write. Seeded content is
        // the one place it would be tempting to skip — the fixtures are known
        // to be distinct — but a door only one caller is allowed to walk past
        // is not a door, and this seeder exists precisely to exercise the paths
        // the app really uses.
        for memory in demo.memories {
            try await environment.memory.remember(memory)
        }
        for plan in demo.reminderPlans {
            try await environment.repositories.reminderPlans.save(plan)
        }
        for event in demo.events {
            _ = try await environment.services.calendar.createEvent(event)
        }

        return try await seedConversation(demo: demo, now: now, calendar: calendar)
    }

    // MARK: Conversation

    /// Builds the opening conversation, including the structured results that
    /// sit beneath the assistant's replies.
    private func seedConversation(
        demo: DemoData,
        now: Date,
        calendar: Calendar
    ) async throws -> Seeded {
        guard
            let haircut = demo.events.first(where: { $0.id == demo.haircutEventID }),
            let haircutPlan = demo.reminderPlans.first(where: {
                $0.subject.reference == .calendarItem(demo.haircutEventID)
            }),
            let gettingReady = demo.memories.first(where: { $0.id == demo.gettingReadyMemoryID })
        else {
            let empty = Conversation(createdAt: now)
            try await environment.repositories.conversations.save(empty)
            return Seeded(conversation: empty, actionPlans: [:], toolResults: [:])
        }

        let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now

        let (eventPlan, eventResults) = makeEventTurn(
            event: haircut,
            plan: haircutPlan,
            now: now,
            calendar: calendar
        )
        let (memoryPlan, memoryResults) = makeMemoryTurn(memory: gettingReady, now: now)

        let messages: [Message] = [
            Message(
                role: .user,
                text: "I have a haircut Sunday at 10 PM.",
                createdAt: yesterday
            ),
            Message(
                role: .assistant,
                text: "Got it. I've added your haircut for Sunday at 10 PM, and I'll nudge you along the way.",
                createdAt: yesterday,
                actionPlanID: eventPlan.id
            ),
            Message(
                role: .user,
                text: "Remember that I normally need 45 minutes to get ready for work.",
                createdAt: yesterday.addingTimeInterval(TimeSpan.minutes(2)),
                actionPlanID: nil
            ),
            Message(
                role: .assistant,
                text: "Noted — I'll build that into your preparation reminders.",
                createdAt: yesterday.addingTimeInterval(TimeSpan.minutes(2)),
                actionPlanID: memoryPlan.id
            ),
        ]

        let conversation = Conversation(
            title: "Assistant",
            messages: messages,
            createdAt: yesterday,
            updatedAt: now
        )
        try await environment.repositories.conversations.save(conversation)

        // Through the repository, like everything else here. The seeded
        // transcript then reloads by exactly the path a real one does, so a
        // screenshot run is testing the restore, not a shortcut around it.
        for (plan, results) in [(eventPlan, eventResults), (memoryPlan, memoryResults)] {
            try await environment.repositories.actionPlans.save(
                ActionPlanRecord(plan: plan, results: results, conversationID: conversation.id)
            )
        }

        return Seeded(
            conversation: conversation,
            actionPlans: [eventPlan.id: eventPlan, memoryPlan.id: memoryPlan],
            toolResults: [eventPlan.id: eventResults, memoryPlan.id: memoryResults]
        )
    }

    /// The calendar turn: one model-requested event, plus the reminder stages
    /// the support planner added on the app's behalf.
    private func makeEventTurn(
        event: CalendarItem,
        plan: ReminderPlan,
        now: Date,
        calendar: Calendar
    ) -> (AssistantActionPlan, [ToolResult]) {
        let eventAction = AssistantAction(
            request: .createCalendarEvent(
                CreateCalendarEventInput(
                    eventID: event.id,
                    title: event.title,
                    start: event.start,
                    end: event.end,
                    location: event.location,
                    importance: event.importance,
                    travelDurationMinutes: minutes(event.travelDuration),
                    preparationDurationMinutes: minutes(event.preparationDuration)
                )
            ),
            origin: .model,
            authorization: .allowed
        )

        let resolver = ReminderScheduleResolver(calendar: calendar)
        let scheduled = resolver.resolve(plan: plan, now: now)

        let reminderActions = scheduled.map { reminder in
            AssistantAction(
                request: .scheduleNotification(
                    ScheduleNotificationInput(
                        title: reminder.title,
                        body: reminder.body,
                        fireDate: reminder.fireDate,
                        escalation: reminder.escalation,
                        requiresCompletionConfirmation: reminder.requiresConfirmation,
                        stageID: reminder.stageID
                    )
                ),
                origin: .supportPlanner,
                authorization: .allowed,
                rationale: "\(reminder.kind.rawValue) reminder for \(plan.subject.title)"
            )
        }

        let actionPlan = AssistantActionPlan(
            actions: [eventAction] + reminderActions,
            createdAt: now
        )

        var results: [ToolResult] = [
            ToolResult(
                actionID: eventAction.id,
                kind: .createCalendarEvent,
                outcome: .simulated(platform: "MockCalendar"),
                message: "Calendar event created: \(event.title)",
                producedAt: now
            )
        ]
        results.append(
            contentsOf: reminderActions.map { action in
                ToolResult(
                    actionID: action.id,
                    kind: .scheduleNotification,
                    outcome: .simulated(platform: "MockNotifications"),
                    message: "Notification scheduled",
                    producedAt: now
                )
            }
        )

        return (actionPlan, results)
    }

    private func makeMemoryTurn(
        memory: MemoryItem,
        now: Date
    ) -> (AssistantActionPlan, [ToolResult]) {
        let action = AssistantAction(
            request: .storeMemory(
                StoreMemoryInput(
                    content: memory.content,
                    kind: memory.kind,
                    tags: memory.tags,
                    salience: memory.salience
                )
            ),
            origin: .model,
            authorization: .allowed
        )

        let plan = AssistantActionPlan(actions: [action], createdAt: now)
        let result = ToolResult(
            actionID: action.id,
            kind: .storeMemory,
            outcome: .executed,
            message: "Remembered: \(memory.content)",
            producedAt: now
        )
        return (plan, [result])
    }

    private func minutes(_ interval: TimeInterval?) -> Int? {
        interval.map { Int($0 / 60) }
    }
}
