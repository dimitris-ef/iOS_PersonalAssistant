import Foundation
import NativeModelKit
import SpeechToText

/// Whether a speech model would run on this device, and if not, why.
///
/// Section 83, and the same conservative philosophy as Part 10's equivalent
/// (section 35): the estimate assumes the app does *not* get all of physical
/// memory, because it does not. iOS kills a foreground app that grows past its
/// jetsam limit without warning, and a transcription that terminates the app is
/// worse in every way than one that refuses to start.
public enum LocalSpeechCompatibility: Hashable, Sendable {
    case compatible
    /// It should run, with a caveat worth reading first.
    case compatibleWithWarning(reason: String)
    /// The estimate says it does not fit.
    case likelyTooLarge(reason: String)
    case insufficientStorage(reason: String)
    /// This build has no speech runtime linked.
    case runtimeUnavailable(reason: String)
    /// The model cannot transcribe the language the user speaks.
    case unsupportedLanguage(reason: String)

    public var permitsDownload: Bool {
        switch self {
        case .compatible, .compatibleWithWarning:
            return true
        case .likelyTooLarge, .insufficientStorage, .runtimeUnavailable,
             .unsupportedLanguage:
            return false
        }
    }

    /// Whether the app will try to load it.
    ///
    /// Storage stops mattering once the file is on disk, so a model whose only
    /// complaint was disk space is loadable.
    public var permitsLoad: Bool {
        switch self {
        case .compatible, .compatibleWithWarning, .insufficientStorage:
            return true
        case .likelyTooLarge, .runtimeUnavailable, .unsupportedLanguage:
            return false
        }
    }

    public var reason: String? {
        switch self {
        case .compatible:
            return nil
        case .compatibleWithWarning(let reason), .likelyTooLarge(let reason),
             .insufficientStorage(let reason), .runtimeUnavailable(let reason),
             .unsupportedLanguage(let reason):
            return reason
        }
    }
}

/// How much memory and disk a Whisper model needs.
///
/// ## Why the numbers are shaped this way
///
/// Whisper's resident cost is not just its weights. The encoder runs over a
/// fixed 30-second mel spectrogram whatever the utterance length, so its
/// activation buffers are a constant that does not shrink for short audio —
/// which is why a naive "weights plus a bit" estimate under-counts badly on the
/// small model and gets the app killed.
public struct LocalSpeechResourceEstimator: Sendable {

    /// The fraction of physical memory the app may plan to use.
    ///
    /// Conservative on purpose. An iPhone's jetsam limit for a foreground app
    /// is well under total RAM, and the app is already holding a SwiftData
    /// store, a UI and possibly a local LLM.
    public var usableMemoryFraction: Double
    /// Held back for everything that is not the speech model.
    public var reservedApplicationBytes: Int64
    /// The runtime's own fixed overhead once a model is loaded.
    public var runtimeOverheadBytes: Int64
    /// Free space kept spare after a download.
    public var storageHeadroomBytes: Int64

    public init(
        usableMemoryFraction: Double = 0.45,
        reservedApplicationBytes: Int64 = 320 * megabyte,
        runtimeOverheadBytes: Int64 = 48 * megabyte,
        storageHeadroomBytes: Int64 = 256 * megabyte
    ) {
        self.usableMemoryFraction = usableMemoryFraction
        self.reservedApplicationBytes = reservedApplicationBytes
        self.runtimeOverheadBytes = runtimeOverheadBytes
        self.storageHeadroomBytes = storageHeadroomBytes
    }

    public static let `default` = LocalSpeechResourceEstimator()

    static let megabyte: Int64 = 1024 * 1024

    /// Encoder and decoder activation buffers, by size.
    ///
    /// Indicative figures from whisper.cpp's own reported memory use, rounded
    /// up. Not measured on device — section 80 forbids presenting unverified
    /// numbers to users, and these drive a compatibility decision rather than a
    /// claim shown in the UI.
    func workingSetBytes(for variant: WhisperModelVariant) -> Int64 {
        switch variant {
        case .tiny: return 96 * Self.megabyte
        case .base: return 128 * Self.megabyte
        case .small: return 256 * Self.megabyte
        case .medium: return 512 * Self.megabyte
        case .large: return 800 * Self.megabyte
        }
    }

    /// Peak resident bytes this model is expected to need.
    public func estimatedMemory(for model: LocalSpeechModelDescriptor) -> Int64 {
        // The file size already reflects the quantization, so the weights term
        // is the file itself rather than a recomputation from parameter counts.
        model.fileSize
            + workingSetBytes(for: model.variant)
            + runtimeOverheadBytes
    }

    /// What the app may plan to spend on a speech model.
    public func memoryBudget(on device: any DeviceResourceProvider) -> Int64 {
        let usable = Int64(Double(device.physicalMemoryBytes) * usableMemoryFraction)
        return max(0, usable - reservedApplicationBytes)
    }

    /// Disk needed to download and install, including the temporary copy.
    ///
    /// Section 36. The download lands in a temporary file and is then moved,
    /// and while a move on the same volume is a rename, a cross-volume move
    /// falls back to a copy — so the safe requirement is twice the file plus
    /// headroom.
    public func storageRequired(for model: LocalSpeechModelDescriptor) -> Int64 {
        model.fileSize * 2 + storageHeadroomBytes
    }

    /// The verdict.
    public func compatibility(
        of model: LocalSpeechModelDescriptor,
        on device: any DeviceResourceProvider,
        runtimeAvailable: Bool,
        locale: Locale? = nil
    ) -> LocalSpeechCompatibility {
        guard runtimeAvailable else {
            return .runtimeUnavailable(
                reason: "On-device speech isn't available in this build."
            )
        }

        if let locale, !model.supports(locale) {
            return .unsupportedLanguage(
                reason: "\(model.displayName) only transcribes English."
            )
        }

        let needed = estimatedMemory(for: model)
        let budget = memoryBudget(on: device)
        if needed > budget {
            return .likelyTooLarge(
                reason: "\(model.displayName) needs about "
                    + "\(SpeechModelByteFormat.string(needed)) of memory, "
                    + "which is more than this iPhone can spare."
            )
        }

        let requiredStorage = storageRequired(for: model)
        let available = device.availableStorageBytes()
        if available < requiredStorage {
            return .insufficientStorage(
                reason: "\(SpeechModelByteFormat.string(requiredStorage)) of free space is "
                    + "needed to download \(model.displayName)."
            )
        }

        // Comfortable, but not by much. Worth saying before someone downloads
        // half a gigabyte and finds transcription is slow.
        if Double(needed) > Double(budget) * 0.8 {
            return .compatibleWithWarning(
                reason: "\(model.displayName) will use most of the memory available to "
                    + "the app. A smaller model may be more reliable."
            )
        }

        return .compatible
    }
}
