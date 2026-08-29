import AssistantAI
import AssistantDomain
import Foundation

/// What a model row offers, and what it says about itself.
///
/// ## Why this is not in the view
///
/// `iOS/` has no test target, and this is a state machine with eleven inputs
/// and eight outputs where every wrong answer is a silent one. A row that
/// offers Load for a model whose file is missing looks identical to a row that
/// offers it for a model that will load; a row that hides Delete for a model
/// taking up two gigabytes looks like a row for a model that is not there.
///
/// ## The rule the whole file exists for
///
/// Sections 15 and 16: **downloading a model does nothing else.** It does not
/// load it, does not select it, and does not change which assistant answers.
/// That is visible here as an absence — a freshly downloaded model reports
/// ``LocalModelRuntimeState/downloadedNotLoaded`` and offers Load and Use as
/// things the user may now choose to do, never as things that have happened.
public enum LocalModelAction: String, Hashable, Sendable, Identifiable, CaseIterable {
    /// Start fetching the weights.
    case download
    /// Stop the transfer in flight.
    case cancelDownload
    /// The transfer failed and is worth another go.
    case retryDownload
    /// Make this the model Local AI answers with. Does not load it.
    case use
    /// Bring the weights into memory now, rather than on the next message.
    case load
    /// The last load failed. Try it again.
    case retryLoad
    /// Release the weights. The file stays.
    case unload
    /// Remove the file and its record.
    case delete

    public var id: String { rawValue }

    /// The button's words. Plain, and never llama.cpp's (section 70).
    public var title: String {
        switch self {
        case .download: return "Download"
        case .cancelDownload: return "Cancel"
        case .retryDownload: return "Try Again"
        case .use: return "Use for Chat"
        case .load: return "Load"
        case .retryLoad: return "Try Loading Again"
        case .unload: return "Unload"
        case .delete: return "Delete"
        }
    }

    public var isDestructive: Bool { self == .delete }

    /// The one action a row leads with, if any.
    public var isProminent: Bool {
        switch self {
        case .download, .use, .retryDownload, .retryLoad: return true
        case .cancelDownload, .load, .unload, .delete: return false
        }
    }
}

/// Where a model stands with the runtime, as distinct from where it stands
/// with the network.
///
/// Section 39 asks for these to be separate, and the reason is the bug that
/// started this: "downloaded" and "loaded" were shown by one label, so a model
/// that had finished downloading read as ready to answer — and the app had done
/// nothing of the kind.
public enum LocalModelRuntimeState: Hashable, Sendable {
    /// Not on the device.
    case notOnDevice
    /// Bytes are arriving.
    case downloading
    /// Bytes have arrived; checksum and structure are being checked.
    case verifying
    /// On disk, verified, **not in memory**. The state sections 15 and 16 are
    /// about: a completed download stops here.
    case downloadedNotLoaded
    /// Weights are being read into memory.
    case loading
    /// In memory, but some other model is the one Local AI answers with.
    case loadedNotInUse
    /// In memory and selected. The only state that means "this will answer".
    case inUse
    case unloading
    /// Something went wrong, with the sentence to show.
    case failed(reason: String)
    /// The file is here, or could be, but it will not run on this device.
    case cannotRun(reason: String)

    /// The short line under the model's name.
    ///
    /// The two-part strings are deliberate: "Downloaded · Not loaded" says both
    /// halves of a state that one word kept collapsing.
    public var label: String {
        switch self {
        case .notOnDevice: return "Not downloaded"
        case .downloading: return "Downloading…"
        case .verifying: return "Verifying…"
        case .downloadedNotLoaded: return "Downloaded · Not loaded"
        case .loading: return "Loading…"
        case .loadedNotInUse: return "Loaded · Not in use"
        case .inUse: return "Loaded · In use"
        case .unloading: return "Unloading…"
        case .failed: return "Error"
        case .cannotRun: return "Can't run here"
        }
    }

    /// The longer sentence, when there is one.
    public var detail: String? {
        switch self {
        case .failed(let reason), .cannotRun(let reason): return reason
        case .notOnDevice, .downloading, .verifying, .downloadedNotLoaded,
             .loading, .loadedNotInUse, .inUse, .unloading:
            return nil
        }
    }

    public var isError: Bool {
        switch self {
        case .failed, .cannotRun: return true
        default: return false
        }
    }

    /// True while a spinner belongs on the row.
    public var isBusy: Bool {
        switch self {
        case .downloading, .verifying, .loading, .unloading: return true
        default: return false
        }
    }

    /// True when the weights are in memory. Nothing else in this enum means
    /// that, which is the point of having it.
    public var isResident: Bool {
        switch self {
        case .loadedNotInUse, .inUse: return true
        default: return false
        }
    }
}

/// One row's worth of derived state: what it says, and what it offers.
public struct LocalModelRowState: Hashable, Sendable {
    public let runtime: LocalModelRuntimeState
    public let actions: [LocalModelAction]
    /// "1.2 GB", nil when nothing knows.
    public let sizeLabel: String?
    /// "Q4_K_M", nil when the catalog does not say (section 41: not invented).
    public let precisionLabel: String?
    /// "qwen3" — what the weights call themselves.
    public let familyLabel: String?

    public init(
        runtime: LocalModelRuntimeState,
        actions: [LocalModelAction],
        sizeLabel: String?,
        precisionLabel: String?,
        familyLabel: String?
    ) {
        self.runtime = runtime
        self.actions = actions
        self.sizeLabel = sizeLabel
        self.precisionLabel = precisionLabel
        self.familyLabel = familyLabel
    }

    public func offers(_ action: LocalModelAction) -> Bool { actions.contains(action) }
}

/// Derives a row's state from a model's status.
///
/// Pure, and takes everything it needs as arguments. The two extras beyond the
/// status are the things the status genuinely cannot know: whether *this*
/// screen has a transfer running for this model, and whether the last attempt
/// left an error on screen that Retry should act on.
public enum LocalModelRowPresenter {

    public static func state(
        for status: LocalModelStatus,
        isDownloading: Bool = false,
        failure: LocalModelRowFailure? = nil
    ) -> LocalModelRowState {
        let runtime = runtimeState(for: status, isDownloading: isDownloading, failure: failure)
        return LocalModelRowState(
            runtime: runtime,
            actions: actions(for: status, runtime: runtime, failure: failure),
            sizeLabel: sizeLabel(for: status),
            precisionLabel: status.descriptor.quantization?.rawValue,
            familyLabel: status.installed?.architecture ?? status.descriptor.architecture
        )
    }

    // MARK: The state

    static func runtimeState(
        for status: LocalModelStatus,
        isDownloading: Bool,
        failure: LocalModelRowFailure?
    ) -> LocalModelRuntimeState {
        // A transfer this screen started outranks everything: the manager's
        // status is refreshed after the download, so mid-flight it still says
        // `notDownloaded` and a row that believed it would show a Download
        // button next to its own progress bar.
        if isDownloading { return .downloading }

        switch status.lifecycle {
        case .notDownloaded:
            // A model that cannot run says so instead of offering a download
            // that ends in disappointment (sections 8 and 12).
            if let reason = status.compatibility.reason, !status.compatibility.permitsDownload {
                return .cannotRun(reason: reason)
            }
            return .notOnDevice
        case .checkingCompatibility:
            return .verifying
        case .downloading:
            return .downloading
        case .verifying:
            return .verifying
        case .downloaded:
            // The important one. Downloaded is *not* loaded, and if the last
            // load failed the row says so rather than inviting a repeat with no
            // acknowledgement that anything went wrong.
            if let failure, failure.kind == .load {
                return .failed(reason: failure.message)
            }
            if !status.compatibility.permitsLoad {
                return .cannotRun(
                    reason: status.compatibility.reason
                        ?? "This model will not run on this iPhone."
                )
            }
            return .downloadedNotLoaded
        case .loading:
            return .loading
        case .loaded:
            return status.isSelected ? .inUse : .loadedNotInUse
        case .unloading:
            return .unloading
        case .failed(let reason):
            return .failed(reason: failure?.message ?? reason)
        case .incompatible(let compatibility):
            return .cannotRun(
                reason: compatibility.reason ?? "This model will not run on this iPhone."
            )
        }
    }

    // MARK: The controls

    static func actions(
        for status: LocalModelStatus,
        runtime: LocalModelRuntimeState,
        failure: LocalModelRowFailure?
    ) -> [LocalModelAction] {
        switch runtime {
        case .downloading:
            // A way out of a multi-gigabyte transfer, always (section 20).
            return [.cancelDownload]

        case .verifying, .loading, .unloading:
            // Nothing offered while a native operation is in flight. Verifying
            // is seconds; a load that is cancelled halfway leaves a runtime in
            // a state nothing here can describe.
            return []

        case .notOnDevice:
            guard status.canDownload else { return [] }
            return failure?.kind == .download ? [.retryDownload] : [.download]

        case .downloadedNotLoaded:
            // Use and Load are separate, and both are offered, because they are
            // different decisions: Use says which model answers, Load says the
            // weights should go into memory now rather than on the next
            // message. Neither happened on its own (sections 15 and 16).
            var actions: [LocalModelAction] = []
            if !status.isSelected { actions.append(.use) }
            actions.append(.load)
            actions.append(.delete)
            return actions

        case .loadedNotInUse:
            return [.use, .unload, .delete]

        case .inUse:
            // No Load — it is loaded. Unload is offered even for the model in
            // use: it frees the memory, and the next message loads it again.
            return [.unload, .delete]

        case .failed:
            // What Retry means depends on what failed. A model whose *file* is
            // gone needs the bytes again; a model whose load failed needs
            // another attempt at the same file, and deleting a working
            // download because a load ran out of memory would be the wrong
            // repair.
            if status.lifecycle.isInstalled {
                return [.retryLoad, .delete]
            }
            if failure?.kind == .load { return [.retryLoad, .delete] }
            return status.canDownload ? [.retryDownload, .delete] : [.delete]

        case .cannotRun:
            // No Load and no Use — offering them would produce a failure the
            // app already knows about. Delete stays, because a file that cannot
            // run is a file worth reclaiming the space from.
            return status.lifecycle.isInstalled ? [.delete] : []
        }
    }

    // MARK: Labels

    static func sizeLabel(for status: LocalModelStatus) -> String? {
        // The installed size first: it is the number of bytes actually on the
        // device, and the catalog's figure is a claim about a file that may
        // have been re-published since.
        guard let bytes = status.installed?.fileSizeBytes ?? status.descriptor.fileSizeBytes,
            bytes > 0
        else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// A failure attached to one row.
///
/// Carries which half failed, because Retry has to mean two different things
/// and a bare message cannot say which.
public struct LocalModelRowFailure: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case download
        case load
        case delete
    }

    public let kind: Kind
    public let message: String

    public init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }
}
