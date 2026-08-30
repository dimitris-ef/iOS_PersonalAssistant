import AssistantAI
import AssistantDomain
import Foundation

/// What a local model's raw output actually was.
///
/// ## Why a classification and not a string
///
/// The regression this exists for: a user typed
///
/// > Remind me something in 10 minutes.
///
/// and the reply on screen was prose about an `updateCalendarEvent` schema, an
/// `eventID` parameter, `type: object`, and a complaint about a malformed UUID.
///
/// The parser at the time had two answers — "here is an envelope" or "there is
/// no envelope, so this is a normal reply" — and schema prose has no envelope.
/// So it went through the second door and straight to the screen. There was no
/// state in which the app could notice that the model had been asked to *do*
/// something and had instead described its own tool protocol.
///
/// That state is this type. Raw output is classified before anything becomes
/// user-visible, and only ``text`` and the two failure sentences are things a
/// person ever reads.
public enum LocalAssistantOutcome: Hashable, Sendable {
    /// An ordinary reply. Safe to show.
    case text(String)
    /// A valid structured request, plus whatever the model said alongside it.
    case toolCalls(calls: [AIToolCall], message: String)
    /// The model tried to produce an action and got the syntax wrong.
    case malformedToolAttempt(reason: String)
    /// The model described the tool protocol instead of using it. Section 21.
    case schemaLeak(reason: String)
    /// Nothing usable, and repairing it has already been tried or ruled out.
    case failure(reason: String)

    /// Whether one constrained repair is worth attempting (section 22).
    public var isRepairable: Bool {
        switch self {
        case .malformedToolAttempt, .schemaLeak: return true
        case .text, .toolCalls, .failure: return false
        }
    }

    /// The internal reason, for the diagnostic log only — never the screen.
    public var diagnosticSymbol: String {
        switch self {
        case .text: return "text"
        case .toolCalls: return "toolCalls"
        case .malformedToolAttempt: return "malformedToolAttempt"
        case .schemaLeak: return "schemaLeak"
        case .failure: return "failure"
        }
    }
}

/// Reads raw local-model output and decides what it was.
///
/// ## Not a second tool protocol
///
/// Section 9. The tools, their names and their schemas all still come from
/// `ToolCatalog` by way of `AIToolSchema`; this only classifies what came back.
/// It produces `AIToolCall` values and cannot do anything else — `AIProviderLocal`
/// depends on `AssistantDomain` and `AssistantAI` and nothing else, so EventKit,
/// UserNotifications and every repository are out of scope by construction
/// (section 54). Everything it returns is exactly as untrusted as cloud output
/// and goes through the same decoding, validation, authorization and
/// confirmation.
public struct LocalToolCallParser: Sendable {

    private let adapter: LocalToolPromptAdapter

    public init(adapter: LocalToolPromptAdapter = LocalToolPromptAdapter()) {
        self.adapter = adapter
    }

    /// Classifies one generation.
    ///
    /// `expectsAction` is what makes schema prose distinguishable from a
    /// legitimate answer. Section 5: if somebody asks *how the calendar tool
    /// works*, an explanation naming `updateCalendarEvent` is the correct reply
    /// and censoring it would be a bug. The same sentence in response to "remind
    /// me in ten minutes" is the model narrating its own protocol instead of
    /// following it.
    public func classify(
        _ raw: String,
        offeredTools: [AIToolSchema],
        expectsAction: Bool,
        maximumCalls: Int? = nil
    ) -> LocalAssistantOutcome {
        let cleaned = LocalToolPromptAdapter.stripCodeFence(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else {
            return expectsAction
                ? .malformedToolAttempt(reason: "the model produced nothing")
                : .text("")
        }

        // The happy path, and the ordinary-chat path, both go through the
        // existing strict parser. Section 19: when it finds a valid envelope
        // inside prose it returns the calls and the message, and the wrapper is
        // never shown as-is.
        do {
            let parsed = try adapter.parse(
                cleaned, offeredTools: offeredTools, maximumCalls: maximumCalls
            )
            if !parsed.toolCalls.isEmpty {
                return .toolCalls(calls: parsed.toolCalls, message: parsed.text)
            }
            // No calls. Either an ordinary reply, or — for an action request —
            // possibly the model describing the tools instead of calling them.
            //
            // Order matters. An envelope the model started and did not finish
            // contains `tool_calls` and a real tool name, which is also what a
            // recital of the protocol looks like; the difference is the unclosed
            // brace, so that is tested first. Calling a truncated call a "schema
            // leak" would be an accurate-sounding wrong diagnosis in the log.
            if expectsAction, Self.looksLikeAbandonedJSON(cleaned) {
                return .malformedToolAttempt(reason: "an unfinished JSON object")
            }
            if expectsAction, let leak = Self.schemaLeakReason(in: parsed.text, tools: offeredTools) {
                return .schemaLeak(reason: leak)
            }
            return .text(parsed.text)
        } catch let error as LocalToolParseError {
            // Section 20 and 50. There *was* an envelope and it was wrong. The
            // detail is kept for the log; the user never sees it.
            switch error {
            case .unknownTool(let name):
                return .malformedToolAttempt(reason: "unknown tool \(name)")
            default:
                return .malformedToolAttempt(reason: error.description)
            }
        } catch {
            return .malformedToolAttempt(reason: "unrecognised output")
        }
    }

    // MARK: Schema leakage

    /// Words that only appear when a model is reciting a JSON Schema rather
    /// than using one.
    ///
    /// Deliberately about *schema vocabulary*, not tool names. A reply that says
    /// "I'll update your dentist appointment" mentions no schema; a reply that
    /// says "`updateCalendarEvent` takes an `eventID` of `type: string`,
    /// `format: uuid`" is quoting the protocol back.
    static let schemaVocabulary = [
        "\"type\":", "type: object", "type:object", "\"properties\"", "properties:",
        "\"required\"", "required:", "format: uuid", "\"format\"", "json schema",
        "\"parameters\"", "parameters:", "\"arguments\"", "argument schema",
        "tool_calls", "toolcalls", "the schema", "schema requires", "schema expects",
    ]

    /// Whether this reply is the model narrating its tool protocol.
    ///
    /// Two independent signals have to agree: the text names a real tool, *and*
    /// it uses schema vocabulary. Either alone is too weak — a normal
    /// confirmation may well name the action it took, and a reply about a
    /// "format" may be about a date format.
    static func schemaLeakReason(in text: String, tools: [AIToolSchema]) -> String? {
        let lowered = text.lowercased()
        guard !lowered.isEmpty else { return nil }

        let namedTool = tools.first { lowered.contains($0.name.lowercased()) }
        let vocabulary = schemaVocabulary.first { lowered.contains($0) }

        if let namedTool, let vocabulary {
            return "named \(namedTool.name) with schema vocabulary (\(vocabulary))"
        }
        // A reply that quotes several pieces of schema vocabulary is reciting a
        // schema whether or not it managed to name a tool correctly — which is
        // exactly what a model that invented `updateCalendarEvent`'s parameters
        // would do.
        let matches = schemaVocabulary.filter { lowered.contains($0) }
        if matches.count >= 2 {
            return "schema vocabulary (\(matches.prefix(2).joined(separator: ", ")))"
        }
        return nil
    }

    /// An opening brace with no matching close — a tool call the model started
    /// and did not finish. Section 20's example.
    static func looksLikeAbandonedJSON(_ text: String) -> Bool {
        guard text.contains("{") else { return false }
        var depth = 0
        var inString = false
        var escaped = false
        for character in text {
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
                continue
            }
            switch character {
            case "\"": inString = true
            case "{": depth += 1
            case "}": depth -= 1
            default: break
            }
        }
        return depth > 0
    }
}

/// Whether the person asked for something to be *done*.
///
/// ## Why this is a heuristic and why that is acceptable here
///
/// It never decides what happens — only whether raw output is allowed through
/// unclassified. A false positive costs a schema-leak check on an ordinary
/// sentence, which passes. A false negative costs the containment this pass
/// exists for. So it is tuned to notice actions, and every path out of it still
/// goes through the same validation and authorization.
///
/// It deliberately does **not** choose a tool (section 34: no second business
/// -logic router). The model still decides that.
public enum LocalActionIntent {

    /// Phrases that ask for something to happen, rather than about something.
    static let actionPhrases = [
        "remind me", "remind us", "set a reminder", "reminder for", "reminder in",
        "wake me", "set an alarm", "alarm for", "alarm in",
        "add an event", "add event", "put in my calendar", "add to my calendar",
        "schedule ", "book ", "create ", "make a note", "add a task", "add task",
        "move my", "reschedule", "cancel my", "delete my", "change my",
        "mark ", "complete ", "finish ",
        "remember that", "note that",
    ]

    /// Phrases that mean the person is asking *about* the system rather than
    /// asking it to act. Section 5 — these keep legitimate technical discussion
    /// out of the containment path.
    static let inquiryPhrases = [
        "how do you", "how does", "what tools", "which tools", "what is the schema",
        "what does the schema", "explain the", "how would you", "can you explain",
        "what parameters", "show me the schema", "what format",
    ]

    /// True when the latest user message reads like a request to act.
    public static func isLikely(in messages: [AIMessage]) -> Bool {
        guard let latest = messages.last(where: { $0.role == .user }) else { return false }
        return isLikely(in: latest.content)
    }

    public static func isLikely(in text: String) -> Bool {
        let lowered = text.lowercased()
        guard !lowered.isEmpty else { return false }
        // Asking about the machinery wins over the action words inside the
        // question: "how do you create a reminder?" contains "create ".
        if inquiryPhrases.contains(where: { lowered.contains($0) }) { return false }
        return actionPhrases.contains(where: { lowered.contains($0) })
    }
}
