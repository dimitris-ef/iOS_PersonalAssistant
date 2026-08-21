import AssistantAI
import AssistantDomain
import AssistantTools
import Foundation

/// Where one tool call has got to.
public enum ToolExecutionStatus: String, Hashable, Codable, Sendable {
    /// Claimed, not started.
    case pending
    /// Running now. A second claim on the same identity must not start it again.
    case executing
    case succeeded
    case failed
    case cancelled

    /// Whether anything more can happen to it.
    var isSettled: Bool {
        switch self {
        case .pending, .executing: return false
        case .succeeded, .failed, .cancelled: return true
        }
    }
}

/// One row of the ledger.
public struct ToolExecutionEntry: Hashable, Sendable {
    public var callID: ToolCallID
    public var toolName: String
    public var fingerprint: ToolFingerprint
    public var status: ToolExecutionStatus
    /// The result, once there is one. Reused verbatim for a duplicate.
    public var result: AIToolResult?
    /// How many times the application has executed this — not how many times
    /// the model proposed it.
    public var attempts: Int
    /// How many times the model has asked for it. The signal loop detection
    /// reads: three proposals of an action that already succeeded is a model
    /// going round in circles, not a user who wants three of something.
    public var proposals: Int
    public var updatedAt: Date

    var scope: String
}

/// The record of what has actually been executed, and the thing that stops it
/// happening twice.
///
/// ## Why this has to exist
///
/// Every mechanism in a multi-round loop that makes it *robust* also makes it
/// capable of repeating itself. The provider continuation fails and is retried,
/// so the round is re-sent. The model is shown a successful result and proposes
/// the same call again. A confirmation callback arrives twice. In every one of
/// those, without a ledger, the user ends up with two dentist appointments in
/// their calendar — and unlike a duplicated read, that one is theirs to clean
/// up by hand.
///
/// So: nothing executes without claiming an identity here first, and a claim on
/// an identity that has already run returns what it produced rather than
/// letting it run again.
///
/// ## Two identities, checked in order
///
/// 1. **The call id.** Exact, and what a well-behaved provider gives us.
/// 2. **The fingerprint.** Content-based, and what catches a call the provider
///    re-issued with a fresh id during a retry — see ``ToolFingerprint``.
///
/// ## What it is not
///
/// It is not persisted. Its whole purpose is safety *within* a turn, and a turn
/// does not outlive the process — a relaunch means a new conversation turn,
/// where a repeated action is a legitimate new request rather than a duplicate.
/// Persisting it would also mean storing the model's proposals, which is
/// operational detail the transcript has no business carrying.
public actor ToolExecutionLedger {
    /// The answer to "may I run this?".
    public enum Claim: Sendable {
        /// Nobody has run it. The caller now owns it and must report back.
        case granted
        /// Already running, claimed by someone else. Do not start a second one.
        case inFlight(ToolExecutionEntry)
        /// Already finished. Use this result; do not execute.
        case settled(ToolExecutionEntry)
    }

    private var entries: [ToolCallID: ToolExecutionEntry] = [:]
    /// Fingerprint to the call that first claimed it.
    private var byFingerprint: [ToolFingerprint: ToolCallID] = [:]
    /// Scopes in the order they were first seen, newest last.
    private var scopes: [String] = []

    /// How many turns' worth of history to keep.
    ///
    /// Bounded because this actor lives as long as the engine does, and an
    /// unbounded dictionary of every action of every conversation would be a
    /// leak that grows for exactly as long as someone uses the app.
    ///
    /// Four rather than two, because turns are not the only scope here: a
    /// structured request through `AssistantEngine.perform` brings its own
    /// idempotency key, and a Shortcut running while a chat turn is in flight
    /// would otherwise be able to evict that turn's own entries and undo its
    /// duplicate protection half way through.
    private let retainedScopes: Int

    public init(retainedScopes: Int = 4) {
        self.retainedScopes = max(1, retainedScopes)
    }

    /// Registers that the model asked for something, and says whether it may run.
    ///
    /// Claiming and asking are the same operation on purpose: a check followed
    /// by a separate "now mark it running" has a gap between them, and the gap
    /// is where two executions of one action come from.
    @discardableResult
    public func claim(
        callID: ToolCallID,
        toolName: String,
        fingerprint: ToolFingerprint,
        scope: String,
        now: Date
    ) -> Claim {
        note(scope: scope)

        // Identity 1: the provider's own call id.
        if var existing = entries[callID] {
            existing.proposals += 1
            existing.updatedAt = now
            entries[callID] = existing
            return existing.status.isSettled ? .settled(existing) : .inFlight(existing)
        }

        // Identity 2: the same arguments under a different id.
        if let owner = byFingerprint[fingerprint], var existing = entries[owner] {
            existing.proposals += 1
            existing.updatedAt = now
            entries[owner] = existing
            return existing.status.isSettled ? .settled(existing) : .inFlight(existing)
        }

        entries[callID] = ToolExecutionEntry(
            callID: callID,
            toolName: toolName,
            fingerprint: fingerprint,
            status: .executing,
            result: nil,
            attempts: 0,
            proposals: 1,
            updatedAt: now,
            scope: scope
        )
        byFingerprint[fingerprint] = callID
        return .granted
    }

    /// Records that an attempt is about to be made. Retries call this again.
    public func beginAttempt(callID: ToolCallID, now: Date) {
        guard var entry = entries[callID] else { return }
        entry.attempts += 1
        entry.status = .executing
        entry.updatedAt = now
        entries[callID] = entry
    }

    public func finish(
        callID: ToolCallID,
        status: ToolExecutionStatus,
        result: AIToolResult,
        now: Date
    ) {
        guard var entry = entries[callID] else { return }
        entry.status = status
        entry.result = result
        entry.updatedAt = now
        entries[callID] = entry
    }

    /// Marks anything still unfinished as cancelled, for a turn the user stopped.
    public func cancelUnfinished(scope: String, now: Date) {
        for (id, entry) in entries where entry.scope == scope && !entry.status.isSettled {
            var entry = entry
            entry.status = .cancelled
            entry.updatedAt = now
            entries[id] = entry
        }
    }

    public func entry(for callID: ToolCallID) -> ToolExecutionEntry? {
        entries[callID]
    }

    /// How many times this exact action has been proposed in this turn.
    public func proposals(of fingerprint: ToolFingerprint) -> Int {
        guard let owner = byFingerprint[fingerprint], let entry = entries[owner] else { return 0 }
        return entry.proposals
    }

    public func entries(inScope scope: String) -> [ToolExecutionEntry] {
        entries.values
            .filter { $0.scope == scope }
            .sorted { $0.updatedAt < $1.updatedAt }
    }

    // MARK: Bounding

    private func note(scope: String) {
        guard !scopes.contains(scope) else { return }
        scopes.append(scope)
        guard scopes.count > retainedScopes else { return }

        let dropped = Set(scopes.prefix(scopes.count - retainedScopes))
        scopes.removeFirst(scopes.count - retainedScopes)

        for (id, entry) in entries where dropped.contains(entry.scope) {
            byFingerprint.removeValue(forKey: entry.fingerprint)
            entries.removeValue(forKey: id)
        }
    }
}
