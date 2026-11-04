# Roadmap

## Now (build 21)

- [x] Multiple chats — list, new, switch, delete.
- [x] Quick Task — one sentence to the action model; nothing kept as a chat.
- [x] Fit history to Apple's on-device window (P6).

## Next

1. **Owner tests build 21**: speed of an action, whether the reminder fired,
   harder sentences ("add a task to call the bank tomorrow", "remember that my
   dentist is Dr. Papadopoulos", "move the dentist to 4pm and rename it
   check-up"), plain chat, and the rest of the build 17 problems.
2. **Feedback feature** (owner's design): opt-in, off by default, on for the
   owner. Per action record: corrected (strongest) > dislike > like > accepted
   without complaint (weakest). After a dislike, offer "fix it" so it becomes
   a correction. Stays on the phone until the owner exports it. Real data is
   weighted above synthetic in training; keep some real data out of training
   as the exam. Format drafted: `ML/MetisActionModel/Dataset/v1/feedback_record_schema.json`.
   Storing it needs schema **V11 — freeze before you change**.
3. **Metis Action v0.2 training**: more varied phrasing (misses are mostly
   unfamiliar wording defaulting to `calendar.update`), plus real sentences.
   Keep the bare-sentence format. Measure with `ML/MetisActionModel/Eval/`
   against `baseline-v0.1-golden.json`.

## Later — asked for, not started

- **"Did you do it?" follow-through** (owner, 2026-11-04). Not only create a
  reminder, but afterwards ask whether the task was done, and whether on time.
  Based on the answer, keep reminding with different notifications, or set an
  alarm, escalating as needed. This is the app's founding idea (a dismissed
  notification is not a completed task). Existing groundwork to build on:
  `Docs/FOLLOW-UP.md`, `Docs/EXECUTIVE-SUPPORT.md`, the "Proactive reminders",
  "Follow up if not confirmed" and "Require completion confirmation" settings.
- Voice input for Quick Task (on-device speech-to-text is stubbed in TestFlight:
  whisper.cpp `PPAI_WHISPER_RUNTIME=1` defect).
- Chat titles written by the model rather than taken from the first message.

## Waiting on the owner's decision

- Bring the curated v2 `train.jsonl` (in `dimitris-ef/0.8b-training-001`) into
  `ML/MetisActionModel/Dataset/v1/`. The model was most likely trained on it.
- Strip the stray `"Evaluation wording: "` prefix from `golden_eval.jsonl`.

## Older open items

Files-picker GGUF import (#123); no SHA-256 on the Hugging Face catalog entries
(Hugging Face is blocked from the cloud session); calendar event lookup not
wired, so `calendar.update` asks which event; no CI check that
`protocol_v1.json` still matches the Swift protocol. Full list:
`Docs/OPEN-ITEMS.md`.
