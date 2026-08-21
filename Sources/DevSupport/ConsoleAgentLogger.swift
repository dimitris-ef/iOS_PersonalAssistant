import AssistantCore
import AssistantDomain
import Foundation

/// Prints what the agent loop did, for a developer watching a console.
///
/// ## Why it is here and not in `AssistantCore`
///
/// Because it must be a deliberate choice to switch on. This lives in the
/// development target beside the scripted provider, so composing it into the
/// app is a visible line in `AppEnvironment` rather than a default someone
/// forgets about. The shipping composition uses `SilentAgentLogger`, and a
/// personal assistant that left a trail of its user's requests on the device
/// console would be a privacy failure whatever it said in the docs.
///
/// ## What it can print
///
/// Round numbers, provider ids, tool **names**, statuses, failure categories and
/// counts. That is the whole of ``AgentRoundRecord``, and the type is shaped so
/// there is nothing else available to print: no arguments, no prompt, no reply,
/// no memory, no reasoning. A line reads
///
/// ```
/// [agent 9F3A…] round 2 via remote.openai-compatible
///               proposed: createTask, scheduleNotification
///               results: succeeded, failed(permissionDenied)
/// ```
///
/// which is enough to debug a loop and not enough to learn anything about the
/// person using it.
public struct ConsoleAgentLogger: AgentLogger {
    private let prefix: String

    public init(prefix: String = "agent") {
        self.prefix = prefix
    }

    public func record(turn: UUID, round: AgentRoundRecord) {
        var line = "[\(prefix) \(short(turn))] round \(round.round) via \(round.providerID)"
        line += "\n  proposed: \(round.proposedTools.joined(separator: ", "))"
        if !round.statuses.isEmpty {
            line += "\n  results: \(round.statuses.map(\.rawValue).joined(separator: ", "))"
        }
        if !round.failures.isEmpty {
            line += "\n  failures: \(round.failures.map(\.rawValue).joined(separator: ", "))"
        }
        if round.retries > 0 { line += "\n  retries: \(round.retries)" }
        if round.duplicatesDetected > 0 { line += "\n  duplicates: \(round.duplicatesDetected)" }
        if round.discardedCalls > 0 { line += "\n  over budget, dropped: \(round.discardedCalls)" }
        print(line)
    }

    public func finish(turn: UUID, diagnostics: AgentDiagnostics) {
        print(
            "[\(prefix) \(short(turn))] finished \(diagnostics.status.rawValue)"
                + " after \(diagnostics.roundCount) round(s): \(diagnostics.stopReason.rawValue)"
        )
    }

    /// Enough of the turn id to correlate lines, not enough to be an identifier
    /// worth keeping.
    private func short(_ turn: UUID) -> String {
        String(turn.uuidString.prefix(8))
    }
}
