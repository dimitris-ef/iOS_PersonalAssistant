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
    private let diagnostics: any LocalInferenceDiagnosticSink
    /// Diagnostic handicaps, applied at load time and never stored (section 76).
    private var overrides: LocalInferenceDiagnosticOverrides
    /// What normal inference asks for, before any override is applied.
    ///
    /// A constant today, and a property rather than a literal so the
    /// composition is visible at the call site: production states an intent,
    /// diagnostics may withdraw it, and nothing else can turn the GPU on.
    private let productionPolicy = LocalInferenceProductionPolicy.production

    private var catalog: LocalModelCatalog
    /// Live download state, per model. Not persisted: a download does not
    /// survive the process, and a resumed one starts from resume data held by
    /// the download manager.
    private var activeStates: [AIModelIdentifier: LocalModelLifecycle] = [:]
    /// Set while a load is in flight, so two callers do not both try.
    private var loadingModelID: AIModelIdentifier?
    /// The configuration the currently loaded model was opened with.
    ///
    /// Kept because the context the runtime actually got is often smaller than
    /// the one the record asked for — the adaptive reduction in `load` may have
    /// halved it — and the provider has to bound its prompt by what the model
    /// really has, not by what the catalog advertises (section 53).
    private var loadedConfiguration: LocalInferenceConfiguration?

    public init(
        catalog: LocalModelCatalog,
        repository: any LocalModelRepository,
        settings: any SettingsRepository,
        store: LocalModelStore,
        runtime: (any LocalModelRuntime)? = nil,
        device: any DeviceResourceProvider = SystemDeviceResources(),
        policy: LocalModelCompatibilityPolicy = .default,
        downloads: LocalModelDownloadManager? = nil,
        dateProvider: any DateProvider = SystemDateProvider(),
        diagnostics: any LocalInferenceDiagnosticSink = NullLocalInferenceDiagnosticSink(),
        overrides: LocalInferenceDiagnosticOverrides = .none
    ) {
        self.diagnostics = diagnostics
        self.overrides = overrides
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

        // Preflight, re-run now rather than trusted from install time. Section
        // 44: a jetsam kill is not catchable, so the check that matters is the
        // one made before any allocation happens — and free memory now is not
        // free memory when the file was downloaded.
        let descriptor = catalog.descriptor(for: id)
        let kvPerToken = descriptor?.kvCacheBytesPerToken
        let parameters = descriptor?.parameterCount
        let budget = policy.estimator.modelMemoryBudget(on: device)

        // Start from what this device can be asked to do, capped by what the
        // model was installed for. Never the model's advertised maximum: a 3B
        // model claiming 32768 tokens wants well over a gigabyte of KV cache
        // on its own (section 7).
        // Section 25. Everything knowable *before* anything is allocated, on
        // disk before the first native call — because if the process does not
        // come back, this is the whole description of what it was attempting.
        diagnostics.info(
            .loadRequested,
            category: .model,
            metadata: LocalInferenceMetadata()
                .setting(.modelID, id.rawValue)
                .setting(.architecture, ifPresent: record.architecture)
                .setting(.quantization, ifPresent: record.quantization)
                .setting(.modelFileBytes, record.fileSizeBytes)
                // Section 20 and 86: the managed relative path, never the
                // container path. It is different on every install, means
                // nothing to a reader, and would be a needless disclosure in a
                // log somebody pastes into an email.
                .setting(.managedRelativePath, record.relativePath)
                .setting(.physicalMemoryBytes, device.physicalMemoryBytes)
                .setting(.processorCount, device.processorCount)
                .setting(.thermalState, String(describing: device.thermalState))
                .setting(.availableMemoryEstimateBytes, budget)
        )
        diagnostics.info(
            .diagnosticOverrides, category: .configuration, metadata: overrides.metadata()
        )

        let deviceConfiguration = overrides.apply(
            to: LocalInferenceConfiguration.forDevice(device)
        )
        let preferredContext = min(deviceConfiguration.contextLength, record.contextLength)

        // Section 8: shrink before refusing. The weights are the same at 4096
        // and at 1024; only the KV cache is linear in context, so a model that
        // will not fit at the preferred size very often fits at half of it, and
        // a shorter conversation is a better outcome than no model at all.
        guard
            let fittedContext = policy.estimator.largestFittingContext(
                weightsBytes: record.fileSizeBytes,
                kvBytesPerToken: kvPerToken,
                preferred: preferredContext,
                minimum: 1024,
                microBatchSize: deviceConfiguration.microBatchSize,
                parameterCount: parameters,
                on: device
            )
        else {
            let estimate = policy.estimator.estimate(
                weightsBytes: record.fileSizeBytes,
                contextLength: 1024,
                kvBytesPerToken: kvPerToken,
                microBatchSize: deviceConfiguration.microBatchSize,
                parameterCount: parameters
            )
            diagnostics.problem(
                .memoryEstimate,
                category: .memory,
                metadata: Self.memoryMetadata(estimate, budget: budget, device: device)
                    .setting(.errorKind, "insufficientMemory")
            )
            throw LocalRuntimeError.insufficientMemory(
                reason: "This model needs about "
                    + "\(LocalModelCompatibilityPolicy.format(estimate.totalBytes)) "
                    + "even at its smallest usable context, and about "
                    + "\(LocalModelCompatibilityPolicy.format(budget)) is safely "
                    + "available on this iPhone. Try a smaller model."
            )
        }

        let configuration = deviceConfiguration.withContextLength(fittedContext)

        // Sections 32 and 33. The numbers the preflight believed, recorded next
        // to the load they authorised — so a termination during
        // `context_create` can be read against what was predicted rather than
        // against a guess made afterwards.
        diagnostics.info(
            .memoryEstimate,
            category: .memory,
            metadata: Self.memoryMetadata(
                policy.estimator.estimate(
                    weightsBytes: record.fileSizeBytes,
                    contextLength: configuration.contextLength,
                    kvBytesPerToken: kvPerToken,
                    microBatchSize: configuration.microBatchSize,
                    parameterCount: parameters
                ),
                budget: budget,
                device: device
            )
        )

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
                contextLength: configuration.contextLength,
                threadCount: configuration.threadCount,
                batchSize: configuration.batchSize,
                microBatchSize: configuration.microBatchSize,
                // Section 29: production asks, diagnostics may take away. The
                // policy is consulted rather than the overrides alone so that
                // "nobody has expressed an opinion" resolves to GPU on, not to
                // whatever the override struct happens to default to.
                gpuOffloadRequested: productionPolicy.wantsGPUOffload(with: overrides)
            )
        )
        loadedConfiguration = configuration

        var touched = record
        touched.lastUsedAt = dateProvider.now
        try? await repository.save(touched)
        return info
    }

    public func unload() async {
        await runtime?.unloadModel()
        loadedConfiguration = nil
    }

    /// Replaces the diagnostic overrides used by the *next* load.
    ///
    /// Section 77: it does not touch a model that is already resident. Metal
    /// and thread counts are fixed when a `llama_context` is created, so
    /// changing them under a live context would either be ignored or corrupt
    /// it. The caller unloads first; the UI says so.
    public func setDiagnosticOverrides(_ value: LocalInferenceDiagnosticOverrides) {
        overrides = value
        diagnostics.info(
            .diagnosticOverrides, category: .configuration, metadata: value.metadata()
        )
    }

    public func diagnosticOverrides() -> LocalInferenceDiagnosticOverrides { overrides }

    /// The memory numbers, in the shape the log and the report both want.
    static func memoryMetadata(
        _ estimate: LocalModelMemoryEstimate,
        budget: Int64,
        device: any DeviceResourceProvider
    ) -> LocalInferenceMetadata {
        LocalInferenceMetadata()
            .setting(.estimatedModelMemoryBytes, estimate.weightsBytes)
            .setting(.estimatedKVCacheBytes, estimate.kvCacheBytes)
            .setting(.estimatedComputeBufferBytes, estimate.computeBufferBytes)
            .setting(.estimatedRuntimeOverheadBytes, estimate.runtimeOverheadBytes)
            .setting(.estimatedTotalBytes, estimate.totalBytes)
            .setting(.actualContextSize, estimate.contextLength)
            .setting(.kvCacheIsMeasured, estimate.kvCacheIsMeasured)
            .setting(.physicalMemoryBytes, device.physicalMemoryBytes)
            // Section 33: this is the app's *budget*, a fraction of physical
            // memory chosen by policy — not free RAM, which iOS does not
            // publish. The key name says estimate because it is one.
            .setting(.availableMemoryEstimateBytes, budget)
    }

    /// What the loaded model was actually opened with, if anything is loaded.
    ///
    /// Nil when nothing is loaded. The provider asks for this rather than
    /// assuming the catalog's numbers, because the adaptive reduction means the
    /// two frequently disagree and only one of them is real.
    public func activeConfiguration() -> LocalInferenceConfiguration? {
        loadedConfiguration
    }

    /// The persisted install metadata for a model, if it is installed.
    ///
    /// Exposed so capability can be resolved from what the file's own GGUF
    /// header said — the architecture, recorded at install — rather than only
    /// from a catalogue join that a model with no curated entry cannot satisfy.
    public func installedRecord(for id: AIModelIdentifier) async -> LocalModelRecord? {
        try? await repository.model(id: id)
    }

    /// The capability of a model, and the evidence behind it.
    public func capability(of id: AIModelIdentifier) async -> LocalModelCapabilityResolution {
        LocalModelCapabilityResolver.resolve(
            descriptor: catalog.descriptor(for: id),
            record: await installedRecord(for: id)
        )
    }

    /// Where an installed model's file actually is, or nil if it is not there.
    ///
    /// Exists for the minimal native decode test (section 41), which opens the
    /// weights itself rather than through this manager — the point of that test
    /// is to have as little of this app as possible between the file and
    /// `llama_decode`, and going through `load` would put all of it back.
    ///
    /// Returns nil rather than a URL for a missing file, so the caller cannot
    /// hand a path that does not exist to the runtime and read the resulting
    /// failure as a decode problem.
    public func installedFileURL(for id: AIModelIdentifier) async -> URL? {
        guard let record = try? await repository.model(id: id) else { return nil }
        guard store.fileExists(record) else { return nil }
        return store.url(for: record)
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

        // Section 19. Recorded here rather than in the view, because this is
        // the one function that actually changes which model answers, and a log
        // line that fires from a screen would miss every other route to it.
        if let id, let status = await status(of: id) {
            diagnostics.info(
                .localModelSelected,
                category: .model,
                metadata: LocalInferenceMetadata()
                    .setting(.modelID, id.rawValue)
                    .setting(.modelDisplayFamily, status.descriptor.architecture)
                    .setting(.quantization, ifPresent: status.descriptor.quantization?.rawValue)
                    .setting(.installed, status.lifecycle.isInstalled)
                    .setting(.selected, true)
                    .setting(.compatibility, status.compatibility.shortLabel)
                    .setting(.modelFileBytes, ifPresent: status.descriptor.fileSizeBytes)
            )
        }

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
