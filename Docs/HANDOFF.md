# Handoff — where things stand

Last updated 2026-11-02. Read this first in a new session.

## The project in one paragraph

MetisAI: a native iPhone ADHD / executive-function assistant (SwiftUI, Swift
package + XcodeGen). Founding idea: *dismissing a notification is not the same
as completing a task.* Work happens on branch
`claude/iphone-ai-assistant-arch-ww96mv`. **Never use branch `ChatGPT`.**

## How work gets checked

- No Swift toolchain in the cloud session: **CI is the only compiler.**
- Four lanes, path-filtered: Swift Tests, Apple SDK Check, iOS Simulator
  Preview, Local model runtime. `Docs/**` and `ML/**` trigger none of them.
- TestFlight: run `testflight-deploy.yml` by hand. Build number = run number.
  It fails unless App Store Connect reports the build VALID. Takes ~20 min —
  wait, then check once.
- Keep usage low: check CI/TestFlight once after a realistic wait, ask for one
  run, not lists (run listings repeat every commit message in full).

## Current state

- Head `6fa7d26`. **TestFlight build 17** is live and VALID.
- Build 16 crashed on launch for every existing install (SwiftData migration —
  see `Docs/PERSISTENCE.md`, "The build 16 crash"). Build 17 fixes it, proven by
  `StoreUpgradeTests`. **Waiting on the user's device test of build 17.**
- Build 17 also ships **Metis Action 0.8B v0.1** in the model catalog (the
  user's own fine-tune, Qwen 3.5 0.8B, Apache 2.0). Measured 85% right action on
  the golden set as the app now runs it — `Docs/ACTION-ROUTING.md` §12.
  Device speed/memory/heat are still unmeasured.

## Build 18 (live on TestFlight, VALID, head `cdc9968`)

User report on build 17: the downloaded Metis Action 0.8B "didn't show" when
choosing models. Cause: it is (by design) never a chat model, and the only
place to pick it was Settings → Action Model — but every hint in the app said
"Settings → AI Model → Action Model", and the AI Model screen had no such
entry. Fixes: Action Model link on the AI Model screen; "Use for Actions"
button and a bolt tick on its Manage Models row; auto-adopted as action model
after download when none is chosen (`ActionModelHost.adoptIfNoneSelected`);
the chat menu names the action model; Settings row shows its name.
The user also said build 17 has "a lot of problems" — not yet described.

## Build 20 (live, VALID): crash on send (build 19 run was cancelled, never shipped)

User: build 18 crashed the moment a message was sent. Found in
`LlamaCppRuntime.generate`: it called `llama_sampler_accept` after
`llama_sampler_sample`, which in b10506 already accepts. Harmless without a
grammar; under the action grammar the token is accepted twice, the grammar
stack empties, and llama.cpp throws `std::runtime_error` through C → abort.
So every action request on a local model crashed; build 18 made it reachable
by auto-adopting Metis Action. Removed the second accept. If a crash remains
on plain chat messages, it is a different cause — ask for Local AI
Diagnostics (Manage Models → Local AI Diagnostics, "Last stage").

## Since build 20 (not shipped yet, CI green at `61dda30`)

- User confirmed on build 20: "remind me in 10 minutes to fix the bottles" →
  reminder created by Metis Action 0.8B. Crash fix works.
- The summary line said "1 action completed: createReminder" (wire name).
  Now `ToolKind.plainAction` / `plainActionDone`: "Done: added a reminder."
- `CloudExplicitnessTests.testEncodingAudioTouchesNoFiles` failed once on a
  macOS `com.apple.dataaccess` temp entry; it now ignores `com.apple.*`.
- Asked the user for: speed, whether the reminder fired, harder sentences,
  plain chat, and the other build 17 problems. Ship the next build with those.

## Next, in order

1. **User tests build 17**: does it open with data intact; download Metis
   Action 0.8B; choose it under Settings → AI Model → Action Model; try
   reminders and "move X to 4pm and rename it Y". Get speed + misses.
2. **Feedback feature** (the user's design): opt-in, off by default, on for the
   owner. Record per action: corrected (strongest) > dislike > like > accepted
   without complaint (weakest). After a dislike, offer "fix it" so it becomes a
   correction. Stays on the phone until the user exports it. Real data weighted
   above synthetic in training. Keep some real data out of training as the
   exam. Format already drafted: `ML/MetisActionModel/Dataset/v1/feedback_record_schema.json`.
   Storing it will need schema **V11 — freeze before you change** (see
   `PersonalAssistantMigrationPlan`).
3. **v0.2 training**: more varied phrasing (misses are almost all unfamiliar
   wording, defaulting to `calendar.update`), plus real sentences. Keep the
   bare-sentence format the app now sends, or the app must change to match.
   Measure with `ML/MetisActionModel/Eval/` against `baseline-v0.1-golden.json`.

## Waiting on the user's decision

- Bring the curated v2 `train.jsonl` (in `dimitris-ef/0.8b-training-001`) into
  `ML/MetisActionModel/Dataset/v1/`. The model was most likely trained on it.
- Strip the stray `"Evaluation wording: "` prefix from `golden_eval.jsonl`.

## Older open items

Files-picker GGUF import (#123); whisper.cpp `PPAI_WHISPER_RUNTIME=1` defect
(local speech-to-text stubbed in TestFlight); no SHA-256 on the Hugging Face
catalog entries (Hugging Face is blocked from the cloud session); calendar event
lookup not wired, so `calendar.update` asks which event; no CI check that
`protocol_v1.json` still matches the Swift protocol.

## Working with this user

- Explain every problem in plain terms as well as technically.
- Be frugal with usage: few, well-timed checks; short commit messages.
- Swift traps that recur here: `await` inside `??`, `&&`, `||`, `XCTAssert*` or
  `XCTUnwrap` will not compile — bind to a `let` first.
