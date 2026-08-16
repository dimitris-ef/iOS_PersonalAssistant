import AssistantDomain
import SwiftUI

/// Settings.
///
/// A native grouped `Form`. The ADHD assistance section is the one that
/// genuinely changes behaviour — those toggles feed `SupportPreferences`, which
/// the reminder planner reads when it builds a plan.
struct SettingsScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel = SettingsViewModel()
    @AppStorage(AppearancePreference.storageKey) private var appearance: AppearancePreference = .system
    @AppStorage("assistantName") private var assistantName = "Assistant"
    @AppStorage("assistantPersonality") private var personality = AssistantPersonality.warm
    @AppStorage("assistantResponseLength") private var responseLength = ResponseLength.balanced

    var body: some View {
        NavigationStack {
            Form {
                assistantSection
                modelSection
                supportSection
                notificationsSection
                appearanceSection
                privacySection
                developerSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                "Reset demo data?",
                isPresented: $viewModel.isConfirmingReset,
                titleVisibility: .visible
            ) {
                Button("Reset", role: .destructive) {
                    Task {
                        await model.resetDemoData()
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Anything you've added in this session will be replaced.")
            }
            .navigationDestination(for: SettingsViewModel.Route.self) { route in
                switch route {
                case .modelSelector:
                    ModelSelectorView()
                case .remoteAI:
                    RemoteAISettingsView()
                case .privacy(let topic):
                    PrivacyDetailView(topic: topic)
                }
            }
        }
    }

    // MARK: Sections

    private var assistantSection: some View {
        Section {
            LabeledContent("Name") {
                TextField("Assistant", text: $assistantName)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.words)
            }

            Picker("Personality", selection: $personality) {
                ForEach(AssistantPersonality.allCases) { value in
                    Text(value.title).tag(value)
                }
            }

            Picker("Response length", selection: $responseLength) {
                ForEach(ResponseLength.allCases) { value in
                    Text(value.title).tag(value)
                }
            }
        } header: {
            Text("Assistant")
        } footer: {
            Text("Personality and length don't change replies yet — they'll shape the assistant's prompt once a model is connected.")
        }
    }

    private var modelSection: some View {
        Section {
            NavigationLink(value: SettingsViewModel.Route.modelSelector) {
                LabeledContent("Model") {
                    HStack(spacing: Theme.Spacing.xs) {
                        Text(viewModel.selectedProviderName(for: model))
                        if !viewModel.selectedProviderIsAvailable(for: model) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .accessibilityLabel("Unavailable")
                        }
                    }
                }
            }
        } header: {
            Text("AI Model")
        } footer: {
            Text("The model is a replaceable reasoning engine. Switching it never moves your conversations, tasks or memory.")
        }
    }

    private var supportSection: some View {
        Section {
            Toggle(
                "Proactive reminders",
                isOn: binding(
                    get: { $0.support.followUp.isEnabled },
                    set: { settings, value in settings.support.followUp.isEnabled = value }
                )
            )

            Toggle(
                "Follow up if not confirmed",
                isOn: binding(
                    get: { $0.support.followUp.escalatesEachTime },
                    set: { settings, value in settings.support.followUp.escalatesEachTime = value }
                )
            )

            Toggle(
                "Require completion confirmation",
                isOn: binding(
                    get: { $0.support.completion.requiresExplicitConfirmation },
                    set: { settings, value in
                        settings.support.completion.requiresExplicitConfirmation = value
                    }
                )
            )

            Toggle(
                "Preparation reminders",
                isOn: binding(
                    get: { !$0.support.advanceNoticeDays.isEmpty },
                    set: { settings, value in
                        settings.support.advanceNoticeDays = value ? [3] : []
                    }
                )
            )
        } header: {
            Text("ADHD Assistance")
        } footer: {
            Text("With confirmation required, dismissing a reminder marks the task as still open rather than done. This is the behaviour the assistant is built around.")
        }
    }

    private var notificationsSection: some View {
        Section {
            LabeledContent("Delivery", value: "Not connected")
            LabeledContent("Critical alerts", value: "Not available")
        } header: {
            Text("Notifications")
        } footer: {
            Text("Reminders are simulated in-app for now. Real delivery, including the Done and Snooze actions, arrives with the notification integration.")
        }
    }

    private var appearanceSection: some View {
        Section("Appearance") {
            Picker("Appearance", selection: $appearance) {
                ForEach(AppearancePreference.allCases) { value in
                    Text(value.title).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var privacySection: some View {
        Section("Privacy") {
            ForEach(PrivacyTopic.allCases) { topic in
                NavigationLink(value: SettingsViewModel.Route.privacy(topic)) {
                    Label(topic.title, systemImage: topic.symbol)
                }
            }
        }
    }

    /// Only shown in a launch that is already running on demo content.
    ///
    /// On a normal launch this section does not exist. "Reset demo data" would
    /// mean deleting the user's real conversations, tasks and memories and
    /// replacing them with a fake haircut — a destructive action mislabelled as
    /// a development convenience, sitting one tap away in Settings.
    @ViewBuilder
    private var developerSection: some View {
        if model.isRunningOnDemoData {
            Section {
                Button("Reset demo data") {
                    viewModel.isConfirmingReset = true
                }
            } header: {
                Text("Development")
            } footer: {
                Text("Restores the seeded conversation, tasks, events and memories. This build is running on temporary demo storage, not your own data.")
            }
        }
    }

    // MARK: Settings bindings

    /// Bridges a field of the domain's `AssistantSettings` to a `Toggle`.
    ///
    /// Writes go through `AppModel`, which persists via the settings
    /// repository, so a toggle here really does change what the planner does.
    private func binding(
        get: @escaping (AssistantSettings) -> Bool,
        set: @escaping (inout AssistantSettings, Bool) -> Void
    ) -> Binding<Bool> {
        Binding(
            get: { get(model.settings) },
            set: { newValue in
                Task { await model.updateSettings { set(&$0, newValue) } }
            }
        )
    }
}

/// Placeholder persona options. Stored in `@AppStorage` until the prompt
/// builder consumes them.
enum AssistantPersonality: String, CaseIterable, Identifiable {
    case warm
    case direct
    case quiet

    var id: String { rawValue }

    var title: String {
        switch self {
        case .warm: return "Warm"
        case .direct: return "Direct"
        case .quiet: return "Quiet"
        }
    }
}

enum ResponseLength: String, CaseIterable, Identifiable {
    case brief
    case balanced
    case detailed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .brief: return "Brief"
        case .balanced: return "Balanced"
        case .detailed: return "Detailed"
        }
    }
}

#Preview {
    // TODO-XCODE: Verify SwiftUI preview.
    SettingsScreen()
        .environment(AppModel(environment: AppEnvironment.makeDemo()))
}
