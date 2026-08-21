import AssistantDomain
import Foundation

/// Something the executive-support layer did, in terms safe to write down.
///
/// ## What is deliberately not in here
///
/// Titles. Not one case carries the name of a task, a routine or a preparation
/// step, and that is the whole design of this type rather than a rule someone
/// has to remember at each call site. "Take the medication", "call the clinic
/// about the results" and "collect the prescription" are among the most
/// sensitive things this app holds, and a diagnostic log is exactly the place
/// they would leak from — into a console, a sysdiagnose, a bug report attached
/// to an email.
///
/// Identifiers, counts, categories and times are enough to debug a scheduler.
/// If a future case needs a title to be useful, that is the signal to reconsider
/// the case, not the rule.
public enum ExecutiveSupportEvent: Hashable, Sendable {
    case routineReconciled(routineID: Routine.ID, created: Int, recovering: Int, expired: Int)
    case occurrenceRecovering(routineID: Routine.ID, until: Date)
    case occurrenceExpired(routineID: Routine.ID, at: Date)
    /// A prerequisite completed and something downstream became workable.
    case dependencyUnlocked(prerequisite: TaskItem.ID, unblocked: Int)
    /// A preparation timeline was calculated or recalculated.
    case preparationPlanned(taskID: TaskItem.ID, startAt: Date, leaveAt: Date, compressed: Bool)
    /// Start support handed back a first step.
    case startSupport(taskID: TaskItem.ID, source: String)
    /// The Today list was ranked.
    case ranked(count: Int, blocked: Int)

    /// A one-line rendering, for a logger that wants one.
    public var summary: String {
        switch self {
        case .routineReconciled(let id, let created, let recovering, let expired):
            return "routine \(short(id.rawValue)): +\(created) new, \(recovering) recovering, \(expired) expired"
        case .occurrenceRecovering(let id, let until):
            return "routine \(short(id.rawValue)): occurrence recoverable until \(until)"
        case .occurrenceExpired(let id, _):
            return "routine \(short(id.rawValue)): occurrence expired"
        case .dependencyUnlocked(let prerequisite, let count):
            return "task \(short(prerequisite.rawValue)) completed, unblocked \(count)"
        case .preparationPlanned(let id, let start, let leave, let compressed):
            return "task \(short(id.rawValue)): start \(start), leave \(leave)\(compressed ? " (compressed)" : "")"
        case .startSupport(let id, let source):
            return "task \(short(id.rawValue)): first step from \(source)"
        case .ranked(let count, let blocked):
            return "ranked \(count) task(s), \(blocked) blocked"
        }
    }

    private func short(_ uuid: UUID) -> String {
        String(uuid.uuidString.prefix(8))
    }
}

/// Somewhere for support diagnostics to go.
///
/// Same shape as `AgentLogger` from Part 7 and for the same reason: what is safe
/// to write down differs between a developer's console and a shipped app, and
/// that decision belongs to whoever composes the application. The default does
/// nothing.
public protocol ExecutiveSupportLogger: Sendable {
    func record(_ event: ExecutiveSupportEvent)
}

extension ExecutiveSupportLogger {
    public func record(_ event: ExecutiveSupportEvent) {}
}

/// The production logger: silence.
public struct SilentExecutiveSupportLogger: ExecutiveSupportLogger {
    public init() {}
}
