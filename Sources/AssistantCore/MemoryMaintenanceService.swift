import AssistantDomain
import AssistantPersistence
import Foundation
import PersonalMemory

/// What one maintenance pass did.
///
/// Counts only. Section 109: a maintenance log that names the memories it
/// touched is a log containing the most personal thing this app holds.
public struct MemoryMaintenanceReport: Hashable, Sendable {
    /// Vectors generated for memories that had none, or whose text had changed.
    public var embeddingsGenerated: Int
    /// Clusters collapsed into a single fact.
    public var consolidations: Int
    /// Memories superseded by a consolidation.
    public var superseded: Int
    /// Memories that stopped being retrieved.
    public var madeStale: Int
    /// Memories filed away.
    public var archived: Int
    /// Memories that came back — used recently enough to be worth keeping.
    public var revived: Int
    /// Edges written or refreshed.
    public var relationsWritten: Int

    public init(
        embeddingsGenerated: Int = 0,
        consolidations: Int = 0,
        superseded: Int = 0,
        madeStale: Int = 0,
        archived: Int = 0,
        revived: Int = 0,
        relationsWritten: Int = 0
    ) {
        self.embeddingsGenerated = embeddingsGenerated
        self.consolidations = consolidations
        self.superseded = superseded
        self.madeStale = madeStale
        self.archived = archived
        self.revived = revived
        self.relationsWritten = relationsWritten
    }

    public var didChangeAnything: Bool {
        embeddingsGenerated > 0 || consolidations > 0 || superseded > 0
            || madeStale > 0 || archived > 0 || revived > 0 || relationsWritten > 0
    }
}

/// Keeps the memory store tidy: vectors current, repeated facts collapsed,
/// stale guesses out of the way.
///
/// ## Why it is a service and not a side effect
///
/// Because none of it belongs anywhere else. `ContextAssembler` assembles
/// context; making it also decide that three commute memories should become one
/// would put a write path inside a read path. A SwiftUI view has no business
/// archiving anything. And an AI provider must never touch memory at all — the
/// whole design is that the application owns recall.
///
/// ## Everything here is deterministic
///
/// Consolidation, conflict resolution and aging are functions of stored metadata
/// plus configured policy plus the clock. No model is consulted. That buys four
/// things at once: it runs offline, it costs nothing, it is testable without a
/// network, and it behaves identically whichever conversational provider the
/// user has selected — which is section 93, and the reason memory behaviour does
/// not change when the AI does.
///
/// ## Safe to run twice
///
/// Every operation is idempotent, and by construction rather than by checking:
///
/// - **Embeddings** are keyed by content hash and encoder identity, so a second
///   pass finds them valid and does nothing.
/// - **Consolidation** excludes consolidated memories and superseded sources, so
///   after one pass there is nothing left to cluster. Section 100's runaway —
///   A+B→C, C+A→D — cannot be expressed.
/// - **Aging** is a pure function of the memory and the clock, so it reaches the
///   same conclusion and writes nothing when it already holds.
/// - **Relations** have derived identities, so writing the same edge updates one
///   row.
public struct MemoryMaintenanceService: Sendable {
    private let repositories: AssistantRepositories
    private let encoder: (any SemanticEncoder)?
    private let consolidator: MemoryConsolidator
    private let aging: MemoryAgingPolicy
    private let dateProvider: any DateProvider

    /// The most memories one pass may encode.
    ///
    /// Maintenance runs opportunistically — on foreground, after a write — and
    /// must never become the reason a launch is slow. What it does not finish,
    /// the next pass picks up, and retrieval fills in what it needs meanwhile.
    public var embeddingBudget: Int

    public init(
        repositories: AssistantRepositories,
        encoder: (any SemanticEncoder)? = nil,
        consolidator: MemoryConsolidator = MemoryConsolidator(),
        aging: MemoryAgingPolicy = .default,
        embeddingBudget: Int = 40,
        dateProvider: any DateProvider = SystemDateProvider()
    ) {
        self.repositories = repositories
        self.encoder = encoder
        self.consolidator = consolidator
        self.aging = aging
        self.embeddingBudget = embeddingBudget
        self.dateProvider = dateProvider
    }

    /// One full pass: vectors, then consolidation, then aging.
    ///
    /// The order matters. Consolidation reads vectors, so they are brought up to
    /// date first; aging reads what consolidation produced, so it runs last and
    /// sees a consolidated fact rather than the three memories it replaced.
    @discardableResult
    public func run() async throws -> MemoryMaintenanceReport {
        var report = MemoryMaintenanceReport()
        report.embeddingsGenerated = try await backfillEmbeddings()

        let consolidation = try await consolidate()
        report.consolidations = consolidation.consolidations
        report.superseded = consolidation.superseded
        report.relationsWritten = consolidation.relationsWritten

        let aged = try await applyAging()
        report.madeStale = aged.madeStale
        report.archived = aged.archived
        report.revived = aged.revived

        return report
    }

    // MARK: Embeddings

    /// Generates vectors for memories that have none or whose text has changed.
    ///
    /// This is also where an encoder upgrade is absorbed. Bumping
    /// ``SemanticEncoderIdentity/version`` invalidates every stored vector at a
    /// stroke — they are no longer *valid for* the configured encoder — and they
    /// are regenerated here, a budget at a time, while retrieval carries on with
    /// whatever mixture of fresh vectors and lexical matching it has. Nobody's
    /// memories are deleted and no launch is blocked; section 11 and 73.
    @discardableResult
    public func backfillEmbeddings() async throws -> Int {
        guard let encoder else { return 0 }
        guard await encoder.isAvailable else { return 0 }

        let memories = try await repositories.memories.all()
            .filter { $0.lifecycle == .active || $0.lifecycle == .stale }
        guard !memories.isEmpty else { return 0 }

        let store = repositories.memoryEmbeddings
        let stored = (try? await store.embeddings(for: memories.map(\.id))) ?? [:]

        var generated = 0
        for memory in memories where generated < embeddingBudget {
            let hash = MemoryContentHash.hash(memory.content)
            if let cached = stored[memory.id],
               cached.isValid(for: hash, encoder: encoder.identity) {
                continue
            }
            guard let vector = try? await encoder.embedding(for: memory.content), !vector.isEmpty
            else { continue }
            try? await store.store(
                MemoryEmbedding(
                    memoryID: memory.id.rawValue,
                    vector: vector,
                    encoder: encoder.identity,
                    contentHash: hash,
                    createdAt: dateProvider.now
                ),
                for: memory.id
            )
            generated += 1
        }
        return generated
    }

    // MARK: Consolidation

    @discardableResult
    public func consolidate() async throws -> (
        consolidations: Int, superseded: Int, relationsWritten: Int
    ) {
        let memories = try await repositories.memories.all()
        guard memories.count >= consolidator.minimumClusterSize else { return (0, 0, 0) }

        let vectors = await validVectors(for: memories)
        let plans = consolidator.consolidations(
            among: memories,
            vectors: vectors,
            now: dateProvider.now
        )
        guard !plans.isEmpty else { return (0, 0, 0) }

        var relationCount = 0
        for plan in plans {
            // The surviving fact first. If the process died between these two
            // writes the sources would still be active, which is a duplicate —
            // recoverable. The other order would leave them superseded with
            // nothing to replace them, which is a memory quietly disappearing.
            try await repositories.memories.store(plan.consolidated)
            for source in plan.superseded {
                try await repositories.memories.store(source)
            }
            try await repositories.memoryRelations.save(plan.relations)
            relationCount += plan.relations.count
        }

        return (plans.count, plans.reduce(0) { $0 + $1.superseded.count }, relationCount)
    }

    // MARK: Aging

    @discardableResult
    public func applyAging() async throws -> (madeStale: Int, archived: Int, revived: Int) {
        let memories = try await repositories.memories.all()
        guard !memories.isEmpty else { return (0, 0, 0) }

        let protectedKeys = try await activeRoutineEntityKeys()
        let now = dateProvider.now

        var madeStale = 0
        var archived = 0
        var revived = 0

        for memory in memories {
            let decision = aging.decide(
                for: memory,
                now: now,
                protectedEntityKeys: protectedKeys
            )
            guard decision.changesAnything else { continue }

            var updated = memory
            updated.lifecycle = decision.lifecycle
            // Deliberately *not* touching `updatedAt`. Aging is the app's own
            // bookkeeping, not a change to what the memory says, and stamping it
            // would reset the very clock the next pass measures — a memory would
            // become stale, look freshly modified, and never reach archived.
            try await repositories.memories.store(updated)

            switch decision.lifecycle {
            case .stale: madeStale += 1
            case .archived: archived += 1
            case .active: revived += 1
            case .superseded, .conflicting: break
            }
        }

        return (madeStale, archived, revived)
    }

    // MARK: Support

    private func validVectors(
        for memories: [MemoryItem]
    ) async -> [MemoryItem.ID: SemanticVector] {
        guard let encoder else { return [:] }
        guard
            let stored = try? await repositories.memoryEmbeddings.embeddings(
                for: memories.map(\.id)
            )
        else { return [:] }

        var valid: [MemoryItem.ID: SemanticVector] = [:]
        for memory in memories {
            guard
                let cached = stored[memory.id],
                cached.isValid(
                    for: MemoryContentHash.hash(memory.content),
                    encoder: encoder.identity
                )
            else { continue }
            valid[memory.id] = cached.vector
        }
        return valid
    }

    /// Entity keys belonging to things the user still does.
    ///
    /// Section 85: a memory that supports a live routine is load-bearing however
    /// old it is. The commute time behind an active "leave for work" routine is
    /// exactly the kind of long-standing fact naive aging would throw away.
    private func activeRoutineEntityKeys() async throws -> Set<String> {
        let routines = try await repositories.routines.routines(activeOnly: true)
        guard !routines.isEmpty else { return [] }
        var keys: Set<String> = []
        for routine in routines {
            keys.formUnion(
                MemoryEntityExtractor.keys(for: routine.title, kind: .routine)
            )
            if let details = routine.details {
                keys.formUnion(MemoryEntityExtractor.keys(for: details, kind: .routine))
            }
        }
        return keys
    }
}
