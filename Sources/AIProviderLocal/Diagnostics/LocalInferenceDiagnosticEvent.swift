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
    case contextBudgetExceeded = "CONTEXT_BUDGET_EXCEEDED"

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
        case .generationDecode: return "Generating the reply"
        case .generation: return "Generation"
        case .inference: return "The whole request"
        }
    }
}
