import AssistantDomain
import Foundation

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

    /// Keyword-overlap scoring. Crude on purpose: retrieval quality is a
    /// separate problem, and this keeps the seam where a better implementation
    /// (embeddings, on-device index) will slot in.
    public func search(_ query: MemoryQuery) async throws -> [MemoryItem] {
        try await loadIfNeeded()

        var candidates = Array(items.values)
        if !query.kinds.isEmpty {
            candidates = candidates.filter { query.kinds.contains($0.kind) }
        }
        if !query.tags.isEmpty {
            let wanted = Set(query.tags.map { $0.lowercased() })
            candidates = candidates.filter { !wanted.isDisjoint(with: Set($0.tags.map { $0.lowercased() })) }
        }

        // Keyword overlap ranks the results, but salience keeps every memory
        // eligible: an unrelated question should still surface what the
        // assistant knows, just lower down.
        let terms = Self.terms(in: query.text ?? "")
        let scored = candidates.map { item -> (item: MemoryItem, score: Double) in
            let itemTerms = Self.terms(in: item.content).union(Set(item.tags.map { $0.lowercased() }))
            let overlap = terms.isEmpty
                ? 0
                : Double(terms.intersection(itemTerms).count) / Double(terms.count)
            return (item, overlap + item.salience * 0.25)
        }

        return scored
            .sorted { lhs, rhs in
                lhs.score == rhs.score ? lhs.item.createdAt > rhs.item.createdAt : lhs.score > rhs.score
            }
            .prefix(query.limit)
            .map(\.item)
    }

    public func delete(id: MemoryItem.ID) async throws {
        try await loadIfNeeded()
        items.removeValue(forKey: id)
        try await persist()
    }

    private static func terms(in text: String) -> Set<String> {
        let separators = CharacterSet.alphanumerics.inverted
        let parts = text.lowercased().components(separatedBy: separators)
        // Two-character words carry almost no signal here.
        return Set(parts.filter { $0.count > 2 })
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
            profile: SnapshotUserProfileRepository(store: store)
        )
    }

    /// In-memory repositories, for tests.
    public static func ephemeral() -> AssistantRepositories {
        snapshot(store: EphemeralSnapshotStore())
    }
}
