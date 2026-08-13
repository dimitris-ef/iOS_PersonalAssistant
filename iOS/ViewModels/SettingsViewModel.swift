import AssistantDomain
import Foundation
import Observation

/// Screen state for Settings.
///
/// Assistant persona and response length are held here rather than in the
/// domain's `AssistantSettings` for now: nothing consumes them yet. They move
/// into the domain when `SystemPromptBuilder` starts reading them, which is the
/// point at which they stop being presentation and start being behaviour.
@MainActor
@Observable
final class SettingsViewModel {
    enum Route: Identifiable, Hashable {
        case modelSelector
        case privacy(PrivacyTopic)

        var id: String {
            switch self {
            case .modelSelector: return "model"
            case .privacy(let topic): return "privacy-\(topic.rawValue)"
            }
        }
    }

    var isConfirmingReset = false

    func selectedProviderName(for model: AppModel) -> String {
        guard
            let id = model.settings.preferredProviderID,
            let option = model.providerOptions.first(where: { $0.id == id })
        else { return "Not selected" }
        return option.metadata.displayName
    }

    func selectedProviderIsAvailable(for model: AppModel) -> Bool {
        guard
            let id = model.settings.preferredProviderID,
            let option = model.providerOptions.first(where: { $0.id == id })
        else { return false }
        return option.isAvailable
    }
}

/// The privacy topics that get their own explanatory screen.
enum PrivacyTopic: String, CaseIterable, Identifiable {
    case personalMemory
    case localData
    case aiProvider
    case permissions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .personalMemory: return "Personal Memory"
        case .localData: return "Local Data"
        case .aiProvider: return "AI Provider"
        case .permissions: return "Permissions"
        }
    }

    var symbol: String {
        switch self {
        case .personalMemory: return "brain"
        case .localData: return "internaldrive"
        case .aiProvider: return "cpu"
        case .permissions: return "lock.shield"
        }
    }

    /// Written to be true of the app as it exists now, not as it is planned.
    var explanation: String {
        switch self {
        case .personalMemory:
            return """
            Memory holds the things worth carrying between conversations — how long you take to get \
            ready, what you prefer, who matters to you. You can read all of it on the Memory screen, \
            edit any entry, and delete anything at any time.

            Memory belongs to the app, not to whichever AI model is running. Changing the model does \
            not move, copy or reset it.
            """
        case .localData:
            return """
            Right now everything lives in memory and is lost when the app closes. Nothing is written \
            to disk, nothing leaves the device, and there is no account or sync.

            Persistent on-device storage is part of the next stage of work.
            """
        case .aiProvider:
            return """
            The assistant is designed so the model is replaceable. Apple's on-device model, a model \
            you download, and a cloud model all sit behind the same interface, and none of them owns \
            your conversations, tasks or memory.

            None of the three can answer yet. Replies in this build come from a scripted development \
            stand-in, which is why the Assistant screen says so.
            """
        case .permissions:
            return """
            The assistant will eventually need access to your calendar, reminders, notifications and \
            alarms. It has none of those yet — every one of those services is a mock that records \
            what was asked for and reports it as simulated.

            When the real integrations arrive, each permission will be requested only when it is \
            first needed, and the app will keep working without any of them.
            """
        }
    }
}
