import AssistantDomain
import Foundation
import PersonalMemory

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

/// Typed links between memories.
///
/// Separate from ``MemoryRepository`` because edges and nodes have different
/// lifetimes: deleting a memory removes its edges, but editing one does not, and
/// consolidation writes edges without writing every memory they touch. Folding
/// them together would mean a relation could only be saved by saving a memory.
public protocol MemoryRelationRepository: Sendable {
    /// Insert or update. Relation identity is derived from source, target and
    /// type, so writing the same edge twice updates one row — which is what
    /// makes repeated maintenance passes idempotent.
    func save(_ relations: [MemoryRelation]) async throws
    /// Every edge touching this memory, in either direction.
    func relations(for memoryID: MemoryItem.ID) async throws -> [MemoryRelation]
    func all() async throws -> [MemoryRelation]
    /// Removes every edge touching this memory. Called when one is deleted, so
    /// the graph never points at something that is gone.
    func deleteRelations(touching memoryID: MemoryItem.ID) async throws
}

/// Cached embeddings for memories.
///
/// ## Why this is a cache and not a column
///
/// A vector is derived data: it can always be recomputed from the text that
/// produced it. Treating it as durable state would put a kilobyte of floats on
/// the domain model, through `Codable`, through every test fixture and every
/// SwiftUI update, for one subsystem's benefit — and would still need
/// invalidating whenever the text or the encoder changed. Storing it beside the
/// memories, keyed by content hash and encoder identity, keeps the domain clean
/// and makes "is this still valid?" a question with a real answer.
///
/// Losing this store costs time, never information: the next retrieval finds
/// nothing cached, falls back to lexical ranking, and maintenance regenerates.
public protocol MemoryEmbeddingStore: Sendable {
    func embedding(for memoryID: MemoryItem.ID) async throws -> MemoryEmbedding?
    func embeddings(for memoryIDs: [MemoryItem.ID]) async throws -> [MemoryItem.ID: MemoryEmbedding]
    func store(_ embedding: MemoryEmbedding, for memoryID: MemoryItem.ID) async throws
    /// Drops one vector — after an edit, or when the memory is deleted.
    func invalidate(memoryID: MemoryItem.ID) async throws
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

/// Recurring responsibilities.
///
/// Separate from `TaskRepository` because a routine and one of its occurrences
/// are different things asked different questions: "which routines are still
/// active" is a routine query, "what is outstanding today" is a task one. The
/// occurrences themselves live in `TaskRepository` like everything else, which
/// is what lets them use the whole existing lifecycle.
public protocol RoutineRepository: Sendable {
    func save(_ routine: Routine) async throws
    func routine(id: Routine.ID) async throws -> Routine?
    /// Every routine, newest first. `activeOnly` is the common case — occurrence
    /// generation has no interest in paused ones.
    func routines(activeOnly: Bool) async throws -> [Routine]
    func delete(id: Routine.ID) async throws
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
    /// Typed links between memories: what supports what, what refines what.
    public let memoryRelations: any MemoryRelationRepository
    /// Cached vectors. Derived data — losing it costs time, never information.
    public let memoryEmbeddings: any MemoryEmbeddingStore
    public let tasks: any TaskRepository
    public let routines: any RoutineRepository
    public let reminderPlans: any ReminderPlanRepository
    public let settings: any SettingsRepository
    public let profile: any UserProfileRepository
    /// What the assistant did, so a loaded conversation still shows its cards.
    public let actionPlans: any ActionPlanRepository

    public init(
        conversations: any ConversationRepository,
        memories: any MemoryRepository,
        memoryRelations: any MemoryRelationRepository,
        memoryEmbeddings: any MemoryEmbeddingStore,
        tasks: any TaskRepository,
        routines: any RoutineRepository,
        reminderPlans: any ReminderPlanRepository,
        settings: any SettingsRepository,
        profile: any UserProfileRepository,
        actionPlans: any ActionPlanRepository
    ) {
        self.conversations = conversations
        self.memories = memories
        self.memoryRelations = memoryRelations
        self.memoryEmbeddings = memoryEmbeddings
        self.tasks = tasks
        self.routines = routines
        self.reminderPlans = reminderPlans
        self.settings = settings
        self.profile = profile
        self.actionPlans = actionPlans
    }
}
