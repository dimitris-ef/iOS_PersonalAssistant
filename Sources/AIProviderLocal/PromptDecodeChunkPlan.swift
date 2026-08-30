import Foundation

/// One contiguous run of prompt tokens, and where it goes.
///
/// A value type with no llama.cpp in it, so the arithmetic that decides which
/// tokens land at which positions can be tested in CI — where there is no
/// framework slice and no model to load. The bridge turns each of these into a
/// `llama_batch` and nothing more; every decision has already been made here.
public struct PromptDecodeChunk: Hashable, Sendable {

    /// Zero-based, in decode order.
    public var index: Int
    /// How many chunks the whole prompt was split into.
    public var chunkCount: Int
    /// Half-open range into the prompt's token array.
    public var tokenStart: Int
    public var tokenEndExclusive: Int
    /// Absolute position of `tokenStart` in the sequence — *not* an offset
    /// within the chunk. Section 9: positions are continuous across the whole
    /// prompt and never reset at a chunk boundary.
    public var positionStart: Int
    public var positionEndInclusive: Int
    /// True only for the chunk carrying the prompt's last token.
    ///
    /// Section 14: a chunk boundary is not a prompt boundary. Nine of the ten
    /// chunks in a 1241-token prompt end at an arbitrary place decided by
    /// `n_batch`, and asking for logits there would be asking the model to
    /// produce a distribution for a token that is not the end of anything.
    public var isFinalPromptChunk: Bool

    public init(
        index: Int,
        chunkCount: Int,
        tokenStart: Int,
        tokenEndExclusive: Int,
        positionStart: Int,
        positionEndInclusive: Int,
        isFinalPromptChunk: Bool
    ) {
        self.index = index
        self.chunkCount = chunkCount
        self.tokenStart = tokenStart
        self.tokenEndExclusive = tokenEndExclusive
        self.positionStart = positionStart
        self.positionEndInclusive = positionEndInclusive
        self.isFinalPromptChunk = isFinalPromptChunk
    }

    public var tokenCount: Int { tokenEndExclusive - tokenStart }

    /// Sections 15 and 16. Exactly one flag, on the prompt's final token.
    public var logitsTrueCount: Int { isFinalPromptChunk ? 1 : 0 }

    /// The chunk's own preflight block (section 30). Counts, ranges and flags —
    /// nothing derived from what the tokens say.
    public func metadata() -> LocalInferenceMetadata {
        LocalInferenceMetadata()
            .setting(.chunkIndex, index)
            .setting(.chunkCount, chunkCount)
            .setting(.chunkTokenCount, tokenCount)
            .setting(.tokenStart, tokenStart)
            .setting(.tokenEndInclusive, tokenEndExclusive - 1)
            .setting(.firstPosition, positionStart)
            .setting(.lastPosition, positionEndInclusive)
            .setting(.isFinalPromptChunk, isFinalPromptChunk)
            .setting(.logitsTrueCount, logitsTrueCount)
    }
}

/// The whole prefill, planned before any of it is decoded.
public struct PromptDecodePlan: Hashable, Sendable {
    public var chunks: [PromptDecodeChunk]
    /// The size limit every chunk was cut to.
    public var chunkSize: Int
    public var tokenCount: Int
    public var basePosition: Int

    public init(
        chunks: [PromptDecodeChunk],
        chunkSize: Int,
        tokenCount: Int,
        basePosition: Int
    ) {
        self.chunks = chunks
        self.chunkSize = chunkSize
        self.tokenCount = tokenCount
        self.basePosition = basePosition
    }

    /// Where generation starts. Section 61 — returned rather than recomputed,
    /// because two places deriving the same position independently is exactly
    /// how they come to disagree.
    public var nextPosition: Int { basePosition + tokenCount }

    /// Section 67's invariant, as a value rather than a comment.
    public var decodedTokenCount: Int { chunks.reduce(0) { $0 + $1.tokenCount } }

    public func metadata() -> LocalInferenceMetadata {
        LocalInferenceMetadata()
            .setting(.promptTokenCount, tokenCount)
            .setting(.plannedChunks, chunks.count)
            .setting(.chunkSize, chunkSize)
            .setting(.basePosition, basePosition)
    }
}

/// Splits a prompt into batches the runtime will actually accept.
///
/// ## The bug this replaces
///
/// The prompt used to be handed to `llama_decode` in a single batch, and a real
/// device rejected it:
///
/// ```
/// n_tokens is 1241 but n_batch is 128
/// ```
///
/// The rejection was correct — that batch genuinely was too large — but the
/// premise behind it was not. **`n_batch` is not a maximum prompt length.** It
/// is the largest logical batch one `llama_decode` call accepts. A prompt many
/// times that size is perfectly ordinary; it just has to arrive in several
/// calls, into the same context, with continuous positions. What the whole
/// prompt *does* have to fit inside is `n_ctx`, and that is a different check
/// made somewhere else.
///
/// So the fix is here rather than in the configuration. Raising `n_batch` until
/// 1241 fits would make this particular prompt work and the next longer one
/// fail, on a device with less memory to spare than the one it was tuned on.
///
/// ## On `n_ubatch`
///
/// Section 5 and 43. `n_ubatch` is the *physical* micro-batch llama.cpp splits
/// a logical batch into internally — the size the compute buffers are allocated
/// from. With `n_batch = 128, n_ubatch = 64`, a 128-token batch is a supported
/// submission that the scheduler runs as two micro-batches. Splitting to 64
/// here would double the number of calls and change nothing else, so the
/// planner does not do it: the application-level invariant is
/// `submitted n_tokens <= n_batch`.
///
/// It is still taken as a parameter, and it is load-bearing — see
/// ``chunkSize(nBatch:nUBatch:)``.
public enum PromptDecodeChunkPlanner {

    /// Used only when the runtime reports nothing usable, which should not
    /// happen — a context always has an `n_batch`. Small enough to be safe
    /// under any configuration rather than tuned for throughput.
    public static let fallbackChunkSize = 32

    /// How many tokens may go into one `llama_decode`.
    ///
    /// Section 6: one policy, one place. No literal batch size appears anywhere
    /// else in the decode path.
    ///
    /// `n_ubatch` does not reduce the answer — llama.cpp micro-batches
    /// internally, so a chunk of `n_batch` is a valid submission whatever the
    /// micro-batch is. It is consulted only when `n_batch` is missing, where it
    /// is a better guess than a constant because it is at least a real number
    /// this context reported.
    public static func chunkSize(nBatch: Int, nUBatch: Int) -> Int {
        if nBatch > 0 { return nBatch }
        if nUBatch > 0 { return nUBatch }
        return fallbackChunkSize
    }

    /// Plans the prefill.
    ///
    /// `basePosition` is where this prompt begins in the sequence. Section 10:
    /// zero for a fresh context, and the current runtime clears the KV cache
    /// before every turn so zero is what it passes — but the parameter exists
    /// rather than the assumption, because a caller that starts reusing a
    /// prefix would otherwise silently write a second run of tokens over
    /// positions that already hold something.
    ///
    /// Returns an empty plan for an empty prompt. Section 64: a zero-token
    /// batch must never reach `llama_decode`, and the caller checks
    /// `chunks.isEmpty` rather than discovering it inside C.
    public static func plan(
        tokenCount: Int,
        basePosition: Int = 0,
        nBatch: Int,
        nUBatch: Int
    ) -> PromptDecodePlan {
        let size = chunkSize(nBatch: nBatch, nUBatch: nUBatch)
        guard tokenCount > 0 else {
            return PromptDecodePlan(
                chunks: [], chunkSize: size, tokenCount: 0, basePosition: basePosition
            )
        }

        // Ceiling division rather than a count accumulated in the loop: a
        // chunk needs to know whether it is the last one *while it is being
        // built*, because that is what decides its logits flag.
        let count = (tokenCount + size - 1) / size
        var chunks: [PromptDecodeChunk] = []
        chunks.reserveCapacity(count)

        var start = 0
        var index = 0
        while start < tokenCount {
            // Half-open, so the next chunk starts exactly where this one ends.
            // Section 66: no token is both the last of one chunk and the first
            // of the next, which would decode it twice at two positions.
            let end = min(start + size, tokenCount)
            chunks.append(
                PromptDecodeChunk(
                    index: index,
                    chunkCount: count,
                    tokenStart: start,
                    tokenEndExclusive: end,
                    positionStart: basePosition + start,
                    positionEndInclusive: basePosition + end - 1,
                    isFinalPromptChunk: end == tokenCount
                )
            )
            start = end
            index += 1
        }

        return PromptDecodePlan(
            chunks: chunks,
            chunkSize: size,
            tokenCount: tokenCount,
            basePosition: basePosition
        )
    }
}

/// A prefill that stopped part-way.
///
/// Section 28 and 29. The user-facing sentence stays short, because "chunk 4 of
/// 10" means nothing to somebody trying to send a message — but the index, the
/// token range and the return code are what a reader of the log needs, and
/// losing them to a generic error is how the previous investigation started.
public struct PromptPrefillFailure: Hashable, Sendable, Error {
    public var chunkIndex: Int
    public var chunkCount: Int
    public var tokenStart: Int
    public var tokenEndInclusive: Int
    public var result: LocalDecodeResult

    public init(
        chunkIndex: Int,
        chunkCount: Int,
        tokenStart: Int,
        tokenEndInclusive: Int,
        result: LocalDecodeResult
    ) {
        self.chunkIndex = chunkIndex
        self.chunkCount = chunkCount
        self.tokenStart = tokenStart
        self.tokenEndInclusive = tokenEndInclusive
        self.result = result
    }

    /// For the diagnostic log.
    public var diagnosticDescription: String {
        "Prompt decode failed at chunk \(chunkIndex + 1)/\(chunkCount). "
            + "Tokens: \(tokenStart)...\(tokenEndInclusive). "
            + "llama_decode return code: \(result.symbol)"
    }

    /// For the person waiting on a reply.
    ///
    /// `noKVSlot` keeps its own explanation: "there was no room in the context"
    /// is both true and actionable, and flattening it into the generic sentence
    /// would throw away the one case the user can do something about.
    public var userDescription: String {
        switch result {
        case .noKVSlot: return result.explanation
        default: return "The local model failed while processing the prompt."
        }
    }
}
