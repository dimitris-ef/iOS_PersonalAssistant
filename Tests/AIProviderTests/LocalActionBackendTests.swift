import AssistantAI
import AssistantDomain
import AssistantPersistence
import NativeModelKit
import XCTest

@testable import AIProviderLocal

/// The temporary action backend, now generating under a grammar.
///
/// ## What changed in Part 2, and why these expectations moved with it
///
/// Part 1's backend asked a small model for JSON and then checked what came
/// back. Several tests here asserted the *check*: prose arrived, the parser
/// refused it, a repair ran, a structured failure came out.
///
/// Under a grammar those inputs are no longer reachable. A constrained sampler
/// cannot emit prose, and cannot emit `relatedTaskID`, because neither is a
/// path through the grammar — so `MockLocalModelRuntime` enforces the same
/// grammar llama.cpp would and returns nothing when a scripted response is
/// outside it. The tests below therefore assert the stronger property: not
/// "the app rejected it" but "the model could not say it".
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

    private func generate(
        _ backend: CurrentLocalSemanticActionBackend,
        _ text: String,
        category: LocalActionCategory = .reminder
    ) async throws -> LocalSemanticActionResult {
        try await backend.generateSemanticAction(
            request: request(text, category: category), constraints: .universal
        )
    }

    private static let reminderEnvelope = """
        {"intent":"reminder.create","arguments":\
        {"title":"change bottles","timeExpression":"in 10 minutes"}}
        """

    // MARK: The contract — sections 28 to 33

    func testItProducesTheExistingSemanticAction() async throws {
        let runtime = MockLocalModelRuntime()
        await runtime.alwaysRespond(.raw(Self.reminderEnvelope))
        let backend = try await makeBackend(runtime: runtime)

        let produced = try await generate(backend, "Remind me in 10 minutes to change bottles.")

        guard case .action(let action) = produced else {
            return XCTFail("expected a semantic action")
        }
        XCTAssertEqual(action.intent, .reminderCreate)
        XCTAssertEqual(action[.title], "change bottles")
        XCTAssertEqual(action[.timeExpression], "in 10 minutes")
    }

    func testMemoryTaskAndCalendarActionsAllPassTheConstraint() async throws {
        let cases: [(String, String, LocalActionCategory, LocalSemanticIntent)] = [
            (
                #"{"intent":"memory.store","arguments":{"content":"John's birthday is May 3"}}"#,
                "Remember that John's birthday is May 3.", .memory, .memoryStore
            ),
            (
                #"{"intent":"task.create","arguments":{"title":"buy milk"}}"#,
                "Create a task to buy milk.", .task, .taskCreate
            ),
            (
                #"{"intent":"task.complete","arguments":{"targetDescription":"buy milk"}}"#,
                "Mark buy milk as done.", .task, .taskComplete
            ),
            (
                """
                {"intent":"calendar.create","arguments":\
                {"title":"dentist appointment","timeExpression":"tomorrow at 3"}}
                """,
                "Create a dentist appointment tomorrow at 3.", .calendar, .calendarCreate
            ),
            (
                """
                {"intent":"calendar.update","arguments":\
                {"targetDescription":"my dentist appointment"},\
                "requestedChanges":{"timeExpression":"5"}}
                """,
                "Move my dentist appointment to 5.", .calendar, .calendarUpdate
            ),
        ]

        for (envelope, sentence, category, intent) in cases {
            let runtime = MockLocalModelRuntime()
            await runtime.alwaysRespond(.raw(envelope))
            let backend = try await makeBackend(runtime: runtime)

            let produced = try await generate(backend, sentence, category: category)
            guard case .action(let action) = produced else {
                XCTFail("\(intent.rawValue) did not survive the constraint")
                continue
            }
            XCTAssertEqual(action.intent, intent)
            let rejections = await runtime.constrainedRejections
            XCTAssertEqual(rejections, 0, "\(intent.rawValue) was refused by the grammar")
        }
    }

    /// Section 33: a human-readable target, and no EventKit identifier — there
    /// is no production in the grammar that could carry one.
    func testACalendarUpdateCarriesOnlyAHumanTarget() async throws {
        let runtime = MockLocalModelRuntime()
        await runtime.alwaysRespond(
            .raw(
                """
                {"intent":"calendar.update","arguments":\
                {"targetDescription":"my dentist appointment"},\
                "requestedChanges":{"timeExpression":"5"}}
                """
            )
        )
        let backend = try await makeBackend(runtime: runtime)

        let produced = try await generate(
            backend, "Move my dentist appointment to 5.", category: .calendar
        )
        guard case .action(let action) = produced else { return XCTFail("expected an action") }
        XCTAssertEqual(action[.targetDescription], "my dentist appointment")
        XCTAssertEqual(action.requestedChanges[.timeExpression], "5")
        XCTAssertNil(action[.title])
    }

    // MARK: What the grammar makes unsayable — sections 34 to 38

    /// Section 34. Not "the parser refused the prose" — the model could not
    /// produce it, so nothing came back at all.
    func testProseCannotEscapeTheGrammar() async throws {
        let runtime = MockLocalModelRuntime()
        await runtime.alwaysRespond(.raw("Sure, I'll create the reminder for you..."))
        let backend = try await makeBackend(runtime: runtime)

        await assertFails(backend, "Remind me in 10 minutes.")
        let rejections = await runtime.constrainedRejections
        XCTAssertEqual(rejections, 2, "the grammar refused both the attempt and the repair")
    }

    /// Section 35.
    func testSchemaProseCannotEscapeTheGrammar() async throws {
        let runtime = MockLocalModelRuntime()
        await runtime.alwaysRespond(
            .raw("The reminder.create schema requires a title and a timeExpression.")
        )
        let backend = try await makeBackend(runtime: runtime)

        await assertFails(backend, "Remind me in 10 minutes.")
    }

    /// Section 36. Structurally valid JSON, one field too many.
    func testAnUnsupportedFieldCannotBeEmitted() async throws {
        let runtime = MockLocalModelRuntime()
        await runtime.alwaysRespond(
            .raw(
                """
                {"intent":"reminder.create","arguments":{"title":"change bottles",\
                "timeExpression":"in 10 minutes","relatedTaskID":"123"}}
                """
            )
        )
        let backend = try await makeBackend(runtime: runtime)

        await assertFails(backend, "Remind me in 10 minutes.")
    }

    /// Section 37.
    func testIdentifierFieldsCannotBeEmitted() async throws {
        for key in ["eventID", "taskID", "reminderID", "listID"] {
            let runtime = MockLocalModelRuntime()
            await runtime.alwaysRespond(
                .raw(
                    """
                    {"intent":"reminder.create","arguments":{"title":"x",\
                    "timeExpression":"in 10 minutes","\(key)":"550e8400"}}
                    """
                )
            )
            let backend = try await makeBackend(runtime: runtime)
            await assertFails(backend, "Remind me in 10 minutes.")
        }
    }

    /// Section 38.
    func testAnArbitraryListNameCannotBeEmitted() async throws {
        let runtime = MockLocalModelRuntime()
        await runtime.alwaysRespond(
            .raw(
                """
                {"intent":"reminder.create","arguments":{"title":"x",\
                "timeExpression":"in 10 minutes","listName":"To-Do List"}}
                """
            )
        )
        let backend = try await makeBackend(runtime: runtime)

        await assertFails(backend, "Remind me in 10 minutes.")
    }

    /// Section 24. `chat` is still in the protocol, and is not a path the
    /// *constrained action* grammar offers — the router already decided this
    /// message was an action, so declining is not one of the answers on offer.
    func testChatIsNotAnOptionUnderTheActionConstraint() async throws {
        let runtime = MockLocalModelRuntime()
        await runtime.alwaysRespond(
            .raw(#"{"intent":"chat","message":"Nothing to do there."}"#)
        )
        let backend = try await makeBackend(runtime: runtime)

        await assertFails(backend, "Remind me in 10 minutes.")
    }

    // MARK: Repair — sections 14, 15, 39, 41 and 42

    /// Section 39 and 42: one repair, then nothing runs.
    func testOneRepairAndNoMore() async throws {
        let runtime = MockLocalModelRuntime()
        await runtime.alwaysRespond(.raw("I would use the reminder.create intent for that."))
        let backend = try await makeBackend(runtime: runtime)

        await assertFails(backend, "Remind me in 10 minutes.")
        let generations = await runtime.generateCount
        XCTAssertEqual(generations, 2, "one generation and exactly one repair")
    }

    /// Section 41.
    func testARepairCanRecoverTheAction() async throws {
        let runtime = MockLocalModelRuntime()
        await runtime.enqueue(
            .raw("I'd use the reminder.create intent with a timeExpression argument."),
            .raw(Self.reminderEnvelope)
        )
        let backend = try await makeBackend(runtime: runtime)

        let produced = try await generate(backend, "Remind me in 10 minutes.")
        guard case .action = produced else { return XCTFail("expected a recovered action") }
    }

    /// Section 15: the repair is constrained to the routed family, so the
    /// second attempt cannot repeat a wrong-family answer even if the model
    /// would like to.
    func testTheRepairIsNarrowedToTheRoutedFamily() async throws {
        let runtime = MockLocalModelRuntime()
        await runtime.enqueue(
            // Structurally valid, semantically the wrong family — and rejected
            // by the validator, which is what triggers the repair.
            .raw(#"{"intent":"memory.store","arguments":{"content":"change bottles"}}"#),
            // The model tries the same thing again. The narrowed grammar has no
            // `memory.store` production, so it cannot.
            .raw(#"{"intent":"memory.store","arguments":{"content":"change bottles"}}"#)
        )
        let backend = try await makeBackend(runtime: runtime)

        await assertFails(backend, "Remind me in 10 minutes.")

        // The first response was grammatical; only the repair was refused by
        // the narrowed grammar. That difference is the point of section 15.
        let rejections = await runtime.constrainedRejections
        XCTAssertEqual(rejections, 1)
        let generations = await runtime.generateCount
        XCTAssertEqual(generations, 2)
    }

    /// Section 40, and mandatory: structure is not meaning. The grammar accepts
    /// `memory.store` for a reminder request, and the semantic validator throws
    /// it out before anything runs.
    func testStructurallyValidButSemanticallyWrongIsStillRefused() async throws {
        // It passes the grammar — which is exactly why the semantic layer is
        // still needed after constrained generation (section 12).
        let compiled = try GBNFGrammar.validate(
            SemanticActionGrammar.gbnf(for: .universal), root: SemanticActionGrammar.rootRule
        )
        XCTAssertTrue(
            compiled.matches(
                #"{"intent":"memory.store","arguments":{"content":"change bottles"}}"#
            )
        )

        let runtime = MockLocalModelRuntime()
        await runtime.alwaysRespond(
            .raw(#"{"intent":"memory.store","arguments":{"content":"change bottles"}}"#)
        )
        let backend = try await makeBackend(runtime: runtime)

        await assertFails(backend, "Remind me in 10 minutes.")
    }

    // MARK: The prompt and the constraint together

    /// Sections 10 and 11: a small semantic instruction, and no tool schemas.
    func testTheActionPromptIsNarrowAndTheGrammarIsAttached() async throws {
        let runtime = MockLocalModelRuntime()
        await runtime.alwaysRespond(.raw(Self.reminderEnvelope))
        let backend = try await makeBackend(runtime: runtime)

        _ = try await generate(backend, "Remind me in 10 minutes to change bottles.")

        let lastPrompt = await runtime.lastPrompt
        let prompt = try XCTUnwrap(lastPrompt)
        let text = prompt.turns.map(\.content).joined(separator: "\n").lowercased()

        XCTAssertTrue(text.contains("reminder.create"))
        XCTAssertTrue(text.contains("remind me in 10 minutes to change bottles."))
        for forbidden in ["createreminder", "relatedtaskid", "listname", "duedate", "2026"] {
            XCTAssertFalse(text.contains(forbidden), "the action prompt showed \(forbidden)")
        }
        XCTAssertEqual(prompt.turns.count, 2)

        // Section 22 and 1: the grammar is on this generation, and the sampling
        // is the deterministic extraction profile.
        let lastOptions = await runtime.lastOptions
        let options = try XCTUnwrap(lastOptions)
        XCTAssertNotNil(options.grammar)
        XCTAssertEqual(options.temperature, 0)
    }

    // MARK: Availability

    func testAvailabilityFollowsTheUnderlyingModel() async throws {
        let ready = try await makeBackend(runtime: MockLocalModelRuntime())
        let readyAvailability = await ready.availability()
        XCTAssertTrue(readyAvailability.isAvailable)

        let empty = try await makeBackend(runtime: MockLocalModelRuntime(), installed: false)
        let availability = await empty.availability()
        XCTAssertFalse(availability.isAvailable)
        XCTAssertNotNil(availability.reason)
    }

    func testTheBackendIsNamedForWhatItActuallyIs() async throws {
        let backend = try await makeBackend(runtime: MockLocalModelRuntime())
        XCTAssertEqual(backend.id, "metis.action.local-semantic")
    }

    // MARK: Helper

    /// Asserts the backend produced no action, whatever the reason.
    ///
    /// Deliberately does not pin the failure *category*: whether a refusal
    /// arrives as a parse failure or a validation failure is an implementation
    /// detail of where the constraint bit, and the property that matters to the
    /// user is the same either way — nothing ran.
    private func assertFails(
        _ backend: CurrentLocalSemanticActionBackend,
        _ text: String,
        category: LocalActionCategory = .reminder,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            let produced = try await generate(backend, text, category: category)
            XCTFail("expected no action, got \(produced)", file: file, line: line)
        } catch is ActionModelError {
            // The expected shape: a structured failure, and nothing executed.
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }
}
