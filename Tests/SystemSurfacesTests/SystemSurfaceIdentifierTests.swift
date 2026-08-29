import Foundation
import XCTest

@testable import SystemSurfaces

/// The strings three binaries and two plists have to agree about.
///
/// None of these disagreements produces an error at build time or at run time.
/// A mistyped App Group resolves to nil and the widget quietly shows a
/// placeholder forever; a mistyped widget kind matches no widget and the
/// reload does nothing; a mistyped scheme opens the App Store. So they are
/// asserted.
final class SystemSurfaceIdentifierTests: XCTestCase {

    /// Section 79. Derived from the bundle identifier, so it is predictable
    /// rather than something to look up — and prefixed `group.`, which the
    /// system requires and which nothing else checks.
    func testTheAppGroupIsDerivedFromTheBundleIdentifier() {
        XCTAssertTrue(SystemSurfaceIdentifiers.appGroup.hasPrefix("group."))
        XCTAssertEqual(
            SystemSurfaceIdentifiers.appGroup,
            "group." + SystemSurfaceIdentifiers.bundlePrefix
        )
    }

    /// Section 118. Predictable child identifiers, not unrelated ones.
    func testExtensionBundleIdentifiersAreChildrenOfTheApp() {
        XCTAssertEqual(
            SystemSurfaceIdentifiers.keyboardBundleID,
            SystemSurfaceIdentifiers.bundlePrefix + ".keyboard"
        )
        XCTAssertEqual(
            SystemSurfaceIdentifiers.widgetsBundleID,
            SystemSurfaceIdentifiers.bundlePrefix + ".widgets"
        )
    }

    func testWidgetKindsAreDistinctAndStable() {
        let kinds = SystemSurfaceWidgetKind.allCases.map(\.rawValue)
        XCTAssertEqual(Set(kinds).count, kinds.count, "two widgets share a kind")
        // Stable strings: changing one orphans every widget the user has
        // already placed on a Home Screen, which looks like the widget
        // breaking rather than like an update.
        XCTAssertEqual(SystemSurfaceWidgetKind.today.rawValue, "PersonalAssistantToday")
        XCTAssertEqual(SystemSurfaceWidgetKind.nextTask.rawValue, "PersonalAssistantNextTask")
        XCTAssertEqual(SystemSurfaceWidgetKind.support.rawValue, "PersonalAssistantSupport")
    }

    // MARK: Deep links

    /// Section 44. Built and parsed by one type, so a widget cannot invent a
    /// URL the app does not understand.
    func testEveryDestinationRoundTrips() {
        let taskID = UUID()
        let destinations: [SystemSurfaceDestination] = [.today, .assistant, .task(taskID)]

        for destination in destinations {
            let parsed = SystemSurfaceDestination.parse(destination.url)
            XCTAssertEqual(parsed, destination, "\(destination) did not survive its own URL")
        }
    }

    func testDestinationURLsUseTheApplicationScheme() {
        XCTAssertEqual(
            SystemSurfaceDestination.today.url.scheme,
            SystemSurfaceIdentifiers.urlScheme
        )
    }

    /// Anything else is not ours, and is refused rather than guessed at — the
    /// app is asked to open URLs by things other than its own widgets.
    func testForeignURLsAreRejected() {
        let foreign = [
            URL(string: "https://example.com/today")!,
            URL(string: "metisai://elsewhere/today")!,
            URL(string: "metisai://open/nonsense")!,
            URL(string: "metisai://open/task")!,
            URL(string: "metisai://open/task?id=not-a-uuid")!,
        ]

        for url in foreign {
            XCTAssertNil(SystemSurfaceDestination.parse(url), "\(url) should not have parsed")
        }
    }
}
