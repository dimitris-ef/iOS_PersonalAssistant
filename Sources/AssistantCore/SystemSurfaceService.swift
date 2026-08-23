import AssistantDomain
import AssistantPersistence
import AssistantPlatform
import ExecutiveSupport
import Foundation
import SystemSurfaces

/// Asks WidgetKit to rebuild a timeline.
///
/// A protocol because `WidgetCenter` is iOS-only and because section 36 asks
/// for restraint that is worth being able to assert: a test can count the
/// reloads a change produced, which is the only way to notice that saving a
/// task reloads three widgets when one of them did not change.
public protocol SystemSurfaceReloader: Sendable {
    /// Reload one widget kind. Section 76 prefers this over reloading all.
    func reload(_ kind: SystemSurfaceWidgetKind)
}

/// Does nothing, for tests and for a build with no widget extension.
public struct SilentSystemSurfaceReloader: SystemSurfaceReloader {
    public init() {}
    public func reload(_ kind: SystemSurfaceWidgetKind) {}
}

/// Starts, updates and ends Live Activities.
///
/// The one seam between the domain and ActivityKit. Everything above it deals
/// in `LiveActivityDescriptor`, which is plain `Codable` data; the
/// implementation in the iOS layer is the only place `import ActivityKit`
/// appears outside the widget extension.
public protocol LiveActivityCoordinator: Sendable {
    /// Whether the system will accept an activity at all — the user can switch
    /// Live Activities off entirely, and section 84 says that must be a
    /// non-event for everything else.
    var isAvailable: Bool { get async }
    /// Start one, returning the system's identifier when it succeeds.
    func start(_ descriptor: LiveActivityDescriptor) async -> String?
    func update(_ descriptor: LiveActivityDescriptor) async
    /// End one. `finalContent` is what it shows while it lingers.
    func end(_ descriptor: LiveActivityDescriptor) async
    /// The identifiers the system says are running, for reconciliation.
    func runningActivityIDs() async -> Set<String>
}

/// A coordinator that records what it was asked to do.
///
/// Not a stub — it is what every Live Activity test asserts against, because
/// requesting a real activity needs a device, a Lock Screen and a person
/// looking at it (section 115).
public actor RecordingLiveActivityCoordinator: LiveActivityCoordinator {
    public enum Action: Hashable, Sendable {
        case start(UUID)
        case update(UUID)
        case end(UUID)
    }

    public private(set) var actions: [Action] = []
    public private(set) var content: [UUID: SupportActivityContent] = [:]
    private var running: Set<String> = []
    private let available: Bool

    public init(isAvailable: Bool = true) {
        self.available = isAvailable
    }

    public var isAvailable: Bool { available }

    public func start(_ descriptor: LiveActivityDescriptor) async -> String? {
        guard available else { return nil }
        actions.append(.start(descriptor.id))
        content[descriptor.id] = descriptor.content
        let identifier = "activity-\(descriptor.id.uuidString)"
        running.insert(identifier)
        return identifier
    }

    public func update(_ descriptor: LiveActivityDescriptor) async {
        actions.append(.update(descriptor.id))
        content[descriptor.id] = descriptor.content
    }

    public func end(_ descriptor: LiveActivityDescriptor) async {
        actions.append(.end(descriptor.id))
        if let identifier = descriptor.systemActivityID { running.remove(identifier) }
    }

    public func runningActivityIDs() async -> Set<String> { running }

    public func starts(for taskID: UUID) -> Int {
        actions.filter { $0 == .start(taskID) }.count
    }
}

/// What one refresh changed.
///
/// Counts, like `SupportReconciliationReport`. A widget refresh log naming what
/// the user is being reminded about would be the same privacy mistake in a new
/// place.
public struct SystemSurfaceRefreshReport: Hashable, Sendable {
    public var todayItems: Int
    public var reloadedKinds: [SystemSurfaceWidgetKind]
    public var activitiesStarted: Int
    public var activitiesUpdated: Int
    public var activitiesEnded: Int
    /// True when the shared container could not be written to.
    public var sharedStorageUnavailable: Bool

    public init(
        todayItems: Int = 0,
        reloadedKinds: [SystemSurfaceWidgetKind] = [],
        activitiesStarted: Int = 0,
        activitiesUpdated: Int = 0,
        activitiesEnded: Int = 0,
        sharedStorageUnavailable: Bool = false
    ) {
        self.todayItems = todayItems
        self.reloadedKinds = reloadedKinds
        self.activitiesStarted = activitiesStarted
        self.activitiesUpdated = activitiesUpdated
        self.activitiesEnded = activitiesEnded
        self.sharedStorageUnavailable = sharedStorageUnavailable
    }
}

/// Keeps every system surface in step with the application's own state.
///
/// ## Where this sits
///
/// Below the app, above the extensions, and downstream of everything that
/// decides anything:
///
///     repositories → briefing / ranker / planner → this → shared container
///                                                       → WidgetCenter
///                                                       → ActivityKit
///
/// The arrows only point one way. Nothing in a widget or a keyboard can make a
/// task change; they read what this wrote, or they send a command that enters
/// the same services the app's own buttons do.
///
/// ## Why refreshing is safe to fail
///
/// Section 85. Every failure path here is swallowed into the report rather than
/// thrown. A widget that did not update is a widget showing something slightly
/// old; a completion that threw because a widget could not be written is a task
/// the user believes they finished and did not. The second must never be
/// possible, so this is never in the failure path of anything that matters.
public actor SystemSurfaceService {
    private let repositories: AssistantRepositories
    private let store: any SystemSurfaceStore
    private let reloader: any SystemSurfaceReloader
    private let activities: (any LiveActivityCoordinator)?
    /// The calendar, when there is one. Optional because a widget refresh that
    /// fails outright when EventKit permission is off would be a worse failure
    /// than a Today snapshot with no events in it.
    private let calendarService: (any CalendarService)?
    private let builder: SystemSurfaceSnapshotBuilder
    private let policy: LiveActivityPresentationPolicy
    private let preparation: PreparationPlanner
    private let ranker: DailyPriorityRanker
    private let dateProvider: any DateProvider
    /// Whether the user wants Live Activities at all (section 89). Independent
    /// of ActivityKit's own authorization, which the coordinator checks.
    private var liveActivitiesEnabled: Bool

    public init(
        repositories: AssistantRepositories,
        store: any SystemSurfaceStore,
        reloader: any SystemSurfaceReloader = SilentSystemSurfaceReloader(),
        activities: (any LiveActivityCoordinator)? = nil,
        calendarService: (any CalendarService)? = nil,
        builder: SystemSurfaceSnapshotBuilder = SystemSurfaceSnapshotBuilder(),
        policy: LiveActivityPresentationPolicy = .default,
        preparation: PreparationPlanner = PreparationPlanner(),
        ranker: DailyPriorityRanker = DailyPriorityRanker(),
        dateProvider: any DateProvider = SystemDateProvider(),
        liveActivitiesEnabled: Bool = true
    ) {
        self.repositories = repositories
        self.store = store
        self.reloader = reloader
        self.activities = activities
        self.calendarService = calendarService
        self.builder = builder
        self.policy = policy
        self.preparation = preparation
        self.ranker = ranker
        self.dateProvider = dateProvider
        self.liveActivitiesEnabled = liveActivitiesEnabled
    }

    public func setLiveActivitiesEnabled(_ enabled: Bool) {
        liveActivitiesEnabled = enabled
    }

    /// Rebuilds every projection and brings the surfaces in line.
    ///
    /// Called after something meaningful changed (section 75) — a task created
    /// or completed, a reminder answered, a reconciliation pass, a routine
    /// occurrence appearing. Never on a read, and never on a timer.
    @discardableResult
    public func refresh(reason: SystemSurfaceRefreshReason = .domainChange) async -> SystemSurfaceRefreshReport {
        var report = SystemSurfaceRefreshReport()
        let now = dateProvider.now
        let calendar = dateProvider.calendar

        guard store.isAvailable else {
            report.sharedStorageUnavailable = true
            return report
        }

        do {
            let tasks = try await repositories.tasks.tasks(matching: TaskFilter())
            let plans = try await plans(for: tasks)
            let events = await todayEvents(on: now, calendar: calendar)

            let briefing = TodayBriefingBuilder(now: now, calendar: calendar, ranker: ranker)
                .build(tasks: tasks, events: events, reminderPlans: plans)
            let ranked = ranker.rank(tasks, now: now, calendar: calendar)

            let today = builder.todaySnapshot(from: briefing, now: now)
            let nextTask = builder.taskSnapshot(ranked: ranked, now: now)
            let support = builder.supportSnapshot(
                tasks: tasks, plans: plans, now: now, calendar: calendar
            )

            report.todayItems = today.items.count
            report.reloadedKinds = try writeIfChanged(
                today: today, nextTask: nextTask, support: support
            )
            for kind in report.reloadedKinds { reloader.reload(kind) }

            let activityReport = await synchronizeActivities(tasks: tasks, now: now)
            report.activitiesStarted = activityReport.started
            report.activitiesUpdated = activityReport.updated
            report.activitiesEnded = activityReport.ended
        } catch {
            // Nothing to report but the fact of it. See the note above about
            // why this cannot be allowed to propagate.
            report.sharedStorageUnavailable = !store.isAvailable
        }

        return report
    }

    /// Publishes the keyboard's configuration.
    ///
    /// Separate from `refresh` because it changes when a *setting* changes, not
    /// when a task does, and reloading widgets because someone toggled a
    /// keyboard switch would be exactly the wasted refresh section 36 asks to
    /// avoid.
    public func publishKeyboardConfiguration(assistantActionsEnabled: Bool) {
        guard store.isAvailable else { return }
        try? store.write(
            builder.keyboardConfiguration(
                assistantActionsEnabled: assistantActionsEnabled,
                now: dateProvider.now
            )
        )
    }

    // MARK: Snapshots

    /// Writes what changed, and reports which widgets that affects.
    ///
    /// The comparison is on the encoded value with the timestamps removed —
    /// `generatedAt` moves on every pass by definition, and a difference that
    /// is only the clock is not a reason to spend a WidgetKit refresh.
    private func writeIfChanged(
        today: TodaySnapshot,
        nextTask: TaskWidgetSnapshot,
        support: ReminderWidgetSnapshot
    ) throws -> [SystemSurfaceWidgetKind] {
        var reloaded: [SystemSurfaceWidgetKind] = []

        if hasChanged(today, comparedTo: try? store.read(TodaySnapshot.self)) {
            try store.write(today)
            reloaded.append(.today)
        }
        if hasChanged(nextTask, comparedTo: try? store.read(TaskWidgetSnapshot.self)) {
            try store.write(nextTask)
            reloaded.append(.nextTask)
        }
        if hasChanged(support, comparedTo: try? store.read(ReminderWidgetSnapshot.self)) {
            try store.write(support)
            reloaded.append(.support)
        }
        return reloaded
    }

    private func hasChanged<Snapshot: SystemSurfaceSnapshot>(
        _ snapshot: Snapshot,
        comparedTo existing: Snapshot?
    ) -> Bool {
        guard let existing else { return true }
        // Normalising through the timestamps is why this compares the *content*
        // rather than the value: two snapshots built a second apart are equal
        // in every way the user could see.
        return !SystemSurfaceComparison.isEquivalent(snapshot, existing)
    }

    // MARK: Live activities

    private struct ActivityReport {
        var started = 0
        var updated = 0
        var ended = 0
    }

    /// Brings the running activities in line with what the domain says.
    ///
    /// ## The reconciliation, and why it is here
    ///
    /// Sections 54 and 65. ActivityKit is not the source of truth and cannot be
    /// asked what a task's state is — it only knows what it was last told. So
    /// this recomputes the answer from the repositories every pass and diffs
    /// it against a registry the app persists.
    ///
    /// The three outcomes are exactly the three that matter: a task that should
    /// have an activity and does not gets one; a task that has one and still
    /// qualifies gets updated; a task that has one and no longer qualifies —
    /// completed, cancelled, or simply past — has it ended. That is the whole
    /// of the relaunch story, and it is why there is no second recovery path
    /// for Live Activities anywhere in the codebase.
    private func synchronizeActivities(
        tasks: [TaskItem],
        now: Date
    ) async -> ActivityReport {
        var report = ActivityReport()
        guard let activities, liveActivitiesEnabled else {
            await endEverything(&report)
            return report
        }
        guard await activities.isAvailable else {
            // Switched off at the system level. Section 84: not an error, and
            // not a reason for anything else to behave differently.
            return report
        }

        var registry = (try? store.read(LiveActivityRegistry.self))
            ?? LiveActivityRegistry(generatedAt: now)

        let candidates = tasks.compactMap { task in
            policy.candidate(
                for: task,
                timeline: preparation.timeline(for: task, now: now),
                now: now
            )
        }
        let chosen = policy.activities(for: candidates)
        let tasksByID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var next: [LiveActivityDescriptor] = []

        for candidate in chosen {
            guard let task = tasksByID[candidate.taskID] else { continue }
            let content = builder.activityContent(for: candidate, task: task)
            let staleAt = policy.staleDate(for: candidate, now: now)

            if var existing = registry.descriptor(for: candidate.taskID.rawValue) {
                // Already running. Update only when the content actually
                // differs — ActivityKit updates are visible and animated, and
                // one per refresh for identical content is a Lock Screen that
                // twitches.
                if existing.content != content {
                    existing.content = content
                    existing.staleAt = staleAt
                    await activities.update(existing)
                    report.updated += 1
                }
                next.append(existing)
            } else {
                var descriptor = LiveActivityDescriptor(
                    id: candidate.taskID.rawValue,
                    kind: builder.activityKind(for: candidate.reason),
                    content: content,
                    startedAt: now,
                    staleAt: staleAt
                )
                descriptor.systemActivityID = await activities.start(descriptor)
                // A nil identifier means the system refused — Live Activities
                // off, or the budget reached. Not recorded as running, so the
                // next pass tries again rather than believing in an activity
                // that does not exist.
                if descriptor.systemActivityID != nil {
                    report.started += 1
                    next.append(descriptor)
                }
            }
        }

        let keeping = Set(next.map(\.id))
        for stale in registry.activities where !keeping.contains(stale.id) {
            await activities.end(stale)
            report.ended += 1
        }

        registry.activities = next
        registry.generatedAt = now
        try? store.write(registry)
        return report
    }

    /// Ends everything, for when the feature is switched off.
    private func endEverything(_ report: inout ActivityReport) async {
        guard let activities else { return }
        guard var registry = try? store.read(LiveActivityRegistry.self) else { return }
        for descriptor in registry.activities {
            await activities.end(descriptor)
            report.ended += 1
        }
        registry.activities = []
        registry.generatedAt = dateProvider.now
        try? store.write(registry)
    }

    // MARK: Loading

    private func plans(for tasks: [TaskItem]) async throws -> [ReminderPlan] {
        var plans: [ReminderPlan] = []
        for task in tasks {
            guard
                let planID = task.reminderPlanID,
                let plan = try await repositories.reminderPlans.plan(id: planID)
            else { continue }
            plans.append(plan)
        }
        return plans
    }

    /// Today's calendar events, when the platform can supply them.
    ///
    /// Best-effort on purpose: a widget missing a calendar entry because
    /// EventKit permission is off is a smaller failure than a refresh that
    /// throws and leaves every snapshot stale. The `try?` is the whole policy.
    private func todayEvents(on date: Date, calendar: Calendar) async -> [CalendarItem] {
        guard let calendarService else { return [] }
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(TimeSpan.day)
        let window = TimeWindow(start: start, end: end)
        return (try? await calendarService.events(in: window)) ?? []
    }
}

/// Why a refresh happened. Recorded, never branched on.
public enum SystemSurfaceRefreshReason: String, Hashable, Sendable {
    case launch
    case foreground
    case domainChange
    case reconciliation
    case settingChanged
}

/// Compares snapshots ignoring the timestamps every rebuild moves.
enum SystemSurfaceComparison {
    static func isEquivalent<Snapshot: SystemSurfaceSnapshot>(
        _ first: Snapshot,
        _ second: Snapshot
    ) -> Bool {
        // Encoding both and comparing bytes would compare `generatedAt` too.
        // Comparing the *displayed* content is what matters, and each snapshot
        // type knows what that is.
        if let a = first as? TodaySnapshot, let b = second as? TodaySnapshot {
            return a.items == b.items && a.outstandingCount == b.outstandingCount
        }
        if let a = first as? TaskWidgetSnapshot, let b = second as? TaskWidgetSnapshot {
            return a.task == b.task && a.outstandingCount == b.outstandingCount
                && a.isBlocked == b.isBlocked
        }
        if let a = first as? ReminderWidgetSnapshot, let b = second as? ReminderWidgetSnapshot {
            return a.intervention == b.intervention && a.taskID == b.taskID
                && a.undeliverableCount == b.undeliverableCount
        }
        return false
    }
}
