import Foundation
import PersonalMemory

#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

/// Apple's on-device sentence embeddings, behind the app's own abstraction.
///
/// ## Why `NaturalLanguage` and not something bigger
///
/// The brief said to look at what the SDK already offers before adding a stack.
/// `NLEmbedding.sentenceEmbedding(for:)` is on every supported device, needs no
/// download, no entitlement, no network and no credential, and produces a real
/// sentence vector. A Core ML embedding model would be better at nuance and
/// would cost tens of megabytes in the bundle, a conversion pipeline, and a
/// second thing to keep working across OS versions — for a memory store of a few
/// hundred sentences about somebody's commute. This is the right size.
///
/// It is also *the whole reason* the encoder is a protocol: swapping this for a
/// Core ML model later is a new conformance and a version bump, and nothing
/// above it changes.
///
/// ## Why this target exists at all
///
/// `NaturalLanguage` is Apple-only, and the memory architecture has to build and
/// be tested on Linux and Windows. So the framework lives here, alone, in a
/// target nothing in the core depends on, and the app composes it in at launch.
/// Everything below — ranking, consolidation, aging, the cache, the tests — sees
/// only ``SemanticEncoder``.
///
/// ## What it promises
///
/// Nothing, on its own. `sentenceEmbedding(for:)` returns nil for a language
/// with no model, and Simulator behaviour is not identical to a device's. Every
/// path here degrades to a throw, and every caller already falls back to lexical
/// ranking — which is why memory keeps working on a device where this returns
/// nothing at all.
public struct AppleNaturalLanguageEncoder: SemanticEncoder {
    /// Bumped when the language, the API or the normalisation changes, because
    /// stored vectors are keyed on it and a silent change is how stale vectors
    /// start ranking the wrong memories.
    public let identity = SemanticEncoderIdentity(providerID: "apple.nl.sentence", version: 1)

    /// Not calibrated against a device, and said so plainly.
    ///
    /// Sentence embeddings from a trained model sit higher than concept overlap
    /// does — unrelated English sentences are routinely above 0.3 — so the
    /// default would let too much through. This is a conservative starting
    /// point; tuning it needs the one thing this project has never had, which is
    /// a device to measure on. Recorded in `Docs/OPEN-ITEMS.md`.
    public var similarityFloor: Double { 0.6 }

    #if canImport(NaturalLanguage)
    private let language: NLLanguage
    #endif

    /// English by default — the only language this app's own text is written
    /// in, and the one whose model Apple ships everywhere.
    public init() {
        #if canImport(NaturalLanguage)
        self.language = .english
        #endif
    }

    #if canImport(NaturalLanguage)
    public init(language: NLLanguage) {
        self.language = language
    }
    #endif

    public var isAvailable: Bool {
        get async {
            #if canImport(NaturalLanguage)
            return NLEmbedding.sentenceEmbedding(for: language) != nil
            #else
            return false
            #endif
        }
    }

    public func embedding(for text: String) async throws -> SemanticVector {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SemanticEncodingError.emptyText }

        #if canImport(NaturalLanguage)
        guard let model = NLEmbedding.sentenceEmbedding(for: language) else {
            throw SemanticEncodingError.unavailable(
                reason: "no sentence embedding for \(language.rawValue)"
            )
        }
        guard let raw = model.vector(for: trimmed) else {
            // The framework has a model but declined this particular string.
            // A throw rather than a zero vector: "we could not encode this" and
            // "this means nothing" are different, and only the first should
            // leave the memory to lexical ranking.
            throw SemanticEncodingError.unavailable(reason: "no vector for the given text")
        }

        let vector = SemanticVector(raw.map(Float.init))
        guard !vector.isEmpty else {
            throw SemanticEncodingError.unavailable(reason: "degenerate vector")
        }
        return vector
        #else
        throw SemanticEncodingError.unavailable(reason: "NaturalLanguage is not available")
        #endif
    }
}

/// The encoder the app should use, chosen once at launch.
///
/// Apple's when the device has it, the lexicon encoder otherwise — never
/// neither, because a device with no encoder at all would fall back to lexical
/// ranking for its whole life, and the lexicon encoder is a good deal better
/// than that at no cost.
///
/// Resolved once at composition and kept, rather than asked per query. The
/// answer does not change while the app is running, and — more importantly —
/// stored vectors are keyed on the encoder's identity, so an encoder that
/// changed underneath the cache would silently be comparing vectors from two
/// different spaces. One decision, at the start, for the life of the process.
///
/// Synchronous because `NLEmbedding.sentenceEmbedding(for:)` is. The protocol's
/// `isAvailable` stays async for the sake of implementations that must load a
/// model; this one does not need it, and the composition root is a much better
/// place to make the choice than the first turn is.
public enum SemanticEncoderResolver {
    public static func best() -> any SemanticEncoder {
        #if canImport(NaturalLanguage)
        if NLEmbedding.sentenceEmbedding(for: .english) != nil {
            return AppleNaturalLanguageEncoder()
        }
        #endif
        // Never nothing. A device without Apple's model would otherwise rank on
        // words for its whole life, and the lexicon encoder is a good deal
        // better than that at no cost.
        return LexiconSemanticEncoder()
    }
}
