import AssistantDomain
import AssistantPlatform
import Foundation

#if canImport(EventKit)

/// The user's real calendar.
///
/// Thin on purpose. Every EventKit call lives in `AppleEventKitStore`, because
/// EventKit's objects are non-Sendable classes and confining them to one actor
/// is the only way two services can share one store safely. What is left here
/// is the protocol conformance and the honest `fidelity`.
///
/// `fidelity` is `.live`, and that is not a formality. It travels through
/// `PlatformReceipt` into `ToolOutcome` and onto the action card the user
/// reads: until this milestone every card said *simulated*, and the value of
/// changing it is exactly that the app is now allowed to say the event is
/// real — because it is.
struct EventKitCalendarService: CalendarService {
    let platformName = "EventKit"
    let fidelity: PlatformFidelity = .live

    private let store: AppleEventKitStore

    init(store: AppleEventKitStore) {
        self.store = store
    }

    func createEvent(
        _ item: CalendarItem
    ) async throws -> (item: CalendarItem, receipt: PlatformReceipt) {
        try await store.createEvent(item)
    }

    func updateEvent(
        _ item: CalendarItem
    ) async throws -> (item: CalendarItem, receipt: PlatformReceipt) {
        try await store.updateEvent(item)
    }

    func deleteEvent(id: CalendarItem.ID) async throws -> PlatformReceipt {
        try await store.deleteEvent(id: id)
    }

    func event(id: CalendarItem.ID) async throws -> CalendarItem? {
        try await store.event(id: id)
    }

    func events(in window: TimeWindow) async throws -> [CalendarItem] {
        try await store.events(in: window)
    }
}

/// Apple's Reminders app, which is a different thing from this app's tasks.
///
/// Worth keeping straight, because the app has both. A `TaskItem` is something
/// the assistant is actively supporting — it has a status, a reminder plan, an
/// escalation history and a follow-up count. A `ReminderItem` is a line in
/// Apple's Reminders app, where the user's shared grocery list lives and where
/// they will look for something they told Siri last week.
///
/// The assistant writes there when the user asks it to, and it is a one-way
/// door: nothing here reads Apple's reminders back into the task lifecycle,
/// because a checkbox in another app is not evidence about whether someone
/// actually did the thing.
struct EventKitReminderService: ReminderService {
    let platformName = "EventKit Reminders"
    let fidelity: PlatformFidelity = .live

    private let store: AppleEventKitStore

    init(store: AppleEventKitStore) {
        self.store = store
    }

    func createReminder(
        _ item: ReminderItem
    ) async throws -> (item: ReminderItem, receipt: PlatformReceipt) {
        try await store.createReminder(item)
    }

    func completeReminder(id: ReminderItem.ID) async throws -> PlatformReceipt {
        try await store.completeReminder(id: id)
    }

    func reminders(includingCompleted: Bool) async throws -> [ReminderItem] {
        try await store.reminders(includingCompleted: includingCompleted)
    }
}
#endif
