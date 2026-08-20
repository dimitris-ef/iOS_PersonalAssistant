import Foundation

/// Something that happened, from the user or from the speech services.
public enum VoiceEvent: Hashable, Sendable {
    /// The user tapped the microphone.
    case startRequested
    /// Permission came back.
    case permissionResolved(VoicePermission)
    /// The recognizer produced a better guess. Partial results arrive many
    /// times a second.
    case transcriptUpdated(String, level: Float)
    /// The user tapped Stop: "I'm finished speaking."
    case stopRequested
    /// The recognizer settled on a final answer.
    case recognitionFinished(String)
    /// The user tapped Cancel: "ignore what I just said."
    case cancelRequested
    /// The assistant finished its turn.
    case processingFinished
    /// Speech output started reading the reply.
    case speechStarted
    /// Speech output finished, or was stopped.
    case speechFinished
    case failed(VoiceError)
    /// The user tapped Retry on an error.
    case retryRequested
    /// The user dismissed an error without retrying.
    case errorDismissed
}

/// What the coordinator should actually do about an event.
///
/// The reducer decides; it does not act. That split is what lets every rule in
/// this file be tested without a microphone, an audio session, an assistant or
/// a device — the tests assert on the effects that come back.
public enum VoiceEffect: Hashable, Sendable {
    case requestPermission
    case startListening(VoiceSessionID)
    /// Finish cleanly and wait for the final transcript.
    case stopListening
    /// Tear down and discard whatever was said.
    case cancelListening
    /// **The one that matters.** Send this text down the ordinary typed-input
    /// path. Emitted at most once per session — see `hasSubmitted`.
    case submit(String, VoiceSessionID)
    case stopSpeaking
}

/// The rules, as a pure value.
///
/// ## Why cancellation is not a state
///
/// The milestone's sketch lists `cancelled` alongside `idle` and `listening`.
/// It is not modelled as a state here because nothing ever rests in it: the
/// user has just pressed Cancel, they know what they did, and showing them a
/// "Cancelled" screen they must then dismiss is worse than simply returning to
/// the composer. Cancellation is an *event*, and its result is `.idle`.
///
/// `failed` is a resting state, by contrast, because there is something to say
/// and a decision — retry, or give up — for the user to make.
public struct VoiceSession: Hashable, Sendable {
    public private(set) var state: VoiceState
    /// The attempt currently in progress. A new one is minted on every start,
    /// which is what makes stale callbacks identifiable.
    public private(set) var sessionID: VoiceSessionID
    /// Whether this session already produced a `.submit`.
    ///
    /// The guard against the duplicate-submission bug. Speech APIs deliver more
    /// than one final-looking callback around the end of a session — a final
    /// result, then a task-completion callback — and a naive implementation
    /// sends the user's sentence to the assistant twice. Since the assistant
    /// creates calendar events and alarms, "twice" is not a cosmetic problem.
    public private(set) var hasSubmitted: Bool

    public init(
        state: VoiceState = .idle,
        sessionID: VoiceSessionID = VoiceSessionID(),
        hasSubmitted: Bool = false
    ) {
        self.state = state
        self.sessionID = sessionID
        self.hasSubmitted = hasSubmitted
    }

    /// Applies an event, returning what the caller should do about it.
    ///
    /// Every unhandled (state, event) pair is a deliberate no-op rather than a
    /// crash or a forced transition. Events genuinely do arrive in the wrong
    /// state — a recognizer callback after cancellation, a Stop tapped twice
    /// before the first took effect — and the correct response to almost all of
    /// them is to do nothing.
    @discardableResult
    public mutating func apply(_ event: VoiceEvent) -> [VoiceEffect] {
        switch (state, event) {

        // MARK: Starting

        case (_, .startRequested) where state.canStartListening:
            // Starting while the assistant is talking stops it first, and in
            // that order. Otherwise the microphone opens into the synthesiser's
            // own voice and the assistant transcribes itself.
            let wasSpeaking = state == .speaking
            state = .requestingPermission
            return wasSpeaking ? [.stopSpeaking, .requestPermission] : [.requestPermission]

        case (_, .startRequested):
            return []

        case (.requestingPermission, .permissionResolved(let permission)):
            guard let failure = permission.failure else {
                sessionID = VoiceSessionID()
                hasSubmitted = false
                state = .listening(transcript: "", level: 0)
                return [.startListening(sessionID)]
            }
            state = .failed(failure)
            return []

        // MARK: Listening

        case (.listening, .transcriptUpdated(let text, let level)):
            state = .listening(transcript: text, level: level)
            return []

        case (.listening(let transcript, _), .stopRequested):
            // Stop is not the end. The recognizer is asked to finish and the
            // last words are still in flight, so this waits in `finalizing`
            // for the final callback rather than submitting what it has.
            state = .finalizing(transcript: transcript)
            return [.stopListening]

        case (.listening, .cancelRequested), (.finalizing, .cancelRequested):
            // Discards the transcript, and deliberately emits no `.submit`.
            // This is the line that makes "Cancel" mean *ignore what I said*
            // rather than "send it a bit sooner".
            state = .idle
            hasSubmitted = false
            return [.cancelListening]

        // MARK: Finishing

        case (.listening, .recognitionFinished(let text)),
             (.finalizing, .recognitionFinished(let text)):
            return finish(with: text)

        case (_, .recognitionFinished):
            // A final result for a session nobody is waiting for any more.
            return []

        case (.listening, .failed(let error)), (.finalizing, .failed(let error)),
             (.requestingPermission, .failed(let error)):
            state = .failed(error)
            return [.cancelListening]

        case (_, .failed):
            return []

        // MARK: Processing and speaking

        case (.processing, .processingFinished):
            state = .idle
            return []

        case (_, .processingFinished):
            return []

        case (.processing, .speechStarted), (.idle, .speechStarted):
            state = .speaking
            return []

        case (_, .speechStarted):
            return []

        case (.speaking, .speechFinished):
            state = .idle
            return []

        case (_, .speechFinished):
            return []

        // MARK: Errors

        case (.failed, .retryRequested):
            // A fresh attempt, from the top — including the permission check,
            // because the reason for the failure may have been a permission.
            // Nothing from the previous session is reused.
            state = .requestingPermission
            return [.requestPermission]

        case (_, .retryRequested):
            return []

        case (.failed, .errorDismissed):
            state = .idle
            return []

        case (_, .errorDismissed):
            return []

        // MARK: Everything else

        case (_, .permissionResolved), (_, .transcriptUpdated),
             (_, .stopRequested), (_, .cancelRequested):
            return []
        }
    }

    /// The end of a session, and the only place `.submit` is produced.
    private mutating func finish(with text: String) -> [VoiceEffect] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !hasSubmitted else {
            // The duplicate. Recognition already finished for this session and
            // the transcript is already on its way to the assistant.
            return []
        }

        guard !trimmed.isEmpty else {
            // Nothing worth saying. An empty user message would appear in the
            // conversation as a blank bubble and make the assistant answer a
            // question nobody asked.
            state = .failed(.noSpeechDetected)
            return [.cancelListening]
        }

        hasSubmitted = true
        state = .processing(transcript: trimmed)
        return [.submit(trimmed, sessionID)]
    }
}
