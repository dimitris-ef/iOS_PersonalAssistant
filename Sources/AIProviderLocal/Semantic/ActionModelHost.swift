import AssistantAI
import AssistantDomain
import AssistantPersistence
import Foundation

/// What the action model is doing right now.
///
/// Section 10, and it is deliberately *not* the chat model's load state. Two
/// models can be in different states at the same time — the usual one being a
/// chat model loaded and talking while the action model sits unloaded, having
/// no work — and one shared enum would make that inexpressible.
public enum ActionModelRuntimeState: Hashable, Sendable {
    /// Selected, on disk, and consuming nothing. Section 11: the normal idle
    /// state, not a problem to be fixed.
    case unloaded
    case loading(AIModelIdentifier)
    case loaded(AIModelIdentifier)
    case failed(reason: String)

    public var loadedModelID: AIModelIdentifier? {
        if case .loaded(let id) = self { return id }
        return nil
    }

    public var isLoaded: Bool { loadedModelID != nil }

    /// For the settings screen.
    public var label: String {
        switch self {
        case .unloaded: return "Unloaded"
        case .loading: return "Loading"
        case .loaded: return "Loaded"
        case .failed: return "Error"
        }
    }

    /// For the log. A symbol, never a native message.
    public var symbol: String {
        switch self {
        case .unloaded: return "unloaded"
        case .loading: return "loading"
        case .loaded: return "loaded"
        case .failed: return "failed"
        }
    }
}

/// Everything the settings screen needs to describe the action model.
public struct ActionModelStatus: Hashable, Sendable {
    public var selectedModelID: AIModelIdentifier?
    public var displayName: String?
    public var compatibility: ActionModelCompatibility
    public var runtimeState: ActionModelRuntimeState
    public var isEnabled: Bool

    public init(
        selectedModelID: AIModelIdentifier? = nil,
        displayName: String? = nil,
        compatibility: ActionModelCompatibility = .incompatible(reason: .modelMissing),
        runtimeState: ActionModelRuntimeState = .unloaded,
        isEnabled: Bool = true
    ) {
        self.selectedModelID = selectedModelID
        self.displayName = displayName
        self.compatibility = compatibility
        self.runtimeState = runtimeState
        self.isEnabled = isEnabled
    }

    /// Why the action path cannot run, when it cannot.
    ///
    /// One sentence, drawn from whichever check failed first, so the screen and
    /// the safe failure agree about the reason.
    public var unavailableReason: String? {
        guard isEnabled else { return "The action model is turned off." }
        guard selectedModelID != nil else { return "No action model is selected." }
        if case .incompatible(let reason) = compatibility { return reason.message }
        if case .failed(let reason) = runtimeState { return reason }
        return nil
    }

    public var isUsable: Bool { unavailableReason == nil }
}

/// Owns the dedicated action model: which one, whether it is loaded, and the
/// runtime it is loaded into.
///
/// ## Why this is not `LocalModelManager`
///
/// Section 4 asks to share low-level infrastructure and keep the lifecycles
/// apart, and that is exactly the split here. Storage, the installed-model
/// records, GGUF validation, the download pipeline and the device resource
/// estimates are all `LocalModelManager`'s, and this reads them rather than
/// reimplementing any of it.
///
/// What it does **not** share is the loaded model, the runtime instance or the
/// load state. Section 17 is a hard requirement: chat and action inference must
/// not share a `llama_context`, because a context carries KV state and sharing
/// one would mean an action request reading the conversation's cache — which is
/// both wrong and precisely the "no chat history" rule this whole path is built
/// on. So this host holds its own `LocalModelRuntime`, and the composition root
/// hands it a different instance from the chat provider's.
///
/// ## On loading the same file twice
///
/// Section 16 allows a warning rather than clever sharing, and that is the
/// choice made here: if somebody selects the same GGUF for both roles, two
/// contexts are opened. Sharing immutable weights across two `llama_context`
/// handles is not something the pinned C API exposes safely, and inventing it
/// would be the "unsafe native sharing" the same section forbids. The action
/// model's context is small (`ActionInferenceProductionPolicy`), it is unloaded
/// when idle, and `ActionModelStatus` says plainly when both roles point at one
/// file.
public actor ActionModelHost {

    private let runtime: (any LocalModelRuntime)?
    private let manager: LocalModelManager
    private let settings: any SettingsRepository
    private let policy: ActionInferenceProductionPolicy
    private let diagnostics: any LocalInferenceDiagnosticSink
    private let dateProvider: any DateProvider

    private var state: ActionModelRuntimeState = .unloaded

    public init(
        manager: LocalModelManager,
        settings: any SettingsRepository,
        runtime: (any LocalModelRuntime)? = nil,
        policy: ActionInferenceProductionPolicy = .production,
        diagnostics: any LocalInferenceDiagnosticSink = NullLocalInferenceDiagnosticSink(),
        dateProvider: any DateProvider = SystemDateProvider()
    ) {
        self.manager = manager
        self.settings = settings
        self.runtime = runtime
        self.policy = policy
        self.diagnostics = diagnostics
        self.dateProvider = dateProvider
    }

    // MARK: Selection

    public func configuration() async -> ActionModelConfiguration {
        (try? await settings.settings())?.actionModel ?? .none
    }

    /// Chooses the action model, and only the action model.
    ///
    /// Section 33: switching unloads whatever was loaded before, persists the
    /// new choice, and leaves it unloaded until something needs it. Two models
    /// loaded at once is the state this avoids.
    ///
    /// Section 15: nothing here touches `selectedLocalModelID`, the chat
    /// provider or the chat model's runtime. `ActionModelLifecycleTests`
    /// asserts that in both directions.
    public func select(_ id: AIModelIdentifier?) async throws {
        let previous = await configuration().selectedModelID
        if previous != id, state.isLoaded {
            await unload()
        }

        var current = try await settings.settings()
        current.actionModel.selectedModelID = id
        try await settings.update(current)

        diagnostics.info(
            .actionModelSelected,
            category: .model,
            metadata: LocalInferenceMetadata()
                .setting(.actionModelID, id?.rawValue ?? "none")
                .setting(.actionModelRuntimeState, state.symbol)
        )
    }

    public func setEnabled(_ enabled: Bool) async throws {
        if !enabled, state.isLoaded { await unload() }
        var current = try await settings.settings()
        current.actionModel.isEnabled = enabled
        try await settings.update(current)
    }

    // MARK: Status

    public func runtimeState() -> ActionModelRuntimeState { state }

    /// Everything the settings screen shows, resolved now.
    public func status() async -> ActionModelStatus {
        let configuration = await configuration()
        guard let id = configuration.selectedModelID else {
            return ActionModelStatus(
                compatibility: .incompatible(reason: .modelMissing),
                runtimeState: state,
                isEnabled: configuration.isEnabled
            )
        }
        let record = await manager.installedRecord(for: id)
        let descriptor = await manager.catalogModels().first { $0.id == id }
        return ActionModelStatus(
            selectedModelID: id,
            displayName: descriptor?.displayName ?? id.rawValue,
            compatibility: await compatibility(of: id, record: record),
            runtimeState: state,
            isEnabled: configuration.isEnabled
        )
    }

    /// Whether an action request could be served right now.
    public func availability() async -> ActionModelAvailability {
        let status = await status()
        guard let reason = status.unavailableReason else { return .available }
        return .unavailable(reason: reason)
    }

    /// Compatibility for any installed model, for the picker.
    public func compatibility(
        of id: AIModelIdentifier,
        record: LocalModelRecord? = nil
    ) async -> ActionModelCompatibility {
        let resolved = record ?? (await manager.installedRecord(for: id))
        // Section 35: the file is checked *now*, not trusted from the record. A
        // selection made before a reinstall points at something that is not
        // there, and "no longer installed" is a state to report rather than a
        // crash to have.
        let fileExists = await manager.installedFileURL(for: id) != nil
        return ActionModelCompatibilityResolver.resolve(
            record: resolved,
            fileExists: fileExists,
            runtime: runtime?.runtimeCapabilities
        )
    }

    /// The installed models a picker may offer, with their verdicts.
    ///
    /// Section 50: incompatible ones are returned with their reason so the
    /// screen can show *why* rather than silently omitting them, and the view
    /// decides not to make them selectable.
    public func selectableModels() async -> [(status: LocalModelStatus,
                                              compatibility: ActionModelCompatibility)] {
        var result: [(LocalModelStatus, ActionModelCompatibility)] = []
        for status in await manager.statuses() where status.lifecycle.isInstalled {
            result.append((status, await compatibility(of: status.descriptor.id,
                                                       record: status.installed)))
        }
        return result
    }

    // MARK: Loading

    /// Loads the selected model if it is not already in memory.
    ///
    /// Section 12: called from the action path, not from launch. Section 59:
    /// already loaded is a no-op, so a second request in a row does not reload.
    @discardableResult
    public func ensureLoaded() async throws -> LoadedModelInfo {
        let configuration = await configuration()
        guard configuration.isEnabled else {
            throw ActionModelError.backendUnavailable("The action model is turned off.")
        }
        guard let id = configuration.selectedModelID else {
            throw ActionModelError.backendUnavailable("No action model is selected.")
        }

        if case .loaded(let loadedID) = state, loadedID == id,
            let info = await runtime?.loadedModel() {
            return info
        }

        guard let runtime else {
            throw ActionModelError.backendUnavailable(LocalModelManager.noRuntimeReason)
        }
        let compatibility = await compatibility(of: id)
        guard compatibility.isUsable else {
            // Section 36 and 61: an incompatible model is refused *before* any
            // native call. Nothing is loaded and nothing is generated.
            let reason: String
            if case .incompatible(let detail) = compatibility {
                reason = detail.message
            } else {
                reason = "This model cannot be used for actions."
            }
            state = .failed(reason: reason)
            diagnostics.problem(
                .actionModelLoadFailed,
                category: .model,
                metadata: LocalInferenceMetadata()
                    .setting(.actionModelID, id.rawValue)
                    .setting(.actionBackendReason, compatibility.symbol)
            )
            throw ActionModelError.modelIncompatible(compatibility.symbol)
        }
        guard let fileURL = await manager.installedFileURL(for: id) else {
            state = .failed(reason: ActionModelIncompatibility.modelMissing.message)
            diagnostics.problem(
                .actionModelLoadFailed,
                category: .model,
                metadata: LocalInferenceMetadata()
                    .setting(.actionModelID, id.rawValue)
                    .setting(.actionBackendReason, "modelMissing")
            )
            throw ActionModelError.modelMissing(id.rawValue)
        }

        state = .loading(id)
        let started = dateProvider.now
        let overrides = await manager.diagnosticOverrides()
        let request = policy.loadRequest(modelID: id, fileURL: fileURL, overrides: overrides)

        diagnostics.info(
            .actionModelLoadStarted,
            category: .model,
            metadata: LocalInferenceMetadata()
                .setting(.actionModelID, id.rawValue)
                // Section 46: what the action runtime was actually asked for,
                // which is not what the chat model was asked for.
                .setting(.requestedContextSize, request.contextLength)
                .setting(.batchSize, request.batchSize ?? 0)
                .setting(.microBatchSize, request.microBatchSize ?? 0)
                .setting(.threadCount, request.threadCount ?? 0)
                .setting(.requestedGPUOffload, request.gpuOffloadRequested)
                .setting(.cpuOnly, overrides.forceCPUOnly)
                .setting(.productionProfile, policy.isProductionProfile(with: overrides))
        )

        do {
            let info = try await runtime.loadModel(request)
            state = .loaded(id)
            diagnostics.info(
                .actionModelLoadCompleted,
                category: .model,
                metadata: LocalInferenceMetadata()
                    .setting(.actionModelID, id.rawValue)
                    .setting(.actualContextSize, info.contextLength)
                    .setting(.architecture, info.architecture)
                    .setting(.actionModelLoadMs, Self.elapsedMs(since: started, now: dateProvider.now))
            )
            return info
        } catch let error as LocalRuntimeError {
            let symbol = SemanticActionGenerator.errorKind(of: error)
            state = .failed(reason: "The action model could not be loaded.")
            diagnostics.problem(
                .actionModelLoadFailed,
                category: .model,
                metadata: LocalInferenceMetadata()
                    .setting(.actionModelID, id.rawValue)
                    .setting(.actionBackendReason, symbol)
            )
            // Section 13: a load failure is a failed action request. It is not
            // a reason to ask the chat model instead.
            throw ActionModelError.loadFailed(symbol)
        }
    }

    /// Releases the action model.
    ///
    /// Section 15: the chat model is not touched. They are different runtime
    /// instances, so there is nothing here that *could* touch it.
    public func unload() async {
        guard state.isLoaded || state.isLoadingOrFailed else {
            state = .unloaded
            return
        }
        diagnostics.info(
            .actionModelUnloadStarted,
            category: .model,
            metadata: LocalInferenceMetadata()
                .setting(.actionModelRuntimeState, state.symbol)
        )
        await runtime?.unloadModel()
        state = .unloaded
        diagnostics.info(.actionModelUnloadCompleted, category: .model, metadata: .empty)
    }

    /// Frees the action model when the system is short of memory.
    ///
    /// Section 32: only when idle. `isGenerating` is the guard — unloading
    /// underneath a native decode is a crash, not a saving. The caller
    /// (`AppLifecycleCoordinator`) already receives the warning; this decides
    /// whether it applies.
    public func unloadIfIdle() async {
        guard !isGenerating else { return }
        await unload()
    }

    // MARK: Generation

    private var isGenerating = false

    /// Runs one constrained generation on the dedicated model.
    ///
    /// Lazy-loads first (section 12), and keeps the model resident afterwards
    /// (section 31): a person setting three reminders in a row should pay the
    /// load once. Memory pressure and an explicit unload are what release it —
    /// a simple, deterministic policy rather than predictive caching.
    public func generate(
        request: ActionModelRequest,
        constraints: ActionGenerationConstraints
    ) async throws -> LocalSemanticActionResult {
        let loaded = try await ensureLoaded()
        guard let runtime else {
            throw ActionModelError.backendUnavailable(LocalModelManager.noRuntimeReason)
        }
        let descriptor = await manager.catalogModels().first { $0.id == loaded.modelID }

        isGenerating = true
        defer { isGenerating = false }

        let started = dateProvider.now
        diagnostics.info(
            .actionModelInferenceStarted,
            category: .generation,
            metadata: LocalInferenceMetadata()
                .setting(.actionModelID, loaded.modelID.rawValue)
                .setting(.actionCategory, request.detectedCategory.rawValue)
        )

        let result = try await SemanticActionGenerator(diagnostics: diagnostics).generate(
            request: request,
            constraints: constraints,
            environment: SemanticActionGenerator.Environment(
                runtime: runtime,
                loaded: loaded,
                descriptor: descriptor,
                // Section 23: the action model's own short context, never the
                // chat model's.
                configuration: policy.configuration
            )
        )

        diagnostics.info(
            .actionModelInferenceCompleted,
            category: .generation,
            metadata: LocalInferenceMetadata()
                .setting(.actionModelID, loaded.modelID.rawValue)
                .setting(
                    .semanticGenerationMs, Self.elapsedMs(since: started, now: dateProvider.now)
                )
        )
        return result
    }

    /// Milliseconds, as an integer. Section 45, and deliberately measured
    /// around the model only — platform execution happens later and elsewhere.
    static func elapsedMs(since start: Date, now: Date) -> Int {
        max(0, Int((now.timeIntervalSince(start) * 1000).rounded()))
    }
}

extension ActionModelRuntimeState {
    /// Whether there is native state worth releasing.
    var isLoadingOrFailed: Bool {
        switch self {
        case .loading, .failed: return true
        case .unloaded, .loaded: return false
        }
    }
}
