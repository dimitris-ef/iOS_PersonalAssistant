import AssistantDomain
import Foundation

/// What the router was asked to classify.
///
/// One field today, and a struct rather than a bare `String` on purpose: the
/// router will later want the locale and possibly whether a confirmation is
/// outstanding, and growing a struct is a smaller change than re-threading a
/// parameter through every call site.
public struct ActionRoutingInput: Hashable, Sendable {
    /// The message the user just sent.
    public var text: String

    public init(text: String) {
        self.text = text
    }
}

/// The broad family of a routed request, and the evidence that carried it.
///
/// Deliberately minimal (section 2). This is a routing hint and a diagnostic
/// label — it does **not** decide the action. The Universal Local Action
/// Protocol still parses and validates the semantic action independently, and
/// a category here that turns out to be wrong is corrected there.
public struct ActionRouteMetadata: Hashable, Sendable {
    public var category: LocalActionCategory
    /// Which phrase family carried the decision. A symbol, never the text.
    public var evidence: ActionRoutingEvidence

    public init(category: LocalActionCategory, evidence: ActionRoutingEvidence) {
        self.category = category
        self.evidence = evidence
    }
}

/// Why a message was routed to the action system.
///
/// Named families rather than a matched phrase, because the phrase is the
/// user's words and diagnostics must not carry those (section 22).
public enum ActionRoutingEvidence: String, Hashable, Sendable {
    case reminderRequest
    case memoryRequest
    case taskCreation
    case taskCompletion
    case calendarCreation
    case calendarChange
}

/// Where a message goes.
public enum ActionRoutingDecision: Hashable, Sendable {
    case chat
    case action(ActionRouteMetadata)

    public var isAction: Bool {
        if case .action = self { return true }
        return false
    }

    public var metadata: ActionRouteMetadata? {
        if case .action(let value) = self { return value }
        return nil
    }

    /// For the diagnostic line (section 22).
    public var symbol: String { isAction ? "action" : "chat" }
}

/// Decides whether a message is for the chat model or for the action system.
public protocol MetisActionRouting: Sendable {
    func route(_ input: ActionRoutingInput) async -> ActionRoutingDecision
}

/// The one decision this type is allowed to make.
///
/// ## The architecture change behind it
///
/// Until now, "can this app do things to your phone" was a property of
/// whichever model the user had picked to chat with. Pick a 1B local model, or
/// Apple's on-device model, or a cloud model without tool support, and setting
/// a reminder either worked, half-worked or produced a confident sentence
/// claiming something had happened. The capability of a *conversation partner*
/// was deciding whether the *phone* could be operated, which is the wrong thing
/// to depend on.
///
/// So actions get their own path and their own model. This router is the fork:
/// everything else about the turn — context, the agent loop, validation,
/// authorization, execution — is unchanged on both sides of it.
///
/// ## What it must never do
///
/// Section 1, and this is the whole discipline of the type: it decides CHAT or
/// ACTION and nothing else. It creates no reminders, touches no calendar,
/// stores no memories, builds no `AIToolCall`, performs no authorization, and
/// does not parse a semantic action. It cannot: it is given a string and
/// returns an enum, and it holds no repository, no platform service and no
/// provider. `MetisActionRouterTests` asserts that structurally.
///
/// ## Why it is a deterministic phrase router
///
/// Section 6. The obvious alternative — ask a model "is this an action?" — puts
/// a model in front of the model, doubles the latency of every message, and
/// makes the answer non-reproducible for the one decision that most needs to be
/// reproducible. The obvious other alternative — a full NLU stack — is a second
/// intent system to keep in step with the semantic protocol.
///
/// What this does instead is narrow: it looks for a phrase that can only be a
/// request to *do* something, and refuses to route on anything less. Two
/// consequences follow, both intended:
///
///  - **Discussion wins.** "How do reminders work?" contains "reminder" and is
///    a question about the feature. A veto list of discussion openers is
///    checked first, so a question that happens to contain an imperative
///    ("how would you create a task?") stays chat.
///  - **A noun is not a request.** "Reminder", "calendar", "task" and
///    "appointment" appear nowhere in the positive evidence on their own
///    (section 5). "Remind me" does; "reminders are useful" does not.
///
/// Ambiguity resolves to CHAT (section 6). A message wrongly sent to chat is a
/// worse answer; a message wrongly sent to the action system is an action
/// nobody asked for, and the two are not equally bad.
public struct MetisActionRouter: MetisActionRouting {

    public init() {}

    public func route(_ input: ActionRoutingInput) async -> ActionRoutingDecision {
        Self.decide(input.text)
    }

    /// Synchronous and static, so the rules can be tested without a harness and
    /// so nothing here can acquire a dependency by accident.
    public static func decide(_ text: String) -> ActionRoutingDecision {
        let padded = LocalActionIntent.padded(
            text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard padded.trimmingCharacters(in: .whitespaces).count > 1 else { return .chat }

        // Discussion first. Somebody asking *about* the feature is not asking
        // for it, however many action words the question contains.
        if discussionPhrases.contains(where: { padded.contains($0) }) { return .chat }

        for rule in rules where rule.phrases.contains(where: { padded.contains($0) }) {
            // A calendar rule that needs a calendar noun does not fire without
            // one: "move my task to tomorrow" is not a calendar change.
            if rule.requiresCalendarNoun,
                !LocalActionIntent.calendarNouns.contains(where: { padded.contains($0) }) {
                continue
            }
            return .action(
                ActionRouteMetadata(category: rule.category, evidence: rule.evidence)
            )
        }
        return .chat
    }

    // MARK: The rules

    struct Rule {
        var category: LocalActionCategory
        var evidence: ActionRoutingEvidence
        var phrases: [String]
        var requiresCalendarNoun: Bool = false
    }

    /// Ordered, and the order is load-bearing.
    ///
    /// Reminder is first for the same reason it wins ties in
    /// `LocalActionIntent.category`: "remind me to remember the passports" is a
    /// reminder, and reading it as a memory leaves the user believing something
    /// will happen at a time when nothing will.
    ///
    /// Calendar is checked before task creation because "add a dentist
    /// appointment" and "add a task" share the words that open them, and the
    /// noun is what tells them apart.
    static let rules: [Rule] = [
        Rule(
            category: .reminder,
            evidence: .reminderRequest,
            phrases: [
                "remind me", "remind us", "set a reminder", "set an alarm",
                "reminder for", "reminder in", "reminder to", "wake me",
                "alarm for", "alarm in", "nudge me", "ping me",
            ]
        ),
        Rule(
            category: .memory,
            evidence: .memoryRequest,
            phrases: [
                "remember that", "remember my", "remember i", "note that",
                "make a note", "keep in mind that", "don't forget that",
                "dont forget that",
            ]
        ),
        Rule(
            category: .calendar,
            evidence: .calendarChange,
            phrases: LocalActionIntent.calendarChangePhrases,
            requiresCalendarNoun: true
        ),
        Rule(
            category: .calendar,
            evidence: .calendarCreation,
            phrases: LocalActionIntent.calendarVerbPhrases
        ),
        Rule(
            category: .calendar,
            evidence: .calendarCreation,
            phrases: LocalActionIntent.calendarAddPhrases,
            requiresCalendarNoun: true
        ),
        Rule(
            category: .task,
            evidence: .taskCompletion,
            phrases: [
                " mark ", " tick off", " check off", " cross off",
                "as done", "is done", "as complete", "as completed",
            ]
        ),
        Rule(
            category: .task,
            evidence: .taskCreation,
            phrases: [
                "add a task", "add task", "create a task", "new task",
                "add to my list", "put on my list", "add to my to-do",
                "add to my todo",
            ]
        ),
    ]

    /// Openers that mean the message is *about* the feature.
    ///
    /// Checked before every positive rule, which is what keeps "how would you
    /// schedule a meeting?" out of the action path even though "schedule "
    /// is otherwise conclusive.
    /// Note what is *not* here: a question mark. "Can you remind me at five?"
    /// is a request phrased politely, and vetoing every question would send it
    /// to the chat model to be answered rather than carried out. The openers
    /// below are what actually distinguish asking about a thing from asking
    /// for it.
    static let discussionPhrases = [
        "how do ", "how does", "how did", "how would", "how can i", "how should",
        "what is ", "what's ", "whats ", "what are", "what does", "what do you",
        "why do", "why does", "why are", "why is",
        "which is", "which one", "when should",
        "tell me about", "do you think", "do you know",
        "explain ", "can you explain", "difference between",
        "best way to", "should i ", "is it worth", "are they",
        " vs ", " versus ",
    ]
}
