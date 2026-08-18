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
    public var now: Date
    public var calendar: Calendar

    public init(
        conversation: Conversation,
        profile: UserProfile,
        settings: AssistantSettings,
        relevantMemories: [MemoryItem],
        outstandingTasks: [TaskItem],
        upcomingEvents: [CalendarItem],
        now: Date,
        calendar: Calendar
    ) {
        self.conversation = conversation
        self.profile = profile
        self.settings = settings
        self.relevantMemories = relevantMemories
        self.outstandingTasks = outstandingTasks
        self.upcomingEvents = upcomingEvents
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

    public init(
        repositories: AssistantRepositories,
        dateProvider: any DateProvider,
        upcomingWindow: TimeInterval = TimeSpan.days(14),
        memoryPolicy: MemoryRelevancePolicy = .default
    ) {
        self.repositories = repositories
        self.dateProvider = dateProvider
        self.upcomingWindow = upcomingWindow
        self.memories = MemoryRetrievalService(
            repository: repositories.memories,
            policy: memoryPolicy
        )
    }

    public func assemble(
        conversation: Conversation,
        query: String,
        calendarEvents: [CalendarItem]
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
            now: now,
            calendar: dateProvider.calendar
        )
    }

    public var window: TimeWindow {
        let now = dateProvider.now
        return TimeWindow(start: now, end: now.addingTimeInterval(upcomingWindow))
    }
}
