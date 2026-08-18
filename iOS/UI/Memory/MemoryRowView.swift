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
    /// "Likely" / "Inferred", or nil when the app is confident. Nil is the
    /// common case, so most rows carry no badge and the list stays quiet.
    let confidenceLabel: String?
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

                    HStack(spacing: Theme.Spacing.sm) {
                        Text(sourceLabel)
                            .font(.caption)
                            .foregroundStyle(.tertiary)

                        if let confidenceLabel {
                            Text(confidenceLabel)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, Theme.Spacing.sm)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.secondary.opacity(0.14)))
                        }
                    }
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
