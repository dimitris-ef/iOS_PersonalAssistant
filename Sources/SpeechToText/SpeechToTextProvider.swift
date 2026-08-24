import Foundation

/// Which transcription engine, as a stable persisted value.
///
/// A wrapper around a string rather than an enum, for the same reason
/// `AIProviderIdentifier` is: this value is written to the user's settings and
/// read back by a later build, so adding a fourth engine must not renumber the
/// three that exist. The raw values are `apple`, `localWhisper` and `openAI` —
/// never display text (section 5). "Apple Speech Recognition" is a label, it is
/// translated, and it changes; `apple` does not.
///
/// Deliberately a *different type* from `AIProviderIdentifier`. The whole claim
/// of this milestone is that choosing who transcribes and choosing who reasons
/// are two independent decisions, and a shared identifier type would make it
/// possible — one careless assignment — to persist a speech engine as the
/// assistant. The type system refuses instead.
public struct SpeechToTextProviderID: Hashable, Codable, Sendable, CustomStringConvertible,
    ExpressibleByStringLiteral
{
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    /// Apple's own speech recognition, whichever API the device supports.
    public static let apple: SpeechToTextProviderID = "apple"
    /// A Whisper model running on this phone.
    public static let localWhisper: SpeechToTextProviderID = "localWhisper"
    /// OpenAI's transcription API.
    public static let openAI: SpeechToTextProviderID = "openAI"
    /// Deterministic transcription for tests, previews and CI.
    public static let mock: SpeechToTextProviderID = "mock"
}

/// Which speech model, as a stable persisted value.
///
/// Separate from `AIModelIdentifier` for the same reason the provider ID is
/// separate: `whisper-base.en` and `qwen3-1.7b` are not interchangeable, and
/// nothing should be able to store one where the other is expected.
public struct SpeechModelIdentifier: Hashable, Codable, Sendable, CustomStringConvertible,
    ExpressibleByStringLiteral
{
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
}

/// What a transcription engine can and cannot do.
///
/// Read by the UI so one screen can serve all three providers (section 56).
/// A provider that cannot stream partial results says so, and the composer
/// shows "Listening…" rather than inventing text that is not there — which is
/// the honest version of section 53's requirement.
public struct SpeechToTextCapabilities: Hashable, Sendable {
    /// Whether text arrives while the user is still speaking.
    public var supportsPartialResults: Bool
    /// Whether transcription completes with no network at all.
    public var supportsOffline: Bool
    /// Whether audio leaves the device. Drives the privacy sentence in
    /// Settings, and is the flag the cloud-explicitness test asserts on.
    public var sendsAudioOffDevice: Bool
    /// Whether a model file has to be downloaded before this can be used.
    public var requiresModelDownload: Bool
    /// Locales the provider will accept, or nil when it accepts any.
    ///
    /// Nil means "unconstrained as far as this app can tell" — not "all
    /// languages". A provider that genuinely does not know reports nil rather
    /// than a guessed list.
    public var supportedLocales: [Locale]?

    public init(
        supportsPartialResults: Bool,
        supportsOffline: Bool,
        sendsAudioOffDevice: Bool,
        requiresModelDownload: Bool = false,
        supportedLocales: [Locale]? = nil
    ) {
        self.supportsPartialResults = supportsPartialResults
        self.supportsOffline = supportsOffline
        self.sendsAudioOffDevice = sendsAudioOffDevice
        self.requiresModelDownload = requiresModelDownload
        self.supportedLocales = supportedLocales
    }
}

/// Whether transcription could run right now, and if not, why.
///
/// Section 63. Modelled as an enum rather than a `Bool` plus a message because
/// the reasons are not interchangeable: `needsModelDownload` offers a download
/// button, `needsPermission` offers Settings, and `networkRequired` offers
/// neither because the fix is to walk somewhere with signal.
public enum SpeechToTextAvailability: Hashable, Sendable {
    /// Usable now.
    case ready
    /// Microphone or speech-recognition authorization is missing.
    case needsPermission(SpeechPermissionKind)
    /// A local model has to be downloaded first.
    case needsModelDownload
    /// A local model is downloaded and being loaded into memory.
    case modelLoading
    /// Temporarily unusable — a recognizer offline, an asset not yet installed.
    case unavailable(reason: String)
    /// This device or OS version cannot run this provider at all.
    case unsupported(reason: String)
    /// The provider needs a network and there is not one.
    case networkRequired
    /// Configured wrongly — most often a missing API key.
    case misconfigured(reason: String)
    /// The provider tried to become ready and could not.
    case failed(SpeechToTextError)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    /// One sentence for the Settings row. Written here so no view composes it.
    public var summary: String {
        switch self {
        case .ready:
            return "Ready"
        case .needsPermission(let kind):
            return kind.summary
        case .needsModelDownload:
            return "A speech model needs to be downloaded."
        case .modelLoading:
            return "Preparing…"
        case .unavailable(let reason):
            return reason
        case .unsupported(let reason):
            return reason
        case .networkRequired:
            return "Needs an internet connection."
        case .misconfigured(let reason):
            return reason
        case .failed(let error):
            return error.message
        }
    }
}

/// Which authorization is missing.
public enum SpeechPermissionKind: String, Hashable, Sendable {
    case microphone
    case speechRecognition

    public var summary: String {
        switch self {
        case .microphone:
            return "Microphone access is off."
        case .speechRecognition:
            return "Speech recognition permission is off."
        }
    }
}

/// What to transcribe, and how.
///
/// Section 7, and note what is *not* here: no assistant model, no memory
/// setting, no tool configuration. This value fully describes a transcription
/// and says nothing at all about what happens to the resulting text.
public struct SpeechToTextConfiguration: Hashable, Sendable {
    public var providerID: SpeechToTextProviderID
    /// The provider's own model, where it has a choice. Nil means the provider
    /// decides — which is the normal case for Apple.
    public var modelID: SpeechModelIdentifier?
    /// The language to transcribe. Nil follows the device.
    public var locale: Locale?
    /// Whether the caller wants live text. A provider that cannot produce it
    /// ignores this rather than faking it.
    public var partialResultsEnabled: Bool

    public init(
        providerID: SpeechToTextProviderID,
        modelID: SpeechModelIdentifier? = nil,
        locale: Locale? = nil,
        partialResultsEnabled: Bool = true
    ) {
        self.providerID = providerID
        self.modelID = modelID
        self.locale = locale
        self.partialResultsEnabled = partialResultsEnabled
    }

    /// The locale to actually use.
    public func resolvedLocale() -> Locale {
        locale ?? Locale.current
    }
}

/// Turning captured audio into text. The entire contract.
///
/// ## The boundary this protocol draws
///
/// Section 2, stated as a type signature: everything a provider can produce is
/// a `SpeechToTextEvent`, and the richest thing that enum carries is a
/// `String`. There is no member here that returns a tool call, reaches a
/// repository, names an `AIProvider`, or takes an `AssistantEngine`. A speech
/// provider cannot call the assistant because it has not been given anything to
/// call it with.
///
/// That is deliberately stronger than a rule in a document. The architecture
/// test asserts the absence of the concrete provider names; the protocol makes
/// their presence not merely forbidden but unrepresentable.
///
/// ## Why `start` returns a session
///
/// Because cancellation has to be addressable. A provider that exposed
/// `transcribe(audio:) async -> String` would leave the caller with nothing to
/// cancel but the `Task`, and cancelling a `Task` does not stop an HTTP upload
/// or unload a Whisper context. The session is the handle Stop and Cancel act
/// on.
public protocol SpeechToTextProvider: Sendable {
    var id: SpeechToTextProviderID { get }
    var capabilities: SpeechToTextCapabilities { get }

    /// Whether transcription could start right now. Asked each time rather than
    /// cached: a recognizer can go offline, an asset can finish downloading,
    /// and a network can come back.
    func availability(for configuration: SpeechToTextConfiguration) async
        -> SpeechToTextAvailability

    /// Begins a transcription over the supplied audio.
    ///
    /// The provider consumes `audio` and publishes events. It does not open the
    /// microphone — capture is shared and already running by the time this is
    /// called (section 9).
    func startSession(
        configuration: SpeechToTextConfiguration,
        audio: SpeechAudioStream
    ) async throws -> SpeechToTextSession
}
