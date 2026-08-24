import Foundation

/// Identifies one transcription attempt.
///
/// Section 60. Speech engines are asynchronous and none of them stops talking
/// because you stopped listening: a cancelled `SFSpeechRecognitionTask` can
/// still deliver a final result, an in-flight HTTP upload completes after the
/// user has moved on, and a Whisper decode running on a background thread
/// finishes whatever happens. Tagging every event with the session it belongs
/// to turns "ignore anything from a session that is over" from a race into a
/// comparison.
///
/// Distinct from Part 5's `VoiceSessionID`, which identifies one *interaction*.
/// A retry is a new voice session; so is a new transcription session. They are
/// one-to-one today, and keeping them separate types means the speech layer
/// never has to import the voice layer's vocabulary to be tested.
public struct SpeechSessionID: Hashable, Sendable {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

/// Everything a transcription engine is allowed to say.
///
/// Section 8. All three providers normalize onto this, so the voice UI has one
/// piece of event-handling code rather than three — and so the tests that
/// matter (a partial arrives, a final arrives twice, a cancelled session speaks
/// up later) are written once and hold for every provider.
///
/// Note the payloads: a `String`, an error, or nothing. No timestamps, no
/// confidence arrays, no token alternatives, no audio. Section 72 asks that
/// none of that reach the assistant; the simplest way to guarantee it is for
/// the speech layer never to produce it in the first place.
public enum SpeechToTextEvent: Hashable, Sendable {
    /// The engine has accepted the audio and is working.
    case started
    /// A better guess, which will be replaced. Never submitted (section 15).
    case partial(String)
    /// The transcript, settled. At most one per session (section 61).
    case final(String)
    /// The session was stopped without producing a transcript.
    case cancelled
    case failed(SpeechToTextError)

    /// Whether this is the last event a session will ever emit.
    public var isTerminal: Bool {
        switch self {
        case .final, .cancelled, .failed: return true
        case .started, .partial: return false
        }
    }
}

/// A running transcription.
///
/// ## Why an `AsyncStream` and not a delegate
///
/// Section 8 asks for structured concurrency where it fits, and this is where
/// it fits: a transcription is a finite sequence of events with a definite end,
/// which is exactly what `AsyncSequence` models. It also gives cancellation for
/// free at the consumer end and makes the "ignore stale events" rule
/// expressible as *not iterating the old stream* rather than as a flag checked
/// in a callback.
///
/// The delegate style survives one layer up, in `SpeechInputDelegate`, because
/// Part 5's coordinator was built around it and section 1 says not to rebuild
/// Part 5. The adapter between them is the only place that knows both.
public struct SpeechToTextSession: Sendable {
    public let id: SpeechSessionID
    /// The provider that produced this session. Recorded for diagnostics, never
    /// for behaviour — nothing branches on it.
    public let providerID: SpeechToTextProviderID
    /// Events, in order, ending after the first terminal one.
    public let events: AsyncStream<SpeechToTextEvent>

    /// "I have finished speaking": stop consuming audio, produce a final
    /// transcript from what was captured.
    ///
    /// For a streaming provider this settles the in-flight recognition. For a
    /// batch provider — OpenAI, and Whisper in its simplest mode — this is the
    /// moment the actual work starts, which is why the UI shows "Transcribing…"
    /// after Stop (section 56).
    public let finish: @Sendable () async -> Void

    /// "Forget it": stop everything and produce nothing.
    ///
    /// Must cancel network requests, delete temporary audio, and release
    /// runtime resources. It must never emit a `.final`.
    public let cancel: @Sendable () async -> Void

    public init(
        id: SpeechSessionID,
        providerID: SpeechToTextProviderID,
        events: AsyncStream<SpeechToTextEvent>,
        finish: @Sendable @escaping () async -> Void,
        cancel: @Sendable @escaping () async -> Void
    ) {
        self.id = id
        self.providerID = providerID
        self.events = events
        self.finish = finish
        self.cancel = cancel
    }
}

/// Emits a session's events, and refuses to emit two finals.
///
/// Section 61 is a guarantee, not a hope. Every provider in this milestone
/// funnels its events through one of these, so "the provider called back twice"
/// is handled once, here, rather than three times with three chances to get it
/// wrong. `SFSpeechRecognitionTask` really does deliver both a final result and
/// a completion callback; an HTTP retry really can deliver two responses.
///
/// An actor because providers finish from whatever executor their engine
/// happens to use, and `hasFinished` is checked and set across an await in
/// every one of them.
public actor SpeechEventEmitter {
    private let continuation: AsyncStream<SpeechToTextEvent>.Continuation
    private var hasFinished = false

    public init(continuation: AsyncStream<SpeechToTextEvent>.Continuation) {
        self.continuation = continuation
    }

    /// Makes a stream and the emitter that feeds it.
    public static func makeStream() -> (AsyncStream<SpeechToTextEvent>, SpeechEventEmitter) {
        // Unbounded because dropping a partial is harmless but dropping the
        // final is the bug this whole subsystem exists to avoid. The stream is
        // short — a handful of events over a few seconds — so the buffer costs
        // nothing.
        var escaped: AsyncStream<SpeechToTextEvent>.Continuation?
        let stream = AsyncStream<SpeechToTextEvent>(bufferingPolicy: .unbounded) {
            escaped = $0
        }
        // Safe to force-unwrap: `AsyncStream.init` runs its builder before
        // returning, so the continuation is always set by this line.
        return (stream, SpeechEventEmitter(continuation: escaped!))
    }

    /// Emits a non-terminal event. Ignored once the session has ended.
    public func emit(_ event: SpeechToTextEvent) {
        guard !hasFinished else { return }
        if event.isTerminal {
            hasFinished = true
            continuation.yield(event)
            continuation.finish()
        } else {
            continuation.yield(event)
        }
    }

    /// Emits the final transcript, exactly once.
    ///
    /// An empty or whitespace-only transcript becomes `.cancelled` rather than
    /// `.final("")`. Section 62: no meaningful speech is not a transcript, and
    /// letting an empty string through would create a blank user message and
    /// make the assistant answer a question nobody asked. The voice layer turns
    /// that into "I didn't catch that."
    public func finish(with transcript: String) {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        emit(trimmed.isEmpty ? .cancelled : .final(trimmed))
    }

    public func fail(_ error: SpeechToTextError) {
        emit(.failed(error))
    }

    public func cancel() {
        emit(.cancelled)
    }

    /// Whether a terminal event has already been emitted.
    public var isFinished: Bool { hasFinished }
}
