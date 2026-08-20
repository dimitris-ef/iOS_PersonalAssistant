import AppIntents
import AssistantCore
import AssistantDomain
import Foundation

/// The five things the system can ask the assistant to do.
///
/// Every one of them is a shell. It collects parameters, calls
/// `AssistantCommandService`, and turns the outcome into a sentence. There is
/// no assistant logic in this file and there must never be: the moment an
/// intent decides something for itself, Siri and the app start behaving
/// differently and only one of them is tested.
///
/// None of these types touches SwiftData, EventKit, UserNotifications,
/// AlarmKit or a concrete AI provider. They cannot — the command service is the
/// only dependency they are given.

// MARK: - Ask

/// Arbitrary natural language, answered by the assistant proper.
///
/// The only intent that involves a model, and it reaches one the same way the
/// composer does: through `AssistantEngine`, which assembles context, retrieves
/// memory, routes to the selected provider, and validates, authorizes and
/// executes any tool calls that come back. Asking Siri to set a reminder runs
/// the identical pipeline as typing it.
/// TODO-DEVICE: Siri discovering this at all, whether the phrases in
/// `AssistantAppShortcuts` are recognised as written, and whether
/// `openAppWhenRun = false` really lets the whole engine turn complete in the
/// background — including whether the Keychain is readable and Apple
/// Intelligence usable when Siri woke the process rather than the user.
struct AskAssistantIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask Assistant"
    static var description = IntentDescription(
        "Ask the assistant anything, the same way you would in the app."
    )

    /// Runs without opening the app. The whole point of the milestone is
    /// system-level access that does not require going to the app first, and
    /// asking a question changes nothing that needs supervising.
    static var openAppWhenRun = false

    @Parameter(
        title: "Question",
        description: "What you want to ask.",
        requestValueDialog: "What would you like to ask?"
    )
    var question: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = try await AssistantIntentRunner.run {
            try await AppIntentDependencies.commands().ask(question)
        }
        return .result(dialog: IntentDialog(stringLiteral: outcome.message))
    }
}

// MARK: - Create a task

/// A task from structured parameters, with no model involved.
///
/// The user already chose the action and filled in the fields; there is nothing
/// left to interpret, and spending a model call to turn "Call the dentist" into
/// a `createTask` request it already is would add latency and a failure mode
/// for no gain. What still happens is everything after interpretation —
/// authorization, the support planner, the reminder plan, persistence.
struct CreateTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Add a Task"
    static var description = IntentDescription(
        "Add a task the assistant will keep track of and chase."
    )
    static var openAppWhenRun = false

    @Parameter(title: "Task", requestValueDialog: "What's the task?")
    var title_: String

    @Parameter(title: "Due")
    var dueDate: Date?

    @Parameter(title: "Important")
    var isImportant: Bool?

    @Parameter(title: "Notes")
    var notes: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$title_) to Personal Assistant") {
            \.$dueDate
            \.$isImportant
            \.$notes
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = try await AssistantIntentRunner.run {
            try await AppIntentDependencies.commands().createTask(
                title: title_,
                dueDate: dueDate,
                importance: (isImportant ?? false) ? .high : nil,
                notes: notes
            )
        }
        return .result(dialog: IntentDialog(stringLiteral: outcome.message))
    }
}

// MARK: - Remember something

/// Stores something explicitly, through the ordinary memory service.
///
/// Duplicate detection, conflict handling and confidence assignment all apply,
/// so telling Siri something already known does not produce a second copy.
struct StoreMemoryIntent: AppIntent {
    static var title: LocalizedStringResource = "Remember Something"
    static var description = IntentDescription(
        "Tell the assistant something to remember about you."
    )
    static var openAppWhenRun = false

    @Parameter(
        title: "Remember",
        requestValueDialog: "What should I remember?"
    )
    var content: String

    static var parameterSummary: some ParameterSummary {
        Summary("Remember \(\.$content)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = try await AssistantIntentRunner.run {
            try await AppIntentDependencies.commands().storeMemory(content)
        }
        return .result(dialog: IntentDialog(stringLiteral: outcome.message))
    }
}

// MARK: - Today

/// The day, from stored data.
///
/// No provider is consulted. The repositories know exactly what is on today,
/// and making a lookup depend on network, credentials and model availability
/// would add three ways to fail at reciting something already known.
struct ShowTodayIntent: AppIntent {
    static var title: LocalizedStringResource = "What's Today?"
    static var description = IntentDescription(
        "Hear what's left on your day, including when to start getting ready."
    )
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let briefing = try await AssistantIntentRunner.run {
            try await AppIntentDependencies.commands().today()
        }
        return .result(dialog: IntentDialog(stringLiteral: briefing.spokenSummary()))
    }
}

// MARK: - Complete a task

/// Marks a task done through the shared lifecycle.
///
/// `FollowUpService` does the work, which is what cancels the reminders still
/// waiting for that task. An intent that set `status = .completed` itself would
/// leave the user being chased about something they had just told Siri they had
/// finished — the exact failure this product exists to prevent, arriving
/// through a new door.
struct MarkTaskCompleteIntent: AppIntent {
    static var title: LocalizedStringResource = "Complete a Task"
    static var description = IntentDescription(
        "Mark one of your tasks as done."
    )
    static var openAppWhenRun = false

    @Parameter(title: "Task", requestValueDialog: "Which task did you finish?")
    var task: TaskEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Complete \(\.$task)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = try await AssistantIntentRunner.run {
            try await AppIntentDependencies.commands().completeTask(id: task.taskID)
        }
        return .result(dialog: IntentDialog(stringLiteral: outcome.message))
    }
}

// MARK: - Shared error handling

/// Turns application errors into something Siri can say.
///
/// Every intent goes through this, so no raw error can reach a system surface.
/// A `RepositoryError`, an EventKit `NSError` or a provider transport failure
/// would otherwise be read out verbatim — and some of them quote user data.
enum AssistantIntentRunner {
    static func run<Value>(
        _ work: () async throws -> Value
    ) async throws -> Value {
        do {
            return try await work()
        } catch let error as AssistantCommandError {
            // Already a sentence written in this codebase.
            throw error.asIntentError
        } catch is CancellationError {
            // The system cancelled us. Nothing half-done was committed —
            // the command layer's writes are individually atomic — so this
            // exits quietly rather than reporting a failure the user caused.
            throw CancellationError()
        } catch {
            throw AssistantIntentError.failed(
                "Something went wrong. Try again from the app."
            )
        }
    }
}

/// The error App Intents shows.
///
/// `CustomLocalizedStringResourceConvertible` is what makes the message appear
/// in Siri and Shortcuts rather than a generic failure.
enum AssistantIntentError: Error, CustomLocalizedStringResourceConvertible {
    case failed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .failed(let message):
            return LocalizedStringResource(stringLiteral: message)
        }
    }
}

extension AssistantCommandError {
    var asIntentError: AssistantIntentError { .failed(message) }
}
