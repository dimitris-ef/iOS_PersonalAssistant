import AppIntents
import SwiftUI
import SystemSurfaces
import WidgetKit

/// The one thing worth doing now, with the three honest answers to it.
///
/// Section 30's second widget, and the one that carries the product's central
/// rule onto the Home Screen: Done, Later and "I'm doing it" are three
/// different buttons because they mean three different things.
struct NextTaskWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: SystemSurfaceWidgetKind.nextTask.rawValue,
            provider: SnapshotTimelineProvider<TaskWidgetSnapshot>(
                placeholderSnapshot: TaskWidgetSnapshot.placeholder(at:)
            )
        ) { entry in
            NextTaskWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Next Task")
        .description("The next thing you can actually start.")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            // Section 32's Lock Screen shapes.
            .accessoryRectangular,
            .accessoryCircular,
            .accessoryInline,
        ])
    }
}

struct NextTaskWidgetView: View {
    var entry: SurfaceEntry<TaskWidgetSnapshot>
    @Environment(\.widgetFamily) private var family
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    private var task: TodaySnapshotItem? { entry.snapshot.task }

    var body: some View {
        switch family {
        case .accessoryInline:
            Text(inlineText)
        case .accessoryCircular:
            circular
        case .accessoryRectangular:
            rectangular
        default:
            standard
        }
    }

    // MARK: Home Screen

    private var standard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let task {
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.privacySafeTitle)
                        .font(.headline)
                        .lineLimit(2)
                    if entry.snapshot.isBlocked, let detail = task.detail {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    } else {
                        Text(task.date, style: .time)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                // Section 38 and 21 of the acceptance criteria: interaction is
                // an App Intent, which is application logic, not a widget
                // reaching into a file.
                if let taskID = task.taskID, !entry.snapshot.isBlocked {
                    actions(for: taskID)
                }
            } else {
                Text(entry.isPlaceholder ? "Open Personal Assistant to get started." : "Nothing to start.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(destination.url)
    }

    @ViewBuilder
    private func actions(for taskID: UUID) -> some View {
        if #available(iOS 17.0, *) {
            HStack(spacing: 6) {
                Button(intent: CompleteTaskFromSurfaceIntent(taskID: taskID)) {
                    Label("Done", systemImage: "checkmark")
                        .labelStyle(.iconOnly)
                }
                .accessibilityLabel("Mark done")

                Button(intent: StartTaskFromSurfaceIntent(taskID: taskID)) {
                    Label("I'm doing it", systemImage: "play")
                        .labelStyle(.iconOnly)
                }
                .accessibilityLabel("I'm doing it")

                if family != .systemSmall {
                    Button(intent: SnoozeTaskFromSurfaceIntent(taskID: taskID)) {
                        Label("Later", systemImage: "clock")
                            .labelStyle(.iconOnly)
                    }
                    .accessibilityLabel("Remind me later")
                }
            }
            .buttonStyle(.bordered)
            .font(.caption)
        }
    }

    // MARK: Lock Screen

    /// Section 32's "Open Tasks — 3 important": a count, because a circular
    /// accessory has room for a number and not a title.
    private var circular: some View {
        VStack(spacing: 0) {
            Text("\(entry.snapshot.outstandingCount)")
                .font(.title2.bold())
            Text("open")
                .font(.caption2)
        }
        .accessibilityLabel("\(entry.snapshot.outstandingCount) open tasks")
        .widgetURL(destination.url)
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(lockScreenTitle)
                .font(.headline)
                .lineLimit(1)
            if let task, !shouldRedact {
                Text(task.date, style: .time)
                    .font(.caption)
            }
            if entry.snapshot.outstandingCount > 1 {
                Text("\(entry.snapshot.outstandingCount - 1) more")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(destination.url)
    }

    private var inlineText: String {
        guard let task else { return "Nothing to start" }
        return shouldRedact ? TodaySnapshotItem.redactedTitle : task.privacySafeTitle
    }

    private var lockScreenTitle: String {
        guard let task else { return "Nothing to start" }
        return shouldRedact ? TodaySnapshotItem.redactedTitle : task.privacySafeTitle
    }

    /// Section 42: on a locked or dimmed screen, the title is withheld.
    private var shouldRedact: Bool {
        isLuminanceReduced && family != .systemSmall && family != .systemMedium
    }

    /// Section 44: tapping opens the task, or the app when there is not one.
    private var destination: SystemSurfaceDestination {
        task?.taskID.map { .task($0) } ?? .today
    }
}

// TODO-XCODE: never rendered.
#Preview(as: .systemSmall) {
    NextTaskWidget()
} timeline: {
    SurfaceEntry(
        date: .now,
        snapshot: TaskWidgetSnapshot(
            generatedAt: .now,
            task: TodaySnapshotItem(
                id: "preview",
                taskID: UUID(),
                title: "Pay the electricity bill",
                date: .now.addingTimeInterval(5_400),
                kind: .task,
                emphasis: .upNext
            ),
            outstandingCount: 3
        )
    )
}
