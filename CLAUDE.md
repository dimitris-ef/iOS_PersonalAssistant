# MetisAI

Start every session by reading `Docs/HANDOFF.md`: current state, what is
pending, and how to work in this repository.

- Develop on `claude/iphone-ai-assistant-arch-ww96mv`. Never use branch `ChatGPT`.
- There is no Swift toolchain in the cloud session; CI is the compiler.
- Changing a SwiftData model: freeze the old class into the current schema
  version first (`PersonalAssistantMigrationPlan`, "Adding V11").
