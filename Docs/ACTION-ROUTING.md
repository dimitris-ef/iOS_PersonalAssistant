# The Metis action system

Part 1: separating phone actions from chat.

---

## 1. The problem this removes

Until this work, "can this app do things to your phone" was a property of
whichever model the user had picked to chat with.

Choose Apple's on-device model, or a 1B local model, or a cloud model without
tool support, and setting a reminder either worked, half-worked, or produced a
confident sentence claiming something had happened. The capability of a
*conversation partner* was deciding whether the *phone* could be operated — and
the user had no way to know that the model picker was also an action switch.

So actions now have their own path and their own model.

---

## 2. The shape

```
user message
  → MetisActionRouter
  ├── CHAT   → ModelRouter → the selected AIProvider → normal reply
  └── ACTION → ActionModelProvider → LocalSemanticAction
               → LocalSemanticActionResolver
               → AIToolCall
               → ToolRequestDecoder → schema validation → provenance
               → ToolAuthorizer → confirmation → PlatformServices
               → ToolResult
```

The action path is **not a second pipeline**. It is the same `AgentRunner` with
a different provider at the front: `ActionTurnProvider` conforms to `AIProvider`
and returns a resolved `AIToolCall`, so decoding, validation, ordering, the
execution ledger, planning, authorization, confirmation, execution, persistence
and summarizing all happen exactly as they did before.

---

## 3. The router

`MetisActionRouter` decides one thing: CHAT or ACTION.

It creates no reminders, touches no calendar, stores no memories, builds no
`AIToolCall`, performs no authorization and parses no semantic action. It
cannot: `decide` takes a `String` and returns an enum, and `MetisActionRouter()`
takes no arguments — `MemoryLayout<MetisActionRouter>.size` is zero, which
`MetisActionRouterTests` asserts. There is nowhere for a repository or a
platform service to live.

### Why phrases and not a model

Asking a model "is this an action?" puts a model in front of the model, doubles
the latency of every message, and makes non-reproducible the one decision that
most needs to be reproducible. A full NLU stack would be a second intent system
to keep in step with the semantic protocol.

So the rules are narrow and deterministic:

1. **Discussion openers veto first.** "How would you schedule a meeting?"
   contains `schedule `, which is otherwise conclusive. A question about the
   feature is not a request for it.
2. **A noun is not a request.** "Reminder", "calendar", "task" and
   "appointment" never appear as positive evidence on their own. "Remind me"
   does; "reminders are useful" does not.
3. **Ambiguity resolves to CHAT.** A message wrongly sent to chat is a worse
   answer. A message wrongly sent to the action system is an action nobody
   asked for. Those are not equally bad.

A question mark is deliberately *not* a veto: "Can you remind me at five?" is a
request phrased politely.

### The families

`reminder`, `memory`, `task`, `calendar` — reported as `ActionRouteMetadata` for
diagnostics and as a hint to the backend and the semantic validator. It does not
choose the intent; the Universal Local Action Protocol still parses and
validates independently, and corrects a wrong guess.

---

## 4. The action-model boundary

```swift
protocol ActionModelProvider: Sendable {
    var id: String { get }
    func availability() async -> ActionModelAvailability
    func generateSemanticAction(
        request: ActionModelRequest
    ) async throws -> LocalSemanticActionResult
}
```

Nothing in it names llama.cpp, GGUF, a chat template, a model family, Apple
Foundation Models or OpenAI. The only contract is a `LocalSemanticAction` —
there is no second semantic format.

### What the action model is shown

`ActionModelRequest` carries the sentence, the clock, the router's category and
the allowed intents. That is the whole struct, and `ActionModelBoundaryTests`
asserts its field set by reflection.

Deliberately absent: the system prompt, the retrieved memories, the
conversation, tool schemas, resource identifiers, EventKit identifiers and
credentials. Every one of those is either a privacy cost or an invitation to
fabricate — a model shown `relatedTaskID` will eventually fill one in.

It is also what makes a small specialised model possible later. A model that
only ever sees a sentence can be small; one that has to read a conversation
cannot.

### Why not a date

`ActionModelRequest.now` exists because a different backend may want it. The
current backend does **not** put it in the prompt: the protocol has no field for
a timestamp and `LocalTimeExpressionResolver` owns the arithmetic, so telling
the model what day it is would be an invitation with nowhere legitimate to go.

---

## 5. The temporary backend

Part 1 ships no new model. `CurrentLocalSemanticActionBackend` is an adapter
over `LocalModelProvider.generateSemanticAction(request:)` — the same runtime,
the same chunked prefill, the same prompt budget, the same parser, the same
validator and the same one-repair policy the chat path uses, asked a much
narrower question.

It is named for what it is (`metis.action.local-semantic`) so a diagnostic line
from this build cannot be mistaken for one from the real Metis Action Model.

---

## 6. Two hard requirements

### The selected chat model no longer gates actions

`ActionRoutingTests.testAChatOnlySelectedModelDoesNotBlockActions`: the chat
provider is Apple's kind, is never invoked at all, and the reminder is still
created.

### No silent fallback

If the router says ACTION and no backend is available, the request is **not**
handed to the chat model. It would answer in fluent sentences describing a
reminder that does not exist, which is the founding failure of this whole app
with better grammar.

Instead the user is told, concisely, and the turn is recorded in the
conversation like any other:

> I can't perform phone actions right now because the action system is
> unavailable.

`testAnUnavailableActionBackendFailsSafely` asserts all four halves: the chat
model was not invoked, nothing was interpreted, no tool ran, and the message is
that sentence.

---

## 7. Two registries, on purpose

`AIProviderRegistry` holds what the *user* picked to talk to. Changing it is a
preference. `ActionModelRegistry` holds what the *app* uses to interpret
actions, and the user does not choose it.

One registry would put them back together, which is the coupling this work
exists to remove.

---

## 8. Diagnostics

Four events, into the existing Local AI diagnostic log through
`LocalActionSystemDiagnostics`:

| Event | Says |
| --- | --- |
| `ROUTER_DECISION` | chat/action, the family, the evidence |
| `ACTION_BACKEND` | which backend, available or not, and why not |
| `SEMANTIC_ACTION_PROCESSING_STARTED` | the backend is interpreting |
| `ACTION_BACKEND_FAILURE` | a structured reason category |

Two closed vocabularies in series — `ActionSystemDiagnosticEvent`, whose cases
carry only symbols, into `LocalInferenceMetadata`, whose keys are an enum with
nothing that could hold a sentence. The user's message has no route through
either, which `testDiagnosticsCarryNoUserText` checks with a marker string.

---

## 9. Where the semantic protocol lives now

It moved from `AIProviderLocal` to `AssistantAI`. It was always provider-neutral
by design; it now has to be visible to `AssistantCore` without the core
depending on one provider's implementation, which is what "not tied to llama.cpp
or GGUF" means at the package level.

Nothing about it changed except the target — plus two new
`LocalActionCategory` cases the router reports. The `Local` prefix is
historical.

---

## 10. Not done in Part 1

Architecture only, by instruction. No tiny Metis Action Model, no training, no
LoRA, no dataset, no distillation, no Core ML conversion, no constrained
decoding, no custom tokenizer, no benchmark suite, and no download or selection
UI for the final model.

Also still open from the previous pass: calendar-event lookup is not wired in
the composition root, because `PlatformServices` sits above `AIProviderLocal`.
`calendar.update` therefore asks which event was meant rather than resolving
one.
