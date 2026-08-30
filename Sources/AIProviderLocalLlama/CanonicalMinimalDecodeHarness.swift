import AIProviderLocal
import AssistantDomain
import Foundation

#if canImport(llama)
import llama
#endif

/// One `llama_decode`, with as little of this app around it as possible.
///
/// ## What it is for
///
/// Section 40. There are now two ways to reach a first native decode:
///
/// - the **production** path — a real conversation, the chat template, the
///   assembled context, the production batch builder, the loaded context;
/// - this **minimal** path — a fixed string, its own small context, and batch
///   construction written to follow upstream's own prefill sample.
///
/// If the minimal decode succeeds and the production one dies, the difference
/// is in what production does *around* the call: the prompt, the size, the
/// context it reused. If both die, the problem is lower — the model, the
/// framework, the device. Neither outcome is proof on its own, and the report
/// wording says so; it is evidence, and evidence is what this pass exists to
/// produce.
///
/// ## Deliberately duplicated
///
/// Section 39 is explicit that the minimal path must not reuse the production
/// batch builder, because the production builder is one of the suspects. The
/// batch below is therefore built here, by hand, rather than through
/// ``LlamaDecodeBatch``. Two implementations of the same idea is normally a
/// smell; here it is the instrument.
///
/// ## What it does not touch
///
/// Section 35 and 83: no `AssistantEngine`, no memory retrieval, no tools, no
/// conversation, no chat template, no settings beyond which model to open. The
/// only input is a constant in this file.
public actor CanonicalMinimalDecodeHarness {

    /// Section 36. A constant, in the source, so no user content can reach it.
    public static let diagnosticPrompt = "Hello"

    /// Section 38. Small, but not so small it is invalid — a context has to
    /// hold the prompt and leave the model somewhere to put its state.
    public static let contextLength = 256
    public static let batchSize = 64

    private let diagnostics: any LocalInferenceDiagnosticSink

    public init(diagnostics: any LocalInferenceDiagnosticSink) {
        self.diagnostics = diagnostics
    }

    /// Loads, tokenizes, decodes once, and tears down.
    ///
    /// Section 70: this opens its **own** model and context rather than
    /// borrowing the runtime's. Two contexts on one model would be a second
    /// user of state `llama_decode` mutates, which is precisely the concurrency
    /// hazard being audited — so the caller is required to have unloaded first,
    /// and this allocates and frees everything it touches.
    public func run(modelURL: URL, modelID: AIModelIdentifier) async -> MinimalDecodeOutcome {
        #if canImport(llama)
        let session = diagnostics.criticalEnter(
            .inference,
            metadata: LocalInferenceMetadata()
                .setting(.origin, "minimal_native_decode")
                .setting(.modelID, modelID.rawValue)
                .setting(.managedRelativePath, modelURL.lastPathComponent)
        )
        var finished = false
        defer {
            if !finished {
                diagnostics.criticalFailure(
                    .inference, operation: session,
                    metadata: LocalInferenceMetadata().setting(.errorKind, "threw")
                )
            }
        }

        LlamaBackend.start()

        // 1. Model.
        var modelParams = llama_model_default_params()
        // CPU only, always. The test exists to remove variables, and a GPU
        // offload is the largest one available (section 37's "deliberately
        // small safe context" has the same motivation).
        modelParams.n_gpu_layers = 0
        modelParams.check_tensors = false

        let loadOperation = diagnostics.criticalEnter(
            .modelLoad,
            metadata: LocalInferenceMetadata()
                .setting(.origin, "minimal_native_decode")
                .setting(.gpuLayers, 0)
        )
        guard let model = modelURL.path.withCString({ llama_model_load_from_file($0, modelParams) })
        else {
            diagnostics.criticalFailure(
                .modelLoad, operation: loadOperation,
                metadata: LocalInferenceMetadata().setting(.errorKind, "loadFailed")
            )
            finished = true
            diagnostics.criticalFailure(.inference, operation: session, metadata: .empty)
            return .failed(stage: .modelLoad, reason: "The model file could not be opened.")
        }
        defer { llama_model_free(model) }
        diagnostics.criticalExit(.modelLoad, operation: loadOperation, metadata: .empty)

        // 2. Context.
        var contextParams = llama_context_default_params()
        contextParams.n_ctx = UInt32(Self.contextLength)
        contextParams.n_batch = UInt32(Self.batchSize)
        contextParams.n_ubatch = UInt32(Self.batchSize)
        contextParams.n_threads = 2
        contextParams.n_threads_batch = 2

        let contextOperation = diagnostics.criticalEnter(
            .contextCreate,
            metadata: LocalInferenceMetadata()
                .setting(.origin, "minimal_native_decode")
                .setting(.requestedContextSize, Self.contextLength)
                .setting(.batchSize, Self.batchSize)
                .setting(.microBatchSize, Self.batchSize)
                .setting(.threadCount, 2)
        )
        guard let context = llama_init_from_model(model, contextParams) else {
            diagnostics.criticalFailure(
                .contextCreate, operation: contextOperation,
                metadata: LocalInferenceMetadata().setting(.errorKind, "insufficientMemory")
            )
            finished = true
            diagnostics.criticalFailure(.inference, operation: session, metadata: .empty)
            return .failed(stage: .contextCreate, reason: "The context could not be created.")
        }
        defer { llama_free(context) }
        diagnostics.criticalExit(
            .contextCreate,
            operation: contextOperation,
            metadata: LocalInferenceMetadata()
                .setting(.actualContextSize, Int(llama_n_ctx(context)))
        )

        // 3. Tokenize the fixed string.
        guard let vocab = llama_model_get_vocab(model) else {
            finished = true
            diagnostics.criticalFailure(.inference, operation: session, metadata: .empty)
            return .failed(stage: .tokenize, reason: "The model has no vocabulary.")
        }
        let tokenizeOperation = diagnostics.criticalEnter(
            .tokenize,
            metadata: LocalInferenceMetadata()
                .setting(.characterCount, Self.diagnosticPrompt.count)
        )
        var tokens = [llama_token](repeating: 0, count: 64)
        let written = Self.diagnosticPrompt.withCString { pointer in
            llama_tokenize(
                vocab, pointer, Int32(Self.diagnosticPrompt.utf8.count),
                &tokens, Int32(tokens.count), true, true
            )
        }
        guard written > 0 else {
            diagnostics.criticalFailure(
                .tokenize, operation: tokenizeOperation,
                metadata: LocalInferenceMetadata().setting(.nativeCode, Int(written))
            )
            finished = true
            diagnostics.criticalFailure(.inference, operation: session, metadata: .empty)
            return .failed(stage: .tokenize, reason: "The test string produced no tokens.")
        }
        tokens = Array(tokens[0..<Int(written)])
        diagnostics.criticalExit(
            .tokenize,
            operation: tokenizeOperation,
            metadata: LocalInferenceMetadata().setting(.tokenCount, tokens.count)
        )

        // 4. The batch, built here rather than through the production helper.
        var batch = llama_batch_init(Int32(tokens.count), 0, 1)
        defer { llama_batch_free(batch) }
        guard
            let tokenBuffer = batch.token,
            let positionBuffer = batch.pos,
            let sequenceCountBuffer = batch.n_seq_id,
            let sequenceBuffer = batch.seq_id,
            let logitsBuffer = batch.logits
        else {
            finished = true
            diagnostics.criticalFailure(.inference, operation: session, metadata: .empty)
            return .failed(
                stage: .minimalPromptDecode, reason: "The batch could not be allocated."
            )
        }
        for index in 0..<tokens.count {
            tokenBuffer[index] = tokens[index]
            positionBuffer[index] = llama_pos(index)
            sequenceCountBuffer[index] = 1
            sequenceBuffer[index]?[0] = 0
            logitsBuffer[index] = index == tokens.count - 1 ? 1 : 0
        }
        batch.n_tokens = Int32(tokens.count)

        let descriptor = LocalDecodeBatchDescriptor(
            nTokens: Int(batch.n_tokens),
            tokenBufferCount: tokens.count,
            allocatedCapacity: tokens.count,
            contextBatchLimit: Int(llama_n_batch(context)),
            contextSize: Int(llama_n_ctx(context)),
            positionCount: tokens.count,
            firstPosition: 0,
            lastPosition: tokens.count - 1,
            sequenceCount: tokens.count,
            logitsCount: tokens.count,
            logitsTrueCount: 1
        )
        let preflight = descriptor.metadata()
            .setting(.origin, "minimal_native_decode")
            .setting(.modelID, modelID.rawValue)
            .setting(.llamaCppVersion, LlamaCppRuntime.linkedVersion)
            .setting(.llamaCppBuildNumber, LlamaCppRuntime.pinnedVersion)
            .setting(.batchConstruction, "canonical_minimal_harness")
            .setting(.cpuOnly, true)
            .setting(.gpuLayers, 0)
            .setting(.threadCount, 2)
            .setting(.processMemoryFootprintBytes, LlamaProcessMemory.footprintBytes() ?? 0)
        diagnostics.info(
            .decodePreflight, category: .runtime, stage: .minimalPromptDecode,
            metadata: preflight
        )

        if let failure = LocalDecodeBatchValidator.validate(descriptor) {
            diagnostics.problem(
                .decodeBatchValidation, category: .runtime, stage: .minimalPromptDecode,
                metadata: LocalInferenceMetadata()
                    .setting(.validationResult, failure.symbol)
                    .setting(.errorReason, failure.description)
            )
            finished = true
            diagnostics.criticalFailure(.inference, operation: session, metadata: .empty)
            return .failed(stage: .minimalPromptDecode, reason: failure.description)
        }

        // 5. Exactly one decode.
        let operation = diagnostics.criticalEnter(.minimalPromptDecode, metadata: preflight)
        let startedAt = DispatchTime.now()
        let status = llama_decode(context, batch)
        let elapsed = Int(LlamaCppRuntime.milliseconds(since: startedAt))
        let result = LocalDecodeResult(returnCode: Int(status))
        let outcome = LocalInferenceMetadata()
            .setting(.decodeReturnCode, Int(status))
            .setting(.validationResult, result.symbol)
            .setting(.decodeElapsedMs, elapsed)

        if result.isSuccess {
            diagnostics.criticalExit(
                .minimalPromptDecode, operation: operation, metadata: outcome
            )
        } else {
            diagnostics.criticalFailure(
                .minimalPromptDecode, operation: operation,
                metadata: outcome.setting(.errorReason, result.explanation)
            )
        }

        finished = true
        diagnostics.criticalExit(
            .inference, operation: session,
            metadata: outcome.setting(.minimalTestResult, result.symbol)
        )
        diagnostics.info(
            .minimalDecodeTest, category: .runtime,
            metadata: outcome.setting(.minimalTestResult, result.symbol)
        )

        return result.isSuccess
            ? .succeeded(tokenCount: tokens.count, elapsedMs: elapsed)
            : .failed(stage: .minimalPromptDecode, reason: result.explanation)
        #else
        return .unavailable
        #endif
    }
}

/// What the minimal test found. Section 42.
public enum MinimalDecodeOutcome: Hashable, Sendable {
    case succeeded(tokenCount: Int, elapsedMs: Int)
    case failed(stage: LocalInferenceStage, reason: String)
    /// This build has no inference runtime linked.
    case unavailable

    public var summary: String {
        switch self {
        case .succeeded(let tokens, let elapsed):
            return "Succeeded — one decode of \(tokens) tokens in \(elapsed) ms."
        case .failed(let stage, let reason):
            return "Failed during \(stage.rawValue): \(reason)"
        case .unavailable:
            return "This build has no on-device inference runtime."
        }
    }

    public var didSucceed: Bool {
        if case .succeeded = self { return true }
        return false
    }
}
