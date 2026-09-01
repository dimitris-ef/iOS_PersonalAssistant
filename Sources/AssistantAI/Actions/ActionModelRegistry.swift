import AssistantDomain
import Foundation

/// The action backends this build knows about.
///
/// ## Why it is not `AIProviderRegistry`
///
/// Section 14. The two registries answer different questions and are chosen by
/// different people. `AIProviderRegistry` holds what the *user* picked to talk
/// to, from a Settings screen, and changing it is a preference. This holds what
/// the *app* uses to interpret phone actions, and the user does not choose it —
/// in Part 1 there is exactly one entry.
///
/// Sharing one registry would put them back together, which is the coupling
/// this whole part exists to remove: selecting a chat model would once again
/// change whether the phone could be operated.
public actor ActionModelRegistry {
    private var backends: [String: any ActionModelProvider] = [:]
    private var registrationOrder: [String] = []

    public init(backends: [any ActionModelProvider] = []) {
        for backend in backends {
            self.backends[backend.id] = backend
            self.registrationOrder.append(backend.id)
        }
    }

    public func register(_ backend: any ActionModelProvider) {
        if backends[backend.id] == nil { registrationOrder.append(backend.id) }
        backends[backend.id] = backend
    }

    public func unregister(_ id: String) {
        backends.removeValue(forKey: id)
        registrationOrder.removeAll { $0 == id }
    }

    public func backend(for id: String) -> (any ActionModelProvider)? { backends[id] }

    public func allBackends() -> [any ActionModelProvider] {
        registrationOrder.compactMap { backends[$0] }
    }

    /// The first backend that reports itself ready, in registration order.
    ///
    /// Returns the reason when nothing is ready, because "unavailable" with no
    /// reason is not something a user or a bug report can act on — and the
    /// reason is what the safe failure and the diagnostic line both need.
    public func selectBackend() async -> ActionBackendSelection {
        let all = allBackends()
        guard !all.isEmpty else {
            return .unavailable(reason: "No action model is configured.")
        }
        var firstReason: String?
        for backend in all {
            let availability = await backend.availability()
            if availability.isAvailable { return .selected(backend) }
            if firstReason == nil { firstReason = availability.reason }
        }
        return .unavailable(reason: firstReason ?? "The action model is unavailable.")
    }

    /// Whether any backend can be used right now.
    public func availability() async -> ActionModelAvailability {
        switch await selectBackend() {
        case .selected: return .available
        case .unavailable(let reason): return .unavailable(reason: reason)
        }
    }
}

/// The outcome of asking the registry for something to use.
public enum ActionBackendSelection: Sendable {
    case selected(any ActionModelProvider)
    case unavailable(reason: String)

    public var backend: (any ActionModelProvider)? {
        if case .selected(let backend) = self { return backend }
        return nil
    }
}
