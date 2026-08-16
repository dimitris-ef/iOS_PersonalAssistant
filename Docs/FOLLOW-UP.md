# Executive-function follow-up

What happens after a reminder is shown — which, for this product, is the part
that matters.

## The problem this solves

Before this milestone, the app posted a reminder and considered its job done.
`TaskStatusMachine` correctly knew that dismissing is not completing, and
`SupportPlanner` knew how to build a staged plan, but nothing connected them:
a dismissal changed a task's status and stopped. The user swiped a notification
away, the task stayed open forever, and no one ever mentioned it again.

That is the exact failure mode an executive-function aid exists to prevent. A
reminder is an *intervention*; a task is an *obligation*. Interventions can
fail. The obligation survives them.

## The chain

```
reminder outcome (or a user action)
        ↓
FollowUpService            loads, persists, calls the platform layer
        ↓
FollowUpCoordinator        pure; owns the order of operations
        ↓
ReminderPlan.recordOutcome the stage remembers what became of it
        ↓
TaskStatusMachine          what that means for the task
        ↓
SupportPlanner             one next intervention, or none
        ↓
repositories + mock platform services
```

Nothing else may change a task's status. The UI's buttons, the assistant's
`completeTask` tool and — later — notification callbacks all enter through
`FollowUpService.handle(outcome:forTask:stageID:)`.

## Reminder state

`ReminderStage` gained a lifecycle: `pending`, `delivered`, `acknowledged`,
`snoozed`, `dismissed`, `missed`, `cancelled`, plus `stateChangedAt` and
`scheduledFor`.

The states describe the **reminder**, never the task. `dismissed` on a stage
and `completed` on a task are different facts about different things, and the
type system now keeps them apart.

`isPending` — only `pending` — is what "is a follow-up already waiting?"
consults. `isResolved` is what makes repeat processing a no-op.

## Policy

Every timing number lives in `FollowUpTiming`, one value type in one file:

| Priority | First follow-up after a dismissal or miss |
| --- | --- |
| Low | 4 hours |
| Normal | 2 hours |
| High | 30 minutes |
| Critical | 15 minutes |

Then three adjustments, in order:

1. **Repeated failure tightens the loop.** Each unsuccessful attempt halves the
   wait (`repeatedAttemptFactor`), because repeating an approach that just
   failed is not a strategy.
2. **A floor.** Never more often than `minimumInterval` (10 minutes), however
   urgent and however many attempts.
3. **Deadlines win.** If the computed interval would land after the deadline,
   it is pulled in to `deadlineFraction` of the time remaining. A reminder
   dismissed at 9:50 PM for a 10:00 PM deadline does not come back at 1:50 AM.

Overdue tasks keep a steady `overdueInterval` rather than an accelerating one —
being late is when support matters most, and also when hammering someone helps
least. Escalation climbs with importance and with attempt count, and stops at
`.alarm`. Quiet hours still apply downstream in `ReminderScheduleResolver`.

`DefaultSupportPlanner` takes a `FollowUpTiming` in its initialiser, so tests
pin their own and no number is hardcoded at a call site.

## What each outcome does

| Outcome | Stage becomes | Task becomes | Next intervention |
| --- | --- | --- | --- |
| `delivered` | `delivered` | `reminded` | none — the user has not answered yet |
| `snoozed(until:)` | `snoozed` | `snoozed` | at the requested time, or the plan's snooze policy |
| `dismissed` | `dismissed` | `needsFollowUp` | after the policy delay |
| `acknowledged` | `acknowledged` | `inProgress` | a gentle check-in, further out |
| `missed` | `missed` | `needsFollowUp` | sooner, escalated |
| `completed` | `cancelled` | `completed` | none, ever |
| `cancelled` | `cancelled` | `cancelled` | none, ever |

**Dismiss and snooze are not the same.** Snoozing is a request, honoured at
face value and at gentle escalation. Dismissing is the absence of a decision,
so the planner picks the timing and urgency.

**Acknowledging is not completing.** "I'm doing it" moves the task to
`inProgress` and pushes the next check-in out by `inProgressCheckIn`. It does
not cancel support, because intending to do something is not doing it.

## Terminal states

`TaskStatus.isTerminal` — `completed` and `cancelled` — is the only thing that
ends support permanently. There is no separate `shouldStopReminding` flag; the
status machine already expresses it.

`missed`, `reminded`, `snoozed` and `needsFollowUp` are all `isOutstanding`:
the assistant is still responsible. Running out of follow-ups stops the
chasing, not the obligation — the task stays outstanding rather than being
quietly moved to a terminal state.

On resolution, `cancelPendingStages` marks every unresolved stage `cancelled`
and the service withdraws the matching platform requests. A completed task
cannot be reopened by a stale callback: the coordinator's first guard reads the
task's status and returns a decision that changes nothing.

## Duplicate prevention and idempotency

Two mechanisms, both in the domain rather than in a caller:

- **`ReminderPlan.recordOutcome`** refuses to apply an outcome to a stage that
  is already resolved. A notification callback delivered twice — which real ones
  are — produces one follow-up.
- **`ReminderPlan.hasPendingStage(kind:at:)`** stops the planner producing an
  equivalent stage when one of the same kind is already pending within a minute
  of the same time.

At the platform level, the stage id *is* the notification request id, so a
re-run cannot create a second OS-level notification for the same stage.

Scheduling happens because of a domain event, never because a screen rendered.
Reconciliation runs on `scenePhase == .active`, not in a view's `task {}`.

## Reconciliation

Real callbacks arrive late, get retried, or never arrive — the app may not have
been running. So the truth about a reminder cannot come only from a callback.

`FollowUpCoordinator.reconcile` marks any `pending` stage whose `scheduledFor`
has passed, on an unresolved task, as `missed` — and missed produces the next
intervention. A backlog of three overdue reminders is applied in order, so the
attempt count climbs and the result is one escalated follow-up rather than three
identical ones.

`FollowUpService.reconcile()` does this across all outstanding tasks. It is
idempotent: the first pass leaves those stages resolved.

## Persistence

Stage state is stored through the existing SwiftData repositories. Schema
**V2** adds `stateRaw`, `stateChangedAt` and `scheduledFor` to
`SDReminderStage`, all optional, migrated by an inferred `.lightweight` stage.

A row written by V1 reads back as `.pending` — a reminder still waiting, never
one already dealt with. The opposite default would silently mark every
pre-existing reminder as handled, which is the failure this milestone fixes.
`scheduledFor` stays nil, so an old stage is skipped by reconciliation rather
than treated as overdue the instant the app opens. Nothing is deleted and no
task's status is touched. See `PersonalAssistantMigrationPlan`.

### Consistency

A reminder outcome writes a plan and a task. The repositories are separate
protocols with no shared transaction, so a crash between the two writes is
possible. The plan is written first, deliberately: a saved plan with a stale
task leaves a pending follow-up on a task whose status is behind, which
reconciliation corrects. The reverse would leave a resolved task with live
reminders — the failure a user would actually notice.

## Platform boundary

The planner produces a `ScheduledReminder`: task, stage, date, channel,
escalation. `FollowUpService` decides only which service delivers it —
`AlarmService` for alarm-level, `NotificationService` otherwise.

Every one of those is a mock. Nothing reaches a real device, and the mocks
report `.simulated`, which travels up into the UI's badges. Swapping in the
Apple implementations changes one method and nothing above it.

## No AI in the loop

Follow-up scheduling never calls a provider. Once a task and its plan exist,
`TaskStatusMachine`, `SupportPlanner` and the repositories decide everything —
deterministically, offline, in microseconds. A model may create or explain a
task; it is not consulted about whether a dismissed reminder should come back.

Switching provider changes one string in settings and touches no lifecycle
state, which there are tests for.

## What is still missing for real delivery

- **Notifications are not delivered by the OS.** `UserNotificationsService` is a
  TODO-XCODE skeleton. Until it exists, "delivered" only happens when the user
  taps a stage in the reminder timeline to simulate it.
- **Missed reminders are only noticed when the app opens.** Catching one at the
  moment it happens needs a notification callback or background execution.
  The domain API is ready for both: `handle(outcome:forTask:stageID:)` is what
  a callback would call, and `reconcile()` is what a launch or background
  refresh would call.
- **No alarm delivery.** `AlarmService` is an AlarmKit skeleton, so an
  alarm-level escalation currently records intent and nothing more.
