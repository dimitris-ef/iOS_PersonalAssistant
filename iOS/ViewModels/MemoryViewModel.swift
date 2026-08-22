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
    /// What the screen is showing: what the assistant uses, or the history.
    var scope: MemoryScope = .current

    private let presenter = MemoryPresenter()

    func sections(for model: AppModel) -> [MemorySection] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let memories = query.isEmpty
            ? model.memories
            : model.memories.filter { $0.content.lowercased().contains(query) }

        return presenter.sections(from: memories, scope: scope)
    }

    /// Whether the "Set aside" tab is worth showing at all.
    ///
    /// Hidden until something is actually set aside. A permanently empty tab is
    /// a question the user has to answer — "what is this for?" — for no benefit.
    func hasSetAsideMemories(in model: AppModel) -> Bool {
        presenter.count(of: .setAside, in: model.memories) > 0
    }

    func lifecycleLabel(for memory: MemoryItem) -> String? {
        presenter.lifecycleLabel(for: memory)
    }

    func lifecycleExplanation(for memory: MemoryItem) -> String? {
        presenter.lifecycleExplanation(for: memory)
    }

    func provenanceLabel(for memory: MemoryItem) -> String? {
        presenter.provenanceLabel(for: memory)
    }

    func sourceLabel(for memory: MemoryItem) -> String {
        presenter.sourceLabel(for: memory)
    }

    func confidenceLabel(for memory: MemoryItem) -> String? {
        presenter.confidenceLabel(for: memory)
    }

    func symbol(for kind: MemoryKind) -> String {
        presenter.symbol(for: kind)
    }

    func kindLabel(for kind: MemoryKind) -> String {
        presenter.kindLabel(for: kind)
    }
}
