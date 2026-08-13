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

    public init() {}

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
        case .daysBefore(let days, _): return Double(days) * Duration.day
        case .morningOf: return Duration.hours(12)
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
