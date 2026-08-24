import AssistantAI
import AssistantDomain
import Foundation
import NativeModelKit

/// Where one model is in its life on this device.
///
/// One enum rather than a handful of booleans, and section 29 is right to ask
/// for it: `isDownloaded`, `isDownloading`, `isVerifying`, `isLoaded`,
/// `isFailed` can encode "downloading and loaded and failed", which is not a
/// state anything can be in. The compiler cannot help with that; it can help
/// with this.
///
/// The order below is the order a model moves through, and the only unusual
/// edge is `verifying → notDownloaded`: a file that fails its checksum is
/// deleted, so the model goes back to not being here at all rather than
/// lingering as a broken install (section 23).
public enum LocalModelLifecycle: Hashable, Sendable {
    /// Nothing of this model is on the device.
    case notDownloaded
    /// Working out whether it would run here. Transient.
    case checkingCompatibility
    /// Bytes are arriving.
    case downloading(progress: LocalModelDownloadProgress)
    /// Bytes have arrived; checksum and GGUF structure are being checked.
    /// Deliberately *not* "downloaded" — section 73: nothing says Ready before
    /// this passes.
    case verifying
    /// On disk, verified, not in memory.
    case downloaded
    case loading
    /// In memory and able to answer.
    case loaded
    case unloading
    /// Something went wrong. The reason is for the user to read.
    case failed(reason: String)
    /// It will not run on this device, and downloading it would be a waste.
    case incompatible(LocalModelCompatibility)

    /// True when the file is on disk, whatever else is happening.
    public var isInstalled: Bool {
        switch self {
        case .downloaded, .loading, .loaded, .unloading: return true
        case .notDownloaded, .checkingCompatibility, .downloading, .verifying,
             .failed, .incompatible:
            return false
        }
    }

    public var isLoaded: Bool {
        if case .loaded = self { return true }
        return false
    }

    /// True while something is happening that the user should see a spinner for.
    public var isBusy: Bool {
        switch self {
        case .checkingCompatibility, .downloading, .verifying, .loading, .unloading:
            return true
        case .notDownloaded, .downloaded, .loaded, .failed, .incompatible:
            return false
        }
    }

    /// The short state shown next to a model's name.
    public var label: String {
        switch self {
        case .notDownloaded: return "Not downloaded"
        case .checkingCompatibility: return "Checking…"
        case .downloading(let progress): return "Downloading \(progress.percentLabel)"
        case .verifying: return "Verifying…"
        case .downloaded: return "Downloaded"
        case .loading: return "Loading…"
        case .loaded: return "Ready"
        case .unloading: return "Unloading…"
        case .failed: return "Failed"
        case .incompatible(let compatibility): return compatibility.shortLabel
        }
    }
}

extension LocalModelRecord {
    /// The quantization as a typed value.
    ///
    /// Stored as a string — see ``LocalModelRecord/quantization`` — and read
    /// back through the wrapper wherever the code wants to compare it against a
    /// named family rather than print it.
    public var typedQuantization: LocalModelQuantization? {
        // Spelled out rather than `map(LocalModelQuantization.init)`: the type
        // has three initialisers taking a single argument — the plain one, the
        // string-literal one and `init(from:)` — and an unapplied `.init` is
        // ambiguous between them.
        quantization.map { LocalModelQuantization($0) }
    }
}

/// A model as the management screen needs to show it: what it is, whether it
/// would run here, and what state it is in.
public struct LocalModelStatus: Hashable, Sendable, Identifiable {
    public var descriptor: LocalModelDescriptor
    public var lifecycle: LocalModelLifecycle
    public var compatibility: LocalModelCompatibility
    public var installed: LocalModelRecord?
    /// True when this is the model the user picked for Local AI.
    public var isSelected: Bool

    public var id: AIModelIdentifier { descriptor.id }

    public init(
        descriptor: LocalModelDescriptor,
        lifecycle: LocalModelLifecycle,
        compatibility: LocalModelCompatibility,
        installed: LocalModelRecord? = nil,
        isSelected: Bool = false
    ) {
        self.descriptor = descriptor
        self.lifecycle = lifecycle
        self.compatibility = compatibility
        self.installed = installed
        self.isSelected = isSelected
    }

    /// Whether the app is willing to start a download.
    ///
    /// Section 8 and section 12: refusing before the download is the whole
    /// point of checking. Starting a 2 GB transfer that ends in "not enough
    /// space" wastes the user's data allowance to tell them something that was
    /// knowable beforehand.
    public var canDownload: Bool {
        guard !lifecycle.isInstalled, !lifecycle.isBusy else { return false }
        guard descriptor.downloadURL != nil else { return false }
        return compatibility.permitsDownload
    }
}

/// What Local AI can do right now, in its own vocabulary.
///
/// Mapped onto ``AIProviderAvailability`` by the provider — section 62. Kept
/// separate so the reasons the *model system* knows about are not flattened
/// into a string before the UI can branch on them.
public enum LocalModelAvailability: Hashable, Sendable {
    case noModelInstalled
    /// Installed and verified, not yet in memory. Selecting Local AI loads it.
    case modelDownloaded
    case modelLoading
    case ready
    case modelIncompatible(reason: String)
    case insufficientMemory(reason: String)
    case corruptedModel(reason: String)
    case runtimeUnavailable(reason: String)
}
