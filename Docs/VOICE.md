# Voice

Speaking to the assistant, without a second assistant appearing.

## The whole design, in one line

```
microphone → text → the same submit(_:) the send button calls → everything else
```

There is no `VoiceAssistantEngine`. There is no voice-specific provider, no
voice-specific memory retrieval, no voice-specific tool path. A sentence spoken
and the same sentence typed produce byte-identical work, because after
transcription they *are* the same call.

```
AppModel.send(_:from:)
    ↑                    ↑
send button        VoiceCoordinator
```

`from:` carries exactly one thing — whether the reply should be read aloud — and
it is applied *after* the turn, in the presentation layer. It is not passed to
`AssistantEngine`, does not reach a provider, is not stored on the message, and
does not alter context assembly, memory ranking, tool validation, authorization,
follow-up planning or platform execution.

## Where the code lives

`Sources/AssistantVoice/`, a package target that **depends on nothing else in
the package**. Not the engine, not a repository, not `AssistantPlatform`. That
is the architectural claim written as a dependency list: the voice layer cannot
call `AlarmKit`, cannot write to SwiftData and cannot reach a provider, because
none of them is available to it. It turns speech into a `String` and hands it to
a closure.

The consequence worth noticing: `VoicePipelineTests` — the test that proves a
spoken command runs the whole pipeline — has to live in `AssistantCoreTests`,
because `AssistantVoice` cannot import the engine to test itself against it.
That inability is the design working.

| File | Role | Imports |
| --- | --- | --- |
| `VoiceState` | States and errors | none |
| `VoiceSession` | **The rules**, as a pure reducer | none |
| `SpeechServices` | Protocols, permissions, transcripts | none |
| `VoiceCoordinator` | Performs effects, publishes state | Observation |
| `MockSpeechServices` | Deterministic services for tests and CI | none |
| `AppleSpeechInputService` | `SFSpeechRecognizer` + `AVAudioEngine` | Speech, AVFAudio |
| `AppleSpeechOutputService` | `AVSpeechSynthesizer` | AVFAudio |

## Which Speech API, and an honest answer about the modern one

**`SFSpeechRecognizer`.** Not iOS 26's `SpeechAnalyzer` / `SpeechTranscriber`.

The modern stack is a better API — `async`-native, with proper volatile and
finalised ranges instead of a stream of whole-string guesses, and explicit
locale asset management. It is also iOS 26+, and this app deploys to iOS 17. So
`SFSpeechRecognizer` is required for the great majority of supported devices no
matter what, and the modern path would be an *addition* rather than a
replacement.

That means two implementations of one feature, neither of which can be executed
from this development environment, because CI has no microphone. Shipping one
unverified speech path is a known risk. Shipping two doubles it while halving
the chance either gets properly device-tested.

The seam is `SpeechInputService`, and the branch is in `VoiceServices.live()`.
Adding `SpeechAnalyzer` later means writing one type and extending one `if`.
Nothing above the protocol changes — the same bet `AIProvider` made, which paid
off when Apple's on-device model arrived.

## The state machine

Voice is where scattered booleans go to become bugs. `isRecording`,
`isProcessing`, `isSpeaking` and `hasError` have sixteen combinations and about
five meanings; the other eleven are races waiting to happen — listening *and*
speaking, processing *and* failed. `VoiceState` cannot represent them.

```
idle ──tap──▶ requestingPermission ──granted──▶ listening
                      │                            │  │
                   refused                      stop│  │cancel
                      ▼                            ▼  ▼
                   failed ◀──error────────── finalizing → idle
                      │                            │
                  retry│                    final result
                      │                            ▼
                      └──────────────────────▶ processing ──▶ idle
                                                              │
                                                     reply spoken
                                                              ▼
                                                          speaking → idle
```

`VoiceSession` is a pure value: events in, `[VoiceEffect]` out. It performs
nothing. That is what makes every rule below testable without a microphone, an
audio session, a device or an assistant — and every bug this subsystem can have
is a timing bug, which against a real recogniser is unreproducible and here is
three lines.

**Cancellation is not a state.** The milestone's sketch lists `cancelled`
alongside `idle`; it is modelled as an *event* returning to `.idle` because
nothing ever rests there. The user has just pressed Cancel — they know what they
did, and a "Cancelled" screen to dismiss is worse than the composer coming back.
`failed` *is* a resting state, because there is something to say and a decision
to make.

## Stop and Cancel mean opposite things

| Button | Meaning | Transcript |
| --- | --- | --- |
| **Stop** | "I've finished speaking" | finalised and submitted |
| **Cancel** | "Ignore what I just said" | discarded, never submitted |

Two buttons that did the same thing would make the second one a lie. `Stop`
calls `endAudio()` — the microphone closes but the recogniser keeps working,
because the last words spoken are still being processed and cancelling there
would throw away the end of the sentence. `Cancel` cancels the task outright, so
no final result is ever produced.

Cancel is the quieter button and sits on the left, away from the thumb. Stop is
the common action.

## Submitting exactly once

Speech APIs deliver more than one final-looking callback around the end of a
session — a final result, then the task completing. A naive implementation sends
the user's sentence twice, and since the assistant creates calendar events and
alarms, "twice" is not cosmetic.

Two independent defences:

1. **`VoiceSessionID`.** A new one per attempt. The coordinator drops any
   callback whose session is not the one in progress, which covers results
   arriving after cancellation — the audio was already in flight.
2. **`hasSubmitted`.** Set when `.submit` is emitted. Covers a *live* session
   producing two finals.

Either alone would leave a hole. `AppleSpeechInputService` adds a third at the
source, refusing to forward anything once `isFinished` is set.

## Permissions

Nothing at launch. Both permissions are requested the first time the user taps
the microphone, and the microphone alert comes first — if it is declined the
speech-recognition alert is never shown, because recognition without a
microphone is useless and two refusals in a row is worse than one.

| iOS | App | Shown |
| --- | --- | --- |
| granted / authorized | `.authorized` | Allowed |
| denied | `.denied` | Denied, with a route to Settings |
| restricted | `.restricted` | Restricted — **no** Settings button |
| not determined | `.notDetermined` | Not asked yet |
| framework absent | `.unsupported` | Unavailable |

`restricted` is kept apart from `denied` because Screen Time and MDM profiles
produce it and the person holding the phone cannot change it. Offering them a
Settings button would be a dead end.

**The app never opens Settings on its own.** It offers a button and the user
decides. Being ejected from an app because a permission was missing is a context
switch nobody asked for.

Apple's authorization enums never leave `AppleSpeechInputService`. No view
switches over `SFSpeechRecognizerAuthorizationStatus`, which is also why the
mapping can be tested on a machine where that type does not exist.

## Audio

One `.playAndRecord` session with `.spokenAudio` mode, `.duckOthers` and
`.allowBluetooth`. The alternative — `.record` for input, `.playback` for the
reply — means recategorising between every turn, and each switch is an audible
gap plus an opportunity to fail.

The session is deactivated on **every** exit path: finish, cancel, failure,
interruption. Leaving it active keeps the orange recording indicator lit and
other apps ducked, which looks exactly like an app secretly listening.

**Interruptions end the attempt.** A phone call or Siri taking the session marks
the session `.interrupted` and offers Retry, rather than trying to resume
through it. Audio captured across an interruption is missing the middle of the
sentence, and half a sentence submitted to an assistant that acts on what it
hears is worse than none.

## Speaking, and the handoff

`AVSpeechSynthesizer`, in `AppleSpeechOutputService`, reached only from the
presentation layer:

```
AssistantEngine → String → AppModel → VoiceCoordinator → SpeechOutputService
```

`AssistantEngine` returns text and has no idea whether anything says it. The
moment an engine knows about a synthesiser, "what the assistant decided" and
"how it was presented" stop being separable, and every future output channel has
to be threaded back through the reasoning layer.

**Tapping the microphone while the assistant is talking stops it first**, in
that order, or the microphone opens into the synthesiser's own voice and the
assistant transcribes itself. The state machine emits `[.stopSpeaking,
.requestPermission]` as one pair, and `stopSpeaking(at: .immediate)` rather than
`.word` — finishing the current word would leave a tail for the microphone to
catch.

### When replies are spoken

Off until asked. Two switches, and the second only appears when the first is on:

| `speaksReplies` | `speaksTypedReplies` | Spoken request | Typed request |
| --- | --- | --- | --- |
| off | — | silent | silent |
| on | off | **spoken** | silent |
| on | on | **spoken** | **spoken** |

Typing is what people do when they cannot or do not want to make noise, so a
typed message stays silent unless explicitly opted in. The decision lives in one
function, `VoicePreferences.shouldSpeak(replyTo:)`, so it cannot drift between
the composer and Settings.

Persisted in `AssistantSettings` through schema V4 — three additive columns
whose declared defaults are `false`, so updating the app never makes it start
talking at someone.

## Privacy

- **No audio is stored.** Buffers are appended to the recogniser and released.
  Nothing is written to disk, and nothing goes into SwiftData.
- **No audio reaches an AI provider.** The provider receives the transcribed
  text, exactly as if it had been typed.
- **On-device recognition is asked for whenever the device supports it**, and
  `recognitionMode()` reports where processing *actually* happens rather than
  where we would like it to. `SFSpeechRecognizer` only guarantees on-device
  handling when `supportsOnDeviceRecognition` is true, so both that and the
  request flag are checked before the Settings screen says "On this iPhone".
  Claiming someone's voice stays on their phone when it does not would be the
  worst kind of privacy claim to get wrong.
- **Nothing spoken is logged.** Platform errors are replaced with sentences
  written in this codebase, because a Speech framework `NSError` can carry the
  recognised text in its user info.

## What is not in this milestone

No wake word, no always-listening mode, no background recording, no lock-screen
assistant, no Siri or App Intents invocation, and no conversation mode that
reopens the microphone by itself. Voice is explicitly user-initiated, every
time.

## What CI proves, and what it cannot

| Job | Proves |
| --- | --- |
| Swift Tests | The state machine, the coordinator wiring, and that a transcript runs the whole assistant pipeline |
| Apple SDK Check | `SFSpeechRecognizer`, `AVAudioEngine` and `AVSpeechSynthesizer` really compile against the iOS SDK |
| iOS Simulator Preview | The app builds, launches and renders the voice UI |

A GitHub runner has no microphone. Every test uses `MockSpeechInputService`,
which is why the timing cases can be tested at all — and why none of them proves
that recognition works.

The screenshot pipeline gets `VoiceServices.mock()` for the same reason demo
seeding gets mock platform services: a seeded launch is a demonstration, and it
must not open an audio session.

## What still needs a real device

Marked `TODO-DEVICE` in the source.

- The permission alerts appearing, in order, with the right Info.plist strings.
- Live recognition: accuracy, and how far behind the speaker partial results
  actually lag.
- The level meter responding to a real voice rather than to a number.
- Bluetooth microphone routing, and what happens when the headset disconnects
  mid-sentence.
- A phone call arriving while listening, and Retry working afterwards.
- The TTS → microphone handoff: that stopping at `.immediate` really prevents
  the recogniser hearing the tail of the assistant's own voice.
- Whether `.playAndRecord` with `.duckOthers` behaves acceptably against music
  already playing.

The scenario worth running first is the milestone's own: tap the microphone,
say *"remind me tomorrow at ten in the morning to call the dentist"*, and stop.
What to check is not that it heard you — it is that the result is
indistinguishable from typing the same sentence.
