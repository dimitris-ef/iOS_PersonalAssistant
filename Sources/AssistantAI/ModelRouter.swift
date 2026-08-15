import AssistantDomain
import Foundation

public enum ModelRoutingError: Error, Hashable, Sendable {
    case noProviderAvailable
    case explicitProviderUnavailable(AIProviderIdentifier, reason: String)
    case explicitProviderNotRegistered(AIProviderIdentifier)
}

/// Picks the provider for a turn.
///
/// Routing is a policy decision made from settings, so the engine never names a
/// provider directly and adding a new provider means registering it, not
/// editing assistant logic.
public struct ModelRouter: Sendable {
    public init() {}

    public func selectProvider(
        from registry: AIProviderRegistry,
        settings: AssistantSettings
    ) async throws -> any AIProvider {
        if let preferred = settings.preferredProviderID {
            guard let provider = await registry.provider(for: preferred) else {
                if settings.routingPolicy == .explicit {
                    throw ModelRoutingError.explicitProviderNotRegistered(preferred)
                }
                return try await fallback(from: registry, settings: settings)
            }

            // Routing only cares whether the provider can answer. *Why* it
            // cannot is carried through to the error so the caller can say
            // something useful — "needs an API key" rather than "unavailable".
            let availability = await provider.availability()
            guard availability.isAvailable else {
                if settings.routingPolicy == .explicit {
                    throw ModelRoutingError.explicitProviderUnavailable(
                        preferred,
                        reason: availability.reason ?? "The provider is unavailable."
                    )
                }
                return try await fallback(from: registry, settings: settings)
            }
            return provider
        }

        if settings.routingPolicy == .explicit {
            throw ModelRoutingError.noProviderAvailable
        }
        return try await fallback(from: registry, settings: settings)
    }

    private func fallback(
        from registry: AIProviderRegistry,
        settings: AssistantSettings
    ) async throws -> any AIProvider {
        let candidates = await registry.availableProviders()
        guard !candidates.isEmpty else { throw ModelRoutingError.noProviderAvailable }

        switch settings.routingPolicy {
        case .preferOnDevice, .explicit:
            let ranked = candidates.sorted { lhs, rhs in
                let lhsLocal = lhs.metadata.requiresNetwork ? 0 : 1
                let rhsLocal = rhs.metadata.requiresNetwork ? 0 : 1
                if lhsLocal != rhsLocal { return lhsLocal > rhsLocal }
                return lhs.metadata.capabilityRank > rhs.metadata.capabilityRank
            }
            // `ranked` is non-empty because `candidates` is.
            return ranked[0]

        case .preferMostCapable:
            let ranked = candidates.sorted { $0.metadata.capabilityRank > $1.metadata.capabilityRank }
            return ranked[0]
        }
    }
}
