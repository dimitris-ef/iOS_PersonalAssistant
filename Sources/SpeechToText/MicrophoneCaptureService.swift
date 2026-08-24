import Foundation

/// Opening the microphone, and nothing else.
///
/// ## Why this exists
///
/// Section 9. Before Part 13 there was one recognizer and it owned the audio
/// engine, which was fine while "recognition" and "capture" were the same
/// thing. With three engines they are not: whisper.cpp wants raw samples,
/// OpenAI wants a finished file, Apple's analyzer wants a live stream. If each
/// provider opened its own `AVAudioEngine` they would fight over
/// `AVAudioSession` — and the failure mode is not a compile error, it is a
/// microphone that silently stops working when the user switches provider.
///
/// So capture happens once, here, and the samples are handed to whichever
/// engine is selected. The audio session is configured in exactly one place.
///
/// ## Why permissions live here
///
/// Because the microphone is what needs them. Speech-recognition authorization
/// is a *provider* concern — only Apple's older API requires it, and asking for
/// it when the user has selected Whisper would be requesting a permission the
/// app does not use (section 16). The provider reports whether it needs one;
/// this reports whether the microphone is available.
public protocol MicrophoneCaptureService: Sendable {
    /// Reads current microphone authorization without prompting.
    func currentPermission() async -> MicrophonePermission
    /// Prompts, if prompting can still help.
    func requestPermission() async -> MicrophonePermission

    /// The format this microphone actually produces.
    ///
    /// Not a constant: a phone's built-in microphone, a Bluetooth headset and
    /// a wired one report different rates, and a conversion that assumed 48 kHz
    /// would quietly transcribe gibberish on the one that isn't.
    func captureFormat() async -> SpeechAudioFormat

    /// Opens the microphone and begins publishing samples.
    ///
    /// The returned stream finishes when `stop()` or `cancel()` is called, or
    /// when the session is interrupted.
    func start() async throws -> SpeechAudioStream
    /// Stops capturing and finishes the stream cleanly. Whatever was captured
    /// is complete and usable.
    func stop() async
    /// Stops capturing and finishes the stream, discarding intent. Used by
    /// Cancel, and by interruption handling.
    func cancel() async
}

/// Whether the app may use the microphone.
public enum MicrophonePermission: String, Hashable, Sendable, CaseIterable {
    case notDetermined
    case authorized
    case denied
    /// Withheld by policy rather than by the user — Screen Time, a managed
    /// device. Distinct from `denied` because the person holding the phone
    /// cannot fix it, so offering them a Settings button is a dead end.
    case restricted
    /// No microphone on this device or in this build.
    case unsupported

    public var isAuthorized: Bool { self == .authorized }

    /// The error to report, or nil when capture may proceed.
    public var failure: SpeechToTextError? {
        switch self {
        case .authorized:
            return nil
        case .denied, .notDetermined:
            // `notDetermined` reaches here only when the prompt could not be
            // shown — the app was backgrounded, or the sheet was dismissed
            // without an answer. Treated as "not now", not as a refusal.
            return .microphonePermissionDenied
        case .restricted:
            return .providerUnavailable(reason: "Voice input is restricted on this device.")
        case .unsupported:
            return .unsupportedDevice(reason: "This device has no microphone available.")
        }
    }
}

/// A microphone a test can drive by hand.
///
/// CI has no microphone and section 116 requires that it not need one. This
/// publishes whatever samples a test hands it, on demand, so the whole pipeline
/// from capture to transcript can be exercised without any audio hardware.
public actor MockMicrophoneCaptureService: MicrophoneCaptureService {
    private var permission: MicrophonePermission
    private let format: SpeechAudioFormat
    private var continuation: AsyncStream<SpeechAudioChunk>.Continuation?

    public private(set) var startCount = 0
    public private(set) var stopCount = 0
    public private(set) var cancelCount = 0
    public private(set) var permissionRequestCount = 0
    /// Whether the microphone is open right now. The recording indicator's
    /// truth, and what a test asserts after Cancel.
    public private(set) var isCapturing = false

    public init(
        permission: MicrophonePermission = .authorized,
        format: SpeechAudioFormat = .whisper
    ) {
        self.permission = permission
        self.format = format
    }

    public func currentPermission() async -> MicrophonePermission { permission }

    public func requestPermission() async -> MicrophonePermission {
        permissionRequestCount += 1
        return permission
    }

    public func captureFormat() async -> SpeechAudioFormat { format }

    public func start() async throws -> SpeechAudioStream {
        guard permission.isAuthorized else {
            throw permission.failure ?? SpeechToTextError.microphonePermissionDenied
        }
        startCount += 1
        isCapturing = true

        var escaped: AsyncStream<SpeechAudioChunk>.Continuation?
        let stream = AsyncStream<SpeechAudioChunk>(bufferingPolicy: .unbounded) { escaped = $0 }
        continuation = escaped
        return SpeechAudioStream(format: format, chunks: stream)
    }

    public func stop() async {
        stopCount += 1
        isCapturing = false
        continuation?.finish()
        continuation = nil
    }

    public func cancel() async {
        cancelCount += 1
        isCapturing = false
        continuation?.finish()
        continuation = nil
    }

    // MARK: Driving it

    public func setPermission(_ permission: MicrophonePermission) {
        self.permission = permission
    }

    /// Publishes a block of audio, as though someone had just spoken.
    public func emit(_ chunk: SpeechAudioChunk) {
        continuation?.yield(chunk)
    }

    /// Publishes `seconds` of constant-amplitude audio. Enough for tests that
    /// only care that *some* audio reached the engine.
    public func emitAudio(seconds: TimeInterval, amplitude: Float = 0.2) {
        let count = Int(format.sampleRate * seconds) * format.channelCount
        emit(SpeechAudioChunk(
            samples: [Float](repeating: amplitude, count: count),
            format: format
        ))
    }
}

/// A microphone on a platform that has none.
///
/// Returned by the live composition on Linux and in any build without the audio
/// frameworks, so the voice button can be shown disabled with a truthful reason
/// rather than opening a session that was never going to work.
public struct UnavailableMicrophoneCaptureService: MicrophoneCaptureService {
    public init() {}

    public func currentPermission() async -> MicrophonePermission { .unsupported }
    public func requestPermission() async -> MicrophonePermission { .unsupported }
    public func captureFormat() async -> SpeechAudioFormat { .whisper }

    public func start() async throws -> SpeechAudioStream {
        throw SpeechToTextError.unsupportedDevice(
            reason: "Voice input isn't available in this build."
        )
    }

    public func stop() async {}
    public func cancel() async {}
}
