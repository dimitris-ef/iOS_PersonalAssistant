import AssistantAI
import AssistantDomain
import Foundation
import NativeModelKit
import XCTest

@testable import AIProviderLocal

/// What normal inference asks the hardware for, and what an investigator may
/// take away.
///
/// ## The failure these exist for
///
/// Local inference on a real phone was extremely slow, because during the crash
/// investigation testers were told to turn CPU-only on and GPU offload off —
/// and those settings were still there, several builds later, with nothing to
/// clear them and nothing on any screen saying they were the reason.
///
/// The defect was not a bad default: `gpuOffloadEnabled` already defaulted to
/// true. It was that there was no distinction between "the app wants GPU" and
/// "nobody has said otherwise", so persisted investigation residue was
/// indistinguishable from a current, deliberate choice and outlived its purpose
/// indefinitely.
final class LocalInferenceAccelerationTests: XCTestCase {

    private let policy = LocalInferenceProductionPolicy.production

    // MARK: Production

    /// Section 55. A user who has never opened Advanced Diagnostics gets the
    /// GPU.
    func testProductionAsksForGPUOffload() {
        XCTAssertTrue(policy.requestsGPUOffload)
        XCTAssertTrue(policy.wantsGPUOffload(with: .none))
        XCTAssertTrue(policy.isProductionProfile(with: .none))
    }

    /// Section 24. Absence is not a request for CPU-only.
    func testDefaultOverridesDoNotDisableTheGPU() {
        let defaults = LocalInferenceDiagnosticOverrides()
        XCTAssertFalse(defaults.forceCPUOnly)
        XCTAssertTrue(defaults.gpuOffloadEnabled)
        XCTAssertTrue(defaults.wantsGPUOffload)
        XCTAssertFalse(defaults.isActive)
    }

    // MARK: Overrides

    /// Section 56. When somebody turns it off, it is off.
    func testForcingCPUOnlyOverridesProduction() {
        let overrides = LocalInferenceDiagnosticOverrides(forceCPUOnly: true)
        XCTAssertFalse(policy.wantsGPUOffload(with: overrides))
        XCTAssertFalse(policy.isProductionProfile(with: overrides))
    }

    /// CPU-only wins over the GPU switch, so the two can never disagree about
    /// the same hardware.
    func testCPUOnlyBeatsAnEnabledGPUSwitch() {
        let overrides = LocalInferenceDiagnosticOverrides(
            forceCPUOnly: true, gpuOffloadEnabled: true
        )
        XCTAssertFalse(policy.wantsGPUOffload(with: overrides))
    }

    /// Section 57. Turning the override back off restores production.
    func testClearingTheOverrideRestoresGPU() {
        var overrides = LocalInferenceDiagnosticOverrides(forceCPUOnly: true)
        XCTAssertFalse(policy.wantsGPUOffload(with: overrides))
        overrides.forceCPUOnly = false
        XCTAssertTrue(policy.wantsGPUOffload(with: overrides))
        XCTAssertTrue(policy.isProductionProfile(with: overrides))
    }

    /// Section 45. A phone left in a diagnostic configuration says so.
    func testAnyActiveOverrideLeavesTheProductionProfile() {
        let handicaps: [LocalInferenceDiagnosticOverrides] = [
            .init(forceCPUOnly: true),
            .init(gpuOffloadEnabled: false),
            .init(conservativeContext: true),
            .init(conservativeBatch: true),
            .init(threadMode: .single),
        ]
        for overrides in handicaps {
            XCTAssertFalse(
                policy.isProductionProfile(with: overrides),
                "\(overrides) should not read as production"
            )
        }
    }

    // MARK: Migration

    /// Section 58. The exact situation on testers' phones.
    func testInvestigationEraSettingsAreResetOnce() {
        let residue = LocalInferenceDiagnosticOverrides(
            forceCPUOnly: true,
            gpuOffloadEnabled: false,
            conservativeContext: true,
            conservativeBatch: true,
            threadMode: .low
        )
        let outcome = LocalInferenceSettingsMigration.migrate(
            residue, storedVersion: LocalInferenceSettingsVersion.crashInvestigation
        )

        XCTAssertTrue(outcome.didReset)
        XCTAssertEqual(outcome.overrides, .none)
        XCTAssertTrue(policy.wantsGPUOffload(with: outcome.overrides))
        XCTAssertTrue(policy.isProductionProfile(with: outcome.overrides))
    }

    /// Section 59. A choice made with this build's behaviour visible is a real
    /// choice, and resetting it every launch would make the switch useless.
    func testACurrentDeliberateChoiceSurvivesMigration() {
        let deliberate = LocalInferenceDiagnosticOverrides(forceCPUOnly: true)
        let outcome = LocalInferenceSettingsMigration.migrate(
            deliberate, storedVersion: LocalInferenceSettingsVersion.current
        )

        XCTAssertFalse(outcome.didReset)
        XCTAssertEqual(outcome.overrides, deliberate)
        XCTAssertFalse(policy.wantsGPUOffload(with: outcome.overrides))
    }

    /// An old blob with nothing turned on has nothing to undo, and must not be
    /// reported as a reset — the flag drives a log line, and a reset that did
    /// not happen would be a false one.
    func testAnOldButInactiveBlobIsNotReported() {
        let outcome = LocalInferenceSettingsMigration.migrate(
            .none, storedVersion: LocalInferenceSettingsVersion.crashInvestigation
        )
        XCTAssertFalse(outcome.didReset)
        XCTAssertEqual(outcome.overrides, .none)
    }

    /// Section 60. Whatever was set, one action undoes all of it.
    func testResettingToProductionDefaultsClearsEveryPerformanceAxis() {
        let everything = LocalInferenceDiagnosticOverrides(
            forceCPUOnly: true,
            gpuOffloadEnabled: false,
            conservativeContext: true,
            conservativeBatch: true,
            threadMode: .single
        )
        XCTAssertTrue(everything.isActive)

        let reset = LocalInferenceDiagnosticOverrides.none
        XCTAssertFalse(reset.isActive)
        XCTAssertFalse(reset.forceCPUOnly)
        XCTAssertTrue(reset.gpuOffloadEnabled)
        XCTAssertFalse(reset.conservativeContext)
        XCTAssertFalse(reset.conservativeBatch)
        XCTAssertEqual(reset.threadMode, .automatic)
        XCTAssertTrue(policy.isProductionProfile(with: reset))
    }

    // MARK: Requested versus actual

    /// Section 61 and 70. The two are different claims and only one of them is
    /// something this build can make.
    func testTheOverrideMetadataReportsWhatWasRequested() {
        let metadata = LocalInferenceDiagnosticOverrides.none.metadata()
        XCTAssertEqual(metadata[.requestedGPUOffload], .bool(true))
        XCTAssertEqual(metadata[.cpuOnly], .bool(false))

        let cpuOnly = LocalInferenceDiagnosticOverrides(forceCPUOnly: true).metadata()
        XCTAssertEqual(cpuOnly[.requestedGPUOffload], .bool(false))
        XCTAssertEqual(cpuOnly[.cpuOnly], .bool(true))
    }

    // MARK: Conservative policy is preserved

    /// Section 33. Restoring the GPU is not permission to raise every limit —
    /// the memory policy that stopped the app being killed is untouched.
    func testRestoringGPUDoesNotEnlargeTheConservativeConfiguration() {
        let conservative = LocalInferenceConfiguration.conservative
        let applied = LocalInferenceDiagnosticOverrides.none.apply(to: conservative)
        XCTAssertEqual(applied.contextLength, conservative.contextLength)
        XCTAssertEqual(applied.batchSize, conservative.batchSize)
        XCTAssertEqual(applied.microBatchSize, conservative.microBatchSize)
        XCTAssertLessThanOrEqual(applied.microBatchSize, applied.batchSize)
    }

    // MARK: Chunking is independent of acceleration

    /// Sections 34, 37 and 63. The chunk planner reads `n_batch` from the
    /// context, and the GPU changes neither. Asserted because "we turned the
    /// GPU back on" is exactly the kind of change that invites somebody to
    /// wonder whether the batching workaround is still needed.
    func testChunkPlanningIsUnaffectedByGPUState() {
        let plan = PromptDecodeChunkPlanner.plan(
            tokenCount: 1241, basePosition: 0, nBatch: 128, nUBatch: 64
        )
        XCTAssertEqual(plan.chunks.count, 10)
        XCTAssertEqual(
            plan.chunks.map(\.tokenCount),
            [128, 128, 128, 128, 128, 128, 128, 128, 128, 89]
        )
        XCTAssertEqual(plan.decodedTokenCount, 1241)
        // The planner takes no acceleration parameter at all, which is the
        // structural version of this guarantee: there is nothing for a GPU
        // setting to change.
        XCTAssertTrue(plan.chunks.allSatisfy { $0.tokenCount <= 128 })
    }
}
