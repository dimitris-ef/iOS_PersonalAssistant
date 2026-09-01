import AssistantDomain
import Foundation

/// One privacy-safe fact about how a message was handled.
///
/// ## What is not in here
///
/// Sections 22, 24 and 25 all say the same thing from different angles, and the
/// type enforces it rather than asking callers to remember: there is no case
/// carrying the user's message, the generated protocol output, a prompt, or a
/// resolved identifier. Every payload is a symbol, an identifier the app chose
/// itself, or a category name.
///
/// The reasons are structured for the same reason: `reason: String` invites an
/// interpolated error, and an interpolated error is how a user's sentence ends
/// up in a log file.
public enum ActionSystemDiagnosticEvent: Hashable, Sendable {
    /// Which way a message went, and on what evidence.
    case routerDecision(decision: String, category: String, evidence: String?)
    /// Which backend was chosen, and whether it can be used.
    case actionBackend(backendID: String, availability: String, reason: String?)
    /// Semantic interpretation is starting.
    case semanticProcessingStarted(backendID: String, category: String)
    /// It did not produce a usable action.
    case actionBackendFailure(backendID: String, reason: String)

    /// The event name written to the log.
    public var name: String {
        switch self {
        case .routerDecision: return "ROUTER_DECISION"
        case .actionBackend: return "ACTION_BACKEND"
        case .semanticProcessingStarted: return "SEMANTIC_ACTION_PROCESSING_STARTED"
        case .actionBackendFailure: return "ACTION_BACKEND_FAILURE"
        }
    }
}

/// Where those facts go.
///
/// A protocol in `AssistantAI` rather than a dependency on the local
/// diagnostics logger, which lives in the local-model target: the action
/// system must not depend on any one provider implementation, and the app
/// bridges this to whichever logger it has.
public protocol ActionSystemDiagnosticSink: Sendable {
    func record(_ event: ActionSystemDiagnosticEvent)
}

/// The default. Records nothing, which is the right behaviour for a build with
/// no diagnostics wired rather than a reason to make the sink optional
/// everywhere.
public struct NullActionSystemDiagnosticSink: ActionSystemDiagnosticSink {
    public init() {}
    public func record(_ event: ActionSystemDiagnosticEvent) {}
}
