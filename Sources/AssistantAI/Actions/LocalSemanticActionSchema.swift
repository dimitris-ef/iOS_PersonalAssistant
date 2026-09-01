import AssistantDomain
import Foundation

/// The shape a generated semantic action is allowed to have.
///
/// ## Derived, never declared
///
/// Section 5, and it is the whole design of this type: every value here is
/// computed from `LocalSemanticIntent`, `LocalSemanticContract` and
/// `LocalSemanticField`. There is no second list of intents and no second list
/// of fields to fall out of step with the protocol — add a field to a contract
/// and the constraint permits it on the next build; remove one and the
/// constraint stops permitting it, with nobody having to remember this file
/// exists.
///
/// ## Deliberately not a grammar
///
/// Section 21. Nothing here mentions GBNF, llama.cpp, JSON Schema or a
/// sampler. It says *what may be produced*; how a particular backend enforces
/// that is the backend's problem. `SemanticActionGrammar` turns this into GBNF
/// for llama.cpp, and a future Core ML or hosted backend can turn the same
/// value into whatever its own runtime understands.
///
/// ## Shallow on purpose
///
/// Section 19. One object, a string intent, one nested arguments object of
/// string-valued keys, and — for `calendar.update` alone — one further object
/// of changes. No arrays, no numbers, no nesting beyond that. Every extra
/// construct is a construct a 300M model can get lost in and a grammar can be
/// wrong about.
public struct LocalSemanticActionSchema: Hashable, Sendable {

    /// Which intents may be produced, in a fixed order.
    ///
    /// Ordered rather than a `Set` because a grammar built from it must be
    /// byte-identical between runs — a constraint that varies per launch is a
    /// constraint nobody can reproduce a failure against.
    public let intents: [LocalSemanticIntent]

    public init(intents: [LocalSemanticIntent]) {
        // Sorted and de-duplicated here, so callers cannot make the ordering a
        // property of how they happened to write the array literal.
        var seen: Set<LocalSemanticIntent> = []
        self.intents = LocalSemanticIntent.allCases
            .filter { intents.contains($0) && seen.insert($0).inserted }
    }

    /// Every intent that does something.
    ///
    /// `chat` is excluded: the constrained path exists because the router
    /// already decided this message was an action, and a grammar that permits
    /// "no action" is a grammar that permits the model to decline by mistake.
    /// Section 24's requirement — that a `chat` answer to a high-confidence
    /// action request still faces semantic validation — is met by the layer
    /// above rather than by widening the grammar.
    public static let universal = LocalSemanticActionSchema(
        intents: LocalSemanticIntent.allCases.filter(\.isAction)
    )

    /// The same protocol, narrowed to one family.
    ///
    /// Section 15: the single repair is constrained *more* tightly than the
    /// attempt that failed, not less. A model that answered "remind me in ten
    /// minutes" with `memory.store` is not asked again from the full menu.
    public static func restricted(to intents: [LocalSemanticIntent]) -> LocalSemanticActionSchema {
        let actionable = intents.filter(\.isAction)
        return LocalSemanticActionSchema(
            intents: actionable.isEmpty ? universal.intents : actionable
        )
    }

    /// The intents that belong to a routed family.
    ///
    /// Used to narrow a repair. `.other` narrows to nothing, which leaves the
    /// full protocol — the app does not pretend to know better than it does.
    public static func intents(for category: LocalActionCategory) -> [LocalSemanticIntent] {
        switch category {
        case .reminder: return [.reminderCreate]
        case .memory: return [.memoryStore]
        case .task: return [.taskCreate, .taskComplete]
        case .calendar: return [.calendarCreate, .calendarUpdate]
        case .other: return []
        }
    }

    public func contract(for intent: LocalSemanticIntent) -> LocalSemanticContract {
        LocalSemanticContract.contract(for: intent)
    }

    /// The arguments an intent must carry, in a fixed order.
    public func requiredFields(for intent: LocalSemanticIntent) -> [LocalSemanticField] {
        ordered(contract(for: intent).required)
    }

    /// The arguments it may carry, in a fixed order.
    public func optionalFields(for intent: LocalSemanticIntent) -> [LocalSemanticField] {
        ordered(contract(for: intent).optional)
    }

    /// What may appear inside `requestedChanges`.
    public func changeableFields(for intent: LocalSemanticIntent) -> [LocalSemanticField] {
        ordered(contract(for: intent).changeable)
    }

    /// Every key permitted anywhere under this intent.
    public func allowedFields(for intent: LocalSemanticIntent) -> [LocalSemanticField] {
        requiredFields(for: intent) + optionalFields(for: intent)
    }

    /// `LocalSemanticField.allCases` order, so two schemas built from the same
    /// contract render identically.
    private func ordered(_ fields: Set<LocalSemanticField>) -> [LocalSemanticField] {
        LocalSemanticField.allCases.filter(fields.contains)
    }

    // MARK: JSON Schema

    /// The same shape as a JSON Schema, for a backend whose runtime speaks it.
    ///
    /// Section 7 asks for `additionalProperties: false` on every object, and
    /// this is where that is spelled out literally. It is not what the
    /// llama.cpp backend uses — that consumes the GBNF built from the same
    /// value — but it is not a second source of truth either: both are derived
    /// from `intents` and the contracts, so neither can permit a field the
    /// other forbids.
    public var jsonSchema: JSONValue {
        .object([
            "type": .string("object"),
            "oneOf": .array(intents.map(intentSchema)),
        ])
    }

    private func intentSchema(_ intent: LocalSemanticIntent) -> JSONValue {
        var properties: [String: JSONValue] = [
            "intent": .object([
                "type": .string("string"),
                "enum": .array([.string(intent.rawValue)]),
            ]),
            "arguments": argumentsSchema(for: intent),
        ]
        var required: [JSONValue] = [.string("intent"), .string("arguments")]

        let changeable = changeableFields(for: intent)
        if !changeable.isEmpty {
            properties["requestedChanges"] = objectSchema(
                required: [], optional: changeable, minimumProperties: 1
            )
            required.append(.string("requestedChanges"))
        }

        return .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required),
            // Section 7. The one line that makes `relatedTaskID`, `eventID`,
            // `listName` and `dueDate` unrepresentable rather than merely
            // rejected: there is no property for them, and no room for one.
            "additionalProperties": .bool(false),
        ])
    }

    private func argumentsSchema(for intent: LocalSemanticIntent) -> JSONValue {
        objectSchema(
            required: requiredFields(for: intent),
            optional: optionalFields(for: intent),
            minimumProperties: nil
        )
    }

    private func objectSchema(
        required: [LocalSemanticField],
        optional: [LocalSemanticField],
        minimumProperties: Int?
    ) -> JSONValue {
        var properties: [String: JSONValue] = [:]
        for field in required + optional {
            // Every semantic value is a string the user is expected to have
            // said. No formats, no patterns, no enums — a `format: uuid` here
            // would be the invitation this whole protocol removed.
            properties[field.rawValue] = .object(["type": .string("string")])
        }
        var schema: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map { .string($0.rawValue) }),
            "additionalProperties": .bool(false),
        ]
        if let minimumProperties {
            schema["minProperties"] = .number(Double(minimumProperties))
        }
        return .object(schema)
    }
}

/// What a backend is asked to enforce for one constrained generation.
///
/// Section 2. A struct rather than the schema alone because a backend will
/// eventually want more than the shape — a token budget, a stop condition —
/// and because the name says what it is for at every call site.
public struct ActionGenerationConstraints: Hashable, Sendable {
    /// The only thing a valid generation may be.
    public let semanticSchema: LocalSemanticActionSchema

    public init(semanticSchema: LocalSemanticActionSchema) {
        self.semanticSchema = semanticSchema
    }

    /// The whole protocol.
    public static let universal = ActionGenerationConstraints(
        semanticSchema: .universal
    )

    /// The protocol, narrowed to the family the request plainly belongs to.
    public static func narrowed(to category: LocalActionCategory) -> ActionGenerationConstraints {
        ActionGenerationConstraints(
            semanticSchema: .restricted(to: LocalSemanticActionSchema.intents(for: category))
        )
    }
}
