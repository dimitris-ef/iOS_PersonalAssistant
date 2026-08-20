import Foundation

/// Identifies one attempt at speaking.
///
/// The reason this exists is that speech recognition is callback-driven and the
/// callbacks do not stop arriving when you stop wanting them. A recognition task
/// that has been cancelled can still deliver a final result; a task that has
/// already delivered a final result can deliver another. Tagging every callback
/// with the session it belongs to is what makes "ignore anything from a session
/// that is over" a decidable question rather than a race.
public struct VoiceSessionID: Hashable, Sendable {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

/// Where the voice interaction is, as one value.
///
/// Deliberately an enum rather than `isRecording` / `isProcessing` /
/// `isSpeaking` / `hasError` booleans. Four booleans have sixteen combinations
/// and only about five of them mean anything; the other eleven are bugs waiting
/// for a race to produce them — listening *and* speaking, processing *and*
/// failed. An enum cannot represent them at all.
public enum VoiceState: Hashable, Sendable {
    /// Nothing is happening. The microphone is off.
    case idle
    /// A permission prompt is on screen, or about to be.
    case requestingPermission
    /// The microphone is live. `transcript` is the best guess so far and
    /// changes as the user speaks; `level` drives the level meter.
    case listening(transcript: String, level: Float)
    /// The user has stopped speaking and the recognizer is settling on a final
    /// answer. Brief, but a real state: the microphone is already off while the
    /// last words are still arriving.
    case finalizing(transcript: String)
    /// The transcript has been submitted and the assistant is working. The
    /// microphone is off — this is what stops the UI showing an active
    /// microphone while a model is thinking.
    case processing(transcript: String)
    /// The assistant's reply is being read aloud.
    case speaking
    /// Something went wrong, and it is worth telling the user. Rests here until
    /// they retry or dismiss.
    case failed(VoiceError)

    /// True while audio is being captured.
    ///
    /// The single source for the recording indicator. Nothing else in the app
    /// decides whether the microphone is on, so the indicator cannot disagree
    /// with reality.
    public var isCapturingAudio: Bool {
        if case .listening = self { return true }
        return false
    }

    /// The text to show in the composer, if any.
    public var transcript: String? {
        switch self {
        case .listening(let transcript, _), .finalizing(let transcript),
             .processing(let transcript):
            return transcript
        case .idle, .requestingPermission, .speaking, .failed:
            return nil
        }
    }

    /// True when the user could start speaking right now.
    public var canStartListening: Bool {
        switch self {
        case .idle, .failed, .speaking:
            return true
        case .requestingPermission, .listening, .finalizing, .processing:
            return false
        }
    }
}

/// What can go wrong, in this app's vocabulary rather than Apple's.
///
/// Apple's speech and audio errors are `NSError`s with domain codes, arbitrary
/// user-info dictionaries, and descriptions that are sometimes the user's own
/// dictated words. None of that belongs in a SwiftUI view, so the boundary maps
/// them to these cases and the message shown is written here.
public enum VoiceError: Hashable, Sendable {
    case microphonePermissionDenied
    case speechPermissionDenied
    /// Permission was withheld by policy — Screen Time, a managed device — so
    /// the user cannot grant it themselves.
    case restricted
    /// The recognizer exists but is not usable right now. Often temporary.
    case recognitionUnavailable
    /// The user finished without saying anything the recognizer could use.
    case noSpeechDetected
    case audioSessionFailed
    case recognitionFailed
    /// A phone call, Siri, or another app took the audio session.
    case interrupted
    /// This device or build cannot do speech recognition at all.
    case unsupported

    /// One sentence, written here, safe to show.
    public var message: String {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone access is off, so the assistant can't hear you."
        case .speechPermissionDenied:
            return "Speech recognition is not available because permission was denied."
        case .restricted:
            return "Voice input is restricted on this device."
        case .recognitionUnavailable:
            return "Speech recognition isn't available right now."
        case .noSpeechDetected:
            return "I didn't catch that."
        case .audioSessionFailed:
            return "The microphone couldn't be started."
        case .recognitionFailed:
            return "That didn't come through clearly."
        case .interrupted:
            return "Something interrupted the recording."
        case .unsupported:
            return "This device can't do speech recognition."
        }
    }

    /// Whether trying again could plausibly work.
    ///
    /// Drives whether a Retry button appears. A denied permission is not
    /// retryable — pressing Retry would do nothing visible, because iOS shows
    /// its prompt once — so those cases offer a route to Settings instead.
    public var isRetryable: Bool {
        switch self {
        case .noSpeechDetected, .recognitionFailed, .interrupted,
             .audioSessionFailed, .recognitionUnavailable:
            return true
        case .microphonePermissionDenied, .speechPermissionDenied, .restricted,
             .unsupported:
            return false
        }
    }

    /// Whether the fix is in Settings.
    ///
    /// The app never opens Settings on its own — that is a jarring, unrequested
    /// context switch. It offers a button, and the user decides.
    public var isResolvableInSettings: Bool {
        switch self {
        case .microphonePermissionDenied, .speechPermissionDenied:
            return true
        case .restricted, .unsupported, .noSpeechDetected, .recognitionFailed,
             .interrupted, .audioSessionFailed, .recognitionUnavailable:
            return false
        }
    }
}
