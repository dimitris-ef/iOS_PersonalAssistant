import AssistantAI
import AssistantDomain
import AssistantPersistence
import NativeModelKit
import XCTest
@testable import AIProviderLocal

/// The provider: what it sends down to the runtime, and what it brings back up.
///
/// The claim under test is that `LocalModelProvider` is a translator and
/// nothing more. It gets an `AIRequest` — already carrying the app's system
/// prompt, its assembled memory context and its tool schemas — and returns an
/// `AIResponse`. It does not retrieve memory, does not execute anything, and
/// does not fall back to the cloud.
final class LocalModelProviderTests: XCTestCase {
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
        _ id: AIModelIdentifier = "model-a",
        toolSupport: LocalModelToolSupport = .supported
    ) -> LocalModelDescriptor {
        LocalModelDescriptor(
            id: id,
            displayName: "Test Model",
            architecture: "qwen3",
            parameterCount: 1_700_000_000,
            quantization: .q4KM,
            fileSizeBytes: 1_100_000_000,
            downloadURL: URL(string: "https://example.invalid/model.gguf"),
            defaultContextLength: 4096,
            kvCacheBytesPerToken: 32 * 1024,
            toolSupport: toolSupport,
            chatTemplate: .chatML
        )
    }

    /// A manager with the model already installed and selected.
    private func makeProvider(
        descriptor model: LocalModelDescriptor,
        runtime: MockLocalModelRuntime,
        repositories: AssistantRepositories = .ephemeral()
    ) async throws -> (LocalModelProvider, LocalModelManager, AssistantRepositories) {
        try store.prepareDirectory()
        try GGUFFixture.header().write(to: store.url(forRelativePath: model.suggestedFileName))
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
        try await repositories.settings.update(AssistantSettings(selectedLocalModelID: model.id))

        let manager = LocalModelManager(
            catalog: LocalModelCatalog(models: [model]),
            repository: repositories.localModels,
            settings: repositories.settings,
            store: store,
            runtime: runtime,
            device: FixedDeviceResources.largePhone,
            dateProvider: FixedDateProvider(now: now)
        )
        return (LocalModelProvider(manager: manager, runtime: runtime), manager, repositories)
    }

    private var tools: [AIToolSchema] {
        [
            AIToolSchema(
                name: "createTask",
                description: "Create a task.",
                parameters: .object(properties: ["title": .string()], required: ["title"])
            )
        ]
    }

    private func request(
        systemPrompt: String = "You are a personal assistant.",
        messages: [AIMessage] = [AIMessage(role: .user, content: "What's on today?")],
        tools: [AIToolSchema] = []
    ) -> AIRequest {
        AIRequest(systemPrompt: systemPrompt, messages: messages, tools: tools)
    }

    // MARK: Text generation

    /// Section 100. Plain text becomes an ordinary `AIResponse` with no
    /// provider-specific leakage.
    func testTextGenerationBecomesANormalResponse() async throws {
        let runtime = MockLocalModelRuntime()
        await runtime.alwaysRespond(.text("Your next appointment is Friday at 10."))
        let (provider, _, _) = try await makeProvider(descriptor: descriptor(), runtime: runtime)

        let response = try await provider.respond(to: request())

        XCTAssertEqual(response.text, "Your next appointment is Friday at 10.")
        XCTAssertTrue(response.toolCalls.isEmpty)
        XCTAssertEqual(response.stopReason, .endTurn)
        XCTAssertEqual(response.providerID, LocalModelProvider.providerID)
        XCTAssertEqual(response.modelID, "model-a")
    }

    /// Section 26 and 41. The app's system prompt reaches the model unchanged,
    /// and there is no separate local personality bolted on.
    func testTheApplicationSystemPromptReachesTheModel() async throws {
        let runtime = MockLocalModelRuntime()
        await runtime.alwaysRespond(.text("ok"))
        let (provider, _, _) = try await makeProvider(descriptor: descriptor(), runtime: runtime)

        _ = try await provider.respond(
            to: request(systemPrompt: "You help someone with ADHD stay on top of their day.")
        )

        let prompt = await runtime.lastPrompt
        let system = prompt?.turns.first { $0.role == "system" }?.content
        XCTAssertNotNil(system)
        XCTAssertTrue(system?.contains("someone with ADHD") == true)
    }

    /// Sections 27, 28 and 42: conversation history and the memory context the
    /// app assembled both arrive, and the provider did not go and fetch them.
    func testConversationAndAssembledMemoryContextBothArrive() async throws {
        let runtime = MockLocalModelRuntime()
        await runtime.alwaysRespond(.text("ok"))
        let (provider, _, _) = try await makeProvider(descriptor: descriptor(), runtime: runtime)

        _ = try await provider.respond(
            to: request(
                systemPrompt: "Assistant.\n\nWhat you remember:\n- It takes 30 minutes to drive to work.",
                messages: [
                    AIMessage(role: .user, content: "When should I leave?"),
                    AIMessage(role: .assistant, content: "Around eight."),
                    AIMessage(role: .user, content: "And tomorrow?"),
                ]
            )
        )

        let prompt = await runtime.lastPrompt
        let joined = prompt?.turns.map(\.content).joined(separator: "\n") ?? ""
        XCTAssertTrue(joined.contains("30 minutes to drive to work"))
        XCTAssertTrue(joined.contains("And tomorrow?"))
        XCTAssertEqual(prompt?.turns.filter { $0.role == "user" }.count, 2)
        XCTAssertEqual(prompt?.turns.filter { $0.role == "assistant" }.count, 1)
    }

    // MARK: Tool calls

    /// Section 101, the provider's half: structured output becomes an
    /// `AIToolCall`, and the runtime executed nothing.
    func testStructuredOutputBecomesAToolCall() async throws {
        let runtime = MockLocalModelRuntime()
        await runtime.alwaysRespond(
            .toolCalls(
                names: ["createTask"],
                arguments: [["title": .string("Call dentist")]],
                message: "I'll add that."
            )
        )
        let (provider, _, _) = try await makeProvider(descriptor: descriptor(), runtime: runtime)

        let response = try await provider.respond(to: request(tools: tools))

        XCTAssertEqual(response.toolCalls.count, 1)
        XCTAssertEqual(response.toolCalls.first?.name, "createTask")
        XCTAssertEqual(
            response.toolCalls.first?.arguments["title"]?.stringValue,
            "Call dentist"
        )
        XCTAssertEqual(response.stopReason, .toolCalls)
        XCTAssertEqual(response.text, "I'll add that.")
    }

    /// The tool instructions are built from the request's own schemas.
    func testToolInstructionsAreDerivedFromTheRequest() async throws {
        let runtime = MockLocalModelRuntime()
        await runtime.alwaysRespond(.text("ok"))
        let (provider, _, _) = try await makeProvider(descriptor: descriptor(), runtime: runtime)

        _ = try await provider.respond(to: request(tools: tools))

        let prompt = await runtime.lastPrompt
        let system = prompt?.turns.first { $0.role == "system" }?.content ?? ""
        XCTAssertTrue(system.contains("createTask"))
        XCTAssertTrue(system.contains("tool_calls"))
    }

    /// Sections 55 and 56. A chat-only model is never offered tools, so it
    /// cannot produce a malformed envelope that becomes a mystery failure.
    func testAChatOnlyModelIsNeverOfferedTools() async throws {
        let runtime = MockLocalModelRuntime()
        await runtime.alwaysRespond(.text("I can chat, but I can't do that."))
        let (provider, _, _) = try await makeProvider(
            descriptor: descriptor(toolSupport: .unsupported),
            runtime: runtime
        )

        let response = try await provider.respond(to: request(tools: tools))

        let prompt = await runtime.lastPrompt
        let system = prompt?.turns.first { $0.role == "system" }?.content ?? ""
        XCTAssertFalse(system.contains("tool_calls"), "a chat-only model gets no action protocol")
        XCTAssertTrue(response.toolCalls.isEmpty)
    }

    /// Section 102 and 39 of the acceptance list. Malformed structured output
    /// is a provider error — never a partial execution, never prose passed off
    /// as an answer.
    func testMalformedStructuredOutputIsAProviderError() async throws {
        let runtime = MockLocalModelRuntime()
        await runtime.alwaysRespond(.raw("{\"tool_calls\":[{\"name\":}],\"message\":\"x\"}"))
        let (provider, _, _) = try await makeProvider(descriptor: descriptor(), runtime: runtime)

        do {
            _ = try await provider.respond(to: request(tools: tools))
            XCTFail("expected an invalid-response error")
        } catch let error as AIProviderError {
            guard case .invalidResponse = error else {
                return XCTFail("expected invalidResponse, got \(error)")
            }
        }
    }

    func testAnUnknownToolNameIsAProviderError() async throws {
        let runtime = MockLocalModelRuntime()
        await runtime.alwaysRespond(
            .raw("{\"tool_calls\":[{\"name\":\"formatDisk\",\"arguments\":{}}],\"message\":\"\"}")
        )
        let (provider, _, _) = try await makeProvider(descriptor: descriptor(), runtime: runtime)

        do {
            _ = try await provider.respond(to: request(tools: tools))
            XCTFail("expected an invalid-response error")
        } catch let error as AIProviderError {
            guard case .invalidResponse = error else {
                return XCTFail("expected invalidResponse, got \(error)")
            }
        }
    }

    // MARK: Continuation

    /// Section 38 and 59. A tool result goes back to the model as the app's own
    /// compact rendering — never a serialized platform object.
    func testToolResultsAreFedBackCompactly() async throws {
        let runtime = MockLocalModelRuntime()
        await runtime.alwaysRespond(.text("Done — it's on your list."))
        let (provider, _, _) = try await makeProvider(descriptor: descriptor(), runtime: runtime)

        let callID = ToolCallID()
        let result = AIToolResult(
            callID: callID,
            toolName: "createTask",
            status: .succeeded,
            payload: ["id": "task-1", "title": "Call dentist"],
            message: "Added to your list."
        )

        _ = try await provider.respond(
            to: request(
                messages: [
                    AIMessage(role: .user, content: "Remind me to call the dentist."),
                    AIMessage(
                        role: .assistant,
                        content: "I'll add that.",
                        toolCalls: [
                            AIToolCall(
                                id: callID,
                                name: "createTask",
                                arguments: .object(["title": .string("Call dentist")])
                            )
                        ]
                    ),
                    AIMessage(
                        role: .tool,
                        content: result.renderedForModel,
                        toolCallID: callID,
                        toolResult: result
                    ),
                ],
                tools: tools
            )
        )

        let prompt = await runtime.lastPrompt
        let toolTurn = prompt?.turns.first { $0.role == "tool" }
        XCTAssertNotNil(toolTurn)
        XCTAssertTrue(toolTurn?.content.contains("succeeded") == true)
        XCTAssertTrue(toolTurn?.content.contains("task-1") == true)

        // The assistant's own previous proposal is replayed in the shape it was
        // asked to produce, so a continuation round recognises its own output.
        let assistantTurn = prompt?.turns.first { $0.role == "assistant" }
        XCTAssertTrue(assistantTurn?.content.contains("createTask") == true)
    }

    /// Section 36 of the acceptance list: the provider declares it can be sent
    /// results and asked to carry on, which is what the agent loop needs.
    func testTheProviderSupportsContinuation() async throws {
        let runtime = MockLocalModelRuntime()
        let (provider, _, _) = try await makeProvider(descriptor: descriptor(), runtime: runtime)
        XCTAssertTrue(provider.metadata.supportsToolResultContinuation)
        XCTAssertFalse(provider.metadata.requiresNetwork)
        XCTAssertFalse(provider.metadata.requiresCredentials)
    }

    // MARK: Failure and cancellation

    /// Section 108. Cancelling stops the reply, produces no stale result, and
    /// leaves the model usable for the next question.
    func testCancellingGenerationLeavesTheModelUsable() async throws {
        let runtime = MockLocalModelRuntime()
        await runtime.enqueue(.hangUntilCancelled, .text("Second answer."))
        let (provider, _, _) = try await makeProvider(descriptor: descriptor(), runtime: runtime)

        let first = Task { try await provider.respond(to: request()) }
        // Give the generation a moment to be in flight before cancelling.
        try await Task.sleep(nanoseconds: 20_000_000)
        await provider.cancelGeneration()

        do {
            _ = try await first.value
            XCTFail("expected cancellation")
        } catch let error as AIProviderError {
            XCTAssertEqual(error, .cancelled)
        }

        // Still loaded, and answers the next question (section 48).
        let resident = await runtime.loadedModel()
        XCTAssertNotNil(resident)
        let second = try await provider.respond(to: request())
        XCTAssertEqual(second.text, "Second answer.")
    }

    /// Section 107. A runtime out-of-memory becomes a meaningful provider error
    /// rather than a crash, and the model can be recovered by unloading.
    func testAnOutOfMemoryFailureIsMappedAndRecoverable() async throws {
        let runtime = MockLocalModelRuntime()
        await runtime.alwaysRespond(
            .failure(.insufficientMemory(reason: "the KV cache could not be grown"))
        )
        let (provider, manager, repositories) = try await makeProvider(
            descriptor: descriptor(),
            runtime: runtime
        )
        try await repositories.memories.store(
            MemoryItem(kind: .fact, content: "Keep me.", createdAt: now, source: .user)
        )

        do {
            _ = try await provider.respond(to: request())
            XCTFail("expected a failure")
        } catch let error as AIProviderError {
            guard case .unavailable(let reason) = error else {
                return XCTFail("expected unavailable, got \(error)")
            }
            XCTAssertTrue(reason.contains("KV cache"))
        }

        await manager.unload()
        let memories = try await repositories.memories.all()
        XCTAssertEqual(memories.count, 1, "an inference failure must not touch user data")
    }

    /// Section 128, and the most important negative in this file. A local
    /// failure is a local failure — there is no path from here to a network.
    func testALocalFailureNeverReachesTheNetwork() async throws {
        let runtime = MockLocalModelRuntime()
        await runtime.alwaysRespond(.failure(.generationFailed(reason: "decode failed")))
        let (provider, _, _) = try await makeProvider(descriptor: descriptor(), runtime: runtime)

        do {
            _ = try await provider.respond(to: request())
            XCTFail("expected a failure")
        } catch let error as AIProviderError {
            guard case .invalidResponse = error else {
                return XCTFail("expected invalidResponse, got \(error)")
            }
        }
        // Stated as a property of the type rather than as a network assertion:
        // the provider is constructed with a manager and a runtime, and holds
        // no transport it could reach a service with.
        XCTAssertFalse(provider.metadata.requiresNetwork)
    }

    // MARK: Offline

    /// Section 109. Nothing in a local turn needs the internet.
    ///
    /// The mock transport is the proof: the manager is built with a download
    /// transport that fails every request, and generation is unaffected because
    /// generation never asks it for anything.
    func testGenerationWorksWithNoNetworkAtAll() async throws {
        let repositories = AssistantRepositories.ephemeral()
        let model = descriptor()
        try store.prepareDirectory()
        try GGUFFixture.header().write(to: store.url(forRelativePath: model.suggestedFileName))
        try await repositories.localModels.save(
            LocalModelRecord(
                id: model.id,
                relativePath: model.suggestedFileName,
                fileSizeBytes: 1_100_000_000,
                installedAt: now,
                contextLength: 4096
            )
        )
        try await repositories.settings.update(AssistantSettings(selectedLocalModelID: model.id))

        let runtime = MockLocalModelRuntime()
        await runtime.alwaysRespond(.text("You have one thing today: the dentist at ten."))
        let offlineTransport = OfflineTransport()
        let manager = LocalModelManager(
            catalog: LocalModelCatalog(models: [model]),
            repository: repositories.localModels,
            settings: repositories.settings,
            store: store,
            runtime: runtime,
            device: FixedDeviceResources.largePhone,
            downloads: LocalModelDownloadManager(transport: offlineTransport)
        )
        let provider = LocalModelProvider(manager: manager, runtime: runtime)

        let response = try await provider.respond(to: request())

        XCTAssertEqual(response.text, "You have one thing today: the dentist at ten.")
        XCTAssertEqual(offlineTransport.attempts, 0, "generation must not touch the network")
    }
}

/// A transport that would fail if anything asked it for bytes.
private final class OfflineTransport: ModelDownloadTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var attempts: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func download(
        from url: URL,
        resumeData: Data?,
        onProgress: @Sendable @escaping (LocalModelDownloadProgress) -> Void
    ) async throws -> DownloadedFile {
        lock.lock()
        count += 1
        lock.unlock()
        throw LocalModelDownloadError.transport(reason: "The Internet connection appears to be offline.")
    }

    func cancel(url: URL) async -> Data? { nil }
}
