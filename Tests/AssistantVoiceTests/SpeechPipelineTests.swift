import Foundation
import SpeechToText
import XCTest

@testable import AssistantVoice

/// The pipeline: shared microphone, selected provider, Part 5's delegate.
///
/// These are the tests that show the seam works — the same `VoiceCoordinator`
/// driving three different engines, with the guarantees that matter (one
/// submission, no submission after Cancel, nothing from a stale session) held
/// by the layer rather than by each provider.
final class SpeechPipelineTests: XCTestCase {

    // MARK: Harness

    /// Collects delegate callbacks, which arrive from arbitrary executors.
    private final class Recorder: SpeechInputDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var _transcripts: [SpeechTranscript] = []
        private var _errors: [VoiceError] = []

        var transcripts: [SpeechTranscript] {
            lock.lock(); defer { lock.unlock() }
            return _transcripts
        }
        var errors: [VoiceError] {
            lock.lock(); defer { lock.unlock() }
            return _errors
        }
        var finals: [String] {
            transcripts.filter(\.isFinal).map(\.text)
        }
        var partials: [String] {
            transcripts.filter { !$0.isFinal }.map(\.text)
        }

        func speechInput(_ session: VoiceSessionID, didProduce transcript: SpeechTranscript) {
            lock.lock(); _transcripts.append(transcript); lock.unlock()
        }
        func speechInput(_ session: VoiceSessionID, didFailWith error: VoiceError) {
            lock.lock(); _errors.append(error); lock.unlock()
        }
    }

    private func makePipeline(
        provider: MockSpeechToTextProvider,
        microphone: MockMicrophoneCaptureService = MockMicrophoneCaptureService(),
        selected: SpeechToTextProviderID? = nil
    ) -> SpeechPipelineInputService {
        let id = selected ?? provider.id
        return SpeechPipelineInputService(
            microphone: microphone,
            registry: SpeechToTextProviderRegistry(providers: [provider]),
            configuration: { SpeechToTextConfiguration(providerID: id) }
        )
    }

    /// Waits for a condition the pump fulfils asynchronously.
    ///
    /// Polling rather than a fixed sleep: the work is a handful of actor hops
    /// and completes in microseconds, so this returns immediately in practice
    /// while still tolerating a loaded CI runner.
    private func eventually(
        timeout: TimeInterval = 2,
        _ condition: @escaping () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    // MARK: Stop

    /// Section 57 and 96. Stop closes the microphone, the provider finalizes,
    /// and exactly one final transcript reaches the delegate.
    func testStopProducesOneFinalTranscript() async {
        let provider = MockSpeechToTextProvider(
            behaviour: .finalOnly("Remind me tomorrow to call the dentist.")
        )
        let microphone = MockMicrophoneCaptureService()
        let pipeline = makePipeline(provider: provider, microphone: microphone)
        let recorder = Recorder()
        let session = VoiceSessionID()

        await pipeline.startListening(session: session, delegate: recorder)
        await microphone.emitAudio(seconds: 1)
        await pipeline.stopListening()

        await eventually { recorder.finals.count == 1 }

        XCTAssertEqual(recorder.finals, ["Remind me tomorrow to call the dentist."])
        XCTAssertTrue(recorder.errors.isEmpty)

        // The microphone closed cleanly rather than being cancelled.
        let stops = await microphone.stopCount
        let capturing = await microphone.isCapturing
        XCTAssertEqual(stops, 1)
        XCTAssertFalse(capturing)
    }

    /// Section 99. Partials reach the UI; only the final is marked final, and
    /// the coordinator above submits only that one.
    func testPartialsArriveAndOnlyTheFinalIsFinal() async {
        let provider = MockSpeechToTextProvider(
            behaviour: .transcribes(
                partials: ["Remind me tomorrow", "Remind me tomorrow to call"],
                final: "Remind me tomorrow to call the dentist."
            )
        )
        let pipeline = makePipeline(provider: provider)
        let recorder = Recorder()

        await pipeline.startListening(session: VoiceSessionID(), delegate: recorder)
        await pipeline.stopListening()
        await eventually { recorder.finals.count == 1 }

        XCTAssertEqual(
            recorder.partials,
            ["Remind me tomorrow", "Remind me tomorrow to call"]
        )
        XCTAssertEqual(recorder.finals, ["Remind me tomorrow to call the dentist."])
    }

    // MARK: Cancel

    /// Section 58 and 100. A partial exists, the user cancels, and no
    /// transcript is ever delivered — so `VoiceCoordinator` never submits and
    /// no user message is created.
    func testCancelDuringPartialDeliversNoTranscript() async {
        let provider = MockSpeechToTextProvider(
            behaviour: .transcribes(partials: ["Remind me"], final: "Remind me to do it.")
        )
        let microphone = MockMicrophoneCaptureService()
        let pipeline = makePipeline(provider: provider, microphone: microphone)
        let recorder = Recorder()

        await pipeline.startListening(session: VoiceSessionID(), delegate: recorder)
        await microphone.emitAudio(seconds: 1)
        await pipeline.cancelListening()

        // Give any late event every chance to arrive and be wrongly delivered.
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(recorder.finals.isEmpty, "a cancelled session produced a transcript")
        let cancels = await microphone.cancelCount
        let capturing = await microphone.isCapturing
        XCTAssertEqual(cancels, 1)
        XCTAssertFalse(capturing, "the microphone was left open after Cancel")

        let providerCancels = await provider.cancelCount
        XCTAssertEqual(providerCancels, 1, "the provider's work was not cancelled")
    }

    // MARK: Stale sessions

    /// Section 102. Session A is cancelled, session B starts, and A's late
    /// event is ignored rather than delivered as though it were B's.
    func testEventsFromAReplacedSessionAreIgnored() async {
        let provider = MockSpeechToTextProvider(behaviour: .hangs)
        let pipeline = makePipeline(provider: provider)
        let recorder = Recorder()

        let sessionA = VoiceSessionID()
        await pipeline.startListening(session: sessionA, delegate: recorder)
        await pipeline.cancelListening()

        let sessionB = VoiceSessionID()
        await provider.setBehaviour(.finalOnly("This is session B."))
        await pipeline.startListening(session: sessionB, delegate: recorder)
        await pipeline.stopListening()

        await eventually { recorder.finals.count == 1 }

        XCTAssertEqual(recorder.finals, ["This is session B."])
    }

    /// Section 59. Retry builds fresh provider state rather than reusing a
    /// finished session — the second attempt transcribes.
    func testRetryStartsACleanSession() async {
        let provider = MockSpeechToTextProvider(behaviour: .finalOnly("First."))
        let pipeline = makePipeline(provider: provider)
        let recorder = Recorder()

        await pipeline.startListening(session: VoiceSessionID(), delegate: recorder)
        await pipeline.stopListening()
        await eventually { recorder.finals.count == 1 }

        await provider.setBehaviour(.finalOnly("Second."))
        await pipeline.startListening(session: VoiceSessionID(), delegate: recorder)
        await pipeline.stopListening()
        await eventually { recorder.finals.count == 2 }

        XCTAssertEqual(recorder.finals, ["First.", "Second."])
        let starts = await provider.startCount
        XCTAssertEqual(starts, 2, "Retry reused a completed provider session")
    }

    // MARK: Empty transcript

    /// Section 62. Silence produces "I didn't catch that", not an empty
    /// message.
    func testSilenceIsReportedRatherThanSubmittedAsEmpty() async {
        let provider = MockSpeechToTextProvider(behaviour: .finalOnly("   "))
        let pipeline = makePipeline(provider: provider)
        let recorder = Recorder()

        await pipeline.startListening(session: VoiceSessionID(), delegate: recorder)
        await pipeline.stopListening()
        await eventually { !recorder.errors.isEmpty }

        XCTAssertTrue(recorder.finals.isEmpty)
        XCTAssertEqual(recorder.errors, [.noSpeechDetected])
    }

    // MARK: Provider independence

    /// Section 94 and 95, at this layer: three different engines, one identical
    /// transcript, one identical delegate callback. Nothing downstream can tell
    /// which engine produced it.
    func testEveryProviderProducesTheSameDelegateCallback() async {
        let transcript = "Remind me tomorrow at ten to call the dentist."

        for id in [SpeechToTextProviderID.apple, .localWhisper, .openAI] {
            let provider = MockSpeechToTextProvider(id: id, behaviour: .finalOnly(transcript))
            let pipeline = makePipeline(provider: provider)
            let recorder = Recorder()

            await pipeline.startListening(session: VoiceSessionID(), delegate: recorder)
            await pipeline.stopListening()
            await eventually { recorder.finals.count == 1 }

            XCTAssertEqual(
                recorder.finals, [transcript],
                "\(id) produced a different transcript to the others"
            )
            XCTAssertEqual(recorder.transcripts.count, 1)
        }
    }

    // MARK: Availability

    /// Section 104. Selecting the local provider with no model downloaded
    /// reports unavailable *before* the microphone opens — no recording
    /// indicator, no infinite "processing".
    func testAMissingLocalModelNeverOpensTheMicrophone() async {
        let provider = MockSpeechToTextProvider(
            id: .localWhisper,
            behaviour: .finalOnly("unused"),
            availability: .needsModelDownload
        )
        let microphone = MockMicrophoneCaptureService()
        let pipeline = makePipeline(provider: provider, microphone: microphone)
        let recorder = Recorder()

        await pipeline.startListening(session: VoiceSessionID(), delegate: recorder)

        XCTAssertEqual(recorder.errors, [.recognitionUnavailable])
        let starts = await microphone.startCount
        XCTAssertEqual(starts, 0, "the microphone opened for a session that could not transcribe")
        let providerStarts = await provider.startCount
        XCTAssertEqual(providerStarts, 0)
    }

    /// Section 41. A selected provider missing from this build fails honestly
    /// rather than resolving to whichever other engine is present.
    func testAMissingProviderFailsRatherThanSubstituting() async {
        let openAI = MockSpeechToTextProvider(id: .openAI, behaviour: .finalOnly("uploaded!"))
        let microphone = MockMicrophoneCaptureService()
        let pipeline = SpeechPipelineInputService(
            microphone: microphone,
            registry: SpeechToTextProviderRegistry(providers: [openAI]),
            configuration: { SpeechToTextConfiguration(providerID: .localWhisper) }
        )
        let recorder = Recorder()

        await pipeline.startListening(session: VoiceSessionID(), delegate: recorder)

        XCTAssertEqual(recorder.errors, [.recognitionUnavailable])
        let openAIStarts = await openAI.startCount
        XCTAssertEqual(openAIStarts, 0, "audio was routed to OpenAI without the user choosing it")
        let micStarts = await microphone.startCount
        XCTAssertEqual(micStarts, 0)
    }

    /// Section 16. With Whisper selected there is no speech-recognition
    /// authorization to ask for, and the pipeline does not invent one.
    func testALocalProviderNeedsNoSpeechRecognitionPermission() async {
        let provider = MockSpeechToTextProvider(id: .localWhisper)
        let pipeline = makePipeline(provider: provider)

        let permissions = await pipeline.requestPermissions()

        XCTAssertEqual(permissions.microphone, .authorized)
        XCTAssertEqual(permissions.speechRecognition, .authorized)
        XCTAssertEqual(permissions.combined, .authorized)
    }

    /// A denied microphone stops everything, whichever provider is selected.
    func testADeniedMicrophoneBlocksEveryProvider() async {
        for id in [SpeechToTextProviderID.apple, .localWhisper, .openAI] {
            let provider = MockSpeechToTextProvider(id: id)
            let microphone = MockMicrophoneCaptureService(permission: .denied)
            let pipeline = makePipeline(provider: provider, microphone: microphone)

            let permissions = await pipeline.currentPermissions()
            XCTAssertEqual(permissions.combined, .denied)
            XCTAssertEqual(permissions.combined.failure, .microphonePermissionDenied)
        }
    }

    // MARK: Privacy reporting

    /// Section 17 and 48. The privacy claim comes from the provider's declared
    /// capabilities, not from an assumption about what "local" means.
    func testRecognitionModeReflectsWhetherAudioLeavesTheDevice() async {
        let onDevice = MockSpeechToTextProvider(
            id: .localWhisper,
            capabilities: SpeechToTextCapabilities(
                supportsPartialResults: false,
                supportsOffline: true,
                sendsAudioOffDevice: false
            )
        )
        let cloud = MockSpeechToTextProvider(
            id: .openAI,
            capabilities: SpeechToTextCapabilities(
                supportsPartialResults: false,
                supportsOffline: false,
                sendsAudioOffDevice: true
            )
        )

        let localMode = await makePipeline(provider: onDevice).recognitionMode()
        let cloudMode = await makePipeline(provider: cloud).recognitionMode()

        XCTAssertEqual(localMode, .onDevice)
        XCTAssertEqual(cloudMode, .server)
    }

    // MARK: Failure

    /// Section 111. A provider failure ends the session cleanly, closes the
    /// microphone, and delivers no transcript.
    func testAProviderFailureClosesTheMicrophoneAndSubmitsNothing() async {
        let provider = MockSpeechToTextProvider(
            behaviour: .fails(.networkUnavailable)
        )
        let microphone = MockMicrophoneCaptureService()
        let pipeline = makePipeline(provider: provider, microphone: microphone)
        let recorder = Recorder()

        await pipeline.startListening(session: VoiceSessionID(), delegate: recorder)
        await eventually { !recorder.errors.isEmpty }

        XCTAssertTrue(recorder.finals.isEmpty)
        XCTAssertEqual(recorder.errors, [.recognitionUnavailable])
        await eventually { true }
        let capturing = await microphone.isCapturing
        XCTAssertFalse(capturing, "the microphone was left open after a provider failure")
    }

    /// The error mapping is total and loses nothing that changes what the user
    /// is offered.
    func testEverySpeechErrorMapsToAVoiceError() {
        let cases: [(SpeechToTextError, VoiceError)] = [
            (.microphonePermissionDenied, .microphonePermissionDenied),
            (.speechPermissionDenied, .speechPermissionDenied),
            (.unsupportedDevice(reason: "x"), .unsupported),
            (.noSpeechDetected, .noSpeechDetected),
            (.modelNotDownloaded, .recognitionUnavailable),
            (.authenticationFailed(reason: "x"), .recognitionUnavailable),
            (.networkUnavailable, .recognitionUnavailable),
            (.insufficientMemory, .recognitionFailed),
            (.transcriptionFailed(reason: "x"), .recognitionFailed),
        ]
        for (speech, voice) in cases {
            XCTAssertEqual(SpeechPipelineInputService.map(speech), voice, "\(speech)")
        }
    }
}
