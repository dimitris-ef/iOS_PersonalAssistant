# How we work

## The project in one paragraph

MetisAI is a native iPhone ADHD / executive-function assistant (SwiftUI, a
Swift package plus an XcodeGen app project). Founding idea: *dismissing a
notification is not the same as completing a task.* Chat models are
replaceable; the owner's conversations, tasks and memories belong to the app.
Actions (reminders, tasks, events) are interpreted by a separate small model,
**Metis Action**, which the owner trains (`ML/MetisActionModel/`, training
repo `dimitris-ef/0.8b-training-001`).

## Branch

- All work: **`claude/iphone-ai-assistant-arch-ww96mv`** — even if a session is
  started on another branch, the owner has asked for this one.
- **Never use branch `ChatGPT`.**

## Checking work

- The cloud session has **no Swift compiler. CI is the compiler.**
- Four lanes, path-filtered: Swift Tests (`Sources/**`, `Tests/**`), Apple SDK
  Check and iOS Simulator Preview (`iOS/**`, `Sources/**`), Local model runtime
  (local AI sources only). `Docs/**`, `ML/**` and this folder trigger none.
- **TestFlight**: run `testflight-deploy.yml` by hand on the branch. Build
  number = the workflow's run number. It succeeds only when App Store Connect
  reports the build VALID. Takes ~15–20 min: wait, then check once. A run that
  is cancelled still uses up its number (build 19).
- **A job "cancelled" after exactly 15 minutes** with no logs means GitHub never
  gave it a macOS machine (builds 19 and 22). It is not the code. Re-run it
  later; do not change code because of it.
- Be frugal: one well-timed check, not polling. Ask for one run, not lists.

## Working with the owner

- **Discuss first, code on "go"** (owner, 2026-11-12). When the owner reports
  problems or ideas, investigate (reading code is fine) and propose fixes with
  their trade-offs and any decisions needed. Do not change code, push, or start
  builds until the owner says to go ahead.

- Explain every problem **in plain terms as well as technically**.
- The owner tests on their own iPhone and reports what happened. When the cause
  is unclear, say exactly what to try and what to report back.
- Short commit messages. No model names in commits or code.
- When an action needs the owner (TestFlight install, App Store Connect,
  training runs), say so plainly.

## Swift traps that recur here

- `await` inside `??`, `&&`, `||`, `XCTAssert*` or `XCTUnwrap` does not compile
  (autoclosures). Bind to a `let` first.
- A ternary in `foregroundStyle` needs both branches the same type:
  `Color.secondary : Color.orange`, not `.secondary : Color.orange`.
- **Changing a SwiftData model**: freeze the current class into the current
  schema version *first* (`PersonalAssistantMigrationPlan`, "Adding V11").
  "Purely additive" is not an exemption — that is what crashed build 16.
- llama.cpp: `llama_sampler_sample` already accepts the token. Never call
  `llama_sampler_accept` after it (build 18/20 crash).
