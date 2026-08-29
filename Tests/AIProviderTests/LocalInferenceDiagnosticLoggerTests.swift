import AssistantAI
import AssistantDomain
import Foundation
import XCTest

@testable import AIProviderLocal

/// The logger, the file it writes, and the trail it leaves behind.
///
/// Everything here runs against a real directory in the temporary folder,
/// because the property under test is "the bytes reached the filesystem" and a
/// double would assert the opposite of what matters.
final class LocalInferenceDiagnosticLoggerTests: XCTestCase {

    private var store: LocalInferenceDiagnosticStore!

    override func setUp() {
        super.setUp()
        store = .temporary()
        try? store.prepareDirectory()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: store.directory)
        store = nil
        super.tearDown()
    }

    private func makeLogger(
        verbose: Bool = true,
        id: LocalInferenceSessionID = LocalInferenceSessionID()
    ) -> LocalInferenceDiagnosticLogger {
        LocalInferenceDiagnosticLogger(store: store, verbose: verbose, appSessionID: id)
    }

    // MARK: Persistence

    /// The whole premise: a breadcrumb is on disk while the process is still
    /// running, not when it shuts down tidily.
    func testACriticalEnterIsOnDiskBeforeTheCallReturns() throws {
        let logger = makeLogger()
        _ = logger.criticalEnter(.contextCreate, metadata: .empty)

        // Read the file with no shutdown, no flush call, no cooperation from
        // the logger — exactly what a second process would see if this one were
        // killed on the next line.
        let data = try Data(contentsOf: store.url(forSession: logger.appSessionID))
        let decoded = LocalInferenceDiagnosticCoding.decode(data)

        XCTAssertEqual(decoded.events.count, 1)
        XCTAssertEqual(decoded.events.first?.type, .enter)
        XCTAssertEqual(decoded.events.first?.stage, .contextCreate)
    }

    func testSequenceNumbersAreStrictlyIncreasing() {
        let logger = makeLogger()
        for _ in 0..<20 {
            logger.info(.appLaunch, category: .lifecycle)
        }
        let events = store.read(session: logger.appSessionID)?.events ?? []
        XCTAssertEqual(events.count, 20)
        XCTAssertEqual(events.map(\.sequence), Array(1...20))
    }

    /// Section 114. The sequence number is claimed under a lock, so concurrent
    /// callers cannot produce a duplicate or a gap — which is what makes
    /// ordering recoverable when two events share a millisecond.
    func testConcurrentCallsStillProduceAStrictlyIncreasingSequence() {
        let logger = makeLogger()
        let iterations = 200

        DispatchQueue.concurrentPerform(iterations: iterations) { _ in
            logger.info(.generationProgress, category: .generation)
        }

        let events = store.read(session: logger.appSessionID)?.events ?? []
        XCTAssertEqual(events.count, iterations)
        XCTAssertEqual(
            Set(events.map(\.sequence)).count, iterations,
            "two events were given the same sequence number"
        )
        XCTAssertEqual(events.map(\.sequence).sorted(), Array(1...iterations))
    }

    /// Section 79: one file per session, named so recovery can find it.
    func testEachSessionGetsItsOwnFile() {
        let first = makeLogger()
        first.info(.appLaunch, category: .lifecycle)
        first.endSession(clean: true)

        let second = makeLogger()
        second.info(.appLaunch, category: .lifecycle)

        let files = store.sessionFiles().map(\.id.rawValue)
        XCTAssertTrue(files.contains(first.appSessionID.rawValue))
        XCTAssertTrue(files.contains(second.appSessionID.rawValue))
    }

    // MARK: Verbose

    /// Section 110, and the distinction the whole verbose setting turns on:
    /// progress is noise, breadcrumbs are the point.
    func testDisablingVerboseSuppressesProgressButNotBreadcrumbsOrErrors() {
        let logger = makeLogger(verbose: false)

        logger.verbose(.generationProgress, category: .generation)
        let operation = logger.criticalEnter(.promptDecode, metadata: .empty)
        logger.criticalExit(.promptDecode, operation: operation, metadata: .empty)
        logger.problem(.nativeError, category: .runtime)

        let events = store.read(session: logger.appSessionID)?.events ?? []
        XCTAssertFalse(
            events.contains { $0.name == .generationProgress },
            "a verbose progress line survived with verbose logging off"
        )
        XCTAssertTrue(events.contains { $0.type == .enter && $0.stage == .promptDecode })
        XCTAssertTrue(events.contains { $0.type == .exit && $0.stage == .promptDecode })
        XCTAssertTrue(
            events.contains { $0.name == .nativeError },
            "an error was suppressed by a verbosity setting"
        )
    }

    func testVerboseEventsAppearWhenVerboseIsOn() {
        let logger = makeLogger(verbose: true)
        logger.verbose(.generationProgress, category: .generation)
        let events = store.read(session: logger.appSessionID)?.events ?? []
        XCTAssertTrue(events.contains { $0.name == .generationProgress })
    }

    // MARK: The sidecar

    func testTheSidecarNamesTheOpenStageAndClearsWhenItCloses() {
        let logger = makeLogger()
        let operation = logger.criticalEnter(.modelLoad, metadata: .empty)

        let open = LocalInferenceSessionRecovery.readCurrentStage(in: store)
        XCTAssertEqual(open?.stage, LocalInferenceStage.modelLoad.rawValue)
        XCTAssertEqual(open?.operationID, operation.rawValue)

        logger.criticalExit(.modelLoad, operation: operation, metadata: .empty)
        XCTAssertNil(LocalInferenceSessionRecovery.readCurrentStage(in: store))
    }

    /// Section 92: an inner EXIT must not erase the outer stage that is still
    /// running, or the sidecar would claim nothing was in flight while a
    /// generation was very much in flight.
    func testANestedExitLeavesTheEnclosingStageNamed() {
        let logger = makeLogger()
        _ = logger.criticalEnter(.generation, metadata: .empty)
        let inner = logger.criticalEnter(.generationDecode, metadata: .empty)
        logger.criticalExit(.generationDecode, operation: inner, metadata: .empty)

        let open = LocalInferenceSessionRecovery.readCurrentStage(in: store)
        XCTAssertEqual(open?.stage, LocalInferenceStage.generation.rawValue)
    }

    // MARK: Writer failure

    /// Section 83 and 113. A logger that cannot write must go quiet, not throw,
    /// not retry and above all not become a second way for inference to fail.
    func testAnUnwritableDirectoryDoesNotThrowOrCrash() {
        // A store pointed at a path that cannot be created: the parent is a
        // regular file, so `mkdir` and `open` both fail.
        let blocker = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("metis-blocker-\(UUID().uuidString)")
        try? Data("not a directory".utf8).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }

        let broken = LocalInferenceDiagnosticStore(
            directory: blocker.appendingPathComponent("diagnostics", isDirectory: true)
        )
        let logger = LocalInferenceDiagnosticLogger(store: broken, verbose: true)

        // The point of the test is that none of this traps.
        logger.startSession(metadata: .empty)
        let operation = logger.criticalEnter(.modelLoad, metadata: .empty)
        logger.criticalExit(.modelLoad, operation: operation, metadata: .empty)
        logger.info(.appLaunch, category: .lifecycle)

        XCTAssertTrue(
            logger.writerDidFail,
            "the failure was swallowed silently — the diagnostics screen would lie"
        )
        XCTAssertNotNil(logger.writerFailureDescription)
    }

    // MARK: Rotation

    /// Sections 78 and 80.
    func testRotationDeletesTheOldestAndKeepsTheCurrent() throws {
        var ids: [LocalInferenceSessionID] = []
        // One more than the retention limit, each written and closed so they
        // are all eligible.
        for index in 0...LocalInferenceDiagnosticStore.retainedSessionCount + 2 {
            let logger = makeLogger()
            logger.info(.appLaunch, category: .lifecycle)
            logger.endSession(clean: true)
            ids.append(logger.appSessionID)
            // Distinct modification times, so "oldest" is well defined.
            let url = store.url(forSession: logger.appSessionID)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_000_000 + Double(index))],
                ofItemAtPath: url.path
            )
        }

        let current = LocalInferenceSessionID()
        store.rotate(keeping: current)

        let remaining = Set(store.sessionFiles().map(\.id.rawValue))
        XCTAssertLessThanOrEqual(
            remaining.count, LocalInferenceDiagnosticStore.retainedSessionCount
        )
        XCTAssertFalse(remaining.contains(ids[0].rawValue), "the oldest survived rotation")
        XCTAssertTrue(remaining.contains(ids.last!.rawValue), "the newest was deleted")
    }

    /// Writes a session file directly, without a logger.
    ///
    /// Constructing a `LocalInferenceDiagnosticLogger` rotates as part of its
    /// initialiser, so building fixtures out of loggers means rotation has
    /// already run several times before the test calls it — which is how the
    /// first version of the test below passed for the wrong reason.
    private func writeSessionFile(
        _ id: LocalInferenceSessionID,
        modifiedAt: Date,
        lines: Int = 1
    ) throws {
        let body = (0..<lines)
            .map { #"{"seq":\#($0 + 1),"event":"INFO","name":"APP_LAUNCH","app":"\#(id.rawValue)"}"# }
            .joined(separator: "\n")
        let url = store.url(forSession: id)
        try Data((body + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: modifiedAt], ofItemAtPath: url.path
        )
    }

    /// Section 81. The evidence must survive the launch that reads it.
    func testRotationProtectsTheSessionBeingRecovered() throws {
        var ids: [LocalInferenceSessionID] = []
        for index in 0...LocalInferenceDiagnosticStore.retainedSessionCount + 2 {
            let id = LocalInferenceSessionID()
            try writeSessionFile(id, modifiedAt: Date(timeIntervalSince1970: 1_000_000 + Double(index)))
            ids.append(id)
        }

        // The oldest file is the one that would normally go first — and, on a
        // launch after a crash, it is exactly the one being read.
        let evidence = ids[0]
        store.rotate(keeping: LocalInferenceSessionID(), protecting: evidence)

        XCTAssertTrue(
            store.sessionFiles().contains { $0.id == evidence },
            "rotation destroyed the unclean session on the launch that was reading it"
        )
        XCTAssertFalse(
            store.sessionFiles().contains { $0.id == ids[1] },
            "nothing was rotated at all, so the protection proved nothing"
        )
    }

    /// The protection is not permanent — section 81 says it survives *until it
    /// falls outside the retention policy naturally*. A logger that pinned the
    /// same file forever would leak one session slot for the life of the app.
    func testAProtectedSessionStillAgesOutWhenItIsNoLongerProtected() throws {
        var ids: [LocalInferenceSessionID] = []
        for index in 0...LocalInferenceDiagnosticStore.retainedSessionCount + 2 {
            let id = LocalInferenceSessionID()
            try writeSessionFile(id, modifiedAt: Date(timeIntervalSince1970: 1_000_000 + Double(index)))
            ids.append(id)
        }

        store.rotate(keeping: LocalInferenceSessionID(), protecting: nil)
        XCTAssertFalse(store.sessionFiles().contains { $0.id == ids[0] })
    }

    func testTheTotalSizeCapIsRespected() throws {
        // Two sessions, each written well past the total cap between them.
        let filler = String(repeating: "x", count: 180)
        for index in 0..<4 {
            let logger = makeLogger()
            for _ in 0..<400 {
                logger.info(
                    .generationProgress,
                    category: .generation,
                    metadata: LocalInferenceMetadata().setting(.errorReason, filler)
                )
            }
            logger.endSession(clean: true)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_000_000 + Double(index))],
                ofItemAtPath: store.url(forSession: logger.appSessionID).path
            )
        }

        store.rotate(keeping: LocalInferenceSessionID())
        let total = store.sessionFiles().reduce(Int64(0)) { $0 + $1.sizeBytes }
        XCTAssertLessThanOrEqual(total, LocalInferenceDiagnosticStore.totalSizeLimitBytes)
    }

    func testClearingRemovesEveryFileButTheCurrentOne() {
        let old = makeLogger()
        old.info(.appLaunch, category: .lifecycle)
        old.endSession(clean: true)

        let current = makeLogger()
        current.info(.appLaunch, category: .lifecycle)

        store.clear(keeping: current.appSessionID)

        let remaining = store.sessionFiles().map(\.id.rawValue)
        XCTAssertEqual(remaining, [current.appSessionID.rawValue])
    }
}
