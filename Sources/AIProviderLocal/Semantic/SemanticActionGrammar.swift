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
/// ## Key order
///
/// `arguments` keys are in a fixed order (section 19). That was argued as
/// "the model is being *told* what to emit", which held for a general model
/// prompted with an example — and still holds for `arguments` in practice:
/// across all 29,933 records of the curated v2 training set, not one puts its
/// arguments in another order.
///
/// `requestedChanges` keys are accepted in **any order, each at most once**.
/// A fine-tuned model learns its key order from its training data, not from
/// an instruction, and in that same training set 492 of 939 multi-change
/// `calendar.update` records list their changes out of declaration order —
/// `timeExpression` before `title`, `durationExpression` before `title`. Under
/// a fixed order, a model that starts with the time can never write the title
/// afterwards: the change is silently dropped, or worse, pushed into a field
/// nobody asked for. On the real Metis Action 0.8B, "move my dentist
/// appointment to 4pm and rename it checkup" produced
/// `"durationExpression":"checkup"`. Measured over the 300-action golden set
/// (with its stray "Evaluation wording:" prefix removed), lost changes fell
/// from 10 to 3 with this rule, and llama.cpp's own grammar
/// checker rejects none of the 29,933 training answers under it against 492
/// under the fixed order.
///
/// Order carries no meaning in a JSON object and the parser decodes into a
/// dictionary, so this widens nothing the app acts on. The cost is size:
/// every ordered selection of distinct fields, 64 alternatives for the four
/// changeable fields. That grows factorially, which is fine at four and is
/// why `testTheChangesRuleStaysSmall` exists.
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

    /// "At least one of these, each at most once, in any order."
    ///
    /// `calendar.update` must actually change something (the validator refuses
    /// an empty `requestedChanges`), so the grammar refuses it too. A repeated
    /// key is refused as well: it would be legal JSON that silently keeps only
    /// one of the two values. See "Key order" above for why any order.
    ///
    /// One alternative per ordered selection of distinct fields, generated in
    /// a fixed sequence so the grammar is byte-identical between runs.
    private static func atLeastOne(of fields: [LocalSemanticField]) -> String {
        var alternatives: [String] = []
        for length in 1...max(1, fields.count) {
            for selection in orderedSelections(of: fields, length: length) {
                alternatives.append(selection.map(pair).joined(separator: " ws \",\" ws "))
            }
        }
        return "( " + alternatives.joined(separator: " | ") + " )"
    }

    /// Every ordered selection of `length` distinct fields: first by which
    /// field leads, in the given order, then recursively for the rest.
    static func orderedSelections(
        of fields: [LocalSemanticField], length: Int
    ) -> [[LocalSemanticField]] {
        guard length > 0 else { return [[]] }
        var result: [[LocalSemanticField]] = []
        for (index, field) in fields.enumerated() {
            var rest = fields
            rest.remove(at: index)
            for tail in orderedSelections(of: rest, length: length - 1) {
                result.append([field] + tail)
            }
        }
        return result
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
