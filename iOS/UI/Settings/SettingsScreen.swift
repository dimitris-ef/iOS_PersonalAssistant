import AssistantDomain
import AssistantPlatform
import AssistantVoice
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
                voiceSection
                systemSurfacesSection
                permissionsSection
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
                case .localModels:
                    LocalModelsView()
                case .voice:
                    VoiceSettingsView()
                case .systemSurfaces:
                    SystemSurfacesView()
                case .appleDiagnostics:
                    AppleOnDeviceDiagnosticsView()
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

    /// Voice: whether the assistant talks back, and what it can hear.
    ///
    /// The permission rows report the real authorization state rather than a
    /// stored guess, and the recognition row says truthfully where audio is
    /// processed — `SFSpeechRecognizer` only guarantees on-device handling when
    /// the device supports it, so this reads that rather than assuming it.
    private var voiceSection: some View {
        Section {
            Toggle(
                "Speak replies",
                isOn: binding(
                    get: { $0.voice.speaksReplies },
                    set: { settings, value in settings.voice.speaksReplies = value }
                )
            )

            if model.settings.voice.speaksReplies {
                Toggle(
                    "Also speak replies to typed messages",
                    isOn: binding(
                        get: { $0.voice.speaksTypedReplies },
                        set: { settings, value in settings.voice.speaksTypedReplies = value }
                    )
                )
            }

            if let voice = model.voice {
                LabeledContent("Microphone", value: Self.describe(voice.permissions.microphone))
                LabeledContent(
                    "Speech recognition",
                    value: Self.describe(voice.permissions.speechRecognition)
                )
                LabeledContent("Recognition", value: voice.recognitionMode.description)
            }

            NavigationLink(value: SettingsViewModel.Route.voice) {
                LabeledContent(
                    "Speech-to-Text",
                    value: model.speechProviderDisplayName
                )
            }
        } header: {
            Text("Voice")
        } footer: {
            // Rewritten for Part 13. The old wording promised that no audio
            // left the device, which was true when Apple Speech was the only
            // option and would now be a lie whenever OpenAI is selected. What
            // is still unconditionally true — and is the architectural point —
            // is that the *assistant* never receives audio: it receives the
            // transcript, exactly as if it had been typed.
            Text(
                "Spoken replies are off until you turn them on, and answer only "
                    + "what you said out loud unless you also switch on typed "
                    + "replies. Audio is transcribed and then discarded; nothing "
                    + "is recorded. The AI model that answers you receives the "
                    + "text, never the audio. Where transcription happens depends "
                    + "on the provider you choose in Speech-to-Text."
            )
        }
        .task { await model.voice?.refreshPermissions() }
    }

    private static func describe(_ permission: VoicePermission) -> String {
        switch permission {
        case .authorized: return "Allowed"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not asked yet"
        case .unsupported: return "Unavailable"
        }
    }

    /// What the OS actually allows, read from the platform layer.
    ///
    /// This section used to say "Delivery: Not connected", which was true when
    /// nothing was connected. Leaving a hard-coded string here after the
    /// integration landed would have turned an honest disclosure into a lie, so
    /// each row now reports the real permission status — including the ones
    /// that are bad news.
    /// Widgets, the keyboard and Live Activities.
    ///
    /// One row. Section 88 asks for no large widget-settings screen, and
    /// section 86 for the app to remain completely functional whether or not
    /// any of it is installed — so this is a door, not a requirement.
    private var systemSurfacesSection: some View {
        Section {
            NavigationLink(value: SettingsViewModel.Route.systemSurfaces) {
                Label("Widgets & Keyboard", systemImage: "square.grid.2x2")
            }
        } footer: {
            Text("Optional. Personal Assistant works fully without any of them.")
        }
    }

    private var permissionsSection: some View {
        Section {
            ForEach(PlatformCapability.allCases, id: \.self) { capability in
                PermissionRow(capability: capability)
            }
        } header: {
            Text("Access")
        } footer: {
            Text("The assistant asks for each of these the first time it needs one, not all at once when you open the app. Anything already answered is changed in the Settings app.")
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

/// One capability, its current answer, and a way to ask when asking helps.
///
/// The wording of each state is doing real work. "Denied" and "Restricted" look
/// the same to a user and are not: one is undone in the Settings app and the
/// other cannot be undone by the person holding the phone, so telling them to
/// go to Settings would send them looking for a switch that is not there.
private struct PermissionRow: View {
    let capability: PlatformCapability

    @Environment(AppModel.self) private var model

    private var status: PermissionStatus {
        model.permissions[capability] ?? .notDetermined
    }

    var body: some View {
        LabeledContent(title) {
            if status.isSettled {
                Text(description)
                    // Both branches spelled as `Color` for legibility. A bare
                    // `.secondary` also compiles here — inference resolves it
                    // against the other branch — but which `secondary` it
                    // means is then something the reader has to work out.
                    .foregroundStyle(status.allowsAccess ? Color.secondary : Color.orange)
            } else {
                Button("Allow") {
                    Task { await model.requestPermission(capability) }
                }
            }
        }
    }

    private var title: String {
        switch capability {
        case .calendar: return "Calendar"
        case .reminders: return "Reminders"
        case .notifications: return "Notifications"
        case .alarms: return "Alarms"
        }
    }

    private var description: String {
        switch status {
        case .granted: return "Allowed"
        case .denied: return "Off — change in Settings"
        case .restricted: return "Not permitted on this device"
        case .limited: return "Partly allowed"
        case .unsupported: return "Not available on this iPhone"
        case .notDetermined: return "Not asked yet"
        }
    }
}

#Preview {
    // TODO-XCODE: Verify SwiftUI preview.
    SettingsScreen()
        .environment(AppModel(environment: AppEnvironment.makeDemo()))
}
