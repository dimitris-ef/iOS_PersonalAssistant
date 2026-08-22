import AssistantAI
import AssistantDomain
import XCTest
@testable import AIProviderLocal

/// Turning a local model's text into actions — and refusing to, when it is not.
///
/// The property under test is section 57's: the parser rejects rather than
/// repairs. A model that gets the syntax wrong produces a structured-output
/// error the turn can report, never a best guess at which action it meant.
final class LocalToolParsingTests: XCTestCase {
    private let adapter = LocalToolPromptAdapter()

    private var tools: [AIToolSchema] {
        [
            AIToolSchema(
                name: "createTask",
                description: "Create a task.",
                parameters: .object(
                    properties: ["title": .string(description: "What to do")],
                    required: ["title"]
                )
            ),
            AIToolSchema(
                name: "createReminder",
                description: "Create a reminder.",
                parameters: .object(
                    properties: [
                        "title": .string(),
                        "at": .string(format: .dateTime),
                    ],
                    required: ["title", "at"]
                )
            ),
        ]
    }

    // MARK: Prompting

    /// Section 53. The instructions are generated from the app's existing tool
    /// schemas — there is no second catalogue to keep in step.
    func testInstructionsDescribeTheOfferedToolsAndNothingElse() {
        let text = adapter.instructions(for: tools)

        XCTAssertTrue(text.contains("createTask"))
        XCTAssertTrue(text.contains("createReminder"))
        XCTAssertTrue(text.contains("Create a task."))
        XCTAssertTrue(text.contains("tool_calls"))
        XCTAssertFalse(text.contains("deleteCalendarEvent"), "only what was offered")
    }

    func testNoToolsMeansNoInstructions() {
        XCTAssertTrue(adapter.instructions(for: []).isEmpty)
    }

    // MARK: Ordinary replies

    /// Section 56. Prose is a reply, not a failure — otherwise every
    /// conversational turn would be an error.
    func testPlainTextIsTreatedAsAReply() throws {
        let output = try adapter.parse(
            "You have a dentist appointment on Friday at 10.",
            offeredTools: tools
        )
        XCTAssertEqual(output.text, "You have a dentist appointment on Friday at 10.")
        XCTAssertTrue(output.toolCalls.isEmpty)
    }

    /// A model that mentions JSON in passing has not proposed anything.
    func testAnUnrelatedJSONObjectInProseIsNotAnEnvelope() throws {
        let output = try adapter.parse(
            "The config looked like {\"theme\": \"dark\"} when I last saw it.",
            offeredTools: tools
        )
        XCTAssertTrue(output.toolCalls.isEmpty)
        XCTAssertTrue(output.text.contains("dark"))
    }

    // MARK: Tool calls

    /// Section 101, the parsing half: a well-formed envelope becomes an
    /// `AIToolCall` and nothing else.
    func testAWellFormedEnvelopeBecomesAToolCall() throws {
        let raw = """
            {"tool_calls":[{"name":"createTask","arguments":{"title":"Call the dentist"}}],\
            "message":"I'll add that."}
            """
        let output = try adapter.parse(raw, offeredTools: tools)

        XCTAssertEqual(output.text, "I'll add that.")
        XCTAssertEqual(output.toolCalls.count, 1)
        XCTAssertEqual(output.toolCalls.first?.name, "createTask")
        XCTAssertEqual(
            output.toolCalls.first?.arguments["title"]?.stringValue,
            "Call the dentist"
        )
    }

    /// Models add code fences whether or not asked.
    func testAFencedEnvelopeIsRead() throws {
        let raw = """
            ```json
            {"tool_calls":[{"name":"createTask","arguments":{"title":"Buy milk"}}],"message":"Done."}
            ```
            """
        let output = try adapter.parse(raw, offeredTools: tools)
        XCTAssertEqual(output.toolCalls.first?.arguments["title"]?.stringValue, "Buy milk")
    }

    /// Prose either side of the envelope is kept when the envelope has no
    /// message: a small model that writes "Sure! {json}" has still said
    /// something, and a blank reply is worse than a slightly odd one.
    func testSurroundingProseBecomesTheReplyWhenTheEnvelopeHasNoMessage() throws {
        let raw = """
            Sure, I'll take care of that.
            {"tool_calls":[{"name":"createTask","arguments":{"title":"Book a table"}}]}
            """
        let output = try adapter.parse(raw, offeredTools: tools)
        XCTAssertEqual(output.text, "Sure, I'll take care of that.")
        XCTAssertEqual(output.toolCalls.count, 1)
    }

    /// Nested objects in arguments must not end the envelope early.
    func testNestedArgumentsAreParsed() throws {
        let raw = """
            {"tool_calls":[{"name":"createReminder","arguments":{"title":"Pay rent",\
            "at":"2026-09-01T09:00:00Z"}}],"message":"Set."}
            """
        let output = try adapter.parse(raw, offeredTools: tools)
        XCTAssertEqual(output.toolCalls.first?.arguments["at"]?.stringValue, "2026-09-01T09:00:00Z")
    }

    /// A brace inside a string is not the end of the object.
    func testABraceInsideAStringDoesNotTerminateTheEnvelope() throws {
        let raw = """
            {"tool_calls":[{"name":"createTask","arguments":{"title":"Fix the } bug"}}],\
            "message":"OK"}
            """
        let output = try adapter.parse(raw, offeredTools: tools)
        XCTAssertEqual(output.toolCalls.first?.arguments["title"]?.stringValue, "Fix the } bug")
    }

    /// The call identifier is minted by the app, never taken from the model —
    /// a model-supplied id would be a model-supplied handle into the execution
    /// ledger, which is what stops the same action running twice.
    func testCallIdentifiersAreNotTakenFromTheModel() throws {
        let raw = """
            {"tool_calls":[{"id":"attacker-chosen","name":"createTask",\
            "arguments":{"title":"x"}}],"message":""}
            """
        let output = try adapter.parse(raw, offeredTools: tools)
        XCTAssertNotEqual(output.toolCalls.first?.id.rawValue.uuidString, "attacker-chosen")
    }

    // MARK: Rejection

    /// Section 102. Malformed JSON inside an envelope is an error.
    func testMalformedJSONIsRejected() {
        let raw = "{\"tool_calls\":[{\"name\":\"createTask\",}],\"message\":\"x\"}"
        XCTAssertThrowsError(try adapter.parse(raw, offeredTools: tools)) { error in
            guard case .malformedJSON = error as? LocalToolParseError else {
                return XCTFail("expected malformedJSON, got \(error)")
            }
        }
    }

    /// Section 102. A tool that does not exist never becomes a call.
    func testAnUnknownToolIsRejected() {
        let raw = """
            {"tool_calls":[{"name":"wipeDevice","arguments":{}}],"message":"ok"}
            """
        XCTAssertThrowsError(try adapter.parse(raw, offeredTools: tools)) { error in
            guard case .unknownTool(let name) = error as? LocalToolParseError else {
                return XCTFail("expected unknownTool, got \(error)")
            }
            XCTAssertEqual(name, "wipeDevice")
        }
    }

    /// A tool the app *has* but did not offer this turn is equally unknown.
    func testAToolNotOfferedThisTurnIsRejected() {
        let raw = """
            {"tool_calls":[{"name":"createReminder","arguments":{"title":"x","at":"y"}}],"message":""}
            """
        XCTAssertThrowsError(
            try adapter.parse(raw, offeredTools: [tools[0]])
        ) { error in
            guard case .unknownTool = error as? LocalToolParseError else {
                return XCTFail("expected unknownTool, got \(error)")
            }
        }
    }

    func testNonObjectArgumentsAreRejected() {
        let raw = """
            {"tool_calls":[{"name":"createTask","arguments":["Call the dentist"]}],"message":""}
            """
        XCTAssertThrowsError(try adapter.parse(raw, offeredTools: tools)) { error in
            guard case .invalidArguments = error as? LocalToolParseError else {
                return XCTFail("expected invalidArguments, got \(error)")
            }
        }
    }

    /// Arguments as a JSON *string* are decoded — the content is unambiguous —
    /// but a string that is not JSON is still a failure.
    func testStringEncodedArgumentsAreDecodedAndGarbageIsNot() throws {
        let good = """
            {"tool_calls":[{"name":"createTask","arguments":"{\\"title\\":\\"Post the letter\\"}"}],\
            "message":""}
            """
        let output = try adapter.parse(good, offeredTools: tools)
        XCTAssertEqual(output.toolCalls.first?.arguments["title"]?.stringValue, "Post the letter")

        let bad = """
            {"tool_calls":[{"name":"createTask","arguments":"just some words"}],"message":""}
            """
        XCTAssertThrowsError(try adapter.parse(bad, offeredTools: tools))
    }

    func testAMissingNameIsRejected() {
        let raw = "{\"tool_calls\":[{\"arguments\":{\"title\":\"x\"}}],\"message\":\"\"}"
        XCTAssertThrowsError(try adapter.parse(raw, offeredTools: tools)) { error in
            guard case .malformedEnvelope = error as? LocalToolParseError else {
                return XCTFail("expected malformedEnvelope, got \(error)")
            }
        }
    }

    /// Section 57's "call count reasonable". A model that emits fifty actions
    /// has lost the plot, and running the first eight of them is not the fix.
    func testTooManyCallsAreRejected() {
        let calls = (0..<20).map { index in
            "{\"name\":\"createTask\",\"arguments\":{\"title\":\"task \(index)\"}}"
        }
        let raw = "{\"tool_calls\":[\(calls.joined(separator: ","))],\"message\":\"\"}"

        XCTAssertThrowsError(try adapter.parse(raw, offeredTools: tools, maximumCalls: 8)) { error in
            guard case .tooManyCalls = error as? LocalToolParseError else {
                return XCTFail("expected tooManyCalls, got \(error)")
            }
        }
    }

    /// An envelope with a message and an explicitly empty call list is a reply.
    func testAnEmptyCallListIsAReply() throws {
        let output = try adapter.parse(
            "{\"tool_calls\":[],\"message\":\"Nothing to do.\"}",
            offeredTools: tools
        )
        XCTAssertEqual(output.text, "Nothing to do.")
        XCTAssertTrue(output.toolCalls.isEmpty)
    }

    // MARK: Round trip

    /// The renderer and the parser agree, which is what makes replaying an
    /// earlier assistant turn into a continuation round safe (section 60).
    func testAnEnvelopeSurvivesARoundTrip() throws {
        let original = AIToolCall(
            name: "createReminder",
            arguments: .object(["title": .string("Call Dad"), "at": .string("2026-09-02T18:00:00Z")])
        )
        let rendered = LocalToolPromptAdapter.renderEnvelope(
            calls: [original],
            message: "Will do."
        )
        let parsed = try adapter.parse(rendered, offeredTools: tools)

        XCTAssertEqual(parsed.text, "Will do.")
        XCTAssertEqual(parsed.toolCalls.first?.name, original.name)
        XCTAssertEqual(parsed.toolCalls.first?.arguments, original.arguments)
    }
}

/// The chat templates, which decide whether a model sees a prompt it recognises.
final class LocalChatTemplateTests: XCTestCase {
    private let turns: [LocalChatTurn] = [
        .system("You are a helpful assistant."),
        .user("What is on today?"),
    ]

    func testChatMLUsesItsOwnMarkers() {
        let rendered = LocalChatTemplate.chatML.render(turns)
        XCTAssertTrue(rendered.contains("<|im_start|>system"))
        XCTAssertTrue(rendered.contains("<|im_end|>"))
        XCTAssertTrue(rendered.hasSuffix("<|im_start|>assistant\n"), "it must invite a reply")
    }

    func testLlama3UsesHeaderBlocks() {
        let rendered = LocalChatTemplate.llama3.render(turns)
        XCTAssertTrue(rendered.hasPrefix("<|begin_of_text|>"))
        XCTAssertTrue(rendered.contains("<|start_header_id|>user<|end_header_id|>"))
        XCTAssertTrue(rendered.hasSuffix("<|start_header_id|>assistant<|end_header_id|>\n\n"))
    }

    /// Gemma has no system role, and the system prompt is the app's entire set
    /// of instructions. Dropping it would be silently removing the assistant.
    func testGemmaFoldsTheSystemPromptIntoTheUserTurn() {
        let rendered = LocalChatTemplate.gemma.render(turns)
        XCTAssertFalse(rendered.contains("<start_of_turn>system"))
        XCTAssertTrue(rendered.contains("You are a helpful assistant."))
        XCTAssertTrue(rendered.contains("What is on today?"))
    }

    func testMistralFoldsTheSystemPromptIntoTheInstruction() {
        let rendered = LocalChatTemplate.mistral.render(turns)
        XCTAssertTrue(rendered.contains("[INST]"))
        XCTAssertTrue(rendered.contains("You are a helpful assistant."))
    }

    /// A system prompt with no user turn after it must not vanish.
    func testATrailingSystemPromptIsStillRendered() {
        for template in [LocalChatTemplate.gemma, .mistral] {
            let rendered = template.render([.system("Remember this.")])
            XCTAssertTrue(
                rendered.contains("Remember this."),
                "\(template) dropped a system prompt"
            )
        }
    }

    func testEveryTemplateHasStopSequences() {
        for template in LocalChatTemplate.allCases {
            XCTAssertFalse(
                template.stopSequences.isEmpty,
                "\(template) has nothing to cut a runaway turn at"
            )
        }
    }

    /// Section 39: guessing from the family beats emitting labelled plain text
    /// at a model trained on markers.
    func testTemplatesAreInferredFromTheArchitecture() {
        XCTAssertEqual(LocalChatTemplate.inferred(fromArchitecture: "gemma3"), .gemma)
        XCTAssertEqual(LocalChatTemplate.inferred(fromArchitecture: "phi3"), .phi3)
        XCTAssertEqual(LocalChatTemplate.inferred(fromArchitecture: "llama"), .llama3)
        XCTAssertEqual(LocalChatTemplate.inferred(fromArchitecture: "qwen3"), .chatML)
        XCTAssertEqual(LocalChatTemplate.inferred(fromArchitecture: "something-new"), .chatML)
    }
}
