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

struct MemoryPresenter {
    var formatters: AppFormatters = .shared

    func sections(from memories: [MemoryItem]) -> [MemorySection] {
        MemoryGroup.allCases.compactMap { group in
            let matching = memories
                .filter { MemoryGroup.containing($0.kind) == group }
                .sorted { $0.createdAt > $1.createdAt }
            return matching.isEmpty ? nil : MemorySection(group: group, memories: matching)
        }
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
