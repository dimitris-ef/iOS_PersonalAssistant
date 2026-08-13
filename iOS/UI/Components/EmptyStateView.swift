import SwiftUI

/// A considered empty state.
///
/// Never "No data available" — an empty screen is still the assistant talking
/// to someone, so it says something true and offers the next step.
struct EmptyStateView<Action: View>: View {
    let systemImage: String
    let title: String
    let message: String
    @ViewBuilder var action: () -> Action

    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: systemImage)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.bottom, Theme.Spacing.xs)

            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)

            action()
                .padding(.top, Theme.Spacing.sm)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.xxl * 2)
        .padding(.horizontal, Theme.Spacing.xl)
        .accessibilityElement(children: .combine)
    }
}

extension EmptyStateView where Action == EmptyView {
    init(systemImage: String, title: String, message: String) {
        self.init(
            systemImage: systemImage,
            title: title,
            message: message,
            action: { EmptyView() }
        )
    }
}

#Preview("Empty states") {
    // TODO-XCODE: Verify SwiftUI preview.
    ScrollView {
        VStack(spacing: 0) {
            EmptyStateView(
                systemImage: "checklist",
                title: "No tasks",
                message: "Nothing waiting for you right now."
            )
            EmptyStateView(
                systemImage: "brain",
                title: "Nothing remembered yet",
                message: "Tell me something worth keeping and it'll show up here."
            )
        }
    }
    .background(Color(.systemGroupedBackground))
}
