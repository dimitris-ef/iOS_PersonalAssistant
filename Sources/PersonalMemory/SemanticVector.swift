import Foundation

/// A piece of text as a direction in meaning-space.
///
/// ## Why a value type and not `[Float]`
///
/// Because the invariant is the whole point. Every vector here is L2-normalised
/// on the way in, which makes cosine similarity a dot product and makes two
/// vectors from the same encoder directly comparable without anyone having to
/// remember to normalise first. A bare array would put that obligation on every
/// call site, and the first one to forget would produce similarities above 1
/// that quietly outrank everything else.
///
/// `Float` rather than `Double`: an embedding's precision is nowhere near
/// `Double`'s, and halving the size matters when a few thousand of these are
/// held in memory and written to disk.
public struct SemanticVector: Hashable, Sendable {
    /// Unit length, always.
    public let components: [Float]

    public var dimension: Int { components.count }
    public var isEmpty: Bool { components.isEmpty }

    /// Normalises on the way in. A zero vector — text the encoder had nothing
    /// to say about — stays empty rather than becoming a division by zero.
    public init(_ components: [Float]) {
        let magnitude = sqrt(components.reduce(Float(0)) { $0 + $1 * $1 })
        guard magnitude > 0, magnitude.isFinite else {
            self.components = []
            return
        }
        self.components = components.map { $0 / magnitude }
    }

    /// For a vector already known to be unit length — reading one back from the
    /// store, where re-normalising would be wasted work on every launch.
    init(preNormalized components: [Float]) {
        self.components = components
    }

    /// How alike two directions are, from −1 to 1.
    ///
    /// Both operands are unit length, so this is the dot product. Vectors of
    /// different dimension are not comparable and score zero rather than
    /// crashing or silently comparing a prefix: that happens when the encoder
    /// changed underneath a cached vector, and the answer is "we do not know",
    /// not "not similar" and certainly not a truncated guess.
    public func similarity(to other: SemanticVector) -> Double {
        guard !isEmpty, dimension == other.dimension else { return 0 }
        var total: Float = 0
        for index in components.indices {
            total += components[index] * other.components[index]
        }
        return Double(min(max(total, -1), 1))
    }

    /// Cosine mapped onto 0...1, which is what ranking wants.
    ///
    /// Not `(x + 1) / 2`. That maps *unrelated* text — cosine near zero — to
    /// 0.5, which would put every memory halfway to relevant and defeat the
    /// threshold that keeps the camera preference out of a scheduling question.
    /// Negative similarity is clamped to zero instead: "points the other way"
    /// and "has nothing to do with it" are both simply not relevant.
    public func normalizedSimilarity(to other: SemanticVector) -> Double {
        max(0, similarity(to: other))
    }

    // MARK: Storage

    /// Little-endian bytes, for the cache.
    ///
    /// Endianness is stated rather than assumed. The store is a file, files get
    /// copied between devices, and a vector read back with the bytes swapped
    /// would not fail — it would silently be a different direction, which is the
    /// worst kind of bug to have in a ranking system.
    public var encoded: Data {
        var data = Data(capacity: components.count * 4)
        for value in components {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// Reads back what ``encoded`` wrote. Nil when the payload is not a whole
    /// number of floats — a truncated write, or someone else's data.
    public static func decoded(_ data: Data) -> SemanticVector? {
        guard !data.isEmpty, data.count % 4 == 0 else { return nil }
        var components: [Float] = []
        components.reserveCapacity(data.count / 4)
        var index = data.startIndex
        while index < data.endIndex {
            var bits: UInt32 = 0
            for offset in 0..<4 {
                bits |= UInt32(data[data.index(index, offsetBy: offset)]) << (8 * UInt32(offset))
            }
            components.append(Float(bitPattern: UInt32(littleEndian: bits)))
            index = data.index(index, offsetBy: 4)
        }
        guard components.allSatisfy({ $0.isFinite }) else { return nil }
        return SemanticVector(preNormalized: components)
    }
}
