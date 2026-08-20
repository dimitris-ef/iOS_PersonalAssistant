import Foundation

#if os(iOS) && canImport(AVFAudio)
import AVFAudio

/// Reads the assistant's replies aloud.
///
/// Kept entirely separate from `AssistantEngine`, which returns a `String` and
/// has no idea whether anything says it. That separation is not tidiness: the
/// moment an engine knows about a synthesiser, "what the assistant decided" and
/// "how it was presented" stop being separable, and every future output
/// channel — a watch, a car, a transcript — has to be threaded back through the
/// reasoning layer.
///
/// A class rather than an actor because `AVSpeechSynthesizer` requires a
/// delegate and the delegate callbacks are the only way to know when speech
/// finished. State is guarded by a lock instead.
public final class AppleSpeechOutputService: NSObject, SpeechOutputService, @unchecked Sendable {

    private let synthesizer = AVSpeechSynthesizer()
    private let lock = NSLock()
    /// Resumed when the current utterance ends, however it ends.
    private var continuation: CheckedContinuation<Void, Never>?
    private var speaking = false

    public override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Speaks, and returns when it has finished.
    ///
    /// Awaiting completion rather than firing and forgetting is what makes
    /// "stop speaking, then start listening" expressible as two sequential
    /// lines elsewhere.
    public func speak(_ text: String) async {
        await stop()

        let utterance = AVSpeechUtterance(string: text)
        // The user's own language, matching the recogniser. A reply spoken in a
        // different accent from the one that was understood is disorienting.
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.identifier)
            ?? AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        // A short lead-in, so the first word is not clipped by the audio route
        // still coming up.
        utterance.preUtteranceDelay = 0.1

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            self.continuation = continuation
            speaking = true
            lock.unlock()
            synthesizer.speak(utterance)
        }
    }

    public func stop() async {
        lock.lock()
        let isSpeaking = speaking
        lock.unlock()

        guard isSpeaking else { return }
        // `.immediate` rather than `.word`: this is called when the user taps
        // the microphone, and finishing the current word first would mean the
        // microphone opens into the tail of the assistant's own voice.
        synthesizer.stopSpeaking(at: .immediate)
        finish()
    }

    public func isSpeaking() async -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return speaking
    }

    /// Resumes the waiter exactly once, whichever way speech ended.
    private func finish() {
        lock.lock()
        let waiter = continuation
        continuation = nil
        speaking = false
        lock.unlock()
        waiter?.resume()
    }
}

extension AppleSpeechOutputService: AVSpeechSynthesizerDelegate {
    public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        finish()
    }

    public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        finish()
    }
}
#endif
