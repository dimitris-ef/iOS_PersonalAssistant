import AssistantAI
import AssistantDomain
import Foundation

/// Translates between the app's AI types and one vendor's wire format.
///
/// This is what keeps the application from being coupled to any single API
/// company: adding a vendor means writing one adapter, not touching the
/// assistant, the tool system or the prompt builder.
///
/// ``OpenAICompatibleAdapter`` implements the chat-completions protocol, which
/// covers OpenAI itself and the many services and self-hosted servers that
/// implement it. A vendor with a different protocol gets its own adapter and
/// changes nothing above this line.
public protocol RemoteAPIAdapter: Sendable {
    /// Identifier for the concrete service, e.g. "remote.openai-compatible".
    var providerID: AIProviderIdentifier { get }
    var displayName: String { get }
    /// Roughly how capable this service's models are, for `.preferMostCapable` routing.
    var capabilityRank: Int { get }

    /// Models this adapter exposes for the given configuration.
    func availableModels(configuration: RemoteAIConfiguration) async throws -> [AIModel]

    /// Builds the HTTP request for one turn, including auth headers built from
    /// the supplied credential.
    ///
    /// The credential is passed per-call rather than stored, so no adapter
    /// holds a secret for longer than one request.
    func makeRequest(
        from request: AIRequest,
        configuration: RemoteAIConfiguration,
        credential: String
    ) throws -> HTTPRequest

    /// Parses a successful response into the app's shape, including any tool
    /// calls, which must come from the API's structured tool-calling output
    /// rather than from parsing the assistant's prose.
    func parse(_ response: HTTPResponse, for request: AIRequest) throws -> AIResponse
}

/// Supplies API credentials to the provider.
///
/// Read-only and deliberately narrow. `AIProviderRemote` depends on
/// `AssistantAI` and nothing else, so it cannot reach the app's repositories
/// even by accident — the composition root bridges this to whatever secure
/// store the platform offers (`CredentialStore` in `AssistantPersistence`,
/// backed by the Keychain on iOS).
public protocol CredentialProvider: Sendable {
    func credential(for providerID: AIProviderIdentifier) async -> String?
}

/// Reads credentials from environment variables.
///
/// The variable name is derived from the provider id, e.g.
/// `remote.openai-compatible` → `ASSISTANT_API_KEY_REMOTE_OPENAI_COMPATIBLE`.
///
/// Development only — for the CLI harness and for running against a local
/// server without going through Settings. The shipping app uses the Keychain.
public struct EnvironmentCredentialProvider: CredentialProvider {
    private let prefix: String

    public init(prefix: String = "ASSISTANT_API_KEY_") {
        self.prefix = prefix
    }

    public func credential(for providerID: AIProviderIdentifier) async -> String? {
        let suffix = providerID.rawValue
            .uppercased()
            .replacingOccurrences(of: ".", with: "_")
            .replacingOccurrences(of: "-", with: "_")
        let value = ProcessInfo.processInfo.environment[prefix + suffix]
        return value?.isEmpty == true ? nil : value
    }
}

/// Holds a credential in memory for the lifetime of the process.
///
/// For tests and previews. Never for storage.
public actor InMemoryCredentialProvider: CredentialProvider {
    private var credentials: [AIProviderIdentifier: String]

    public init(credentials: [AIProviderIdentifier: String] = [:]) {
        self.credentials = credentials
    }

    public func credential(for providerID: AIProviderIdentifier) async -> String? {
        let value = credentials[providerID]
        return value?.isEmpty == true ? nil : value
    }

    public func set(_ credential: String?, for providerID: AIProviderIdentifier) {
        credentials[providerID] = credential
    }
}

/// Tries each source in order and takes the first credential found.
///
/// The order is the configuration priority: whatever the user saved at runtime
/// wins over a development fallback, so a local secrets file can never quietly
/// override a key someone typed into Settings.
public struct ChainedCredentialProvider: CredentialProvider {
    private let sources: [any CredentialProvider]

    public init(_ sources: [any CredentialProvider]) {
        self.sources = sources
    }

    public func credential(for providerID: AIProviderIdentifier) async -> String? {
        for source in sources {
            if let credential = await source.credential(for: providerID),
               !credential.isEmpty {
                return credential
            }
        }
        return nil
    }
}
