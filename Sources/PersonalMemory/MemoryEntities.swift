import AssistantDomain
import Foundation

/// Coarse handles for the recurring things memories are about.
///
/// ## What this is for, and what it is not
///
/// Two memories that both mention work should be recognised as being about the
/// same *thing*, not merely as sharing a word. That is worth a little effort
/// because it makes consolidation and conflict detection safer: comparing "the
/// commute to work" with "the walk to the gym" is a comparison that should never
/// have been attempted, and an entity key is the cheapest way to say so.
///
/// It is not entity extraction in the NLP sense and must never be relied on.
/// Retrieval works perfectly well on memories that carry no keys at all —
/// section 26 is explicit about that, and it is the right constraint: a memory
/// whose subject this misses is still found by meaning and by words.
///
/// It is also not an address book. `person:dr_smith` is a string. There is no
/// record behind it, no contact, no merging with the user's phone, and none of
/// that is coming.
public enum MemoryEntityExtractor {
    /// Prefix for a place key.
    public static let placeNamespace = "place"
    /// Prefix for a person key.
    public static let personNamespace = "person"
    /// Prefix for a recurring activity key.
    public static let routineNamespace = "routine"

    /// The entity keys a memory's text and category suggest, sorted and unique.
    ///
    /// Sorted so that two runs produce the same array and a stored memory does
    /// not look edited because a `Set` iterated differently.
    public static func keys(for content: String, kind: MemoryKind) -> [String] {
        let profile = MemoryTextProfile(content)
        guard !profile.isEmpty else { return [] }

        var keys: Set<String> = []

        for (term, key) in wellKnownPlaces where profile.terms.contains(term) {
            keys.insert("\(placeNamespace):\(key)")
        }
        for (term, key) in wellKnownRoutines where profile.terms.contains(term) {
            keys.insert("\(routineNamespace):\(key)")
        }

        // Titled people — "Dr Smith", "Doctor Alvarez". A title followed by a
        // capitalised word is about as far as this goes on purpose: guessing at
        // names from bare capitalisation would file "Monday" as a person.
        for name in titledNames(in: content) {
            keys.insert("\(personNamespace):\(name)")
        }

        // A `person` memory is about somebody by definition, so its rarest
        // content word is a reasonable handle even without a title.
        if kind == .person, keys.allSatisfy({ !$0.hasPrefix(personNamespace) }),
           let subject = profile.terms.sorted().first(where: { $0.count > 3 }) {
            keys.insert("\(personNamespace):\(subject)")
        }

        return keys.sorted()
    }

    /// Whether two memories can be talking about the same thing.
    ///
    /// ## Compared per namespace, and why that matters
    ///
    /// Requiring any shared key at all is too strict, and the failure is
    /// invisible: "I take 30 minutes to get to work" is filed under
    /// `place:work`, "my commute is usually half an hour" under
    /// `routine:commute`, and a naive intersection concludes they are about
    /// different subjects — so the two statements of one fact are never
    /// compared. Recognising nothing in common is not the same as recognising a
    /// difference.
    ///
    /// So the question asked is narrower: *where both memories name a place, is
    /// it the same place? Where both name a person, is it the same person?* Work
    /// and the gym are a real difference. Work and "the commute" are not; they
    /// are two aspects of one thing, seen through different lenses.
    ///
    /// Two memories that share no namespace — or carry no keys at all, which is
    /// most of them — are not blocked. Entity keys are a hint, and nothing may
    /// depend on one having been recognised.
    public static func shareEntity(_ lhs: [String], _ rhs: [String]) -> Bool {
        guard !lhs.isEmpty, !rhs.isEmpty else { return true }

        let left = grouped(lhs)
        let right = grouped(rhs)
        for (namespace, leftValues) in left {
            guard let rightValues = right[namespace] else { continue }
            if leftValues.isDisjoint(with: rightValues) { return false }
        }
        return true
    }

    private static func grouped(_ keys: [String]) -> [String: Set<String>] {
        var groups: [String: Set<String>] = [:]
        for key in keys {
            let parts = key.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            groups[String(parts[0]), default: []].insert(String(parts[1]))
        }
        return groups
    }

    // MARK: Lexicons

    /// Stemmed, matching `MemoryTextProfile.terms`.
    private static let wellKnownPlaces: [String: String] = [
        "work": "work", "office": "work", "job": "work",
        "home": "home", "hous": "home", "flat": "home", "apartment": "home",
        "gym": "gym", "school": "school", "univers": "university",
        "hospit": "hospital", "clinic": "clinic", "dentist": "dentist",
        "airport": "airport", "station": "station",
    ]

    private static let wellKnownRoutines: [String: String] = [
        "commute": "commute", "commut": "commute",
        "workout": "workout", "exercis": "exercise",
        "medication": "medication", "medicin": "medication", "pill": "medication",
        "groceri": "groceries", "shop": "shopping",
        "laundri": "laundry", "bin": "bins", "rent": "rent",
    ]

    private static let titles: Set<String> = [
        "dr", "doctor", "prof", "professor", "mr", "mrs", "ms", "miss", "sir",
        "nurse", "coach", "uncle", "aunt",
    ]

    /// "Dr Smith" → `dr_smith`. Nothing clever, and nothing that fires on a
    /// sentence that merely begins with a capital letter.
    private static func titledNames(in content: String) -> [String] {
        let words = MemoryTextNormalizer.tokenize(MemoryTextNormalizer.normalize(content))
        var names: [String] = []
        for (index, word) in words.enumerated() where titles.contains(word) {
            guard index + 1 < words.count else { continue }
            let next = words[index + 1]
            guard next.count > 1, !MemoryTextNormalizer.stopWords.contains(next) else { continue }
            names.append("\(word)_\(next)")
        }
        return names
    }
}
