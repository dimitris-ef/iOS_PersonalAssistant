import Foundation

/// A transcription engine a test can drive by hand.
///
/// Section 91. Every timing problem worth testing in this subsystem is a matter
/// of *when* events happen: a partial arriving after Cancel, two finals for one
/// session, a failure part-way through. Against a real engine those are
/// unreproducible; here each is a line.
///
/// It is also what makes CI possible at all — a GitHub runner has no
/// microphone, no Whisper model and no API key, and section 116 requires that
/// none of them be needed.
public actor MockSpeechToTextProvider: SpeechToTextProvider {

    /// What the provider does when a session starts.
    public enum Behaviour: Sendable {
        /// Emit partials, then a final, when the caller finishes.
        case transcribes(partials: [String], final: String)
        /// Emit a final immediately on `finish()`, with no partials.
        case finalOnly(String)
        /// Fail with this error as soon as the session starts.
        case fails(SpeechToTextError)
        /// Accept audio and never produce anything until cancelled.
        case hangs
        /// Emit the final transcript *twice*, to prove section 61's guard.
        case emitsDuplicateFinal(String)
    }

    public nonisolated let id: SpeechToTextProviderID
    /// `nonisolated` because a provider's capabilities do not change over its
    /// life, and making the protocol requirement `async` purely to serve an
    /// actor-based mock would have cost every call site a suspension for a
    /// constant.
    public nonisolated let capabilities: SpeechToTextCapabilities
    private var behaviour: Behaviour
    private var _availability: SpeechToTextAvailability

    /// Bookkeeping the tests assert on.
    public private(set) var startCount = 0
    public private(set) var finishCount = 0
    public private(set) var cancelCount = 0
    /// Every configuration this provider was started with, in order.
    public private(set) var receivedConfigurations: [SpeechToTextConfiguration] = []
    /// Total samples handed over, so "audio actually reached the engine" is
    /// checkable.
    public private(set) var receivedSampleCount = 0

    public init(
        id: SpeechToTextProviderID = .mock,
        behaviour: Behaviour = .transcribes(partials: [], final: "Hello."),
        availability: SpeechToTextAvailability = .ready,
        capabilities: SpeechToTextCapabilities = SpeechToTextCapabilities(
            supportsPartialResults: true,
            supportsOffline: true,
            sendsAudioOffDevice: false
        )
    ) {
        self.id = id
        self.behaviour = behaviour
        self._availability = availability
        self.capabilities = capabilities
    }

    public func availability(for configuration: SpeechToTextConfiguration)
        -> SpeechToTextAvailability
    {
        _availability
    }

    public func startSession(
        configuration: SpeechToTextConfiguration,
        audio: SpeechAudioStream
    ) async throws -> SpeechToTextSession {
        startCount += 1
        receivedConfigurations.append(configuration)

        let (stream, emitter) = SpeechEventEmitter.makeStream()
        let sessionID = SpeechSessionID()
        let behaviour = self.behaviour

        await emitter.emit(.started)

        // Drains audio in the background so a test can assert the samples
        // arrived, and so `hangs` behaves like a real engine that is listening.
        let pump = Task { [weak self] in
            for await chunk in audio.chunks {
                await self?.record(samples: chunk.samples.count)
            }
        }

        if case .fails(let error) = behaviour {
            await emitter.fail(error)
            pump.cancel()
        }

        return SpeechToTextSession(
            id: sessionID,
            providerID: id,
            events: stream,
            finish: { [weak self] in
                pump.cancel()
                await self?.noteFinish()
                switch behaviour {
                case .transcribes(let partials, let final):
                    for partial in partials { await emitter.emit(.partial(partial)) }
                    await emitter.finish(with: final)
                case .finalOnly(let final):
                    await emitter.finish(with: final)
                case .emitsDuplicateFinal(let final):
                    await emitter.finish(with: final)
                    // The second one. A correct emitter swallows it.
                    await emitter.finish(with: final)
                case .fails, .hangs:
                    break
                }
            },
            cancel: { [weak self] in
                pump.cancel()
                await self?.noteCancel()
                await emitter.cancel()
            }
        )
    }

    // MARK: Driving it

    public func setBehaviour(_ behaviour: Behaviour) { self.behaviour = behaviour }
    public func setAvailability(_ availability: SpeechToTextAvailability) {
        _availability = availability
    }

    /// Emits a partial outside the scripted sequence, for tests that need to
    /// control the exact moment one arrives.
    public func emit(_ event: SpeechToTextEvent, on emitter: SpeechEventEmitter) async {
        await emitter.emit(event)
    }

    private func record(samples: Int) { receivedSampleCount += samples }
    private func noteFinish() { finishCount += 1 }
    private func noteCancel() { cancelCount += 1 }
}
