import Foundation

/// Every string the app and its extensions have to agree on, in one file.
///
/// ## Why one file
///
/// An App Group identifier typed out in an entitlement, a widget kind typed out
/// in a timeline reload call, and a URL scheme typed out in a deep link are
/// three chances to make the same typo in three places that fail differently:
/// a container that silently resolves to nil, a reload that quietly matches
/// nothing, and a link that opens the App Store. None of them raises an error.
///
/// So they live here, are referenced everywhere else, and are asserted in
/// tests. The entitlement files still repeat the group identifier — a plist
/// cannot import Swift — and a test checks that they still agree.
public enum SystemSurfaceIdentifiers {
    /// The App Group both extensions and the app share.
    ///
    /// Derived from the app's bundle identifier, which is what makes it
    /// predictable rather than something to look up.
    public static let appGroup = "group.com.example.personalassistant"

    /// The bundle identifier prefix the extensions hang off.
    public static let bundlePrefix = "com.example.personalassistant"
    public static let keyboardBundleID = bundlePrefix + ".keyboard"
    public static let widgetsBundleID = bundlePrefix + ".widgets"

    /// The URL scheme the app registers, used by widget deep links.
    public static let urlScheme = "personalassistant"
}

/// The widgets this app publishes.
///
/// A `kind` is what `WidgetCenter.reloadTimelines(ofKind:)` matches on, so the
/// value here and the value in the widget's initialiser must be the same
/// string. Making it an enum means the compiler enforces that rather than the
/// user noticing their widget never updates.
public enum SystemSurfaceWidgetKind: String, Hashable, Sendable, CaseIterable {
    /// The day: what is next and what is coming.
    case today = "PersonalAssistantToday"
    /// One task — the highest-ranked thing that can actually be started now.
    case nextTask = "PersonalAssistantNextTask"
    /// The next executive-support intervention: leave time, preparation, a
    /// follow-up that is waiting.
    case support = "PersonalAssistantSupport"
}

/// Where tapping a system surface should land.
///
/// Built and parsed in one place so a widget cannot invent a URL the app does
/// not understand. Everything is expressed as a stable identifier plus a
/// destination — never a screen name or a navigation path, which are UI
/// details that would tie a widget to the current shape of the app.
public enum SystemSurfaceDestination: Hashable, Sendable {
    case today
    case assistant
    case task(UUID)

    private static let host = "open"

    public var url: URL {
        var components = URLComponents()
        components.scheme = SystemSurfaceIdentifiers.urlScheme
        components.host = Self.host
        switch self {
        case .today:
            components.path = "/today"
        case .assistant:
            components.path = "/assistant"
        case .task(let id):
            components.path = "/task"
            components.queryItems = [URLQueryItem(name: "id", value: id.uuidString)]
        }
        // The components above are all literals and a UUID, so this cannot
        // fail; the fallback exists so a URL is never optional at the call
        // site, where an optional would become a widget that silently does
        // nothing when tapped.
        return components.url ?? URL(string: SystemSurfaceIdentifiers.urlScheme + "://open/today")!
    }

    /// Reads a destination back, or nil when the URL is not one of ours.
    public static func parse(_ url: URL) -> SystemSurfaceDestination? {
        guard url.scheme == SystemSurfaceIdentifiers.urlScheme, url.host == host else {
            return nil
        }
        switch url.path {
        case "/today":
            return .today
        case "/assistant":
            return .assistant
        case "/task":
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            guard
                let raw = components?.queryItems?.first(where: { $0.name == "id" })?.value,
                let id = UUID(uuidString: raw)
            else { return nil }
            return .task(id)
        default:
            return nil
        }
    }
}
