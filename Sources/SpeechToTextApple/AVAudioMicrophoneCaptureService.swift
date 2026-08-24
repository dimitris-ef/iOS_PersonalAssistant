import Foundation
import SpeechToText

#if os(iOS) && canImport(AVFAudio)
import AVFAudio

/// The microphone, opened once and shared by every transcription engine.
///
/// ## Why this is the only audio session in the app
///
/// Section 9. `AVAudioSession` is a process-wide singleton, and three providers
/// each activating and deactivating it would produce a microphone that works
/// until the user switches engine and then silently does not. Capture is
/// configured here, once, and the samples are published to whichever provider
/// is selected.
///
/// ## Why samples rather than buffers
///
/// The stream carries `[Float]` in a plain struct rather than
/// `AVAudioPCMBuffer`. Apple's buffer is a non-`Sendable` class from a
/// framework that does not exist on Linux; publishing one would make the entire
/// speech abstraction Apple-only and untestable, which is precisely the
/// coupling `SpeechAudioChunk` exists to avoid. The Apple backend converts back
/// into a buffer at its own boundary.
///
/// TODO-DEVICE: nothing here has captured real audio. Route changes, a
/// Bluetooth headset connecting mid-sentence, and interruption by a phone call
/// all need an iPhone — see `Docs/SPEECH.md`.
public actor AVAudioMicrophoneCaptureService: MicrophoneCaptureService {

    private var engine: AVAudioEngine?
    private var continuation: AsyncStream<SpeechAudioChunk>.Continuation?
    private var interruptionObserver: (any NSObjectProtocol)?

    /// The format the hardware is actually producing, once capture has started.
    private var activeFormat: SpeechAudioFormat?

    public init() {}

    // MARK: Permission

    public func currentPermission() async -> MicrophonePermission {
        Self.read()
    }

    public func requestPermission() async -> MicrophonePermission {
        let current = Self.read()
        guard current == .notDetermined else { return current }
        // Contextual, and only here: the prompt appears because the user just
        // tapped the microphone, never at launch (section 16).
        let granted = await AVAudioApplication.requestRecordPermission()
        return granted ? .authorized : .denied
    }

    /// Reads microphone permission without naming its type.
    ///
    /// `AVAudioApplication.recordPermission` is both a property and a
    /// lowercase-initial nested enum, an Objective-C import artefact and an
    /// ambiguity waiting to happen. Switching over the value sidesteps having
    /// to spell the type at all.
    private static func read() -> MicrophonePermission {
        switch AVAudioApplication.shared.recordPermission {
        case .undetermined: return .notDetermined
        case .granted: return .authorized
        case .denied: return .denied
        // Fails closed: a case a future OS adds is treated as no access until
        // this code understands it.
        @unknown default: return .denied
        }
    }

    // MARK: Format

    public func captureFormat() async -> SpeechAudioFormat {
        if let activeFormat { return activeFormat }
        // Before capture starts the honest answer is the session's preferred
        // rate, which is what the engine will most likely give. Not a constant:
        // built-in, wired and Bluetooth microphones differ, and a conversion
        // that assumed 48 kHz would transcribe gibberish on the one that isn't.
        let rate = AVAudioSession.sharedInstance().sampleRate
        return SpeechAudioFormat(
            sampleRate: rate > 0 ? rate : 48_000,
            channelCount: 1
        )
    }

    // MARK: Capture

    public func start() async throws -> SpeechAudioStream {
        // A previous session that was never torn down would keep a tap
        // installed, and `AVAudioEngine` throws on a second tap at the same
        // bus — the classic "voice worked once" bug.
        await teardown(finishing: true)

        let permission = Self.read()
        guard permission.isAuthorized else {
            throw permission.failure ?? SpeechToTextError.microphonePermissionDenied
        }

        let session = AVAudioSession.sharedInstance()
        do {
            // `.record` rather than `.playAndRecord`: this app speaks replies
            // through a separate session activation, and asking for playback
            // here would duck other audio for the whole listening period.
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            throw SpeechToTextError.providerUnavailable(
                reason: "The microphone couldn't be started."
            )
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let hardwareFormat = input.outputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0 else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw SpeechToTextError.providerUnavailable(
                reason: "The microphone couldn't be started."
            )
        }

        let format = SpeechAudioFormat(
            sampleRate: hardwareFormat.sampleRate,
            channelCount: Int(hardwareFormat.channelCount)
        )
        activeFormat = format

        var escaped: AsyncStream<SpeechAudioChunk>.Continuation?
        let stream = AsyncStream<SpeechAudioChunk>(bufferingPolicy: .unbounded) { escaped = $0 }
        continuation = escaped
        let sink = escaped

        // 1024 frames is about 21 ms at 48 kHz: small enough that a partial
        // result feels live, large enough that the callback is not the
        // bottleneck.
        input.installTap(onBus: 0, bufferSize: 1024, format: hardwareFormat) { buffer, _ in
            guard let chunk = Self.chunk(from: buffer, format: format) else { return }
            sink?.yield(chunk)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            sink?.finish()
            continuation = nil
            activeFormat = nil
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw SpeechToTextError.providerUnavailable(
                reason: "The microphone couldn't be started."
            )
        }

        self.engine = engine
        observeInterruptions()
        return SpeechAudioStream(format: format, chunks: stream)
    }

    public func stop() async {
        // Finishes the stream cleanly: what was captured is complete, and the
        // provider transcribes it (section 57).
        await teardown(finishing: true)
    }

    public func cancel() async {
        // Also finishes the stream — a provider blocked on `for await` would
        // otherwise never return. The difference from `stop` is upstream: the
        // pipeline cancels the provider session, so the audio is discarded
        // rather than transcribed.
        await teardown(finishing: true)
    }

    private func teardown(finishing: Bool) async {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        activeFormat = nil

        if finishing { continuation?.finish() }
        continuation = nil

        // Handed back so other audio — music, a podcast — resumes. Failing to
        // is the bug that leaves a phone silent after one voice command.
        try? AVAudioSession.sharedInstance()
            .setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: Interruptions

    /// A phone call, Siri, or another app taking the session.
    ///
    /// Section 86: capture stops safely and the stream ends. Whatever was
    /// captured before the interruption is complete audio, so the provider can
    /// still produce a transcript from it — which is better than discarding a
    /// sentence because a notification arrived at the end of it.
    private func observeInterruptions() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { [weak self] notification in
            let info = notification.userInfo
            let raw = info?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard let raw, let type = AVAudioSession.InterruptionType(rawValue: raw),
                  type == .began
            else { return }
            Task { await self?.stop() }
        }
    }

    // MARK: Conversion

    /// Copies an Apple buffer into the shared representation.
    ///
    /// Returns nil rather than trapping on an unexpected format: a dropped
    /// buffer costs a fraction of a second of audio, a crash costs the session.
    static func chunk(
        from buffer: AVAudioPCMBuffer,
        format: SpeechAudioFormat
    ) -> SpeechAudioChunk? {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let channelData = buffer.floatChannelData else { return nil }

        let channels = Int(buffer.format.channelCount)
        var samples = [Float]()
        samples.reserveCapacity(frames * channels)
        // Interleaved on the way out, because `SpeechAudioChunk` is defined
        // that way and the converter downmixes from it.
        for frame in 0..<frames {
            for channel in 0..<channels {
                samples.append(channelData[channel][frame])
            }
        }
        return SpeechAudioChunk(
            samples: samples,
            format: SpeechAudioFormat(
                sampleRate: buffer.format.sampleRate,
                channelCount: channels
            )
        )
    }
}
#endif
