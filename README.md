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
- the reminder-planning layer
- protocol-based platform services plus mock implementations
- repository interfaces and a JSON-backed development implementation
- a command-line harness and unit tests
- **the iPhone app's SwiftUI interface** — Assistant, Today, Tasks, Memory and
  Settings, with real navigation, sheets, forms and components

The UI is the production interface, not a prototype: it is SwiftUI, it sits on
the existing architecture, and it calls the same protocols the Apple
implementations will. What is mocked is the layer *beneath* it — the platform
services and the model — never the UI itself.

What does not exist yet, deliberately: every Apple framework integration. Those
need Xcode. See [TODO-XCODE](#todo-xcode) below.

> **Not verified by a compiler.** All of this was written on a machine with no
> Swift toolchain and no Apple SDK, so nothing has been built or run — the core
> or the UI. Expect to fix compile errors on the first build. The architecture
> and the interface are the deliverable; treat the first build as part of
> adopting them.

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
interface the core already defines*. It lives in [`iOS/`](iOS/README.md), is not
part of the Swift package, and is not compiled during Windows development.

This is still a native iOS app. There is no React Native, Flutter, Electron,
Capacitor or webview anywhere in it, and the abstractions exist to defer Apple
work, not to avoid it.

### What works on Windows

| Works today | Needs Xcode |
| --- | --- |
| Domain models, task/reminder state | SwiftUI screens |
| Assistant turn pipeline | Apple Foundation Models inference |
| Tool definitions, validation, authorization | EventKit calendar & reminders |
| Reminder planning and scheduling | AlarmKit alarms |
| Task status machine | UserNotifications delivery |
| Repositories (JSON-backed) | App Intents / Siri |
| Mock platform services | Widgets, Live Activities |
| AI provider abstraction and routing | iOS permissions, background execution |
| CLI harness, unit tests | Signing, provisioning, TestFlight |

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
│   ├── AIProviderApple/        Apple Foundation Models  (stub, TODO-XCODE)
│   ├── AIProviderLocal/        Downloaded local model    (runtime not chosen)
│   ├── AIProviderRemote/       Remote API, vendor-neutral
│   ├── DevSupport/             Scripted provider for development only
│   └── DevHarness/             CLI harness (assistant-dev)
├── Tests/
├── iOS/                        The SwiftUI app. Not in the package — Xcode territory.
│   ├── App/                    Entry point, composition root, shared state
│   ├── Data/                   Centralised demo content
│   ├── Presentation/           Domain → display mapping
│   ├── ViewModels/             Per-screen state
│   ├── UI/                     Views and reusable components
│   ├── Platform/               Apple adapters (TODO-XCODE skeletons)
│   └── Resources/              Assets, Info.plist
├── project.yml                 XcodeGen spec for the app target
└── Docs/
    ├── ARCHITECTURE.md
    └── UI-ARCHITECTURE.md
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

- **`AIProviderApple`** — Apple's on-device Foundation Models. Interface and
  metadata exist; `respond(to:)` throws. `TODO-XCODE`.
- **`AIProviderLocal`** — a model the user downloaded. Fully built except
  inference, which is delegated to a `LocalModelRuntime`. **No runtime is
  chosen** — not llama.cpp, MLX, Core ML or ExecuTorch. That decision is
  deliberately deferred, and making it later means writing one type.
- **`AIProviderRemote`** — models over the network. Vendor-specific request and
  response shapes live in a `RemoteAPIAdapter`; the provider itself is neutral.
  Credentials come from a `CredentialProvider`, never from source.

`ModelRouter` picks one per turn based on settings (`preferOnDevice`,
`preferMostCapable`, `explicit`). Under `explicit`, an unavailable provider is an
error rather than a silent substitution.

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

## How mock platform services work

`MockCalendarService`, `MockReminderService`, `MockNotificationService` and
`MockAlarmService` implement the real protocols and record what they were asked
to do:

```
[simulated:MockCalendar] Calendar event created: Haircut — Sun 26 Nov 22:00
[simulated:MockNotifications] Notification scheduled: Haircut — Fri 24 Nov 08:00 [gentle]
```

Every service reports a `PlatformFidelity`, and the mocks report `.simulated`.
That value travels all the way up into `ToolResult.outcome` as
`.simulated(platform:)` rather than `.executed`. Nothing in this project claims
an iPhone action happened when it did not.

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

## Running the tests

```bash
swift test
```

Coverage focuses on the behaviour that matters architecturally: the task status
machine (dismissal ≠ completion), reminder plan generation, tool decoding and
rejection, authorization, the provider swap guarantee, and repository round
trips.

---

## TODO-XCODE

`TODO-XCODE` marks something that **genuinely cannot be implemented or tested
without Xcode and an Apple SDK**. It is not a general-purpose "unfinished"
marker. Where you see it, the feature does not work, and the code says so rather
than faking it.

Find them all:

```bash
grep -rn "TODO-XCODE" .
```

Current list:

| Where | What |
| --- | --- |
| `Package.swift` | Raise the iOS deployment target for Foundation Models / AlarmKit |
| `Sources/AIProviderApple/AppleFoundationModelsProvider.swift` | Implement `respond(to:)` and real availability against `FoundationModels` |
| `Sources/AssistantPlatform/PlatformService.swift` | Real permission flow |
| `iOS/App/AppEnvironment.swift` | Swap `makeDemo()` for a live environment |
| `iOS/App/UnconfiguredCloudAdapter.swift` | A real `RemoteAPIAdapter` |
| `iOS/Data/DemoDataSeeder.swift` | Seeding should move behind a debug flag |
| `iOS/UI/Assistant/AssistantComposerView.swift` | Microphone capture and speech recognition |
| `iOS/UI/Shared/SimulatedReminderView.swift` | Real notification categories and actions |
| `iOS/Resources/Info.plist` | Verify usage descriptions |
| `project.yml` | Never run through XcodeGen |
| Every `#Preview` | Marked `TODO-XCODE: Verify SwiftUI preview` |
| `Sources/AssistantPlatform/PlatformProtocols.swift` | EventKit / AlarmKit / UserNotifications implementation notes |
| `Sources/MockPlatform/MockPermissionService.swift` | iOS permission prompts cannot be modelled here |
| `Sources/AIProviderRemote/RemoteAPIAdapter.swift` | Keychain-backed credential storage |
| `iOS/Platform/EventKitCalendarService.swift` | EventKit calendar |
| `iOS/Platform/UserNotificationsService.swift` | Notification delivery and the Done/Snooze actions |
| `iOS/Platform/AlarmKitAlarmService.swift` | AlarmKit alarms |
| `iOS/Integrations/README.md` | App Intents, widgets, Live Activities, background execution |

---

## Known limitations

- **Unverified build.** No Swift toolchain was available; see Status above.
- **Single-pass turns.** A turn asks the provider once and executes what comes
  back. Tool *results* are not fed back for a second pass, so
  `getUpcomingSchedule` currently returns a count rather than data the model can
  reason over. The seam for a multi-pass loop is in `AssistantEngine.send`.
- **Reminder scheduling is one-shot.** Plans are generated and resolved at
  creation time. Re-planning after a snooze or a follow-up is modelled by
  `TaskStatusMachine` but not yet driven by anything.
- **Memory retrieval is keyword overlap.** Good enough to prove the seam, not
  good enough to ship.
- **The JSON snapshot repositories rewrite the whole file on every save.** Fine
  for development, not for a real message history.
- **The scripted development provider understands very few phrasings.** By
  design — it exists to make the pipeline runnable, not to be smart.
