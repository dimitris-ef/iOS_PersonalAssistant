# Claude Instructions — the project's memory

This folder is the archive that lets any new session (Claude, or a person)
continue MetisAI from exactly where the last one stopped, even if every chat is
gone. **Read it before doing anything else.**

| File | What it holds | Update it when |
|---|---|---|
| [CURRENT-STATE.md](CURRENT-STATE.md) | Where things stand right now: latest build, what is waiting on whom, the next step | Every session, before ending |
| [BUILD-HISTORY.md](BUILD-HISTORY.md) | Every TestFlight build: what it shipped, what the owner found on the phone | Each build, and each device report |
| [PROBLEMS-AND-FIXES.md](PROBLEMS-AND-FIXES.md) | Every problem: what the owner saw, the real cause (plain and technical), the fix, the build it shipped in | A problem is reported, and when it is fixed |
| [ROADMAP.md](ROADMAP.md) | What we want to build: now, next, later, and decisions waiting on the owner | A feature is asked for, started, or finished |
| [HOW-WE-WORK.md](HOW-WE-WORK.md) | Branch, CI, TestFlight, the owner's preferences, Swift traps that recur | A rule is learned the hard way |

## Rules for keeping it useful

- **Write it down in the same push as the change.** An archive that lags the
  code is how the next session repeats a mistake.
- **Use the owner's words for symptoms**, then explain the cause plainly and
  technically. "It crashed when I pressed send" is the record; the stack trace
  is the explanation.
- **Never delete history.** Mark things done or superseded instead.
- Deeper technical documents stay in `Docs/` (architecture, persistence,
  action routing…). This folder points at them rather than repeating them.
