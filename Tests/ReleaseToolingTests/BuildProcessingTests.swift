import Foundation
import XCTest

@testable import ReleaseTooling

/// Waiting for a build, and knowing which build was waited for.
///
/// This is the check that separates "the upload command exited zero" from "the
/// build is usable" — the distinction Part 14 section 73 exists to enforce.
final class BuildProcessingTests: XCTestCase {

    // MARK: States

    func testReadsApplesProcessingStates() {
        XCTAssertEqual(BuildProcessingState(rawValue: "VALID"), .valid)
        XCTAssertEqual(BuildProcessingState(rawValue: "PROCESSING"), .processing)
        XCTAssertEqual(BuildProcessingState(rawValue: "FAILED"), .failed)
        XCTAssertEqual(BuildProcessingState(rawValue: "INVALID"), .invalid)
        XCTAssertEqual(BuildProcessingState(rawValue: "valid"), .valid)
    }

    /// Kept rather than folded into a default. Mapping an unrecognised state to
    /// "still processing" would burn the timeout; mapping it to "valid" would
    /// report a build as shipped on the strength of a string nobody has seen.
    func testAnUnrecognisedStateIsKeptAndIsNotSuccess() {
        let state = BuildProcessingState(rawValue: "MARINATING")
        XCTAssertEqual(state.rawValue, "MARINATING")
        XCTAssertTrue(state.isTerminal)
        XCTAssertFalse(state.isSuccess)
    }

    func testOnlyProcessingIsWorthWaitingOn() {
        XCTAssertFalse(BuildProcessingState.processing.isTerminal)
        for state in [BuildProcessingState.valid, .failed, .invalid] {
            XCTAssertTrue(state.isTerminal)
        }
        XCTAssertTrue(BuildProcessingState.valid.isSuccess)
        XCTAssertFalse(BuildProcessingState.failed.isSuccess)
    }

    // MARK: Decoding

    private func buildsResponse(_ builds: [(String, String, String)]) -> Data {
        let items = builds.map { id, version, state in
            """
            {"type":"builds","id":"\(id)","attributes":{"version":"\(version)",
            "processingState":"\(state)","uploadedDate":"2026-08-28T10:00:00.000Z"}}
            """
        }
        return Data("{\"data\":[\(items.joined(separator: ","))]}".utf8)
    }

    func testDecodesTheBuildsResponse() throws {
        let records = try AppStoreConnectDecoder.builds(
            from: buildsResponse([("id-1", "412.1", "VALID")])
        )
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].id, "id-1")
        XCTAssertEqual(records[0].version, "412.1")
        XCTAssertEqual(records[0].processingState, .valid)
        XCTAssertNotNil(records[0].uploadedDate)
    }

    func testDecodesTheAppsResponse() throws {
        let data = Data(
            """
            {"data":[{"type":"apps","id":"6600000000",
            "attributes":{"bundleId":"com.dimitrisefthymiou.MetisAI"}}]}
            """.utf8
        )
        let apps = try AppStoreConnectDecoder.apps(from: data)
        XCTAssertEqual(apps.first?.id, "6600000000")
        XCTAssertEqual(apps.first?.bundleID, "com.dimitrisefthymiou.MetisAI")
    }

    /// A 401 from a bad token and a 403 from a key without the App Manager role
    /// are the same HTTP failure and completely different problems.
    func testDecodesApplesErrorEnvelope() {
        let data = Data(
            """
            {"errors":[{"status":"401","title":"NOT_AUTHORIZED",
            "detail":"Authentication credentials are missing or invalid."}]}
            """.utf8
        )
        let messages = AppStoreConnectDecoder.errors(from: data)
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].contains("NOT_AUTHORIZED"))
    }

    func testAnUnreadableResponseIsAnError() {
        XCTAssertThrowsError(try AppStoreConnectDecoder.builds(from: Data("<html>".utf8)))
    }

    // MARK: The loop

    /// Answers a scripted sequence of responses, and records what was asked.
    private final class StubTransport: AppStoreConnectTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var responses: [(Data, Int)]
        private(set) var requestedURLs: [URL] = []
        private(set) var tokens: [String] = []

        init(_ responses: [(Data, Int)]) { self.responses = responses }

        func get(_ url: URL, token: String) async throws -> (Data, Int) {
            lock.lock()
            defer { lock.unlock() }
            requestedURLs.append(url)
            tokens.append(token)
            // The last response repeats, so a test can describe a steady state
            // without listing it once per poll.
            return responses.count > 1 ? responses.removeFirst() : responses[0]
        }
    }

    /// A clock the test moves, so a twenty-minute wait runs in microseconds.
    ///
    /// Sleeping for real would make this file take longer than the deploy it
    /// describes; sleeping for zero and leaving the clock still would make the
    /// deadline unreachable and the loop infinite. Advancing on `sleep` is the
    /// only arrangement that tests the loop rather than avoiding it.
    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var seconds: TimeInterval = 0

        func now() -> Date {
            lock.lock()
            defer { lock.unlock() }
            return Date(timeIntervalSince1970: seconds)
        }

        func advance(by interval: TimeInterval) {
            lock.lock()
            seconds += interval
            lock.unlock()
        }
    }

    private func poll(
        _ transport: StubTransport,
        buildNumber: String = "412.1",
        deadline: TimeInterval = 300,
        interval: TimeInterval = 30
    ) async throws -> BuildPollOutcome {
        let clock = TestClock()
        return try await BuildProcessingPoller(transport: transport).wait(
            appID: "6600000000",
            buildNumber: buildNumber,
            token: { "token" },
            deadline: deadline,
            interval: interval,
            sleep: { clock.advance(by: $0) },
            now: { clock.now() }
        )
    }

    func testStopsAsSoonAsTheBuildIsValid() async throws {
        let transport = StubTransport([(buildsResponse([("id-1", "412.1", "VALID")]), 200)])
        let outcome = try await poll(transport)
        guard case .settled(let record) = outcome else {
            return XCTFail("expected the poll to settle, got \(outcome)")
        }
        XCTAssertEqual(record.processingState, .valid)
        XCTAssertEqual(transport.requestedURLs.count, 1, "a settled build needs one request")
    }

    func testWaitsThroughProcessingAndThenSettles() async throws {
        let transport = StubTransport([
            (buildsResponse([("id-1", "412.1", "PROCESSING")]), 200),
            (buildsResponse([("id-1", "412.1", "PROCESSING")]), 200),
            (buildsResponse([("id-1", "412.1", "VALID")]), 200),
        ])
        let outcome = try await poll(transport, deadline: 3_600)
        guard case .settled(let record) = outcome else {
            return XCTFail("expected the poll to settle, got \(outcome)")
        }
        XCTAssertEqual(record.processingState, .valid)
        XCTAssertEqual(transport.requestedURLs.count, 3)
    }

    /// A failed build is terminal. Continuing to poll would spend the whole
    /// deadline waiting for a state that will never change.
    func testStopsImmediatelyOnAFailedBuild() async throws {
        let transport = StubTransport([(buildsResponse([("id-1", "412.1", "FAILED")]), 200)])
        let outcome = try await poll(transport)
        guard case .settled(let record) = outcome else {
            return XCTFail("expected the poll to settle, got \(outcome)")
        }
        XCTAssertEqual(record.processingState, .failed)
        XCTAssertFalse(record.processingState.isSuccess)
    }

    /// The load-bearing test of this file.
    ///
    /// Two deploys racing, or a build uploaded by hand from a laptop, and the
    /// newest build in App Store Connect is not the one this run produced.
    /// Reporting *its* success as this run's success is the exact false green
    /// section 73 is written against — so a build with any other version is not
    /// looked at, even when it is sitting at the top of the response.
    func testABuildWithADifferentNumberIsNotMistakenForThisOne() async throws {
        let transport = StubTransport([
            (
                buildsResponse([
                    ("id-9", "500.1", "VALID"),
                    ("id-1", "412.1", "PROCESSING"),
                ]), 200
            )
        ])
        let outcome = try await poll(transport, buildNumber: "412.1", deadline: 60, interval: 30)
        guard case .stillProcessing(let record) = outcome else {
            return XCTFail("a different build's VALID was taken for ours: \(outcome)")
        }
        XCTAssertEqual(record.version, "412.1")
    }

    func testReportsWhenTheBuildNeverAppears() async throws {
        let transport = StubTransport([(Data("{\"data\":[]}".utf8), 200)])
        let outcome = try await poll(transport, deadline: 60, interval: 30)
        XCTAssertEqual(outcome, .neverAppeared)
    }

    func testReportsWhenTheDeadlinePassesWhileStillProcessing() async throws {
        let transport = StubTransport([
            (buildsResponse([("id-1", "412.1", "PROCESSING")]), 200)
        ])
        let outcome = try await poll(transport, deadline: 60, interval: 30)
        guard case .stillProcessing = outcome else {
            return XCTFail("expected stillProcessing, got \(outcome)")
        }
    }

    /// A token lives fifteen minutes; processing can take longer. Reusing one
    /// turns a slow build into a 401 that reads like an authentication problem.
    func testEveryPollCarriesAFreshlyMintedToken() async throws {
        let transport = StubTransport([
            (buildsResponse([("id-1", "412.1", "PROCESSING")]), 200)
        ])
        let clock = TestClock()
        let minted = Counter()
        let poller = BuildProcessingPoller(transport: transport)
        _ = try await poller.wait(
            appID: "app",
            buildNumber: "412.1",
            token: { "token-\(minted.next())" },
            deadline: 90,
            interval: 30,
            sleep: { clock.advance(by: $0) },
            now: { clock.now() }
        )
        XCTAssertGreaterThan(transport.tokens.count, 1)
        XCTAssertEqual(
            Set(transport.tokens).count, transport.tokens.count,
            "the same token was reused across polls"
        )
    }

    /// A counter a `@Sendable` closure may increment. A captured `var` cannot
    /// be, and that restriction is correct — this is the narrowest way around
    /// it that keeps the test honest.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }
    }

    // MARK: The app record

    /// Section 33. There is nothing the workflow can do about a missing app
    /// record — only a person with an App Store Connect login can create one —
    /// so the message says that rather than reporting a 404.
    func testAMissingAppRecordSaysWhatToDoAboutIt() async throws {
        let transport = StubTransport([(Data("{\"data\":[]}".utf8), 200)])
        let poller = BuildProcessingPoller(transport: transport)
        do {
            _ = try await poller.appID(
                forBundleID: "com.dimitrisefthymiou.MetisAI", token: "token"
            )
            XCTFail("expected the lookup to fail")
        } catch let error as BuildPollError {
            XCTAssertEqual(
                error, .appRecordNotFound(bundleID: "com.dimitrisefthymiou.MetisAI")
            )
            XCTAssertTrue(error.description.contains("Create the app"))
        }
    }

    /// Apple's `filter[bundleId]` is a prefix match, so the app's record and
    /// both extensions' come back together. Uploading to the keyboard's record
    /// is not a mistake that announces itself.
    func testTheAppLookupMatchesTheBundleIdentifierExactly() async throws {
        let data = Data(
            """
            {"data":[
              {"type":"apps","id":"111","attributes":
                {"bundleId":"com.dimitrisefthymiou.MetisAI.widgets"}},
              {"type":"apps","id":"222","attributes":
                {"bundleId":"com.dimitrisefthymiou.MetisAI"}}
            ]}
            """.utf8
        )
        let poller = BuildProcessingPoller(transport: StubTransport([(data, 200)]))
        let id = try await poller.appID(
            forBundleID: "com.dimitrisefthymiou.MetisAI", token: "token"
        )
        XCTAssertEqual(id, "222")
    }

    func testAnHTTPFailureCarriesApplesExplanation() async throws {
        let body = Data(
            """
            {"errors":[{"status":"403","title":"FORBIDDEN_ERROR",
            "detail":"The key is not permitted to access this resource."}]}
            """.utf8
        )
        let poller = BuildProcessingPoller(transport: StubTransport([(body, 403)]))
        do {
            _ = try await poller.appID(forBundleID: "com.dimitrisefthymiou.MetisAI", token: "t")
            XCTFail("expected the lookup to fail")
        } catch let error as BuildPollError {
            XCTAssertTrue(error.description.contains("403"))
            XCTAssertTrue(error.description.contains("FORBIDDEN_ERROR"))
        }
    }
}
