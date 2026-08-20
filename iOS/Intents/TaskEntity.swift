import AppIntents
import AssistantCore
import AssistantDomain
import Foundation

/// A task, as the system sees it.
///
/// ## A projection, not a record
///
/// The domain's `TaskItem` is the task. This is how it looks to Siri and
/// Shortcuts so they can offer a picker — nothing more. It carries the domain
/// id verbatim, so there is exactly one identity for a task across the app, the
/// notification layer, the voice layer and here. Minting a second id for Siri
/// would create two names for one thing and a mapping table to keep them
/// married.
///
/// Deliberately thin. Title and due date are what a person needs to pick the
/// right row; importance, snooze counts, follow-up history and reminder plans
/// are the assistant's working notes and have no business being handed to the
/// system.
struct TaskEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Task")
    static var defaultQuery = TaskEntityQuery()

    /// The domain id, unchanged. See the type's note above.
    var id: UUID
    var title: String
    var dueDate: Date?

    var taskID: TaskItem.ID { TaskItem.ID(id) }

    var displayRepresentation: DisplayRepresentation {
        guard let dueDate else {
            return DisplayRepresentation(title: "\(title)")
        }
        return DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(Self.formatter.string(from: dueDate))"
        )
    }

    init(_ task: TaskItem) {
        self.id = task.id.rawValue
        self.title = task.title
        self.dueDate = task.timing.anchorDate ?? task.deadline
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

/// Lets the system find tasks worth completing.
///
/// Backed by the same repository the app reads, through the command service —
/// so the list Siri offers is the list the app shows, and a task created two
/// seconds ago by another intent is already in it.
///
/// **Outstanding tasks only.** Offering someone a list of things they already
/// finished, to finish again, is not a picker; and the only intent using this
/// is "Complete a Task", for which a completed task is not a candidate.
struct TaskEntityQuery: EntityStringQuery {

    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [TaskEntity] {
        let commands = try AppIntentDependencies.commands()

        var found: [TaskEntity] = []
        for id in identifiers {
            // Looked up individually and by id, so a task the system remembers
            // from a previous run still resolves even if it has since fallen
            // out of the outstanding list.
            if let task = try await commands.task(id: TaskItem.ID(id)) {
                found.append(TaskEntity(task))
            }
        }
        return found
    }

    @MainActor
    func entities(matching string: String) async throws -> [TaskEntity] {
        let commands = try AppIntentDependencies.commands()
        return try await commands.selectableTasks(matching: string).map(TaskEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [TaskEntity] {
        let commands = try AppIntentDependencies.commands()
        // A short list: this is what the system shows before the user has typed
        // anything, and a picker of forty rows is a picker nobody reads.
        return try await commands.selectableTasks().prefix(10).map(TaskEntity.init)
    }
}
