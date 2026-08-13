import AssistantAI
import AssistantCore
import AssistantDomain
import AssistantPersistence
import AssistantPlatform
import AssistantTools
import ExecutiveSupport
import Foundation
import Observation

/// Application-wide state the screens share.
///
/// This is the presentation layer's view of the core: it loads from the
/// repositories and platform services, exposes plain values for SwiftUI to
/// render, and turns user intent back into calls on `AssistantEngine`. It holds
/// no business rules of its own — completing a task, dismissing a reminder and
/// planning reminders all happen in the core.
///
/// Per-screen state (filters, drafts, sheet routing) lives in the individual
/// view models, not here. Only genuinely shared things do.
@MainActor
@Observable
final class AppModel {
    // MARK: Shared state

    private(set) var conversation: Conversation
    private(set) var tasks: [TaskItem] = []
    private(set) var memories: [MemoryItem] = []
    private(set) var events: [CalendarItem] = []
    private(set) var reminderPlans: [ReminderPlan] = []
    private(set) var settings = AssistantSettings()
    private(set) var profile = UserProfile()
    private(set) var providerOptions: [ProviderOption] = []

    /// Action plans and results, keyed by plan, so the conversation can render
    /// what the assistant actually did beneath what it said.
    ///
    /// Held in memory only. The core does not persist action plans yet; when it
    /// does, this becomes a repository read.
    private(set) var actionPlans: [ActionPlanID: AssistantActionPlan] = [:]
    private(set) var toolResults: [ActionPlanID: [ToolResult]] = [:]

    /// True while a turn is in flight. Drives the typing indicator; never
    /// blocks the composer.
    private(set) var isAssistantResponding = false

    /// A reminder being simulated in-app. See `SimulatedReminder`.
    var simulatedReminder: SimulatedReminder?

    /// Transient confirmation text shown after an action.
    var banner: BannerMessage?

    private let environment: AppEnvironment

    var now: Date { environment.dateProvider.now }
    var calendar: Calendar { environment.dateProvider.calendar }

    init(environment: AppEnvironment) {
        self.environment = environment
        self.conversation = Conversation(createdAt: environment.dateProvider.now)
    }

    // MARK: Loading

    /// Seeds demo content on first launch and loads everything into memory.
    func bootstrap() async {
        do {
            let seeded = try await DemoDataSeeder(environment: environment).seedIfNeeded()
            conversation = seeded.conversation
            actionPlans = seeded.actionPlans
            toolResults = seeded.toolResults
            await reload()
            providerOptions = await environment.providerOptions()
        } catch {
            banner = BannerMessage(
                text: "Couldn't load demo data.",
                style: .warning
            )
        }
    }

    /// Re-reads everything the screens display.
    ///
    /// Deliberately coarse: the data set is small, and one refresh path is far
    /// easier to reason about than incremental invalidation.
    func reload() async {
        do {
            tasks = try await environment.repositories.tasks.tasks(matching: TaskFilter())
            memories = try await environment.repositories.memories.all()
            settings = try await environment.repositories.settings.settings()
            profile = try await environment.repositories.profile.profile()
            events = try await environment.services.calendar.events(
                in: TimeWindow(
                    start: calendar.startOfDay(for: now),
                    end: now.addingTimeInterval(TimeSpan.days(60))
                )
            )
            reminderPlans = try await loadReminderPlans()
        } catch {
            banner = BannerMessage(text: "Couldn't refresh.", style: .warning)
        }
    }

    private func loadReminderPlans() async throws -> [ReminderPlan] {
        var plans: [ReminderPlan] = []
        for task in tasks {
            guard let planID = task.reminderPlanID else { continue }
            if let plan = try await environment.repositories.reminderPlans.plan(id: planID) {
                plans.append(plan)
            }
        }
        for event in events {
            let found = try await environment.repositories.reminderPlans.plans(
                for: .calendarItem(event.id)
            )
            plans.append(contentsOf: found)
        }
        // Keep one entry per plan; a plan can be reachable from both sides.
        var unique: [ReminderPlan.ID: ReminderPlan] = [:]
        for plan in plans { unique[plan.id] = plan }
        return Array(unique.values)
    }

    // MARK: Lookups

    func task(id: TaskItem.ID) -> TaskItem? {
        tasks.first { $0.id == id }
    }

    func event(id: CalendarItem.ID) -> CalendarItem? {
        events.first { $0.id == id }
    }

    func memory(id: MemoryItem.ID) -> MemoryItem? {
        memories.first { $0.id == id }
    }

    func reminderPlan(id: ReminderPlan.ID) -> ReminderPlan? {
        reminderPlans.first { $0.id == id }
    }

    func reminderPlan(forEvent eventID: CalendarItem.ID) -> ReminderPlan? {
        reminderPlans.first { $0.subject.reference == .calendarItem(eventID) }
    }

    func reminderPlan(forTask taskID: TaskItem.ID) -> ReminderPlan? {
        reminderPlans.first { $0.subject.reference == .task(taskID) }
    }

    // MARK: Conversation

    /// Sends a message through the real turn pipeline.
    ///
    /// The provider behind it is the scripted development stand-in, so the
    /// *words* are canned — but the tool decoding, authorization, reminder
    /// planning and (simulated) execution around them are the production path.
    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isAssistantResponding else { return }

        isAssistantResponding = true
        defer { isAssistantResponding = false }

        do {
            let result = try await environment.engine.send(trimmed, in: conversation.id)
            conversation = result.conversation
            actionPlans[result.plan.id] = result.plan
            toolResults[result.plan.id] = result.results
            await reload()
        } catch {
            // Surfaced rather than swallowed: if no provider can answer, the
            // user should be told, not left with a silent composer.
            banner = BannerMessage(
                text: "The assistant couldn't respond right now.",
                style: .warning
            )
            isAssistantResponding = false
        }
    }

    // MARK: Tasks

    func completeTask(_ id: TaskItem.ID) async {
        await record(.confirmedComplete(at: now), for: id, banner: "Marked as done.")
    }

    func startTask(_ id: TaskItem.ID) async {
        await record(.startedWorking(at: now), for: id, banner: "Marked as in progress.")
    }

    func snoozeTask(_ id: TaskItem.ID, minutes: Int = 10) async {
        let until = now.addingTimeInterval(TimeSpan.minutes(Double(minutes)))
        await record(.snoozed(until: until), for: id, banner: "Snoozed for \(minutes) minutes.")
    }

    /// Records that a reminder was dismissed.
    ///
    /// The core decides what that means, and it never means "done". This is the
    /// single most important behaviour in the product, so the UI deliberately
    /// has no path that turns a dismissal into a completion.
    func dismissReminder(for id: TaskItem.ID) async {
        guard let updated = await applyEvent(.reminderDismissed(at: now), to: id) else { return }
        banner = BannerMessage(
            text: updated.status == .needsFollowUp
                ? "Dismissed — it's still not done, so I'll come back to it."
                : "Dismissed. Still on your list.",
            style: .neutral
        )
    }

    func reopenTask(_ id: TaskItem.ID) async {
        guard var task = task(id: id) else { return }
        task.status = .notStarted
        task.completedAt = nil
        task.updatedAt = now
        await save(task, banner: "Reopened.")
    }

    func updateTask(_ task: TaskItem) async {
        var updated = task
        updated.updatedAt = now
        await save(updated, banner: nil)
    }

    func deleteTask(_ id: TaskItem.ID) async {
        do {
            try await environment.repositories.tasks.delete(id: id)
            await reload()
            banner = BannerMessage(text: "Task deleted.", style: .neutral)
        } catch {
            banner = BannerMessage(text: "Couldn't delete that task.", style: .warning)
        }
    }

    private func record(
        _ event: EngagementEvent,
        for id: TaskItem.ID,
        banner text: String
    ) async {
        guard await applyEvent(event, to: id) != nil else { return }
        banner = BannerMessage(text: text, style: .success)
    }

    @discardableResult
    private func applyEvent(_ event: EngagementEvent, to id: TaskItem.ID) async -> TaskItem? {
        do {
            let updated = try await environment.engine.record(event, for: id)
            await reload()
            return updated
        } catch {
            banner = BannerMessage(text: "Couldn't update that task.", style: .warning)
            return nil
        }
    }

    private func save(_ task: TaskItem, banner text: String?) async {
        do {
            try await environment.repositories.tasks.save(task)
            await reload()
            if let text {
                banner = BannerMessage(text: text, style: .success)
            }
        } catch {
            banner = BannerMessage(text: "Couldn't save that task.", style: .warning)
        }
    }

    // MARK: Memory

    func addMemory(content: String, kind: MemoryKind) async {
        let item = MemoryItem(
            kind: kind,
            content: content.trimmingCharacters(in: .whitespacesAndNewlines),
            salience: 0.6,
            createdAt: now,
            source: .user
        )
        do {
            try await environment.repositories.memories.store(item)
            await reload()
            banner = BannerMessage(text: "I'll remember that.", style: .success)
        } catch {
            banner = BannerMessage(text: "Couldn't save that memory.", style: .warning)
        }
    }

    func updateMemory(_ memory: MemoryItem, content: String, kind: MemoryKind) async {
        var updated = memory
        updated.content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.kind = kind
        updated.updatedAt = now
        do {
            try await environment.repositories.memories.store(updated)
            await reload()
        } catch {
            banner = BannerMessage(text: "Couldn't update that memory.", style: .warning)
        }
    }

    func deleteMemory(_ id: MemoryItem.ID) async {
        do {
            try await environment.repositories.memories.delete(id: id)
            await reload()
            banner = BannerMessage(text: "Forgotten.", style: .neutral)
        } catch {
            banner = BannerMessage(text: "Couldn't delete that memory.", style: .warning)
        }
    }

    // MARK: Settings

    func updateSettings(_ transform: (inout AssistantSettings) -> Void) async {
        var updated = settings
        transform(&updated)
        do {
            try await environment.repositories.settings.update(updated)
            settings = updated
        } catch {
            banner = BannerMessage(text: "Couldn't save that setting.", style: .warning)
        }
    }

    /// Switching the model changes one settings field and nothing else.
    ///
    /// Conversations, memories, tasks, reminder plans and preferences all live
    /// in the repositories, which the provider never touches.
    func selectProvider(_ id: AIProviderIdentifier) async {
        await updateSettings { $0.preferredProviderID = id }
        banner = BannerMessage(
            text: "Model changed. Nothing else moved.",
            style: .neutral
        )
    }

    func updateProfile(_ transform: (inout UserProfile) -> Void) async {
        var updated = profile
        transform(&updated)
        do {
            try await environment.repositories.profile.update(updated)
            profile = updated
        } catch {
            banner = BannerMessage(text: "Couldn't save your profile.", style: .warning)
        }
    }

    // MARK: Simulated reminders

    /// Presents an in-app reminder so the response flow can be exercised.
    ///
    /// This is **not** an iOS notification. Nothing is scheduled with the
    /// system; the sheet is drawn by the app while it is in the foreground.
    /// Real delivery arrives with UserNotifications. TODO-XCODE.
    func simulateReminder(for reminder: SimulatedReminder) {
        simulatedReminder = reminder
    }

    func respondToSimulatedReminder(_ response: SimulatedReminderResponse) async {
        guard let reminder = simulatedReminder else { return }
        simulatedReminder = nil

        switch (response, reminder.subject) {
        case (.doingIt, .task(let id)):
            await startTask(id)
        case (.doingIt, .event):
            banner = BannerMessage(text: "Good — I'll stop nudging.", style: .success)
        case (.completed, .task(let id)):
            await completeTask(id)
        case (.completed, .event):
            banner = BannerMessage(text: "Marked as handled.", style: .success)
        case (.snooze, .task(let id)):
            await snoozeTask(id)
        case (.snooze, .event):
            banner = BannerMessage(text: "I'll remind you again shortly.", style: .neutral)
        case (.dismiss, .task(let id)):
            await dismissReminder(for: id)
        case (.dismiss, .event):
            banner = BannerMessage(
                text: "Dismissed. The event is still on your calendar.",
                style: .neutral
            )
        }
    }

    // MARK: Demo data

    func resetDemoData() async {
        do {
            let seeded = try await DemoDataSeeder(environment: environment).reseed()
            conversation = seeded.conversation
            actionPlans = seeded.actionPlans
            toolResults = seeded.toolResults
            await reload()
            banner = BannerMessage(text: "Demo data reset.", style: .neutral)
        } catch {
            banner = BannerMessage(text: "Couldn't reset demo data.", style: .warning)
        }
    }
}

/// A short confirmation shown after an action.
struct BannerMessage: Identifiable, Equatable {
    enum Style {
        case success
        case neutral
        case warning
    }

    let id = UUID()
    let text: String
    let style: Style
}
