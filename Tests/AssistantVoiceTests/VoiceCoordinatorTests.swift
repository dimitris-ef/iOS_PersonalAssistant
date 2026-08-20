import AssistantVoice
import XCTest

/// The coordinator, driven by a mock recogniser.
///
/// `VoiceSessionTests` covers the rules; this covers the wiring — that the
/// effects actually reach the speech service, that permission is asked for
/// before the microphone opens, and that a transcript arrives at the
/// submission closure exactly once.
@MainActor
final class VoiceCoordinatorTests: XCTestCase {

    /// Records what was submitted, standing in for the app's `send(_:)`.
    private final class SubmissionSpy: @unchecked Sendable {
        private(set) var submitted: [String] = []
        func record(_ text: String) { submitted.append(text) }
    }

    private func makeCoordinator(
        input: MockSpeechInputService = MockSpeechInputService(),
        output: MockSpeechOutputService? = nil
    ) -> (VoiceCoordinator, SubmissionSpy) {
        let spy = SubmissionSpy()
        let coordinator = VoiceCoordinator(
            input: input,
            output: output,
            submit: { text in spy.record(text) }
        )
        return (coordinator, spy)
    }

    // MARK: The architecture test

    /// The claim this whole milestone rests on: a spoken sentence reaches the
    /// ordinary submission path, unchanged and once.
    func testAFinalTranscriptIsSubmittedThroughTheOrdinaryPath() async throws {
        let input = MockSpeechInputService()
        let (coordinator, spy) = makeCoordinator(input: input)

        coordinator.startListening()
        try await settle()

        let started = await input.startCount
        XCTAssertEqual(started, 1)

        await input.emitPartial("Remind me tomorrow")
        try await settle()
        XCTAssertEqual(coordinator.state.transcript, "Remind me tomorrow")

        await input.emitFinal("Remind me tomorrow to call the dentist.")
        try await settle()

        XCTAssertEqual(
            spy.submitted, ["Remind me tomorrow to call the dentist."],
            "The transcript must arrive verbatim at the same method typed input uses"
        )
    }

    func testPermissionIsAskedForBeforeTheMicrophoneOpens() async throws {
        let input = MockSpeechInputService()
        let (coordinator, _) = makeCoordinator(input: input)

        coordinator.startListening()
        try await settle()

        let asked = await input.permissionRequestCount
        let started = await input.startCount
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(started, 1)
    }

    func testADeniedMicrophoneNeverStartsListeningOrSubmits() async throws {
        let input = MockSpeechInputService(
            permissions: VoicePermissions(microphone: .denied, speechRecognition: .authorized)
        )
        let (coordinator, spy) = makeCoordinator(input: input)

        coordinator.startListening()
        try await settle()

        let started = await input.startCount
        XCTAssertEqual(started, 0, "A refusal must not open the microphone")
        XCTAssertEqual(spy.submitted, [], "Nothing can reach the assistant")
        XCTAssertEqual(coordinator.state, .failed(.microphonePermissionDenied))
    }

    func testAnUnavailableRecognizerFailsBeforeListening() async throws {
        let input = MockSpeechInputService(available: false)
        let (coordinator, _) = makeCoordinator(input: input)

        coordinator.startListening()
        try await settle()

        let started = await input.startCount
        XCTAssertEqual(started, 0)
        XCTAssertEqual(coordinator.state, .failed(.recognitionUnavailable))
        // Temporary, not permanent — the user can try again.
        XCTAssertTrue(VoiceError.recognitionUnavailable.isRetryable)
    }

    // MARK: Cancel and stop

    func testCancelStopsCaptureAndSubmitsNothing() async throws {
        let input = MockSpeechInputService()
        let (coordinator, spy) = makeCoordinator(input: input)

        coordinator.startListening()
        try await settle()
        await input.emitPartial("Set an alarm for")
        try await settle()

        coordinator.cancelListening()
        try await settle()

        let cancelled = await input.cancelCount
        XCTAssertEqual(cancelled, 1, "The recogniser must actually be torn down")
        XCTAssertEqual(spy.submitted, [])
        XCTAssertEqual(coordinator.state, .idle)
    }

    func testStopFinalizesAndSubmitsExactlyOnce() async throws {
        let input = MockSpeechInputService()
        let (coordinator, spy) = makeCoordinator(input: input)

        coordinator.startListening()
        try await settle()
        await input.emitPartial("Book a haircut")
        try await settle()

        coordinator.stopListening()
        try await settle()

        let stopped = await input.stopCount
        XCTAssertEqual(stopped, 1)
        XCTAssertEqual(spy.submitted, [], "Stop asks the recogniser to finish; it does not guess")

        await input.emitFinal("Book a haircut on Saturday.")
        try await settle()

        XCTAssertEqual(spy.submitted, ["Book a haircut on Saturday."])
    }

    /// Real recognisers deliver more than one final callback. Submitting twice
    /// would create two calendar events.
    func testDuplicateFinalResultsSubmitOnce() async throws {
        let input = MockSpeechInputService()
        let (coordinator, spy) = makeCoordinator(input: input)

        coordinator.startListening()
        try await settle()

        await input.emitFinal("Call the dentist")
        await input.emitFinal("Call the dentist")
        try await settle()

        XCTAssertEqual(spy.submitted.count, 1)
    }

    /// The stale-callback case: a result for a session the user abandoned.
    func testAResultFromAnAbandonedSessionIsDropped() async throws {
        let input = MockSpeechInputService()
        let (coordinator, spy) = makeCoordinator(input: input)

        coordinator.startListening()
        try await settle()
        let abandoned = await input.currentSession()

        coordinator.cancelListening()
        try await settle()

        await input.emitFinal("Set an alarm for 7", forSession: try XCTUnwrap(abandoned))
        try await settle()

        XCTAssertEqual(
            spy.submitted, [],
            "A recogniser that finishes after cancellation must not speak for the user"
        )
    }

    // MARK: Empty and failed

    func testSilenceIsNotSubmitted() async throws {
        let input = MockSpeechInputService()
        let (coordinator, spy) = makeCoordinator(input: input)

        coordinator.startListening()
        try await settle()
        await input.emitFinal("   ")
        try await settle()

        XCTAssertEqual(spy.submitted, [])
        XCTAssertEqual(coordinator.state, .failed(.noSpeechDetected))
    }

    func testRetryAfterAFailureStartsAFreshSession() async throws {
        let input = MockSpeechInputService()
        let (coordinator, spy) = makeCoordinator(input: input)

        coordinator.startListening()
        try await settle()
        await input.emitFailure(.recognitionFailed)
        try await settle()
        XCTAssertEqual(coordinator.state, .failed(.recognitionFailed))

        coordinator.retry()
        try await settle()

        let started = await input.startCount
        XCTAssertEqual(started, 2, "Retry must open a new session, not reuse the broken one")

        await input.emitFinal("Second time")
        try await settle()
        XCTAssertEqual(spy.submitted, ["Second time"])
    }

    // MARK: Speech output

    func testTheAssistantsReplyReachesSpeechOutput() async throws {
        let output = MockSpeechOutputService()
        let (coordinator, _) = makeCoordinator(output: output)

        await coordinator.speak("Your reminder is scheduled.")

        let spoken = await output.spokenText
        XCTAssertEqual(spoken, ["Your reminder is scheduled."])
    }

    /// The decision about *whether* to speak lives in `VoicePreferences`, not
    /// here — so this only checks that an empty reply is not announced.
    func testAnEmptyReplyIsNotSpoken() async throws {
        let output = MockSpeechOutputService()
        let (coordinator, _) = makeCoordinator(output: output)

        await coordinator.speak("   ")

        let spoken = await output.spokenText
        XCTAssertEqual(spoken, [])
    }

    /// Otherwise the microphone opens into the assistant's own voice and it
    /// transcribes itself.
    func testTappingTheMicrophoneWhileSpeakingStopsSpeechThenListens() async throws {
        let input = MockSpeechInputService()
        let output = MockSpeechOutputService()
        let spy = SubmissionSpy()
        let coordinator = VoiceCoordinator(
            input: input,
            output: output,
            submit: { text in spy.record(text) }
        )

        // The mock holds inside `speak` until stopped, the way a real
        // synthesiser does. Without that the coordinator would be back at
        // `.idle` before the test could tap the microphone, and the handoff
        // being tested would never happen.
        await output.setHoldsUntilStopped(true)
        Task { await coordinator.speak("A long reply the user talks over.") }
        try await settle()
        XCTAssertEqual(coordinator.state, .speaking)

        coordinator.startListening()
        try await settle()

        let stopped = await output.stopCount
        let started = await input.startCount
        XCTAssertGreaterThanOrEqual(stopped, 1, "Speech must be stopped")
        XCTAssertEqual(started, 1, "and then the microphone opens")
    }

    // MARK: Helpers

    /// Lets queued main-actor work run.
    ///
    /// The coordinator performs effects in detached tasks, so the assertions
    /// have to give those tasks a turn. A fixed sleep would be flaky and slow;
    /// yielding repeatedly drains the queue as fast as it drains.
    private func settle(iterations: Int = 12) async throws {
        for _ in 0..<iterations {
            await Task.yield()
            // Yielding alone does not reliably drain work that hops to another
            // actor and back, which every effect here does. A few milliseconds
            // each time is enough and keeps the suite fast.
            try await Task.sleep(nanoseconds: 4_000_000)
        }
    }
}
