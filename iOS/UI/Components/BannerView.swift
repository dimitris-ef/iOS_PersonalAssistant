import SwiftUI

/// A short confirmation that appears after an action and clears itself.
///
/// Used instead of an alert because none of these need a decision — they only
/// need to be seen. It also carries the honest wording after a dismissal
/// ("still not done"), which is the one message the product cannot afford to
/// leave implicit.
struct BannerView: View {
    let message: BannerMessage

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: symbol)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(tint)

            Text(message.text)
                .font(.footnote)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06)))
        .padding(.horizontal, Theme.Spacing.lg)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch message.style {
        case .success: return "checkmark.circle.fill"
        case .neutral: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch message.style {
        case .success: return .green
        case .neutral: return .secondary
        case .warning: return .orange
        }
    }
}

/// Presents `AppModel.banner` above the tab bar and clears it after a moment.
struct BannerHost: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let banner = model.banner {
                BannerView(message: banner)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: banner.id) {
                        try? await Task.sleep(for: .seconds(3))
                        withAnimation(Theme.transition) {
                            if model.banner?.id == banner.id { model.banner = nil }
                        }
                    }
            }
        }
        .animation(Theme.transition, value: model.banner)
    }
}

extension View {
    func bannerHost() -> some View {
        modifier(BannerHost())
    }
}
