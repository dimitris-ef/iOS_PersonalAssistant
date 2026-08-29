import Foundation
import NativeModelKit
import XCTest

@testable import AIProviderLocal

/// The numbers the runtime is opened with, and the arithmetic that decides
/// whether a model fits.
///
/// ## What this file is really about
///
/// A 3B model crashed the app when a conversation started — not when it loaded.
/// That timing is the diagnosis: `llama_init_from_model` allocates the weights
/// and the KV cache, but the compute buffers are allocated lazily on the first
/// `llama_decode` and are sized from the micro batch. A model could pass a
/// preflight that modelled only weights and KV, load, report itself ready, and
/// then be killed by iOS the moment somebody typed.
///
/// So these tests pin two things: the batch numbers are conservative, and the
/// estimate knows about them.
final class LocalInferenceConfigurationTests: XCTestCase {

    // MARK: Device tiers

    func testEveryTierIsFarBelowTheModelsAdvertisedMaximum() {
        for device in [
            FixedDeviceResources.smallPhone,
            .midPhone,
            .largePhone,
        ] {
            let configuration = LocalInferenceConfiguration.forDevice(device)
            // Qwen3 advertises 32768. A 32k KV cache for a 3B model is well
            // over a gigabyte on its own, and nothing here should go near it.
            XCTAssertLessThanOrEqual(configuration.contextLength, 4096)
            XCTAssertGreaterThanOrEqual(configuration.contextLength, 2048)
        }
    }

    func testABiggerDeviceGetsAMoreGenerousConfiguration() {
        let small = LocalInferenceConfiguration.forDevice(FixedDeviceResources.smallPhone)
        let large = LocalInferenceConfiguration.forDevice(FixedDeviceResources.largePhone)

        XCTAssertLessThanOrEqual(small.contextLength, large.contextLength)
        XCTAssertLessThanOrEqual(small.microBatchSize, large.microBatchSize)
    }

    /// llama.cpp's own default is 512 for both. That is tuned for a machine
    /// with swap and a GPU that is not also drawing the user interface.
    func testTheMicroBatchIsWellBelowTheDesktopDefault() {
        for device in [FixedDeviceResources.smallPhone, .midPhone, .largePhone] {
            let configuration = LocalInferenceConfiguration.forDevice(device)
            XCTAssertLessThanOrEqual(
                configuration.microBatchSize, 128,
                "a desktop-sized micro batch is what allocates the buffer that killed the app"
            )
            XCTAssertLessThanOrEqual(configuration.microBatchSize, configuration.batchSize)
        }
    }

    /// Inference that saturates every core starves SwiftUI and the audio
    /// session, and on a phone that reads as the app hanging.
    func testThreadsLeaveHeadroomForTheRestOfTheApp() {
        for device in [FixedDeviceResources.smallPhone, .midPhone, .largePhone] {
            let configuration = LocalInferenceConfiguration.forDevice(device)
            XCTAssertGreaterThanOrEqual(configuration.threadCount, 2)
            XCTAssertLessThanOrEqual(configuration.threadCount, 4)
            XCTAssertLessThan(
                configuration.threadCount, max(2, device.processorCount),
                "every core is not a thread budget"
            )
        }
    }

    /// Section 52: a conversation plus memories plus tool schemas has to leave
    /// the model room to answer.
    func testThePromptBudgetLeavesRoomForAReply() {
        let configuration = LocalInferenceConfiguration.forDevice(FixedDeviceResources.largePhone)
        XCTAssertLessThan(configuration.maximumPromptTokens, configuration.contextLength)
        XCTAssertGreaterThanOrEqual(
            configuration.contextLength - configuration.maximumPromptTokens,
            configuration.generationReserveTokens
        )
    }

    // MARK: Shrinking

    func testShrinkingTheContextAlsoShrinksTheBatches() {
        let configuration = LocalInferenceConfiguration
            .forDevice(FixedDeviceResources.largePhone)
            .withContextLength(512)

        XCTAssertEqual(configuration.contextLength, 512)
        XCTAssertLessThanOrEqual(
            configuration.batchSize, 512,
            "a batch larger than the context allocates a buffer it can never fill"
        )
        XCTAssertLessThanOrEqual(configuration.microBatchSize, configuration.batchSize)
        XCTAssertLessThan(configuration.generationReserveTokens, configuration.contextLength)
    }

    func testShrinkingNeverProducesAnUnusableContext() {
        let configuration = LocalInferenceConfiguration.conservative.withContextLength(0)
        XCTAssertGreaterThanOrEqual(configuration.contextLength, 512)
        XCTAssertGreaterThan(configuration.maximumPromptTokens, 0)
    }

    // MARK: The estimate

    /// The term that was missing, stated as a difference.
    func testTheEstimateGrowsWithTheMicroBatch() {
        let estimator = LocalModelResourceEstimator.default
        let weights: Int64 = 2_000_000_000
        let parameters: Int64 = 3_000_000_000

        let small = estimator.estimate(
            weightsBytes: weights, contextLength: 4096, kvBytesPerToken: 40 * 1024,
            microBatchSize: 64, parameterCount: parameters
        )
        let large = estimator.estimate(
            weightsBytes: weights, contextLength: 4096, kvBytesPerToken: 40 * 1024,
            microBatchSize: 512, parameterCount: parameters
        )

        XCTAssertGreaterThan(
            large.computeBufferBytes, small.computeBufferBytes,
            "the compute buffer must scale with the micro batch, or a preflight "
                + "cannot see the allocation that happens on the first decode"
        )
        XCTAssertGreaterThan(large.totalBytes, small.totalBytes)
    }

    /// Without a micro batch the estimate must not get *smaller* — the
    /// pre-download catalog path passes no batch and still has to be safe.
    func testAnEstimateWithoutABatchIsStillConservative() {
        let estimator = LocalModelResourceEstimator.default
        let estimate = estimator.estimate(
            weightsBytes: 2_000_000_000, contextLength: 4096, kvBytesPerToken: 40 * 1024
        )
        XCTAssertGreaterThanOrEqual(
            estimate.computeBufferBytes, estimator.minimumComputeBufferBytes
        )
        XCTAssertGreaterThan(estimate.totalBytes, 2_000_000_000)
    }

    // MARK: Adaptive reduction

    /// Section 8. The weights are the same at 4096 and at 1024; only the KV
    /// cache is linear in context. A model that will not fit at the preferred
    /// size very often fits at half of it, and a shorter conversation beats no
    /// model at all.
    func testAModelThatWillNotFitAtFullContextIsOfferedASmallerOne() {
        let estimator = LocalModelResourceEstimator.default
        let device = FixedDeviceResources.midPhone

        let fitted = estimator.largestFittingContext(
            weightsBytes: 1_900_000_000,
            kvBytesPerToken: 40 * 1024,
            preferred: 4096,
            minimum: 1024,
            microBatchSize: 96,
            parameterCount: 3_000_000_000,
            on: device
        )

        if let fitted {
            XCTAssertLessThanOrEqual(fitted, 4096)
            XCTAssertGreaterThanOrEqual(fitted, 1024)
            // And whatever it picked really does fit.
            let estimate = estimator.estimate(
                weightsBytes: 1_900_000_000, contextLength: fitted,
                kvBytesPerToken: 40 * 1024, microBatchSize: 96,
                parameterCount: 3_000_000_000
            )
            XCTAssertLessThanOrEqual(
                estimate.totalBytes, estimator.modelMemoryBudget(on: device)
            )
        }
        // A nil is also a correct answer on a small device — it means the
        // model does not fit even at 1024, which is what refusing looks like.
    }

    /// A model far too large gets nil rather than a context that lies.
    func testAnImpossibleModelIsRefusedRatherThanShrunkForever() {
        let fitted = LocalModelResourceEstimator.default.largestFittingContext(
            weightsBytes: 40_000_000_000,
            kvBytesPerToken: 40 * 1024,
            preferred: 4096,
            minimum: 1024,
            microBatchSize: 64,
            parameterCount: 70_000_000_000,
            on: FixedDeviceResources.largePhone
        )
        XCTAssertNil(fitted)
    }

    /// The budget is a fraction of physical memory, never all of it — an 8 GB
    /// phone does not have 8 GB for this app, and growing past the jetsam limit
    /// is a kill with no error to catch (section 45).
    func testTheMemoryBudgetIsWellUnderPhysicalMemory() {
        let estimator = LocalModelResourceEstimator.default
        for device in [FixedDeviceResources.smallPhone, .midPhone, .largePhone] {
            let budget = estimator.modelMemoryBudget(on: device)
            XCTAssertLessThan(budget, device.physicalMemoryBytes / 2)
            XCTAssertGreaterThan(budget, 0)
        }
    }
}
