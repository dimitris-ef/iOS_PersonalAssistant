import Foundation
import SpeechToText
import SpeechToTextLocal

#if canImport(whisper)
import whisper
#endif

// A build that *intends* to link whisper.cpp says so, and finds out here if it
// did not.
//
// Without this, the `#if canImport(whisper)` guards that make this target
// compile everywhere would also make a broken integration compile silently:
// the binary target fails to resolve, every guarded branch disappears, the
// build goes green, and the app ships a speech runtime that reports itself
// unavailable on every device. The `Local model runtime` workflow passes
// `-DPPAI_REQUIRE_WHISPER`, which turns that into a build failure.
#if PPAI_REQUIRE_WHISPER && !canImport(whisper)
#error("whisper.cpp was expected but is not linked. Is PPAI_WHISPER_RUNTIME=1 set?")
#endif

/// whisper.cpp, behind `LocalSpeechRuntime`.
///
/// ## The only file that imports `whisper`
///
/// Section 19, 20 and 89. Everything above sees `[Float]` in and `String` out;
/// the `whisper_context`, the ggml allocations and the Metal buffers live here
/// and are never handed out. That is what keeps every shared Swift target free
/// of a C dependency and what lets the whole local speech path be tested in CI
/// against `MockLocalSpeechRuntime`.
///
/// ## Threading
///
/// An actor, because `whisper_context` is a mutable C object with a lifecycle
/// and every bug this can have is a lifecycle bug: transcribing on a context
/// that is being freed, freeing one that is mid-decode, loading a second model
/// while the first is running. Serializing access removes the entire class.
///
/// The decode itself is synchronous and long — seconds — so it runs off the
/// actor's executor. That is the one place the isolation is deliberately
/// stepped outside, and it is safe because the actor holds no other work while
/// it happens.
///
/// TODO-DEVICE: nothing here has run. Load time, transcription speed, real RAM
/// use, whether Metal is actually engaged, and thermal behaviour on a long
/// recording all need an iPhone — see `Docs/SPEECH.md`.
public actor WhisperCppRuntime: LocalSpeechRuntime {

    public nonisolated var isAvailable: Bool {
        #if canImport(whisper)
        return true
        #else
        return false
        #endif
    }

    #if canImport(whisper)
    /// The loaded model. `OpaquePointer` because `whisper_context` is
    /// forward-declared in the header, so Swift imports it opaquely — unlike
    /// `llama_sampler` in Part 10, which is a complete struct and imports as a
    /// typed pointer. Reading the header is the only way to know which, and
    /// getting it wrong is a compile error the runtime CI lane catches.
    private var context: OpaquePointer?
    #endif

    private var loadedURL: URL?
    /// Set by `cancelTranscription`, read by the native abort callback.
    private let cancellation = CancellationFlag()

    public init() {}

    public func runtimeCapabilities() async -> LocalSpeechRuntimeCapabilities {
        #if canImport(whisper)
        return LocalSpeechRuntimeCapabilities(
            usesGPUAcceleration: Self.metalIsEnabled,
            // Section 55: chunked streaming is deliberately not implemented.
            supportsStreaming: false,
            supportedFormats: ["ggml"]
        )
        #else
        return .unavailable
        #endif
    }

    /// Whether Metal is compiled in and requested.
    ///
    /// Section 23 keeps this internal to the runtime. It is a build fact rather
    /// than a runtime probe: the published XCFramework enables Metal for Apple
    /// targets, and `use_gpu` asks for it. Whether the GPU is *actually* used
    /// for a given model on a given device is something only a device can say,
    /// which is why nothing shows this to the user as a performance promise
    /// (section 80).
    static var metalIsEnabled: Bool {
        #if canImport(whisper) && !targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    // MARK: Loading

    public func loadModel(at url: URL) async throws {
        #if canImport(whisper)
        if loadedURL == url, context != nil { return }
        await unloadModel()

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SpeechToTextError.modelNotDownloaded
        }

        var params = whisper_context_default_params()
        // The simulator has no usable Metal path for this, and asking for one
        // there produces a slow failure rather than a fast CPU decode.
        params.use_gpu = Self.metalIsEnabled
        params.flash_attn = Self.metalIsEnabled

        let created = url.path.withCString { path in
            whisper_init_from_file_with_params(path, params)
        }
        guard let created else {
            // whisper.cpp returns null for a file that is not a model, a model
            // it cannot parse, and an allocation failure alike. The catalog
            // already verified the format at install time, so on a phone the
            // overwhelmingly likely cause is memory.
            throw SpeechToTextError.insufficientMemory
        }
        context = created
        loadedURL = url
        #else
        throw SpeechToTextError.modelIncompatible(
            reason: "On-device speech isn't available in this build."
        )
        #endif
    }

    public func unloadModel() async {
        #if canImport(whisper)
        if let context {
            // Section 38: the native context is freed. Not a flag — the ggml
            // allocations and the Metal resources go with it.
            whisper_free(context)
        }
        context = nil
        #endif
        loadedURL = nil
    }

    public func isModelLoaded() async -> Bool {
        #if canImport(whisper)
        return context != nil
        #else
        return false
        #endif
    }

    // MARK: Transcription

    public func transcribe(samples: [Float], locale: Locale?) async throws -> String {
        #if canImport(whisper)
        guard let context else { throw SpeechToTextError.modelNotDownloaded }
        guard !samples.isEmpty else { return "" }

        cancellation.reset()
        let flag = cancellation
        let language = Self.languageCode(for: locale)
        let threads = Self.threadCount()

        // The decode is a long synchronous C call. Running it on the actor's
        // executor would block every other message to this actor — including
        // the `cancelTranscription` that is meant to stop it.
        let transcript = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
                params.n_threads = Int32(threads)
                params.print_progress = false
                params.print_realtime = false
                params.print_timestamps = false
                params.print_special = false
                // Section 72: no timestamps, no token-level data. The assistant
                // gets a sentence, so nothing else is even generated.
                params.no_timestamps = true
                params.token_timestamps = false
                params.translate = false
                // Each utterance stands alone. Carrying decoder context between
                // separate things the user said would let one transcription
                // influence the next, which is a subtle way of putting words in
                // someone's mouth.
                params.no_context = true
                params.suppress_blank = true

                let flagPointer = Unmanaged.passUnretained(flag).toOpaque()
                params.abort_callback = { userData in
                    guard let userData else { return false }
                    let flag = Unmanaged<CancellationFlag>
                        .fromOpaque(userData)
                        .takeUnretainedValue()
                    // Returning true tells whisper.cpp to abandon the decode.
                    // Section 20's cancellation: prompt, but checked between
                    // steps rather than instantaneous.
                    return flag.isCancelled
                }
                params.abort_callback_user_data = flagPointer

                let run: Int32
                if let language {
                    run = language.withCString { code -> Int32 in
                        params.language = code
                        return samples.withUnsafeBufferPointer { buffer in
                            whisper_full(
                                context,
                                params,
                                buffer.baseAddress,
                                Int32(buffer.count)
                            )
                        }
                    }
                } else {
                    // No language given: let the model detect it. The
                    // English-only builds ignore this and transcribe English.
                    run = samples.withUnsafeBufferPointer { buffer in
                        whisper_full(
                            context,
                            params,
                            buffer.baseAddress,
                            Int32(buffer.count)
                        )
                    }
                }

                if flag.isCancelled {
                    continuation.resume(throwing: SpeechToTextError.cancelled)
                    return
                }
                guard run == 0 else {
                    continuation.resume(
                        throwing: SpeechToTextError.transcriptionFailed(
                            reason: "On-device transcription didn't complete."
                        )
                    )
                    return
                }

                var text = ""
                let segments = whisper_full_n_segments(context)
                for index in 0..<segments {
                    if let segment = whisper_full_get_segment_text(context, index) {
                        text += String(cString: segment)
                    }
                }
                continuation.resume(returning: text)
            }
        }
        return transcript
        #else
        throw SpeechToTextError.modelIncompatible(
            reason: "On-device speech isn't available in this build."
        )
        #endif
    }

    public func cancelTranscription() async {
        cancellation.cancel()
    }

    // MARK: Parameters

    /// How many threads to decode with.
    ///
    /// Capped at four. whisper.cpp scales past that on a desktop; on a phone
    /// the extra threads land on efficiency cores, add heat, and make the
    /// decode slower rather than faster. Leaving cores free also keeps the UI
    /// responsive while transcription runs.
    static func threadCount() -> Int {
        max(1, min(4, ProcessInfo.processInfo.activeProcessorCount - 1))
    }

    /// The two-letter code whisper.cpp expects, or nil to auto-detect.
    static func languageCode(for locale: Locale?) -> String? {
        guard let locale else { return nil }
        let identifier = locale.identifier
        let head = identifier
            .components(separatedBy: CharacterSet(charactersIn: "-_"))
            .first ?? identifier
        let code = head.lowercased()
        return code.isEmpty ? nil : code
    }
}

/// A cancellation flag the C abort callback can read.
///
/// A locked class rather than an actor because the callback is a C function
/// pointer invoked from whisper.cpp's decode loop many times a second: it
/// cannot await, and it cannot capture Swift context beyond the opaque pointer
/// it is handed.
final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    func reset() {
        lock.lock(); cancelled = false; lock.unlock()
    }
}

/// Picks the speech runtime this build actually has.
///
/// Mirrors `LocalRuntimeResolver` in Part 10, and for the same reason: "no
/// runtime" and "a runtime that reports itself unavailable" are the same thing
/// to every caller, and only one of them needs an optional threaded through the
/// app.
public enum LocalSpeechRuntimeResolver {
    /// True when this build links whisper.cpp.
    public static var hasNativeRuntime: Bool {
        #if canImport(whisper)
        return true
        #else
        return false
        #endif
    }

    /// The runtime to hand to `LocalSpeechModelManager`.
    public static func make() -> any LocalSpeechRuntime {
        WhisperCppRuntime()
    }

    /// The pinned upstream version, for the About screen and the release notes.
    ///
    /// Section 21: a fixed tag, never a branch. Reported here so the number in
    /// the app and the number in `Package.swift` cannot drift apart silently.
    public static let whisperVersion = "v1.9.2"
}
