import AssistantDomain
import Foundation
import XCTest

@testable import AssistantAI

/// Which messages reach the action system, and which stay a conversation.
///
/// ## The architecture change these protect
///
/// Until now "can this app do things to your phone" was a property of whichever
/// model the user had picked to chat with. The router takes that decision away
/// from the model picker — so what it decides, and just as importantly what it
/// refuses to decide, is now load-bearing for the whole feature.
final class MetisActionRouterTests: XCTestCase {

    private let router = MetisActionRouter()

    private func decide(_ text: String) async -> ActionRoutingDecision {
        await router.route(ActionRoutingInput(text: text))
    }

    private func assertAction(
        _ text: String,
        _ category: LocalActionCategory,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let decision = await decide(text)
        guard case .action(let metadata) = decision else {
            return XCTFail("\"\(text)\" should be an action", file: file, line: line)
        }
        XCTAssertEqual(metadata.category, category, "\(text)", file: file, line: line)
    }

    private func assertChat(
        _ text: String, file: StaticString = #filePath, line: UInt = #line
    ) async {
        let decision = await decide(text)
        XCTAssertFalse(
            decision.isAction, "\"\(text)\" should stay chat", file: file, line: line
        )
    }

    // MARK: Actions — sections 3 and 28 to 33

    func testReminderRequestsRoutedToTheActionSystem() async {
        await assertAction("Remind me in 10 minutes to change bottles.", .reminder)
        await assertAction("Set a reminder for tomorrow at 8.", .reminder)
        await assertAction("Remind me in 10 minutes.", .reminder)
        await assertAction("Wake me at 6.", .reminder)
    }

    func testMemoryRequestsRoutedToTheActionSystem() async {
        await assertAction("Remember that John's birthday is May 3.", .memory)
        await assertAction("Remember my sister is allergic to nuts.", .memory)
    }

    func testTaskCreationRoutedToTheActionSystem() async {
        await assertAction("Create a task to buy milk.", .task)
        await assertAction("Add a task to call the bank.", .task)
    }

    func testTaskCompletionRoutedToTheActionSystem() async {
        await assertAction("Mark buy milk as complete.", .task)
        await assertAction("Mark buy milk as done.", .task)
    }

    func testCalendarCreationRoutedToTheActionSystem() async {
        await assertAction("Add a dentist appointment tomorrow at 3.", .calendar)
        await assertAction("Schedule a review on Friday.", .calendar)
    }

    func testCalendarChangesRoutedToTheActionSystem() async {
        await assertAction("Move my dentist appointment to 5.", .calendar)
        await assertAction("Cancel my meeting on Thursday.", .calendar)
    }

    /// Section 3, stated as the property it is: the decision is a function of
    /// the sentence, and nothing about the selected chat model is an input. The
    /// router is given a string and holds nothing else.
    func testRoutingDependsOnNothingButTheMessage() async {
        let first = await decide("Remind me in 10 minutes to change bottles.")
        let second = await MetisActionRouter().route(
            ActionRoutingInput(text: "Remind me in 10 minutes to change bottles.")
        )
        XCTAssertEqual(first, second)
    }

    // MARK: Chat — sections 4, 34 and 35

    func testOrdinaryQuestionsStayChat() async {
        await assertChat("What is a reminder?")
        await assertChat("How does Calendar work on iPhone?")
        await assertChat("What's the best way to organize my tasks?")
        await assertChat("Tell me about time management.")
        await assertChat("Why do people forget appointments?")
    }

    /// Section 5, the one that matters most for false positives: naming a
    /// feature is not asking for it.
    func testMentioningActionConceptsIsNotEnough() async {
        await assertChat("How do reminders work?")
        await assertChat("What's the difference between tasks and calendar events?")
        await assertChat("Do you think reminders are useful?")
        await assertChat("Why do people use reminders?")
        await assertChat("How do reminders work on iPhone?")
        await assertChat("What's better for planning, calendar events or tasks?")
    }

    /// A question that contains an imperative is still a question. "How would
    /// you schedule a meeting?" contains "schedule ", which is otherwise
    /// conclusive.
    func testDiscussionBeatsAnImperativeInsideIt() async {
        await assertChat("How would you schedule a meeting?")
        await assertChat("Can you explain how to add a task?")
        await assertChat("What does it mean to complete a task?")
    }

    /// Section 6: ambiguity resolves to chat. A bare noun, an empty message and
    /// a fragment are all chat rather than a guess.
    func testAmbiguityPrefersChat() async {
        await assertChat("")
        await assertChat("reminders")
        await assertChat("calendar")
        await assertChat("tasks and appointments")
        await assertChat("hmm")
    }

    /// A polite request is still a request. Vetoing every question mark would
    /// send this to the chat model to be *described* rather than carried out.
    func testAPolitelyPhrasedRequestIsStillAnAction() async {
        await assertAction("Can you remind me at five?", .reminder)
    }

    // MARK: What the router is not

    /// Section 1 and 40, asserted structurally rather than by inspection: the
    /// decision is a pure function of a string, so there is nothing for a tool
    /// call or a platform service to be made *from*. A router that grew either
    /// would need a dependency, and this signature has nowhere to put one.
    func testTheRouterIsAPureFunctionOfTheMessage() {
        let first = MetisActionRouter.decide("Remind me in 10 minutes.")
        let second = MetisActionRouter.decide("Remind me in 10 minutes.")
        XCTAssertEqual(first, second)
        XCTAssertTrue(first.isAction)
        // The whole surface: `decide` takes a String and returns an enum.
        // `MetisActionRouter()` takes no arguments, so it holds no repository,
        // no platform service, no provider and no resolver.
        XCTAssertEqual(MemoryLayout<MetisActionRouter>.size, 0)
    }

    /// Section 2: the metadata is a category and a symbol. Nothing on it can
    /// carry the user's sentence into a log.
    func testRouteMetadataCarriesOnlySymbols() async {
        guard case .action(let metadata) = await decide("Remind me to call Ann at 6.") else {
            return XCTFail("expected an action")
        }
        XCTAssertEqual(metadata.evidence, .reminderRequest)
        XCTAssertEqual(metadata.category.rawValue, "reminder")
        for symbol in [metadata.evidence.rawValue, metadata.category.rawValue] {
            XCTAssertFalse(symbol.lowercased().contains("ann"))
            XCTAssertFalse(symbol.contains(" "))
        }
    }
}
