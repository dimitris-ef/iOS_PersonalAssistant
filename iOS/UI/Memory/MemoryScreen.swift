import AssistantDomain
import SwiftUI

/// What the assistant knows about you.
///
/// This screen exists for transparency and control: an assistant that quietly
/// accumulates facts about someone should be able to show them the list and let
/// them delete any of it. Everything here is editable and deletable.
struct MemoryScreen: View {
    @Environment(AppModel.self) private var model
    @State private var viewModel = MemoryViewModel()

    var body: some View {
        NavigationStack {
            Group {
                if model.memories.isEmpty {
                    EmptyStateView(
                        systemImage: "brain",
                        title: "Nothing remembered yet",
                        message: "As we talk I'll pick up how long things take you and what you prefer. You can add something yourself too."
                    ) {
                        Button("Add memory") { viewModel.editor = .new }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    list
                }
            }
            .navigationTitle("Memory")
            .searchable(text: $viewModel.searchText, prompt: "Search memories")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { SettingsToolbarButton() }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        viewModel.editor = .new
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add memory")
                }
            }
            .sheet(item: $viewModel.editor) { editor in
                NavigationStack {
                    switch editor {
                    case .new:
                        MemoryEditorView(memory: nil)
                    case .existing(let memory):
                        MemoryEditorView(memory: memory)
                    }
                }
                .presentationDragIndicator(.visible)
            }
            .animation(Theme.transition, value: model.memories)
        }
    }

    private var list: some View {
        List {
            ForEach(viewModel.sections(for: model)) { section in
                Section {
                    ForEach(section.memories) { memory in
                        MemoryRowView(
                            memory: memory,
                            symbol: viewModel.symbol(for: memory.kind),
                            sourceLabel: viewModel.sourceLabel(for: memory)
                        ) {
                            viewModel.editor = .existing(memory)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task { await model.deleteMemory(memory.id) }
                            } label: {
                                Label("Forget", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text(section.group.title)
                } footer: {
                    Text(section.group.footer)
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

#Preview {
    // TODO-XCODE: Verify SwiftUI preview.
    MemoryScreen()
        .environment(AppModel(environment: AppEnvironment.makeDemo()))
}
