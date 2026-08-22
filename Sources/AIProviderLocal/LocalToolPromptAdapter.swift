import AssistantAI
import AssistantDomain
import Foundation

/// What a local model's raw output turned out to mean.
public struct LocalModelOutput: Hashable, Sendable {
    /// What to show the user. Never parsed for behaviour.
    public var text: String
    /// Actions the model is asking the application to consider.
    public var toolCalls: [AIToolCall]

    public init(text: String, toolCalls: [AIToolCall] = []) {
        self.text = text
        self.toolCalls = toolCalls
    }
}

/// Why a local model's output could not be used.
public enum LocalToolParseError: Error, Hashable, Sendable, CustomStringConvertible {
    /// There is an envelope, and it is not valid JSON.
    case malformedJSON(String)
    /// Valid JSON, wrong shape.
    case malformedEnvelope(String)
    /// A call names a tool that was not offered.
    case unknownTool(String)
    /// Arguments are not an object.
    case invalidArguments(tool: String)
    /// More calls than the turn allows.
    case tooManyCalls(count: Int, limit: Int)

    public var description: String {
        switch self {
        case .malformedJSON(let detail):
            return "The local model's structured output was not valid JSON: \(detail)"
        case .malformedEnvelope(let detail):
            return "The local model's structured output had the wrong shape: \(detail)"
        case .unknownTool(let name):
            return "The local model asked for a tool that does not exist: \(name)"
        case .invalidArguments(let tool):
            return "The local model's arguments for \(tool) were not an object."
        case .tooManyCalls(let count, let limit):
            return "The local model proposed \(count) actions in one turn; the limit is \(limit)."
        }
    }
}

/// Turns the app's tool catalogue into instructions a local model can follow,
/// and its answer back into ``AIToolCall``s.
///
/// ## Why this exists rather than a native tool API
///
/// Small local models mostly have no tool-calling API — and where they do, its
/// shape differs per family and per fine-tune. What every instruct model can do
/// is follow an instruction to emit JSON. So the app describes its *existing*
/// tool schemas (section 53: the same `AIToolSchema` the cloud adapter and the
/// Foundation Models adapter are given, never a second catalogue) as text, and
/// parses the answer strictly.
///
/// ## The safety property
///
/// Section 52 is the one that matters, and it is structural rather than
/// promised: this type produces `AIToolCall` values and has no capacity to do
/// anything else. It cannot import a platform service — `AIProviderLocal`
/// depends on `AssistantDomain` and `AssistantAI` and nothing else, so
/// `EventKit`, `UserNotifications` and every repository are simply not in
/// scope. A call it produces is exactly as untrusted as one from the cloud
/// model, goes through the same decoding, validation, authorization and
/// confirmation, and is executed — if at all — by `AgentRunner`.
///
/// ## Strictness
///
/// Section 57. The parser rejects rather than repairs: unknown tool name,
/// non-object arguments, too many calls, unparseable JSON. A model that gets
/// the syntax wrong gets an error the turn can report, never a best-effort
/// guess about which action it meant.
public struct LocalToolPromptAdapter: Sendable {
    /// Hard ceiling on calls per response, independent of the turn's own budget.
    public var maximumCallsPerResponse: Int

    public init(maximumCallsPerResponse: Int = 8) {
        self.maximumCallsPerResponse = maximumCallsPerResponse
    }

    // MARK: Prompting

    /// The instruction block appended to the system prompt when tools are on
    /// offer.
    ///
    /// Deliberately terse. A small model has a small context and a smaller
    /// attention budget, and every paragraph of protocol here is a paragraph
    /// not spent on the user's actual memory and tasks.
    public func instructions(for tools: [AIToolSchema]) -> String {
        guard !tools.isEmpty else { return "" }

        var lines: [String] = []
        lines.append("## Actions")
        lines.append("")
        lines.append(
            "You can ask the app to carry out actions. You never perform them yourself: "
                + "you propose them, and the app validates, authorizes and runs them."
        )
        lines.append("")
        lines.append("Available actions:")
        for tool in tools.sorted(by: { $0.name < $1.name }) {
            lines.append("")
            lines.append("### \(tool.name)")
            lines.append(tool.description)
            lines.append("Parameters: \(compactSchema(tool.parameters))")
        }
        lines.append("")
        lines.append("To propose actions, reply with a single JSON object and nothing else:")
        lines.append("")
        lines.append(Self.envelopeExample)
        lines.append("")
        lines.append(
            "Rules: use only the action names listed above; include every required "
                + "parameter; put what you want to say to the person in \"message\". "
                + "If no action is needed, reply with ordinary text and no JSON."
        )
        return lines.joined(separator: "\n")
    }

    static let envelopeExample = """
        {"tool_calls":[{"name":"createTask","arguments":{"title":"Call the dentist"}}],\
        "message":"I'll add that."}
        """

    /// Renders the envelope this adapter asks a model to produce.
    ///
    /// Used for two things, both of which need the *same* shape the parser
    /// accepts: replaying an earlier assistant turn into a continuation round
    /// (section 60), and letting the mock runtime produce output that exercises
    /// the real parser rather than bypassing it.
    public static func renderEnvelope(
        calls: [AIToolCall],
        message: String
    ) -> String {
        let rendered: [JSONValue] = calls.map { call in
            .object(["name": .string(call.name), "arguments": call.arguments])
        }
        let envelope = JSONValue.object([
            "tool_calls": .array(rendered),
            "message": .string(message),
        ])
        guard
            let data = try? JSONCoding.encoder.encode(envelope),
            let text = String(data: data, encoding: .utf8)
        else {
            return message
        }
        return text
    }

    /// A JSON Schema rendered as one compact line.
    ///
    /// Pretty-printed schemas are easier for a person to read and much worse
    /// for a 1B model: they spend tokens on whitespace and give the model more
    /// opportunities to lose its place. This is the same `JSONSchema` the other
    /// providers get, rendered smaller.
    func compactSchema(_ schema: JSONSchema) -> String {
        let value = schema.jsonValue()
        guard
            let data = try? JSONCoding.encoder.encode(value),
            let text = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return text
    }

    // MARK: Parsing

    /// Reads a model's raw output.
    ///
    /// Three outcomes:
    ///
    /// - No envelope at all → the whole output is the reply. This is the normal
    ///   case for a chat turn and for a text-only model, and treating it as an
    ///   error would make every ordinary sentence a failure.
    /// - A well-formed envelope → text plus validated calls.
    /// - An envelope that is present and wrong → an error. Section 57: the app
    ///   would rather report a structured-output failure than guess at what a
    ///   half-written action meant.
    public func parse(
        _ raw: String,
        offeredTools: [AIToolSchema],
        maximumCalls: Int? = nil
    ) throws -> LocalModelOutput {
        let cleaned = Self.stripCodeFence(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = Self.envelopeRange(in: cleaned) else {
            return LocalModelOutput(text: cleaned)
        }

        let json = String(cleaned[range])
        guard let data = json.data(using: .utf8) else {
            throw LocalToolParseError.malformedJSON("the output was not valid text")
        }

        let envelope: JSONValue
        do {
            envelope = try JSONCoding.decoder.decode(JSONValue.self, from: data)
        } catch {
            throw LocalToolParseError.malformedJSON(error.localizedDescription)
        }
        guard let object = envelope.objectValue else {
            throw LocalToolParseError.malformedEnvelope("expected a JSON object")
        }

        // Prose either side of the envelope is kept when the envelope carries
        // no message of its own. A small model that writes "Sure! {json}" has
        // still said something, and throwing it away leaves the user with a
        // blank reply.
        let surrounding = (cleaned[cleaned.startIndex..<range.lowerBound]
            + cleaned[range.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let message = object["message"]?.stringValue
            ?? object["text"]?.stringValue
            ?? surrounding

        guard let rawCalls = object["tool_calls"] ?? object["toolCalls"] else {
            // An object with a message and no calls is a perfectly good reply —
            // some models wrap everything in JSON out of habit.
            return LocalModelOutput(text: message)
        }
        guard let callArray = rawCalls.arrayValue else {
            if case .null = rawCalls { return LocalModelOutput(text: message) }
            throw LocalToolParseError.malformedEnvelope("\"tool_calls\" must be a list")
        }

        let limit = min(maximumCalls ?? maximumCallsPerResponse, maximumCallsPerResponse)
        guard callArray.count <= limit else {
            throw LocalToolParseError.tooManyCalls(count: callArray.count, limit: limit)
        }

        let known = Set(offeredTools.map(\.name))
        var calls: [AIToolCall] = []
        for entry in callArray {
            guard let call = entry.objectValue else {
                throw LocalToolParseError.malformedEnvelope("each action must be an object")
            }
            guard let name = (call["name"] ?? call["tool"])?.stringValue, !name.isEmpty else {
                throw LocalToolParseError.malformedEnvelope("an action is missing its name")
            }
            guard known.contains(name) else {
                throw LocalToolParseError.unknownTool(name)
            }

            let rawArguments = call["arguments"] ?? call["parameters"] ?? .object([:])
            let arguments: JSONValue
            switch rawArguments {
            case .object:
                arguments = rawArguments
            case .null:
                arguments = .object([:])
            case .string(let text):
                // Some models emit arguments as a JSON *string*. Decoding it is
                // not repair — the content is unambiguous — but a string that
                // is not JSON is still a failure rather than a shrug.
                guard
                    let nested = text.data(using: .utf8),
                    let decoded = try? JSONCoding.decoder.decode(JSONValue.self, from: nested),
                    decoded.objectValue != nil
                else {
                    throw LocalToolParseError.invalidArguments(tool: name)
                }
                arguments = decoded
            default:
                throw LocalToolParseError.invalidArguments(tool: name)
            }

            // The identifier is minted here, by the app. A model-supplied call
            // id would be a model-supplied handle into the execution ledger,
            // and the ledger is what stops the same action running twice.
            calls.append(AIToolCall(name: name, arguments: arguments))
        }

        return LocalModelOutput(text: message, toolCalls: calls)
    }

    /// Removes a ```json fence, which models add whether or not asked.
    static func stripCodeFence(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("```") else { return raw }
        if let firstNewline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: firstNewline)...])
        }
        if let fence = text.range(of: "```", options: .backwards) {
            text = String(text[text.startIndex..<fence.lowerBound])
        }
        return text
    }

    /// Locates the envelope: the first balanced `{…}` that mentions a call list.
    ///
    /// Brace matching rather than a regular expression, because tool arguments
    /// contain nested objects and a non-greedy match stops at the first inner
    /// `}`. Strings are tracked so a `}` inside a task title does not end the
    /// object early.
    static func envelopeRange(in text: String) -> Range<String.Index>? {
        var depth = 0
        var start: String.Index?
        var inString = false
        var escaped = false

        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else {
                switch character {
                case "\"":
                    inString = true
                case "{":
                    if depth == 0 { start = index }
                    depth += 1
                case "}":
                    depth -= 1
                    if depth == 0, let opening = start {
                        let range = opening..<text.index(after: index)
                        let candidate = text[range]
                        // Only an object that claims to carry actions counts.
                        // A model that mentions `{"date": …}` in prose has not
                        // proposed anything, and treating that as a malformed
                        // envelope would turn ordinary sentences into errors.
                        if candidate.contains("tool_calls") || candidate.contains("toolCalls") {
                            return range
                        }
                        // Not the envelope. Keep looking rather than giving up:
                        // "Sure — {\"date\":1}. {\"tool_calls\":[…]}" has one of
                        // each, and stopping at the first would miss the action.
                        start = nil
                    }
                    if depth < 0 { return nil }
                default:
                    break
                }
            }
            index = text.index(after: index)
        }
        return nil
    }
}
