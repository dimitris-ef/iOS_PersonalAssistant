# Build history

Newest first. "Owner found" is what was seen on the phone, in the owner's words
where possible. Details of each problem are in
[PROBLEMS-AND-FIXES.md](PROBLEMS-AND-FIXES.md) under the same number.

## Build 22 — never shipped

The TestFlight run (and several CI runs the same afternoon, 2026-11-04
16:09–17:09 UTC) was cancelled after exactly 15 minutes without ever getting a
macOS machine. Not a code failure: Apple SDK Check compiled the same commit
successfully at 16:49. Its number was used up; the code below ships as the
next successful build.

## Build 23 — never shipped

Cancelled the same way at 17:56–18:11 UTC, and so was a Swift Tests re-run.
No reason given by the API; the owner was asked to look at the run page and
at GitHub → Settings → Billing (Actions minutes) in case macOS minutes ran out.

## Build 27 — 2026-11-11 (head `a3d4d2c`, VALID)

- Approve button for actions that wait for approval, in Quick Task and chat
  (P10).
- **Owner found:** waiting for the device report.

## Build 26 — 2026-11-11 (head `a07bf3b`, VALID)

- A chosen, set-up cloud model does actions itself (chat and Quick Task);
  the chat menu names it. On-device models keep Metis Action.

## Build 25 — 2026-11-05 (head `042be25`, VALID)

- A stated appointment misread as a change is created instead (P9).
- **Owner found:** (1) "I have an appointment tomorrow at the barber at
  12:30 p.m." added correctly; (2) moving it stopped at "waiting for approval"
  with nothing to tap (P10); (3) reminder set; (4) task added.

## Build 24 — 2026-11-04 (head `acd662e`, VALID)

- Calendar events can be found to move or change them (P7).
- "Move the …", "reschedule", "postpone" go to the action model (P8).
- Apple's chat model is no longer sent tool descriptions that fill its whole
  window (P8).
- **Owner found:** (had deleted the old dentist event first) "I have an
  appointment with a dentist 18th of November, 6 p.m." in Quick Task asked
  "what is it called?" instead of adding it (P9).

## Build 21 — 2026-11-04 (head `aebe0f2`, VALID)

- Multiple chats: a chats list, New Chat, switch, delete.
- Quick Task: type a reminder/task/event, the action model does it, nothing is
  kept as a chat.
- Apple's on-device model is sent only as much recent history as fits its
  window, instead of failing with "conversation too long" (P6).
- Plain wording under replies: "Done: added a reminder." (P5).
- **Owner found:** Quick Task created "dentist, 18 November, 6 p.m."
  correctly. "Move the dentist appointment I have to 15 November, 5 p.m."
  could not find it (P7). In a new chat the same request said "conversation
  too long" (P8).

## Build 20 — 2026-11-02 (head `2487967`)

- Fix: crash on send for every action request on a local model (P4).
- **Owner found:** "remind me in 10 minutes to fix the bottles" worked —
  Metis Action 0.8B created the reminder. The reply said "1 action completed:
  createReminder" (P5). After more messages the chat refused: "That
  conversation is too long for the on-device model. Starting a new one will
  help." — and there was no way to start a new one (P6).

## Build 19 — never shipped

The TestFlight run was cancelled after 15 minutes with no error and no logs.
Its number was used up; the same code shipped as build 20.

## Build 18 — 2026-11-02 (head `cdc9968`)

- Metis Action findable: "Use for Actions" button, bolt tick, auto-chosen after
  download, Action Model link on the AI Model screen, action model named in
  the chat menu (P3).
- **Owner found:** the app crashed the moment a message was sent (P4).

## Build 17 — 2026-11-02 (head `6fa7d26`)

- Fix for the build 16 launch crash (P1).
- Ships Metis Action 0.8B v0.1 in the model catalog (P2 notes).
- **Owner found:** "a lot of problems" (only partly described yet); the
  downloaded Metis Action did not show anywhere it could be chosen (P3).

## Build 16

- **Owner found:** crashed on launch for every existing install (P1).

## Builds 1–15 — 2026-08-29 to 2026-09-02

First TestFlight deploy on 2026-08-29 (Part 14). These builds brought Apple
on-device AI, local models (llama.cpp), the crash trail and Local AI
Diagnostics, the universal semantic action protocol, the action router, grammar
constrained actions, and the dedicated action model. Per-build device reports
from that period were not archived; see `git log` and `Docs/` for detail.
