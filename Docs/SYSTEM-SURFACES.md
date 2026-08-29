# System surfaces

The keyboard, the widgets, the Lock Screen and the Dynamic Island.

> Main app owns intelligence and state → extensions receive minimal projections
> or route commands → widgets and Live Activities display support → the keyboard
> provides quick access → no duplicate business logic and no always-running
> assistant.

## The shape of it

```
Main application
  repositories · TaskStatusMachine · SupportPlanner · AssistantEngine
        │
        ├─ SystemSurfaceSnapshotBuilder ─→ App Group container ─→ widgets, keyboard
        ├─ SystemSurfaceCommandService  ←─ App Intents         ←─ widget buttons
        └─ LiveActivityCoordinator      ─→ ActivityKit
```

Every arrow points away from the domain, except the one that comes back through
an App Intent — and that one lands in `FollowUpService`, the same door the app's
own buttons use.

## Modules

| Where | What | Why there |
| --- | --- | --- |
| `Sources/SystemSurfaces` | Snapshots, the App Group store, the keyboard exchange, the layout, the timeline planner | Foundation only. An extension that links it gets none of the domain, no repositories, no provider, no runtime. |
| `Sources/ExecutiveSupport` | `LiveActivityPresentationPolicy` | Which task deserves the Lock Screen is a support decision, tested with the rest of them. |
| `Sources/AssistantCore` | Snapshot builder, command service, `SystemSurfaceService`, keyboard service | The join. Reads the domain, writes the projections. |
| `iOS/SystemSurfaces/Shared` | ActivityKit attributes, App Intents, the App Group store location, the extension composition | Compiled into the app *and* the widget extension. |
| `iOS/SystemSurfaces/Widgets` | Three widgets, the Live Activity, the timeline provider | The widget extension. |
| `iOS/SystemSurfaces/Keyboard` | `KeyboardViewController` and its bridge | The keyboard extension. |

## Snapshots

The main app computes; extensions read. `DailyPriorityRanker` runs once, in the
app, and its answer is copied into a `TodaySnapshot`. A widget process never
ranks, never resolves a `ReminderPlan` and never opens the database to draw
something.

| Snapshot | Feeds | Carries |
| --- | --- | --- |
| `TodaySnapshot` | Today widget | Up to eight rows: title, time, kind, emphasis, a one-line detail |
| `TaskWidgetSnapshot` | Next Task widget | The one actionable task, the outstanding count, whether it is blocked |
| `ReminderWidgetSnapshot` | Support widget | The next intervention, the task it belongs to, how many reminders iOS refused |
| `KeyboardConfigurationSnapshot` | Keyboard | Whether assistant actions are on, and which |
| `KeyboardExchange` | Both ways | One pending request, one result |
| `LiveActivityRegistry` | The app alone | Which activities the app believes are running |

Each is versioned, has a `generatedAt`, and may have a `validUntil`. A reader
from an older build refuses a newer snapshot rather than guessing at it — during
an app update the two binaries are briefly different versions, and a widget that
half-understands a future format shows something wrong instead of nothing.

Each has its own file, written atomically. One corrupt projection cannot take
the others down, and a widget reading mid-write sees the whole previous file.

### What is not in them

No API key, no token, no endpoint, no provider identifier, no model name, no
memory, no conversation, no prompt, no reminder history, no task notes. This is
asserted rather than intended: `SystemSurfaceTests` encodes every snapshot the
builder produces and greps the JSON.

Credentials stay where Part 6 put them — the Keychain, behind `CredentialStore`.
The App Group has no key-value API at all, so there is nowhere to put one.

## Widgets

Three, not fifteen.

| Widget | Families | Shows |
| --- | --- | --- |
| **Today** | small, medium, large, `accessoryRectangular` | What is next and what is coming |
| **Next Task** | small, medium, `accessoryRectangular`, `accessoryCircular`, `accessoryInline` | The highest-ranked thing that can actually be started |
| **Support** | small, medium, `accessoryRectangular`, `accessoryInline` | Leave times, preparation, waiting follow-ups |

**No widget calls a model.** Not for a timeline, not for a snapshot, not ever.
The widget extension does not link a provider, so this is structural.

### Timelines

`WidgetTimelinePlanner` prepares the future rather than asking to be woken.
Given

```
2:35  start getting ready
3:20  leave
4:00  work
```

the timeline is four entries — now, and each transition. At 3:19 the widget
says "leave at 3:20"; at 3:21 it says "work at 4:00"; between them nothing of
this app ran. WidgetKit has a daily refresh budget, and an app that asks for a
reload every minute gets refused and then shows the same stale entry for hours.

`SystemSurfaceService` compares each new projection against the stored one and
calls `reloadTimelines(ofKind:)` only for the kinds whose *content* changed —
never `reloadAllTimelines()`.

### Privacy

Widgets are visible on a locked screen and in Always On. The accessory families
check `isLuminanceReduced` and withhold the title, keeping the time. The
placeholder text is deliberately bland — "Upcoming", not "Private", which
advertises that there is something to hide.

`TaskItem` has no sensitivity flag yet. When it gets one, exactly one function
changes: `SystemSurfaceSnapshotBuilder.isSensitive`.

### Interaction

Done, Later and "I'm doing it" are App Intents:

```
Button → CompleteTaskFromSurfaceIntent
       → SystemSurfaceCommandService
       → FollowUpService
       → TaskStatusMachine
       → pending stages cancelled, OS requests withdrawn
       → repositories
       → snapshots rebuilt, WidgetKit reloaded
```

Nothing writes a shared JSON file and calls that task completion.

**Snooze is not completion. "I'm doing it" is not completion.** Three separate
buttons because they mean three different things, and offering only Done is what
turns a support system into a nagging one.

## Live Activities

### When one appears

`LiveActivityPresentationPolicy`, deterministic and never a model. The bar is
high on purpose: a Live Activity occupies the Lock Screen and the Dynamic Island
continuously, and one that appears for everything trains the user to dismiss it.

| Qualifies | Does not |
| --- | --- |
| A preparation timeline that is running now | A normal task due in an hour |
| Prepared, and the leave time is close | An important task six hours out |
| A "Help me start" session the user accepted | Anything completed, cancelled, expired or skipped |
| An important task with a fixed time inside two hours | A task with no time at all |
| A routine occurrence inside its window | Everything else |

At most two at once, ordered by urgency, then by how soon, then by identifier —
the last so two otherwise-equal candidates do not swap places between passes and
make the Lock Screen flicker.

### What it says

`SupportActivityContent`: a title, a phase, a target date, a next step and a
step count. Six small fields, all `Codable`, none of them ActivityKit. That is
what makes the content of a Live Activity a unit test rather than something you
learn by watching a phone.

The countdown is a date handed to the system, so it ticks with no process of
ours running. There is no timer anywhere near ActivityKit.

### Lifecycle

```
domain state → LiveActivityPresentationPolicy → LiveActivityCoordinator → ActivityKit
```

One direction. ActivityKit never decides a task's state and is never asked what
one is; the registry in the App Group is what the app reads after a relaunch to
know which activities it started. A task that no longer qualifies — completed,
cancelled, or simply past — has its activity ended, which is the whole of the
relaunch story and the reason there is no second recovery path.

### Dynamic Island

Compact leading, compact trailing, minimal and expanded. An iPhone without one
gets the Lock Screen presentation, which is the primary presentation rather than
a fallback — availability does not depend on the hardware.

## The keyboard

A real keyboard: characters, shift with one-shot and lock, three planes,
backspace with repeat, space, return, and the globe key.

**All of it works with Full Access off.** The `RequestsOpenAccess` flag is true
because the assistant actions need the App Group container, and iOS gates shared
containers behind Full Access for custom keyboards. With it off, typing is
unaffected and the assistant row says it is unavailable rather than pretending.

### The assistant bridge

```
keyboard → KeyboardAssistantRequest → App Group → KeyboardAssistantService
                                                → engine or command service
                                                → KeyboardAssistantResult → keyboard
```

Four fields out, four back. The keyboard does not know which provider will
answer, whether one is configured, or whether the app is running.

- **Improve, Shorten, Fix Grammar** go through `AssistantEngine.transformText`,
  which offers the model **no tools** and persists nothing. "Shorten this"
  cannot create a calendar event, because there is no calendar tool in the
  request.
- **Ask Assistant** goes through `AssistantCommandService.ask` — the full
  pipeline, including validation, authorization and execution. If the question
  does lead to a tool, it enters the same door every other tool call enters.

The keyboard never writes a task, never stores a memory and never executes a
tool.

### When the app is not running

iOS does not launch a containing app because an extension asked it to. The
keyboard waits three seconds, then says so, and offers the deterministic tidy-up
— whitespace and capitalisation, labelled as what it is. The user's text is
never replaced without them tapping Accept, and never deleted because a request
failed.

### What the keyboard never does

Persist what is typed in other apps. Build memories from it. Read the document
beyond what `textDocumentProxy` exposes for the operation. Attempt to work in a
secure field. A cancelled request clears itself out of the shared container so
the text does not sit in a file after the user changed their mind.

## App Group and entitlements

One identifier, `group.com.dimitrisefthymiou.MetisAI`, derived from the bundle
identifier and declared in `SystemSurfaceIdentifiers` — with entitlement files
for the app and both extensions repeating it, because a plist cannot import
Swift. A test asserts the Swift half.

The SwiftData store moved into the group container, because iOS runs an
interactive widget's App Intent in the widget extension's process and an
extension cannot reach the app's own container. An existing store is copied
across once, on first launch after the update, including the `-wal` and `-shm`
files. A build with no App Group entitlement — an unsigned CI build — falls back
to the app container and behaves exactly as before.

## Extension dependency graphs

The architectural claim of this milestone, expressed as `project.yml`:

| Target | Links | Notably does not link |
| --- | --- | --- |
| Keyboard | `SystemSurfaces`, UIKit | Everything else |
| Widgets | `SystemSurfaces`, `AssistantDomain`, `AssistantPersistence(+SwiftData)`, `ExecutiveSupport`, `AssistantCore`, `AssistantPlatformApple` | `AIProviderRemote`, `AIProviderApple`, `AIProviderLocal`, `AIProviderLocalLlama` |

A widget cannot invoke a model because no provider is in its graph, and the
keyboard cannot reach a repository because nothing but `SystemSurfaces` is.

The widget extension does link `AssistantPlatformApple`, and therefore EventKit
and AlarmKit alongside UserNotifications. That is deliberate: cancelling the
notification behind a completed task needs the same notification centre the app
scheduled it with, and the Apple adapters ship as one product.

## What is deliberately not built

No Apple Watch app, no CarPlay, no Control Center controls, no StandBy product,
no macOS widgets beyond what iOS gives for free, no push infrastructure for
ActivityKit, and no conversation UI in either a widget or the keyboard. A widget
deep-links to the assistant; the app remains the rich environment.

No always-running process. No daemon, no polling, no socket. The keyboard asks
and waits three seconds; the widgets read a file; the Live Activity is presented
by the system.

## Device-only validation remaining

CI compiles every target, runs the projection, policy and command tests against
mocks, and launches the app in a simulator. It cannot exercise anything below,
and the simulator does not stand in for it.

1. Installing and discovering the keyboard in Settings, and its appearance in
   the globe-key rotation.
2. The next-keyboard control actually switching keyboards.
3. Full Access on and off, including the moment it is granted.
4. Keyboard extension memory pressure, and whether iOS kills it while typing.
5. Typing across third-party apps, and apps that disable third-party keyboards.
6. Secure input fields refusing the keyboard.
7. The App Group container resolving under real signing — an unsigned build
   cannot have the entitlement, so the fallback path is the one CI exercises.
8. The SwiftData migration from the app container to the group container, on a
   device with a real store.
9. Widget gallery discovery and Home Screen rendering.
10. Lock Screen widget rendering and the accessory families' real dimensions.
11. Always On behaviour and `isLuminanceReduced` in practice.
12. Interactive widget actions performing in the extension's process.
13. Live Activity start, update and end on a real Lock Screen.
14. Dynamic Island compact, minimal and expanded rendering on supported
    hardware.
15. ActivityKit behaviour after the app is suspended and after it is terminated.
16. Part 11 reconciliation ending a stale Live Activity after a real absence.
17. WidgetKit's real refresh budget over a day of ordinary use.

These are recorded in [`Docs/OPEN-ITEMS.md`](OPEN-ITEMS.md).
