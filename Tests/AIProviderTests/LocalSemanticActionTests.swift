import AssistantAI
import AssistantDomain
import AssistantPersistence
import NativeModelKit
import XCTest

@testable import AIProviderLocal

/// The universal semantic action protocol, from what a model may say to what
/// the app ends up doing.
///
/// ## The device failure these exist for
///
/// A reminder request on a real phone produced tool-shaped output carrying a
/// fabricated `relatedTaskID`, a due date from 2023, an invented title, an
/// invented list name, invented notes, and a made-up explanation that the data
/// was corrupted — most of which reached the screen.
///
/// The fix is not a better prompt. It is that the model is no longer shown any
/// of those fields: it says an intent and a handful of the person's own words,
/// and the app decides every implementation detail afterwards. Several of the
/// tests below therefore assert something stronger than "it is rejected" —
/// they assert there is nowhere to put it.
final class LocalSemanticActionTests: XCTestCase {

    /// 31 August 2026, 14:20, Europe/Athens.
    private static let now = Date(timeIntervalSince1970: 1_788_175_200)
    private static let athens = TimeZone(identifier: "Europe/Athens")!

    private let parser = LocalSemanticActionParser()

    private var clock: FixedDateProvider {
        FixedDateProvider(now: Self.now, timeZone: Self.athens)
    }

    private func resolver(
        tasks: LocalResourceMatch = .none,
        events: LocalResourceMatch = .none
    ) -> LocalSemanticActionResolver {
        LocalSemanticActionResolver(
            dateProvider: clock,
            resources: StubResources(taskMatch: tasks, eventMatch: events)
        )
    }

    private struct StubResources: LocalSemanticResourceResolving {
        var taskMatch: LocalResourceMatch
        var eventMatch: LocalResourceMatch

        func resolveTask(matching description: String) async -> LocalResourceMatch { taskMatch }
        func resolveCalendarEvent(
            matching description: String
        ) async -> LocalResourceMatch { eventMatch }
    }

    // MARK: The protocol's shape

    /// Section 4. The field set is closed, and nothing in it is an identifier,
    /// a timestamp, or a storage location. This is the assertion that the
    /// device's fabricated `relatedTaskID` is unrepresentable rather than
    /// merely refused.
    func testNoSemanticFieldIsAnImplementationDetail() {
        for field in LocalSemanticField.allCases {
            XCTAssertNil(
                LocalSemanticForbiddenField.category(of: field.rawValue),
                "\(field.rawValue) is an implementation detail and must not be model-facing"
            )
        }
        XCTAssertEqual(LocalSemanticField.allCases.count, 6)
    }

    /// The model-facing instructions must not smuggle the internal schema back
    /// in under another name.
    func testTheModelFacingPromptNamesNoInternalTool() {
        let instructions = LocalSemanticPrompt.instructions().lowercased()
        for tool in ToolKind.allCases {
            XCTAssertFalse(
                instructions.contains(tool.rawValue.lowercased()),
                "the semantic prompt names the internal tool \(tool.rawValue)"
            )
        }
        for detail in ["duedate", "listname", "relatedtaskid", "eventid", "notes"] {
            XCTAssertFalse(instructions.contains(detail), "the prompt offers \(detail)")
        }
        // And it does describe every intent that does something.
        for intent in LocalSemanticIntent.allCases where intent != .chat {
            XCTAssertTrue(instructions.contains(intent.rawValue))
        }
    }

    // MARK: Parsing

    func testAReminderEnvelopeParsesToTitleAndExpressionOnly() {
        let raw = """
            {"intent":"reminder.create","arguments":\
            {"title":"change the bottles","timeExpression":"in 10 minutes"}}
            """
        guard
            case .validSemanticAction(let action) = parser.classify(
                raw, expectsAction: true, detectedCategory: .reminder
            )
        else { return XCTFail("expected a valid action") }

        XCTAssertEqual(action.intent, .reminderCreate)
        XCTAssertEqual(action[.title], "change the bottles")
        XCTAssertEqual(action[.timeExpression], "in 10 minutes")
        XCTAssertEqual(action.arguments.count, 2)
    }

    /// Section 21. The exact fabrication from the device report.
    func testAFabricatedRelatedTaskIDIsRefusedAsAnImplementationDetail() {
        let raw = """
            {"intent":"reminder.create","arguments":\
            {"title":"Bottles","timeExpression":"in 10 minutes",\
            "relatedTaskID":"550e8400-e29b-41d4-a716-446655440000"}}
            """
        guard
            case .forbiddenImplementationDetails(let failure) = parser.classify(
                raw, expectsAction: true, detectedCategory: .reminder
            )
        else { return XCTFail("a fabricated identifier was accepted") }
        XCTAssertEqual(failure.symbol, "forbiddenImplementationField")
        if case .forbiddenImplementationDetail(_, let category) = failure {
            XCTAssertEqual(category, "resourceIdentifier")
        } else {
            XCTFail("expected a forbidden implementation detail")
        }
    }

    /// The other fabrications from the same report: a due date, a list, notes.
    func testInventedApplicationOwnedFieldsAreRefused() {
        for key in ["dueDate", "listName", "notes", "priority", "calendar"] {
            let raw = """
                {"intent":"reminder.create","arguments":\
                {"title":"Bottles","timeExpression":"in 10 minutes","\(key)":"anything"}}
                """
            guard
                case .forbiddenImplementationDetails = parser.classify(
                    raw, expectsAction: true, detectedCategory: .reminder
                )
            else { return XCTFail("\(key) was accepted") }
        }
    }

    /// Section 43. Even inside the field it is allowed to use, the model may
    /// not hand over an instant — which is how a 2023 date reached a 2026
    /// reminder.
    func testAnAbsoluteTimestampInTheTimeExpressionIsRefused() {
        let raw = """
            {"intent":"reminder.create","arguments":\
            {"title":"Bottles","timeExpression":"2023-03-15T14:00:00"}}
            """
        guard
            case .forbiddenImplementationDetails(let failure) = parser.classify(
                raw, expectsAction: true, detectedCategory: .reminder
            )
        else { return XCTFail("a model-supplied timestamp was accepted") }
        XCTAssertEqual(failure.symbol, "absoluteTimestampSupplied")
    }

    func testAFieldThatBelongsToAnotherIntentIsRefused() {
        let raw = """
            {"intent":"memory.store","arguments":\
            {"content":"John's birthday is May 3","timeExpression":"in 10 minutes"}}
            """
        guard
            case .forbiddenImplementationDetails(let failure) = parser.classify(
                raw, expectsAction: true, detectedCategory: .memory
            )
        else { return XCTFail("a cross-intent field was accepted") }
        XCTAssertEqual(failure.symbol, "fieldNotAllowedForIntent")
    }

    func testAMissingRequiredFieldIsMalformedRatherThanFilledIn() {
        let raw = #"{"intent":"reminder.create","arguments":{"title":"Bottles"}}"#
        guard
            case .malformedSemanticAction(let reason) = parser.classify(
                raw, expectsAction: true, detectedCategory: .reminder
            )
        else { return XCTFail("a reminder with no time was accepted") }
        XCTAssertEqual(reason, "missingRequiredField")
    }

    /// Section 101.
    func testAnInventedIntentIsUnsupportedRatherThanGuessed() {
        let raw = #"{"intent":"calendar.fix","arguments":{"title":"x"}}"#
        guard
            case .unsupportedSemanticIntent(let name) = parser.classify(
                raw, expectsAction: true
            )
        else { return XCTFail("an invented intent was accepted") }
        XCTAssertEqual(name, "calendar.fix")
    }

    func testUnfinishedJSONIsMalformed() {
        let raw = #"{"intent":"reminder.create","arguments":{"title":"Bottles""#
        guard
            case .malformedSemanticAction = parser.classify(raw, expectsAction: true)
        else { return XCTFail("unfinished JSON was accepted") }
    }

    /// Section 31. Describing the protocol is not using it.
    func testRecitingTheProtocolIsALeak() {
        let raw = """
            To do that I would emit a semantic action with "intent" set to \
            reminder.create and a timeExpression argument.
            """
        guard
            case .protocolLeak = parser.classify(
                raw, expectsAction: true, detectedCategory: .reminder
            )
        else { return XCTFail("protocol prose was not caught") }
    }

    /// Section 32. A model falling back to the app's real tool vocabulary.
    func testReachingForTheInternalToolSchemaIsItsOwnLeak() {
        let raw = """
            {"tool_calls":[{"name":"updateCalendarEvent","arguments":\
            {"eventID":"550e8400-e29b-41d4-a716-446655440000"}}],"message":"Updating."}
            """
        let outcome = parser.classify(raw, expectsAction: true, detectedCategory: .reminder)
        switch outcome {
        case .internalToolProtocolLeak, .malformedSemanticAction, .unsupportedSemanticIntent:
            break
        default:
            XCTFail("a legacy tool envelope was not contained: \(outcome.symbol)")
        }
        XCTAssertNotEqual(outcome.symbol, "validSemanticAction")
    }

    /// Section 26. The continuation's device failure, at the protocol level: a
    /// reminder request must not become a stored note.
    func testAReminderRequestAnsweredWithMemoryStoreIsRefused() {
        let raw = """
            {"intent":"memory.store","arguments":\
            {"content":"Change the bottles in 10 minutes"}}
            """
        guard
            case .malformedSemanticAction(let reason) = parser.classify(
                raw, expectsAction: true, detectedCategory: .reminder
            )
        else { return XCTFail("a reminder became a memory") }
        XCTAssertEqual(reason, "intentMismatch")
    }

    /// And the converse still works, because the guard is one denial and not a
    /// general suspicion of `memory.store`.
    func testRememberingAFactIsStillAValidMemory() {
        let raw = """
            {"intent":"memory.store","arguments":{"content":"John's birthday is May 3"}}
            """
        guard
            case .validSemanticAction(let action) = parser.classify(
                raw, expectsAction: true, detectedCategory: .memory
            )
        else { return XCTFail("a genuine memory was refused") }
        XCTAssertEqual(action.intent, .memoryStore)
    }

    /// Ordinary conversation is untouched. A question that happens to be about
    /// reminders is answered, not contained.
    func testOrdinaryChatIsNotAnAction() {
        guard
            case .normalChat(let text) = parser.classify(
                "Reminders let you get a notification at a set time.", expectsAction: false
            )
        else { return XCTFail("an ordinary reply was treated as an action") }
        XCTAssertTrue(text.hasPrefix("Reminders let you"))
    }

    // MARK: Resolution

    private func resolve(
        _ action: LocalSemanticAction,
        tasks: LocalResourceMatch = .none,
        events: LocalResourceMatch = .none
    ) async -> LocalSemanticResolution {
        await resolver(tasks: tasks, events: events).resolve(action)
    }

    private func date(from iso: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)
    }

    /// Section 67, end to end through resolution: the model said "in 10
    /// minutes" and the app produced 14:30 Athens.
    func testAReminderResolvesToACreateCallWithARealDueDate() async {
        let action = LocalSemanticAction(
            intent: .reminderCreate,
            arguments: [.title: "change the bottles", .timeExpression: "in 10 minutes"]
        )
        guard case .resolved(let call) = await resolve(action) else {
            return XCTFail("expected a resolved call")
        }

        XCTAssertEqual(call.name, "createReminder")
        XCTAssertEqual(call.arguments["title"]?.stringValue, "change the bottles")
        XCTAssertEqual(
            date(from: call.arguments["dueDate"]?.stringValue ?? ""),
            Date(timeIntervalSince1970: 1_788_175_800)
        )
    }

    /// Section 7 and 13, asserted on the produced call rather than on the
    /// protocol: every field the device invented is simply absent.
    func testAResolvedReminderCarriesNothingTheUserDidNotSay() async {
        let action = LocalSemanticAction(
            intent: .reminderCreate,
            arguments: [.title: "change the bottles", .timeExpression: "in 10 minutes"]
        )
        guard
            case .resolved(let call) = await resolve(action),
            let arguments = call.arguments.objectValue
        else { return XCTFail("expected a resolved call") }

        XCTAssertEqual(Set(arguments.keys), ["title", "dueDate"])
        for invented in ["relatedTaskID", "listName", "notes", "priority"] {
            XCTAssertNil(arguments[invented], "\(invented) was invented during resolution")
        }
    }

    /// The same expression resolved twice is the same call — the app's decision,
    /// not a sampled one.
    func testResolutionIsDeterministic() async {
        let action = LocalSemanticAction(
            intent: .reminderCreate,
            arguments: [.title: "Bottles", .timeExpression: "in 10 minutes"]
        )
        let first = await resolve(action)
        let second = await resolve(action)
        XCTAssertEqual(first.toolCall?.arguments, second.toolCall?.arguments)
        XCTAssertEqual(first.toolCall?.name, second.toolCall?.name)
    }

    func testATimeNobodyCanReadBecomesAQuestion() async {
        let action = LocalSemanticAction(
            intent: .reminderCreate,
            arguments: [.title: "Bottles", .timeExpression: "at some point"]
        )
        guard case .needsClarification(let question, let reason) = await resolve(action) else {
            return XCTFail("an unreadable time must not become a reminder")
        }
        XCTAssertEqual(reason, .timeNotUnderstood)
        XCTAssertFalse(question.isEmpty)
    }

    func testAMemoryResolvesToStoreMemoryWithAnAppChosenKind() async {
        let action = LocalSemanticAction(
            intent: .memoryStore, arguments: [.content: "John's birthday is May 3"]
        )
        guard case .resolved(let call) = await resolve(action) else {
            return XCTFail("expected a resolved call")
        }
        XCTAssertEqual(call.name, "storeMemory")
        XCTAssertEqual(call.arguments["content"]?.stringValue, "John's birthday is May 3")
        XCTAssertEqual(call.arguments["kind"]?.stringValue, MemoryKind.fact.rawValue)
    }

    func testATaskWithNoTimeResolvesToATitleOnlyCall() async {
        let action = LocalSemanticAction(intent: .taskCreate, arguments: [.title: "Call the bank"])
        guard
            case .resolved(let call) = await resolve(action),
            let arguments = call.arguments.objectValue
        else { return XCTFail("expected a resolved call") }
        XCTAssertEqual(call.name, "createTask")
        XCTAssertEqual(Set(arguments.keys), ["title"])
    }

    // MARK: Existing things

    /// Sections 16 to 20. The identifier comes from the app's lookup, and the
    /// model never named one.
    func testCompletingATaskUsesTheIdentifierTheLookupReturned() async {
        let real = UUID().uuidString
        let action = LocalSemanticAction(
            intent: .taskComplete, arguments: [.targetDescription: "the shopping"]
        )
        guard
            case .resolved(let call) = await resolve(
                action, tasks: .one(LocalResourceCandidate(identifier: real, label: "Shopping"))
            )
        else { return XCTFail("expected a resolved call") }

        XCTAssertEqual(call.name, "completeTask")
        XCTAssertEqual(call.arguments["taskID"]?.stringValue, real)
        XCTAssertEqual(call.arguments["confirmedByUser"]?.boolValue, true)
    }

    func testNoMatchBecomesAQuestionRatherThanAnInventedIdentifier() async {
        let action = LocalSemanticAction(
            intent: .taskComplete, arguments: [.targetDescription: "the thing"]
        )
        guard case .needsClarification(_, let reason) = await resolve(action, tasks: .none) else {
            return XCTFail("a missing task must not resolve to anything")
        }
        XCTAssertEqual(reason, .noMatchingResource)
    }

    func testAmbiguityBecomesAQuestionRatherThanAChoice() async {
        let candidates = [
            LocalResourceCandidate(identifier: UUID().uuidString, label: "Dentist Monday"),
            LocalResourceCandidate(identifier: UUID().uuidString, label: "Dentist Friday"),
        ]
        let action = LocalSemanticAction(
            intent: .calendarUpdate,
            arguments: [.targetDescription: "my dentist appointment"],
            requestedChanges: [.timeExpression: "tomorrow at 5"]
        )
        guard
            case .needsClarification(let question, let reason) = await resolve(
                action, events: .ambiguous(candidates)
            )
        else { return XCTFail("an ambiguous target must not be chosen for the user") }
        XCTAssertEqual(reason, .ambiguousResource)
        XCTAssertTrue(question.contains("Dentist Monday"))
    }

    func testUpdatingAnEventUsesTheResolvedIdentifierAndTheResolvedTime() async {
        let real = UUID().uuidString
        let action = LocalSemanticAction(
            intent: .calendarUpdate,
            arguments: [.targetDescription: "my dentist appointment"],
            requestedChanges: [.timeExpression: "tomorrow at 5"]
        )
        guard
            case .resolved(let call) = await resolve(
                action, events: .one(LocalResourceCandidate(identifier: real, label: "Dentist"))
            )
        else { return XCTFail("expected a resolved call") }

        XCTAssertEqual(call.name, "updateCalendarEvent")
        XCTAssertEqual(call.arguments["eventID"]?.stringValue, real)
        let start = date(from: call.arguments["start"]?.stringValue ?? "")
        XCTAssertNotNil(start)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.athens
        let parts = calendar.dateComponents([.day, .hour], from: start ?? Date())
        XCTAssertEqual(parts.day, 1)
        XCTAssertEqual(parts.hour, 17)
    }

    /// With nothing to look things up in, the app asks. It does not fall back
    /// to whatever the model might have meant.
    func testWithNoLookupAvailableTheAppAsksRatherThanActs() async {
        let resolver = LocalSemanticActionResolver(dateProvider: clock, resources: nil)
        let action = LocalSemanticAction(
            intent: .taskComplete, arguments: [.targetDescription: "the shopping"]
        )
        guard case .needsClarification(_, let reason) = await resolver.resolve(action) else {
            return XCTFail("expected a question")
        }
        XCTAssertEqual(reason, .lookupUnavailable)
    }

    // MARK: Description matching

    func testDescriptionMatchingIsNarrowEnoughToBeUseful() {
        XCTAssertTrue(
            LocalDescriptionMatching.matches(
                description: "my dentist appointment", title: "Dentist appointment"
            )
        )
        XCTAssertTrue(
            LocalDescriptionMatching.matches(description: "the shopping", title: "Shopping")
        )
        XCTAssertFalse(
            LocalDescriptionMatching.matches(
                description: "my dentist appointment", title: "Dentist bill"
            )
        )
    }

    // MARK: Recovery budget

    /// Section 39. One budget for the turn, spent once, whichever path spends
    /// it — the two "exactly one repair" rules must not add up to two.
    func testTheRecoveryBudgetIsSpentOnce() {
        var policy = LocalActionRecoveryPolicy()
        XCTAssertTrue(policy.mayRetry)
        XCTAssertTrue(policy.consume())
        XCTAssertFalse(policy.mayRetry)
        XCTAssertFalse(policy.consume())
        XCTAssertEqual(policy.attemptsUsed, LocalActionRecoveryPolicy.maximumAttempts)
    }
}
