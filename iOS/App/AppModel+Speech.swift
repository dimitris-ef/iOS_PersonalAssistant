import Foundation
import Observation
import SpeechToText
import SpeechToTextLocal

/// The speech-to-text half of `AppModel`.
///
/// Kept in its own file because it is a genuinely separate concern from the
/// assistant state the rest of `AppModel` holds — and because that separation
/// is the point of the milestone. Nothing here reads or writes the assistant's
/// provider selection, and a reader can check that by the fact that no line
/// below mentions it.
@MainActor
extension AppModel {

    // MARK: Selection

    /// What the user has chosen for transcription.
    var speechSelection: SpeechSelection {
        environment.speechSelection
    }

    /// Changes the transcription provider or model.
    ///
    /// Section 36: this writes `speech.*` keys and nothing else. The assistant's
    /// provider and model are untouched — not by convention, but because this
    /// method has no way to reach them.
    func setSpeechSelection(_ selection: SpeechSelection) async {
        environment.updateSpeechSelection(selection)
        if selection.providerID == .localWhisper, let modelID = selection.modelID {
            await environment.speechModels?.select(modelID)
        }
    }

    /// Availability for every provider, for the Settings list.
    func speechAvailabilities() async -> [SpeechToTextProviderID: SpeechToTextAvailability] {
        await environment.speechProviders.availabilities(
            for: environment.speechSelection.configuration()
        )
    }

    /// The selected transcription provider's name, for the Settings row.
    var speechProviderDisplayName: String {
        switch speechSelection.providerID {
        case .apple: return "Apple Speech"
        case .localWhisper: return "Local AI"
        case .openAI: return "OpenAI"
        default: return speechSelection.providerID.rawValue
        }
    }

    /// The assistant provider's name, shown read-only on the Voice screen so
    /// the distinction between the two selections is visible where it matters.
    var assistantProviderDisplayName: String {
        selectedProviderOption?.metadata.displayName ?? "Not selected"
    }

    // MARK: On-device models

    func speechModelStatuses() async -> [LocalSpeechModelManager.Status] {
        guard let models = environment.speechModels else { return [] }
        return await models.statuses(for: environment.speechSelection.locale)
    }

    func downloadSpeechModel(_ id: SpeechModelIdentifier) async throws {
        guard let models = environment.speechModels else {
            throw SpeechToTextError.unsupportedDevice(
                reason: "On-device speech isn't available in this build."
            )
        }
        _ = try await models.download(id)
        // The first model downloaded becomes the selection, so the user does
        // not have to make a second choice to use what they just fetched.
        if environment.speechSelection.modelID == nil {
            var selection = environment.speechSelection
            selection.modelID = id
            environment.updateSpeechSelection(selection)
        }
    }

    func cancelSpeechModelDownload(_ id: SpeechModelIdentifier) async {
        await environment.speechModels?.cancelDownload(id)
    }

    func selectSpeechModel(_ id: SpeechModelIdentifier) async {
        var selection = environment.speechSelection
        selection.modelID = id
        await setSpeechSelection(selection)
    }

    /// Section 39. Removes the model file and nothing else.
    func deleteSpeechModel(_ id: SpeechModelIdentifier) async throws {
        guard let models = environment.speechModels else { return }
        try await models.delete(id)
        if environment.speechSelection.modelID == id {
            var selection = environment.speechSelection
            selection.modelID = nil
            environment.updateSpeechSelection(selection)
        }
    }

    // MARK: Spoken replies

    /// Preserved from Part 5, and deliberately reached through the same setting
    /// the existing Settings screen writes — section 87: changing the
    /// transcription provider must not affect speech output, and two toggles
    /// writing the same preference would be two things that can disagree.
    var speaksReplies: Bool {
        settings.voice.speaksReplies
    }

    func setSpeaksReplies(_ enabled: Bool) {
        Task { await updateSettings { $0.voice.speaksReplies = enabled } }
    }
}
