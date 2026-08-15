import AssistantDomain
import Foundation

public enum AIProviderKind: String, Hashable, Codable, Sendable, CaseIterable {
    /// Apple's on-device Foundation Models framework.
    case appleFoundationModels
    /// A model file the user downloaded and runs locally.
    case downloadedLocalModel
    /// A model reached over the network.
    case remoteAPI
    /// Deterministic stand-in used by the development harness and tests.
    case development
}

public struct AIModel: Hashable, Codable, Sendable, Identifiable {
    public var id: AIModelIdentifier
    public var displayName: String
    public var contextWindow: Int?
    public var supportsNativeToolCalling: Bool
    /// Runs without a network connection.
    public var isOnDevice: Bool

    public init(
        id: AIModelIdentifier,
        displayName: String,
        contextWindow: Int? = nil,
        supportsNativeToolCalling: Bool,
        isOnDevice: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.contextWindow = contextWindow
        self.supportsNativeToolCalling = supportsNativeToolCalling
        self.isOnDevice = isOnDevice
    }
}

public struct AIProviderMetadata: Hashable, Codable, Sendable, Identifiable {
    public var id: AIProviderIdentifier
    public var displayName: String
    public var kind: AIProviderKind
    public var requiresNetwork: Bool
    public var requiresCredentials: Bool
    /// Relative capability hint used by `.preferMostCapable` routing.
    public var capabilityRank: Int
    /// Whether the provider can be sent tool results and asked to continue.
    ///
    /// Providers that cannot are given exactly one round, so the engine never
    /// re-asks a provider that would simply repeat its previous tool calls.
    public var supportsToolResultContinuation: Bool

    public init(
        id: AIProviderIdentifier,
        displayName: String,
        kind: AIProviderKind,
        requiresNetwork: Bool,
        requiresCredentials: Bool,
        capabilityRank: Int,
        supportsToolResultContinuation: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.requiresNetwork = requiresNetwork
        self.requiresCredentials = requiresCredentials
        self.capabilityRank = capabilityRank
        self.supportsToolResultContinuation = supportsToolResultContinuation
    }
}

public enum AIProviderError: Error, Hashable, Sendable {
    /// The provider exists but its implementation is not written yet.
    case notImplemented(String)
    case unavailable(String)
    case missingCredentials(String)
    case modelNotFound(AIModelIdentifier)
    case transport(String)
    case invalidResponse(String)
    case cancelled
}

/// The single seam between the assistant and whatever is doing the reasoning.
///
/// Everything the user cares about — conversations, memory, tasks, routines,
/// settings, the tool catalogue — lives outside this protocol, which is why a
/// provider can be swapped at runtime without losing anything.
public protocol AIProvider: Sendable {
    var metadata: AIProviderMetadata { get }

    /// Cheap enough to call before every turn; providers should not do heavy
    /// work here (no model loading, no network round-trips beyond a cached check).
    func availability() async -> AIProviderAvailability

    func availableModels() async throws -> [AIModel]

    func respond(to request: AIRequest) async throws -> AIResponse
}

extension AIProvider {
    public var id: AIProviderIdentifier { metadata.id }
}
