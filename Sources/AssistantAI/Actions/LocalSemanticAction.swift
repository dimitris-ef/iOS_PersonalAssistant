import AssistantDomain
import Foundation

/// What a local model is allowed to ask the app to do.
///
/// ## Why a second, smaller protocol exists
///
/// A 3B model on a phone was asked to fill in `createReminder`'s real schema
/// and produced a fabricated `relatedTaskID`, a due date from 2023, an invented
/// title, an invented list name, invented notes, and a made-up explanation that
/// the data was corrupted — most of which reached the screen.
///
/// None of that is a prompting failure to be tuned away. It is what happens
/// when a small model is handed a form with fields it has no way to fill and no
/// way to leave blank convincingly. Every fabricated value in that report is a
/// field the model should never have been shown.
///
/// So the model-facing protocol is not the internal tool schema. It is this:
/// seven intents, six possible fields, all of them things a person actually
/// said. Everything else — identifiers, timestamps, list choices, defaults — is
/// the app's job, decided deterministically after the model has finished.
///
/// ## Provider-neutral on purpose
///
/// Section 55. Nothing here mentions llama.cpp, GGUF, a chat template or a
/// model family. A model-specific adapter may translate whatever a particular
/// template emits, but it translates *into this*, and resolution only ever sees
/// this.
public enum LocalSemanticIntent: String, Hashable, Sendable, Codable, CaseIterable {
    /// No action — ordinary conversation. Present in the protocol so "the model
    /// decided nothing was needed" is a first-class answer rather than a
    /// parse failure.
    case chat = "chat"
    case reminderCreate = "reminder.create"
    case memoryStore = "memory.store"
    case taskCreate = "task.create"
    case taskComplete = "task.complete"
    case calendarCreate = "calendar.create"
    case calendarUpdate = "calendar.update"

    /// One line each, for the model-facing prompt. Section 57 and 58: this is
    /// the entire description a small model gets, and it is deliberately much
    /// smaller than the JSON Schema it replaces.
    public var modelFacingDescription: String {
        switch self {
        case .chat:
            return "Reply normally. No action needed."
        case .reminderCreate:
            return "Create a future reminder. Fields: title, timeExpression."
        case .memoryStore:
            return "Store a lasting fact about the user. Field: content."
        case .taskCreate:
            return "Create a task. Fields: title, optional timeExpression."
        case .taskComplete:
            return "Complete an existing task. Field: targetDescription."
        case .calendarCreate:
            return "Create a calendar event. Fields: title, timeExpression."
        case .calendarUpdate:
            return "Change an existing event. Fields: targetDescription, requestedChanges."
        }
    }

    /// Whether this intent, once resolved, changes anything.
    public var isAction: Bool { self != .chat }

    /// Whether resolving it needs an existing thing found first (sections 16-20).
    public var needsResourceResolution: Bool {
        switch self {
        case .taskComplete, .calendarUpdate: return true
        default: return false
        }
    }
}

/// Every value a local model may supply.
///
/// ## The closed set is the safety property
///
/// This enum is the whole reason the fabricated `relatedTaskID` from the device
/// report cannot happen again — not because a validator rejects it, but because
/// there is no case to put it in. A `LocalSemanticAction` is structurally
/// incapable of carrying an identifier, a timestamp, a list name or a notes
/// field. Rejection is a check somebody can forget to run; unrepresentability
/// is not.
///
/// Note what is absent and why: no `dueDate` (the model gives an expression,
/// the app computes the instant), no `listName` or `calendarName` (deterministic
/// app policy), no `notes` or `priority` (the user did not say them), and
/// nothing ending in ID.
public enum LocalSemanticField: String, Hashable, Sendable, Codable, CaseIterable {
    /// What the thing is called, in the user's words.
    case title
    /// When, as the person said it — "in 10 minutes", "tomorrow at 3".
    /// Section 43: never an absolute timestamp from the model.
    case timeExpression
    /// The fact to remember, in the user's words.
    case content
    /// Which existing thing they meant — "my dentist appointment".
    /// Section 16: a human description, never an identifier.
    case targetDescription
    /// How long, if the user said — "for an hour".
    case durationExpression
    /// Where, if the user said.
    case locationExpression
}

/// One thing the model is asking for.
///
/// Deliberately not `[String: Any]` (section 2). The keys are a closed enum and
/// the values are strings the user is expected to have said, so the type itself
/// carries the contract.
public struct LocalSemanticAction: Hashable, Sendable {
    public var intent: LocalSemanticIntent
    public var arguments: [LocalSemanticField: String]
    /// For `calendar.update` only: what to change about the resolved event.
    public var requestedChanges: [LocalSemanticField: String]

    public init(
        intent: LocalSemanticIntent,
        arguments: [LocalSemanticField: String] = [:],
        requestedChanges: [LocalSemanticField: String] = [:]
    ) {
        self.intent = intent
        self.arguments = arguments
        self.requestedChanges = requestedChanges
    }

    public subscript(field: LocalSemanticField) -> String? { arguments[field] }
}

/// What each intent may and must carry.
///
/// Section 5 and 6: an explicit allowlist per intent, so a field that is legal
/// for one action is not silently legal for another. `timeExpression` belongs
/// on a reminder and on a task; it has no meaning on `memory.store`, and a
/// model that attaches one there has misunderstood the request.
public struct LocalSemanticContract: Hashable, Sendable {
    public var required: Set<LocalSemanticField>
    public var optional: Set<LocalSemanticField>
    /// Fields allowed inside `requestedChanges`. Empty for every intent that
    /// does not take changes.
    public var changeable: Set<LocalSemanticField>

    public var allowed: Set<LocalSemanticField> { required.union(optional) }

    public static func contract(for intent: LocalSemanticIntent) -> LocalSemanticContract {
        switch intent {
        case .chat:
            return LocalSemanticContract(required: [], optional: [], changeable: [])
        case .reminderCreate:
            // Exactly the two things "remind me in 10 minutes to change
            // bottles" contains, and nothing else. Section 7.
            return LocalSemanticContract(
                required: [.title, .timeExpression], optional: [], changeable: []
            )
        case .memoryStore:
            return LocalSemanticContract(required: [.content], optional: [], changeable: [])
        case .taskCreate:
            return LocalSemanticContract(
                required: [.title], optional: [.timeExpression], changeable: []
            )
        case .taskComplete:
            return LocalSemanticContract(
                required: [.targetDescription], optional: [], changeable: []
            )
        case .calendarCreate:
            return LocalSemanticContract(
                required: [.title, .timeExpression],
                optional: [.durationExpression, .locationExpression],
                changeable: []
            )
        case .calendarUpdate:
            return LocalSemanticContract(
                required: [.targetDescription],
                optional: [],
                changeable: [.timeExpression, .durationExpression, .locationExpression, .title]
            )
        }
    }
}

/// Why a semantic action could not be used.
public enum LocalSemanticValidationFailure: Hashable, Sendable, CustomStringConvertible {
    case unsupportedIntent(String)
    /// A key that is not in the protocol at all.
    case unknownArgument(String)
    /// A key that names an implementation detail — an identifier, a timestamp,
    /// a storage location. Section 21, and tracked separately from
    /// `unknownArgument` because it means something different: the model is
    /// reaching for the internal schema, not mistyping a field.
    case forbiddenImplementationDetail(field: String, category: String)
    case missingRequired(LocalSemanticField)
    /// A field that is legal in the protocol but not for this intent.
    case fieldNotAllowedForIntent(field: LocalSemanticField, intent: LocalSemanticIntent)
    case emptyValue(LocalSemanticField)
    /// The model supplied an absolute timestamp where an expression belongs.
    case absoluteTimestampSupplied(LocalSemanticField)
    /// The model chose an action family the request plainly was not.
    case intentMismatch(detected: String, produced: LocalSemanticIntent)

    public var description: String {
        switch self {
        case .unsupportedIntent(let name): return "unsupported intent \(name)"
        case .unknownArgument(let name): return "unknown argument \(name)"
        case .forbiddenImplementationDetail(let field, let category):
            return "forbidden \(category) field \(field)"
        case .missingRequired(let field): return "missing \(field.rawValue)"
        case .fieldNotAllowedForIntent(let field, let intent):
            return "\(field.rawValue) is not allowed for \(intent.rawValue)"
        case .emptyValue(let field): return "\(field.rawValue) is empty"
        case .absoluteTimestampSupplied(let field):
            return "\(field.rawValue) carried an absolute timestamp"
        case .intentMismatch(let detected, let produced):
            return "request looks like \(detected) but got \(produced.rawValue)"
        }
    }

    /// The short symbol for the diagnostic log (section 65).
    public var symbol: String {
        switch self {
        case .unsupportedIntent: return "unsupportedIntent"
        case .unknownArgument: return "unknownArgument"
        case .forbiddenImplementationDetail: return "forbiddenImplementationField"
        case .missingRequired: return "missingRequiredField"
        case .fieldNotAllowedForIntent: return "fieldNotAllowedForIntent"
        case .emptyValue: return "emptyValue"
        case .absoluteTimestampSupplied: return "absoluteTimestampSupplied"
        case .intentMismatch: return "intentMismatch"
        }
    }
}

/// Recognises keys that name implementation details.
///
/// Section 21. These never reach a `LocalSemanticAction` — the field enum has
/// no case for them — but naming them explicitly turns "unknown key" into
/// "the model is trying to fill in the internal schema", which is a different
/// finding, points at a different fix, and is worth its own line in the log.
public enum LocalSemanticForbiddenField {

    /// Suffixes and names that identify a stored resource.
    static let identifierSuffixes = ["id", "identifier", "uuid", "guid"]

    /// Fields that are real on some internal tool but must not be model-chosen
    /// (sections 3, 7 and 13) — the app decides these or leaves them absent.
    static let applicationOwnedFields: Set<String> = [
        "duedate", "startdate", "enddate", "start", "end", "timestamp", "date",
        "listname", "list", "calendar", "calendarname",
        "notes", "note", "priority", "importance", "url", "alarms",
        "isallday", "recurrence", "status", "completed",
    ]

    /// nil when the key is not a forbidden implementation detail.
    public static func category(of key: String) -> String? {
        let lowered = key.lowercased()
        if identifierSuffixes.contains(where: { lowered.hasSuffix($0) }) {
            return "resourceIdentifier"
        }
        if applicationOwnedFields.contains(lowered) {
            return "applicationOwnedValue"
        }
        return nil
    }
}

/// Validates a parsed action against its contract.
public enum LocalSemanticValidator {

    /// `detectedCategory` is the app's own reading of the user's request, used
    /// only to catch a plain family mismatch (sections 25 to 27) — a reminder
    /// answered with `memory.store`. It never *chooses* the intent.
    public static func validate(
        _ action: LocalSemanticAction,
        detectedCategory: LocalActionCategory = .other
    ) -> LocalSemanticValidationFailure? {
        let contract = LocalSemanticContract.contract(for: action.intent)

        for field in action.arguments.keys where !contract.allowed.contains(field) {
            return .fieldNotAllowedForIntent(field: field, intent: action.intent)
        }
        for field in contract.required where (action.arguments[field] ?? "").isEmpty {
            return action.arguments[field] == nil
                ? .missingRequired(field) : .emptyValue(field)
        }
        for (field, value) in action.arguments
        where value.trimmingCharacters(in: .whitespaces).isEmpty {
            return .emptyValue(field)
        }
        // Section 43: the model may not hand over an instant. It says what the
        // person said; the resolver turns that into a date using the real
        // clock. A model-supplied ISO timestamp is exactly how a 2023 due date
        // reached a 2026 reminder.
        if let expression = action.arguments[.timeExpression],
            LocalSemanticValidator.looksAbsolute(expression) {
            return .absoluteTimestampSupplied(.timeExpression)
        }
        for field in action.requestedChanges.keys where !contract.changeable.contains(field) {
            return .fieldNotAllowedForIntent(field: field, intent: action.intent)
        }
        if action.intent == .calendarUpdate, action.requestedChanges.isEmpty {
            return .missingRequired(.timeExpression)
        }

        // Section 26: a reminder must not become a memory. Only checked when
        // the app is confident about the family, and only in the direction that
        // silently loses the action.
        if detectedCategory == .reminder, action.intent == .memoryStore {
            return .intentMismatch(detected: "reminder", produced: action.intent)
        }
        if detectedCategory == .memory, action.intent == .reminderCreate {
            return .intentMismatch(detected: "memory", produced: action.intent)
        }
        return nil
    }

    /// Whether a time expression is really a machine timestamp.
    ///
    /// Conservative: "in 10 minutes", "tomorrow at 3", "September 5 at 18:00"
    /// all pass, because they are what a person says. `2023-03-15T14:00:00`
    /// does not.
    static func looksAbsolute(_ expression: String) -> Bool {
        let trimmed = expression.trimmingCharacters(in: .whitespaces)
        // ISO-8601-ish: four digits, dash, two digits, dash, two digits.
        let pattern = "^\\d{4}-\\d{2}-\\d{2}([T ]\\d{2}:\\d{2})?"
        return trimmed.range(of: pattern, options: .regularExpression) != nil
    }
}
