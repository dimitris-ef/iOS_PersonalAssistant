# Problems and fixes

One entry per problem. Status: **open**, **fixed (build N)**, or
**fixed, not shipped**.

---

## P1 — App crashed on launch after updating (build 16)

- **Owner saw:** build 16 closed immediately on opening, for everyone who
  already had the app.
- **Plain cause:** the app's database changed shape, and the step that upgrades
  an old database could not tell the old shape from the new one, so it gave up.
- **Technical:** SwiftData identifies a store's version by a checksum of its
  model classes. Every `VersionedSchema` listed the same live classes, so V9
  and V10 computed identical checksums; the staged migration validated the
  plan, found duplicates, and trapped. Fix: V9 holds a frozen copy of the
  class V10 changed; the plan lists only V9 → V10. `StoreUpgradeTests` writes
  a real V9 store and opens it. Full write-up: `Docs/PERSISTENCE.md`,
  "The build 16 crash".
- **Status:** fixed (build 17).

## P2 — Metis Action answered worse with the instruction page

- **Plain cause:** the model was trained on bare sentences; the app was also
  sending it a page of rules it had never seen, which confused it.
- **Technical:** 73% right action with the protocol page vs 85% without, and
  2.5× faster. Purpose `.metisAction` now gets the bare sentence.
  `Docs/ACTION-ROUTING.md` §12.
- **Status:** fixed (build 17).

## P3 — Downloaded Metis Action did not show when choosing models (build 17)

- **Owner saw:** downloaded the 0.8B Metis model; it did not show when they
  went to select models.
- **Plain cause:** it is deliberately not a chat model, so it never appears in
  the chat list. It could only be chosen on an "Action Model" screen — and the
  app's own hint pointed to "Settings → AI Model → Action Model", but the AI
  Model screen had no such entry.
- **Fix:** "Use for Actions" button and a bolt tick on its row in Manage Models;
  chosen automatically after download if no action model is set
  (`ActionModelHost.adoptIfNoneSelected`); Action Model link on the AI Model
  screen; the chat menu names the action model.
- **Status:** fixed (build 18).

## P4 — Crash the moment a message was sent (build 18)

- **Owner saw:** typed in chat, pressed send, the app closed.
- **Plain cause:** while the action model wrote its answer, the app counted
  each word twice. The second count broke the rules that keep the answer a
  valid action, and the AI engine stopped the whole app.
- **Technical:** `LlamaCppRuntime.generate` called `llama_sampler_accept`
  after `llama_sampler_sample`, which (b10506) already accepts. Under a grammar
  the token was accepted twice, the grammar stack emptied, and llama.cpp threw
  `std::runtime_error` across the C boundary → abort. The bug existed since
  grammar actions were added; build 18 made it reachable by switching Metis
  Action on automatically. Removed the second accept.
- **Status:** fixed (build 20). Confirmed on the phone.

## P5 — Reply said "1 action completed: createReminder"

- **Owner saw:** an internal name instead of words.
- **Fix:** `ToolKind.plainAction` / `plainActionDone`; the summary now reads
  "Done: added a reminder."
- **Status:** fixed (build 21), awaiting device confirmation.

## P6 — "That conversation is too long for the on-device model" (build 20)

- **Owner saw:** after a few messages the chat refused to answer and said to
  start a new conversation — but the app had no way to start one.
- **Plain cause:** Apple's on-device model can only read a short amount of text
  at once (about 4,000 tokens). The app sent it the whole chat every time, so
  the chat soon became too long for it.
- **Fix:** only the most recent messages that fit are sent to Apple's model
  (older ones stay saved, just not re-read); and multiple chats with a New Chat
  button.
- **Status:** fixed (build 21), awaiting device confirmation.

## P7 — "Move the dentist appointment" could not find it (build 21)

- **Owner saw:** Quick Task "I have to go to the dentist, 18th of November,
  6 p.m." added the appointment correctly. Then "move the dentist appointment
  I have to 15th of November, 5 p.m." answered that it couldn't find it.
- **Plain cause:** to change an existing appointment the app has to look it up
  in the calendar first, and that lookup had never been connected — the app
  could look up tasks, but not calendar events. So the answer was always
  "couldn't find". The matching was also too strict: the request said more
  words ("dentist appointment I have") than the event's title.
- **Technical:** `AppEnvironment` built `LocalSemanticResources` with only the
  task closure; `events` defaulted to `{ _ in .none }` (a known open item).
  Now `LocalSemanticResources.events(listing:)` matches against
  `services.calendar.events(in:)` from yesterday to a year ahead.
  `LocalDescriptionMatching.matches` also accepts the title's words being a
  subset of the description's ("Dentist" ⊂ "the dentist appointment I have");
  "Dentist bill" still does not match "dentist appointment".
- **Status:** fixed (build 24), awaiting device confirmation.

## P8 — "Conversation too long" even in a brand-new chat (build 21)

- **Owner saw:** in a new chat, "move the dentist appointment to 15 November,
  5 p.m." answered that the conversation was too long.
- **Plain cause, two parts:**
  1. The app only recognised "move **my** appointment", not "move **the**
     appointment", so the sentence went to the chat model (Apple's) instead
     of Metis Action.
  2. Every message to Apple's model also carries the descriptions of all 19 of
     the app's tools, plus open tasks and upcoming events. Together that is
     more than Apple's whole 4,096-token window, so even a new chat could not
     fit. Build 21 only trimmed old messages, which could not help.
- **Technical:** `LocalActionIntent.calendarChangePhrases` gains "move the",
  "reschedule", "postpone", "cancel the", "change the", etc. (still gated on a
  calendar noun). `ContextWindowFitter.fitDroppingToolsIfNeeded`: if tools
  would leave under 1,000 tokens for the conversation, they are dropped for
  that request (never mid-turn) and the model is told it cannot act and to
  suggest asking directly or Quick Task.
- **Status:** fixed (build 24), awaiting device confirmation.
