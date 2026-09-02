import AIProviderApple
import AIProviderLocal
import AIProviderLocalLlama
import AIProviderRemote
import AssistantAI
import AssistantCore
import AssistantDomain
import AssistantPersistence
import AssistantPlatform
import AssistantTools
import AssistantVoice
import ExecutiveSupport
import Foundation
import Observation

/// Application-wide state the screens share.
///
/// This is the presentation layer's view of the core: it loads from the
/// repositories and platform services, exposes plain values for SwiftUI to
/// render, and turns user intent back into calls on `AssistantEngine`. It holds
/// no business rules of its own — completing a task, dismissing a reminder and
/// planning reminders all happen in the core.
///
/// Per-screen state (filters, drafts, sheet routing) lives in the individual
/// view models, not here. Only genuinely shared things do.
@MainActor
@Observable
final class AppModel {
    // MARK: Shared state

    private(set) var conversation: Conversation
    private(set) var tasks: [TaskItem] = []
    private(set) var memories: [MemoryItem] = []
    private(set) var events: [CalendarItem] = []
    private(set) var reminderPlans: [ReminderPlan] = []
    /// The recurring responsibilities themselves, not their occurrences.
    private(set) var routines: [Routine] = []
    private(set) var settings = AssistantSettings()
    private(set) var profile = UserProfile()
    private(set) var providerOptions: [ProviderOption] = []

    /// The remote provider's non-secret settings, mirrored for the UI.
    private(set) var remoteConfiguration = RemoteAIConfiguration()
    /// Whether an API key is stored. The key itself is never held here — the
    /// UI only ever needs to know that one exists.
    private(set) var hasRemoteAPIKey = false

    /// Action plans and results, keyed by plan, so the conversation can render
    /// what the assistant actually did beneath what it said.
    ///
    /// Read from `ActionPlanRepository` when a conversation loads, so the cards
    /// under a reply are still there after a relaunch.
    private(set) var actionPlans: [ActionPlanID: AssistantActionPlan] = [:]
    private(set) var toolResults: [ActionPlanID: [ToolResult]] = [:]

    /// True while a turn is in flight. Drives the typing indicator; never
    /// blocks the composer.
    private(set) var isAssistantResponding = false

    /// Set while a local model is being read into memory for the turn that is
    /// about to start, and holding the sentence to show.
    ///
    /// Section 46. A local load is seconds of nothing — a mmap of a couple of
    /// gigabytes and a Metal warm-up — and the typing indicator alone cannot
    /// tell that apart from a model that is thinking. Naming what is happening
    /// is the difference between a wait and a hang.
    private(set) var assistantLoadingNotice: String?

    /// What the OS currently allows, per capability.
    ///
    /// Read with `status(for:)`, which never prompts, so showing this screen
    /// cannot put an alert in front of someone who only came to look. The
    /// prompt happens when an action needs the permission, or when the user
    /// taps the row here and asks for it.
    private(set) var permissions: [PlatformCapability: PermissionStatus] = [:]

    /// A reminder being simulated in-app. See `SimulatedReminder`.
    var simulatedReminder: SimulatedReminder?

    /// Speech in and out, when this build has it.
    ///
    /// Created once and shared, rather than owned by the Assistant screen: a
    /// spoken request that is still processing must survive the user switching
    /// tabs, and a reply being read aloud must be stoppable from anywhere.
    private(set) var voice: VoiceCoordinator?

    /// The task to show because the user tapped its notification.
    ///
    /// Set from the notification router's `.open` route, which is the one
    /// response that changes nothing: tapping a reminder means "let me look at
    /// this", not "I've done it". Showing the task and letting them say which
    /// is the whole point.
    var focusedTask: FocusedTask?

    /// Transient confirmation text shown after an action.
    var banner: BannerMessage?

    /// Internal rather than private so `AppModel`'s own extensions — which
    /// live in separate files for readability — can reach it. The rule Part 10
    /// established still holds and is what matters: *views* do not reach past
    /// `AppModel` into the environment, and none do.
    let environment: AppEnvironment

    var now: Date { environment.dateProvider.now }
    var calendar: Calendar { environment.dateProvider.calendar }

    /// Whether calendar writes reach the device.
    ///
    /// Asked of the service rather than inferred from the launch
    /// configuration, so a screen cannot describe the app's honesty wrongly by
    /// consulting the wrong thing. `PlatformFidelity` travels with the service
    /// exactly so this question has one answer.
    var calendarIsLive: Bool { environment.services.calendar.fidelity == .live }

    /// Downloading, verifying, loading and deleting local models.
    ///
    /// Exposed rather than reached through `environment` by views: the
    /// model-management screen genuinely drives this service directly —
    /// downloads outlive the screen and cancellation has to reach the one that
    /// is running — and routing every call through a wrapper method here would
    /// be a second API to keep in step for no benefit.
    var localModels: LocalModelManager { environment.localModels }

    /// The dedicated action model, for the screen that selects and loads it.
    ///
    /// Exposed for the same reason `localModels` is, and kept visibly separate
    /// from it: they are two model lifecycles, and a single accessor would
    /// invite a screen to change one while meaning the other.
    var actionModelHost: ActionModelHost { environment.actionModelHost }

    /// The local-inference crash trail, and the previous session's remains.
    ///
    /// Held on the app model rather than created per screen so the recovery
    /// summary is read once, at launch, and the acknowledgement of its banner
    /// survives navigation.
    let localDiagnostics: LocalInferenceDiagnosticsCentre

    init(environment: AppEnvironment) {
        self.environment = environment
        self.conversation = Conversation(createdAt: environment.dateProvider.now)
        self.localDiagnostics = LocalInferenceDiagnosticsCentre(
            logger: environment.localDiagnostics,
            store: environment.localDiagnosticStore
        )
    }

    // MARK: Loading

    /// Opens the user's data and loads everything the screens display.
    ///
    /// A production launch reads whatever is in the store and writes nothing:
    /// a new user gets an empty conversation, an empty task list and no
    /// memories. Demo content is only ever written when the launch
    /// configuration asks for it, which happens in previews, in CI and in a
    /// developer's debug build — never in a shipped app. See
    /// `AppLaunchConfiguration`.
    func bootstrap() async {
        // First line of the session, before anything can fail. Section 17: if
        // the process dies during bootstrap, the launch record and the previous
        // session's recovery are already on disk.
        localDiagnostics.recordLaunch()
        // Connected first, before anything that can fail. A "Done" tapped on
        // the lock screen is already queued inside the coordinator by the time
        // this runs, and it should be applied even if loading the screens goes
        // wrong afterwards.
        connectNotifications()
        connectVoice()

        do {
            if environment.launch.seedsDemoData {
                _ = try await DemoDataSeeder(environment: environment).seedIfNeeded()
            }
            conversation = try await loadOrStartConversation()
            await reload()
            await refreshProviderState()
        } catch {
            banner = BannerMessage(text: "Couldn't load your data.", style: .warning)
        }
    }

    /// Routes notification responses into the lifecycle and back into the UI.
    ///
    /// The closures are the only part of this that belongs to the presentation
    /// layer. Deciding what a response *means* happened in
    /// `AppleNotificationRouter`, and applying it happens in `FollowUpService`;
    /// what is left here is showing the user the result.
    /// Builds the voice coordinator, if this build has speech services.
    ///
    /// The `submit` closure is `send(_:from:)` — the same method the composer's
    /// send button calls. Not a copy, not a variant: the identical function,
    /// which is what makes "voice cannot bypass a layer" true by construction
    /// rather than by review.
    private func connectVoice() {
        guard let services = environment.voice else { return }
        voice = VoiceCoordinator(
            input: services.input,
            output: services.output,
            submit: { [weak self] text in
                await self?.send(text, from: .voice)
            }
        )
        Task { [weak self] in await self?.voice?.refreshPermissions() }
    }

    private func connectNotifications() {
        environment.connectNotificationRouting(
            onOpen: { [weak self] taskID in
                await self?.focus(taskID)
            },
            onChange: { [weak self] in
                await self?.reload()
            }
        )
    }

    /// Whether the microphone button should do anything.
    ///
    /// Not simply `voice != nil`: the coordinator always exists, because a
    /// device with no Speech framework gets `UnavailableSpeechInputService`
    /// rather than nothing at all. What decides this is the permission state
    /// that service reports — `unsupported` means the capability does not exist
    /// here, and the button is disabled with a reason instead of opening a
    /// session that was never going to work.
    var isVoiceAvailable: Bool {
        guard let voice else { return false }
        return voice.permissions.combined != .unsupported
    }

    private func focus(_ taskID: TaskItem.ID) async {
        await reload()
        focusedTask = FocusedTask(id: taskID)
    }

    /// Opens a task because something outside the app asked for it.
    ///
    /// A widget deep link, today. Reloads first so the detail screen is drawn
    /// from current state rather than from whatever was in memory when the app
    /// was last put away — which, for a widget tap, may be hours ago.
    func focusTask(_ taskID: TaskItem.ID) {
        Task { await focus(taskID) }
    }

    /// The conversation to show, and the action history beneath it.
    ///
    /// The most recently updated conversation is the one the user was last in.
    /// If there is none — a first launch — one is created and saved, so the
    /// first message has somewhere to go.
    private func loadOrStartConversation() async throws -> Conversation {
        let existing = try await environment.repositories.conversations.allConversations()

        guard let latest = existing.first else {
            actionPlans = [:]
            toolResults = [:]
            return try await environment.engine.startConversation(title: "Assistant")
        }

        try await loadActionHistory(for: latest.id)
        return latest
    }

    /// Rebuilds the cards shown under past assistant replies.
    ///
    /// Without this the transcript would come back as plain text: every
    /// `Message.actionPlanID` would point at a plan nothing had kept, and the
    /// event cards, reminder timelines and "simulated" badges would be gone
    /// with no sign that anything had been dropped.
    private func loadActionHistory(for conversationID: Conversation.ID) async throws {
        let records = try await environment.repositories.actionPlans.records(
            inConversation: conversationID
        )

        var plans: [ActionPlanID: AssistantActionPlan] = [:]
        var results: [ActionPlanID: [ToolResult]] = [:]
        for record in records {
            plans[record.plan.id] = record.plan
            results[record.plan.id] = record.results
        }
        actionPlans = plans
        toolResults = results
    }

    /// Re-reads everything the screens display.
    ///
    /// Deliberately coarse: the data set is small, and one refresh path is far
    /// easier to reason about than incremental invalidation.
    func reload() async {
        do {
            tasks = try await environment.repositories.tasks.tasks(matching: TaskFilter())
            memories = try await environment.repositories.memories.all()
            settings = try await environment.repositories.settings.settings()
            profile = try await environment.repositories.profile.profile()
            reminderPlans = try await loadReminderPlans()
            routines = try await environment.repositories.routines.routines(activeOnly: false)
        } catch {
            banner = BannerMessage(text: "Couldn't refresh.", style: .warning)
        }

        await reloadCalendar()
        await reloadPermissions()
        await refreshSystemSurfaces()
    }

    // MARK: System surfaces

    /// Rebuilds the widget projections and brings the Live Activities in line.
    ///
    /// Hung off `reload()` because that is what runs after anything meaningful
    /// changes — a task created, a reminder answered, a routine occurrence
    /// generated — which is section 75's list. Not on a timer, and not on every
    /// repository read: `SystemSurfaceService` compares each projection against
    /// what is already stored and asks WidgetKit for a refresh only when the
    /// content genuinely differs.
    ///
    /// Deliberately not awaited by anything that can fail because of it
    /// (section 85). A widget that did not update is a widget showing something
    /// slightly old; a completion that failed because a widget could not be
    /// written would be a task the user believes they finished.
    func refreshSystemSurfaces(reason: SystemSurfaceRefreshReason = .domainChange) async {
        await environment.systemSurfaces.setLiveActivitiesEnabled(
            SystemSurfaceSettings.liveActivitiesEnabled
        )
        await environment.systemSurfaces.refresh(reason: reason)
        await environment.systemSurfaces.publishKeyboardConfiguration(
            assistantActionsEnabled: SystemSurfaceSettings.keyboardAssistantEnabled
        )
    }

    /// Section 89. The user's own switch — turning it off ends what is running.
    func setLiveActivitiesEnabled(_ enabled: Bool) async {
        await environment.systemSurfaces.setLiveActivitiesEnabled(enabled)
        await environment.systemSurfaces.refresh(reason: .settingChanged)
    }

    /// Republishes what the keyboard is allowed to offer.
    ///
    /// Widgets are not reloaded for this: a keyboard toggle changes nothing a
    /// widget shows, and spending a WidgetKit refresh on it is exactly the
    /// waste section 36 asks to avoid.
    func setKeyboardAssistantEnabled(_ enabled: Bool) async {
        await environment.systemSurfaces.publishKeyboardConfiguration(
            assistantActionsEnabled: enabled
        )
    }

    private func reloadPermissions() async {
        var statuses: [PlatformCapability: PermissionStatus] = [:]
        for capability in PlatformCapability.allCases {
            statuses[capability] = await environment.services.permissions.status(for: capability)
        }
        permissions = statuses
    }

    /// Asks for a capability because the user tapped a row asking for it.
    ///
    /// The one place a permission prompt is triggered by visiting a screen
    /// rather than by an action needing it — and it is still the user's doing.
    /// If the answer is already settled iOS shows nothing, so the row offers
    /// this only while the question is genuinely open.
    func requestPermission(_ capability: PlatformCapability) async {
        permissions[capability] = await environment.services.permissions.request(capability)
    }

    /// The calendar, separately, because it is the one source that can be
    /// switched off.
    ///
    /// Everything above comes from this app's own store and fails only if the
    /// database is broken. The calendar belongs to iOS and the user may have
    /// declined it, granted add-only access, or turned it off since last
    /// launch — none of which is a reason for the task list, the memories and
    /// the settings to disappear from the screen.
    ///
    /// The banner names the calendar specifically. "Couldn't refresh" for a
    /// permission the user themselves declined is a message that sends someone
    /// looking for a bug.
    private func reloadCalendar() async {
        do {
            events = try await environment.services.calendar.events(
                in: TimeWindow(
                    start: calendar.startOfDay(for: now),
                    end: now.addingTimeInterval(TimeSpan.days(60))
                )
            )
        } catch {
            events = []
            let status = await environment.services.permissions.status(for: .calendar)
            switch status {
            case .granted, .notDetermined:
                banner = BannerMessage(text: "Couldn't read your calendar.", style: .warning)
            case .denied, .limited:
                banner = BannerMessage(
                    text: "Calendar access is off, so your schedule isn't shown.",
                    style: .warning
                )
            case .restricted, .unsupported:
                // Nothing the user can do about it, so nothing is said. A
                // banner they cannot act on is just noise on every launch.
                break
            }
        }
    }

    private func loadReminderPlans() async throws -> [ReminderPlan] {
        var plans: [ReminderPlan] = []
        for task in tasks {
            guard let planID = task.reminderPlanID else { continue }
            if let plan = try await environment.repositories.reminderPlans.plan(id: planID) {
                plans.append(plan)
            }
        }
        for event in events {
            let found = try await environment.repositories.reminderPlans.plans(
                for: .calendarItem(event.id)
            )
            plans.append(contentsOf: found)
        }
        // Keep one entry per plan; a plan can be reachable from both sides.
        var unique: [ReminderPlan.ID: ReminderPlan] = [:]
        for plan in plans { unique[plan.id] = plan }
        return Array(unique.values)
    }

    /// Re-reads provider availability and the remote configuration.
    ///
    /// Called after anything that could change readiness, so the model selector
    /// never shows a stale "Setup needed".
    func refreshProviderState() async {
        remoteConfiguration = environment.remoteConfiguration.current
        hasRemoteAPIKey = await environment.hasRemoteAPIKey()
        providerOptions = await environment.providerOptions()
        await refreshAssistantChoices()
    }

    /// Re-reads the on-device model's full runtime state.
    ///
    /// Deliberately not stored on this model and not persisted. It describes
    /// one instant on one device: caching it is exactly the bug that makes a
    /// phone report `modelNotReady` forever after the assets have finished
    /// downloading. Every caller gets a fresh read.
    func appleFoundationModelsDiagnostic() async -> AppleFoundationModelsDiagnostic {
        await environment.appleFoundationModelsDiagnostic()
    }

    /// What this build's on-device inference runtime is, and whether it works.
    ///
    /// Read fresh, like the Apple one, and for the same reason: "is llama.cpp
    /// in this binary" is a compile-time fact, but "did it initialize" is not,
    /// and caching the pair would hide a runtime that came up on the second
    /// attempt.
    func localRuntimeDiagnostic() async -> LocalRuntimeDiagnostic {
        await LocalRuntimeResolver.diagnostic()
    }

    /// Runs one native decode with as little of this app around it as possible.
    ///
    /// Sections 35 to 43. The chosen model is named explicitly by the caller
    /// (section 71) rather than inferred from what happens to be selected, and
    /// the resident model is unloaded first (section 70): the harness opens its
    /// own `llama_context`, and two live contexts on one device is the very
    /// concurrency variable this pass is trying to remove.
    ///
    /// Refuses outright while a turn is in flight, for the same reason.
    func runMinimalNativeDecodeTest(
        on modelID: AIModelIdentifier
    ) async -> MinimalDecodeOutcome {
        guard !isAssistantResponding else {
            return .failed(
                stage: .minimalPromptDecode,
                reason: "The assistant is answering. Wait for it to finish and try again."
            )
        }
        guard let fileURL = await localModels.installedFileURL(for: modelID) else {
            return .failed(
                stage: .modelLoad,
                reason: "That model is not installed on this iPhone."
            )
        }
        await localModels.unload()
        let harness = CanonicalMinimalDecodeHarness(diagnostics: environment.localDiagnostics)
        return await harness.run(modelURL: fileURL, modelID: modelID)
    }

    /// A status coordinator for the Apple On-Device screen.
    ///
    /// Built per screen rather than held here, because its automatic refresh is
    /// scoped to that screen being open. A long-lived one on `AppModel` would
    /// be a polling loop the rest of the app has no way to stop.
    ///
    /// It is handed the same provider instance the engine uses, so the status
    /// it reports is the status `respond(to:)` would act on.
    func makeAppleModelStatusCoordinator() -> AppleModelStatusCoordinator {
        AppleModelStatusCoordinator(source: environment.appleProvider)
    }

    /// Saves the remote endpoint and model, and the key if one was entered.
    ///
    /// `apiKey` is `nil` when the user did not touch the field, which leaves any
    /// stored key alone; an empty string clears it.
    func saveRemoteConfiguration(baseURL: String, model: String, apiKey: String?) async {
        environment.remoteConfiguration.update(baseURL: baseURL, model: model)

        if let apiKey {
            do {
                try await environment.setRemoteAPIKey(apiKey.isEmpty ? nil : apiKey)
            } catch {
                banner = BannerMessage(
                    text: "Couldn't save the API key to the keychain.",
                    style: .warning
                )
            }
        }

        await refreshProviderState()
        banner = BannerMessage(text: "Remote AI settings saved.", style: .success)
    }

    func clearRemoteAPIKey() async {
        do {
            try await environment.setRemoteAPIKey(nil)
            await refreshProviderState()
            banner = BannerMessage(text: "API key removed.", style: .neutral)
        } catch {
            banner = BannerMessage(text: "Couldn't remove the API key.", style: .warning)
        }
    }

    /// The provider currently selected in settings, if it is one the user can
    /// choose. Used by the Assistant screen's notice.
    var selectedProviderOption: ProviderOption? {
        guard let id = settings.preferredProviderID else { return nil }
        return providerOptions.first { $0.id == id }
    }

    // MARK: Lookups

    func task(id: TaskItem.ID) -> TaskItem? {
        tasks.first { $0.id == id }
    }

    func routine(id: Routine.ID) -> Routine? {
        routines.first { $0.id == id }
    }

    /// The routine an occurrence belongs to, if it is one.
    func routine(forTask task: TaskItem) -> Routine? {
        task.routineID.flatMap { routine(id: $0) }
    }

    func event(id: CalendarItem.ID) -> CalendarItem? {
        events.first { $0.id == id }
    }

    func memory(id: MemoryItem.ID) -> MemoryItem? {
        memories.first { $0.id == id }
    }

    func reminderPlan(id: ReminderPlan.ID) -> ReminderPlan? {
        reminderPlans.first { $0.id == id }
    }

    func reminderPlan(forEvent eventID: CalendarItem.ID) -> ReminderPlan? {
        reminderPlans.first { $0.subject.reference == .calendarItem(eventID) }
    }

    func reminderPlan(forTask taskID: TaskItem.ID) -> ReminderPlan? {
        reminderPlans.first { $0.subject.reference == .task(taskID) }
    }

    // MARK: Conversation

    /// Sends a message through the real turn pipeline.
    ///
    /// The provider behind it is the scripted development stand-in, so the
    /// *words* are canned — but the tool decoding, authorization, reminder
    /// planning and (simulated) execution around them are the production path.
    @discardableResult
    func send(_ text: String) async -> Bool {
        await send(text, from: .typed)
    }

    /// The one door into the assistant, for typed and spoken input alike.
    ///
    /// `source` changes exactly one thing — whether the reply is read aloud —
    /// and it is applied *after* the turn, in the presentation layer. It is not
    /// passed to `AssistantEngine`, does not reach a provider, is not stored on
    /// the message and does not alter context assembly, memory retrieval, tool
    /// validation, authorization or follow-up planning. A sentence spoken and
    /// the same sentence typed produce byte-identical work.
    /// Returns false when nothing was sent, so the composer can put the text
    /// back rather than swallowing a message that never reached the assistant.
    @discardableResult
    func send(_ text: String, from source: MessageInputSource) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isAssistantResponding else { return false }

        // Claimed before the preflight, not after: a local load takes seconds,
        // and leaving the flag false through it would let a second tap start a
        // second turn against a model that is still arriving.
        isAssistantResponding = true
        defer { isAssistantResponding = false }

        // Sections 47 and 48. A local turn is decided before it starts: the
        // weights load here, with something on screen saying so, rather than
        // inside the provider where the only visible effect is a spinner that
        // does not move. A state nothing can answer from refuses outright
        // instead of spending the wait to arrive at the same answer.
        guard await prepareLocalModelIfNeeded() else { return false }

        do {
            let result = try await environment.engine.send(trimmed, in: conversation.id)
            conversation = result.conversation
            actionPlans[result.plan.id] = result.plan
            toolResults[result.plan.id] = result.results
            await reload()

            // Presentation, after the fact. The engine returned a string and
            // has no idea anything might say it out loud.
            if settings.voice.shouldSpeak(replyTo: source) {
                await voice?.speak(result.assistantMessage.text)
            }
        } catch {
            // Surfaced rather than swallowed: if the provider cannot answer, the
            // user is told why, and the composer never sits in a silent
            // loading state.
            banner = BannerMessage(text: Self.describe(error), style: .warning)
        }
        return true
    }

    /// Loads the chosen local model before the turn, or explains why not.
    ///
    /// Returns false when the turn must not start. The load is idempotent —
    /// `LocalModelManager.load` returns immediately for a model already
    /// resident — so this costs a state read on every other send.
    ///
    /// Nothing here downloads. A model that is not on the device is a refusal
    /// with a route to Manage Models, never a gigabyte started on somebody's
    /// cellular connection because they typed a sentence (section 106).
    private func prepareLocalModelIfNeeded() async -> Bool {
        guard settings.preferredProviderID == AssistantLocalChoices.localProviderID else {
            return true
        }

        let manager = environment.localModels
        let name = activeAssistantChoice?.title
        let decision = LocalTurnPreflight.decide(
            availability: await manager.availability(),
            modelName: name
        )

        switch decision {
        case .proceed:
            return true
        case .refuse(let reason):
            banner = BannerMessage(text: reason, style: .warning)
            return false
        case .loadFirst(let notice):
            assistantLoadingNotice = notice
            defer { assistantLoadingNotice = nil }
            do {
                _ = try await manager.ensureSelectedModelLoaded()
                return true
            } catch let error as LocalRuntimeError {
                banner = BannerMessage(
                    text: LocalTurnPreflight.loadFailureMessage(error),
                    style: .warning
                )
                return false
            } catch {
                banner = BannerMessage(
                    text: "The local model couldn't be loaded.",
                    style: .warning
                )
                return false
            }
        }
    }

    /// Turns a provider failure into a sentence worth reading.
    ///
    /// The remote layer has already mapped HTTP statuses and transport errors
    /// into explanations; this only unwraps them. No case can contain a
    /// credential — `RemoteAIError` never carries one.
    private static func describe(_ error: any Error) -> String {
        guard let providerError = error as? AIProviderError else {
            if error is CancellationError { return "Cancelled." }
            return "The assistant couldn't respond right now."
        }

        switch providerError {
        case .notImplemented(let detail), .unavailable(let detail):
            return detail
        case .missingCredentials(let detail):
            return detail
        case .modelNotFound(let id):
            return "The model \(id) isn't available."
        case .transport(let detail), .invalidResponse(let detail):
            return detail
        case .cancelled:
            return "Cancelled."
        }
    }

    // MARK: Tasks

    func completeTask(_ id: TaskItem.ID, stageID: ReminderStage.ID? = nil) async {
        await handle(.completed, for: id, stageID: stageID, fallback: "Marked as done.")
    }

    /// "I'm doing it."
    ///
    /// Explicitly not completion. It buys quiet — the planner moves the next
    /// check-in out rather than cancelling it — because intending to do
    /// something is not doing it, and that gap is the entire problem this app
    /// exists for.
    func startTask(_ id: TaskItem.ID, stageID: ReminderStage.ID? = nil) async {
        await handle(.acknowledged, for: id, stageID: stageID, fallback: "Marked as in progress.")
    }

    func snoozeTask(_ id: TaskItem.ID, minutes: Int = 10, stageID: ReminderStage.ID? = nil) async {
        let until = now.addingTimeInterval(TimeSpan.minutes(Double(minutes)))
        await handle(
            .snoozed(until: until),
            for: id,
            stageID: stageID,
            fallback: "Snoozed for \(minutes) minutes."
        )
    }

    /// Records that a reminder was dismissed.
    ///
    /// The core decides what that means, and it never means "done". This is the
    /// single most important behaviour in the product, so the UI deliberately
    /// has no path that turns a dismissal into a completion.
    func dismissReminder(for id: TaskItem.ID, stageID: ReminderStage.ID? = nil) async {
        await handle(
            .dismissed,
            for: id,
            stageID: stageID,
            fallback: "Dismissed. Still on your list."
        )
    }

    /// Brings pending reminders up to date with the clock.
    ///
    /// Called when the app becomes active. A reminder whose moment passed while
    /// the app was closed is missed, and missed means the assistant tries
    /// again — without this, closing the app would be a way to make support
    /// stop.
    func reconcileFollowUps(trigger: ReconciliationTrigger = .foreground) async {
        do {
            // Routines first. Generating today's occurrences before reconciling
            // reminders means a routine whose moment passed while the app was
            // closed is caught in the same pass, rather than appearing an hour
            // later once something else happened to trigger a reload.
            // Memory maintenance rides along on the same foreground pass:
            // vectors for anything new or edited, repeated facts collapsed,
            // stale guesses moved out of the way. Bounded, deterministic and
            // offline — and entirely optional, which is why its failure is
            // swallowed separately below rather than being allowed to stop the
            // reconciliation the user can actually see.
            async let maintenance = try? environment.engine.memoryMaintenance.run()

            // One pass, owning the order: routines first so a missed
            // occurrence exists as a task, then overdue reminders, then the
            // OS schedule diffed against what iOS actually holds. Single-
            // flighted inside the service, so a background refresh arriving at
            // the same moment joins this pass rather than racing it.
            let report = try await environment.engine.reconciliation.reconcile(
                trigger: trigger
            )
            _ = await maintenance
            guard report.didChange else { return }
            await reload()

            guard report.missedStages > 0 else {
                // Occurrences appeared or expired, but no reminder was missed.
                // Nothing to announce: the Today list already shows it, and a
                // banner for "your routine still exists" is noise.
                return
            }

            // Said out loud rather than silently rescheduling. Repeated
            // interventions the user cannot see or explain are how an assistant
            // becomes something to switch off.
            //
            // Counted, never listed. After a week away the honest number can be
            // dozens, and naming each one is the notification storm the
            // catch-up policy exists to prevent, merely relocated into a banner.
            banner = BannerMessage(
                text: report.missedStages == 1
                    ? "You missed a reminder — I've scheduled another."
                    : "You missed \(report.missedStages) reminders — I've scheduled a follow-up.",
                style: .neutral
            )
        } catch {
            // Reconciliation is a background correction, not something the user
            // asked for. Failing it quietly is better than an alarming banner
            // about an operation they did not initiate.
        }
    }

    func reopenTask(_ id: TaskItem.ID) async {
        guard var task = task(id: id) else { return }
        task.status = .notStarted
        task.completedAt = nil
        task.updatedAt = now
        await save(task, banner: "Reopened.")
    }

    /// "Help me start."
    ///
    /// Distinct from ``startTask(_:stageID:)``, which records that the user has
    /// already begun. This one is for the person who has not, and cannot: it
    /// hands back one concrete first step and *then* moves the task into
    /// progress. Encouragement is not what is missing; a next physical action
    /// is.
    ///
    /// It never completes anything, and the banner shows the step rather than a
    /// congratulation.
    func helpMeStart(_ id: TaskItem.ID) async {
        do {
            let support = try await environment.engine.startSupport.start(taskID: id)
            await reload()
            banner = BannerMessage(text: support.summary, style: .success)
        } catch {
            banner = BannerMessage(text: "Couldn't work out a first step for that.", style: .warning)
        }
    }

    /// Ticks off one preparation step. Never the task itself — section 45.
    func completePreparationStep(_ stepID: PreparationStep.ID, taskID: TaskItem.ID) async {
        do {
            let outcome = try await environment.engine.startSupport.completeStep(stepID, taskID: taskID)
            await reload()
            banner = BannerMessage(
                text: outcome.next.map { "Done. Next: \($0.title)." }
                    ?? "That's all the steps — the task itself is still open.",
                style: .success
            )
        } catch {
            banner = BannerMessage(text: "Couldn't update that step.", style: .warning)
        }
    }

    /// Resolves one occurrence of a routine without touching the routine.
    ///
    /// "Skip the gym today" means today, not forever — section 105. Cancelling
    /// would read everywhere else as calling off the responsibility itself.
    func skipOccurrence(_ id: TaskItem.ID) async {
        do {
            let skipped = try await environment.engine.routines.skipOccurrence(id)
            await reload()
            banner = BannerMessage(
                text: "Skipped \(skipped.title) for today. The routine carries on.",
                style: .neutral
            )
        } catch {
            banner = BannerMessage(text: "Couldn't skip that one.", style: .warning)
        }
    }

    func updateTask(_ task: TaskItem) async {
        var updated = task
        updated.updatedAt = now
        await save(updated, banner: nil)
    }

    func deleteTask(_ id: TaskItem.ID) async {
        do {
            try await environment.repositories.tasks.delete(id: id)
            await reload()
            banner = BannerMessage(text: "Task deleted.", style: .neutral)
        } catch {
            banner = BannerMessage(text: "Couldn't delete that task.", style: .warning)
        }
    }

    /// The one route from a button to the support lifecycle.
    ///
    /// Every task action in the UI goes through here, which is what stops a new
    /// screen from quietly inventing its own idea of what "dismiss" means. The
    /// banner prefers the planner's own rationale — "You dismissed the last
    /// reminder without finishing this" — over a generic confirmation, so the
    /// user can see why another reminder exists.
    private func handle(
        _ outcome: ReminderOutcome,
        for id: TaskItem.ID,
        stageID: ReminderStage.ID?,
        fallback: String
    ) async {
        do {
            let result = try await environment.engine.followUp.handle(
                outcome: outcome,
                forTask: id,
                stageID: stageID
            )
            await reload()

            guard result.didChange else { return }
            banner = BannerMessage(
                text: message(for: result, fallback: fallback),
                style: outcome.resolvesTask ? .success : .neutral
            )
        } catch {
            banner = BannerMessage(text: "Couldn't update that task.", style: .warning)
        }
    }

    private func message(for result: FollowUpResult, fallback: String) -> String {
        guard let next = result.nextReminder else {
            return result.rationale ?? fallback
        }
        let when = AppFormatters.shared.relativeDayAndTime(next.fireDate, now: now)
        return "\(fallback.hasSuffix(".") ? fallback : fallback + ".") I'll check back \(when)."
    }

    private func save(_ task: TaskItem, banner text: String?) async {
        do {
            try await environment.repositories.tasks.save(task)
            await reload()
            if let text {
                banner = BannerMessage(text: text, style: .success)
            }
        } catch {
            banner = BannerMessage(text: "Couldn't save that task.", style: .warning)
        }
    }

    // MARK: Memory

    /// Something the user typed into the Memory screen.
    ///
    /// Goes through `MemoryService` like everything else, so writing down what
    /// the assistant already knew updates that record rather than adding a
    /// second row saying the same thing. Source and confidence come from
    /// `.manual`, not from numbers chosen here.
    func addMemory(content: String, kind: MemoryKind) async {
        do {
            let result = try await environment.memory.remember(
                MemoryItem(
                    kind: kind,
                    content: content,
                    salience: 0.6,
                    createdAt: now,
                    source: .manual
                )
            )
            await reload()
            banner = BannerMessage(
                text: result.effect == .stored ? "I'll remember that." : result.summary,
                style: .success
            )
        } catch {
            banner = BannerMessage(text: "Couldn't save that memory.", style: .warning)
        }
    }

    /// An edit to a memory the user is looking at.
    ///
    /// Authoritative and never deduplicated — they are changing this exact
    /// record. Folding their edit into a similar memory would look, from their
    /// side, like the app refusing to save.
    func updateMemory(_ memory: MemoryItem, content: String, kind: MemoryKind) async {
        var updated = memory
        updated.content = content
        updated.kind = kind
        do {
            _ = try await environment.memory.update(updated)
            await reload()
        } catch {
            banner = BannerMessage(text: "Couldn't update that memory.", style: .warning)
        }
    }

    func deleteMemory(_ id: MemoryItem.ID) async {
        do {
            try await environment.memory.forget(id: id)
            await reload()
            banner = BannerMessage(text: "Forgotten.", style: .neutral)
        } catch {
            banner = BannerMessage(text: "Couldn't delete that memory.", style: .warning)
        }
    }

    /// Brings an archived or fading memory back into use.
    ///
    /// The point of archiving rather than deleting: aging is the app's guess
    /// about what stopped mattering, and a guess the user can reverse in one tap
    /// is a very different thing from data quietly disposed of.
    func restoreMemory(_ id: MemoryItem.ID) async {
        do {
            let restored = try await environment.memory.restore(id: id)
            await reload()
            banner = BannerMessage(
                text: "Back in use: \(restored.content)",
                style: .success
            )
        } catch {
            banner = BannerMessage(text: "Couldn't restore that memory.", style: .warning)
        }
    }

    /// The memories a consolidated fact was built from.
    ///
    /// Read from what is already loaded rather than queried, because the Memory
    /// screen has the whole store in hand and "based on 3 similar memories"
    /// should not cost a round trip to render.
    func sourceMemories(of memory: MemoryItem) -> [MemoryItem] {
        memory.consolidatedFrom.compactMap { id in memories.first { $0.id == id } }
    }

    // MARK: Settings

    func updateSettings(_ transform: (inout AssistantSettings) -> Void) async {
        var updated = settings
        transform(&updated)
        do {
            try await environment.repositories.settings.update(updated)
            settings = updated
        } catch {
            banner = BannerMessage(text: "Couldn't save that setting.", style: .warning)
        }
    }

    /// Switching the model changes one settings field and nothing else.
    ///
    /// Conversations, memories, tasks, reminder plans and preferences all live
    /// in the repositories, which the provider never touches.
    func selectProvider(_ id: AIProviderIdentifier) async {
        await updateSettings { $0.preferredProviderID = id }
        await refreshProviderState()
        banner = BannerMessage(
            text: "Model changed. Nothing else moved.",
            style: .neutral
        )
    }

    /// The assistant choices the chat picker offers.
    ///
    /// Built from the provider registry plus the installed local models, so
    /// there is one source of truth rather than a hardcoded list in the view
    /// (section 21 and 61). Local entries are filtered by
    /// `AssistantLocalChoices`, which is the rule worth testing.
    private(set) var assistantChoices: [AssistantModelChoice] = []

    /// What will answer the next message.
    var activeAssistantChoice: AssistantModelChoice? {
        let providerID = settings.preferredProviderID
        return assistantChoices.first { choice in
            guard choice.providerID == providerID else { return false }
            guard choice.modelID != nil else { return true }
            return choice.modelID == settings.selectedLocalModelID
        }
    }

    /// Re-reads the pickable assistants.
    func refreshAssistantChoices() async {
        var choices: [AssistantModelChoice] = []
        for option in providerOptions {
            if option.metadata.kind == .downloadedLocalModel {
                // One entry per downloaded, compatible model rather than a
                // single "Local AI": which model answers is the actual choice.
                choices.append(
                    contentsOf: AssistantLocalChoices.choices(
                        from: await environment.localModels.statuses()
                    )
                )
            } else if option.isAvailable {
                choices.append(
                    AssistantModelChoice(
                        providerID: option.id,
                        modelID: nil,
                        title: option.metadata.displayName,
                        subtitle: option.metadata.requiresNetwork ? "Cloud" : "On device"
                    )
                )
            }
        }
        assistantChoices = choices
    }

    /// Applies a pick from the chat selector.
    ///
    /// Selection only. Section 24 and 25: choosing a local model records the
    /// choice and stops — the weights are loaded when the first message needs
    /// them, not here, because a multi-gigabyte load on a menu tap is how a
    /// picker becomes a hang.
    func selectAssistantChoice(_ choice: AssistantModelChoice) async {
        if let modelID = choice.modelID {
            // Switching models releases whatever was resident. `select` does
            // that, and does it before the new one is ever loaded, so two large
            // models are never in memory at once (section 26).
            try? await environment.localModels.select(modelID)
            await updateSettings {
                $0.preferredProviderID = choice.providerID
                $0.selectedLocalModelID = modelID
            }
        } else {
            // Leaving Local AI frees the runtime rather than leaving gigabytes
            // resident behind a provider nobody is using (section 27).
            await environment.localModels.unload()
            await updateSettings { $0.preferredProviderID = choice.providerID }
        }
        // Refreshing provider state re-derives the choice list too.
        await refreshProviderState()
        banner = BannerMessage(
            text: "Model changed. Nothing else moved.",
            style: .neutral
        )
    }

    func updateProfile(_ transform: (inout UserProfile) -> Void) async {
        var updated = profile
        transform(&updated)
        do {
            try await environment.repositories.profile.update(updated)
            profile = updated
        } catch {
            banner = BannerMessage(text: "Couldn't save your profile.", style: .warning)
        }
    }

    // MARK: Simulated reminders

    /// Presents an in-app reminder so the response flow can be exercised.
    ///
    /// This is **not** an iOS notification. Nothing is scheduled with the
    /// system; the sheet is drawn by the app while it is in the foreground.
    ///
    /// Real delivery now exists alongside it. This is kept because it is the
    /// only way to exercise the response flow without waiting for a reminder to
    /// come due — useful in a simulator, where a lock-screen notification is
    /// awkward to produce on demand. It stays labelled a simulation.
    func simulateReminder(for reminder: SimulatedReminder) {
        simulatedReminder = reminder
    }

    func respondToSimulatedReminder(_ response: SimulatedReminderResponse) async {
        guard let reminder = simulatedReminder else { return }
        simulatedReminder = nil

        // The stage id travels with the answer, so the outcome lands on the
        // reminder that prompted it rather than on the task in general.
        let stageID = reminder.stageID

        switch (response, reminder.subject) {
        case (.doingIt, .task(let id)):
            await startTask(id, stageID: stageID)
        case (.doingIt, .event):
            banner = BannerMessage(text: "Good — I'll stop nudging.", style: .success)
        case (.completed, .task(let id)):
            await completeTask(id, stageID: stageID)
        case (.completed, .event):
            banner = BannerMessage(text: "Marked as handled.", style: .success)
        case (.snooze, .task(let id)):
            await snoozeTask(id, stageID: stageID)
        case (.snooze, .event):
            banner = BannerMessage(text: "I'll remind you again shortly.", style: .neutral)
        case (.dismiss, .task(let id)):
            await dismissReminder(for: id, stageID: stageID)
        case (.dismiss, .event):
            banner = BannerMessage(
                text: "Dismissed. The event is still on your calendar.",
                style: .neutral
            )
        }
    }

    // MARK: Demo data

    /// True when this launch is running on seeded, temporary storage.
    ///
    /// Drives whether the developer section appears at all. It reads the launch
    /// configuration rather than `#if DEBUG` directly, so a debug build opened
    /// normally — on the developer's own real data — is treated exactly like a
    /// user's.
    var isRunningOnDemoData: Bool { environment.launch.seedsDemoData }

    /// Rebuilds the demo dataset.
    ///
    /// Guarded, because this deletes conversations, tasks and memories before
    /// writing the fake ones. On a normal launch those would be the user's. The
    /// guard is the enforcement; hiding the button is only the courtesy.
    func resetDemoData() async {
        guard isRunningOnDemoData else {
            banner = BannerMessage(
                text: "Demo data isn't available on your own storage.",
                style: .warning
            )
            return
        }

        do {
            let seeded = try await DemoDataSeeder(environment: environment).reseed()
            conversation = seeded.conversation
            actionPlans = seeded.actionPlans
            toolResults = seeded.toolResults
            await reload()
            banner = BannerMessage(text: "Demo data reset.", style: .neutral)
        } catch {
            banner = BannerMessage(text: "Couldn't reset demo data.", style: .warning)
        }
    }
}

/// A task the app has been asked to show.
///
/// A wrapper rather than the bare id because `.sheet(item:)` needs something
/// `Identifiable`, and `TaskItem.ID` is deliberately not — an identifier that
/// identifies itself invites exactly the confusion between a thing and its name
/// that the `Identifier` type exists to prevent.
struct FocusedTask: Identifiable, Hashable {
    let id: TaskItem.ID
}

/// A short confirmation shown after an action.
struct BannerMessage: Identifiable, Equatable {
    enum Style {
        case success
        case neutral
        case warning
    }

    let id = UUID()
    let text: String
    let style: Style
}
