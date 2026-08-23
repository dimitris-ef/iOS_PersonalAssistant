import AssistantDomain
import ExecutiveSupport
import Foundation
import SystemSurfaces

/// Turns application state into the small values a widget or keyboard may see.
///
/// ## Why this is one type, in the package
///
/// Section 74. The alternative — each widget's timeline provider reaching into
/// whatever it needs — puts the decision "what is a widget allowed to know"
/// in as many places as there are surfaces, and every new surface is a fresh
/// chance to include one field too many. Here it is a single function whose
/// output type lists every field, so "does the Lock Screen see task notes" is
/// answered by reading one file.
///
/// Pure and synchronous: it takes already-loaded domain values and returns
/// projections. No repository, no clock of its own, no I/O. That is what makes
/// section 96's test — seed state, build a snapshot, assert on exactly what is
/// in it — a unit test.
///
/// ## What it never does
///
/// Recompute anything. `DailyPriorityRanker` already ranked, `PreparationPlanner`
/// already scheduled, `SupportPlanner` already decided what the next
/// intervention is. Section 6 and section 33: this copies their answers into a
/// smaller shape. If a widget looks wrong, the bug is upstream, and that is a
/// property worth preserving.
public struct SystemSurfaceSnapshotBuilder: Sendable {
    /// How many rows a Today snapshot carries.
    ///
    /// Section 128: widgets are glanceable. Even `systemLarge` shows a handful,
    /// and a snapshot with forty rows is thirty-five rows of the user's private
    /// task titles sitting in a shared container for no reason.
    public var maximumItems: Int

    public init(maximumItems: Int = 8) {
        self.maximumItems = max(1, maximumItems)
    }

    // MARK: Today

    /// The day, from a briefing the application already built.
    public func todaySnapshot(
        from briefing: TodayBriefing,
        now: Date
    ) -> TodaySnapshot {
        let ahead = briefing.items
            .filter { !$0.isDone }
            .sorted { $0.date < $1.date }

        let items = ahead.prefix(maximumItems).map(Self.item(from:))

        return TodaySnapshot(
            generatedAt: now,
            // Valid until the next thing happens: after that the widget is
            // showing a moment that has passed, and would rather be rebuilt.
            validUntil: ahead.first { $0.date > now }?.date,
            items: Array(items),
            outstandingCount: ahead.count
        )
    }

    // MARK: Next task

    /// The single highest-ranked actionable task.
    ///
    /// Takes the ranking as an argument rather than computing it. The ranker is
    /// `ExecutiveSupport`'s and its inputs are every task, not today's — see
    /// `TodayBriefingBuilder` for why. Duplicating that here would be the
    /// second implementation section 19 forbids.
    public func taskSnapshot(
        ranked: [RankedTask],
        now: Date
    ) -> TaskWidgetSnapshot {
        let outstanding = ranked.filter { $0.task.status.isOutstanding }
        let actionable = outstanding.first { !$0.isBlocked }
        let chosen = actionable ?? outstanding.first

        guard let chosen else {
            return TaskWidgetSnapshot(generatedAt: now)
        }

        return TaskWidgetSnapshot(
            generatedAt: now,
            validUntil: chosen.task.anchorDate.map { max($0, now) },
            task: TodaySnapshotItem(
                id: "task-\(chosen.task.id)",
                taskID: chosen.task.id.rawValue,
                title: chosen.task.title,
                date: chosen.task.anchorDate ?? now,
                kind: chosen.task.isRoutineOccurrence ? .routine : .task,
                emphasis: chosen.isBlocked ? .blocked : .upNext,
                isDone: false,
                detail: chosen.blocked?.summary,
                isSensitive: Self.isSensitive(chosen.task)
            ),
            outstandingCount: outstanding.count,
            isBlocked: chosen.isBlocked
        )
    }

    // MARK: Support

    /// The next executive-support intervention.
    ///
    /// Reads the plans that already exist. A stage's *message* is the sentence
    /// `SupportPlanner` wrote; nothing here composes a new one, because two
    /// places writing the assistant's voice is how the widget ends up saying
    /// something the app would not.
    public func supportSnapshot(
        tasks: [TaskItem],
        plans: [ReminderPlan],
        now: Date,
        calendar: Calendar
    ) -> ReminderWidgetSnapshot {
        let tasksByID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let resolver = ReminderScheduleResolver(calendar: calendar)

        var best: (reminder: ScheduledReminder, plan: ReminderPlan)?
        var undeliverable = 0

        for plan in plans {
            guard case .task(let taskID) = plan.subject.reference else { continue }
            guard let task = tasksByID[taskID], task.status.isOutstanding else { continue }

            undeliverable += plan.stages.filter { $0.state.isPending && $0.delivery.state == .unavailable }.count

            for reminder in resolver.resolve(plan: plan, now: now) {
                guard reminder.fireDate >= now else { continue }
                if best == nil || reminder.fireDate < best!.reminder.fireDate {
                    best = (reminder, plan)
                }
            }
        }

        guard let best, case .task(let taskID) = best.plan.subject.reference else {
            return ReminderWidgetSnapshot(generatedAt: now, undeliverableCount: undeliverable)
        }

        let task = tasksByID[taskID]
        return ReminderWidgetSnapshot(
            generatedAt: now,
            validUntil: best.reminder.fireDate,
            intervention: TodaySnapshotItem(
                id: "stage-\(best.reminder.stageID)",
                taskID: taskID.rawValue,
                title: best.reminder.body,
                date: best.reminder.fireDate,
                kind: Self.kind(for: best.reminder.kind),
                emphasis: best.reminder.kind == .leave ? .startNow : .none,
                isDone: false,
                detail: nil,
                isSensitive: task.map(Self.isSensitive) ?? false
            ),
            taskID: taskID.rawValue,
            undeliverableCount: undeliverable
        )
    }

    // MARK: Keyboard

    /// What the keyboard may offer.
    ///
    /// Reads one setting and nothing else. Section 8 and section 26 in one
    /// place: there is no provider identifier here, no endpoint, no key, and no
    /// way to add one without changing a type in `SystemSurfaces` that a test
    /// asserts the field list of.
    public func keyboardConfiguration(
        assistantActionsEnabled: Bool,
        now: Date
    ) -> KeyboardConfigurationSnapshot {
        KeyboardConfigurationSnapshot(
            generatedAt: now,
            assistantActionsEnabled: assistantActionsEnabled,
            operations: assistantActionsEnabled ? KeyboardAssistantOperation.allCases : []
        )
    }

    // MARK: Live activities

    /// The content state for one qualifying task.
    ///
    /// Section 49: the result is a plain `Codable` value. The ActivityKit type
    /// is built from it by one adapter in the iOS layer, which is why every
    /// assertion about what a Live Activity says can be made here.
    public func activityContent(
        for candidate: LiveActivityCandidate,
        task: TaskItem
    ) -> SupportActivityContent {
        SupportActivityContent(
            title: Self.isSensitive(task) ? TodaySnapshotItem.redactedTitle : task.title,
            phase: Self.phase(for: candidate.reason),
            targetDate: candidate.targetDate,
            // Section 67: the step, not the memory that produced its timing.
            nextStep: candidate.nextStep?.title,
            completedSteps: candidate.totalSteps > 0 ? candidate.completedSteps : nil,
            totalSteps: candidate.totalSteps > 0 ? candidate.totalSteps : nil
        )
    }

    public func activityKind(for reason: LiveActivityReason) -> SupportActivityKind {
        switch reason {
        case .preparing, .leaving: return .appointmentPreparation
        case .startSession: return .startSession
        case .deadline: return .deadline
        case .routineWindow: return .routineWindow
        }
    }

    // MARK: Translation

    private static func item(from item: TodayItem) -> TodaySnapshotItem {
        var taskID: UUID?
        if case .task(let id) = item.reference { taskID = id.rawValue }
        return TodaySnapshotItem(
            id: item.id,
            taskID: taskID,
            title: item.title,
            date: item.date,
            kind: kind(for: item.kind),
            emphasis: emphasis(for: item.emphasis),
            isDone: item.isDone,
            detail: item.detail,
            // Nothing in the domain marks a task private yet. Section 43 says
            // that when it does, this is the one place that has to change —
            // and until then Lock Screen content stays conservative by
            // `TodaySnapshotItem.privacySafeTitle` being what the accessory
            // views actually call.
            isSensitive: false
        )
    }

    private static func kind(for kind: TodayItem.Kind) -> SurfaceItemKind {
        switch kind {
        case .task: return .task
        case .event: return .event
        case .preparation: return .preparation
        case .leave: return .leave
        case .reminder: return .reminder
        case .routine: return .routine
        }
    }

    private static func kind(for kind: ReminderStageKind) -> SurfaceItemKind {
        switch kind {
        case .preparation: return .preparation
        case .leave: return .leave
        case .advanceNotice, .morningOf, .finalCall, .followUp, .nudge: return .reminder
        }
    }

    private static func emphasis(for emphasis: TodayItem.Emphasis) -> SurfaceEmphasis {
        switch emphasis {
        case .none: return .none
        case .upNext: return .upNext
        case .blocked: return .blocked
        case .recovery: return .recovery
        case .startNow: return .startNow
        case .behind: return .behind
        }
    }

    private static func phase(for reason: LiveActivityReason) -> SupportActivityPhase {
        switch reason {
        case .preparing: return .preparing
        case .leaving: return .leaving
        case .startSession: return .inProgress
        case .deadline, .routineWindow: return .waiting
        }
    }

    /// Whether a task's title should be withheld where others can see it.
    ///
    /// One function, so the answer is the same on the Lock Screen, in a Live
    /// Activity and in a widget. There is no privacy flag on `TaskItem` yet, so
    /// it is `false` — stated here rather than implied, because section 43's
    /// requirement is that when the flag arrives, exactly one place changes.
    private static func isSensitive(_ task: TaskItem) -> Bool { false }
}
