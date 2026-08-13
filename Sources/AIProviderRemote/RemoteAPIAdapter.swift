import AssistantAI
import AssistantDomain
import Foundation

/// Translates between the app's AI types and one vendor's wire format.
///
/// This is what keeps the application from being coupled to any single API
/// company: adding a vendor means writing one adapter, not touching the
/// assistant, the tool system or the prompt builder. No adapter implementations
/// ship yet, because which API to support is a product decision, not an
/// architectural one.
public protocol RemoteAPIAdapter: Sendable {
    /// Identifier for the concrete service, e.g. "remote.acme".
    var providerID: AIProviderIdentifier { get }
    var displayName: String { get }
    /// Roughly how capable this service's models are, for `.preferMostCapable` routing.
    var capabilityRank: Int { get }

    /// Models this adapter exposes. May be a static list or fetched.
    func availableModels() async throws -> [AIModel]

    /// Builds the HTTP request for one turn, including auth headers built from
    /// the supplied credential.
    func makeRequest(from request: AIRequest, credential: String) throws -> HTTPRequest

    /// Parses a successful response into the app's shape, including any tool
    /// calls, which must come from the API's structured tool-calling output
    /// rather than from parsing the assistant's prose.
    func parse(_ response: HTTPResponse, for request: AIRequest) throws -> AIResponse
}

/// Supplies API credentials.
///
/// Credentials are never held in source or in `AssistantSettings`. On iOS this
/// is backed by the Keychain; during Windows development, by the environment.
public protocol CredentialProvider: Sendable {
    func credential(for providerID: AIProviderIdentifier) async -> String?
}

/// Reads credentials from environment variables.
///
/// The variable name is derived from the provider id, e.g. `remote.acme` →
/// `ASSISTANT_API_KEY_REMOTE_ACME`.
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
        return ProcessInfo.processInfo.environment[prefix + suffix]
    }
}

/// TODO-XCODE: Keychain-backed credential storage for the iOS build.
/// `EnvironmentCredentialProvider` is a development convenience only and must
/// not ship in the app.
