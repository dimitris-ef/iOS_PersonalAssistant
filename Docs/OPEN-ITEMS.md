# Open items

Everything known to be incomplete, unverified or deliberately limited, in one
place.

This exists because the three categories below get confused with each other,
and they need completely different responses. A `TODO-DEVICE` is discharged by
plugging in an iPhone. A deliberate limitation is not — it is a decision, and
changing it means changing the design. Filing them together as "TODOs" would
mean someone eventually "fixes" a trade-off that was made on purpose, or waits
for a device to resolve something no device will.

Nothing here is a bug that is known and unfixed. Where a defect was found, it
was fixed.

```bash
grep -rn "TODO-XCODE"  --include=*.swift --include=*.yml .   # 27 — needs Xcode or an Apple SDK
grep -rn "TODO-DEVICE" --include=*.swift .                   # 13 — compiles, never executed
```

Restrict the grep to source. Counting `Docs/` as well inflates both numbers,
because these files discuss the markers — including this one.

---

## 1. Deliberate limitations

Decisions with a cost, taken knowingly. Each one has an alternative that was
considered and rejected; the rejection is the entry. Revisit these when the
trade-off changes, not when someone notices the symptom.

| # | Limitation | Why it is this way | Where |
| --- | --- | --- | --- |
| 1 | **"Add Events Only" blocks event creation too.** With write-only calendar access the app declines to write, even though EventKit would permit it. | `PermissionStatus` is checked per capability, not per operation. Distinguishing reads from writes means a permission check at every call site. Few people will pick this answer, and the ones who do are told exactly what is missing. | `ToolExecutor.execute`, `AppleCalendarAuthorization.permissionStatus` |
| 2 | **Repeating alarms schedule one occurrence.** `AlarmRequest.recurrence` is not honoured. | AlarmKit expresses repetition through `Alarm.Schedule.relative`, a different shape from the `.fixed` date this layer builds. Nothing sets `recurrence` today — `createAlarm` has no such input — so the receipt says "this one time only" rather than the code pretending. | `AlarmKitAlarmService.schedule` |
| 3 | **`maximumSnoozes` is not enforced by the OS.** AlarmKit will let someone snooze indefinitely. | AlarmKit has no equivalent setting. The limit is enforced where it can be: the follow-up ladder counts snoozes and escalates. A cap the OS silently ignores would be worse than none. | `AlarmKitAlarmService.configuration` |
| 4 | **Alarm labels are lost across a relaunch.** `scheduledAlarms()` reports "Alarm" for any alarm this process did not schedule. | AlarmKit's `Alarm` carries an id, a schedule and a state — not the text that was shown, and attributes cannot be read back. The label is domain data and lives in the reminder plan; the in-actor mirror is a convenience, not a record. Cancellation is by id and is unaffected. | `AlarmKitAlarmService.labels` |
| 5 | **Critical alerts are never requested.** The loudest level the app produces is Time Sensitive. | The entitlement is granted case by case for things like medical alerts and this app does not hold it. Requesting the level without it does not fail loudly — it simply does not happen, which would leave a line of code that looks like it delivers an unmissable alert. | `AppleEscalationMapping.delivery` |
| 6 | **Time Sensitive delivery itself depends on an entitlement this build lacks.** Without it iOS treats those notifications as `active`. | Same reasoning. The level is set because it is correct once the entitlement exists, and no receipt promises Focus will be broken through. | `AppleEscalationMapping`, `UserNotificationsService.schedule` |
| 7 | **A cold lookup only searches ±1 year.** `event(id:)` rescans a two-year window to rebuild its identifier cache; an event outside that is reported as not found. | EventKit refuses predicates spanning more than four years, and a wider scan on every cache miss is expensive. Two years covers everything the assistant plans around. | `AppleEventKitStore.eventObject(for:)` |
| 8 | **Importance, travel time and preparation time are not written to EventKit.** They survive on the returned item and in the app's own store. | EventKit has no field for any of them on an event. The near-misses are worse: encoding preparation time into `notes` puts machine text in front of the user in Apple's Calendar app, and moving `startDate` earlier for travel tells everyone in a shared calendar the meeting starts at a time it does not. | `AppleEventKitStore.apply(_:to:)` |
| 9 | **Apple Reminders is a one-way door.** The assistant writes there; nothing reads completions back into the task lifecycle. | A ticked checkbox in another app is not evidence that the thing was done, and treating it as confirmation would reintroduce exactly the failure this product exists to prevent. | `EventKitReminderService` |
| 10 | **No local inference runtime is chosen.** `LocalModelProvider` is complete except for the runtime. | Deliberately deferred — llama.cpp, MLX, Core ML and ExecuTorch are a real decision, and the provider is written so making it later means writing one type. | `LocalModelProvider` (`TODO:`) |
| 11 | **Speech recognition uses `SFSpeechRecognizer`, not iOS 26's `SpeechAnalyzer`.** | The modern stack is the better API but is iOS 26+, and the app deploys to iOS 17 — so `SFSpeechRecognizer` is required for most supported devices regardless, and the modern path would be an *addition*. That means two implementations of one feature, neither executable from this environment. One unverified speech path is a known risk; two doubles it. The seam is `SpeechInputService`; adding it later is one type and one `if`. | `VoiceServices.live()` |
| 12 | **An interrupted recording is discarded, not resumed.** A phone call mid-sentence ends the attempt and offers Retry. | Audio captured across an interruption is missing the middle of the sentence, and this assistant *acts* on what it hears — half a command submitted is worse than none. | `AppleSpeechInputService.interrupted()` |
| 13 | **Cancellation is an event, not a state.** The milestone's sketch lists `cancelled` beside `idle`. | Nothing rests there: the user just pressed Cancel and knows it, so a "Cancelled" screen to dismiss is worse than the composer returning. `failed` *is* a state, because there is something to say and a decision to make. | `VoiceSession` |
| 14 | **Voice input source is not stored on the message.** Only the reply's spokenness depends on it. | Forking messages into spoken and typed kinds would make every reader handle both, for a distinction that matters for exactly one decision — and that decision is made before the message is saved. | `MessageInputSource` |
| 15 | **Structured intents log nothing to the conversation.** Adding a task through Shortcuts leaves no chat message. | The task *is* the record. A fabricated "I created a task" message would be the app talking to itself, and would make the conversation a log rather than a conversation. | `AssistantCommandService` |
| 16 | **`AskAssistantIntent` shortens long replies for Siri.** The full text is still persisted. | Siri reading a 600-word answer is an answer nobody retains. The provider's own behaviour is untouched — only what the system surface reads aloud is trimmed, and it is cut at a sentence boundary. | `AssistantCommandService.concise` |
| 17 | **Only a Task entity is exposed, not Memory or CalendarItem entities.** | An entity earns its place by making system interaction materially better, which for tasks means the completion picker. Nothing in this milestone needs to pick a memory, and unused system-model duplication is surface to maintain for no benefit. | `TaskEntity` |
| 18 | **Tool calls execute one at a time, never in parallel.** Two independent actions still run in sequence. | The gain is milliseconds against a model round trip measured in seconds, paid for with a class of ordering bug that only appears under load. Reliability is worth more here than latency, and the dependency resolver would have to become a scheduler to make it safe. | `AgentRunner.execute` |
| 19 | **The execution ledger is in memory and bounded to a handful of recent scopes.** Idempotency does not survive a relaunch. | Its purpose is safety *within* a turn, and a turn does not outlive the process — after a relaunch a repeated request is a new request, not a duplicate. Persisting it would also mean storing the model's proposals, which the transcript has no business carrying. The bound is what stops an actor that lives as long as the engine from growing for as long as the app is used. | `ToolExecutionLedger` |
| 20 | **Dependency edges are only read from identifiers the model wrote down.** A call cannot reference an id the planner invents during normalisation. | The model never saw that id, so it could not have referred to it. Dependencies on generated ids are expressed the other way round — by proposing the dependent call in the next round, once the result is in front of it. | `ToolDependencyResolver.produces` |
| 21 | **An omitted optional and an explicitly passed default fingerprint differently.** Two logically identical calls can both run. | The conservative direction. The cost of treating identical actions as different is one duplicate, which the call-id check usually catches anyway; the cost of the opposite mistake is silently swallowing something the user asked for twice. | `ToolFingerprint` |
| 22 | **Confirmation is reported, not yet resumable from the UI.** An action needing approval produces an `awaitingConfirmation` card, and there is no button on it that runs the action later. | The policy and the replay safety exist — `engine.perform(_:origin:idempotencyKey:)` executes once however many times a callback arrives — but the approval control itself is UI work no milestone has asked for yet. Nothing executes unapproved in the meantime, which is the property that matters. | `AssistantEngine.perform`, `AssistantActionCardView` |
| 23 | **Recurrence is daily, weekly or monthly. No yearly, no "last Friday", no "every second Tuesday of the month".** | Each addition is a new matching rule *and* a new way for the bounded forward scan to find nothing. The three that exist cover medication, bins, gym, rent and standing appointments — which is what people actually write down. `RecurrenceRule` is a value type with a `Frequency` enum; adding one is a case and a branch in `matches(day:)`. | `RecurrenceRule` |
| 24 | **Occurrences are materialised two days ahead, not on demand.** A routine's Thursday exists as a record from Tuesday evening. | The alternative is generating on read, which means the Today list, Siri and the follow-up reconciler each have to generate — and a reminder cannot be scheduled with iOS for a task that does not exist yet. Two days is enough for tonight's and tomorrow's notifications to be in the OS queue before the app is next opened, and short enough that a paused routine leaves almost nothing behind. | `RoutineScheduler.horizon` |
| 25 | **No UI for creating or editing a routine.** They arrive through the assistant (`createRoutine`) and can be paused, skipped-for-today or read; there is no routine editor screen. | Conversation is the intended way in — "every Thursday at eight" is one sentence and a form is four fields. Editing the *rule* from inside one morning's occurrence would silently change every future morning, so the detail view shows the recurrence in words and does not offer to change it. A routines screen is UI work no milestone has asked for. | `TaskDetailView.routineSection` |
| 26 | **Travel time is a number the user or the model states.** Nothing consults Maps, and there is no GPS or geofencing. | Explicitly out of scope, and the trade is bad even if it were not: a live travel API adds a permission, a network dependency and a failure mode to a calculation that has to work offline for someone who is already late. A stated 30 minutes is wrong less often than a routing call that times out. | `PreparationPlanner` |
| 27 | **Dependencies are a single "must happen first" edge. No conditionals, no parallel joins.** | A general workflow engine would be a second lifecycle competing with `TaskStatus` for the answer to "where does this stand", and two answers to that question is how a task list starts lying. | `TaskDependencyGraph` |
| 28 | **The first-step templates are keyword matches, not language understanding.** "Clean the bedroom" gets a cleaning step; "sort out the spare room" gets the universal five-minute time box. | The fallback is honest rather than clever: when the app does not know what a task involves, "spend five minutes on the easiest part" is a real first action, and it needs no network. A `TaskDecomposer` implementation backed by a provider is a substitution at composition time — the protocol exists precisely so that adding one changes nothing else. | `TemplateTaskDecomposer` |
| 29 | **Preparation steps are stored as JSON, not as related rows.** They cannot be queried across tasks. | Following the documented `SDAction.requestJSON` precedent, so the V6 migration stays purely additive and inference-safe. Nothing asks a cross-task question about steps; when something does, that is the migration to write. | `TaskMapping.encodeSteps` |
| 30a | **Contradictions with no number and no negation are not detected.** "I prefer morning workouts" and "I prefer working out at night" are stored as two memories rather than one superseding the other. | The rule that would catch it — same subject, mutually exclusive attribute — is loose enough to also merge "I prefer tea in the morning" with "I prefer coffee at night", and a false contradiction destroys something the user said. Storing both is the conservative direction, and the behaviour the user sees still holds: source trust and recency put the explicit, newer statement first. Numbers and negations *are* caught, which covers most real corrections. | `MemoryDeduplicator.classify` |
| 30b | **The Apple encoder's similarity floor is a guess.** 0.6, chosen conservatively and never measured. | Calibrating it needs the one thing this project has never had — a device to measure the distribution on. Too high costs a recall the lexical channel usually still catches; too low fills prompts with near-misses, which is the worse failure, so the guess errs high. The number is one property on one type. | `AppleNaturalLanguageEncoder.similarityFloor` |
| 30c | **The lexicon encoder knows only its lexicon.** A memory phrased entirely in words it does not have — "the place I go every weekday morning" meaning work — gets no useful vector. | It is the fallback, not the primary: Apple's sentence encoder handles exactly that and is used wherever the device has one. Growing the lexicon indefinitely would be rebuilding a language model by hand, badly. What it buys is that the memory architecture builds and is tested where `NaturalLanguage` does not exist. | `LexiconSemanticEncoder` |
| 30d | **Embeddings are compared exhaustively, with no index.** Every candidate is scored on every turn. | At the scale this app deals in — hundreds of memories, low thousands at worst — a few thousand dot products is microseconds once per turn, and an approximate index would add a structure to keep correct for no measurable gain. The seam for one is behind `MemoryRetrievalService`, so adding it later changes nothing above. | `MemoryRetrievalService.retrieve` |
| 31a | **The shipped model catalog carries no SHA-256 checksums.** The verification machinery is complete and enforced wherever a checksum *is* declared; the four entries currently shipped declare none. | Obtaining a published digest means fetching each file from its publisher, which the environment this was built in cannot reach. Verification is not skipped for those entries — the file must still be a structurally valid GGUF of the declared architecture and roughly the declared size, and the digest of what arrived is recorded so a later integrity check has a baseline. What is missing is detection of a *substituted* but well-formed file, which is also why the transport refuses plain HTTP. Filling one in is one line per entry; the procedure is in `Sources/AIProviderLocal/Resources/README.md`. | `local-models.json`, `LocalModelInstaller.verify` |
| 31b | **llama.cpp is linked only when `PPAI_LLAMA_RUNTIME=1` is set.** A default build gets a runtime that reports itself unavailable. | Not a preference: the published `llama-b10506-xcframework.zip` contains `ios-arm64` and `macos-arm64_x86_64` and **no iOS Simulator slice**, so an app target that links it cannot be built for the simulator at all. Making it unconditional would take down the simulator CI lane and every SwiftUI preview. The dedicated `Local model runtime` workflow builds with the flag on, so the integration is compiled and linked on every change. Building our own XCFramework with a simulator slice would remove the flag, at the cost of hosting an artifact and ~30 minutes of CI. | `Package.swift`, `LlamaCppRuntime` |
| 31c | **The memory budget fraction is a judgement, not a measurement.** 45% of physical RAM, minus a fixed reserve. | iOS does not publish the jetsam limit, and it varies by device, by OS version and by what else is resident. The figure is deliberately pessimistic because the two failure directions are not symmetric: too low means the user picks a smaller model, too high means the app is terminated mid-sentence with nothing to catch. Real limits are a device-measurement question. | `LocalModelResourceEstimator.usableMemoryFraction` |
| 31d | **The catalog's model sizes and context ceilings are from published metadata, not measured downloads.** | Nothing here has fetched the files. A wrong size makes the pre-download storage check approximate; the installer tolerates 5% drift and records anything larger as a discrepancy, and the file's own header overrides every claim after download. | `local-models.json`, `LocalModelInstaller` |
| 31e | **Load cancellation is best-effort.** llama.cpp's progress callback aborts between tensors, so a load stuck inside one large mmap does not notice until it finishes. | The runtime offers no other cancellation point during loading, and inventing one would mean freeing structures llama.cpp is still writing into. Generation cancellation — the one that matters to a person waiting — is exact, and section 118 asks for the limitation to be reported rather than papered over. | `LlamaCppRuntime.loadModel` |
| 32a | **A background refresh is opportunistic and may never run.** Nothing about reminder correctness depends on it. | `BGTaskScheduler` decides when — or whether — to grant time, from battery, charging state and how often the app is used. Building support on top of it would make the assistant unreliable for exactly the people who use their phone least predictably. So user-facing timing is `UNUserNotificationCenter` and AlarmKit, which keep working with the process gone, and a refresh is only ever a chance to tidy up early. | `AppLifecycleCoordinator.scheduleNextRefresh` |
| 32b | **Only a rolling seven days of reminders is handed to iOS.** Stages beyond the horizon stay in the plan, unscheduled, until a later pass. | Pre-scheduling every adaptive escalation for the next month would fill the pending queue with requests that are mostly obsolete by the time they fire, and the system caps how many an app may hold. The exposure is narrow and stated plainly: a task whose only reminder is more than a week out, in an app that is neither opened nor granted a background refresh in that time, will not have been scheduled when its moment arrives. | `SupportCatchUpPolicy.schedulingHorizon` |
| 32c | **Escalation climbs by at most one step per reconciliation pass.** A week of silence does not produce an alarm. | Elapsed time is evidence that support is not working and worth escalating for — but jumping to the loudest level because of the calendar rather than because of anything the user did is how an assistant becomes frightening. The counters still record every missed stage, so the level continues to climb across passes; it just does not arrive all at once. | `SupportCatchUpPolicy.maximumEscalationStepsPerPass` |
| 32d | **After a force quit, iOS will not launch the app for a background refresh.** Already-scheduled notifications and alarms still fire; reconciliation resumes at the next open. | This is the platform's behaviour, not a gap. The alternative would be promising something iOS does not support, and an assistant that quietly under-delivers on a promise like that is worse than one that says what it can do. | `Docs/BACKGROUND.md` |
| 32e | **The handled-action table does not reuse the Part 7 tool ledger.** Two idempotency mechanisms exist, deliberately. | `ToolExecutionLedger` is turn-scoped and in memory — it stops one agent loop repeating itself inside one turn. A duplicate notification callback arrives with no turn in sight, in a process that may have just launched to handle it, minutes or a relaunch later. Generalising the ledger to cover both would have produced something that served neither well; a small persisted table with one job was the cheaper honest answer. | `HandledSupportAction`, `SDHandledAction` |
| 33a | **The SwiftData store moved into the App Group container.** An existing app-container store is copied across on the first launch after the update. | Not a preference: iOS runs an interactive widget's App Intent in the widget extension's process, and an extension cannot reach the app's own container. Without the move, Done on a widget could only open the app. The migration copies rather than moves, so a failure leaves the original intact, and it copies the `-wal` and `-shm` files too — taking only the `.store` would silently drop everything not yet checkpointed. A build with no App Group entitlement falls back to the old location unchanged. | `SharedStoreLocation` |
| 33b | **The widget extension links `AssistantPlatformApple`, and therefore EventKit and AlarmKit, which it never calls.** | It genuinely needs `UserNotificationsService`: a reminder cancelled by a widget's Done has to be cancelled with the same notification centre the app scheduled it with, or a notification fires for a task the user just finished. The Apple adapters ship as one product, so the other two frameworks come along. Splitting the product to shave an extension's link list would put the calendar and the alarm mappings in separate targets for a size saving nobody has measured. | `project.yml`, `SystemSurfaceBridge` |
| 33c | **At most two Live Activities at once, and most tasks qualify for none.** | A Live Activity occupies the Lock Screen and the Dynamic Island continuously. One that appears for every due task trains the user to dismiss them, which costs the feature exactly when it matters — the appointment they were about to be late for. The bar is: something is happening now, it has a time, and being late for it would be bad. Everything else is a notification's job. | `LiveActivityPresentationPolicy` |
| 33d | **The keyboard's assistant actions need Full Access, and typing does not.** | iOS gates shared containers behind Full Access for custom keyboards, so a keyboard that cannot reach the App Group cannot hand text to the app. What it can still do is everything a keyboard is for. The row above the keys says which state it is in rather than hiding the buttons, because a control that vanishes teaches the user the feature is broken. | `Info.plist`, `KeyboardAssistantBridge` |
| 33e | **A keyboard request waits three seconds and then gives up.** | iOS does not launch a containing app because an extension asked it to, and section 23 of the milestone is explicit about not designing as if it did. Three seconds covers the case where the app is already running; past that the honest answer is that nothing serviced it. The user's text is never altered on the way to finding that out, and the deterministic tidy-up is offered as itself rather than dressed up as the model's answer. | `KeyboardAssistantBridge.submit` |
| 33f | **Lock Screen widgets withhold the title when the screen is dimmed, and there is no per-task privacy flag to be more precise than that.** | `TaskItem` has no sensitivity field yet, so the choice is between conservative and nothing. `isLuminanceReduced` is the signal iOS gives, and the placeholder is deliberately bland — "Upcoming" rather than "Private", which advertises that there is something worth hiding. When a flag arrives, exactly one function changes. | `SystemSurfaceSnapshotBuilder.isSensitive` |
| 34a | **The speech-model catalog ships without published checksums.** | The model host is unreachable from the environment this was built in, so the digests could not be recorded truthfully. The installer enforces a checksum when one is present; without one it still checks the declared size within 20% and the `ggml` magic, which catches the failure that actually happens — a CDN error page saved under a model's name. Fill the digests in before shipping. | `LocalSpeechModelCatalog` |
| 34b | **One catalog entry's size is derived rather than measured.** | The `f16` sizes come from whisper.cpp's own README and are exact. The `q5_1` figure is computed from the quantization ratio, for the same unreachable-host reason. The 20% tolerance above is what protects against it being wrong, and a wrong number produces a clear rejection rather than a silently mis-sized install. | `LocalSpeechModelCatalog` |
| 34c | **Local Whisper produces no live partial results.** | Chunk-based streaming means re-decoding overlapping windows and reconciling transcripts that disagree at the seams. Done carelessly it produces text that reads fluently and says something the user did not — which is worse than no partials. The capability is declared false honestly and the composer shows "Transcribing…" after Stop rather than inventing text. | `LocalSpeechToTextProvider` |
| 34d | **Audio resampling is linear interpolation with no anti-aliasing filter.** | The alternative is `AVAudioConverter`, which does not exist in a Foundation-only target that CI compiles on Linux. Adequate for 16 kHz speech-recognition input; a real if minor quality cost when downsampling a 48 kHz microphone. Isolated in one function, so replacing it is a local change. | `SpeechAudioConverter.resample` |
| 34e | **Cancelling a Whisper decode is prompt, not instantaneous.** | whisper.cpp decodes in a tight native loop and offers an abort callback it checks between steps. That is the only shape cancellation can take from Swift, so Cancel abandons the decode within a step rather than immediately. No transcript is delivered either way, which is the part that matters. | `WhisperCppRuntime.cancelTranscription` |
| 30 | **Priority scores are not shown to the user.** The breakdown exists and is asserted on in tests; the UI shows a reason ("Waiting on: collect the forms") and never a number. | Someone who asked what to do next wants the answer, not arithmetic. The breakdown is kept as separate terms rather than one number so that *when the ordering is wrong*, a test and a log can say which rule misfired — which is a maintainer's need, not a user's. | `PriorityScoreBreakdown` |

---

## 2. `TODO-DEVICE` — compiles, never executed

Reasoned about and checked as far as a machine without an iPhone can check.
None of it has run. A CI runner has no calendar database, no notification
centre, no alarm daemon and no Apple Intelligence, which is why the decisions
worth testing were extracted into functions that need none of them — but the
framework calls themselves are unexercised.

| Area | What is unverified | Where |
| --- | --- | --- |
| Speech — Apple | Recognition accuracy with a real microphone, and how far behind the speaker partial results appear | `SFSpeechRecognizerBackend` |
| Speech — Apple | Which backend the chain selects on a given device and locale, and whether the on-device path is genuinely taken | `AppleSpeechToTextProvider` |
| Speech — Apple | Locale asset download, and whether `installedLocales` reports what the device actually has | `SpeechAnalyzerBackend` |
| Speech — Whisper | Model load time, real RAM use against the conservative estimate, and transcription speed | `WhisperCppRuntime` |
| Speech — Whisper | Whether Metal acceleration is actually engaged, and thermal behaviour on a long transcription | `WhisperCppRuntime` |
| Speech — OpenAI | Upload latency on a real connection, and cellular versus Wi-Fi including a mid-upload network change | `URLSessionTranscriptionTransport` |
| Speech — capture | Bluetooth input, a headset connecting mid-sentence, route changes, and interruption by a phone call | `AVAudioMicrophoneCaptureService` |
| Speech — capture | Whether the level meter tracks a real voice, and long-recording stability against the ten-minute bound | `SpeechAudioChunk.level` |
| Permissions | That each alert appears at the moment the action is attempted, and shows the right Info.plist string | `AppleEventKitStore` |
| Calendar | That "Add Events Only" really arrives as `.writeOnly` | `AppleEventKitStore` |
| Calendar | Which identifier a recurring event's occurrences report, and whether the derived domain id is stable across them | `AppleEventKitStore` |
| Notifications | A reminder arriving with all three buttons, and each reaching `FollowUpService` with the right outcome | `UserNotificationsService` |
| Notifications | Whether a withdrawn reminder actually leaves the lock screen | `UserNotificationsService` |
| Notifications | Foreground presentation while the app is open | `UserNotificationsService` |
| Cold launch | The queued-route replay: answering from the lock screen with the app not running | `AppleNotificationCoordinator` |
| Alarms | That anything sounds at all — the alert, its buttons, Snooze running the countdown, breaking through Focus and the silent switch | `AlarmKitAlarmService` |
| On-device AI | Every part of the generation path; which availability case a device reports; whether a refusal surfaces as `.refusal` or `.guardrailViolation` | `AppleFoundationModelsProvider` |
| On-device AI | Whether the framework pairs a `ToolCall` with its `ToolOutput` by the shared id this code gives them | `AppleFoundationSessionAdapter` |
| Voice | The microphone and speech alerts appearing, in order, with the right strings | `AppleSpeechInputService` |
| Voice | Live recognition: accuracy, and how far behind the speaker partial results lag | `AppleSpeechInputService` |
| Voice | The level meter responding to a real voice rather than to a number | `AppleSpeechInputService` |
| Voice | Bluetooth routing, and a headset disconnecting mid-sentence | `AppleSpeechInputService` |
| Voice | A phone call arriving while listening, and Retry working afterwards | `AppleSpeechInputService` |
| Voice | The TTS → microphone handoff: that `.immediate` really stops the recogniser hearing the assistant's own tail | `AppleSpeechOutputService` |
| Voice | Whether `.playAndRecord` with `.duckOthers` behaves acceptably over music already playing | `AppleSpeechInputService` |
| Siri | Discovery of the app's shortcuts, and whether the phrases are recognised as written | `AssistantAppShortcuts` |
| Siri | Shortcuts app discovery and how the parameter prompts read | `AssistantIntents` |
| Siri | Action Button assignment and invocation | `AssistantAppShortcuts` |
| Siri | Whether `openAppWhenRun = false` lets a whole engine turn finish in the background, and the system's real time limit | `AskAssistantIntent` |
| Siri | Provider availability when Siri woke the process — Keychain readability, Apple Intelligence usability | `AskAssistantIntent` |
| Siri | Opening the SwiftData store from a background launch | `AppIntentDependencies` |
| Background | Whether iOS grants a `BGAppRefreshTask` at all, how often, and how much time — which depends on usage, battery and Low Power Mode | `AppLifecycleCoordinator` |
| Background | That the expiration handler is reached under real suspension pressure and the pass stops cleanly, rather than only when a test cancels it | `AppLifecycleCoordinator.handle(_:)` |
| Background | That a notification scheduled a week out fires at the right moment, and survives a reboot and an app update | `UserNotificationsService` |
| Background | That pending requests survive a power cycle, and that the first launch afterwards reconciles rather than duplicating | `SupportReconciliationService` |
| Background | Force quit: that already-scheduled reminders still fire, and that recovery is correct the next time the app is opened | `SupportReconciliationService` |
| Background | Notification permission revoked in Settings while reminders are pending, and what the app then tells the user | `PlatformScheduleReconciler` |
| Background | How the rolling horizon behaves on an account with many active tasks, against the system's real limit on pending requests | `SupportCatchUpPolicy.schedulingHorizon` |
| Background | A device that changes time zone, or crosses a DST boundary, while the app is not running | `SupportReconciliationService` |
| Keyboard | Installation and discovery in Settings, and appearance in the globe-key rotation | `KeyboardViewController` |
| Keyboard | The next-keyboard control actually switching keyboards | `handleInputModeList(from:with:)` |
| Keyboard | Full Access on and off, including the moment it is granted | `KeyboardAssistantBridge` |
| Keyboard | Extension memory pressure — whether iOS kills the keyboard while someone is typing | `KeyboardViewController` |
| Keyboard | Typing across third-party apps, and apps that disable third-party keyboards | `KeyboardViewController` |
| Keyboard | Secure input fields refusing the keyboard | `KeyboardAssistantBar` |
| Widgets | Gallery discovery and Home Screen rendering | `PersonalAssistantWidgetBundle` |
| Widgets | Lock Screen accessory families at their real dimensions | `NextTaskWidget`, `SupportWidget` |
| Widgets | Always On behaviour, and `isLuminanceReduced` in practice | `TodayWidgetView` |
| Widgets | An interactive action performing in the widget extension's process | `SystemSurfaceIntents` |
| Widgets | WidgetKit's real refresh budget over a day of ordinary use | `WidgetTimelinePlanner` |
| Live Activities | Start, update and end on a real Lock Screen | `AppleLiveActivityCoordinator` |
| Live Activities | Dynamic Island compact, minimal and expanded rendering on supported hardware | `ExecutiveSupportLiveActivity` |
| Live Activities | ActivityKit behaviour after the app is suspended and after it is terminated | `AppleLiveActivityCoordinator` |
| Live Activities | Part 11 reconciliation ending a stale activity after a real absence | `SystemSurfaceService` |
| App Group | The container resolving under real signing — an unsigned CI build cannot carry the entitlement, so CI exercises the fallback | `SharedStoreLocation` |
| App Group | The SwiftData migration from the app container to the group container, on a device with a real store | `SharedStoreLocation.migrateIfNeeded` |

The full list, with the reasoning behind each, is in
[`Docs/BACKGROUND.md`](BACKGROUND.md#device-only-background-validation-remaining).

**The first scenario worth running**, because it tests the product's founding
claim end to end: ask for a reminder in ten minutes, lock the phone, and swipe
the notification away when it arrives. Watch what happens *after* — the task
should still be open and the assistant should come back.

---

## 3. `TODO-XCODE` — needs Xcode or an Apple SDK

Not an "unfinished" marker. Each of these is something that genuinely cannot be
done from a machine with no Apple toolchain.

| What | Sites | Note |
| --- | --- | --- |
| `#Preview` verification | 21 | Every SwiftUI preview is marked; none has been rendered |
| Keychain | 3 | `KeychainCredentialStore` has never run against a real Keychain |
| Voice input | 1 | `AVAudioEngine` capture and `SFSpeechRecognizer` — not started |
| AlarmKit initialiser | 1 | Uses the deprecated `AlarmPresentation.Alert` init on purpose — its replacement arrived partway through the iOS 26 line and would not compile against the earlier SDKs. Switch when the project's minimum Xcode passes that change. |
| Mock permissions | 1 | iOS permission alerts cannot be modelled in a mock |

`project.yml` is no longer on this list. It carried a `TODO-XCODE` saying it had
never been run through XcodeGen; both Apple workflows now generate the project
from it and compile the result on every build, so `1d5e202` retired the marker.
Opening the generated project in Xcode by hand is still unverified, and the file
says so in prose rather than claiming to be untested.

---

## What is verified

Worth stating alongside the gaps, so this file is not read as a list of
everything that is wrong.

| Workflow | Runner | Proves |
| --- | --- | --- |
| Swift Tests | macos-26 | The full suite compiles and runs, including the routing, identity, escalation, recurrence and permission mappings, the voice state machine and coordinator, and the EventKit and UserNotifications code (which compiles on macOS) |
| Apple SDK Check | macos-26 | EventKit, UserNotifications, AlarmKit and FoundationModels are present in the SDK, are really referenced by the built binary, and the two iOS 26 frameworks are **weakly** linked — the check that stops a launch crash on every iPhone below iOS 26. The Speech and AVFAudio code compiles here too, since `AppleSpeechInputService` is iOS-only |
| iOS Simulator Preview | macos-15 | The app builds against an older SDK (where AlarmKit does not exist), launches and renders |

App Intents definitions are validated by the compiler: a malformed
`ParameterSummary`, a phrase missing `\(.applicationName)`, or an entity with no
query are compile-time failures, so a green Apple SDK Check is meaningful
validation of the intent metadata — not merely that the files parse.

## Keeping this file honest

Add an entry when a decision has a cost someone could later mistake for an
oversight. Delete an entry when the thing is done, not when it is worked
around. If an item moves category — a deliberate limitation that becomes worth
fixing — say what changed, because the original reasoning is the thing a future
reader needs in order to disagree with it.
