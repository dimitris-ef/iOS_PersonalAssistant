import AIProviderLocal
import AssistantDomain
import SwiftUI

/// The dedicated action model: which one, whether it can be used, and whether
/// it is currently in memory.
///
/// ## What this screen is for, and what it is not
///
/// Section 8 and 49: enough to inspect and change the action model, and no
/// more. It is not a second model marketplace — downloading and deleting still
/// belong to Local Models, and this offers what is already installed.
///
/// The three lines at the top are the three questions worth answering when
/// somebody reports "reminders don't work": which model, is it usable, and is
/// it loaded. A screen that showed only the name would leave the interesting
/// half unsaid.
struct ActionModelSettingsView: View {
    @Environment(AppModel.self) private var model

    @State private var status = ActionModelStatus()
    @State private var candidates: [Candidate] = []
    @State private var isWorking = false

    /// One installed model, with the verdict this screen groups it by.
    private struct Candidate: Identifiable {
        let id: AIModelIdentifier
        let displayName: String
        let compatibility: ActionModelCompatibility

        var isSelectable: Bool { compatibility.isUsable }
    }

    var body: some View {
        Form {
            statusSection
            controlsSection
            pickerSection
        }
        .navigationTitle("Action Model")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
    }

    // MARK: Status

    private var statusSection: some View {
        Section {
            LabeledContent("Action Model") {
                Text(status.displayName ?? "None selected")
                    .foregroundStyle(status.selectedModelID == nil ? .secondary : .primary)
            }
            LabeledContent("Compatibility") {
                Text(status.compatibility.label)
                    .foregroundStyle(colour(for: status.compatibility))
            }
            LabeledContent("Status") {
                Text(status.runtimeState.label)
                    .foregroundStyle(status.runtimeState.isLoaded ? .primary : .secondary)
            }
            if let reason = status.unavailableReason {
                // Section 20 and 51: the reason is shown, and it is one of the
                // authored sentences — never a native error.
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Action Model")
        } footer: {
            Text(
                "Actions — reminders, tasks, calendar events — are interpreted by this "
                    + "model, not by the assistant you chat with. Changing one never "
                    + "changes the other."
            )
        }
    }

    // MARK: Load and unload

    private var controlsSection: some View {
        Section {
            Button("Load") {
                perform { try await model.actionModelHost.ensureLoaded() }
            }
            .disabled(isWorking || status.runtimeState.isLoaded || !status.isUsable)

            Button("Unload") {
                perform { await model.actionModelHost.unload() }
            }
            .disabled(isWorking || !status.runtimeState.isLoaded)
        } footer: {
            Text(
                "The action model loads by itself the first time you ask for something "
                    + "and stays in memory afterwards. Unloaded is the normal resting "
                    + "state and does not mean anything is wrong."
            )
        }
    }

    // MARK: Choosing one

    private var pickerSection: some View {
        Section {
            if candidates.isEmpty {
                Text("No local models are installed.")
                    .foregroundStyle(.secondary)
            }
            ForEach(candidates) { candidate in
                Button {
                    perform { try await model.actionModelHost.select(candidate.id) }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.displayName)
                                .foregroundStyle(candidate.isSelectable ? .primary : .secondary)
                            // Section 51: an incompatible model says why rather
                            // than vanishing from the list. Somebody who
                            // downloaded it deserves to know it cannot be used
                            // here, and for what reason.
                            if case .incompatible(let reason) = candidate.compatibility {
                                Text(reason.message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else if candidate.compatibility == .experimental {
                                Text("Experimental")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if candidate.id == status.selectedModelID {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                                .accessibilityLabel("Selected")
                        }
                    }
                }
                .disabled(isWorking || !candidate.isSelectable)
            }

            if status.selectedModelID != nil {
                Button("Clear selection", role: .destructive) {
                    perform { try await model.actionModelHost.select(nil) }
                }
                .disabled(isWorking)
            }
        } header: {
            Text("Choose a Model")
        } footer: {
            Text(
                "Small models are fine here. This one only has to turn a sentence into "
                    + "one structured action, and its output is constrained by a grammar."
            )
        }
    }

    // MARK: Work

    /// Runs one host operation and refreshes. Serialised by `isWorking` so two
    /// taps cannot race a load against an unload.
    private func perform(_ operation: @escaping @Sendable () async throws -> Void) {
        guard !isWorking else { return }
        isWorking = true
        Task {
            try? await operation()
            await refresh()
            isWorking = false
        }
    }

    private func refresh() async {
        status = await model.actionModelHost.status()
        let selectable = await model.actionModelHost.selectableModels()
        candidates = selectable.map {
            Candidate(
                id: $0.status.descriptor.id,
                displayName: $0.status.descriptor.displayName,
                compatibility: $0.compatibility
            )
        }
    }

    private func colour(for compatibility: ActionModelCompatibility) -> Color {
        switch compatibility {
        case .compatible: return .green
        case .experimental: return .orange
        case .incompatible: return .secondary
        }
    }
}
