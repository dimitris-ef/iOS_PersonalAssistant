import Foundation

/// One line in the diagnostic trail.
///
/// ## What this file is for
///
/// The app dies when the first message reaches a local model, and it dies
/// somewhere native where no Swift error is thrown and no console survives. The
/// only thing that can answer "where" is a breadcrumb that reached the
/// filesystem *before* the call that killed the process — so this type is
/// designed around being small, append-only, and parseable from a file whose
/// last line may be half-written.
///
/// ## Why every field is a closed enum
///
/// The stage, the event type, the name and the metadata keys are all `enum`s
/// with a fixed set of cases. That is the privacy design, not a style
/// preference: a call site *cannot* log the user's prompt, because there is no
/// key that would hold it. Section 84 asks for a redaction layer so call sites
/// do not have to remember the rules; a closed vocabulary is the version of
/// that which the compiler enforces.
public struct LocalInferenceDiagnosticEvent: Hashable, Sendable {

    /// The process this event belongs to.
    public let appSessionID: LocalInferenceSessionID
    /// The generation attempt, when there is one. Section 99: several inference
    /// attempts can happen inside one app session, and correlating them is the
    /// difference between "the second message crashed" and "a message crashed".
    public let inferenceSessionID: LocalInferenceSessionID?
    /// Strictly increasing within an app session. Section 3.
    public let sequence: Int
    /// Wall clock, for correlating with anything outside the app.
    public let timestamp: Date
    /// Seconds since the session started. Section 4 — the one that stays
    /// meaningful when two events share a millisecond, and when the wall clock
    /// jumps because the user crossed a time zone mid-generation.
    public let elapsed: TimeInterval
    public let level: LocalInferenceDiagnosticLevel
    public let category: LocalInferenceDiagnosticCategory
    public let type: LocalInferenceEventType
    public let name: LocalInferenceEventName
    /// The native stage, for `enter`/`exit` and for anything that happened
    /// during one.
    public let stage: LocalInferenceStage?
    /// Pairs an `exit` with its `enter`. Section 16.
    public let operationID: LocalInferenceOperationID?
    public let metadata: LocalInferenceMetadata

    public init(
        appSessionID: LocalInferenceSessionID,
        inferenceSessionID: LocalInferenceSessionID? = nil,
        sequence: Int,
        timestamp: Date,
        elapsed: TimeInterval,
        level: LocalInferenceDiagnosticLevel = .info,
        category: LocalInferenceDiagnosticCategory,
        type: LocalInferenceEventType,
        name: LocalInferenceEventName,
        stage: LocalInferenceStage? = nil,
        operationID: LocalInferenceOperationID? = nil,
        metadata: LocalInferenceMetadata = .empty
    ) {
        self.appSessionID = appSessionID
        self.inferenceSessionID = inferenceSessionID
        self.sequence = sequence
        self.timestamp = timestamp
        self.elapsed = elapsed
        self.level = level
        self.category = category
        self.type = type
        self.name = name
        self.stage = stage
        self.operationID = operationID
        self.metadata = metadata
    }
}

/// An opaque identifier for a session. A UUID, kept behind a type so a session
/// identifier and an operation identifier cannot be swapped by accident.
public struct LocalInferenceSessionID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init() { self.init(rawValue: UUID().uuidString) }

    public var description: String { rawValue }
    /// The first eight characters, for a UI that has one line to spend.
    public var shortDescription: String { String(rawValue.prefix(8)) }
}

/// Identifies one *invocation* of a stage.
///
/// Section 16, and the reason it exists rather than pairing by stage name:
/// `generation_decode` runs once per turn and `model_load` can run twice in a
/// session if the user switches models. Matching an EXIT to the wrong ENTER
/// would report a stage as completed when the process actually died inside it,
/// which is the single most misleading thing this system could do.
public struct LocalInferenceOperationID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    /// Short by design: it appears on every critical line, and a full UUID per
    /// breadcrumb is bytes spent on nothing. Twelve hex characters is far more
    /// than enough to keep the handful of operations alive at one time distinct.
    public init() { self.init(rawValue: String(UUID().uuidString.prefix(13).suffix(12))) }

    public var description: String { rawValue }
}

public enum LocalInferenceDiagnosticLevel: String, Hashable, Sendable, CaseIterable, Codable {
    case debug
    case info
    case warning
    case error
}

public enum LocalInferenceDiagnosticCategory: String, Hashable, Sendable, CaseIterable, Codable {
    case lifecycle
    case model
    case runtime
    case prompt
    case generation
    case memory
    case thermal
    case configuration
    case diagnostics
}

/// Section 2's event types.
public enum LocalInferenceEventType: String, Hashable, Sendable, CaseIterable, Codable {
    case info = "INFO"
    case enter = "ENTER"
    case exit = "EXIT"
    case warning = "WARNING"
    case error = "ERROR"
    case state = "STATE"
}

/// What happened, as a closed vocabulary.
///
/// Separate from ``LocalInferenceEventType`` because "ENTER" says *how* to read
/// a line and this says *what* the line is about. The report renders `ENTER
/// model_load` from the pair.
public enum LocalInferenceEventName: String, Hashable, Sendable, CaseIterable, Codable {
    case appLaunch = "APP_LAUNCH"
    case sessionStart = "SESSION_START"
    case sessionEnd = "SESSION_END"
    case inferenceSessionStart = "INFERENCE_SESSION_START"
    case inferenceSessionEnd = "INFERENCE_SESSION_END"

    case providerSelected = "PROVIDER_SELECTED"
    case localModelSelected = "LOCAL_MODEL_SELECTED"
    case modelPathResolved = "MODEL_PATH_RESOLVED"
    case modelMetadata = "MODEL_METADATA"

    case runtimeAvailability = "RUNTIME_AVAILABILITY"
    case runtimeConfiguration = "RUNTIME_CONFIGURATION"
    case diagnosticOverrides = "DIAGNOSTIC_OVERRIDES"
    case memoryEstimate = "MEMORY_ESTIMATE"

    case loadRequested = "LOAD_REQUESTED"
    case stage = "STAGE"

    case promptMetadata = "PROMPT_METADATA"
    /// The complete immutable snapshot taken immediately before the first
    /// native decode (sections 4 and 46).
    case decodePreflight = "DECODE_PREFLIGHT"
    /// The result of validating the batch in Swift before handing it to C.
    case decodeBatchValidation = "DECODE_BATCH_VALIDATION"
    /// What `llama_decode` returned, when it returned.
    case decodeResult = "DECODE_RESULT"
    /// KV cache summary, before and after.
    case kvCacheState = "KV_CACHE_STATE"
    /// A line llama.cpp itself emitted, through its log callback.
    case nativeLog = "NATIVE_LOG"
    /// The minimal single-decode diagnostic test.
    case minimalDecodeTest = "MINIMAL_DECODE_TEST"
    /// How the prompt was split before any of it was decoded (section 73).
    /// Written once, before the first chunk, so a log that stops half-way still
    /// says how many chunks were expected.
    case promptPrefillPlan = "PROMPT_PREFILL_PLAN"
    /// One chunk's preflight: range, positions, flags (section 30).
    case promptChunk = "PROMPT_CHUNK"
    /// What the model's raw output turned out to be — text, a valid call, a
    /// malformed attempt, or the model reciting its own tool schema.
    case localToolParse = "LOCAL_TOOL_PARSE"
    /// The single constrained repair generation, and what it produced.
    case localToolRepair = "LOCAL_TOOL_REPAIR"
    /// A proposed call refused before validation — an identifier for an
    /// existing resource that no tool result produced.
    case localToolRejected = "LOCAL_TOOL_REJECTED"
    case contextBudgetExceeded = "CONTEXT_BUDGET_EXCEEDED"

    // MARK: The universal semantic action protocol
    //
    // One line per stage, so a device report says exactly how far a request got
    // and where it stopped. Section 61: what the model produced, whether it
    // survived validation, what the app resolved it to, and what execution did
    // are four different facts, and a single "it failed" collapses them.

    /// The app decided this turn was a request to act.
    case semanticActionDetected = "SEMANTIC_ACTION_DETECTED"
    /// What the raw generation turned out to be under the semantic protocol.
    case semanticActionParsed = "SEMANTIC_ACTION_PARSED"
    /// The contract check: allowed fields, required fields, no implementation
    /// details.
    case semanticActionValidated = "SEMANTIC_ACTION_VALIDATED"
    /// The single constrained retry, and what it produced.
    case semanticActionRepaired = "SEMANTIC_ACTION_REPAIRED"
    /// A described thing was looked up in the app's own store.
    case resourceResolution = "RESOURCE_RESOLUTION"
    /// Deterministic resolution finished: a call, a question, or nothing.
    case semanticActionResolved = "SEMANTIC_ACTION_RESOLVED"
    /// Which way a user message was sent: the chat model, or the dedicated
    /// action system.
    case routerDecision = "ROUTER_DECISION"
    /// Which action backend was chosen, and whether it can be used.
    case actionBackend = "ACTION_BACKEND"
    /// The action backend is about to interpret a request.
    case actionProcessingStarted = "SEMANTIC_ACTION_PROCESSING_STARTED"
    /// Whether this action generation is constrained, and by what.
    ///
    /// Section 26: the line that says `active=false` is the fail-closed record.
    /// There is no path in which it is followed by an unconstrained action
    /// generation, which is exactly why it is worth writing down.
    case actionConstrainedGeneration = "ACTION_CONSTRAINED_GENERATION"
    /// Whether the constrained output parsed into a semantic action.
    case semanticParse = "SEMANTIC_PARSE"
    /// It did not produce a usable semantic action.
    case actionBackendFailure = "ACTION_BACKEND_FAILURE"

    // MARK: The dedicated action model (Part 3)
    //
    // Its own vocabulary, deliberately: an action-model load is not a chat
    // model load, and a report that used one name for both would make "which
    // model was it holding when it died" unanswerable.

    /// The user chose which model interprets actions.
    case actionModelSelected = "ACTION_MODEL_SELECTED"
    case actionModelLoadStarted = "ACTION_MODEL_LOAD_STARTED"
    case actionModelLoadCompleted = "ACTION_MODEL_LOAD_COMPLETED"
    case actionModelLoadFailed = "ACTION_MODEL_LOAD_FAILED"
    case actionModelUnloadStarted = "ACTION_MODEL_UNLOAD_STARTED"
    case actionModelUnloadCompleted = "ACTION_MODEL_UNLOAD_COMPLETED"
    case actionModelInferenceStarted = "ACTION_MODEL_INFERENCE_STARTED"
    case actionModelInferenceCompleted = "ACTION_MODEL_INFERENCE_COMPLETED"
    /// The prompt budget for one action generation.
    case actionModelInference = "ACTION_MODEL_INFERENCE"
    /// The resolver produced an `AIToolCall` for the existing pipeline.
    case toolCallCreated = "AITOOLCALL_CREATED"
    /// That call passed the existing schema and argument validation.
    case toolCallValidated = "AITOOLCALL_VALIDATED"

    /// Measured prompt-prefill throughput (section 39). Separate from
    /// generation because the two run differently and one figure describes
    /// neither.
    case promptEvaluation = "PROMPT_EVALUATION"

    case firstToken = "FIRST_TOKEN"
    case generationProgress = "GENERATION_PROGRESS"
    case generationFinished = "GENERATION_FINISHED"
    case generationFailed = "GENERATION_FAILED"
    case generationCancelled = "GENERATION_CANCELLED"

    case nativeError = "NATIVE_ERROR"
    case memoryWarning = "MEMORY_WARNING"
    case thermalStateChanged = "THERMAL_STATE_CHANGED"
    case writerFailure = "WRITER_FAILURE"
}

/// The native stages worth a breadcrumb.
///
/// Section 27 is the reason `modelLoad` and `contextCreate` are separate and
/// not one opaque "load": `llama_model_load_from_file` maps the weights and
/// `llama_init_from_model` allocates the KV cache, and those fail for different
/// reasons. Collapsing them would throw away the distinction the whole
/// investigation turns on.
public enum LocalInferenceStage: String, Hashable, Sendable, CaseIterable, Codable {
    case modelLoad = "model_load"
    case contextCreate = "context_create"
    case contextDestroy = "context_destroy"
    case modelUnload = "model_unload"
    case promptConstruct = "prompt_construct"
    case chatTemplate = "chat_template"
    case tokenize = "tokenize"
    /// The first `llama_decode` of the turn — the one that allocates the
    /// compute buffers, and the current prime suspect.
    case promptDecode = "prompt_decode"
    /// One `llama_decode` of one slice of the prompt.
    ///
    /// Nested inside `prompt_decode`, which now spans the whole prefill rather
    /// than a single call (section 34). Two levels because they answer
    /// different questions: the outer one says the process died reading the
    /// prompt, and the inner one says it died on chunk 5 of 10 at tokens
    /// 640–767 — and the second is only recoverable if it is written per chunk.
    case promptDecodeChunk = "prompt_decode_chunk"
    /// The one decode the minimal diagnostic harness performs. Deliberately a
    /// distinct stage from `prompt_decode` so a recovery report can say which
    /// of the two paths the process died in (section 42).
    case minimalPromptDecode = "minimal_prompt_decode"
    /// The sampling loop as a whole. Deliberately not per token: a breadcrumb
    /// per token would be thousands of `fsync` calls and would change the
    /// timing of the thing being measured (section 40).
    case generationDecode = "generation_decode"
    /// The whole generation, from prompt render to output. Nests the above.
    case generation = "generation"
    /// The whole attempt, including a lazy load. Nests everything.
    case inference = "inference"

    /// What the recovery screen says happened.
    public var displayName: String {
        switch self {
        case .modelLoad: return "Loading the model file"
        case .contextCreate: return "Allocating the model's context"
        case .contextDestroy: return "Releasing the context"
        case .modelUnload: return "Unloading the model"
        case .promptConstruct: return "Building the prompt"
        case .chatTemplate: return "Applying the chat template"
        case .tokenize: return "Tokenizing the prompt"
        case .promptDecode: return "Reading the prompt into the model"
        case .promptDecodeChunk: return "Reading one part of the prompt into the model"
        case .minimalPromptDecode: return "The minimal native decode test"
        case .generationDecode: return "Generating the reply"
        case .generation: return "Generation"
        case .inference: return "The whole request"
        }
    }
}
