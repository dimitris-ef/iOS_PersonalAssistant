import AssistantAI
import AssistantDomain
import SwiftUI

/// Choose which model does the reasoning.
///
/// Two things this screen must get right:
///
/// 1. **It tells the truth.** Status comes from each provider's own
///    availability, so a provider is never "ready" just because its type exists
///    in the binary. The cloud model is ready only once it has an endpoint, a
///    key and a model name.
/// 2. **Switching costs nothing.** Selecting a different model writes one field
///    in settings. Conversations, tasks, memory and preferences live in the
///    repositories and are never touched.
struct ModelSelectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section {
                ForEach(model.providerOptions) { option in
                    ModelOptionRow(
                        option: option,
                        isSelected: option.id == model.settings.preferredProviderID,
                        configureAction: configureRoute(for: option)
                    ) {
                        Task { await model.selectProvider(option.id) }
                    }
                }
            } footer: {
                Text("Your conversations, tasks and memory belong to the app, not to the model. Switching never moves or resets them.")
            }

            if !anyProviderIsReady {
                Section {
                    Label {
                        Text("No model is connected, so replies come from a scripted development stand-in. Set up the cloud model to talk to a real one.")
                    } icon: {
                        Image(systemName: "info.circle")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("AI Model")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.refreshProviderState() }
    }

    private var anyProviderIsReady: Bool {
        model.providerOptions.contains { $0.isAvailable }
    }

    /// Where a provider's own setup lives, for the two that have one.
    ///
    /// The cloud model needs an endpoint and a key; Local AI needs a model
    /// file. Both are things the user can go and fix, which is exactly what
    /// `configurationRequired` means and why selecting Local AI with nothing
    /// downloaded leads here rather than to a dead end (section 63).
    private func configureRoute(for option: ProviderOption) -> SettingsViewModel.Route? {
        switch option.metadata.kind {
        case .remoteAPI: return .remoteAI
        case .downloadedLocalModel: return .localModels
        case .appleFoundationModels, .development: return nil
        }
    }
}

/// One provider, with its trade-offs and its honest status.
private struct ModelOptionRow: View {
    let option: ProviderOption
    let isSelected: Bool
    let configureAction: SettingsViewModel.Route?
    let onSelect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Button(action: onSelect) {
                HStack(alignment: .top, spacing: Theme.Spacing.md) {
                    Image(systemName: symbol)
                        .font(.body)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color.accentColor.opacity(0.12)))

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: Theme.Spacing.sm) {
                            Text(option.metadata.displayName)
                                .font(.headline)
                                .foregroundStyle(.primary)
                            StatusPill(option: option)
                        }

                        Text(tagline)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        if let reason = option.unavailableReason {
                            Text(reason)
                                .font(.caption)
                                .foregroundStyle(option.needsConfiguration ? .orange : .secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 2)
                        }
                    }

                    Spacer(minLength: 0)

                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .accessibilityLabel("Selected")
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)

            if let configureAction {
                NavigationLink(value: configureAction) {
                    Text(configureLabel)
                        .font(.subheadline)
                }
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
    }

    /// What the link under a provider says.
    ///
    /// "Manage Models" rather than "Set up" for Local AI: the screen it opens is
    /// where models are downloaded, chosen and deleted, and it stays useful long
    /// after the first one is installed.
    private var configureLabel: String {
        if option.metadata.kind == .downloadedLocalModel { return "Manage Models" }
        return option.isAvailable ? "Edit configuration" : "Set up"
    }

    private var symbol: String {
        switch option.metadata.kind {
        case .appleFoundationModels: return "apple.logo"
        case .downloadedLocalModel: return "iphone"
        case .remoteAPI: return "cloud"
        case .development: return "hammer"
        }
    }

    /// Short, concrete trade-offs — the things that actually decide the choice.
    private var tagline: String {
        switch option.metadata.kind {
        case .appleFoundationModels:
            // Not "works offline" flatly: it needs a device that supports
            // Apple Intelligence, with it switched on and the model
            // downloaded. The status pill and reason line say whether this
            // particular phone qualifies.
            return "Private · Runs on this device · No API key"
        case .downloadedLocalModel:
            // Not "works offline" flatly, for the same reason as Apple's above:
            // it needs a model downloaded first, and the status line says
            // whether this phone has one.
            return "Private · Runs on this device · No API key"
        case .remoteAPI:
            return "Most capable · Needs internet · Your messages go to the service"
        case .development:
            return "Development stand-in"
        }
    }
}

/// The state badge: Ready / Setup needed / Not available yet.
private struct StatusPill: View {
    let option: ProviderOption

    var body: some View {
        Text(option.statusLabel)
            .font(.caption2.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.14)))
    }

    private var tint: Color {
        switch option.availability {
        case .available: return .green
        case .configurationRequired: return .orange
        case .temporarilyUnavailable: return .orange
        case .unsupported: return .secondary
        }
    }
}

#Preview {
    // TODO-XCODE: Verify SwiftUI preview.
    NavigationStack {
        ModelSelectorView()
    }
    .environment(AppModel(environment: AppEnvironment.makeDemo()))
}
