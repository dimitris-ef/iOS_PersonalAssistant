import AssistantDomain
import ExecutiveSupport
import Foundation
import SwiftUI

/// A reminder plan, resolved and shaped for display.
///
/// This is the model behind `ReminderTimelineView` — the component that answers
/// the question the whole support system exists to answer: *when will the
/// assistant help me remember this?*
struct ReminderPlanPresentation: Identifiable, Equatable {
    struct Stage: Identifiable, Equatable {
        let id: ReminderStage.ID
        let kind: ReminderStageKind
        let fireDate: Date
        /// "Thursday" / "Sunday · 10:00 AM" / "8:45 PM"
        let whenLabel: String
        /// "Early reminder" / "Start getting ready"
        let title: String
        let escalation: EscalationLevel
        let requiresConfirmation: Bool
        /// True once its moment has passed, so the timeline can dim it.
        let hasPassed: Bool
        /// What became of this reminder.
        ///
        /// Shown rather than inferred: "6:00 PM — dismissed, 7:00 PM —
        /// follow-up" is the difference between a user who understands why they
        /// are being reminded again and one who thinks the app is broken.
        let state: ReminderStageState

        /// The badge, or nil when there is nothing worth saying.
        ///
        /// A pending reminder needs no label — its time already says it.
        var stateLabel: String? {
            switch state {
            case .pending: return nil
            case .delivered: return "Delivered"
            case .acknowledged: return "You said you were on it"
            case .snoozed: return "Snoozed"
            case .dismissed: return "Dismissed"
            case .missed: return "Missed"
            case .cancelled: return "Cancelled"
            }
        }
    }

    let id: ReminderPlan.ID
    let subjectTitle: String
    /// "Sunday · 10:00 PM"
    let anchorLabel: String
    let anchorDate: Date?
    let stages: [Stage]
    let requiresExplicitConfirmation: Bool
    let followUpSummary: String?

    var isEmpty: Bool { stages.isEmpty }

    static func make(
        from plan: ReminderPlan,
        now: Date,
        calendar: Calendar,
        formatters: AppFormatters = .shared
    ) -> ReminderPlanPresentation {
        let resolver = ReminderScheduleResolver(calendar: calendar)
        // Resolve from the distant past so stages that have already fired are
        // still shown — the timeline is a record as well as a forecast.
        let resolved = resolver.resolve(plan: plan, now: .distantPast)

        let stateByStage = Dictionary(
            plan.stages.map { ($0.id, $0.state) },
            uniquingKeysWith: { first, _ in first }
        )

        let stages = resolved.map { reminder in
            Stage(
                id: reminder.stageID,
                kind: reminder.kind,
                fireDate: reminder.fireDate,
                whenLabel: whenLabel(
                    for: reminder,
                    anchor: plan.subject.anchor.date,
                    now: now,
                    calendar: calendar,
                    formatters: formatters
                ),
                title: title(for: reminder.kind),
                escalation: reminder.escalation,
                requiresConfirmation: reminder.requiresConfirmation,
                hasPassed: reminder.fireDate < now,
                state: stateByStage[reminder.stageID] ?? .pending
            )
        }

        return ReminderPlanPresentation(
            id: plan.id,
            subjectTitle: plan.subject.title,
            anchorLabel: plan.subject.anchor.date.map {
                formatters.relativeDayAndTime($0, now: now)
            } ?? "No fixed time",
            anchorDate: plan.subject.anchor.date,
            stages: stages,
            requiresExplicitConfirmation: plan.completion.requiresExplicitConfirmation,
            followUpSummary: followUpSummary(for: plan)
        )
    }

    /// Stages on the anchor day show a time; earlier stages show the day, since
    /// "8:45 PM" is meaningless three days out.
    private static func whenLabel(
        for reminder: ScheduledReminder,
        anchor: Date?,
        now: Date,
        calendar: Calendar,
        formatters: AppFormatters
    ) -> String {
        guard let anchor else {
            return formatters.relativeDayAndTime(reminder.fireDate, now: now)
        }
        if calendar.isDate(reminder.fireDate, inSameDayAs: anchor) {
            return formatters.time(reminder.fireDate)
        }
        return formatters.relativeDayAndTime(reminder.fireDate, now: now)
    }

    private static func title(for kind: ReminderStageKind) -> String {
        switch kind {
        case .advanceNotice: return "Early reminder"
        case .morningOf: return "Same-day reminder"
        case .preparation: return "Start getting ready"
        case .leave: return "Leave"
        case .finalCall: return "Final reminder"
        case .followUp: return "Follow-up"
        case .nudge: return "Nudge"
        }
    }

    private static func followUpSummary(for plan: ReminderPlan) -> String? {
        guard plan.followUp.isEnabled else { return nil }
        let hours = Int(plan.followUp.interval / 3600)
        let interval = hours >= 1 ? "\(hours)h" : "\(Int(plan.followUp.interval / 60))m"
        return "If you don't confirm, I'll check back after \(interval), up to \(plan.followUp.maximumFollowUps) times."
    }
}

/// Visual treatment for a stage kind.
///
/// Colour is used sparingly — a small dot and an icon — so a plan with five
/// stages still reads calmly.
enum ReminderStageStyle {
    static func symbol(for kind: ReminderStageKind) -> String {
        switch kind {
        case .advanceNotice: return "calendar"
        case .morningOf: return "sun.horizon"
        case .preparation: return "hourglass"
        case .leave: return "figure.walk"
        case .finalCall: return "bell.badge"
        case .followUp: return "arrow.uturn.backward"
        case .nudge: return "bell"
        }
    }

    static func tint(for kind: ReminderStageKind) -> Color {
        switch kind {
        case .advanceNotice, .nudge: return .secondary
        case .morningOf: return .accentColor
        case .preparation: return .orange
        case .leave: return .pink
        case .finalCall: return .red
        case .followUp: return .purple
        }
    }
}
