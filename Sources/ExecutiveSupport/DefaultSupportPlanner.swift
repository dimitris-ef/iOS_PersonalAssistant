import AssistantDomain
import Foundation

/// The first reminder strategy.
///
/// It is deliberately simple and entirely driven by ``SupportPreferences`` — no
/// stage lead time is hardcoded here. The shape it produces for a fixed
/// appointment is:
///
///   advance notice (N days before) → morning of → preparation → leave → final call
///
/// Flexible work with only a deadline gets spread-out nudges instead, because
/// leave-time and final-call stages are meaningless without a fixed moment.
public struct DefaultSupportPlanner: SupportPlanner {
    public let identifier = "default-support-planner.v1"

    /// Every timing decision this planner makes. Injected so tests can pin it
    /// and so nothing here reaches for a magic number.
    public let timing: FollowUpTiming

    public init(timing: FollowUpTiming = .default) {
        self.timing = timing
    }

    public func makePlan(
        for subject: ReminderSubject,
        context: SupportPlanningContext
    ) -> ReminderPlan {
        let stages: [ReminderStage]
        switch subject.anchor {
        case .moment(let date):
            stages = fixedTimeStages(for: subject, at: date, context: context)
        case .deadline(let date):
            stages = deadlineStages(for: subject, by: date, context: context)
        case .window(let window):
            stages = windowStages(for: subject, in: window, context: context)
        case .unscheduled:
            stages = []
        }

        return ReminderPlan(
            subject: subject,
            stages: stages.sorted { lead(of: $0) > lead(of: $1) },
            followUp: context.preferences.followUp,
            snooze: context.preferences.snooze,
            completion: context.preferences.completion,
            createdAt: context.now,
            generatedBy: identifier
        )
    }

    // MARK: Follow-up

    /// Decides whether the assistant takes another turn, and what it looks like.
    ///
    /// The order of the guards is the policy in miniature: resolved tasks end
    /// support, outcomes that already have a next step do not get a second one,
    /// and everything else gets exactly one new stage.
    public func nextIntervention(
        for task: TaskItem,
        plan: ReminderPlan,
        outcome: ReminderOutcome,
        context: SupportPlanningContext
    ) -> SupportIntervention? {
        // Resolved is resolved. This is the only clause that stops support
        // permanently, and it reads the task's own status rather than any
        // separate flag, so there is one answer to "are we done here".
        guard !task.status.isTerminal else { return nil }
        guard !outcome.resolvesTask else { return nil }

        switch outcome {
        case .completed, .cancelled:
            return nil

        case .delivered:
            // Delivery is not an outcome yet — the user has not had a chance to
            // respond. Scheduling a follow-up here would double every reminder.
            return nil

        case .snoozed(let until):
            let target = until ?? context.now.addingTimeInterval(plan.snooze.defaultDuration)
            return intervention(
                for: task,
                plan: plan,
                kind: .nudge,
                at: target,
                context: context,
                // Snoozing is a reasonable request, honoured at face value. It
                // does not escalate on its own — the status machine raises the
                // level once someone has snoozed repeatedly.
                escalation: plan.subject.importance >= .high
                    ? context.preferences.defaultEscalation
                    : .gentle,
                message: "Still to do: \(plan.subject.title).",
                rationale: "You asked to be reminded again."
            )

        case .dismissed:
            let attempt = task.followUpCount
            let delay = timing.delay(
                importance: plan.subject.importance,
                attempt: attempt,
                deadline: deadline(for: task, plan: plan),
                now: context.now
            )
            return intervention(
                for: task,
                plan: plan,
                kind: .followUp,
                at: context.now.addingTimeInterval(delay),
                context: context,
                escalation: timing.escalation(
                    importance: plan.subject.importance,
                    attempt: attempt,
                    base: context.preferences.defaultEscalation
                ),
                message: "Still open: \(plan.subject.title).",
                rationale: "You dismissed the last reminder without finishing this."
            )

        case .missed:
            // Silence is treated slightly more seriously than a dismissal: the
            // user did not even see it, so the same approach is unlikely to
            // work twice.
            let attempt = max(task.followUpCount, 1)
            let delay = timing.delay(
                importance: plan.subject.importance,
                attempt: attempt,
                deadline: deadline(for: task, plan: plan),
                now: context.now
            )
            return intervention(
                for: task,
                plan: plan,
                kind: .followUp,
                at: context.now.addingTimeInterval(delay),
                context: context,
                escalation: timing.escalation(
                    importance: plan.subject.importance,
                    attempt: attempt,
                    base: context.preferences.defaultEscalation
                ),
                message: "Still open: \(plan.subject.title).",
                rationale: "The last reminder went unanswered."
            )

        case .acknowledged:
            // "I'm doing it." Back off, but do not disappear — the whole point
            // is that intending to do something is not doing it.
            return intervention(
                for: task,
                plan: plan,
                kind: .followUp,
                at: context.now.addingTimeInterval(timing.inProgressCheckIn),
                context: context,
                escalation: .gentle,
                message: "Did you finish \(plan.subject.title)?",
                rationale: "Checking in on something you started."
            )
        }
    }

    /// Builds one stage, or nothing when an equivalent is already waiting.
    ///
    /// The duplicate check lives here rather than at each call site so no
    /// outcome can route around it.
    private func intervention(
        for task: TaskItem,
        plan: ReminderPlan,
        kind: ReminderStageKind,
        at date: Date,
        context: SupportPlanningContext,
        escalation: EscalationLevel,
        message: String,
        rationale: String
    ) -> SupportIntervention? {
        guard plan.followUp.isEnabled else { return nil }
        guard !plan.hasPendingStage(kind: kind, at: date) else { return nil }

        let stage = ReminderStage(
            kind: kind,
            // Absolute, because a follow-up is tied to when the last one failed
            // rather than to the task's anchor — which a flexible task may not
            // even have.
            offset: .absolute(date),
            channel: escalation >= .alarm ? .alarm : .notification,
            escalation: escalation,
            message: message,
            requiresConfirmation: timing.requiresConfirmation(
                attempt: task.followUpCount,
                importance: plan.subject.importance
            ),
            state: .pending,
            stateChangedAt: context.now,
            scheduledFor: date
        )
        return SupportIntervention(stage: stage, rationale: rationale)
    }

    /// The moment this task is actually due, if it has one.
    ///
    /// Checked against both the task and the plan's anchor, because a task can
    /// carry a deadline the plan's subject does not repeat.
    private func deadline(for task: TaskItem, plan: ReminderPlan) -> Date? {
        let candidates = [task.deadline, task.timing.anchorDate, plan.subject.anchor.date]
        return candidates.compactMap { $0 }.min()
    }

    // MARK: Fixed appointments

    private func fixedTimeStages(
        for subject: ReminderSubject,
        at anchor: Date,
        context: SupportPlanningContext
    ) -> [ReminderStage] {
        var stages: [ReminderStage] = []
        let preferences = context.preferences
        let title = subject.title

        // Advance notice, only where it still lands in the future and the thing
        // is important enough to be worth interrupting for.
        if subject.importance >= .normal {
            for days in preferences.advanceNoticeDays.sorted(by: >) {
                let fireDate = context.calendar.date(byAdding: .day, value: -days, to: anchor)
                let resolved = fireDate.map { preferences.morningOfTime.resolved(on: $0, calendar: context.calendar) }
                guard let resolved, resolved > context.now else { continue }
                stages.append(
                    ReminderStage(
                        kind: .advanceNotice,
                        offset: .daysBefore(days, at: preferences.morningOfTime),
                        escalation: .gentle,
                        message: "\(title) is in \(days) day\(days == 1 ? "" : "s")."
                    )
                )
            }
        }

        // Morning of.
        let morningOf = preferences.morningOfTime.resolved(on: anchor, calendar: context.calendar)
        if morningOf > context.now && morningOf < anchor {
            stages.append(
                ReminderStage(
                    kind: .morningOf,
                    offset: .morningOf(preferences.morningOfTime),
                    escalation: preferences.defaultEscalation,
                    message: "Today: \(title) at \(Self.timeString(anchor, calendar: context.calendar))."
                )
            )
        }

        let travel = subject.travelDuration ?? 0
        let preparation = subject.preparationDuration ?? profilePreparation(context)

        // "Start getting ready" — before travel time, not instead of it.
        let preparationLead = travel + preparation
        if preparationLead > 0 {
            stages.append(
                ReminderStage(
                    kind: .preparation,
                    offset: .beforeAnchor(preparationLead),
                    escalation: preferences.defaultEscalation,
                    message: "Start getting ready for \(title).",
                    requiresConfirmation: true
                )
            )
        }

        // "Leave now" — only meaningful when there is somewhere to travel to.
        if travel > 0 {
            stages.append(
                ReminderStage(
                    kind: .leave,
                    offset: .beforeAnchor(travel),
                    escalation: escalation(for: subject.importance, base: preferences.defaultEscalation),
                    message: "Leave now for \(title).",
                    requiresConfirmation: true
                )
            )
        }

        // Final call.
        stages.append(
            ReminderStage(
                kind: .finalCall,
                offset: .beforeAnchor(preferences.finalCallLead),
                escalation: escalation(for: subject.importance, base: preferences.defaultEscalation),
                message: "\(title) is starting.",
                requiresConfirmation: true
            )
        )

        return stages
    }

    // MARK: Deadlines and flexible windows

    private func deadlineStages(
        for subject: ReminderSubject,
        by deadline: Date,
        context: SupportPlanningContext
    ) -> [ReminderStage] {
        let window = TimeWindow(start: context.now, end: deadline)
        return windowStages(for: subject, in: window, context: context)
    }

    private func windowStages(
        for subject: ReminderSubject,
        in window: TimeWindow,
        context: SupportPlanningContext
    ) -> [ReminderStage] {
        let preferences = context.preferences
        let start = max(window.start, context.now)
        guard window.end > start else { return [] }

        let days = max(
            1,
            context.calendar.dateComponents([.day], from: start, to: window.end).day ?? 1
        )
        let nudgeCount = max(1, min(days * preferences.flexibleNudgesPerDay, 7))

        var stages: [ReminderStage] = []
        for index in 0..<nudgeCount {
            // Space nudges evenly across the window, ending before the deadline.
            let fraction = Double(index + 1) / Double(nudgeCount + 1)
            let secondsBeforeEnd = window.end.timeIntervalSince(start) * (1 - fraction)
            stages.append(
                ReminderStage(
                    kind: .nudge,
                    offset: .beforeAnchor(secondsBeforeEnd),
                    escalation: index == nudgeCount - 1 ? preferences.defaultEscalation : .gentle,
                    message: "Still open: \(subject.title).",
                    requiresConfirmation: true
                )
            )
        }

        stages.append(
            ReminderStage(
                kind: .finalCall,
                offset: .beforeAnchor(preferences.finalCallLead),
                escalation: escalation(for: subject.importance, base: preferences.defaultEscalation),
                message: "Last chance: \(subject.title).",
                requiresConfirmation: true
            )
        )
        return stages
    }

    // MARK: Helpers

    private func profilePreparation(_ context: SupportPlanningContext) -> TimeInterval {
        // The user's own stated preparation time wins over the generic default.
        context.profile.defaultPreparationDuration > 0
            ? context.profile.defaultPreparationDuration
            : context.preferences.preparationLeadDefault
    }

    private func escalation(for importance: Importance, base: EscalationLevel) -> EscalationLevel {
        switch importance {
        case .low: return .gentle
        case .normal: return base
        case .high: return base.escalated
        case .critical: return .alarm
        }
    }

    /// Sort key: how far ahead of the anchor a stage fires. Larger fires earlier.
    private func lead(of stage: ReminderStage) -> TimeInterval {
        switch stage.offset {
        case .beforeAnchor(let interval): return interval
        case .afterAnchor(let interval): return -interval
        case .daysBefore(let days, _): return Double(days) * TimeSpan.day
        case .morningOf: return TimeSpan.hours(12)
        case .absolute: return 0
        }
    }

    static func timeString(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
