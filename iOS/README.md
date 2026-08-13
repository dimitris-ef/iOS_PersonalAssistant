# iOS layer

Everything in this directory needs Xcode and an Apple SDK. **None of it is part
of the Swift package**, and none of it is compiled or tested during the
Windows-first development stage — `Package.swift` never references this
directory, so `swift build` on Windows or Linux ignores it entirely.

The files here are skeletons that show where each Apple integration plugs into
the core. Every one of them is marked `TODO-XCODE`. They do not work, and they
do not pretend to.

## What goes here

| Path | Purpose | Apple framework |
| --- | --- | --- |
| `App/` | The `@main` app entry point and dependency wiring | SwiftUI |
| `UI/` | Screens: conversation, plan review, tasks, settings | SwiftUI |
| `Platform/` | Implementations of the `AssistantPlatform` protocols | EventKit, UserNotifications, AlarmKit |
| `Integrations/` | App Intents, Siri, widgets, Live Activities | AppIntents, WidgetKit, ActivityKit |

## Bringing this up on a Mac

1. Create an iOS App target in Xcode (`PersonalAssistant`).
2. Add the package at the repository root as a local Swift Package dependency,
   and link `AssistantCore`, `MockPlatform` (debug only), `AIProviderApple`,
   `AIProviderLocal` and `AIProviderRemote`.
3. Add the files from this directory to the app target.
4. Raise the deployment target as needed — Apple Foundation Models and AlarmKit
   both require a newer minimum than the package currently declares.
5. Add the usage descriptions and entitlements: calendar, reminders,
   notifications, and (for alarms) whatever AlarmKit requires.
6. Replace `PlatformServices.mock(...)` in `AssistantComposition` with the real
   services one at a time. Each one can be swapped independently, because the
   core only ever sees the protocol.

## What the core already guarantees

The work below is *implementation*, not redesign. None of it requires changing
the assistant's logic:

- **Apple Foundation Models** — implement `respond(to:)` in
  `AIProviderApple`. Nothing else changes; the provider is already registered
  and already reports itself unavailable.
- **A downloaded local model** — implement `LocalModelRuntime` and inject it
  into `LocalModelProvider`. The runtime has deliberately not been chosen.
- **A remote API** — implement one `RemoteAPIAdapter`. Vendor-specific request
  and response shapes live entirely inside the adapter.
- **EventKit / AlarmKit / UserNotifications** — implement `CalendarService`,
  `ReminderService`, `AlarmService` and `NotificationService`, and set
  `fidelity` to `.live` once they genuinely reach the OS.
- **App Intents / Siri** — build `ToolRequest` values directly and hand them to
  the same executor the model's requests go through. An intent is just another
  origin; the authorization and execution path is shared.
- **Widgets / Live Activities** — read from the repositories. They never need
  an AI provider.
