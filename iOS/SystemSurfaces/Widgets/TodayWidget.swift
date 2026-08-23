import SwiftUI
import SystemSurfaces
import WidgetKit

/// The day, at a glance.
///
/// Section 128, and the reason there is a limit on everything here: a widget is
/// looked at for about a second. Three rows that can be read in that second are
/// worth more than eight that cannot, and a widget nobody can read is a widget
/// nobody looks at.
struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: SystemSurfaceWidgetKind.today.rawValue,
            provider: SnapshotTimelineProvider<TodaySnapshot>(
                placeholderSnapshot: TodaySnapshot.placeholder(at:),
                transitions: { snapshot, now in
                    WidgetTimelinePlanner().entries(for: snapshot, now: now)
                        .map(\.date)
                        .filter { $0 > now }
                }
            )
        ) { entry in
            TodayWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Today")
        .description("What is next, and what is coming.")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .systemLarge,
            // Section 32: a Lock Screen variant, deliberately terse.
            .accessoryRectangular,
        ])
    }
}

struct TodayWidgetView: View {
    var entry: SurfaceEntry<TodaySnapshot>
    @Environment(\.widgetFamily) private var family
    /// Section 42. iOS sets this when the screen may be visible to somebody
    /// else — a locked device, or Always On. Honouring it is the difference
    /// between a helpful widget and one people take off their Lock Screen.
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    private var upcoming: [TodaySnapshotItem] {
        entry.snapshot.upcoming(at: entry.date)
    }

    private var visibleCount: Int {
        switch family {
        case .systemSmall, .accessoryRectangular: return 1
        case .systemMedium: return 3
        default: return 5
        }
    }

    var body: some View {
        switch family {
        case .accessoryRectangular:
            accessory
        default:
            standard
        }
    }

    private var standard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Up next")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            if upcoming.isEmpty {
                Text(entry.isPlaceholder ? "Open Personal Assistant to get started." : "Nothing left today.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(upcoming.prefix(visibleCount)) { item in
                    SurfaceRow(item: item, isRedacted: shouldRedact)
                }
                if upcoming.count > visibleCount {
                    Text("\(upcoming.count - visibleCount) more")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(SystemSurfaceDestination.today.url)
    }

    /// The Lock Screen shape: one line, monochrome, minimal.
    private var accessory: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let next = upcoming.first {
                Text(displayTitle(for: next))
                    .font(.headline)
                    .lineLimit(1)
                Text(next.date, style: .time)
                    .font(.caption)
                if upcoming.count > 1 {
                    Text("\(upcoming.count - 1) more")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Nothing left today")
                    .font(.headline)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(SystemSurfaceDestination.today.url)
    }

    /// Section 42 and 43: withhold the title where the screen is not the
    /// user's alone. The time stays — it is what makes the row useful — and
    /// the placeholder is deliberately bland rather than "Private", which
    /// advertises that there is something to hide.
    private var shouldRedact: Bool {
        family == .accessoryRectangular && isLuminanceReduced
    }

    private func displayTitle(for item: TodaySnapshotItem) -> String {
        shouldRedact ? TodaySnapshotItem.redactedTitle : item.privacySafeTitle
    }
}

/// One line of a widget.
struct SurfaceRow: View {
    var item: TodaySnapshotItem
    var isRedacted: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.caption2)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(isRedacted ? TodaySnapshotItem.redactedTitle : item.privacySafeTitle)
                    .font(.footnote.weight(item.emphasis == .upNext ? .semibold : .regular))
                    .lineLimit(1)
                if let detail = item.detail, !isRedacted {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Text(item.date, style: .time)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        // Section 126: the symbol carries meaning a sighted user reads at a
        // glance, so it is spelled out rather than left as an unlabelled image.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        let title = isRedacted ? TodaySnapshotItem.redactedTitle : item.privacySafeTitle
        var parts = [emphasisWord, title].compactMap { $0 }
        parts.append(item.date.formatted(date: .omitted, time: .shortened))
        return parts.joined(separator: ", ")
    }

    private var emphasisWord: String? {
        switch item.emphasis {
        case .none: return nil
        case .upNext: return "Up next"
        case .blocked: return "Blocked"
        case .recovery: return "Missed"
        case .startNow: return "Start now"
        case .behind: return "Running late"
        }
    }

    private var symbol: String {
        switch item.kind {
        case .task: return "circle"
        case .event: return "calendar"
        case .preparation: return "figure.walk.departure"
        case .leave: return "arrow.right.circle"
        case .reminder: return "bell"
        case .routine: return "repeat"
        }
    }

    private var tint: Color {
        switch item.emphasis {
        case .none: return .secondary
        case .upNext, .startNow: return .accentColor
        case .blocked: return .orange
        case .recovery, .behind: return .red
        }
    }
}

// Section 78: previews run on mock snapshots and never touch production
// SwiftData — there is none in this process to touch.
// TODO-XCODE: never rendered; this repository has no Xcode.
#Preview(as: .systemMedium) {
    TodayWidget()
} timeline: {
    SurfaceEntry(
        date: .now,
        snapshot: TodaySnapshot(
            generatedAt: .now,
            items: [
                TodaySnapshotItem(
                    id: "preview-1",
                    title: "Dentist",
                    date: .now.addingTimeInterval(3_600),
                    kind: .event,
                    emphasis: .upNext
                ),
                TodaySnapshotItem(
                    id: "preview-2",
                    title: "Leave",
                    date: .now.addingTimeInterval(2_400),
                    kind: .leave,
                    emphasis: .startNow
                ),
            ],
            outstandingCount: 4
        )
    )
}
