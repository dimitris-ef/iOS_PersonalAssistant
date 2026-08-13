import SwiftUI

/// The one thing that matters most right now, given more weight than the rest
/// of the day.
///
/// The lead-in line — "Start getting ready in 1h 25m" — is the part that
/// actually helps: knowing when work starts is easy, knowing when to *begin*
/// is the hard bit.
struct UpNextCard: View {
    let item: UpNextItem
    let onOpen: () -> Void
    let onDone: () -> Void
    let onSnooze: () -> Void
    let onPreviewReminder: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                SectionHeading(text: "Up next")

                Text(item.title)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(item.timeLabel)
                    .font(.headline)
                    .foregroundStyle(.secondary)

                if let leadIn = item.leadInLabel {
                    Label(leadIn, systemImage: "hourglass")
                        .font(.subheadline)
                        .foregroundStyle(Color.accentColor)
                        .padding(.top, Theme.Spacing.xs)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)

            HStack(spacing: Theme.Spacing.sm) {
                if item.isTask {
                    Button(action: onDone) {
                        Label("Done", systemImage: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)

                    Button(action: onSnooze) {
                        Label("Snooze", systemImage: "moon.zzz")
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button(action: onPreviewReminder) {
                        Label("Preview reminder", systemImage: "bell")
                    }
                    .buttonStyle(.bordered)
                }

                Spacer(minLength: 0)

                Button("Details", action: onOpen)
                    .buttonStyle(.borderless)
            }
            .labelStyle(.titleAndIcon)
            .font(.subheadline)
        }
        .cardSurface(padding: Theme.Spacing.xl)
    }
}

#Preview("Up next") {
    // TODO-XCODE: Verify SwiftUI preview.
    UpNextCard(
        item: UpNextItem(
            title: "Work",
            timeLabel: "Today · 4:00 PM",
            date: Date().addingTimeInterval(3600 * 3),
            leadInLabel: "Start getting ready in 1h 25m",
            reference: .event(.init()),
            isTask: false
        ),
        onOpen: {},
        onDone: {},
        onSnooze: {},
        onPreviewReminder: {}
    )
    .padding()
    .background(Color(.systemGroupedBackground))
}
