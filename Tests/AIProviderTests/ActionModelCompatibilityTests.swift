import AssistantAI
import AssistantDomain
import NativeModelKit
import XCTest

@testable import AIProviderLocal

/// Which installed models may interpret actions, and — the rule that matters
/// most — which criterion is not allowed to decide it.
final class ActionModelCompatibilityTests: XCTestCase {

    private static let now = Date(timeIntervalSince1970: 1_788_175_200)

    private func record(
        architecture: String?,
        fileSizeBytes: Int64 = 400_000_000
    ) -> LocalModelRecord {
        LocalModelRecord(
            id: "m",
            relativePath: "m.gguf",
            fileSizeBytes: fileSizeBytes,
            installedAt: Self.now,
            architecture: architecture,
            contextLength: 4096
        )
    }

    private var constrainedRuntime: LocalRuntimeCapabilities {
        LocalRuntimeCapabilities(
            supportsConstrainedGeneration: true,
            runtimeName: "Test",
            runtimeVersion: "1"
        )
    }

    private var unconstrainedRuntime: LocalRuntimeCapabilities {
        LocalRuntimeCapabilities(
            supportsConstrainedGeneration: false,
            runtimeName: "Test",
            runtimeVersion: "1"
        )
    }

    private func resolve(
        _ record: LocalModelRecord?,
        fileExists: Bool = true,
        runtime: LocalRuntimeCapabilities? = nil
    ) -> ActionModelCompatibility {
        ActionModelCompatibilityResolver.resolve(
            record: record,
            fileExists: fileExists,
            runtime: runtime ?? constrainedRuntime
        )
    }

    // MARK: The hard requirement — section 7

    /// Two records identical but for their size resolve identically.
    ///
    /// If anybody ever reaches for "under a billion parameters is too small to
    /// interpret an action", this fails. Under a grammar the *shape* is
    /// guaranteed whatever the size, which is much of why the dedicated action
    /// path exists at all.
    func testSizeAloneDecidesNothing() {
        let sizes: [Int64] = [
            180_000_000, 300_000_000, 500_000_000,
            1_100_000_000, 3_000_000_000, 7_600_000_000,
        ]
        let verdicts = sizes.map {
            resolve(record(architecture: "qwen3", fileSizeBytes: $0))
        }
        XCTAssertEqual(Set(verdicts.map(\.symbol)).count, 1, "size changed the verdict")
        XCTAssertEqual(verdicts.first, .compatible)
    }

    /// Section 7 by name: a 300M model is usable.
    func testSmallModelsAreAllowed() {
        for architecture in ["smollm2", "qwen3", "llama"] {
            let verdict = resolve(
                record(architecture: architecture, fileSizeBytes: 200_000_000)
            )
            XCTAssertTrue(verdict.isUsable, "\(architecture) at 200M should be usable")
        }
    }

    // MARK: The checks — section 6

    func testARecognisedFamilyIsCompatible() {
        XCTAssertEqual(resolve(record(architecture: "qwen3")), .compatible)
        XCTAssertEqual(resolve(record(architecture: "smollm2")), .compatible)
        XCTAssertEqual(resolve(record(architecture: "llama")), .compatible)
    }

    /// An architecture nobody has tried is offered with the honest label, not
    /// refused. Refusing it would make every upstream model release a reason to
    /// ship an app update.
    func testAnUnknownFamilyIsExperimentalRatherThanRefused() {
        let verdict = resolve(record(architecture: "some-new-arch"))
        XCTAssertEqual(verdict, .experimental)
        XCTAssertTrue(verdict.isUsable)
    }

    func testAMissingFileIsIncompatible() {
        let verdict = resolve(record(architecture: "qwen3"), fileExists: false)
        XCTAssertEqual(verdict, .incompatible(reason: .modelMissing))
        XCTAssertFalse(verdict.isUsable)
    }

    func testNoRecordAtAllIsIncompatible() {
        XCTAssertEqual(resolve(nil), .incompatible(reason: .modelMissing))
    }

    /// No architecture means the header never parsed. That points at the file,
    /// not the family, and the message says so — "could not be read" tells
    /// somebody to re-download, "unsupported architecture" tells them to pick a
    /// different model, and only one of those is the right advice.
    func testAnUnreadableHeaderIsAFileProblem() {
        XCTAssertEqual(
            resolve(record(architecture: nil)), .incompatible(reason: .invalidModelFile)
        )
        XCTAssertEqual(
            resolve(record(architecture: "")), .incompatible(reason: .invalidModelFile)
        )
    }

    func testNoRuntimeIsIncompatible() {
        let verdict = ActionModelCompatibilityResolver.resolve(
            record: record(architecture: "qwen3"), fileExists: true, runtime: nil
        )
        XCTAssertEqual(verdict, .incompatible(reason: .runtimeUnavailable))
    }

    /// The check that ties Part 3 back to Part 2: a runtime that cannot
    /// constrain cannot serve an action request at all, because an
    /// unconstrained action generation is exactly what Part 2 forbids.
    func testARuntimeThatCannotConstrainIsIncompatible() {
        let verdict = resolve(record(architecture: "qwen3"), runtime: unconstrainedRuntime)
        XCTAssertEqual(verdict, .incompatible(reason: .structuredDecodingUnavailable))
        XCTAssertFalse(verdict.isUsable)
    }

    // MARK: What a person is told — section 51

    func testEveryIncompatibilityHasAnActionableSentence() {
        let reasons: [ActionModelIncompatibility] = [
            .modelMissing, .invalidModelFile, .unsupportedArchitecture,
            .runtimeUnavailable, .structuredDecodingUnavailable,
        ]
        for reason in reasons {
            XCTAssertFalse(reason.message.isEmpty, "\(reason.rawValue) has no message")
            // Authored prose, not a native error: no C symbols, no error codes.
            XCTAssertFalse(reason.message.contains("_"))
            XCTAssertTrue(reason.message.hasSuffix("."))
        }
    }

    func testTheLabelsAreTheThreeStatesTheScreenShows() {
        XCTAssertEqual(ActionModelCompatibility.compatible.label, "Compatible")
        XCTAssertEqual(ActionModelCompatibility.experimental.label, "Experimental")
        XCTAssertEqual(
            ActionModelCompatibility.incompatible(reason: .modelMissing).label, "Incompatible"
        )
    }

    // MARK: The action inference policy — sections 23, 25 and 30

    /// Section 30: the action model's settings are its own, and smaller than
    /// the chat model's on every axis that costs memory.
    func testTheActionPolicyIsSmallerThanAChatConfiguration() {
        let action = ActionInferenceProductionPolicy.production.configuration
        let chat = LocalInferenceConfiguration.forDevice(FixedDeviceResources.largePhone)

        XCTAssertLessThan(action.contextLength, chat.contextLength)
        XCTAssertLessThanOrEqual(action.maximumGenerationTokens, chat.maximumGenerationTokens)
        XCTAssertLessThanOrEqual(action.microBatchSize, action.batchSize)
        // Section 25: a short bounded generation.
        XCTAssertLessThanOrEqual(action.maximumGenerationTokens, 256)
        XCTAssertGreaterThanOrEqual(action.maximumGenerationTokens, 64)
    }

    /// A bigger phone does not make this job bigger. The policy is a constant,
    /// where the chat configuration scales with the device — which is right for
    /// a conversation and wrong for an extractor.
    func testTheActionContextDoesNotScaleWithTheDevice() {
        XCTAssertEqual(
            ActionInferenceProductionPolicy.production.configuration.contextLength,
            ActionInferenceProductionPolicy.production.contextLength
        )
        XCTAssertEqual(ActionInferenceProductionPolicy.production.contextLength, 1024)
    }
}
