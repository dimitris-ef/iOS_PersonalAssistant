import Foundation
import Observation

/// Drives one voice interaction: owns the state machine, performs its effects,
/// and publishes state for SwiftUI.
///
/// ## What it deliberately does not know
///
/// There is no `AssistantEngine` here, no repository, no provider, no tool. The
/// coordinator submits a `String` through a closure it was handed, and what
/// happens to that string is none of its business. That is the whole
/// architectural claim of this milestone stated as a type signature: voice is
/// an input method, not a second assistant.
///
/// The closure the app supplies is the same `send(_:)` a typed message goes
/// through. Not a copy of it, not a variant with a `fromVoice` flag — the same
/// method. Everything downstream — context assembly, memory ranking, provider
/// routing, tool validation, authorization, follow-up planning, platform
/// execution — therefore happens identically, because it is literally the same
/// code path.
@MainActor
@Observable
public final class VoiceCoordinator {

    /// What the UI renders. The only voice state in the app.
    public private(set) var state: VoiceState = .idle

    /// Permissions as last read, for Settings. Refreshed on demand rather than
    /// polled.
    public private(set) var permissions = VoicePermissions(
        microphone: .notDetermined,
        speechRecognition: .notDetermined
    )

    /// Where recognition runs, once known.
    public private(set) var recognitionMode: SpeechRecognitionMode = .unavailable

    private var session = VoiceSession()
    private let input: any SpeechInputService
    private let output: (any SpeechOutputService)?

    /// The typed-input path. See the type's documentation.
    private let submit: @MainActor (String) async -> Void

    /// Work owned by the current session, so cancellation actually cancels.
    private var sessionTask: Task<Void, Never>?

    public init(
        input: any SpeechInputService,
        output: (any SpeechOutputService)? = nil,
        submit: @escaping @MainActor (String) async -> Void
    ) {
        self.input = input
        self.output = output
        self.submit = submit
    }

    // MARK: User actions

    public func startListening() { handle(.startRequested) }
    public func stopListening() { handle(.stopRequested) }
    public func cancelListening() { handle(.cancelRequested) }
    public func retry() { handle(.retryRequested) }
    public func dismissError() { handle(.errorDismissed) }

    /// Reads permission state without prompting. For Settings.
    public func refreshPermissions() async {
        permissions = await input.currentPermissions()
        recognitionMode = await input.recognitionMode()
    }

    /// Reads a reply aloud.
    ///
    /// Speaks unconditionally: *whether* to speak is one decision and it lives
    /// in `VoicePreferences.shouldSpeak(replyTo:)`, because it depends on how
    /// the request arrived — which this type does not know and should not.
    /// Gating here as well would mean two places that can disagree about the
    /// same setting.
    ///
    /// Called by the app *after* a turn completes, with the assistant's own
    /// text. `AssistantEngine` returns a string and remains ignorant of whether
    /// anything says it out loud, which is what keeps speech synthesis a
    /// presentation concern.
    public func speak(_ text: String) async {
        guard let output else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        handle(.speechStarted)
        await output.speak(trimmed)
        handle(.speechFinished)
    }

    public func stopSpeaking() async {
        await output?.stop()
        handle(.speechFinished)
    }

    // MARK: The loop

    private func handle(_ event: VoiceEvent) {
        let effects = session.apply(event)
        state = session.state
        for effect in effects {
            perform(effect)
        }
    }

    private func perform(_ effect: VoiceEffect) {
        switch effect {
        case .requestPermission:
            run { [weak self] in
                guard let self else { return }
                // Contextual, and only here. The prompt appears because the
                // user just tapped the microphone — never at launch, and never
                // for a capability they have not tried to use.
                let resolved = await self.input.requestPermissions()
                self.permissions = resolved

                guard resolved.combined == .authorized else {
                    self.handle(.permissionResolved(resolved.combined))
                    return
                }
                // Availability is separate from permission: a recognizer can be
                // authorized and still temporarily unusable.
                guard await self.input.isAvailable() else {
                    self.handle(.failed(.recognitionUnavailable))
                    return
                }
                self.recognitionMode = await self.input.recognitionMode()
                self.handle(.permissionResolved(.authorized))
            }

        case .startListening(let id):
            run { [weak self] in
                guard let self else { return }
                await self.input.startListening(session: id, delegate: self)
            }

        case .stopListening:
            run { [weak self] in
                await self?.input.stopListening()
            }

        case .cancelListening:
            // Not `run`: cancellation must not be queued behind the work it is
            // cancelling, and it must survive `sessionTask` being torn down.
            sessionTask?.cancel()
            sessionTask = nil
            Task { [input] in await input.cancelListening() }

        case .submit(let text, _):
            run { [weak self] in
                guard let self else { return }
                // The typed-input path. Nothing voice-specific happens beyond
                // this line.
                await self.submit(text)
                self.handle(.processingFinished)
            }

        case .stopSpeaking:
            Task { [output] in await output?.stop() }
        }
    }

    /// Runs session work, keeping a handle so cancellation can reach it.
    ///
    /// Deliberately does not cancel the previous task. Effects chain — the
    /// permission task ends by starting the listening task — and cancelling the
    /// outgoing one from inside itself would mark the running task cancelled
    /// for the rest of its own body. Only `.cancelListening` cancels, which is
    /// the only moment that should.
    private func run(_ work: @escaping @MainActor () async -> Void) {
        sessionTask = Task { @MainActor in
            await work()
        }
    }
}

// MARK: - Recognition callbacks

extension VoiceCoordinator: SpeechInputDelegate {

    /// Callbacks are dropped unless they belong to the session in progress.
    ///
    /// The first of the two defences against a cancelled session submitting
    /// its transcript anyway. A recognition task that has been torn down can
    /// still deliver a result — the audio was already in flight — and without
    /// this check that result would arrive as though the user had spoken it
    /// just now. The second defence is `VoiceSession.hasSubmitted`, which stops
    /// a *live* session submitting twice.
    public nonisolated func speechInput(
        _ id: VoiceSessionID,
        didProduce transcript: SpeechTranscript
    ) {
        Task { @MainActor [weak self] in
            guard let self, self.session.sessionID == id else { return }
            if transcript.isFinal {
                self.handle(.recognitionFinished(transcript.text))
            } else {
                self.handle(.transcriptUpdated(transcript.text, level: transcript.level))
            }
        }
    }

    public nonisolated func speechInput(
        _ id: VoiceSessionID,
        didFailWith error: VoiceError
    ) {
        Task { @MainActor [weak self] in
            guard let self, self.session.sessionID == id else { return }
            self.handle(.failed(error))
        }
    }
}
