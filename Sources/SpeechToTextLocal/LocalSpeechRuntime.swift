import Foundation
import SpeechToText

/// Running a Whisper model, abstracted away from whisper.cpp.
///
/// ## Why this exists
///
/// Sections 19 and 20. `LocalSpeechToTextProvider` implements a *provider*: it
/// decides availability, manages the session lifecycle, and normalizes events.
/// None of that should have to know what a `whisper_context` is. Putting the
/// native calls behind this protocol means the provider is testable without
/// linking whisper.cpp, and CI compiles and exercises the whole local path
/// against `MockLocalSpeechRuntime` (section 92).
///
/// ## What must not cross this line
///
/// No `whisper_context`, no `ggml` pointers, no Metal buffers. The
/// implementation holds those; everything above sees `[Float]` in and `String`
/// out. That is what keeps the runtime replaceable — and what keeps every
/// shared Swift target free of a C dependency (section 89).
///
/// ## Why it is not `LocalModelRuntime`
///
/// Section 81 and 82. Part 10's runtime streams tokens from a chat model with a
/// context window, a sampler and a tool-call convention. This takes a block of
/// audio and returns a sentence. Forcing both behind one "inference" protocol
/// would produce a type whose every method is optional for one of its two
/// implementations.
public protocol LocalSpeechRuntime: Sendable {
    /// Whether this build can run local speech at all.
    ///
    /// False in a build without the native library linked, which is what the
    /// simulator and the default CI lane get. Reported rather than crashed on.
    var isAvailable: Bool { get }

    /// What this runtime can do, for the compatibility check.
    func runtimeCapabilities() async -> LocalSpeechRuntimeCapabilities

    /// Reads a model into memory. Idempotent for the same file.
    func loadModel(at url: URL) async throws

    /// Releases the model and every native resource behind it.
    ///
    /// Section 38: this frees the whisper context, the ggml allocations and the
    /// Metal resources. It is not a flag — a "loaded" boolean set to false
    /// while half a gigabyte stays resident is the bug this method exists to
    /// prevent.
    func unloadModel() async

    /// Whether a model is currently resident.
    func isModelLoaded() async -> Bool

    /// Transcribes mono 16 kHz audio.
    ///
    /// - Parameter samples: interleaved is meaningless at one channel; these
    ///   are plain PCM floats in −1…1.
    /// - Parameter locale: nil lets the model detect the language, which the
    ///   English-only builds ignore.
    func transcribe(
        samples: [Float],
        locale: Locale?
    ) async throws -> String

    /// Abandons an in-flight transcription.
    ///
    /// Whisper decodes in a tight native loop, so this sets a flag the loop
    /// checks rather than interrupting it — cancellation is prompt, not
    /// instantaneous, and the difference is documented rather than hidden.
    func cancelTranscription() async
}

/// What a local speech runtime supports.
public struct LocalSpeechRuntimeCapabilities: Hashable, Sendable {
    /// Whether GPU acceleration is active. Reported by the runtime, never
    /// assumed — the simulator has no usable Metal path for this.
    public var usesGPUAcceleration: Bool
    /// Whether the runtime can emit text before the audio ends.
    ///
    /// False for this milestone. Section 55: chunked streaming for whisper.cpp
    /// means re-decoding overlapping windows and reconciling the results, and
    /// getting that subtly wrong produces a transcript that reads fluently and
    /// says something the user did not. Correctness first.
    public var supportsStreaming: Bool
    /// The model formats this runtime reads.
    public var supportedFormats: [String]

    public init(
        usesGPUAcceleration: Bool,
        supportsStreaming: Bool = false,
        supportedFormats: [String] = ["ggml"]
    ) {
        self.usesGPUAcceleration = usesGPUAcceleration
        self.supportsStreaming = supportsStreaming
        self.supportedFormats = supportedFormats
    }

    public static let unavailable = LocalSpeechRuntimeCapabilities(
        usesGPUAcceleration: false,
        supportsStreaming: false,
        supportedFormats: []
    )
}

/// A speech runtime for builds without the native library.
///
/// Refuses honestly rather than pretending. The simulator lane and the default
/// CI build get this, and the Settings screen shows "not available in this
/// build" instead of a model that downloads and then cannot run.
public struct UnavailableLocalSpeechRuntime: LocalSpeechRuntime {
    public init() {}

    public var isAvailable: Bool { false }

    public func runtimeCapabilities() async -> LocalSpeechRuntimeCapabilities { .unavailable }

    public func loadModel(at url: URL) async throws {
        throw SpeechToTextError.modelIncompatible(
            reason: "On-device speech isn't available in this build."
        )
    }

    public func unloadModel() async {}
    public func isModelLoaded() async -> Bool { false }

    public func transcribe(samples: [Float], locale: Locale?) async throws -> String {
        throw SpeechToTextError.modelIncompatible(
            reason: "On-device speech isn't available in this build."
        )
    }

    public func cancelTranscription() async {}
}

/// A speech runtime a test can drive by hand.
///
/// Section 92. Model loading, load failure, out-of-memory, transcription and
/// cancellation, all without a 142 MB file or a GPU.
public actor MockLocalSpeechRuntime: LocalSpeechRuntime {

    public enum Behaviour: Sendable {
        case transcribes(String)
        case fails(SpeechToTextError)
        /// Never returns until cancelled.
        case hangs
    }

    public nonisolated let isAvailable: Bool

    private var behaviour: Behaviour
    private var loadFailure: SpeechToTextError?
    private var loadedURL: URL?
    private var capabilities: LocalSpeechRuntimeCapabilities
    private var isCancelled = false

    public private(set) var loadCount = 0
    public private(set) var unloadCount = 0
    public private(set) var transcribeCount = 0
    public private(set) var cancelCount = 0
    /// Samples handed to the last transcription, so a test can assert the audio
    /// actually arrived.
    public private(set) var lastSampleCount = 0

    public init(
        behaviour: Behaviour = .transcribes("Remind me tomorrow to call the dentist."),
        loadFailure: SpeechToTextError? = nil,
        isAvailable: Bool = true,
        capabilities: LocalSpeechRuntimeCapabilities = LocalSpeechRuntimeCapabilities(
            usesGPUAcceleration: false
        )
    ) {
        self.behaviour = behaviour
        self.loadFailure = loadFailure
        self.isAvailable = isAvailable
        self.capabilities = capabilities
    }

    public func runtimeCapabilities() async -> LocalSpeechRuntimeCapabilities {
        isAvailable ? capabilities : .unavailable
    }

    public func loadModel(at url: URL) async throws {
        if let loadFailure { throw loadFailure }
        loadCount += 1
        loadedURL = url
    }

    public func unloadModel() async {
        unloadCount += 1
        loadedURL = nil
    }

    public func isModelLoaded() async -> Bool { loadedURL != nil }

    public func transcribe(samples: [Float], locale: Locale?) async throws -> String {
        guard loadedURL != nil else { throw SpeechToTextError.modelNotDownloaded }
        transcribeCount += 1
        lastSampleCount = samples.count
        isCancelled = false

        switch behaviour {
        case .transcribes(let text):
            return text
        case .fails(let error):
            throw error
        case .hangs:
            while !isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000)
                if Task.isCancelled { break }
            }
            throw SpeechToTextError.cancelled
        }
    }

    public func cancelTranscription() async {
        cancelCount += 1
        isCancelled = true
    }

    // MARK: Driving it

    public func setBehaviour(_ behaviour: Behaviour) { self.behaviour = behaviour }
    public func setLoadFailure(_ error: SpeechToTextError?) { loadFailure = error }
}
