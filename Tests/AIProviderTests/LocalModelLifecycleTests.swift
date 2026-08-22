import AssistantAI
import AssistantDomain
import AssistantPersistence
import XCTest
@testable import AIProviderLocal

/// Loading, unloading, switching, deleting — and what must survive each.
///
/// Everything here runs against `MockLocalModelRuntime` (section 89). Real
/// inference is a real-device question; what these assert is the plumbing, and
/// the plumbing is what breaks.
final class LocalModelLifecycleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_781_078_400)
    private var store: LocalModelStore!

    override func setUp() {
        super.setUp()
        store = LocalModelStore.temporary()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: store.directory)
        store = nil
        super.tearDown()
    }

    // MARK: Fixtures

    private func descriptor(
        _ id: AIModelIdentifier,
        bytes: Int64 = 1_100_000_000,
        toolSupport: LocalModelToolSupport = .supported
    ) -> LocalModelDescriptor {
        LocalModelDescriptor(
            id: id,
            displayName: id.rawValue,
            architecture: "qwen3",
            parameterCount: 1_700_000_000,
            quantization: .q4KM,
            fileSizeBytes: bytes,
            downloadURL: URL(string: "https://example.invalid/\(id.rawValue).gguf"),
            defaultContextLength: 4096,
            kvCacheBytesPerToken: 32 * 1024,
            toolSupport: toolSupport
        )
    }

    /// Puts a model on disk and in the repository, as a completed download
    /// would have.
    @discardableResult
    private func install(
        _ descriptor: LocalModelDescriptor,
        into repositories: AssistantRepositories
    ) async throws -> LocalModelRecord {
        try store.prepareDirectory()
        let path = descriptor.suggestedFileName
        try GGUFFixture.header().write(to: store.url(forRelativePath: path))
        let record = LocalModelRecord(
            id: descriptor.id,
            relativePath: path,
            fileSizeBytes: 1_100_000_000,
            checksumSHA256: String(repeating: "b", count: 64),
            checksumWasDeclared: true,
            installedAt: now,
            architecture: "qwen3",
            quantization: "Q4_K_M",
            contextLength: 4096
        )
        try await repositories.localModels.save(record)
        return record
    }

    private func manager(
        _ repositories: AssistantRepositories,
        catalog: [LocalModelDescriptor],
        runtime: MockLocalModelRuntime
    ) -> LocalModelManager {
        LocalModelManager(
            catalog: LocalModelCatalog(models: catalog),
            repository: repositories.localModels,
            settings: repositories.settings,
            store: store,
            runtime: runtime,
            device: FixedDeviceResources.largePhone,
            dateProvider: FixedDateProvider(now: now)
        )
    }

    // MARK: Load and unload

    /// Section 98. downloaded → load → ready → unload → downloaded.
    func testAModelLoadsAndUnloads() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let model = descriptor("model-a")
        try await install(model, into: repositories)
        let runtime = MockLocalModelRuntime()
        let manager = manager(repositories, catalog: [model], runtime: runtime)

        var status = await manager.status(of: model.id)
        XCTAssertEqual(status?.lifecycle, .downloaded)

        let info = try await manager.load(model.id)
        XCTAssertEqual(info.modelID, model.id)
        status = await manager.status(of: model.id)
        XCTAssertTrue(status?.lifecycle.isLoaded == true)

        await manager.unload()
        status = await manager.status(of: model.id)
        XCTAssertEqual(status?.lifecycle, .downloaded)
        let unloads = await runtime.unloadCount
        XCTAssertEqual(unloads, 1)
    }

    /// Loading a model that is already resident does not load it twice.
    func testLoadingAnAlreadyLoadedModelIsANoOp() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let model = descriptor("model-a")
        try await install(model, into: repositories)
        let runtime = MockLocalModelRuntime()
        let manager = manager(repositories, catalog: [model], runtime: runtime)

        _ = try await manager.load(model.id)
        _ = try await manager.load(model.id)

        let loads = await runtime.loadCount
        XCTAssertEqual(loads, 1)
    }

    /// Section 99. A runtime that refuses to load is reported, not fatal.
    func testALoadFailureIsReportedAndLeavesTheAppIntact() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let model = descriptor("model-a")
        try await install(model, into: repositories)
        try await repositories.memories.store(
            MemoryItem(kind: .fact, content: "I take the 8:15 train.", createdAt: now, source: .user)
        )

        let runtime = MockLocalModelRuntime()
        await runtime.setLoadBehaviour(
            .fail(.insufficientMemory(reason: "not enough memory for the KV cache"))
        )
        let manager = manager(repositories, catalog: [model], runtime: runtime)

        do {
            _ = try await manager.load(model.id)
            XCTFail("expected the load to fail")
        } catch let error as LocalRuntimeError {
            guard case .insufficientMemory = error else {
                return XCTFail("expected insufficientMemory, got \(error)")
            }
        }

        // Section 99 and 107: user data is untouched by an inference failure.
        let memories = try await repositories.memories.all()
        XCTAssertEqual(memories.count, 1)
        let stillInstalled = try await repositories.localModels.installedModels()
        XCTAssertEqual(stillInstalled.count, 1)
    }

    /// A record whose file has gone is reported, not loaded from a stale path.
    func testAMissingFileIsReportedRatherThanLoaded() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let model = descriptor("model-a")
        let record = try await install(model, into: repositories)
        try FileManager.default.removeItem(at: store.url(for: record))

        let runtime = MockLocalModelRuntime()
        let manager = manager(repositories, catalog: [model], runtime: runtime)

        do {
            _ = try await manager.load(model.id)
            XCTFail("expected a missing-file error")
        } catch let error as LocalRuntimeError {
            guard case .modelFileMissing = error else {
                return XCTFail("expected modelFileMissing, got \(error)")
            }
        }

        try await repositories.settings.update(
            AssistantSettings(selectedLocalModelID: model.id)
        )
        let availability = await manager.availability()
        guard case .corruptedModel = availability else {
            return XCTFail("expected corruptedModel, got \(availability)")
        }
    }

    /// Section 35: preflight refuses before any allocation, because a jetsam
    /// kill is not catchable and an honest refusal is.
    func testAModelTooLargeForTheDeviceIsRefusedBeforeLoading() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let model = descriptor("huge", bytes: 6 * .gigabyte)
        try store.prepareDirectory()
        try GGUFFixture.header().write(to: store.url(forRelativePath: model.suggestedFileName))
        try await repositories.localModels.save(
            LocalModelRecord(
                id: model.id,
                relativePath: model.suggestedFileName,
                fileSizeBytes: 6 * .gigabyte,
                installedAt: now,
                contextLength: 4096
            )
        )

        let runtime = MockLocalModelRuntime()
        let manager = LocalModelManager(
            catalog: LocalModelCatalog(models: [model]),
            repository: repositories.localModels,
            settings: repositories.settings,
            store: store,
            runtime: runtime,
            device: FixedDeviceResources.smallPhone,
            dateProvider: FixedDateProvider(now: now)
        )

        do {
            _ = try await manager.load(model.id)
            XCTFail("expected a preflight refusal")
        } catch let error as LocalRuntimeError {
            guard case .insufficientMemory = error else {
                return XCTFail("expected insufficientMemory, got \(error)")
            }
        }
        let loads = await runtime.loadCount
        XCTAssertEqual(loads, 0, "the runtime must not have been asked at all")
    }

    // MARK: Switching

    /// Section 105. A → B unloads A before loading B, and touches nothing else.
    func testSwitchingModelsUnloadsTheFirstAndKeepsUserData() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let a = descriptor("model-a")
        let b = descriptor("model-b")
        try await install(a, into: repositories)
        try await install(b, into: repositories)

        var conversation = Conversation(title: "Morning", createdAt: now)
        conversation.messages = [Message(role: .user, text: "Hello", createdAt: now)]
        try await repositories.conversations.save(conversation)
        try await repositories.memories.store(
            MemoryItem(kind: .routine, content: "I leave at eight.", createdAt: now, source: .user)
        )

        let runtime = MockLocalModelRuntime()
        let manager = manager(repositories, catalog: [a, b], runtime: runtime)

        try await manager.select(a.id)
        _ = try await manager.load(a.id)
        try await manager.select(b.id)
        _ = try await manager.load(b.id)

        let loaded = await runtime.loadedModel()
        XCTAssertEqual(loaded?.modelID, b.id)
        let unloads = await runtime.unloadCount
        XCTAssertGreaterThanOrEqual(unloads, 1, "A must have been released before B loaded")

        // Section 67: none of the user's data moved.
        let conversations = try await repositories.conversations.allConversations()
        XCTAssertEqual(conversations.first?.messages.count, 1)
        let memories = try await repositories.memories.all()
        XCTAssertEqual(memories.count, 1)
    }

    /// Section 64. The selection is a setting and survives a relaunch; the
    /// loaded runtime is not and cannot.
    func testTheSelectedModelIsPersistedAndTheLoadedOneIsNot() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let model = descriptor("model-a")
        try await install(model, into: repositories)

        let firstRun = manager(repositories, catalog: [model], runtime: MockLocalModelRuntime())
        try await firstRun.select(model.id)
        _ = try await firstRun.load(model.id)

        // A second manager over the same store is what a relaunch looks like.
        let freshRuntime = MockLocalModelRuntime()
        let secondRun = manager(repositories, catalog: [model], runtime: freshRuntime)

        let selected = await secondRun.selectedModelID()
        XCTAssertEqual(selected, model.id)
        let residentAfterRelaunch = await freshRuntime.loadedModel()
        XCTAssertNil(residentAfterRelaunch, "nothing may be loaded at startup")

        // Section 112: it can be loaded again from what was persisted.
        let info = try await secondRun.ensureSelectedModelLoaded()
        XCTAssertEqual(info.modelID, model.id)
    }

    // MARK: Deletion

    /// Section 106. Deleting a model removes its file, its row and its
    /// selection — and nothing else at all.
    func testDeletingAModelKeepsEverythingElse() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let model = descriptor("model-a")
        let record = try await install(model, into: repositories)

        try await repositories.memories.store(
            MemoryItem(kind: .fact, content: "My dentist is Dr Alvarez.", createdAt: now, source: .user)
        )
        try await repositories.tasks.save(
            TaskItem(title: "Call the dentist", createdAt: now)
        )
        var conversation = Conversation(title: "Chat", createdAt: now)
        conversation.messages = [Message(role: .user, text: "Hi", createdAt: now)]
        try await repositories.conversations.save(conversation)

        let runtime = MockLocalModelRuntime()
        let manager = manager(repositories, catalog: [model], runtime: runtime)
        try await manager.select(model.id)
        _ = try await manager.load(model.id)

        try await manager.delete(model.id)

        XCTAssertFalse(store.fileExists(record))
        let rows = try await repositories.localModels.installedModels()
        XCTAssertTrue(rows.isEmpty)
        let selected = await manager.selectedModelID()
        XCTAssertNil(selected, "the selection must not point at something deleted")
        let resident = await runtime.loadedModel()
        XCTAssertNil(resident, "the runtime must release a model that has been deleted")

        // Section 67, stated as assertions.
        let memories = try await repositories.memories.all()
        XCTAssertEqual(memories.count, 1)
        let tasks = try await repositories.tasks.tasks(matching: TaskFilter())
        XCTAssertEqual(tasks.count, 1)
        let conversations = try await repositories.conversations.allConversations()
        XCTAssertEqual(conversations.first?.messages.count, 1)
        let settings = try await repositories.settings.settings()
        XCTAssertEqual(settings.conversationContextLimit, AssistantSettings().conversationContextLimit)
    }

    /// Local AI with nothing installed is `configurationRequired`, which is
    /// what makes Settings offer a way forward instead of a dead end.
    func testNoModelInstalledIsAnActionableState() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let manager = manager(
            repositories,
            catalog: [descriptor("model-a")],
            runtime: MockLocalModelRuntime()
        )

        let availability = await manager.availability()
        guard case .noModelInstalled = availability else {
            return XCTFail("expected noModelInstalled, got \(availability)")
        }

        let provider = LocalModelProvider(manager: manager, runtime: MockLocalModelRuntime())
        let providerAvailability = await provider.availability()
        XCTAssertTrue(providerAvailability.isUserResolvable)
    }

    /// A build with no runtime says so, rather than looking merely unconfigured.
    func testNoRuntimeIsReportedAsUnsupported() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let manager = LocalModelManager(
            catalog: LocalModelCatalog(models: [descriptor("model-a")]),
            repository: repositories.localModels,
            settings: repositories.settings,
            store: store,
            runtime: nil,
            device: FixedDeviceResources.largePhone
        )

        let availability = await manager.availability()
        guard case .runtimeUnavailable = availability else {
            return XCTFail("expected runtimeUnavailable, got \(availability)")
        }

        let provider = LocalModelProvider(manager: manager, runtime: nil)
        let providerAvailability = await provider.availability()
        guard case .unsupported = providerAvailability else {
            return XCTFail("expected unsupported, got \(providerAvailability)")
        }
    }

    // MARK: Listing

    /// The list is ordered best fit first, so the model most likely to work is
    /// the one the user sees.
    func testStatusesAreOrderedByFit() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let small = descriptor("small", bytes: 500_000_000)
        let huge = descriptor("huge", bytes: 20 * .gigabyte)
        let manager = LocalModelManager(
            catalog: LocalModelCatalog(models: [huge, small]),
            repository: repositories.localModels,
            settings: repositories.settings,
            store: store,
            runtime: MockLocalModelRuntime(),
            device: FixedDeviceResources.midPhone
        )

        let statuses = await manager.statuses()
        XCTAssertEqual(statuses.first?.id, small.id)
        XCTAssertFalse(statuses.last?.canDownload == true)
    }
}
