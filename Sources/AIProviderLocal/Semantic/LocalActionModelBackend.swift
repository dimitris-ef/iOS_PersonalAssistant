import AssistantAI
import AssistantDomain
import Foundation

/// The action model, until there is a real one.
///
/// ## What this is and is not
///
/// Section 10. Part 1 is the architecture, not the model: there is no tiny
/// Metis Action Model yet, no training, no dataset. So the backend is the
/// semantic-action pipeline that already works — the user's downloaded local
/// model, prompted with the six intents and nothing else — wearing the new
/// interface.
///
/// It is an adapter and only an adapter. It holds no runtime, loads nothing,
/// and duplicates no inference: every call goes straight to
/// ``LocalModelProvider/generateSemanticAction(request:)``, which is the same
/// object, the same llama.cpp context and the same parser the chat path uses.
///
/// ## Why the adapter is worth having anyway
///
/// Two things become true the moment it exists, and neither depends on the
/// final model:
///
///  - The action path stops going through `AIProvider`, so what the *user*
///    picked to chat with no longer decides whether the phone can be operated.
///  - Replacing this with a purpose-trained model is a change to one
///    composition line, because everything above it is written against
///    `ActionModelProvider` and `LocalSemanticAction`.
public struct CurrentLocalSemanticActionBackend: ActionModelProvider {

    /// Names what it actually is, so a diagnostic line from a build running the
    /// temporary backend cannot be mistaken for one running the real model.
    public let id = "metis.action.local-semantic"

    private let provider: LocalModelProvider

    public init(provider: LocalModelProvider) {
        self.provider = provider
    }

    public func availability() async -> ActionModelAvailability {
        switch await provider.availability() {
        case .available:
            return .available
        case .configurationRequired(let reason),
             .temporarilyUnavailable(let reason),
             .unsupported(let reason):
            return .unavailable(reason: reason)
        }
    }

    public func generateSemanticAction(
        request: ActionModelRequest
    ) async throws -> LocalSemanticActionResult {
        try await provider.generateSemanticAction(request: request)
    }
}
