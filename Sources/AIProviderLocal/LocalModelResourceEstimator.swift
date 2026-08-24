import Foundation
import NativeModelKit

/// A breakdown of what running one model would cost in memory.
///
/// Every field is an estimate and the type says so in its name. What matters is
/// not that the total is right — it cannot be, the runtime allocates things
/// this code does not model — but that it is *conservative*, and that when it
/// is wrong it is wrong in the direction of refusing a model that might have
/// worked rather than accepting one that gets the app killed.
public struct LocalModelMemoryEstimate: Hashable, Sendable {
    /// The weights. Effectively the file size — llama.cpp memory-maps the file
    /// and the pages are resident while in use.
    public var weightsBytes: Int64
    /// K and V for `contextLength` tokens.
    public var kvCacheBytes: Int64
    /// Activations, the compute graph and Metal's own buffers.
    public var computeBufferBytes: Int64
    /// The runtime itself: backend registry, tokenizer, sampler chain.
    public var runtimeOverheadBytes: Int64
    /// The context length this estimate was made for.
    public var contextLength: Int
    /// True when the KV figure came from the model's own header rather than
    /// from the parameter-count fallback.
    public var kvCacheIsMeasured: Bool

    public init(
        weightsBytes: Int64,
        kvCacheBytes: Int64,
        computeBufferBytes: Int64,
        runtimeOverheadBytes: Int64,
        contextLength: Int,
        kvCacheIsMeasured: Bool
    ) {
        self.weightsBytes = weightsBytes
        self.kvCacheBytes = kvCacheBytes
        self.computeBufferBytes = computeBufferBytes
        self.runtimeOverheadBytes = runtimeOverheadBytes
        self.contextLength = contextLength
        self.kvCacheIsMeasured = kvCacheIsMeasured
    }

    public var totalBytes: Int64 {
        weightsBytes + kvCacheBytes + computeBufferBytes + runtimeOverheadBytes
    }
}

/// Turns a model plus a context length into a memory figure.
///
/// ## Why this is centralized
///
/// Because the alternative is the number 0.45 appearing in the compatibility
/// check, a different number in the download screen, and a third one in
/// whatever decides to unload under pressure — and then a device that is told
/// it can download a model it cannot load. One type owns every constant, and
/// every one of them is named and explained.
///
/// ## The one that matters most
///
/// ``usableMemoryFraction``. Section 9: an 8 GB phone does not have 8 GB for
/// this app. iOS reserves memory for itself, other processes stay resident, and
/// an app that grows past its jetsam limit is killed outright with no error to
/// catch. The fraction below is chosen to sit well inside that limit for the
/// device classes this app targets, and it is deliberately pessimistic — the
/// cost of being wrong downwards is "you had to pick a smaller model", and the
/// cost of being wrong upwards is the app disappearing mid-sentence.
public struct LocalModelResourceEstimator: Sendable {
    /// Share of physical RAM this app is willing to plan around using in total.
    ///
    /// Not a limit anything enforces — nothing can enforce it — but the budget
    /// every compatibility answer is measured against.
    public var usableMemoryFraction: Double
    /// Held back for everything that is not the model: SwiftUI, SwiftData, the
    /// conversation, memory, the image cache, the OS's share of the app.
    public var reservedApplicationBytes: Int64
    /// Fixed cost of having a runtime at all.
    public var runtimeOverheadBytes: Int64
    /// Floor for compute and Metal buffers.
    public var minimumComputeBufferBytes: Int64
    /// Compute buffers also scale with the model; this is the share of weights
    /// added on top of the floor.
    public var computeBufferWeightFraction: Double
    /// KV bytes per token when the model file did not say.
    ///
    /// Derived from what phone-sized instruct models actually look like: around
    /// 16–36 transformer blocks with grouped-query attention, which lands
    /// between 24 KB and 40 KB per token for K and V together in f16. 48 KB is
    /// above the top of that range on purpose — this fallback only runs when
    /// the facts are missing, and a fallback that guesses low is a fallback
    /// that approves a model the device cannot hold.
    public var fallbackKVBytesPerToken: Int
    /// Free space wanted beyond the model file itself, so a download does not
    /// fill the disk to the last byte (section 12).
    public var storageHeadroomBytes: Int64

    public init(
        usableMemoryFraction: Double = 0.45,
        reservedApplicationBytes: Int64 = 320 * .megabyte,
        runtimeOverheadBytes: Int64 = 96 * .megabyte,
        minimumComputeBufferBytes: Int64 = 128 * .megabyte,
        computeBufferWeightFraction: Double = 0.12,
        fallbackKVBytesPerToken: Int = 48 * 1024,
        storageHeadroomBytes: Int64 = 1024 * .megabyte
    ) {
        self.usableMemoryFraction = usableMemoryFraction
        self.reservedApplicationBytes = reservedApplicationBytes
        self.runtimeOverheadBytes = runtimeOverheadBytes
        self.minimumComputeBufferBytes = minimumComputeBufferBytes
        self.computeBufferWeightFraction = computeBufferWeightFraction
        self.fallbackKVBytesPerToken = fallbackKVBytesPerToken
        self.storageHeadroomBytes = storageHeadroomBytes
    }

    public static let `default` = LocalModelResourceEstimator()

    /// How much memory the model system may plan to use on this device.
    public func modelMemoryBudget(on device: any DeviceResourceProvider) -> Int64 {
        let usable = Int64(Double(device.physicalMemoryBytes) * usableMemoryFraction)
        return max(0, usable - reservedApplicationBytes)
    }

    /// What one model would cost at one context length.
    ///
    /// `measuredKVBytesPerToken` comes from the GGUF header once the file is on
    /// disk. Before download there is only the catalog, which may or may not
    /// carry the figure — hence the fallback, and hence
    /// ``LocalModelMemoryEstimate/kvCacheIsMeasured`` so the UI can be honest
    /// about which kind of estimate the user is looking at.
    public func estimate(
        weightsBytes: Int64,
        contextLength: Int,
        kvBytesPerToken: Int?
    ) -> LocalModelMemoryEstimate {
        let perToken = kvBytesPerToken ?? fallbackKVBytesPerToken
        let context = max(0, contextLength)
        let kv = Int64(context) * Int64(max(0, perToken))
        let compute = max(
            minimumComputeBufferBytes,
            Int64(Double(weightsBytes) * computeBufferWeightFraction)
        )
        return LocalModelMemoryEstimate(
            weightsBytes: weightsBytes,
            kvCacheBytes: kv,
            computeBufferBytes: compute,
            runtimeOverheadBytes: runtimeOverheadBytes,
            contextLength: context,
            kvCacheIsMeasured: kvBytesPerToken != nil
        )
    }

    /// The same, for a catalog entry the app has not downloaded yet.
    public func estimate(
        for descriptor: LocalModelDescriptor,
        contextLength: Int? = nil
    ) -> LocalModelMemoryEstimate {
        estimate(
            weightsBytes: descriptor.fileSizeBytes ?? expectedFileSize(for: descriptor) ?? 0,
            contextLength: contextLength ?? descriptor.defaultContextLength,
            kvBytesPerToken: descriptor.kvCacheBytesPerToken
        )
    }

    /// Roughly how big the weights should be, from parameters and quantization.
    ///
    /// Used only where the catalog omitted a size, and to notice when a
    /// catalog's declared size is wildly inconsistent with what it claims the
    /// model is.
    public func expectedFileSize(for descriptor: LocalModelDescriptor) -> Int64? {
        guard
            let parameters = descriptor.parameterCount,
            let bits = descriptor.quantization?.approximateBitsPerWeight
        else { return nil }
        return Int64(Double(parameters) * bits / 8)
    }

    /// The largest context that still fits the memory budget.
    ///
    /// Section 11: the same weights load at 2048 and fail at 16384, because the
    /// KV cache is linear in context and the weights are not. Rather than
    /// refusing a model outright, the manager asks for this and opens it
    /// smaller — a shorter conversation is a better outcome than no model.
    public func largestFittingContext(
        weightsBytes: Int64,
        kvBytesPerToken: Int?,
        preferred: Int,
        minimum: Int = 1024,
        on device: any DeviceResourceProvider
    ) -> Int? {
        let budget = modelMemoryBudget(on: device)
        var candidate = preferred
        while candidate >= minimum {
            let estimate = estimate(
                weightsBytes: weightsBytes,
                contextLength: candidate,
                kvBytesPerToken: kvBytesPerToken
            )
            if estimate.totalBytes <= budget { return candidate }
            candidate /= 2
        }
        return nil
    }

    /// Free space needed before a download may start.
    ///
    /// The file, plus the same again while it is in a temporary location, plus
    /// headroom. Section 12's "do not start a 5 GB download when 5.1 GB
    /// remains" is exactly this: the download lands in a temporary file and is
    /// then moved, and on the same volume the move is a rename — but the
    /// temporary file and the final file coexist for the length of the
    /// verification pass, and the phone still needs room to function.
    public func storageRequired(forDownloadOf bytes: Int64) -> Int64 {
        bytes + storageHeadroomBytes
    }
}
