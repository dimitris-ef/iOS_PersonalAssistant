import AIProviderLocal
import AssistantAI
import AssistantDomain
import Foundation

#if canImport(llama)
import llama
#endif

/// llama.cpp, behind ``LocalModelRuntime``.
///
/// ## What crosses this boundary
///
/// Going down: a file URL, a context length, chat turns and sampling numbers.
/// Coming back: a `String` and two token counts. Nothing else — no
/// `llama_context`, no `llama_model`, no batch, no token array. Section 3 and
/// the review question in section 138 are the same requirement seen twice, and
/// the way to satisfy it is for the pointers to be `private` fields of an actor
/// that nothing else in the app can name.
///
/// ## Why an actor
///
/// Sections 49 and 50. A `llama_context` holds a KV cache that `llama_decode`
/// mutates in place. Two turns decoding into one context do not produce two
/// slightly-wrong answers; they produce a corrupted cache and, fairly often, a
/// crash inside GGML. Serializing every entry point is the whole defence, and
/// an actor is how Swift expresses it.
///
/// ## Resource ownership
///
/// One rule, applied everywhere (section 117): whoever allocates, releases.
/// ``releaseNativeResources()`` is the only place `llama_free` and
/// `llama_model_free` are called, it is idempotent because it nils what it
/// frees, and every path that can end a model's life goes through it — unload,
/// a failed load, and switching models. Sampler chains are freed by the
/// function that created them, with `defer`, on every exit including throwing
/// ones.
///
/// ## When llama.cpp is not linked
///
/// This type still exists and still compiles. `runtimeAvailability()` reports
/// `unavailable`, loading throws, and the app behaves exactly as it does on a
/// device with no model downloaded — Settings says Local AI needs setting up,
/// and every other provider is unaffected. That is what makes the binary
/// dependency optional without the app growing a second code path.
public actor LlamaCppRuntime: LocalModelRuntime {
    /// The upstream build this adapter was written against.
    ///
    /// Kept next to the code as well as in `Package.swift` so a debug screen or
    /// a crash report can say which llama.cpp is running. It must be updated
    /// together with the pin in the manifest: `llama.h` changes between builds,
    /// and this file names functions a different build may have renamed.
    public static let pinnedVersion = "b10506"

    public nonisolated let runtimeCapabilities = LocalRuntimeCapabilities(
        supportedFormats: [.gguf],
        usesHardwareAcceleration: LlamaCppRuntime.hasMetal,
        // llama.cpp's model loader takes a progress callback that aborts the
        // load by returning false — a real cancellation rather than a flag
        // checked after the fact.
        supportsLoadCancellation: true,
        runtimeName: "llama.cpp",
        runtimeVersion: LlamaCppRuntime.pinnedVersion
    )

    private var loaded: LoadedModelInfo?
    /// Read by the sampling loop between tokens.
    private var cancellationRequested = false
    private var isGenerating = false

    /// Where breadcrumbs go.
    ///
    /// A protocol, so this file contains no file-writing code (section 1) and
    /// no knowledge of where a log lives. Every call on it is synchronous by
    /// contract — an ENTER that suspended before reaching the disk would be an
    /// ENTER that does not survive the call it precedes.
    private let diagnostics: any LocalInferenceDiagnosticSink

    #if canImport(llama)
    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var vocab: OpaquePointer?
    #endif

    public init(diagnostics: any LocalInferenceDiagnosticSink = NullLocalInferenceDiagnosticSink()) {
        self.diagnostics = diagnostics
        #if canImport(llama)
        LlamaBackend.start()
        #endif
    }

    // MARK: Availability

    public func runtimeAvailability() async -> LocalRuntimeAvailability {
        #if canImport(llama)
        return loaded == nil ? .idle : .available
        #else
        return .unavailable(
            reason: "This build does not include the on-device inference runtime."
        )
        #endif
    }

    public func loadedModel() async -> LoadedModelInfo? { loaded }

    // MARK: Loading

    public func loadModel(_ request: LocalModelLoadRequest) async throws -> LoadedModelInfo {
        #if canImport(llama)
        guard FileManager.default.fileExists(atPath: request.fileURL.path) else {
            throw LocalRuntimeError.modelFileMissing(request.fileURL)
        }

        releaseNativeResources()
        loaded = nil
        cancellationRequested = false
        LlamaBackend.loadCancellation.reset()

        var modelParams = llama_model_default_params()
        // Everything on the GPU where there is one. On Apple silicon the CPU
        // and GPU share memory, so a partial offload costs bandwidth without
        // saving any, and the parameter is negative-means-all rather than a
        // layer count this file would have to keep in step with each model.
        //
        // Zero when the caller asked for CPU-only (section 70). Note the two
        // conditions: the build must have Metal *and* the caller must want it,
        // and the log records both separately so "GPU offload was requested"
        // and "GPU offload happened" cannot be confused (section 31).
        let wantsGPU = LlamaCppRuntime.hasMetal && request.gpuOffloadRequested
        modelParams.n_gpu_layers = wantsGPU ? -1 : 0
        // Tensor validation walks every weight. The file has already been
        // checksummed and structurally validated before it was installed, and
        // repeating that on every load would add seconds to opening a model.
        modelParams.check_tensors = false
        modelParams.progress_callback = { _, _ in
            // Returning false aborts the load. Honest about being best-effort:
            // llama.cpp calls back between tensors, so a load stuck inside one
            // large mmap will not notice until it finishes (section 118).
            !LlamaBackend.loadCancellation.isCancelled
        }

        // Section 26. The breadcrumb is on disk before the call, so a process
        // that never comes back leaves `ENTER model_load` as its last word.
        let loadOperation = diagnostics.criticalEnter(
            .modelLoad,
            metadata: LocalInferenceMetadata()
                .setting(.modelID, request.modelID.rawValue)
                .setting(.managedRelativePath, request.fileURL.lastPathComponent)
                .setting(.requestedGPUOffload, wantsGPU)
                .setting(.compiledWithMetal, LlamaCppRuntime.hasMetal)
                .setting(.gpuLayers, Int(modelParams.n_gpu_layers))
        )
        let handle = request.fileURL.path.withCString { path in
            llama_model_load_from_file(path, modelParams)
        }
        guard let handle else {
            // llama.cpp does not distinguish "this is not a model" from "there
            // was not enough memory" in its return value. The caller has
            // already run a conservative preflight and a structural check, so
            // the message names both rather than guessing.
            diagnostics.criticalFailure(
                .modelLoad,
                operation: loadOperation,
                metadata: LocalInferenceMetadata()
                    .setting(.errorKind, "loadFailed")
                    .setting(.nativeSymbol, "llama_model_load_from_file")
                    .setting(.errorReason, "returned null")
            )
            throw LocalRuntimeError.loadFailed(
                reason: "llama.cpp could not open \(request.fileURL.lastPathComponent). "
                    + "The file may be damaged, or the device may be out of memory."
            )
        }
        model = handle
        vocab = llama_model_get_vocab(handle)
        diagnostics.criticalExit(
            .modelLoad,
            operation: loadOperation,
            metadata: LocalInferenceMetadata()
                .setting(.architecture, LlamaCppRuntime.metadataValue(handle, key: "general.architecture") ?? "unknown")
                .setting(.parameterCount, Int64(llama_model_n_params(handle)))
                .setting(.trainedContextLength, Int(llama_model_n_ctx_train(handle)))
                .setting(.hasEmbeddedChatTemplate, llama_model_chat_template(handle, nil) != nil)
        )

        var contextParams = llama_context_default_params()
        contextParams.n_ctx = UInt32(max(512, request.contextLength))
        // The batch bounds one `llama_decode`; the micro batch bounds one
        // compute-graph pass and is what the Metal compute buffer is sized
        // from. Both come from `LocalInferenceConfiguration` so that the memory
        // preflight and the allocation agree — they did not before, and a 3B
        // model that passed the check was then killed on its first decode.
        //
        // The fallbacks are the conservative tier rather than llama.cpp's 512,
        // which is tuned for a machine with swap and a GPU not also drawing a
        // user interface.
        let batch = request.batchSize ?? 128
        let microBatch = request.microBatchSize ?? 64
        contextParams.n_batch = UInt32(max(32, min(batch, request.contextLength)))
        contextParams.n_ubatch = UInt32(max(32, min(microBatch, Int(contextParams.n_batch))))
        if let threads = request.threadCount {
            contextParams.n_threads = Int32(threads)
            contextParams.n_threads_batch = Int32(threads)
        }
        contextParams.no_perf = true

        // Section 27, and the reason this is a separate stage from the load
        // above: `llama_init_from_model` is where the KV cache is allocated,
        // and it fails for entirely different reasons than opening the weights.
        // A recovery report that said only "load" would leave the two
        // indistinguishable, which is exactly the ambiguity this pass exists to
        // remove. The requested numbers go in the ENTER, because if the process
        // dies here they are the evidence.
        let contextOperation = diagnostics.criticalEnter(
            .contextCreate,
            metadata: LocalInferenceMetadata()
                .setting(.requestedContextSize, Int(contextParams.n_ctx))
                .setting(.batchSize, Int(contextParams.n_batch))
                .setting(.microBatchSize, Int(contextParams.n_ubatch))
                .setting(.threadCount, Int(contextParams.n_threads))
                .setting(.batchThreadCount, Int(contextParams.n_threads_batch))
                .setting(.gpuLayers, Int(modelParams.n_gpu_layers))
        )
        guard let newContext = llama_init_from_model(handle, contextParams) else {
            diagnostics.criticalFailure(
                .contextCreate,
                operation: contextOperation,
                metadata: LocalInferenceMetadata()
                    .setting(.errorKind, "insufficientMemory")
                    .setting(.nativeSymbol, "llama_init_from_model")
                    .setting(.errorReason, "returned null")
            )
            releaseNativeResources()
            // A model that opened and a context that would not is very nearly
            // always the KV cache failing to allocate — the one failure the
            // user can act on, by choosing a smaller model.
            throw LocalRuntimeError.insufficientMemory(
                reason: "There was not enough memory for a "
                    + "\(request.contextLength)-token context."
            )
        }
        context = newContext
        diagnostics.criticalExit(
            .contextCreate,
            operation: contextOperation,
            // Section 28: what was actually allocated, which llama.cpp may have
            // clamped below what was asked for.
            metadata: LocalInferenceMetadata()
                .setting(.actualContextSize, Int(llama_n_ctx(newContext)))
                .setting(.requestedContextSize, Int(contextParams.n_ctx))
        )

        let info = LoadedModelInfo(
            modelID: request.modelID,
            architecture: LlamaCppRuntime.metadataValue(handle, key: "general.architecture")
                ?? LlamaCppRuntime.description(of: handle),
            contextLength: Int(llama_n_ctx(newContext)),
            trainedContextLength: Int(llama_model_n_ctx_train(handle)),
            parameterCount: Int64(llama_model_n_params(handle)),
            hasEmbeddedChatTemplate: llama_model_chat_template(handle, nil) != nil
        )
        loaded = info

        // Section 90: one line holding every number the native runtime is
        // actually running with. This is what a recovery report quotes, and it
        // is read from the context rather than from the request — the request
        // is what was asked for and this is what was granted.
        diagnostics.info(
            .runtimeConfiguration,
            category: .configuration,
            metadata: LocalInferenceMetadata()
                .setting(.modelID, request.modelID.rawValue)
                .setting(.architecture, info.architecture)
                .setting(.runtimeImplementation, "LlamaCppRuntime")
                .setting(.llamaCppVersion, LlamaCppRuntime.pinnedVersion)
                .setting(.actualContextSize, Int(llama_n_ctx(newContext)))
                .setting(.requestedContextSize, request.contextLength)
                .setting(.batchSize, Int(llama_n_batch(newContext)))
                .setting(.microBatchSize, Int(llama_n_ubatch(newContext)))
                .setting(.threadCount, Int(contextParams.n_threads))
                .setting(.batchThreadCount, Int(contextParams.n_threads_batch))
                .setting(.compiledWithMetal, LlamaCppRuntime.hasMetal)
                .setting(.requestedGPUOffload, request.gpuOffloadRequested)
                // Section 31 again, and the honest version of it: this build
                // cannot interrogate ggml for which backend a tensor landed on,
                // so "active" means the offload was both compiled in and asked
                // for. Claiming more would be claiming a measurement nothing
                // took.
                .setting(.runtimeGPUOffloadActive, wantsGPU)
                .setting(.gpuLayers, Int(modelParams.n_gpu_layers))
                .setting(.parameterCount, info.parameterCount ?? 0)
                .setting(.trainedContextLength, ifPresent: info.trainedContextLength)
                .setting(.hasEmbeddedChatTemplate, info.hasEmbeddedChatTemplate)
        )
        return info
        #else
        throw LocalRuntimeError.runtimeUnavailable(
            reason: "This build does not include the on-device inference runtime."
        )
        #endif
    }

    public func unloadModel() async {
        // Section 46. Freeing is native too, and a context holding a KV cache
        // that ggml is mid-way through releasing is as capable of taking the
        // process down as allocating one.
        guard loaded != nil else {
            releaseNativeResources()
            return
        }
        let operation = diagnostics.criticalEnter(.modelUnload, metadata: .empty)
        releaseNativeResources()
        loaded = nil
        diagnostics.criticalExit(.modelUnload, operation: operation, metadata: .empty)
    }

    /// Frees every native allocation. Idempotent.
    ///
    /// The order matters: the context references the model, so it goes first.
    /// Nilling what it frees is what makes calling this twice safe — and it is
    /// called twice, by `unloadModel()` and again by a load that failed partway.
    private func releaseNativeResources() {
        #if canImport(llama)
        if let context {
            // Section 46: `llama_free` walks the KV cache and the Metal
            // buffers, and a crash there looks nothing like a crash allocating
            // them. Worth its own stage so the two cannot be confused.
            let operation = diagnostics.criticalEnter(.contextDestroy, metadata: .empty)
            llama_free(context)
            self.context = nil
            diagnostics.criticalExit(.contextDestroy, operation: operation, metadata: .empty)
        }
        if let model {
            llama_model_free(model)
            self.model = nil
        }
        vocab = nil
        #endif
    }

    // MARK: Generation

    public func generate(
        _ prompt: LocalPrompt,
        options: LocalGenerationOptions
    ) async throws -> LocalGenerationOutput {
        #if canImport(llama)
        guard let model, let context, let vocab else {
            throw LocalRuntimeError.noModelLoaded
        }
        // Being on an actor already serializes this. The flag exists so a
        // second caller gets a clear error instead of silently queueing behind
        // a generation it does not know about.
        guard !isGenerating else {
            throw LocalRuntimeError.generationFailed(
                reason: "The model is already answering something else."
            )
        }
        isGenerating = true
        cancellationRequested = false
        defer { isGenerating = false }

        let generationOperation = diagnostics.criticalEnter(
            .generation,
            metadata: LocalInferenceMetadata()
                .setting(.messageCount, prompt.turns.count)
                .setting(.actualContextSize, Int(llama_n_ctx(context)))
        )
        var generationFinished = false
        defer {
            // Belt and braces around every `throw` below: an unresolved
            // `generation` would otherwise be reported as the crash site for a
            // turn that merely failed. `defer` runs on the throwing path too.
            if !generationFinished {
                diagnostics.criticalFailure(
                    .generation, operation: generationOperation,
                    metadata: LocalInferenceMetadata().setting(.errorKind, "threw")
                )
            }
        }

        // Section 36. The template is applied natively — `llama_chat_apply_template`
        // runs the Jinja the weights shipped with — so it is native code that
        // can fail, and it gets a stage. What it produces is the fully rendered
        // prompt, and that is never logged (section 35): only its size.
        let templateOperation = diagnostics.criticalEnter(
            .chatTemplate,
            metadata: LocalInferenceMetadata()
                .setting(.templateSource, llama_model_chat_template(model, nil) != nil ? "model" : "fallback")
                .setting(.templateName, prompt.fallback.rawValue)
        )
        let text = renderPrompt(prompt, model: model)
        diagnostics.criticalExit(
            .chatTemplate,
            operation: templateOperation,
            metadata: LocalInferenceMetadata().setting(.characterCount, text.count)
        )

        // Section 37.
        let tokenizeOperation = diagnostics.criticalEnter(
            .tokenize,
            metadata: LocalInferenceMetadata().setting(.characterCount, text.count)
        )
        let tokenized: [llama_token]
        do {
            tokenized = try tokenize(text, vocab: vocab, addSpecial: true)
        } catch {
            diagnostics.criticalFailure(
                .tokenize, operation: tokenizeOperation,
                metadata: LocalInferenceMetadata().setting(.errorKind, "tokenizeFailed")
            )
            throw error
        }
        var tokens = tokenized
        let contextLength = Int(llama_n_ctx(context))
        diagnostics.criticalExit(
            .tokenize,
            operation: tokenizeOperation,
            metadata: LocalInferenceMetadata()
                .setting(.tokenCount, tokens.count)
                .setting(.contextBudget, contextLength)
                .setting(.generationReserve, options.maximumOutputTokens)
        )

        guard !tokens.isEmpty else {
            throw LocalRuntimeError.generationFailed(reason: "The prompt produced no tokens.")
        }

        let room = contextLength - options.maximumOutputTokens - 8
        // Section 38. Refusing here rather than decoding is the point: a prompt
        // that cannot fit alongside its own reply is a request the native layer
        // must never be handed, and "fail with an error" beats "find out inside
        // ggml".
        guard room > 0 else {
            diagnostics.problem(
                .contextBudgetExceeded,
                category: .prompt,
                stage: .promptDecode,
                metadata: LocalInferenceMetadata()
                    .setting(.tokenCount, tokens.count)
                    .setting(.contextBudget, contextLength)
                    .setting(.generationReserve, options.maximumOutputTokens)
            )
            throw LocalRuntimeError.generationFailed(
                reason: "The reply reserve of \(options.maximumOutputTokens) tokens leaves no "
                    + "room in a \(contextLength)-token context."
            )
        }
        if tokens.count > room {
            // Keeping the tail rather than refusing. The context budget is
            // already respected upstream — `ContextAssembler` trims memory and
            // history — so arriving here means one unusually long message, and
            // answering its most recent part beats an error about token counts.
            diagnostics.record(
                .contextBudgetExceeded, type: .warning, level: .warning, category: .prompt,
                stage: .promptDecode,
                metadata: LocalInferenceMetadata()
                    .setting(.tokenCount, tokens.count)
                    .setting(.contextBudget, room)
                    .setting(.promptWasTrimmed, true)
            )
            tokens = Array(tokens.suffix(room))
        }

        // A fresh KV cache per turn. The app rebuilds the whole prompt each
        // time — system prompt, memories, history — so there is no prefix worth
        // reusing, and a stale cache would silently prepend a previous
        // conversation to this one.
        llama_memory_clear(llama_get_memory(context), true)

        let promptTokens = tokens.count

        // Section 39, and the most important breadcrumb in the file.
        //
        // This is the first `llama_decode` of the turn, and it is where the
        // compute buffers are allocated — lazily, sized from the micro batch,
        // *after* the model reported itself loaded and ready. A model that
        // passed every preflight and answered "Ready" dies here, which is
        // exactly the shape of the crash being investigated. If the next
        // recovery report names `prompt_decode`, this line is why it can.
        let decodeOperation = diagnostics.criticalEnter(
            .promptDecode,
            metadata: LocalInferenceMetadata()
                .setting(.promptTokenCount, promptTokens)
                .setting(.actualContextSize, contextLength)
                .setting(.batchSize, Int(llama_n_batch(context)))
                .setting(.microBatchSize, Int(llama_n_ubatch(context)))
        )
        // The batch borrows the token buffer and `llama_decode` reads it, so
        // the pointer has to stay valid across both calls. `&tokens` would
        // produce one that is valid only for the duration of `batch_get_one`.
        let promptStatus = tokens.withUnsafeMutableBufferPointer { buffer -> Int32 in
            let batch = llama_batch_get_one(buffer.baseAddress, Int32(buffer.count))
            return llama_decode(context, batch)
        }
        guard promptStatus == 0 else {
            diagnostics.criticalFailure(
                .promptDecode,
                operation: decodeOperation,
                metadata: LocalInferenceMetadata()
                    .setting(.errorKind, "decodeFailed")
                    .setting(.nativeSymbol, "llama_decode")
                    .setting(.nativeCode, Int(promptStatus))
            )
            throw LocalRuntimeError.generationFailed(
                reason: "The model could not read the prompt."
            )
        }
        diagnostics.criticalExit(
            .promptDecode,
            operation: decodeOperation,
            metadata: LocalInferenceMetadata().setting(.promptTokenCount, promptTokens)
        )

        guard let sampler = makeSampler(options: options) else {
            throw LocalRuntimeError.generationFailed(reason: "The sampler could not be created.")
        }
        defer { llama_sampler_free(sampler) }

        var output = ""
        var generated = 0
        var stop = LocalGenerationStop.maximumTokens

        // Section 40: one breadcrumb around the whole loop, not one per token.
        // A pair of `fsync`s per token would be thousands of synchronous writes
        // during a single reply — enough to dominate the runtime and change the
        // timing of the thing being measured.
        let samplingOperation = diagnostics.criticalEnter(
            .generationDecode,
            metadata: LocalInferenceMetadata()
                .setting(.promptTokenCount, promptTokens)
                .setting(.generationReserve, options.maximumOutputTokens)
        )
        let startedAt = DispatchTime.now()
        var decodeStatus: Int32 = 0

        while generated < options.maximumOutputTokens {
            if cancellationRequested {
                stop = .cancelled
                break
            }

            let token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) {
                stop = .endOfText
                break
            }
            llama_sampler_accept(sampler, token)
            output += piece(for: token, vocab: vocab)
            generated += 1

            if generated == 1 {
                // Section 41. First-token latency is the number that separates
                // "the model is slow" from "the model never started", and it is
                // the one figure a person watching a spinner actually has an
                // intuition about. The token itself is never recorded.
                diagnostics.info(
                    .firstToken,
                    category: .generation,
                    stage: .generationDecode,
                    metadata: LocalInferenceMetadata()
                        .setting(.latencyMs, Int(LlamaCppRuntime.milliseconds(since: startedAt)))
                        .setting(.generatedTokenCount, 1)
                )
            } else if generated % LlamaCppRuntime.progressTokenInterval == 0 {
                // Section 42, verbose only. Measured values, so the rate is a
                // real observation rather than a claim (section 121 of Part 10
                // forbids inventing a speed; this one was counted).
                diagnostics.verbose(
                    .generationProgress,
                    category: .generation,
                    stage: .generationDecode,
                    metadata: {
                        let elapsed = LlamaCppRuntime.milliseconds(since: startedAt) / 1000
                        return LocalInferenceMetadata()
                            .setting(.generatedTokenCount, generated)
                            .setting(.elapsedSeconds, elapsed)
                            .setting(
                                .tokensPerSecond,
                                elapsed > 0 ? Double(generated) / elapsed : 0
                            )
                    }()
                )
            }

            if let trimmed = LlamaCppRuntime.truncate(output, atAnyOf: options.stopSequences) {
                output = trimmed
                stop = .stopSequence
                break
            }

            var next = token
            let status = withUnsafeMutablePointer(to: &next) { pointer -> Int32 in
                llama_decode(context, llama_batch_get_one(pointer, 1))
            }
            guard status == 0 else {
                // Non-zero mid-generation is nearly always a full KV cache.
                // Whatever has been generated is real text and is returned
                // rather than thrown away.
                decodeStatus = status
                stop = .maximumTokens
                break
            }

            // Yields between tokens. Without this the actor never suspends,
            // `cancelGeneration()` never gets to run, and Stop does nothing
            // until the model finishes on its own.
            await Task.yield()
        }

        let elapsedSeconds = LlamaCppRuntime.milliseconds(since: startedAt) / 1000
        diagnostics.criticalExit(
            .generationDecode,
            operation: samplingOperation,
            metadata: LocalInferenceMetadata()
                .setting(.generatedTokenCount, generated)
                .setting(.stopReason, stop.rawValue)
                .setting(.nativeCode, Int(decodeStatus))
        )

        // Sections 43 and 45. Counts, timings and a stop reason — no text.
        let outcome = LocalInferenceMetadata()
            .setting(.generatedTokenCount, generated)
            .setting(.promptTokenCount, promptTokens)
            .setting(.elapsedSeconds, elapsedSeconds)
            .setting(.tokensPerSecond, elapsedSeconds > 0 ? Double(generated) / elapsedSeconds : 0)
            .setting(.stopReason, stop.rawValue)
            .setting(.cancelled, stop == .cancelled)
            // Cancellation and a full KV cache both leave the context usable —
            // nothing was freed and nothing was corrupted — so the next turn can
            // reuse it. Said explicitly because "did the runtime survive" is the
            // question a reader has after a failure.
            .setting(.runtimeHealthy, true)
        diagnostics.info(
            stop == .cancelled ? .generationCancelled : .generationFinished,
            category: .generation,
            stage: .generationDecode,
            metadata: outcome
        )

        generationFinished = true
        diagnostics.criticalExit(
            .generation, operation: generationOperation, metadata: outcome
        )

        return LocalGenerationOutput(
            text: output.trimmingCharacters(in: .whitespacesAndNewlines),
            stop: stop,
            promptTokens: promptTokens,
            generatedTokens: generated
        )
        #else
        throw LocalRuntimeError.runtimeUnavailable(
            reason: "This build does not include the on-device inference runtime."
        )
        #endif
    }

    public func cancelGeneration() async {
        cancellationRequested = true
        #if canImport(llama)
        LlamaBackend.loadCancellation.cancel()
        #endif
    }

    /// How often a verbose progress line is written during generation.
    ///
    /// Section 42. Sixteen tokens is roughly a second or two on a phone — often
    /// enough to show a stall, rare enough that the log stays readable and the
    /// writing stays free next to the decode it sits between.
    static let progressTokenInterval = 16

    static func milliseconds(since start: DispatchTime) -> Double {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now > start.uptimeNanoseconds else { return 0 }
        return Double(now - start.uptimeNanoseconds) / 1_000_000
    }

    /// Cuts the output at the first stop sequence, if one has appeared.
    static func truncate(_ text: String, atAnyOf sequences: [String]) -> String? {
        for sequence in sequences where !sequence.isEmpty {
            if let range = text.range(of: sequence) {
                return String(text[text.startIndex..<range.lowerBound])
            }
        }
        return nil
    }

    /// True when this build can offload to the GPU.
    ///
    /// The published xcframework has no simulator slice, so `canImport(llama)`
    /// is already false there — the simulator check is belt and braces for a
    /// locally built framework that does include one, where GGML's Metal path
    /// is not representative of a device anyway (section 37).
    static var hasMetal: Bool {
        #if canImport(llama) && (os(iOS) || os(macOS))
        #if targetEnvironment(simulator)
        return false
        #else
        return true
        #endif
        #else
        return false
        #endif
    }
}

#if canImport(llama)

// MARK: - Process-wide backend

/// llama.cpp's global backend registry.
///
/// Started once and never stopped. `llama_backend_free` tears down state shared
/// by every context in the process, so calling it from one runtime's `deinit`
/// would break any other that happened to be alive — and there is nothing to
/// reclaim that process exit does not reclaim anyway.
enum LlamaBackend {
    private static let once: Void = {
        // Silences llama.cpp's own logging, and not for tidiness: at its
        // default level it prints every tensor it loads and, during
        // generation, text derived from the prompt — which is the user's
        // memories and messages going to the system log. This app does not do
        // that (sections 80 and, from Part 9, 109).
        llama_log_set({ _, _, _ in }, nil)
        llama_backend_init()
    }()

    static func start() { _ = once }

    /// Cancellation the C progress callback can reach.
    static let loadCancellation = LoadCancellation()
}

/// A boolean a `@convention(c)` callback can read.
///
/// llama.cpp's progress callback is a plain C function pointer, which cannot
/// capture anything. Its `user_data` parameter exists for this, but passing an
/// unmanaged actor reference through it and reading actor state from whichever
/// thread the loader is on is exactly what actor isolation prevents. A
/// lock-guarded box is the honest version: one boolean, no concurrency
/// machinery involved.
final class LoadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func reset() {
        lock.lock()
        cancelled = false
        lock.unlock()
    }
}

// MARK: - The parts that touch C

extension LlamaCppRuntime {
    /// Applies the chat template, preferring the one inside the model file.
    ///
    /// Section 39. `llama_chat_apply_template` understands the template the
    /// weights were trained with, which is the only source of truth still
    /// correct for a model released after this code was written. The app's own
    /// renderer is the fallback for a file that carries none, and for a
    /// template llama.cpp declines to apply.
    func renderPrompt(_ prompt: LocalPrompt, model: OpaquePointer) -> String {
        guard let template = llama_model_chat_template(model, nil) else {
            return prompt.fallback.render(prompt.turns)
        }

        // `llama_chat_message` holds borrowed C strings, and they must outlive
        // the call. Duplicating them onto the heap is the version that is
        // obviously correct: a `withUnsafeBufferPointer` over an array element
        // hands back a pointer into a temporary copy, which is dangling by the
        // time the array of messages is built.
        var owned: [UnsafeMutablePointer<CChar>] = []
        defer { owned.forEach { free($0) } }

        var messages: [llama_chat_message] = []
        messages.reserveCapacity(prompt.turns.count)
        for turn in prompt.turns {
            guard let role = strdup(turn.role), let content = strdup(turn.content) else {
                return prompt.fallback.render(prompt.turns)
            }
            owned.append(role)
            owned.append(content)
            messages.append(
                llama_chat_message(role: UnsafePointer(role), content: UnsafePointer(content))
            )
        }

        // The header recommends twice the total character count; doubling again
        // is cheap and avoids the retry in the common case.
        let estimated = prompt.turns.reduce(0) {
            $0 + $1.content.utf8.count + $1.role.utf8.count
        }
        var size = max(1024, estimated * 4)
        var out = [CChar](repeating: 0, count: size)
        var written = llama_chat_apply_template(
            template, messages, messages.count, true, &out, Int32(size)
        )
        if written > Int32(size) {
            size = Int(written) + 1
            out = [CChar](repeating: 0, count: size)
            written = llama_chat_apply_template(
                template, messages, messages.count, true, &out, Int32(size)
            )
        }
        guard written > 0, Int(written) <= out.count else {
            // Some files carry Jinja this function does not implement. Section
            // 40: rather than send the model a prompt shape it has never seen,
            // fall back to the family's known format.
            return prompt.fallback.render(prompt.turns)
        }
        let bytes = out[0..<Int(written)].map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    func tokenize(
        _ text: String,
        vocab: OpaquePointer,
        addSpecial: Bool
    ) throws -> [llama_token] {
        let byteCount = Int32(text.utf8.count)
        var capacity = text.utf8.count + 8
        var tokens = [llama_token](repeating: 0, count: capacity)
        var count = text.withCString { pointer in
            llama_tokenize(
                vocab, pointer, byteCount, &tokens, Int32(capacity), addSpecial, true
            )
        }
        if count < 0 {
            // llama.cpp returns the negative of what it needs.
            capacity = Int(-count)
            tokens = [llama_token](repeating: 0, count: capacity)
            count = text.withCString { pointer in
                llama_tokenize(
                    vocab, pointer, byteCount, &tokens, Int32(capacity), addSpecial, true
                )
            }
        }
        guard count >= 0, Int(count) <= tokens.count else {
            throw LocalRuntimeError.generationFailed(reason: "The prompt could not be tokenized.")
        }
        return Array(tokens[0..<Int(count)])
    }

    /// One token as text.
    ///
    /// Appended to an accumulating `String` rather than decoded standalone: a
    /// single character can span several tokens, and decoding each alone
    /// produces replacement characters mid-word. `String(decoding:as:)` is
    /// lossy in exactly the right way — a partial sequence is dropped here and
    /// completed by the next token's bytes.
    func piece(for token: llama_token, vocab: OpaquePointer) -> String {
        var buffer = [CChar](repeating: 0, count: 64)
        var written = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        if written < 0 {
            buffer = [CChar](repeating: 0, count: Int(-written) + 1)
            written = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        }
        guard written > 0, Int(written) <= buffer.count else { return "" }
        let bytes = buffer[0..<Int(written)].map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The sampler chain.
    ///
    /// Order is not cosmetic: the filters narrow the candidate set and the
    /// distribution sampler picks from what is left, so `dist` is last.
    /// Temperature before top-k and top-p would rescale probabilities that are
    /// about to be discarded.
    /// - Note: the return type is a typed pointer rather than `OpaquePointer`.
    ///   `llama_model`, `llama_context` and `llama_vocab` are forward-declared
    ///   in `llama.h` and import as opaque; `llama_sampler` is a *complete*
    ///   struct with `iface` and `ctx` fields, so it imports as
    ///   `UnsafeMutablePointer<llama_sampler>`. They are not interchangeable.
    func makeSampler(options: LocalGenerationOptions) -> UnsafeMutablePointer<llama_sampler>? {
        var params = llama_sampler_chain_default_params()
        params.no_perf = true
        guard let chain = llama_sampler_chain_init(params) else { return nil }

        if options.temperature <= 0 {
            // Temperature zero means "always the most likely token", which is
            // greedy decoding — and passing 0 to `temp` is a division by zero.
            llama_sampler_chain_add(chain, llama_sampler_init_greedy())
            return chain
        }

        if options.topK > 0 {
            llama_sampler_chain_add(chain, llama_sampler_init_top_k(Int32(options.topK)))
        }
        if options.topP > 0, options.topP < 1 {
            llama_sampler_chain_add(chain, llama_sampler_init_top_p(Float(options.topP), 1))
        }
        llama_sampler_chain_add(chain, llama_sampler_init_temp(Float(options.temperature)))
        // A fixed seed where one was asked for, so a diagnostic run gets the
        // same answer twice. llama.cpp's own default otherwise.
        llama_sampler_chain_add(chain, llama_sampler_init_dist(options.seed ?? 0xFFFF_FFFF))
        return chain
    }

    /// Reads one GGUF metadata string out of a loaded model.
    static func metadataValue(_ model: OpaquePointer, key: String) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        let written = llama_model_meta_val_str(model, key, &buffer, buffer.count)
        guard written > 0 else { return nil }
        return String(cString: buffer)
    }

    /// llama.cpp's own one-line description of a model.
    static func description(of model: OpaquePointer) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        let written = llama_model_desc(model, &buffer, buffer.count)
        guard written > 0 else { return "unknown" }
        return String(cString: buffer)
    }
}

#endif
