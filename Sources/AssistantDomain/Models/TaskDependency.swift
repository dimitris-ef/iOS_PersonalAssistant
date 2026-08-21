import Foundation

/// Why one task cannot start yet.
public struct BlockedReason: Hashable, Sendable {
    /// The unresolved prerequisites, in the order they were declared.
    public var prerequisites: [TaskItem.ID]
    /// Their titles, for saying so out loud without a second lookup.
    public var titles: [String]

    public init(prerequisites: [TaskItem.ID], titles: [String]) {
        self.prerequisites = prerequisites
        self.titles = titles
    }

    public var summary: String {
        switch titles.count {
        case 0: return "Waiting on something else."
        case 1: return "Waiting on: \(titles[0])."
        default: return "Waiting on: \(titles.joined(separator: ", "))."
        }
    }
}

/// The "must happen first" relationships between tasks.
///
/// ## Deliberately not a workflow engine
///
/// One relationship, one meaning: A must be resolved before B is worth doing.
/// No conditional branches, no parallel joins, no states of its own. Section 13
/// asks for exactly this and warns against the rest, and the warning is right —
/// a general workflow engine would be a second lifecycle competing with
/// ``TaskStatus`` for the answer to "where does this stand".
///
/// Edges live on the dependent task, as `TaskItem.dependsOn`. That makes the
/// question a task most often asks — *am I blocked?* — answerable from the task
/// itself, with no join and no graph load.
///
/// This type is the operations that need to see more than one task at once:
/// validating a proposed edge, and working out what a completion unblocks.
public struct TaskDependencyGraph: Sendable {
    /// Every task that might take part, by id.
    private let tasks: [TaskItem.ID: TaskItem]

    public init(tasks: [TaskItem]) {
        self.tasks = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public enum ValidationError: Error, Hashable, Sendable, CustomStringConvertible {
        case selfDependency(TaskItem.ID)
        case unknownTask(TaskItem.ID)
        case duplicateEdge(prerequisite: TaskItem.ID, dependent: TaskItem.ID)
        case cycle(through: [TaskItem.ID])

        public var description: String {
            switch self {
            case .selfDependency:
                return "a task cannot depend on itself"
            case .unknownTask(let id):
                return "no task with id \(id)"
            case .duplicateEdge:
                return "that dependency already exists"
            case .cycle(let path):
                return "that would create a loop: \(path.map(\.description).joined(separator: " → "))"
            }
        }
    }

    /// Checks a proposed edge before anything is written.
    ///
    /// The cycle check is the one that needs the whole graph, and the one a
    /// caller cannot be trusted to remember: A→B and B→A are each individually
    /// reasonable, and together they are a pair of tasks that block each other
    /// forever while the assistant insists both are waiting on the other.
    public func validate(prerequisite: TaskItem.ID, dependent: TaskItem.ID) throws {
        guard prerequisite != dependent else {
            throw ValidationError.selfDependency(dependent)
        }
        guard tasks[prerequisite] != nil else {
            throw ValidationError.unknownTask(prerequisite)
        }
        guard let dependentTask = tasks[dependent] else {
            throw ValidationError.unknownTask(dependent)
        }
        guard !dependentTask.dependsOn.contains(prerequisite) else {
            throw ValidationError.duplicateEdge(prerequisite: prerequisite, dependent: dependent)
        }

        // Walking from the prerequisite: if the dependent is already somewhere
        // upstream of it, adding this edge closes the loop.
        if let path = pathFrom(prerequisite, to: dependent) {
            throw ValidationError.cycle(through: [dependent] + path)
        }
    }

    /// Whether `origin` transitively depends on `target`, and how.
    ///
    /// Depth-first with a visited set, so a graph that already contains a cycle
    /// — one written before this validation existed, or by a future bug —
    /// terminates rather than recursing until the stack runs out.
    private func pathFrom(_ origin: TaskItem.ID, to target: TaskItem.ID) -> [TaskItem.ID]? {
        var visited: Set<TaskItem.ID> = []
        var stack: [(id: TaskItem.ID, path: [TaskItem.ID])] = [(origin, [origin])]

        while let current = stack.popLast() {
            if current.id == target { return current.path }
            guard visited.insert(current.id).inserted else { continue }
            for next in tasks[current.id]?.dependsOn ?? [] {
                stack.append((next, current.path + [next]))
            }
        }
        return nil
    }

    /// Why this task cannot be worked on, if it cannot.
    ///
    /// A prerequisite that is completed, cancelled, skipped or expired does not
    /// block: all four are settled, and only the first is a success. That is
    /// the point of them being separate statuses — "you skipped the gym" still
    /// unblocks "put the kit away".
    public func blockedReason(for task: TaskItem) -> BlockedReason? {
        let open = task.dependsOn.filter { id in
            guard let prerequisite = tasks[id] else {
                // A prerequisite that no longer exists cannot be waited on. It
                // was deleted; blocking forever on a ghost would be worse than
                // letting the work proceed.
                return false
            }
            return !prerequisite.status.isSettled
        }
        guard !open.isEmpty else { return nil }
        return BlockedReason(
            prerequisites: open,
            titles: open.compactMap { tasks[$0]?.title }
        )
    }

    public func isBlocked(_ task: TaskItem) -> Bool {
        blockedReason(for: task) != nil
    }

    /// The tasks that become workable now that `completed` is settled.
    ///
    /// Only tasks with nothing else outstanding are returned. Finishing one of
    /// three prerequisites unblocks nothing, and announcing otherwise would be
    /// the assistant telling someone to start work they still cannot do.
    public func unblocked(by completed: TaskItem.ID) -> [TaskItem] {
        tasks.values
            .filter { $0.dependsOn.contains(completed) }
            .filter { !$0.status.isSettled }
            .filter { task in
                task.dependsOn.allSatisfy { id in
                    id == completed || tasks[id].map(\.status.isSettled) ?? true
                }
            }
            .sorted { $0.title < $1.title }
    }

    /// Prerequisites of `task` that are still open, nearest first.
    public func openPrerequisites(of task: TaskItem) -> [TaskItem] {
        task.dependsOn
            .compactMap { tasks[$0] }
            .filter { !$0.status.isSettled }
    }
}
