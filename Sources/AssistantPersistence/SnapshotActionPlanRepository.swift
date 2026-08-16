import AssistantDomain
import AssistantTools
import Foundation

/// Snapshot-backed action plan storage.
///
/// Exists so the ephemeral and JSON backends keep feature parity with the
/// SwiftData one: a test or the dev harness sees the same behaviour the app
/// sees, and a repository swap cannot quietly change what survives.
public actor SnapshotActionPlanRepository: ActionPlanRepository {
    private static let key = "action-plans"

    private let store: any SnapshotStore
    private var storage: [ActionPlanID: StoredActionPlan] = [:]
    private var isLoaded = false

    public init(store: any SnapshotStore) {
        self.store = store
    }

    public func save(_ record: ActionPlanRecord) async throws {
        try await loadIfNeeded()
        storage[record.plan.id] = StoredActionPlan(record)
        try await persist()
    }

    public func record(id: ActionPlanID) async throws -> ActionPlanRecord? {
        try await loadIfNeeded()
        return storage[id]?.record
    }

    public func records(inConversation id: Conversation.ID) async throws -> [ActionPlanRecord] {
        try await loadIfNeeded()
        return storage.values
            .filter { $0.conversationID == id }
            .sorted { $0.createdAt < $1.createdAt }
            .map(\.record)
    }

    private func loadIfNeeded() async throws {
        guard !isLoaded else { return }
        isLoaded = true
        guard let data = try await store.read(key: Self.key) else { return }
        let decoded = try JSONCoding.decoder.decode([StoredActionPlan].self, from: data)
        storage = Dictionary(decoded.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func persist() async throws {
        let data = try JSONCoding.encoder.encode(Array(storage.values))
        try await store.write(data, key: Self.key)
    }
}

/// The JSON shape of a stored plan.
///
/// A separate type rather than `Codable` on `AssistantActionPlan` itself,
/// because the domain type carries `rejected`, which is turn-scoped diagnostics
/// and deliberately not persisted — see `ActionPlanRepository`. Keeping the
/// on-disk shape its own type makes that omission explicit instead of hiding it
/// behind custom coding keys.
struct StoredActionPlan: Codable, Sendable {
    var id: ActionPlanID
    var conversationID: Conversation.ID
    var createdAt: Date
    var actions: [AssistantAction]
    var results: [ToolResult]

    init(_ record: ActionPlanRecord) {
        self.id = record.plan.id
        self.conversationID = record.conversationID
        self.createdAt = record.plan.createdAt
        self.actions = record.plan.actions
        self.results = record.results
    }

    var record: ActionPlanRecord {
        ActionPlanRecord(
            plan: AssistantActionPlan(id: id, actions: actions, createdAt: createdAt),
            results: results,
            conversationID: conversationID
        )
    }
}
