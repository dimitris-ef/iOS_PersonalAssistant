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
    /// "Superseded" / "Archived" / "Unresolved", or nil for a current memory.
    let lifecycleLabel: String?
    /// "Based on 3 similar memories", for a consolidated fact.
    let provenanceLabel: String?
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
                        // Dimmed rather than hidden. A memory the assistant has
                        // stopped using is still something the user told it, and
                        // it stays legible — it just stops looking current.
                        .foregroundStyle(memory.isRetrievable ? .primary : .secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    if let provenanceLabel {
                        Text(provenanceLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: Theme.Spacing.sm) {
                        Text(sourceLabel)
                            .font(.caption)
                            .foregroundStyle(.tertiary)

                        if let confidenceLabel {
                            badge(confidenceLabel)
                        }

                        if let lifecycleLabel {
                            badge(lifecycleLabel)
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

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.secondary.opacity(0.14)))
    }
}
