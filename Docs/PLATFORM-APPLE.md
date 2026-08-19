# Real iPhone actions

EventKit, UserNotifications and AlarmKit, behind the platform protocols that
were already there.

## What changed, and what did not

Before this milestone every action the assistant took ended in a dictionary.
`MockCalendarService` recorded the event, reported `.simulated`, and the card
under the reply said so. The app was honest and it was useless.

Now `PlatformServices.live()` returns EventKit, UserNotifications and — where
the device has it — AlarmKit. Nothing above the protocols moved. The engine,
the tool catalogue, the authorizer, the validator, the follow-up ladder, the
repositories and every provider are byte for byte what they were; the only
difference is which five objects `AppEnvironment` puts in a struct.

```
AssistantEngine → ToolExecutor → PlatformServices
                                   ├── CalendarService      → EventKit
                                   ├── ReminderService      → EventKit
                                   ├── NotificationService  → UserNotifications
                                   ├── AlarmService         → AlarmKit ‖ unavailable
                                   └── PermissionService    → all of the above
```

The AI still cannot reach any of this. It proposes an `AIToolCall`; the call is
decoded, validated, authorized, confirmed if destructive, and only then does a
platform service see it. Adding real frameworks changed what happens at the end
of that pipeline and nothing about the pipeline.

## Where the code lives, and why not in `iOS/`

`Sources/AssistantPlatformApple/`, a package target — not `iOS/Platform/`,
which is where the skeletons were.

`iOS/` is not part of the Swift package, so it has no test target. Nothing in
it can be run by `swift test`, which means nothing in it is checked by anything
except a human reading it. That was tolerable for a stub that threw. It is not
tolerable for the code that decides whether swiping a notification away means
the task got done.

So the target is in the package, framework imports are behind `#if canImport`,
and the decisions worth checking are pure functions with no import at all:

| File | Decides | Imports |
| --- | --- | --- |
| `AppleNotificationRouting` | What each button and gesture means | none |
| `AppleNotificationIdentity` | The string iOS knows a reminder by | none |
| `AppleAuthorizationMapping` | What partial access is allowed to claim | none |
| `AppleEscalationMapping` | How loud a reminder is delivered | none |
| `AppleRecurrenceMapping` | What a repeating event becomes | none |
| `AppleExternalIdentity` | Domain ids for events the app did not create | none |
| `AppleEventKitStore` | Every EventKit call | EventKit |
| `UserNotificationsService` | Scheduling and withdrawal | UserNotifications |
| `AppleNotificationCoordinator` | The delegate | UserNotifications |
| `AlarmKitAlarmService` | Alarms | AlarmKit, SwiftUI |

The Linux and Windows builds still work; they simply contain the first six
files and nothing else.

## Dismiss is not complete

The rule the whole product rests on, and now the one place it is enforced for
notifications:

```swift
case AppleNotificationResponse.dismissActionIdentifier:
    return .outcome(.dismissed, task: taskID, stage: payload.stageID)
```

A dismissal produces `ReminderOutcome.dismissed`, which `FollowUpCoordinator`
turns into an escalation rather than a resolution. The task stays open, the
ladder climbs, and the user hears about it again.

Every route goes through `FollowUpService` — the same door the UI's own Done
and Snooze buttons use. There is no second path from a notification into a
task's status, which is what stops the rule being routed around by someone
adding a button later.

| Gesture | Outcome | Task |
| --- | --- | --- |
| **Done** | `.completed` | resolved |
| **I'm on it** | `.acknowledged` | still open, support continues |
| **Later** | `.snoozed(until: nil)` | still open, rescheduled |
| **Swipe away** | `.dismissed` | still open, **escalates** |
| **Tap the banner** | none | unchanged — the app just opens it |

The last two rows are the ones that matter. Tapping a notification is not a
claim about the task, so nothing is recorded; the task is shown and the user
says what is true. And a swipe is the gesture every other app treats as
"handled", which is exactly why this one does not.

"Later" deliberately carries no duration. The button says *Later*, and how long
later is depends on how many times this task has already been put off and how
close its deadline is — facts the reminder plan holds and a notification action
does not.

## The delegate holds nothing

`AppleNotificationCoordinator` converts Apple's response to a value type, asks
`AppleNotificationRouter` what it means, and hands the answer on. No task
lookup, no status machine, no repository, no SwiftData.

A notification callback is a hostile place for logic. It arrives on the main
thread at an arbitrary moment, it can arrive during launch before the app has
assembled itself, and it can arrive twice. Two consequences shaped the design:

- **The delegate is installed in `PersonalAssistantApp.init`**, not in a
  `.task`. Answering a reminder from the lock screen launches the app and
  delivers the response almost immediately; a delegate registered when the
  first view appears is registered too late and simply never hears it.
- **Routes that arrive before the repositories are open are queued**, and
  replayed when `setHandler` runs. Without that, a cold launch from a
  notification action would lose the answer every time.

The completion-handler form of each delegate method is implemented rather than
the `async` one. Both exist, but every method on `UNUserNotificationCenterDelegate`
is optional: a signature the runtime does not recognise produces no compile
error and no callback, and the failure would be a delegate that is never called,
discovered on a device.

## Identifiers

**Notifications** are keyed by `assistant.reminder.<uuid>`, derived from the
domain id. `FollowUpService` already uses the stage id as the request id, so a
reminder's OS-level identity follows from its place in the plan and no table has
to remember it. Deriving rather than storing is what makes cancellation survive
a relaunch with an empty cache.

Nothing is ever removed by `removeAllPendingNotificationRequests`. Every removal
names identifiers, and `AppleNotificationIdentity.isOurs` filters the list, so
this feature cannot delete a notification it did not schedule.

**Calendar events and reminders** have the harder problem: the domain keys them
by a UUID this app owns, EventKit keys them by a string EventKit owns, and there
is no repository of calendar events to hold a mapping — the user's calendar *is*
the store. Inventing a UUID per read would make ids unstable, so the domain id is
*derived* from the EventKit one by a namespaced hash. Same event, same id, every
launch, no table.

The hash is FNV-1a rather than a proper UUIDv5, because SHA-1 on Apple platforms
means CryptoKit, CryptoKit does not exist on Linux, and the derivation would then
be behind a guard where the tests cannot reach it. Nothing is authenticated or
authorised by this value; it needs to be stable and well distributed, and it is
stamped with the RFC 4122 version and variant bits so it is a well-formed UUID.

## Permissions, at the moment they are needed

Nothing is requested at launch. `ToolExecutor` calls `permissions.ensure(_:)`
immediately before an action that needs a capability, so the calendar prompt
arrives just after the user said "put that in my calendar" and someone who never
mentions a calendar is never asked about one. `ensure` prompts only when the
answer is unknown — a declined capability is not re-requested on every turn,
because iOS shows its alert once and further requests display nothing.

Notification permission is asked for inside `UserNotificationsService.schedule`
rather than through the same gate, because reminders are scheduled by the
follow-up ladder as well as by tools and that path does not run through
`ToolExecutor`.

### Full calendar access, and why write-only was not enough

`CalendarService` declares `events(in:)`, and `AssistantEngine` calls it on
every turn. Knowing what is already on the day before agreeing to anything is
the assistant's central behaviour — the difference between a scheduling
assistant and a notepad. Write-only access cannot answer that question, so the
app asks for full access.

The user can still answer **Add Events Only**, and iOS will. That is a real
answer rather than a refusal, so it became a new `PermissionStatus.limited`:

| iOS says | App records | The app may |
| --- | --- | --- |
| Full Access | `.granted` | everything |
| Add Events Only | `.limited` | nothing, and says which part is missing |
| Don't Allow | `.denied` | nothing; Settings can undo it |
| Restricted | `.restricted` | nothing, and Settings cannot undo it |

`restricted` is kept apart from `denied` on purpose: Screen Time and MDM
profiles produce it, the person holding the phone cannot change it, and sending
them to Settings would send them looking for a switch that is not there.

The honest cost: with add-only access this app declines to create events even
though EventKit would allow it. Making that work would need permission checks
that distinguish reads from writes at every call site, and the trade was not
worth the complexity for an answer few people will choose.

Notifications get a `limited` of their own, for the same reason. A
**provisional** authorization delivers silently to Notification Centre with no
banner and no sound — reasonable as a trial mode for most apps, close to
useless for this one. An app that counted it as granted would believe it was
reminding someone who was hearing nothing.

## Escalation, honestly

| Level | iOS interruption level | Sound |
| --- | --- | --- |
| `gentle` | `passive` | no |
| `standard` | `active` | yes |
| `insistent` | `timeSensitive` | yes |
| `alarm` | `timeSensitive`, **and the receipt says so** | yes |

Two levels are deliberately never produced.

**`critical`** sounds through the ringer switch and Do Not Disturb, and Apple
gates it behind an entitlement granted case by case for things like medical
alerts. This app does not have it, and requesting the level without it does not
fail loudly — it just does not happen. Writing a line that looks like it
delivers an unmissable alert and does not is worse than not writing it.

**An alarm from the notification service.** A notification cannot become an
alarm. When a request asks for alarm-level insistence on the notification
channel it is delivered as the loudest notification available and the receipt
says *delivered as a time-sensitive notification, not an alarm* — because the
user reads that receipt.

## Alarms fail rather than pretend

AlarmKit needs iOS 26. The app supports iOS 17. On every device in between there
is no alarm framework, and the obvious fallback — send a notification instead —
is the one thing this layer must never do.

Someone who asks the assistant to make sure they wake up has said something
specific: they want the thing that sounds through the ringer switch and has to be
dismissed. A notification is silenced by the same switch that silences
everything else. Substituting one for the other produces exactly the failure this
app exists to eliminate — *I thought it was set*.

So `UnavailableAlarmService` throws with a reason, and the user finds out when
they ask, while they can still set an alarm in the Clock app. `scheduledAlarms()`
returns an empty array rather than throwing, because "what alarms are set?" has
a truthful answer on a device that cannot set them.

Two guards, neither redundant:

| Guard | Answers | False when |
| --- | --- | --- |
| `#if canImport(AlarmKit)` | Is it in the **SDK**? | Linux, Windows, a Mac SDK |
| `if #available(iOS 26, *)` | Is it on **this device**? | any iPhone on iOS 17–25 |

AlarmKit is weakly linked for the same reason FoundationModels is, and CI
asserts it: strongly linking a framework the OS lacks makes dyld refuse to start
the app, which is a launch crash on most supported devices and something no
`if #available` in Swift prevents.

`maximumSnoozes` is not expressed, because AlarmKit has no equivalent — the
system lets someone snooze indefinitely. The limit is enforced where it can be:
the follow-up ladder counts snoozes and escalates, which is better than a cap
the OS silently ignores.

## Snooze schedules exactly one replacement

Three separate mechanisms, and all three have to agree:

1. `FollowUpCoordinator` produces a decision whose `cancel` list is applied
   before its `schedule` list, so the replacement never overlaps what it
   replaces.
2. The new request reuses the stage id, so its OS identifier is the same
   string. `UNUserNotificationCenter.add` *replaces* a request with an
   existing identifier rather than adding a second.
3. `AlarmKitAlarmService.update` cancels before rescheduling under the same
   id, in that order, so the worst outcome of a failure halfway through is no
   alarm rather than two.

Point 2 is the belt and braces that matters: even if a cancellation were lost,
the user ends up with one reminder.

## What is in `userInfo`

Identifiers and one flag. Nothing else.

```
assistant.v        schema version
assistant.request  the notification request id
assistant.task     the task id
assistant.stage    the reminder stage id
assistant.confirm  whether an answer is wanted
```

`userInfo` is written to disk by the system, survives backups, and is readable
by anything that can read the notification. So no task titles, no notes, no
memory context, no prompts, no credentials. Everything the app needs to display
is loaded from the repositories once routing has found the task.

The schema version is checked rather than assumed. Notifications outlive app
versions — one scheduled last week is delivered by whatever build is installed
when it fires — and a payload this build does not understand is ignored rather
than guessed at.

## Logging

`ApplePlatformLog` takes only caller-authored strings, and the call sites pass
operation names, capability names and permission states. Never an event title, a
reminder body, a note, a location, or an identifier that could be correlated
back to one.

The values in this layer are the user's actual appointments and the titles of
things they have not managed to do. A device log is readable from a connected
Mac and is captured by sysdiagnose. Platform errors are caught and replaced with
sentences written in this codebase, because an EventKit error's description can
quote calendar and account state.

## The failures a live calendar introduced

Making the calendar real gave two call sites a failure mode they never had
against mocks — a user who declined calendar access makes `events(in:)` throw.

`AssistantEngine.send` used to propagate it, which would have meant the
assistant refusing to answer *anything*, including the many questions that have
nothing to do with a calendar. It now degrades: no events, and the turn
continues.

What it does **not** do is pretend the calendar was empty. `AssistantContext`
carries `calendarIsReadable`, and when it is false the prompt says the schedule
is unavailable and not to assume any time is free. An empty list and an
unreadable calendar look identical and mean opposite things, and the wrong
reading produces "you're free at three" to someone who is not — the most
damaging thing a planning assistant can say.

`AppModel.reload` had the same shape and now loads the calendar separately, so a
declined permission no longer empties the task list, the memories and the
settings from the screen. The banner names the calendar specifically, and says
nothing at all when the status is `restricted`, since a banner the user cannot
act on is noise on every launch.

## Demo data can never reach a real calendar

```swift
let platform = launch.seedsDemoData ? nil : PlatformServices.live()
```

A seeded launch always gets mocks. Demo seeding writes example appointments, and
a seeder pointed at EventKit would put a fabricated haircut in someone's real
calendar, where it would sync to their other devices and outlive the app. The
only launches that seed are CI screenshots, SwiftUI previews and a developer's
debug build.

This is also why the simulator preview workflow stays green without granting a
single permission.

## What CI proves, and what it cannot

| Job | Runner | Proves |
| --- | --- | --- |
| Swift Tests | macos-26 | The routing, identity, escalation and permission mappings behave |
| Apple SDK Check | macos-26 | EventKit, UserNotifications and AlarmKit are really compiled in, and the iOS 26 frameworks are weakly linked |
| iOS Simulator Preview | macos-15 | The app still builds, launches and renders |

The SDK check was extended rather than duplicated: it now looks for four
frameworks in the SDK before building, then asserts each is referenced by
something in the bundle afterwards. A `#if canImport` branch that compiled to
nothing would otherwise leave every job green having verified nothing.

None of the three grants a permission, delivers a notification, or sounds an
alarm. A CI runner has no calendar database, no notification centre and no alarm
daemon, which is precisely why the decisions worth checking were extracted into
functions that need none of them.

## What still needs a real device

Marked `TODO-DEVICE` in the source. These compile, are reasoned about, and have
never executed.

- The permission alerts themselves: that each one appears at the moment the
  action is attempted, and that the Info.plist string shown is the right one.
- **Add Events Only** in practice: that EventKit reports `.writeOnly` and the
  app describes it as partial access.
- A notification arriving with all three buttons, and each one reaching
  `FollowUpService` with the outcome this code says it should.
- The cold-launch path: answering a reminder from the lock screen with the app
  not running, and the queued route being replayed rather than lost.
- Whether a withdrawn reminder actually leaves the lock screen when the task is
  completed from inside the app.
- An alarm sounding through Focus and the silent switch, and Snooze producing
  exactly one replacement.
- Which EventKit identifier a recurring event's occurrences report, and whether
  the derived domain id is stable across them.

The scenario worth running first is the milestone's own: ask for a reminder in
ten minutes, lock the phone, and swipe the notification away when it arrives.
What to watch is not the notification but what happens next — the task should
still be open, and the assistant should come back.
