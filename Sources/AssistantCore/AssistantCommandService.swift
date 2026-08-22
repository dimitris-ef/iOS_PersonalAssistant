import AssistantAI
import AssistantDomain
import AssistantPersistence
import AssistantPlatform
import AssistantTools
import ExecutiveSupport
import Foundation

/// What went wrong, in terms a system surface can say out loud.
///
/// Siri and Shortcuts show whatever an intent returns, so a raw
/// `RepositoryError` or an EventKit `NSError` would be read to the user
/// verbatim. Every failure is mapped to one of these first, and every message
/// is a sentence written in this codebase.
public enum AssistantCommandError: Error, Hashable, Sendable {
    case providerUnavailable(reason: String)
    case permissionDenied(capability: PlatformCapability)
    case itemNotFound
    case validationFailed(reason: String)
    case authorizationDenied(reason: String)
    case operationFailed

    /// One concise line, safe for Siri to speak.
    public var message: String {
        switch self {
        case .providerUnavailable(let reason):
            return reason
        case .permissionDenied(let capability):
            return "I couldn't do that because \(capability.rawValue) access is turned off."
        case .itemNotFound:
            return "I couldn't find that."
        case .validationFailed(let reason):
            return reason
        case .authorizationDenied(let reason):
            return reason
        case .operationFailed:
            return "That didn't work. Try again from the app."
        }
    }
}

/// What a command did, for the system surface to report.
public struct AssistantCommandOutcome: Hashable, Sendable {
    /// The sentence to speak or show. Always truthful about what happened.
    public var message: String
    /// False when the command completed but changed nothing.
    public var didSucceed: Bool

    public init(message: String, didSucceed: Bool = true) {
        self.message = message
        self.didSucceed = didSucceed
    }
}

/// The one entry point for anything outside the app that wants the assistant to
/// do something.
///
/// ## What this is, and what it deliberately is not
///
/// It is a **bridge**, not a second assistant. Every method below is a handful
/// of lines that calls something that already existed: `AssistantEngine`,
/// `MemoryService`, `FollowUpService`, the repositories. It holds no rules of
/// its own about tasks, memory, reminders or providers, and it must not acquire
/// any — the moment it does, there are two definitions of what creating a task
/// means and they will drift.
///
/// ## Why it lives in the package rather than beside the intents
///
/// `iOS/` has no test target, and everything in this file is worth testing:
/// that a structured task creation still produces a reminder plan, that storing
/// a memory still runs duplicate detection, that completing an already-complete
/// task says so instead of lying. An `AppIntent` type cannot be instantiated in
/// a unit test without the App Intents runtime, so the logic sits here and the
/// intent is a thin shell around it.
///
/// Nothing in this file imports `AppIntents`, and it never will. It does not
/// know Siri exists.
public struct AssistantCommandService: Sendable {
    private let engine: AssistantEngine
    private let repositories: AssistantRepositories
    private let memory: MemoryService
    private let dateProvider: any DateProvider

    public init(
        engine: AssistantEngine,
        repositories: AssistantRepositories,
        memory: MemoryService,
        dateProvider: any DateProvider = SystemDateProvider()
    ) {
        self.engine = engine
        self.repositories = repositories
        self.memory = memory
        self.dateProvider = dateProvider
    }

    // MARK: Ask

    /// A natural-language request, answered by the assistant proper.
    ///
    /// This is the *only* command that involves a model, and it involves it the
    /// same way the composer does — through `AssistantEngine`, which assembles
    /// context, retrieves memory, routes to whichever provider settings name,
    /// decodes and validates any tool calls, authorizes them, plans support and
    /// executes. The system surface supplies a string and receives a string.
    ///
    /// The conversation is persisted like any other, so a question asked
    /// through Siri is there in the app afterwards. Hidden system-only history
    /// would mean the assistant remembered a conversation the user could not
    /// find.
    public func ask(_ text: String) async throws -> AssistantCommandOutcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AssistantCommandError.validationFailed(reason: "There was nothing to ask.")
        }

        let conversation = try await currentConversation()

        do {
            let result = try await engine.send(trimmed, in: conversation.id)
            return AssistantCommandOutcome(
                message: Self.concise(result.assistantMessage.text, results: result.results)
            )
        } catch let error as ModelRoutingError {
            // The provider the user chose is not usable right now. Said
            // plainly, and **not** worked around: silently answering with a
            // different model than the one someone selected is exactly the
            // substitution the routing policy exists to prevent.
            throw AssistantCommandError.providerUnavailable(reason: Self.describe(error))
        } catch let error as AIProviderError {
            throw AssistantCommandError.providerUnavailable(reason: Self.describe(error))
        } catch {
            throw AssistantCommandError.operationFailed
        }
    }

    /// Continues the most recent conversation, or starts one.
    ///
    /// The same rule the app uses when it opens. Asking Siri something is a
    /// turn in the ongoing conversation, not a new one each time — otherwise a
    /// week of Siri questions becomes a week of one-message conversations.
    private func currentConversation() async throws -> Conversation {
        let existing = try await repositories.conversations.allConversations()
        if let latest = existing.first { return latest }
        return try await engine.startConversation(title: "Assistant")
    }

    // MARK: Create a task

    /// A task from already-structured parameters.
    ///
    /// No model is involved, and that is deliberate — see
    /// `AssistantEngine.perform(_:origin:)`. Everything after interpretation
    /// still runs: authorization, the support planner, the reminder plan, and
    /// persistence. A task created from Shortcuts is chased exactly as hard as
    /// one created by talking.
    public func createTask(
        title: String,
        dueDate: Date? = nil,
        importance: Importance? = nil,
        notes: String? = nil
    ) async throws -> AssistantCommandOutcome {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AssistantCommandError.validationFailed(reason: "A task needs a title.")
        }

        let input = CreateTaskInput(
            title: trimmed,
            details: notes?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            importance: importance,
            dueDate: dueDate
        )

        let (plan, results) = try await run(.createTask(input))
        try Self.throwIfBlocked(plan: plan, results: results)

        // Truthful only *after* the repository confirmed it. Reporting success
        // from the fact that a plan was made would announce a task that a
        // failed write had thrown away.
        let saved = try await repositories.tasks.tasks(matching: .outstanding)
        guard saved.contains(where: { $0.title == trimmed }) else {
            throw AssistantCommandError.operationFailed
        }

        return AssistantCommandOutcome(message: "Added “\(trimmed)” to your tasks.")
    }

    // MARK: Remember something

    /// Stores something the user explicitly asked to be remembered.
    ///
    /// Through `MemoryService`, so the duplicate detection, conflict handling
    /// and confidence assignment from the memory milestone all apply. Telling
    /// Siri something you already told the app does not produce a second copy.
    ///
    /// The source is `.user` — stated explicitly by the person, which is what
    /// a Shortcut called "Remember Something" is, and what makes it rank above
    /// something the assistant merely inferred.
    public func storeMemory(_ content: String) async throws -> AssistantCommandOutcome {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AssistantCommandError.validationFailed(reason: "There was nothing to remember.")
        }

        do {
            let result = try await memory.remember(
                MemoryItem(
                    kind: .fact,
                    content: trimmed,
                    createdAt: dateProvider.now,
                    source: .user
                )
            )
            return AssistantCommandOutcome(message: result.summary)
        } catch let error as MemoryServiceError {
            throw AssistantCommandError.validationFailed(reason: Self.describe(error))
        } catch {
            throw AssistantCommandError.operationFailed
        }
    }

    // MARK: Today

    /// The day, from stored data alone.
    ///
    /// No provider is consulted. "What's on today" is a question the
    /// repositories can answer exactly, and routing it through a language model
    /// would make a deterministic lookup depend on network, credentials and
    /// Apple Intelligence availability — three ways for it to fail at
    /// answering something the app already knows.
    public func today() async throws -> TodayBriefing {
        let now = dateProvider.now
        let calendar = dateProvider.calendar

        let tasks = try await repositories.tasks.tasks(matching: TaskFilter())
        let events = try await calendarEvents(around: now, calendar: calendar)
        let plans = try await reminderPlans(for: tasks)

        return TodayBriefingBuilder(now: now, calendar: calendar)
            .build(tasks: tasks, events: events, reminderPlans: plans)
    }

    /// A calendar the app cannot read produces a briefing without events rather
    /// than a failure — the tasks are still worth reporting.
    private func calendarEvents(around now: Date, calendar: Calendar) async throws -> [CalendarItem] {
        let window = TimeWindow(
            start: calendar.startOfDay(for: now),
            end: calendar.startOfDay(for: now).addingTimeInterval(TimeSpan.days(1))
        )
        return (try? await engine.calendarEvents(in: window)) ?? []
    }

    private func reminderPlans(for tasks: [TaskItem]) async throws -> [ReminderPlan] {
        var plans: [ReminderPlan] = []
        for task in tasks {
            guard let planID = task.reminderPlanID else { continue }
            if let plan = try await repositories.reminderPlans.plan(id: planID) {
                plans.append(plan)
            }
        }
        return plans
    }

    // MARK: Complete a task

    /// Marks a task done through the shared lifecycle.
    ///
    /// `FollowUpService.handle(outcome: .completed …)` — the same door the
    /// app's own Done button and the notification action use. That is what
    /// cancels the reminders still waiting, updates the plan and runs the
    /// status machine. Setting `status = .completed` here instead would leave
    /// the user being chased about something they had just told Siri they had
    /// finished.
    public func completeTask(id: TaskItem.ID) async throws -> AssistantCommandOutcome {
        guard let task = try await repositories.tasks.task(id: id) else {
            throw AssistantCommandError.itemNotFound
        }

        // Already resolved. Reported truthfully rather than reopened, and
        // rather than claiming to have just done it — a retried Shortcut must
        // not look like it completed the task a second time.
        guard task.status != .completed else {
            return AssistantCommandOutcome(
                message: "“\(task.title)” was already done.",
                didSucceed: false
            )
        }
        guard task.status != .cancelled else {
            return AssistantCommandOutcome(
                message: "“\(task.title)” was cancelled, so there's nothing to complete.",
                didSucceed: false
            )
        }

        do {
            let result = try await engine.followUp.handle(outcome: .completed, forTask: id)
            guard result.task.status == .completed else {
                throw AssistantCommandError.operationFailed
            }
            return AssistantCommandOutcome(message: "Marked “\(task.title)” done.")
        } catch let error as AssistantCommandError {
            throw error
        } catch {
            throw AssistantCommandError.operationFailed
        }
    }

    /// Tasks a system surface may offer for completion.
    ///
    /// Outstanding only. Offering someone a list of things they already
    /// finished, to finish again, is not a useful picker.
    public func selectableTasks(matching search: String? = nil) async throws -> [TaskItem] {
        let tasks = try await repositories.tasks.tasks(matching: .outstanding)
        guard let search = search?.trimmingCharacters(in: .whitespacesAndNewlines),
              !search.isEmpty
        else { return tasks }

        return tasks.filter { $0.title.localizedCaseInsensitiveContains(search) }
    }

    public func task(id: TaskItem.ID) async throws -> TaskItem? {
        try await repositories.tasks.task(id: id)
    }

    // MARK: Plumbing

    private func run(
        _ request: ToolRequest
    ) async throws -> (plan: AssistantActionPlan, results: [ToolResult]) {
        do {
            return try await engine.perform(request, origin: .user)
        } catch {
            throw AssistantCommandError.operationFailed
        }
    }

    /// Turns a blocked or failed action into the error the surface reports.
    ///
    /// The authorization and permission layers do their work by *not*
    /// executing; without this the command would return "Done" for something
    /// that was refused.
    private static func throwIfBlocked(
        plan: AssistantActionPlan,
        results: [ToolResult]
    ) throws {
        for result in results {
            switch result.outcome {
            case .executed, .simulated:
                continue
            case .awaitingConfirmation:
                throw AssistantCommandError.authorizationDenied(
                    reason: "That needs confirming in the app first."
                )
            case .denied(let reason):
                // Permission denials are phrased by capability, because
                // "calendar access is off" is actionable and "denied" is not.
                if let capability = Self.capability(mentionedIn: reason) {
                    throw AssistantCommandError.permissionDenied(capability: capability)
                }
                throw AssistantCommandError.authorizationDenied(reason: reason)
            case .failed, .unsupported:
                throw AssistantCommandError.operationFailed
            }
        }

        guard !plan.actions.isEmpty else {
            throw AssistantCommandError.operationFailed
        }
    }

    private static func capability(mentionedIn reason: String) -> PlatformCapability? {
        PlatformCapability.allCases.first { reason.contains($0.rawValue) }
    }

    // MARK: Wording

    /// Trims an answer to something Siri can say without becoming a monologue.
    ///
    /// Presentation only. The provider's own behaviour is untouched and the
    /// full reply is still persisted in the conversation — a system surface
    /// shortening what it reads aloud must not shorten what the app recorded.
    static func concise(_ text: String, results: [ToolResult]) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            // A turn that only performed actions still owes the user a
            // sentence, so the actions describe themselves.
            let performed = results.filter { $0.outcome.didChangeAnything }.map(\.message)
            return performed.first ?? "Done."
        }

        guard trimmed.count > 320 else { return trimmed }

        // Cut at a sentence boundary rather than mid-word.
        let prefix = trimmed.prefix(320)
        if let stop = prefix.lastIndex(where: { ".!?".contains($0) }) {
            return String(prefix[...stop])
        }
        return String(prefix) + "…"
    }

    private static func describe(_ error: ModelRoutingError) -> String {
        switch error {
        case .explicitProviderUnavailable(_, let reason):
            // The provider identifier is deliberately not read out. "apple.
            // foundation-models" means nothing to someone talking to Siri; the
            // reason is the part they can act on.
            return "The selected AI model isn't available right now. \(reason)"
        case .explicitProviderNotRegistered:
            return "The selected AI model isn't set up on this device."
        case .noProviderAvailable:
            return "No AI model is available right now."
        }
    }

    /// Provider failures, said in one line.
    ///
    /// Each case is phrased here rather than by interpolating the error's own
    /// payload: a transport or invalid-response string comes from a remote
    /// service and is not something to read aloud to someone. `missingCredentials`
    /// never carries the credential — but it is not repeated regardless.
    private static func describe(_ error: AIProviderError) -> String {
        switch error {
        case .missingCredentials:
            return "The selected AI model needs to be set up in the app first."
        case .unavailable, .notImplemented, .modelNotFound:
            return "The selected AI model isn't available right now."
        case .transport:
            return "I couldn't reach the AI model. Check your connection."
        case .invalidResponse:
            return "The AI model sent something I couldn't read."
        case .cancelled:
            return "That was cancelled."
        }
    }

    private static func describe(_ error: MemoryServiceError) -> String {
        switch error {
        case .emptyContent:
            return "There was nothing to remember."
        case .notFound:
            // Reachable only through restore, which Siri has no route to today.
            // Stated anyway rather than left to a `default`, so adding one later
            // is a compiler error instead of a sentence nobody wrote.
            return "I couldn't find that memory."
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
