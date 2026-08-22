import AssistantDomain
import AssistantPersistence
import Foundation
import PersonalMemory

/// The application state a turn is reasoned about with.
///
/// Assembled fresh each turn and handed to the prompt builder and the planner.
/// Providers see only what the prompt builder chooses to render from this —
/// they never get repository handles.
public struct AssistantContext: Sendable {
    public var conversation: Conversation
    public var profile: UserProfile
    public var settings: AssistantSettings
    public var relevantMemories: [MemoryItem]
    public var outstandingTasks: [TaskItem]
    public var upcomingEvents: [CalendarItem]
    /// False when the calendar could not be read at all.
    ///
    /// Exists because an empty `upcomingEvents` has two very different causes
    /// and only one of them is "your week is clear". If the user has not
    /// granted calendar access — or has granted add-only access — the list is
    /// also empty, and an assistant that cannot tell those apart will cheerfully
    /// agree to a two o'clock meeting on top of an existing one.
    ///
    /// The prompt says which it is, so the model can hedge instead of inventing
    /// confidence it has no basis for.
    public var calendarIsReadable: Bool
    public var now: Date
    public var calendar: Calendar

    public init(
        conversation: Conversation,
        profile: UserProfile,
        settings: AssistantSettings,
        relevantMemories: [MemoryItem],
        outstandingTasks: [TaskItem],
        upcomingEvents: [CalendarItem],
        calendarIsReadable: Bool = true,
        now: Date,
        calendar: Calendar
    ) {
        self.conversation = conversation
        self.profile = profile
        self.settings = settings
        self.relevantMemories = relevantMemories
        self.outstandingTasks = outstandingTasks
        self.upcomingEvents = upcomingEvents
        self.calendarIsReadable = calendarIsReadable
        self.now = now
        self.calendar = calendar
    }
}

/// Gathers the context for a turn from the repositories and the calendar.
///
/// Orchestration only. Deciding *which* memories matter is a judgement about
/// relevance and belongs to ``MemoryRetrievalService``; this decides what kinds
/// of thing a turn needs at all.
public struct ContextAssembler: Sendable {
    private let repositories: AssistantRepositories
    private let dateProvider: any DateProvider
    private let upcomingWindow: TimeInterval
    private let memories: MemoryRetrievalService

    /// `encoder` is optional and stays that way.
    ///
    /// Semantic retrieval is an improvement to ranking, not a dependency of it.
    /// A composition that passes nothing here — a test, a preview, a platform
    /// with no encoder — gets lexical ranking and a working assistant, which is
    /// exactly what section 5 asks for and is why this parameter has a default.
    ///
    /// Note what is *not* a parameter: which AI provider is selected. Nothing
    /// about memory retrieval reads it.
    public init(
        repositories: AssistantRepositories,
        dateProvider: any DateProvider,
        upcomingWindow: TimeInterval = TimeSpan.days(14),
        memoryPolicy: MemoryRelevancePolicy = .default,
        semanticEncoder: (any SemanticEncoder)? = nil
    ) {
        self.repositories = repositories
        self.dateProvider = dateProvider
        self.upcomingWindow = upcomingWindow
        self.memories = MemoryRetrievalService(
            repository: repositories.memories,
            relations: repositories.memoryRelations,
            embeddings: repositories.memoryEmbeddings,
            encoder: semanticEncoder,
            policy: memoryPolicy
        )
    }

    public func assemble(
        conversation: Conversation,
        query: String,
        calendarEvents: [CalendarItem],
        calendarIsReadable: Bool = true
    ) async throws -> AssistantContext {
        let now = dateProvider.now
        let settings = try await repositories.settings.settings()
        let profile = try await repositories.profile.profile()

        // Ranked against this request, then cut to what is actually relevant.
        // Not every memory the user has: a question about a bill has no
        // business carrying their camera preference, and a prompt that grows
        // with the length of someone's history gets worse the longer they use
        // the app.
        //
        // The retrieval service applies its own maximum and relevance
        // threshold; `memoryContextLimit` is the user's ceiling on top of that,
        // so lowering it in settings tightens the selection and raising it can
        // never loosen the threshold.
        let relevantMemories = try await memories.relevantMemories(
            for: query,
            now: now,
            limit: settings.memoryContextLimit
        )
        let tasks = try await repositories.tasks.tasks(
            matching: TaskFilter(
                statuses: Set(TaskStatus.allCases.filter(\.isOutstanding)),
                limit: 20
            )
        )

        return AssistantContext(
            conversation: conversation,
            profile: profile,
            settings: settings,
            relevantMemories: relevantMemories,
            outstandingTasks: tasks,
            upcomingEvents: calendarEvents,
            calendarIsReadable: calendarIsReadable,
            now: now,
            calendar: dateProvider.calendar
        )
    }

    public var window: TimeWindow {
        let now = dateProvider.now
        return TimeWindow(start: now, end: now.addingTimeInterval(upcomingWindow))
    }
}
