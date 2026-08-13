import AssistantDomain
import AssistantPersistence
import Foundation

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
public struct ContextAssembler: Sendable {
    private let repositories: AssistantRepositories
    private let dateProvider: any DateProvider
    private let upcomingWindow: TimeInterval

    public init(
        repositories: AssistantRepositories,
        dateProvider: any DateProvider,
        upcomingWindow: TimeInterval = TimeSpan.days(14)
    ) {
        self.repositories = repositories
        self.dateProvider = dateProvider
        self.upcomingWindow = upcomingWindow
    }

    public func assemble(
        conversation: Conversation,
        query: String,
        calendarEvents: [CalendarItem]
    ) async throws -> AssistantContext {
        let now = dateProvider.now
        let settings = try await repositories.settings.settings()
        let profile = try await repositories.profile.profile()

        let memories = try await repositories.memories.search(
            MemoryQuery(text: query, limit: settings.memoryContextLimit)
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
            relevantMemories: memories,
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
