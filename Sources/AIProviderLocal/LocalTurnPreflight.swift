import AssistantAI
import AssistantDomain
import Foundation

/// What pressing Send should do when Local AI is the chosen assistant.
///
/// ## Why Send needs a decision at all
///
/// Sections 47 and 48. Three things can be true when somebody types a message
/// and the answer is meant to come from the device:
///
/// - the weights are in memory, and the turn can start;
/// - the weights are on disk but not in memory, and a load has to happen first
///   — which takes seconds and is the thing that made Send look frozen;
/// - nothing usable is there at all, and starting a turn produces a failure the
///   app could have predicted.
///
/// Collapsing those into "just try it" gives the third case a spinner followed
/// by an error, and the second case a spinner with no explanation. Both read as
/// the app hanging.
public enum LocalTurnPreflight {

    /// What to do before the turn.
    public enum Decision: Hashable, Sendable {
        /// The model is resident. Start the turn.
        case proceed
        /// Load first, showing `notice` while it happens.
        case loadFirst(notice: String)
        /// Do not start a turn. `reason` is a sentence to show the user.
        case refuse(reason: String)

        public var startsATurn: Bool {
            switch self {
            case .proceed, .loadFirst: return true
            case .refuse: return false
            }
        }
    }

    /// Decides from what the model system reports.
    ///
    /// The message for `loadFirst` names the model, because "Loading…" with no
    /// subject during a five-second pause is the same non-explanation the
    /// spinner already was.
    public static func decide(
        availability: LocalModelAvailability,
        modelName: String?
    ) -> Decision {
        let subject = modelName.map { "Loading \($0)…" } ?? "Loading the model…"
        switch availability {
        case .ready:
            return .proceed
        case .modelDownloaded:
            return .loadFirst(notice: subject)
        case .modelLoading:
            // Already on its way. Waiting is right; starting a second load is
            // how two multi-gigabyte allocations end up in flight at once.
            return .loadFirst(notice: subject)
        case .noModelInstalled:
            return .refuse(
                reason: "No local model is downloaded yet. Choose one in "
                    + "Settings › Manage Models."
            )
        case .corruptedModel(let reason):
            return .refuse(reason: reason)
        case .modelIncompatible(let reason):
            return .refuse(reason: reason)
        case .insufficientMemory(let reason):
            // Section 106 and section 128: no quiet hop to the cloud. Somebody
            // who chose an on-device model chose it for a reason, and sending
            // their message to a remote service because the local one ran out
            // of memory is the one thing this must never do.
            return .refuse(reason: reason)
        case .runtimeUnavailable(let reason):
            return .refuse(reason: reason)
        }
    }

    /// The sentence shown when a load fails at Send time.
    ///
    /// Distinguished from a generation failure on purpose: "the model could not
    /// be loaded" is actionable — pick a smaller one — and "the model could not
    /// answer" is not.
    public static func loadFailureMessage(_ error: LocalRuntimeError) -> String {
        switch error {
        case .insufficientMemory(let reason):
            return reason
        case .modelFileMissing:
            return "The model file is missing. Download it again from Manage Models."
        case .runtimeUnavailable(let reason):
            return reason
        default:
            return error.description
        }
    }
}
