import AIProviderLocal
import AssistantDomain
import SwiftUI

/// One model, in detail: what it is, how it was verified, and how to remove it.
///
/// Section 72 asks for Use / Load / Unload / Delete and optional details. What
/// it does not ask for, and what this deliberately does not show, is a
/// filesystem path — the file lives inside the app's container under a name the
/// app chose, and showing someone a sandbox path is showing them something they
/// can neither use nor act on.
struct LocalModelDetailView: View {
    @Environment(AppModel.self) private var model
    let status: LocalModelStatus
    @Bindable var viewModel: LocalModelsViewModel

    var body: some View {
        List {
            Section {
                LabeledContent("Status", value: LocalModelPresentation.statusLabel(status))
                LabeledContent("Size", value: LocalModelPresentation.size(
                    status.installed?.fileSizeBytes ?? status.descriptor.fileSizeBytes
                ))
                if let parameters = status.descriptor.parameterLabel {
                    LabeledContent("Parameters", value: parameters)
                }
                if let quantization = status.descriptor.quantization {
                    LabeledContent("Precision", value: quantization.rawValue)
                }
            } header: {
                Text(status.descriptor.displayName)
            } footer: {
                if let summary = status.descriptor.summary {
                    Text(summary)
                }
            }

            Section("What it can do") {
                Label {
                    Text(LocalModelPresentation.capabilityLabel(status.descriptor))
                } icon: {
                    Image(systemName: status.descriptor.toolSupport.offersTools
                        ? "checkmark.seal"
                        : "text.bubble")
                }
                .font(.subheadline)

                if status.descriptor.toolSupport == .unsupported {
                    Text(
                        "This model can hold a conversation, but the assistant will not ask "
                            + "it to create tasks, reminders or calendar events."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }

            if let installed = status.installed {
                Section("On this device") {
                    Label {
                        Text(LocalModelPresentation.verificationLabel(installed))
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: installed.checksumWasDeclared
                            ? "checkmark.shield"
                            : "shield.lefthalf.filled")
                        .foregroundStyle(installed.checksumWasDeclared ? .green : .secondary)
                    }

                    if let architecture = installed.architecture {
                        LabeledContent("Model family", value: architecture)
                    }
                    LabeledContent("Conversation memory", value: "\(installed.contextLength) tokens")
                    LabeledContent(
                        "Installed",
                        value: installed.installedAt.formatted(date: .abbreviated, time: .omitted)
                    )
                }
            }

            if let licence = status.descriptor.license {
                Section("Licence") {
                    if let url = licence.url {
                        Link(licence.displayName, destination: url)
                    } else {
                        Text(licence.displayName)
                    }
                    Text(
                        "The model's own licence, set by whoever published it. It is separate "
                            + "from this app's, and from the licence of the software that runs it."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }

            if status.lifecycle.isInstalled {
                Section {
                    if !status.isSelected {
                        Button("Use This Model") {
                            Task { await viewModel.use(status, manager: model.environment.localModels) }
                        }
                    } else if status.lifecycle.isLoaded {
                        Button("Unload from memory") {
                            Task { await viewModel.unload(model.environment.localModels) }
                        }
                        Text(
                            "Frees the memory it is using. It loads again the next time you "
                                + "ask the assistant something."
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    } else {
                        Button("Load") {
                            Task { await viewModel.use(status, manager: model.environment.localModels) }
                        }
                    }

                    Button("Delete Model", role: .destructive) {
                        viewModel.pendingDeletion = status
                    }
                }
            }
        }
        .navigationTitle(status.descriptor.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Delete \(status.descriptor.displayName)?",
            isPresented: Binding(
                get: { viewModel.pendingDeletion?.id == status.id },
                set: { if !$0 { viewModel.pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task { await viewModel.delete(status, manager: model.environment.localModels) }
            }
            Button("Cancel", role: .cancel) { viewModel.pendingDeletion = nil }
        } message: {
            // Says what survives, because "delete the thing the assistant runs
            // on" reasonably makes people wonder what goes with it.
            Text(LocalModelPresentation.deletionExplanation(status))
        }
    }
}
