# The iOS application

This is the real app. Not a prototype, not a preview, not a mock-up in another
framework — this is the SwiftUI code the iPhone app ships with.

It is written on Windows, where it cannot be compiled or run. That constraint
changes *when* it is verified, not *what* it is: opening this repository on a
Mac gives you this UI, not a design to reimplement.

## Layout

```
iOS/
├── App/            Entry point, composition root, shared app state
│   ├── PersonalAssistantApp.swift   @main, appearance preference
│   ├── AppEnvironment.swift         The only place implementations are chosen
│   ├── AppModel.swift               Shared observable state; talks to the core
│   └── RootView.swift               TabView, settings + reminder presentation
├── Data/           Centralised demo content
│   ├── DemoData.swift               Seed values, built relative to "now"
│   └── DemoDataSeeder.swift         Writes them through the real interfaces
├── RemoteAI/       Remote-provider configuration and credential bridging
├── Presentation/   Domain → display mapping (no SwiftUI state)
│   ├── AppFormatters.swift
│   ├── ConversationPresentation.swift
│   ├── ReminderPlanPresentation.swift
│   ├── TodayPresentation.swift
│   ├── TaskPresentation.swift
│   ├── MemoryPresentation.swift
│   └── SimulatedReminder.swift
├── ViewModels/     Per-screen state
├── UI/             Views, grouped by screen, plus Components/ and Shared/
├── Platform/       KeychainCredentialStore. The calendar, reminder,
│                  notification and alarm adapters live in the package as
│                  AssistantPlatformApple, where they can be tested.
├── Integrations/   App Intents, widgets, background execution — notes only
└── Resources/      Assets.xcassets, Info.plist
```

## How the UI reaches the core

```
View  →  ViewModel (screen state)  →  AppModel  →  AssistantEngine / repositories
                                                 →  PlatformServices (real, or
                                                    mocked on a seeded launch)
```

`AppModel` is the only type that talks to the core. Views never construct a
service, and no business rule lives in a `body`: completing a task, dismissing a
reminder and planning reminders all happen in `ExecutiveSupport` and
`AssistantCore`, exactly as they will in the shipping app.

`AppEnvironment.makeDemo()` is the single line to change when the Apple layer
arrives. Nothing in `UI/` knows which services it is running against.

## Opening it on a Mac

Either generate the project:

```bash
brew install xcodegen
xcodegen generate           # reads project.yml at the repository root
open PersonalAssistant.xcodeproj
```

…or create an iOS App target by hand and use `project.yml` as the checklist:
add `iOS/` (minus this README) as sources, point `INFOPLIST_FILE` at
`iOS/Resources/Info.plist`, add the package at the repository root as a local
dependency, and link `AssistantCore`, `AssistantDomain`, `AssistantAI`,
`AssistantTools`, `AssistantPlatform`, `AssistantPersistence`,
`ExecutiveSupport`, `MockPlatform`, `AssistantPlatformApple`,
`AIProviderApple`, `AIProviderLocal`, `AIProviderRemote` and `DevSupport`. Point `configFiles` at `Config/App.xcconfig`
so development secrets are picked up when present.

Expect to fix compile errors on the first build. None of this has been through a
compiler — see the Status section of the root README.

## What is honest about the current build

Every one of these is stated in the UI itself, not just here:

- The Assistant screen carries a notice when the selected model is unavailable,
  saying replies come from a scripted development stand-in. It disappears once a
  cloud model is configured.
- Action cards say "Simulated · nothing was scheduled on this device" only
  when a mock service really produced them, which now means a seeded demo
  launch. A shipped build's cards say the action was executed, because it was.
- Event detail says which calendar holds the event.
- The in-app reminder sheet is still labelled a simulation. It is a development
  aid that predates real delivery, and it remains honest about being one.
- Settings → Privacy describes the app as it is, including what is missing.

## Replacing the mocks

Each of these is an implementation task with no UI consequences:

| To make real | Implement | Register in |
| --- | --- | --- |
| Calendar | Done — see [`Docs/PLATFORM-APPLE.md`](../Docs/PLATFORM-APPLE.md) | `PlatformServices.live()` |
| Reminders | Done — same | `PlatformServices.live()` |
| Notifications | Done, with Done / I'm on it / Later actions | `PlatformServices.live()` |
| Alarms | Done on iOS 26; fails honestly below it | `PlatformServices.live()` |
| On-device model | `respond(to:)` in `AppleFoundationModelsProvider` | already registered |
| Local model | A `LocalModelRuntime` | `LocalModelProvider` |
| Cloud model | Done — see [`Docs/REMOTE-AI.md`](../Docs/REMOTE-AI.md) | Settings → AI Model |
| Voice input | `AVAudioEngine` + `SFSpeechRecognizer` | `VoiceInputPlaceholderView` |
| Storage | Done — see [`Docs/PERSISTENCE.md`](../Docs/PERSISTENCE.md) | `AppEnvironment.makePersistent()` |
| Keychain | Verify `KeychainCredentialStore` on a device | already wired |
