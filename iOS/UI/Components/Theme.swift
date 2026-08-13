import SwiftUI

/// Shared visual constants.
///
/// Colour deliberately comes from the system's semantic palette
/// (`.secondarySystemGroupedBackground`, `.secondary`, and the accent colour in
/// the asset catalogue) rather than hard-coded hex values. That is what makes
/// Light and Dark work without a parallel theme system, and what keeps the app
/// looking like it belongs on the platform.
///
/// Only spacing, radii and a couple of materials are defined here — the things
/// the system has no opinion about.
enum Theme {
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 28
    }

    enum Radius {
        static let small: CGFloat = 10
        static let medium: CGFloat = 14
        static let large: CGFloat = 18
        static let card: CGFloat = 20
    }

    /// Minimum comfortable hit area.
    static let touchTarget: CGFloat = 44

    /// The standard animation. Short, and no bounce.
    static let transition: Animation = .easeInOut(duration: 0.22)
    static let quickTransition: Animation = .easeInOut(duration: 0.15)
}

/// The standard raised surface: a grouped-background card with a soft corner.
struct CardSurface: ViewModifier {
    var padding: CGFloat = Theme.Spacing.lg
    var cornerRadius: CGFloat = Theme.Radius.card

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
    }
}

extension View {
    func cardSurface(
        padding: CGFloat = Theme.Spacing.lg,
        cornerRadius: CGFloat = Theme.Radius.card
    ) -> some View {
        modifier(CardSurface(padding: padding, cornerRadius: cornerRadius))
    }
}

/// A small caption above a group of content.
struct SectionHeading: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .kerning(0.4)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A quiet label used for categories and states.
struct MetaLabel: View {
    let text: String
    var systemImage: String?
    var tint: Color = .secondary

    var body: some View {
        Label {
            Text(text)
        } icon: {
            if let systemImage {
                Image(systemName: systemImage)
            }
        }
        .font(.caption)
        .foregroundStyle(tint)
        .labelStyle(.titleAndIcon)
    }
}
