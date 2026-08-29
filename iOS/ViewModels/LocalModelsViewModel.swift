import AIProviderLocal
import AssistantDomain
import Foundation
import NativeModelKit
import Observation

/// Screen state for Manage Models.
///
/// ## What lives here and what does not
///
/// Here: what the list is showing, which download is running, which error is on
/// screen. All of it presentation state that dies with the screen.
///
/// Not here: downloading, verifying, installing, loading, deleting. Section 17
/// is explicit that download code does not go in a view, and the same reasoning
/// covers a view model — a transfer that a `NavigationStack` pop can cancel is
/// a transfer the user loses by scrolling. Every one of those is a call into
/// ``LocalModelManager``, which is owned by the app environment and outlives
/// this object.
@MainActor
@Observable
final class LocalModelsViewModel {
    /// Every catalog model with its state, best fit first.
    private(set) var statuses: [LocalModelStatus] = []
    /// Live progress for the download in flight, if any.
    private(set) var downloading: AIModelIdentifier?
    private(set) var progress: LocalModelDownloadProgress = .zero
    private(set) var isRefreshing = false
    /// The model a load or unload is running for, so its row can show a
    /// spinner while the runtime is busy and its controls stay out of reach.
    private(set) var isWorking: AIModelIdentifier?
    /// Bytes the models directory occupies, and what is free right now.
    private(set) var storageUsed: Int64 = 0
    private(set) var storageAvailable: Int64 = 0

    /// The last failure, with its model, so the row that failed is the row that
    /// shows it.
    var failure: Failure?
    var pendingDeletion: LocalModelStatus?

    /// What the person typed into the search field.
    var query = ""
    /// Which slice of the list they asked for.
    var filter: LocalModelFilter = .all

    /// What the list actually shows.
    ///
    /// Both criteria are applied together — a filter that ignored the query
    /// would produce a list that looks authoritative and is wrong. The rule
    /// itself lives in `LocalModelSearch`, in the package, because `iOS/` has no
    /// test target and which models a person can see is worth testing.
    var visibleStatuses: [LocalModelStatus] {
        LocalModelSearch.apply(filter: filter, query: query, to: statuses)
    }

    /// True when a search or filter is hiding models that exist.
    var isFiltering: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty || filter != .all
    }


    struct Failure: Identifiable {
        let id = UUID()
        let modelID: AIModelIdentifier
        let message: String
        let isRetryable: Bool
        /// Which half failed. Retry means "fetch the bytes again" after a
        /// download and "try the same file again" after a load, and offering
        /// the wrong one turns a transient memory failure into a re-download.
        let kind: LocalModelRowFailure.Kind
    }

    /// The failure attached to one row, in the form the presenter takes.
    func rowFailure(for id: AIModelIdentifier) -> LocalModelRowFailure? {
        guard let failure, failure.modelID == id else { return nil }
        return LocalModelRowFailure(kind: failure.kind, message: failure.message)
    }

    /// What one row says and offers.
    ///
    /// Derived in the package rather than in the view: which control appears
    /// for which state is a table with a wrong answer for every cell, and
    /// `iOS/` has no test target.
    func rowState(for status: LocalModelStatus) -> LocalModelRowState {
        LocalModelRowPresenter.state(
            for: status,
            isDownloading: isDownloading(status.id),
            failure: rowFailure(for: status.id)
        )
    }

    /// Runs one row control.
    ///
    /// A single door so the view does not carry eight closures, and so every
    /// control goes through the same refresh afterwards.
    func perform(
        _ action: LocalModelAction,
        on status: LocalModelStatus,
        manager: LocalModelManager
    ) async {
        switch action {
        case .download, .retryDownload:
            await download(status, manager: manager)
        case .cancelDownload:
            await cancelDownload(manager)
        case .use:
            await select(status, manager: manager)
        case .load, .retryLoad:
            await load(status, manager: manager)
        case .unload:
            await unload(manager)
        case .delete:
            // The only one that does not act immediately: deleting gigabytes
            // on a single tap, with the row that was tapped ambiguous in a
            // scrolling list, is not a decision to take without confirming.
            pendingDeletion = status
        }
    }

    func refresh(_ manager: LocalModelManager) async {
        isRefreshing = true
        defer { isRefreshing = false }
        statuses = await manager.statuses()
        // Re-read rather than cached: storage changes while this screen is
        // open, and a stale figure is what refuses a download that would now
        // succeed (section 115).
        storageUsed = await manager.storageUsed()
        storageAvailable = await manager.availableStorage()
    }

    /// Starts a download and follows it to installed or failed.
    ///
    /// Only ever from a tap (section 123). Nothing on this screen downloads on
    /// appear, on selection, or because Local AI was chosen.
    func download(_ status: LocalModelStatus, manager: LocalModelManager) async {
        guard downloading == nil else { return }
        downloading = status.id
        progress = LocalModelDownloadProgress(
            bytesReceived: 0,
            bytesExpected: status.descriptor.fileSizeBytes
        )
        failure = nil
        defer { downloading = nil }

        do {
            try await manager.download(status.id) { [weak self] update in
                // The manager has already throttled this. Hopping to the main
                // actor per update is what keeps SwiftUI's work proportional to
                // what the user can see rather than to the network's speed.
                Task { @MainActor in self?.progress = update }
            }
        } catch let error as LocalModelDownloadError {
            failure = Failure(
                modelID: status.id,
                message: error.description,
                isRetryable: error.isRetryable,
                kind: .download
            )
        } catch {
            failure = Failure(
                modelID: status.id,
                message: error.localizedDescription,
                isRetryable: true,
                kind: .download
            )
        }
        await refresh(manager)
    }

    func cancelDownload(_ manager: LocalModelManager) async {
        guard let downloading else { return }
        await manager.cancelDownload(downloading)
        self.downloading = nil
        progress = .zero
        await refresh(manager)
    }

    /// Makes a model the one Local AI answers with. Nothing else.
    ///
    /// Sections 15, 16 and 24: selecting is a settings write, and the weights
    /// are read into memory when the first message needs them. Loading here
    /// would put a multi-second, multi-gigabyte operation behind a tap that
    /// looks like flipping a switch — and would mean that choosing a model you
    /// then never message had cost you the memory anyway.
    func select(_ status: LocalModelStatus, manager: LocalModelManager) async {
        failure = nil
        do {
            try await manager.select(status.id)
        } catch {
            failure = Failure(
                modelID: status.id,
                message: error.localizedDescription,
                isRetryable: true,
                kind: .load
            )
        }
        await refresh(manager)
    }

    /// Reads the weights into memory now.
    ///
    /// Separate from selection on purpose. This is the explicit "load it now"
    /// of section 31 — useful before going offline, or to find out whether a
    /// model will load at all without composing a message first.
    func load(_ status: LocalModelStatus, manager: LocalModelManager) async {
        failure = nil
        isWorking = status.id
        defer { isWorking = nil }
        do {
            _ = try await manager.load(status.id)
        } catch let error as LocalRuntimeError {
            failure = Failure(
                modelID: status.id,
                message: LocalTurnPreflight.loadFailureMessage(error),
                isRetryable: true,
                kind: .load
            )
        } catch {
            failure = Failure(
                modelID: status.id,
                message: error.localizedDescription,
                isRetryable: true,
                kind: .load
            )
        }
        await refresh(manager)
    }

    /// Releases the weights. The file, the record and the selection all stay.
    func unload(_ manager: LocalModelManager) async {
        await manager.unload()
        await refresh(manager)
    }

    /// Deletes a model's file and its record.
    ///
    /// Nothing else. Conversations, memories, tasks, routines and every other
    /// setting are untouched — section 67, and the sentence the confirmation
    /// dialog says out loud so the user does not have to take it on trust.
    func delete(_ status: LocalModelStatus, manager: LocalModelManager) async {
        failure = nil
        do {
            try await manager.delete(status.id)
        } catch {
            failure = Failure(
                modelID: status.id,
                message: error.localizedDescription,
                isRetryable: false,
                kind: .delete
            )
        }
        await refresh(manager)
    }

    func status(for id: AIModelIdentifier) -> LocalModelStatus? {
        statuses.first { $0.id == id }
    }

    /// True while this model is the one downloading.
    func isDownloading(_ id: AIModelIdentifier) -> Bool {
        downloading == id
    }

    var installedCount: Int {
        statuses.filter { $0.lifecycle.isInstalled }.count
    }

    /// How many installed models this build could actually load.
    ///
    /// Reported beside `installedCount` in the runtime diagnostic, because
    /// "four models installed, none runnable" and "no models installed" are
    /// different problems and only the first points at the runtime.
    var runnableCount: Int {
        statuses.filter { $0.lifecycle.isInstalled && $0.compatibility.permitsLoad }.count
    }
}
