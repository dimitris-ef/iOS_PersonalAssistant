import AssistantDomain
import Foundation

/// Renders selected memories for a model prompt.
///
/// Provider-neutral by construction: it produces plain lines that any model
/// can read, and nothing here knows which one will receive them.
///
/// What it deliberately omits is the point. Identifiers, confidence decimals,
/// salience, timestamps and source labels are all *application* metadata —
/// they decide what gets selected, and telling the model about them would
/// invite it to reason about them ("you said you were only 60% sure...") while
/// spending context on nothing useful. The model gets the facts.
public struct MemoryContextFormatter: Sendable {
    private let heading: String

    public init(heading: String = "What you remember about this person") {
        self.heading = heading
    }

    /// The memory section, or nil when there is nothing to say.
    ///
    /// Nil rather than "no memories found": a sentence telling the model the
    /// user has no history is worse than silence, because it is something for
    /// it to remark on.
    public func section(for memories: [MemoryItem]) -> String? {
        guard !memories.isEmpty else { return nil }
        let lines = memories.map { "- [\(label(for: $0.kind))] \($0.content)" }
        return "# \(heading)\n" + lines.joined(separator: "\n")
    }

    /// A readable category name. The raw enum case is an implementation
    /// detail — `recurringCommitment` is not a word.
    private func label(for kind: MemoryKind) -> String {
        switch kind {
        case .routine: return "Routine"
        case .preference: return "Preference"
        case .person: return "Person"
        case .place: return "Place"
        case .recurringCommitment: return "Recurring"
        case .fact: return "Fact"
        }
    }
}
