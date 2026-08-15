import AssistantDomain
import Foundation

/// What a remote provider needs to reach a service.
///
/// **The API key is deliberately not in here.** Non-secret settings (endpoint,
/// model, tuning) are ordinary preferences that can live in plain storage; the
/// credential is fetched separately from a ``CredentialProvider`` backed by the
/// Keychain. Keeping them in one struct is how keys end up in UserDefaults, in
/// logs and in `description` output.
public struct RemoteAIConfiguration: Hashable, Codable, Sendable {
    /// The service root, e.g. `https://api.openai.com/v1`. Path suffixes are
    /// normalised by ``RemoteAIEndpoint``.
    public var baseURL: String
    /// An opaque model identifier. Never an enum — compatible services use
    /// names this app has never heard of.
    public var model: String
    public var timeout: TimeInterval
    public var temperature: Double?
    public var maximumOutputTokens: Int?

    public init(
        baseURL: String = "",
        model: String = "",
        timeout: TimeInterval = 60,
        temperature: Double? = nil,
        maximumOutputTokens: Int? = nil
    ) {
        self.baseURL = baseURL
        self.model = model
        self.timeout = timeout
        self.temperature = temperature
        self.maximumOutputTokens = maximumOutputTokens
    }

    /// What is still missing before a request could be made.
    ///
    /// Returns every problem rather than the first, so the UI can say
    /// "endpoint and model" instead of making the user fix one at a time.
    public func missingRequirements(hasCredential: Bool) -> [Requirement] {
        var missing: [Requirement] = []

        if baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            missing.append(.endpoint)
        } else if RemoteAIEndpoint(baseURL: baseURL) == nil {
            missing.append(.validEndpoint)
        }

        if model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            missing.append(.model)
        }
        if !hasCredential {
            missing.append(.apiKey)
        }
        return missing
    }

    public enum Requirement: String, Hashable, Sendable {
        case endpoint
        case validEndpoint
        case model
        case apiKey

        public var label: String {
            switch self {
            case .endpoint: return "an endpoint"
            case .validEndpoint: return "a valid endpoint URL"
            case .model: return "a model name"
            case .apiKey: return "an API key"
            }
        }
    }

    /// The endpoint's host, for display. Never the full URL — a configured
    /// endpoint can carry a token in its path or query on some services.
    public var displayHost: String? {
        RemoteAIEndpoint(baseURL: baseURL)?.host
    }
}

/// Supplies the current configuration at request time.
///
/// A protocol rather than a stored value so the provider always reads what the
/// user last saved, without the app having to rebuild the provider whenever a
/// setting changes.
public protocol RemoteAIConfigurationSource: Sendable {
    func configuration() async -> RemoteAIConfiguration
}

/// A fixed configuration, for tests and for composition roots that already
/// know the values.
public struct StaticRemoteAIConfigurationSource: RemoteAIConfigurationSource {
    private let value: RemoteAIConfiguration

    public init(_ value: RemoteAIConfiguration) {
        self.value = value
    }

    public func configuration() async -> RemoteAIConfiguration { value }
}
