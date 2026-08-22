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
            // The filter, shown only once something has actually been set aside.
            // Archiving is only defensible if the user can see what was archived
            // and put it back, and this is the way back.
            if viewModel.hasSetAsideMemories(in: model) {
                Section {
                    Picker("Show", selection: $viewModel.scope) {
                        ForEach(MemoryScope.allCases) { scope in
                            Text(scope.title).tag(scope)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .listRowBackground(Color.clear)
            }

            let sections = viewModel.sections(for: model)
            if sections.isEmpty {
                Section {
                    Text(viewModel.scope.emptyMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(sections) { section in
                Section {
                    ForEach(section.memories) { memory in
                        MemoryRowView(
                            memory: memory,
                            symbol: viewModel.symbol(for: memory.kind),
                            sourceLabel: viewModel.sourceLabel(for: memory),
                            confidenceLabel: viewModel.confidenceLabel(for: memory),
                            lifecycleLabel: viewModel.lifecycleLabel(for: memory),
                            provenanceLabel: viewModel.provenanceLabel(for: memory)
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
                        .swipeActions(edge: .leading) {
                            // Only where there is something to restore *to*. A
                            // superseded memory has been replaced by a newer
                            // one, and the way back is to edit or delete that —
                            // a decision, not an undo.
                            if memory.lifecycle.isRestorable {
                                Button {
                                    Task { await model.restoreMemory(memory.id) }
                                } label: {
                                    Label("Use again", systemImage: "arrow.uturn.backward")
                                }
                                .tint(.accentColor)
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
