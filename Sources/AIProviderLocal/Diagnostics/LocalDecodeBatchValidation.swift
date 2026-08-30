import Foundation

/// What is about to be handed to `llama_decode`, described without llama.cpp.
///
/// ## Why this type exists in a target that cannot see llama.h
///
/// Section 28 asks for a validator that runs *before* the native call, and the
/// only useful validator is one that runs in CI. `AIProviderLocalLlama` cannot
/// be tested — there is no iOS-simulator slice of the framework, and CI must
/// never run a real multi-gigabyte decode (section 85). So the shape of the
/// batch is described here, as plain integers, and the bridge fills it in from
/// the real `llama_batch` immediately before the call.
///
/// The validator then checks the arithmetic that a malformed batch would fail,
/// which is the arithmetic a person reading a crash report needs anyway.
public struct LocalDecodeBatchDescriptor: Hashable, Sendable {

    /// `llama_batch.n_tokens`, read back off the struct — not the count the
    /// caller believes it set.
    public var nTokens: Int
    /// How many tokens the Swift side actually put in the buffer.
    public var tokenBufferCount: Int
    /// The capacity the batch was allocated with.
    public var allocatedCapacity: Int
    /// `n_batch` for the context. A batch larger than this cannot be submitted
    /// in one call.
    public var contextBatchLimit: Int
    /// `n_ctx`.
    public var contextSize: Int
    /// True when `batch.token` is non-null.
    public var usesTokens: Bool
    /// True when `batch.embd` is non-null. Exactly one of the two may be set.
    public var usesEmbeddings: Bool
    /// Number of entries behind `batch.pos`, or nil when the pointer is null
    /// and llama.cpp is being asked to infer positions.
    public var positionCount: Int?
    public var firstPosition: Int?
    public var lastPosition: Int?
    /// Entries behind `batch.n_seq_id`, or nil for the null-pointer mode.
    public var sequenceCount: Int?
    /// Entries behind `batch.logits`, or nil for the null-pointer mode.
    public var logitsCount: Int?
    /// How many of those flags are set.
    public var logitsTrueCount: Int?

    public init(
        nTokens: Int,
        tokenBufferCount: Int,
        allocatedCapacity: Int,
        contextBatchLimit: Int,
        contextSize: Int,
        usesTokens: Bool = true,
        usesEmbeddings: Bool = false,
        positionCount: Int? = nil,
        firstPosition: Int? = nil,
        lastPosition: Int? = nil,
        sequenceCount: Int? = nil,
        logitsCount: Int? = nil,
        logitsTrueCount: Int? = nil
    ) {
        self.nTokens = nTokens
        self.tokenBufferCount = tokenBufferCount
        self.allocatedCapacity = allocatedCapacity
        self.contextBatchLimit = contextBatchLimit
        self.contextSize = contextSize
        self.usesTokens = usesTokens
        self.usesEmbeddings = usesEmbeddings
        self.positionCount = positionCount
        self.firstPosition = firstPosition
        self.lastPosition = lastPosition
        self.sequenceCount = sequenceCount
        self.logitsCount = logitsCount
        self.logitsTrueCount = logitsTrueCount
    }

    /// The preflight block (section 46). Counts and sizes; never a token's text.
    public func metadata() -> LocalInferenceMetadata {
        LocalInferenceMetadata()
            .setting(.batchNTokens, nTokens)
            .setting(.batchTokenCount, tokenBufferCount)
            .setting(.batchAllocatedCapacity, allocatedCapacity)
            .setting(.batchSize, contextBatchLimit)
            .setting(.actualContextSize, contextSize)
            .setting(.batchUsesTokens, usesTokens)
            .setting(.batchUsesEmbeddings, usesEmbeddings)
            .setting(.positionsMode, positionCount == nil ? "automatic" : "explicit")
            .setting(.positionCount, ifPresent: positionCount)
            .setting(.firstPosition, ifPresent: firstPosition)
            .setting(.lastPosition, ifPresent: lastPosition)
            .setting(.sequenceMode, sequenceCount == nil ? "default" : "explicit")
            .setting(.sequenceCount, ifPresent: sequenceCount)
            .setting(.logitsPointerPresent, logitsCount != nil)
            .setting(.logitsFlagCount, ifPresent: logitsCount)
            .setting(.logitsTrueCount, ifPresent: logitsTrueCount)
    }
}

/// Why a batch must not be handed to `llama_decode`.
///
/// The header for the pinned revision documents `-1 — invalid input batch` as a
/// *return code*, which means llama.cpp checks some of this itself. Checking it
/// here first is not redundant: a return code arrives only if the library got
/// far enough to return, and the failure being investigated is one where it
/// does not.
public enum LocalDecodeBatchValidationFailure: Hashable, Sendable, CustomStringConvertible {
    case invalidTokenCount(nTokens: Int)
    case tokenBufferMissing
    case tokenCountMismatch(nTokens: Int, buffer: Int)
    case batchExceedsCapacity(nTokens: Int, capacity: Int)
    case batchExceedsContextLimit(nTokens: Int, limit: Int)
    case batchExceedsContextSize(nTokens: Int, contextSize: Int)
    case bothTokensAndEmbeddings
    case neitherTokensNorEmbeddings
    case positionCountMismatch(positions: Int, nTokens: Int)
    case negativePosition(Int)
    case invalidSequenceMetadata(sequences: Int, nTokens: Int)
    case logitsCountMismatch(logits: Int, nTokens: Int)
    case noLogitsRequested

    public var description: String {
        switch self {
        case .invalidTokenCount(let n):
            return "n_tokens is \(n); a batch must carry at least one token"
        case .tokenBufferMissing:
            return "batch.token is null but the batch is in token mode"
        case .tokenCountMismatch(let n, let buffer):
            return "n_tokens is \(n) but the token buffer holds \(buffer)"
        case .batchExceedsCapacity(let n, let capacity):
            return "n_tokens is \(n) but the batch was allocated for \(capacity)"
        case .batchExceedsContextLimit(let n, let limit):
            return "n_tokens is \(n) but n_batch is \(limit)"
        case .batchExceedsContextSize(let n, let size):
            return "n_tokens is \(n) but the context holds \(size)"
        case .bothTokensAndEmbeddings:
            return "batch.token and batch.embd are both set; exactly one may be"
        case .neitherTokensNorEmbeddings:
            return "neither batch.token nor batch.embd is set"
        case .positionCountMismatch(let positions, let n):
            return "batch.pos has \(positions) entries for \(n) tokens"
        case .negativePosition(let position):
            return "position \(position) is negative"
        case .invalidSequenceMetadata(let sequences, let n):
            return "batch.n_seq_id has \(sequences) entries for \(n) tokens"
        case .logitsCountMismatch(let logits, let n):
            return "batch.logits has \(logits) entries for \(n) tokens"
        case .noLogitsRequested:
            return "no token requests logits, so the decode would produce nothing to sample"
        }
    }

    /// A short symbolic name for the log (section 29).
    public var symbol: String {
        switch self {
        case .invalidTokenCount: return "invalidTokenCount"
        case .tokenBufferMissing: return "tokenBufferMissing"
        case .tokenCountMismatch: return "tokenCountMismatch"
        case .batchExceedsCapacity: return "batchExceedsCapacity"
        case .batchExceedsContextLimit: return "batchExceedsContextLimit"
        case .batchExceedsContextSize: return "batchExceedsContextSize"
        case .bothTokensAndEmbeddings: return "bothTokensAndEmbeddings"
        case .neitherTokensNorEmbeddings: return "neitherTokensNorEmbeddings"
        case .positionCountMismatch: return "positionCountMismatch"
        case .negativePosition: return "negativePosition"
        case .invalidSequenceMetadata: return "invalidSequenceMetadata"
        case .logitsCountMismatch: return "logitsCountMismatch"
        case .noLogitsRequested: return "noLogitsRequested"
        }
    }
}

/// Everything about a batch that Swift can check before crossing into C.
///
/// Section 13 and 28. Returns the first failure rather than a list: the caller
/// is going to refuse either way, and the first inconsistency is the one worth
/// reading.
public enum LocalDecodeBatchValidator {

    public static func validate(
        _ batch: LocalDecodeBatchDescriptor
    ) -> LocalDecodeBatchValidationFailure? {
        guard batch.nTokens > 0 else {
            return .invalidTokenCount(nTokens: batch.nTokens)
        }
        // Exactly one input mode. `llama_batch` has both a token and an
        // embedding pointer and llama.cpp branches on which is null; setting
        // both is a state the struct can represent and the library cannot.
        switch (batch.usesTokens, batch.usesEmbeddings) {
        case (true, true): return .bothTokensAndEmbeddings
        case (false, false): return .neitherTokensNorEmbeddings
        default: break
        }
        if batch.usesTokens {
            guard batch.tokenBufferCount > 0 else { return .tokenBufferMissing }
            guard batch.nTokens == batch.tokenBufferCount else {
                return .tokenCountMismatch(
                    nTokens: batch.nTokens, buffer: batch.tokenBufferCount
                )
            }
        }
        guard batch.nTokens <= batch.allocatedCapacity else {
            return .batchExceedsCapacity(
                nTokens: batch.nTokens, capacity: batch.allocatedCapacity
            )
        }
        guard batch.contextBatchLimit <= 0 || batch.nTokens <= batch.contextBatchLimit else {
            return .batchExceedsContextLimit(
                nTokens: batch.nTokens, limit: batch.contextBatchLimit
            )
        }
        guard batch.contextSize <= 0 || batch.nTokens <= batch.contextSize else {
            return .batchExceedsContextSize(
                nTokens: batch.nTokens, contextSize: batch.contextSize
            )
        }

        // The three parallel arrays. Each is optional because llama.cpp accepts
        // a null pointer and infers — but when a pointer *is* supplied it must
        // have exactly `n_tokens` entries, and a short array is a read past the
        // end rather than an error.
        if let positions = batch.positionCount {
            guard positions == batch.nTokens else {
                return .positionCountMismatch(positions: positions, nTokens: batch.nTokens)
            }
            if let first = batch.firstPosition, first < 0 { return .negativePosition(first) }
            if let last = batch.lastPosition, last < 0 { return .negativePosition(last) }
        }
        if let sequences = batch.sequenceCount {
            guard sequences == batch.nTokens else {
                return .invalidSequenceMetadata(sequences: sequences, nTokens: batch.nTokens)
            }
        }
        if let logits = batch.logitsCount {
            guard logits == batch.nTokens else {
                return .logitsCountMismatch(logits: logits, nTokens: batch.nTokens)
            }
            // A prefill that flags nothing decodes fine and then has no logits
            // to sample from, which surfaces much later as a nonsense reply.
            guard (batch.logitsTrueCount ?? 0) > 0 else { return .noLogitsRequested }
        }
        return nil
    }
}

/// How `llama_decode` answered.
///
/// The pinned header documents these distinctly, so section 54 is right that
/// collapsing them loses information: "could not find a KV slot" is a context
/// that is too small, and "invalid input batch" is a bridge bug. Treating both
/// as "the model could not read the prompt" throws away the one word that says
/// which.
public enum LocalDecodeResult: Hashable, Sendable {
    case success
    /// 1 — no KV slot. The context is too small for this batch.
    case noKVSlot
    /// 2 — aborted. Processed micro-batches remain in the context's memory.
    case aborted
    /// -1 — invalid input batch.
    case invalidBatch
    /// < -1 — fatal.
    case fatal(Int)
    /// Anything the header does not document.
    case unknown(Int)

    public init(returnCode: Int) {
        switch returnCode {
        case 0: self = .success
        case 1: self = .noKVSlot
        case 2: self = .aborted
        case -1: self = .invalidBatch
        case ..<(-1): self = .fatal(returnCode)
        default: self = .unknown(returnCode)
        }
    }

    public var isSuccess: Bool { self == .success }

    public var symbol: String {
        switch self {
        case .success: return "success"
        case .noKVSlot: return "noKVSlot"
        case .aborted: return "aborted"
        case .invalidBatch: return "invalidBatch"
        case .fatal: return "fatal"
        case .unknown: return "unknown"
        }
    }

    /// What to tell the user. Different causes, different sentences.
    public var explanation: String {
        switch self {
        case .success:
            return "The prompt was read."
        case .noKVSlot:
            return "There was no room in the model's context for this prompt. "
                + "Try a shorter message, or a model with a larger context."
        case .aborted:
            return "Reading the prompt was interrupted."
        case .invalidBatch:
            return "The prompt was rejected by the inference runtime as malformed. "
                + "This is a bug in MetisAI rather than something you did."
        case .fatal(let code):
            return "The inference runtime reported a fatal error (\(code)) reading the prompt."
        case .unknown(let code):
            return "The inference runtime returned an unrecognised code (\(code))."
        }
    }
}
