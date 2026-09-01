import AssistantAI
import AssistantDomain
import Foundation

/// Turns the semantic protocol into a GBNF grammar llama.cpp can enforce.
///
/// ## Why a grammar at all
///
/// Everything the previous passes added was a check on output that had already
/// been produced: classify it, validate it, refuse it, repair it once. That
/// works, and it costs a whole generation every time a small model wanders. A
/// grammar moves the same rules one stage earlier — into the sampler, where a
/// token that would start a `"relatedTaskID"` key is simply not among the
/// tokens the model may pick.
///
/// The device failure that started this whole line of work is then not
/// "rejected"; it is not expressible. A model cannot emit a field the grammar
/// has no production for, however confidently it would like to.
///
/// ## Why GBNF and not JSON Schema
///
/// llama.cpp's JSON-Schema-to-grammar converter lives in `common`, which the
/// pinned `llama-b10506-xcframework.zip` does not export — its public surface
/// is `llama.h` and `ggml.h`. Reaching for it would mean vendoring a C++
/// translation unit to avoid writing forty lines of string building.
///
/// So the grammar is built here, directly, from `LocalSemanticActionSchema`.
/// `LocalSemanticActionSchema.jsonSchema` still exists for a future backend
/// whose runtime speaks JSON Schema — both are derived from the same intents
/// and contracts, so neither can permit what the other forbids.
///
/// ## Shape
///
/// One object. A literal intent, a literal `arguments` key, a closed set of
/// string-valued keys in a fixed order, and nothing after the closing brace.
///
/// ```
/// root          ::= action
/// action        ::= reminder-create | memory-store | …
/// reminder-create ::= "{" ws "\"intent\"" ws ":" ws "\"reminder.create\"" …
/// ```
///
/// Fixed key order is deliberate (section 19). Permitting any permutation
/// multiplies the rules by the factorial of the field count and buys nothing:
/// the model is being *told* what to emit, so there is no user expectation
/// about key order to respect.
public enum SemanticActionGrammar {

    /// The start symbol handed to `llama_sampler_init_grammar`.
    public static let rootRule = "root"

    /// The failure a runtime reports when the grammar itself could not be
    /// built.
    ///
    /// One authored string, shared by the runtime that raises it and the
    /// backend that recognises it, so section 26's `reason=...` line cannot
    /// drift from the message that caused it.
    public static let initializationFailureReason = "grammarInitializationFailed"

    /// The grammar for one schema.
    public static func gbnf(for schema: LocalSemanticActionSchema) -> String {
        var lines: [String] = []
        let intents = schema.intents.isEmpty
            ? LocalSemanticActionSchema.universal.intents
            : schema.intents

        lines.append("\(rootRule) ::= action")
        lines.append("action ::= " + intents.map(ruleName).joined(separator: " | "))
        lines.append("")

        for intent in intents {
            lines.append(contentsOf: rules(for: intent, schema: schema))
            lines.append("")
        }

        lines.append(contentsOf: Self.jsonPrimitives)
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: One intent

    private static func rules(
        for intent: LocalSemanticIntent, schema: LocalSemanticActionSchema
    ) -> [String] {
        let name = ruleName(intent)
        var members = [
            key("intent") + " ws \":\" ws " + literal(intent.rawValue),
            "\",\" ws " + key("arguments") + " ws \":\" ws \(name)-args",
        ]
        var rules: [String] = []

        let changeable = schema.changeableFields(for: intent)
        if !changeable.isEmpty {
            members.append(
                "\",\" ws " + key("requestedChanges") + " ws \":\" ws \(name)-changes"
            )
            rules.append(
                "\(name)-changes ::= \"{\" ws " + atLeastOne(of: changeable) + " ws \"}\""
            )
        }

        return [
            "\(name) ::= \"{\" ws " + members.joined(separator: " ws ") + " ws \"}\"",
            "\(name)-args ::= " + argumentsRule(for: intent, schema: schema),
        ] + rules
    }

    /// Required fields in order, then each optional one as an optional suffix.
    private static func argumentsRule(
        for intent: LocalSemanticIntent, schema: LocalSemanticActionSchema
    ) -> String {
        let required = schema.requiredFields(for: intent)
        let optional = schema.optionalFields(for: intent)

        guard !required.isEmpty else {
            // No intent in the protocol has this shape today. Emitting an empty
            // object rather than trapping keeps the generator total.
            return "\"{\" ws \"}\""
        }

        var body = required.map(pair).joined(separator: " ws \",\" ws ")
        for field in optional {
            body += " ( ws \",\" ws " + pair(field) + " )?"
        }
        return "\"{\" ws " + body + " ws \"}\""
    }

    /// "At least one of these, in this order."
    ///
    /// `calendar.update` must actually change something (the validator refuses
    /// an empty `requestedChanges`), so the grammar refuses it too. Expressed as
    /// one alternative per possible *first* field, each followed by the later
    /// fields as optional suffixes — linear in the field count, and with no
    /// ambiguity about ordering.
    private static func atLeastOne(of fields: [LocalSemanticField]) -> String {
        var alternatives: [String] = []
        for (index, field) in fields.enumerated() {
            var alternative = pair(field)
            for later in fields[(index + 1)...] {
                alternative += " ( ws \",\" ws " + pair(later) + " )?"
            }
            alternatives.append(alternative)
        }
        return "( " + alternatives.joined(separator: " | ") + " )"
    }

    private static func pair(_ field: LocalSemanticField) -> String {
        key(field.rawValue) + " ws \":\" ws string"
    }

    /// A JSON key, as a GBNF literal including its quotes.
    private static func key(_ name: String) -> String { "\"\\\"\(name)\\\"\"" }

    /// A JSON string value with fixed content.
    private static func literal(_ value: String) -> String { "\"\\\"\(value)\\\"\"" }

    private static func ruleName(_ intent: LocalSemanticIntent) -> String {
        // `reminder.create` → `reminder-create`. GBNF rule names are dashed
        // identifiers; a dot would not parse.
        intent.rawValue.replacingOccurrences(of: ".", with: "-")
    }

    // MARK: Primitives

    /// The JSON string and whitespace rules.
    ///
    /// `ws` is bounded rather than `*`: unbounded whitespace is a production a
    /// stuck model can ride forever, emitting spaces until the token budget
    /// runs out and reporting a truncated action.
    static let jsonPrimitives: [String] = [
        #"string ::= "\"" char* "\"""#,
        #"char ::= [^"\\] | "\\" ["\\/bfnrt]"#,
        #"ws ::= [ \t\n]{0,2}"#,
    ]
}
