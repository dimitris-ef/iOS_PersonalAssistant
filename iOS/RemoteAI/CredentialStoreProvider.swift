import AIProviderRemote
import AssistantDomain
import AssistantPersistence
import Foundation

/// Bridges the app's secure store to the narrow interface providers use.
///
/// `AIProviderRemote` deliberately depends on `AssistantAI` and nothing else,
/// so it cannot reach persistence. The composition root joins the two here,
/// which is the only place that knows both exist.
struct CredentialStoreProvider: CredentialProvider {
    let store: any CredentialStore

    func credential(for providerID: AIProviderIdentifier) async -> String? {
        do {
            let value = try await store.credential(for: .remoteAIAPIKey(providerID: providerID))
            return value?.isEmpty == true ? nil : value
        } catch {
            // A Keychain failure is not a reason to crash a turn; the provider
            // treats a missing credential as "needs configuring".
            return nil
        }
    }
}
