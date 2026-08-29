import Foundation
import XCTest

@testable import ReleaseTooling

/// The plist that decides how the archive is exported.
final class ExportOptionsTests: XCTestCase {

    private let options = ExportOptions.appStore(
        teamID: "TEAM000000",
        mainProfile: "MetisAI App Store",
        widgetsProfile: "MetisAI Widgets App Store",
        keyboardProfile: "MetisAI Keyboard App Store"
    )

    /// Section 61. Three bundles go into the archive and each needs its own
    /// profile; a map with two entries exports two and fails on the third after
    /// several minutes.
    func testEveryBundleInTheArchiveHasAProfile() {
        XCTAssertEqual(options.provisioningProfiles.count, 3)
        for identifier in DistributionIdentifiers.allBundleIDs {
            XCTAssertNotNil(
                options.provisioningProfiles[identifier],
                "\(identifier) has no provisioning profile in the export options"
            )
        }
        XCTAssertEqual(options.problems(), [])
    }

    func testTheShippingConfigurationIsAppStoreManualDistributionSigning() {
        XCTAssertEqual(options.method, .appStoreConnect)
        XCTAssertEqual(options.method.rawValue, "app-store-connect")
        XCTAssertEqual(options.signingStyle, "manual")
        XCTAssertEqual(options.signingCertificate, "Apple Distribution")
    }

    /// Symbols are uploaded and not stripped, or every crash report a tester
    /// files is a column of hex addresses.
    func testSymbolsSurviveTheExport() {
        XCTAssertTrue(options.uploadSymbols)
        XCTAssertFalse(options.stripSwiftSymbols)
    }

    /// Xcode would otherwise renumber the build during export, so the binary
    /// App Store Connect receives would not be the one that was verified.
    func testXcodeIsNotAllowedToRewriteTheBuildNumber() {
        XCTAssertEqual(options.dictionary["manageAppVersionAndBuildNumber"] as? Bool, false)
    }

    func testSerializesAsAnXMLPropertyListXcodebuildCanRead() throws {
        var format = PropertyListSerialization.PropertyListFormat.binary
        let object = try PropertyListSerialization.propertyList(
            from: try options.serialized(), options: [], format: &format
        )
        XCTAssertEqual(format, .xml)

        let plist = try XCTUnwrap(object as? [String: Any])
        XCTAssertEqual(plist["method"] as? String, "app-store-connect")
        XCTAssertEqual(plist["teamID"] as? String, "TEAM000000")
        let profiles = try XCTUnwrap(plist["provisioningProfiles"] as? [String: String])
        XCTAssertEqual(profiles[DistributionIdentifiers.appBundleID], "MetisAI App Store")
    }

    // MARK: What must not be in it

    /// Section 62, asserted rather than assumed.
    ///
    /// The file is written to the workspace and printed to the build log, so
    /// this is the test that keeps that safe. It checks for the *key names* a
    /// credential would arrive under, because that is what a future edit would
    /// add — not for the secret values, which this test does not have and must
    /// never be given.
    func testExportOptionsCarryNoCredentials() throws {
        let text = String(decoding: try options.serialized(), as: UTF8.self)
        let forbidden = [
            "password", "Password", "privateKey", "PrivateKey", "apiKey", "APIKey",
            "certificate\u{2D}password", "p12", "p8", "BEGIN PRIVATE KEY", "AuthKey",
            "keychain", "secret", "Secret", "token", "Token",
        ]
        for term in forbidden {
            XCTAssertFalse(
                text.contains(term),
                "'\(term)' appears in a file that is written to disk and printed to the log"
            )
        }
    }

    // MARK: Refusals

    func testAMissingProfileIsRefusedBeforeTheExportRuns() {
        let incomplete = ExportOptions(
            teamID: "TEAM000000",
            provisioningProfiles: [
                DistributionIdentifiers.appBundleID: "MetisAI App Store",
                DistributionIdentifiers.widgetsBundleID: "MetisAI Widgets App Store",
            ]
        )
        XCTAssertFalse(incomplete.problems().isEmpty)
    }

    /// A profile name that decoded to nothing. The export would otherwise run
    /// and fail with a message about a signing certificate.
    func testAnEmptyProfileNameIsRefused() {
        let blank = ExportOptions(
            teamID: "TEAM000000",
            provisioningProfiles: [
                DistributionIdentifiers.appBundleID: "",
                DistributionIdentifiers.widgetsBundleID: "MetisAI Widgets App Store",
                DistributionIdentifiers.keyboardBundleID: "MetisAI Keyboard App Store",
            ]
        )
        XCTAssertTrue(blank.problems().contains { $0.contains("empty") })
    }

    func testAnEmptyTeamIsRefused() {
        let teamless = ExportOptions.appStore(
            teamID: "  ", mainProfile: "A", widgetsProfile: "B", keyboardProfile: "C"
        )
        XCTAssertTrue(teamless.problems().contains { $0.contains("team") })
    }

    /// Section 49. Automatic signing on a headless runner means a build whose
    /// entitlements were decided by the portal rather than reviewed here.
    func testAutomaticSigningIsRefused() {
        let automatic = ExportOptions(
            teamID: "TEAM000000",
            provisioningProfiles: [
                DistributionIdentifiers.appBundleID: "A",
                DistributionIdentifiers.widgetsBundleID: "B",
                DistributionIdentifiers.keyboardBundleID: "C",
            ],
            signingStyle: "automatic"
        )
        XCTAssertTrue(automatic.problems().contains { $0.contains("manual") })
    }
}
