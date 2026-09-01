import AssistantDomain
import Foundation

/// The kind of thing a request is asking for.
///
/// ## Why this is needed at all
///
/// A device produced `storeMemory` for "Remind me in 10 minutes to change
/// bottles". Nothing caught it: the envelope was valid, the tool existed, the
/// arguments were fine, and no identifier was invented. It was simply the wrong
/// action, and the user got a confirmation for a note they never asked for
/// while the reminder they did ask for never existed.
///
/// That failure is the app's founding distinction in miniature — recording that
/// something matters is not the same as making it happen — so it is worth a
/// check even though the model, not this code, chooses the tool.
/// ## Why it lives in `AssistantAI` rather than beside the local provider
///
/// It began as a local-model containment detail. It is now also what
/// `MetisActionRouter` reports as the broad family of a routed request, and the
/// router must be visible to `AssistantCore` without the core depending on any
/// one provider implementation. The vocabulary is the same in both places on
/// purpose: two lists of reminder phrasings would drift, and the day they
/// disagreed the router would send something to the action system that the
/// validator then refused as the wrong family.
public enum LocalActionCategory: String, Hashable, Sendable {
    /// "Remind me…", "set an alarm…" — do something for me, at a time.
    case reminder
    /// "Remember that…" — hold on to this fact about me.
    case memory
    /// "Add a task…", "mark … done" — something on my list.
    case task
    /// "Add a dentist appointment…", "move my meeting…" — my calendar.
    case calendar
    /// Something else, or nothing recognisable. Never constrains anything.
    case other
}

/// Whether the person asked for something to be *done*.
///
/// ## Why this is a heuristic and why that is acceptable here
///
/// It never decides what happens — only whether raw output is allowed through
/// unclassified. A false positive costs a schema-leak check on an ordinary
/// sentence, which passes. A false negative costs the containment this pass
/// exists for. So it is tuned to notice actions, and every path out of it still
/// goes through the same validation and authorization.
///
/// It deliberately does **not** choose a tool (section 34: no second business
/// -logic router). The model still decides that.
public enum LocalActionIntent {

    /// Phrases that ask for something to happen, rather than about something.
    static let actionPhrases = [
        "remind me", "remind us", "set a reminder", "reminder for", "reminder in",
        "wake me", "set an alarm", "alarm for", "alarm in",
        "add an event", "add event", "put in my calendar", "add to my calendar",
        "schedule ", "book ", "create ", "make a note", "add a task", "add task",
        "move my", "reschedule", "cancel my", "delete my", "change my",
        "mark ", "complete ", "finish ",
        "remember that", "note that",
    ]

    /// Phrases that mean the person is asking *about* the system rather than
    /// asking it to act. Section 5 — these keep legitimate technical discussion
    /// out of the containment path.
    static let inquiryPhrases = [
        "how do you", "how does", "what tools", "which tools", "what is the schema",
        "what does the schema", "explain the", "how would you", "can you explain",
        "what parameters", "show me the schema", "what format",
    ]

    /// True when the latest user message reads like a request to act.
    public static func isLikely(in messages: [AIMessage]) -> Bool {
        guard let latest = messages.last(where: { $0.role == .user }) else { return false }
        return isLikely(in: latest.content)
    }

    public static func isLikely(in text: String) -> Bool {
        let lowered = text.lowercased()
        guard !lowered.isEmpty else { return false }
        // Asking about the machinery wins over the action words inside the
        // question: "how do you create a reminder?" contains "create ".
        if inquiryPhrases.contains(where: { lowered.contains($0) }) { return false }
        return actionPhrases.contains(where: { lowered.contains($0) })
    }

    /// Phrases that ask for something to happen at a time.
    static let reminderPhrases = [
        "remind me", "remind us", "set a reminder", "reminder for", "reminder in",
        "reminder to", "wake me", "set an alarm", "alarm for", "alarm in",
        "nudge me", "ping me", "tell me when", "let me know when",
    ]

    /// Phrases that ask for a fact to be kept.
    static let memoryPhrases = [
        "remember that", "remember my", "remember i", "note that",
        "keep in mind that", "make a note", "don't forget that", "dont forget that",
    ]

    /// Phrases that ask for something on the user's list.
    ///
    /// Both halves of a task's life: putting one on the list and taking it off.
    /// The completion phrasings carry a leading space because "mark" and
    /// "finish" are common inside longer words, and " complete " must not match
    /// "completely".
    static let taskPhrases = [
        "add a task", "add task", "create a task", "new task", "put on my list",
        "add to my list", "add to my to-do", "add to my todo",
        " mark ", " tick off", " check off", " cross off",
        " complete ", " finish ", "as done", "is done", "as complete",
    ]

    /// Phrases that ask for something in the user's calendar.
    ///
    /// Two shapes: a verb that only means scheduling ("schedule", "book"), or a
    /// change verb paired with a calendar noun — "move my dentist appointment"
    /// is the calendar, "move my task" is not.
    static let calendarVerbPhrases = ["schedule ", "book "]
    static let calendarChangePhrases = [
        "move my", "reschedule", "push my", "shift my", "cancel my", "change my",
    ]
    static let calendarNouns = [
        "appointment", "event", "meeting", "calendar", "booking",
    ]
    static let calendarAddPhrases = [
        "add a", "add an", "add to my calendar", "put in my calendar",
        "put it in my calendar", "create a", "create an", "new ",
    ]

    public static func category(in messages: [AIMessage]) -> LocalActionCategory {
        guard let latest = messages.last(where: { $0.role == .user }) else { return .other }
        return category(in: latest.content)
    }

    /// Reminder wins a tie.
    ///
    /// "Remind me to remember the passports" contains both, and the thing being
    /// asked for is the reminding — the remembering is what the reminder is
    /// about. Getting this backwards would produce a stored note and no alarm,
    /// which is the exact failure this classification exists to stop.
    ///
    /// Calendar is checked before task because "add a dentist appointment"
    /// matches `add a` in both lists, and the noun is what settles it.
    public static func category(in text: String) -> LocalActionCategory {
        let lowered = padded(text.lowercased())
        guard !lowered.trimmingCharacters(in: .whitespaces).isEmpty else { return .other }
        if inquiryPhrases.contains(where: { lowered.contains($0) }) { return .other }
        if reminderPhrases.contains(where: { lowered.contains($0) }) { return .reminder }
        if memoryPhrases.contains(where: { lowered.contains($0) }) { return .memory }
        if isCalendar(lowered) { return .calendar }
        if taskPhrases.contains(where: { lowered.contains($0) }) { return .task }
        return .other
    }

    /// Whether the sentence is about a calendar entry.
    static func isCalendar(_ padded: String) -> Bool {
        if calendarVerbPhrases.contains(where: { padded.contains($0) }) { return true }
        let namesACalendarThing = calendarNouns.contains { padded.contains($0) }
        guard namesACalendarThing else { return false }
        return calendarChangePhrases.contains { padded.contains($0) }
            || calendarAddPhrases.contains { padded.contains($0) }
    }

    /// A copy with one space on each side, so a phrase written with a leading
    /// space still matches at the very start of the sentence.
    static func padded(_ text: String) -> String { " " + text + " " }
}

