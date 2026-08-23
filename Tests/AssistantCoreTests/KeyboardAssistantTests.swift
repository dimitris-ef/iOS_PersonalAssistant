import AssistantAI
import AssistantDomain
import AssistantPersistence
import AssistantPlatform
import Foundation
import MockPlatform
import SystemSurfaces
import XCTest

@testable import AssistantCore

/// The keyboard's half of the application, without a keyboard.
///
/// Everything a `UIInputViewController` would do is UIKit and needs a device.
/// Everything that *decides* anything is here: what request an operation
/// produces, what happens when nothing services it, and — the one that matters
/// most — that a question asked from a keyboard cannot write a task by any
/// route except the one every other tool call takes.
final class KeyboardAssistantTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    // MARK: Request mapping

    /// Section 103. The operation and the text, and nothing that names a
    /// provider, a model or a prompt.
    func testAnOperationProducesAMinimalRequest() throws {
        let request = KeyboardAssistantRequest(
            operation: .improve,
            inputText: "hi can you send me files",
            createdAt: now
        )

        XCTAssertEqual(request.operation, .improve)
        XCTAssertEqual(request.inputText, "hi can you send me files")
        XCTAssertEqual(request.createdAt, now)

        // The instruction is built application-side, from the operation alone.
        let instruction = KeyboardAssistantService.instruction(for: .improve)
        XCTAssertFalse(instruction.isEmpty)
        XCTAssertFalse(instruction.lowercased().contains("openai"))
        XCTAssertFalse(instruction.lowercased().contains("model"))
    }

    /// Each transformation asks for something different. Spelled out so the
    /// four operations cannot drift into meaning the same thing.
    func testEachTransformationHasItsOwnInstruction() {
        let instructions = [
            KeyboardAssistantService.instruction(for: .improve),
            KeyboardAssistantService.instruction(for: .shorten),
            KeyboardAssistantService.instruction(for: .grammar),
        ]
        XCTAssertEqual(Set(instructions).count, 3)

        // Ask Assistant is not a transformation and carries no instruction —
        // it is the user's own question, passed through unchanged.
        XCTAssertTrue(KeyboardAssistantService.instruction(for: .assistantQuery).isEmpty)
    }

    // MARK: Servicing

    /// The happy path: a request is waiting, the app is running, it answers.
    func testAPendingRequestIsAnsweredAndTheResultStored() async throws {
        let harness = Harness(providerText: "Could you send me the files?")
        try harness.store.write(
            KeyboardExchange(
                generatedAt: now,
                request: KeyboardAssistantRequest(
                    operation: .improve,
                    inputText: "hi can you send me files",
                    createdAt: now
                )
            )
        )

        let result = await harness.service(at: now).servicePendingRequest()

        XCTAssertEqual(result?.status, .completed)
        XCTAssertEqual(result?.text, "Could you send me the files?")

        let stored = try harness.store.read(KeyboardExchange.self)
        XCTAssertEqual(stored.result?.status, .completed)
    }

    /// Section 26. The keyboard states an operation; routing happens elsewhere,
    /// and the answer is the same shape whichever provider gives it.
    func testTheKeyboardNeverLearnsWhichProviderAnswered() async throws {
        for id in ["remote.stub", "apple.stub", "local.stub"] {
            let harness = Harness(providerID: AIProviderIdentifier(id), providerText: "Tidied.")
            try harness.store.write(
                KeyboardExchange(
                    generatedAt: now,
                    request: KeyboardAssistantRequest(
                        operation: .shorten, inputText: "a long sentence", createdAt: now
                    )
                )
            )

            let result = await harness.service(at: now).servicePendingRequest()
            XCTAssertEqual(result?.text, "Tidied.")

            let json = try String(
                decoding: SystemSurfaceCoding.encode(harness.store.read(KeyboardExchange.self)),
                as: UTF8.self
            )
            XCTAssertFalse(json.contains(id), "the provider identifier reached the keyboard")
        }
    }

    /// Section 105. The request failed; the user's text is untouched and there
    /// is no replacement to apply.
    func testAFailedRequestProducesNoReplacementText() async throws {
        let harness = Harness(providerText: "")
        try harness.store.write(
            KeyboardExchange(
                generatedAt: now,
                request: KeyboardAssistantRequest(
                    operation: .improve, inputText: "leave this alone", createdAt: now
                )
            )
        )

        let result = await harness.service(at: now).servicePendingRequest()

        XCTAssertEqual(result?.status, .failed)
        XCTAssertNil(result?.text)
        XCTAssertNotNil(result?.error)

        // Section 22: a sentence, not a diagnostic.
        let message = result?.error ?? ""
        XCTAssertFalse(message.contains("Error Domain"))
        XCTAssertFalse(message.lowercased().contains("stub"))
    }

    /// Section 94. A request nobody came back for does not sit in a shared file
    /// with somebody's half-written message in it.
    func testAnAbandonedRequestIsDiscardedRatherThanAnswered() async throws {
        let harness = Harness(providerText: "should never be produced")
        try harness.store.write(
            KeyboardExchange(
                generatedAt: now,
                request: KeyboardAssistantRequest(
                    operation: .improve,
                    inputText: "something private from yesterday",
                    createdAt: now
                )
            )
        )

        // An hour later. The keyboard gave up long ago.
        let later = now.addingTimeInterval(TimeSpan.hours(1))
        let result = await harness.service(at: later).servicePendingRequest()

        XCTAssertNil(result)
        let stored = try harness.store.read(KeyboardExchange.self)
        XCTAssertNil(stored.request)
        XCTAssertNil(stored.result)
    }

    /// Section 12 and 104. No shared container — Full Access is off — and the
    /// app simply has nothing to service. Nothing throws.
    func testWithNoSharedContainerThereIsNothingToService() async {
        let harness = Harness(providerText: "unused", storeAvailable: false)
        let result = await harness.service(at: now).servicePendingRequest()
        XCTAssertNil(result)
    }

    /// Nothing waiting is the normal state, and it is not an error.
    func testAnEmptyExchangeIsNotAnError() async {
        let harness = Harness(providerText: "unused")
        let result = await harness.service(at: now).servicePendingRequest()
        XCTAssertNil(result)
    }

    // MARK: Tool safety

    /// Section 106, and the most important test in this file.
    ///
    /// A transformation is handed **no tools**. Even a model that tries to call
    /// `createTask` has nothing to call, so a keyboard rewrite cannot write to
    /// the user's task list by any route — not because a validator rejected it,
    /// but because the capability was never offered.
    func testATransformationOffersTheModelNoTools() async throws {
        let provider = StubAIProvider(id: "tool.happy", text: "Rewritten.")
        let harness = Harness(provider: provider)

        _ = try await harness.engine.transformText(
            instruction: "Rewrite this:",
            text: "please add a dentist appointment tomorrow at ten"
        )

        let request = try XCTUnwrap(provider.receivedRequests.first)
        XCTAssertTrue(
            request.tools.isEmpty,
            "a keyboard transformation was offered tools it could call"
        )
        // And nothing was written.
        let tasks = try await harness.repositories.tasks.tasks(matching: TaskFilter())
        XCTAssertTrue(tasks.isEmpty)
    }

    /// Section 94 again, from the other side: a transformation is not a
    /// conversation, so nothing about it is persisted.
    func testATransformationPersistsNothing() async throws {
        let harness = Harness(providerText: "Rewritten.")

        _ = try await harness.engine.transformText(
            instruction: "Rewrite this:",
            text: "a private message to a colleague"
        )

        let conversations = try await harness.repositories.conversations.allConversations()
        XCTAssertTrue(
            conversations.isEmpty,
            "a keyboard rewrite appeared in the user's conversation history"
        )
        let memories = try await harness.repositories.memories.all()
        XCTAssertTrue(memories.isEmpty, "a keyboard rewrite became a memory")
    }

    /// Section 25's other half. Ask Assistant *is* the full pipeline — it goes
    /// through `AssistantCommandService.ask`, so a question that leads to a
    /// tool enters validation and authorization like any other.
    func testAskAssistantGoesThroughTheNormalPipeline() async throws {
        let harness = Harness(providerText: "Added it.")
        try harness.store.write(
            KeyboardExchange(
                generatedAt: now,
                request: KeyboardAssistantRequest(
                    operation: .assistantQuery,
                    inputText: "what is on today?",
                    createdAt: now
                )
            )
        )

        let result = await harness.service(at: now).servicePendingRequest()
        XCTAssertEqual(result?.status, .completed)

        // The conversation exists, because this one is a real assistant turn
        // the user chose to have — which is exactly the exception section 94
        // carves out.
        let conversations = try await harness.repositories.conversations.allConversations()
        XCTAssertFalse(conversations.isEmpty)
    }

    // MARK: Harness

    private struct Harness {
        let repositories = AssistantRepositories.ephemeral()
        let services = PlatformServices.mock()
        let store: InMemorySystemSurfaceStore
        let engine: AssistantEngine
        let commands: AssistantCommandService

        init(
            provider: StubAIProvider,
            storeAvailable: Bool = true
        ) {
            let clock = FixedDateProvider(now: Date(timeIntervalSince1970: 1_760_000_000))
            self.store = InMemorySystemSurfaceStore(isAvailable: storeAvailable)
            let engine = AssistantEngine(
                providers: AIProviderRegistry(providers: [provider]),
                repositories: repositories,
                services: services,
                dateProvider: clock
            )
            self.engine = engine
            self.commands = AssistantCommandService(
                engine: engine,
                repositories: repositories,
                memory: MemoryService(
                    repository: repositories.memories,
                    relations: repositories.memoryRelations,
                    embeddings: repositories.memoryEmbeddings,
                    dateProvider: clock
                ),
                dateProvider: clock
            )
        }

        init(
            providerID: AIProviderIdentifier = "test.stub",
            providerText: String,
            storeAvailable: Bool = true
        ) {
            self.init(
                provider: StubAIProvider(id: providerID, text: providerText),
                storeAvailable: storeAvailable
            )
        }

        func service(at date: Date) -> KeyboardAssistantService {
            KeyboardAssistantService(
                engine: engine,
                commands: commands,
                store: store,
                dateProvider: FixedDateProvider(now: date)
            )
        }
    }
}
