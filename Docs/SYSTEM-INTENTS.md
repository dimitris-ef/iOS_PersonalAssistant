# Siri, Shortcuts and the Action Button

App Intents, over the architecture that was already there.

## The shape

```
Siri / Shortcuts / Action Button
        ↓
    AppIntent            ← iOS/Intents/, ~30 lines each
        ↓
AssistantCommandService  ← Sources/AssistantCore/, the bridge
        ↓
AssistantEngine · MemoryService · FollowUpService · repositories
        ↓
memory · provider routing · validation · authorization · SupportPlanner
        ↓
persistence · PlatformServices
```

There is no `SiriAssistantEngine`. Every intent collects parameters, calls one
method on the command service, and turns the outcome into a sentence.

## Two routes, on purpose

The milestone's sharpest distinction, and the one that decides whether this
feature is cheap or wasteful:

| Route | Intent | Model involved? |
| --- | --- | --- |
| **Natural language** | `AskAssistantIntent` | **Yes** — the whole pipeline |
| **Structured** | `CreateTaskIntent`, `StoreMemoryIntent`, `MarkTaskCompleteIntent`, `ShowTodayIntent` | **No** |

A Shortcuts action called "Add a Task" with a title and a due date has nothing
left to interpret. Sending it to a language model to be turned back into the
`createTask` call it already is would cost latency, money and a failure mode for
no gain — and would make adding a task depend on network, credentials and model
availability.

What the structured route must **not** skip is everything *after*
interpretation. `AssistantEngine.perform(_:origin:)` runs the request through
the engine's **own** planner and executor — the same instances `send` uses — so
authorization, support expansion, reminder-plan generation, persistence and
platform routing all happen exactly as they would for a call a model made. The
only thing missing is the model.

That is why a task created from Shortcuts still gets a `ReminderPlan` and is
still chased when you ignore it.

## Ask reaches the real assistant

`AskAssistantIntent` calls `AssistantEngine.send` — the same method the composer
and the voice coordinator call. Context assembly, memory ranking, provider
routing, tool decoding, validation, authorization, planning and execution all
follow, because it is the same function.

So this works, and works the long way round:

```
"Set an alarm for tomorrow at 7" (Siri)
  → AskAssistantIntent → AssistantEngine → provider → CreateAlarm AIToolCall
  → decode → validate → authorize → SupportPlanner → AlarmKitAlarmService
```

The intent never parses "7". It never touches AlarmKit. It cannot: the command
service is the only dependency it has.

## What the intents cannot reach

`iOS/Intents/` types are given exactly one thing — `AssistantCommandService`.
Not a repository, not `PlatformServices`, not a `ModelContext`, not a provider.
The absence is the enforcement:

| Forbidden | Why it is impossible |
| --- | --- |
| `modelContext.insert(…)` | No context is passed to an intent |
| EventKit / AlarmKit / UserNotifications | Reached only via `ToolExecutor` |
| `RemoteAIProvider`, `AppleFoundationModelsProvider` | Reached only via the registry, through the engine |
| A second database | See below |

## One composition, one database

`AppIntentDependencies` calls `AppEnvironment.makePersistent()` — the same
function `PersonalAssistantApp.init` calls. Not a copy, not a slimmer variant.

The subtlety is lifetime. An intent can run when the app is not open: Siri wakes
the process, calls `perform()`, and there is no `WindowGroup`, no `RootView`, no
`AppModel`. So the environment is built on demand and cached per process. And
when the app *is* running, `PersonalAssistantApp.init` hands its environment
over via `adopt(_:)` — without that, launching the app and then running an
intent would open a **second `ModelContainer` over the same file**, which is the
concurrency mistake SwiftData is least forgiving about.

A task created by Siri is in the store the app opens because it is the store the
app opens.

## Today comes from data, not from a model

`ShowTodayIntent` consults no provider. The repositories know exactly what is on
today; routing that through a language model would make a lookup the app can
always do depend on three things that can fail.

The selection rules — which tasks count as today's, which reminder stages are
worth showing, what "has passed" means — moved out of `TodayPresenter` (which
lives in `iOS/`, where no test can reach it) into `TodayBriefing` in the
package. An intent needing the same answer would otherwise have meant a second
copy, and two definitions of "what is on today" drift the first time either is
touched.

Preparation and leave stages are included, because they are the assistant's own
additions to the day and the reason this is not just a calendar. Advance notices
and morning-of heads-ups are not: they are the assistant talking, and a briefing
padded with them buries the two lines that matter.

## Completion goes through the lifecycle

`MarkTaskCompleteIntent` calls `FollowUpService.handle(outcome: .completed …)` —
the same door the app's Done button and the notification action use. That is
what cancels the reminders still waiting.

An intent that set `status = .completed` itself would leave the user being
chased about something they had just told Siri they had finished: the exact
failure this product exists to prevent, arriving through a new door.

**Already-resolved tasks are reported truthfully**, not re-completed. A retried
Shortcut says "that was already done" rather than claiming to have just done it,
and a cancelled task is not reopened.

## The task entity is a projection

`TaskEntity` carries the domain id verbatim, so there is one identity for a task
across the app, the notification layer, the voice layer and the system. Minting a
second id for Siri would create two names for one thing and a table to keep them
married.

It is deliberately thin — title and due date. Importance, snooze counts,
follow-up history and reminder plans are the assistant's working notes and have
no business being handed to the system. The query offers **outstanding tasks
only**: a picker of things you already finished, to finish again, is not useful.

## App Shortcuts and the Action Button

`AssistantAppShortcuts` exposes all five intents with phrases. Everything there
appears in the Shortcuts app automatically, is offered to Siri, and — on an
iPhone with an Action Button — becomes assignable under **Settings → Action
Button → Shortcut**.

Every phrase contains `\(.applicationName)`, which App Intents requires and
which also means renaming or localising the app does not break them. Two or
three phrasings each: enough to cover how people speak, few enough to stay
distinguishable.

**Ask** is listed first deliberately — the system treats the leading shortcut as
the headline one, and "ask it anything" is both the most useful Action Button
assignment and the best single representation of the app.

The app does not, and cannot, configure the Action Button itself. iOS owns that
choice; providing good shortcuts is the whole of the app's side of it.

### Setting it up on a device

1. **Settings → Action Button**
2. Scroll to **Shortcut**
3. Tap **Choose a Shortcut**
4. Pick **Ask** under Personal Assistant

Then press and hold the Action Button.

## Failure is reported, never papered over

Every intent goes through `AssistantIntentRunner`, so no raw error reaches a
system surface — a `RepositoryError` or an EventKit `NSError` would otherwise be
read aloud verbatim, and some of them quote user data.

| Situation | What Siri says |
| --- | --- |
| Selected provider unavailable | "The selected AI model isn't available right now…" |
| Calendar permission denied | "I couldn't do that because calendar access is turned off." |
| Task not found | "I couldn't find that." |
| Needs confirmation | "That needs confirming in the app first." |
| Empty parameter | "A task needs a title." |

**No silent provider substitution.** Under `.explicit` routing an unavailable
provider is reported, not worked around — answering with a different model than
the one someone chose is what that policy exists to prevent. The provider
identifier is deliberately *not* read out: "apple.foundation-models" means
nothing to someone talking to Siri.

**Success is only claimed after it happened.** `createTask` re-reads the
repository before saying the task was added; reporting from the fact that a plan
was made would announce a task a failed write had thrown away.

## Conversation history

Questions asked through Siri are ordinary conversation, persisted like any
other, and visible in the app afterwards. Hidden system-only history would mean
the assistant remembered a conversation the user could not find.

Repeated questions continue the most recent conversation rather than starting a
new one each time — otherwise a week of Siri questions becomes a week of
one-message conversations.

Structured intents log nothing to the conversation. The task or memory they
created is the record; a fabricated chat message saying "I created a task" would
be the app talking to itself.

## What CI proves, and what it cannot

| Job | Proves |
| --- | --- |
| Swift Tests | Every command path: routing, tool pipeline, reminder plans, duplicate memories, completion cancelling follow-ups, truthful failures |
| Apple SDK Check | The intents, the entity, the query and the shortcuts provider compile against the real App Intents SDK |
| iOS Simulator Preview | The app still builds, launches and renders |

CI needs no Siri, no Shortcuts runtime, no Action Button hardware, no AI
credentials and no granted permissions. No workflow invokes Siri.

The compiler is doing more work here than usual: App Intents metadata errors —
a malformed `ParameterSummary`, a phrase missing `\(.applicationName)`, an
entity without a query — are compile-time failures, so a green Apple SDK Check
is meaningful validation of the definitions.

## What still needs a real device

Marked `TODO-DEVICE`.

- Siri discovering the app's shortcuts at all, and how long after install.
- Whether the invocation phrases are recognised as written.
- Shortcuts app discovery, and whether the parameter prompts read well.
- Action Button assignment and invocation.
- Whether `openAppWhenRun = false` really lets each intent complete in the
  background, and what the system's time limit turns out to be in practice.
- Provider availability during system invocation — in particular whether the
  Keychain is readable and Apple Intelligence is usable when Siri woke the
  process rather than the user.
- Whether `AppIntentDependencies` opening the store from a background launch
  behaves as it does from a foreground one.

The first scenario worth running: ask Siri to add a task, then open the app. The
task should already be there, with a reminder plan, indistinguishable from one
typed in.
