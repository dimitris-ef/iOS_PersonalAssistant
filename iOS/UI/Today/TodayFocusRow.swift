import SwiftUI

/// One row of "what to do now".
///
/// ## Why this row is not the timeline row
///
/// The timeline answers *when*; this answers *what next*. They look similar and
/// mean different things, and the difference shows in what each row carries: a
/// timeline entry has a time and a category, a focus entry has a reason. "Waiting
/// on: collect the forms" is the whole value of the row — without it a blocked
/// task looks like any other task the user is failing to do, which is precisely
/// the misreading this product exists to stop.
struct TodayFocusRow: View {
    let item: TodayFocusItem
    let isLast: Bool
    let onOpen: () -> Void
    let onStart: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            glyph

            VStack(alignment: .leading, spacing: 3) {
                if let label = item.emphasis.label {
                    Text(label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(item.emphasis.tint)
                        .textCase(.uppercase)
                }

                Text(item.title)
                    .font(.body.weight(item.emphasis == .upNext ? .semibold : .regular))
                    // Blocked work is dimmed rather than hidden. Seeing that it
                    // is waiting is information; being nagged about it is not.
                    .foregroundStyle(item.isBlocked ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)

                if let detail = item.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }

                if let time = item.timeLabel {
                    Text(time)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 0)

            if item.canStart {
                Button(action: onStart) {
                    Text("Help me start")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .accessibilityHint("Gives you one small first step and marks this in progress.")
            }
        }
        .padding(.vertical, Theme.Spacing.md)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .overlay(alignment: .bottom) {
            if !isLast {
                Divider().padding(.leading, 24 + Theme.Spacing.md)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    private var glyph: some View {
        Image(systemName: item.emphasis.symbol)
            .font(.footnote)
            .foregroundStyle(item.emphasis.tint)
            .frame(width: 24, height: 24)
            .background(Circle().fill(item.emphasis.tint.opacity(0.12)))
            .accessibilityHidden(true)
    }

    private var accessibilityLabel: String {
        [item.emphasis.label, item.title, item.detail, item.timeLabel]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}
