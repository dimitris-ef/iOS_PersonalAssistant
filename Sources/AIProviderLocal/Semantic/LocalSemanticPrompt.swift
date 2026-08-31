import Foundation

/// The instructions a local model is given under the semantic protocol.
///
/// ## Why this replaces the tool schemas rather than adding to them
///
/// Sections 57 and 58. The old local prompt rendered the app's real
/// `AIToolSchema`s — `createReminder` with its `notes`, `listName`,
/// `relatedTaskID` and ISO-8601 `dueDate`, and eighteen other tools beside it.
/// That is a large document, and every field in it is an invitation: a small
/// model shown `relatedTaskID` will eventually fill in a `relatedTaskID`.
///
/// This is the whole protocol instead — six intents that do something, one that
/// does not, and six possible fields — and it is short enough that the context
/// it frees goes back to the user's own memories and tasks, which is what
/// actually makes the answers better.
///
/// ## Deliberately not a second catalogue
///
/// Nothing here is a tool. These are *requests*, and the mapping from a request
/// to the app's one real tool catalogue lives in
/// ``LocalSemanticActionResolver``. There is still exactly one set of tools.
public enum LocalSemanticPrompt {

    /// The block appended to the system prompt when actions are on offer.
    public static func instructions() -> String {
        var lines: [String] = []
        lines.append("## Actions")
        lines.append("")
        lines.append(
            "When the person asks you to do something, reply with a single JSON object "
                + "and nothing else. The app carries the action out; you never do."
        )
        lines.append("")
        lines.append("Intents:")
        for intent in LocalSemanticIntent.allCases where intent != .chat {
            lines.append("- \(intent.rawValue): \(intent.modelFacingDescription)")
        }
        lines.append("")
        lines.append("Example:")
        lines.append(reminderExample)
        lines.append("")
        lines.append(rules)
        return lines.joined(separator: "\n")
    }

    static let reminderExample = """
        {"intent":"reminder.create","arguments":\
        {"title":"change the bottles","timeExpression":"in 10 minutes"}}
        """

    /// The five rules, each of which is a failure that actually happened on a
    /// real phone.
    static let rules = """
        Rules:
        - Use only the fields listed for the intent. There are no other fields.
        - Never write dates, times or identifiers. Put the person's own words in \
        timeExpression ("in 10 minutes", "tomorrow at 3") and let the app work \
        out the date.
        - Never invent a title, a note, a list or a reason. If they did not say \
        it, leave it out.
        - To change or finish something that already exists, describe it in \
        targetDescription in the person's words. The app finds it.
        - If no action is needed, reply with ordinary text and no JSON.
        """

    /// The one constrained retry (sections 33 and 34).
    ///
    /// Written from the specific way the previous attempt failed, because
    /// "that was wrong, try again" reliably produces the same output a second
    /// time. Internal: never shown to the user.
    public static func repairInstruction(for outcome: LocalSemanticOutcome) -> String {
        var lines = ["Your previous reply could not be used."]
        switch outcome {
        case .malformedSemanticAction:
            lines.append(
                "Reply with one JSON object of the form "
                    + "{\"intent\":\"…\",\"arguments\":{…}} and nothing else."
            )
        case .protocolLeak:
            lines.append(
                "Do not describe the format. Use it: reply with the JSON object itself."
            )
        case .internalToolProtocolLeak:
            lines.append(
                "Do not use tool names or tool_calls. The only intents are the ones "
                    + "listed above."
            )
        case .unsupportedSemanticIntent:
            lines.append("Use one of the intents listed above, exactly as written.")
        case .forbiddenImplementationDetails:
            lines.append(
                "Remove any field that is not listed for the intent. Do not write "
                    + "dates, times, identifiers, list names or notes — the app "
                    + "decides those."
            )
        case .normalChat, .validSemanticAction, .failedActionAttempt:
            lines.append("Reply with one JSON object using the intents listed above.")
        }
        lines.append("If you cannot, reply with ordinary text and no JSON.")
        return lines.joined(separator: " ")
    }
}
