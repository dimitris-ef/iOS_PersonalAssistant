import Foundation

/// Why a tool did not do what was asked.
///
/// This exists because "Tool failed." is useless to everyone downstream. The
/// model cannot tell a denied permission (explain it, carry on with the rest)
/// from a dropped network call (worth one more try) from an invalid argument
/// (fix the argument, do not repeat it), and neither can the retry policy. One
/// vocabulary, in the domain layer, so the executor, the agent loop, the retry
/// policy and the model all mean the same thing by the same word.
///
/// It lives beside ``ToolKind`` and not in the AI or platform layer for the
/// same reason `ToolKind` does: it is product vocabulary. The platform layer
/// throws `PlatformError`, persistence throws `RepositoryError`, and the
/// executor translates both into this.
public enum ToolFailureCategory: String, Hashable, Codable, Sendable, CaseIterable {
    /// The arguments did not survive decoding or cross-field validation.
    case validationFailure
    /// The user's own settings forbid this tool.
    case authorizationDenied
    /// Allowed, but only after the user approves it.
    case confirmationRequired
    /// The operating system has not granted the capability.
    case permissionDenied
    /// This build cannot do it at all.
    case unsupported
    /// The thing being acted on does not exist.
    case notFound
    /// A service failed in a way that may not repeat.
    case temporaryFailure
    /// The network was the problem.
    case networkFailure
    /// The model provider failed — not the tool.
    case providerFailure
    /// The store refused the write.
    case persistenceFailure
    /// Already done. Not a failure of intent, only of novelty.
    case duplicate
    /// Something this action needed was produced by an action that failed.
    case dependencyFailed
    /// The turn was cancelled before this action ran.
    case cancelled

    /// What, if anything, could make this work.
    public enum Recovery: String, Hashable, Codable, Sendable {
        /// Worth trying something else — possibly the same thing again.
        case recoverable
        /// Nothing automatic will help; the person has to answer something.
        case requiresUserInput
        /// This action is finished. It will not succeed in this turn.
        case terminal
    }

    public var recovery: Recovery {
        switch self {
        case .temporaryFailure, .networkFailure, .providerFailure,
             .persistenceFailure, .notFound, .duplicate:
            return .recoverable
        case .confirmationRequired:
            return .requiresUserInput
        case .validationFailure, .authorizationDenied, .permissionDenied,
             .unsupported, .dependencyFailed, .cancelled:
            return .terminal
        }
    }

    /// Whether the **application** may repeat the call by itself.
    ///
    /// Deliberately narrower than `recovery == .recoverable`. A missing task can
    /// be recovered from by doing something else; repeating the same lookup
    /// cannot help. Permission denials, validation failures and authorization
    /// denials are never retried automatically — retrying them produces the same
    /// answer, and in the permission case it would mean asking the operating
    /// system about a decision the user has already made.
    public var isAutomaticallyRetryable: Bool {
        switch self {
        case .temporaryFailure, .networkFailure:
            return true
        case .validationFailure, .authorizationDenied, .confirmationRequired,
             .permissionDenied, .unsupported, .notFound, .providerFailure,
             .persistenceFailure, .duplicate, .dependencyFailed, .cancelled:
            return false
        }
    }
}
