import XCTest

@testable import ReleaseTooling

/// The number App Store Connect files the upload under.
///
/// A build number can only be used once, ever, within a marketing version.
/// Getting it wrong costs a whole archive-export-upload cycle, and the error
/// arrives at the very end.
final class BuildNumberTests: XCTestCase {

    /// Section 35.
    func testTheBuildNumberIsTheRunAndTheAttempt() throws {
        XCTAssertEqual(try BuildNumber.make(runNumber: "412", runAttempt: "1"), "412.1")
    }

    /// The reason the attempt is in there at all: a re-run reuses the run
    /// number, and a deploy that failed after uploading would otherwise collide
    /// with itself.
    func testARerunProducesADifferentBuildNumberFromTheSameRun() throws {
        let first = try BuildNumber.make(runNumber: "412", runAttempt: "1")
        let second = try BuildNumber.make(runNumber: "412", runAttempt: "2")
        XCTAssertNotEqual(first, second)
    }

    func testBuildNumbersIncreaseWithTheRunNumber() throws {
        // Compared the way App Store Connect compares them: component by
        // component as integers, not as strings, where "9" would sort after
        // "412".
        let low = try BuildNumber.make(runNumber: "9", runAttempt: "1")
        let high = try BuildNumber.make(runNumber: "412", runAttempt: "1")
        XCTAssertLessThan(numeric(low), numeric(high))
    }

    private func numeric(_ value: String) -> [Int] {
        value.split(separator: ".").compactMap { Int($0) }
    }

    // MARK: Refusals

    func testANonNumericRunNumberIsRefused() {
        for bad in ["", "abc", "-1", "1.2", " 4", "4 ", "+4"] {
            XCTAssertThrowsError(
                try BuildNumber.make(runNumber: bad, runAttempt: "1"),
                "\(bad.debugDescription) should not produce a build number"
            )
        }
    }

    /// `007` and `7` are the same build to App Store Connect, so a leading zero
    /// is a collision waiting to be discovered at upload.
    func testLeadingZerosAreRefused() {
        XCTAssertThrowsError(try BuildNumber.make(runNumber: "007", runAttempt: "1"))
        XCTAssertThrowsError(try BuildNumber.validate(override: "412.01"))
    }

    // MARK: Overrides

    /// Section 37. The one legitimate use: an upload that succeeded and a poll
    /// that did not, re-run against the number already in App Store Connect.
    func testAValidOverrideIsUsedInsteadOfTheRunNumber() throws {
        let resolved = try BuildNumber.resolve(
            override: "412.1", runNumber: "999", runAttempt: "3"
        )
        XCTAssertEqual(resolved, "412.1")
    }

    func testAnAbsentOrBlankOverrideFallsBackToTheRun() throws {
        XCTAssertEqual(
            try BuildNumber.resolve(override: nil, runNumber: "999", runAttempt: "3"), "999.3"
        )
        XCTAssertEqual(
            try BuildNumber.resolve(override: "   ", runNumber: "999", runAttempt: "3"), "999.3"
        )
    }

    /// An override reaches a signed binary and an `xcodebuild` command line, so
    /// it is validated rather than trusted.
    func testAMalformedOverrideIsRefused() {
        for bad in ["1.2.3.4", "1.2.x", "abc", "1..2", "1 2", "99999999", "-1", "'; echo"] {
            XCTAssertThrowsError(
                try BuildNumber.validate(override: bad),
                "\(bad.debugDescription) should not be accepted as a build number"
            )
        }
    }

    func testThreeComponentsAreTheCeiling() throws {
        XCTAssertEqual(try BuildNumber.validate(override: "1.2.3"), "1.2.3")
        XCTAssertThrowsError(try BuildNumber.validate(override: "1.2.3.4"))
    }

    // MARK: Marketing version

    /// Section 34: preserved, and checked for a shape App Store Connect will
    /// accept.
    func testTheProjectsMarketingVersionIsAcceptable() throws {
        // The value in `project.yml`. If it changes to something
        // CFBundleShortVersionString does not allow, the upload is refused, and
        // this is where that is noticed instead.
        XCTAssertEqual(try MarketingVersion.validate("0.1"), "0.1")
    }

    func testAMalformedMarketingVersionIsRefused() {
        for bad in ["", "1.0-beta", "v1.0", "1.0.0.0", "one"] {
            XCTAssertThrowsError(try MarketingVersion.validate(bad))
        }
    }
}
