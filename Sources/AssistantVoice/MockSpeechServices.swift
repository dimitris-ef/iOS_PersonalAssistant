import Foundation

/// A speech recogniser a test can drive by hand.
///
/// Every timing problem worth testing in this subsystem — a result arriving
/// after cancellation, two finals for one session, a failure part-way through —
/// is a matter of *when* callbacks happen. Against a real recogniser those are
/// unreproducible; here they are three lines each.
///
/// It is also what lets CI and the screenshot pipeline run: a GitHub runner has
/// no microphone, and an implementation that needed one would make the whole
/// voice layer untestable rather than merely unproven.
public actor MockSpeechInputService: SpeechInputService {

    /// What `requestPermissions()` will answer.
    public var permissions: VoicePermissions
    /// What `isAvailable()` will answer.
    public var available: Bool
    public var mode: SpeechRecognitionMode

    public private(set) var startCount = 0
    public private(set) var stopCount = 0
    public private(set) var cancelCount = 0
    public private(set) var permissionRequestCount = 0

    private weak var delegate: (any SpeechInputDelegate)?
    private var activeSession: VoiceSessionID?

    public init(
        permissions: VoicePermissions = VoicePermissions(
            microphone: .authorized,
            speechRecognition: .authorized
        ),
        available: Bool = true,
        mode: SpeechRecognitionMode = .onDevice
    ) {
        self.permissions = permissions
        self.available = available
        self.mode = mode
    }

    // MARK: SpeechInputService

    public func currentPermissions() async -> VoicePermissions { permissions }

    public func requestPermissions() async -> VoicePermissions {
        permissionRequestCount += 1
        return permissions
    }

    public func isAvailable() async -> Bool { available }

    public func recognitionMode() async -> SpeechRecognitionMode { mode }

    public func startListening(
        session: VoiceSessionID,
        delegate: any SpeechInputDelegate
    ) async {
        startCount += 1
        activeSession = session
        self.delegate = delegate
    }

    public func stopListening() async {
        stopCount += 1
        // Deliberately does *not* deliver a final result. Stopping asks the
        // recogniser to settle; the result arrives afterwards, and the test
        // decides when — which is the behaviour that makes the `finalizing`
        // state worth having.
    }

    public func cancelListening() async {
        cancelCount += 1
        activeSession = nil
    }

    // MARK: Driving it

    public func setPermissions(_ permissions: VoicePermissions) {
        self.permissions = permissions
    }

    public func setAvailable(_ available: Bool) {
        self.available = available
    }

    public func emitPartial(_ text: String, level: Float = 0.5) {
        emit(SpeechTranscript(text: text, isFinal: false, level: level))
    }

    public func emitFinal(_ text: String) {
        emit(SpeechTranscript(text: text, isFinal: true))
    }

    public func emitFailure(_ error: VoiceError) {
        guard let activeSession, let delegate else { return }
        delegate.speechInput(activeSession, didFailWith: error)
    }

    /// Delivers a result for a session that is already over.
    ///
    /// The stale-callback case. Real recognisers do this, and the coordinator
    /// has to drop it rather than treat it as something the user just said.
    public func emitFinal(_ text: String, forSession session: VoiceSessionID) {
        delegate?.speechInput(session, didProduce: SpeechTranscript(text: text, isFinal: true))
    }

    /// The session the mock currently believes it is recognising for.
    public func currentSession() -> VoiceSessionID? { activeSession }

    private func emit(_ transcript: SpeechTranscript) {
        guard let activeSession, let delegate else { return }
        delegate.speechInput(activeSession, didProduce: transcript)
    }
}

/// A synthesiser that records instead of speaking.
///
/// Unit tests must never make noise, and a CI runner has no audio output
/// device. This records what it was asked to say so a test can assert the
/// assistant's own words reached speech output — without asserting anything
/// about audio, which is not this layer's claim to make.
public actor MockSpeechOutputService: SpeechOutputService {
    public private(set) var spokenText: [String] = []
    public private(set) var stopCount = 0
    private var speaking = false

    public init() {}

    public func speak(_ text: String) async {
        spokenText.append(text)
        speaking = true
        // Returns immediately. The real implementation waits for the
        // synthesiser to finish; a test that waited would just be sleeping.
        speaking = false
    }

    public func stop() async {
        stopCount += 1
        speaking = false
    }

    public func isSpeaking() async -> Bool { speaking }

    /// The last thing the assistant said out loud.
    public func lastSpoken() -> String? { spokenText.last }
}

/// The service used where speech recognition cannot exist.
///
/// Reports `unsupported` rather than pretending to listen and then failing. The
/// microphone button can then be shown disabled with a truthful reason instead
/// of opening a session that was never going to work.
public actor UnavailableSpeechInputService: SpeechInputService {
    public init() {}

    public func currentPermissions() async -> VoicePermissions {
        VoicePermissions(microphone: .unsupported, speechRecognition: .unsupported)
    }

    public func requestPermissions() async -> VoicePermissions {
        await currentPermissions()
    }

    public func isAvailable() async -> Bool { false }

    public func recognitionMode() async -> SpeechRecognitionMode { .unavailable }

    public func startListening(session: VoiceSessionID, delegate: any SpeechInputDelegate) async {
        delegate.speechInput(session, didFailWith: .unsupported)
    }

    public func stopListening() async {}
    public func cancelListening() async {}
}
