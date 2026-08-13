import SwiftUI

/// One entry on the day's timeline.
///
/// Category is carried by a small tinted glyph and a quiet caption rather than
/// by colouring the whole row — a day with eight items should still read as one
/// calm list.
struct TodayTimelineRow: View {
    let item: TodayTimelineItem
    let isLast: Bool
    let onOpen: (() -> Void)?

    var body: some View {
        Button {
            onOpen?()
        } label: {
            HStack(alignment: .top, spacing: Theme.Spacing.md) {
                Text(AppFormatters.shared.time(item.date))
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(item.hasPassed ? .tertiary : .secondary)
                    .frame(width: 62, alignment: .leading)

                glyph

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.body)
                        .foregroundStyle(item.isDone ? .secondary : .primary)
                        .strikethrough(item.isDone, color: .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)

                    Text(item.kind.label)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 0)

                if onOpen != nil {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.quaternary)
                        .padding(.top, 2)
                }
            }
            .padding(.vertical, Theme.Spacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(onOpen == nil)
        .overlay(alignment: .bottom) {
            if !isLast {
                Divider().padding(.leading, 62 + Theme.Spacing.md + 24)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(AppFormatters.shared.time(item.date)), \(item.title), \(item.kind.label)"
        )
        .accessibilityAddTraits(onOpen != nil ? .isButton : [])
    }

    private var glyph: some View {
        Image(systemName: item.isDone ? "checkmark.circle.fill" : item.kind.symbol)
            .font(.footnote)
            .foregroundStyle(item.isDone ? Color.green : item.kind.tint)
            .frame(width: 24, height: 24)
            .background(
                Circle().fill(
                    (item.isDone ? Color.green : item.kind.tint).opacity(0.12)
                )
            )
            .opacity(item.hasPassed && !item.isDone ? 0.55 : 1)
            .accessibilityHidden(true)
    }
}
