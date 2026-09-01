import AssistantDomain
import Foundation

/// The action half of the assistant, assembled once by the composition root.
///
/// ## Why one value rather than four engine parameters
///
/// The four pieces are only ever useful together: a router with no backend
/// routes into nothing, and a backend with no resolver produces a semantic
/// action nobody turns into a call. Passing them as one value means a build
/// either has an action system or does not, and `AssistantEngine` has one
/// `nil` check rather than four.
///
/// A build with no action system behaves exactly as the app did before this
/// part: every message goes to the selected chat provider. That is what keeps
/// the development harness and every existing test working unchanged.
public struct MetisActionSystem: Sendable {
    public var router: any MetisActionRouting
    public var registry: ActionModelRegistry
    public var resolver: any SemanticActionResolving
    public var diagnostics: any ActionSystemDiagnosticSink

    public init(
        router: any MetisActionRouting = MetisActionRouter(),
        registry: ActionModelRegistry,
        resolver: any SemanticActionResolving,
        diagnostics: any ActionSystemDiagnosticSink = NullActionSystemDiagnosticSink()
    ) {
        self.router = router
        self.registry = registry
        self.resolver = resolver
        self.diagnostics = diagnostics
    }

    /// What the user is told when a request was clearly an action and the
    /// action system cannot run.
    ///
    /// Section 15 and 16. Concise, and honest about which part is missing —
    /// "I can't" without a reason is a dead end, and the alternative the code
    /// must never take is handing the request to the chat model, which would
    /// answer it as though something had happened.
    public static let unavailableMessage =
        "I can't perform phone actions right now because the action system is unavailable."
}
