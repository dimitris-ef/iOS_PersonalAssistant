import AssistantDomain
import Foundation
import Observation

/// Screen state for Memory.
@MainActor
@Observable
final class MemoryViewModel {
    enum Editor: Identifiable {
        case new
        case existing(MemoryItem)

        var id: String {
            switch self {
            case .new: return "new"
            case .existing(let memory): return memory.id.description
            }
        }
    }

    var editor: Editor?
    var searchText = ""

    private let presenter = MemoryPresenter()

    func sections(for model: AppModel) -> [MemorySection] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let memories = query.isEmpty
            ? model.memories
            : model.memories.filter { $0.content.lowercased().contains(query) }

        return presenter.sections(from: memories)
    }

    func sourceLabel(for memory: MemoryItem) -> String {
        presenter.sourceLabel(for: memory)
    }

    func symbol(for kind: MemoryKind) -> String {
        presenter.symbol(for: kind)
    }

    func kindLabel(for kind: MemoryKind) -> String {
        presenter.kindLabel(for: kind)
    }
}
