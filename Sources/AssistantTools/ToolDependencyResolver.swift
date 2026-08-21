import AssistantDomain
import Foundation

/// Orders the calls in one round so that whatever produces an identifier runs
/// before whatever uses it.
///
/// ## The case this exists for
///
/// A model that proposes, in a single response:
///
/// ```
/// createTask(taskID: A, title: "Send the paperwork")
/// createFollowUp(taskID: A, checkBackAt: …)
/// ```
///
/// has expressed a dependency: the follow-up is about a task that does not
/// exist yet. Run in the order given it happens to work; run in the order a
/// dictionary or a set iteration produced it, it fails with "task not found"
/// and the user loses the chase-up. Rather than hope, the edge is read from the
/// arguments — B depends on A when B mentions an identifier A creates — and the
/// order is made deterministic.
///
/// It also decides what happens when a producer fails: a dependent is not run
/// with an identifier that was never created. It is skipped, truthfully, and
/// the model is told which action it was waiting on.
///
/// ## What it deliberately does not do
///
/// It does not run anything in parallel. Independent calls could be, and the
/// gain would be milliseconds against a model round trip measured in seconds,
/// paid for with a class of ordering bug that only appears under load. Sequential
/// and predictable is worth more here.
///
/// It also only sees identifiers the model wrote down. An event the planner
/// invents an id for during normalisation cannot be referenced by a call in the
/// same response — the model never saw that id. Those dependencies are
/// expressed the other way round, by proposing the second call in the next
/// round, once the result is in front of it.
public struct ToolDependencyResolver: Sendable {
    /// One call, and which of its siblings it is waiting on.
    public struct Node: Hashable, Sendable {
        public var call: DecodedToolCall
        public var dependsOn: [ToolCallID]

        public init(call: DecodedToolCall, dependsOn: [ToolCallID] = []) {
            self.call = call
            self.dependsOn = dependsOn
        }
    }

    public init() {}

    /// The calls, in an order that satisfies their dependencies.
    public func resolve(_ calls: [DecodedToolCall]) -> [Node] {
        // Which call creates which identifier. First writer wins: two calls
        // claiming to create the same id is nonsense, and picking the earlier
        // one at least stays deterministic.
        var producers: [UUID: ToolCallID] = [:]
        for call in calls {
            for produced in Self.produces(call.request) where producers[produced] == nil {
                producers[produced] = call.callID
            }
        }

        var dependencies: [ToolCallID: [ToolCallID]] = [:]
        for call in calls {
            let needed = Self.consumes(call.request)
                .compactMap { producers[$0] }
                .filter { $0 != call.callID }
            // Deduplicated while preserving order, so a call that references
            // one producer twice lists it once.
            var seen: Set<ToolCallID> = []
            dependencies[call.callID] = needed.filter { seen.insert($0).inserted }
        }

        return sorted(calls, dependencies: dependencies).map { call in
            Node(call: call, dependsOn: dependencies[call.callID] ?? [])
        }
    }

    /// Kahn's algorithm with the original order as the tie-break, so the result
    /// is not merely valid but the same on every run.
    private func sorted(
        _ calls: [DecodedToolCall],
        dependencies: [ToolCallID: [ToolCallID]]
    ) -> [DecodedToolCall] {
        var remaining = calls
        var emitted: Set<ToolCallID> = []
        var ordered: [DecodedToolCall] = []

        while !remaining.isEmpty {
            let readyIndex = remaining.firstIndex { call in
                (dependencies[call.callID] ?? []).allSatisfy { emitted.contains($0) }
            }

            // No call is ready: the model has described a cycle. Emitting the
            // first one breaks it in a defined place rather than looping, and
            // the call that then runs with an unsatisfied reference fails
            // honestly at execution — which is a better outcome than an engine
            // that hangs.
            let index = readyIndex ?? remaining.startIndex
            let call = remaining.remove(at: index)
            emitted.insert(call.callID)
            ordered.append(call)
        }

        return ordered
    }

    // MARK: Identifier flow

    /// Identifiers this call brings into existence — but only the ones the
    /// model chose itself. A nil id is one the planner will invent, which no
    /// sibling call can be referring to.
    static func produces(_ request: ToolRequest) -> Set<UUID> {
        switch request {
        case .createCalendarEvent(let input):
            return input.eventID.map { [$0.rawValue] } ?? []
        case .createTask(let input):
            return input.taskID.map { [$0.rawValue] } ?? []
        default:
            return []
        }
    }

    /// Identifiers this call needs to already exist.
    ///
    /// Includes identifiers of things no tool in the catalogue creates — an
    /// alarm id, a memory id. They cost nothing to list and they matter if a
    /// creating tool is ever added.
    static func consumes(_ request: ToolRequest) -> Set<UUID> {
        switch request {
        case .updateCalendarEvent(let input):
            return [input.eventID.rawValue]
        case .deleteCalendarEvent(let input):
            return [input.eventID.rawValue]
        case .createReminder(let input):
            return input.relatedTaskID.map { [$0.rawValue] } ?? []
        case .completeReminder(let input):
            return [input.reminderID.rawValue]
        case .updateAlarm(let input):
            return [input.alarmID.rawValue]
        case .cancelAlarm(let input):
            return [input.alarmID.rawValue]
        case .scheduleNotification(let input):
            return input.relatedTaskID.map { [$0.rawValue] } ?? []
        case .updateMemory(let input):
            return [input.memoryID.rawValue]
        case .completeTask(let input):
            return [input.taskID.rawValue]
        case .createFollowUp(let input):
            return [input.taskID.rawValue]
        case .createCalendarEvent, .createTask, .createAlarm, .storeMemory,
             .getUpcomingSchedule, .askClarification:
            return []
        }
    }
}
