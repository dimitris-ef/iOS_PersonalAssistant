import Foundation
import SpeechToText

/// The OpenAI models that transcribe.
///
/// ## Why these are configurable rather than fixed
///
/// Section 45. `whisper-1` was the only transcription model for a long time and
/// plenty of code still assumes it is; it is not. The dedicated speech models
/// that followed are better and cheaper, and the list will change again. So the
/// model is a string carried in configuration, the catalog below is a
/// convenience for the picker rather than a constraint, and an identifier this
/// build has never heard of is passed through to the API unchanged.
///
/// ## Why no chat models are here
///
/// Section 46. `gpt-4o` is not in this list even though it exists and the same
/// key reaches it, because the transcription endpoint does not accept it — and
/// more importantly because offering an assistant model in the *speech* picker
/// is exactly the conflation this milestone removes. Section 44 for the same
/// reason: this calls the transcription endpoint, not the chat endpoint with a
/// request to decode audio by hand.
public enum OpenAITranscriptionModel {

    /// The transcription endpoint. Not the chat endpoint.
    public static let defaultEndpoint = URL(
        string: "https://api.openai.com/v1/audio/transcriptions"
    )!

    /// What is offered in the picker, best-first.
    public static let catalog: [SpeechToTextModelDescriptor] = [
        SpeechToTextModelDescriptor(
            id: "gpt-4o-transcribe",
            providerID: .openAI,
            displayName: "GPT-4o Transcribe",
            summary: "Most accurate. Handles accents and background noise well.",
            supportsPartialResults: false,
            supportsOffline: false
        ),
        SpeechToTextModelDescriptor(
            id: "gpt-4o-mini-transcribe",
            providerID: .openAI,
            displayName: "GPT-4o mini Transcribe",
            summary: "Faster and cheaper, still well above Whisper.",
            supportsPartialResults: false,
            supportsOffline: false
        ),
        SpeechToTextModelDescriptor(
            id: "whisper-1",
            providerID: .openAI,
            displayName: "Whisper",
            summary: "The original hosted Whisper model.",
            supportsPartialResults: false,
            supportsOffline: false
        ),
    ]

    /// The model used when the user has not chosen one.
    public static let defaultModelID: SpeechModelIdentifier = "gpt-4o-transcribe"

    /// The wire identifier to send.
    ///
    /// An unknown identifier is passed through rather than rejected: a model
    /// released after this build shipped should work by typing its name, not
    /// require an app update.
    public static func resolve(_ id: SpeechModelIdentifier?) -> String {
        guard let id, !id.rawValue.isEmpty else { return defaultModelID.rawValue }
        return id.rawValue
    }

    public static func model(for id: SpeechModelIdentifier) -> SpeechToTextModelDescriptor? {
        catalog.first { $0.id == id }
    }
}
