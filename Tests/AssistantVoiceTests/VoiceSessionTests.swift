import AssistantVoice
import XCTest

/// The voice state machine, exhaustively.
///
/// These run anywhere: no microphone, no audio session, no device, no
/// assistant. That is the reason the rules were extracted into a pure value in
/// the first place — every one of the failures below is a timing problem that
/// is unreproducible against a real recogniser and trivial here.
final class VoiceSessionTests: XCTestCase {

    // MARK: The happy path

    func testTheFullPathFromTapToSubmission() {
        var session = VoiceSession()

        XCTAssertEqual(session.apply(.startRequested), [.requestPermission])
        XCTAssertEqual(session.state, .requestingPermission)

        let started = session.apply(.permissionResolved(.authorized))
        XCTAssertEqual(started, [.startListening(session.sessionID)])
        XCTAssertEqual(session.state, .listening(transcript: "", level: 0))

        session.apply(.transcriptUpdated("Remind me tomorrow", level: 0.4))
        XCTAssertEqual(session.state, .listening(transcript: "Remind me tomorrow", level: 0.4))

        XCTAssertEqual(session.apply(.stopRequested), [.stopListening])
        XCTAssertEqual(session.state, .finalizing(transcript: "Remind me tomorrow"))

        let submitted = session.apply(
            .recognitionFinished("Remind me tomorrow to call the dentist.")
        )
        XCTAssertEqual(
            submitted,
            [.submit("Remind me tomorrow to call the dentist.", session.sessionID)]
        )
        XCTAssertEqual(
            session.state,
            .processing(transcript: "Remind me tomorrow to call the dentist.")
        )

        session.apply(.processingFinished)
        XCTAssertEqual(session.state, .idle)
    }

    /// The microphone must go off the moment the user stops talking, not when
    /// the assistant finishes thinking.
    func testTheMicrophoneIsNotShownActiveWhileTheAssistantWorks() {
        var session = listening()

        XCTAssertTrue(session.state.isCapturingAudio)

        session.apply(.stopRequested)
        XCTAssertFalse(session.state.isCapturingAudio, "finalizing is not recording")

        session.apply(.recognitionFinished("Anything"))
        XCTAssertFalse(session.state.isCapturingAudio, "processing is not recording")
    }

    // MARK: Cancel

    func testCancelDiscardsTheTranscriptAndSubmitsNothing() {
        var session = listening()
        session.apply(.transcriptUpdated("Set an alarm", level: 0.5))

        let effects = session.apply(.cancelRequested)

        XCTAssertEqual(effects, [.cancelListening])
        XCTAssertEqual(session.state, .idle)
        XCTAssertFalse(
            effects.contains { if case .submit = $0 { return true } else { return false } },
            "Cancel means ignore what I said — it must never reach the assistant"
        )
    }

    func testCancelWhileFinalizingAlsoSubmitsNothing() {
        var session = listening()
        session.apply(.transcriptUpdated("Set an alarm", level: 0.5))
        session.apply(.stopRequested)

        let effects = session.apply(.cancelRequested)

        XCTAssertEqual(effects, [.cancelListening])
        XCTAssertEqual(session.state, .idle)
    }

    /// The race the session id exists for: recognition finishes *after* the
    /// user cancelled, because the audio was already in flight.
    func testAResultArrivingAfterCancellationIsIgnored() {
        var session = listening()
        session.apply(.cancelRequested)

        let effects = session.apply(.recognitionFinished("Set an alarm for 7"))

        XCTAssertEqual(effects, [], "A cancelled session must not submit late results")
        XCTAssertEqual(session.state, .idle)
    }

    // MARK: Stop versus cancel

    func testStopAndCancelDoOppositeThings() {
        var stopping = listening()
        stopping.apply(.transcriptUpdated("Call the dentist", level: 0.3))
        stopping.apply(.stopRequested)
        let stopped = stopping.apply(.recognitionFinished("Call the dentist"))

        var cancelling = listening()
        cancelling.apply(.transcriptUpdated("Call the dentist", level: 0.3))
        cancelling.apply(.cancelRequested)
        let cancelled = cancelling.apply(.recognitionFinished("Call the dentist"))

        XCTAssertEqual(stopped, [.submit("Call the dentist", stopping.sessionID)])
        XCTAssertEqual(cancelled, [])
    }

    // MARK: Duplicate submission

    /// Speech APIs deliver more than one final-looking callback around the end
    /// of a session. Since the assistant creates calendar events and alarms,
    /// submitting twice is not cosmetic.
    func testOneSessionCannotSubmitTwice() {
        var session = listening()
        session.apply(.stopRequested)

        let first = session.apply(.recognitionFinished("Book a haircut"))
        let second = session.apply(.recognitionFinished("Book a haircut"))
        let third = session.apply(.recognitionFinished("Book a haircut again"))

        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(second, [], "The second final callback must be ignored")
        XCTAssertEqual(third, [], "Even different text must not start a second turn")
    }

    func testANewSessionCanSubmitAgain() {
        var session = listening()
        session.apply(.stopRequested)
        session.apply(.recognitionFinished("First thing"))
        session.apply(.processingFinished)

        session.apply(.startRequested)
        let effects = session.apply(.permissionResolved(.authorized))

        XCTAssertEqual(effects, [.startListening(session.sessionID)])
        XCTAssertFalse(session.hasSubmitted, "A fresh session starts unsubmitted")
    }

    func testEachSessionGetsItsOwnIdentity() {
        var session = VoiceSession()
        session.apply(.startRequested)
        session.apply(.permissionResolved(.authorized))
        let first = session.sessionID

        session.apply(.cancelRequested)
        session.apply(.startRequested)
        session.apply(.permissionResolved(.authorized))

        XCTAssertNotEqual(first, session.sessionID)
    }

    // MARK: Empty speech

    func testSilenceIsNotSubmittedAsAMessage() {
        for text in ["", "   ", "\n\t "] {
            var session = listening()
            session.apply(.stopRequested)

            let effects = session.apply(.recognitionFinished(text))

            XCTAssertEqual(effects, [.cancelListening])
            XCTAssertEqual(
                session.state, .failed(.noSpeechDetected),
                "An empty transcript should say 'I didn't catch that', not post a blank message"
            )
        }
    }

    func testTranscriptsAreTrimmedBeforeSubmission() {
        var session = listening()
        session.apply(.stopRequested)

        let effects = session.apply(.recognitionFinished("  Call the dentist.  "))

        XCTAssertEqual(effects, [.submit("Call the dentist.", session.sessionID)])
    }

    // MARK: Permission

    func testDeniedPermissionNeverOpensTheMicrophone() {
        var session = VoiceSession()
        session.apply(.startRequested)

        let effects = session.apply(.permissionResolved(.denied))

        XCTAssertEqual(effects, [], "Nothing should start listening after a refusal")
        XCTAssertEqual(session.state, .failed(.microphonePermissionDenied))
    }

    func testRestrictedPermissionIsReportedAsRestricted() {
        var session = VoiceSession()
        session.apply(.startRequested)
        session.apply(.permissionResolved(.restricted))

        XCTAssertEqual(session.state, .failed(.restricted))
        // Not fixable by this person, so no Settings button is offered.
        XCTAssertFalse(VoiceError.restricted.isResolvableInSettings)
        XCTAssertFalse(VoiceError.restricted.isRetryable)
    }

    func testAnUnsupportedDeviceSaysSoRatherThanFailingQuietly() {
        var session = VoiceSession()
        session.apply(.startRequested)
        session.apply(.permissionResolved(.unsupported))

        XCTAssertEqual(session.state, .failed(.unsupported))
    }

    // MARK: Failure and retry

    func testRetryStartsACompletelyFreshAttempt() {
        var session = listening()
        session.apply(.failed(.recognitionFailed))
        XCTAssertEqual(session.state, .failed(.recognitionFailed))

        let retried = session.apply(.retryRequested)
        XCTAssertEqual(
            retried, [.requestPermission],
            "Retry re-checks permission — the failure may have been one"
        )

        let restarted = session.apply(.permissionResolved(.authorized))
        XCTAssertEqual(restarted, [.startListening(session.sessionID)])
        XCTAssertFalse(session.hasSubmitted)
    }

    func testAFailureDuringListeningReleasesTheMicrophone() {
        var session = listening()

        let effects = session.apply(.failed(.interrupted))

        XCTAssertEqual(
            effects, [.cancelListening],
            "An interrupted session must let go of the audio session"
        )
        XCTAssertFalse(session.state.isCapturingAudio)
    }

    func testDismissingAnErrorReturnsToIdle() {
        var session = listening()
        session.apply(.failed(.noSpeechDetected))

        session.apply(.errorDismissed)

        XCTAssertEqual(session.state, .idle)
    }

    // MARK: Speaking

    func testTappingTheMicrophoneWhileSpeakingStopsSpeechFirst() {
        var session = VoiceSession()
        session.apply(.speechStarted)
        XCTAssertEqual(session.state, .speaking)

        let effects = session.apply(.startRequested)

        // Order matters: the microphone must not open into the assistant's own
        // voice, or it transcribes itself.
        XCTAssertEqual(effects, [.stopSpeaking, .requestPermission])
    }

    func testStartingFromIdleDoesNotTryToStopSpeech() {
        var session = VoiceSession()
        XCTAssertEqual(session.apply(.startRequested), [.requestPermission])
    }

    // MARK: Impossible transitions

    /// Every event, in every state, must leave the machine somewhere sensible.
    /// This is the test that would catch a new event being added without being
    /// thought about.
    func testNoEventCanProduceAnImpossibleState() {
        let events: [VoiceEvent] = [
            .startRequested,
            .permissionResolved(.authorized),
            .permissionResolved(.denied),
            .transcriptUpdated("x", level: 0.5),
            .stopRequested,
            .recognitionFinished("x"),
            .cancelRequested,
            .processingFinished,
            .speechStarted,
            .speechFinished,
            .failed(.recognitionFailed),
            .retryRequested,
            .errorDismissed,
        ]

        for first in events {
            for second in events {
                var session = VoiceSession()
                session.apply(first)
                session.apply(second)

                // The invariant that matters: audio capture and every other
                // activity are mutually exclusive, and only `listening` records.
                if session.state.isCapturingAudio {
                    guard case .listening = session.state else {
                        return XCTFail("isCapturingAudio true outside listening: \(session.state)")
                    }
                }
                // Submission is one-way. Nothing can un-submit a session.
                if case .processing = session.state {
                    XCTAssertTrue(
                        session.hasSubmitted,
                        "processing without having submitted: \(first), \(second)"
                    )
                }
            }
        }
    }

    func testStartingIsRefusedWhileAlreadyBusy() {
        for state in [VoiceState.requestingPermission, .listening(transcript: "", level: 0)] {
            var session = VoiceSession(state: state)
            XCTAssertEqual(
                session.apply(.startRequested), [],
                "\(state) should ignore a second start"
            )
        }
    }

    // MARK: Fixtures

    /// A session that has reached `listening`, the way the app reaches it.
    private func listening() -> VoiceSession {
        var session = VoiceSession()
        session.apply(.startRequested)
        session.apply(.permissionResolved(.authorized))
        return session
    }
}
