import AssistantAI
import AssistantDomain
import Foundation

/// Provider for models reached over the network.
///
/// The provider itself is vendor-neutral: everything specific to a particular
/// API lives in the injected ``RemoteAPIAdapter``, and everything specific to
/// transport lives in the injected ``HTTPTransport``. Swapping vendors is a
/// composition change.
public struct RemoteAIProvider: AIProvider {
    public let metadata: AIProviderMetadata

    private let adapter: any RemoteAPIAdapter
    private let transport: any HTTPTransport
    private let credentials: any CredentialProvider

    public init(
        adapter: any RemoteAPIAdapter,
        transport: any HTTPTransport = URLSessionHTTPTransport(),
        credentials: any CredentialProvider = EnvironmentCredentialProvider()
    ) {
        self.adapter = adapter
        self.transport = transport
        self.credentials = credentials
        self.metadata = AIProviderMetadata(
            id: adapter.providerID,
            displayName: adapter.displayName,
            kind: .remoteAPI,
            requiresNetwork: true,
            requiresCredentials: true,
            capabilityRank: adapter.capabilityRank
        )
    }

    public func availability() async -> AIProviderAvailability {
        guard await credentials.credential(for: adapter.providerID) != nil else {
            return .unavailable(reason: "No API credential configured for \(adapter.displayName).")
        }
        // Reachability is not probed here: an availability check runs before
        // every turn and must stay cheap. A failed request surfaces as an error.
        return .available
    }

    public func availableModels() async throws -> [AIModel] {
        try await adapter.availableModels()
    }

    public func respond(to request: AIRequest) async throws -> AIResponse {
        guard let credential = await credentials.credential(for: adapter.providerID) else {
            throw AIProviderError.missingCredentials(adapter.displayName)
        }

        let httpRequest = try adapter.makeRequest(from: request, credential: credential)
        let httpResponse: HTTPResponse
        do {
            httpResponse = try await transport.send(httpRequest)
        } catch {
            throw AIProviderError.transport(String(describing: error))
        }

        guard httpResponse.isSuccess else {
            let body = String(data: httpResponse.body, encoding: .utf8) ?? "<binary>"
            throw AIProviderError.invalidResponse("HTTP \(httpResponse.statusCode): \(body)")
        }

        return try adapter.parse(httpResponse, for: request)
    }
}
