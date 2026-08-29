import Foundation
import XCTest

@testable import ReleaseTooling

/// Reading a provisioning profile, and refusing the wrong one.
///
/// ## About the fixtures
///
/// Every profile in this file is synthesised in code. Section 98: no real
/// `.mobileprovision` is committed, and none is needed — a real one differs
/// from these only in carrying a signature and a list of certificates, neither
/// of which the parser looks at. The team identifiers are obvious fakes.
final class ProvisioningProfileTests: XCTestCase {

    // MARK: Fixtures

    private static let team = "TEAM000000"

    private func profilePlist(
        name: String = "MetisAI App Store",
        uuid: String = "11111111-2222-3333-4444-555555555555",
        team: String = ProvisioningProfileTests.team,
        applicationIdentifier: String = "TEAM000000.com.dimitrisefthymiou.MetisAI",
        groups: [String] = ["group.com.dimitrisefthymiou.MetisAI"],
        expires: Date? = Date(timeIntervalSince1970: 4_000_000_000),
        provisionsAllDevices: Bool = false,
        provisionedDevices: [String]? = nil,
        getTaskAllow: Bool = false
    ) -> Data {
        var entitlements: [String: Any] = [
            "application-identifier": applicationIdentifier,
            "get-task-allow": getTaskAllow,
            "com.apple.developer.team-identifier": team,
        ]
        if !groups.isEmpty {
            entitlements["com.apple.security.application-groups"] = groups
        }

        var plist: [String: Any] = [
            "Name": name,
            "UUID": uuid,
            "TeamIdentifier": [team],
            "Entitlements": entitlements,
            "ProvisionsAllDevices": provisionsAllDevices,
        ]
        if let expires { plist["ExpirationDate"] = expires }
        if let provisionedDevices { plist["ProvisionedDevices"] = provisionedDevices }

        // XML, because that is the format Apple embeds and the format the
        // scanner in `embeddedPlist` looks for.
        return try! PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0
        )
    }

    /// Wraps a plist the way a signed `.mobileprovision` does: binary DER
    /// before it, binary DER after it.
    private func cmsWrapped(_ payload: Data) -> Data {
        var data = Data([0x30, 0x82, 0x0A, 0xBC, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x00, 0xFF])
        data.append(payload)
        data.append(Data([0x31, 0x82, 0x03, 0x00, 0xA0, 0x03, 0x02, 0x01, 0x01, 0x00, 0xFE]))
        return data
    }

    // MARK: Parsing

    func testReadsEveryFieldTheDeployStepDependsOn() throws {
        let profile = try ProvisioningProfile.parse(profilePlist())

        XCTAssertEqual(profile.name, "MetisAI App Store")
        XCTAssertEqual(profile.uuid, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(profile.teamIdentifier, Self.team)
        XCTAssertEqual(profile.bundleIdentifier, "com.dimitrisefthymiou.MetisAI")
        XCTAssertEqual(profile.applicationGroups, ["group.com.dimitrisefthymiou.MetisAI"])
        XCTAssertEqual(profile.expirationDate, Date(timeIntervalSince1970: 4_000_000_000))
    }

    /// Section 16: the file on disk is CMS-wrapped, and the payload has to come
    /// out of it before anything can be read.
    func testFindsThePlistInsideASignedProfile() throws {
        let wrapped = cmsWrapped(profilePlist(name: "Wrapped Profile"))
        let profile = try ProvisioningProfile.parse(wrapped)
        XCTAssertEqual(profile.name, "Wrapped Profile")
    }

    func testRefusesAFileThatIsNotAProfile() {
        XCTAssertThrowsError(try ProvisioningProfile.parse(Data("not a profile".utf8)))
        XCTAssertThrowsError(try ProvisioningProfile.parse(Data()))
    }

    func testRefusesAProfileMissingTheFieldsSigningNeeds() throws {
        let plist: [String: Any] = ["Name": "Nameless", "UUID": "abc"]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0
        )
        XCTAssertThrowsError(try ProvisioningProfile.parse(data)) { error in
            XCTAssertEqual(
                error as? ProvisioningProfileError,
                .missingField("TeamIdentifier")
            )
        }
    }

    /// A wildcard profile parses, and reports no bundle identifier — which is
    /// what makes `problems` reject it rather than silently comparing nil.
    func testAWildcardProfileHasNoBundleIdentifier() throws {
        let profile = try ProvisioningProfile.parse(
            profilePlist(applicationIdentifier: "TEAM000000.*")
        )
        XCTAssertNil(profile.bundleIdentifier)
    }

    // MARK: Distribution kind

    func testDistinguishesTheFourKindsOfProfile() throws {
        let appStore = try ProvisioningProfile.parse(profilePlist())
        XCTAssertEqual(appStore.distribution, .appStore)

        let development = try ProvisioningProfile.parse(
            profilePlist(provisionedDevices: ["device"], getTaskAllow: true)
        )
        XCTAssertEqual(development.distribution, .development)

        let adHoc = try ProvisioningProfile.parse(
            profilePlist(provisionedDevices: ["device"], getTaskAllow: false)
        )
        XCTAssertEqual(adHoc.distribution, .adHoc)

        let enterprise = try ProvisioningProfile.parse(
            profilePlist(provisionsAllDevices: true)
        )
        XCTAssertEqual(enterprise.distribution, .enterprise)
    }

    // MARK: Validation

    private var mainExpectation: ProvisioningProfile.Expectation {
        ProvisioningProfile.Expectation(
            role: "Main",
            bundleIdentifier: "com.dimitrisefthymiou.MetisAI",
            teamIdentifier: Self.team,
            applicationGroup: "group.com.dimitrisefthymiou.MetisAI"
        )
    }

    func testACorrectProfilePasses() throws {
        let profile = try ProvisioningProfile.parse(profilePlist())
        XCTAssertEqual(profile.problems(against: mainExpectation), [])
    }

    /// The failure that produces the least helpful error from `xcodebuild`:
    /// the widgets target signed with the app's profile.
    func testAProfileForTheWrongBundleIsRejected() throws {
        let profile = try ProvisioningProfile.parse(
            profilePlist(
                applicationIdentifier: "TEAM000000.com.dimitrisefthymiou.MetisAI.widgets"
            )
        )
        let problems = profile.problems(against: mainExpectation)
        XCTAssertTrue(problems.contains { $0.contains("different bundle identifier") })
    }

    func testAProfileFromAnotherTeamIsRejected() throws {
        let profile = try ProvisioningProfile.parse(
            profilePlist(team: "OTHER00000", applicationIdentifier: "OTHER00000.com.dimitrisefthymiou.MetisAI")
        )
        let problems = profile.problems(against: mainExpectation)
        XCTAssertTrue(problems.contains { $0.contains("different team") })
    }

    /// Section 21.
    func testAnExpiredProfileIsRejected() throws {
        let expired = Date(timeIntervalSince1970: 1_000_000_000)
        let profile = try ProvisioningProfile.parse(profilePlist(expires: expired))
        let problems = profile.problems(
            against: mainExpectation, now: Date(timeIntervalSince1970: 1_100_000_000)
        )
        XCTAssertEqual(problems.first, "Main provisioning profile is expired.")
    }

    /// A profile that expires the day after tomorrow is not expired and is
    /// still a problem, because the next release will be blocked by it.
    func testAProfileAboutToExpireIsFlagged() throws {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let profile = try ProvisioningProfile.parse(
            profilePlist(expires: now.addingTimeInterval(2 * 86_400))
        )
        let problems = profile.problems(against: mainExpectation, now: now)
        XCTAssertTrue(problems.contains { $0.contains("expires in 2 day(s)") })
    }

    /// Section 20. The App Group is the entitlement whose absence produces no
    /// error at all — the container simply resolves to nil on the device.
    func testAProfileWithoutTheAppGroupIsRejected() throws {
        let profile = try ProvisioningProfile.parse(profilePlist(groups: []))
        let problems = profile.problems(against: mainExpectation)
        XCTAssertTrue(problems.contains { $0.contains("App Group") })
    }

    /// Section 22. A development profile archives and exports; App Store
    /// Connect refuses it after the upload.
    func testADevelopmentProfileIsRejected() throws {
        let profile = try ProvisioningProfile.parse(
            profilePlist(provisionedDevices: ["device"], getTaskAllow: true)
        )
        let problems = profile.problems(against: mainExpectation)
        XCTAssertTrue(problems.contains { $0.contains("development profile") })
    }

    /// Every problem, not the first one. Re-running a deploy to find the second
    /// mistake is the cost this check exists to remove.
    func testAThoroughlyWrongProfileReportsEveryProblemAtOnce() throws {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let profile = try ProvisioningProfile.parse(
            profilePlist(
                team: "OTHER00000",
                applicationIdentifier: "OTHER00000.com.someoneelse.App",
                groups: [],
                expires: now.addingTimeInterval(-1),
                provisionedDevices: ["device"],
                getTaskAllow: true
            )
        )
        let problems = profile.problems(against: mainExpectation, now: now)
        XCTAssertGreaterThanOrEqual(problems.count, 5, "\(problems)")
    }

    // MARK: Nothing leaks

    /// Section 18 and section 86. A CI log is readable by anyone who can read
    /// the repository, so a validation failure must name the role and the
    /// problem — never the profile's contents.
    func testValidationMessagesRevealNothingFromTheProfile() throws {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let profile = try ProvisioningProfile.parse(
            profilePlist(
                team: "SECRETTEAM",
                applicationIdentifier: "SECRETTEAM.com.private.internal",
                uuid: "DEADBEEF-0000-0000-0000-000000000000",
                groups: ["group.com.private.internal"],
                expires: now.addingTimeInterval(-1)
            )
        )

        let joined = profile.problems(against: mainExpectation, now: now).joined(separator: " ")
        for secret in [
            "SECRETTEAM", "com.private.internal", "DEADBEEF", "group.com.private.internal",
        ] {
            XCTAssertFalse(joined.contains(secret), "the message leaked \(secret)")
        }
        XCTAssertTrue(joined.contains("Main"), "the message does not say which profile")
    }

    /// The summary is printed on success, so it is allowed the profile's name —
    /// which is the one field a human needs in order to recognise it — and
    /// nothing else.
    func testTheLogSummaryCarriesTheNameAndNoIdentifiers() throws {
        let profile = try ProvisioningProfile.parse(
            profilePlist(name: "MetisAI App Store", team: "SECRETTEAM",
                         applicationIdentifier: "SECRETTEAM.com.dimitrisefthymiou.MetisAI")
        )
        let summary = profile.logSummary
        XCTAssertTrue(summary.contains("MetisAI App Store"))
        XCTAssertTrue(summary.contains("appStore"))
        XCTAssertFalse(summary.contains("SECRETTEAM"))
        XCTAssertFalse(summary.contains(profile.uuid))
    }
}
