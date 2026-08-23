import AssistantDomain
import AssistantPersistence
import AssistantPlatform
import ExecutiveSupport
import Foundation

/// What a widget button or a Live Activity control actually did.
public struct SystemSurfaceCommandOutcome: Hashable, Sendable {
    /// The task afterwards.
    public var status: TaskStatus
    /// A short sentence, for the rare surface that can show one.
    public var message: String
    /// False when the action had already been applied.
    public var didChange: Bool

    public init(status: TaskStatus, message: String, didChange: Bool) {
        self.status = status
        self.message = message
        self.didChange = didChange
    }
}

/// The three buttons a system surface is allowed to offer, and nothing else.
///
/// ## Why this is not `AssistantCommandService`
///
/// Section 2 is explicit: do not inject the entire production engine graph into
/// every extension. `AssistantCommandService` holds an `AssistantEngine`, which
/// holds an `AIProviderRegistry`, which on this project means the remote
/// provider, Apple Foundation Models and — in a device build — llama.cpp. A
/// widget extension that linked that would be an eighty-megabyte widget
/// extension whose Done button drags an inference stack into memory to change
/// one enum.
///
/// So this exists: repositories, platform services, a clock, and the support
/// lifecycle. **No provider, no engine, no model.** The dependency list is the
/// guarantee — a widget cannot invoke AI because nothing in its graph can.
///
/// ## Why it is still not a second implementation
///
/// Every method here is three lines over `FollowUpService`, which is the same
/// object the app's own buttons and the notification delegate use. Done means
/// `ReminderOutcome.completed`, which means `TaskStatusMachine`, which means
/// pending stages are cancelled and their OS requests withdrawn. Section 39's
/// pipeline, entered at the same door.
public struct SystemSurfaceCommandService: Sendable {
    private let repositories: AssistantRepositories
    private let followUp: FollowUpService
    private let dateProvider: any DateProvider
    private let timing: FollowUpTiming

    public init(
        repositories: AssistantRepositories,
        services: PlatformServices,
        dateProvider: any DateProvider = SystemDateProvider(),
        timing: FollowUpTiming = .default
    ) {
        self.repositories = repositories
        self.dateProvider = dateProvider
        self.timing = timing
        self.followUp = FollowUpService(
            repositories: repositories,
            services: services,
            dateProvider: dateProvider,
            timing: timing
        )
    }

    /// "Done."
    ///
    /// The only action in the entire product that completes a task, reached
    /// here by exactly the route the app's own button takes.
    @discardableResult
    public func complete(taskID: TaskItem.ID) async throws -> SystemSurfaceCommandOutcome {
        let result = try await followUp.handle(outcome: .completed, forTask: taskID)
        return SystemSurfaceCommandOutcome(
            status: result.task.status,
            message: result.didChange ? "Done." : "Already done.",
            didChange: result.didChange
        )
    }

    /// "Later."
    ///
    /// Section 40, and the rule the product is built on: this is **not**
    /// completion. It produces a new reminder stage through `SupportPlanner`
    /// and leaves the task outstanding, which is what the assertion in
    /// `SystemSurfaceCommandTests` checks rather than trusts.
    ///
    /// `until` is nil deliberately: the plan's own snooze policy knows how many
    /// times this has already been put off and how close the deadline is.
    /// Hard-coding a duration in a widget would quietly override it.
    @discardableResult
    public func snooze(taskID: TaskItem.ID) async throws -> SystemSurfaceCommandOutcome {
        let result = try await followUp.handle(outcome: .snoozed(until: nil), forTask: taskID)
        return SystemSurfaceCommandOutcome(
            status: result.task.status,
            message: result.rationale ?? "I'll remind you again.",
            didChange: result.didChange
        )
    }

    /// "I'm doing it."
    ///
    /// Section 41 and section 64: engagement, not completion. The task becomes
    /// `inProgress` and a check-in is scheduled, because someone who has
    /// started is not someone who has finished — which is the distinction this
    /// whole app exists to hold onto.
    @discardableResult
    public func startWorking(taskID: TaskItem.ID) async throws -> SystemSurfaceCommandOutcome {
        let result = try await followUp.handle(outcome: .acknowledged, forTask: taskID)
        return SystemSurfaceCommandOutcome(
            status: result.task.status,
            message: result.rationale ?? "I'll check back shortly.",
            didChange: result.didChange
        )
    }

    /// The task a surface is acting on, for the caller that needs to redraw.
    public func task(id: TaskItem.ID) async throws -> TaskItem? {
        try await repositories.tasks.task(id: id)
    }
}
