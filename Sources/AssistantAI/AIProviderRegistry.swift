import AssistantDomain
import Foundation

/// Holds the providers the app knows about.
///
/// An actor because providers are registered at launch and read from every
/// turn; nothing else about provider selection needs shared mutable state.
public actor AIProviderRegistry {
    private var providers: [AIProviderIdentifier: any AIProvider] = [:]
    private var registrationOrder: [AIProviderIdentifier] = []

    public init(providers: [any AIProvider] = []) {
        for provider in providers {
            self.providers[provider.metadata.id] = provider
            self.registrationOrder.append(provider.metadata.id)
        }
    }

    public func register(_ provider: any AIProvider) {
        let id = provider.metadata.id
        if providers[id] == nil {
            registrationOrder.append(id)
        }
        providers[id] = provider
    }

    public func unregister(_ id: AIProviderIdentifier) {
        providers.removeValue(forKey: id)
        registrationOrder.removeAll { $0 == id }
    }

    public func provider(for id: AIProviderIdentifier) -> (any AIProvider)? {
        providers[id]
    }

    public func allProviders() -> [any AIProvider] {
        registrationOrder.compactMap { providers[$0] }
    }

    public func allMetadata() -> [AIProviderMetadata] {
        allProviders().map { $0.metadata }
    }

    /// Providers reporting themselves ready, in registration order.
    public func availableProviders() async -> [any AIProvider] {
        var result: [any AIProvider] = []
        for provider in allProviders() {
            let availability = await provider.availability()
            if availability.isAvailable {
                result.append(provider)
            }
        }
        return result
    }
}
