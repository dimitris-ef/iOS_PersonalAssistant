# Open items

Everything known to be incomplete, unverified or deliberately limited, in one
place.

This exists because the three categories below get confused with each other,
and they need completely different responses. A `TODO-DEVICE` is discharged by
plugging in an iPhone. A deliberate limitation is not — it is a decision, and
changing it means changing the design. Filing them together as "TODOs" would
mean someone eventually "fixes" a trade-off that was made on purpose, or waits
for a device to resolve something no device will.

Nothing here is a bug that is known and unfixed. Where a defect was found, it
was fixed.

```bash
grep -rn "TODO-XCODE"  --include=*.swift --include=*.yml .   # 27 — needs Xcode or an Apple SDK
grep -rn "TODO-DEVICE" --include=*.swift .                   # 11 — compiles, never executed
```

Restrict the grep to source. Counting `Docs/` as well inflates both numbers,
because these files discuss the markers — including this one.

---

## 1. Deliberate limitations

Decisions with a cost, taken knowingly. Each one has an alternative that was
considered and rejected; the rejection is the entry. Revisit these when the
trade-off changes, not when someone notices the symptom.

| # | Limitation | Why it is this way | Where |
| --- | --- | --- | --- |
| 1 | **"Add Events Only" blocks event creation too.** With write-only calendar access the app declines to write, even though EventKit would permit it. | `PermissionStatus` is checked per capability, not per operation. Distinguishing reads from writes means a permission check at every call site. Few people will pick this answer, and the ones who do are told exactly what is missing. | `ToolExecutor.execute`, `AppleCalendarAuthorization.permissionStatus` |
| 2 | **Repeating alarms schedule one occurrence.** `AlarmRequest.recurrence` is not honoured. | AlarmKit expresses repetition through `Alarm.Schedule.relative`, a different shape from the `.fixed` date this layer builds. Nothing sets `recurrence` today — `createAlarm` has no such input — so the receipt says "this one time only" rather than the code pretending. | `AlarmKitAlarmService.schedule` |
| 3 | **`maximumSnoozes` is not enforced by the OS.** AlarmKit will let someone snooze indefinitely. | AlarmKit has no equivalent setting. The limit is enforced where it can be: the follow-up ladder counts snoozes and escalates. A cap the OS silently ignores would be worse than none. | `AlarmKitAlarmService.configuration` |
| 4 | **Alarm labels are lost across a relaunch.** `scheduledAlarms()` reports "Alarm" for any alarm this process did not schedule. | AlarmKit's `Alarm` carries an id, a schedule and a state — not the text that was shown, and attributes cannot be read back. The label is domain data and lives in the reminder plan; the in-actor mirror is a convenience, not a record. Cancellation is by id and is unaffected. | `AlarmKitAlarmService.labels` |
| 5 | **Critical alerts are never requested.** The loudest level the app produces is Time Sensitive. | The entitlement is granted case by case for things like medical alerts and this app does not hold it. Requesting the level without it does not fail loudly — it simply does not happen, which would leave a line of code that looks like it delivers an unmissable alert. | `AppleEscalationMapping.delivery` |
| 6 | **Time Sensitive delivery itself depends on an entitlement this build lacks.** Without it iOS treats those notifications as `active`. | Same reasoning. The level is set because it is correct once the entitlement exists, and no receipt promises Focus will be broken through. | `AppleEscalationMapping`, `UserNotificationsService.schedule` |
| 7 | **A cold lookup only searches ±1 year.** `event(id:)` rescans a two-year window to rebuild its identifier cache; an event outside that is reported as not found. | EventKit refuses predicates spanning more than four years, and a wider scan on every cache miss is expensive. Two years covers everything the assistant plans around. | `AppleEventKitStore.eventObject(for:)` |
| 8 | **Importance, travel time and preparation time are not written to EventKit.** They survive on the returned item and in the app's own store. | EventKit has no field for any of them on an event. The near-misses are worse: encoding preparation time into `notes` puts machine text in front of the user in Apple's Calendar app, and moving `startDate` earlier for travel tells everyone in a shared calendar the meeting starts at a time it does not. | `AppleEventKitStore.apply(_:to:)` |
| 9 | **Apple Reminders is a one-way door.** The assistant writes there; nothing reads completions back into the task lifecycle. | A ticked checkbox in another app is not evidence that the thing was done, and treating it as confirmation would reintroduce exactly the failure this product exists to prevent. | `EventKitReminderService` |
| 10 | **No local inference runtime is chosen.** `LocalModelProvider` is complete except for the runtime. | Deliberately deferred — llama.cpp, MLX, Core ML and ExecuTorch are a real decision, and the provider is written so making it later means writing one type. | `LocalModelProvider` (`TODO:`) |
| 11 | **Speech recognition uses `SFSpeechRecognizer`, not iOS 26's `SpeechAnalyzer`.** | The modern stack is the better API but is iOS 26+, and the app deploys to iOS 17 — so `SFSpeechRecognizer` is required for most supported devices regardless, and the modern path would be an *addition*. That means two implementations of one feature, neither executable from this environment. One unverified speech path is a known risk; two doubles it. The seam is `SpeechInputService`; adding it later is one type and one `if`. | `VoiceServices.live()` |
| 12 | **An interrupted recording is discarded, not resumed.** A phone call mid-sentence ends the attempt and offers Retry. | Audio captured across an interruption is missing the middle of the sentence, and this assistant *acts* on what it hears — half a command submitted is worse than none. | `AppleSpeechInputService.interrupted()` |
| 13 | **Cancellation is an event, not a state.** The milestone's sketch lists `cancelled` beside `idle`. | Nothing rests there: the user just pressed Cancel and knows it, so a "Cancelled" screen to dismiss is worse than the composer returning. `failed` *is* a state, because there is something to say and a decision to make. | `VoiceSession` |
| 14 | **Voice input source is not stored on the message.** Only the reply's spokenness depends on it. | Forking messages into spoken and typed kinds would make every reader handle both, for a distinction that matters for exactly one decision — and that decision is made before the message is saved. | `MessageInputSource` |

---

## 2. `TODO-DEVICE` — compiles, never executed

Reasoned about and checked as far as a machine without an iPhone can check.
None of it has run. A CI runner has no calendar database, no notification
centre, no alarm daemon and no Apple Intelligence, which is why the decisions
worth testing were extracted into functions that need none of them — but the
framework calls themselves are unexercised.

| Area | What is unverified | Where |
| --- | --- | --- |
| Permissions | That each alert appears at the moment the action is attempted, and shows the right Info.plist string | `AppleEventKitStore` |
| Calendar | That "Add Events Only" really arrives as `.writeOnly` | `AppleEventKitStore` |
| Calendar | Which identifier a recurring event's occurrences report, and whether the derived domain id is stable across them | `AppleEventKitStore` |
| Notifications | A reminder arriving with all three buttons, and each reaching `FollowUpService` with the right outcome | `UserNotificationsService` |
| Notifications | Whether a withdrawn reminder actually leaves the lock screen | `UserNotificationsService` |
| Notifications | Foreground presentation while the app is open | `UserNotificationsService` |
| Cold launch | The queued-route replay: answering from the lock screen with the app not running | `AppleNotificationCoordinator` |
| Alarms | That anything sounds at all — the alert, its buttons, Snooze running the countdown, breaking through Focus and the silent switch | `AlarmKitAlarmService` |
| On-device AI | Every part of the generation path; which availability case a device reports; whether a refusal surfaces as `.refusal` or `.guardrailViolation` | `AppleFoundationModelsProvider` |
| On-device AI | Whether the framework pairs a `ToolCall` with its `ToolOutput` by the shared id this code gives them | `AppleFoundationSessionAdapter` |
| Voice | The microphone and speech alerts appearing, in order, with the right strings | `AppleSpeechInputService` |
| Voice | Live recognition: accuracy, and how far behind the speaker partial results lag | `AppleSpeechInputService` |
| Voice | The level meter responding to a real voice rather than to a number | `AppleSpeechInputService` |
| Voice | Bluetooth routing, and a headset disconnecting mid-sentence | `AppleSpeechInputService` |
| Voice | A phone call arriving while listening, and Retry working afterwards | `AppleSpeechInputService` |
| Voice | The TTS → microphone handoff: that `.immediate` really stops the recogniser hearing the assistant's own tail | `AppleSpeechOutputService` |
| Voice | Whether `.playAndRecord` with `.duckOthers` behaves acceptably over music already playing | `AppleSpeechInputService` |

**The first scenario worth running**, because it tests the product's founding
claim end to end: ask for a reminder in ten minutes, lock the phone, and swipe
the notification away when it arrives. Watch what happens *after* — the task
should still be open and the assistant should come back.

---

## 3. `TODO-XCODE` — needs Xcode or an Apple SDK

Not an "unfinished" marker. Each of these is something that genuinely cannot be
done from a machine with no Apple toolchain.

| What | Sites | Note |
| --- | --- | --- |
| `#Preview` verification | 21 | Every SwiftUI preview is marked; none has been rendered |
| Keychain | 3 | `KeychainCredentialStore` has never run against a real Keychain |
| Voice input | 1 | `AVAudioEngine` capture and `SFSpeechRecognizer` — not started |
| AlarmKit initialiser | 1 | Uses the deprecated `AlarmPresentation.Alert` init on purpose — its replacement arrived partway through the iOS 26 line and would not compile against the earlier SDKs. Switch when the project's minimum Xcode passes that change. |
| Mock permissions | 1 | iOS permission alerts cannot be modelled in a mock |

`project.yml` is no longer on this list. It carried a `TODO-XCODE` saying it had
never been run through XcodeGen; both Apple workflows now generate the project
from it and compile the result on every build, so `1d5e202` retired the marker.
Opening the generated project in Xcode by hand is still unverified, and the file
says so in prose rather than claiming to be untested.

---

## What is verified

Worth stating alongside the gaps, so this file is not read as a list of
everything that is wrong.

| Workflow | Runner | Proves |
| --- | --- | --- |
| Swift Tests | macos-26 | The full suite compiles and runs, including the routing, identity, escalation, recurrence and permission mappings, the voice state machine and coordinator, and the EventKit and UserNotifications code (which compiles on macOS) |
| Apple SDK Check | macos-26 | EventKit, UserNotifications, AlarmKit and FoundationModels are present in the SDK, are really referenced by the built binary, and the two iOS 26 frameworks are **weakly** linked — the check that stops a launch crash on every iPhone below iOS 26. The Speech and AVFAudio code compiles here too, since `AppleSpeechInputService` is iOS-only |
| iOS Simulator Preview | macos-15 | The app builds against an older SDK (where AlarmKit does not exist), launches and renders |

## Keeping this file honest

Add an entry when a decision has a cost someone could later mistake for an
oversight. Delete an entry when the thing is done, not when it is worked
around. If an item moves category — a deliberate limitation that becomes worth
fixing — say what changed, because the original reasoning is the thing a future
reader needs in order to disagree with it.
