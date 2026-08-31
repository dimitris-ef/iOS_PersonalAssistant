import AssistantAI
import AssistantDomain
import Foundation

/// What a local model's raw output turned out to be, under the semantic
/// protocol.
///
/// Section 22. Every generation is classified before any of it can reach the
/// screen; only `chat` and the two fixed failure sentences are ever shown.
public enum LocalSemanticOutcome: Hashable, Sendable {
    /// Ordinary conversation. Safe to show as-is.
    case normalChat(String)
    /// A valid, contract-satisfying action.
    case validSemanticAction(LocalSemanticAction)
    /// An envelope that is there and wrong.
    case malformedSemanticAction(reason: String)
    /// The model described the protocol instead of using it (section 31).
    case protocolLeak(reason: String)
    /// The model reached for the *internal* tool schema (section 32).
    case internalToolProtocolLeak(reason: String)
    /// A named intent that is not in the protocol.
    case unsupportedSemanticIntent(String)
    /// A structurally fine envelope carrying implementation details.
    case forbiddenImplementationDetails(LocalSemanticValidationFailure)
    /// Nothing usable, and repair is spent or ruled out.
    case failedActionAttempt(reason: String)

    /// Whether one constrained repair is worth spending (sections 33, 34).
    public var isRepairable: Bool {
        switch self {
        case .malformedSemanticAction, .protocolLeak, .internalToolProtocolLeak,
             .unsupportedSemanticIntent, .forbiddenImplementationDetails:
            return true
        case .normalChat, .validSemanticAction, .failedActionAttempt:
            return false
        }
    }

    /// For the diagnostic log only, never the screen.
    public var symbol: String {
        switch self {
        case .normalChat: return "normalChat"
        case .validSemanticAction: return "validSemanticAction"
        case .malformedSemanticAction: return "malformedSemanticAction"
        case .protocolLeak: return "protocolLeak"
        case .internalToolProtocolLeak: return "internalToolProtocolLeak"
        case .unsupportedSemanticIntent: return "unsupportedSemanticIntent"
        case .forbiddenImplementationDetails: return "forbiddenImplementationDetails"
        case .failedActionAttempt: return "failedActionAttempt"
        }
    }
}

/// Reads a generation and decides what it was.
///
/// ## Strict on purpose
///
/// Section 29. The parser accepts one envelope shape and rejects everything
/// else rather than repairing it in place. A best-effort read of a half-formed
/// action is how an invented title and a 2023 due date get executed: each
/// individual guess looks locally reasonable and the result is an action the
/// user never asked for.
public struct LocalSemanticActionParser: Sendable {

    public init() {}

    /// Classifies one generation.
    ///
    /// `expectsAction` is what separates a legitimate explanation from a leak.
    /// Somebody asking "how do reminders work?" may be answered with the word
    /// `reminder.create`; the same sentence in reply to "remind me in ten
    /// minutes" is the model narrating the protocol instead of using it.
    public func classify(
        _ raw: String,
        expectsAction: Bool,
        detectedCategory: LocalActionCategory = .other
    ) -> LocalSemanticOutcome {
        let cleaned = LocalToolPromptAdapter.stripCodeFence(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else {
            return expectsAction
                ? .malformedSemanticAction(reason: "empty output")
                : .normalChat("")
        }

        guard let range = Self.envelopeRange(in: cleaned) else {
            // No envelope. For a plain question that is the whole answer.
            guard expectsAction else { return .normalChat(cleaned) }
            // Abandoned JSON first. An envelope that stops mid-object still
            // contains the word `arguments`, which is also what a model reciting
            // the internal tool schema produces — and calling a truncated
            // generation a schema leak points at the wrong fix. This ordering
            // is the same lesson the tool parser learned.
            if Self.hasUnclosedBrace(cleaned) {
                return .malformedSemanticAction(reason: "unfinished JSON")
            }
            if let leak = Self.internalToolLeakReason(in: cleaned) {
                return .internalToolProtocolLeak(reason: leak)
            }
            if let leak = Self.protocolLeakReason(in: cleaned) {
                return .protocolLeak(reason: leak)
            }
            // An action was expected and the model just talked. Section 47 and
            // 49: whatever it said, it did not do anything, and text claiming
            // otherwise must not be shown.
            return .malformedSemanticAction(reason: "prose instead of an action")
        }

        let json = String(cleaned[range])
        guard
            let data = json.data(using: .utf8),
            let decoded = try? JSONCoding.decoder.decode(JSONValue.self, from: data),
            let object = decoded.objectValue
        else {
            return .malformedSemanticAction(reason: "invalid JSON")
        }

        guard let intentName = object["intent"]?.stringValue, !intentName.isEmpty else {
            return .malformedSemanticAction(reason: "missing intent")
        }
        guard let intent = LocalSemanticIntent(rawValue: intentName) else {
            // Section 101: an invented action such as `calendar.fix`.
            return .unsupportedSemanticIntent(intentName)
        }
        if intent == .chat {
            let message = object["message"]?.stringValue
                ?? object["text"]?.stringValue
                ?? ""
            return .normalChat(message)
        }

        let rawArguments = object["arguments"]?.objectValue ?? [:]
        var arguments: [LocalSemanticField: String] = [:]
        for (key, value) in rawArguments {
            if key == "requestedChanges" { continue }
            switch Self.field(for: key) {
            case .known(let field):
                guard let text = value.stringValue else {
                    return .malformedSemanticAction(reason: "\(key) is not text")
                }
                arguments[field] = text.trimmingCharacters(in: .whitespacesAndNewlines)
            case .forbidden(let category):
                return .forbiddenImplementationDetails(
                    .forbiddenImplementationDetail(field: key, category: category)
                )
            case .unknown:
                return .forbiddenImplementationDetails(.unknownArgument(key))
            }
        }

        var changes: [LocalSemanticField: String] = [:]
        let rawChanges = rawArguments["requestedChanges"]?.objectValue
            ?? object["requestedChanges"]?.objectValue
            ?? [:]
        for (key, value) in rawChanges {
            switch Self.field(for: key) {
            case .known(let field):
                guard let text = value.stringValue else {
                    return .malformedSemanticAction(reason: "\(key) is not text")
                }
                changes[field] = text.trimmingCharacters(in: .whitespacesAndNewlines)
            case .forbidden(let category):
                return .forbiddenImplementationDetails(
                    .forbiddenImplementationDetail(field: key, category: category)
                )
            case .unknown:
                return .forbiddenImplementationDetails(.unknownArgument(key))
            }
        }

        let action = LocalSemanticAction(
            intent: intent, arguments: arguments, requestedChanges: changes
        )
        if let failure = LocalSemanticValidator.validate(
            action, detectedCategory: detectedCategory
        ) {
            switch failure {
            case .forbiddenImplementationDetail, .unknownArgument,
                 .fieldNotAllowedForIntent, .absoluteTimestampSupplied:
                return .forbiddenImplementationDetails(failure)
            default:
                return .malformedSemanticAction(reason: failure.symbol)
            }
        }
        return .validSemanticAction(action)
    }

    // MARK: Field lookup

    enum FieldLookup {
        case known(LocalSemanticField)
        case forbidden(String)
        case unknown
    }

    static func field(for key: String) -> FieldLookup {
        if let field = LocalSemanticField(rawValue: key) { return .known(field) }
        if let category = LocalSemanticForbiddenField.category(of: key) {
            return .forbidden(category)
        }
        return .unknown
    }

    // MARK: Leak detection

    /// Names of the app's real internal tools. A model producing these has gone
    /// back to the schema the semantic protocol exists to hide (section 32).
    static let internalToolNames: [String] = ToolKind.allCases.map { $0.rawValue.lowercased() }

    static func internalToolLeakReason(in text: String) -> String? {
        let lowered = text.lowercased()
        if let name = internalToolNames.first(where: { lowered.contains($0) }) {
            return "named internal tool \(name)"
        }
        if lowered.contains("tool_calls") || lowered.contains("\"arguments\"") {
            return "internal tool envelope"
        }
        return nil
    }

    /// Words that appear when a model recites the semantic protocol rather than
    /// using it.
    static let protocolVocabulary = [
        "reminder.create", "memory.store", "task.create", "task.complete",
        "calendar.create", "calendar.update",
        "timeexpression", "targetdescription", "requestedchanges",
        "semantic action", "the schema", "allowed fields", "\"intent\"",
    ]

    static func protocolLeakReason(in text: String) -> String? {
        let lowered = text.lowercased()
        let hits = protocolVocabulary.filter { lowered.contains($0) }
        guard let first = hits.first else { return nil }
        return "protocol vocabulary (\(first))"
    }

    static func hasUnclosedBrace(_ text: String) -> Bool {
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

    /// The first balanced `{…}` that names an intent.
    ///
    /// Brace matching rather than a regular expression, for the same reason the
    /// tool parser uses it: arguments nest, and strings can contain braces.
    static func envelopeRange(in text: String) -> Range<String.Index>? {
        var depth = 0
        var start: String.Index?
        var inString = false
        var escaped = false
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
            } else {
                switch character {
                case "\"": inString = true
                case "{":
                    if depth == 0 { start = index }
                    depth += 1
                case "}":
                    depth -= 1
                    if depth == 0, let opening = start {
                        let range = opening..<text.index(after: index)
                        if text[range].contains("\"intent\"") { return range }
                        start = nil
                    }
                    if depth < 0 { return nil }
                default: break
                }
            }
            index = text.index(after: index)
        }
        return nil
    }
}
