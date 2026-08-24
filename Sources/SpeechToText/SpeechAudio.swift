import Foundation

/// The shape of a block of captured audio.
///
/// Section 10. Every engine in this milestone wants something slightly
/// different — Apple's analyzer takes the microphone's own format, whisper.cpp
/// insists on 16 kHz mono float, OpenAI wants a container it can parse — and
/// none of that belongs anywhere near the microphone button. This type plus
/// `SpeechAudioConverter` is the whole conversion boundary.
public struct SpeechAudioFormat: Hashable, Sendable {
    public var sampleRate: Double
    public var channelCount: Int

    public init(sampleRate: Double, channelCount: Int) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }

    /// What whisper.cpp requires, and what this app normalizes to internally.
    ///
    /// Chosen as the internal format because it is the most constrained of the
    /// three: converting 16 kHz mono up to something else is lossless in the
    /// only sense that matters here, while converting down from an arbitrary
    /// microphone rate has to happen exactly once no matter which provider is
    /// selected.
    public static let whisper = SpeechAudioFormat(sampleRate: 16_000, channelCount: 1)

    public var isMono: Bool { channelCount == 1 }
}

/// One block of captured audio, as normalized samples.
///
/// Interleaved `Float` in −1…1, which is what every engine here either wants
/// directly or can be fed after a trivial conversion. Deliberately not a
/// platform buffer type: `AVAudioPCMBuffer` is a non-`Sendable` class from a
/// framework that does not exist on Linux, and putting one in this type would
/// make the entire speech abstraction Apple-only and untestable.
public struct SpeechAudioChunk: Hashable, Sendable {
    public var samples: [Float]
    public var format: SpeechAudioFormat

    public init(samples: [Float], format: SpeechAudioFormat) {
        self.samples = samples
        self.format = format
    }

    public var duration: TimeInterval {
        guard format.sampleRate > 0, format.channelCount > 0 else { return 0 }
        return Double(samples.count) / (format.sampleRate * Double(format.channelCount))
    }

    /// Rough loudness, 0…1, for the level meter.
    ///
    /// Root-mean-square rather than peak: a single click should not pin the
    /// meter, and RMS is what tracks perceived loudness closely enough for a
    /// bar that is four pixels tall. Presentation only — nothing about
    /// recognition depends on it.
    public var level: Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        let rms = (sum / Float(samples.count)).squareRoot()
        // ×4 because speech at a comfortable distance sits around 0.05–0.25 RMS
        // and an unscaled meter would look broken.
        return min(1, rms * 4)
    }
}

/// Live audio, as an async sequence a provider consumes.
///
/// The stream ends when capture stops. A provider that transcribes in batches
/// drains it to completion and then works; a streaming provider processes as it
/// goes. Both see the same thing, which is what stops the capture layer needing
/// to know which kind it is talking to.
public struct SpeechAudioStream: Sendable {
    public let format: SpeechAudioFormat
    public let chunks: AsyncStream<SpeechAudioChunk>

    public init(format: SpeechAudioFormat, chunks: AsyncStream<SpeechAudioChunk>) {
        self.format = format
        self.chunks = chunks
    }

    /// A stream over already-captured audio. For tests and for replay.
    public static func fixed(_ chunks: [SpeechAudioChunk], format: SpeechAudioFormat)
        -> SpeechAudioStream
    {
        SpeechAudioStream(
            format: format,
            chunks: AsyncStream { continuation in
                for chunk in chunks { continuation.yield(chunk) }
                continuation.finish()
            }
        )
    }

    /// An empty stream — capture that produced nothing.
    public static func empty(format: SpeechAudioFormat = .whisper) -> SpeechAudioStream {
        fixed([], format: format)
    }
}

/// Sample-rate and channel conversion, in plain Swift.
///
/// ## Why not `AVAudioConverter`
///
/// Because this has to run in tests, on Linux, and inside a target that
/// deliberately imports nothing but Foundation. The conversion needed is
/// narrow — downmix to mono, resample to a fixed rate — and linear
/// interpolation is entirely adequate for speech recognition input at 16 kHz.
/// The Apple capture layer still uses `AVAudioConverter` where it is already
/// holding platform buffers; this is what the shared path uses.
///
/// It is not a general-purpose resampler and does not pretend to be: no
/// anti-aliasing filter, no dithering. For downsampling a 48 kHz microphone to
/// 16 kHz that is a real if minor quality cost, and it is recorded honestly in
/// `Docs/SPEECH.md` rather than glossed over.
public enum SpeechAudioConverter {

    /// Converts a chunk into `target`, returning it unchanged when it already
    /// matches.
    public static func convert(
        _ chunk: SpeechAudioChunk,
        to target: SpeechAudioFormat
    ) -> SpeechAudioChunk {
        guard chunk.format != target else { return chunk }
        let mono = downmix(chunk.samples, channels: chunk.format.channelCount)
        let resampled = resample(
            mono,
            from: chunk.format.sampleRate,
            to: target.sampleRate
        )
        // Only mono output is supported, because it is the only thing any
        // engine here asks for. Duplicating samples into stereo would be a
        // feature nobody uses hiding a conversion nobody checked.
        return SpeechAudioChunk(
            samples: resampled,
            format: SpeechAudioFormat(sampleRate: target.sampleRate, channelCount: 1)
        )
    }

    /// Averages interleaved channels down to one.
    static func downmix(_ samples: [Float], channels: Int) -> [Float] {
        guard channels > 1 else { return samples }
        let frames = samples.count / channels
        guard frames > 0 else { return [] }
        var output = [Float](repeating: 0, count: frames)
        for frame in 0..<frames {
            var sum: Float = 0
            for channel in 0..<channels {
                sum += samples[frame * channels + channel]
            }
            output[frame] = sum / Float(channels)
        }
        return output
    }

    /// Linear-interpolating resample.
    static func resample(_ samples: [Float], from source: Double, to target: Double) -> [Float] {
        guard source > 0, target > 0, source != target else { return samples }
        guard samples.count > 1 else { return samples }

        let ratio = source / target
        let outputCount = Int((Double(samples.count) / ratio).rounded(.down))
        guard outputCount > 0 else { return [] }

        var output = [Float](repeating: 0, count: outputCount)
        for index in 0..<outputCount {
            let position = Double(index) * ratio
            let lower = Int(position)
            let upper = min(lower + 1, samples.count - 1)
            let fraction = Float(position - Double(lower))
            output[index] = samples[lower] * (1 - fraction) + samples[upper] * fraction
        }
        return output
    }

    /// Drains a stream into one buffer in the target format.
    ///
    /// What a batch provider calls. Bounded by `maximumDuration` so a recording
    /// left running cannot grow without limit — at 16 kHz mono float, ten
    /// minutes is about 38 MB, which is a sane ceiling for a phone and well
    /// beyond any utterance this app expects.
    public static func collect(
        _ stream: SpeechAudioStream,
        as target: SpeechAudioFormat = .whisper,
        maximumDuration: TimeInterval = 600
    ) async -> SpeechAudioChunk {
        let limit = Int(target.sampleRate * maximumDuration)
        var samples: [Float] = []
        samples.reserveCapacity(min(limit, Int(target.sampleRate * 30)))

        for await chunk in stream.chunks {
            let converted = convert(chunk, to: target)
            if samples.count + converted.samples.count > limit {
                samples.append(contentsOf: converted.samples.prefix(limit - samples.count))
                break
            }
            samples.append(contentsOf: converted.samples)
        }
        return SpeechAudioChunk(
            samples: samples,
            format: SpeechAudioFormat(sampleRate: target.sampleRate, channelCount: 1)
        )
    }
}
