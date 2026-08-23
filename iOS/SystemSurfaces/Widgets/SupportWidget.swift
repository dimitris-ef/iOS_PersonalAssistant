import SwiftUI
import SystemSurfaces
import WidgetKit

/// The next thing the assistant is going to do for you.
///
/// Section 30's third widget, and the one that is genuinely this app rather
/// than a task list: "Leave at 9:20", "Start getting ready at 2:35". Part 8
/// decided all of it and Part 11 keeps it current; this shows the answer.
struct SupportWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: SystemSurfaceWidgetKind.support.rawValue,
            provider: SnapshotTimelineProvider<ReminderWidgetSnapshot>(
                placeholderSnapshot: ReminderWidgetSnapshot.placeholder(at:),
                transitions: { snapshot, now in
                    // One transition worth planning for: the moment the
                    // intervention is due, after which it is no longer "next".
                    [snapshot.intervention?.date].compactMap { $0 }.filter { $0 > now }
                }
            )
        ) { entry in
            SupportWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Support")
        .description("Leave times, preparation and follow-ups.")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .accessoryRectangular,
            .accessoryInline,
        ])
    }
}

struct SupportWidgetView: View {
    var entry: SurfaceEntry<ReminderWidgetSnapshot>
    @Environment(\.widgetFamily) private var family
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    private var intervention: TodaySnapshotItem? { entry.snapshot.intervention }

    var body: some View {
        switch family {
        case .accessoryInline:
            Text(inlineText)
        case .accessoryRectangular:
            rectangular
        default:
            standard
        }
    }

    private var standard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(heading)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            if let intervention {
                Text(intervention.privacySafeTitle)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                // Section 60: handed to the system as a date, so the countdown
                // moves without this app being woken every second.
                Text(intervention.date, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(entry.isPlaceholder ? "Open Personal Assistant to get started." : "Nothing waiting.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            // Told truthfully rather than hidden: a reminder that could not be
            // handed to iOS will not arrive, and a widget that stayed quiet
            // about it would be the app pretending otherwise.
            if entry.snapshot.undeliverableCount > 0 {
                Label(
                    "\(entry.snapshot.undeliverableCount) can't be delivered",
                    systemImage: "bell.slash"
                )
                .font(.caption2)
                .foregroundStyle(.orange)
                .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(destination.url)
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let intervention {
                Text(shouldRedact ? TodaySnapshotItem.redactedTitle : intervention.privacySafeTitle)
                    .font(.headline)
                    .lineLimit(1)
                Text(intervention.date, style: .time)
                    .font(.caption)
            } else {
                Text("Nothing waiting")
                    .font(.headline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(destination.url)
    }

    private var heading: String {
        switch intervention?.kind {
        case .leave: return "Leave"
        case .preparation: return "Get ready"
        default: return "Next"
        }
    }

    private var inlineText: String {
        guard let intervention else { return "Nothing waiting" }
        let title = shouldRedact ? TodaySnapshotItem.redactedTitle : intervention.privacySafeTitle
        return "\(heading): \(title)"
    }

    private var shouldRedact: Bool { isLuminanceReduced }

    private var destination: SystemSurfaceDestination {
        entry.snapshot.taskID.map { .task($0) } ?? .today
    }
}

// TODO-XCODE: never rendered.
#Preview(as: .systemSmall) {
    SupportWidget()
} timeline: {
    SurfaceEntry(
        date: .now,
        snapshot: ReminderWidgetSnapshot(
            generatedAt: .now,
            intervention: TodaySnapshotItem(
                id: "preview",
                taskID: UUID(),
                title: "Leave for the dentist",
                date: .now.addingTimeInterval(1_200),
                kind: .leave,
                emphasis: .startNow
            ),
            taskID: UUID()
        )
    )
}
