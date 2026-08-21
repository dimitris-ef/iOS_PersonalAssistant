import AssistantDomain
import Foundation

/// What became of one tool call, in the vocabulary every provider shares.
public enum AIToolStatus: String, Hashable, Codable, Sendable {
    /// It really happened.
    case succeeded
    /// A mock recorded it. The named platform did nothing.
    case simulated
    /// Prepared, waiting for the user to approve it.
    case awaitingConfirmation
    /// Not run: an action it depended on failed, or the turn was cancelled.
    case skipped
    case failed

    /// Whether the intent was carried out — honestly including the simulated
    /// case, which *did* record the action even though no phone changed.
    public var didAct: Bool {
        self == .succeeded || self == .simulated
    }
}

/// The result of one tool call as the model is shown it.
///
/// This is the provider-neutral half of the contract in ``AIToolCall``: the
/// model proposes a call, the application decides and executes, and this comes
/// back. It carries the outcome, a small amount of normalized result data, and
/// — when something went wrong — which *kind* of wrong, so the model can pick a
/// different action rather than guessing from prose.
///
/// Three things it deliberately is not:
///
/// - It is not a serialized platform object. A calendar result carries an id, a
///   title and a start, not an `EKEvent`. Continuation context grows with every
///   round, and the model needs the identifier, not the object graph.
/// - It is not persisted. ``ToolResult`` is the record the conversation keeps;
///   this is the turn-scoped view handed to a provider, and duplicating it in
///   the store would mean two descriptions of one event that can disagree.
/// - It is not provider-shaped. `RemoteAIProvider` renders it as an OpenAI tool
///   message and `AppleFoundationModelsProvider` as a transcript tool output;
///   neither shape reaches the engine.
public struct AIToolResult: Hashable, Codable, Sendable {
    /// The call this answers. Stable for the whole turn.
    public var callID: ToolCallID
    /// The tool's wire name, so a result is readable without its call.
    public var toolName: String
    public var status: AIToolStatus
    /// Small, normalized facts about what was produced: identifiers, titles,
    /// times. Rendered in sorted key order, so the same result always reads the
    /// same way.
    public var payload: [String: String]
    /// Present whenever `status` is `.failed` or `.skipped`.
    public var failure: ToolFailureCategory?
    /// One human-readable line. Also what the user's action card says.
    public var message: String
    /// True when this result was reused rather than executed — the same call, or
    /// the same arguments, having already run earlier in this turn.
    public var wasAlreadyPerformed: Bool

    public init(
        callID: ToolCallID,
        toolName: String,
        status: AIToolStatus,
        payload: [String: String] = [:],
        failure: ToolFailureCategory? = nil,
        message: String,
        wasAlreadyPerformed: Bool = false
    ) {
        self.callID = callID
        self.toolName = toolName
        self.status = status
        self.payload = payload
        self.failure = failure
        self.message = message
        self.wasAlreadyPerformed = wasAlreadyPerformed
    }

    /// The text a provider is given for this result.
    ///
    /// Deterministic and compact. Every branch states plainly what happened,
    /// because this string is the only thing standing between a failed action
    /// and a model that tells the user it succeeded.
    public var renderedForModel: String {
        var line: String

        switch status {
        case .succeeded:
            line = "succeeded"
        case .simulated:
            line = "recorded by the app only — simulated, nothing was scheduled on the device"
        case .awaitingConfirmation:
            line = "waiting for the user to approve it — not done yet"
        case .skipped:
            line = "skipped"
        case .failed:
            line = "failed"
        }

        if let failure {
            line += " (\(failure.rawValue))"
        }

        if wasAlreadyPerformed {
            line += " — already performed earlier in this turn; this is the original result, not a second execution"
        }

        if !message.isEmpty {
            line += ": \(message)"
        }

        if !payload.isEmpty {
            let facts = payload
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ", ")
            line += " [\(facts)]"
        }

        return "\(toolName) \(line)"
    }
}
