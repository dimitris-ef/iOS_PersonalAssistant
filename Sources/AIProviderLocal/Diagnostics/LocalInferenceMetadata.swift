import Foundation

/// Everything a diagnostic line is allowed to say.
///
/// ## The privacy design, in one sentence
///
/// There is no key for the user's words.
///
/// Section 85 asks for a typed allowlist rather than `[String: Any]`, and
/// section 84 asks for a redaction layer so that call sites do not have to
/// remember the rules. A closed enum of keys is both at once: a call site that
/// tries to log a prompt does not get a redacted line, it gets a compile error.
/// Counts, sizes, identifiers and configuration numbers are here. Text the user
/// typed, text the model produced, memories, tool results and credentials have
/// no representation in this type at all.
///
/// The `sanitizing:` initialiser exists for the one place values arrive as
/// strings from outside — and for the privacy tests, which need something to
/// attempt a forbidden write against.
public enum LocalInferenceMetadataKey: String, Hashable, Sendable, CaseIterable, Codable {

    // MARK: Process and build

    case appVersion
    case buildNumber
    case osVersion
    case deviceModel
    case physicalMemoryBytes
    case processorCount
    case thermalState
    case verboseLoggingEnabled

    // MARK: Provider and model

    case providerID
    case modelID
    case modelDisplayFamily
    case architecture
    case quantization
    case modelFileBytes
    /// Section 20 and 86: a path *relative to the managed models directory*, or
    /// a file name. Never the container path — it is different on every
    /// install, useless to the reader, and a needless disclosure in a log the
    /// user may share.
    case managedRelativePath
    case installed
    case selected
    case compatibility
    case ggufVersion
    case tensorCount
    case tokenizerFamily
    case hasEmbeddedChatTemplate
    case parameterCount
    case trainedContextLength

    // MARK: Runtime

    case runtimeIncluded
    case runtimeInitialized
    case runtimeImplementation
    case llamaCppVersion
    case llamaCppCommit
    case requestedContextSize
    case actualContextSize
    case batchSize
    case microBatchSize
    case threadCount
    case batchThreadCount
    case compiledWithMetal
    case requestedGPUOffload
    case runtimeGPUOffloadActive
    case gpuLayers

    // MARK: Memory

    case estimatedModelMemoryBytes
    case estimatedKVCacheBytes
    case estimatedComputeBufferBytes
    case estimatedRuntimeOverheadBytes
    case estimatedTotalBytes
    /// Section 33: named an estimate because that is what it is. iOS does not
    /// hand an app its jetsam headroom.
    case availableMemoryEstimateBytes
    case kvCacheIsMeasured

    // MARK: Diagnostic overrides

    case cpuOnly
    case conservativeContext
    case conservativeBatch
    case threadMode

    // MARK: Prompt — counts only

    case messageCount
    case systemMessageCount
    case userMessageCount
    case assistantMessageCount
    case toolMessageCount
    case characterCount
    case estimatedTokenCount
    case tokenCount
    case contextBudget
    case generationReserve
    case promptWasTrimmed
    case droppedTurnCount
    case toolCount
    case retrievedMemoryCount
    case templateName
    case templateSource

    // MARK: Generation

    case generatedTokenCount
    case promptTokenCount
    case latencyMs
    case elapsedSeconds
    case tokensPerSecond
    case stopReason
    case cancelled
    case runtimeHealthy

    // MARK: Failures

    case stageName
    case errorKind
    /// A short, authored explanation. Passed through the redactor and capped —
    /// it is the one free-text field, and free text is where a prompt fragment
    /// would sneak in.
    case errorReason
    case nativeCode
    case nativeSymbol

    // MARK: The decode boundary — sections 9 to 21 and 54 to 64

    /// `assistant_chat` or `minimal_native_decode` (section 43).
    case origin
    case llamaCppBuildNumber
    case llamaCppBuildTarget
    case llamaCppSystemInfo
    /// Bumped every time a context is created, so a report can say which
    /// context a decode belonged to without printing a pointer (section 22).
    case contextGeneration
    case batchTokenCount
    case batchNTokens
    case batchAllocatedCapacity
    case batchUsesTokens
    case batchUsesEmbeddings
    case batchConstruction
    case positionsMode
    case positionCount
    case firstPosition
    case lastPosition
    case sequenceMode
    case sequenceCount
    case logitsPointerPresent
    case logitsFlagCount
    case logitsTrueCount
    case validationResult
    case decodeReturnCode
    case decodeElapsedMs
    case firstTokenIDs
    case lastTokenIDs
    case remainingContextCapacity
    case kvUsedCells
    case kvTokenCount
    case kvSequenceCount
    /// Section 47: the real footprint, from `task_info`, distinct from every
    /// estimate in this file.
    case processMemoryFootprintBytes
    case nativeLogLevel
    case decodeConcurrentOperations
    case minimalTestResult

    // MARK: Chunked prefill

    /// Zero-based, in decode order.
    case chunkIndex
    case chunkCount
    case chunkTokenCount
    /// Index into the prompt's token array, not a position. The two differ
    /// whenever `basePosition` is non-zero, and conflating them is how a second
    /// run of tokens ends up written over positions that already hold
    /// something.
    case tokenStart
    case tokenEndInclusive
    case isFinalPromptChunk
    /// How many chunks the whole prompt was split into. Recorded at the plan
    /// as well as on every chunk, so a truncated log still says how many were
    /// expected (section 73).
    case plannedChunks
    /// The per-decode token limit the plan was cut to — `n_batch`, in practice.
    case chunkSize
    /// Where this prompt starts in the sequence.
    case basePosition
    /// Where generation will start. Section 61.
    case nextPosition
    case tokensDecoded

    // MARK: Local tool calling

    /// The catalog's `toolSupport` for the model that ran: supported,
    /// experimental or unsupported.
    case toolCapability
    /// Whether the latest user message read like a request to act. A heuristic,
    /// and named as one — it gates containment, never behaviour.
    case actionIntentLikely
    /// What the raw output was classified as. Section 37.
    case parserResult
    /// 0 for the first generation, 1 for the single repair.
    case repairAttempt
    case repairResult
    /// The tool name the model chose — a name from the app's own catalog, never
    /// anything the model invented, because an unknown name never gets this far.
    case selectedTool
    case toolCallCount
    /// What kind of thing the request asked for — reminder, memory, or other.
    /// Recorded so a wrong-tool refusal can be read back later without the
    /// message that caused it.
    case actionCategory
    /// Why the model has the capability it has (section 4). "Chat only" with no
    /// reason is unarguable; with a reason it is checkable.
    case capabilitySource

    // MARK: The universal semantic action protocol
    //
    // Section 64 and 65 govern every key here: symbols and counts only. A
    // reader can tell that a reminder was asked for, that the model named a
    // field it may not use, and which field name it was — and cannot recover
    // the reminder's title, the user's sentence, or a fabricated identifier's
    // value.

    /// The semantic intent the model produced — `reminder.create` and friends.
    case semanticIntent
    /// What the generation was classified as under the semantic protocol.
    case semanticOutcome
    /// Whether the generation produced something the app can act on.
    /// Section 25 of Part 2, and section 47 of Part 3.
    case semanticParseSuccess
    /// Which contract rule refused it, as a symbol.
    case semanticValidation
    /// How many fields the action carried. A count, never the values.
    case semanticFieldCount
    /// The offending key when a model reached for an implementation detail.
    /// The *name*, which is protocol vocabulary, never the value it carried.
    case semanticRejectedField
    /// Which category of implementation detail that key was.
    case semanticRejectedFieldCategory
    /// What resolution produced: a call, a question, or a failure.
    case semanticResolution
    /// Why the app had to ask the user before acting.
    case clarificationReason
    /// How a time expression was read — relative offset, day and time, and so
    /// on. Not the expression, and not the resulting instant.
    case timeExpressionReading
    /// Whether a time expression resolved at all.
    case timeExpressionResolved
    /// What kind of thing was looked up.
    case resourceKind
    /// How many things matched a description: 0, 1, or more.
    case resourceMatchCount
    /// Whether the semantic protocol was the one in force this turn, as opposed
    /// to the older direct tool-schema prompt.
    case semanticProtocolActive

    // MARK: Constrained generation
    //
    // Section 25: whether the constraint was in force, what kind it was, and
    // how wide it was. Never the grammar itself and never the generated JSON —
    // a grammar is authored text, but it is long, and a log that carries one
    // per generation is a log nobody reads.

    /// True when a grammar was enforced for this generation. False is the
    /// fail-closed record, never a note that generation continued freely.
    case constrainedGenerationActive
    /// `gbnf` for the llama.cpp backend. A symbol, not a claim about others.
    case constraintType
    /// How many intents the constraint permitted — the full protocol, or the
    /// one family a repair was narrowed to.
    case constraintIntentCount
    /// Whether the constrained output parsed into a semantic action.
    case semanticParseSucceeded
    /// The intent a generation produced, when it produced one.
    case generatedIntent

    // MARK: The action router and its backend
    //
    // Section 22 and 23 again: symbols only. "reminder" is a family name the
    // app chose; the sentence that made it a reminder never leaves the router.

    /// chat or action.
    case routerDecision
    /// Which phrase family carried an action decision.
    case routerEvidence
    /// How sure the router was. The router only ever routes on high-confidence
    /// evidence, so the field exists to make the line self-describing rather
    /// than to record a spectrum.
    case routingConfidence
    /// Which action backend was selected. An identifier this app assigned.
    case actionBackendID
    /// available or unavailable.
    case actionBackendAvailability
    /// Why a backend is unavailable, or which structured category a generation
    /// failed under. Authored text, never model output and never user text.
    case actionBackendReason

    // MARK: The dedicated action model (Part 3)
    //
    // Section 41: a stable model identifier, never a filename — a path is
    // different on every install, useless to a reader, and a needless
    // disclosure in a log somebody may share.

    /// Which model was selected to interpret actions.
    case actionModelID
    /// unloaded / loading / loaded / failed.
    case actionModelRuntimeState
    /// Section 45. Milliseconds to open the action model.
    case actionModelLoadMs
    /// Milliseconds spent generating one semantic action. Deliberately excludes
    /// everything downstream: platform execution is not model latency.
    case semanticGenerationMs

    // MARK: Acceleration and throughput

    /// True when this load ran the product's own configuration rather than a
    /// diagnostic handicap (section 45).
    case productionProfile
    /// Layers actually offloaded, where the runtime will say. Absent rather
    /// than zero when it will not (section 44) — "Unknown" and "none" are
    /// different answers and only one of them is a problem.
    case actualGPULayers
    case requestedGPULayers
    /// Prompt prefill throughput, measured (section 39).
    case promptEvaluationTokens
    case promptEvaluationDurationMs
    case promptEvaluationTokensPerSecond
    /// Generation throughput, measured, excluding the prompt (section 40).
    case generationDurationMs
    case generationTokensPerSecond

    // MARK: Session

    case clean
    case reason
    case previousSessionID
    case diagnosticWriterFailed
}

/// A value a diagnostic line may carry.
public enum LocalInferenceMetadataValue: Hashable, Sendable {
    case int(Int)
    case int64(Int64)
    case double(Double)
    case bool(Bool)
    case text(String)
}

/// A bag of allowlisted key/value pairs.
public struct LocalInferenceMetadata: Hashable, Sendable {
    public private(set) var values: [LocalInferenceMetadataKey: LocalInferenceMetadataValue]

    public static let empty = LocalInferenceMetadata()

    public init(_ values: [LocalInferenceMetadataKey: LocalInferenceMetadataValue] = [:]) {
        self.values = values.mapValues(LocalInferenceRedaction.sanitize)
    }

    public subscript(key: LocalInferenceMetadataKey) -> LocalInferenceMetadataValue? {
        values[key]
    }

    public var isEmpty: Bool { values.isEmpty }

    // Convenience setters. They return `self` so a call site reads as one
    // expression rather than four statements around a `var`.
    public func setting(_ key: LocalInferenceMetadataKey, _ value: Int) -> Self {
        setting(key, .int(value))
    }
    public func setting(_ key: LocalInferenceMetadataKey, _ value: Int64) -> Self {
        setting(key, .int64(value))
    }
    public func setting(_ key: LocalInferenceMetadataKey, _ value: Double) -> Self {
        setting(key, .double(value))
    }
    public func setting(_ key: LocalInferenceMetadataKey, _ value: Bool) -> Self {
        setting(key, .bool(value))
    }
    public func setting(_ key: LocalInferenceMetadataKey, _ value: String) -> Self {
        setting(key, .text(value))
    }
    public func setting(_ key: LocalInferenceMetadataKey, _ value: LocalInferenceMetadataValue) -> Self {
        var copy = self
        copy.values[key] = LocalInferenceRedaction.sanitize(value)
        return copy
    }

    /// Optional-tolerant, so a caller does not branch around every unknown.
    public func setting(_ key: LocalInferenceMetadataKey, ifPresent value: Int?) -> Self {
        value.map { setting(key, $0) } ?? self
    }
    public func setting(_ key: LocalInferenceMetadataKey, ifPresent value: Int64?) -> Self {
        value.map { setting(key, $0) } ?? self
    }
    public func setting(_ key: LocalInferenceMetadataKey, ifPresent value: String?) -> Self {
        value.map { setting(key, $0) } ?? self
    }

    public func merging(_ other: LocalInferenceMetadata) -> Self {
        var copy = self
        for (key, value) in other.values { copy.values[key] = value }
        return copy
    }

    /// Builds metadata from string keys, dropping anything not on the allowlist.
    ///
    /// The only entry point that takes untyped input. It exists because section
    /// 107 asks for a test that *attempts* to log `prompt`, `response`,
    /// `apiKey` and `memory` and proves the values never reach the file — and a
    /// vocabulary that makes the attempt impossible to express leaves nothing
    /// to test. This is that door, and it is locked: an unknown key is
    /// discarded along with its value, silently and by construction.
    public init(sanitizing raw: [String: String]) {
        var accepted: [LocalInferenceMetadataKey: LocalInferenceMetadataValue] = [:]
        for (key, value) in raw {
            guard !LocalInferenceRedaction.isForbiddenKey(key) else { continue }
            guard let allowed = LocalInferenceMetadataKey(rawValue: key) else { continue }
            accepted[allowed] = LocalInferenceRedaction.sanitize(.text(value))
        }
        self.values = accepted
    }
}

/// The last line of defence.
///
/// The allowlist above is the real protection; this catches the two things a
/// closed enum cannot. First, free text: `errorReason` holds authored
/// sentences, but an error message that ever interpolated user input would
/// carry it into the log, so text is capped and scanned. Second, untyped input
/// through `init(sanitizing:)`.
///
/// Being explicit about the limit: this is not a content classifier and does
/// not pretend to be one. It rejects keys that name private things and truncates
/// values that are long enough to be prose. The guarantee that prompts are never
/// logged comes from there being no key for them, not from here.
public enum LocalInferenceRedaction {

    /// Substrings that disqualify a key outright, whatever its value.
    static let forbiddenKeyFragments = [
        "prompt", "content", "response", "memory", "message", "text", "transcript",
        "apikey", "api_key", "token", "credential", "authorization", "bearer",
        "secret", "password", "conversation", "history", "reply", "answer",
    ]

    /// Free text longer than this is not a diagnostic value, it is prose.
    public static let maximumTextLength = 200

    public static func isForbiddenKey(_ key: String) -> Bool {
        let lowered = key.lowercased()
        // `tokenCount` and `tokenizerFamily` contain "token" and are perfectly
        // safe, so an exact allowlist match wins over the fragment scan. The
        // fragment scan only decides the fate of keys that are not on the
        // allowlist at all.
        if LocalInferenceMetadataKey(rawValue: key) != nil { return false }
        return forbiddenKeyFragments.contains { lowered.contains($0) }
    }

    static func sanitize(_ value: LocalInferenceMetadataValue) -> LocalInferenceMetadataValue {
        guard case .text(let text) = value else { return value }
        return .text(sanitizeText(text))
    }

    /// Collapses whitespace, strips control characters and caps the length.
    ///
    /// Newlines matter more than they look: this is JSONL, one record per line,
    /// and a raw newline inside a value would split one event into two lines,
    /// the second of which is unparseable. The encoder escapes them anyway;
    /// removing them keeps the file readable in a terminal as well.
    public static func sanitizeText(_ text: String) -> String {
        let collapsed = text
            .components(separatedBy: .controlCharacters)
            .joined(separator: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count > maximumTextLength else { return collapsed }
        return String(collapsed.prefix(maximumTextLength - 1)) + "…"
    }
}
