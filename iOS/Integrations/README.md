# Integrations

All `TODO-XCODE`. Nothing here is built yet; this file records how each
integration attaches to the core so the decisions do not have to be rediscovered
later.

## App Intents / Siri

An App Intent is just another *origin* for an action. It should build a
`ToolRequest` directly and hand it to the same `ToolExecutor` the model's
requests go through, so authorization, permission checks and result reporting
are shared. Set `AssistantAction.origin` to `.user`.

Do **not** give an intent its own path to the platform services.

## Widgets (WidgetKit)

A widget reads from the repositories — outstanding tasks, the next reminder
stage, today's events. It needs no AI provider at all, which is the point of
keeping tasks and reminder plans in application storage rather than inside a
provider.

Requires an app group so the widget extension can reach the same store, which is
one of the reasons the storage layer sits behind `SnapshotStore`.

## Live Activities (ActivityKit)

Best fit is the run-up to a fixed appointment: showing preparation → leave →
final-call stages counting down. The data is already there in
`ScheduledReminder`.

## Background execution

The follow-up logic (a task that was reminded but never confirmed) needs to run
without the app being open. Options to evaluate on a Mac: `BGTaskScheduler` for
periodic re-evaluation, plus notification-triggered updates. The status
transitions themselves are already pure and synchronous in
`TaskStatusMachine`, so whatever wakes the app only has to feed it events.
