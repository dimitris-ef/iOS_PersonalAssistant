import AIProviderRemote
import SwiftUI

/// Configure the remote model: where to send requests, which model, and the key.
///
/// Deliberately three fields and a status line. The protocol is
/// OpenAI-compatible, but nothing here is OpenAI-specific — the same form
/// points at a self-hosted server or any other compatible service.
struct RemoteAISettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var baseURL = ""
    @State private var modelName = ""
    /// `nil` until the user types something, so saving without touching the
    /// field leaves the stored key alone.
    @State private var apiKeyDraft: String?
    @State private var isConfirmingKeyRemoval = false
    @State private var hasLoaded = false

    var body: some View {
        Form {
            endpointSection
            keySection
            statusSection
            helpSection
        }
        .navigationTitle("Remote AI")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task {
                        await model.saveRemoteConfiguration(
                            baseURL: baseURL,
                            model: modelName,
                            apiKey: apiKeyDraft
                        )
                        apiKeyDraft = nil
                    }
                }
                .disabled(!hasChanges)
            }
        }
        .task {
            guard !hasLoaded else { return }
            hasLoaded = true
            await model.refreshProviderState()
            baseURL = model.remoteConfiguration.baseURL
            modelName = model.remoteConfiguration.model
        }
        .confirmationDialog(
            "Remove the stored API key?",
            isPresented: $isConfirmingKeyRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                Task {
                    await model.clearRemoteAPIKey()
                    apiKeyDraft = nil
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: Sections

    private var endpointSection: some View {
        Section {
            LabeledContent("Endpoint") {
                TextField("api.openai.com/v1", text: $baseURL)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
            }

            LabeledContent("Model") {
                TextField("model name", text: $modelName)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        } header: {
            Text("Service")
        } footer: {
            Text("Any service that speaks the OpenAI chat-completions protocol works, including a self-hosted one. The model name is passed through as you type it.")
        }
    }

    private var keySection: some View {
        Section {
            // SecureField, so the key is never rendered on screen. When one is
            // already stored the field shows a masked placeholder rather than
            // the value — the app has no reason to read it back.
            SecureField(
                model.hasRemoteAPIKey ? "••••••••••••" : "Paste your API key",
                text: Binding(
                    get: { apiKeyDraft ?? "" },
                    set: { apiKeyDraft = $0 }
                )
            )
            .textContentType(.password)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()

            if model.hasRemoteAPIKey {
                Button("Remove stored key", role: .destructive) {
                    isConfirmingKeyRemoval = true
                }
            }
        } header: {
            Text("API Key")
        } footer: {
            Text("Stored in the device keychain, never in settings or backups. Leave this blank to keep the key you already saved.")
        }
    }

    private var statusSection: some View {
        Section {
            LabeledContent("Status") {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: isReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(isReady ? Color.green : Color.orange)
                        .font(.footnote)
                    Text(isReady ? "Ready" : "Configuration required")
                        .foregroundStyle(.secondary)
                }
            }

            if let host = model.remoteConfiguration.displayHost {
                // Host only — a configured endpoint can carry a token in its
                // path or query on some services.
                LabeledContent("Host", value: host)
            }

            if !isReady {
                Text(missingDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var helpSection: some View {
        Section {
            Text("The model proposes actions — reminders, events, alarms. The app validates every one against its own rules before anything runs, and right now they run against mock services, so nothing reaches your real calendar or notifications.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Derived

    private var hasChanges: Bool {
        baseURL != model.remoteConfiguration.baseURL
            || modelName != model.remoteConfiguration.model
            || (apiKeyDraft?.isEmpty == false)
    }

    private var missing: [RemoteAIConfiguration.Requirement] {
        RemoteAIConfiguration(baseURL: baseURL, model: modelName)
            .missingRequirements(hasCredential: model.hasRemoteAPIKey || apiKeyDraft?.isEmpty == false)
    }

    private var isReady: Bool { missing.isEmpty }

    private var missingDescription: String {
        RemoteAIError.notConfigured(missing: missing).userFacingDescription
    }
}

#Preview {
    // TODO-XCODE: Verify SwiftUI preview.
    NavigationStack {
        RemoteAISettingsView()
    }
    .environment(AppModel(environment: AppEnvironment.makeDemo()))
}
