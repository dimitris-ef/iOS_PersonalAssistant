import AssistantDomain
import Foundation

/// Turns a plan's relative stages into concrete, dated reminders.
///
/// Kept separate from planning so the two concerns stay testable apart:
/// planners decide *what* stages exist, the resolver decides *when* they land
/// and drops the ones that are already in the past.
public struct ReminderScheduleResolver: Sendable {
    private let calendar: Calendar

    public init(calendar: Calendar) {
        self.calendar = calendar
    }

    public func resolve(
        plan: ReminderPlan,
        now: Date,
        quietHours: DayWindow? = nil
    ) -> [ScheduledReminder] {
        guard let anchor = plan.subject.anchor.date else { return [] }

        var resolved: [ScheduledReminder] = []
        for stage in plan.stages {
            guard let rawDate = fireDate(for: stage, anchor: anchor) else { continue }
            let resolvedDate = adjustedForQuietHours(rawDate, quietHours: quietHours, stage: stage)
            // Silently dropping past stages is intended: a plan generated for an
            // event two hours from now should not fire its "three days before"
            // stage immediately.
            guard resolvedDate > now else { continue }

            resolved.append(
                ScheduledReminder(
                    planID: plan.id,
                    stageID: stage.id,
                    kind: stage.kind,
                    fireDate: resolvedDate,
                    channel: stage.channel,
                    title: plan.subject.title,
                    body: stage.message,
                    escalation: stage.escalation,
                    requiresConfirmation: stage.requiresConfirmation
                        || plan.completion.requiresExplicitConfirmation
                )
            )
        }

        return resolved.sorted { $0.fireDate < $1.fireDate }
    }

    public func fireDate(for stage: ReminderStage, anchor: Date) -> Date? {
        switch stage.offset {
        case .beforeAnchor(let interval):
            return anchor.addingTimeInterval(-interval)
        case .afterAnchor(let interval):
            return anchor.addingTimeInterval(interval)
        case .absolute(let date):
            return date
        case .morningOf(let time):
            return time.resolved(on: anchor, calendar: calendar)
        case .daysBefore(let days, let time):
            guard let day = calendar.date(byAdding: .day, value: -days, to: anchor) else { return nil }
            return time.resolved(on: day, calendar: calendar)
        }
    }

    /// Pushes a reminder out of quiet hours, unless it is urgent enough to
    /// justify waking the user — an alarm-level stage is exactly that case.
    private func adjustedForQuietHours(
        _ date: Date,
        quietHours: DayWindow?,
        stage: ReminderStage
    ) -> Date {
        guard let quietHours, stage.escalation < .alarm else { return date }

        let components = calendar.dateComponents([.hour, .minute], from: date)
        let time = TimeOfDay(hour: components.hour ?? 0, minute: components.minute ?? 0)
        guard quietHours.contains(time) else { return date }

        // Move to the end of the quiet window. If the window wraps midnight and
        // we are in its late-night part, that end is on the following day.
        let isAfterMidnightPortion = quietHours.start > quietHours.end && time <= quietHours.end
        let isLateNightPortion = quietHours.start > quietHours.end && time >= quietHours.start

        var target = quietHours.end.resolved(on: date, calendar: calendar)
        if isLateNightPortion, let nextDay = calendar.date(byAdding: .day, value: 1, to: date) {
            target = quietHours.end.resolved(on: nextDay, calendar: calendar)
        } else if !isAfterMidnightPortion && target < date {
            target = quietHours.end.resolved(on: date, calendar: calendar)
        }
        return target
    }
}
