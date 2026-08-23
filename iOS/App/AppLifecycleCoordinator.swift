import AssistantCore
import AssistantDomain
import Foundation

#if canImport(BackgroundTasks)
import BackgroundTasks
#endif

/// The app's execution moments, and what support does at each of them.
///
/// ## Why this is not in a view
///
/// Section 77. `.onChange(of: scenePhase)` is a perfectly good place to *notice*
/// that the app became active, and a terrible place to decide what that means:
/// a view can be recreated, can appear twice, can be replaced by a preview, and
/// none of that should change whether the user's reminders get reconciled.
/// SwiftUI calls one method here; everything else is application-level.
///
/// ## What actually schedules reminders
///
/// Not this. Sections 3 to 5, which are the architectural heart of the
/// milestone: user-facing timing is `UNUserNotificationCenter` and AlarmKit,
/// because those keep working when this process does not exist. This type only
/// arranges for reconciliation to happen when the app *does* get to run — at
/// launch, on foreground, and opportunistically in the background.
///
/// There is no timer anywhere in it. A `Task.sleep` that fires a reminder is a
/// reminder that stops existing when iOS suspends the app, which on a phone is
/// within seconds of the user switching away.
@MainActor
final class AppLifecycleCoordinator {
    private let environment: AppEnvironment
    /// The screen state, so a pass that found something can refresh what the
    /// user is looking at.
    ///
    /// Weak, and settable after construction, because the two are mutually
    /// dependent: `AppModel` is built from the environment and this is built
    /// alongside it. A strong reference here would be a cycle for the life of
    /// the process.
    weak var appModel: AppModel?
    /// Set while a background refresh is running, so its expiry handler can
    /// stop the pass rather than letting iOS kill the process mid-write.
    private var backgroundPass: Task<Void, Never>?

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    // MARK: Launch

    /// Runs once, after persistence and the platform services exist.
    ///
    /// Section 8: bounded, and deliberately *not* awaited by the UI. The screens
    /// render from persisted state, and blocking the first frame on a
    /// reconciliation pass would make a cold launch feel like a hang for the
    /// benefit of a correction the user cannot see happening.
    func applicationDidLaunch() {
        registerBackgroundTasks()
        // The widget extension may perform an intent while the app is running.
        // Handing it this composition is what stops it opening a second
        // `ModelContainer` over the same file.
        SystemSurfaceBridge.adopt(
            repositories: environment.repositories,
            services: environment.services,
            surfaces: environment.systemSurfaces
        )
        Task { [environment] in
            _ = try? await environment.engine.reconciliation.reconcile(trigger: .launch)
            // Section 75: after reconciliation, because reconciliation is
            // exactly the thing most likely to have changed what the widgets
            // should say. Section 65 in one line.
            await environment.systemSurfaces.refresh(reason: .launch)
            await scheduleNextRefresh()
        }
    }

    // MARK: Foreground

    /// Runs when the app becomes active.
    ///
    /// Section 9's case: backgrounded at 1 PM, a reminder due at 2 PM the user
    /// ignored, app reopened at 5 PM. A notification that was delivered and
    /// never answered produces no callback at all — iOS has nothing to report —
    /// so this sweep is the *only* thing that ever notices it.
    func applicationDidBecomeActive() async {
        if let appModel {
            // Through the view model, which also runs memory maintenance,
            // reloads the screens and says what changed. The pass itself is
            // single-flighted inside the service, so this cannot race a
            // background refresh that is already running — it joins it.
            await appModel.reconcileFollowUps(trigger: .foreground)
        } else {
            _ = try? await environment.engine.reconciliation.reconcile(trigger: .foreground)
        }
        await environment.systemSurfaces.refresh(reason: .foreground)
        // Section 23's other half. The keyboard cannot make this app run, so
        // the moment it *is* running is the moment to answer anything waiting.
        // Not a loop and not a timer — one look, when there is a process.
        await environment.keyboardAssistant.servicePendingRequest()
        await scheduleNextRefresh()
    }

    /// Runs when the app leaves the foreground.
    ///
    /// Deliberately almost nothing. Section 46: no inference is kept alive, no
    /// work is started that iOS will kill halfway. The one useful act is asking
    /// for a background refresh, so that if the app stays closed for a long
    /// time there is *some* chance of a pass before the user next opens it.
    func applicationDidEnterBackground() async {
        await scheduleNextRefresh()
    }

    // MARK: Background refresh

    /// The identifier declared in `Info.plist` under
    /// `BGTaskSchedulerPermittedIdentifiers`.
    ///
    /// A constant, never built at runtime (section 41): iOS matches the string
    /// against the plist at registration, and a mismatch is a crash at launch
    /// rather than a warning.
    static let refreshTaskIdentifier = "com.example.personalassistant.refresh"

    /// How far ahead to ask for the next refresh.
    ///
    /// A request, not a promise. Section 5 and section 38: `BGTaskScheduler`
    /// decides when — or whether — to run this, based on battery, charging
    /// state, and how often the user actually opens the app. Nothing about
    /// reminder correctness may depend on it firing, which is why the reminders
    /// themselves are `UNUserNotificationCenter`'s job and this is only ever an
    /// opportunity to tidy up early.
    static let refreshInterval: TimeInterval = TimeSpan.hours(4)

    private func registerBackgroundTasks() {
        #if canImport(BackgroundTasks) && os(iOS)
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.refreshTaskIdentifier,
            using: nil
        ) { [weak self] task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            // Hopped rather than assumed: iOS does not promise which queue the
            // launch handler runs on, and `assumeIsolated` on the wrong one is
            // a crash rather than a warning.
            Task { @MainActor in self?.handle(refresh) }
        }
        #endif
    }

    #if canImport(BackgroundTasks) && os(iOS)
    /// Runs one opportunistic pass, within whatever time iOS has granted.
    ///
    /// Sections 39 and 42. The work is the same reconciliation the foreground
    /// runs — there is no second, background-only state machine (section 1) —
    /// and it is short by construction: the pass is bounded by
    /// `SupportCatchUpPolicy` and every step commits before the next begins, so
    /// being stopped halfway leaves the store consistent rather than torn.
    private func handle(_ task: BGAppRefreshTask) {
        // Requested *before* the work, not after. If the pass is expired
        // partway through, the expiration handler still has to leave a
        // successor behind — and code after a cancellation may not run.
        Task { await scheduleNextRefresh() }

        let pass = Task { [environment] in
            _ = try? await environment.engine.reconciliation.reconcile(
                trigger: .backgroundRefresh
            )
            // Cheap, and the whole reason a background refresh is worth having
            // for widgets: the projections are rebuilt without the user having
            // opened anything.
            await environment.systemSurfaces.refresh(reason: .reconciliation)
        }
        backgroundPass = pass

        task.expirationHandler = { [environment] in
            // iOS is about to stop the process. Cancelling the pass lets it
            // stop at its next checkpoint with everything already committed
            // still committed — the alternative is being killed mid-write.
            //
            // Both halves matter: cancelling the enclosing `Task` interrupts
            // the await, and telling the service cancels the pass it is
            // actually running, which may have been started by a different
            // trigger and merely joined here.
            pass.cancel()
            Task { await environment.engine.reconciliation.cancel() }
        }

        Task {
            await pass.value
            backgroundPass = nil
            // Reported as a success even when the pass was cut short: the work
            // is resumable by design, and telling iOS the app failed would make
            // it less willing to grant time next time — for something that
            // behaved exactly as intended.
            task.setTaskCompleted(success: true)
        }
    }
    #endif

    /// Asks for one future refresh.
    ///
    /// Section 43: exactly one outstanding request at a time. Submitting from
    /// several places without care is how an app ends up with a queue of
    /// requests it did not intend, and `BGTaskScheduler` keeps only the latest
    /// per identifier anyway — so the discipline is about intent, not about
    /// what the API tolerates.
    private func scheduleNextRefresh() async {
        #if canImport(BackgroundTasks) && os(iOS)
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskIdentifier)
        request.earliestBeginDate = Date().addingTimeInterval(Self.refreshInterval)
        // A throw here is entirely normal: the simulator has no background
        // scheduler, and iOS refuses when the app is not permitted background
        // refresh at all. Neither is an error worth surfacing — the reminders
        // are already scheduled with the notification centre, and this was only
        // ever an optimisation.
        try? BGTaskScheduler.shared.submit(request)
        #endif
    }
}
