#if canImport(SwiftData)

import AssistantDomain
import AssistantPersistence
import Foundation
import SwiftData

/// Maps between `LocalModelRecord` and its row.
///
/// Nothing here is derived or interpreted: every field is stored as it is, and
/// the one piece of judgement — how to read a row whose file has since gone —
/// belongs to the manager, which can see the filesystem. A mapper that quietly
/// dropped rows whose file was missing would make a model disappear from the
/// Settings screen with no explanation, when what the user needs is to be told
/// it is gone and offered the download again.
@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
enum LocalModelMapper {
    static let entity = "localModel"

    static func makeRow(from record: LocalModelRecord) -> SDLocalModel {
        SDLocalModel(
            modelID: record.id.rawValue,
            relativePath: record.relativePath,
            fileSizeBytes: record.fileSizeBytes,
            checksumSHA256: record.checksumSHA256,
            checksumWasDeclared: record.checksumWasDeclared,
            installedAt: record.installedAt,
            lastUsedAt: record.lastUsedAt,
            architecture: record.architecture,
            quantization: record.quantization,
            contextLength: record.contextLength
        )
    }

    static func update(_ row: SDLocalModel, from record: LocalModelRecord) {
        row.relativePath = record.relativePath
        row.fileSizeBytes = record.fileSizeBytes
        row.checksumSHA256 = record.checksumSHA256
        row.checksumWasDeclared = record.checksumWasDeclared
        row.installedAt = record.installedAt
        row.lastUsedAt = record.lastUsedAt
        row.architecture = record.architecture
        row.quantization = record.quantization
        row.contextLength = record.contextLength
    }

    static func makeDomain(_ row: SDLocalModel) -> LocalModelRecord {
        LocalModelRecord(
            id: AIModelIdentifier(row.modelID),
            relativePath: row.relativePath,
            fileSizeBytes: row.fileSizeBytes,
            checksumSHA256: row.checksumSHA256,
            checksumWasDeclared: row.checksumWasDeclared,
            installedAt: row.installedAt,
            lastUsedAt: row.lastUsedAt,
            architecture: row.architecture,
            quantization: row.quantization,
            contextLength: row.contextLength
        )
    }
}

/// `LocalModelRepository`, backed by SwiftData.
///
/// Rows describing files. Section 26: the weights are not in here and must not
/// be — this store holds a path and some numbers, which is why installing a
/// 2 GB model costs the database a few hundred bytes.
@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
public struct SwiftDataLocalModelRepository: LocalModelRepository {
    private let persistence: AssistantPersistenceActor

    public init(persistence: AssistantPersistenceActor) {
        self.persistence = persistence
    }

    public func installedModels() async throws -> [LocalModelRecord] {
        try await persistence.read { context in
            let rows = try context.fetchAll(
                FetchDescriptor<SDLocalModel>(
                    sortBy: [SortDescriptor(\.installedAt, order: .reverse)]
                ),
                entity: LocalModelMapper.entity
            )
            return rows.map(LocalModelMapper.makeDomain)
        }
    }

    public func model(id: AIModelIdentifier) async throws -> LocalModelRecord? {
        let raw = id.rawValue
        return try await persistence.read { context in
            try context.first(
                FetchDescriptor<SDLocalModel>(predicate: #Predicate { $0.modelID == raw }),
                entity: LocalModelMapper.entity
            ).map(LocalModelMapper.makeDomain)
        }
    }

    public func save(_ model: LocalModelRecord) async throws {
        let raw = model.id.rawValue
        try await persistence.mutate(entity: LocalModelMapper.entity) { context in
            // Update-or-insert on the logical identifier, so re-downloading a
            // model corrects the row it already had. Inserting instead would
            // leave two rows claiming the same file, and deleting one of them
            // would then delete the other's weights.
            if let existing = try context.first(
                FetchDescriptor<SDLocalModel>(predicate: #Predicate { $0.modelID == raw }),
                entity: LocalModelMapper.entity
            ) {
                LocalModelMapper.update(existing, from: model)
            } else {
                context.insert(LocalModelMapper.makeRow(from: model))
            }
        }
    }

    public func delete(id: AIModelIdentifier) async throws {
        let raw = id.rawValue
        try await persistence.mutate(entity: LocalModelMapper.entity) { context in
            let rows = try context.fetchAll(
                FetchDescriptor<SDLocalModel>(predicate: #Predicate { $0.modelID == raw }),
                entity: LocalModelMapper.entity
            )
            for row in rows { context.delete(row) }
        }
    }
}

#endif
