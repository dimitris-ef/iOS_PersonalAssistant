import Foundation

/// Corrects one known way a small action model picks the wrong intent.
///
/// ## The mistake
///
/// Metis Action 0.8B v0.1 answers unfamiliar wording with `calendar.update`
/// far more often than with anything else (`Docs/ACTION-ROUTING.md` §12). On
/// the phone, "I have an appointment with a dentist, 18th of November, 6 p.m."
/// became "change the dentist appointment" — and, with no such appointment in
/// the calendar, the person was asked what it was called (build 24).
///
/// ## The correction, and why it is safe
///
/// Changing an event is something people say with a verb that changes things:
/// move, reschedule, postpone, cancel, rename… A sentence with none of those
/// words, carrying a time, is somebody stating an appointment, not editing
/// one. So exactly that case — `calendar.update`, no change word anywhere in
/// what the person said, and a time to put it at — becomes `calendar.create`
/// with the same title and time.
///
/// It never runs the other way, and it never invents a field: everything in
/// the corrected action came from the model's own output. When the sentence
/// does contain a change word, the model's reading stands.
public enum LocalSemanticIntentCorrection {

    /// Words that signal changing something that already exists.
    static let changeWords: Set<String> = [
        "move", "moved", "moving", "reschedule", "rescheduled", "rescheduling",
        "postpone", "postponed", "push", "pushed", "shift", "shifted",
        "change", "changed", "changing", "cancel", "cancelled", "canceled",
        "rename", "renamed", "update", "updated", "delay", "delayed",
        "instead", "edit", "modify", "earlier", "forward",
    ]

    public static func corrected(
        _ action: LocalSemanticAction,
        userRequest: String
    ) -> LocalSemanticAction {
        guard action.intent == .calendarUpdate,
            !mentionsAChange(userRequest),
            let time = action.requestedChanges[.timeExpression],
            !time.trimmingCharacters(in: .whitespaces).isEmpty,
            let title = action.requestedChanges[.title] ?? action[.targetDescription],
            !title.trimmingCharacters(in: .whitespaces).isEmpty
        else { return action }

        var arguments: [LocalSemanticField: String] = [
            .title: title,
            .timeExpression: time,
        ]
        if let duration = action.requestedChanges[.durationExpression] {
            arguments[.durationExpression] = duration
        }
        if let location = action.requestedChanges[.locationExpression] {
            arguments[.locationExpression] = location
        }
        return LocalSemanticAction(intent: .calendarCreate, arguments: arguments)
    }

    static func mentionsAChange(_ text: String) -> Bool {
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
        return words.contains { changeWords.contains($0) }
    }
}
