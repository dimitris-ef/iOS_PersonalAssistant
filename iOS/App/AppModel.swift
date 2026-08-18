import AIProviderRemote
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

    /// The remote provider's non-secret settings, mirrored for the UI.
    private(set) var remoteConfiguration = RemoteAIConfiguration()
    /// Whether an API key is stored. The key itself is never held here — the
    /// UI only ever needs to know that one exists.
    private(set) var hasRemoteAPIKey = false

    /// Action plans and results, keyed by plan, so the conversation can render
    /// what the assistant actually did beneath what it said.
    ///
    /// Read from `ActionPlanRepository` when a conversation loads, so the cards
    /// under a reply are still there after a relaunch.
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

    /// Opens the user's data and loads everything the screens display.
    ///
    /// A production launch reads whatever is in the store and writes nothing:
    /// a new user gets an empty conversation, an empty task list and no
    /// memories. Demo content is only ever written when the launch
    /// configuration asks for it, which happens in previews, in CI and in a
    /// developer's debug build — never in a shipped app. See
    /// `AppLaunchConfiguration`.
    func bootstrap() async {
        do {
            if environment.launch.seedsDemoData {
                _ = try await DemoDataSeeder(environment: environment).seedIfNeeded()
            }
            conversation = try await loadOrStartConversation()
            await reload()
            await refreshProviderState()
        } catch {
            banner = BannerMessage(text: "Couldn't load your data.", style: .warning)
        }
    }

    /// The conversation to show, and the action history beneath it.
    ///
    /// The most recently updated conversation is the one the user was last in.
    /// If there is none — a first launch — one is created and saved, so the
    /// first message has somewhere to go.
    private func loadOrStartConversation() async throws -> Conversation {
        let existing = try await environment.repositories.conversations.allConversations()

        guard let latest = existing.first else {
            actionPlans = [:]
            toolResults = [:]
            return try await environment.engine.startConversation(title: "Assistant")
        }

        try await loadActionHistory(for: latest.id)
        return latest
    }

    /// Rebuilds the cards shown under past assistant replies.
    ///
    /// Without this the transcript would come back as plain text: every
    /// `Message.actionPlanID` would point at a plan nothing had kept, and the
    /// event cards, reminder timelines and "simulated" badges would be gone
    /// with no sign that anything had been dropped.
    private func loadActionHistory(for conversationID: Conversation.ID) async throws {
        let records = try await environment.repositories.actionPlans.records(
            inConversation: conversationID
        )

        var plans: [ActionPlanID: AssistantActionPlan] = [:]
        var results: [ActionPlanID: [ToolResult]] = [:]
        for record in records {
            plans[record.plan.id] = record.plan
            results[record.plan.id] = record.results
        }
        actionPlans = plans
        toolResults = results
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

    /// Re-reads provider availability and the remote configuration.
    ///
    /// Called after anything that could change readiness, so the model selector
    /// never shows a stale "Setup needed".
    func refreshProviderState() async {
        remoteConfiguration = environment.remoteConfiguration.current
        hasRemoteAPIKey = await environment.hasRemoteAPIKey()
        providerOptions = await environment.providerOptions()
    }

    /// Saves the remote endpoint and model, and the key if one was entered.
    ///
    /// `apiKey` is `nil` when the user did not touch the field, which leaves any
    /// stored key alone; an empty string clears it.
    func saveRemoteConfiguration(baseURL: String, model: String, apiKey: String?) async {
        environment.remoteConfiguration.update(baseURL: baseURL, model: model)

        if let apiKey {
            do {
                try await environment.setRemoteAPIKey(apiKey.isEmpty ? nil : apiKey)
            } catch {
                banner = BannerMessage(
                    text: "Couldn't save the API key to the keychain.",
                    style: .warning
                )
            }
        }

        await refreshProviderState()
        banner = BannerMessage(text: "Remote AI settings saved.", style: .success)
    }

    func clearRemoteAPIKey() async {
        do {
            try await environment.setRemoteAPIKey(nil)
            await refreshProviderState()
            banner = BannerMessage(text: "API key removed.", style: .neutral)
        } catch {
            banner = BannerMessage(text: "Couldn't remove the API key.", style: .warning)
        }
    }

    /// The provider currently selected in settings, if it is one the user can
    /// choose. Used by the Assistant screen's notice.
    var selectedProviderOption: ProviderOption? {
        guard let id = settings.preferredProviderID else { return nil }
        return providerOptions.first { $0.id == id }
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
            // Surfaced rather than swallowed: if the provider cannot answer, the
            // user is told why, and the composer never sits in a silent
            // loading state.
            banner = BannerMessage(text: Self.describe(error), style: .warning)
        }
    }

    /// Turns a provider failure into a sentence worth reading.
    ///
    /// The remote layer has already mapped HTTP statuses and transport errors
    /// into explanations; this only unwraps them. No case can contain a
    /// credential — `RemoteAIError` never carries one.
    private static func describe(_ error: any Error) -> String {
        guard let providerError = error as? AIProviderError else {
            if error is CancellationError { return "Cancelled." }
            return "The assistant couldn't respond right now."
        }

        switch providerError {
        case .notImplemented(let detail), .unavailable(let detail):
            return detail
        case .missingCredentials(let detail):
            return detail
        case .modelNotFound(let id):
            return "The model \(id) isn't available."
        case .transport(let detail), .invalidResponse(let detail):
            return detail
        case .cancelled:
            return "Cancelled."
        }
    }

    // MARK: Tasks

    func completeTask(_ id: TaskItem.ID, stageID: ReminderStage.ID? = nil) async {
        await handle(.completed, for: id, stageID: stageID, fallback: "Marked as done.")
    }

    /// "I'm doing it."
    ///
    /// Explicitly not completion. It buys quiet — the planner moves the next
    /// check-in out rather than cancelling it — because intending to do
    /// something is not doing it, and that gap is the entire problem this app
    /// exists for.
    func startTask(_ id: TaskItem.ID, stageID: ReminderStage.ID? = nil) async {
        await handle(.acknowledged, for: id, stageID: stageID, fallback: "Marked as in progress.")
    }

    func snoozeTask(_ id: TaskItem.ID, minutes: Int = 10, stageID: ReminderStage.ID? = nil) async {
        let until = now.addingTimeInterval(TimeSpan.minutes(Double(minutes)))
        await handle(
            .snoozed(until: until),
            for: id,
            stageID: stageID,
            fallback: "Snoozed for \(minutes) minutes."
        )
    }

    /// Records that a reminder was dismissed.
    ///
    /// The core decides what that means, and it never means "done". This is the
    /// single most important behaviour in the product, so the UI deliberately
    /// has no path that turns a dismissal into a completion.
    func dismissReminder(for id: TaskItem.ID, stageID: ReminderStage.ID? = nil) async {
        await handle(
            .dismissed,
            for: id,
            stageID: stageID,
            fallback: "Dismissed. Still on your list."
        )
    }

    /// Brings pending reminders up to date with the clock.
    ///
    /// Called when the app becomes active. A reminder whose moment passed while
    /// the app was closed is missed, and missed means the assistant tries
    /// again — without this, closing the app would be a way to make support
    /// stop.
    func reconcileFollowUps() async {
        do {
            let results = try await environment.engine.followUp.reconcile()
            guard !results.isEmpty else { return }
            await reload()

            // Said out loud rather than silently rescheduling. Repeated
            // interventions the user cannot see or explain are how an assistant
            // becomes something to switch off.
            let titles = results.map(\.task.title)
            banner = BannerMessage(
                text: titles.count == 1
                    ? "You missed a reminder for \(titles[0]) — I've scheduled another."
                    : "You missed \(titles.count) reminders — I've scheduled follow-ups.",
                style: .neutral
            )
        } catch {
            // Reconciliation is a background correction, not something the user
            // asked for. Failing it quietly is better than an alarming banner
            // about an operation they did not initiate.
        }
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

    /// The one route from a button to the support lifecycle.
    ///
    /// Every task action in the UI goes through here, which is what stops a new
    /// screen from quietly inventing its own idea of what "dismiss" means. The
    /// banner prefers the planner's own rationale — "You dismissed the last
    /// reminder without finishing this" — over a generic confirmation, so the
    /// user can see why another reminder exists.
    private func handle(
        _ outcome: ReminderOutcome,
        for id: TaskItem.ID,
        stageID: ReminderStage.ID?,
        fallback: String
    ) async {
        do {
            let result = try await environment.engine.followUp.handle(
                outcome: outcome,
                forTask: id,
                stageID: stageID
            )
            await reload()

            guard result.didChange else { return }
            banner = BannerMessage(
                text: message(for: result, fallback: fallback),
                style: outcome.resolvesTask ? .success : .neutral
            )
        } catch {
            banner = BannerMessage(text: "Couldn't update that task.", style: .warning)
        }
    }

    private func message(for result: FollowUpResult, fallback: String) -> String {
        guard let next = result.nextReminder else {
            return result.rationale ?? fallback
        }
        let when = AppFormatters.shared.relativeDayAndTime(next.fireDate, now: now)
        return "\(fallback.hasSuffix(".") ? fallback : fallback + ".") I'll check back \(when)."
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

    /// Something the user typed into the Memory screen.
    ///
    /// Goes through `MemoryService` like everything else, so writing down what
    /// the assistant already knew updates that record rather than adding a
    /// second row saying the same thing. Source and confidence come from
    /// `.manual`, not from numbers chosen here.
    func addMemory(content: String, kind: MemoryKind) async {
        do {
            let result = try await environment.memory.remember(
                MemoryItem(
                    kind: kind,
                    content: content,
                    salience: 0.6,
                    createdAt: now,
                    source: .manual
                )
            )
            await reload()
            banner = BannerMessage(
                text: result.effect == .stored ? "I'll remember that." : result.summary,
                style: .success
            )
        } catch {
            banner = BannerMessage(text: "Couldn't save that memory.", style: .warning)
        }
    }

    /// An edit to a memory the user is looking at.
    ///
    /// Authoritative and never deduplicated — they are changing this exact
    /// record. Folding their edit into a similar memory would look, from their
    /// side, like the app refusing to save.
    func updateMemory(_ memory: MemoryItem, content: String, kind: MemoryKind) async {
        var updated = memory
        updated.content = content
        updated.kind = kind
        do {
            _ = try await environment.memory.update(updated)
            await reload()
        } catch {
            banner = BannerMessage(text: "Couldn't update that memory.", style: .warning)
        }
    }

    func deleteMemory(_ id: MemoryItem.ID) async {
        do {
            try await environment.memory.forget(id: id)
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
        await refreshProviderState()
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

        // The stage id travels with the answer, so the outcome lands on the
        // reminder that prompted it rather than on the task in general.
        let stageID = reminder.stageID

        switch (response, reminder.subject) {
        case (.doingIt, .task(let id)):
            await startTask(id, stageID: stageID)
        case (.doingIt, .event):
            banner = BannerMessage(text: "Good — I'll stop nudging.", style: .success)
        case (.completed, .task(let id)):
            await completeTask(id, stageID: stageID)
        case (.completed, .event):
            banner = BannerMessage(text: "Marked as handled.", style: .success)
        case (.snooze, .task(let id)):
            await snoozeTask(id, stageID: stageID)
        case (.snooze, .event):
            banner = BannerMessage(text: "I'll remind you again shortly.", style: .neutral)
        case (.dismiss, .task(let id)):
            await dismissReminder(for: id, stageID: stageID)
        case (.dismiss, .event):
            banner = BannerMessage(
                text: "Dismissed. The event is still on your calendar.",
                style: .neutral
            )
        }
    }

    // MARK: Demo data

    /// True when this launch is running on seeded, temporary storage.
    ///
    /// Drives whether the developer section appears at all. It reads the launch
    /// configuration rather than `#if DEBUG` directly, so a debug build opened
    /// normally — on the developer's own real data — is treated exactly like a
    /// user's.
    var isRunningOnDemoData: Bool { environment.launch.seedsDemoData }

    /// Rebuilds the demo dataset.
    ///
    /// Guarded, because this deletes conversations, tasks and memories before
    /// writing the fake ones. On a normal launch those would be the user's. The
    /// guard is the enforcement; hiding the button is only the courtesy.
    func resetDemoData() async {
        guard isRunningOnDemoData else {
            banner = BannerMessage(
                text: "Demo data isn't available on your own storage.",
                style: .warning
            )
            return
        }

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
