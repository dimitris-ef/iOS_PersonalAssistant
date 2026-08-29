import Foundation
import NativeModelKit

/// Every number the local inference runtime is opened with.
///
/// ## Why this exists
///
/// A 3B model crashed the app when a conversation started — not when it
/// loaded. That timing is the whole diagnosis. `llama_init_from_model`
/// allocates the model and the KV cache; the *compute* buffers are allocated
/// lazily on the first `llama_decode`, and their size is driven by the micro
/// batch, not by the weights. So a model could pass a memory preflight, load
/// successfully, report itself Ready, and then be killed by iOS the moment
/// somebody typed a message.
///
/// Two things follow, and both are here rather than scattered:
///
/// 1. The batch numbers are part of the memory budget, so they have to be
///    knowable *before* the load, by the same code that decides whether the
///    model fits.
/// 2. They must be conservative. llama.cpp's defaults are tuned for a machine
///    with swap and a GPU that is not also drawing the user interface.
///
/// ## What is deliberately not here
///
/// A settings panel. Section 106: no user-editable low-level tuning. These are
/// engineering decisions with one right answer per device class, and exposing
/// them would turn a crash into a support conversation about batch sizes.
public struct LocalInferenceConfiguration: Hashable, Sendable {

    /// Tokens the model is opened with. Bounds the KV cache directly.
    public var contextLength: Int
    /// Tokens per `llama_decode` call. Bounds prompt-processing throughput.
    public var batchSize: Int
    /// Tokens per compute-graph pass. **The number that drives the Metal
    /// compute buffer**, and the one that was too large.
    public var microBatchSize: Int
    /// CPU threads for prompt processing and generation.
    public var threadCount: Int
    /// Upper bound on a single reply, in tokens.
    public var maximumGenerationTokens: Int
    /// Tokens held back from the context for the reply, so a long conversation
    /// cannot leave the model with no room to answer.
    public var generationReserveTokens: Int

    public init(
        contextLength: Int,
        batchSize: Int,
        microBatchSize: Int,
        threadCount: Int,
        maximumGenerationTokens: Int,
        generationReserveTokens: Int
    ) {
        self.contextLength = contextLength
        self.batchSize = batchSize
        self.microBatchSize = microBatchSize
        self.threadCount = threadCount
        self.maximumGenerationTokens = maximumGenerationTokens
        self.generationReserveTokens = generationReserveTokens
    }

    /// The most prompt tokens that may be sent, leaving room for a reply.
    ///
    /// Section 52. A conversation plus its memories plus the tool schemas can
    /// exceed a phone-sized context long before anybody notices, and llama.cpp
    /// does not politely truncate — it is asked to decode more tokens than the
    /// context holds, which is one of the ways this goes wrong natively.
    public var maximumPromptTokens: Int {
        max(256, contextLength - generationReserveTokens)
    }

    // MARK: Device tiers

    /// The configuration for a device, before any model is considered.
    ///
    /// Tiers are chosen on physical memory rather than on device name, because
    /// a name table is a list that is wrong the day a new iPhone ships
    /// (section 45).
    ///
    /// The context numbers are deliberately far below what these models can
    /// technically do — Qwen3 advertises 32768, and a 32k KV cache for a 3B
    /// model is well over a gigabyte on its own. A shorter conversation that
    /// works beats a long one that gets the app terminated.
    public static func forDevice(_ device: any DeviceResourceProvider) -> LocalInferenceConfiguration {
        let gigabytes = Double(device.physicalMemoryBytes) / Double(Int64.gigabyte)

        // Threads: half the cores, floor 2, ceiling 4.
        //
        // Not every core, deliberately. Inference that saturates the CPU
        // starves SwiftUI and the audio session, and on a phone the result is
        // a stuttering interface during generation — which reads as the app
        // hanging. Four is enough to keep the performance cores busy.
        let threads = max(2, min(4, device.processorCount / 2))

        if gigabytes >= 7.5 {
            // 8 GB and up: current Pro hardware.
            return LocalInferenceConfiguration(
                contextLength: 4096,
                batchSize: 256,
                microBatchSize: 128,
                threadCount: threads,
                maximumGenerationTokens: 768,
                generationReserveTokens: 768
            )
        }
        if gigabytes >= 5.5 {
            // 6 GB: the common modern iPhone.
            return LocalInferenceConfiguration(
                contextLength: 3072,
                batchSize: 192,
                microBatchSize: 96,
                threadCount: threads,
                maximumGenerationTokens: 640,
                generationReserveTokens: 640
            )
        }
        // 4 GB and below. Small models only, and a context to match.
        return LocalInferenceConfiguration(
            contextLength: 2048,
            batchSize: 128,
            microBatchSize: 64,
            threadCount: threads,
            maximumGenerationTokens: 512,
            generationReserveTokens: 512
        )
    }

    /// The same configuration at a smaller context.
    ///
    /// Used by the adaptive reduction in `LocalModelManager.load`: rather than
    /// refusing a model whose KV cache will not fit, the manager halves the
    /// context and asks again. The batch is capped to the context too — a batch
    /// larger than the context allocates a buffer it can never fill.
    public func withContextLength(_ length: Int) -> LocalInferenceConfiguration {
        var copy = self
        copy.contextLength = max(512, length)
        copy.batchSize = min(batchSize, copy.contextLength)
        copy.microBatchSize = min(microBatchSize, copy.batchSize)
        copy.generationReserveTokens = min(generationReserveTokens, copy.contextLength / 2)
        return copy
    }

    /// A fixed configuration for tests and previews.
    public static let conservative = LocalInferenceConfiguration(
        contextLength: 2048,
        batchSize: 128,
        microBatchSize: 64,
        threadCount: 2,
        maximumGenerationTokens: 512,
        generationReserveTokens: 512
    )
}
