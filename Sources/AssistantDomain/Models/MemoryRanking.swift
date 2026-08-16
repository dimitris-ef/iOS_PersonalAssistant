import Foundation

extension MemoryQuery {
    /// Applies this query to a set of memories: filters, ranks, truncates.
    ///
    /// Lives in the domain rather than inside a repository because every
    /// backend has to answer `search` the same way. When the ranking was
    /// written into the in-memory repository, adding a second backend meant
    /// either copying it — two implementations free to drift — or letting the
    /// database decide the order, which would make results depend on the
    /// storage engine. Neither is acceptable for something the assistant uses
    /// to choose what it remembers about someone.
    ///
    /// The scoring itself is crude on purpose: keyword overlap, nudged by
    /// salience. Retrieval quality is a separate problem, and this is the seam
    /// a better implementation (embeddings, an on-device index) slots into.
    public func rank(_ items: [MemoryItem]) -> [MemoryItem] {
        var candidates = items
        if !kinds.isEmpty {
            candidates = candidates.filter { kinds.contains($0.kind) }
        }
        if !tags.isEmpty {
            let wanted = Set(tags.map { $0.lowercased() })
            candidates = candidates.filter {
                !wanted.isDisjoint(with: Set($0.tags.map { $0.lowercased() }))
            }
        }

        // Salience keeps every memory eligible: an unrelated question should
        // still surface what the assistant knows, just lower down.
        let terms = Self.terms(in: text ?? "")
        let scored = candidates.map { item -> (item: MemoryItem, score: Double) in
            let itemTerms = Self.terms(in: item.content)
                .union(Set(item.tags.map { $0.lowercased() }))
            let overlap = terms.isEmpty
                ? 0
                : Double(terms.intersection(itemTerms).count) / Double(terms.count)
            return (item, overlap + item.salience * 0.25)
        }

        return scored
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                // Newest first among equals, then by id, so the order is fully
                // determined and two identical queries cannot disagree.
                if lhs.item.createdAt != rhs.item.createdAt {
                    return lhs.item.createdAt > rhs.item.createdAt
                }
                return lhs.item.id.rawValue.uuidString < rhs.item.id.rawValue.uuidString
            }
            .prefix(limit)
            .map(\.item)
    }

    /// Two-character words carry almost no signal here.
    private static func terms(in text: String) -> Set<String> {
        let separators = CharacterSet.alphanumerics.inverted
        let parts = text.lowercased().components(separatedBy: separators)
        return Set(parts.filter { $0.count > 2 })
    }
}
