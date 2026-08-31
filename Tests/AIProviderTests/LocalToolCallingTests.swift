import AssistantAI
import AssistantDomain
import AssistantPersistence
import NativeModelKit
import XCTest

@testable import AIProviderLocal

/// Local models asking the app to do things, and what happens when they get it
/// wrong.
///
/// ## The regression these exist for
///
/// On a real device somebody typed
///
/// > Remind me something in 10 minutes.
///
/// and got back prose about an `updateCalendarEvent` schema, an `eventID`
/// parameter, `type: object`, and a complaint about a malformed UUID. Three
/// separate things had to be true for that to reach the screen:
///
/// 1. schema prose carries no tool envelope, so the parser classified it as an
///    ordinary reply and passed it straight through;
/// 2. nothing distinguished "the user asked a question" from "the user asked
///    for something to be done", so there was no basis on which to object;
/// 3. nothing checked where an identifier for an existing thing came from, so a
///    plausible invented UUID was indistinguishable from a real one.
///
/// Each is covered below, and the containment is asserted from the outside —
/// what the user would actually see.
final class LocalToolCallingTests: XCTestCase {

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

    private func makeProvider(
        descriptor model: LocalModelDescriptor,
        runtime: MockLocalModelRuntime
    ) async throws -> LocalModelProvider {
        let repositories = AssistantRepositories.ephemeral()
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
        // These are the tool-envelope path's own regression tests, so they
        // ask for that path explicitly. The semantic protocol is the local
        // default and has its own suite; this one keeps the older parser,
        // provenance check and repair honest, because they are still what a
        // provider configured without the semantic protocol relies on.
        return LocalModelProvider(
            manager: manager, runtime: runtime, semanticProtocolEnabled: false
        )
    }

    /// The real tool names, from the app's own catalogue.
    private var actionTools: [AIToolSchema] {
        [
            AIToolSchema(
                name: "createReminder",
                description: "Create a NEW reminder. Use this for \"remind me…\" requests.",
                parameters: .object(
                    properties: ["title": .string(), "dueDate": .string()],
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
                name: "createCalendarEvent",
                description: "Create a NEW event in the user's calendar.",
                parameters: .object(
                    properties: ["title": .string(), "start": .string()],
                    required: ["title", "start"]
                )
            ),
            AIToolSchema(
                name: "updateCalendarEvent",
                description: "Modify an EXISTING calendar event.",
                parameters: .object(
                    properties: ["eventID": .string(), "start": .string()],
                    required: ["eventID"]
                )
            ),
        ]
    }

    private func request(
        _ text: String,
        tools: [AIToolSchema]? = nil,
        priorResults: [AIMessage] = []
    ) -> AIRequest {
        AIRequest(
            systemPrompt: "You are a personal assistant.",
            messages: priorResults + [AIMessage(role: .user, content: text)],
            tools: tools ?? actionTools
        )
    }

    /// A `.tool` message carrying a real result — the only trusted source of an
    /// identifier for something that already exists.
    private func toolResult(
        tool: String,
        payload: [String: String],
        status: AIToolStatus = .succeeded
    ) -> AIMessage {
        let callID = ToolCallID()
        return AIMessage(
            role: .tool,
            content: "done",
            toolCallID: callID,
            toolResult: AIToolResult(
                callID: callID,
                toolName: tool,
                status: status,
                payload: payload,
                message: "done"
            )
        )
    }

    private static let realEventID = "8F4A21C0-B7D3-4E15-9A62-1C0D5E7B3A94"
    private static let fabricatedEventID = "550e8400-e29b-41d4-a716-446655440000"

    // MARK: The regression

    /// Section 38. The exact case from the device.
    func testARemindMeRequestProducesAReminderCallAndNotACalendarUpdate() async throws {
        let runtime = MockLocalModelRuntime()
        await runtime.alwaysRespond(
            .toolCalls(
                names: ["createReminder"],
                arguments: [["title": .string("Something"), "dueDate": .string("2026-08-30T14:10:00Z")]],
                message: "I'll remind you."
            )
        )
        let provider = try await makeProvider(descriptor: descriptor(), runtime: runtime)

        let response = try await provider.respond(to: request("Remind me something in 10 minutes."))

        XCTAssertEqual(response.toolCalls.count, 1)
        XCTAssertEqual(response.toolCalls.first?.name, "createReminder")
        XCTAssertNotEqual(response.toolCalls.first?.name, "updateCalendarEvent")
        XCTAssertEqual(response.stopReason, .toolCalls)
    }

    /// Section 49 and the heart of it: the exact prose the device produced must
    /// never reach the user.
    func testSchemaProseForAnActionRequestIsNeverShown() async throws {
        let leak = """
            To do that I would use the updateCalendarEvent tool. Its schema requires \
            an eventID parameter of "type": "string" with "format": "uuid", and the \
            value you gave is not a valid UUID.
            """
        let runtime = MockLocalModelRuntime()
        await runtime.alwaysRespond(.raw(leak))
        let provider = try await makeProvider(descriptor: descriptor(), runtime: runtime)

        let response = try await provider.respond(to: request("Remind me something in 10 minutes."))

        XCTAssertTrue(response.toolCalls.isEmpty)
        XCTAssertEqual(response.text, LocalModelProvider.actionFailureMessage)
        for forbidden in ["updateCalendarEvent", "eventID", "uuid", "schema", "type"] {
            XCTAssertFalse(
                response.text.lowercased().contains(forbidden.lowercased()),
                "the reply leaked \(forbidden)"
            )
        }
    }

    /// Section 5. The same words, asked for on purpose, are a legitimate answer.
    func testSchemaProseForAnExplicitQuestionIsStillAllowed() async throws {
        let explanation =
            "The updateCalendarEvent tool takes an eventID parameter of type string."
        let runtime = MockLocalModelRuntime()
        await runtime.alwaysRespond(.raw(explanation))
        let provider = try await makeProvider(descriptor: descriptor(), runtime: runtime)

        let response = try await provider.respond(
            to: request("How does the updateCalendarEvent tool work?")
        )

        XCTAssertEqual(response.text, explanation)
    }

    // MARK: The wrong kind of action

    /// The device regression this continuation exists for.
    ///
    /// `storeMemory` for "remind me in 10 minutes" passes every other check —
    /// valid envelope, real tool, sound arguments, no invented identifier — and
    /// is still wrong in the way that matters most: the user is told something
    /// was noted, believes a reminder exists, and nothing will happen at 10
    /// minutes. Recording that something matters is not the same as making it
    /// happen, which is the distinction the whole app is built on.
    func testAReminderRequestAnsweredWithStoreMemoryIsRefused() async throws {
        let runtime = MockLocalModelRuntime()
        await runtime.alwaysRespond(
            .toolCalls(
                names: ["storeMemory"],
                arguments: [["content": .string("Change bottles in 10 minutes")]],
                message: "I'll remember that."
            )
        )
        let provider = try await makeProvider(descriptor: descriptor(), runtime: runtime)

        let response = try await provider.respond(
            to: request("Remind me in 10 minutes to change bottles")
        )

        XCTAssertTrue(
            response.toolCalls.isEmpty,
            "a reminder request must never execute storeMemory"
        )
        XCTAssertEqual(response.text, LocalModelProvider.actionFailureMessage)
    }

    /// The same request, answered correctly, still works. The guard refuses one
    /// specific wrong answer — it does not make reminders harder to set.
    func testTheChangeBottlesReminderReachesTheReminderTool() async throws {
        let runtime = MockLocalModelRuntime()
        await runtime.alwaysRespond(
            .toolCalls(
                names: ["createReminder"],
                arguments: [[
                    "title": .string("Change bottles"),
                    "dueDate": .string("2026-08-30T14:10:00Z"),
                ]],
                message: "I'll remind you."
            )
        )
        let provider = try await makeProvider(descriptor: descriptor(), runtime: runtime)

        let response = try await provider.respond(
            to: request("Remind me in 10 minutes to change bottles")
        )

        XCTAssertEqual(response.toolCalls.count, 1)
        XCTAssertEqual(response.toolCalls.first?.name, "createReminder")
    }

    /// The converse must keep working: a request to remember a fact is exactly
    /// what `storeMemory` is for, and the guard must not touch it.
    func testRememberingAFactStillReachesStoreMemory() async throws {
        let runtime = MockLocalModelRuntime()
        await runtime.alwaysRespond(
            .toolCalls(
                names: ["storeMemory"],
                arguments: [["content": .string("John's birthday is May 3")]],
                message: "Noted."
            )
        )
        let provider = try await makeProvider(descriptor: descriptor(), runtime: runtime)

        let response = try await provider.respond(
            to: request("Remember that John's birthday is May 3")
        )

        XCTAssertEqual(response.toolCalls.count, 1)
        XCTAssertEqual(response.toolCalls.first?.name, "storeMemory")
    }

    /// A reminder that also stores a note has done the thing that was asked.
    /// Refusing the pair would throw away a correct action to punish a harmless
    /// extra one.
    func testAReminderAlongsideAStoredNoteIsAllowed() async throws {
        let runtime = MockLocalModelRuntime()
        await runtime.alwaysRespond(
            .toolCalls(
                names: ["createReminder", "storeMemory"],
                arguments: [
                    ["title": .string("Change bottles")],
                    ["content": .string("Bottles need changing every 10 minutes")],
                ],
                message: "Done."
            )
        )
        let provider = try await makeProvider(descriptor: descriptor(), runtime: runtime)

        let response = try await provider.respond(
            to: request("Remind me in 10 minutes to change bottles")
        )

        XCTAssertEqual(response.toolCalls.count, 2)
        XCTAssertTrue(response.toolCalls.contains { $0.name == "createReminder" })
    }

    // MARK: Create versus update

    /// Section 39.
    func testACalendarRequestProducesACreateCall() async throws {
        let runtime = MockLocalModelRuntime()
        await runtime.alwaysRespond(
            .toolCalls(
                names: ["createCalendarEvent"],
                arguments: [["title": .string("Dentist"), "start": .string("2026-08-31T15:00:00Z")]],
                message: "Adding it."
            )
        )
        let provider = try await makeProvider(descriptor: descriptor(), runtime: runtime)

        let response = try await provider.respond(
            to: request("Create a calendar event tomorrow at 3 called Dentist.")
        )

        XCTAssertEqual(response.toolCalls.first?.name, "createCalendarEvent")
    }

    /// Section 40. A real identifier, from a real result, passes.
    func testAnUpdateWithATrustedIdentifierIsAllowedThrough() async throws {
        let runtime = MockLocalModelRuntime()
        await runtime.alwaysRespond(
            .toolCalls(
                names: ["updateCalendarEvent"],
                arguments: [[
                    "eventID": .string(Self.realEventID),
                    "start": .string("2026-08-31T17:00:00Z"),
                ]],
                message: "Moving it."
            )
        )
        let provider = try await makeProvider(descriptor: descriptor(), runtime: runtime)

        let response = try await provider.respond(
            to: request(
                "Move my dentist event from 4 to 5.",
                priorResults: [
                    toolResult(tool: "getUpcomingSchedule", payload: ["eventID": Self.realEventID])
                ]
            )
        )

        XCTAssertEqual(response.toolCalls.count, 1)
        XCTAssertEqual(response.toolCalls.first?.name, "updateCalendarEvent")
    }

    /// Section 42. The central protection: well-formed, plausible, and not from
    /// anywhere.
    func testAnUpdateWithAFabricatedIdentifierIsRejected() async throws {
        let runtime = MockLocalModelRuntime()
        // Both the first attempt and the repair fabricate — a model that has
        // invented one will usually invent another.
        await runtime.alwaysRespond(
            .toolCalls(
                names: ["updateCalendarEvent"],
                arguments: [["eventID": .string(Self.fabricatedEventID)]],
                message: "Updating."
            )
        )
        let provider = try await makeProvider(descriptor: descriptor(), runtime: runtime)

        let response = try await provider.respond(
            to: request(
                "Move my dentist event to 5.",
                priorResults: [
                    toolResult(tool: "getUpcomingSchedule", payload: ["eventID": Self.realEventID])
                ]
            )
        )

        XCTAssertTrue(response.toolCalls.isEmpty, "a fabricated identifier reached execution")
        XCTAssertEqual(response.text, LocalModelProvider.actionFailureMessage)
    }

    /// Section 41. Missing is refused, not filled in.
    func testAnUpdateWithNoIdentifierIsRejectedRatherThanInvented() async throws {
        let runtime = MockLocalModelRuntime()
        await runtime.alwaysRespond(
            .toolCalls(
                names: ["updateCalendarEvent"],
                arguments: [["start": .string("2026-08-31T17:00:00Z")]],
                message: "Updating."
            )
        )
        let provider = try await makeProvider(descriptor: descriptor(), runtime: runtime)

        let response = try await provider.respond(to: request("Move my dentist event to 5."))

        XCTAssertTrue(response.toolCalls.isEmpty)
        XCTAssertEqual(response.text, LocalModelProvider.actionFailureMessage)
    }

    // MARK: Repair

    /// Section 43 and 45. Prose around a valid call is unwrapped, not shown.
    func testProseWrappedJSONBecomesACleanToolCall() async throws {
        let runtime = MockLocalModelRuntime()
        await runtime.alwaysRespond(
            .raw("""
                Sure, I'll create the reminder:
                {"tool_calls":[{"name":"createReminder","arguments":{"title":"Something"}}],\
                "message":"I'll remind you."}
                """)
        )
        let provider = try await makeProvider(descriptor: descriptor(), runtime: runtime)

        let response = try await provider.respond(to: request("Remind me in 10 minutes."))

        XCTAssertEqual(response.toolCalls.first?.name, "createReminder")
        XCTAssertEqual(response.text, "I'll remind you.")
        XCTAssertFalse(response.text.contains("tool_calls"))
    }

    /// Sections 44 and 45: one repair, and it works.
    func testAMalformedAttemptIsRepairedExactlyOnce() async throws {
        let runtime = MockLocalModelRuntime()
        await runtime.enqueue(
            .raw("{\"tool_calls\":[{\"name\":\"createReminder\",\"arguments\":{\"title\":\"x\""),
            .toolCalls(
                names: ["createReminder"],
                arguments: [["title": .string("Something")]],
                message: "I'll remind you."
            )
        )
        let provider = try await makeProvider(descriptor: descriptor(), runtime: runtime)

        let response = try await provider.respond(to: request("Remind me in 10 minutes."))

        XCTAssertEqual(response.toolCalls.first?.name, "createReminder")
        let generations = await runtime.generateCount
        XCTAssertEqual(generations, 2, "expected one generation plus one repair")
    }

    /// Sections 46 and 55. Two failures, and it stops.
    func testAFailedRepairStopsAndSaysSoWithoutLeaking() async throws {
        let runtime = MockLocalModelRuntime()
        await runtime.alwaysRespond(
            .raw("The createReminder schema requires \"properties\" and a \"required\" list.")
        )
        let provider = try await makeProvider(descriptor: descriptor(), runtime: runtime)

        let response = try await provider.respond(to: request("Remind me in 10 minutes."))

        XCTAssertTrue(response.toolCalls.isEmpty)
        XCTAssertEqual(response.text, LocalModelProvider.actionFailureMessage)
        XCTAssertFalse(response.text.contains("properties"))
        let generations = await runtime.generateCount
        XCTAssertEqual(generations, 2, "there must be no third attempt")
    }

    /// Section 31. A repair that answers in prose has not done anything, and
    /// must not be allowed to sound as if it had.
    func testARepairThatReturnsProseIsNotTreatedAsSuccess() async throws {
        let runtime = MockLocalModelRuntime()
        await runtime.enqueue(
            .raw("{\"tool_calls\":[{\"name\":\"createReminder\","),
            .text("Done — I'll remind you in 10 minutes.")
        )
        let provider = try await makeProvider(descriptor: descriptor(), runtime: runtime)

        let response = try await provider.respond(to: request("Remind me in 10 minutes."))

        XCTAssertTrue(response.toolCalls.isEmpty)
        XCTAssertEqual(response.text, LocalModelProvider.actionFailureMessage)
        XCTAssertFalse(response.text.contains("Done"))
    }

    /// Section 50. A tool that does not exist is not a tool.
    func testAnUnknownToolIsRejected() async throws {
        let runtime = MockLocalModelRuntime()
        await runtime.alwaysRespond(
            .raw("{\"tool_calls\":[{\"name\":\"setPhoneAlarmDirectly\",\"arguments\":{}}]}")
        )
        let provider = try await makeProvider(descriptor: descriptor(), runtime: runtime)

        let response = try await provider.respond(to: request("Remind me in 10 minutes."))

        XCTAssertTrue(response.toolCalls.isEmpty)
        XCTAssertEqual(response.text, LocalModelProvider.actionFailureMessage)
    }

    // MARK: Capability

    /// Section 47. Honest rather than pretending.
    func testAChatOnlyModelRefusesAnActionRequestPlainly() async throws {
        let runtime = MockLocalModelRuntime()
        await runtime.alwaysRespond(.text("Sure, I've set that reminder for you."))
        let provider = try await makeProvider(
            descriptor: descriptor(toolSupport: .unsupported), runtime: runtime
        )

        let response = try await provider.respond(to: request("Remind me in 10 minutes."))

        XCTAssertTrue(response.toolCalls.isEmpty)
        XCTAssertEqual(response.text, LocalModelProvider.chatOnlyMessage)
        // Section 31: the model's own fake confirmation never reaches the user.
        XCTAssertFalse(response.text.contains("I've set"))
        let generations = await runtime.generateCount
        XCTAssertEqual(generations, 0, "a refusal should not spend a generation")
    }

    /// Section 48. Chat-only means chat works.
    func testAChatOnlyModelStillAnswersOrdinaryQuestions() async throws {
        let runtime = MockLocalModelRuntime()
        await runtime.alwaysRespond(.text("Paris."))
        let provider = try await makeProvider(
            descriptor: descriptor(toolSupport: .unsupported), runtime: runtime
        )

        let response = try await provider.respond(to: request("What is the capital of France?"))

        XCTAssertEqual(response.text, "Paris.")
    }

    /// Section 7. The badge a person reads before choosing.
    func testCapabilityBadgesAreDistinctAndHonest() {
        XCTAssertEqual(LocalModelToolSupport.supported.badge, "Supports actions")
        XCTAssertEqual(LocalModelToolSupport.experimental.badge, "Experimental actions")
        XCTAssertEqual(LocalModelToolSupport.unsupported.badge, "Chat only")
        XCTAssertFalse(LocalModelToolSupport.unsupported.offersTools)
    }

    // MARK: Continuation

    /// Section 53. After a real result, the model writes the confirmation — and
    /// only then.
    func testAToolResultContinuationProducesTheFinalConfirmation() async throws {
        let runtime = MockLocalModelRuntime()
        await runtime.alwaysRespond(.text("Done — I'll remind you in 10 minutes."))
        let provider = try await makeProvider(descriptor: descriptor(), runtime: runtime)

        let response = try await provider.respond(
            to: request(
                "Remind me in 10 minutes.",
                priorResults: [
                    toolResult(tool: "createReminder", payload: ["reminderID": Self.realEventID])
                ]
            )
        )

        XCTAssertEqual(response.text, "Done — I'll remind you in 10 minutes.")
        XCTAssertTrue(response.toolCalls.isEmpty)
    }
}

/// The classification itself, without a model in the way.
final class LocalToolClassificationTests: XCTestCase {

    private let parser = LocalToolCallParser()

    private var tools: [AIToolSchema] {
        [
            AIToolSchema(
                name: "createReminder", description: "Create a NEW reminder.",
                parameters: .object(properties: ["title": .string()], required: ["title"])
            ),
            AIToolSchema(
                name: "updateCalendarEvent", description: "Modify an EXISTING event.",
                parameters: .object(properties: ["eventID": .string()], required: ["eventID"])
            ),
        ]
    }

    private func classify(_ raw: String, expectsAction: Bool) -> LocalAssistantOutcome {
        parser.classify(raw, offeredTools: tools, expectsAction: expectsAction)
    }

    // MARK: Intent

    /// Section 5's distinction, which is what makes containment safe to apply.
    func testActionPhrasingIsRecognised() {
        for phrase in [
            "Remind me something in 10 minutes.",
            "remind me to call the dentist",
            "Set an alarm for 7.",
            "Add an event tomorrow at 3 called Dentist.",
            "Move my dentist event from 4 to 5.",
        ] {
            XCTAssertTrue(LocalActionIntent.isLikely(in: phrase), phrase)
        }
    }

    func testQuestionsAboutTheSystemAreNotActionRequests() {
        for phrase in [
            "How do you create a reminder?",
            "What tools do you have?",
            "Can you explain the updateCalendarEvent schema?",
            "What is the capital of France?",
        ] {
            XCTAssertFalse(LocalActionIntent.isLikely(in: phrase), phrase)
        }
    }

    // MARK: Category

    func testReminderPhrasingIsCategorisedAsAReminder() {
        for phrase in [
            "Remind me in 10 minutes to change bottles",
            "remind me to call the dentist",
            "Set an alarm for 7.",
            "Wake me at six.",
            "Nudge me about the laundry.",
        ] {
            XCTAssertEqual(LocalActionIntent.category(in: phrase), .reminder, phrase)
        }
    }

    func testMemoryPhrasingIsCategorisedAsMemory() {
        for phrase in [
            "Remember that John's birthday is May 3",
            "Note that I prefer aisle seats.",
            "Remember my sister's name is Ana.",
        ] {
            XCTAssertEqual(LocalActionIntent.category(in: phrase), .memory, phrase)
        }
    }

    /// The ambiguous sentence, resolved the way that fails safe: what is being
    /// asked for is the reminding.
    func testRemindMeToRememberIsAReminder() {
        XCTAssertEqual(
            LocalActionIntent.category(in: "Remind me to remember the passports"),
            .reminder
        )
    }

    func testAnOrdinaryQuestionHasNoActionCategory() {
        XCTAssertEqual(LocalActionIntent.category(in: "What is the capital of France?"), .other)
        XCTAssertEqual(LocalActionIntent.category(in: "How do you create a reminder?"), .other)
    }

    private func toolCall(_ name: String) -> AIToolCall {
        AIToolCall(name: name, arguments: .object([:]))
    }

    func testTheGuardRefusesOnlyAReminderAnsweredEntirelyWithMemoryTools() {
        XCTAssertNotNil(
            LocalToolIntentGuard.mismatch(category: .reminder, calls: [toolCall("storeMemory")])
        )
        XCTAssertNotNil(
            LocalToolIntentGuard.mismatch(
                category: .reminder,
                calls: [toolCall("storeMemory"), toolCall("updateMemory")]
            )
        )
        // A real action is present.
        XCTAssertNil(
            LocalToolIntentGuard.mismatch(
                category: .reminder,
                calls: [toolCall("createReminder"), toolCall("storeMemory")]
            )
        )
        // Not a reminder request at all.
        XCTAssertNil(
            LocalToolIntentGuard.mismatch(category: .memory, calls: [toolCall("storeMemory")])
        )
        XCTAssertNil(
            LocalToolIntentGuard.mismatch(category: .other, calls: [toolCall("storeMemory")])
        )
        // Nothing proposed is not a mismatch; it is handled elsewhere.
        XCTAssertNil(LocalToolIntentGuard.mismatch(category: .reminder, calls: []))
    }

    /// The names the guard refuses on must be real tools, so a rename in the
    /// domain cannot quietly empty the set and turn the guard into a no-op that
    /// still looks like it is working.
    func testTheGuardsToolNamesAreRealTools() {
        XCTAssertFalse(LocalToolIntentGuard.memoryOnlyTools.isEmpty)
        for name in LocalToolIntentGuard.memoryOnlyTools {
            XCTAssertNotNil(ToolKind(rawValue: name), "\(name) is not a ToolKind")
        }
    }

    // MARK: Classification

    func testSchemaProseForAnActionIsClassifiedAsALeak() {
        let outcome = classify(
            "The updateCalendarEvent schema requires an eventID of \"type\": \"string\".",
            expectsAction: true
        )
        guard case .schemaLeak = outcome else {
            return XCTFail("expected schemaLeak, got \(outcome.diagnosticSymbol)")
        }
        XCTAssertTrue(outcome.isRepairable)
    }

    func testTheSameProseWithoutAnActionRequestIsOrdinaryText() {
        let outcome = classify(
            "The updateCalendarEvent schema requires an eventID of \"type\": \"string\".",
            expectsAction: false
        )
        guard case .text = outcome else {
            return XCTFail("expected text, got \(outcome.diagnosticSymbol)")
        }
        XCTAssertFalse(outcome.isRepairable)
    }

    func testAnUnfinishedJSONObjectIsAMalformedAttempt() {
        let outcome = classify(
            "{\"tool_calls\":[{\"name\":\"createReminder\",\"arguments\":{\"minutes\":10",
            expectsAction: true
        )
        guard case .malformedToolAttempt = outcome else {
            return XCTFail("expected malformedToolAttempt, got \(outcome.diagnosticSymbol)")
        }
    }

    func testAnOrdinaryConfirmationIsNotMistakenForALeak() {
        // Names a tool, no schema vocabulary — a perfectly normal thing to say.
        let outcome = classify("I'll add a reminder for you in ten minutes.", expectsAction: true)
        guard case .text = outcome else {
            return XCTFail("expected text, got \(outcome.diagnosticSymbol)")
        }
    }

    func testProseWrappedJSONIsClassifiedAsAToolCall() {
        let outcome = classify(
            """
            Sure, I'll do that:
            {"tool_calls":[{"name":"createReminder","arguments":{"title":"x"}}],"message":"OK"}
            """,
            expectsAction: true
        )
        guard case .toolCalls(let calls, let message) = outcome else {
            return XCTFail("expected toolCalls, got \(outcome.diagnosticSymbol)")
        }
        XCTAssertEqual(calls.first?.name, "createReminder")
        XCTAssertEqual(message, "OK")
    }

    // MARK: Provenance

    private func result(_ payload: [String: String], status: AIToolStatus = .succeeded) -> AIMessage {
        let callID = ToolCallID()
        return AIMessage(
            role: .tool, content: "ok", toolCallID: callID,
            toolResult: AIToolResult(
                callID: callID, toolName: "getUpcomingSchedule", status: status,
                payload: payload, message: "ok"
            )
        )
    }

    private func call(_ name: String, _ arguments: [String: JSONValue]) -> AIToolCall {
        AIToolCall(name: name, arguments: .object(arguments))
    }

    func testAnIdentifierFromAToolResultIsTrusted() {
        let provenance = LocalResourceProvenance.harvested(from: [result(["eventID": "EVENT_ABC"])])
        XCTAssertTrue(provenance.isTrusted("EVENT_ABC"))
        XCTAssertNil(
            provenance.check(call("updateCalendarEvent", ["eventID": .string("EVENT_ABC")]))
        )
    }

    func testAnIdentifierFromNowhereIsRejected() {
        let provenance = LocalResourceProvenance.harvested(from: [result(["eventID": "EVENT_ABC"])])
        XCTAssertEqual(
            provenance.check(
                call("updateCalendarEvent", ["eventID": .string("EVENT_ZZZ")])
            )?.symbol,
            "fabricatedIdentifier"
        )
    }

    func testAMissingIdentifierIsReportedRatherThanFilledIn() {
        let provenance = LocalResourceProvenance.harvested(from: [])
        XCTAssertEqual(
            provenance.check(call("updateCalendarEvent", [:]))?.symbol,
            "missingIdentifier"
        )
    }

    /// Section 13: a create has no existing resource, so nothing to prove.
    func testCreateToolsAreNotSubjectToProvenance() {
        let provenance = LocalResourceProvenance.harvested(from: [])
        XCTAssertNil(provenance.check(call("createReminder", ["title": .string("x")])))
        XCTAssertNil(
            provenance.check(
                call("createCalendarEvent", ["title": .string("Dentist"), "start": .string("x")])
            )
        )
    }

    /// Section 52. The two identifier kinds are the same shape and mean
    /// completely different things.
    func testAToolCallIdentifierNeverSatisfiesResourceProvenance() {
        let invocation = ToolCallID()
        // The app minted this to track an invocation. It refers to no calendar
        // event, and a result that merely echoes a call id must not make it a
        // usable handle to a resource.
        let provenance = LocalResourceProvenance.harvested(from: [])
        XCTAssertFalse(provenance.isTrusted(invocation.rawValue.uuidString))
        XCTAssertEqual(
            provenance.check(
                call("updateCalendarEvent", ["eventID": .string(invocation.rawValue.uuidString)])
            )?.symbol,
            "fabricatedIdentifier"
        )
    }

    /// A failed call produced no resource, so its payload is not a source of
    /// trusted identifiers.
    func testIdentifiersFromFailedResultsAreNotTrusted() {
        let provenance = LocalResourceProvenance.harvested(
            from: [result(["eventID": "EVENT_ABC"], status: .failed)]
        )
        XCTAssertFalse(provenance.isTrusted("EVENT_ABC"))
    }

    /// Section 55, as a property of the type rather than of a run.
    func testOnlyMalformedAndLeakedOutcomesAreEverRepaired() {
        XCTAssertTrue(LocalAssistantOutcome.malformedToolAttempt(reason: "x").isRepairable)
        XCTAssertTrue(LocalAssistantOutcome.schemaLeak(reason: "x").isRepairable)
        XCTAssertFalse(LocalAssistantOutcome.text("hello").isRepairable)
        XCTAssertFalse(LocalAssistantOutcome.failure(reason: "x").isRepairable)
        XCTAssertFalse(
            LocalAssistantOutcome.toolCalls(calls: [], message: "").isRepairable
        )
    }
}
