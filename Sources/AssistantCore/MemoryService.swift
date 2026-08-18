import AssistantDomain
import AssistantPersistence
import Foundation
import PersonalMemory

/// What happened when a memory was offered to the store.
public struct MemoryWriteResult: Sendable {
    public enum Effect: Hashable, Sendable {
        case stored
        /// Folded into an existing record; no second row.
        case merged(into: MemoryItem.ID)
        /// An existing record was corrected.
        case replaced(MemoryItem.ID)
        /// Kept alongside a memory it disagrees with.
        case keptAlongsideConflict(with: MemoryItem.ID)
    }

    public var memory: MemoryItem
    public var effect: Effect
    /// One line for the user or the transcript.
    public var summary: String

    public init(memory: MemoryItem, effect: Effect, summary: String) {
        self.memory = memory
        self.effect = effect
        self.summary = summary
    }
}

/// The one way a memory gets written.
///
/// Deduplication has to live behind a single door or it does not exist: put it
/// in the `storeMemory` tool and the Memory screen creates duplicates; put it
/// in the screen and the assistant does. Both go through here.
///
/// Separate from retrieval on purpose. Writing is about trust, duplication and
/// conflict; reading is about relevance and budget. They change for different
/// reasons and share nothing but the repository.
public struct MemoryService: Sendable {
    private let repository: any MemoryRepository
    private let deduplicator: MemoryDeduplicator
    private let dateProvider: any DateProvider

    public init(
        repository: any MemoryRepository,
        deduplicator: MemoryDeduplicator = MemoryDeduplicator(),
        dateProvider: any DateProvider = SystemDateProvider()
    ) {
        self.repository = repository
        self.deduplicator = deduplicator
        self.dateProvider = dateProvider
    }

    /// Offers a memory to the store, deduplicating and resolving conflicts.
    @discardableResult
    public func remember(_ candidate: MemoryItem) async throws -> MemoryWriteResult {
        let content = candidate.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            throw MemoryServiceError.emptyContent
        }

        var candidate = candidate
        candidate.content = content

        let now = dateProvider.now
        let existing = try await repository.all()

        switch deduplicator.classify(candidate, against: existing) {
        case .distinct:
            try await repository.store(candidate)
            return MemoryWriteResult(
                memory: candidate,
                effect: .stored,
                summary: "Remembered: \(candidate.content)"
            )

        case .exactDuplicate(let stored), .nearDuplicate(let stored, _):
            // Already known. Refresh it rather than accumulating a second copy
            // of the same fact — the Memory screen is something the user reads.
            let merged = deduplicator.merged(stored, with: candidate, at: now)
            try await repository.store(merged)
            return MemoryWriteResult(
                memory: merged,
                effect: .merged(into: merged.id),
                summary: "Already knew that: \(merged.content)"
            )

        case .conflicting(let stored, _):
            switch deduplicator.resolution(existing: stored, candidate: candidate) {
            case .replaceContent:
                var corrected = stored
                corrected.content = candidate.content
                corrected.kind = candidate.kind
                corrected.source = candidate.source
                corrected.confidence = candidate.confidence
                corrected.salience = max(stored.salience, candidate.salience)
                corrected.tags = Array(Set(stored.tags).union(candidate.tags)).sorted()
                corrected.updatedAt = now
                try await repository.store(corrected)
                return MemoryWriteResult(
                    memory: corrected,
                    effect: .replaced(corrected.id),
                    summary: "Updated what I knew: \(corrected.content)"
                )

            case .keepBoth:
                // Weaker evidence than what is already stored. Keeping both
                // leaves the disagreement visible in the Memory screen, where
                // the user can settle it, rather than silently overwriting
                // something they said with something the assistant guessed.
                try await repository.store(candidate)
                return MemoryWriteResult(
                    memory: candidate,
                    effect: .keptAlongsideConflict(with: stored.id),
                    summary: "Remembered: \(candidate.content)"
                )
            }
        }
    }

    /// Applies a user's edit.
    ///
    /// Authoritative and never deduplicated: the user is looking at this exact
    /// record and changing it. Running it through duplicate detection could
    /// fold their edit into a different memory, which from their side would
    /// look like the app refusing to save.
    @discardableResult
    public func update(_ memory: MemoryItem) async throws -> MemoryItem {
        let content = memory.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { throw MemoryServiceError.emptyContent }

        var updated = memory
        updated.content = content
        updated.updatedAt = dateProvider.now
        updated.source = .manual
        updated.confidence = MemorySource.manual.defaultConfidence
        try await repository.store(updated)
        return updated
    }

    public func forget(id: MemoryItem.ID) async throws {
        try await repository.delete(id: id)
    }
}

public enum MemoryServiceError: Error, Hashable, Sendable {
    case emptyContent
}
