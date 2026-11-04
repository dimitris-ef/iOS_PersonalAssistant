# MetisAI

Start every session by reading `Claude Instructions/README.md` and then
`Claude Instructions/CURRENT-STATE.md`: the project's archive — current state,
build history, every problem and fix, the roadmap, and how to work here. Keep
those files up to date in the same push as the work.

- Develop on `claude/iphone-ai-assistant-arch-ww96mv`. Never use branch `ChatGPT`.
- There is no Swift toolchain in the cloud session; CI is the compiler.
- Changing a SwiftData model: freeze the old class into the current schema
  version first (`PersonalAssistantMigrationPlan`, "Adding V11").
