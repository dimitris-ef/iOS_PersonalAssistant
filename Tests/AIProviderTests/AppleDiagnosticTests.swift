import AssistantAI
import AssistantDomain
import Foundation
import XCTest

@testable import AIProviderApple

/// The bug this pass exists to fix, pinned so it cannot come back.
///
/// A real iPhone with Apple Intelligence switched on and working reported only
/// "Apple on-device unavailable". The adapter's mapping was correct — it always
/// distinguished Apple's three reasons — but everything above it collapsed six
/// distinct situations into two provider-neutral cases and one English
/// sentence, and the UI showed one word. Nobody holding the phone could tell
/// whether the model was downloading, switched off, or absent from the build.
///
/// These tests assert the reason survives every layer it has to cross.
final class AppleDiagnosticTests: XCTestCase {

    private let everyState: [AppleModelAvailabilityState] = [
        .ready,
        .appleIntelligenceNotEnabled,
        .deviceNotEligible,
        .modelNotReady,
        .operatingSystemTooOld,
        .frameworkMissingFromSDK,
        .unrecognised("aReasonFromAFutureOS"),
    ]

    // MARK: Section 6 — the tokens themselves

    /// Section 6 names four of these explicitly. They are a contract with
    /// whoever reads a bug report, so they are spelled out here rather than
    /// derived — a test that computed the expected value the same way the code
    /// does would pass no matter what either said.
    func testTheReasonTokensAreTheOnesAppleUses() {
        XCTAssertEqual(AppleModelAvailabilityState.ready.reasonToken, "available")
        XCTAssertEqual(
            AppleModelAvailabilityState.appleIntelligenceNotEnabled.reasonToken,
            "appleIntelligenceNotEnabled"
        )
        XCTAssertEqual(
            AppleModelAvailabilityState.deviceNotEligible.reasonToken,
            "deviceNotEligible"
        )
        XCTAssertEqual(AppleModelAvailabilityState.modelNotReady.reasonToken, "modelNotReady")
    }

    /// Section 11 and 42: a reason released after this build must arrive as
    /// `unknown` — not as a crash, not as `available`, and not silently
    /// wearing one of the known reasons' names.
    func testAFutureReasonBecomesUnknownAndNotAKnownReason() {
        let token = AppleModelAvailabilityState.unrecognised("modelIsThinkingAboutIt").reasonToken
        XCTAssertEqual(token, "unknown")
        XCTAssertNotEqual(token, "available")
        XCTAssertNotEqual(token, "modelNotReady")
        XCTAssertNotEqual(token, "deviceNotEligible")
        XCTAssertNotEqual(token, "appleIntelligenceNotEnabled")
    }

    // MARK: Section 43 — the regression

    /// **The load-bearing test of this pass.**
    ///
    /// Every distinct Apple state must still be distinguishable after crossing
    /// the adapter, the provider and the diagnostic snapshot. Before this work
    /// the four `.unsupported` states were indistinguishable to anything that
    /// branched on the availability case, which is exactly what the UI does.
    func testNoTwoStatesCollapseIntoTheSameDiagnostic() async {
        var tokens: [String] = []
        for state in everyState {
            let provider = AppleFoundationModelsProvider(
                availabilityReader: FixedAppleModelAvailabilityReader(state)
            )
            tokens.append(await provider.availabilityReasonToken())
        }

        XCTAssertEqual(
            Set(tokens).count, everyState.count,
            "two Apple states arrive at the UI wearing the same token: \(tokens)"
        )
    }

    /// The narrower statement of the same thing, and the one that actually
    /// regressed: `deviceNotEligible` and `frameworkMissingFromSDK` are both
    /// `.unsupported`, so without a token they are the same row on screen —
    /// while meaning "buy a different phone" and "this build is broken".
    func testUnsupportedStatesAreDistinguishableDespiteSharingACase() async {
        let ineligible = AppleFoundationModelsProvider(
            availabilityReader: FixedAppleModelAvailabilityReader(.deviceNotEligible)
        )
        let noFramework = AppleFoundationModelsProvider(
            availabilityReader: FixedAppleModelAvailabilityReader(.frameworkMissingFromSDK)
        )

        let a = await ineligible.availability()
        let b = await noFramework.availability()
        // The provider-neutral case really is the same. That is not a bug — it
        // is the right level of detail for a list that also describes a cloud
        // endpoint. It is only a bug when it is the *only* thing available.
        XCTAssertEqual(
            AppleFoundationModelsDiagnostic.caseToken(a),
            AppleFoundationModelsDiagnostic.caseToken(b)
        )

        let tokenA = await ineligible.availabilityReasonToken()
        let tokenB = await noFramework.availabilityReasonToken()
        XCTAssertNotEqual(tokenA, tokenB)
    }

    // MARK: The snapshot

    func testTheSnapshotReportsTheStateTheProviderWouldActOn() async {
        for state in everyState {
            let provider = AppleFoundationModelsProvider(
                availabilityReader: FixedAppleModelAvailabilityReader(state)
            )
            let snapshot = await provider.diagnostic()
            let availability = await provider.availability()

            XCTAssertEqual(snapshot.state, state)
            XCTAssertEqual(snapshot.reasonToken, state.reasonToken)
            // Section 55 in reverse: the diagnostic can never claim a state the
            // provider would not act on.
            XCTAssertEqual(snapshot.mappedAvailability, availability)
            XCTAssertEqual(snapshot.mappedAvailability.isAvailable, state == .ready)
        }
    }

    /// Section 21: the screen has to name the implementation that answered, so
    /// a build that had somehow composed a mock is obvious rather than guessed
    /// at from behaviour.
    func testTheSnapshotNamesTheProviderImplementation() async {
        let provider = AppleFoundationModelsProvider(
            availabilityReader: FixedAppleModelAvailabilityReader(.ready)
        )
        let snapshot = await provider.diagnostic()
        XCTAssertEqual(snapshot.providerImplementation, "AppleFoundationModelsProvider")
    }

    /// Section 17: `isAvailable` is exposed for comparison, and the pair is the
    /// interesting reading — a false Boolean beside a specific reason.
    func testIsAvailableIsExposedAlongsideTheReason() async {
        let provider = AppleFoundationModelsProvider(
            availabilityReader: FixedAppleModelAvailabilityReader(.modelNotReady)
        )
        let snapshot = await provider.diagnostic()
        XCTAssertEqual(snapshot.systemModelIsAvailable, false)
        XCTAssertEqual(snapshot.reasonToken, "modelNotReady")
    }

    /// The combination that would previously have been invisible: Apple says
    /// the model is ready, and something above has decided otherwise. If that
    /// ever happens the snapshot shows both halves rather than only the verdict.
    func testAReadyModelAndAnUnavailableMappingWouldBeVisible() async {
        let provider = AppleFoundationModelsProvider(
            availabilityReader: FixedAppleModelAvailabilityReader(.ready)
        )
        let snapshot = await provider.diagnostic()
        XCTAssertEqual(snapshot.systemModelIsAvailable, true)
        XCTAssertEqual(snapshot.reasonToken, "available")
        XCTAssertEqual(snapshot.mappedAvailabilityToken, "available")
    }

    // MARK: Section 44 — refresh

    /// A device whose assets are still downloading reports `modelNotReady` and
    /// then, minutes later, `available`. Nothing may cache the first answer:
    /// the user must not have to reinstall the app to get the second.
    func testARefreshCanSeeTheModelBecomeAvailable() async {
        let reader = SequenceAppleModelAvailabilityReader([.modelNotReady, .ready])
        let provider = AppleFoundationModelsProvider(availabilityReader: reader)

        let first = await provider.availability()
        XCTAssertFalse(first.isAvailable)

        let second = await provider.availability()
        XCTAssertTrue(second.isAvailable, "a re-read must be able to observe the model arriving")
    }

    func testTheDiagnosticAlsoReflectsARefresh() async {
        let reader = SequenceAppleModelAvailabilityReader([.modelNotReady, .ready])
        let provider = AppleFoundationModelsProvider(availabilityReader: reader)

        let before = await provider.diagnostic()
        XCTAssertEqual(before.reasonToken, "modelNotReady")

        let after = await provider.diagnostic()
        XCTAssertEqual(after.reasonToken, "available")
    }

    /// Section 29 and 26: no permanent negative cache. Asking twice in a row
    /// with an unchanging reader must give the same answer both times — the
    /// provider holds no state that could drift.
    func testRepeatedReadsAreStable() async {
        let provider = AppleFoundationModelsProvider(
            availabilityReader: FixedAppleModelAvailabilityReader(.deviceNotEligible)
        )
        let first = await provider.availabilityReasonToken()
        let second = await provider.availabilityReasonToken()
        XCTAssertEqual(first, second)
    }

    // MARK: The copyable report

    /// Section 33. The report is pasted into messages and bug trackers, so what
    /// it must *not* contain matters more than what it does.
    func testTheReportCarriesTheDiagnosticFieldsAndNothingSensitive() async {
        let provider = AppleFoundationModelsProvider(
            availabilityReader: FixedAppleModelAvailabilityReader(.modelNotReady)
        )
        let report = await provider.diagnostic().report

        for expected in [
            "Framework compiled:", "Runtime supported:", "Provider active:",
            "isAvailable:", "availability:", "modelNotReady",
        ] {
            XCTAssertTrue(report.contains(expected), "the report omits \(expected)")
        }

        for forbidden in [
            "sk-", "Bearer", "api_key", "apiKey", "password", "serial", "UDID",
            "@icloud.com", "token=",
        ] {
            XCTAssertFalse(
                report.contains(forbidden),
                "the copyable report contains '\(forbidden)'"
            )
        }
    }

    /// Every state must produce a sentence a person can read, not only a token.
    func testEveryStateHasAHumanReadableHeadline() async {
        for state in everyState {
            let provider = AppleFoundationModelsProvider(
                availabilityReader: FixedAppleModelAvailabilityReader(state)
            )
            let headline = await provider.diagnostic().headline
            XCTAssertFalse(headline.isEmpty, "\(state.reasonToken) has no headline")
            // The sentence is prose, not the token repeated back.
            XCTAssertTrue(headline.contains(" "), "\(state.reasonToken): \(headline)")
        }
    }

    // MARK: Section 45 — production composition

    /// `AppEnvironment` builds the Apple provider by calling
    /// `AppleFoundationModelsProvider()` with no arguments. This asserts that
    /// the no-argument initializer wires the *real* framework reader, so a
    /// shipped build cannot be quietly running on a fixture.
    ///
    /// It deliberately does not assert an availability: a CI runner will report
    /// `deviceNotEligible` or `operatingSystemTooOld`, and section 47 says that
    /// is fine. What is asserted is which code is doing the reporting.
    func testTheDefaultProviderUsesTheRealFrameworkReader() async {
        let production = AppleFoundationModelsProvider()
        let snapshot = await production.diagnostic()

        XCTAssertEqual(snapshot.providerImplementation, "AppleFoundationModelsProvider")
        // The fixture reader stamps "Test"; the real one reports the running OS.
        XCTAssertNotEqual(
            snapshot.osName, "Test",
            "the default initializer is reading a fixture rather than the framework"
        )
        XCTAssertFalse(snapshot.osVersion.isEmpty)
    }

    /// Whatever a runner reports, it must be a token from the fixed vocabulary
    /// rather than something improvised — including on a machine that has no
    /// Apple Intelligence at all.
    func testTheRealReaderProducesAKnownToken() async {
        let production = AppleFoundationModelsProvider()
        let token = await production.availabilityReasonToken()
        XCTAssertTrue(
            [
                "available", "appleIntelligenceNotEnabled", "deviceNotEligible",
                "modelNotReady", "unknown", "frameworkMissingFromSDK",
                "operatingSystemTooOld",
            ].contains(token),
            "unexpected token from the live reader: \(token)"
        )
    }

    // MARK: Section 46 — the other providers are untouched

    /// The diagnostic path must not have changed what any other provider
    /// reports. Nothing here imports them; this asserts the Apple provider's
    /// new members did not alter the shared availability vocabulary.
    func testTheProviderNeutralVocabularyIsUnchanged() {
        XCTAssertTrue(AIProviderAvailability.available.isAvailable)
        XCTAssertFalse(AIProviderAvailability.unsupported(reason: "x").isAvailable)
        XCTAssertTrue(
            AIProviderAvailability.configurationRequired(reason: "x").isUserResolvable
        )
        XCTAssertFalse(
            AIProviderAvailability.temporarilyUnavailable(reason: "x").isUserResolvable
        )
    }
}

extension AppleFoundationModelsDiagnostic {
    /// The provider-neutral case as a token, for a test that needs to say
    /// "these two really do share a case".
    static func caseToken(_ availability: AIProviderAvailability) -> String {
        switch availability {
        case .available: return "available"
        case .configurationRequired: return "configurationRequired"
        case .temporarilyUnavailable: return "temporarilyUnavailable"
        case .unsupported: return "unsupported"
        }
    }
}
