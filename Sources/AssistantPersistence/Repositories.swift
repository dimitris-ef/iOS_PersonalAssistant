import AssistantDomain
import Foundation

public enum RepositoryError: Error, Hashable, Sendable {
    case notFound(String)
    case storageFailure(String)
}

/// Message history. Owned by the app, never by a provider.
public protocol ConversationRepository: Sendable {
    func conversation(id: Conversation.ID) async throws -> Conversation?
    func allConversations() async throws -> [Conversation]
    func save(_ conversation: Conversation) async throws
    func delete(id: Conversation.ID) async throws
}

/// Long-term personal memory.
public protocol MemoryRepository: Sendable {
    func store(_ item: MemoryItem) async throws
    func item(id: MemoryItem.ID) async throws -> MemoryItem?
    func all() async throws -> [MemoryItem]
    func search(_ query: MemoryQuery) async throws -> [MemoryItem]
    func delete(id: MemoryItem.ID) async throws
}

/// Things the user needs to do, and their engagement state.
public protocol TaskRepository: Sendable {
    func save(_ task: TaskItem) async throws
    func task(id: TaskItem.ID) async throws -> TaskItem?
    func tasks(matching filter: TaskFilter) async throws -> [TaskItem]
    func delete(id: TaskItem.ID) async throws
}

/// Generated reminder plans, kept so follow-up logic can consult the policies
/// that were in force when a plan was made.
public protocol ReminderPlanRepository: Sendable {
    func save(_ plan: ReminderPlan) async throws
    func plan(id: ReminderPlan.ID) async throws -> ReminderPlan?
    func plans(for reference: ReminderSubject.Reference) async throws -> [ReminderPlan]
}

public protocol SettingsRepository: Sendable {
    func settings() async throws -> AssistantSettings
    func update(_ settings: AssistantSettings) async throws
}

public protocol UserProfileRepository: Sendable {
    func profile() async throws -> UserProfile
    func update(_ profile: UserProfile) async throws
}

/// The full set of stores the assistant needs.
///
/// Bundled so swapping the storage backend (in-memory → file → SwiftData on
/// iOS) is one substitution at composition time.
public struct AssistantRepositories: Sendable {
    public let conversations: any ConversationRepository
    public let memories: any MemoryRepository
    public let tasks: any TaskRepository
    public let reminderPlans: any ReminderPlanRepository
    public let settings: any SettingsRepository
    public let profile: any UserProfileRepository

    public init(
        conversations: any ConversationRepository,
        memories: any MemoryRepository,
        tasks: any TaskRepository,
        reminderPlans: any ReminderPlanRepository,
        settings: any SettingsRepository,
        profile: any UserProfileRepository
    ) {
        self.conversations = conversations
        self.memories = memories
        self.tasks = tasks
        self.reminderPlans = reminderPlans
        self.settings = settings
        self.profile = profile
    }
}
