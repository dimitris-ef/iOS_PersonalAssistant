import Foundation

// iOS only, and not merely because that is where the app ships.
// `AVAudioSession` does not exist on macOS at all, and microphone permission is
// a different mechanism there. Guarding the whole file rather than sprinkling
// `#if os(iOS)` through it keeps the audio lifecycle readable, at the cost that
// the macOS test runner compiles nothing here — which is why the decisions
// worth testing live in `VoiceSession`, not in this file. The iOS build in the
// Apple SDK Check workflow is what type-checks this.
#if os(iOS) && canImport(Speech) && canImport(AVFAudio)
import AVFAudio
import Speech

/// Speech recognition on a real iPhone.
///
/// ## Which Speech API this uses, and why
///
/// `SFSpeechRecognizer`, not iOS 26's `SpeechAnalyzer` / `SpeechTranscriber`.
/// The app deploys to iOS 17, so the modern stack is unavailable on most of the
/// devices it supports and a fallback would be required regardless. Writing
/// both would mean two implementations of the same feature, neither of which
/// can be executed from this development environment — one unverified path is
/// enough. `SpeechInputService` is the seam that makes adding the modern one
/// later a matter of writing a second type and choosing between them; nothing
/// above the protocol would change. See `Docs/VOICE.md`.
///
/// ## Threading
///
/// An actor, because the audio engine, the recognition request and the
/// recognition task are non-`Sendable` reference types with a shared lifecycle,
/// and every bug this subsystem can have is a lifecycle bug. Apple's callbacks
/// arrive on arbitrary queues and hop back in through `Task { await … }`.
public actor AppleSpeechInputService: SpeechInputService {

    private let locale: Locale
    private var recognizer: SFSpeechRecognizer?
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    private var session: VoiceSessionID?
    private weak var delegate: (any SpeechInputDelegate)?
    /// Set when the session ended, so late callbacks are dropped at the source
    /// as well as at the coordinator.
    private var isFinished = false
    private var interruptionObserver: (any NSObjectProtocol)?

    /// Recognition runs in the user's own language.
    ///
    /// Defaulting to the current locale rather than hard-coding English: the
    /// assistant's whole value is understanding how someone actually talks, and
    /// forcing them into a second language to use it defeats the point. If the
    /// locale is not supported the recogniser reports unavailable, which
    /// surfaces honestly instead of silently transcribing nonsense.
    public init(locale: Locale = Locale.current) {
        self.locale = locale
    }

    // MARK: Permissions

    public func currentPermissions() async -> VoicePermissions {
        VoicePermissions(
            microphone: Self.microphonePermission(),
            speechRecognition: Self.map(SFSpeechRecognizer.authorizationStatus())
        )
    }

    /// Asks for both, microphone first.
    ///
    /// The order is deliberate. Two system alerts in a row is already a lot to
    /// put in front of someone who tapped a microphone button, and if they
    /// decline the first there is no reason to show the second — speech
    /// recognition with no microphone is useless. So a refusal short-circuits.
    public func requestPermissions() async -> VoicePermissions {
        var microphone = Self.microphonePermission()
        if microphone == .notDetermined {
            microphone = await AVAudioApplication.requestRecordPermission()
                ? .authorized : .denied
        }
        guard microphone == .authorized else {
            return VoicePermissions(
                microphone: microphone,
                speechRecognition: Self.map(SFSpeechRecognizer.authorizationStatus())
            )
        }

        var speech = Self.map(SFSpeechRecognizer.authorizationStatus())
        if speech == .notDetermined {
            speech = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: Self.map(status))
                }
            }
        }
        return VoicePermissions(microphone: microphone, speechRecognition: speech)
    }

    /// Reads microphone permission without naming its type.
    ///
    /// `AVAudioApplication.recordPermission` is both a property and a
    /// lowercase-initial nested enum, which is an Objective-C import artefact
    /// and an ambiguity waiting to happen. Switching over the value directly
    /// sidesteps having to spell the type at all.
    private static func microphonePermission() -> VoicePermission {
        switch AVAudioApplication.shared.recordPermission {
        case .undetermined: return .notDetermined
        case .granted: return .authorized
        case .denied: return .denied
        // Fails closed. A permission case a future OS adds is treated as no
        // access until this code understands it.
        @unknown default: return .denied
        }
    }

    private static func map(_ status: SFSpeechRecognizerAuthorizationStatus) -> VoicePermission {
        switch status {
        case .notDetermined: return .notDetermined
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .denied
        }
    }

    // MARK: Availability

    /// Asked before every session, never cached.
    ///
    /// `isAvailable` genuinely changes at runtime — it goes false when a
    /// server-backed recogniser loses the network and true again when it
    /// returns. Caching this at launch would disable voice for the rest of the
    /// session because of one bad moment.
    public func isAvailable() async -> Bool {
        makeRecognizer()?.isAvailable ?? false
    }

    /// The truth about where audio is processed, never a guess.
    ///
    /// `supportsOnDeviceRecognition` is the only thing that makes on-device
    /// processing possible, and this implementation additionally *asks* for it
    /// on every request, so when both hold the claim is real. When they do not,
    /// this says `.server` — because telling someone their voice stays on their
    /// phone when it does not would be the worst kind of privacy claim to get
    /// wrong.
    public func recognitionMode() async -> SpeechRecognitionMode {
        guard let recognizer = makeRecognizer(), recognizer.isAvailable else {
            return .unavailable
        }
        return recognizer.supportsOnDeviceRecognition ? .onDevice : .server
    }

    private func makeRecognizer() -> SFSpeechRecognizer? {
        if let recognizer { return recognizer }
        // `init(locale:)` returns nil for a locale with no recognition support.
        let created = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer()
        recognizer = created
        return created
    }

    // MARK: Listening

    /// TODO-DEVICE: nothing below has ever captured audio. That the two
    /// permission alerts appear in order with the right Info.plist strings,
    /// how far behind the speaker partial results actually lag, whether the
    /// level meter tracks a real voice, and Bluetooth routing including a
    /// headset disconnecting mid-sentence, all need an iPhone.
    public func startListening(
        session: VoiceSessionID,
        delegate: any SpeechInputDelegate
    ) async {
        // Any previous session is torn down first. Reusing an audio engine or a
        // recognition request that has already ended is the classic source of
        // "voice worked once" bugs — `AVAudioEngine` throws on a second tap
        // installed at the same bus, and a finished request refuses audio.
        await teardown()

        self.session = session
        self.delegate = delegate
        isFinished = false

        guard let recognizer = makeRecognizer(), recognizer.isAvailable else {
            return fail(.recognitionUnavailable)
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Asked for whenever the device can do it. When it cannot, recognition
        // still works via Apple's servers and `recognitionMode()` says so
        // rather than this silently downgrading a privacy promise.
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        // Tells the recogniser to expect conversational speech rather than
        // short commands or search terms, which is what people actually say to
        // this app.
        request.taskHint = .dictation
        self.request = request

        do {
            try configureAudioSession()
            try startEngine(feeding: request)
        } catch {
            await teardown()
            return fail(.audioSessionFailed)
        }

        observeInterruptions()

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // Arbitrary queue. Everything below hops onto the actor.
            guard let self else { return }
            Task { await self.handle(result: result, error: error, for: session) }
        }
    }

    /// "I've finished speaking."
    ///
    /// Stops the microphone but leaves the recognition task alive, because the
    /// last words spoken are still being processed. `endAudio()` is what tells
    /// the recogniser no more audio is coming, so it can produce its final
    /// result — cancelling here instead would throw away the end of the
    /// sentence.
    public func stopListening() async {
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        request?.endAudio()
    }

    /// "Ignore what I just said."
    ///
    /// Cancels the task outright, so no final result is ever produced.
    public func cancelListening() async {
        isFinished = true
        await teardown()
    }

    // MARK: Results

    private func handle(
        result: SFSpeechRecognitionResult?,
        error: (any Error)?,
        for session: VoiceSessionID
    ) async {
        // Two guards, and both earn their place. The session check drops
        // callbacks from an attempt the user has moved on from; `isFinished`
        // drops the second callback of the *same* attempt, which Apple delivers
        // routinely — a final result, then the task completing.
        guard self.session == session, !isFinished else { return }

        if let result {
            let text = result.bestTranscription.formattedString
            if result.isFinal {
                isFinished = true
                delegate?.speechInput(session, didProduce: SpeechTranscript(text: text, isFinal: true))
                await teardown()
                return
            }
            delegate?.speechInput(
                session,
                didProduce: SpeechTranscript(text: text, isFinal: false, level: currentLevel)
            )
            return
        }

        guard error != nil else { return }
        isFinished = true
        // The error's own description is not surfaced. `NSError` from the
        // Speech framework can carry the recognised text in its user info,
        // which is the user's own words and has no business in a UI string
        // written by an error domain.
        delegate?.speechInput(session, didFailWith: .recognitionFailed)
        await teardown()
    }

    private func fail(_ error: VoiceError) {
        guard let session else { return }
        isFinished = true
        delegate?.speechInput(session, didFailWith: error)
    }

    // MARK: Audio

    /// `.playAndRecord`, so speaking and listening share one configuration.
    ///
    /// The alternative — `.record` for input and `.playback` for the reply —
    /// means recategorising the session between every turn, and each switch is
    /// an audible gap plus an opportunity to fail. `.spokenAudio` tells the
    /// system this is speech rather than music, which is what makes it duck
    /// other audio politely instead of stopping it.
    /// TODO-DEVICE: whether `.playAndRecord` with `.duckOthers` behaves
    /// acceptably over music already playing, and whether the route survives a
    /// Bluetooth handoff, are audible questions no simulator answers.
    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .spokenAudio,
            options: [.duckOthers, .defaultToSpeaker, .allowBluetooth]
        )
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private func startEngine(feeding request: SFSpeechAudioBufferRecognitionRequest) throws {
        let engine = AVAudioEngine()
        self.engine = engine

        let input = engine.inputNode
        // The hardware's own format. Asking for a different one here is the
        // other classic crash: the tap format must match the bus.
        let format = input.outputFormat(forBus: 0)

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            guard let self else { return }
            let level = Self.level(of: buffer)
            Task { await self.setLevel(level) }
        }

        engine.prepare()
        try engine.start()
    }

    private var currentLevel: Float = 0

    private func setLevel(_ level: Float) {
        currentLevel = level
    }

    /// Rough loudness for the level meter.
    ///
    /// Root mean square of the first channel, scaled into 0...1. Presentation
    /// only — recognition is unaffected by it, and nothing persists it.
    private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }

        var sum: Float = 0
        for index in 0..<count {
            let sample = channel[index]
            sum += sample * sample
        }
        let rms = (sum / Float(count)).squareRoot()
        // Speech sits low in a linear scale, so this lifts it into a range
        // where a meter actually moves.
        return min(1, rms * 12)
    }

    /// Releases the microphone and everything attached to it.
    ///
    /// Called on every exit path — finish, cancel, failure. Leaving the audio
    /// session active keeps the orange recording indicator lit and other apps
    /// ducked, which looks exactly like an app secretly listening.
    private func teardown() async {
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        engine = nil

        task?.cancel()
        task = nil
        request = nil
        currentLevel = 0

        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        interruptionObserver = nil

        // `notifyOthersOnDeactivation` lets whatever was ducked come back up.
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    /// A phone call, Siri, or another app taking the session.
    ///
    /// Treated as the end of the attempt rather than something to resume
    /// through. Audio captured across an interruption is missing the middle of
    /// the sentence, and half a sentence submitted to the assistant is worse
    /// than none — it would be acted on as though it were what the user said.
    /// TODO-DEVICE: a real phone call arriving mid-sentence, and Retry
    /// working cleanly afterwards.
    private func observeInterruptions() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { [weak self] notification in
            guard let self else { return }
            guard
                let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                let type = AVAudioSession.InterruptionType(rawValue: raw),
                type == .began
            else { return }

            Task { await self.interrupted() }
        }
    }

    private func interrupted() async {
        guard let session, !isFinished else { return }
        isFinished = true
        delegate?.speechInput(session, didFailWith: .interrupted)
        await teardown()
    }
}
#endif
