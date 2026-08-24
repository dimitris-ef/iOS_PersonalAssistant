import Foundation
import SpeechToText

/// One of Apple's speech APIs, behind a shape this provider can choose between.
///
/// ## Why a chain rather than one implementation
///
/// Section 14. Apple has three generations of speech API in play and which one
/// a device has depends on its OS and its locale:
///
/// - `SpeechAnalyzer` + `SpeechTranscriber` — current, async-native, explicit
///   about assets and about what is finalized. Not on every device or locale.
/// - `DictationTranscriber` — Apple's documented compatibility module for
///   devices where `SpeechTranscriber` is unavailable.
/// - `SFSpeechRecognizer` — available everywhere this app deploys.
///
/// Section 14 also says all of them live under one provider, and they do: the
/// user picks "Apple Speech" and gets the best one their phone can run. Which
/// one that is is reported honestly, because the privacy answer differs between
/// them (section 17).
protocol AppleTranscriberBackend: Sendable {
    /// Which API this is, for the privacy and availability text.
    var kind: AppleTranscriberKind { get }

    /// Whether this backend can run for a locale right now.
    func availability(for locale: Locale) async -> SpeechToTextAvailability

    /// Whether audio is processed on the device.
    ///
    /// Reported, never assumed. Section 17 is explicit that not every Apple
    /// path guarantees on-device processing, and claiming it where it does not
    /// hold would be the worst kind of privacy claim to get wrong.
    func isOnDevice(for locale: Locale) async -> Bool

    /// Runs one transcription over the supplied audio.
    ///
    /// The backend publishes into `emitter` and returns when it has emitted a
    /// terminal event or been cancelled.
    func transcribe(
        audio: SpeechAudioStream,
        locale: Locale,
        wantsPartialResults: Bool,
        emitter: SpeechEventEmitter,
        control: AppleTranscriptionControl
    ) async
}

/// Which of Apple's APIs is in use.
enum AppleTranscriberKind: String, Sendable {
    case speechAnalyzer
    case dictationTranscriber
    case speechRecognizer

    /// What Settings says about this path.
    ///
    /// Section 17: conservative, and specific to the path actually running.
    var privacySummary: String {
        switch self {
        case .speechAnalyzer:
            return "Uses Apple's current on-device speech recognition."
        case .dictationTranscriber:
            return "Uses Apple's dictation recognition."
        case .speechRecognizer:
            return "Uses Apple's native speech recognition."
        }
    }
}

/// Shared stop/cancel state for a running Apple transcription.
///
/// Apple's three APIs finish in three different ways — a task to cancel, an
/// analyzer to finalize, a request to end — and the provider above needs one
/// handle for all of them. This is that handle: the backend observes it, the
/// session's `finish` and `cancel` set it.
final class AppleTranscriptionControl: @unchecked Sendable {
    private let lock = NSLock()
    private var _isFinishing = false
    private var _isCancelled = false

    var isFinishing: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isFinishing
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isCancelled
    }

    func finish() {
        lock.lock(); _isFinishing = true; lock.unlock()
    }

    func cancel() {
        lock.lock(); _isCancelled = true; _isFinishing = true; lock.unlock()
    }
}
