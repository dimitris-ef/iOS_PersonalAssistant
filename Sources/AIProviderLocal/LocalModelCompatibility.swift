import Foundation

/// Whether a model would run on this device, and if not, why not.
///
/// Ordered from "yes" to "no". The cases are the ones a user can act on:
/// `insufficientStorage` means delete something, `likelyTooLarge` means pick a
/// smaller model, `unsupportedFormat` means this app will never run it. A
/// single `false` would have told them none of that.
public enum LocalModelCompatibility: Hashable, Sendable {
    case compatible
    /// It should run, with a caveat worth reading first.
    case compatibleWithWarning(reason: String)
    /// The estimate says it does not fit in memory.
    case likelyTooLarge(reason: String)
    case insufficientStorage(reason: String)
    /// Not GGUF.
    case unsupportedFormat(reason: String)
    /// GGUF, but an architecture this build's runtime does not implement.
    case unsupportedArchitecture(reason: String)
    /// The device or OS cannot run local inference at all.
    case unsupportedOS(reason: String)
    /// Not enough information to judge. Treated as permission to try, with a
    /// warning — refusing on missing metadata would make every model the
    /// catalog under-describes unusable.
    case unknown(reason: String)

    /// Whether the app will let a download start.
    ///
    /// `unknown` says yes. The alternative — refuse anything the catalog did
    /// not fully describe — turns a metadata gap into a product limitation, and
    /// the file's own header is read after download anyway, which is the check
    /// that actually knows.
    public var permitsDownload: Bool {
        switch self {
        case .compatible, .compatibleWithWarning, .unknown:
            return true
        case .likelyTooLarge, .insufficientStorage, .unsupportedFormat,
             .unsupportedArchitecture, .unsupportedOS:
            return false
        }
    }

    /// Whether the app will attempt to load it.
    ///
    /// Storage no longer matters once the file is here, so an installed model
    /// whose only complaint was disk space is loadable.
    public var permitsLoad: Bool {
        switch self {
        case .compatible, .compatibleWithWarning, .unknown, .insufficientStorage:
            return true
        case .likelyTooLarge, .unsupportedFormat, .unsupportedArchitecture, .unsupportedOS:
            return false
        }
    }

    public var reason: String? {
        switch self {
        case .compatible:
            return nil
        case .compatibleWithWarning(let reason),
             .likelyTooLarge(let reason),
             .insufficientStorage(let reason),
             .unsupportedFormat(let reason),
             .unsupportedArchitecture(let reason),
             .unsupportedOS(let reason),
             .unknown(let reason):
            return reason
        }
    }

    /// The badge text in the model list.
    ///
    /// Section 71: labels about fit, never about speed. "Recommended" is a
    /// claim this code can support from RAM and file size; "30 tokens per
    /// second" is a claim only a real device can support, and section 121 is
    /// right that it must not be made here.
    public var shortLabel: String {
        switch self {
        case .compatible: return "Recommended"
        case .compatibleWithWarning: return "Should work"
        case .likelyTooLarge: return "Not enough memory"
        case .insufficientStorage: return "Not enough storage"
        case .unsupportedFormat: return "Unsupported"
        case .unsupportedArchitecture: return "Unsupported"
        case .unsupportedOS: return "Unsupported"
        case .unknown: return "May be slow"
        }
    }
}

/// The coarse fit bands the list sorts and colours by (section 122).
public enum LocalModelTier: Int, Hashable, Sendable, Comparable, CaseIterable {
    case recommended = 0
    case usable = 1
    case heavy = 2
    case notRecommended = 3

    public static func < (lhs: LocalModelTier, rhs: LocalModelTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var label: String {
        switch self {
        case .recommended: return "Recommended"
        case .usable: return "Should work"
        case .heavy: return "May be slow"
        case .notRecommended: return "Not recommended"
        }
    }
}

/// Decides whether a model and a device belong together.
///
/// Pure, synchronous and injected with everything it reads, which is what makes
/// section 91 and section 92 testable: the same policy answers for a 3 GB phone
/// and an 8 GB one because the device is an argument, not an ambient fact.
public struct LocalModelCompatibilityPolicy: Sendable {
    public var estimator: LocalModelResourceEstimator
    /// Architectures the linked runtime is known to handle. Empty means "do not
    /// second-guess the runtime" — llama.cpp supports a long and growing list,
    /// and a hard-coded allow-list here would reject new model families for no
    /// reason other than that this file is old.
    public var supportedArchitectures: Set<String>
    /// Share of the memory budget above which a model is offered with a
    /// warning rather than a recommendation.
    public var comfortableFraction: Double

    public init(
        estimator: LocalModelResourceEstimator = .default,
        supportedArchitectures: Set<String> = [],
        comfortableFraction: Double = 0.8
    ) {
        self.estimator = estimator
        self.supportedArchitectures = supportedArchitectures
        self.comfortableFraction = comfortableFraction
    }

    public static let `default` = LocalModelCompatibilityPolicy()

    /// The verdict for a catalog entry on a device, before it is downloaded.
    public func compatibility(
        of descriptor: LocalModelDescriptor,
        on device: any DeviceResourceProvider,
        runtime: LocalRuntimeAvailability,
        isInstalled: Bool = false
    ) -> LocalModelCompatibility {
        if case .unavailable(let reason) = runtime {
            return .unsupportedOS(reason: reason)
        }

        guard descriptor.isRunnableFormat else {
            return .unsupportedFormat(
                reason: "\(descriptor.format.displayName) models cannot run in this app. "
                    + "Only GGUF models are supported."
            )
        }

        if !supportedArchitectures.isEmpty,
           !supportedArchitectures.contains(descriptor.architecture.lowercased()) {
            return .unsupportedArchitecture(
                reason: "This app's local runtime does not support \(descriptor.architecture) models."
            )
        }

        if let license = descriptor.license, !license.isRedistributable {
            return .unsupportedFormat(
                reason: "\(license.displayName) requires accepting terms on the model's website "
                    + "before it can be downloaded."
            )
        }

        // Memory first, because it is the check that survives the download. A
        // model that will not fit in RAM is not made to fit by freeing disk.
        let weights = descriptor.fileSizeBytes ?? estimator.expectedFileSize(for: descriptor)
        guard let weights, weights > 0 else {
            return .unknown(
                reason: "This model's size is not recorded, so its memory use cannot be estimated."
            )
        }

        let budget = estimator.modelMemoryBudget(on: device)
        let estimate = estimator.estimate(
            weightsBytes: weights,
            contextLength: descriptor.defaultContextLength,
            kvBytesPerToken: descriptor.kvCacheBytesPerToken
        )

        if estimate.totalBytes > budget {
            // Before refusing: would it fit with a shorter context? Section 11.
            // Halving the context halves the KV cache and often nothing else,
            // and a model that answers with a 2048-token window is worth more
            // than a model that does not load.
            if let fallbackContext = estimator.largestFittingContext(
                weightsBytes: weights,
                kvBytesPerToken: descriptor.kvCacheBytesPerToken,
                preferred: descriptor.defaultContextLength,
                on: device
            ), fallbackContext < descriptor.defaultContextLength {
                return .compatibleWithWarning(
                    reason: "This model will run with a shorter conversation memory "
                        + "(\(fallbackContext) tokens) on this device."
                )
            }
            return .likelyTooLarge(
                reason: "This model needs about \(Self.format(estimate.totalBytes)) of memory. "
                    + "This device can spare about \(Self.format(budget)) for a local model."
            )
        }

        // Storage is checked only for something not already on disk.
        if !isInstalled {
            let available = device.availableStorageBytes()
            let required = estimator.storageRequired(forDownloadOf: weights)
            if available < required {
                return .insufficientStorage(
                    reason: "This download needs about \(Self.format(required)) free, "
                        + "including room to verify it. "
                        + "\(Self.format(available)) is available."
                )
            }
        }

        var warnings: [String] = []
        if Double(estimate.totalBytes) > Double(budget) * comfortableFraction {
            warnings.append("This model uses most of the memory available to the app.")
        }
        if let quantization = descriptor.quantization, !quantization.isRecommended {
            warnings.append("\(quantization) is an unusual quantization for a phone.")
        }
        if descriptor.toolSupport == .unsupported {
            warnings.append("Chat only — this model cannot carry out assistant actions.")
        }
        if device.thermalState >= .serious {
            warnings.append("The device is warm, so replies may be slower than usual.")
        }

        return warnings.isEmpty ? .compatible : .compatibleWithWarning(reason: warnings.joined(separator: " "))
    }

    /// The band the list groups by.
    public func tier(for compatibility: LocalModelCompatibility) -> LocalModelTier {
        switch compatibility {
        case .compatible: return .recommended
        case .compatibleWithWarning: return .usable
        case .unknown: return .heavy
        case .likelyTooLarge, .insufficientStorage, .unsupportedFormat,
             .unsupportedArchitecture, .unsupportedOS:
            return .notRecommended
        }
    }

    /// "2.0 GB". Rounded, because a byte count implies a precision none of
    /// these numbers have.
    static func format(_ bytes: Int64) -> String {
        let gigabytes = Double(bytes) / Double(Int64.gigabyte)
        if gigabytes >= 1 { return String(format: "%.1f GB", gigabytes) }
        return "\(bytes / .megabyte) MB"
    }
}
