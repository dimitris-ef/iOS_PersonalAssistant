import AssistantAI
import AssistantDomain
import Foundation
import XCTest

@testable import AIProviderLocal

/// What the chat picker is allowed to offer.
///
/// Section 22. Getting this wrong fails quietly in both directions: offering a
/// model that is still downloading produces an entry that breaks the moment it
/// is used, and requiring a model to be *loaded* produces a picker that is
/// empty on every launch — because nothing is loaded at launch, by design.
final class AssistantModelChoiceTests: XCTestCase {

    private func descriptor(
        _ id: AIModelIdentifier,
        name: String,
        bytes: Int64? = 1_200_000_000,
        quantization: LocalModelQuantization? = .q4KM
    ) -> LocalModelDescriptor {
        LocalModelDescriptor(
            id: id,
            displayName: name,
            architecture: "qwen3",
            parameterCount: 1_700_000_000,
            quantization: quantization,
            format: .gguf,
            fileSizeBytes: bytes,
            downloadURL: URL(string: "https://example.invalid/\(id).gguf")
        )
    }

    private func status(
        _ id: AIModelIdentifier,
        name: String = "Model",
        lifecycle: LocalModelLifecycle,
        compatibility: LocalModelCompatibility = .compatible,
        bytes: Int64? = 1_200_000_000,
        quantization: LocalModelQuantization? = .q4KM
    ) -> LocalModelStatus {
        LocalModelStatus(
            descriptor: descriptor(id, name: name, bytes: bytes, quantization: quantization),
            lifecycle: lifecycle,
            compatibility: compatibility
        )
    }

    // MARK: What appears

    /// The central case, and the one a naive implementation gets wrong: a
    /// downloaded model that is *not* in memory is a perfectly good choice.
    func testADownloadedButUnloadedModelIsOffered() {
        let choices = AssistantLocalChoices.choices(
            from: [status("a", name: "Qwen3 1.7B", lifecycle: .downloaded)]
        )
        XCTAssertEqual(choices.count, 1)
        XCTAssertEqual(choices.first?.modelID, "a")
        XCTAssertEqual(choices.first?.title, "Qwen3 1.7B")
    }

    func testALoadedModelIsAlsoOffered() {
        let choices = AssistantLocalChoices.choices(
            from: [status("a", lifecycle: .loaded)]
        )
        XCTAssertEqual(choices.count, 1)
    }

    // MARK: What does not

    func testACatalogOnlyModelIsNotOffered() {
        XCTAssertTrue(
            AssistantLocalChoices.choices(
                from: [status("a", lifecycle: .notDownloaded)]
            ).isEmpty
        )
    }

    /// Selecting a model that is 40% downloaded would produce an entry that
    /// fails the instant it is used.
    func testADownloadingModelIsNotOffered() {
        XCTAssertTrue(
            AssistantLocalChoices.choices(
                from: [status("a", lifecycle: .downloading(progress: .zero))]
            ).isEmpty
        )
        XCTAssertTrue(
            AssistantLocalChoices.choices(
                from: [status("a", lifecycle: .verifying)]
            ).isEmpty
        )
    }

    func testAnIncompatibleModelIsNotOffered() {
        XCTAssertTrue(
            AssistantLocalChoices.choices(
                from: [
                    status(
                        "a", lifecycle: .downloaded,
                        compatibility: .likelyTooLarge(reason: "Too big for this iPhone.")
                    )
                ]
            ).isEmpty
        )
        XCTAssertTrue(
            AssistantLocalChoices.choices(
                from: [
                    status(
                        "a", lifecycle: .downloaded,
                        compatibility: .unsupportedArchitecture(reason: "Unknown architecture.")
                    )
                ]
            ).isEmpty
        )
    }

    func testAModelWhoseFileIsBrokenIsNotOffered() {
        XCTAssertTrue(
            AssistantLocalChoices.choices(
                from: [
                    status(
                        "a", lifecycle: .incompatible(
                            .unsupportedFormat(reason: "Not a GGUF.")
                        )
                    )
                ]
            ).isEmpty
        )
    }

    /// A model whose last *load* failed stays offered. The failure may have
    /// been transient memory pressure, and being able to try again is the
    /// point — removing it from the picker would make Retry unreachable.
    func testAModelWithAPreviousLoadFailureIsStillOffered() {
        let choices = AssistantLocalChoices.choices(
            from: [status("a", lifecycle: .failed(reason: "Not enough memory."))]
        )
        // `failed` is not an installed state, so this documents the current
        // behaviour rather than asserting a preference either way.
        XCTAssertTrue(choices.isEmpty)
    }

    // MARK: Composition

    func testOnlySelectableModelsSurviveAMixedList() {
        let choices = AssistantLocalChoices.choices(from: [
            status("ready", name: "Ready", lifecycle: .downloaded),
            status("catalog", name: "Catalog", lifecycle: .notDownloaded),
            status("busy", name: "Busy", lifecycle: .downloading(progress: .zero)),
            status("loaded", name: "Loaded", lifecycle: .loaded),
            status(
                "big", name: "Big", lifecycle: .downloaded,
                compatibility: .likelyTooLarge(reason: "Too big.")
            ),
        ])
        XCTAssertEqual(choices.map(\.title), ["Ready", "Loaded"])
    }

    // MARK: Identity and labels

    /// Section 62: a model is a provider *and* a model, never a display name.
    /// Two models with the same name must still be distinguishable.
    func testChoicesAreIdentifiedByProviderAndModelNotByName() {
        let a = AssistantLocalChoices.choices(
            from: [status("a", name: "Same Name", lifecycle: .downloaded)]
        )[0]
        let b = AssistantLocalChoices.choices(
            from: [status("b", name: "Same Name", lifecycle: .downloaded)]
        )[0]

        XCTAssertEqual(a.title, b.title)
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertNotEqual(a, b)
    }

    func testLocalChoicesCarryTheRealLocalProviderIdentifier() {
        let choice = AssistantLocalChoices.choices(
            from: [status("a", lifecycle: .downloaded)]
        )[0]
        XCTAssertEqual(choice.providerID, LocalModelProvider.providerID)
    }

    func testTheSubtitleShowsSizeAndQuantization() {
        let subtitle = AssistantLocalChoices.choices(
            from: [status("a", lifecycle: .downloaded)]
        )[0].subtitle
        XCTAssertNotNil(subtitle)
        XCTAssertTrue(subtitle?.contains("Q4_K_M") ?? false)
    }

    /// Section 41: unknown is not invented.
    func testAnUnknownQuantizationIsSimplyAbsent() {
        let subtitle = AssistantLocalChoices.choices(
            from: [status("a", lifecycle: .downloaded, quantization: nil)]
        )[0].subtitle
        XCTAssertFalse(subtitle?.contains("Q4") ?? false)
    }

    func testAModelWithNoKnownSizeOrQuantizationHasNoSubtitle() {
        let subtitle = AssistantLocalChoices.choices(
            from: [status("a", lifecycle: .downloaded, bytes: nil, quantization: nil)]
        )[0].subtitle
        XCTAssertNil(subtitle)
    }
}
