# Speech-to-Text

Part 13. Three interchangeable transcription providers behind one microphone,
producing a plain string that meets the assistant through exactly the path
typed text takes.

## The shape of it

```
microphone (one AVAudioSession, shared)
        │  SpeechAudioChunk — [Float], 16 kHz mono
        ▼
SpeechToTextProvider          Apple │ Local Whisper │ OpenAI
        │  SpeechToTextEvent — .partial(String), .final(String)
        ▼
SpeechPipelineInputService    (Part 5's SpeechInputService, unchanged contract)
        │  SpeechTranscript
        ▼
VoiceCoordinator              (Part 5, untouched)
        │  String
        ▼
AppModel.send(_:from:)        ← the same method the composer's Send button calls
        ▼
AssistantEngine → AIProvider → memory, tools, follow-up, platform
```

The last arrow into the assistant carries a `String`. Nothing audio-shaped
crosses it, because by that point nothing audio-shaped exists.

## Why the boundary holds

`SpeechToText` is a package target with **no dependencies at all** — not
`AssistantDomain`, not `AssistantAI`, not the repositories. A transcription
provider cannot call the assistant, retrieve a memory or execute a tool,
because none of those types are reachable from the module it lives in. That is
the difference between a rule someone has to remember and a property of the
program.

The same technique carries the other guarantees:

| Guarantee | How it is enforced |
|---|---|
| A local failure never uploads audio | `SpeechToTextLocal` does not depend on `SpeechToTextOpenAI` |
| Speech is not the assistant's provider | `SpeechToTextOpenAI` does not depend on `AIProviderRemote` |
| `Speech.framework` stays out of shared code | Only `SpeechToTextApple` imports it |
| whisper.cpp stays out of shared code | Only `SpeechToTextLocalWhisper` imports it |
| Speech models are not chat models | `SpeechModelIdentifier` ≠ `AIModelIdentifier` |

## The three providers

### Apple

One provider, three of Apple's APIs behind it, chosen per locale at session
start:

1. `SpeechAnalyzer` + `SpeechTranscriber` (iOS 26) — preferred where the OS and
   locale support it, and where the locale assets are actually installed.
2. `DictationTranscriber` — Apple's documented compatibility path.
3. `SFSpeechRecognizer` — available on every device this app deploys to.

Partial results are supported. The privacy claim is **reported by the backend
that will run**, not asserted for the provider: `SFSpeechRecognizer` only
guarantees on-device processing when `supportsOnDeviceRecognition` is true *and*
the request asked for it. Both are checked. Where they do not hold, Settings
says Apple may use its servers.

An uninstalled locale asset is reported as a *preparation* state, never as
Ready — the one case where an optimistic answer means failing at the exact
moment the user speaks.

### Local Whisper

whisper.cpp, pinned to **v1.9.2**.

> v1.9.3 is a newer tag but its release did not publish an XCFramework asset. A
> pin has to point at something that exists.

- URL: `https://github.com/ggml-org/whisper.cpp/releases/download/v1.9.2/whisper-v1.9.2-xcframework.zip`
- SHA-256: `af74fed13ea7f2d5ca2a39d9f58ec177713fafd7cab63aef4e27b79f3ceca80b`
- Linked only when `PPAI_WHISPER_RUNTIME=1` is set at manifest evaluation. The
  `Local model runtime` workflow sets it and builds with `-DPPAI_REQUIRE_WHISPER`,
  which turns "whisper is missing" into a `#error` — so a stub build cannot pass
  for a real one.

Final transcripts only. Chunked streaming would mean re-decoding overlapping
windows and reconciling transcripts that disagree at the seams; done carelessly
it produces text that reads fluently and says something the user did not.
`supportsPartialResults` is false, honestly, and the composer shows
"Transcribing…" after Stop.

Models live in `Application Support/Models/Speech/` — a sibling of the language
models, never a mixture. Install order is download → checksum → size → `ggml`
magic → atomic move, and a file that fails any step is deleted rather than left
on disk.

### OpenAI

A separate provider from `RemoteAIProvider`: same company, same credential, two
different decisions. Reads the OpenAI key from the existing Keychain-backed
credential store — there is no second key to enter and no second place a key
could live.

Audio is encoded once, at Stop, as 16-bit PCM WAV held **in memory**. Nothing is
written to disk, which is the strongest available form of "delete temporary
audio promptly": there is nothing to delete, and nothing left behind if the app
is killed mid-upload.

Transcription models are configurable strings. `gpt-4o-transcribe` is the
default; an identifier newer than this build is passed through unchanged rather
than rejected.

## What audio does, per provider

| Provider | Leaves the device | Works offline | Live partials |
|---|---|---|---|
| Apple | Apple's own servers, for some locales | Where on-device is available | Yes |
| Local Whisper | No | Yes, once a model is installed | No |
| OpenAI | **Yes, to OpenAI** | No | No |

Uploading happens only while OpenAI is the selected provider. There is no
fallback path into it: not from Apple, not from Local, and not when either of
those fails. A failure is reported as a failure.

## Known limitations

- **Catalog checksums are absent.** The model host is unreachable from the
  development environment this was built in, so the published digests could not
  be recorded. The installer enforces a checksum when the catalog provides one;
  without one it still validates size (±20%) and the `ggml` magic, which catches
  the failure that actually happens — a CDN error page saved under a model's
  name. Recorded in `OPEN-ITEMS.md`; fill the digests in before shipping.
- **The compressed model's declared size is derived, not measured**, for the
  same reason. The tolerance above is what protects against it being wrong.
- **Resampling is linear interpolation**, with no anti-aliasing filter.
  Adequate for 16 kHz speech recognition input; a real if minor quality cost
  when downsampling a 48 kHz microphone.
- **Cancellation of a Whisper decode is prompt, not instantaneous.** It is a C
  abort callback the decode loop checks between steps.

## Device-only validation remaining

None of the following can be checked by CI, a simulator, or this development
environment. They do not represent incomplete implementation.

- Apple Speech accuracy with a real microphone and a real voice
- Apple partial-result latency — how far behind the speaker text appears
- Apple locale asset download, and whether `installedLocales` reports what the
  device actually has
- Which Apple backend is selected on a given device and locale, and whether the
  on-device path is genuinely taken
- Local Whisper model load time
- Local Whisper RAM use against the conservative estimate
- Local Whisper transcription speed, and whether the real-time factor is usable
- Whether Metal acceleration is actually engaged
- Thermal behaviour during a long transcription
- Battery consumption
- Long-recording stability, and the ten-minute capture bound
- Bluetooth microphone input, including a headset connecting mid-sentence
- Interruption by a phone call or Siri, mid-utterance
- OpenAI upload latency on a real connection
- Cellular versus Wi-Fi behaviour, including a mid-upload network change
- Real microphone and audio quality, and whether the level meter tracks a voice
