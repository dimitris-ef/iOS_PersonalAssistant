import Foundation

/// A piece of text, prepared once for comparison.
///
/// Built ahead of scoring rather than inside it. Ranking compares one query
/// against every stored memory, so re-tokenising each memory per query would
/// make retrieval quadratic in the thing most likely to grow. A profile is
/// cheap to build and cheap to compare.
public struct MemoryTextProfile: Hashable, Sendable {
    /// Lowercased, punctuation stripped, whitespace collapsed.
    public let normalized: String
    /// Content words, stemmed, stop words removed.
    public let terms: Set<String>
    /// Adjacent term pairs, so "leave work" and "work leave" are not the same.
    public let bigrams: Set<String>
    /// Durations mentioned, in seconds. "half an hour" and "30 minutes" agree.
    public let durations: Set<TimeInterval>
    /// Words that make a statement conditional — "during rush hour", "on
    /// weekends". Two otherwise-similar sentences that differ here are talking
    /// about different situations.
    public let qualifiers: Set<String>

    public var isEmpty: Bool { terms.isEmpty }

    public init(_ text: String) {
        let normalized = MemoryTextNormalizer.normalize(text)
        self.normalized = normalized

        let tokens = MemoryTextNormalizer.tokenize(normalized)
        let content = tokens.filter { !MemoryTextNormalizer.stopWords.contains($0) }
        self.terms = Set(content.map(MemoryTextNormalizer.stem))

        var pairs: Set<String> = []
        for index in content.indices.dropLast() {
            pairs.insert(
                MemoryTextNormalizer.stem(content[index])
                    + "|"
                    + MemoryTextNormalizer.stem(content[index + 1])
            )
        }
        self.bigrams = pairs

        self.durations = MemoryTextNormalizer.durations(in: normalized)
        self.qualifiers = Set(tokens.filter { MemoryTextNormalizer.qualifierWords.contains($0) })
    }
}

/// Lightweight, deterministic text handling.
///
/// Deliberately not a natural-language library. Everything here is a few
/// hundred bytes of rules that behave identically on every platform, run
/// offline, and can be read in one sitting — which matters more for a personal
/// assistant's memory than linguistic sophistication would.
public enum MemoryTextNormalizer {
    public static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        let stripped = lowered.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(stripped)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    public static func tokenize(_ normalized: String) -> [String] {
        normalized.split(separator: " ").map(String.init)
    }

    /// Crude suffix stripping, so "minutes" and "minute" match.
    ///
    /// Not a real stemmer, and does not need to be: it exists so a query and a
    /// memory that use the same word in different forms still line up. Short
    /// words are left alone, because that is where naive stemming does damage.
    public static func stem(_ word: String) -> String {
        guard word.count > 4 else { return word }

        for suffix in ["ing", "ies", "ed", "es", "s"] where word.hasSuffix(suffix) {
            let stem = String(word.dropLast(suffix.count))
            guard stem.count >= 3 else { continue }
            return suffix == "ies" ? stem + "y" : stem
        }
        return word
    }

    /// Words carrying no retrieval signal.
    ///
    /// Kept small on purpose. An over-eager stop list removes the very words
    /// that distinguish two memories — "before" and "after" matter a great deal
    /// to someone planning a morning.
    public static let stopWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "if", "so", "to", "of", "in", "on",
        "at", "for", "with", "is", "are", "was", "were", "be", "been", "am",
        "do", "does", "did", "have", "has", "had", "it", "its", "this", "that",
        "these", "those", "there", "here", "what", "when", "how", "why", "who",
        "me", "my", "i", "you", "your", "we", "our", "they", "them", "their",
        "should", "would", "could", "can", "will", "shall", "may", "might",
        "about", "as", "by", "from", "into", "than", "then", "too", "very",
        "just", "also", "get", "got", "s", "t", "m", "re", "ll", "ve",
    ]

    /// Words that make a claim conditional.
    ///
    /// "Commute takes 30 minutes" and "commute takes 45 minutes during rush
    /// hour" are both true. Spotting the condition is what stops deduplication
    /// destroying the second one.
    public static let qualifierWords: Set<String> = [
        "during", "rush", "weekend", "weekends", "weekday", "weekdays",
        "sometimes", "usually", "occasionally", "winter", "summer", "morning",
        "evening", "night", "holiday", "holidays", "traffic", "unless", "except",
        "when", "if", "while",
    ]

    // MARK: Durations

    /// Every duration mentioned, in seconds.
    ///
    /// Written words count: "half an hour" is the same fact as "30 minutes",
    /// and a deduplicator that could not see that would happily store both.
    public static func durations(in normalized: String) -> Set<TimeInterval> {
        var found: Set<TimeInterval> = []
        let tokens = tokenize(normalized)

        for phrase in writtenDurations where normalized.contains(phrase.key) {
            found.insert(phrase.value)
        }

        for (index, token) in tokens.enumerated() {
            guard let value = Double(token) else { continue }
            let unit = index + 1 < tokens.count ? tokens[index + 1] : ""
            if unit.hasPrefix("min") {
                found.insert(value * 60)
            } else if unit.hasPrefix("hour") || unit.hasPrefix("hr") {
                found.insert(value * 3_600)
            } else if unit.hasPrefix("day") {
                found.insert(value * 86_400)
            }
        }

        return found
    }

    private static let writtenDurations: [String: TimeInterval] = [
        "half an hour": 1_800,
        "half hour": 1_800,
        "quarter of an hour": 900,
        "quarter hour": 900,
        "an hour and a half": 5_400,
        "hour and a half": 5_400,
    ]
}
