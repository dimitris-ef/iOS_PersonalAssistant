import SpeechToText
import SpeechToTextLocal
import SpeechToTextOpenAI
import SwiftUI

/// Voice: which engine transcribes, which model it uses, and where the audio
/// goes.
///
/// ## What this screen is careful about
///
/// Section 66. The single most important thing here is that a user reading it
/// understands they are choosing something *different* from the assistant's
/// model. The header says "Voice Transcription", the footer names the assistant
/// setting and where it lives, and the two never appear in the same list. A
/// person who has set up a local Llama assistant should be able to pick OpenAI
/// transcription without wondering whether they have just changed their
/// assistant.
///
/// ## Why the privacy line is per provider
///
/// Section 47 and 48. "Audio is sent to OpenAI" is not a footnote — it is the
/// consequence of the selection, so it appears on the row itself, before the
/// choice is made, and again as the section footer once it is. Nothing is
/// buried behind a disclosure triangle.
struct VoiceSettingsView: View {
    @Environment(AppModel.self) private var model

    @State private var selection: SpeechSelection = .default
    @State private var availabilities: [SpeechToTextProviderID: SpeechToTextAvailability] = [:]

    var body: some View {
        Form {
            providerSection
            modelSection
            assistantSeparationSection
            spokenRepliesSection
        }
        .navigationTitle("Voice")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            selection = model.speechSelection
            availabilities = await model.speechAvailabilities()
        }
    }

    // MARK: Provider

    private var providerSection: some View {
        Section {
            ForEach(SpeechProviderPresentation.all, id: \.id) { provider in
                Button {
                    Task { await select(provider.id) }
                } label: {
                    ProviderRow(
                        provider: provider,
                        availability: availabilities[provider.id],
                        isSelected: selection.providerID == provider.id
                    )
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("Speech-to-Text Provider")
        } footer: {
            // The consequence of the current choice, stated plainly.
            Text(SpeechProviderPresentation.privacyFooter(for: selection.providerID))
        }
    }

    // MARK: Model

    /// Only shown when the selected provider actually offers a choice.
    ///
    /// Section 67: Apple exposes no meaningful model selection, so presenting an
    /// empty picker would be inventing a decision the user cannot make.
    @ViewBuilder
    private var modelSection: some View {
        switch selection.providerID {
        case .localWhisper:
            Section {
                NavigationLink {
                    SpeechModelsView()
                } label: {
                    LabeledContent("Speech Model") {
                        Text(localModelName)
                            .foregroundStyle(.secondary)
                    }
                }
                if let availability = availabilities[.localWhisper] {
                    LabeledContent("Status") {
                        Text(availability.summary)
                            .foregroundStyle(availability.isReady ? Color.secondary : Color.orange)
                    }
                }
            } header: {
                Text("On-Device Model")
            } footer: {
                Text(
                    "Manage Speech Models to download, switch or remove models. "
                        + "Deleting a speech model does not affect your assistant model."
                )
            }

        case .openAI:
            Section {
                Picker("OpenAI Speech Model", selection: openAIModelBinding) {
                    ForEach(OpenAITranscriptionModel.catalog, id: \.id) { descriptor in
                        Text(descriptor.displayName).tag(descriptor.id)
                    }
                }
                if let availability = availabilities[.openAI],
                   case .misconfigured(let reason) = availability {
                    // Section 69: points at the existing secure settings rather
                    // than offering a second API-key field.
                    Text(reason)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Cloud Model")
            } footer: {
                Text(
                    "Uses the OpenAI key from Remote AI settings. There is no "
                        + "separate key for transcription."
                )
            }

        case .apple:
            if let availability = availabilities[.apple] {
                Section {
                    LabeledContent("Status") {
                        Text(availability.summary)
                            .foregroundStyle(availability.isReady ? Color.secondary : Color.orange)
                    }
                    LabeledContent("Language") {
                        Text(languageName)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Apple Speech")
                } footer: {
                    Text("Apple Speech follows your device language and needs no download.")
                }
            }

        default:
            EmptyView()
        }
    }

    // MARK: Separation from the assistant

    /// Section 66, made explicit rather than implied.
    ///
    /// A read-only row naming the assistant provider, with a link to where it
    /// is changed. It exists purely so the distinction is visible on the screen
    /// where the confusion would otherwise happen.
    private var assistantSeparationSection: some View {
        Section {
            LabeledContent("Assistant AI") {
                Text(model.assistantProviderDisplayName)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Not This Setting")
        } footer: {
            Text(
                "Your assistant model is separate and is changed in Settings › "
                    + "Assistant AI. Changing your transcription provider does not "
                    + "change which AI answers you."
            )
        }
    }

    // MARK: Spoken replies

    /// Preserved from Part 5, unchanged. Section 87: changing the transcription
    /// provider must not affect speech output.
    private var spokenRepliesSection: some View {
        Section {
            Toggle("Speak Assistant Replies", isOn: spokenRepliesBinding)
        } footer: {
            Text("Reads replies aloud after a voice request.")
        }
    }

    // MARK: Actions

    private func select(_ id: SpeechToTextProviderID) async {
        selection.providerID = id
        // A provider with its own model needs a sensible default the moment it
        // is chosen, or the first thing the user says goes nowhere.
        switch id {
        case .localWhisper:
            if selection.modelID == nil {
                selection.modelID = LocalSpeechModelCatalog.defaultModelID
            }
        case .openAI:
            if selection.modelID == nil || OpenAITranscriptionModel.model(
                for: selection.modelID ?? ""
            ) == nil {
                selection.modelID = OpenAITranscriptionModel.defaultModelID
            }
        default:
            selection.modelID = nil
        }
        await model.setSpeechSelection(selection)
        availabilities = await model.speechAvailabilities()
    }

    private var openAIModelBinding: Binding<SpeechModelIdentifier> {
        Binding(
            get: { selection.modelID ?? OpenAITranscriptionModel.defaultModelID },
            set: { newValue in
                selection.modelID = newValue
                Task { await model.setSpeechSelection(selection) }
            }
        )
    }

    private var spokenRepliesBinding: Binding<Bool> {
        Binding(
            get: { model.speaksReplies },
            set: { model.setSpeaksReplies($0) }
        )
    }

    private var localModelName: String {
        guard let id = selection.modelID,
              let descriptor = LocalSpeechModelCatalog.model(for: id)
        else { return "None" }
        return descriptor.displayName
    }

    private var languageName: String {
        let locale = selection.locale ?? Locale.current
        return Locale.current.localizedString(forIdentifier: locale.identifier)
            ?? locale.identifier
    }
}

/// One provider row: name, one line about it, and its current state.
private struct ProviderRow: View {
    let provider: SpeechProviderPresentation
    let availability: SpeechToTextAvailability?
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                    .foregroundStyle(.primary)
                Text(provider.summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let availability, !availability.isReady {
                    // Truthful state on the row, before the choice is made.
                    Text(availability.summary)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
                    .accessibilityLabel("Selected")
            }
        }
        .contentShape(Rectangle())
    }
}

/// How each provider is described.
///
/// The words live here rather than in the view so the privacy sentences are in
/// one place and can be checked against what the providers actually do.
struct SpeechProviderPresentation {
    let id: SpeechToTextProviderID
    let displayName: String
    let summary: String

    static let all: [SpeechProviderPresentation] = [
        SpeechProviderPresentation(
            id: .apple,
            displayName: "Apple Speech",
            summary: "Uses Apple's native speech recognition. No download needed."
        ),
        SpeechProviderPresentation(
            id: .localWhisper,
            displayName: "Local AI",
            summary: "Runs a downloaded Whisper model on this iPhone."
        ),
        SpeechProviderPresentation(
            id: .openAI,
            displayName: "OpenAI",
            summary: "Sends audio to OpenAI for transcription."
        ),
    ]

    /// The privacy consequence of a selection, in one sentence.
    ///
    /// Section 47 is explicit that the cloud case must not be buried, and
    /// section 17 that the Apple case must not over-claim. Note that Apple's
    /// line does not say "on-device": the specific answer depends on the device
    /// and the language, and `AppleSpeechToTextProvider.privacyStatus` reports
    /// it where it is known.
    static func privacyFooter(for id: SpeechToTextProviderID) -> String {
        switch id {
        case .localWhisper:
            return "Runs on this device. Audio is not uploaded for transcription, "
                + "and transcription works without an internet connection."
        case .openAI:
            return "Audio is sent to OpenAI for transcription when this provider "
                + "is selected. It is not stored on this device afterwards."
        case .apple:
            return "Uses Apple's speech-recognition system. Depending on your "
                + "device and language, Apple may process audio on its servers."
        default:
            return ""
        }
    }
}
