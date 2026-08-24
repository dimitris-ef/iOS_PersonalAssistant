import AssistantAI
import AssistantDomain
import AssistantPersistence
import Foundation
import NativeModelKit

/// Orchestrates everything about local models except inference.
///
/// ## What it owns
///
/// The catalog, compatibility, downloads, verification, the install records,
/// which model is selected, and asking the runtime to load or unload. Section
/// 28 asks for exactly this split, and the reason is worth stating: a type that
/// also held the llama context would be a type that could not be reasoned about
/// without llama.cpp linked, and half of what is here — compatibility, storage,
/// checksums, the state machine — is testable and useful with no runtime at all.
///
/// ## One model at a time
///
/// Section 31. Switching models unloads before it loads, and it does so in that
/// order deliberately: two multi-gigabyte models resident at once is how the
/// switch itself becomes the thing that gets the app killed.
///
/// ## An actor
///
/// Because downloads, loads, deletions and the Settings screen all touch the
/// same state from different tasks. "Delete the model the user is mid-download
/// of" needs to be a decision made in one place, not a race.
public actor LocalModelManager {
    private let repository: any LocalModelRepository
    private let settingsRepository: any SettingsRepository
    private let store: LocalModelStore
    private let installer: LocalModelInstaller
    private let downloads: LocalModelDownloadManager
    private let runtime: (any LocalModelRuntime)?
    private let device: any DeviceResourceProvider
    private let policy: LocalModelCompatibilityPolicy
    private let dateProvider: any DateProvider

    private var catalog: LocalModelCatalog
    /// Live download state, per model. Not persisted: a download does not
    /// survive the process, and a resumed one starts from resume data held by
    /// the download manager.
    private var activeStates: [AIModelIdentifier: LocalModelLifecycle] = [:]
    /// Set while a load is in flight, so two callers do not both try.
    private var loadingModelID: AIModelIdentifier?

    public init(
        catalog: LocalModelCatalog,
        repository: any LocalModelRepository,
        settings: any SettingsRepository,
        store: LocalModelStore,
        runtime: (any LocalModelRuntime)? = nil,
        device: any DeviceResourceProvider = SystemDeviceResources(),
        policy: LocalModelCompatibilityPolicy = .default,
        downloads: LocalModelDownloadManager? = nil,
        dateProvider: any DateProvider = SystemDateProvider()
    ) {
        self.catalog = catalog
        self.repository = repository
        self.settingsRepository = settings
        self.store = store
        self.runtime = runtime
        self.device = device
        self.policy = policy
        self.downloads = downloads ?? LocalModelDownloadManager(dateProvider: dateProvider)
        self.dateProvider = dateProvider
        self.installer = LocalModelInstaller(
            store: store,
            dateProvider: dateProvider,
            estimator: policy.estimator
        )
    }

    // MARK: Reading state

    public func catalogModels() -> [LocalModelDescriptor] { catalog.models }

    /// Every catalog model with its state on this device, best fit first.
    ///
    /// Storage is re-read on every call rather than cached (section 115): the
    /// user may have deleted photos since the screen opened, and a cached "not
    /// enough space" would keep refusing a download that would now succeed.
    public func statuses() async -> [LocalModelStatus] {
        let installed = (try? await repository.installedModels()) ?? []
        let byID = Dictionary(uniqueKeysWithValues: installed.map { ($0.id, $0) })
        let selected = await selectedModelID()
        let availability = await runtime?.runtimeAvailability()
            ?? .unavailable(reason: Self.noRuntimeReason)
        let loaded = await runtime?.loadedModel()?.modelID

        return catalog.models.map { descriptor in
            let record = byID[descriptor.id]
            let compatibility = policy.compatibility(
                of: descriptor,
                on: device,
                runtime: availability,
                isInstalled: record != nil
            )
            return LocalModelStatus(
                descriptor: descriptor,
                lifecycle: lifecycle(
                    for: descriptor,
                    record: record,
                    compatibility: compatibility,
                    loadedModelID: loaded
                ),
                compatibility: compatibility,
                installed: record,
                isSelected: descriptor.id == selected
            )
        }
        .sorted { lhs, rhs in
            let leftTier = policy.tier(for: lhs.compatibility)
            let rightTier = policy.tier(for: rhs.compatibility)
            if leftTier != rightTier { return leftTier < rightTier }
            return lhs.descriptor.displayName < rhs.descriptor.displayName
        }
    }

    public func status(of id: AIModelIdentifier) async -> LocalModelStatus? {
        await statuses().first { $0.id == id }
    }

    /// What Local AI can do right now.
    ///
    /// Section 62, and the reason it is a rich enum rather than a boolean: "not
    /// ready" splits into a download the user should start, a load that is
    /// happening, a file that has gone missing and a build with no runtime, and
    /// only one of those is worth showing a Download button for.
    public func availability() async -> LocalModelAvailability {
        guard let runtime else { return .runtimeUnavailable(reason: Self.noRuntimeReason) }
        if case .unavailable(let reason) = await runtime.runtimeAvailability() {
            return .runtimeUnavailable(reason: reason)
        }

        guard let record = await selectedRecord() else {
            return .noModelInstalled
        }
        guard store.fileExists(record) else {
            // The row survived and the file did not — a restore that dropped
            // excluded-from-backup files, or a user clearing storage. Saying
            // "corrupted" is the honest answer; silently re-downloading a
            // gigabyte on someone's cellular connection is not.
            return .corruptedModel(
                reason: "The model file is missing. Download it again from Manage Models."
            )
        }

        if let loading = loadingModelID, loading == record.id { return .modelLoading }
        if await runtime.loadedModel()?.modelID == record.id { return .ready }

        guard let descriptor = catalog.descriptor(for: record.id) else {
            // Installed, but no longer in the catalog — an app update dropped
            // it. It still runs; nothing about compatibility can be recomputed.
            return .modelDownloaded
        }
        let compatibility = policy.compatibility(
            of: descriptor,
            on: device,
            runtime: await runtime.runtimeAvailability(),
            isInstalled: true
        )
        switch compatibility {
        case .likelyTooLarge(let reason):
            return .insufficientMemory(reason: reason)
        case .unsupportedFormat(let reason),
             .unsupportedArchitecture(let reason),
             .unsupportedOS(let reason):
            return .modelIncompatible(reason: reason)
        case .compatible, .compatibleWithWarning, .insufficientStorage, .unknown:
            return .modelDownloaded
        }
    }

    public func selectedModelID() async -> AIModelIdentifier? {
        (try? await settingsRepository.settings())?.selectedLocalModelID
    }

    public func selectedRecord() async -> LocalModelRecord? {
        guard let id = await selectedModelID() else { return nil }
        return try? await repository.model(id: id)
    }

    // MARK: Downloading

    /// Downloads, verifies and installs one model.
    ///
    /// Section 123: only ever from an explicit user action. Nothing in this
    /// type is called on a timer, at launch, or when Local AI is selected.
    ///
    /// Progress is reported through `onProgress`, already throttled.
    @discardableResult
    public func download(
        _ id: AIModelIdentifier,
        onProgress: @Sendable @escaping (LocalModelDownloadProgress) -> Void = { _ in }
    ) async throws -> LocalModelRecord {
        guard let descriptor = catalog.descriptor(for: id) else {
            throw LocalModelDownloadError.invalidURL(reason: "That model is not in the catalog.")
        }

        activeStates[id] = .checkingCompatibility
        defer { activeStates[id] = nil }

        // Re-checked here rather than trusted from the screen: storage changes
        // while a list is on screen, and this is the last moment before
        // spending someone's data allowance.
        let availability = await runtime?.runtimeAvailability()
            ?? .unavailable(reason: Self.noRuntimeReason)
        let compatibility = policy.compatibility(
            of: descriptor,
            on: device,
            runtime: availability,
            isInstalled: false
        )
        guard compatibility.permitsDownload else {
            switch compatibility {
            case .insufficientStorage(let reason):
                throw LocalModelDownloadError.insufficientStorage(reason: reason)
            default:
                throw LocalModelDownloadError.notAModel(
                    reason: compatibility.reason ?? "This model cannot run on this device."
                )
            }
        }

        activeStates[id] = .downloading(progress: .zero)
        let file = try await downloads.download(descriptor) { progress in
            onProgress(progress)
        }

        // Section 73: nothing says Ready until this passes.
        activeStates[id] = .verifying
        let record = try installer.install(file, descriptor: descriptor, device: device)
        try await repository.save(record)
        activeStates[id] = .downloaded
        return record
    }

    /// Reports live download progress for a model, if one is running.
    public func lifecycleOverride(for id: AIModelIdentifier) -> LocalModelLifecycle? {
        activeStates[id]
    }

    /// Stops a download in progress.
    public func cancelDownload(_ id: AIModelIdentifier) async {
        let url = catalog.descriptor(for: id)?.downloadURL
        await downloads.cancel(id, url: url)
        activeStates[id] = nil
    }

    // MARK: Loading

    /// Brings a model into memory, unloading whatever was there.
    ///
    /// Section 65: never called at launch. The app starts with the runtime
    /// empty and loads the first time Local AI is actually asked for something,
    /// because a multi-gigabyte mmap and a Metal warm-up on the launch path is
    /// how an assistant becomes an app people wait for.
    @discardableResult
    public func load(_ id: AIModelIdentifier) async throws -> LoadedModelInfo {
        guard let runtime else {
            throw LocalRuntimeError.runtimeUnavailable(reason: Self.noRuntimeReason)
        }
        guard let record = try await repository.model(id: id) else {
            throw LocalRuntimeError.loadFailed(reason: "That model is not installed.")
        }
        if let loaded = await runtime.loadedModel(), loaded.modelID == id {
            return loaded
        }

        let fileURL = store.url(for: record)
        guard store.fileExists(record) else {
            throw LocalRuntimeError.modelFileMissing(fileURL)
        }

        // Preflight. Section 35: a runtime allocation failure is catchable and
        // a jetsam kill is not, so the check that matters is the one made
        // before any allocation happens.
        let estimate = policy.estimator.estimate(
            weightsBytes: record.fileSizeBytes,
            contextLength: record.contextLength,
            kvBytesPerToken: catalog.descriptor(for: id)?.kvCacheBytesPerToken
        )
        let budget = policy.estimator.modelMemoryBudget(on: device)
        guard estimate.totalBytes <= budget else {
            throw LocalRuntimeError.insufficientMemory(
                reason: "\(record.id) needs about "
                    + "\(LocalModelCompatibilityPolicy.format(estimate.totalBytes)), "
                    + "and about \(LocalModelCompatibilityPolicy.format(budget)) is available."
            )
        }

        // Unload first, always. Loading the new model while the old one is
        // still resident would briefly need both, which on the devices this
        // matters for is the difference between switching models and being
        // terminated mid-switch.
        await runtime.unloadModel()

        loadingModelID = id
        defer { loadingModelID = nil }

        let info = try await runtime.loadModel(
            LocalModelLoadRequest(
                modelID: id,
                fileURL: fileURL,
                contextLength: record.contextLength,
                threadCount: Self.threadCount(for: device)
            )
        )

        var touched = record
        touched.lastUsedAt = dateProvider.now
        try? await repository.save(touched)
        return info
    }

    public func unload() async {
        await runtime?.unloadModel()
    }

    /// Loads the selected model if it is not already in memory.
    public func ensureSelectedModelLoaded() async throws -> LoadedModelInfo {
        guard let id = await selectedModelID() else {
            throw LocalRuntimeError.loadFailed(reason: "No local model has been selected.")
        }
        return try await load(id)
    }

    // MARK: Selection

    /// Makes a model the one Local AI uses.
    ///
    /// Writes one settings field. It does not touch conversations, memories,
    /// tasks or routines — section 67, and the reason the model system was
    /// given its own repository rather than being folded into settings.
    public func select(_ id: AIModelIdentifier?) async throws {
        var settings = try await settingsRepository.settings()
        guard settings.selectedLocalModelID != id else { return }
        settings.selectedLocalModelID = id
        try await settingsRepository.update(settings)

        // Switching away from the loaded model releases it. Not for tidiness:
        // it is gigabytes, and the user has just said they want a different one.
        if let loaded = await runtime?.loadedModel()?.modelID, loaded != id {
            await runtime?.unloadModel()
        }
    }

    // MARK: Deleting

    /// Removes a model's file and its row.
    ///
    /// Section 66 and section 67. The order matters — unload before delete, or
    /// the runtime is holding a memory mapping of a file that no longer exists
    /// — and what is *not* touched matters more: conversations, memories,
    /// tasks, routines, reminder plans, the profile and every setting other
    /// than the selection itself all survive untouched.
    public func delete(_ id: AIModelIdentifier) async throws {
        if await runtime?.loadedModel()?.modelID == id {
            await runtime?.unloadModel()
        }

        if let record = try await repository.model(id: id) {
            try store.remove(relativePath: record.relativePath)
        }
        try await repository.delete(id: id)
        await downloads.discardResumeData(for: id)
        activeStates[id] = nil

        if await selectedModelID() == id {
            try await select(nil)
        }
    }

    /// Removes files in the models directory that no record claims.
    ///
    /// Section 114. Called on demand from the model management screen rather
    /// than on a timer: a stray `.part` file is a storage annoyance, not a
    /// correctness problem, and scanning a directory at launch to fix an
    /// annoyance is the wrong trade.
    @discardableResult
    public func removeOrphanedFiles() async -> Int {
        let installed = (try? await repository.installedModels()) ?? []
        return store.removeOrphanedFiles(knownPaths: Set(installed.map(\.relativePath)))
    }

    /// Bytes the models directory occupies.
    public func storageUsed() -> Int64 { store.totalBytesUsed() }

    /// Free space right now.
    public func availableStorage() -> Int64 { device.availableStorageBytes() }

    // MARK: Internals

    static let noRuntimeReason =
        "This build has no local inference runtime, so downloaded models cannot run."

    private func lifecycle(
        for descriptor: LocalModelDescriptor,
        record: LocalModelRecord?,
        compatibility: LocalModelCompatibility,
        loadedModelID: AIModelIdentifier?
    ) -> LocalModelLifecycle {
        if let live = activeStates[descriptor.id] { return live }
        if let record {
            guard store.fileExists(record) else {
                return .failed(reason: "The model file is missing. Download it again.")
            }
            if loadedModelID == descriptor.id { return .loaded }
            if loadingModelID == descriptor.id { return .loading }
            return .downloaded
        }
        if !compatibility.permitsDownload { return .incompatible(compatibility) }
        return .notDownloaded
    }

    /// Threads for inference.
    ///
    /// Performance cores only, roughly. Handing llama.cpp every core on a
    /// phone including the efficiency ones makes generation *slower*, because
    /// the fast cores finish their share and then wait — and it makes the phone
    /// hot enough that the system starts throttling the fast cores too.
    static func threadCount(for device: any DeviceResourceProvider) -> Int {
        max(2, min(6, device.processorCount / 2))
    }
}
