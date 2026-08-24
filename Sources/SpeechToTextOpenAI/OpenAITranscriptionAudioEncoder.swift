import Foundation
import SpeechToText

/// Turning captured samples into something OpenAI will accept.
///
/// ## Why WAV, and why in memory
///
/// Section 50 asks for an efficient conversion and warns against re-encoding
/// the whole recording repeatedly during capture. The approach here is the
/// simplest thing that satisfies both: samples accumulate as floats while the
/// user speaks, and the container is written **once**, at Stop, in a single
/// pass. There is no encoder running during capture at all.
///
/// WAV rather than a compressed format because the alternative is an audio
/// codec — `AVAudioConverter` or a third-party encoder — and neither can run in
/// a Foundation-only target that CI compiles on Linux. Sixteen-bit PCM at
/// 16 kHz mono is 32 KB per second: a thirty-second utterance is under a
/// megabyte, which is a completely ordinary upload and not worth a codec
/// dependency to shrink.
///
/// ## Why nothing touches the filesystem
///
/// Sections 49, 51 and 78 all ask that temporary audio be deleted promptly
/// after the request completes, fails or is cancelled. The strongest version of
/// that guarantee is to never write a file: the buffer lives for the duration
/// of one request and is released with it. Nothing to clean up, nothing to
/// leave behind if the app is killed mid-upload, and nothing on disk for
/// anything else to find.
public enum OpenAITranscriptionAudioEncoder {

    /// What the audio is converted to before upload.
    ///
    /// The same 16 kHz mono the rest of the speech subsystem normalizes to, so
    /// switching providers does not change how the microphone is treated.
    public static let uploadFormat = SpeechAudioFormat.whisper

    /// Writes samples as a 16-bit PCM WAV file, in memory.
    public static func wav(from chunk: SpeechAudioChunk) -> Data {
        let audio = SpeechAudioConverter.convert(chunk, to: uploadFormat)
        let sampleRate = UInt32(uploadFormat.sampleRate)
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataBytes = UInt32(audio.samples.count * 2)

        var data = Data(capacity: 44 + Int(dataBytes))

        // RIFF header
        data.append(contentsOf: Array("RIFF".utf8))
        data.appendLittleEndian(UInt32(36 + dataBytes))
        data.append(contentsOf: Array("WAVE".utf8))

        // Format chunk
        data.append(contentsOf: Array("fmt ".utf8))
        data.appendLittleEndian(UInt32(16))          // PCM chunk size
        data.appendLittleEndian(UInt16(1))           // PCM, uncompressed
        data.appendLittleEndian(channels)
        data.appendLittleEndian(sampleRate)
        data.appendLittleEndian(byteRate)
        data.appendLittleEndian(blockAlign)
        data.appendLittleEndian(bitsPerSample)

        // Data chunk
        data.append(contentsOf: Array("data".utf8))
        data.appendLittleEndian(dataBytes)
        for sample in audio.samples {
            // Clamped before scaling: a sample slightly outside −1…1 would
            // otherwise wrap to the opposite extreme and produce an audible
            // click that the transcriber hears as a consonant.
            let clamped = max(-1, min(1, sample))
            data.appendLittleEndian(Int16(clamped * 32767).bitPattern)
        }
        return data
    }

    /// Builds the multipart body for a transcription request.
    ///
    /// - Parameter language: an ISO-639-1 code. Sent when known, because it
    ///   materially improves accuracy; omitted rather than guessed when not.
    public static func multipartBody(
        wav: Data,
        model: String,
        language: String?,
        boundary: String
    ) -> Data {
        var body = Data()

        func field(_ name: String, _ value: String) {
            body.append(contentsOf: Array("--\(boundary)\r\n".utf8))
            body.append(contentsOf: Array(
                "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8
            ))
            body.append(contentsOf: Array("\(value)\r\n".utf8))
        }

        body.append(contentsOf: Array("--\(boundary)\r\n".utf8))
        body.append(contentsOf: Array(
            "Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".utf8
        ))
        body.append(contentsOf: Array("Content-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav)
        body.append(contentsOf: Array("\r\n".utf8))

        field("model", model)
        if let language, !language.isEmpty { field("language", language) }
        // Plain JSON rather than `verbose_json`: the extra response carries
        // segment timings and token log-probabilities, none of which may cross
        // into the assistant (section 72), so asking for them would be
        // requesting data purely to discard it.
        field("response_format", "json")

        body.append(contentsOf: Array("--\(boundary)--\r\n".utf8))
        return body
    }

    /// A fresh multipart boundary.
    ///
    /// Random per request, because a fixed boundary that happens to occur in
    /// the audio bytes would corrupt the upload — and PCM audio is arbitrary
    /// binary, so "happens to occur" is a real possibility rather than a
    /// theoretical one.
    public static func makeBoundary() -> String {
        "PersonalAssistantAudio-\(UUID().uuidString)"
    }

    /// The language code to send, or nil to let the service detect it.
    public static func languageCode(for locale: Locale?) -> String? {
        guard let locale else { return nil }
        let identifier = locale.identifier
        let head = identifier
            .components(separatedBy: CharacterSet(charactersIn: "-_"))
            .first ?? identifier
        let code = head.lowercased()
        return code.isEmpty ? nil : code
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
