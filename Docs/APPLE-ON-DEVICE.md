# Apple on-device AI

Running the assistant on Apple's Foundation Models framework, without the rest
of the app knowing it happened.

## What changed, and what did not

`AppleFoundationModelsProvider` used to be a shape: correct metadata, an
honest `.unsupported`, and a `respond` that threw rather than fabricate. It now
talks to `SystemLanguageModel` through a `LanguageModelSession`.

Nothing above it moved. The engine, the context assembler, memory ranking, the
tool catalogue, the authorizer and the repositories are exactly what the remote
provider finds. That is the whole test of whether the provider abstraction was
real: adding a second working model should be an implementation task, and it
was.

```
ContextAssembler → AssistantEngine → AIProvider
                                       └── AppleFoundationModelsProvider
                                             ├── SystemLanguageModel (availability)
                                             └── LanguageModelSession (generation + tools)
```

## Isolation

Everything Apple-specific is in `Sources/AIProviderApple/`, which depends on
`AssistantDomain` and `AssistantAI` and nothing else. It cannot reach a
repository or a platform service, because those modules are not in its
dependency list.

`import FoundationModels` appears in four files, each behind
`#if canImport(FoundationModels)`. No domain file, no repository protocol, no
engine file imports it, and the package still builds on Windows and Linux where
the framework does not exist.

Two guards are needed and neither is redundant:

| Guard | Answers | Fails when |
| --- | --- | --- |
| `#if canImport(FoundationModels)` | Is the framework in the **SDK**? | Linux, Windows, Xcode older than 26 |
| `if #available(iOS 26, *)` | Is it on **this device**? | An iPhone running iOS 17–25 |

Getting only one right produces a build that either will not compile or will
not launch.

## Deployment target: still iOS 17

Not raised. Foundation Models needs iOS 26, but the app supports iOS 17 and
most of what it does — tasks, reminders, memory, the follow-up engine — has
nothing to do with a language model. Making the whole product iOS 26 to gain one
optional provider would trade most of the addressable devices for a feature
those devices were never going to be able to run.

The consequence is that `FoundationModels` must be **weakly linked**, or dyld
refuses to start the app on every OS older than 26. Xcode does this
automatically when a framework's availability is newer than the deployment
target; CI asserts it rather than trusting it, because the failure is a launch
crash on most supported devices and no amount of `if #available` in Swift
prevents it.

## Availability

Read from `SystemLanguageModel.default.availability` **before every request**,
not once at launch: Apple Intelligence can be switched off and model assets
evicted while the app is running.

Apple's enum is translated immediately into `AppleModelAvailabilityState`, which
imports nothing. That is what makes the mapping testable on a CI runner with no
Apple Intelligence, and it keeps the framework's vocabulary out of the app.

| Apple | App | Shown as |
| --- | --- | --- |
| `.available` | `.available` | Ready |
| `.unavailable(.appleIntelligenceNotEnabled)` | `.configurationRequired` | Setup needed |
| `.unavailable(.modelNotReady)` | `.temporarilyUnavailable` | Unavailable |
| `.unavailable(.deviceNotEligible)` | `.unsupported` | Not available |
| an unrecognised reason | `.unsupported` | Not available |
| framework absent from the SDK | `.unsupported` | Not available |
| OS older than the framework | `.unsupported` | Not available |

Only "Apple Intelligence is off" is `.configurationRequired`, because it is the
only one the person can act on. `UnavailableReason` is not frozen, so a case a
future OS adds **fails closed** — unusable with an honest message, never
mistaken for ready.

Nothing in any of these messages mentions an API key. The on-device model has
never needed one, and sending someone to look for it would send them looking for
something that does not exist.

## Sessions

**One session per request, rebuilt from a `Transcript`, thrown away after.**

`LanguageModelSession` can be kept alive across turns, and for an app whose chat
*is* the session that is the natural design. It is the wrong one here.

`AssistantEngine` already owns the transcript: it assembles messages from the
`ConversationRepository`, trims them to `conversationContextLimit`, and re-sends
the whole list every round. That is the contract every provider is written to. A
long-lived session would hold a second copy of the same conversation, which
would then have to be kept in step through provider switches, relaunches and
context trimming — and the persisted copy is the one that would lose.

So the session is ephemeral infrastructure and the repository is the record.
Nothing Apple-specific is ever persisted; a `Transcript` is built on the way in
and discarded on the way out.

## Context and memory

The Apple provider never queries a repository and never retrieves a memory.

By the time a request reaches it, `MemoryRetrievalService` has already ranked
and selected memories and `SystemPromptBuilder` has rendered them into
`AIRequest.systemPrompt` — the same text, from the same ranking, that the remote
provider receives. The provider's job is to put that text in the session's
instructions.

That is why the camera preference stays out of a scheduling question here for
exactly the reason it stays out everywhere else: the decision was made before
any provider was chosen.

## Tools

The part that had to be got right.

### One adapter, not one per tool

Apple's `Tool` protocol has an associated `Arguments` type, which normally means
a hand-written `@Generable` struct per tool — a second definition of every tool
the catalogue already declares, and exactly the three-sources-of-truth problem
the architecture exists to avoid.

`DynamicGenerationSchema` is the way out. Schemas are built at runtime from the
app's own `JSONSchema`, so `Arguments` can be `GeneratedContent` for every tool
and one adapter type serves the whole registry. Adding a tool to `ToolCatalog`
needs no Apple-specific code at all.

```
ToolCatalog  →  AIToolSchema  →  DynamicGenerationSchema  →  GenerationSchema
                                                                   ↓
                                                  AppleFoundationToolAdapter
```

String formats are folded into property descriptions rather than expressed as
regex constraints, because `ToolRequestDecoder` is what actually parses these
values and a pattern disagreeing with it by one character would reject arguments
the app would have accepted. One parser stays authoritative.

### Proposals, not actions

```
model asks for a tool
      ↓
AppleFoundationToolAdapter.call     ← converts arguments, records, returns
      ↓
AppleFoundationToolCollector        ← an actor, private to this module
      ↓
AIToolCall in the AIResponse
      ↓
AssistantEngine: decode → validate → authorize → confirm → plan → execute
      ↓
mock platform services
```

**The adapter never performs the action.** That is a security boundary, not a
style preference. If `call(arguments:)` created the calendar event, the model's
output would *be* the action, and the tool authorizer, the confirmation rules
for destructive tools and the platform permission checks would all be bypassed
by the one path that most needs them. Hence no EventKit, no AlarmKit, no
UserNotifications, no repositories, and no imports that would make any of them
reachable from that file.

Apple's tool protocol demands a return value, and what it says matters, because
the model keeps reasoning afterwards:

> Received. The app has this request and will check it, ask the person to
> confirm if needed, and carry it out. Nothing has happened yet, so do not tell
> the person it is done — acknowledge that you have passed it on.

Not success, or the model writes "Done — I've set that reminder" to someone
whose reminder does not exist. Not failure either, or it apologises and proposes
the same action again.

### The second round

The provider declares `supportsToolResultContinuation`, so it joins the engine's
existing loop rather than having one of its own. Round two rebuilds the session
with the real outcomes as `Transcript.ToolOutput` entries — including, in as
many words, that the work was simulated — and asks for a closing reply. The
engine's text from round two replaces round one's, so what the user reads
describes what actually happened.

### Unknown tools

The model is offered adapters built from `AIRequest.tools` and nothing else.
There is no name-to-function lookup and no dispatch by string anywhere in the
provider, so there is no mechanism by which a model could name something else
and be obeyed. A tool whose schema fails to translate is dropped rather than
offered broken.

## Errors and refusals

A guardrail refusal is **an answer, not a crash**: it comes back as an ordinary
reply with `stopReason: .refusal`. Declining is a normal outcome of asking a
safety-filtered model something, and no attempt is made to work around it.

Everything else maps to a provider-neutral `AIProviderError`. Apple's errors
carry `Context` objects that can quote the prompt — which is the user's own
words — so only strings written in this codebase are ever surfaced. Context
overflow gets a specific message, because "start a new conversation" is
something the person can act on.

Anything the model proposed before a failure is discarded. A half-finished
generation's tool calls were never reasoned through to a conclusion, and running
them would be acting on an interrupted thought.

## Privacy

Choosing this provider means choosing on-device processing, and the code has to
mean it.

- **No transport, no endpoint, no credential** exists in this module.
- **No silent fallback to the cloud.** If the on-device model cannot answer, the
  request fails. Under the explicit routing policy an unavailable Apple provider
  raises `explicitProviderUnavailable` rather than substituting another one.
- **Logging is category names only**: availability state, tool count, tool name,
  mapped error case. Never a prompt, a memory, a reply or tool arguments.
  `AppleProviderLog` takes only caller-authored strings, because a helper that
  *could* take user text eventually does.

## What CI proves, and what it cannot

Two workflows, and the split matters:

| Job | Runner | Proves |
| --- | --- | --- |
| iOS Simulator Preview | macos-15, Xcode 16.4 | The app builds, launches and renders |
| Apple SDK Check | macos-26, Xcode 26.6 | The Foundation Models code compiles and is weakly linked |

The preview runner's SDK has no FoundationModels, so `canImport` is false there
and every line of this provider compiles out — that job would stay green
whatever this code contained. Hence the second one, which asserts the framework
is in the SDK *before* building and that the binary really references it
afterwards. A green check that verified nothing is worse than a red one.

Neither runs the model. Apple Intelligence inference needs eligible hardware
with the model downloaded, which no CI runner has, and no amount of wanting
changes that.

## What still needs a real device

Marked `TODO-DEVICE` in the source. These are behaviours that compile and are
reasoned about but have never executed:

- A generation actually returning text.
- The model choosing a tool, and the arguments it produces under the runtime
  schema.
- Transcript rehydration across a real multi-round turn — in particular whether
  the framework pairs a `ToolCall` with its `ToolOutput` by the shared id this
  code gives them.
- Which availability case a given device reports.
- Whether a guardrail refusal surfaces as `GenerationError.refusal` or
  `.guardrailViolation` in practice.

The manual scenario worth running first is the milestone's own: enable Apple
Intelligence, select **Apple On-Device**, and ask "remind me tomorrow at 10 AM
to call the dentist". What to watch for is not the reply but the action cards
beneath it — they should say *simulated*, because the platform services are
still mocks and the reminder is not real.
