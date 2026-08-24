import AssistantDomain
import Foundation
import NativeModelKit
import SpeechToText

/// Everything about speech models except transcription.
///
/// Section 29: catalog, download, verification, installed state, compatibility,
/// selection and deletion. Explicitly *not* inference — that is the runtime's,
/// and keeping them apart is what lets every line below run in CI against a
/// mock runtime and a mock transport.
///
/// ## What it shares with Part 10, and what it does not
///
/// It shares the machinery (section 28): `NativeDownloadManager` moves the
/// bytes, `SHA256Hash` checks them, `NativeFileStore` puts them away. It shares
/// no *types* with the language-model manager (section 27) — a
/// `LocalSpeechModelDescriptor` cannot be passed to `LocalModelManager` and a
/// `LocalModelDescriptor` cannot be passed here, which is what makes section
/// 39's guarantee structural: deleting a speech model cannot touch an
/// assistant model because this type cannot name one.
public actor LocalSpeechModelManager {

    /// One model's current state, as the UI renders it.
    public struct Status: Sendable, Identifiable, Hashable {
        public var descriptor: LocalSpeechModelDescriptor
        public var lifecycle: LocalSpeechModelLifecycle
        public var compatibility: LocalSpeechCompatibility
        public var isSelected: Bool
        /// Bytes actually on disk, when installed.
        public var installedSize: Int64?

        public var id: SpeechModelIdentifier { descriptor.id }

        public var canDownload: Bool {
            !lifecycle.isInstalled && !lifecycle.isBusy && compatibility.permitsDownload
        }
        public var canDelete: Bool {
            lifecycle.isInstalled && !lifecycle.isBusy
        }
    }

    private let catalog: [LocalSpeechModelDescriptor]
    private let store: NativeFileStore
    private let downloads: NativeDownloadManager<SpeechModelIdentifier>
    private let device: any DeviceResourceProvider
    private let estimator: LocalSpeechResourceEstimator
    private let runtime: any LocalSpeechRuntime

    /// Lifecycle per model, in memory. The filesystem is the real record —
    /// this is rebuilt from it at launch by `refreshInstalledState()`.
    private var lifecycles: [SpeechModelIdentifier: LocalSpeechModelLifecycle] = [:]
    private var selected: SpeechModelIdentifier?
    /// The model currently loaded into the runtime, if any.
    private var loaded: SpeechModelIdentifier?

    /// How far a declared size may be from the real one before the download is
    /// rejected.
    ///
    /// Generous at 20% because the catalog's compressed-model sizes are derived
    /// rather than measured — see `LocalSpeechModelCatalog`. It still catches
    /// what matters: an HTML error page served instead of a model is off by
    /// orders of magnitude, not by a fifth.
    public static let sizeTolerance = 0.20

    public init(
        catalog: [LocalSpeechModelDescriptor] = LocalSpeechModelCatalog.models,
        store: NativeFileStore,
        downloads: NativeDownloadManager<SpeechModelIdentifier> = NativeDownloadManager(),
        device: any DeviceResourceProvider = SystemDeviceResources(),
        estimator: LocalSpeechResourceEstimator = .default,
        runtime: any LocalSpeechRuntime,
        selected: SpeechModelIdentifier? = nil
    ) {
        self.catalog = catalog
        self.store = store
        self.downloads = downloads
        self.device = device
        self.estimator = estimator
        self.runtime = runtime
        self.selected = selected
    }

    /// The production location: `Application Support/Models/Speech`.
    ///
    /// Section 34, and a sibling of the language models rather than a mixture
    /// with them. Two directories means "delete every speech model" is a
    /// directory operation that provably cannot reach a chat model.
    public static func applicationSupportStore() throws -> NativeFileStore {
        try NativeFileStore.applicationSupport(subdirectory: "Models/Speech")
    }

    // MARK: State

    /// Rebuilds lifecycle from what is actually on disk.
    ///
    /// Called at launch. The filesystem is authoritative because it survives
    /// everything: a crash mid-download, a restore from backup, the user
    /// deleting the app's data. An in-memory flag that said "installed" for a
    /// file that is not there would produce exactly the broken infinite
    /// processing section 104 asks to avoid.
    public func refreshInstalledState() async {
        for model in catalog {
            let url = store.url(forRelativePath: model.fileName)
            let exists = FileManager.default.fileExists(atPath: url.path)
            if exists {
                lifecycles[model.id] = loaded == model.id ? .ready : .downloaded
            } else if case .downloading = lifecycles[model.id] {
                // A download that was in flight when the app died. The partial
                // file is the transport's temporary and is already gone.
                lifecycles[model.id] = .notDownloaded
            } else {
                lifecycles[model.id] = .notDownloaded
            }
        }
    }

    public func statuses(for locale: Locale? = nil) async -> [Status] {
        let runtimeAvailable = runtime.isAvailable
        return catalog.map { model in
            let lifecycle = lifecycles[model.id] ?? .notDownloaded
            let url = store.url(forRelativePath: model.fileName)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path))
                .flatMap { ($0[.size] as? NSNumber)?.int64Value }
            return Status(
                descriptor: model,
                lifecycle: lifecycle,
                compatibility: estimator.compatibility(
                    of: model,
                    on: device,
                    runtimeAvailable: runtimeAvailable,
                    locale: locale
                ),
                isSelected: selected == model.id,
                installedSize: lifecycle.isInstalled ? size : nil
            )
        }
    }

    public func lifecycle(of id: SpeechModelIdentifier) -> LocalSpeechModelLifecycle {
        lifecycles[id] ?? .notDownloaded
    }

    public func selectedModel() -> SpeechModelIdentifier? { selected }

    /// Chooses the model transcription will use.
    ///
    /// Selecting a different model unloads the current one: two Whisper models
    /// resident at once is most of a gigabyte for no benefit, and section 37
    /// says one at a time is sufficient.
    public func select(_ id: SpeechModelIdentifier?) async {
        guard selected != id else { return }
        selected = id
        if let loaded, loaded != id {
            await runtime.unloadModel()
            self.loaded = nil
            if lifecycles[loaded]?.isReady == true { lifecycles[loaded] = .downloaded }
        }
    }

    /// Whether the selected model is installed and usable right now.
    public func availability(for locale: Locale?) async -> SpeechToTextAvailability {
        guard runtime.isAvailable else {
            return .unsupported(reason: "On-device speech isn't available in this build.")
        }
        guard let selected, catalog.contains(where: { $0.id == selected }) else {
            return .needsModelDownload
        }
        switch lifecycles[selected] ?? .notDownloaded {
        case .ready:
            return .ready
        case .downloaded:
            // Installed but cold. Loading happens on first use, which is a
            // preparation state rather than an error.
            return .ready
        case .loading, .verifying:
            return .modelLoading
        case .downloading:
            return .needsModelDownload
        case .notDownloaded:
            return .needsModelDownload
        case .failed(let reason):
            return .unavailable(reason: reason)
        case .incompatible(let reason):
            return .unsupported(reason: reason)
        }
    }

    // MARK: Download

    /// Downloads, verifies and installs a model.
    ///
    /// Section 32's order is the whole point and it is not negotiable:
    /// download, then checksum, then validate the file is a model, then install
    /// atomically. A file is not "installed" until every one of those passed —
    /// so a corrupt download is never selectable, and the app never tries to
    /// transcribe with it (section 33).
    @discardableResult
    public func download(
        _ id: SpeechModelIdentifier,
        onProgress: @Sendable @escaping (NativeProgressSnapshot) -> Void = { _ in }
    ) async throws -> URL {
        guard let model = catalog.first(where: { $0.id == id }) else {
            throw SpeechToTextError.modelIncompatible(reason: "Unknown speech model.")
        }

        let compatibility = estimator.compatibility(
            of: model,
            on: device,
            runtimeAvailable: runtime.isAvailable
        )
        guard compatibility.permitsDownload else {
            let reason = compatibility.reason ?? "This model can't be used on this iPhone."
            lifecycles[id] = .incompatible(reason: reason)
            if case .insufficientStorage = compatibility {
                throw SpeechToTextError.insufficientStorage(reason: reason)
            }
            throw SpeechToTextError.modelIncompatible(reason: reason)
        }

        lifecycles[id] = .downloading(.zero)

        let file: DownloadedFile
        do {
            file = try await downloads.download(
                id: id,
                from: model.downloadURL,
                displayName: model.displayName,
                onProgress: { progress in
                    onProgress(NativeProgressSnapshot(
                        bytesReceived: progress.bytesReceived,
                        bytesExpected: progress.bytesExpected
                    ))
                }
            )
        } catch {
            let mapped = Self.map(error)
            lifecycles[id] = mapped == .cancelled
                ? .notDownloaded
                : .failed(reason: mapped.message)
            throw mapped
        }

        lifecycles[id] = .verifying

        do {
            try verify(file, against: model)
        } catch {
            // Section 33: the bad file goes, immediately. Leaving it would
            // consume the user's storage and invite a later "it's already
            // downloaded" shortcut past the check that just failed.
            try? FileManager.default.removeItem(at: file.url)
            let mapped = Self.map(error)
            lifecycles[id] = .failed(reason: mapped.message)
            throw mapped
        }

        do {
            let installed = try store.install(file.url, as: model.fileName)
            lifecycles[id] = .downloaded
            if selected == nil { selected = id }
            return installed
        } catch {
            try? FileManager.default.removeItem(at: file.url)
            let mapped = Self.map(error)
            lifecycles[id] = .failed(reason: mapped.message)
            throw mapped
        }
    }

    /// Checksum, size and format, in that order.
    private func verify(_ file: DownloadedFile, against model: LocalSpeechModelDescriptor) throws {
        if let expected = model.checksum {
            let actual = try SHA256Hash.hexDigest(ofFileAt: file.url)
            guard SHA256Hash.matches(expected, actual) else {
                throw SpeechToTextError.modelCorrupt(
                    reason: "The downloaded file did not match its published checksum."
                )
            }
        }

        // Size, within tolerance. Catches the classic failure the checksum
        // cannot when no checksum was published: a CDN error page or a
        // truncated transfer saved under the model's name.
        let declared = Double(model.fileSize)
        let actual = Double(file.byteCount)
        if declared > 0, abs(actual - declared) / declared > Self.sizeTolerance {
            throw SpeechToTextError.modelCorrupt(
                reason: "The downloaded file is not the expected size."
            )
        }

        // The format. A ggml Whisper file begins with the magic `ggml`
        // (0x67676d6c); anything else is not a model whatever it is called
        // (section 26).
        guard let handle = try? FileHandle(forReadingFrom: file.url) else {
            throw SpeechToTextError.modelCorrupt(reason: "The downloaded file could not be read.")
        }
        defer { try? handle.close() }
        let magic = try? handle.read(upToCount: 4)
        guard let magic, magic.count == 4, Self.isGGMLMagic(magic) else {
            throw SpeechToTextError.modelCorrupt(
                reason: "The downloaded file is not a Whisper speech model."
            )
        }
    }

    /// `ggml` in either byte order.
    ///
    /// The published Whisper files are little-endian and read as `lmgg` byte by
    /// byte; accepting both spellings means the check does not depend on which
    /// tool wrote the file.
    static func isGGMLMagic(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        return bytes == Array("ggml".utf8) || bytes == Array("ggml".utf8).reversed()
    }

    /// Stops an in-flight download.
    public func cancelDownload(_ id: SpeechModelIdentifier) async {
        guard let model = catalog.first(where: { $0.id == id }) else { return }
        await downloads.cancel(id, url: model.downloadURL)
        lifecycles[id] = .notDownloaded
    }

    // MARK: Loading

    /// Reads the selected model into memory, if it is not already there.
    public func loadSelectedModel() async throws {
        guard let selected, let model = catalog.first(where: { $0.id == selected }) else {
            throw SpeechToTextError.modelNotDownloaded
        }
        if loaded == selected, await runtime.isModelLoaded() { return }

        let url = store.url(forRelativePath: model.fileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            lifecycles[selected] = .notDownloaded
            throw SpeechToTextError.modelNotDownloaded
        }

        lifecycles[selected] = .loading
        do {
            try await runtime.loadModel(at: url)
            loaded = selected
            lifecycles[selected] = .ready
        } catch {
            let mapped = Self.map(error)
            // Out of memory leaves nothing resident, so the model goes back to
            // "downloaded" rather than "failed" — it is still on disk and a
            // smaller one may work (section 107).
            lifecycles[selected] = mapped == .insufficientMemory
                ? .downloaded
                : .failed(reason: mapped.message)
            await runtime.unloadModel()
            loaded = nil
            throw mapped
        }
    }

    /// Releases the loaded model.
    public func unload() async {
        guard let loaded else { return }
        await runtime.unloadModel()
        if lifecycles[loaded]?.isReady == true { lifecycles[loaded] = .downloaded }
        self.loaded = nil
    }

    // MARK: Deletion

    /// Removes a model's file.
    ///
    /// Section 39: this touches the speech model and nothing else. It cannot
    /// reach a conversation, a task, a memory, a language model or an assistant
    /// setting, because this type holds none of them — the only thing it has is
    /// a file store rooted at the speech directory.
    public func delete(_ id: SpeechModelIdentifier) async throws {
        guard let model = catalog.first(where: { $0.id == id }) else { return }
        if loaded == id { await unload() }
        do {
            try store.remove(relativePath: model.fileName)
        } catch {
            throw Self.map(error)
        }
        lifecycles[id] = .notDownloaded
        if selected == id { selected = nil }
    }

    /// Bytes the speech models occupy.
    public func totalBytesUsed() -> Int64 {
        store.totalBytesUsed()
    }

    // MARK: Errors

    /// Maps the download layer's vocabulary into the speech layer's.
    ///
    /// The two families exist for different audiences: `NativeDownloadError` is
    /// about bytes, `SpeechToTextError` is about transcription. Translating
    /// here means the voice UI never has to know that a model arrives over
    /// HTTP.
    static func map(_ error: any Error) -> SpeechToTextError {
        if let speech = error as? SpeechToTextError { return speech }
        guard let download = error as? NativeDownloadError else {
            return .transcriptionFailed(reason: "The speech model could not be prepared.")
        }
        switch download {
        case .cancelled:
            return .cancelled
        case .transport, .httpStatus, .invalidURL:
            return .networkUnavailable
        case .checksumMismatch:
            return .modelCorrupt(
                reason: "The downloaded file is damaged. Download it again."
            )
        case .notAModel(let reason), .modelMismatch(let reason):
            return .modelCorrupt(reason: reason)
        case .insufficientStorage(let reason):
            return .insufficientStorage(reason: reason)
        case .diskWrite(let reason):
            return .insufficientStorage(reason: reason)
        }
    }
}
