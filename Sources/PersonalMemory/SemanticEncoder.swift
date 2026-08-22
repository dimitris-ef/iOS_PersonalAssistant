import Foundation

/// Which encoder produced a vector, and which version of it.
///
/// ## Why a vector is not permanent truth
///
/// An embedding only means something relative to the model that produced it.
/// Compare a vector from Apple's sentence encoder against one from the lexicon
/// encoder and the number you get is noise wearing the costume of a similarity.
/// So every stored vector carries the identity of what made it, and anything
/// that does not match the encoder currently configured is treated as absent —
/// regenerated when it is next needed, never silently used.
///
/// `version` is bumped by hand when an encoder's *behaviour* changes: a new
/// lexicon entry, a different normalisation, a different Apple API. Getting this
/// wrong is the failure mode where stale vectors quietly rank the wrong
/// memories forever, so it is stated in one place per encoder.
public struct SemanticEncoderIdentity: Hashable, Sendable, CustomStringConvertible {
    /// Stable name of the implementation, e.g. `apple.nl.sentence`.
    public let providerID: String
    /// Bumped when the same provider starts producing different vectors.
    public let version: Int

    public init(providerID: String, version: Int) {
        self.providerID = providerID
        self.version = version
    }

    public var description: String { "\(providerID)@v\(version)" }
}

public enum SemanticEncodingError: Error, Hashable, Sendable, CustomStringConvertible {
    /// No encoder on this device, or the framework declined for this language.
    case unavailable(reason: String)
    /// Nothing to encode.
    case emptyText

    public var description: String {
        switch self {
        case .unavailable(let reason): return "semantic encoding unavailable: \(reason)"
        case .emptyText: return "nothing to encode"
        }
    }
}

/// Turns text into a direction in meaning-space.
///
/// ## The one thing this abstraction is for
///
/// Nothing above it may know whether the vectors come from Apple's
/// `NaturalLanguage`, a Core ML model, the built-in lexicon encoder or a
/// deterministic test double. The ranker, the retrieval service,
/// `ContextAssembler` and every provider are written against this protocol, so
/// swapping the implementation is a composition-root edit and nothing else.
///
/// It is deliberately *not* on `AIProvider`. Which conversational model the user
/// selected has nothing to do with how their memories are indexed: switching
/// from the on-device model to a remote one must not change what the assistant
/// remembers, and using the remote provider as the embedding service would mean
/// uploading the user's entire memory store to index it. That is the single
/// hardest requirement in this part of the system.
///
/// ## Async, and why the rest of ranking is not
///
/// `embedding(for:)` is async because a real encoder may need to load a model.
/// Ranking itself stays synchronous and pure: the retrieval service resolves the
/// vectors it needs first, then hands them to the ranker as data. That keeps
/// scoring testable without a scheduler and stops "rank these memories" from
/// becoming an operation that can await inside a loop.
public protocol SemanticEncoder: Sendable {
    /// Identity and version, for cache validity.
    var identity: SemanticEncoderIdentity { get }

    /// Below this cosine, two texts are not about the same thing.
    ///
    /// ## Why the threshold belongs to the encoder
    ///
    /// Because it is a property of the vector space, not of the product. Every
    /// encoder has its own distribution: one may put unrelated sentences near
    /// 0.1 and related ones near 0.9, another may crowd everything above 0.5. A
    /// single number applied to both would be too strict for one and useless for
    /// the other — and "useless" here means every memory clearing the bar, which
    /// is exactly the failure the threshold exists to prevent.
    ///
    /// `MemoryRelevancePolicy` still owns the *product* floor, and the effective
    /// threshold is whichever is higher. So tuning stays in one place and an
    /// encoder can only ever be more conservative than the policy, never less.
    var similarityFloor: Double { get }

    /// Whether encoding is expected to work right now.
    ///
    /// Cheap and advisory. A `true` here does not promise `embedding(for:)`
    /// succeeds — callers must still handle the throw — but it lets the
    /// maintenance pass skip work on a device where no encoder exists at all.
    var isAvailable: Bool { get async }

    /// The vector for a piece of text.
    func embedding(for text: String) async throws -> SemanticVector
}

extension SemanticEncoder {
    /// A deliberately cautious default for an encoder that has not calibrated
    /// itself. Too high costs a recall the lexical channel usually still
    /// catches; too low fills every prompt with near-misses.
    public var similarityFloor: Double { 0.5 }
}

/// A stable fingerprint of what a memory says.
///
/// ## Why hash the normalised form
///
/// Because the question being asked is "did the meaning change?", not "did the
/// bytes change?". Fixing a capital letter or a stray double space should not
/// throw away a vector and pay to recompute it; changing thirty to forty-five
/// must. Normalising first — the same normalisation retrieval uses — makes the
/// hash answer the question that matters.
///
/// Not `Hasher`: it is seeded per process, so a value stored today would not
/// match the same text tomorrow and every vector would be invalidated on every
/// launch. FNV-1a is stable across processes, which is the only property needed
/// here. Nothing is defending against an adversary choosing a colliding text.
public enum MemoryContentHash {
    public static func hash(_ text: String) -> String {
        let normalized = MemoryTextNormalizer.normalize(text)
        // The prime is eleven hex digits; written ungrouped because splitting it
        // into fours inserts a zero and silently changes the constant.
        let prime: UInt64 = 0x100000001b3
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in normalized.utf8 {
            value ^= UInt64(byte)
            value = value &* prime
        }
        return String(value, radix: 16)
    }
}

/// A vector plus everything needed to know whether it is still valid.
///
/// Deliberately not stored on `MemoryItem`. A vector is derived data — it can
/// always be recomputed from the text — and putting it in the domain model would
/// mean every memory carried a kilobyte of floats through the UI, through
/// `Codable`, and into every test fixture, for the benefit of one subsystem.
public struct MemoryEmbedding: Hashable, Sendable {
    public let memoryID: MemoryEmbeddingKey
    public let vector: SemanticVector
    public let encoder: SemanticEncoderIdentity
    /// The content this was computed from. See ``MemoryContentHash``.
    public let contentHash: String
    public let createdAt: Date

    public init(
        memoryID: MemoryEmbeddingKey,
        vector: SemanticVector,
        encoder: SemanticEncoderIdentity,
        contentHash: String,
        createdAt: Date
    ) {
        self.memoryID = memoryID
        self.vector = vector
        self.encoder = encoder
        self.contentHash = contentHash
        self.createdAt = createdAt
    }

    /// Whether this vector may still be used.
    ///
    /// Both halves matter and they fail differently. A changed hash means the
    /// user edited the memory and the vector describes text that no longer
    /// exists. A changed encoder means the vector is in a different space
    /// altogether. Either way the answer is regenerate, not "close enough".
    public func isValid(for contentHash: String, encoder: SemanticEncoderIdentity) -> Bool {
        self.contentHash == contentHash && self.encoder == encoder
    }
}

/// The identifier a stored embedding hangs off.
///
/// A `UUID` rather than `MemoryItem.ID`, so this file — and the whole embedding
/// cache — needs no knowledge of the domain model it happens to be indexing.
public typealias MemoryEmbeddingKey = UUID
