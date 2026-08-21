# The agent loop

How one message becomes several coordinated actions without the assistant ever
being able to lie about them.

## The sentence this exists for

> I have an appointment Friday at 10, remind me beforehand, make sure I leave on
> time, and tell me to bring my documents.

Four objectives, one message. Answering it needs the assistant to act, look at
what happened, and act again — and it needs the answer at the end to describe
what really occurred rather than what was planned.

## The shape

```
user message
    ↓
AssistantEngine.send
    ↓
AgentRunner.run ──── round 1 ─── ask provider
                                     ↓
                                 tool calls
                                     ↓
                                 decode + validate      ← every round
                                     ↓
                                 duplicate check        ← the ledger
                                     ↓
                                 dependency order
                                     ↓
                                 plan (authorize + SupportPlanner)
                                     ↓
                                 execute, action by action, with bounded retry
                                     ↓
                                 AIToolResult per call
                                     ↓
                     round 2 ─── ask provider, now with the results
                                     ↓
                                   … up to 6 rounds …
                                     ↓
                                 final reply
```

The loop is in `Sources/AssistantCore/AgentRunner.swift`. It is **not** in any
provider, and the reason is not tidiness: a provider that ran the loop would be
a provider that executes tools, and every safety property in this codebase rests
on providers being unable to do anything but generate.

## What each round is allowed to assume

Nothing. A tool call proposed in round 6 goes through decoding, validation,
settings authorization, confirmation policy and the operating system's
permission gate exactly as one proposed in round 1 would. Succeeding once buys a
model no standing at all — if it creates a reminder and then asks to delete a
calendar, the deletion is evaluated on its own terms, which for a destructive
tool means it stops and waits for the user.

`AgentLoopTests.testEveryRoundIsValidatedAndAuthorizedIndependently` is that
rule as a test.

## The bounds

`AgentLimits`, one value, all of them together:

| Limit | Default | What it stops |
|---|---|---|
| `maximumRounds` | 6 | model → tool → model → tool, forever |
| `maximumToolCallsPerRound` | 8 | one response asking for a hundred things |
| `maximumToolCallsPerTurn` | 24 | eight things in each of six rounds |
| `maximumToolRetries` | 1 | retrying a broken service until the app is unusable |
| `repeatedProposalLimit` | 3 | a model that keeps proposing what it already did |

Hitting a bound is never silence. Each produces an `AgentStopReason`, and the
reply the user gets says the request did not finish cleanly while everything
that *did* happen stays done.

## Nothing happens twice

`ToolExecutionLedger` is the only reason it is safe for any of the above to
exist. Retries, replays and repeated proposals all create the same danger: two
dentist appointments in a real calendar, which is the user's problem to clean up
rather than the app's.

Two identities, checked in that order:

1. **The call id** the provider gave. Exact, when the provider behaves.
2. **The fingerprint** — `ToolFingerprint`, a hash of the *typed, decoded*
   request plus the conversation and turn. This is what catches a call reissued
   with a fresh id during a retry.

Fingerprinting the decoded request rather than the raw JSON is what makes the
comparison meaningful: field order, whitespace, number spelling and date
formatting have all normalised away by then. Comparing argument strings would
fail on all four.

An action already done returns its original result, marked
`wasAlreadyPerformed`, and the model is told in as many words that this is the
first result rather than a second execution. An action still running is not
started again.

The scope includes the turn, deliberately. "Remind me to call the dentist"
tomorrow is a new request, not a duplicate.

## Order, and what happens when something upstream fails

`ToolDependencyResolver` reads the identifiers: a call that mentions a task id
another call creates is ordered after it. If the producer fails, the dependent
is **skipped** — `dependencyFailed` — rather than run against an id that was
never created.

Support reminders the app adds itself are treated more carefully than that. When
a calendar write is refused but the appointment time is known, the reminders
still get set: they are notifications keyed to a clock, not to the event. When a
*task* fails to save, its reminders are skipped, because they point at a task id
and their Done button would do nothing.

## Failure has kinds

`ToolFailureCategory` — eleven of them, in `AssistantDomain`, beside `ToolKind`
because they are product vocabulary. Each has a `recovery` (recoverable,
requiresUserInput, terminal) and an `isAutomaticallyRetryable`.

The two questions the taxonomy answers:

- **May the app try again by itself?** Only `temporaryFailure` and
  `networkFailure`. Never a permission denial, a validation failure or an
  authorization denial — retrying those produces the same answer, and in the
  permission case it means pestering someone about a decision they have made.
- **What can the model do about it?** A denied calendar means explain and carry
  on with the rest. A missing task means try something else. A refused
  authorization means stop asking.

## Truth

Three rules, and the whole milestone is really about these:

1. **Results reflect reality.** A failed EventKit save is `failed`, never
   `success`. A mock service is `simulated`, and the model is told in words that
   nothing was scheduled on the device.
2. **A partial success is a partial success.** `AgentTurnStatus` has
   `partialSuccess` because a turn where the calendar was refused and the task
   was created is neither a success nor a failure, and an application with only
   two words for it would have to lie in one direction.
3. **The model's words are used only when the model saw the results.** If it
   never got a closing round — the provider failed, the ceiling was hit — its
   last remark was written *before* the results existed and may describe a
   success that did not happen. `TurnSummarizer` writes the reply instead, from
   the results, with no second model call.

## Clarification

`askClarification` is a tool, because a tool call is the only structured channel
a model has, and the alternative is parsing prose for question marks.

It is the one tool the application never executes. When it appears, the turn
ends with `AgentTurnStatus.requiresClarification`, the question becomes the
assistant's message, and **nothing else proposed in that round is carried out** —
moving one of two possible appointments and then asking which one was meant is
the exact failure the question exists to prevent.

Resuming needs no machinery. The question is in the transcript, so the user's
answer arrives in a conversation that still contains what was asked.

The harder half is not asking. Left alone a model asks about everything — how
long before, whether to follow up, how insistent to be — and every question is a
step someone with a depleted executive function has to climb. Those all have
defaults, and the `SupportPlanner` owns them. Both the tool's own description and
the system prompt say so.

## What is not stored

No chain-of-thought. `AgentDiagnostics` is shaped so there is nowhere to put it:
round numbers, provider ids, tool names, statuses, failure categories, counts.
`ConsoleAgentLogger` in `DevSupport` can print all of it and still reveal
nothing about the person using the app. The production composition logs nothing
at all.

## What the providers had to do

Nothing, in the end. `RemoteAIProvider` already parsed several tool calls and
correlated ids; it gained one thing — rendering `AIToolResult` as compact JSON
rather than a sentence, which is this protocol's own shape and a mapping that
belongs in the adapter. `AppleFoundationModelsProvider` already mapped tool
calls and outputs into a `Transcript`.

That is the dependency direction working. The engine changed; the providers,
which know nothing about rounds or ledgers or dependencies, did not have to.

## Where it applies

Everything that reaches `AssistantEngine.send`: typed messages, Part 5 voice,
and Part 6's `AskAssistantIntent`. There is no separate multi-step path for Siri
or for speech.

Direct App Intents — "Add a Task" with a title and a date — still go through
`engine.perform`, which runs the planner and executor with no model involved.
Making a structured request agentic would cost latency and accuracy for nothing.
`perform` takes an optional `idempotencyKey` so a callback delivered twice
executes once.
