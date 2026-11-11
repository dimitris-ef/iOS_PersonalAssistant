# Current state

Last updated 2026-11-11. Update this at the end of every session.

## Where things stand

- **Build 28 in progress**: cloud requests adapt to the service (P11). Owner is
  setting up OpenAI `gpt-6-luna` (endpoint `https://api.openai.com/v1`).
- **Latest on TestFlight: build 27** (VALID, head `a3d4d2c`): Approve button
  in Quick Task and chat (P10). All four CI lanes green.
- **Build 26** (VALID, on TestFlight): the cloud model does its own actions when chosen
  (owner's plan to test the app independently of the model; see ROADMAP
  "Decision — 2026-11-11").
- Build 25 (VALID, head `042be25`): a stated
  appointment that Metis Action misreads as a change is created instead (P9).
- Build 24 (VALID, head `acd662e`): calendar
  lookup for "move the dentist…" (P7); "move the/reschedule/postpone" go to
  the action model and Apple's chat model is not sent tool descriptions that
  don't fit (P8). Builds 22 and 23 were cancelled by GitHub before starting.
  Swift Tests green on `d8b95d3` (re-run after the outage).
- Before that, build 21 (VALID, head `aebe0f2`): multiple chats,
  Quick Task, history fitted to Apple's on-device window, plain wording under
  replies. See [BUILD-HISTORY.md](BUILD-HISTORY.md).
- Build 20 confirmed on the phone: no crash on send; Metis Action 0.8B created
  a reminder from "remind me in 10 minutes to fix the bottles".
- The owner chats with **Apple's on-device model**; actions go to **Metis
  Action 0.8B** (chosen automatically after download since build 18).

## What changed in build 21, and where

| Feature | Code |
|---|---|
| Chats list, New Chat, open, delete | `iOS/UI/Assistant/ConversationsListView.swift`, `AppModel` "Chats" section, `Conversation.displayTitle` |
| Quick Task (no chat kept) | `iOS/UI/Assistant/QuickTaskSheet.swift`, `AppModel.performQuickTask`, `AssistantEngine.performQuickAction` |
| Apple window fitting | `Sources/AssistantAI/ContextWindowFitter.swift`, used in `AppleFoundationModelsProvider.generate` |
| Plain wording | `ToolKind.plainAction` / `plainActionDone`, `TurnSummarizer` |

No database change: conversations were already stored as many; only the screen
assumed one.

## Waiting on the owner

- Device test of build 21 (see "Next" in [ROADMAP.md](ROADMAP.md)).
- The other build 17 problems, still not described.
- Two dataset decisions in [ROADMAP.md](ROADMAP.md).

## Next step for whoever picks this up

1. Wait for the owner's device report; log each problem in
   PROBLEMS-AND-FIXES.md before fixing it.
2. Then the feedback feature (ROADMAP "Next" 2). Needs schema V11 — read
   HOW-WE-WORK.md "Changing a SwiftData model" first.
