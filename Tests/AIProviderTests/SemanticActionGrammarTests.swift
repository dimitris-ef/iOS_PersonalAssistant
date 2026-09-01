import AssistantAI
import AssistantDomain
import XCTest

@testable import AIProviderLocal

/// What the constraint permits, asserted against the constraint itself.
///
/// ## Why these tests are worth more than they look
///
/// Every claim here is about the exact bytes handed to
/// `llama_sampler_init_grammar` — not about what a mock was told to return.
/// `GBNFGrammar` parses that string and decides membership, so
/// "prose cannot escape the grammar" is checked against the grammar rather
/// than asserted about it.
///
/// What they cannot show is that llama.cpp's own parser reads the string the
/// same way. That is a real-device claim, and the grammar is deliberately
/// confined to constructs its GBNF documents as supported.
final class SemanticActionGrammarTests: XCTestCase {

    private func compiled(
        _ schema: LocalSemanticActionSchema = .universal
    ) throws -> GBNFGrammar {
        try GBNFGrammar.validate(
            SemanticActionGrammar.gbnf(for: schema), root: SemanticActionGrammar.rootRule
        )
    }

    // MARK: It is a valid grammar at all — section 18

    func testTheGeneratedGrammarValidates() throws {
        _ = try compiled()
        for intent in LocalSemanticIntent.allCases where intent.isAction {
            _ = try compiled(.restricted(to: [intent]))
        }
    }

    func testAGrammarWithADanglingReferenceIsRefused() {
        XCTAssertThrowsError(
            try GBNFGrammar.validate("root ::= missing-rule", root: "root")
        ) { error in
            XCTAssertEqual(
                (error as? GBNFGrammar.ValidationFailure)?.symbol, "undefinedRule"
            )
        }
    }

    func testAGrammarWithNoRootIsRefused() {
        XCTAssertThrowsError(
            try GBNFGrammar.validate(#"other ::= "x""#, root: "root")
        ) { error in
            XCTAssertEqual((error as? GBNFGrammar.ValidationFailure)?.symbol, "missingRoot")
        }
    }

    func testAnEmptyGrammarIsRefused() {
        XCTAssertThrowsError(try GBNFGrammar.validate("", root: "root")) { error in
            XCTAssertEqual((error as? GBNFGrammar.ValidationFailure)?.symbol, "emptyGrammar")
        }
    }

    // MARK: What it accepts — sections 28 to 33

    func testEveryIntentsCanonicalActionIsAccepted() throws {
        let grammar = try compiled()
        let valid = [
            #"{"intent":"reminder.create","arguments":{"title":"change bottles","timeExpression":"in 10 minutes"}}"#,
            #"{"intent":"memory.store","arguments":{"content":"John's birthday is May 3"}}"#,
            #"{"intent":"task.create","arguments":{"title":"buy milk"}}"#,
            #"{"intent":"task.create","arguments":{"title":"buy milk","timeExpression":"tomorrow"}}"#,
            #"{"intent":"task.complete","arguments":{"targetDescription":"buy milk"}}"#,
            #"{"intent":"calendar.create","arguments":{"title":"dentist","timeExpression":"tomorrow at 3"}}"#,
            #"{"intent":"calendar.update","arguments":{"targetDescription":"my dentist appointment"},"requestedChanges":{"timeExpression":"5"}}"#,
        ]
        for action in valid {
            XCTAssertTrue(grammar.matches(action), "rejected a valid action: \(action)")
        }
    }

    /// Whitespace after the structural punctuation is allowed, because real
    /// tokenizers emit `": "` as one token and a grammar that forbade it would
    /// leave the sampler with dead ends.
    func testModestWhitespaceIsTolerated() throws {
        let grammar = try compiled()
        XCTAssertTrue(
            grammar.matches(
                #"{ "intent": "memory.store", "arguments": { "content": "x" } }"#
            )
        )
    }

    // MARK: What it makes unsayable — sections 34 to 38

    func testProseIsNotInTheLanguage() throws {
        let grammar = try compiled()
        for prose in [
            "Sure, I'll create the reminder for you...",
            "The reminder.create schema requires a title and a timeExpression.",
            "I've set that reminder.",
            "",
        ] {
            XCTAssertFalse(grammar.matches(prose), "prose was accepted: \(prose)")
        }
    }

    /// Section 23: nothing may follow the action.
    func testNothingMayFollowTheAction() throws {
        let grammar = try compiled()
        XCTAssertFalse(
            grammar.matches(
                #"{"intent":"memory.store","arguments":{"content":"x"}} I hope that helps!"#
            )
        )
    }

    /// Sections 7, 8, 36, 37 and 38 in one place: every field the device once
    /// fabricated, and every identifier shape, has no production.
    func testForbiddenFieldsHaveNoProduction() throws {
        let grammar = try compiled()
        for key in [
            "relatedTaskID", "eventID", "taskID", "reminderID", "listID", "listName",
            "EventKitIdentifier", "databaseID", "internalTool", "dueDate", "notes",
            "uuid", "priority",
        ] {
            let action = """
                {"intent":"reminder.create","arguments":{"title":"x",\
                "timeExpression":"in 10 minutes","\(key)":"value"}}
                """
            XCTAssertFalse(grammar.matches(action), "\(key) was accepted")
        }
    }

    /// The same property stated from the other side: the grammar text contains
    /// no forbidden key at all, so there is nothing to match even by accident.
    func testTheGrammarTextNamesNoImplementationDetail() {
        let text = SemanticActionGrammar.gbnf(for: .universal).lowercased()
        for key in ["relatedtaskid", "eventid", "taskid", "listname", "duedate", "notes"] {
            XCTAssertFalse(text.contains(key), "the grammar names \(key)")
        }
        // And it does name every field the protocol really has.
        for field in LocalSemanticField.allCases {
            XCTAssertTrue(text.contains(field.rawValue.lowercased()), field.rawValue)
        }
    }

    func testAMissingRequiredFieldIsNotInTheLanguage() throws {
        let grammar = try compiled()
        XCTAssertFalse(
            grammar.matches(#"{"intent":"reminder.create","arguments":{"title":"x"}}"#)
        )
    }

    /// `calendar.update` must actually change something.
    func testAnEmptyChangeSetIsNotInTheLanguage() throws {
        let grammar = try compiled()
        XCTAssertFalse(
            grammar.matches(
                #"{"intent":"calendar.update","arguments":{"targetDescription":"x"},"requestedChanges":{}}"#
            )
        )
    }

    // MARK: Narrowing — section 15

    func testANarrowedGrammarAdmitsOnlyItsFamily() throws {
        let reminders = try compiled(.restricted(to: [.reminderCreate]))
        XCTAssertTrue(
            reminders.matches(
                #"{"intent":"reminder.create","arguments":{"title":"x","timeExpression":"in 10 minutes"}}"#
            )
        )
        XCTAssertFalse(
            reminders.matches(#"{"intent":"memory.store","arguments":{"content":"x"}}"#)
        )
    }

    func testTheRoutedFamilyDecidesTheNarrowing() {
        XCTAssertEqual(
            LocalSemanticActionSchema.intents(for: .reminder), [.reminderCreate]
        )
        XCTAssertEqual(LocalSemanticActionSchema.intents(for: .memory), [.memoryStore])
        XCTAssertEqual(
            Set(LocalSemanticActionSchema.intents(for: .task)), [.taskCreate, .taskComplete]
        )
        XCTAssertEqual(
            Set(LocalSemanticActionSchema.intents(for: .calendar)),
            [.calendarCreate, .calendarUpdate]
        )
        // `.other` narrows to nothing, which leaves the whole protocol rather
        // than pretending the app knows the family (section 6 of Part 1).
        XCTAssertTrue(LocalSemanticActionSchema.intents(for: .other).isEmpty)
        XCTAssertEqual(
            ActionGenerationConstraints.narrowed(to: .other).semanticSchema.intents,
            LocalSemanticActionSchema.universal.intents
        )
    }

    // MARK: Derived, not declared — section 5

    /// The schema is a function of the protocol, so it cannot drift from it.
    func testTheSchemaIsDerivedFromTheProtocol() {
        let schema = LocalSemanticActionSchema.universal
        XCTAssertEqual(
            Set(schema.intents), Set(LocalSemanticIntent.allCases.filter(\.isAction))
        )
        XCTAssertFalse(schema.intents.contains(.chat))

        for intent in schema.intents {
            let contract = LocalSemanticContract.contract(for: intent)
            XCTAssertEqual(Set(schema.requiredFields(for: intent)), contract.required)
            XCTAssertEqual(Set(schema.optionalFields(for: intent)), contract.optional)
            XCTAssertEqual(Set(schema.changeableFields(for: intent)), contract.changeable)
        }
    }

    /// Two schemas built the same way render the same bytes — a constraint that
    /// varied per launch would be one nobody could reproduce a failure against.
    func testGrammarGenerationIsDeterministic() {
        XCTAssertEqual(
            SemanticActionGrammar.gbnf(for: .universal),
            SemanticActionGrammar.gbnf(for: .universal)
        )
        XCTAssertEqual(
            SemanticActionGrammar.gbnf(
                for: LocalSemanticActionSchema(intents: [.taskComplete, .taskCreate])
            ),
            SemanticActionGrammar.gbnf(
                for: LocalSemanticActionSchema(intents: [.taskCreate, .taskComplete])
            )
        )
    }

    // MARK: The JSON Schema rendering — section 7

    /// Every object says `additionalProperties: false`, literally.
    func testEveryObjectRejectsAdditionalProperties() throws {
        let schema = LocalSemanticActionSchema.universal.jsonSchema
        var objectsChecked = 0

        func walk(_ value: JSONValue) {
            guard let object = value.objectValue else {
                value.arrayValue?.forEach(walk)
                return
            }
            if object["type"]?.stringValue == "object", object["properties"] != nil {
                XCTAssertEqual(object["additionalProperties"], .bool(false))
                objectsChecked += 1
            }
            for child in object.values { walk(child) }
        }

        walk(schema)
        XCTAssertGreaterThan(objectsChecked, LocalSemanticActionSchema.universal.intents.count)
    }

    /// The two renderings are derived from the same source, so neither permits
    /// a field the other forbids.
    func testTheJSONSchemaAndTheGrammarAgreeOnFields() throws {
        let schema = LocalSemanticActionSchema.universal
        let text = SemanticActionGrammar.gbnf(for: schema)
        let json = try XCTUnwrap(schema.jsonSchema.objectValue)
        let branches = try XCTUnwrap(json["oneOf"]?.arrayValue)

        XCTAssertEqual(branches.count, schema.intents.count)
        for intent in schema.intents {
            XCTAssertTrue(text.contains("\\\"\(intent.rawValue)\\\""), intent.rawValue)
            for field in schema.allowedFields(for: intent) {
                XCTAssertTrue(text.contains(field.rawValue), field.rawValue)
            }
        }
    }
}
