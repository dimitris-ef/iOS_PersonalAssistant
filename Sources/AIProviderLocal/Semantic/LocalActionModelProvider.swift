import AssistantAI
import AssistantDomain
import Foundation

/// The dedicated action model, as an `ActionModelProvider`.
///
/// ## What Part 3 changes
///
/// Part 1's backend was the chat model wearing the action interface — the same
/// `LocalModelProvider`, the same loaded weights, the same lifecycle. It proved
/// the architecture and left one thing unfinished: the action path still could
/// not run unless the user happened to have selected a suitable *chat* model.
///
/// This one has its own selection, its own runtime instance, its own context
/// policy and its own load state. Which model the user talks to is now
/// genuinely unrelated to whether the phone can be operated:
///
/// | Chat | Action |
/// | --- | --- |
/// | Apple Foundation Models | a small local GGUF |
/// | a remote provider | a small local GGUF |
/// | a 3B local model | a 0.5B local model |
///
/// ## What it is not
///
/// It is a thin adapter. Every decision — which model, whether to load, what
/// context, what grammar, how many repairs — belongs to ``ActionModelHost`` and
/// ``SemanticActionGenerator``. This type exists to satisfy the boundary Part 1
/// defined, and it holds nothing but a reference to the host.
///
/// Section 71: it cannot execute anything. It produces a `LocalSemanticAction`,
/// and `AIProviderLocal` cannot import `PlatformServices` at all — EventKit,
/// notifications and every repository are outside its dependency graph, so
/// "the action model does not touch the calendar" is a fact about the package
/// rather than a promise about the code.
public struct LocalActionModelProvider: ActionModelProvider {

    /// Names the role, not the model. The *model* is a user selection that can
    /// change; this identifier is what the diagnostics correlate on.
    public let id = "metis.action.local-gguf"

    private let host: ActionModelHost

    public init(host: ActionModelHost) {
        self.host = host
    }

    public func availability() async -> ActionModelAvailability {
        await host.availability()
    }

    /// The action model's own status, for the settings screen.
    public func status() async -> ActionModelStatus {
        await host.status()
    }

    public func generateSemanticAction(
        request: ActionModelRequest,
        constraints: ActionGenerationConstraints
    ) async throws -> LocalSemanticActionResult {
        try await host.generate(request: request, constraints: constraints)
    }
}
