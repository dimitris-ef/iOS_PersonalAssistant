#if canImport(SwiftData)

import AssistantDomain
import Foundation
import SwiftData

/// `MemoryItem` ↔ `SDMemory`.
@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
enum MemoryMapper {
    static let entity = "memory"

    static func makeRow(from item: MemoryItem) -> SDMemory {
        SDMemory(
            id: item.id.rawValue,
            kindRaw: item.kind.rawValue,
            content: item.content,
            salience: item.salience,
            tags: item.tags,
            createdAt: item.createdAt,
            updatedAt: item.updatedAt,
            lastUsedAt: item.lastUsedAt,
            sourceRaw: item.source.rawValue
        )
    }

    static func update(_ row: SDMemory, from item: MemoryItem) {
        row.kindRaw = item.kind.rawValue
        row.content = item.content
        row.salience = item.salience
        row.tags = item.tags
        row.createdAt = item.createdAt
        row.updatedAt = item.updatedAt
        row.lastUsedAt = item.lastUsedAt
        row.sourceRaw = item.source.rawValue
    }

    static func makeDomain(from row: SDMemory) throws -> MemoryItem {
        MemoryItem(
            id: MemoryItem.ID(row.id),
            // The category is a first-class column, not something derived from
            // the text: losing it would quietly change what the assistant is
            // allowed to reason about.
            kind: try decodeEnum(MemoryKind.self, from: row.kindRaw, entity: entity, field: "kind"),
            content: row.content,
            salience: row.salience,
            tags: row.tags,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt,
            lastUsedAt: row.lastUsedAt,
            source: try decodeEnum(MemorySource.self, from: row.sourceRaw, entity: entity, field: "source")
        )
    }
}

#endif
