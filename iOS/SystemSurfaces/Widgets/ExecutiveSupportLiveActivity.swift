import ActivityKit
import AppIntents
import SwiftUI
import SystemSurfaces
import WidgetKit

/// The Lock Screen and Dynamic Island presentation of an active support
/// session.
///
/// ## What this file is
///
/// Views. All of it. The decision about *whether* there is an activity is
/// `LiveActivityPresentationPolicy`'s; the decision about *what it says* is
/// `SystemSurfaceSnapshotBuilder`'s; both are in package targets with tests.
/// What is left here cannot be unit-tested and does not need to be — it is
/// which font, which corner, which two words fit.
///
/// ## Sections 57 and 58
///
/// Compact leading, compact trailing, minimal and expanded, all four, and all
/// four kept short. The expanded region shows what is happening, what is next
/// and when — three lines. Not the plan, not the step list, not the reasoning.
@available(iOS 16.2, *)
struct ExecutiveSupportLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ExecutiveSupportActivityAttributes.self) { context in
            LockScreenView(
                content: context.state.content,
                taskID: context.attributes.taskID
            )
            .activityBackgroundTint(Color.black.opacity(0.35))
            .activitySystemActionForegroundColor(.primary)
        } dynamicIsland: { context in
            let content = context.state.content
            return DynamicIsland {
                // Section 58's expanded example. Three regions, each one line.
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text(content.title).font(.caption).lineLimit(1)
                    } icon: {
                        Image(systemName: symbol(for: content.phase))
                    }
                    .foregroundStyle(.primary)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    countdown(for: content)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        if let step = content.nextStep {
                            Text("Next: \(step)")
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                        } else {
                            Text(content.phase.shortLabel)
                                .font(.subheadline.weight(.medium))
                        }
                        // Section 61: a small set, each routing through an
                        // App Intent into the existing services.
                        ActivityActions(taskID: context.attributes.taskID)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: symbol(for: content.phase))
                    .foregroundStyle(.primary)
            } compactTrailing: {
                countdown(for: content)
                    .font(.caption2.monospacedDigit())
            } minimal: {
                Image(systemName: symbol(for: content.phase))
            }
            .widgetURL(SystemSurfaceDestination.task(context.attributes.taskID).url)
        }
    }

    /// Section 60. A `Text` given a date counts down in the system's own
    /// rendering — no process of ours is woken, and nothing here runs a timer.
    /// Implementing this as "update ActivityKit every second from a suspended
    /// app" is both impossible and the thing section 60 forbids attempting.
    @ViewBuilder
    private func countdown(for content: SupportActivityContent) -> some View {
        if let target = content.targetDate {
            Text(timerInterval: Date.now...max(target, Date.now), countsDown: true)
        } else {
            Text(content.phase.shortLabel)
        }
    }

    private func symbol(for phase: SupportActivityPhase) -> String {
        switch phase {
        case .preparing: return "figure.walk.departure"
        case .leaving: return "arrow.right.circle.fill"
        case .inProgress: return "play.circle.fill"
        case .waiting: return "clock"
        case .finished: return "checkmark.circle.fill"
        }
    }
}

/// The Lock Screen presentation.
///
/// Section 59: this is what a device without a Dynamic Island shows, and it is
/// the primary presentation rather than a fallback. Live Activities do not
/// depend on the hardware; only the compact regions do.
@available(iOS 16.2, *)
struct LockScreenView: View {
    var content: SupportActivityContent
    var taskID: UUID

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(content.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let target = content.targetDate {
                    Text(timerInterval: Date.now...max(target, Date.now), countsDown: true)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 64, alignment: .trailing)
                }
            }

            if let step = content.nextStep {
                Text("Next: \(step)")
                    .font(.subheadline)
                    .lineLimit(1)
            } else {
                Text(content.phase.shortLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let done = content.completedSteps, let total = content.totalSteps, total > 0 {
                ProgressView(value: Double(done), total: Double(total))
                    .tint(.accentColor)
                    .accessibilityLabel("\(done) of \(total) steps done")
            }

            ActivityActions(taskID: taskID)
        }
        .padding()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(content.accessibilitySummary)
    }
}

/// The three buttons, wherever they appear.
///
/// Section 62, 63 and 64 in one view: Done completes through
/// `TaskStatusMachine`, Later does not, and "I'm doing it" does not. Each is an
/// App Intent that runs the same command service the widgets use.
@available(iOS 16.2, *)
struct ActivityActions: View {
    var taskID: UUID

    var body: some View {
        if #available(iOS 17.0, *) {
            HStack(spacing: 8) {
                Button(intent: CompleteTaskFromSurfaceIntent(taskID: taskID)) {
                    Label("Done", systemImage: "checkmark")
                }
                .accessibilityLabel("Mark done")

                Button(intent: StartTaskFromSurfaceIntent(taskID: taskID)) {
                    Label("On it", systemImage: "play")
                }
                .accessibilityLabel("I'm doing it")

                Button(intent: SnoozeTaskFromSurfaceIntent(taskID: taskID)) {
                    Label("Later", systemImage: "clock")
                }
                .accessibilityLabel("Remind me later")
            }
            .buttonStyle(.bordered)
            .font(.caption)
            .lineLimit(1)
        }
    }
}
