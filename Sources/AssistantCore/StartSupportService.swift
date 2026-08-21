import AssistantDomain
import AssistantPersistence
import ExecutiveSupport
import Foundation

/// Where a first step came from.
///
/// Recorded because the preference order in section 40 is a real product rule —
/// the model is the last resort, not the first — and a source that says
/// "template" when explicit steps existed is a bug worth being able to see.
public enum StartStepSource: String, Hashable, Sendable {
    /// The user or the assistant wrote these steps down already.
    case preparationSteps
    /// Copied from the routine this occurrence belongs to.
    case routine
    /// A deterministic template matched the task.
    case template
    /// A provider proposed a decomposition, which was then structured.
    case model
}

/// What "help me start" produced.
public struct StartSupport: Sendable {
    /// The task, now in progress.
    public var task: TaskItem
    /// The one thing to do next.
    public var step: PreparationStep
    public var source: StartStepSource
    /// When the assistant will check back, if it will.
    public var checkInAt: Date?

    public init(task: TaskItem, step: PreparationStep, source: StartStepSource, checkInAt: Date? = nil) {
        self.task = task
        self.step = step
        self.source = source
        self.checkInAt = checkInAt
    }

    /// A sentence for the UI or for Siri.
    public var summary: String {
        let minutes = Int((step.estimatedDuration / 60).rounded())
        guard minutes > 0 else { return "Start with this: \(step.title)." }
        return "Start with this: \(step.title). About \(minutes) minute\(minutes == 1 ? "" : "s")."
    }
}

/// Proposes a breakdown for a task nobody has broken down.
///
/// A protocol so the model is optional rather than assumed. Everything in Part
/// 8 works with the deterministic implementation; a provider-backed one is a
/// substitution at composition time, and section 90's rule that tests must not
/// need live AI falls out of that rather than being worked around.
public protocol TaskDecomposer: Sendable {
    /// A few concrete steps, or nothing if it has no idea.
    func decompose(_ task: TaskItem) async -> [PreparationStep]
}

/// First steps without a model.
///
/// ## Why templates and not motivation
///
/// Section 38 draws the line exactly right. "You can do it, start small" is
/// advice; "pick up all the clothes from the floor, about five minutes" is a
/// thing a person can begin doing in the next ten seconds. The difference for
/// somebody stuck at the starting line is the whole product.
///
/// The templates are keyed on words that appear in what people actually write
/// down. They are not clever and they do not need to be: a concrete, slightly
/// generic first step beats a perfect one that requires a network round trip,
/// and the explicit-steps path above this covers everything that matters most.
public struct TemplateTaskDecomposer: TaskDecomposer {
    public init() {}

    private static let templates: [(keywords: [String], step: String, minutes: Double)] = [
        (["clean", "tidy", "declutter"], "Pick up everything off the floor in one room", 5),
        (["wash", "laundry", "dishes"], "Load whatever is nearest and start the machine", 5),
        (["write", "report", "essay", "draft"], "Open the document and write one sentence", 5),
        (["email", "reply", "respond"], "Open the message and write the first line", 3),
        (["call", "phone", "ring"], "Find the number and put it on screen", 2),
        (["pay", "bill", "invoice"], "Open the app and find the amount", 3),
        (["pack", "bag", "suitcase"], "Put one thing you definitely need in the bag", 3),
        (["shop", "groceries", "buy"], "Write down the first three things you need", 4),
        (["form", "application", "paperwork"], "Open the form and fill in your name", 3),
        (["book", "appointment", "schedule"], "Open the booking page", 3),
        (["study", "revise", "read"], "Open it and read one page", 5),
        (["tax", "accounts", "expenses"], "Open the folder and find the first document", 5),
    ]

    public func decompose(_ task: TaskItem) async -> [PreparationStep] {
        let text = "\(task.title) \(task.details ?? "")".lowercased()

        let matched = Self.templates.first { template in
            template.keywords.contains { text.contains($0) }
        }

        // The universal fallback. Deliberately a *time box* rather than an
        // instruction: when the app genuinely does not know what the task
        // involves, the honest smallest step is to spend five minutes on it and
        // see. That is still concrete, and it is still something a person can
        // start now.
        let title = matched?.step ?? "Spend five minutes on the easiest part of it"
        let minutes = matched?.minutes ?? 5

        return [
            PreparationStep(
                id: PreparationStep.identity(parent: task.id.description, title: title),
                title: title,
                estimatedDuration: TimeSpan.minutes(minutes),
                necessity: .required,
                sequence: 0
            )
        ]
    }
}

/// "Help me start."
///
/// ## The two things it must not do
///
/// It must not answer with encouragement — see ``TemplateTaskDecomposer`` — and
/// it must not mark anything complete. Starting is `inProgress`; that is
/// section 42, and it is the same rule as dismissal-is-not-completion wearing a
/// different hat. Someone who says "I'm doing it" has told the assistant where
/// they are, not that they are finished, and an app that treats the two as the
/// same is one that quietly loses work.
///
/// ## Where the step comes from
///
/// In the order section 40 sets out: steps the task already carries, then the
/// routine's own steps, then a deterministic template, then — only if one is
/// composed in — a model. Whatever the source, the result is a structured
/// ``PreparationStep`` before anything is persisted. Model prose never becomes
/// task state.
public struct StartSupportService: Sendable {
    private let repositories: AssistantRepositories
    private let followUp: FollowUpService
    private let decomposer: any TaskDecomposer
    private let dateProvider: any DateProvider
    private let logger: any ExecutiveSupportLogger

    public init(
        repositories: AssistantRepositories,
        followUp: FollowUpService,
        decomposer: any TaskDecomposer = TemplateTaskDecomposer(),
        dateProvider: any DateProvider = SystemDateProvider(),
        logger: any ExecutiveSupportLogger = SilentExecutiveSupportLogger()
    ) {
        self.repositories = repositories
        self.followUp = followUp
        self.decomposer = decomposer
        self.dateProvider = dateProvider
        self.logger = logger
    }

    /// Produces the next concrete action and moves the task into progress.
    public func start(taskID: TaskItem.ID) async throws -> StartSupport {
        guard let task = try await repositories.tasks.task(id: taskID) else {
            throw RepositoryError.notFound(taskID.description)
        }

        let resolved = try await firstStep(for: task)
        var updated = resolved.task

        // Persist the steps if this is the first time they have existed, so the
        // next "help me start" continues the sequence rather than inventing a
        // new one.
        if updated.preparationSteps != task.preparationSteps {
            try await repositories.tasks.save(updated)
        }

        // Through `FollowUpService`, not by setting the status here. It is the
        // one door: it records the acknowledgement against the plan, asks the
        // planner for a check-in, and cancels nothing it should not. A status
        // written directly would skip all three.
        let outcome = try await followUp.handle(outcome: .acknowledged, forTask: taskID)
        updated = outcome.task

        logger.record(.startSupport(taskID: taskID, source: resolved.source.rawValue))

        return StartSupport(
            task: updated,
            step: resolved.step,
            source: resolved.source,
            checkInAt: outcome.nextReminder?.fireDate
        )
    }

    /// Marks one step done and returns the next.
    ///
    /// Completing a step is not completing the task — section 45. Packing the
    /// documents does not make the appointment happen, and the parent stays
    /// exactly where it was unless every step is now done and the caller says
    /// otherwise.
    @discardableResult
    public func completeStep(
        _ stepID: PreparationStep.ID,
        taskID: TaskItem.ID
    ) async throws -> (task: TaskItem, next: PreparationStep?) {
        guard var task = try await repositories.tasks.task(id: taskID) else {
            throw RepositoryError.notFound(taskID.description)
        }
        guard let index = task.preparationSteps.firstIndex(where: { $0.id == stepID }) else {
            throw RepositoryError.notFound(stepID.description)
        }

        task.preparationSteps[index].complete(at: dateProvider.now)
        task.updatedAt = dateProvider.now
        try await repositories.tasks.save(task)

        return (task, task.preparationSteps.nextIncomplete)
    }

    // MARK: Sources

    private func firstStep(
        for task: TaskItem
    ) async throws -> (task: TaskItem, step: PreparationStep, source: StartStepSource) {
        // 1. Steps the task already carries.
        if let step = task.preparationSteps.nextIncomplete {
            return (task, step, .preparationSteps)
        }

        // 2. The routine's steps, for an occurrence that has none of its own.
        if task.preparationSteps.isEmpty,
           let routineID = task.routineID,
           let routine = try await repositories.routines.routine(id: routineID),
           let template = routine.preparationSteps.ordered.first {
            var updated = task
            updated.preparationSteps = routine.preparationSteps.map { step in
                var copy = step
                copy.id = PreparationStep.identity(parent: task.id.description, title: step.title)
                copy.isCompleted = false
                copy.completedAt = nil
                return copy
            }
            updated.updatedAt = dateProvider.now
            let first = updated.preparationSteps.nextIncomplete ?? template
            return (updated, first, .routine)
        }

        // 3 and 4. A template, or whatever a composed-in decomposer proposes.
        //
        // Both land here, and both go through the same door: the result is a
        // list of `PreparationStep` values, validated and bounded, before it
        // touches the task. A provider-backed decomposer returning prose gets
        // no more privilege than the template does.
        let proposed = await decomposer.decompose(task)
        let steps = Self.sanitised(proposed, parent: task)
        guard let first = steps.nextIncomplete else {
            // Nothing could be proposed at all. Rather than fail, fall back to
            // the one step that is always true.
            let step = PreparationStep(
                id: PreparationStep.identity(parent: task.id.description, title: task.title),
                title: "Spend five minutes on it",
                estimatedDuration: TimeSpan.minutes(5)
            )
            var updated = task
            updated.preparationSteps = [step]
            updated.updatedAt = dateProvider.now
            return (updated, step, .template)
        }

        var updated = task
        updated.preparationSteps = steps
        updated.updatedAt = dateProvider.now
        let source: StartStepSource = decomposer is TemplateTaskDecomposer ? .template : .model
        return (updated, first, source)
    }

    /// Bounds whatever was proposed before it becomes state.
    ///
    /// Section 57, applied at the point it matters rather than only at the tool
    /// boundary: a decomposer is code somebody else may write, and a four-hour
    /// "open the document" would quietly wreck every timeline the task appears
    /// in.
    static func sanitised(_ steps: [PreparationStep], parent: TaskItem) -> [PreparationStep] {
        steps
            .prefix(8)
            .enumerated()
            .compactMap { index, step in
                let title = step.title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return nil }
                return PreparationStep(
                    id: PreparationStep.identity(parent: parent.id.description, title: title),
                    title: String(title.prefix(120)),
                    estimatedDuration: min(max(0, step.estimatedDuration), TimeSpan.hours(2)),
                    necessity: step.necessity,
                    sequence: index
                )
            }
    }
}
