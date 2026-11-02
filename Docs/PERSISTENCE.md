# Persistence

Where the user's data lives, and why the rest of the app cannot tell.

## The layering

```
SwiftUI views / view models     know: AppModel
        ↓
AssistantEngine                 knows: repository protocols
        ↓
Repository protocols            AssistantPersistence — no storage of any kind
        ↓
SwiftData repositories          AssistantPersistenceSwiftData
        ↓
SwiftData models (SD*)          the only types that know what a table is
        ↓
one ModelContainer              one store, one schema
```

`TaskItem`, `Conversation`, `MemoryItem`, `ReminderPlan`, `AssistantSettings`
and `UserProfile` are plain value types in `AssistantDomain`. None of them is a
`@Model`, none imports SwiftData, and none has a persistence annotation. They
are the source of truth for what the product means; the `SD*` types are one
possible way of writing it down.

Nothing above the repository layer touches a `ModelContext`. The engine calls
`taskRepository.save(task)`, exactly as it did against the in-memory store.

## Where SwiftData is allowed to exist

Only in the `AssistantPersistenceSwiftData` target. Every file there is wrapped
in `#if canImport(SwiftData)`, so the package still builds on Linux and Windows —
the target is simply empty there. No core target depends on it.

That constraint is not ceremony. Development happens on Windows, and the day the
domain layer needs an Apple framework to compile is the day the core stops being
testable before there is a Mac in the room.

The package's macOS minimum moved from 13 to 14, which is SwiftData's floor. The
iOS deployment target is unchanged at 17.

## Current schema

The container opens at **version 10**, and the migration plan knows **V9 and
V10 only** — see "The build 16 crash" below for why. The table below describes
`PersonalAssistantSchemaV1`, `Schema.Version(1, 0, 0)` — the shape everything
since has added to, and the file that must never be edited because it describes
what is already on disk.

| Version | Adds |
| --- | --- |
| V2 | Reminder stage lifecycle: `stateRaw`, `stateChangedAt`, `scheduledFor` |
| V3–V5 | Memory metadata, spoken replies, and the settings that came with them |
| V6–V7 | Routines and occurrences; memory relations, embeddings and lifecycle |
| V8 | Installed local models (`SDLocalModel`) |
| V9 | Platform delivery state on each stage, `revision` on each plan, and `SDHandledAction` — see [`BACKGROUND.md`](BACKGROUND.md) |
| V10 | `selectedActionModelID` and `actionModelEnabled` on settings — the dedicated action model |

V9 → V10 is an inferred `.lightweight` migration: one optional column and one
with a declared default.

| Model | Holds | Relationships |
| --- | --- | --- |
| `SDConversation` | id, title, created, updated | cascades to messages and action plans |
| `SDMessage` | id, role, text, timestamp, action-plan id, sequence | belongs to a conversation |
| `SDActionPlan` | id, created | belongs to a conversation; cascades to actions and results |
| `SDAction` | id, tool kind, origin, authorization, rationale, source call id, request JSON | belongs to a plan |
| `SDToolResult` | id, action id, kind, outcome + detail, message, produced | belongs to a plan |
| `SDMemory` | id, kind, content, salience, tags, dates, source | — |
| `SDTask` | id, title, details, status, importance, timing, deadline, durations, recurrence, links, counts, dates | — |
| `SDReminderPlan` | id, subject, anchor, three policies, created, generator | cascades to stages |
| `SDReminderStage` | id, kind, offset, channel, escalation, message, confirmation, sequence | belongs to a plan |
| `SDAssistantSettings` | provider/model ids, routing, tool authorizations, support preferences | singleton |
| `SDUserProfile` | display name, time zone, wake/sleep, durations, quiet hours | singleton |

### Two rules the models follow

**The domain's identifier is the key.** Every entity stores the domain `UUID`
and is fetched by it, with a uniqueness constraint. Loading a value, editing it
and saving it updates the row it came from. SwiftData's own object identity is
never depended on.

**Enums with associated values are decomposed, not encoded.** `TimingPreference`
becomes `timingKind` plus the dates that case carries; `ReminderOffset` becomes
`offsetKind` plus an interval, a day count, an hour and minute, or a date. More
columns than a blob, but inspectable, queryable, and — the part that matters —
migratable. A future schema version can migrate a column; it cannot migrate the
inside of an opaque payload.

The discriminator strings are declared as constants in `DomainCoding.swift`
because they are *on disk*. Renaming a Swift case must not silently change what
a stored row means.

### The one exception

`SDAction.requestJSON` holds the typed tool input as JSON. `ToolRequest` is a
closed union of fifteen input types; modelling it relationally would mean
fifteen tables that exist only to rebuild a value nothing queries by field. It
is also not an invented format — it is the same name-plus-JSON-arguments shape
the tool pipeline already speaks, so a stored action is a recorded tool call.
`toolKindRaw` stays a real column, which is what a migration would need.

## Migrations

`PersonalAssistantMigrationPlan` is wired into the container from the first
launch, even though V1 needs no stages. Adding it later is not possible in any
cheap way: a store created without a plan has no path forward except deletion,
and by then the data being deleted belongs to someone.

### The build 16 crash

TestFlight build 16 crashed on launch for everyone who had the app installed,
with every test green.

SwiftData identifies an existing store's version by a checksum of its model
shapes, computed from the classes each `VersionedSchema` lists. Here every
version listed the **same shared classes**, so every version computed *today's*
shapes. V1–V5 only ever added columns to shared classes, so they were
identical; V10 added two columns to the shared `SDAssistantSettings`, so V9
became identical to V10 — and no longer matched the V9 store on disk.

None of it mattered while no store ever migrated, and none ever had: V9 was in
place before TestFlight build 1, and builds 1–15 all created and kept a V9
store. Build 16 was the first to migrate one, and a staged migration validates
the whole plan: duplicate checksums, trap.

The fix: V9 carries a frozen copy of the one class V10 changed
(`PersonalAssistantSchemaV9.SDAssistantSettings`, property-for-property as
build 15 declared it), and the plan lists only V9 and V10. V1–V8 stay in the
source as history. No shipped build ever wrote a store older than V9.

Every test created a fresh store at the newest version, so none could see this.
`StoreUpgradeTests` now writes a real V9 store through V9's frozen classes and
opens it with the current container, and
`SchemaVersioningTests.testEveryVersionInThePlanIsDistinct` fails if any two
versions in the plan describe the same store.

### Adding a version

Documented in the migration plan's own comments. The rule that matters most,
because ignoring it is what crashed build 16: **freeze before you change.** Copy
every class you are about to edit into the current version as a nested type,
exactly as it is, list the copy there, and only then edit the shared class.
"Purely additive" does not exempt a change. Then add the new version and a
stage, and add a `StoreUpgradeTests` case that writes the previous version's
store through its frozen classes and asserts the data survived.

**A migration never deletes data.** If a field cannot be derived it becomes
optional or takes a documented default. There is no code anywhere in this layer
that catches a load failure and recreates an empty store, and there must not be:
that turns a recoverable problem — a full disk, a locked file, a migration bug
worth fixing — into permanent loss. When the container cannot be opened, the app
says so and stops. See `PersistenceFailureView`.

## Concurrency

`ModelContext` is not `Sendable`. Rather than each repository inventing an
answer, they share one `AssistantPersistenceActor` (a `@ModelActor`) which owns
the context and lends it to a closure running on its executor. Only mapped
domain values cross the boundary.

The actor has no per-entity methods — no `saveTask`, no `fetchMemories`. It
provides `read` and `mutate`, and repository behaviour stays in the
repositories, split the way the protocols are split.

`mutate` saves before returning. A repository call is a user action that already
happened; it should be on disk when the call returns, not whenever autosave next
runs. One save per operation covers everything the closure touched, so a
conversation and its new message commit together, and a failure rolls back
rather than leaving half an object graph behind.

## Ordering

Never left to the database:

- **Messages** — timestamp ascending, `sequence` breaking ties. Messages written
  in the same instant are common, and without the tiebreak their order would be
  whatever the storage engine returned.
- **Conversations** — most recently updated first, then id.
- **Memories** — oldest first, then id. `search` uses `MemoryQuery.rank(_:)`,
  which lives in the domain so every backend ranks identically.
- **Tasks** — by anchor date, then deadline, then creation date, filtered
  through the domain's own `TaskFilter.matches`.
- **Reminder stages** — by stored sequence.
- **Action plans** — oldest first.

Task filtering happens in Swift rather than as a `#Predicate`, deliberately: the
window check reads `timing.anchorDate`, which is derived from a decomposed enum
and has no single column. Two implementations of "matches" that could disagree
is a worse problem than fetching a few hundred rows.

## What is *not* in SwiftData

**Credentials.** API keys, tokens and any other secret live in the Keychain
behind `CredentialStore`, unchanged from the Remote AI milestone. The database
holds the provider *identifier* and nothing that could authenticate as anyone.
Endpoint and model name are non-secret configuration and stay in `UserDefaults`.

Switching provider therefore rewrites one string in the settings row. It does
not touch conversations, tasks, memories, reminder plans or the profile, and
there is no per-provider store for any of them.

**`AssistantActionPlan.rejected`.** The calls the decoder refused are turn-scoped
diagnostics — they explain, in the moment, why something did not happen. The
transcript's cards are built from `plan.actions` alone, so nothing in a restored
conversation depends on them.

**Presentation state.** Sheet routing, filters, drafts, banners and the
in-progress typing indicator are view-model state and are not persisted.

## Demo data

A production launch writes nothing it was not asked to write. A new user gets an
empty conversation, an empty task list and no memories — plus default settings
and a default profile, which are configuration, not content. The app cannot plan
a reminder without a preparation duration; it can perfectly well plan without a
fake haircut.

Seeding is available only in debug builds and only when asked for, via
`-seed-demo-data` or `ASSISTANT_SEED_DEMO_DATA=1`. It also switches the store to
in-memory, so seeded content can never reach a database a real user might later
open. The CI screenshot job passes that flag; a release build compiles the branch
out entirely.

The "Reset demo data" row in Settings only exists on a launch that is already
running on demo storage, and `resetDemoData()` refuses regardless — on real data
it would mean deleting the user's conversations and replacing them with examples.

## Other backends

`EphemeralSnapshotStore` and `JSONFileSnapshotStore` are unchanged and still
useful: tests, the CLI dev harness, SwiftUI previews, deterministic screenshots
and fixture data. `AssistantRepositories.ephemeral()` is still the right call in
all of those. It is no longer what the app runs on.

Every repository protocol now has two implementations, which is the point: the
parity tests in `AssistantPersistenceTests` and
`AssistantPersistenceSwiftDataTests` hold both to the same behaviour, so the
backend really is a substitution rather than a rewrite.

## Testing

`PersistenceTestCase` gives each test a store in its own temporary directory,
on disk rather than in memory — because most of what is being tested is whether
data survives the container that wrote it, and an in-memory store cannot answer
that. `relaunch()` drops the container and opens a new one over the same file,
which is as close as a test gets to the user quitting and reopening the app.

Nothing in the suite touches the application's real store.

## Known limitations

- **No batch delete.** `ReminderPlanRepository` has no delete operation; plans
  become unreachable when the task or event that indexes them goes away. On
  SwiftData a deleted conversation does cascade to its action plans, but a
  deleted *task* leaves its reminder plan row behind. Worth an explicit cleanup
  before the store grows large.
- **`CalendarItem` is not persisted here.** Events still live in the mock
  calendar service, which is memory-backed. That is a platform-layer gap, not a
  persistence one: it closes when `EventKitCalendarService` is implemented.
- **No conflict resolution.** One device, one store, no sync. iCloud/CloudKit
  would need `SDModel` classes to satisfy CloudKit's constraints (no unique
  attributes, every relationship optional), which is a V2-shaped change and
  should be designed before the first user has data worth syncing.
- **Unverified on a device.** None of this has run on real hardware — see the
  Status section of the root README.
