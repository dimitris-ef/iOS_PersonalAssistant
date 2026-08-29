import AssistantAI
import AssistantDomain
import AssistantPersistence
import NativeModelKit
import XCTest

@testable import AIProviderLocal

/// Downloading a model does nothing else.
///
/// ## Why this file exists
///
/// Sections 15 and 16, stated as a hard requirement: a completed download must
/// **not** load the model, must **not** select it, and must **not** change
/// which provider answers the next message. This is the regression that is
/// easiest to reintroduce and hardest to notice — the convenient thing to write
/// is `download(); load(); select()`, and the result looks *helpful* right up
/// until a phone with three downloaded models is holding two gigabytes it was
/// never asked to hold, answering from a model the user did not pick.
///
/// So each of the three is asserted separately, on the same completed download,
/// against the real download path with a fake transport rather than by
/// installing a record by hand.
final class LocalModelDownloadIsolationTests: XCTestCase {
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

    private func descriptor(_ id: AIModelIdentifier) -> LocalModelDescriptor {
        LocalModelDescriptor(
            id: id,
            displayName: id.rawValue,
            architecture: "qwen3",
            parameterCount: 1_700_000_000,
            quantization: .q4KM,
            fileSizeBytes: nil,
            downloadURL: URL(string: "https://example.invalid/\(id.rawValue).gguf"),
            defaultContextLength: 4096,
            kvCacheBytesPerToken: 32 * 1024
        )
    }

    private func manager(
        _ repositories: AssistantRepositories,
        catalog: [LocalModelDescriptor],
        runtime: MockLocalModelRuntime,
        transport: FakeTransport
    ) -> LocalModelManager {
        LocalModelManager(
            catalog: LocalModelCatalog(models: catalog),
            repository: repositories.localModels,
            settings: repositories.settings,
            store: store,
            runtime: runtime,
            device: FixedDeviceResources.largePhone,
            downloads: LocalModelDownloadManager(
                transport: transport,
                dateProvider: FixedDateProvider(now: now)
            ),
            dateProvider: FixedDateProvider(now: now)
        )
    }

    // MARK: The three things a download must not do

    func testACompletedDownloadDoesNotLoadTheModel() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let model = descriptor("model-a")
        let runtime = MockLocalModelRuntime()
        let manager = manager(
            repositories,
            catalog: [model],
            runtime: runtime,
            transport: FakeTransport(payload: GGUFFixture.header())
        )

        let record = try await manager.download(model.id)
        XCTAssertEqual(record.id, model.id)

        let loadCount = await runtime.loadCount
        XCTAssertEqual(loadCount, 0, "downloading loaded the model")
        let loaded = await runtime.loadedModel()
        XCTAssertNil(loaded, "the weights are resident after a download")
    }

    func testACompletedDownloadDoesNotSelectTheModel() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let model = descriptor("model-a")
        let manager = manager(
            repositories,
            catalog: [model],
            runtime: MockLocalModelRuntime(),
            transport: FakeTransport(payload: GGUFFixture.header())
        )

        try await manager.download(model.id)

        let selected = await manager.selectedModelID()
        XCTAssertNil(selected, "downloading chose the model on the user's behalf")
        let status = await manager.status(of: model.id)
        XCTAssertEqual(status?.isSelected, false)
    }

    /// The one with teeth. Someone using the cloud who downloads a local model
    /// to try later must still be using the cloud when the download finishes.
    func testACompletedDownloadDoesNotChangeTheChatProvider() async throws {
        let repositories = AssistantRepositories.ephemeral()
        var settings = try await repositories.settings.settings()
        settings.preferredProviderID = "remote.openai-compatible"
        try await repositories.settings.update(settings)

        let model = descriptor("model-a")
        let manager = manager(
            repositories,
            catalog: [model],
            runtime: MockLocalModelRuntime(),
            transport: FakeTransport(payload: GGUFFixture.header())
        )

        try await manager.download(model.id)

        let after = try await repositories.settings.settings()
        XCTAssertEqual(
            after.preferredProviderID, "remote.openai-compatible",
            "downloading a local model switched the assistant"
        )
        XCTAssertNil(after.selectedLocalModelID)
    }

    /// A second download leaves the first model's selection alone. The greedy
    /// version of this — "the newest download becomes the model" — silently
    /// changes what answers the next message.
    func testASecondDownloadDoesNotDisplaceTheChosenModel() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let first = descriptor("model-a")
        let second = descriptor("model-b")
        let manager = manager(
            repositories,
            catalog: [first, second],
            runtime: MockLocalModelRuntime(),
            transport: FakeTransport(payload: GGUFFixture.header())
        )

        try await manager.download(first.id)
        try await manager.select(first.id)
        try await manager.download(second.id)

        let selected = await manager.selectedModelID()
        XCTAssertEqual(selected, first.id)
    }

    // MARK: What a download *does* leave behind

    /// The positive half: the model is installed, is offered to the picker, and
    /// reports itself as downloaded-but-not-loaded rather than ready.
    func testADownloadLeavesTheModelSelectableButNotLoaded() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let model = descriptor("model-a")
        let manager = manager(
            repositories,
            catalog: [model],
            runtime: MockLocalModelRuntime(),
            transport: FakeTransport(payload: GGUFFixture.header())
        )

        try await manager.download(model.id)
        guard let status = await manager.status(of: model.id) else {
            return XCTFail("the downloaded model has no status")
        }

        XCTAssertEqual(status.lifecycle, .downloaded)
        XCTAssertFalse(status.lifecycle.isLoaded)
        XCTAssertTrue(
            AssistantLocalChoices.isSelectable(status),
            "a downloaded model that is not loaded must still be offerable"
        )

        let row = LocalModelRowPresenter.state(for: status)
        XCTAssertEqual(row.runtime, .downloadedNotLoaded)
        XCTAssertTrue(row.offers(.use), "Use is how the user selects it, deliberately")
        XCTAssertTrue(row.offers(.load), "Load is how the user brings it into memory")
    }

    /// Local AI reports itself available on a downloaded model, so the picker
    /// is not a dead end — but availability is not residency, and nothing about
    /// asking the question loads anything.
    func testAskingAboutAvailabilityLoadsNothing() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let model = descriptor("model-a")
        let runtime = MockLocalModelRuntime()
        let manager = manager(
            repositories,
            catalog: [model],
            runtime: runtime,
            transport: FakeTransport(payload: GGUFFixture.header())
        )

        try await manager.download(model.id)
        try await manager.select(model.id)

        let availability = await manager.availability()
        XCTAssertEqual(availability, .modelDownloaded)

        let loadCount = await runtime.loadCount
        XCTAssertEqual(loadCount, 0)
    }
}

// MARK: - Doubles

/// A transport that hands back a fixed payload without touching the network.
private final class FakeTransport: ModelDownloadTransport, @unchecked Sendable {
    private let payload: Data

    init(payload: Data) {
        self.payload = payload
    }

    func download(
        from url: URL,
        resumeData: Data?,
        onProgress: @Sendable @escaping (LocalModelDownloadProgress) -> Void
    ) async throws -> DownloadedFile {
        onProgress(
            LocalModelDownloadProgress(
                bytesReceived: Int64(payload.count),
                bytesExpected: Int64(payload.count)
            )
        )
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("isolation-\(UUID().uuidString).part")
        try payload.write(to: file)
        return DownloadedFile(url: file, byteCount: Int64(payload.count))
    }

    func cancel(url: URL) async -> Data? { nil }
}
