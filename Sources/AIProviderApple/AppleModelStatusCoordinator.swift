import Foundation
import Observation

/// Where the status screen gets its readings.
///
/// A protocol so the coordinator can be driven by a script in a test. The
/// production conformance is `AppleFoundationModelsProvider` itself, which is
/// what keeps the framework query inside the provider boundary — SwiftUI never
/// becomes the owner of FoundationModels logic.
///
/// `throws` because the app's own integration can fail, and that failure has to
/// stay distinguishable from Apple reporting `modelNotReady`.
public protocol AppleModelStatusSource: Sendable {
    func currentDiagnostic() async throws -> AppleFoundationModelsDiagnostic
}

extension AppleFoundationModelsProvider: AppleModelStatusSource {
    public func currentDiagnostic() async throws -> AppleFoundationModelsDiagnostic {
        await diagnostic()
    }
}

/// Holds the on-device model's status, and re-asks while that could change.
///
/// ## Why this is not in the view
///
/// A `.task` in a SwiftUI body restarts on every identity change, runs twice
/// under a navigation animation, and leaves a loop running if the view is
/// rebuilt while the previous body's task is still suspended. Polling written
/// there tends to end up with two loops, or none, and no way to tell which.
///
/// Here it is one object with an explicit lifecycle: start, stop, and a single
/// task handle that can only hold one loop.
///
/// ## What it guarantees
///
/// * Exactly one automatic loop, however many times `start` is called.
/// * The loop only exists while the status is `modelPreparing`, and cancels
///   itself the moment a check returns anything else.
/// * `Check Again` during an in-flight check joins that check rather than
///   starting a second one.
/// * `lastCheckedAt` moves when a check *completes* — never because a view
///   redrew.
@MainActor
@Observable
public final class AppleModelStatusCoordinator {

    /// One interval, in one place.
    ///
    /// Ten seconds: slow enough that a phone preparing a model for twenty
    /// minutes performs a hundred-odd cheap local reads rather than thousands,
    /// fast enough that somebody watching the screen sees it change without
    /// wondering whether it is stuck.
    public static let automaticRefreshInterval: TimeInterval = 10

    public private(set) var status: AppleModelStatus = .modelPreparing
    /// The full snapshot from the previous debug pass, kept so the diagnostic
    /// rows survive this one.
    public private(set) var diagnostic: AppleFoundationModelsDiagnostic?
    /// When a check last *finished*. Nil until the first one has.
    public private(set) var lastCheckedAt: Date?
    public private(set) var isChecking = false
    /// True while the automatic loop exists. Exposed for tests and for the
    /// screen, which has no other way to know it is being kept up to date.
    public private(set) var isAutomaticallyRefreshing = false

    private let source: any AppleModelStatusSource
    private let now: @MainActor () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    /// The single automatic loop. Non-nil exactly while one is running.
    private var pollingTask: Task<Void, Never>?
    /// The check currently in flight, so a second request can join it.
    private var inFlight: Task<Void, Never>?

    /// Lets `deinit` cancel the loop without touching main-actor state.
    private let liveTasks = TaskHandleBox()

    public init(
        source: any AppleModelStatusSource,
        now: @escaping @MainActor () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) {
        self.source = source
        self.now = now
        self.sleep = sleep
    }

    deinit {
        // A screen dismissed mid-download must not leave a loop behind.
        liveTasks.cancelAll()
    }

    // MARK: Checking

    /// Reads the current availability, once.
    ///
    /// Serves both the manual "Check Again" and each tick of the automatic
    /// loop, so there is one code path that can update the status and one place
    /// the timestamp is written.
    ///
    /// If a check is already running this joins it rather than starting a
    /// second: two simultaneous reads would race to write `status` and could
    /// leave the older answer in place.
    public func refresh() async {
        if let inFlight {
            await inFlight.value
            return
        }
        let task = Task { @MainActor in await self.performCheck() }
        inFlight = task
        liveTasks.track(task)
        await task.value
        inFlight = nil
    }

    private func performCheck() async {
        isChecking = true
        defer { isChecking = false }

        do {
            let snapshot = try await source.currentDiagnostic()
            diagnostic = snapshot
            status = AppleModelStatus(snapshot.state)
        } catch {
            // Section: never dressed up as `modelNotReady`. The diagnostic from
            // the previous successful read is deliberately kept, so the screen
            // does not go blank while reporting the failure.
            status = .checkFailed(String(describing: error))
        }

        // Written after the read completes, which is what makes it mean
        // "when the system was last asked" rather than "when the view drew".
        lastCheckedAt = now()

        // A loop that has done its job ends itself, rather than waiting for the
        // view to notice and call stop.
        if !status.pollsAutomatically {
            stopAutomaticRefresh()
        }
    }

    // MARK: The automatic loop

    /// Starts re-checking, if the current status is one that can change.
    ///
    /// Idempotent. Calling it from `.task`, from `.onAppear` and again after
    /// every check — which the screen does — still yields one loop.
    public func startAutomaticRefreshIfNeeded() {
        guard pollingTask == nil, status.pollsAutomatically else { return }

        isAutomaticallyRefreshing = true
        let interval = Self.automaticRefreshInterval
        let task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    try await self.sleep(interval)
                } catch {
                    // Cancelled mid-wait. Nothing to clean up: whoever
                    // cancelled owns the state.
                    return
                }
                guard !Task.isCancelled else { return }
                await self.refresh()
                // `performCheck` already stops the loop when the status
                // settles; this is the belt to that braces.
                if !self.status.pollsAutomatically { return }
            }
        }
        pollingTask = task
        liveTasks.track(task)
    }

    /// Stops re-checking. Safe to call when nothing is running.
    public func stopAutomaticRefresh() {
        pollingTask?.cancel()
        pollingTask = nil
        isAutomaticallyRefreshing = false
    }

    /// The first read, plus the loop if it is warranted.
    ///
    /// What the screen calls when it appears.
    public func begin() async {
        await refresh()
        startAutomaticRefreshIfNeeded()
    }

    /// What the screen calls when it goes away.
    public func end() {
        stopAutomaticRefresh()
    }
}

/// Somewhere `deinit` can reach the tasks.
///
/// A `@MainActor` class's `deinit` is not main-actor isolated, so it cannot
/// read `pollingTask` directly. This box can be touched from anywhere, holds
/// only cancellation handles, and drops finished ones as it goes so a long
/// session does not accumulate them.
private final class TaskHandleBox: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [Task<Void, Never>] = []

    func track(_ task: Task<Void, Never>) {
        lock.lock()
        defer { lock.unlock() }
        tasks.removeAll { $0.isCancelled }
        tasks.append(task)
    }

    func cancelAll() {
        lock.lock()
        let current = tasks
        tasks.removeAll()
        lock.unlock()
        for task in current { task.cancel() }
    }
}
