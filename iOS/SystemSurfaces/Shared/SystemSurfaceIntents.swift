import AppIntents
import AssistantCore
import AssistantDomain
import Foundation

/// The buttons a widget or a Live Activity may offer.
///
/// ## Why App Intents and not a shared file
///
/// Section 39 and section 70 spell out the failure this avoids: a widget that
/// writes `"completed": true` into a JSON file and calls that task completion.
/// Nothing would run the status machine, no pending reminder would be
/// cancelled, no follow-up would be withdrawn, and the next reconciliation pass
/// would find a task in a state nothing put it in.
///
/// So each of these is four lines that hand off to `SystemSurfaceCommandService`,
/// which is `FollowUpService`, which is `TaskStatusMachine`. The same door the
/// app's own buttons and the notification delegate use.
///
/// ## Why the trio is exactly this
///
/// Because the product's central rule needs all three to exist separately.
/// "Done" is the only one that completes. "Later" and "I'm doing it" are the
/// two honest things a person can say when they have not finished, and offering
/// only Done is what turns a support system into a nagging one — people press
/// the button that makes the notification go away.
///
/// ## Where these run
///
/// In the widget extension's process, which is iOS's design rather than ours.
/// `SystemSurfaceBridge` is what makes that safe: it composes the repositories
/// and the support lifecycle, and nothing else — no engine and no provider.
@available(iOS 17.0, *)
struct CompleteTaskFromSurfaceIntent: AppIntent {
    static var title: LocalizedStringResource = "Mark Done"
    static var description = IntentDescription(
        "Marks a task complete and stops the assistant chasing it."
    )
    /// The whole point of an interactive widget: it must not open the app.
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Task")
    var taskID: String

    init() {}

    init(taskID: UUID) {
        self.taskID = taskID.uuidString
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await SystemSurfaceIntentRunner.run(taskID: taskID) { commands, id in
            try await commands.complete(taskID: id)
        }
        return .result()
    }
}

/// "Later."
///
/// Section 40 and section 63: **not** completion. It produces a new reminder
/// stage through `SupportPlanner` and leaves the task outstanding.
@available(iOS 17.0, *)
struct SnoozeTaskFromSurfaceIntent: AppIntent {
    static var title: LocalizedStringResource = "Remind Me Later"
    static var description = IntentDescription(
        "Asks the assistant to come back to this. The task stays open."
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Task")
    var taskID: String

    init() {}

    init(taskID: UUID) {
        self.taskID = taskID.uuidString
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await SystemSurfaceIntentRunner.run(taskID: taskID) { commands, id in
            try await commands.snooze(taskID: id)
        }
        return .result()
    }
}

/// "I'm doing it."
///
/// Section 41 and section 64: engagement, not completion. The task becomes
/// `inProgress` and a check-in is scheduled — because someone who has started
/// is not someone who has finished, and pretending otherwise is the failure
/// this whole application exists to avoid.
@available(iOS 17.0, *)
struct StartTaskFromSurfaceIntent: AppIntent {
    static var title: LocalizedStringResource = "I'm Doing It"
    static var description = IntentDescription(
        "Tells the assistant you have started. It will check back rather than nag."
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Task")
    var taskID: String

    init() {}

    init(taskID: UUID) {
        self.taskID = taskID.uuidString
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await SystemSurfaceIntentRunner.run(taskID: taskID) { commands, id in
            try await commands.startWorking(taskID: id)
        }
        return .result()
    }
}

/// The three lines every one of the intents above shares.
///
/// Extracted so the pattern cannot drift between them: parse, act through the
/// command service, then refresh the projections so the widget the user is
/// looking at redraws with the new state rather than the old.
@available(iOS 17.0, *)
@MainActor
enum SystemSurfaceIntentRunner {
    static func run(
        taskID raw: String,
        _ body: (SystemSurfaceCommandService, TaskItem.ID) async throws -> Void
    ) async throws {
        guard let uuid = UUID(uuidString: raw) else { return }

        let bridge = try SystemSurfaceBridge.composition()
        try await body(bridge.commands, TaskItem.ID(uuid))

        // Section 39's last step. The domain changed, so the projections are
        // stale — rebuild them and let WidgetKit know. Deliberately after the
        // command and deliberately not part of it: a refresh that failed must
        // never be able to fail a completion (section 85).
        await bridge.surfaces.refresh(reason: .domainChange)
    }
}
