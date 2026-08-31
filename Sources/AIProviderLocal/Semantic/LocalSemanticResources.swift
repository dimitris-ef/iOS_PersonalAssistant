import AssistantDomain
import AssistantPersistence
import Foundation

/// How well a description matches something the app already has.
///
/// Deliberately crude, and deliberately not a ranking. The only three answers
/// that matter downstream are "nothing", "exactly one" and "more than one",
/// because the first two are actions and the third is a question. Scoring
/// candidates to pick a winner would be the app guessing on the user's behalf,
/// which is the failure mode this whole pass exists to remove.
public enum LocalDescriptionMatching {

    /// Words too common to distinguish one thing from another.
    static let stopWords: Set<String> = [
        "the", "a", "an", "my", "our", "his", "her", "their", "your", "this",
        "that", "these", "those", "to", "of", "for", "on", "at", "in", "with",
        "and", "or", "is", "was", "it", "me", "i",
    ]

    static func tokens(_ text: String) -> Set<String> {
        let separators = CharacterSet.alphanumerics.inverted
        let words = text.lowercased()
            .components(separatedBy: separators)
            .filter { $0.count > 1 && !stopWords.contains($0) }
        return Set(words)
    }

    /// Whether a described thing plausibly refers to a stored one.
    ///
    /// A match needs either a substring hit or every meaningful word of the
    /// description present in the title. "My dentist appointment" matches
    /// "Dentist appointment"; it does not match "Dentist bill".
    public static func matches(description: String, title: String) -> Bool {
        let loweredTitle = title.lowercased()
        let loweredDescription = description.lowercased()
        if loweredTitle.contains(loweredDescription) { return true }

        let described = tokens(description)
        guard !described.isEmpty else { return false }
        return described.isSubset(of: tokens(title))
    }

    /// Turns whatever matched into the three-way answer.
    public static func match(_ candidates: [LocalResourceCandidate]) -> LocalResourceMatch {
        switch candidates.count {
        case 0: return .none
        case 1: return .one(candidates[0])
        default: return .ambiguous(candidates)
        }
    }
}

/// A resource resolver assembled from whatever the app has to hand.
///
/// Calendar lookup and task lookup live in different layers — one behind
/// `PlatformServices`, one behind a repository — and `AIProviderLocal` can see
/// neither of them by design (it depends on the domain and persistence and
/// nothing else, which is what keeps a local model structurally unable to
/// execute anything). So the composition root supplies the two lookups as
/// closures, and this type is the seam.
public struct LocalSemanticResources: LocalSemanticResourceResolving {
    private let tasks: @Sendable (String) async -> LocalResourceMatch
    private let events: @Sendable (String) async -> LocalResourceMatch

    public init(
        tasks: @escaping @Sendable (String) async -> LocalResourceMatch = { _ in .none },
        events: @escaping @Sendable (String) async -> LocalResourceMatch = { _ in .none }
    ) {
        self.tasks = tasks
        self.events = events
    }

    public func resolveTask(matching description: String) async -> LocalResourceMatch {
        await tasks(description)
    }

    public func resolveCalendarEvent(matching description: String) async -> LocalResourceMatch {
        await events(description)
    }

    /// The task half, backed by the app's own repository.
    ///
    /// Only outstanding tasks are considered: "mark the shopping done" cannot
    /// mean one that is already done, and including finished tasks would turn a
    /// clear request into an ambiguity every time something was repeated.
    public static func tasks(
        from repository: any TaskRepository,
        limit: Int = 200
    ) -> @Sendable (String) async -> LocalResourceMatch {
        { description in
            var filter = TaskFilter.outstanding
            filter.limit = limit
            guard let found = try? await repository.tasks(matching: filter) else { return .none }
            let candidates = found
                .filter { LocalDescriptionMatching.matches(description: description, title: $0.title) }
                .map { LocalResourceCandidate(identifier: $0.id.rawValue.uuidString, label: $0.title) }
            return LocalDescriptionMatching.match(candidates)
        }
    }
}
