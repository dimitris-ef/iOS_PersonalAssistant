# Background reliability

How the assistant keeps supporting someone while it is not running.

> Persist intent → schedule with iOS → the app may disappear → reconcile when
> execution returns → continue support exactly once.

## The problem

iOS gives an app no general way to run. It is launched, suspended, terminated
and relaunched, and none of that is under the app's control. A user force-quits
it, the phone runs out of battery, the system reclaims memory overnight, the app
is simply not opened for a week.

An assistant built on in-memory timers stops supporting someone the moment they
switch apps. `Task.sleep`, `Timer` and `DispatchQueue.asyncAfter` are all
suspended within seconds of the app leaving the foreground, and a reminder that
depends on one of them is a reminder that silently does not happen.

So none of them are used for anything durable. There is no always-running
process, no polling loop, no background daemon and no hidden microphone.

## The three layers

Everything in this milestone is one of these, and which layer a thing belongs to
is never ambiguous.

| Layer | What it is | Who owns it |
| --- | --- | --- |
| **Persisted domain state** | The source of truth. What the user is owed. | SwiftData, via `AssistantRepositories` |
| **OS-backed scheduling** | User-facing delivery, which keeps working with the app gone. | `UNUserNotificationCenter`, AlarmKit |
| **Reconciliation** | Working out what happened while away, when execution returns. | `SupportReconciliationService` |

The database decides. iOS delivers. Reconciliation makes the second match the
first whenever the app next gets to run.

## What runs when

`AppLifecycleCoordinator` — application-level, deliberately not a SwiftUI
lifecycle callback. A view can be recreated, appear twice, or be replaced by a
preview, and none of that should decide whether reminders get reconciled.

| Moment | What happens |
| --- | --- |
| **Launch** | Register `BGTaskScheduler` identifiers, install the notification delegate, then one bounded pass. |
| **Foreground** | One pass, plus the screens reload. |
| **Background** | Ask for the next opportunistic refresh. Nothing else — no work iOS will kill halfway. |
| **`BGAppRefreshTask`** | The same pass, with an expiration handler that cancels it cleanly. |
| **Notification action** | Route → `FollowUpService` → the same domain logic the UI uses. |

Registration cannot wait for a view: iOS requires every background-task
identifier to be registered before the app finishes launching, and one
registered later never runs. The notification delegate is the same — a
lock-screen "Done" is delivered almost immediately after launch, and a delegate
installed when the first view appears is installed too late.

### `BGTaskScheduler` is an optimisation, never a guarantee

`BGAppRefreshTaskRequest.earliestBeginDate` is a request. iOS decides whether to
honour it based on battery, charging state, and how often the app is actually
used — and on a device that is low on power, or an app the user rarely opens, it
may never run at all.

Nothing about reminder correctness depends on it. The reminders themselves are
`UNUserNotificationCenter`'s job; a background refresh is only ever a chance to
tidy up before the user opens the app.

## The reconciliation pass

`SupportReconciliationService`, and the order is fixed:

1. **Routines.** A recurring responsibility whose moment passed while the app was
   closed has to exist as a task before anything can notice it was missed.
2. **Load outstanding tasks.** Bounded by `maximumTasksPerPass`.
3. **Detect and transition.** Overdue pending stages become missed.
4. **Plan.** Through `SupportPlanner`, via the existing `FollowUpCoordinator`.
   Reconciliation answers *what happened while we were away*; planning answers
   *what now*. Merging them would put escalation policy in two places.
5. **Persist.** Everything, before a single platform call.
6. **Diff and apply.** The desired schedule against what iOS actually holds.

Step 5 before step 6 matters: if the process dies between them, the plan is on
disk and the next pass schedules it. The other order would leave iOS holding a
reminder for a stage that does not exist.

### Single-flight

Two triggers routinely overlap — the app becomes active at the same moment a
background refresh fires, or a lock-screen action cold-launches the app beside
the launch pass. A second caller **awaits the first** rather than being turned
away, because a caller that needs the state settled before it draws a screen
cannot use "someone else is doing it".

### It never calls a model

Not the remote provider, not Apple Foundation Models, not llama.cpp. This is a
hard requirement and the design makes it structural rather than a promise:
`SupportReconciliationService` takes repositories, platform services, a clock and
pure policy values. There is no provider registry in scope for it to call.

Reasons, in order of importance: a pass runs on a cold launch with no network; a
background refresh has seconds, not the tens of seconds an inference takes; and
recovery has to behave identically every time, or the user cannot form a habit
around it.

## Scheduled ≠ delivered ≠ completed

Three separate facts, three separate places.

- `ReminderStageState` — what became of the reminder for the *user*: pending,
  delivered, acknowledged, snoozed, dismissed, missed, cancelled.
- `StageDelivery` — whether *iOS* holds a request: planned, scheduled, failed,
  unavailable.
- `TaskStatus` — whether the *work* is done.

Folding the first two together would force a stage that could not be scheduled
(notification permission is off) to choose between lying — `pending`, as though a
reminder were coming — and destroying its own lifecycle by marking itself missed.
Kept apart, it is pending and undelivered, which is exactly the truth, and the
Settings screen can say so.

And the rule the product rests on survives all of it:

| Gesture | Means |
| --- | --- |
| Swipe away | **Not** completion. The follow-up ladder continues. |
| "I'm on it" | Engagement. **Not** completion. |
| "Later" | A reschedule. **Not** completion. |
| Notification Center cleared | Nothing at all. |
| Notification delivered | iOS showed something. Evidence, not an outcome. |
| **"Done"** | The only thing that completes a task. |

## Identifiers, revisions and duplicates

**Stable identifiers.** The stage id *is* the notification request id, derived
rather than allocated. Cancelling and replacing therefore need no mapping table
that could go stale, and re-scheduling the same stage replaces its request
instead of adding a second one.

**Plan revisions.** `ReminderPlan.revision` moves once per change to the plan.
Every notification carries the revision it was scheduled under in its `userInfo`
and brings it back with the user's answer. A *lower* revision means the button
they pressed belonged to a schedule that has since been replaced — the classic
case being a notification that sat on the lock screen while the event moved — and
it is declined rather than allowed to resurrect a reminder that no longer exists.

A *higher* revision cannot legitimately happen, and if it somehow did (a restored
backup, a clock that went backwards) refusing it would be the app arguing with
the user about a button they just pressed. So only lower is refused.

**Handled actions.** A small persisted table keyed by (stage, action, revision),
derived and never allocated. Real notification callbacks arrive more than once:
iOS can redeliver after a crash, a cold launch triggered by a lock-screen action
can race a foreground pass doing the same work, and users tap twice when the
first tap appears to do nothing. The second arrival — in this process or the next
— finds the row already there and changes nothing.

This deliberately does not reuse the Part 7 `ToolExecutionLedger`. That ledger is
turn-scoped and in memory; its job is stopping one agent loop repeating itself
inside one turn. A duplicate notification callback arrives with no turn in sight,
in a process that may have just launched to handle it, possibly minutes later.
Nothing in-memory can see that.

## The schedule diff

`PlatformScheduleDiff` compares what the domain wants against what
`getPendingNotificationRequests` reports, producing **toSchedule**, **toCancel**
and **unchanged**.

`removeAllPendingNotificationRequests()` is never called. It removes
notifications this app did not schedule, it leaves a window in which the user has
no reminders at all — and if the app is terminated inside that window, support
silently stops until the next launch — and it makes duplicate detection
impossible, because everything is always both new and obsolete.

A diff also means a pass over an unchanged store makes **zero** platform calls,
which is what makes running it on every foreground affordable.

Matching compares time (to the second), escalation, channel and revision.
Deliberately not the body text: a wording change is not worth tearing down and
re-adding a notification.

## Catch-up after a long absence

`SupportCatchUpPolicy` owns every threshold, in one place, so a limit cannot be
raised in one service and not another.

| Bound | Default | Why |
| --- | --- | --- |
| `missedStageGracePeriod` | 2 minutes | A reminder that just fired is not one that was missed — the user may be looking at it. |
| `maximumHistoricalStagesPerTask` | 3 | The rest are recorded as missed without each driving a planning round. |
| `maximumEscalationStepsPerPass` | 1 | A week of silence is worth escalating for; jumping to an alarm because time passed is frightening. |
| `maximumTasksPerPass` | 100 | A background refresh has seconds. |
| `schedulingHorizon` | 7 days | A rolling window, so the pending queue holds what is imminent. |
| `maximumSchedulingAttempts` | 5 | A call that has failed five times will not succeed on the sixth. |

Someone who has not opened the app for a week may have dozens of theoretically
missed follow-ups on one task. All of them really were missed and the plan says
so. What they get is **one** reminder — because arriving to a screenful of
notifications is precisely the overwhelm this app exists to prevent.

## Failure, told truthfully

- **Permission denied.** Recorded as `unavailable` and not retried. Retrying a
  decision the user made, on every launch, is a battery bug that also lies about
  whether the reminder will fire. The domain reminder survives: the app has not
  forgotten the task, it just cannot announce it.
- **A transient refusal.** Recorded as `failed` and retried on the next pass,
  bounded by the attempt count. Because the identifier is stable, the retry
  replaces rather than duplicates.
- **Notification delivery itself.** Not guaranteed by iOS, ever. Which is why a
  delivered timestamp is treated as evidence that something was shown and never
  as an outcome, and why reconciliation — not the callback — is what ultimately
  decides that a reminder went unanswered.

## Time, zones and clocks

Recurrence is computed with `Calendar` and `DateComponents`, never by adding
86,400 seconds, so a daily 9 AM routine stays at 9 AM across a DST boundary. A
time-zone change re-evaluates the schedule on the next pass; quiet hours are
respected by the planner, which is where that policy already lived.

## What is not promised

- **Force quit.** After the user force-quits, iOS will not launch the app for a
  background refresh. Already-scheduled notifications and alarms still fire —
  they belong to the system, not to the process — and reconciliation resumes the
  next time the app is opened. Anything stronger than that would be a promise
  the platform does not support, and the app does not make it.
- **Exact background timing.** `BGTaskScheduler` runs when it runs.
- **The simulator.** It does not prove production timing, delivery, or
  background execution behaviour. See below.

## Privacy in logs

`SupportReconciliationReport` is counts and identifiers: tasks evaluated, stages
missed, follow-ups generated, requests scheduled and cancelled. Never titles,
never reminder text. A log line naming what somebody is being reminded about is
the most private thing this app could emit, and the report type is shaped so
that emitting one is not possible by accident.

`userInfo` is the same story from the other side: it is written to disk by the
system, survives backups, and outlives the app version that scheduled it. So it
carries a schema version, three identifiers, one flag and a revision number —
no titles, no task details, no memory context, no prompt text, no credentials.

## Device-only background validation remaining

CI compiles and exercises all of this against injected clocks and mock platform
services. It cannot exercise the parts that are the operating system's, and the
simulator does not stand in for them. What still needs a real device, with a
real user, over real time:

1. **`BGAppRefreshTask` actually firing.** Whether iOS grants the app background
   time at all, how often, and how much — which depends on usage patterns,
   battery and charging state, and Low Power Mode.
2. **Expiration under real pressure.** That the expiration handler is reached and
   the pass stops cleanly when iOS is genuinely about to suspend the process,
   rather than when a test cancels a task.
3. **Notification delivery over days.** That requests scheduled a week out fire
   at the right moment, survive a reboot, and survive an app update.
4. **AlarmKit on device.** Sound through silent mode, the dismissal requirement,
   and behaviour on a locked screen.
5. **Cold launch from a lock-screen action.** That the delegate is installed
   early enough to see a response delivered during launch, in a build that was
   not already running.
6. **Force quit.** Confirming that scheduled notifications still fire, and that
   the app recovers correctly the next time it is opened.
7. **Reboot.** That pending requests survive a power cycle and that the first
   launch afterwards reconciles rather than duplicating.
8. **Time-zone and DST transitions in the wild**, including a device that travels
   while the app is not running.
9. **Permission revoked mid-life.** Switching notifications off in Settings while
   reminders are pending, and what the app then says to the user.
10. **Pending-request pressure.** How the rolling horizon behaves on an account
    with many active tasks, against the system's real limit on pending requests.

These are recorded in [`Docs/OPEN-ITEMS.md`](OPEN-ITEMS.md).
