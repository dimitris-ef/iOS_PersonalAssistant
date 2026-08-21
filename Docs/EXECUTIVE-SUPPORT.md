# Advanced executive support

Recurring responsibilities, task order, preparation timing, and helping someone
begin.

## The sentence this exists for

> I take my medication every morning at nine, I have to print the forms before
> Thursday's appointment, and I don't know where to start with the tax return.

Three different failures of executive function in one message, and none of them
is answered by another reminder. The first needs something that comes round
again and survives being missed once. The second needs the app to know that
chasing the appointment while the forms are unprinted is chasing the wrong
thing. The third needs a first physical action, not encouragement.

---

## What was added, and what already existed

Nothing here is a second engine. Part 8 extends the domain that Parts 2 and 7
built: the same `TaskStatusMachine`, the same `SupportPlanner`, the same
`ReminderPlan`, the same follow-up ladder, the same repositories, the same
`AssistantEngine`, the same validate → authorize → execute path for tools.

The single design decision everything else follows from:

> **A routine occurrence is an ordinary `TaskItem`.**

It carries `routineID` and `occurrenceDate`, and that is the whole difference.
Which means this morning's medication gets the existing status machine, the
existing reminder plan, the existing escalation, the existing Today list and
the existing follow-up — without one line of "if this is a routine".

The alternative — one task that gets reset every morning — is the design this
prevents. It loses the history, it cannot express "yesterday's dose was missed
but today's is done", and completing it once ends the routine forever.

---

## 1. Recurring responsibilities

### `RecurrenceRule` — and why it is not `EKRecurrenceRule`

`EKRecurrenceRule` belongs to a framework that exists on one platform, cannot be
constructed without EventKit linked, and would make "take my medication every
morning" — which touches no calendar at all — depend on the user granting
calendar access. Recurrence is a fact about a person's life, not about Apple's
calendar database.

`AppleRecurrenceMapping` maps outward, for the cases where a rule really is
going into the user's calendar. Nothing reads recurrence back out.

### Why the maths is calendar-based

Every occurrence is computed with `Calendar` and `DateComponents`, never by
adding 86,400 seconds.

"Every morning at 9" means nine o'clock as the clock on the wall reads it, and
on the two days a year the clocks change, nine o'clock is not twenty-four hours
after the previous nine o'clock. `RecurrenceTests` asserts this directly: across
29 March 2026 in Europe/London the gap between consecutive occurrences is 23
hours, and the occurrence is still at 09:00. A daily medication reminder that
drifts to 8 AM every spring is a bug someone notices only once it has already
gone wrong.

### Routine versus occurrence

| | `Routine` | Occurrence (`TaskItem`) |
| --- | --- | --- |
| What it is | The responsibility | One morning of it |
| Can be completed | No | Yes |
| Can be missed | No | Yes |
| Can be skipped | No | Yes |
| Ends when | The user ends it | It resolves |

A routine is never completed, never missed and never in progress, because those
are things that happen to a particular morning. It records `lastCompletedAt` and
`lastMissedAt` and nothing else about how any individual occurrence went.

### Generation is bounded and idempotent

`RoutineScheduler.pendingOccurrences` materialises a rolling two-day window,
capped at sixteen per pass. "Every day at 9" over a year is 365 task records
nobody has looked at, each with a reminder plan and a set of platform
notifications — and iOS caps pending notifications at 64 regardless.

Idempotent twice over. The scheduled instants come from the rule, so the same
window always yields the same list; and each occurrence's id is *derived* from
the routine and that instant rather than allocated:

```swift
TaskItem.ID.deterministic(
    namespace: "routine-occurrence/\(id.rawValue.uuidString)",
    name: String(Int(date.timeIntervalSince1970.rounded()))
)
```

So working out that Thursday needs an occurrence twice produces one occurrence.
Relaunching the app three times before breakfast produces one morning
medication task. Without this, "have I already made this?" needs a query, the
query needs an index on two columns, and the first time the query is missed the
user has two sets of bin reminders.

(Not `Hasher`: it is seeded per process and is not stable across launches, which
is exactly the property being relied on here. Two independently seeded FNV-1a
passes give 128 stable bits. Not a cryptographic hash either — nothing is
defending against an adversary choosing a colliding name.)

---

## 2. Missing one, and what happens next

`RoutineRecoveryPolicy` is per routine, and the judgement it encodes is:

> Missing the bins on Thursday night is recoverable on Friday morning. Missing a
> 10 AM meeting is not recoverable at 4 PM.

Both are "the reminder did not work". Treating them the same produces one of two
failures: nagging someone at 4 PM about a meeting that finished, or silently
dropping a medication dose that could still be taken at 10.

```
occurrence's moment passes
        ↓
recovery disabled? ──────────────→ expired
        ↓ no
inside the window? ──── yes ────→ missed, still outstanding, support continues
        ↓ no
     expired
```

`allowsNextDay` is separate from `window` because "still useful tomorrow
morning" and "still useful for twelve hours" are different claims. Thursday 8 PM
plus twelve hours is 8 AM Friday, which is right for the bins; the same twelve
hours on a 9 AM medication reaches 9 PM, which is not.

### `expired` and `skipped`

Two new statuses, both terminal, neither a success.

- **`expired`** — its window closed. Support stops, because continuing to ask
  about something that cannot happen is what teaches people to ignore the app.
  Nothing claims it was done: `completedAt` stays nil and `isSuccess` is false.
  Expiring also *withdraws the pending platform notifications*. An expired
  occurrence that still buzzes at nine o'clock is worse than one nobody
  cancelled, because now the app is visibly wrong.
- **`skipped`** — "not this time". Deliberately not `cancelled`, which reads
  everywhere else as calling off the responsibility. Skipping today's gym
  session is not cancelling the gym.

**Missing an occurrence never deactivates the routine.** That falls out of the
routine and the occurrence being separate records, rather than needing a rule to
protect it.

---

## 3. Order between tasks

`TaskDependencyGraph` records one relationship with one meaning: A must be
settled before B is worth doing. No conditional branches, no parallel joins, no
states of its own — a general workflow engine would be a second lifecycle
competing with `TaskStatus` for the answer to "where does this stand".

Edges live on the dependent task, as `TaskItem.dependsOn`, so the question a
task asks most often — *am I blocked?* — is answerable from the task itself with
no join and no graph load.

### What is refused

| Refused | Why | Where |
| --- | --- | --- |
| Self-dependency | Decidable without loading anything | `ToolRequestDecoder`, then again in the graph |
| Unknown task | Nothing to wait for | `TaskDependencyGraph.validate` |
| Duplicate edge | Already recorded | `TaskDependencyGraph.validate` |
| Cycle | A→B and B→A are each reasonable; together they are two tasks that block each other forever | `DefaultToolExecutor`, where the whole graph is visible |

The cycle check happens at execution rather than at decoding because it needs
every task. Self-dependency is caught at decoding as well, so the model is told
immediately rather than after authorization.

### Blocked means quiet, not hidden

A blocked task keeps its place on the Today list, dimmed, saying what it is
waiting for. It is not chased. The reassurance matters: silence about a blocked
task is deliberate, not the app forgetting.

Four statuses unblock, not one. Completed, cancelled, skipped and expired are
all *settled* — a prerequisite that was skipped is never going to be completed,
and leaving its dependents blocked forever would turn one missed step into a
permanently stuck list. "You skipped the gym" still unblocks "put the kit away".

When a prerequisite settles, `FollowUpService` re-evaluates its dependents in
the same pass and returns what became workable. The user does not have to reopen
the app for a blocked task to notice it is free.

---

## 4. Preparation and leaving on time

```
anchor            16:00   the thing itself
 − buffer          10m    slack, so arriving is not a photo finish
 − travel          30m
= leave           15:20
 − preparation     45m    the steps, or the stated duration
= start           14:35
```

One buffer with an importance multiplier, not a number repeated in four places.
The minimum buffer is two minutes and not zero: a plan that has the user
arriving at the exact second the appointment begins is a plan that fails, and
telling someone it fits is worse than telling them it does not.

Steps win over a bare `preparationDuration` when there are any — they say the
same thing with more detail.

### Compression: the interesting case

The interesting case is not the plan. It is what happens twenty minutes after
the plan was ignored. Repeating "start getting ready at 2:35" at 2:55 is worse
than useless: it is visibly wrong, and being visibly wrong is how an assistant
loses the benefit of the doubt.

So the plan is rebuilt against the time that is actually left. Order of
sacrifice:

1. `optional` steps
2. `recommended` steps
3. the buffer, down to its floor

`required` steps are never dropped. If they still do not fit, the answer is
`cannotMakeIt(shortBy:)` — because "you are eight minutes short" is something a
person can act on and "you are late" is not.

### Stable step identities

Replanning happens constantly: the event moves, a step is completed, recovery
compresses the plan. With allocated ids every pass would append another "Leave
home"; with `PreparationStep.identity(parent:title:)` it updates the one that is
already there.

---

## 5. What to do now

`DailyPriorityRanker` is one place, not the Today view, because three surfaces
need the same answer — the Today screen, Siri, and the assistant's own sense of
what to bring up — and because the interesting rules are not sortable by a
keypath.

The score is kept as separate terms rather than one number. When the wrong thing
is at the top, "score 4.7" says nothing and "deadline 3.0, overdue 0.0, blocked
−2.0" says exactly which rule misfired. It is for tests and for logs; the user
who asked what to do next wants the answer, not arithmetic.

| Term | What it is for |
| --- | --- |
| `urgency` | Rises as the moment approaches, flat beyond six hours so next month does not compete with this afternoon |
| `importance` | How much it matters |
| `deadline` | Extra weight for today |
| `overdue` | **Bounded.** Grows for a couple of days and then stops, so a stale errand nags gently while a fresh urgent thing still wins |
| `recovery` | Missed but rescuable: surfaced, not enthroned |
| `preparation` | The case the ranker turns on — when getting ready should start about now, that *is* the thing to do, even though the appointment is hours away |
| `dependency` | Large and negative when blocked |
| `momentum` | Work already under way, so starting something is rewarded |

Preparation weight applies only to tasks that actually have preparation. A
timeline can be computed for anything with a date, but a zero-length plan ending
at the buffer is not "you should be getting ready" — it is "this is soon", which
urgency already says. (An overdue task's degenerate timeline reads as *behind*,
which would otherwise hand a month-old errand the top of the list.)

### The rule that is not a comparator

**No task appears above one it is waiting on.** The blocked penalty alone is not
enough: a blocked task with a deadline this afternoon can still outscore the
prerequisite due next week. Telling someone to submit the paperwork above
telling them to finish it is advice they cannot follow. So after scoring, a
stable pass lifts open prerequisites immediately above their dependents.

---

## 6. "Help me start"

The line section 38 draws is exactly right:

> "You can do it, start small" is advice. "Pick up all the clothes from the
> floor, about five minutes" is a thing a person can begin doing in the next ten
> seconds.

For somebody stuck at the starting line, that difference is the whole product.

### Where the step comes from, in order

1. **Steps the task already carries.** The user or the assistant wrote them down;
   overriding them would be the app ignoring what it was told.
2. **The routine's steps**, copied onto the occurrence — copied, not shared, so
   completing Tuesday's "pack the kit" does not tick Thursday's.
3. **A deterministic template.** Keyed on words that appear in what people
   actually write down. Not clever, and it does not need to be: a concrete,
   slightly generic first step beats a perfect one that requires a network round
   trip. The universal fallback is a *time box* — "spend five minutes on the
   easiest part" — because when the app genuinely does not know what the task
   involves, that is the honest smallest step.
4. **A model**, only if one is composed in, and only through `TaskDecomposer`.
   Whatever it proposes becomes structured `PreparationStep` values, bounded to
   eight steps of at most two hours each, before anything is persisted. Model
   prose never becomes task state.

### The two things it must not do

- **It must not answer with encouragement.** See above.
- **It must not complete anything.** Starting is `inProgress`. That is the same
  rule as dismissal-is-not-completion wearing a different hat: someone who says
  "I'm doing it" has told the assistant where they are, not that they are
  finished, and an app that treats the two as the same quietly loses work.

Completing a step is likewise not completing the task. Packing the documents
does not make the appointment happen. The UI says so in a footer rather than
letting anyone find out the hard way.

Starting routes through `FollowUpService.handle(outcome: .acknowledged, …)` —
the same door every UI button uses — so it records the acknowledgement against
the plan and asks the planner for a check-in. It buys quiet; it does not end
support.

---

## 7. Escalation, adapted and bounded

Escalation now reads dismissals and misses as well as snoozes, because they mean
different things: a dismissal is a person who saw it and chose not to act, a
miss is one who never saw it. The first calls for a different approach, the
second for a louder one.

```swift
pressure = followUpCount + missCount + snoozeCount + dismissalCount * weight
```

Bounded twice: escalation saturates at a maximum level, and there is a daily
intervention budget. Not LLM-driven, and the language never becomes punishing —
the point is to be a mechanism a person can predict, not one that seems to be
losing patience with them.

---

## 8. Tools

Three new ones, all through the existing path: **decode → validate → authorize →
execute**. No provider can modify a recurring schedule directly.

| Tool | What it does | Refuses |
| --- | --- | --- |
| `createRoutine` | Sets up the responsibility; occurrences are generated by the app | Zero or negative interval, weekly with no weekdays, day-of-month outside 1–31, end before start, a `time` that is not `HH:mm`, an unknown frequency |
| `addTaskDependency` | Records that one thing precedes another | Self-dependency at decode; cycles, duplicates and unknown tasks at execution |
| `startTask` | Produces a first step and marks the task in progress | — (it completes nothing, by construction) |

`createTask` also gained `estimatedMinutes` and `preparationSteps`.

Absurd durations are **refused rather than clamped**. Clamping would be
friendlier and worse: a model that says a shower takes six hours has
misunderstood something, and silently rewriting it to two leaves the user with a
plan nobody agreed to. A rejection gets corrected on the next round of the loop.

---

## 9. Offline and deterministic

A hard requirement, and it applies to all of it: occurrence generation, missed
recovery, dependency unblocking, preparation timing, escalation, Today ranking,
follow-up and check-ins. Nothing in this milestone consults a provider.

Two reasons, and both are sufficient on their own. This runs on a cold launch
with no network — a person who is already late does not need the answer to
depend on a round trip. And its behaviour has to be identical every time, or the
assistant becomes something you cannot form a habit around.

The only place a model appears at all is as an *optional* `TaskDecomposer`
behind a protocol, with a deterministic implementation as the default.

---

## 10. Persistence

Schema **V6**, lightweight and purely additive:

- `SDRoutine` — the routine itself, with recurrence decomposed into columns.
- `SDTask` gains `estimatedDuration`, `routineID`, `occurrenceDate`, `dependsOn`,
  `preparationStepsJSON`, `dismissalCount`, `missCount`.

An existing task loads with safe defaults: no routine, no dependencies, no
steps, zero counts. **Nothing is reset** — attempt counts, escalation level,
snooze state and missed-reminder history all survive untouched, which is the
whole point of the migration being additive.

Ordinary tasks are not turned into fake recurring tasks. The old task-level
recurrence columns are dormant rather than deleted; nothing ever wrote them, so
nothing is lost.

Preparation steps are JSON rather than a relationship, following the documented
`SDAction.requestJSON` precedent, so the migration stays inference-safe.

---

## What this deliberately does not do

| Not built | Why |
| --- | --- |
| Live travel-time APIs, GPS, geofencing | Out of scope, and each adds a permission and a failure mode for a number the user can state |
| Behavioural ML that predicts when someone will actually do things | A prediction that is wrong is worse than a policy that is legible |
| Health or medical safety logic | This is not a medical device |
| Cloud sync, collaborative tasks | Nothing here leaves the phone |
| Gamification, streaks, rewards | Rewards for a routine make missing one a punishment, which is the opposite of what someone needs after missing it |
| Always-on background AI | The assistant acts when asked or when its own plan says to, and at no other time |
| Autonomous routine modification | The app never decides on its own that the user's medication is now at ten |

---

## Where to look

| Thing | File |
| --- | --- |
| Recurrence rules and occurrence dates | `Sources/AssistantDomain/Models/Recurrence.swift` |
| The routine and its recovery policy | `Sources/AssistantDomain/Models/Routine.swift` |
| Preparation steps | `Sources/AssistantDomain/Models/PreparationStep.swift` |
| Dependency validation and unblocking | `Sources/AssistantDomain/Models/TaskDependency.swift` |
| Occurrence generation, recovery, skipping | `Sources/ExecutiveSupport/RoutineScheduler.swift` |
| Start and leave times, compression | `Sources/ExecutiveSupport/PreparationTimeline.swift` |
| What to do now | `Sources/ExecutiveSupport/DailyPriorityRanker.swift` |
| Reconciling routines against the clock | `Sources/AssistantCore/RoutineService.swift` |
| "Help me start" | `Sources/AssistantCore/StartSupportService.swift` |
| Schema V6 | `Sources/AssistantPersistenceSwiftData/Schema/PersonalAssistantSchemaV6.swift` |
