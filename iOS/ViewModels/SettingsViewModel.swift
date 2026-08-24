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
        case remoteAI
        case localModels
        case voice
        case systemSurfaces
        case privacy(PrivacyTopic)

        var id: String {
            switch self {
            case .modelSelector: return "model"
            case .remoteAI: return "remote-ai"
            case .localModels: return "local-models"
            case .voice: return "voice"
            case .systemSurfaces: return "system-surfaces"
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
        model.selectedProviderOption?.isAvailable ?? false
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

            Apple's on-device model and downloaded local models are not implemented yet. A cloud \
            model works once you give it an endpoint, a key and a model name; until then, replies \
            come from a scripted development stand-in and the Assistant screen says so.

            If you configure a cloud model, your messages and the context the assistant assembles \
            are sent to that service. Your API key is kept in the device keychain and is never \
            written to settings, logs or backups.
            """
        case .permissions:
            return """
            The assistant uses your calendar, your reminders, notifications and — on iOS 26 and \
            later — alarms. Each one is asked for the first time something actually needs it, not \
            all at once when you open the app, so the reason for every request is whatever you \
            just asked for.

            The app keeps working without any of them. Anything it cannot do, it says it cannot do \
            rather than failing quietly: an alarm on an iPhone without alarm support is refused \
            instead of being downgraded to a notification you might sleep through.

            Calendar access is asked for in full, because the assistant reads what is already on \
            your day before it agrees to anything. If you allow adding events only, it says so and \
            stops rather than pretending your calendar is empty.

            Notifications carry only identifiers — enough to know which task you answered. Your \
            task titles, notes and anything the assistant remembers about you stay in the app.
            """
        }
    }
}
