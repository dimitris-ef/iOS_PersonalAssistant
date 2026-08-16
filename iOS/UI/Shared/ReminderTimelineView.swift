import AssistantDomain
import SwiftUI

/// The assistant's support plan, as a vertical timeline.
///
/// This component answers the question the whole executive-function system
/// exists to answer: *when will you help me remember this?* It is used inside
/// conversation cards, in event detail and in task detail, so a plan always
/// looks the same wherever it appears.
struct ReminderTimelineView: View {
    let plan: ReminderPlanPresentation
    /// Compact drops the stage descriptions, for use inside a conversation card.
    var isCompact: Bool = false
    /// Lets a stage be delivered as a simulated reminder, for testing the flow.
    var onSimulate: ((ReminderPlanPresentation.Stage) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(plan.stages.enumerated()), id: \.element.id) { index, stage in
                stageRow(
                    stage,
                    isFirst: index == 0,
                    isLast: index == plan.stages.count - 1 && anchorRow == nil
                )
            }

            if let anchor = anchorRow {
                anchorStageRow(anchor)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Reminder plan for \(plan.subjectTitle)")
    }

    // MARK: Rows

    private func stageRow(
        _ stage: ReminderPlanPresentation.Stage,
        isFirst: Bool,
        isLast: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            rail(
                tint: ReminderStageStyle.tint(for: stage.kind),
                symbol: ReminderStageStyle.symbol(for: stage.kind),
                isFirst: isFirst,
                isLast: isLast,
                isFilled: !stage.hasPassed
            )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Theme.Spacing.sm) {
                    Text(stage.whenLabel)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(stage.hasPassed ? .secondary : .primary)

                    // "6:00 PM — Dismissed" then "7:00 PM — Follow-up" is the
                    // whole story of an intervention, told without the user
                    // having to guess why they are hearing about this again.
                    if let label = stage.stateLabel {
                        Text(label)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, Theme.Spacing.sm)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.14)))
                    }
                }

                if !isCompact {
                    Text(stage.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, isLast ? 0 : Theme.Spacing.lg)

            Spacer(minLength: 0)

            if let onSimulate, !isCompact {
                Button {
                    onSimulate(stage)
                } label: {
                    Image(systemName: "play.circle")
                        .font(.body)
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .accessibilityLabel("Preview the \(stage.title) reminder")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            [stage.title, stage.whenLabel, stage.stateLabel]
                .compactMap { $0 }
                .joined(separator: ", ")
        )
    }

    /// The commitment itself, closing the timeline.
    private func anchorStageRow(_ label: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            rail(
                tint: .accentColor,
                symbol: "flag",
                isFirst: plan.stages.isEmpty,
                isLast: true,
                isFilled: true
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.subheadline.weight(.semibold))
                if !isCompact {
                    Text(plan.subjectTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var anchorRow: String? {
        guard plan.anchorDate != nil else { return nil }
        return plan.anchorLabel
    }

    // MARK: Rail

    /// The dot-and-line spine. Drawn rather than using a Divider so the line
    /// meets the dot exactly at every Dynamic Type size.
    private func rail(
        tint: Color,
        symbol: String,
        isFirst: Bool,
        isLast: Bool,
        isFilled: Bool
    ) -> some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color(.separator))
                .frame(width: 1, height: Theme.Spacing.xs)
                .opacity(isFirst ? 0 : 1)

            Image(systemName: symbol)
                .font(.caption)
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(isFilled ? tint : Color.secondary)
                .frame(width: 22, height: 22)
                .background(
                    Circle().fill(isFilled ? tint.opacity(0.14) : Color(.tertiarySystemFill))
                )

            Rectangle()
                .fill(Color(.separator))
                .frame(width: 1)
                .frame(maxHeight: .infinity)
                .opacity(isLast ? 0 : 1)
        }
        .frame(width: 22)
        .accessibilityHidden(true)
    }
}

#Preview("Reminder timeline") {
    // TODO-XCODE: Verify SwiftUI preview.
    let now = Date()
    let calendar = Calendar.current
    let anchor = calendar.date(byAdding: .day, value: 3, to: now) ?? now

    let plan = ReminderPlan(
        subject: ReminderSubject(
            reference: .freeform("preview"),
            title: "Haircut",
            anchor: .moment(anchor),
            preparationDuration: TimeSpan.minutes(45),
            travelDuration: TimeSpan.minutes(30)
        ),
        stages: [
            ReminderStage(kind: .advanceNotice, offset: .daysBefore(3, at: TimeOfDay(hour: 8)), message: "In three days"),
            ReminderStage(kind: .morningOf, offset: .morningOf(TimeOfDay(hour: 10)), message: "Today"),
            ReminderStage(kind: .preparation, offset: .beforeAnchor(TimeSpan.minutes(75)), message: "Get ready"),
            ReminderStage(kind: .leave, offset: .beforeAnchor(TimeSpan.minutes(30)), message: "Leave"),
        ],
        createdAt: now,
        generatedBy: "preview"
    )

    return ReminderTimelineView(
        plan: ReminderPlanPresentation.make(from: plan, now: now, calendar: calendar)
    )
    .padding()
}
