import Foundation
import NativeModelKit

/// Deliberate handicaps, for isolating a crash.
///
/// ## What these are, and what they are not
///
/// Section 69: these are diagnostic overrides, not performance settings. Every
/// one of them makes inference slower or dumber on purpose, in exchange for
/// removing one variable from the investigation — the GPU, the KV cache size,
/// the batch size, thread concurrency. They belong on a screen labelled
/// Advanced Diagnostics, next to the log, and nowhere near anything a normal
/// user is invited to tune (section 106 of the previous pass forbids a tuning
/// panel, and this is not one: there is no number to type, only a variable to
/// eliminate).
///
/// ## They override, they do not rewrite
///
/// Section 76. Nothing here mutates a stored default. The overrides are applied
/// to a freshly derived ``LocalInferenceConfiguration`` at the moment a model
/// is loaded, so turning them all off restores exactly the automatic behaviour
/// — there is no third state where a "reset" is needed.
public struct LocalInferenceDiagnosticOverrides: Hashable, Sendable, Codable {

    /// Ask for zero GPU offload. Section 70.
    public var forceCPUOnly: Bool
    /// Whether GPU offload is wanted at all, when CPU-only is off. Section 71.
    public var gpuOffloadEnabled: Bool
    /// A deliberately small context. Section 72.
    public var conservativeContext: Bool
    /// Deliberately small batches. Section 73.
    public var conservativeBatch: Bool
    /// Section 74.
    public var threadMode: LocalInferenceThreadMode

    public static let none = LocalInferenceDiagnosticOverrides()

    public init(
        forceCPUOnly: Bool = false,
        gpuOffloadEnabled: Bool = true,
        conservativeContext: Bool = false,
        conservativeBatch: Bool = false,
        threadMode: LocalInferenceThreadMode = .automatic
    ) {
        self.forceCPUOnly = forceCPUOnly
        self.gpuOffloadEnabled = gpuOffloadEnabled
        self.conservativeContext = conservativeContext
        self.conservativeBatch = conservativeBatch
        self.threadMode = threadMode
    }

    /// True when anything is being overridden. Drives the "diagnostics active"
    /// note on the chat screen, so a slow reply has a visible explanation.
    public var isActive: Bool {
        forceCPUOnly || !gpuOffloadEnabled || conservativeContext || conservativeBatch
            || threadMode != .automatic
    }

    /// Whether GPU offload should be requested.
    ///
    /// Section 71: CPU-only wins. Two switches that can disagree about the same
    /// hardware is a configuration nobody can reason about, so this collapses
    /// them into one answer and the UI disables the GPU switch while CPU-only
    /// is on rather than letting them contradict each other.
    public var wantsGPUOffload: Bool {
        forceCPUOnly ? false : gpuOffloadEnabled
    }

    /// The deliberately small context. Not a literal in a view (section 72) —
    /// it is the conservative tier the runtime policy already defines.
    public static var conservativeContextLength: Int {
        LocalInferenceConfiguration.conservative.contextLength
    }

    public func metadata() -> LocalInferenceMetadata {
        LocalInferenceMetadata()
            .setting(.cpuOnly, forceCPUOnly)
            .setting(.requestedGPUOffload, wantsGPUOffload)
            .setting(.conservativeContext, conservativeContext)
            .setting(.conservativeBatch, conservativeBatch)
            .setting(.threadMode, threadMode.rawValue)
    }

    /// Applies the overrides to a configuration the device policy produced.
    public func apply(to configuration: LocalInferenceConfiguration) -> LocalInferenceConfiguration {
        var result = configuration

        if conservativeContext {
            // `withContextLength` also caps the batches to the new context, so
            // this cannot produce a batch larger than the context it feeds.
            result = result.withContextLength(
                min(result.contextLength, Self.conservativeContextLength)
            )
        }
        if conservativeBatch {
            let conservative = LocalInferenceConfiguration.conservative
            result.batchSize = min(result.batchSize, conservative.batchSize)
            result.microBatchSize = min(result.microBatchSize, conservative.microBatchSize)
        }
        result.threadCount = threadMode.threadCount(automatic: result.threadCount)
        // The micro batch can never exceed the batch. Enforced after every
        // override rather than trusted from each one, because two overrides
        // that are each individually fine can compose into a configuration that
        // is not.
        result.microBatchSize = min(result.microBatchSize, result.batchSize)
        return result
    }
}

/// How many threads inference may use, as a diagnostic axis.
public enum LocalInferenceThreadMode: String, Hashable, Sendable, Codable, CaseIterable {
    /// The device policy decides. The normal setting.
    case automatic
    /// Two threads. Enough to make progress, few enough to change the shape of
    /// a concurrency problem if there is one.
    case low
    /// One thread. Removes intra-op parallelism entirely — if a crash survives
    /// this, it is not a data race between worker threads.
    case single

    public var displayName: String {
        switch self {
        case .automatic: return "Automatic"
        case .low: return "Low (2 threads)"
        case .single: return "Single thread"
        }
    }

    public func threadCount(automatic value: Int) -> Int {
        switch self {
        case .automatic: return value
        case .low: return min(2, value)
        case .single: return 1
        }
    }
}
