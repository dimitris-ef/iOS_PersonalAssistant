# UI architecture

How the SwiftUI layer is put together, and why.

## The four layers

```
View                 SwiftUI composition. No business rules, no service calls.
  ↓
ViewModel            Screen state: filters, drafts, which sheet is open.
  ↓
Presentation         Domain → display mapping. Pure, no SwiftUI state.
  ↓
AppModel             Shared state. The only type that talks to the core.
  ↓
AssistantCore        The engine, repositories and platform services.
```

Two boundaries carry the weight:

**Presentation is pure.** `TodayPresenter`, `TaskPresenter`,
`ConversationPresenter` and `ReminderPlanPresentation` take domain values and a
date, and return display values. No `@State`, no environment, no side effects —
which is why the summary sentence and the timeline ordering are ordinary
functions that can be reasoned about without a running app.

**Only `AppModel` touches the core.** Every mutation goes through it, and it in
turn goes through `AssistantEngine`. A view cannot complete a task by setting a
boolean; it calls `model.completeTask(id)`, which calls
`engine.record(.confirmedComplete(at:), for:)`, which runs
`TaskStatusMachine`. That is what stops the UI from re-implementing rules the
core already owns — most importantly the one below.

## Why the domain is not decorated for the UI

`AssistantSettings` gained nothing during this phase. Appearance
(Light/Dark/System) and the assistant persona placeholders live in
`@AppStorage` in the UI layer, because nothing in the core reads them yet. When
`SystemPromptBuilder` starts consuming persona and response length, they move
into `AssistantSettings` — at the point they become behaviour rather than
presentation.

One thing did go into the domain: `MemoryKind.place`. Designing the Memory
screen showed that "where you go, and how long it takes to get there" is a real
category that feeds leave-time planning, not a display grouping. That belonged
in the domain, so it went there rather than being faked with a tag.

## Dismissed is not done, in the UI

This distinction is enforced structurally, not by discipline:

- There is no code path from a dismissal to a completion. `AppModel` has
  `dismissReminder(for:)` and `completeTask(_:)` as separate methods calling
  separate domain events.
- `SimulatedReminderResponse` has four cases — `doingIt`, `completed`,
  `snooze`, `dismiss` — rather than a boolean.
- The reminder sheet says so before you press anything: "Dismissing won't mark
  this done — I'll come back to it."
- After a dismissal the banner reports what actually happened: "Dismissed — it's
  still not done, so I'll come back to it."
- `TaskStatus.needsFollowUp` is visible on the task row and explained in the
  detail view.

## Honesty about mock services

`PlatformFidelity` travels from the service, through `ToolOutcome`, into
`ActionFidelity`, and onto the card as a badge. A card produced by
`MockCalendarService` reads "Simulated · nothing was scheduled on this device".

There is no `isDemoMode` flag anywhere. Whether something was real is a property
of the result, not of the build, so it cannot be forgotten at a call site.

## Component map

| Component | Used by | Purpose |
| --- | --- | --- |
| `AssistantActionCardView` | Assistant | One card per structured result |
| `ReminderTimelineView` | Assistant, Task detail, Event detail, Plan detail | The support plan, everywhere |
| `ConversationTurnView` | Assistant | Message + its results |
| `UserMessageView` / `AssistantMessageView` | Assistant | Bubble vs. in-page text |
| `AssistantComposerView` | Assistant | Text, mic, send |
| `SuggestedPromptsView` | Assistant | Quick ways in |
| `UpNextCard` | Today | The one thing that matters now |
| `TodayTimelineRow` | Today | One entry in the day |
| `TaskRowView` / `TaskStatusBadge` | Tasks | List row and state pill |
| `TaskDetailView` / `TaskEditorView` | Tasks | Detail and form |
| `MemoryRowView` / `MemoryEditorView` | Memory | Row and form |
| `ModelSelectorView` | Settings | Provider choice |
| `SimulatedReminderView` | Root | In-app reminder preview |
| `EmptyStateView` | All | Considered empty states |
| `BannerView` | Root | Post-action confirmation |
| `DetailRoute` + `.detailSheet` | Assistant, Today, Tasks | One route type, one destination |

## Adding a new assistant capability

Routines, automations and travel plans all follow the same path:

1. Add a `ToolKind` and its input in the core (already the pattern).
2. Add a case to `AssistantActionPresentation`.
3. Map it in `ConversationPresenter.present(action:result:reminderPlans:)`.
4. Add a body to `AssistantActionCardView` using `ActionCardChrome`.

The message list, the composer and the turn pipeline do not change. The
`unsupported` case means a new capability never vanishes from the transcript
while its card is unwritten — it renders as a plain row instead.

## Navigation

- `TabView` — Assistant, Today, Tasks, Memory.
- Settings is a sheet from every screen's toolbar, opened through the
  `\.presentSettings` environment action so one sheet serves four screens.
- `NavigationStack` inside Settings, with `navigationDestination(for:)` for the
  model selector and privacy topics.
- `DetailRoute` + `.detailSheet(route:)` for task, event and reminder-plan
  detail, so the same task opens the same way from three places.
- The simulated reminder is presented from `RootView`, since it can arrive over
  any tab.
