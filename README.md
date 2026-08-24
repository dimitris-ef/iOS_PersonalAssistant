# PhonePersonalAI

A native iPhone personal AI assistant, built around executive-function and ADHD
support.

You talk to it normally — *"I have a haircut next Sunday at 10 PM"*, *"remind me
to pay this bill"*, *"make sure I actually wake up"* — and it turns that into
calendar events, staged reminders, alarms and tracked tasks, then keeps chasing
the ones you have not actually finished.

The distinguishing idea is in that last sentence. **Dismissing a notification is
not the same as doing the thing.** The app models the difference explicitly and
keeps responsibility for a task until you confirm it is done.

---

## Status

The repository contains the **core** and the **SwiftUI application**. What
exists:

- the domain models
- the assistant turn pipeline (context → provider → structured actions → execution)
- the AI provider abstraction, with three provider types
- the structured tool system, with validation and authorization
- the reminder-planning layer, including follow-up after a reminder is
  dismissed, snoozed or ignored
- protocol-based platform services, with **real Apple implementations** —
  EventKit, UserNotifications and AlarmKit — alongside the mocks that tests,
  previews and CI still use
- repository interfaces with two implementations: **SwiftData on disk for the
  app**, and in-memory/JSON for tests, previews and the dev harness
- a command-line harness and unit tests
- **the iPhone app's SwiftUI interface** — Assistant, Today, Tasks, Memory and
  Settings, with real navigation, sheets, forms and components
- **voice input and optional spoken replies**, which reuse the typed-input
  submission path rather than adding a second assistant
- **Siri, Shortcuts and Action Button access** through App Intents, over the
  same command layer — no second assistant engine
- **a bounded multi-round agent loop**: one message can need several coordinated
  actions, the model sees what each one really did before choosing the next, and
  nothing can happen twice

The UI is the production interface, not a prototype: it is SwiftUI, it sits on
the existing architecture, and it calls the same protocols the Apple
implementations do.

The Apple framework integrations: the on-device model over Foundation Models;
the calendar, reminders, notifications and alarms over EventKit,
UserNotifications and AlarmKit; and **speaking to the assistant** over one
shared microphone feeding whichever transcription provider is selected — Apple
Speech, a downloaded Whisper model running on the phone, or OpenAI — see
[`Docs/SPEECH.md`](Docs/SPEECH.md). Which engine transcribes and which model
answers are two independent choices; and **Siri, Shortcuts and the Action Button** over App Intents. A
shipped build changes the user's actual phone; tests, previews and CI keep the
mocks. **Widgets, Lock Screen widgets, Live Activities, the Dynamic Island and a
custom keyboard** exist too, as thin surfaces over the same state — see
[`Docs/SYSTEM-SURFACES.md`](Docs/SYSTEM-SURFACES.md). CarPlay and a Watch app do
not — see [Open items](Docs/OPEN-ITEMS.md).

> **What has and has not been verified.** This is written on a machine with no
> Swift toolchain, so CI is the only compiler. Three GitHub Actions workflows,
> all green:
>
> | Workflow | Runner | What it proves |
> | --- | --- | --- |
> | iOS Simulator Preview | macos-15, Xcode 16.4 | The app builds, launches and renders |
> | Apple SDK Check | macos-26, Xcode 26.6 | Foundation Models, AlarmKit, EventKit, UserNotifications, Speech, AVFAudio and App Intents are really compiled in, and the two iOS 26 frameworks are weakly linked |
> | Swift Tests | macos-26, Xcode 26.6 | 400 tests, 0 failures |
>
> What remains unverified is narrower now: **nothing has run on a device.** The
> Apple integrations compile, link, and have their decisions tested — which
> notification action means "done", what partial calendar access may claim, how
> an identifier round-trips — but no permission alert has appeared, no
> notification has been delivered, no alarm has sounded, no word has been
> spoken or heard, and no generation has happened. A CI runner has no calendar
> database, no notification centre, no alarm daemon, no microphone, no Siri and
> no Apple Intelligence. See [Open items](Docs/OPEN-ITEMS.md).

---

## Windows-first development strategy

The developer is on Windows with no Mac. Rather than compromise on building a
genuinely native iOS app, the project is split so that the majority of the work
can happen now and the Apple-specific work happens later without redesign.

**Layer A — platform-independent core.** Plain Swift. No SwiftUI, no Apple-only
frameworks. Conversation and memory models, the assistant pipeline, AI provider
abstraction, tool definitions, reminder planning, task state, persistence
interfaces. This is the "brain", and it is what you can develop and test today.

**Layer B — the iOS layer.** SwiftUI, EventKit, AlarmKit, UserNotifications,
App Intents, WidgetKit, ActivityKit. Everything here is an *implementation of an
interface the core already defines*.

The SwiftUI app lives in [`iOS/`](iOS/README.md), which is not part of the Swift
package and is not compiled during Windows development. The framework adapters
moved into the package as `AssistantPlatformApple`, behind `#if canImport`
guards: they still do not compile on Windows, but the decisions inside them —
what each notification action means, what partial permission may claim — are
pure functions that compile and are tested everywhere. `iOS/` has no test
target, and code that decides whether a dismissal counts as completion should
not live somewhere nothing can check it.

This is still a native iOS app. There is no React Native, Flutter, Electron,
Capacitor or webview anywhere in it, and the abstractions exist to defer Apple
work, not to avoid it.

### What works on Windows

| Works today | Needs Xcode |
| --- | --- |
| Domain models, task/reminder state | Notification delivery on a device |
| Assistant turn pipeline | Permission alerts actually appearing |
| Tool definitions, validation, authorization | An alarm sounding through Focus |
| Reminder planning and scheduling | Siri discovery and invocation |
| Task status machine | Action Button assignment |
| App Intent command layer | Widget and Lock Screen rendering |
| Widget projections, timelines, keyboard layout | Live Activities, Dynamic Island |
| Repositories (SwiftData and JSON-backed) | Background execution |
| Mock **and** Apple platform services | Signing, provisioning, TestFlight |
| AI provider abstraction and routing | |
| CLI harness, unit tests | |

---

## Architecture

```
PhonePersonalAI/
├── Package.swift
├── Sources/
│   ├── AssistantDomain/        Models and vocabulary. Depends on nothing.
│   ├── AssistantAI/            AIProvider abstraction, registry, routing.
│   ├── AssistantTools/         Tool definitions, decoding, authorization, plans.
│   ├── AssistantPlatform/      Protocols for OS capabilities.
│   ├── AssistantPersistence/   Repository protocols + snapshot implementations.
│   ├── ExecutiveSupport/       Reminder planning and task status rules.
│   ├── AssistantCore/          The turn pipeline that ties it together.
│   ├── MockPlatform/           In-memory platform services.
│   ├── AssistantPlatformApple/ EventKit, UserNotifications, AlarmKit (real)
│   ├── AssistantVoice/         Speech recognition and synthesis (real)
│   ├── AIProviderApple/        Apple Foundation Models  (real; TODO-DEVICE)
│   ├── AIProviderLocal/        Downloaded local model    (runtime not chosen)
│   ├── SystemSurfaces/         What the keyboard and widgets may see. Foundation only.
│   ├── AIProviderRemote/       Remote API, vendor-neutral
│   ├── DevSupport/             Scripted provider for development only
│   └── DevHarness/             CLI harness (assistant-dev)
├── Tests/
├── iOS/                        The SwiftUI app. Not in the package — Xcode territory.
│   ├── App/                    Entry point, composition root, shared state
│   ├── Data/                   Centralised demo content
│   ├── Presentation/           Domain → display mapping
│   ├── ViewModels/             Per-screen state
│   ├── Intents/                App Intents: Siri, Shortcuts, Action Button
│   ├── SystemSurfaces/         Keyboard extension, widget extension, shared
│   ├── UI/                     Views and reusable components
│   ├── Platform/               Keychain credential store
│   └── Resources/              Assets, Info.plist
├── project.yml                 XcodeGen spec for the app target
└── Docs/
    ├── ARCHITECTURE.md      Decisions and module boundaries
    ├── AGENT.md             The multi-round tool loop
    ├── UI-ARCHITECTURE.md   How the SwiftUI layer is organised
    ├── OPEN-ITEMS.md        Everything incomplete, unverified or limited
    ├── PLATFORM-APPLE.md    EventKit, UserNotifications, AlarmKit
    ├── VOICE.md             Speech in, speech out
    ├── SYSTEM-INTENTS.md    Siri, Shortcuts and the Action Button
    ├── APPLE-ON-DEVICE.md   Foundation Models
    ├── LOCAL-MODELS.md      Downloadable GGUF models and llama.cpp
    ├── REMOTE-AI.md         The cloud provider and its credentials
    ├── PERSISTENCE.md       SwiftData schema and migration
    ├── FOLLOW-UP.md         The escalation ladder
    ├── EXECUTIVE-SUPPORT.md Routines, dependencies, preparation, starting
    ├── BACKGROUND.md        Recovery when the app was not running
    ├── SYSTEM-SURFACES.md   Keyboard, widgets, Lock Screen, Dynamic Island
    ├── SPEECH.md            Interchangeable speech-to-text providers
    ├── MEMORY.md            Retrieval, ranking, deduplication
    └── SEMANTIC-MEMORY.md   Meaning, consolidation, aging, lifecycle
```

Dependencies point one way: `AssistantDomain` ← everything else, and the engine
sits at the top. Nothing in the core imports SwiftUI or an Apple-only framework.

Longer discussion of the decisions is in [`Docs/ARCHITECTURE.md`](Docs/ARCHITECTURE.md).

---

## How AI providers work

The rest of the app does not know or care which model is running.

```swift
public protocol AIProvider: Sendable {
    var metadata: AIProviderMetadata { get }
    func availability() async -> AIProviderAvailability
    func availableModels() async throws -> [AIModel]
    func respond(to request: AIRequest) async throws -> AIResponse
}
```

Three categories are supported:

- **`AIProviderApple`** — Apple's on-device Foundation Models, over
  `SystemLanguageModel` and `LanguageModelSession`. Real, and compiled in CI
  against the iOS 26 SDK, but never run: inference needs an Apple
  Intelligence device. `TODO-DEVICE`. See [`Docs/APPLE-ON-DEVICE.md`](Docs/APPLE-ON-DEVICE.md).
- **`AIProviderLocal`** — a model the user downloaded. Fully built except
  inference, which is delegated to a `LocalModelRuntime`. **No runtime is
  chosen** — not llama.cpp, MLX, Core ML or ExecuTorch. That decision is
  deliberately deferred, and making it later means writing one type.
- **`AIProviderRemote`** — **working.** Speaks the OpenAI-compatible
  chat-completions protocol, including tool calling, against any endpoint you
  configure: OpenAI, a compatible vendor, or a self-hosted server. The wire
  format lives entirely in `OpenAICompatibleAdapter`; the provider itself is
  neutral. Endpoint and model are settings; the API key is kept in the Keychain.
  See [`Docs/REMOTE-AI.md`](Docs/REMOTE-AI.md).

`ModelRouter` picks one per turn based on settings (`preferOnDevice`,
`preferMostCapable`, `explicit`). Under `explicit`, an unavailable provider is an
error rather than a silent substitution. With nothing configured, routing falls
back to the scripted development provider, so the app always works.

Availability is a provider-neutral state — `available`, `configurationRequired`,
`temporarilyUnavailable`, `unsupported` — so Settings can tell "needs an API
key" apart from "not built yet" without matching on error strings.

**Switching providers costs the user nothing.** Conversations, memories, the
profile, routines, tasks, reminder plans, automations, settings and the tool
catalogue all live in application storage. A provider receives a rendered view of
context and returns text plus structured tool calls; it owns none of it. This is
covered by tests in `Tests/AssistantCoreTests/ProviderSwapTests.swift`.

---

## How tools work

The model never touches an OS API. It proposes; the app disposes.

```
model proposes  →  decode + validate  →  authorize  →  service executes  →  result
   AIToolCall        ToolRequest        ToolAuthorization    PlatformService   ToolResult
```

1. A provider returns `AIToolCall`s: a name and untyped JSON arguments.
2. `ToolRequestDecoder` turns each into a typed `ToolRequest`, or rejects it.
   Unknown names, malformed arguments and nonsense values (empty titles, alarms
   in the past) are discarded, not guessed at.
3. `DefaultActionPlanner` builds an `AssistantActionPlan` and — this is the
   interesting part — *expands* it: a calendar event also produces its staged
   reminder actions, attributed to the app rather than to the model.
4. `SettingsToolAuthorizer` marks each action `allowed`,
   `requiresConfirmation` or `denied`.
5. `DefaultToolExecutor` re-checks authorization, checks the OS permission, and
   calls the relevant platform service.

Application behaviour never depends on parsing the assistant's prose.

The tools: `createCalendarEvent`, `updateCalendarEvent`, `deleteCalendarEvent`,
`createReminder`, `completeReminder`, `createAlarm`, `updateAlarm`,
`cancelAlarm`, `scheduleNotification`, `storeMemory`, `updateMemory`,
`createTask`, `completeTask`, `createFollowUp`, `getUpcomingSchedule`.

---

## Real services, and the mocks beside them

There are two complete implementations of every platform protocol, and which
one a launch gets is decided in one line of `AppEnvironment`.

**The app gets the real ones.** `PlatformServices.live()` returns EventKit for
the calendar and reminders, UserNotifications for reminders, and AlarmKit for
alarms on iOS 26 and later. A shipped build changes the user's actual phone.
See [Docs/PLATFORM-APPLE.md](Docs/PLATFORM-APPLE.md).

**Tests, previews, CI and any seeded launch get the mocks.**
`MockCalendarService` and friends implement the same protocols and record what
they were asked to do:

```
[simulated:MockCalendar] Calendar event created: Haircut — Sun 26 Nov 22:00
[simulated:MockNotifications] Notification scheduled: Haircut — Fri 24 Nov 08:00 [gentle]
```

Every service reports a `PlatformFidelity`. The mocks report `.simulated` and
the Apple services report `.live`, and that value travels all the way up into
`ToolResult.outcome` as `.simulated(platform:)` or `.executed`. Nothing in this
project claims an iPhone action happened when it did not — which is why the
action cards in the UI changed the day the real services landed, without the UI
being touched.

---

## Running the development harness

Requires a Swift toolchain (Swift on Windows, or Linux/macOS).

```bash
swift build
swift run assistant-dev --demo        # scripted transcript, then exit
swift run assistant-dev               # interactive
swift run assistant-dev --providers   # list providers and their availability
swift run assistant-dev --store ./devdata   # persist to JSON files
```

The harness is a scaffold for exercising the core, not a preview of the product.
It uses a **scripted development provider** that recognises a handful of
phrasings deterministically — it is not an AI, it is labelled as such
everywhere, and it must never be registered in a shipping build.

Typical output:

```
you> I have a haircut next Sunday at 10 PM

Assistant response:
  I've added haircut for Sunday 26 November at 22:00.

Planned actions:
  - Calendar event "haircut" at Sun 26 Nov 22:00
  - Notification "haircut" at Thu 23 Nov 08:00 [support plan]
  - Notification "haircut" at Sun 26 Nov 08:00 [support plan]
  - Notification "haircut" at Sun 26 Nov 21:30 [support plan]
  - Notification "haircut" at Sun 26 Nov 21:50 [support plan]

Platform execution (simulated — nothing reached a device):
  - [simulated:MockCalendar] Calendar event created: haircut — Sun 26 Nov 22:00
  - [simulated:MockNotifications] Notification scheduled: ...
```

## The app

Five screens, built on the core:

- **Assistant** — a conversation that produces structured results. Replies sit
  in the page; what the assistant *did* appears as a card beneath, with the
  reminder plan drawn inside it.
- **Today** — what to care about today. An assistant-written summary, an
  Up Next card with the lead-in that actually helps ("start getting ready in
  1h 25m"), and a timeline where preparation and leave reminders sit alongside
  events as equals.
- **Tasks** — To Do / In Progress / Done, with filters, swipe actions, detail
  and an editor. The finer domain states (snoozed, missed, needs follow-up) stay
  visible on the row.
- **Memory** — everything the assistant knows, grouped and editable, with the
  provenance of each entry shown.
- **Settings** — assistant, model selector, ADHD assistance, notifications,
  appearance, privacy.

See [`Docs/UI-ARCHITECTURE.md`](Docs/UI-ARCHITECTURE.md) for how the layers fit
together, and [`iOS/README.md`](iOS/README.md) for opening it in Xcode.

## Seeing it run, from Windows

`.github/workflows/ios-simulator-preview.yml` uses a GitHub-hosted macOS runner
as the Mac this project does not have. On every push touching `iOS/**`,
`Sources/**`, `Package.swift` or `project.yml` — or on demand from the Actions
tab — it generates the Xcode project with XcodeGen, builds the real
`PersonalAssistant` app for an iPhone Simulator, boots the simulator, installs
and launches the app, and uploads:

| Artifact | What it is |
| --- | --- |
| `ios-simulator-screenshot` | The app actually running, in light and dark |
| `PersonalAssistant-iOS-Simulator` | The `.app`, zipped — usable with Appetize |
| `xcodebuild-log` | The full build log, uploaded only when the build fails |

No Apple Developer account, certificate or secret is involved: it is a Simulator
build with code signing disabled, running against the same mock services and
seeded data as everything else.

This gives a build-and-look loop, not interactive development. It cannot tell
you how a gesture feels.

## Running the tests

```bash
swift test
```

Coverage focuses on the behaviour that matters architecturally: the task status
machine (dismissal ≠ completion), reminder plan generation, tool decoding and
rejection, authorization, the provider swap guarantee, and repository round
trips.

---

## Open items

**[`Docs/OPEN-ITEMS.md`](Docs/OPEN-ITEMS.md) is the single register** of
everything incomplete, unverified or deliberately limited — including the
design trade-offs that no amount of device testing will discharge, which are
the ones easiest to mistake later for oversights.

The two markers below are indexed there, and both are grep-able:

`TODO-XCODE` marks something that **genuinely cannot be implemented or tested
without Xcode and an Apple SDK**. It is not a general-purpose "unfinished"
marker. Where you see it, the feature does not work, and the code says so rather
than faking it.

`TODO-DEVICE` marks something that **compiles and is reasoned about but has
never executed**, because no CI runner has a calendar database, a notification
centre, an alarm daemon or Apple Intelligence.

Find them all:

```bash
grep -rn "TODO-XCODE" .
```

Current list:

| Where | What |
| --- | --- |
| `iOS/UI/Assistant/AssistantComposerView.swift` | Microphone capture and speech recognition |
| `project.yml` | Never run through XcodeGen |
| Every `#Preview` | Marked `TODO-XCODE: Verify SwiftUI preview` |
| `Sources/MockPlatform/MockPermissionService.swift` | iOS permission prompts cannot be modelled here |
| `iOS/Platform/KeychainCredentialStore.swift` | Verify against a real Keychain |
| `Sources/AssistantPlatformApple/AlarmKitAlarmService.swift` | Switch off the deprecated alert initialiser once the minimum Xcode allows |

The calendar, reminder, notification and alarm entries are gone from this list
because those integrations now exist. What is left of them is a shorter list of
`TODO-DEVICE` notes — behaviour that compiles and is reasoned about but has
never executed, because no CI runner has a calendar database, a notification
centre or an alarm daemon. See
[Docs/PLATFORM-APPLE.md](Docs/PLATFORM-APPLE.md#what-still-needs-a-real-device).
| `iOS/Platform/AlarmKitAlarmService.swift` | AlarmKit alarms |
| `iOS/Integrations/README.md` | App Intents, widgets, Live Activities, background execution |

---

## Known limitations

- **The on-device model has never actually answered.** The Apple provider
  compiles against the iOS 26 SDK and links correctly, but Apple Intelligence
  inference needs eligible hardware, so the generation path is `TODO-DEVICE`.
  See `Docs/APPLE-ON-DEVICE.md`.
- **Background execution has never been observed on a real device.** Reminders
  are handed to `UNUserNotificationCenter` and AlarmKit, and the app reconciles
  its state at launch, on foreground and in a `BGAppRefreshTask` — but whether
  iOS actually grants that refresh, and whether a notification scheduled a week
  out fires when it should, cannot be established in CI or the simulator. See
  the device-only list in `Docs/BACKGROUND.md`.
- **A missed reminder is noticed on the next pass, not at the moment it is
  missed.** A notification that was delivered and ignored produces no callback —
  iOS has nothing to report — so the app learns about it when it next gets
  execution time. That is inherent to the platform, not a gap in the
  implementation. See `Docs/BACKGROUND.md`.
- **Two rounds, not a full loop.** A turn asks the provider, executes what it
  proposed, shows it the results and asks for a closing reply — but only for
  providers that declare `supportsToolResultContinuation`, and only twice.
  A model that needs three steps to answer cannot have them.
- **Only a rolling week of reminders is ever handed to iOS.** Stages further out
  stay in the plan and are scheduled by a later pass. If the app is never opened
  and never gets a background refresh for longer than that, a reminder beyond
  the horizon will not have been scheduled when its moment arrives.
- **Memory retrieval is lexical, not semantic.** Relevance, salience,
  confidence, category and recency are combined and bounded properly, but the
  relevance signal itself is term overlap — it cannot see that "my commute is
  half an hour" restates "it takes 30 minutes to drive to work" except through a
  narrow duration rule. `MemorySemanticMatcher` is the seam for on-device
  embeddings; see `Docs/MEMORY.md`.
- **The JSON snapshot repositories rewrite the whole file on every save.** Fine
  for the dev harness and fixtures, which is all they are used for now; the app
  runs on SwiftData.
- **Reminder plans are never deleted.** Deleting a task leaves its plan row
  behind — unreachable, because plans are only found through a task or event id,
  but still taking up space. See `Docs/PERSISTENCE.md`.
- **The scripted development provider understands very few phrasings.** By
  design — it exists to make the pipeline runnable, not to be smart.
