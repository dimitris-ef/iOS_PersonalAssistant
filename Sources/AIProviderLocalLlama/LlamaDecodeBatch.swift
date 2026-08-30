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
/// Which tokens in a batch should produce an output distribution.
///
/// Sections 13 to 16. Prefill is the case that matters: the model has to be
/// *told* the prompt, and only the very last token of the whole prompt is
/// sampled from. A ten-chunk prefill therefore asks for logits once, on the
/// final token of the final chunk — not once per chunk. A chunk boundary is an
/// artefact of `n_batch`; it is not a place the model is being asked anything.
///
/// Outside the `canImport` guard so the policy is nameable — and testable — in
/// CI, where there is no llama.cpp.
public enum LlamaBatchLogitsPolicy: Hashable, Sendable {
    /// An intermediate prefill chunk. Nothing to sample here.
    case none
    /// The end of a prompt: one distribution, for the token generation
    /// continues from.
    case lastTokenOnly
    /// Every position. Not used by prefill or generation; present because the
    /// batch type is general and a scoring path would need it.
    case everyToken

    /// What the validator should expect to find set.
    public func expectedLogitsTrueCount(tokenCount: Int) -> Int {
        switch self {
        case .none: return 0
        case .lastTokenOnly: return tokenCount > 0 ? 1 : 0
        case .everyToken: return tokenCount
        }
    }
}

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

    /// Fills the batch with one contiguous run of tokens.
    ///
    /// Positions are explicit and start at `startPosition` — which for a
    /// chunked prefill is the absolute position of the chunk's first token, not
    /// zero (section 9). The sequence is the same for every chunk, so the
    /// tokens all land in one KV sequence and the model sees one prompt rather
    /// than several short ones (section 11).
    /// Takes a slice so a chunked prefill does not copy each chunk out of the
    /// prompt array first (section 69). `enumerated()` gives zero-based offsets
    /// whatever the slice's own indices are, which is what the C buffers want.
    func fill(
        tokens: ArraySlice<llama_token>,
        startPosition: llama_pos = 0,
        sequenceID: llama_seq_id = 0,
        logits policy: LlamaBatchLogitsPolicy = .lastTokenOnly
    ) -> Bool {
        guard tokens.count <= capacity else { return false }
        guard
            let tokenBuffer = batch.token,
            let positionBuffer = batch.pos,
            let sequenceCountBuffer = batch.n_seq_id,
            let sequenceBuffer = batch.seq_id,
            let logitsBuffer = batch.logits
        else { return false }

        // The whole capacity, not just the part in use. One batch object is
        // reused across every chunk of a prefill, so a flag left set by a
        // longer earlier chunk would otherwise still be sitting past the end of
        // a shorter later one — harmless today, because llama.cpp reads only
        // `n_tokens` entries, and precisely the kind of thing that stops being
        // harmless when somebody changes how the buffer is read.
        for index in 0..<capacity { logitsBuffer[index] = 0 }

        for (offset, token) in tokens.enumerated() {
            tokenBuffer[offset] = token
            // `llama_pos` is int32_t, and so is the offset arithmetic. Section
            // 63: the conversion is written out rather than left to inference,
            // because a silent truncation here would produce positions that
            // look plausible and are wrong.
            positionBuffer[offset] = startPosition + llama_pos(offset)
            sequenceCountBuffer[offset] = 1
            // The inner array llama.cpp allocated for this token. Writing
            // through it rather than replacing the pointer is what keeps the
            // storage llama.cpp's.
            sequenceBuffer[offset]?[0] = sequenceID
        }
        switch policy {
        case .none:
            break
        case .lastTokenOnly:
            if !tokens.isEmpty { logitsBuffer[tokens.count - 1] = 1 }
        case .everyToken:
            for index in 0..<tokens.count { logitsBuffer[index] = 1 }
        }

        batch.n_tokens = Int32(tokens.count)
        tokenCount = tokens.count
        return true
    }

    /// One token at one position — the shape every generation step needs.
    ///
    /// Section 37: the first generated token goes at the position immediately
    /// after the prompt's last, and each one after that advances by one. Stated
    /// rather than inferred, for the same reason the prompt's positions are.
    /// Written directly rather than by wrapping the token in a one-element
    /// array: this runs once per generated token, and an allocation per token
    /// is the one place in the loop where it would actually be noticed.
    func fill(
        singleToken token: llama_token,
        position: llama_pos,
        sequenceID: llama_seq_id = 0
    ) -> Bool {
        guard capacity >= 1 else { return false }
        guard
            let tokenBuffer = batch.token,
            let positionBuffer = batch.pos,
            let sequenceCountBuffer = batch.n_seq_id,
            let sequenceBuffer = batch.seq_id,
            let logitsBuffer = batch.logits
        else { return false }

        for index in 0..<capacity { logitsBuffer[index] = 0 }
        tokenBuffer[0] = token
        positionBuffer[0] = position
        sequenceCountBuffer[0] = 1
        sequenceBuffer[0]?[0] = sequenceID
        // Generation samples from every token it decodes, so unlike a prefill
        // chunk this one always wants its distribution back.
        logitsBuffer[0] = 1

        batch.n_tokens = 1
        tokenCount = 1
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
