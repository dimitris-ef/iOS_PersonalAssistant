import XCTest

@testable import ReleaseTooling

import SystemSurfaces

/// The identifiers this app is signed, uploaded and installed under.
///
/// Every check here is about a failure that happens *after* a successful build:
/// an archive signed against the wrong record, an extension that installs and
/// cannot see the shared container, a placeholder that was never replaced. None
/// of them is a compile error, so they are assertions instead.
final class DistributionIdentifierTests: XCTestCase {

    // MARK: The two sources of truth agree

    /// The one test that justifies `DistributionIdentifiers` existing.
    ///
    /// `SystemSurfaceIdentifiers` is what the running app uses;
    /// `DistributionIdentifiers` is what the deploy workflow signs and uploads.
    /// They are separate constants in separate modules with no dependency
    /// between them, which is what makes this an assertion rather than a
    /// tautology: change one and this fails, instead of the app shipping under
    /// an identifier its own code does not use.
    func testDistributionIdentifiersMatchTheRuntimeIdentifiers() {
        XCTAssertEqual(DistributionIdentifiers.appBundleID, SystemSurfaceIdentifiers.bundlePrefix)
        XCTAssertEqual(
            DistributionIdentifiers.widgetsBundleID, SystemSurfaceIdentifiers.widgetsBundleID
        )
        XCTAssertEqual(
            DistributionIdentifiers.keyboardBundleID, SystemSurfaceIdentifiers.keyboardBundleID
        )
        XCTAssertEqual(DistributionIdentifiers.appGroup, SystemSurfaceIdentifiers.appGroup)
    }

    // MARK: They are production values

    /// Section 96. The shipping set must contain no placeholder at all.
    func testTheShippingIdentifiersAreProductionValues() {
        XCTAssertEqual(
            IdentifierPlaceholderCheck.problemsInShippingSet(), [],
            "the app is configured to ship under an identifier that is not a real one"
        )
    }

    func testTheProductionIdentifiersAreTheOnesRegisteredWithApple() {
        // Spelled out rather than derived, so that a typo in the constant is
        // caught by a test that does not share the typo.
        XCTAssertEqual(DistributionIdentifiers.appBundleID, "com.dimitrisefthymiou.MetisAI")
        XCTAssertEqual(
            DistributionIdentifiers.widgetsBundleID, "com.dimitrisefthymiou.MetisAI.widgets"
        )
        XCTAssertEqual(
            DistributionIdentifiers.keyboardBundleID, "com.dimitrisefthymiou.MetisAI.keyboard"
        )
        XCTAssertEqual(DistributionIdentifiers.appGroup, "group.com.dimitrisefthymiou.MetisAI")
    }

    // MARK: The check itself works

    /// Section 97. A preflight that passes everything is worse than no
    /// preflight, because it is trusted.
    func testPlaceholderIdentifiersAreRejected() {
        let rejected = [
            "com.example.personalassistant",
            "com.example.MetisAI",
            "org.example.app",
            "com.yourcompany.MetisAI",
            "com.mycompany.assistant",
            "com.acme.tool",
            "com.dimitrisefthymiou.TestApp.demo",
            "com.apple.MetisAI",
        ]
        for identifier in rejected {
            XCTAssertFalse(
                IdentifierPlaceholderCheck.problems(in: identifier, role: "Main").isEmpty,
                "\(identifier) should have been rejected as a placeholder"
            )
        }
    }

    /// A real identifier that merely *contains* a suspicious substring must
    /// pass. Matching on components rather than substrings is the difference
    /// between a check and an obstacle.
    func testRealIdentifiersAreNotRejectedForContainingASuspiciousSubstring() {
        let accepted = [
            "com.dimitrisefthymiou.MetisAI",
            // "testing" is not "test"; "Exampleware" is not "example".
            "com.testingtimes.Product",
            "com.exampleware.Product",
            "io.democracy.Product",
        ]
        for identifier in accepted {
            XCTAssertEqual(
                IdentifierPlaceholderCheck.problems(in: identifier, role: "Main"), [],
                "\(identifier) is a legitimate identifier and should not be rejected"
            )
        }
    }

    func testStructurallyInvalidIdentifiersAreRejected() {
        XCTAssertFalse(IdentifierPlaceholderCheck.problems(in: "", role: "Main").isEmpty)
        XCTAssertFalse(IdentifierPlaceholderCheck.problems(in: "MetisAI", role: "Main").isEmpty)
        XCTAssertFalse(
            IdentifierPlaceholderCheck.problems(in: "com.dimitris_efthymiou.App", role: "Main")
                .isEmpty,
            "an underscore is not a legal bundle identifier character"
        )
        XCTAssertFalse(
            IdentifierPlaceholderCheck.problems(in: "com.dimitris efthymiou.App", role: "Main")
                .isEmpty
        )
    }

    /// A message that does not name the target it is about sends whoever reads
    /// the log looking through three of them.
    func testProblemsNameTheRoleTheyAreAbout() {
        let problems = IdentifierPlaceholderCheck.problems(
            in: "com.example.thing", role: "Keyboard"
        )
        XCTAssertFalse(problems.isEmpty)
        XCTAssertTrue(problems.allSatisfy { $0.contains("Keyboard") })
    }
}
