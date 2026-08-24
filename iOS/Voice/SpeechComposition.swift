import AssistantPersistence
import AssistantVoice
import Foundation
import SpeechToText
import SpeechToTextApple
import SpeechToTextLocal
import SpeechToTextLocalWhisper
import SpeechToTextOpenAI

/// Assembles the speech-to-text stack this build has.
///
/// ## The composition root for transcription
///
/// One place decides which providers exist, which runtime backs the local one,
/// and where the OpenAI credential is read from. Everything above sees a
/// `SpeechToTextProviderRegistry` and a `SpeechInputService` — neither of which
/// names a concrete provider — which is what makes section 35 and 36 true:
/// changing the speech provider is a value written to settings, not a rewiring.
///
/// ## What is deliberately absent
///
/// No `AIProviderRegistry`, no `AssistantEngine`, no repositories. This file
/// builds the thing that turns audio into a string and stops there. The string
/// meets the assistant in `AppEnvironment`, through the same `submit(text:)`
/// that typed input uses.
@MainActor
enum SpeechComposition {

    /// The registry for a real build.
    ///
    /// All three providers are constructed whether or not they are usable —
    /// each one reports its own availability, and a provider that is missing
    /// from the registry would be indistinguishable from one that is merely
    /// unconfigured. The Settings list needs to show "OpenAI — add an API key",
    /// not an absence.
    static func liveRegistry(
        credentialStore: any CredentialStore,
        speechModels: LocalSpeechModelManager,
        runtime: any LocalSpeechRuntime
    ) -> SpeechToTextProviderRegistry {
        SpeechToTextProviderRegistry(providers: [
            AppleSpeechToTextProvider(),
            LocalSpeechToTextProvider(models: speechModels, runtime: runtime),
            OpenAISpeechToTextProvider(
                credential: {
                    // Section 43 and 69: the same Keychain-backed credential
                    // the Remote AI settings already manage. There is no second
                    // key to enter, and no second place a key could be stored.
                    try? await credentialStore.credential(
                        for: .remoteAIAPIKey(providerID: "openai")
                    )
                }
            ),
        ])
    }

    /// A registry with no real engines, for demo launches and CI screenshots.
    ///
    /// A GitHub runner has no microphone, no Whisper model and no API key, and
    /// section 118 requires the voice UI to render regardless.
    static func mockRegistry() -> SpeechToTextProviderRegistry {
        SpeechToTextProviderRegistry(providers: [
            MockSpeechToTextProvider(
                id: .apple,
                behaviour: .transcribes(
                    partials: ["Remind me tomorrow", "Remind me tomorrow to call"],
                    final: "Remind me tomorrow to call the dentist."
                )
            ),
            MockSpeechToTextProvider(
                id: .localWhisper,
                behaviour: .finalOnly("Remind me tomorrow to call the dentist."),
                availability: .needsModelDownload,
                capabilities: SpeechToTextCapabilities(
                    supportsPartialResults: false,
                    supportsOffline: true,
                    sendsAudioOffDevice: false,
                    requiresModelDownload: true
                )
            ),
            MockSpeechToTextProvider(
                id: .openAI,
                behaviour: .finalOnly("Remind me tomorrow to call the dentist."),
                availability: .misconfigured(
                    reason: "Add an OpenAI API key in Remote AI settings to use this."
                ),
                capabilities: SpeechToTextCapabilities(
                    supportsPartialResults: false,
                    supportsOffline: false,
                    sendsAudioOffDevice: true
                )
            ),
        ])
    }

    /// The manager for on-device speech models.
    ///
    /// Falls back to a temporary directory when Application Support cannot be
    /// reached, which keeps the app running rather than failing at launch over
    /// a models folder — the manager will simply report nothing installed.
    static func speechModelManager(runtime: any LocalSpeechRuntime) -> LocalSpeechModelManager {
        let store = (try? LocalSpeechModelManager.applicationSupportStore())
            ?? .temporary(prefix: "speech-models")
        return LocalSpeechModelManager(store: store, runtime: runtime)
    }

    /// Part 5's input service, backed by the selected provider.
    ///
    /// The configuration is read fresh on every session, so changing provider
    /// in Settings while the composer is open sends the *next* thing the user
    /// says to the engine they just picked.
    static func inputService(
        microphone: any MicrophoneCaptureService,
        registry: SpeechToTextProviderRegistry,
        selection: @escaping @Sendable () -> SpeechSelection
    ) -> any SpeechInputService {
        SpeechPipelineInputService(
            microphone: microphone,
            registry: registry,
            configuration: { selection().configuration() }
        )
    }
}

/// Reads and writes the speech selection through `UserDefaults`.
///
/// The app's adapter for the storage protocol. `UserDefaults` holds a provider
/// name and a model name — section 43's list of what must *not* go here is
/// about credentials, and neither of these is one.
struct UserDefaultsSpeechSettingsStore: SpeechSettingsStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func string(forKey key: String) -> String? { defaults.string(forKey: key) }

    func bool(forKey key: String) -> Bool? {
        defaults.object(forKey: key) == nil ? nil : defaults.bool(forKey: key)
    }

    func set(_ value: String?, forKey key: String) {
        if let value, !value.isEmpty {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    func set(_ value: Bool, forKey key: String) {
        defaults.set(value, forKey: key)
    }
}
