import AssistantDomain
import Foundation
import PersonalMemory

// Repository implementations that keep their working set in memory and write a
// JSON snapshot through a `SnapshotStore` after every change.
//
// One implementation covers both the ephemeral case (tests) and the persisted
// case (the dev harness) by varying only the store. These are correct but not
// scalable — the iOS build will replace them with a real database.

private enum SnapshotKey {
    static let conversations = "conversations"
    static let memories = "memories"
    static let tasks = "tasks"
    static let reminderPlans = "reminder-plans"
    static let settings = "settings"
    static let profile = "profile"
}

public actor SnapshotConversationRepository: ConversationRepository {
    private let store: any SnapshotStore
    private var conversations: [Conversation.ID: Conversation] = [:]
    private var isLoaded = false

    public init(store: any SnapshotStore) {
        self.store = store
    }

    public func conversation(id: Conversation.ID) async throws -> Conversation? {
        try await loadIfNeeded()
        return conversations[id]
    }

    public func allConversations() async throws -> [Conversation] {
        try await loadIfNeeded()
        return conversations.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func save(_ conversation: Conversation) async throws {
        try await loadIfNeeded()
        conversations[conversation.id] = conversation
        try await persist()
    }

    public func delete(id: Conversation.ID) async throws {
        try await loadIfNeeded()
        conversations.removeValue(forKey: id)
        try await persist()
    }

    private func loadIfNeeded() async throws {
        guard !isLoaded else { return }
        isLoaded = true
        guard let data = try await store.read(key: SnapshotKey.conversations) else { return }
        let decoded = try JSONCoding.decoder.decode([Conversation].self, from: data)
        conversations = Dictionary(uniqueKeysWithValues: decoded.map { ($0.id, $0) })
    }

    private func persist() async throws {
        let data = try JSONCoding.encoder.encode(Array(conversations.values))
        try await store.write(data, key: SnapshotKey.conversations)
    }
}

public actor SnapshotMemoryRepository: MemoryRepository {
    private let backing: any SnapshotStore
    private var items: [MemoryItem.ID: MemoryItem] = [:]
    private var isLoaded = false

    public init(store: any SnapshotStore) {
        self.backing = store
    }

    public func store(_ item: MemoryItem) async throws {
        try await loadIfNeeded()
        items[item.id] = item
        try await persist()
    }

    public func item(id: MemoryItem.ID) async throws -> MemoryItem? {
        try await loadIfNeeded()
        return items[id]
    }

    public func all() async throws -> [MemoryItem] {
        try await loadIfNeeded()
        return items.values.sorted { $0.createdAt < $1.createdAt }
    }

    /// Ranking lives in `MemoryRanker` so every backend answers this question
    /// identically — and so improving retrieval improves it everywhere at once.
    public func search(_ query: MemoryQuery) async throws -> [MemoryItem] {
        try await loadIfNeeded()
        return MemoryRanker().rank(Array(items.values), query: query)
    }

    public func delete(id: MemoryItem.ID) async throws {
        try await loadIfNeeded()
        items.removeValue(forKey: id)
        try await persist()
    }

    private func loadIfNeeded() async throws {
        guard !isLoaded else { return }
        isLoaded = true
        guard let data = try await backing.read(key: SnapshotKey.memories) else { return }
        let decoded = try JSONCoding.decoder.decode([MemoryItem].self, from: data)
        items = Dictionary(uniqueKeysWithValues: decoded.map { ($0.id, $0) })
    }

    private func persist() async throws {
        let data = try JSONCoding.encoder.encode(Array(items.values))
        try await backing.write(data, key: SnapshotKey.memories)
    }
}

public actor SnapshotTaskRepository: TaskRepository {
    private let store: any SnapshotStore
    private var storage: [TaskItem.ID: TaskItem] = [:]
    private var isLoaded = false

    public init(store: any SnapshotStore) {
        self.store = store
    }

    public func save(_ task: TaskItem) async throws {
        try await loadIfNeeded()
        storage[task.id] = task
        try await persist()
    }

    public func task(id: TaskItem.ID) async throws -> TaskItem? {
        try await loadIfNeeded()
        return storage[id]
    }

    public func tasks(matching filter: TaskFilter) async throws -> [TaskItem] {
        try await loadIfNeeded()
        let matched = storage.values
            .filter(filter.matches)
            .sorted { lhs, rhs in
                let left = lhs.timing.anchorDate ?? lhs.deadline ?? Date.distantFuture
                let right = rhs.timing.anchorDate ?? rhs.deadline ?? Date.distantFuture
                return left < right
            }
        guard let limit = filter.limit else { return matched }
        return Array(matched.prefix(limit))
    }

    public func delete(id: TaskItem.ID) async throws {
        try await loadIfNeeded()
        storage.removeValue(forKey: id)
        try await persist()
    }

    private func loadIfNeeded() async throws {
        guard !isLoaded else { return }
        isLoaded = true
        guard let data = try await store.read(key: SnapshotKey.tasks) else { return }
        let decoded = try JSONCoding.decoder.decode([TaskItem].self, from: data)
        storage = Dictionary(uniqueKeysWithValues: decoded.map { ($0.id, $0) })
    }

    private func persist() async throws {
        let data = try JSONCoding.encoder.encode(Array(storage.values))
        try await store.write(data, key: SnapshotKey.tasks)
    }
}

public actor SnapshotReminderPlanRepository: ReminderPlanRepository {
    private let store: any SnapshotStore
    private var storage: [ReminderPlan.ID: ReminderPlan] = [:]
    private var isLoaded = false

    public init(store: any SnapshotStore) {
        self.store = store
    }

    public func save(_ plan: ReminderPlan) async throws {
        try await loadIfNeeded()
        storage[plan.id] = plan
        try await persist()
    }

    public func plan(id: ReminderPlan.ID) async throws -> ReminderPlan? {
        try await loadIfNeeded()
        return storage[id]
    }

    public func plans(for reference: ReminderSubject.Reference) async throws -> [ReminderPlan] {
        try await loadIfNeeded()
        return storage.values
            .filter { $0.subject.reference == reference }
            .sorted { $0.createdAt < $1.createdAt }
    }

    private func loadIfNeeded() async throws {
        guard !isLoaded else { return }
        isLoaded = true
        guard let data = try await store.read(key: SnapshotKey.reminderPlans) else { return }
        let decoded = try JSONCoding.decoder.decode([ReminderPlan].self, from: data)
        storage = Dictionary(uniqueKeysWithValues: decoded.map { ($0.id, $0) })
    }

    private func persist() async throws {
        let data = try JSONCoding.encoder.encode(Array(storage.values))
        try await store.write(data, key: SnapshotKey.reminderPlans)
    }
}

public actor SnapshotSettingsRepository: SettingsRepository {
    private let store: any SnapshotStore
    private var cached: AssistantSettings?

    public init(store: any SnapshotStore) {
        self.store = store
    }

    public func settings() async throws -> AssistantSettings {
        if let cached { return cached }
        guard let data = try await store.read(key: SnapshotKey.settings) else {
            let defaults = AssistantSettings()
            cached = defaults
            return defaults
        }
        let decoded = try JSONCoding.decoder.decode(AssistantSettings.self, from: data)
        cached = decoded
        return decoded
    }

    public func update(_ settings: AssistantSettings) async throws {
        cached = settings
        let data = try JSONCoding.encoder.encode(settings)
        try await store.write(data, key: SnapshotKey.settings)
    }
}

public actor SnapshotUserProfileRepository: UserProfileRepository {
    private let store: any SnapshotStore
    private var cached: UserProfile?

    public init(store: any SnapshotStore) {
        self.store = store
    }

    public func profile() async throws -> UserProfile {
        if let cached { return cached }
        guard let data = try await store.read(key: SnapshotKey.profile) else {
            let defaults = UserProfile()
            cached = defaults
            return defaults
        }
        let decoded = try JSONCoding.decoder.decode(UserProfile.self, from: data)
        cached = decoded
        return decoded
    }

    public func update(_ profile: UserProfile) async throws {
        cached = profile
        let data = try JSONCoding.encoder.encode(profile)
        try await store.write(data, key: SnapshotKey.profile)
    }
}

extension AssistantRepositories {
    /// All repositories backed by one store.
    public static func snapshot(store: any SnapshotStore) -> AssistantRepositories {
        AssistantRepositories(
            conversations: SnapshotConversationRepository(store: store),
            memories: SnapshotMemoryRepository(store: store),
            tasks: SnapshotTaskRepository(store: store),
            reminderPlans: SnapshotReminderPlanRepository(store: store),
            settings: SnapshotSettingsRepository(store: store),
            profile: SnapshotUserProfileRepository(store: store),
            actionPlans: SnapshotActionPlanRepository(store: store)
        )
    }

    /// In-memory repositories.
    ///
    /// Still the right choice for tests, SwiftUI previews, deterministic
    /// screenshots and the dev harness — anywhere a clean, disposable store is
    /// what you want. It is no longer what the shipping app runs on: see
    /// `AssistantRepositories.persistent(...)` in `AssistantPersistenceSwiftData`.
    public static func ephemeral() -> AssistantRepositories {
        snapshot(store: EphemeralSnapshotStore())
    }
}
