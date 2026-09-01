import AssistantAI
import AssistantDomain
import AssistantPersistence
import NativeModelKit
import XCTest

@testable import AIProviderLocal

/// The semantic protocol running inside the provider, asserted from the
/// outside — what the user would actually see.
///
/// ## The device failure
///
/// > Remind me in 10 minutes to change bottles
///
/// came back, on TestFlight build 14.1, as tool-shaped output carrying a
/// fabricated `relatedTaskID`, a due date from 2023, an invented title, an
/// invented list name, invented notes and a made-up explanation that the data
/// was corrupted — with the raw internal content visible on screen.
///
/// The first test below is that request, answered correctly. The second is the
/// same request answered exactly as the device answered it, and what the user
/// sees instead.
final class LocalSemanticProviderTests: XCTestCase {

    /// 31 August 2026, 14:20, Europe/Athens.
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

    // MARK: Fixtures

    private struct StubResources: LocalSemanticResourceResolving {
        var taskMatch: LocalResourceMatch = .none
        var eventMatch: LocalResourceMatch = .none

        func resolveTask(matching description: String) async -> LocalResourceMatch { taskMatch }
        func resolveCalendarEvent(
            matching description: String
        ) async -> LocalResourceMatch { eventMatch }
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

    private func makeProvider(
        runtime: MockLocalModelRuntime,
        resources: LocalSemanticResourceResolving? = nil
    ) async throws -> LocalModelProvider {
        let model = descriptor()
        let repositories = AssistantRepositories.ephemeral()
        try store.prepareDirectory()
        try GGUFFixture.header().write(to: store.url(forRelativePath: model.suggestedFileName))
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
        try await repositories.settings.update(AssistantSettings(selectedLocalModelID: model.id))
        let manager = LocalModelManager(
            catalog: LocalModelCatalog(models: [model]),
            repository: repositories.localModels,
            settings: repositories.settings,
            store: store,
            runtime: runtime,
            device: FixedDeviceResources.largePhone,
            dateProvider: FixedDateProvider(now: Self.now)
        )
        return LocalModelProvider(
            manager: manager,
            runtime: runtime,
            dateProvider: FixedDateProvider(now: Self.now, timeZone: Self.athens),
            resources: resources
        )
    }

    /// The app's real tool schemas. Present so the provider offers actions at
    /// all — and, under the semantic protocol, never shown to the model.
    private var tools: [AIToolSchema] {
        [
            AIToolSchema(
                name: "createReminder",
                description: "Create a NEW reminder.",
                parameters: .object(
                    properties: [
                        "title": .string(),
                        "dueDate": .string(format: .dateTime),
                        "listName": .string(),
                        "relatedTaskID": .string(format: .uuid),
                    ],
                    required: ["title"]
                )
            ),
            AIToolSchema(
                name: "storeMemory",
                description: "Store a lasting fact about the user.",
                parameters: .object(
                    properties: ["content": .string()], required: ["content"]
                )
            ),
            AIToolSchema(
                name: "updateCalendarEvent",
                description: "Modify an EXISTING calendar event.",
                parameters: .object(
                    properties: ["eventID": .string(format: .uuid)], required: ["eventID"]
                )
            ),
        ]
    }

    private func request(_ text: String, priorResults: [AIMessage] = []) -> AIRequest {
        AIRequest(
            systemPrompt: "You are a personal assistant.",
            messages: priorResults + [AIMessage(role: .user, content: text)],
            tools: tools
        )
    }

    private func date(from iso: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)
    }

    private static let reminderEnvelope = """
        {"intent":"reminder.create","arguments":\
        {"title":"change the bottles","timeExpression":"in 10 minutes"}}
        """

    // MARK: The request that failed on the device

    /// Section 66 and 67, through the whole provider: the model says the words,
    /// the app produces the call and the date.
    func testTheChangeBottlesReminderBecomesARealCallWithARealTime() async throws {
        let runtime = MockLocalModelRuntime()
        await runtime.alwaysRespond(.raw(Self.reminderEnvelope))
        let provider = try await makeProvider(runtime: runtime)

        let response = try await provider.respond(
            to: request("Remind me in 10 minutes to change bottles")
        )

        XCTAssertEqual(response.toolCalls.count, 1)
        let call = try XCTUnwrap(response.toolCalls.first)
        XCTAssertEqual(call.name, "createReminder")
        XCTAssertEqual(call.arguments["title"]?.stringValue, "change the bottles")
        XCTAssertEqual(
            date(from: call.arguments["dueDate"]?.stringValue ?? ""),
            Date(timeIntervalSince1970: 1_788_175_800),
            "the reminder must be due at 14:30 Athens, ten minutes after the injected clock"
        )
        XCTAssertEqual(response.stopReason, .toolCalls)
    }

    /// Section 7 and 13, on the wire: none of the values the device invented
    /// exists in the call the app produced.
    func testTheProducedCallCarriesNoInventedValues() async throws {
        let runtime = MockLocalModelRuntime()
        await runtime.alwaysRespond(.raw(Self.reminderEnvelope))
        let provider = try await makeProvider(runtime: runtime)

        let response = try await provider.respond(
            to: request("Remind me in 10 minutes to change bottles")
        )
        let arguments = try XCTUnwrap(response.toolCalls.first?.arguments.objectValue)

        XCTAssertEqual(Set(arguments.keys), ["title", "dueDate"])
        for invented in ["relatedTaskID", "listName", "notes", "priority"] {
            XCTAssertNil(arguments[invented], "the app invented \(invented)")
        }
    }

    /// The device's own answer, replayed. Every fabricated field is in it, and
    /// none of it reaches the user.
    func testTheDeviceFailureIsContained() async throws {
        let deviceOutput = """
            {"intent":"reminder.create","arguments":{"title":"Follow up on the report",\
            "dueDate":"2023-11-14T09:00:00","listName":"Work","notes":"Recovered from a \
            corrupted record","relatedTaskID":"550e8400-e29b-41d4-a716-446655440000"}}
            """
        let runtime = MockLocalModelRuntime()
        await runtime.alwaysRespond(.raw(deviceOutput))
        let provider = try await makeProvider(runtime: runtime)

        let response = try await provider.respond(
            to: request("Remind me in 10 minutes to change bottles")
        )

        XCTAssertTrue(response.toolCalls.isEmpty, "a fabricated action reached execution")
        XCTAssertEqual(response.text, LocalModelProvider.actionFailureMessage)
        for fragment in [
            "relatedTaskID", "550e8400", "2023", "listName", "Work",
            "corrupted", "Follow up on the report", "intent",
        ] {
            XCTAssertFalse(
                response.text.lowercased().contains(fragment.lowercased()),
                "the reply leaked \(fragment)"
            )
        }
    }

    /// Section 47 and 49. Prose claiming the action happened is not shown,
    /// because it did not happen.
    func testProseClaimingSuccessIsNeverShown() async throws {
        let runtime = MockLocalModelRuntime()
        await runtime.alwaysRespond(
            .raw("Done — I've set a reminder for you in 10 minutes to change the bottles.")
        )
        let provider = try await makeProvider(runtime: runtime)

        let response = try await provider.respond(
            to: request("Remind me in 10 minutes to change bottles")
        )

        XCTAssertTrue(response.toolCalls.isEmpty)
        XCTAssertEqual(response.text, LocalModelProvider.actionFailureMessage)
    }

    /// Section 32. A model that falls back to the app's internal tool envelope
    /// is contained rather than obeyed.
    func testALegacyToolEnvelopeIsNotExecutedUnderTheSemanticProtocol() async throws {
        let runtime = MockLocalModelRuntime()
        await runtime.alwaysRespond(
            .toolCalls(
                names: ["updateCalendarEvent"],
                arguments: [["eventID": .string("550e8400-e29b-41d4-a716-446655440000")]],
                message: "Updating."
            )
        )
        let provider = try await makeProvider(runtime: runtime)

        let response = try await provider.respond(
            to: request("Remind me in 10 minutes to change bottles")
        )

        XCTAssertTrue(response.toolCalls.isEmpty)
        XCTAssertEqual(response.text, LocalModelProvider.actionFailureMessage)
    }

    // MARK: Memory, tasks and questions

    func testRememberingAFactStillWorks() async throws {
        let runtime = MockLocalModelRuntime()
        await runtime.alwaysRespond(
            .raw(#"{"intent":"memory.store","arguments":{"content":"John's birthday is May 3"}}"#)
        )
        let provider = try await makeProvider(runtime: runtime)

        let response = try await provider.respond(
            to: request("Remember that John's birthday is May 3")
        )

        XCTAssertEqual(response.toolCalls.first?.name, "storeMemory")
        XCTAssertEqual(
            response.toolCalls.first?.arguments["content"]?.stringValue,
            "John's birthday is May 3"
        )
    }

    /// Section 26 through the provider: the wrong kind of action never runs.
    func testAReminderRequestAnsweredWithAMemoryIsRefused() async throws {
        let runtime = MockLocalModelRuntime()
        await runtime.alwaysRespond(
            .raw(#"{"intent":"memory.store","arguments":{"content":"Change bottles"}}"#)
        )
        let provider = try await makeProvider(runtime: runtime)

        let response = try await provider.respond(
            to: request("Remind me in 10 minutes to change bottles")
        )

        XCTAssertTrue(
            response.toolCalls.isEmpty, "a reminder request must never execute storeMemory"
        )
    }

    /// Sections 16 to 20 end to end: the identifier the app looked up is the
    /// one that reaches the call.
    func testCompletingATaskUsesTheAppsOwnIdentifier() async throws {
        let real = UUID().uuidString
        let runtime = MockLocalModelRuntime()
        await runtime.alwaysRespond(
            .raw(#"{"intent":"task.complete","arguments":{"targetDescription":"the shopping"}}"#)
        )
        let provider = try await makeProvider(
            runtime: runtime,
            resources: StubResources(
                taskMatch: .one(LocalResourceCandidate(identifier: real, label: "Shopping"))
            )
        )

        let response = try await provider.respond(to: request("Mark the shopping as done"))

        XCTAssertEqual(response.toolCalls.first?.name, "completeTask")
        XCTAssertEqual(response.toolCalls.first?.arguments["taskID"]?.stringValue, real)
    }

    /// A question, not an action. The clarification is shown as itself.
    func testAnUnresolvableTargetAsksInsteadOfActing() async throws {
        let runtime = MockLocalModelRuntime()
        await runtime.alwaysRespond(
            .raw(#"{"intent":"task.complete","arguments":{"targetDescription":"the thing"}}"#)
        )
        let provider = try await makeProvider(
            runtime: runtime, resources: StubResources(taskMatch: .none)
        )

        let response = try await provider.respond(to: request("Mark the thing as done"))

        XCTAssertTrue(response.toolCalls.isEmpty)
        XCTAssertNotEqual(response.text, LocalModelProvider.actionFailureMessage)
        XCTAssertTrue(response.text.contains("couldn't find"))
    }

    // MARK: Chat is untouched

    func testAnOrdinaryQuestionIsAnsweredNormally() async throws {
        let answer = "Reminders arrive as a notification at the time you choose."
        let runtime = MockLocalModelRuntime()
        await runtime.alwaysRespond(.raw(answer))
        let provider = try await makeProvider(runtime: runtime)

        let response = try await provider.respond(to: request("How do reminders work?"))

        XCTAssertEqual(response.text, answer)
        XCTAssertTrue(response.toolCalls.isEmpty)
    }

    /// A continuation round — the engine handing back a tool result and asking
    /// for a summary — is prose by design, and must not be treated as a failed
    /// action.
    func testAContinuationRoundIsAllowedToBeProse() async throws {
        let summary = "Done — that's set for 14:30."
        let runtime = MockLocalModelRuntime()
        await runtime.alwaysRespond(.raw(summary))
        let provider = try await makeProvider(runtime: runtime)

        let callID = ToolCallID()
        let result = AIMessage(
            role: .tool,
            content: "created",
            toolCallID: callID,
            toolResult: AIToolResult(
                callID: callID,
                toolName: "createReminder",
                status: .succeeded,
                payload: ["reminderID": UUID().uuidString],
                message: "created"
            )
        )
        let response = try await provider.respond(
            to: AIRequest(
                systemPrompt: "You are a personal assistant.",
                messages: [
                    AIMessage(role: .user, content: "Remind me in 10 minutes to change bottles"),
                    result,
                ],
                tools: tools
            )
        )

        XCTAssertEqual(response.text, summary)
    }

    // MARK: Repair

    /// Section 33. One retry, and it is allowed to succeed.
    func testOneRepairCanRecoverTheAction() async throws {
        let runtime = MockLocalModelRuntime()
        await runtime.enqueue(
            .raw("I'd use the reminder.create intent with a timeExpression argument."),
            .raw(Self.reminderEnvelope)
        )
        let provider = try await makeProvider(runtime: runtime)

        let response = try await provider.respond(
            to: request("Remind me in 10 minutes to change bottles")
        )

        XCTAssertEqual(response.toolCalls.first?.name, "createReminder")
        let generations = await runtime.generateCount
        XCTAssertEqual(generations, 2)
    }

    /// Section 34 and 39. Exactly one — the semantic repair and the older tool
    /// repair share one budget and cannot add up to two.
    func testASecondFailureEndsTheTurnRatherThanRetryingAgain() async throws {
        let runtime = MockLocalModelRuntime()
        await runtime.alwaysRespond(.raw("I would use the reminder.create intent for that."))
        let provider = try await makeProvider(runtime: runtime)

        let response = try await provider.respond(
            to: request("Remind me in 10 minutes to change bottles")
        )

        XCTAssertTrue(response.toolCalls.isEmpty)
        XCTAssertEqual(response.text, LocalModelProvider.actionFailureMessage)
        let generations = await runtime.generateCount
        XCTAssertEqual(generations, 2, "the turn must generate once and repair once")
    }

    // MARK: Chat is never constrained — Part 2, sections 1 and 43

    /// The whole point of scoping constrained decoding to the action path: a
    /// grammar on a conversation would make the assistant unable to answer a
    /// question. Asserted on the options the runtime actually received.
    func testChatGenerationCarriesNoGrammar() async throws {
        let answer = "Reminders arrive as a notification at the time you choose."
        let runtime = MockLocalModelRuntime()
        await runtime.alwaysRespond(.raw(answer))
        let provider = try await makeProvider(runtime: runtime)

        let response = try await provider.respond(to: request("How do reminders work?"))

        XCTAssertEqual(response.text, answer)
        let options = await runtime.lastOptions
        XCTAssertNil(options?.grammar, "a chat turn must never be given a grammar")
        let rejections = await runtime.constrainedRejections
        XCTAssertEqual(rejections, 0)
    }

    /// And the same for a chat turn that is *about* an action: the router is
    /// what decides the path, and this provider entry point is the chat one
    /// whatever the sentence says.
    func testEvenAnActionSoundingChatTurnIsUnconstrained() async throws {
        let runtime = MockLocalModelRuntime()
        await runtime.alwaysRespond(.raw(Self.reminderEnvelope))
        let provider = try await makeProvider(runtime: runtime)

        _ = try await provider.respond(
            to: request("Remind me in 10 minutes to change bottles")
        )

        let options = await runtime.lastOptions
        XCTAssertNil(options?.grammar)
    }

    // MARK: What the model is shown

    /// Sections 57 and 58. The prompt the runtime actually received carries the
    /// semantic protocol and none of the internal schema — which is the reason
    /// the model cannot fill in a field it has no business filling in.
    func testTheModelIsNeverShownTheInternalToolSchema() async throws {
        let runtime = MockLocalModelRuntime()
        await runtime.alwaysRespond(.raw(Self.reminderEnvelope))
        let provider = try await makeProvider(runtime: runtime)

        _ = try await provider.respond(
            to: request("Remind me in 10 minutes to change bottles")
        )

        // Read the actor's property first: `XCTUnwrap` takes an autoclosure,
        // which cannot carry an `await`.
        let lastPrompt = await runtime.lastPrompt
        let prompt = try XCTUnwrap(lastPrompt)
        let text = prompt.turns.map(\.content).joined(separator: "\n").lowercased()

        XCTAssertTrue(text.contains("reminder.create"))
        for forbidden in ["relatedtaskid", "listname", "duedate", "eventid", "createreminder"] {
            XCTAssertFalse(text.contains(forbidden), "the prompt showed the model \(forbidden)")
        }
    }
}
