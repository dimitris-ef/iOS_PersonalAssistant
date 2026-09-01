import AssistantAI
import AssistantDomain
import AssistantPersistence
import NativeModelKit
import XCTest

@testable import AIProviderLocal

/// The temporary action backend: the model the user already downloaded, asked
/// a much narrower question.
///
/// ## What this is checking
///
/// Section 10 and 11. Part 1 ships no new model, so the backend is an adapter
/// over the existing semantic pipeline. What has to be true of it is not that
/// it is clever — it is the same inference either way — but that it satisfies
/// `ActionModelProvider` honestly: a semantic action out, availability
/// reported truthfully, and a *narrow* prompt in.
final class LocalActionBackendTests: XCTestCase {

    private static let now = Date(timeIntervalSince1970: 1_788_175_200)
    private static let athens = TimeZone(identifier: "Europe/Athens")!

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

    private func descriptor() -> LocalModelDescriptor {
        LocalModelDescriptor(
            id: "model-a",
            displayName: "Test Model",
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

    private func makeBackend(
        runtime: MockLocalModelRuntime,
        installed: Bool = true
    ) async throws -> CurrentLocalSemanticActionBackend {
        let model = descriptor()
        let repositories = AssistantRepositories.ephemeral()
        if installed {
            try store.prepareDirectory()
            try GGUFFixture.header().write(
                to: store.url(forRelativePath: model.suggestedFileName)
            )
            try await repositories.localModels.save(
                LocalModelRecord(
                    id: model.id,
                    relativePath: model.suggestedFileName,
                    fileSizeBytes: 1_100_000_000,
                    installedAt: Self.now,
                    architecture: "qwen3",
                    contextLength: 4096
                )
            )
            try await repositories.settings.update(
                AssistantSettings(selectedLocalModelID: model.id)
            )
        }
        let manager = LocalModelManager(
            catalog: LocalModelCatalog(models: [model]),
            repository: repositories.localModels,
            settings: repositories.settings,
            store: store,
            runtime: runtime,
            device: FixedDeviceResources.largePhone,
            dateProvider: FixedDateProvider(now: Self.now)
        )
        return CurrentLocalSemanticActionBackend(
            provider: LocalModelProvider(
                manager: manager,
                runtime: runtime,
                dateProvider: FixedDateProvider(now: Self.now, timeZone: Self.athens)
            )
        )
    }

    private func request(
        _ text: String, category: LocalActionCategory = .reminder
    ) -> ActionModelRequest {
        ActionModelRequest(
            userRequest: text,
            now: Self.now,
            timeZoneIdentifier: Self.athens.identifier,
            detectedCategory: category
        )
    }

    private static let reminderEnvelope = """
        {"intent":"reminder.create","arguments":\
        {"title":"change the bottles","timeExpression":"in 10 minutes"}}
        """

    // MARK: The contract

    func testItProducesTheExistingSemanticAction() async throws {
        let runtime = MockLocalModelRuntime()
        await runtime.alwaysRespond(.raw(Self.reminderEnvelope))
        let backend = try await makeBackend(runtime: runtime)

        let produced = try await backend.generateSemanticAction(
            request: request("Remind me in 10 minutes to change bottles.")
        )

        guard case .action(let action) = produced else {
            return XCTFail("expected a semantic action")
        }
        XCTAssertEqual(action.intent, .reminderCreate)
        XCTAssertEqual(action[.title], "change the bottles")
        XCTAssertEqual(action[.timeExpression], "in 10 minutes")
    }

    /// Section 8 and 21, on the prompt the runtime actually received: the
    /// sentence and the protocol, and none of a chat turn's context.
    func testTheActionPromptIsNarrow() async throws {
        let runtime = MockLocalModelRuntime()
        await runtime.alwaysRespond(.raw(Self.reminderEnvelope))
        let backend = try await makeBackend(runtime: runtime)

        _ = try await backend.generateSemanticAction(
            request: request("Remind me in 10 minutes to change bottles.")
        )

        let lastPrompt = await runtime.lastPrompt
        let prompt = try XCTUnwrap(lastPrompt)
        let text = prompt.turns.map(\.content).joined(separator: "\n").lowercased()

        XCTAssertTrue(text.contains("reminder.create"))
        XCTAssertTrue(text.contains("remind me in 10 minutes to change bottles."))
        // Not the internal schema, and not a date for the model to copy.
        for forbidden in ["createreminder", "relatedtaskid", "listname", "duedate", "2026"] {
            XCTAssertFalse(text.contains(forbidden), "the action prompt showed \(forbidden)")
        }
        // Two turns: the instructions and the request. No history.
        XCTAssertEqual(prompt.turns.count, 2)
    }

    /// The one repair is spent here too, and only once (section 17's
    /// preservation of the existing policy).
    func testOneRepairAndNoMore() async throws {
        let runtime = MockLocalModelRuntime()
        await runtime.alwaysRespond(.raw("I would use the reminder.create intent for that."))
        let backend = try await makeBackend(runtime: runtime)

        do {
            _ = try await backend.generateSemanticAction(
                request: request("Remind me in 10 minutes.")
            )
            XCTFail("expected a structured failure")
        } catch let error as ActionModelError {
            XCTAssertEqual(error.symbol, "semanticParsingFailed")
        }

        let generations = await runtime.generateCount
        XCTAssertEqual(generations, 2, "one generation and exactly one repair")
    }

    func testARepairCanRecoverTheAction() async throws {
        let runtime = MockLocalModelRuntime()
        await runtime.enqueue(
            .raw("I'd use the reminder.create intent with a timeExpression argument."),
            .raw(Self.reminderEnvelope)
        )
        let backend = try await makeBackend(runtime: runtime)

        let produced = try await backend.generateSemanticAction(
            request: request("Remind me in 10 minutes.")
        )
        guard case .action = produced else { return XCTFail("expected a recovered action") }
    }

    /// A fabricated field is refused here as it is everywhere else — the
    /// backend runs the same validator (section 17).
    func testAFabricatedFieldIsRefusedByTheBackend() async throws {
        let runtime = MockLocalModelRuntime()
        await runtime.alwaysRespond(
            .raw(
                """
                {"intent":"reminder.create","arguments":{"title":"Bottles",\
                "timeExpression":"in 10 minutes","relatedTaskID":\
                "550e8400-e29b-41d4-a716-446655440000"}}
                """
            )
        )
        let backend = try await makeBackend(runtime: runtime)

        do {
            _ = try await backend.generateSemanticAction(
                request: request("Remind me in 10 minutes.")
            )
            XCTFail("a fabricated identifier was accepted")
        } catch let error as ActionModelError {
            XCTAssertEqual(error.symbol, "semanticValidationFailed")
        }
    }

    /// Ordinary prose with nothing to do is "no action needed", not a failure.
    func testProseBecomesNoActionNeededRatherThanAnError() async throws {
        let runtime = MockLocalModelRuntime()
        await runtime.alwaysRespond(
            .raw(#"{"intent":"chat","message":"Nothing to do there."}"#)
        )
        let backend = try await makeBackend(runtime: runtime)

        let produced = try await backend.generateSemanticAction(
            request: request("Remind me in 10 minutes.")
        )
        guard case .noActionNeeded(let message) = produced else {
            return XCTFail("expected no action needed")
        }
        XCTAssertEqual(message, "Nothing to do there.")
    }

    // MARK: Availability

    func testAvailabilityFollowsTheUnderlyingModel() async throws {
        let ready = try await makeBackend(runtime: MockLocalModelRuntime())
        XCTAssertTrue(await ready.availability().isAvailable)

        let empty = try await makeBackend(runtime: MockLocalModelRuntime(), installed: false)
        let availability = await empty.availability()
        XCTAssertFalse(availability.isAvailable)
        XCTAssertNotNil(availability.reason)
    }

    /// Section 7: the identifier names the temporary backend, so a diagnostic
    /// line from this build cannot be mistaken for one from the real Metis
    /// Action Model.
    func testTheBackendIsNamedForWhatItActuallyIs() async throws {
        let backend = try await makeBackend(runtime: MockLocalModelRuntime())
        XCTAssertEqual(backend.id, "metis.action.local-semantic")
    }
}
