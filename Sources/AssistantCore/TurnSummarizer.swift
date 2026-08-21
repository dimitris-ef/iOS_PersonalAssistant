import AssistantAI
import AssistantDomain
import Foundation

/// Writes the closing line when the model cannot.
///
/// ## When it is used
///
/// Three cases, all of them ones where actions have already happened:
///
/// - the provider failed while being asked to summarise (§58),
/// - the round limit was reached with the model still proposing (§57),
/// - the model returned no text at all.
///
/// In every one of them the alternative would be to leave the user with either
/// silence or the model's last remark — and its last remark was written *before*
/// the results existed, so "I've added that for you" may be describing an action
/// that then failed. This is the point of the whole milestone stated in one
/// class: what the user is told comes from what happened.
///
/// ## Why it does not ask a model
///
/// Because the model is the thing that just failed. Spending another request,
/// another second and another chance of failure to phrase two sentences would
/// make the failure path the most expensive path in the app. This is string
/// assembly over a list of results, it always succeeds, and it always agrees
/// with the action cards below it because both read the same list.
public struct TurnSummarizer: Sendable {
    public init() {}

    /// - Parameters:
    ///   - results: Every tool result of the turn, in execution order.
    ///   - stopReason: Why the loop ended, which decides whether the summary
    ///     needs to admit that the turn did not finish cleanly.
    public func summary(for results: [AIToolResult], stopReason: AgentStopReason) -> String {
        let done = results.filter { $0.status.didAct && !$0.wasAlreadyPerformed }
        let pending = results.filter { $0.status == .awaitingConfirmation }
        // Validation rejections are left out. A call that failed to decode never
        // became an action and has no card under the reply; naming it here would
        // tell the user about a mistake in the model's tool arguments, which is
        // ours to handle and not theirs to read.
        let problems = results.filter {
            ($0.status == .failed || $0.status == .skipped) && $0.failure != .validationFailure
        }

        var sentences: [String] = []

        switch stopReason {
        case .providerFailed:
            if done.isEmpty {
                sentences.append("I couldn't get a reply from the model.")
            } else if problems.isEmpty {
                sentences.append("I finished what you asked for, but couldn't write the reply myself.")
            } else {
                // Not "I finished what you asked for" — something did not
                // happen, and it is named in the sentences below.
                sentences.append("I couldn't write the reply myself, so here is what happened.")
            }
        case .agentRoundLimitExceeded, .repeatedProposals:
            sentences.append("I couldn't finish that request cleanly, so I stopped.")
        case .toolBudgetExhausted:
            sentences.append("That needed more steps than I'm allowed to take in one go, so I stopped.")
        case .cancelled:
            sentences.append("Stopped.")
        case .modelFinished, .continuationUnsupported, .clarificationRequested:
            break
        }

        if !done.isEmpty {
            sentences.append("\(count(done.count, "action")) completed: \(list(done)).")
        }

        if !pending.isEmpty {
            sentences.append("\(count(pending.count, "action")) waiting for your approval: \(list(pending)).")
        }

        for problem in problems {
            // Named one by one rather than counted. "1 action failed" tells
            // someone that something is wrong without telling them what, which
            // leaves them to work it out — precisely the load this app exists
            // to carry.
            sentences.append("\(problem.toolName) did not happen: \(reason(for: problem)).")
        }

        if sentences.isEmpty {
            // Nothing ran and nothing failed: the model asked for no tools and
            // wrote no text.
            return "I didn't do anything for that one."
        }

        return sentences.joined(separator: " ")
    }

    private func list(_ results: [AIToolResult]) -> String {
        results.map(\.toolName).joined(separator: ", ")
    }

    private func count(_ value: Int, _ noun: String) -> String {
        "\(value) \(noun)\(value == 1 ? "" : "s")"
    }

    /// The sentence the executor wrote, if it wrote one, and otherwise the
    /// category. Never a bare "failed".
    private func reason(for result: AIToolResult) -> String {
        if !result.message.isEmpty { return result.message }
        guard let failure = result.failure else { return "no reason was recorded" }
        switch failure {
        case .permissionDenied:
            return "the app does not have permission for it"
        case .authorizationDenied:
            return "your settings do not allow it"
        case .confirmationRequired:
            return "it needs your approval first"
        case .validationFailure:
            return "the details were not usable"
        case .unsupported:
            return "this device cannot do it"
        case .notFound:
            return "I could not find what it referred to"
        case .dependencyFailed:
            return "something it depended on did not happen"
        case .duplicate:
            return "it had already been done"
        case .cancelled:
            return "it was stopped before it ran"
        case .temporaryFailure, .networkFailure, .providerFailure, .persistenceFailure:
            return "it failed and may work if you try again"
        }
    }
}
