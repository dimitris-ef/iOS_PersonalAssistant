import AIProviderLocal
import Foundation

#if canImport(llama)
import llama
#endif

/// How much of a batch reaches the log.
///
/// Outside the `canImport` guard on purpose: this is the privacy bound from
/// section 11 — identifiers are numbers, nothing detokenizes them, and
/// "thousands of IDs" is explicitly not wanted — and it is testable in CI only
/// if it exists in CI.
public enum LlamaDecodeBatchLimits {
    /// Identifiers logged from each end of the batch. Enough to spot a missing
    /// BOS or a run of zeros, which is what a malformed tokenization looks like.
    public static let loggedTokenIDLimit = 8
}

/// A `llama_batch` whose storage llama.cpp owns, filled in explicitly.
///
/// ## Why this exists
///
/// Sections 14, 17, 19, 20, 27 and 50. The audit question is whether anything
/// `llama_decode` reads can die before it returns. The answer this type gives is
/// structural rather than careful: **every buffer belongs to llama.cpp**.
///
/// `llama_batch_init(capacity, 0, n_seq_max)` heap-allocates `token`, `pos`,
/// `n_seq_id`, `seq_id` — including the inner `llama_seq_id *` arrays that make
/// `seq_id` a pointer-to-pointer — and `logits`. Nothing here is a Swift array,
/// so there is no `withUnsafe…` closure whose end could invalidate a pointer,
/// no nested-array bridging, and no assumption about Swift's contiguous storage
/// surviving anything. The buffers live from `init` to `llama_batch_free`, and
/// this type is a class with a `deinit` so that pairing cannot be forgotten.
///
/// Section 20 asked not to duplicate C struct definitions in Swift, and this
/// does not: `batch` is the imported `llama_batch`, populated through the
/// pointers llama.cpp handed back.
///
/// ## Why not `llama_batch_get_one`
///
/// It is *not* deprecated in the pinned revision — the header at b10506
/// declares it plainly — so the previous code was calling a supported API.
/// What it does is leave `pos`, `n_seq_id`, `seq_id` and `logits` null and let
/// llama.cpp infer all four from the memory state. That inference is a contract
/// this app cannot see and did not verify, and section 15 and 60 both say not
/// to assume it. Supplying all four explicitly replaces an assumption with a
/// value that gets written into the diagnostic log.
///
/// The logging bound lives in ``LlamaDecodeBatchLimits`` rather than on this
/// class, because this class is inside `#if canImport(llama)` and CI has no
/// llama slice — a privacy bound nothing can assert is one that quietly stops
/// holding.
#if canImport(llama)
final class LlamaDecodeBatch {

    private(set) var batch: llama_batch
    let capacity: Int
    private(set) var tokenCount: Int
    private var isFreed = false

    /// Allocates a batch for `capacity` tokens in one sequence.
    ///
    /// `embd: 0` selects token mode — llama.cpp then allocates `token` and
    /// leaves `embd` null, which is the pairing the validator checks for.
    init?(capacity: Int, sequenceCount: Int32 = 1) {
        guard capacity > 0 else { return nil }
        self.capacity = capacity
        self.tokenCount = 0
        self.batch = llama_batch_init(Int32(capacity), 0, sequenceCount)
        // `llama_batch_init` returns a struct by value and cannot signal
        // failure except by leaving the pointers null.
        guard batch.token != nil else {
            llama_batch_free(batch)
            return nil
        }
    }

    deinit {
        free()
    }

    func free() {
        guard !isFreed else { return }
        isFreed = true
        llama_batch_free(batch)
    }

    /// Fills the batch with one contiguous run of prompt tokens.
    ///
    /// Positions are explicit and start at `startPosition`, sequence 0, and
    /// only the final token requests logits — which is the canonical prefill
    /// shape: the model needs to be *told* the prompt, and only the last
    /// position's distribution is sampled from (section 62).
    func fill(
        tokens: [llama_token],
        startPosition: llama_pos = 0,
        sequenceID: llama_seq_id = 0,
        logitsForLastTokenOnly: Bool = true
    ) -> Bool {
        guard tokens.count <= capacity else { return false }
        guard
            let tokenBuffer = batch.token,
            let positionBuffer = batch.pos,
            let sequenceCountBuffer = batch.n_seq_id,
            let sequenceBuffer = batch.seq_id,
            let logitsBuffer = batch.logits
        else { return false }

        for index in 0..<tokens.count {
            tokenBuffer[index] = tokens[index]
            // `llama_pos` is int32_t, and so is the index arithmetic. Section
            // 63: the conversion is written out rather than left to inference,
            // because a silent truncation here would produce positions that
            // look plausible and are wrong.
            positionBuffer[index] = startPosition + llama_pos(index)
            sequenceCountBuffer[index] = 1
            // The inner array llama.cpp allocated for this token. Writing
            // through it rather than replacing the pointer is what keeps the
            // storage llama.cpp's.
            sequenceBuffer[index]?[0] = sequenceID
            logitsBuffer[index] = 0
        }
        if logitsForLastTokenOnly, !tokens.isEmpty {
            logitsBuffer[tokens.count - 1] = 1
        } else if !logitsForLastTokenOnly {
            for index in 0..<tokens.count { logitsBuffer[index] = 1 }
        }

        batch.n_tokens = Int32(tokens.count)
        tokenCount = tokens.count
        return true
    }

    /// Describes the batch as the validator and the log want it — read back off
    /// the struct rather than from what the caller believes it set.
    func descriptor(contextBatchLimit: Int, contextSize: Int) -> LocalDecodeBatchDescriptor {
        var logitsTrue = 0
        if let logits = batch.logits, batch.n_tokens > 0 {
            for index in 0..<Int(batch.n_tokens) where logits[index] != 0 { logitsTrue += 1 }
        }
        let count = Int(batch.n_tokens)
        return LocalDecodeBatchDescriptor(
            nTokens: count,
            tokenBufferCount: tokenCount,
            allocatedCapacity: capacity,
            contextBatchLimit: contextBatchLimit,
            contextSize: contextSize,
            usesTokens: batch.token != nil,
            usesEmbeddings: batch.embd != nil,
            positionCount: batch.pos != nil ? count : nil,
            firstPosition: batch.pos.flatMap { count > 0 ? Int($0[0]) : nil },
            lastPosition: batch.pos.flatMap { count > 0 ? Int($0[count - 1]) : nil },
            sequenceCount: batch.n_seq_id != nil ? count : nil,
            logitsCount: batch.logits != nil ? count : nil,
            logitsTrueCount: batch.logits != nil ? logitsTrue : nil
        )
    }

    /// The first and last few token identifiers, bounded.
    ///
    /// Section 11 permits numeric identifiers because they are not text and
    /// nothing here detokenizes them — but "thousands of IDs" is explicitly
    /// not wanted, so this is capped at both ends. Useful for spotting a
    /// missing BOS or a run of zeros, which is exactly what a malformed
    /// tokenization looks like.
    func tokenIDSummary() -> (first: String, last: String) {
        let limit = LlamaDecodeBatchLimits.loggedTokenIDLimit
        guard let buffer = batch.token, batch.n_tokens > 0 else { return ("", "") }
        let count = Int(batch.n_tokens)
        let head = (0..<min(limit, count)).map { String(buffer[$0]) }
        let tailStart = max(0, count - limit)
        let tail = (tailStart..<count).map { String(buffer[$0]) }
        return ("[" + head.joined(separator: ",") + "]", "[" + tail.joined(separator: ",") + "]")
    }
}
#endif
