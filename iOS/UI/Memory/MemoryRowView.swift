import AssistantDomain
import SwiftUI

/// One remembered thing.
///
/// The provenance line ("You told me this" / "I worked this out from what you
/// do") matters: knowing *why* the assistant believes something is most of what
/// makes it trustworthy.
struct MemoryRowView: View {
    let memory: MemoryItem
    let symbol: String
    let sourceLabel: String
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: Theme.Spacing.md) {
                Image(systemName: symbol)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color(.tertiarySystemFill)))

                VStack(alignment: .leading, spacing: 3) {
                    Text(memory.content)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(sourceLabel)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, Theme.Spacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens for editing")
    }
}
