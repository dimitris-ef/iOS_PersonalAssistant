import AssistantDomain
import Foundation

/// A human-friendly grouping of memory kinds.
///
/// The domain's `MemoryKind` is the storage vocabulary; this is the reading
/// vocabulary. Keeping them separate means the Memory screen can regroup
/// without touching the core.
enum MemoryGroup: String, CaseIterable, Identifiable {
    case routines
    case preferences
    case people
    case places
    case commitments
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .routines: return "Routines"
        case .preferences: return "Preferences"
        case .people: return "People"
        case .places: return "Places"
        case .commitments: return "Commitments"
        case .other: return "Other"
        }
    }

    var footer: String {
        switch self {
        case .routines:
            return "How long things usually take you. I use these to time reminders."
        case .preferences:
            return "How you want me to behave."
        case .people:
            return "People who come up in what you tell me."
        case .places:
            return "Where you go, and how long it takes to get there."
        case .commitments:
            return "Things that come round regularly."
        case .other:
            return "Everything else worth keeping."
        }
    }

    static func containing(_ kind: MemoryKind) -> MemoryGroup {
        switch kind {
        case .routine: return .routines
        case .preference: return .preferences
        case .person: return .people
        case .place: return .places
        case .recurringCommitment: return .commitments
        case .fact: return .other
        }
    }
}

struct MemorySection: Identifiable {
    let group: MemoryGroup
    let memories: [MemoryItem]

    var id: String { group.id }
}

/// What the Memory screen is currently showing.
///
/// Archiving is only defensible if the user can see what was archived and put it
/// back. A filter is the cheapest honest way to offer that: the default view is
/// what the assistant is actually using, and one tap shows everything it has
/// stopped using and why.
enum MemoryScope: String, CaseIterable, Identifiable {
    /// What the assistant is using right now.
    case current
    /// Faded, archived, superseded and unresolved — the history.
    case setAside

    var id: String { rawValue }

    var title: String {
        switch self {
        case .current: return "In use"
        case .setAside: return "Set aside"
        }
    }

    func includes(_ lifecycle: MemoryLifecycle) -> Bool {
        switch self {
        case .current: return lifecycle == .active
        case .setAside: return lifecycle != .active
        }
    }

    var emptyMessage: String {
        switch self {
        case .current:
            return "Nothing yet. Tell me something worth remembering, or add it here."
        case .setAside:
            return "Nothing set aside. Memories appear here when they are replaced by "
                + "something newer, or when they have gone unused for a long time."
        }
    }
}

struct MemoryPresenter {
    var formatters: AppFormatters = .shared

    func sections(from memories: [MemoryItem], scope: MemoryScope = .current) -> [MemorySection] {
        let visible = memories.filter { scope.includes($0.lifecycle) }
        return MemoryGroup.allCases.compactMap { group in
            let matching = visible
                .filter { MemoryGroup.containing($0.kind) == group }
                .sorted { $0.createdAt > $1.createdAt }
            return matching.isEmpty ? nil : MemorySection(group: group, memories: matching)
        }
    }

    func count(of scope: MemoryScope, in memories: [MemoryItem]) -> Int {
        memories.filter { scope.includes($0.lifecycle) }.count
    }

    /// The status badge, or nil for an ordinary current memory.
    ///
    /// Nil in the common case on purpose: a screen where every row wears a
    /// "Current" label is a screen where the labels stop being read, and the
    /// only ones worth reading are the ones that say something has changed.
    func lifecycleLabel(for memory: MemoryItem) -> String? {
        memory.lifecycle == .active ? nil : memory.lifecycle.label
    }

    /// One sentence explaining a non-current status.
    ///
    /// Written for somebody who never asked to learn what "superseded" means.
    func lifecycleExplanation(for memory: MemoryItem) -> String? {
        switch memory.lifecycle {
        case .active:
            return nil
        case .stale:
            return "I have not needed this in a while, so I have stopped bringing it up. "
                + "It is still here."
        case .archived:
            return "Filed away after a long time unused. Restore it and I will use it again."
        case .superseded:
            return "Something newer replaced this. Kept so you can see what changed."
        case .conflicting:
            return "This disagrees with something else I know, and I could not tell which "
                + "is right. Edit or delete either one to settle it."
        }
    }

    /// "Based on 3 similar memories" — provenance, in the one form a user wants
    /// it. The full list is on the detail screen; nobody needs an audit log.
    func provenanceLabel(for memory: MemoryItem) -> String? {
        let count = memory.consolidatedFrom.count
        guard count > 0 else { return nil }
        return count == 1
            ? "Based on 1 earlier memory"
            : "Based on \(count) similar memories"
    }

    /// "You told me this" / "I worked this out" — transparency about where a
    /// memory came from matters more here than anywhere else in the app.
    func sourceLabel(for memory: MemoryItem) -> String {
        switch memory.source {
        case .user: return "You told me this"
        case .manual: return "You wrote this"
        case .assistant: return "I saved this from a conversation"
        case .observation: return "I worked this out from what you do"
        case .legacy: return "Saved earlier"
        }
    }

    /// How sure the app is, in words.
    ///
    /// A number would be worse than useless here. "0.72" invites the user to
    /// wonder what the other 0.28 is, and there is no honest answer — the value
    /// is a ranking input, not a measurement. Three bands say the only thing
    /// that matters: did you tell me this, or did I work it out?
    ///
    /// Returns nil for anything the app is confident about, so the common case
    /// carries no badge at all and the screen stays readable.
    func confidenceLabel(for memory: MemoryItem) -> String? {
        switch memory.confidence {
        case 0.85...: return nil
        case 0.6..<0.85: return "Likely"
        default: return "Inferred"
        }
    }

    func kindLabel(for kind: MemoryKind) -> String {
        switch kind {
        case .routine: return "Routine"
        case .preference: return "Preference"
        case .person: return "Person"
        case .place: return "Place"
        case .recurringCommitment: return "Recurring commitment"
        case .fact: return "Other"
        }
    }

    func symbol(for kind: MemoryKind) -> String {
        switch kind {
        case .routine: return "repeat"
        case .preference: return "slider.horizontal.3"
        case .person: return "person"
        case .place: return "mappin.and.ellipse"
        case .recurringCommitment: return "calendar.badge.clock"
        case .fact: return "text.quote"
        }
    }
}
