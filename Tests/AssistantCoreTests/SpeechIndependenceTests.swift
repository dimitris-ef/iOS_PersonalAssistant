import AssistantAI
import AssistantDomain
import AssistantPersistence
import AssistantPlatform
import AssistantVoice
import Foundation
import MockPlatform
import SpeechToText
import XCTest

@testable import AssistantCore

/// The claim Part 13 actually makes, tested against a real `AssistantEngine`:
/// changing who transcribes changes nothing about who reasons, and a
/// transcript arrives at the assistant indistinguishable from typed text.
///
/// Sections 94, 95, 96, 97, 98 and 114.
final class SpeechIndependenceTests: XCTestCase {

    // MARK: Harness

    /// Everything below the transcript, wired for real.
    ///
    /// Not a mock of the assistant — the actual engine, repositories, memory
    /// service and command service. A test that asserted "the transcript
    /// reached a stub" would prove nothing about section 96, which is a claim
    /// about the *production* submission path.
    private struct Harness {
        let repositories = AssistantRepositories.ephemeral()
        let services = PlatformServices.mock()
        let provider: StubAIProvider
        let engine: AssistantEngine
        let commands: AssistantCommandService

        init(providerID: AIProviderIdentifier, reply: String) {
            let clock = FixedDateProvider(now: Date(timeIntervalSince1970: 1_760_000_000))
            self.provider = StubAIProvider(id: providerID, text: reply)
            let engine = AssistantEngine(
                providers: AIProviderRegistry(providers: [provider]),
                repositories: repositories,
                services: services,
                dateProvider: clock
            )
            self.engine = engine
            self.commands = AssistantCommandService(
                engine: engine,
                repositories: repositories,
                memory: MemoryService(
                    repository: repositories.memories,
                    relations: repositories.memoryRelations,
                    embeddings: repositories.memoryEmbeddings,
                    dateProvider: clock
                ),
                dateProvider: clock
            )
        }
    }

    /// Runs a full voice interaction and returns what the provider was asked.
    ///
    /// This is the whole pipeline: a mock speech engine, the shared microphone,
    /// `SpeechPipelineInputService`, and a submission closure that calls the
    /// real engine — the same closure shape `AppModel` supplies.
    private func speak(
        _ transcript: String,
        through speechProviderID: SpeechToTextProviderID,
        into harness: Harness
    ) async -> String? {
        let speech = MockSpeechToTextProvider(
            id: speechProviderID,
            behaviour: .finalOnly(transcript)
        )
        let microphone = MockMicrophoneCaptureService()
        let pipeline = SpeechPipelineInputService(
            microphone: microphone,
            registry: SpeechToTextProviderRegistry(providers: [speech]),
            configuration: { SpeechToTextConfiguration(providerID: speechProviderID) }
        )

        let submitted = SubmittedText()
        let delegate = SubmittingDelegate(submitted: submitted)

        await pipeline.startListening(session: VoiceSessionID(), delegate: delegate)
        await microphone.emitAudio(seconds: 1)
        await pipeline.stopListening()

        // The pump is a detached task; wait for the transcript to land.
        for _ in 0..<200 {
            if submitted.value != nil { break }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        guard let text = submitted.value else { return nil }

        // The submission path: exactly what typed input calls.
        if let conversation = try? await harness.engine.startConversation() {
            _ = try? await harness.engine.send(text, in: conversation.id)
        }
        return text
    }

    /// Captures the final transcript the way `VoiceCoordinator` would.
    private final class SubmittedText: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: String?
        var value: String? {
            lock.lock(); defer { lock.unlock() }
            return _value
        }
        func set(_ text: String) {
            lock.lock(); _value = text; lock.unlock()
        }
    }

    private final class SubmittingDelegate: SpeechInputDelegate, @unchecked Sendable {
        private let submitted: SubmittedText
        init(submitted: SubmittedText) { self.submitted = submitted }

        func speechInput(_ session: VoiceSessionID, didProduce transcript: SpeechTranscript) {
            guard transcript.isFinal else { return }
            submitted.set(transcript.text)
        }
        func speechInput(_ session: VoiceSessionID, didFailWith error: VoiceError) {}
    }

    // MARK: Section 94 — provider independence

    /// The same spoken words, three speech providers, two assistant providers.
    /// The engine receives identical text every time.
    func testTheAssistantReceivesIdenticalTextWhicheverProviderTranscribed() async throws {
        let spoken = "Remind me tomorrow at ten to call the dentist."

        for assistantID: AIProviderIdentifier in ["remote.stub", "local.stub", "apple.stub"] {
            for speechID: SpeechToTextProviderID in [.apple, .localWhisper, .openAI] {
                let harness = Harness(providerID: assistantID, reply: "Added it.")
                let submitted = await speak(spoken, through: speechID, into: harness)

                XCTAssertEqual(
                    submitted, spoken,
                    "speech=\(speechID) assistant=\(assistantID) altered the transcript"
                )

                // And the engine saw exactly that text, with nothing about
                // speech attached to it (section 72).
                let request = try XCTUnwrap(harness.provider.receivedRequests.last)
                let userText = request.messages.compactMap { message -> String? in
                    message.role == .user ? message.content : nil
                }.last
                XCTAssertEqual(userText, spoken)
            }
        }
    }

    // MARK: Section 95 — switching providers

    /// Apple → Local → OpenAI → Apple. The assistant selection, the
    /// conversations, the memories and the tasks are all where they were.
    func testSwitchingSpeechProvidersLeavesTheAssistantUntouched() async throws {
        let store = InMemorySpeechSettingsStore()
        var selection = SpeechSelection(providerID: .apple)
        selection.save(to: store)

        let harness = Harness(providerID: "remote.stub", reply: "Done.")

        // Something for the assistant side to lose, if switching were to touch
        // it: a task, a memory and a conversation turn.
        _ = try await harness.commands.ask("Remember that I take the 8:15 train.")
        let tasksBefore = try await harness.repositories.tasks.tasks(matching: TaskFilter())
        let memoriesBefore = try await harness.repositories.memories.all()
        let conversationsBefore = try await harness.repositories.conversations.allConversations()

        for provider: SpeechToTextProviderID in [.localWhisper, .openAI, .apple] {
            selection.providerID = provider
            selection.save(to: store)
        }

        // Only the speech keys moved.
        let reloaded = SpeechSelection.load(from: store)
        XCTAssertEqual(reloaded.providerID, .apple)

        let tasksAfter = try await harness.repositories.tasks.tasks(matching: TaskFilter())
        let memoriesAfter = try await harness.repositories.memories.all()
        let conversationsAfter = try await harness.repositories.conversations.allConversations()

        XCTAssertEqual(tasksAfter.count, tasksBefore.count)
        XCTAssertEqual(memoriesAfter.count, memoriesBefore.count)
        XCTAssertEqual(conversationsAfter.count, conversationsBefore.count)
    }

    // MARK: Section 114 — persistence

    /// Both selections persist, and each survives the other changing.
    func testSpeechAndAssistantSelectionsPersistIndependently() {
        let store = InMemorySpeechSettingsStore()

        var selection = SpeechSelection(
            providerID: .localWhisper,
            modelID: "whisper-base-en-q5-1"
        )
        selection.save(to: store)

        // "Restart the repository": a fresh reader over the same backing store.
        let restarted = InMemorySpeechSettingsStore(seed: store.contents)
        let loaded = SpeechSelection.load(from: restarted)

        XCTAssertEqual(loaded.providerID, .localWhisper)
        XCTAssertEqual(loaded.modelID, "whisper-base-en-q5-1")

        // The keys are the speech ones and nothing else — nothing here could
        // have written an assistant setting even by accident.
        let keys = Set(store.contents.keys)
        XCTAssertTrue(keys.allSatisfy { $0.hasPrefix("speech.") })
    }

    // MARK: Section 96 — the submission path

    /// A spoken transcript goes through the same call typed input uses.
    ///
    /// Asserted by *outcome* rather than by inspecting a call stack: the
    /// conversation that results from speaking is byte-for-byte the one that
    /// results from typing the same words.
    func testASpokenTranscriptTakesTheSamePathAsTypedText() async throws {
        let spoken = "What's important today?"

        let typedHarness = Harness(providerID: "remote.stub", reply: "Two things.")
        let typedConversation = try await typedHarness.engine.startConversation()
        _ = try await typedHarness.engine.send(spoken, in: typedConversation.id)
        let typedRequest = try XCTUnwrap(typedHarness.provider.receivedRequests.last)

        let spokenHarness = Harness(providerID: "remote.stub", reply: "Two things.")
        _ = await speak(spoken, through: .localWhisper, into: spokenHarness)
        let spokenRequest = try XCTUnwrap(spokenHarness.provider.receivedRequests.last)

        // Same messages, same tools offered, same everything.
        XCTAssertEqual(
            typedRequest.messages.map(\.content),
            spokenRequest.messages.map(\.content)
        )
        XCTAssertEqual(
            typedRequest.tools.map(\.name).sorted(),
            spokenRequest.tools.map(\.name).sorted()
        )
    }

    // MARK: Sections 97 and 98 — what the speech layer cannot do

    /// Section 98. "Set an alarm for seven" transcribes to plain text; the
    /// speech layer emits no tool call, and the assistant does the rest.
    func testTheSpeechLayerEmitsTextNotToolCalls() async throws {
        let spoken = "Set an alarm for seven."
        let speech = MockSpeechToTextProvider(behaviour: .finalOnly(spoken))

        let session = try await speech.startSession(
            configuration: SpeechToTextConfiguration(providerID: .mock),
            audio: .empty()
        )
        await session.finish()

        var events: [SpeechToTextEvent] = []
        for await event in session.events { events.append(event) }

        // Every event's payload is a string or nothing. There is no case in
        // `SpeechToTextEvent` that could carry a tool call — which is the
        // point, and is why this is checkable at all.
        XCTAssertEqual(events, [.started, .final(spoken)])

        // Separately: the same words through the assistant do reach the tool
        // pipeline, so the capability lives where section 74 puts it.
        let harness = Harness(providerID: "remote.stub", reply: "Set.")
        let conversation = try await harness.engine.startConversation()
        _ = try await harness.engine.send(spoken, in: conversation.id)
        let request = try XCTUnwrap(harness.provider.receivedRequests.last)
        XCTAssertFalse(
            request.tools.isEmpty,
            "the assistant was not offered tools for a request that needs one"
        )
    }

    /// Section 73. Transcription does not consult memory.
    ///
    /// A store full of memories, a deliberately ambiguous utterance, and a
    /// transcript that is exactly what was said — because the speech layer has
    /// no repository to ask.
    func testTranscriptionDoesNotConsultMemory() async throws {
        let harness = Harness(providerID: "remote.stub", reply: "OK.")
        _ = try await harness.commands.ask("Remember that my dentist is Dr Achterberg.")

        // Something a memory-aware transcriber would be tempted to "correct".
        let spoken = "call doctor ackterberg tomorrow"
        let submitted = await speak(spoken, through: .apple, into: harness)

        XCTAssertEqual(
            submitted, spoken,
            "the transcript was rewritten using something the speech layer should not have"
        )
    }
}
