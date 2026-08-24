import Foundation

/// What can go wrong on the way from audio to text.
///
/// ## Why this is not `AIProviderError`
///
/// Section 64. The two families look superficially similar — both have
/// "unavailable", both have "authentication failed" — but they mean different
/// things to the user and lead to different buttons. `AIProviderError.rateLimited`
/// is about the assistant's model; `SpeechToTextError.authenticationFailed` is
/// about the *transcription* credential, and offering to reconfigure the
/// assistant when the speech key is wrong would send someone to fix a setting
/// that is already correct.
///
/// Sharing the type would also have made a subtler mistake possible: an error
/// thrown by transcription flowing into the assistant's retry logic and causing
/// a model call. Separate types make that a compile error.
///
/// ## Why the messages are here
///
/// Section 52: HTTP status codes, `NSError` domains and whisper.cpp return
/// values must not reach SwiftUI. Each provider maps its own vocabulary into
/// this enum at its boundary, and the sentence shown to the user is written
/// once, here.
public enum SpeechToTextError: Error, Hashable, Sendable, CustomStringConvertible {

    // MARK: Permission

    case microphonePermissionDenied
    case speechPermissionDenied

    // MARK: Provider state

    /// The provider exists but cannot run now. Often temporary.
    case providerUnavailable(reason: String)
    /// This device or OS cannot run this provider at all.
    case unsupportedDevice(reason: String)
    /// The provider does not handle the requested language.
    case unsupportedLocale(String)

    // MARK: Local model

    case modelNotDownloaded
    /// The file on disk failed verification.
    case modelCorrupt(reason: String)
    /// The file is valid but will not run here — wrong format, wrong runtime.
    case modelIncompatible(reason: String)
    /// Loading or running the model exhausted memory.
    case insufficientMemory
    case insufficientStorage(reason: String)

    // MARK: Cloud

    case networkUnavailable
    /// The credential is missing, wrong, or refused.
    case authenticationFailed(reason: String)

    // MARK: Outcome

    /// The engine ran and did not produce usable text.
    case transcriptionFailed(reason: String)
    /// No speech was found in the audio.
    case noSpeechDetected
    case cancelled

    /// One sentence, safe to show, written here rather than by a view.
    ///
    /// Deliberately free of diagnostics. "The request failed with status 401"
    /// is a sentence for a log; "Your OpenAI key was refused" is a sentence for
    /// a person, and only one of them tells them what to do next.
    public var message: String {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone access is off, so the assistant can't hear you."
        case .speechPermissionDenied:
            return "Speech recognition is not available because permission was denied."
        case .providerUnavailable(let reason):
            return reason
        case .unsupportedDevice(let reason):
            return reason
        case .unsupportedLocale(let language):
            return "This speech provider doesn't handle \(language)."
        case .modelNotDownloaded:
            return "Download a speech model before using on-device transcription."
        case .modelCorrupt:
            return "The speech model is damaged. Download it again."
        case .modelIncompatible(let reason):
            return reason
        case .insufficientMemory:
            return "There wasn't enough memory to transcribe. Try a smaller speech model."
        case .insufficientStorage(let reason):
            return reason
        case .networkUnavailable:
            // Says *which* thing needs the network. With three providers and
            // only one of them online, "no connection" alone would leave the
            // user wondering why a phone in aeroplane mode cannot hear them.
            return "Transcription needs an internet connection with this speech provider."
        case .authenticationFailed(let reason):
            return reason
        case .transcriptionFailed(let reason):
            return reason
        case .noSpeechDetected:
            return "I didn't catch that."
        case .cancelled:
            return "Transcription was cancelled."
        }
    }

    public var description: String { message }

    /// Whether trying the same thing again could plausibly work.
    ///
    /// Drives whether Retry appears. A denied permission is not retryable — iOS
    /// shows its prompt once — so those offer a route to Settings instead.
    public var isRetryable: Bool {
        switch self {
        case .providerUnavailable, .networkUnavailable, .transcriptionFailed,
             .noSpeechDetected, .cancelled, .insufficientMemory:
            return true
        case .microphonePermissionDenied, .speechPermissionDenied, .unsupportedDevice,
             .unsupportedLocale, .modelNotDownloaded, .modelCorrupt, .modelIncompatible,
             .insufficientStorage, .authenticationFailed:
            return false
        }
    }

    /// Whether the fix is somewhere in Settings — the app's or the system's.
    public var isResolvableInSettings: Bool {
        switch self {
        case .microphonePermissionDenied, .speechPermissionDenied, .authenticationFailed,
             .modelNotDownloaded, .modelCorrupt, .modelIncompatible, .unsupportedLocale:
            return true
        case .providerUnavailable, .unsupportedDevice, .insufficientMemory,
             .insufficientStorage, .networkUnavailable, .transcriptionFailed,
             .noSpeechDetected, .cancelled:
            return false
        }
    }

    /// Whether this is a problem with the *speech* configuration rather than
    /// with the assistant's.
    ///
    /// Section 112: a refused transcription credential must be presented as a
    /// speech-provider problem and must not send anyone to change the
    /// assistant's model settings. Every case here is true — which is the
    /// point, and is asserted by a test rather than merely stated.
    public var isSpeechConfigurationProblem: Bool { true }
}
