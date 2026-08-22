import AssistantAI
import AssistantDomain
import XCTest
@testable import AIProviderLocal

/// Whether a model is offered, and whether the app is honest about why not.
///
/// Every test here injects the device (sections 91 and 92). A test that read
/// the CI machine's real RAM would assert whatever GitHub allocated that
/// morning, and would pass or fail for reasons that have nothing to do with the
/// policy it claims to be checking.
final class LocalModelCompatibilityTests: XCTestCase {
    private let policy = LocalModelCompatibilityPolicy.default

    private func model(
        id: AIModelIdentifier = "test-model",
        bytes: Int64,
        context: Int = 4096,
        kvPerToken: Int? = 32 * 1024,
        format: LocalModelFormat = .gguf,
        toolSupport: LocalModelToolSupport = .supported,
        quantization: LocalModelQuantization? = .q4KM
    ) -> LocalModelDescriptor {
        LocalModelDescriptor(
            id: id,
            displayName: "Test Model",
            architecture: "qwen3",
            parameterCount: 1_700_000_000,
            quantization: quantization,
            format: format,
            fileSizeBytes: bytes,
            downloadURL: URL(string: "https://example.invalid/model.gguf"),
            defaultContextLength: context,
            kvCacheBytesPerToken: kvPerToken,
            toolSupport: toolSupport
        )
    }

    // MARK: Memory

    /// Section 91. A 1 GB model on a phone with room for it.
    func testASmallModelIsAcceptedOnACapableDevice() {
        let verdict = policy.compatibility(
            of: model(bytes: 1_100_000_000),
            on: FixedDeviceResources.largePhone,
            runtime: .idle
        )
        XCTAssertTrue(verdict.permitsDownload)
        XCTAssertEqual(policy.tier(for: verdict), .recommended)
    }

    /// The same model on a phone that cannot hold it.
    func testAnOversizedModelIsRefusedOnASmallDevice() {
        let verdict = policy.compatibility(
            of: model(bytes: 4_500_000_000, kvPerToken: 48 * 1024),
            on: FixedDeviceResources.smallPhone,
            runtime: .idle
        )
        XCTAssertFalse(verdict.permitsDownload)
        guard case .likelyTooLarge = verdict else {
            return XCTFail("expected likelyTooLarge, got \(verdict)")
        }
        // The reason has to be readable, because it is what the user sees.
        XCTAssertTrue(verdict.reason?.contains("memory") == true)
    }

    /// Section 9. The check must not assume the app gets all of physical RAM.
    ///
    /// A 6 GB device with a 5 GB model is nonsense, and a policy that compared
    /// against `physicalMemory` directly would wave it through.
    func testTheBudgetIsWellBelowPhysicalMemory() {
        let device = FixedDeviceResources.midPhone
        let budget = policy.estimator.modelMemoryBudget(on: device)

        XCTAssertLessThan(budget, device.physicalMemoryBytes / 2)
        XCTAssertGreaterThan(budget, 0)

        let verdict = policy.compatibility(
            of: model(bytes: 5 * .gigabyte),
            on: device,
            runtime: .idle
        )
        XCTAssertFalse(verdict.permitsDownload)
    }

    /// Section 11. The same weights fit at 2048 and do not at 16384, and the
    /// answer is a shorter context rather than a refusal.
    func testALongContextIsTradedDownRatherThanRefused() {
        let device = FixedDeviceResources.midPhone
        let short = policy.compatibility(
            of: model(bytes: 1_100_000_000, context: 2048),
            on: device,
            runtime: .idle
        )
        let long = policy.compatibility(
            of: model(bytes: 1_100_000_000, context: 65536),
            on: device,
            runtime: .idle
        )

        XCTAssertTrue(short.permitsDownload)
        XCTAssertTrue(long.permitsDownload, "a long context must not disqualify the model")
        guard case .compatibleWithWarning(let reason) = long else {
            return XCTFail("expected a warning about the shortened context, got \(long)")
        }
        XCTAssertTrue(reason.contains("shorter"))
    }

    /// The KV cache really is what makes context expensive.
    func testContextLengthDominatesTheEstimateForASmallModel() {
        let estimator = LocalModelResourceEstimator.default
        let short = estimator.estimate(
            weightsBytes: 1_100_000_000, contextLength: 2048, kvBytesPerToken: 32 * 1024
        )
        let long = estimator.estimate(
            weightsBytes: 1_100_000_000, contextLength: 32768, kvBytesPerToken: 32 * 1024
        )

        XCTAssertEqual(short.weightsBytes, long.weightsBytes)
        XCTAssertGreaterThan(long.kvCacheBytes, short.kvCacheBytes * 10)
        XCTAssertGreaterThan(long.totalBytes, short.totalBytes)
    }

    /// A missing KV figure falls back conservatively rather than optimistically.
    func testAMissingKVFigureIsEstimatedPessimistically() {
        let estimator = LocalModelResourceEstimator.default
        let measured = estimator.estimate(
            weightsBytes: 1_000_000_000, contextLength: 4096, kvBytesPerToken: 24 * 1024
        )
        let guessed = estimator.estimate(
            weightsBytes: 1_000_000_000, contextLength: 4096, kvBytesPerToken: nil
        )

        XCTAssertTrue(measured.kvCacheIsMeasured)
        XCTAssertFalse(guessed.kvCacheIsMeasured)
        XCTAssertGreaterThan(
            guessed.kvCacheBytes,
            measured.kvCacheBytes,
            "a guess that comes in under a real measurement is a guess that approves too much"
        )
    }

    // MARK: Storage

    /// Section 92 and section 12. Space for the file is not space for the
    /// download.
    func testADownloadIsRefusedWhenStorageIsTight() {
        let device = FixedDeviceResources(
            physicalMemoryBytes: 8 * .gigabyte,
            storageBytes: 1_200_000_000
        )
        let verdict = policy.compatibility(
            of: model(bytes: 1_100_000_000),
            on: device,
            runtime: .idle
        )
        guard case .insufficientStorage = verdict else {
            return XCTFail("expected insufficientStorage, got \(verdict)")
        }
        XCTAssertFalse(verdict.permitsDownload)
    }

    /// …and the same model already on disk is loadable, because storage no
    /// longer matters once the bytes are here.
    func testAnInstalledModelIsNotBlockedByStorage() {
        let device = FixedDeviceResources(
            physicalMemoryBytes: 8 * .gigabyte,
            storageBytes: 100_000_000
        )
        let verdict = policy.compatibility(
            of: model(bytes: 1_100_000_000),
            on: device,
            runtime: .idle,
            isInstalled: true
        )
        XCTAssertTrue(verdict.permitsLoad)
    }

    func testTheStorageRequirementLeavesHeadroom() {
        let required = LocalModelResourceEstimator.default
            .storageRequired(forDownloadOf: 5 * .gigabyte)
        XCTAssertGreaterThan(required, 5 * .gigabyte)
    }

    // MARK: Format, architecture and runtime

    /// Section 5 and section 93. Anything that is not GGUF is marked
    /// incompatible rather than attempted.
    func testANonGGUFModelIsUnsupported() {
        for format in [LocalModelFormat.mlx, .coreML, .executorch, .other] {
            let verdict = policy.compatibility(
                of: model(bytes: 500_000_000, format: format),
                on: FixedDeviceResources.largePhone,
                runtime: .idle
            )
            guard case .unsupportedFormat = verdict else {
                return XCTFail("expected unsupportedFormat for \(format), got \(verdict)")
            }
            XCTAssertFalse(verdict.permitsDownload)
        }
    }

    /// Section 19 of the acceptance list: no runtime is a truthful "no", not a
    /// silent one.
    func testNoRuntimeMeansUnsupportedForEveryModel() {
        let verdict = policy.compatibility(
            of: model(bytes: 100_000_000),
            on: FixedDeviceResources.largePhone,
            runtime: .unavailable(reason: "no runtime in this build")
        )
        guard case .unsupportedOS(let reason) = verdict else {
            return XCTFail("expected unsupportedOS, got \(verdict)")
        }
        XCTAssertEqual(reason, "no runtime in this build")
    }

    /// An architecture allow-list, when one is configured, is respected.
    func testAnUnsupportedArchitectureIsRefused() {
        let strict = LocalModelCompatibilityPolicy(supportedArchitectures: ["llama"])
        let verdict = strict.compatibility(
            of: model(bytes: 500_000_000),
            on: FixedDeviceResources.largePhone,
            runtime: .idle
        )
        guard case .unsupportedArchitecture = verdict else {
            return XCTFail("expected unsupportedArchitecture, got \(verdict)")
        }
    }

    /// Section 16. A model behind an acceptance gate cannot be fetched by an
    /// app with no credential, and pretending otherwise produces a download
    /// that fails with an authentication error nobody can act on.
    func testAGatedLicenceBlocksTheDownload() {
        var descriptor = model(bytes: 500_000_000)
        descriptor.license = LocalModelLicense(
            identifier: "custom",
            displayName: "Community Licence",
            isRedistributable: false
        )
        let verdict = policy.compatibility(
            of: descriptor,
            on: FixedDeviceResources.largePhone,
            runtime: .idle
        )
        XCTAssertFalse(verdict.permitsDownload)
    }

    // MARK: Unknown metadata

    /// A catalog entry missing its size is a warning, not a wall.
    ///
    /// The file's own header is read after download and is the check that
    /// actually knows; refusing here would turn a metadata gap into a product
    /// limitation.
    func testAnUnsizedModelIsOfferedWithAWarning() {
        var descriptor = model(bytes: 0)
        descriptor.fileSizeBytes = nil
        descriptor.parameterCount = nil
        let verdict = policy.compatibility(
            of: descriptor,
            on: FixedDeviceResources.largePhone,
            runtime: .idle
        )
        guard case .unknown = verdict else {
            return XCTFail("expected unknown, got \(verdict)")
        }
        XCTAssertTrue(verdict.permitsDownload)
    }

    // MARK: Labels

    /// Section 121. Nothing in a user-facing label may promise a speed.
    func testNoCompatibilityLabelClaimsAPerformanceFigure() {
        let labels = [
            LocalModelCompatibility.compatible,
            .compatibleWithWarning(reason: "x"),
            .likelyTooLarge(reason: "x"),
            .insufficientStorage(reason: "x"),
            .unsupportedFormat(reason: "x"),
            .unsupportedArchitecture(reason: "x"),
            .unsupportedOS(reason: "x"),
            .unknown(reason: "x"),
        ].map(\.shortLabel)

        for label in labels {
            for forbidden in ["token", "/s", "per second", "fast", "ms"] {
                XCTAssertFalse(
                    label.lowercased().contains(forbidden),
                    "\(label) claims a performance figure this app has not measured"
                )
            }
        }
    }

    /// Every tier a verdict can produce has a label, and the ordering is the
    /// one the list sorts by.
    func testTiersAreOrderedBestFirst() {
        XCTAssertLessThan(LocalModelTier.recommended, .usable)
        XCTAssertLessThan(LocalModelTier.usable, .heavy)
        XCTAssertLessThan(LocalModelTier.heavy, .notRecommended)
    }
}
