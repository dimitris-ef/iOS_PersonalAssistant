import AIProviderRemote
import AssistantAI
import AssistantDomain
import Foundation

/// The cloud provider slot, with no vendor behind it.
///
/// `RemoteAIProvider` is vendor-neutral: everything specific to one API lives in
/// a `RemoteAPIAdapter`. No vendor has been chosen, so this adapter fills the
/// slot with identity and metadata only, and throws on any attempt to build or
/// parse a request.
///
/// It exists so the model selector can offer the cloud option honestly — the
/// provider reports itself unavailable (no credential is configured) rather
/// than the option being hidden or, worse, pretending to work.
///
/// TODO-XCODE: replace with a real adapter for whichever API is chosen, and
/// swap `EnvironmentCredentialProvider` for a Keychain-backed one.
struct UnconfiguredCloudAdapter: RemoteAPIAdapter {
    var providerID: AIProviderIdentifier { "remote.cloud-model" }
    var displayName: String { "Cloud Model" }
    var capabilityRank: Int { 100 }

    func availableModels() async throws -> [AIModel] {
        []
    }

    func makeRequest(from request: AIRequest, credential: String) throws -> HTTPRequest {
        throw AIProviderError.notImplemented(
            "No cloud API adapter has been written yet."
        )
    }

    func parse(_ response: HTTPResponse, for request: AIRequest) throws -> AIResponse {
        throw AIProviderError.notImplemented(
            "No cloud API adapter has been written yet."
        )
    }
}
