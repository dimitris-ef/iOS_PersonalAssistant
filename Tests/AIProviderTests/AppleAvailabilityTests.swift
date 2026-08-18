import AssistantAI
import AssistantDomain
import XCTest
@testable import AIProviderApple

/// What the user is told about the on-device model, and when.
///
/// None of this needs Apple Intelligence, a supported device, or even an Apple
/// SDK — which is the entire point of translating the framework's availability
/// through a plain enum. The mapping is the part that decides what appears on
/// the Settings screen, so it is the part worth pinning.
final class AppleAvailabilityTests: XCTestCase {

    func testReadyIsTheOnlyStateThatReportsAvailable() {
        XCTAssertTrue(AppleModelAvailabilityState.ready.providerAvailability.isAvailable)

        let unavailable: [AppleModelAvailabilityState] = [
            .deviceNotEligible,
            .appleIntelligenceNotEnabled,
            .modelNotReady,
            .unrecognised("somethingNewerKnows"),
            .frameworkMissingFromSDK,
            .operatingSystemTooOld,
        ]
        for state in unavailable {
            XCTAssertFalse(
                state.providerAvailability.isAvailable,
                "\(state.diagnosticName) must not report as ready"
            )
        }
    }

    /// Switching Apple Intelligence on is something the person can actually do.
    /// Nothing else here is.
    func testOnlyAppleIntelligenceBeingOffIsPresentedAsFixable() {
        XCTAssertTrue(
            AppleModelAvailabilityState.appleIntelligenceNotEnabled
                .providerAvailability.isUserResolvable
        )

        for state in [
            AppleModelAvailabilityState.deviceNotEligible,
            .modelNotReady,
            .operatingSystemTooOld,
            .frameworkMissingFromSDK,
            .unrecognised("whatever"),
        ] {
            XCTAssertFalse(
                state.providerAvailability.isUserResolvable,
                "\(state.diagnosticName) is not something the user can fix"
            )
        }
    }

    /// A model still downloading is worth trying again; a device that cannot
    /// run Apple Intelligence never will be. The UI draws these differently, so
    /// the distinction has to survive the mapping.
    func testDownloadingIsTemporaryAndIneligibleHardwareIsNot() {
        guard case .temporarilyUnavailable = AppleModelAvailabilityState.modelNotReady.providerAvailability
        else {
            return XCTFail("A model still downloading is temporary, not permanent")
        }
        guard case .unsupported = AppleModelAvailabilityState.deviceNotEligible.providerAvailability
        else {
            return XCTFail("Ineligible hardware is not going to become eligible")
        }
        guard case .unsupported = AppleModelAvailabilityState.operatingSystemTooOld.providerAvailability
        else {
            return XCTFail("An OS predating the framework is unsupported, not a temporary blip")
        }
    }

    /// Apple's reason enum is not frozen. A case added by a future OS must
    /// leave the provider unusable rather than crashing or, far worse, being
    /// read as ready.
    func testAnUnrecognisedReasonFailsClosed() {
        let availability = AppleModelAvailabilityState.unrecognised("futureReason").providerAvailability
        XCTAssertFalse(availability.isAvailable)
        XCTAssertFalse(availability.isUserResolvable)
        XCTAssertNotNil(availability.reason)
    }

    /// Every unavailable state has to explain itself; a bare "Not available"
    /// with no reason leaves the person with nothing to act on.
    func testEveryUnavailableStateExplainsItself() {
        for state in [
            AppleModelAvailabilityState.deviceNotEligible,
            .appleIntelligenceNotEnabled,
            .modelNotReady,
            .operatingSystemTooOld,
            .frameworkMissingFromSDK,
            .unrecognised("x"),
        ] {
            let reason = state.providerAvailability.reason
            XCTAssertNotNil(reason, "\(state.diagnosticName) gave no reason")
            XCTAssertFalse(reason?.isEmpty ?? true)
        }
    }

    /// The on-device model has never needed a credential, and telling someone
    /// to go and find an API key for it would send them looking for something
    /// that does not exist.
    func testNoAvailabilityMessageMentionsCredentials() {
        for state in [
            AppleModelAvailabilityState.deviceNotEligible,
            .appleIntelligenceNotEnabled,
            .modelNotReady,
            .operatingSystemTooOld,
            .frameworkMissingFromSDK,
            .unrecognised("x"),
        ] {
            let reason = (state.providerAvailability.reason ?? "").lowercased()
            for forbidden in ["api key", "token", "credential", "sign in", "account"] {
                XCTAssertFalse(
                    reason.contains(forbidden),
                    "\(state.diagnosticName) mentions '\(forbidden)': \(reason)"
                )
            }
        }
    }

    /// The raw reason string from a future OS is a framework implementation
    /// detail. It belongs in a log, not on someone's screen.
    func testTheRawUnrecognisedReasonIsNotShownToTheUser() {
        let state = AppleModelAvailabilityState.unrecognised("deviceIsHauntedByGhosts")
        XCTAssertFalse(state.providerAvailability.reason?.contains("Haunted") ?? false)
        XCTAssertFalse(state.providerAvailability.reason?.contains("deviceIsHaunted") ?? false)
        // But it is kept for diagnostics.
        XCTAssertTrue(state.diagnosticName.contains("deviceIsHauntedByGhosts"))
    }

    // MARK: The provider, driven through a fixed reader

    func testTheProviderReportsWhateverTheModelActuallySays() async {
        let ready = AppleFoundationModelsProvider(
            availabilityReader: FixedAppleModelAvailabilityReader(.ready)
        )
        let availability = await ready.availability()
        XCTAssertTrue(availability.isAvailable)
    }

    /// §55: an unavailable Apple provider stays in the registry, reports why,
    /// and returns a meaningful error rather than crashing or inventing a reply.
    func testAnUnavailableProviderFailsWithAReasonRatherThanAnswering() async throws {
        let provider = AppleFoundationModelsProvider(
            availabilityReader: FixedAppleModelAvailabilityReader(.appleIntelligenceNotEnabled)
        )

        let availability = await provider.availability()
        XCTAssertFalse(availability.isAvailable)
        XCTAssertTrue(availability.isUserResolvable)

        do {
            _ = try await provider.respond(
                to: AIRequest(
                    systemPrompt: "You are an assistant.",
                    messages: [AIMessage(role: .user, content: "what's on today?")]
                )
            )
            XCTFail("Expected the provider to refuse rather than answer")
        } catch let error as AIProviderError {
            guard case .unavailable(let reason) = error else {
                return XCTFail("Expected .unavailable, got \(error)")
            }
            XCTAssertTrue(reason.lowercased().contains("apple intelligence"), reason)
        }
    }

    /// The registry keeps the provider whatever its state, so Settings can show
    /// it and explain itself. A provider that vanished when unavailable would
    /// leave the screen silently missing a row.
    func testTheProviderStaysInTheRegistryWhileUnavailable() async {
        let apple = AppleFoundationModelsProvider(
            availabilityReader: FixedAppleModelAvailabilityReader(.deviceNotEligible)
        )
        let registry = AIProviderRegistry(providers: [apple])

        let all = await registry.allMetadata()
        XCTAssertTrue(all.contains { $0.id == AppleFoundationModelsProvider.providerID })

        let ready = await registry.availableProviders()
        XCTAssertFalse(ready.contains { $0.metadata.id == AppleFoundationModelsProvider.providerID })
    }
}
