# Architecture

Companion to the README. This records *why* the pieces are shaped the way they
are, so the reasoning does not have to be reconstructed later.

## The two layers

**Core** (`Sources/`) is plain Swift, buildable anywhere, and holds as much of
the product as possible. **iOS** (`iOS/`) holds SwiftUI and the Apple
frameworks, and is not part of the Swift package.

The split is not a portability strategy — the product is a native iOS app and
will stay one. It exists so that (a) the assistant's logic is testable without a
phone, and (b) development can proceed on Windows without pretending the Apple
work is done.

Every boundary between the two is a protocol the core owns. The iOS layer
implements those protocols; it never defines new vocabulary the core has to
learn.

## Module graph

```
                     AssistantDomain
                    /    |     |    \
        AssistantAI  Tools  Platform  Persistence   ExecutiveSupport
              \        |       |         /            /
                     AssistantCore  ─────────────────
                       /        \
              MockPlatform    AssistantPlatformApple

  AIProviderApple ┐
  AIProviderRemote├── depend on AssistantDomain + AssistantAI only
  AIProviderLocal ┘   (Local also uses AssistantPersistence, for the rows
                       describing which model files are installed)

  AIProviderLocalLlama ── the only target that imports llama.cpp
```

Two properties are load-bearing:

- **`AssistantDomain` depends on nothing.** Enums like `ToolKind` and
  `TaskStatus` live there rather than in the modules that act on them, so
  settings can reference a tool without the domain depending on the tool system.
- **Providers cannot reach the platform.** A provider's dependency list
  contains no platform module and no tool implementation, so it cannot call
  `EventKit`, `UserNotifications` or `AlarmKit` even by accident. This is what
  makes the Apple provider's tool adapter safe by construction — and the local
  model's, which is the same argument applied to a model running inside the
  process: it *cannot*
  create a calendar event, because EventKit is not reachable from where it
  lives.

Apple's Foundation Models is now a real implementation behind that boundary —
`import FoundationModels` appears only in `AIProviderApple`, always behind
`#if canImport`, so the package still builds where the framework does not
exist. See [`APPLE-ON-DEVICE.md`](APPLE-ON-DEVICE.md).

## The turn pipeline

`AssistantEngine.send(_:in:)`:

1. Append the user message and persist it.
2. Assemble `AssistantContext` — profile, relevant memories, outstanding tasks,
   upcoming events, settings.
3. `ModelRouter` selects a provider from settings.
4. `SystemPromptBuilder` renders the context into a system prompt, message list
   and tool schemas. This is the *only* thing a provider is shown.
5. `AgentRunner` runs steps 6–9 as a bounded loop, up to `AgentLimits`.
6. The provider returns text plus `AIToolCall`s.
7. `ToolRequestDecoder` types and validates each call; failures are rejected.
8. `DefaultActionPlanner` builds the plan and expands reminder support.
9. `DefaultToolExecutor` runs the authorized actions, one at a time.
10. The results go back to the provider and the loop repeats, until the model
    stops asking for tools or a limit is reached.
11. The assistant message and results are persisted.

Steps 7–9 are three separate types on purpose: decoding, deciding and doing fail
for different reasons and change for different reasons.

### Several rounds, one turn

One user message can need several coordinated actions, and the model has to be
able to see what each one really did before choosing the next. `AgentRunner`
owns that loop — in the application, never in a provider, because a provider
running the loop would be a provider executing tools.

Each round is untrusted output again: a call proposed in round six is decoded,
validated, authorized and permission-checked exactly as one in round one.
Nothing executes twice, because `ToolExecutionLedger` claims each call by id and
by content fingerprint before it can run. When the model cannot write the
closing reply — the provider failed, or the ceiling was reached —
`TurnSummarizer` writes a truthful one from the results rather than letting a
sentence composed before the results stand as the answer.

See [`Docs/AGENT.md`](AGENT.md).

### Why the plan is a value

`AssistantActionPlan` is produced before anything executes. That makes it
possible to show the user what is about to happen, hold back the parts that need
approval, and assert on the whole thing in a test with no side effects.

## Security boundary

The model proposes structured requests. It never gets an API surface.

```
AIToolCall (untyped JSON)
  → ToolRequestDecoder      types it, or throws
  → validation              cross-field checks a schema cannot express
  → ToolAuthorizing         allowed / requiresConfirmation / denied
  → PermissionService       does the OS even allow this?
  → PlatformService         the only code that causes an effect
  → ToolResult              what actually happened, honestly
```

Four consequences worth stating explicitly:

- An unrecognised tool name is dropped. There is no fallback to prose parsing.
- Destructive tools (`deleteCalendarEvent`, `updateCalendarEvent`,
  `cancelAlarm`) default to `requiresConfirmation`.
- `completeTask` refuses to close a task unless `confirmedByUser` is true. A
  model inferring that something is probably done cannot close it.
- The executor re-checks authorization rather than trusting the plan it was
  handed.
- A successful action grants the next one nothing. Every round of a multi-round
  turn goes through this pipeline from the top, so a model that creates a
  reminder and then asks to delete a calendar gets the deletion evaluated on its
  own terms — which, for a destructive tool, means it waits for the user.

## Honesty about what ran

Every platform service declares a `PlatformFidelity`: `.live` or `.simulated`.
Mocks report `.simulated`, the Apple services in `AssistantPlatformApple`
report `.live`, and the value propagates into `ToolOutcome` as
`.simulated(platform:)` or `.executed`.

This is why there is no `Bool` called `isMock` anywhere: the fidelity has to
travel with the result, not be a property of the environment that callers might
forget to consult. It is also why the action cards under an assistant reply
stopped saying *simulated* the moment the real services were wired in, with no
change to any view — the honesty was already plumbed through, waiting for
something true to report.

The one service that reports `.simulated` while never simulating anything is
`UnavailableAlarmService`, used where AlarmKit does not exist. It produces no
receipts at all, because every method throws; the fidelity value exists only so
`PlatformServices.isFullyLive` stays truthful. See
[PLATFORM-APPLE.md](PLATFORM-APPLE.md).

## Executive-function support

This is application logic, not prompt text. A model that changes should not
change how the user is supported.

### Reminder plans

A `ReminderSubject` (what, when, how important, how long to prepare, how far to
travel, fixed or flexible) goes to a `SupportPlanner`, which returns a
`ReminderPlan`: a list of `ReminderStage`s plus follow-up, snooze and completion
policies.

`DefaultSupportPlanner` produces, for a fixed appointment:

```
advance notice (N days before, at the morning time)
morning of
preparation      (travel + getting-ready time before the anchor)
leave            (travel time before the anchor)
final call
```

and for flexible work with only a deadline, spread-out nudges plus a last call.

Nothing about that shape is hardcoded. Every lead time, the morning-of hour, the
advance-notice days, the escalation defaults and the policies come from
`SupportPreferences` in `AssistantSettings`. `SupportPlanner` is a protocol, so a
planner that adapts to the individual — or one driven by a model — replaces it
without touching anything downstream.

`ReminderScheduleResolver` then turns relative stages into dated
`ScheduledReminder`s, drops any that are already past, and pushes non-urgent
ones out of quiet hours (alarm-level stages are exempt — that is the point of an
alarm).

### Task status

One enum, `TaskStatus`, covering `notStarted`, `reminded`, `snoozed`,
`inProgress`, `completed`, `missed`, `needsFollowUp`, `cancelled`.

`TaskStatusMachine` is pure and synchronous. Its rules:

- **A dismissal is not a completion.** With `requiresExplicitConfirmation` set,
  dismissing moves a task to `needsFollowUp` and schedules a check-back.
- Snoozing is counted, and raises escalation past a threshold. Running out of
  snoozes forces an alarm rather than letting the task quietly die.
- An anchor passing without confirmation means `missed`, not silence.
- Only `confirmedComplete` completes anything.
- Follow-ups stop at a configured maximum, so the app does not nag forever.

Being pure means whatever eventually drives it on iOS — a notification response,
a background task, an App Intent — only has to feed it events.

## Memory

Four distinct stores, deliberately not merged:

| Store | Holds | Lifetime |
| --- | --- | --- |
| `ConversationRepository` | Messages | Per thread |
| `MemoryRepository` | Routines, preferences, people, commitments | Long-term |
| `TaskRepository` | What needs doing, and its state | Until done |
| `SettingsRepository` / `UserProfileRepository` | How the assistant behaves, who it works for | Persistent |

A provider is given a selection from these as rendered context. It never holds
them, which is the mechanism behind the provider-swap guarantee.

Which memories make it into that selection is decided locally by `MemoryRanker`
— meaning, wording, salience, confidence, source, category and recency, bounded
by a count and a character budget. No model is asked what to recall. See
[`MEMORY.md`](MEMORY.md).

Meaning comes from `SemanticEncoder`, which is deliberately **not** the selected
AI provider: using the conversational model to index memories would mean
uploading the user's entire store to search it, and would make recall depend on
which model happened to be chosen. Apple's on-device sentence encoder where the
device has one, the app's own lexicon encoder everywhere else, and lexical
ranking if both fail — memory never stops working because encoding did.
Repeated facts are consolidated, contradictions are held as state, and low-value
memories fade rather than being deleted. See
[`SEMANTIC-MEMORY.md`](SEMANTIC-MEMORY.md).

`UserProfile` is separate from `MemoryItem` because a few facts — preparation
time, wake time, quiet hours — are read directly by planning code and need to be
structured, while memory is open-ended text.

## Persistence

Repositories are protocols, and there are two implementations of each.

The **iOS app runs on SwiftData**, on disk, through
`AssistantRepositories.persistent(...)`. The domain models are not SwiftData
models; separate `SD*` entities and explicit mappers sit behind the same
repository protocols. See [`PERSISTENCE.md`](PERSISTENCE.md).

The **snapshot implementations** keep a working set in memory and write a JSON
snapshot through a `SnapshotStore` after each change. `SnapshotStore` is
intentionally dumb (`read(key:)` / `write(_:key:)`). They remain the right
choice for tests, previews, the dev harness and fixtures —
`AssistantRepositories.ephemeral()` is not deprecated, it is just not what
ships.

Having two backends is what keeps the abstraction honest: parity tests hold both
to the same behaviour, so swapping storage really is a substitution at
composition time rather than a rewrite.

No credentials go through either. API keys come from a `CredentialProvider`,
Keychain-backed on iOS, and never enter the database.

## Follow-up

`TaskStatusMachine` decides what an engagement event means; `SupportPlanner`
decides what to do about it; `FollowUpCoordinator` runs the two in the right
order and `FollowUpService` persists the result and calls the platform layer.
A reminder being dismissed, snoozed or ignored never ends support — only a
terminal task status does. See [`FOLLOW-UP.md`](FOLLOW-UP.md).

## Executive support

Repeating things, order between things, getting ready for things, and starting
them.

The design decision the rest follows from: **a routine occurrence is an ordinary
`TaskItem`**, carrying `routineID` and `occurrenceDate`. This morning's
medication therefore gets the existing status machine, reminder plan,
escalation, Today list and follow-up, with no branch anywhere asking whether a
task repeats. `Routine` holds the rule; `RoutineScheduler` decides which
occurrences exist and whether a late one is still worth doing;
`PreparationPlanner` turns "work starts at four" into "start getting ready at
2:35"; `DailyPriorityRanker` answers what to do now, in one place rather than in
a view.

None of it consults a model. Occurrence generation, recovery, unblocking,
preparation timing, escalation and ranking are deterministic and work with no
network — a person who is already late does not need the answer to depend on a
round trip. See [`EXECUTIVE-SUPPORT.md`](EXECUTIVE-SUPPORT.md).

## Extension points

Each of these is an implementation task, not a redesign:

| To add | Implement | Nothing else changes |
| --- | --- | --- |
| A downloaded local model | `LocalModelRuntime` | Provider, catalog, settings |
| Another API vendor | `RemoteAPIAdapter` | Provider, transport, engine |
| EventKit / AlarmKit / notifications | The four platform protocols | Executor, planner, engine |
| App Intents / Siri | Build a `ToolRequest`, hand it to the executor | Authorization, execution |
| Widgets | Read the repositories | Everything else |
| A different reminder strategy | `SupportPlanner` | Planner, executor, engine |
| A different store | `SnapshotStore` | Repositories, engine |

## Things deliberately not built

- A multi-agent framework. One provider call per turn.
- A local inference runtime. Choosing one now would be the hardest decision to
  reverse.
- A cloud backend, accounts, sync or billing.
- Any Apple framework integration.
- Automation execution. `ToolKind` and the plan model leave room for it; nothing
  runs on a trigger yet.
