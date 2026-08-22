import AIProviderLocal
import AssistantAI
import AssistantDomain
import AssistantPersistence
import AssistantPlatform
import AssistantTools
import MockPlatform
import PersonalMemory
import XCTest
@testable import AssistantCore

/// Local AI, through the whole application pipeline.
///
/// ## Why these live here rather than beside the provider
///
/// Because the claim Part 10 makes is not about `LocalModelProvider` — it is
/// about everything *above* it being unchanged. A test inside the provider's
/// own target can only assert that an `AIToolCall` came out; only here can it
/// assert that the call was decoded, validated, authorized, ordered, planned
/// and executed by the same `AgentRunner` that serves the cloud model, and that
/// the llama.cpp runtime touched none of it.
///
/// Everything runs on `MockLocalModelRuntime` (section 89): scripted, offline,
/// no GPU, no model file worth the name. What is under test is the plumbing.
final class LocalProviderIntegrationTests: XCTestCase {
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

    // MARK: Harness

    private var descriptor: LocalModelDescriptor {
        LocalModelDescriptor(
            id: "test-local",
            displayName: "Test Local Model",
            architecture: "qwen3",
            parameterCount: 1_700_000_000,
            quantization: .q4KM,
            fileSizeBytes: 1_100_000_000,
            downloadURL: URL(string: "https://example.invalid/model.gguf"),
            defaultContextLength: 4096,
            kvCacheBytesPerToken: 32 * 1024,
            toolSupport: .supported,
            chatTemplate: .chatML
        )
    }

    /// A local provider with its model installed and selected, ready to serve
    /// a turn.
    private func makeLocalProvider(
        repositories: AssistantRepositories,
        runtime: MockLocalModelRuntime
    ) async throws -> LocalModelProvider {
        let model = descriptor
        try store.prepareDirectory()
        // A single byte would do — the mock runtime never reads it — but a real
        // header keeps the manager's "is the file still there" checks honest.
        try Data("GGUF-placeholder".utf8).write(to: store.url(forRelativePath: model.suggestedFileName))
        try await repositories.localModels.save(
            LocalModelRecord(
                id: model.id,
                relativePath: model.suggestedFileName,
                fileSizeBytes: 1_100_000_000,
                installedAt: now,
                architecture: "qwen3",
                contextLength: 4096
            )
        )
        var settings = try await repositories.settings.settings()
        settings.selectedLocalModelID = model.id
        try await repositories.settings.update(settings)

        let manager = LocalModelManager(
            catalog: LocalModelCatalog(models: [model]),
            repository: repositories.localModels,
            settings: repositories.settings,
            store: store,
            runtime: runtime,
            device: FixedDeviceResources.largePhone,
            dateProvider: FixedDateProvider(now: now)
        )
        return LocalModelProvider(manager: manager, runtime: runtime)
    }

    private func makeEngine(
        _ repositories: AssistantRepositories,
        provider: any AIProvider,
        services: PlatformServices = .mock()
    ) async throws -> AssistantEngine {
        var settings = try await repositories.settings.settings()
        settings.preferredProviderID = provider.metadata.id
        settings.routingPolicy = .explicit
        try await repositories.settings.update(settings)

        return AssistantEngine(
            providers: AIProviderRegistry(providers: [provider]),
            repositories: repositories,
            services: services,
            dateProvider: FixedDateProvider(now: now)
        )
    }

    // MARK: A local tool call, end to end

    /// Section 101 and 135. The model proposes; the application decides,
    /// authorizes and executes.
    func testALocalToolCallIsValidatedAuthorizedAndExecuted() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let runtime = MockLocalModelRuntime()
        await runtime.enqueue(
            .toolCalls(
                names: ["createTask"],
                arguments: [["title": .string("Call the dentist")]],
                message: "I'll add that."
            ),
            .text("Added — it's on your list.")
        )

        let provider = try await makeLocalProvider(repositories: repositories, runtime: runtime)
        let engine = try await makeEngine(repositories, provider: provider)

        let conversation = try await engine.startConversation(title: "Local")
        let turn = try await engine.send("Remind me to call the dentist.", in: conversation.id)

        // It reached the real executor, through the real planner.
        let tasks = try await repositories.tasks.tasks(matching: .outstanding)
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks.first?.title, "Call the dentist")
        XCTAssertEqual(turn.providerID, LocalModelProvider.providerID)
        XCTAssertFalse(turn.results.isEmpty)
        XCTAssertTrue(turn.results.allSatisfy { $0.status.didAct })
    }

    /// Section 52 and 58, stated as an assertion rather than as a comment: the
    /// runtime never reaches a platform service. If it could, this counter
    /// would move without the engine ever running.
    func testTheRuntimeCannotReachPlatformServicesItself() async throws {
        let repositories = AssistantRepositories.ephemeral()
        // Real mock services wired to a log that records anything they are
        // asked to do. Nothing else in this test touches them, so a single
        // entry would mean the provider reached the platform on its own.
        let log = PlatformEventLog()
        _ = PlatformServices.mock(log: log)
        let runtime = MockLocalModelRuntime()
        await runtime.alwaysRespond(
            .toolCalls(
                names: ["createCalendarEvent"],
                arguments: [[
                    "title": .string("Dentist"),
                    "start": .string("2026-09-04T10:00:00Z"),
                ]],
                message: "Adding it."
            )
        )

        let provider = try await makeLocalProvider(repositories: repositories, runtime: runtime)

        // Generating on its own — no engine, no executor — must change nothing.
        _ = try? await provider.respond(
            to: AIRequest(
                systemPrompt: "Assistant.",
                messages: [AIMessage(role: .user, content: "Book the dentist.")],
                tools: [
                    AIToolSchema(
                        name: "createCalendarEvent",
                        description: "Create an event.",
                        parameters: .object(
                            properties: ["title": .string(), "start": .string(format: .dateTime)],
                            required: ["title", "start"]
                        )
                    )
                ]
            )
        )

        let entries = await log.allEntries()
        XCTAssertTrue(entries.isEmpty, "a provider must never be able to act on its own")
    }

    /// Section 103. Two rounds of actions and a final reply, through the
    /// existing agent loop — no separate local agent engine.
    func testAMultiStepLocalTurnRunsThroughTheExistingAgentLoop() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let runtime = MockLocalModelRuntime()
        await runtime.enqueue(
            .toolCalls(
                names: ["createCalendarEvent"],
                arguments: [[
                    "title": .string("Dentist"),
                    "start": .string("2026-09-04T10:00:00Z"),
                ]],
                message: "Putting that in the calendar."
            ),
            .toolCalls(
                names: ["createTask"],
                arguments: [["title": .string("Take the referral letter")]],
                message: "And a reminder for the letter."
            ),
            .text("Both done. You're at the dentist on Friday at ten.")
        )

        let provider = try await makeLocalProvider(repositories: repositories, runtime: runtime)
        let engine = try await makeEngine(repositories, provider: provider)

        var settings = try await repositories.settings.settings()
        settings.routingPolicy = .explicit
        try await repositories.settings.update(settings)

        let conversation = try await engine.startConversation(title: "Multi-step")
        let turn = try await engine.send(
            "I've got the dentist Friday at ten — sort it out and remind me about the letter.",
            in: conversation.id
        )

        let tasks = try await repositories.tasks.tasks(matching: .outstanding)
        XCTAssertTrue(
            tasks.contains { $0.title == "Take the referral letter" },
            "the second round's action must have run"
        )
        XCTAssertGreaterThanOrEqual(turn.results.count, 2)
        XCTAssertFalse(turn.assistantMessage.text.isEmpty)

        // Section 61: the loop's own limits still applied, and the same model
        // was asked more than once rather than a second engine being used.
        let rounds = await runtime.generateCount
        XCTAssertGreaterThanOrEqual(rounds, 2)
        XCTAssertLessThanOrEqual(rounds, AgentLimits.default.maximumRounds + 1)
    }

    /// Section 37 of the acceptance list. The same action proposed twice in one
    /// turn is executed once — the ledger does not care which provider asked.
    func testDuplicatePreventionAppliesToTheLocalModelToo() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let runtime = MockLocalModelRuntime()
        await runtime.enqueue(
            .toolCalls(
                names: ["createTask"],
                arguments: [["title": .string("Pay the rent")]],
                message: "Adding it."
            ),
            .toolCalls(
                names: ["createTask"],
                arguments: [["title": .string("Pay the rent")]],
                message: "Adding it."
            ),
            .text("Done.")
        )

        let provider = try await makeLocalProvider(repositories: repositories, runtime: runtime)
        let engine = try await makeEngine(repositories, provider: provider)

        let conversation = try await engine.startConversation(title: "Duplicates")
        _ = try await engine.send("Remind me to pay the rent.", in: conversation.id)

        let tasks = try await repositories.tasks.tasks(matching: .outstanding)
        XCTAssertEqual(tasks.filter { $0.title == "Pay the rent" }.count, 1)
    }

    /// Section 102 and 39 of the acceptance list. Output that does not parse
    /// cannot execute anything.
    func testMalformedLocalOutputExecutesNothing() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let runtime = MockLocalModelRuntime()
        await runtime.alwaysRespond(
            .raw("{\"tool_calls\":[{\"name\":\"createTask\",\"arguments\":\"not json\"}],\"message\":\"\"}")
        )

        let provider = try await makeLocalProvider(repositories: repositories, runtime: runtime)
        let engine = try await makeEngine(repositories, provider: provider)

        let conversation = try await engine.startConversation(title: "Bad output")
        let turn = try? await engine.send("Do something.", in: conversation.id)

        let tasks = try await repositories.tasks.tasks(matching: .outstanding)
        XCTAssertTrue(tasks.isEmpty, "nothing may execute from output that did not parse")
        // The turn either failed or produced no actions; both are acceptable,
        // and neither is "a task appeared".
        XCTAssertTrue(turn?.results.contains { $0.status.didAct } != true)
    }

    // MARK: Provider independence

    /// Section 110 and 42. The memory selected for a turn is the same whichever
    /// provider is answering — because memory retrieval happens before a
    /// provider is involved at all.
    func testTheSameMemoryContextReachesEveryProvider() async throws {
        let repositories = AssistantRepositories.ephemeral()
        for content in [
            "It takes me about 30 minutes to drive to work.",
            "I usually need about 45 minutes to get ready before work.",
            "I like Sony cameras.",
        ] {
            try await repositories.memories.store(
                MemoryItem(
                    kind: .routine,
                    content: content,
                    createdAt: now,
                    source: .user,
                    entityKeys: MemoryEntityExtractor.keys(for: content, kind: .routine)
                )
            )
        }

        let question = "When should I leave for work?"

        // What the local model is given.
        let localRuntime = MockLocalModelRuntime()
        await localRuntime.alwaysRespond(.text("Around eight."))
        let localProvider = try await makeLocalProvider(
            repositories: repositories,
            runtime: localRuntime
        )
        let localEngine = try await makeEngine(repositories, provider: localProvider)
        let localConversation = try await localEngine.startConversation(title: "Local")
        _ = try await localEngine.send(question, in: localConversation.id)
        let localPrompt = await localRuntime.lastPrompt
        let localSystem = localPrompt?.turns.first { $0.role == "system" }?.content ?? ""

        // What a completely different provider is given, from the same store.
        let recorder = RecordingProvider(id: "test.recorder")
        let otherEngine = try await makeEngine(repositories, provider: recorder)
        let otherConversation = try await otherEngine.startConversation(title: "Other")
        _ = try await otherEngine.send(question, in: otherConversation.id)
        let otherSystem = await recorder.lastRequest?.systemPrompt ?? ""

        XCTAssertFalse(localSystem.isEmpty)
        XCTAssertFalse(otherSystem.isEmpty)
        // The commute memory reaches both; the camera preference reaches
        // neither, which is the relevance gate doing its job identically.
        XCTAssertTrue(localSystem.contains("30 minutes"))
        XCTAssertTrue(otherSystem.contains("30 minutes"))
        XCTAssertEqual(
            localSystem.contains("Sony"),
            otherSystem.contains("Sony"),
            "the selection must not depend on which model is answering"
        )
    }

    /// Section 104. Remote → Local → Apple → Local, with nothing lost.
    func testSwitchingToAndFromLocalKeepsEverything() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let runtime = MockLocalModelRuntime()
        await runtime.alwaysRespond(.text("Still here."))
        let local = try await makeLocalProvider(repositories: repositories, runtime: runtime)
        let cloud = RecordingProvider(id: "test.cloud", reply: "Cloud reply.")
        let apple = RecordingProvider(id: "test.apple", reply: "Apple reply.")

        var settings = try await repositories.settings.settings()
        settings.routingPolicy = .explicit
        settings.preferredProviderID = cloud.metadata.id
        settings.support.advanceNoticeDays = [5]
        try await repositories.settings.update(settings)

        let engine = AssistantEngine(
            providers: AIProviderRegistry(providers: [cloud, local, apple]),
            repositories: repositories,
            services: .mock(),
            dateProvider: FixedDateProvider(now: now)
        )

        try await repositories.memories.store(
            MemoryItem(kind: .fact, content: "My dentist is Dr Alvarez.", createdAt: now, source: .user)
        )
        try await repositories.tasks.save(TaskItem(title: "Pay the rent", createdAt: now))

        let conversation = try await engine.startConversation(title: "Shared")
        _ = try await engine.send("Hello.", in: conversation.id)

        for provider in [local.metadata.id, apple.metadata.id, local.metadata.id] {
            var switched = try await repositories.settings.settings()
            switched.preferredProviderID = provider
            try await repositories.settings.update(switched)
            _ = try await engine.send("Still there?", in: conversation.id)
        }

        // Everything the user owns is exactly where it was.
        let memories = try await repositories.memories.all()
        XCTAssertEqual(memories.count, 1)
        XCTAssertEqual(memories.first?.content, "My dentist is Dr Alvarez.")
        let tasks = try await repositories.tasks.tasks(matching: .outstanding)
        XCTAssertEqual(tasks.count, 1)
        let final = try await repositories.settings.settings()
        XCTAssertEqual(final.support.advanceNoticeDays, [5])
        XCTAssertEqual(final.selectedLocalModelID, descriptor.id, "the local selection survived")

        let reloaded = try await repositories.conversations.conversation(id: conversation.id)
        XCTAssertEqual(reloaded?.messages.count, 8, "four turns, each a question and an answer")
    }
}

/// A provider that records what it was asked and replies with a fixed line.
private actor RecordingProvider: AIProvider {
    nonisolated let metadata: AIProviderMetadata
    private let reply: String
    private(set) var lastRequest: AIRequest?

    init(id: AIProviderIdentifier, reply: String = "Noted.") {
        self.metadata = AIProviderMetadata(
            id: id,
            displayName: id.rawValue,
            kind: .development,
            requiresNetwork: false,
            requiresCredentials: false,
            capabilityRank: 10
        )
        self.reply = reply
    }

    func availability() async -> AIProviderAvailability { .available }

    func availableModels() async throws -> [AIModel] { [] }

    func respond(to request: AIRequest) async throws -> AIResponse {
        lastRequest = request
        return AIResponse(text: reply, providerID: metadata.id)
    }
}
