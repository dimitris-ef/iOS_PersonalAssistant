import AssistantDomain
import Foundation

/// Everything the action model is given, and nothing else.
///
/// ## Why this is not an `AIRequest`
///
/// Section 8 and 21. An `AIRequest` carries the assembled system prompt, the
/// retrieved memories, the whole conversation and the app's real tool schemas.
/// An action model needs none of that to turn "remind me in ten minutes to
/// change the bottles" into `reminder.create(title, timeExpression)`, and every
/// one of those things is either a privacy cost or an invitation to fabricate:
/// a model shown `relatedTaskID` will eventually fill one in.
///
/// It is also what makes a tiny specialised model possible later. A model that
/// only ever sees a sentence and a clock can be small; one that has to read a
/// conversation cannot.
///
/// What is deliberately absent: resource identifiers, EventKit identifiers,
/// `AIToolCall` schemas, conversation history, credentials, and any
/// application internals.
public struct ActionModelRequest: Hashable, Sendable {
    /// The sentence to interpret. The user's own words, unmodified.
    public var userRequest: String
    /// The clock the expression will be resolved against.
    ///
    /// Supplied so a model that wants to reason about "tomorrow" can, and so
    /// the request is reproducible in a test. It does **not** license the model
    /// to produce a timestamp: the protocol has no field for one, and
    /// `LocalTimeExpressionResolver` still owns the arithmetic.
    public var now: Date
    public var timeZoneIdentifier: String
    /// The app's own reading of the request's family, from the router.
    ///
    /// A hint for the backend and for the semantic validator's family check.
    /// It never chooses the intent.
    public var detectedCategory: LocalActionCategory
    /// The intents this build will accept. The protocol, made explicit rather
    /// than assumed, so a backend cannot be asked for something the resolver
    /// has no case for.
    public var allowedIntents: Set<LocalSemanticIntent>

    public init(
        userRequest: String,
        now: Date,
        timeZoneIdentifier: String = TimeZone.current.identifier,
        detectedCategory: LocalActionCategory = .other,
        allowedIntents: Set<LocalSemanticIntent> = Set(
            LocalSemanticIntent.allCases.filter(\.isAction)
        )
    ) {
        self.userRequest = userRequest
        self.now = now
        self.timeZoneIdentifier = timeZoneIdentifier
        self.detectedCategory = detectedCategory
        self.allowedIntents = allowedIntents
    }
}

/// What an action model produced.
///
/// Section 9: the existing `LocalSemanticAction`, and no second format. A
/// backend that invented its own representation would need its own validator,
/// its own resolver and its own forbidden-field rules, which is the whole of
/// the Universal Local Action Protocol written twice.
public enum LocalSemanticActionResult: Hashable, Sendable {
    case action(LocalSemanticAction)
    /// The backend read the request and found nothing to do. The message, if
    /// any, is the backend's own words.
    case noActionNeeded(message: String)
}

/// Whether the action system can be used at all.
public enum ActionModelAvailability: Hashable, Sendable {
    case available
    case unavailable(reason: String)

    public var isAvailable: Bool { self == .available }

    public var reason: String? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }

    /// For the diagnostic line (section 23).
    public var symbol: String { isAvailable ? "available" : "unavailable" }
}

/// Why an action model could not produce a semantic action.
///
/// The cases are the structured reasons section 25 asks to be logged, which is
/// why they are an enum rather than a string: a free-text reason is a reason
/// somebody has to grep for, and one that could carry the user's sentence into
/// a log by accident.
public enum ActionModelError: Error, Hashable, Sendable, CustomStringConvertible {
    case backendUnavailable(String)
    case generationFailed(String)
    case semanticParsingFailed(String)
    case semanticValidationFailed(String)

    /// The symbol written to diagnostics. Never the associated detail, which is
    /// authored text and stays for the developer-facing error only.
    public var symbol: String {
        switch self {
        case .backendUnavailable: return "backendUnavailable"
        case .generationFailed: return "generationFailed"
        case .semanticParsingFailed: return "semanticParsingFailed"
        case .semanticValidationFailed: return "semanticValidationFailed"
        }
    }

    public var description: String {
        switch self {
        case .backendUnavailable(let detail): return "action backend unavailable: \(detail)"
        case .generationFailed(let detail): return "action generation failed: \(detail)"
        case .semanticParsingFailed(let detail): return "semantic parsing failed: \(detail)"
        case .semanticValidationFailed(let detail):
            return "semantic validation failed: \(detail)"
        }
    }
}

/// The model that interprets phone actions.
///
/// ## Why this is separate from `AIProvider`
///
/// Section 7 and 11. `AIProvider` is a conversation: a system prompt, a history,
/// tools, free text back. This is one narrow job — a sentence in, a semantic
/// action out — and the two have been conflated until now, with the consequence
/// that picking a chat model decided whether the phone could be operated.
///
/// Keeping them apart is what lets the answer to "which model do I want to talk
/// to?" stop being the answer to "can this app set a reminder?".
///
/// ## Deliberately model-agnostic
///
/// Nothing in this protocol names llama.cpp, GGUF, a chat template, a model
/// family, Apple Foundation Models or OpenAI. A conforming backend may be any
/// of those, a remote service, a rules engine, or — the point of the exercise —
/// a small model trained for this and nothing else. The only contract is a
/// `LocalSemanticAction`.
///
/// ## What a backend must never do
///
/// Section 18. It produces a semantic action. It does not call EventKit,
/// schedule a notification, write to SwiftData, touch reminders or mutate a
/// task. It cannot reach any of those: this protocol hands it a struct of
/// strings and a date and takes a semantic action back.
public protocol ActionModelProvider: Sendable {
    /// Stable identifier, for diagnostics and for registry selection.
    var id: String { get }

    /// Cheap enough to call before every routed message.
    func availability() async -> ActionModelAvailability

    func generateSemanticAction(
        request: ActionModelRequest
    ) async throws -> LocalSemanticActionResult
}
