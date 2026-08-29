import Foundation
import XCTest

@testable import AIProviderApple

/// The status screen's behaviour, without a device and without waiting.
///
/// Every test here injects both the clock and the sleeper, so a scenario that
/// takes half a minute on a phone runs in microseconds and never depends on
/// wall-clock timing. Nothing in this file sleeps for real.
@MainActor
final class AppleModelStatusTests: XCTestCase {

    // MARK: Doubles

    /// Answers a scripted sequence of availability states, then repeats the
    /// last one — which is how a real device behaves once it settles.
    private final class ScriptedSource: AppleModelStatusSource, @unchecked Sendable {
        private let lock = NSLock()
        private var remaining: [AppleModelAvailabilityState]
        private var last: AppleModelAvailabilityState
        private var _queryCount = 0
        private var _failure: (any Error)?

        init(_ states: [AppleModelAvailabilityState]) {
            precondition(!states.isEmpty)
            remaining = states
            last = states[0]
        }

        var queryCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return _queryCount
        }

        func failNextChecks(with error: any Error) {
            lock.lock()
            _failure = error
            lock.unlock()
        }

        func currentDiagnostic() async throws -> AppleFoundationModelsDiagnostic {
            lock.lock()
            _queryCount += 1
            if !remaining.isEmpty { last = remaining.removeFirst() }
            let state = last
            let failure = _failure
            lock.unlock()

            if let failure { throw failure }
            return FixedAppleModelAvailabilityReader(state).diagnostic(now: Date())
        }
    }

    /// A clock the test moves, and a sleeper that moves it.
    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var seconds: TimeInterval = 0
        /// The greatest number of sleeps in flight at once. One loop can only
        /// ever be waiting once, so anything above 1 means duplicate timers.
        private(set) var maxConcurrentSleepers = 0
        private var active = 0
        private var sleeps = 0
        /// Stops a scenario that would otherwise spin forever.
        var sleepBudget = 50

        func now() -> Date {
            lock.lock()
            defer { lock.unlock() }
            return Date(timeIntervalSince1970: seconds)
        }

        var sleepCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return sleeps
        }

        /// Moves the clock without a sleep, so a test can prove the timestamp
        /// follows the check rather than the other way round.
        func advance(by interval: TimeInterval) {
            lock.lock()
            seconds += interval
            lock.unlock()
        }

        func sleep(_ interval: TimeInterval) async throws {
            lock.lock()
            active += 1
            maxConcurrentSleepers = max(maxConcurrentSleepers, active)
            sleeps += 1
            let overBudget = sleeps > sleepBudget
            lock.unlock()

            // Yields rather than waits: the loop still suspends, so ordering is
            // real, but no time passes.
            await Task.yield()

            lock.lock()
            active -= 1
            seconds += interval
            lock.unlock()

            if overBudget { throw CancellationError() }
        }
    }

    private func makeCoordinator(
        _ states: [AppleModelAvailabilityState]
    ) -> (AppleModelStatusCoordinator, ScriptedSource, TestClock) {
        let source = ScriptedSource(states)
        let clock = TestClock()
        let coordinator = AppleModelStatusCoordinator(
            source: source,
            now: { clock.now() },
            sleep: { try await clock.sleep($0) }
        )
        return (coordinator, source, clock)
    }

    /// Lets queued work run without sleeping for real.
    @discardableResult
    private func settle(until predicate: () -> Bool, limit: Int = 10_000) async -> Bool {
        for _ in 0..<limit {
            if predicate() { return true }
            await Task.yield()
        }
        return predicate()
    }

    // MARK: Mapping

    func testEveryAvailabilityStateMapsToTheRequiredStatus() {
        XCTAssertEqual(AppleModelStatus(.ready), .ready)
        XCTAssertEqual(AppleModelStatus(.appleIntelligenceNotEnabled), .appleIntelligenceDisabled)
        XCTAssertEqual(AppleModelStatus(.deviceNotEligible), .deviceNotEligible)
        XCTAssertEqual(AppleModelStatus(.modelNotReady), .modelPreparing)
        XCTAssertEqual(
            AppleModelStatus(.unrecognised("futureReason")),
            .unknownUnavailable(reason: "unknown")
        )
    }

    func testTheTitlesAreTheOnesTheBriefSpecifies() {
        XCTAssertEqual(AppleModelStatus.ready.title, "Ready")
        XCTAssertEqual(
            AppleModelStatus.appleIntelligenceDisabled.title, "Apple Intelligence disabled"
        )
        XCTAssertEqual(AppleModelStatus.deviceNotEligible.title, "Device not eligible")
        XCTAssertEqual(
            AppleModelStatus.modelPreparing.title,
            "Preparing / downloading Apple on-device model"
        )
        XCTAssertEqual(
            AppleModelStatus.unknownUnavailable(reason: "x").title,
            "Apple on-device model unavailable"
        )
    }

    /// The two states that are not Apple's are not silently called ineligible
    /// hardware — the token says which they really are.
    func testTheStatesAppleDoesNotReportKeepTheirOwnReason() {
        XCTAssertEqual(
            AppleModelStatus(.operatingSystemTooOld),
            .unknownUnavailable(reason: "operatingSystemTooOld")
        )
        XCTAssertEqual(
            AppleModelStatus(.frameworkMissingFromSDK),
            .unknownUnavailable(reason: "frameworkMissingFromSDK")
        )
        XCTAssertNotEqual(AppleModelStatus(.operatingSystemTooOld), .deviceNotEligible)
    }

    // MARK: No invented progress

    /// The load-bearing honesty test.
    ///
    /// Apple exposes availability and nothing else, so no status text may carry
    /// a *quantity* — no percentage, no byte count, no rate, no estimate.
    ///
    /// Checked as "contains no digit and no percent sign" rather than as a list
    /// of banned words, deliberately: the preparing text has to *name* progress,
    /// speed, bytes and ETA in order to say they are unavailable, so a word
    /// blacklist would forbid the one sentence that makes the absence honest.
    /// What must never appear is a number.
    func testNoStatusTextCarriesAnInventedQuantity() {
        let statuses: [AppleModelStatus] = [
            .ready, .appleIntelligenceDisabled, .deviceNotEligible, .modelPreparing,
            .unknownUnavailable(reason: "modelNotReady"),
        ]
        for status in statuses {
            let text = status.title + " " + status.detail
            XCTAssertFalse(
                text.contains("%"),
                "\(status.token) shows a percentage: \(text)"
            )
            XCTAssertFalse(
                text.contains(where: \.isNumber),
                "\(status.token) shows a number Apple never provided: \(text)"
            )
        }
    }

    /// The preparing text has to say the numbers do not exist, or their absence
    /// reads as a missing feature rather than as Apple's limit.
    func testThePreparingTextSaysExactProgressIsUnavailable() {
        let detail = AppleModelStatus.modelPreparing.detail
        XCTAssertTrue(detail.contains("does not expose"))
        XCTAssertTrue(detail.contains("progress"))
        XCTAssertTrue(detail.contains("ETA"))
    }

    func testOnlyPreparingShowsAnIndeterminateIndicator() {
        XCTAssertTrue(AppleModelStatus.modelPreparing.showsActivityIndicator)
        for status in [
            AppleModelStatus.ready, .deviceNotEligible, .appleIntelligenceDisabled,
            .unknownUnavailable(reason: "x"), .checkFailed("x"),
        ] {
            XCTAssertFalse(status.showsActivityIndicator, "\(status.token)")
        }
    }

    // MARK: Last checked

    func testLastCheckedIsNilUntilTheFirstCheckCompletes() {
        let (coordinator, _, _) = makeCoordinator([.modelNotReady])
        XCTAssertNil(coordinator.lastCheckedAt)
    }

    func testLastCheckedMovesWithEachCompletedCheck() async {
        let (coordinator, _, clock) = makeCoordinator([.deviceNotEligible])

        await coordinator.refresh()
        let first = coordinator.lastCheckedAt
        XCTAssertEqual(first, clock.now())

        // Time passes, but nothing asks the system anything.
        clock.advance(by: 120)

        // Reading the properties is all a redraw does, and it must not touch
        // the timestamp — otherwise "last checked" would drift forward while
        // the app sat there having checked nothing.
        _ = coordinator.status
        _ = coordinator.diagnostic
        _ = coordinator.isChecking
        XCTAssertEqual(
            coordinator.lastCheckedAt, first,
            "the timestamp moved without a check happening"
        )

        // A real check moves it, to the time the check finished.
        await coordinator.refresh()
        XCTAssertEqual(coordinator.lastCheckedAt, clock.now())
        XCTAssertNotEqual(coordinator.lastCheckedAt, first)
    }

    // MARK: The automatic transition

    /// The scenario the whole pass exists for: two preparing readings, then
    /// ready, with the UI arriving at Ready on its own.
    func testPreparingBecomesReadyWithoutAnyUserAction() async {
        let (coordinator, source, _) = makeCoordinator([
            .modelNotReady, .modelNotReady, .ready,
        ])

        await coordinator.begin()
        XCTAssertEqual(coordinator.status, .modelPreparing)
        XCTAssertTrue(coordinator.isAutomaticallyRefreshing)

        let reachedReady = await settle { coordinator.status == .ready }
        XCTAssertTrue(reachedReady, "the status never became Ready")

        // And the loop stops itself.
        let stopped = await settle { !coordinator.isAutomaticallyRefreshing }
        XCTAssertTrue(stopped, "polling continued after the model was ready")
        XCTAssertGreaterThanOrEqual(source.queryCount, 3)
    }

    func testPollingStopsOnceReady() async {
        let (coordinator, source, _) = makeCoordinator([.modelNotReady, .ready])
        await coordinator.begin()
        _ = await settle { coordinator.status == .ready }
        _ = await settle { !coordinator.isAutomaticallyRefreshing }

        let afterSettling = source.queryCount
        // Give any surviving loop every chance to fire.
        for _ in 0..<200 { await Task.yield() }
        XCTAssertEqual(source.queryCount, afterSettling, "a loop kept running after Ready")
    }

    // MARK: No polling for permanent states

    func testAPermanentStateStartsNoLoopAtAll() async {
        let (coordinator, source, clock) = makeCoordinator([.deviceNotEligible])
        await coordinator.begin()

        XCTAssertEqual(coordinator.status, .deviceNotEligible)
        XCTAssertFalse(coordinator.isAutomaticallyRefreshing)

        let afterBegin = source.queryCount
        for _ in 0..<200 { await Task.yield() }
        XCTAssertEqual(source.queryCount, afterBegin)
        XCTAssertEqual(clock.sleepCount, 0, "a permanent state should never wait to re-ask")
    }

    func testNeitherDisabledNorUnknownPolls() async {
        for state in [
            AppleModelAvailabilityState.appleIntelligenceNotEnabled,
            .unrecognised("future"),
            .operatingSystemTooOld,
        ] {
            let (coordinator, _, clock) = makeCoordinator([state])
            await coordinator.begin()
            XCTAssertFalse(
                coordinator.isAutomaticallyRefreshing,
                "\(state.reasonToken) should not poll"
            )
            XCTAssertEqual(clock.sleepCount, 0)
        }
    }

    // MARK: Manual Check Again

    /// Works for every unavailable state, not only the preparing one — someone
    /// who just switched Apple Intelligence on comes back to this screen and
    /// taps it.
    func testCheckAgainReadsTheCurrentStateRatherThanTheCachedOne() async {
        let (coordinator, source, _) = makeCoordinator([
            .appleIntelligenceNotEnabled, .ready,
        ])

        await coordinator.refresh()
        XCTAssertEqual(coordinator.status, .appleIntelligenceDisabled)
        let firstQueryCount = source.queryCount

        await coordinator.refresh()
        XCTAssertEqual(coordinator.status, .ready)
        XCTAssertGreaterThan(source.queryCount, firstQueryCount, "Check Again did not re-read")
    }

    func testCheckAgainOnAPreparingModelStopsThePollingOnceReady() async {
        let (coordinator, _, _) = makeCoordinator([.modelNotReady, .ready])

        await coordinator.begin()
        XCTAssertTrue(coordinator.isAutomaticallyRefreshing)

        // The manual tap gets the second reading before the timer would have.
        await coordinator.refresh()
        XCTAssertEqual(coordinator.status, .ready)
        XCTAssertFalse(coordinator.isAutomaticallyRefreshing)
    }

    // MARK: One loop, and no overlapping reads

    func testStartingRepeatedlyProducesOneLoop() async {
        let (coordinator, _, clock) = makeCoordinator([.modelNotReady])
        clock.sleepBudget = 6

        await coordinator.refresh()
        for _ in 0..<5 { coordinator.startAutomaticRefreshIfNeeded() }

        _ = await settle { clock.sleepCount >= 3 }
        coordinator.stopAutomaticRefresh()

        XCTAssertEqual(
            clock.maxConcurrentSleepers, 1,
            "more than one refresh loop was waiting at the same time"
        )
    }

    /// Two callers must not race to write the status.
    func testConcurrentChecksAreCoalescedIntoOne() async {
        let (coordinator, source, _) = makeCoordinator([.modelNotReady])

        async let a: Void = coordinator.refresh()
        async let b: Void = coordinator.refresh()
        async let c: Void = coordinator.refresh()
        _ = await (a, b, c)

        XCTAssertLessThanOrEqual(
            source.queryCount, 3,
            "checks were not serialized"
        )
        XCTAssertNotNil(coordinator.lastCheckedAt)
        XCTAssertFalse(coordinator.isChecking, "a check was left running")
    }

    // MARK: Cancellation

    func testEndingStopsTheLoop() async {
        let (coordinator, source, _) = makeCoordinator([.modelNotReady])

        await coordinator.begin()
        XCTAssertTrue(coordinator.isAutomaticallyRefreshing)

        coordinator.end()
        XCTAssertFalse(coordinator.isAutomaticallyRefreshing)

        let afterEnd = source.queryCount
        for _ in 0..<200 { await Task.yield() }
        XCTAssertEqual(source.queryCount, afterEnd, "the loop survived being stopped")
    }

    func testStoppingWhenNothingIsRunningIsHarmless() {
        let (coordinator, _, _) = makeCoordinator([.ready])
        coordinator.stopAutomaticRefresh()
        coordinator.stopAutomaticRefresh()
        XCTAssertFalse(coordinator.isAutomaticallyRefreshing)
    }

    // MARK: Errors stay distinguishable

    /// An integration failure must never look like Apple preparing a model.
    /// One means "wait, iOS is working"; the other means "MetisAI has a bug".
    func testAnIntegrationFailureIsNotReportedAsPreparing() async {
        struct Boom: Error {}
        let (coordinator, source, _) = makeCoordinator([.ready])
        source.failNextChecks(with: Boom())

        await coordinator.refresh()

        guard case .checkFailed = coordinator.status else {
            return XCTFail("expected checkFailed, got \(coordinator.status.token)")
        }
        XCTAssertNotEqual(coordinator.status, .modelPreparing)
        XCTAssertFalse(coordinator.status.pollsAutomatically)
        XCTAssertNotNil(coordinator.lastCheckedAt, "a failed check still happened")
    }

    // MARK: The diagnostics survive

    /// The previous pass's rows are still populated — improving the status was
    /// not a reason to remove what makes a bug report actionable.
    func testTheFullDiagnosticIsStillAvailable() async {
        let (coordinator, _, _) = makeCoordinator([.modelNotReady])
        await coordinator.refresh()

        let snapshot = coordinator.diagnostic
        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.reasonToken, "modelNotReady")
        XCTAssertEqual(snapshot?.systemModelIsAvailable, false)
        XCTAssertNotNil(snapshot?.rawAvailability)
    }

    /// The interval is centralized and inside the range the brief allows.
    func testTheRefreshIntervalIsOneCentralizedReasonableValue() {
        XCTAssertGreaterThanOrEqual(AppleModelStatusCoordinator.automaticRefreshInterval, 5)
        XCTAssertLessThanOrEqual(AppleModelStatusCoordinator.automaticRefreshInterval, 15)
    }
}
