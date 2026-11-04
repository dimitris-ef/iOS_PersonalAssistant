# Current state

Last updated 2026-11-04 (evening). Update this at the end of every session.

## Where things stand

- **Latest on TestFlight: build 21** (VALID, head `aebe0f2`): multiple chats,
  Quick Task, history fitted to Apple's on-device window, plain wording under
  replies. See [BUILD-HISTORY.md](BUILD-HISTORY.md).
- **Build 22 in progress**: calendar lookup for "move the dentist…" (P7),
  wider change phrases and no tool descriptions for Apple when they don't
  fit (P8).
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
