import Foundation

/// Whether the app may listen, in the app's own vocabulary.
///
/// Apple's authorization enums stay inside the Apple implementation. The UI
/// asks this type, which means a view never switches over
/// `SFSpeechRecognizerAuthorizationStatus` and the state machine can be tested
/// on a machine where that type does not exist.
public enum VoicePermission: String, Hashable, Sendable, CaseIterable {
    case notDetermined
    case authorized
    case denied
    /// Withheld by policy rather than by the user — Screen Time, a managed
    /// device. Kept apart from `denied` because the person holding the phone
    /// cannot fix it, so offering them a Settings button would be a dead end.
    case restricted
    /// No speech recognition on this device or in this build at all.
    case unsupported

    /// The error to show, or nil when listening may proceed.
    ///
    /// Both microphone and speech permission collapse into one answer here,
    /// because the *combination* is what decides whether voice works. Which of
    /// the two was refused is reported separately in Settings, where it is
    /// actionable.
    public var failure: VoiceError? {
        switch self {
        case .authorized: return nil
        case .denied: return .microphonePermissionDenied
        case .restricted: return .restricted
        case .unsupported: return .unsupported
        case .notDetermined:
            // Reached when the prompt could not be shown — the app was
            // backgrounded, or the request was dismissed without an answer.
            // Treated as "not now" rather than as a refusal.
            return .microphonePermissionDenied
        }
    }
}

/// The two permissions voice needs, reported separately for Settings.
public struct VoicePermissions: Hashable, Sendable {
    public var microphone: VoicePermission
    public var speechRecognition: VoicePermission

    public init(microphone: VoicePermission, speechRecognition: VoicePermission) {
        self.microphone = microphone
        self.speechRecognition = speechRecognition
    }

    /// The combined answer the state machine acts on.
    ///
    /// The worse of the two wins, and the order matters: a denied microphone is
    /// reported ahead of a denied recognizer, because without a microphone the
    /// recognizer's state is irrelevant and telling someone to fix the second
    /// thing first wastes their time.
    public var combined: VoicePermission {
        for permission in [microphone, speechRecognition] {
            if permission != .authorized { return permission }
        }
        return .authorized
    }
}

/// One recognition result on its way to becoming a user message.
public struct SpeechTranscript: Hashable, Sendable {
    public var text: String
    /// False while the recognizer is still refining. Only a final transcript is
    /// ever submitted.
    public var isFinal: Bool
    /// Rough input loudness, 0...1, for the level meter. Presentation only —
    /// never persisted, and recognition works identically without it.
    public var level: Float

    public init(text: String, isFinal: Bool, level: Float = 0) {
        self.text = text
        self.isFinal = isFinal
        self.level = level
    }
}

/// What a live recognition session reports back.
///
/// A protocol rather than a closure because there are three distinct things to
/// say and grouping them keeps the coordinator's wiring readable. Every method
/// carries the `VoiceSessionID` so the coordinator can drop callbacks from a
/// session the user has already abandoned — speech APIs do not stop talking
/// just because you stopped listening.
public protocol SpeechInputDelegate: AnyObject, Sendable {
    func speechInput(_ session: VoiceSessionID, didProduce transcript: SpeechTranscript)
    func speechInput(_ session: VoiceSessionID, didFailWith error: VoiceError)
}

/// Turning speech into text. The only thing the voice UI knows about
/// recognition.
///
/// Implementations: `AppleSpeechInputService` in the app,
/// `MockSpeechInputService` in tests, previews and CI. Nothing above this
/// protocol knows whether recognition is happening on the device, in the cloud,
/// or not at all.
public protocol SpeechInputService: AnyObject, Sendable {
    /// Reads current authorization without prompting, so Settings can describe
    /// the world without changing it.
    func currentPermissions() async -> VoicePermissions
    /// Prompts, if prompting can still help.
    func requestPermissions() async -> VoicePermissions

    /// Whether recognition could run right now. Availability changes —
    /// a recognizer can go offline and come back — so this is asked each time
    /// rather than cached at launch.
    func isAvailable() async -> Bool

    /// Opens the microphone. Results arrive on `delegate`.
    func startListening(session: VoiceSessionID, delegate: any SpeechInputDelegate) async
    /// "I've finished speaking": stop capturing, but let the recognizer settle
    /// and deliver its final result.
    func stopListening() async
    /// "Forget it": tear everything down and deliver nothing.
    func cancelListening() async

    /// A truthful description of where recognition happens, for the privacy
    /// screen. Never a guess — see `SpeechRecognitionMode`.
    func recognitionMode() async -> SpeechRecognitionMode
}

/// Where recognition actually runs.
///
/// Reported rather than assumed. Claiming on-device processing that is not
/// happening would be a privacy lie, and `SFSpeechRecognizer` only guarantees
/// it when `supportsOnDeviceRecognition` is true *and* the request asked for
/// it, so both are checked before this says `.onDevice`.
public enum SpeechRecognitionMode: String, Hashable, Sendable {
    case onDevice
    case server
    case unavailable

    public var description: String {
        switch self {
        case .onDevice: return "On this iPhone"
        case .server: return "Apple's servers"
        case .unavailable: return "Unavailable"
        }
    }
}

/// Reading the assistant's replies aloud.
///
/// Separate from input on purpose: they are different capabilities with
/// different permissions — speaking needs none — and a single "voice service"
/// doing both would make the microphone code depend on the synthesiser.
public protocol SpeechOutputService: AnyObject, Sendable {
    func speak(_ text: String) async
    func stop() async
    func isSpeaking() async -> Bool
}
