import AIProviderRemote
import AssistantDomain
import Foundation
import Observation

/// Stores the remote provider's non-secret settings.
///
/// Endpoint, model and tuning are ordinary preferences and live in
/// `UserDefaults`. **The API key is not here** — it goes to the Keychain
/// through `CredentialStore`. Keeping the two apart is what stops a secret
/// ending up in a plist, a backup or a debug description.
///
/// Reads fall back to development values supplied by a gitignored xcconfig, so
/// a developer can run against a real service without typing credentials into
/// Settings every launch. User-entered values always win — see
/// `Docs/REMOTE-AI.md`.
@MainActor
@Observable
final class RemoteAIConfigurationStore: RemoteAIConfigurationSource {
    private enum Key {
        static let baseURL = "remoteAI.baseURL"
        static let model = "remoteAI.model"
        static let timeout = "remoteAI.timeout"
    }

    private let defaults: UserDefaults
    private let developmentDefaults: DevelopmentRemoteAIDefaults

    private(set) var current: RemoteAIConfiguration

    init(
        defaults: UserDefaults = .standard,
        developmentDefaults: DevelopmentRemoteAIDefaults = DevelopmentRemoteAIDefaults()
    ) {
        self.defaults = defaults
        self.developmentDefaults = developmentDefaults
        self.current = Self.load(from: defaults, development: developmentDefaults)
    }

    /// `RemoteAIConfigurationSource` — read by the provider on every turn, so a
    /// change in Settings takes effect on the next message with no rebuild.
    nonisolated func configuration() async -> RemoteAIConfiguration {
        await MainActor.run { current }
    }

    func update(baseURL: String, model: String) {
        var updated = current
        updated.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        current = updated

        defaults.set(updated.baseURL, forKey: Key.baseURL)
        defaults.set(updated.model, forKey: Key.model)
    }

    /// Clears what the user set, falling back to any development defaults.
    func reset() {
        defaults.removeObject(forKey: Key.baseURL)
        defaults.removeObject(forKey: Key.model)
        defaults.removeObject(forKey: Key.timeout)
        current = Self.load(from: defaults, development: developmentDefaults)
    }

    private static func load(
        from defaults: UserDefaults,
        development: DevelopmentRemoteAIDefaults
    ) -> RemoteAIConfiguration {
        // Priority: what the user saved, then the development file, then empty.
        let baseURL = nonEmpty(defaults.string(forKey: Key.baseURL))
            ?? development.baseURL
            ?? ""
        let model = nonEmpty(defaults.string(forKey: Key.model))
            ?? development.model
            ?? ""

        let storedTimeout = defaults.double(forKey: Key.timeout)
        return RemoteAIConfiguration(
            baseURL: baseURL,
            model: model,
            timeout: storedTimeout > 0 ? storedTimeout : 60
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }
}

/// Development-only defaults read from the app bundle.
///
/// The values are injected at build time from `Config/LocalSecrets.xcconfig`,
/// which is gitignored. When that file is absent — as it is in CI and for
/// anyone who has not created it — every value is empty and the remote provider
/// simply reports that it needs configuring.
///
/// These are a convenience for development. They are baked into the built
/// bundle, so a real key placed here must never ship.
struct DevelopmentRemoteAIDefaults: Sendable {
    let baseURL: String?
    let model: String?
    let apiKey: String?

    init(bundle: Bundle = .main) {
        func value(_ key: String) -> String? {
            guard
                let raw = bundle.object(forInfoDictionaryKey: key) as? String
            else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // The template ships placeholders; treat them as absent.
            guard !trimmed.isEmpty, !trimmed.hasPrefix("$("), !trimmed.hasPrefix("YOUR_") else {
                return nil
            }
            return trimmed
        }

        baseURL = value("RemoteAIBaseURL")
        model = value("RemoteAIModel")
        apiKey = value("RemoteAIAPIKey")
    }
}

/// Offers the development API key, if one was built in.
///
/// Placed last in the credential chain so it can never override a key the user
/// saved to the Keychain.
struct DevelopmentSecretsCredentialProvider: CredentialProvider {
    private let apiKey: String?

    init(defaults: DevelopmentRemoteAIDefaults = DevelopmentRemoteAIDefaults()) {
        self.apiKey = defaults.apiKey
    }

    func credential(for providerID: AIProviderIdentifier) async -> String? {
        apiKey
    }
}
