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

## P9 — A new appointment was treated as changing an old one (build 24)

- **Owner saw:** after deleting the old dentist event by hand, Quick Task "I
  have an appointment with a dentist 18th of November, 6 p.m." answered "I
  couldn't find an event matching 'dentist appointment'. What is it called?"
- **Plain cause:** Metis Action misunderstood the sentence as *change* the
  dentist appointment rather than *add* one. The app then searched the
  calendar for an existing one, found none, and asked. This is Metis Action
  0.8B v0.1's most common mistake: unfamiliar wording falls back to
  "change an event".
- **Fix (app side):** `LocalSemanticIntentCorrection` — if the model says
  `calendar.update` but the person's sentence contains no change word (move,
  reschedule, postpone, change, cancel, rename, …) and there is a time, it is
  turned into `calendar.create` with the model's own title and time. Applied
  in `ActionTurnProvider` before resolving. Real changes are untouched.
- **Fix (model side, later):** v0.2 training needs more "I have a … at …"
  style sentences labelled `calendar.create` (ROADMAP "Next" 3).
- **Status:** fixed (build 25), confirmed on the phone (barber, 12:30).

## P10 — "Waiting for approval" with no way to approve (build 25)

- **Owner saw:** Quick Task "move the barber appointment I have tomorrow … to
  another day" answered that it was waiting for approval — and there was
  nothing to tap.
- **Plain cause:** moving or deleting an event and cancelling an alarm are set
  to ask first (so a wrong guess cannot silently move the wrong appointment).
  The app could *ask*, but no screen had ever been given an Approve button —
  not Quick Task, and not the chat either. So those actions could never run.
- **Technical:** `AssistantSettings.defaultToolAuthorizations` marks
  `updateCalendarEvent`, `deleteCalendarEvent`, `cancelAlarm` as
  `.requiresConfirmation`; `ToolExecutor` returns `.awaitingConfirmation`; the
  UI only drew a badge. Now `AssistantEngine.perform(_:approvedByUser:)` runs
  the same request with that one kind allowed (a *denied* kind stays denied);
  `QuickActionResult.awaitingApproval` lists what is waiting; Quick Task shows
  Approve / Don't; the chat card shows Approve and updates in place
  (`AppModel.approve`).
- **Status:** fixed (build 27), awaiting device confirmation.

## P11 — Cloud model settings newer OpenAI models refuse (found before it bit)

- **Context:** the owner set up OpenAI's `gpt-6-luna` as the cloud model
  (2026-11-11).
- **Plain cause:** the app always sent two optional settings — a reply-length
  limit called `max_tokens`, and a "temperature". OpenAI's recent reasoning
  models refuse both (they want `max_completion_tokens` and their own
  temperature). A refused setting fails the whole message.
- **Fix:** `RemoteRequestStyle`. For `api.openai.com` the app sends
  `max_completion_tokens` and no temperature from the start. For any service,
  a 400 whose message names a setting (`max_tokens`, `max_completion_tokens`,
  `temperature`, `reasoning_effort`) changes that one setting and retries, at
  most twice (`RemoteAIProvider.respond`). No model names are hard-coded.
- **Confirmed on build 27** (owner's screen): "This model doesn't support
  tool calling. Function tools with reasoning effort are not supported for
  GPT-6 Luna in v1/chat/completions. To use function tools, use v1/responses
  or set reasoning effort to none." The retry sends `reasoning_effort: "none"`
  for exactly this message (test `testGPT6LunasToolRefusalAddsReasoningEffortNone`),
  and the working settings are remembered per host and model for the rest of
  the run (`RemoteRequestStyleMemory`).
- **Later option:** OpenAI's Responses API (`/v1/responses`) would allow tools
  *with* reasoning. Not needed while "none" works.
- **Status:** fixed (build 28), confirmed on the phone — the cloud model works.

## P12 — "Event not found" / "No reminders are planned" for the same event (build 28)

- **Owner saw:** with the cloud model, "tomorrow morning I really really have
  to go to the Serres racing circuit at 9am" was added to the calendar with
  reminders (which fired). But tapping the event card in chat said "Event not
  found. It may have been removed", and Today → Up next → Preview reminder
  said "No reminders are planned for this yet".
- **Plain cause:** the event had two IDs. The app planned it (and its
  reminders) under one; after Apple's Calendar saved it, the app read it back
  under another. Each side looked for the other's ID and found nothing. The
  reminders themselves were fine — notifications do not need the lookup.
- **Technical:** `ToolExecutor` discarded `createEvent`'s result;
  `AppleEventKitStore` derived every event's domain id from EventKit's
  `eventIdentifier`; the planned → EventKit alias was in memory only. The
  mock calendar keeps the id it is given, which is why no test caught it.
- **Fix:** `AppleEventKitStore` now records, on disk (UserDefaults key
  `AppleEventKitStore.appAssignedEventIDs`), EventKit identifier → the id the
  app created the event with, and reads every such event back under that id —
  one id everywhere, across restarts. Events made before build 29 are
  reconnected once at launch: `EventLinkRepair` matches an orphaned reminder
  plan to the single event with the same title and start (±60 s) and
  `CalendarService.linkEvent` records the link. Ambiguous matches are left
  alone.
- **Status:** fixed, ships in build 29.

## P13 — The keyboard could not be put away (build 28)

- **Owner saw:** once the keyboard was up in chat there was no way to hide it.
- **Cause:** only swipe-down-to-dismiss existed, and only when the chat was
  long enough to scroll.
- **Fix:** tap anywhere on the conversation (simultaneous gesture, so card
  buttons still work), a keyboard-down button above the keyboard, and
  swipe-down as before.
- **Status:** fixed, ships in build 29.

## P14 — Deleting chats was hidden and one at a time (build 28)

- **Owner saw:** no visible way to delete old chats.
- **Cause:** only swipe-left existed.
- **Fix:** Chats list → Edit → tick several → Delete (N); long-press a chat →
  Delete; swipe-left as before. `AppModel.deleteConversations`.
- **Status:** fixed, ships in build 29.

## P15 — No temporary chat (owner's request)

- **Asked:** a normal chat that is not saved — not Quick Task.
- **Decided with the owner:** actions in it still happen (reminders, tasks,
  events), and memories are kept; only the conversation is not saved.
- **Built:** ✏️ menu → New Temporary Chat (also in the Chats list). Header says
  "Temporary Chat", a notice says it is not saved. Held in `AppModel` only;
  `AssistantEngine.sendTemporary` runs a full turn without writing the
  conversation or its action history. Leaving it, starting another chat or
  closing the app discards it.
- **Status:** built, ships in build 29.
