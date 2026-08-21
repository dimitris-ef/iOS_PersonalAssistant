import AssistantAI
import AssistantDomain
import AssistantTools
import Foundation

/// The ceilings on one assistant turn.
///
/// All of them exist for the same reason: the thing driving the loop is a
/// language model, and a model that malfunctions does not stop politely. It
/// proposes the same action forever, or four hundred actions at once, or keeps
/// asking for one more round. Every limit here turns one of those into a
/// bounded, explainable outcome.
///
/// Kept in one value so the bounds are visible together and can be tightened
/// for a test without reaching into the engine.
public struct AgentLimits: Hashable, Sendable {
    /// How many times the provider may be asked within one user message,
    /// counting the first.
    ///
    /// Six covers the compound case this milestone is about — create the event,
    /// see it worked, add the task, see that worked, write the reply — with
    /// room for one recovery. It is not a target: most turns finish in two.
    public var maximumRounds: Int
    /// How many tool calls one response may contain.
    public var maximumToolCallsPerRound: Int
    /// How many tool calls the whole turn may contain, across all rounds.
    ///
    /// Deliberately several times the per-round limit rather than equal to it:
    /// "three tasks, each with reminders" is a normal request, and a budget that
    /// cannot express it would be a limit on the product rather than on
    /// malfunction.
    public var maximumToolCallsPerTurn: Int
    /// How many times the application may repeat a failed call by itself.
    ///
    /// One. A transient failure usually clears on the next attempt; a second
    /// retry mostly buys latency. Which failures are eligible at all is
    /// ``ToolFailureCategory/isAutomaticallyRetryable``, and permission,
    /// validation and authorization failures never are.
    public var maximumToolRetries: Int
    /// How many times the same action may be proposed before the turn is
    /// treated as stuck and ended.
    public var repeatedProposalLimit: Int

    public init(
        maximumRounds: Int = 6,
        maximumToolCallsPerRound: Int = 8,
        maximumToolCallsPerTurn: Int = 24,
        maximumToolRetries: Int = 1,
        repeatedProposalLimit: Int = 3
    ) {
        self.maximumRounds = max(1, maximumRounds)
        self.maximumToolCallsPerRound = max(1, maximumToolCallsPerRound)
        self.maximumToolCallsPerTurn = max(1, maximumToolCallsPerTurn)
        self.maximumToolRetries = max(0, maximumToolRetries)
        self.repeatedProposalLimit = max(2, repeatedProposalLimit)
    }

    public static let `default` = AgentLimits()
}

/// What one turn amounted to.
///
/// The distinction that matters most is `success` from `partialSuccess`. A
/// compound request where the calendar was refused and the task was created is
/// not a failure and it is not a success, and an application that only had those
/// two words for it would have to lie in one direction or the other.
public enum AgentTurnStatus: String, Hashable, Codable, Sendable {
    case success
    case partialSuccess
    case requiresClarification
    case failed
    case cancelled
}

/// Why the loop stopped. Operational detail, not something the user is shown.
public enum AgentStopReason: String, Hashable, Codable, Sendable {
    /// The model answered without asking for anything more. The normal ending.
    case modelFinished
    /// The provider cannot be shown tool results, so it got its one round.
    case continuationUnsupported
    /// The round ceiling was reached while the model still wanted to act.
    case agentRoundLimitExceeded
    /// The per-turn tool budget ran out.
    case toolBudgetExhausted
    /// The model kept proposing an action that had already been done.
    case repeatedProposals
    /// The provider failed while being asked to continue.
    case providerFailed
    /// The model asked the user a question.
    case clarificationRequested
    case cancelled
}

/// A question the assistant needs answered before it acts.
public struct ClarificationRequest: Hashable, Sendable {
    public var question: String
    public var options: [String]

    public init(question: String, options: [String] = []) {
        self.question = question
        self.options = options
    }

    /// The question as the user reads it.
    public var prompt: String {
        guard !options.isEmpty else { return question }
        return "\(question)\n" + options.map { "• \($0)" }.joined(separator: "\n")
    }
}

/// What happened in one round, in terms safe to log.
///
/// Names of tools and statuses of results — never arguments, never the reply,
/// never anything the person told the assistant. A log line from here can say
/// "round 2, createTask, failed(permissionDenied)" and nothing about whose
/// dentist it was.
public struct AgentRoundRecord: Hashable, Sendable {
    public var round: Int
    public var providerID: AIProviderIdentifier
    public var proposedTools: [String]
    public var executedTools: [String]
    public var statuses: [AIToolStatus]
    public var failures: [ToolFailureCategory]
    public var retries: Int
    public var duplicatesDetected: Int
    /// Calls dropped because the turn's tool budget was spent.
    public var discardedCalls: Int
}

/// The turn's own account of itself.
///
/// Exists to make the loop debuggable without keeping a transcript. Note what
/// it does not contain: no prompts, no arguments, no model reasoning. Section
/// 55's rule is not an aspiration here — there is nowhere in this type to put
/// chain-of-thought even if something tried to.
public struct AgentDiagnostics: Hashable, Sendable {
    public var turnID: UUID
    public var rounds: [AgentRoundRecord]
    public var stopReason: AgentStopReason
    public var status: AgentTurnStatus

    public init(
        turnID: UUID = UUID(),
        rounds: [AgentRoundRecord] = [],
        stopReason: AgentStopReason = .modelFinished,
        status: AgentTurnStatus = .success
    ) {
        self.turnID = turnID
        self.rounds = rounds
        self.stopReason = stopReason
        self.status = status
    }

    public var roundCount: Int { rounds.count }
    public var retryCount: Int { rounds.reduce(0) { $0 + $1.retries } }
    public var duplicateCount: Int { rounds.reduce(0) { $0 + $1.duplicatesDetected } }
}

/// Somewhere for round-level diagnostics to go.
///
/// A protocol rather than a call to `print`, because what is safe to write down
/// differs between a developer's console and a shipped app, and that decision
/// belongs to whoever composes the application. The default does nothing, which
/// is the right production behaviour: an assistant for personal life should not
/// leave a record of what its user asked for on the console of a device.
public protocol AgentLogger: Sendable {
    func record(turn: UUID, round: AgentRoundRecord)
    func finish(turn: UUID, diagnostics: AgentDiagnostics)
}

extension AgentLogger {
    public func record(turn: UUID, round: AgentRoundRecord) {}
    public func finish(turn: UUID, diagnostics: AgentDiagnostics) {}
}

/// The production logger: silence.
public struct SilentAgentLogger: AgentLogger {
    public init() {}
}
