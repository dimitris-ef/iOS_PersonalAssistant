import AssistantDomain
import SwiftUI

/// Add or change something the assistant remembers.
struct MemoryEditorView: View {
    /// `nil` creates a new memory.
    let memory: MemoryItem?

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var content = ""
    @State private var kind: MemoryKind = .fact
    @State private var isConfirmingDelete = false
    @State private var hasLoaded = false

    private let presenter = MemoryPresenter()

    var body: some View {
        Form {
            Section {
                TextField(
                    "It normally takes me 30 minutes to drive to work.",
                    text: $content,
                    axis: .vertical
                )
                .lineLimit(3...8)
            } footer: {
                Text("Write it the way you'd say it. I'll use it when planning your reminders.")
            }

            Section {
                Picker("Kind", selection: $kind) {
                    ForEach(MemoryKind.allCases, id: \.self) { value in
                        Label(
                            presenter.kindLabel(for: value),
                            systemImage: presenter.symbol(for: value)
                        )
                        .tag(value)
                    }
                }
            }

            if let memory {
                Section {
                    LabeledContent("Source", value: presenter.sourceLabel(for: memory))
                    LabeledContent(
                        "Added",
                        value: AppFormatters.shared.dayAndMonth(memory.createdAt)
                    )
                    if let status = presenter.lifecycleLabel(for: memory) {
                        LabeledContent("Status", value: status)
                    }
                } footer: {
                    // Said in plain words rather than left as a badge. "Superseded"
                    // means nothing to somebody who did not design this.
                    if let explanation = presenter.lifecycleExplanation(for: memory) {
                        Text(explanation)
                    }
                }

                // Provenance, for a fact assembled from several statements. The
                // sources themselves, not a count and not an audit log — the
                // question a user actually has is "what did I say that made you
                // think this?".
                let sources = model.sourceMemories(of: memory)
                if !sources.isEmpty {
                    Section {
                        ForEach(sources) { source in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.content)
                                    .font(.subheadline)
                                Text(presenter.sourceLabel(for: source))
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    } header: {
                        Text("Based on")
                    } footer: {
                        Text(
                            "I combined these into one. They are kept here, and no longer "
                                + "used separately."
                        )
                    }
                }

                if memory.lifecycle.isRestorable {
                    Section {
                        Button {
                            Task {
                                await model.restoreMemory(memory.id)
                                dismiss()
                            }
                        } label: {
                            Label("Use this again", systemImage: "arrow.uturn.backward")
                        }
                    }
                }

                Section {
                    Button(role: .destructive) {
                        isConfirmingDelete = true
                    } label: {
                        Label("Forget this", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle(memory == nil ? "New Memory" : "Memory")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task {
                        await save()
                        dismiss()
                    }
                }
                .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .confirmationDialog(
            "Forget this?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Forget", role: .destructive) {
                guard let memory else { return }
                Task {
                    await model.deleteMemory(memory.id)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("I'll stop using this when planning.")
        }
        .onAppear(perform: loadIfNeeded)
    }

    private func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        guard let memory else { return }
        content = memory.content
        kind = memory.kind
    }

    private func save() async {
        if let memory {
            await model.updateMemory(memory, content: content, kind: kind)
        } else {
            await model.addMemory(content: content, kind: kind)
        }
    }
}

#Preview {
    // TODO-XCODE: Verify SwiftUI preview.
    NavigationStack {
        MemoryEditorView(memory: nil)
    }
    .environment(AppModel(environment: AppEnvironment.makeDemo()))
}
