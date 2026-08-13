import AssistantAI
import AssistantDomain
import SwiftUI

/// Choose which model does the reasoning.
///
/// Two things this screen must get right:
///
/// 1. **It tells the truth.** Availability comes from each provider, and none
///    of them can serve a request yet, so each row says why.
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
                        isSelected: option.id == model.settings.preferredProviderID
                    ) {
                        Task { await model.selectProvider(option.id) }
                    }
                }
            } footer: {
                Text("Your conversations, tasks and memory belong to the app, not to the model. Switching never moves or resets them.")
            }

            Section {
                Label {
                    Text("No model is connected yet, so replies come from a scripted development stand-in.")
                } icon: {
                    Image(systemName: "info.circle")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("AI Model")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One provider, with its selling points and its honest status.
private struct ModelOptionRow: View {
    let option: ProviderOption
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: Theme.Spacing.md) {
                Image(systemName: symbol)
                    .font(.body)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.accentColor.opacity(0.12)))

                VStack(alignment: .leading, spacing: 4) {
                    Text(option.metadata.displayName)
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Text(tagline)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    if let reason = option.unavailableReason {
                        Label(reason, systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(.orange)
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
            .padding(.vertical, Theme.Spacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
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
            return "Private · Fast · Works offline"
        case .downloadedLocalModel:
            return "Runs on this device · Downloaded separately"
        case .remoteAPI:
            return "Most capable · Needs internet"
        case .development:
            return "Development stand-in"
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
