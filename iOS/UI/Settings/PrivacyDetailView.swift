import SwiftUI

/// An explanation of one privacy topic.
///
/// Deliberately written about the app as it actually is today — including the
/// parts that are not built — rather than about the app as planned. A privacy
/// screen that describes intentions is worse than none.
struct PrivacyDetailView: View {
    let topic: PrivacyTopic

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                Image(systemName: topic.symbol)
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(Color.accentColor.opacity(0.12)))

                Text(topic.title)
                    .font(.title2.weight(.semibold))

                Text(topic.explanation)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Spacing.xl)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(topic.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    // TODO-XCODE: Verify SwiftUI preview.
    NavigationStack {
        PrivacyDetailView(topic: .personalMemory)
    }
}
