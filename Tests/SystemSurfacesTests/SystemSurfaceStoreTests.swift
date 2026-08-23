import Foundation
import XCTest

@testable import SystemSurfaces

/// The shared container, and what happens when it lies.
///
/// Everything here is about a boundary between two binaries that are updated
/// separately and run in different processes. The app writes; a widget or a
/// keyboard reads, possibly mid-write, possibly from an older build, possibly
/// with no entitlement at all. None of those may produce a crash, and none of
/// them may produce something wrong-looking rather than nothing.
final class SystemSurfaceStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    // MARK: Round trip

    /// Section 97. Encode, store, decode — including the version.
    func testASnapshotSurvivesTheRoundTrip() throws {
        let store = InMemorySystemSurfaceStore()
        let snapshot = TodaySnapshot(
            generatedAt: now,
            validUntil: now.addingTimeInterval(3_600),
            items: [
                TodaySnapshotItem(
                    id: "task-1",
                    taskID: UUID(),
                    title: "Pay the electricity bill",
                    date: now.addingTimeInterval(1_800),
                    kind: .task,
                    emphasis: .upNext
                ),
            ],
            outstandingCount: 4
        )

        try store.write(snapshot)
        let loaded = try store.read(TodaySnapshot.self)

        XCTAssertEqual(loaded, snapshot)
        XCTAssertEqual(loaded.snapshotVersion, TodaySnapshot.currentVersion)
        XCTAssertEqual(loaded.outstandingCount, 4)
    }

    /// Dates go through ISO-8601, so a snapshot read by a different build reads
    /// the same instant rather than one offset by a reference date.
    func testDatesRoundTripExactlyToTheSecond() throws {
        let store = InMemorySystemSurfaceStore()
        let fireDate = Date(timeIntervalSince1970: 1_760_012_345)
        try store.write(
            ReminderWidgetSnapshot(
                generatedAt: now,
                intervention: TodaySnapshotItem(
                    id: "stage-1", title: "Leave now", date: fireDate, kind: .leave
                )
            )
        )

        let loaded = try store.read(ReminderWidgetSnapshot.self)
        XCTAssertEqual(
            loaded.intervention?.date.timeIntervalSince1970,
            fireDate.timeIntervalSince1970
        )
    }

    // MARK: Failure

    /// Section 73. Nonsense in the file is a placeholder on the screen, never a
    /// crash and never a reason to touch the authoritative store.
    func testCorruptDataDecodesToACorruptError() {
        let store = InMemorySystemSurfaceStore()
        store.writeRaw(Data("{ not json at all".utf8), forKey: TodaySnapshot.storageKey)

        XCTAssertThrowsError(try store.read(TodaySnapshot.self)) { error in
            XCTAssertEqual(error as? SystemSurfaceStoreError, .corrupt)
        }
    }

    /// And the convenience every widget actually calls gives back something
    /// drawable rather than an error it cannot handle.
    func testCorruptDataStillYieldsAPlaceholder() {
        let store = InMemorySystemSurfaceStore()
        store.writeRaw(Data("½".utf8), forKey: TodaySnapshot.storageKey)

        let snapshot = store.readOrPlaceholder(
            TodaySnapshot.self,
            fallback: .placeholder(at: now)
        )
        XCTAssertTrue(snapshot.items.isEmpty)
        XCTAssertEqual(snapshot.generatedAt, now)
    }

    /// Section 71. During an app update the extension binary and the app binary
    /// are briefly different versions. An extension that half-understands a
    /// future format shows something wrong; one that refuses shows a
    /// placeholder, which is the better of the two.
    func testANewerSnapshotVersionIsRefusedRatherThanGuessedAt() throws {
        let store = InMemorySystemSurfaceStore()
        let future = TodaySnapshot(
            snapshotVersion: TodaySnapshot.currentVersion + 1,
            generatedAt: now
        )
        store.writeRaw(try SystemSurfaceCoding.encode(future), forKey: TodaySnapshot.storageKey)

        XCTAssertThrowsError(try store.read(TodaySnapshot.self)) { error in
            guard case .unsupportedVersion(let found, let supported)? =
                error as? SystemSurfaceStoreError
            else { return XCTFail("expected an unsupported-version error") }
            XCTAssertEqual(found, TodaySnapshot.currentVersion + 1)
            XCTAssertEqual(supported, TodaySnapshot.currentVersion)
        }
    }

    func testNothingWrittenYetIsMissingRatherThanCorrupt() {
        let store = InMemorySystemSurfaceStore()
        XCTAssertThrowsError(try store.read(TaskWidgetSnapshot.self)) { error in
            XCTAssertEqual(error as? SystemSurfaceStoreError, .missing)
        }
    }

    /// Section 12 and section 13. A keyboard without Full Access has no shared
    /// container; every read says so, and nothing throws its way out to the
    /// user as a crash.
    func testAnUnavailableContainerIsReportedRatherThanCrashing() {
        let store = InMemorySystemSurfaceStore(isAvailable: false)

        XCTAssertFalse(store.isAvailable)
        XCTAssertThrowsError(try store.read(KeyboardConfigurationSnapshot.self)) { error in
            XCTAssertEqual(error as? SystemSurfaceStoreError, .containerUnavailable)
        }
        XCTAssertThrowsError(
            try store.write(KeyboardConfigurationSnapshot(generatedAt: now))
        )
    }

    // MARK: The real file store

    /// Section 72. Writes go through a temporary file and a rename, so a reader
    /// racing a writer sees one whole file or the other — never half of one.
    func testTheFileStoreWritesAndReadsBack() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = FileSystemSurfaceStore(directory: directory)
        XCTAssertTrue(store.isAvailable)

        let snapshot = TaskWidgetSnapshot(generatedAt: now, outstandingCount: 3)
        try store.write(snapshot)
        XCTAssertEqual(try store.read(TaskWidgetSnapshot.self), snapshot)

        // Overwriting is a replacement, not an append.
        try store.write(TaskWidgetSnapshot(generatedAt: now, outstandingCount: 1))
        XCTAssertEqual(try store.read(TaskWidgetSnapshot.self).outstandingCount, 1)

        try store.remove(TaskWidgetSnapshot.self)
        XCTAssertThrowsError(try store.read(TaskWidgetSnapshot.self))
    }

    /// A build with no App Group entitlement resolves no container at all. The
    /// store still exists and still answers; it just answers "no".
    func testAFileStoreWithNoDirectoryIsUnavailableRatherThanFatal() {
        let store = FileSystemSurfaceStore(directory: nil)

        XCTAssertFalse(store.isAvailable)
        XCTAssertThrowsError(try store.read(TodaySnapshot.self)) { error in
            XCTAssertEqual(error as? SystemSurfaceStoreError, .containerUnavailable)
        }
        XCTAssertThrowsError(try store.write(TodaySnapshot(generatedAt: now)))
        XCTAssertThrowsError(try store.remove(TodaySnapshot.self))
    }

    /// Each snapshot has its own file, so one bad projection cannot take the
    /// others down with it — the reason this is not one shared property list.
    func testEachSnapshotKindHasItsOwnSlot() throws {
        let store = InMemorySystemSurfaceStore()
        try store.write(TodaySnapshot(generatedAt: now, outstandingCount: 2))
        store.writeRaw(Data("broken".utf8), forKey: TaskWidgetSnapshot.storageKey)

        XCTAssertEqual(try store.read(TodaySnapshot.self).outstandingCount, 2)
        XCTAssertThrowsError(try store.read(TaskWidgetSnapshot.self))

        let keys = Set([
            TodaySnapshot.storageKey,
            TaskWidgetSnapshot.storageKey,
            ReminderWidgetSnapshot.storageKey,
            KeyboardConfigurationSnapshot.storageKey,
            KeyboardExchange.storageKey,
            LiveActivityRegistry.storageKey,
        ])
        XCTAssertEqual(keys.count, 6, "two snapshot kinds share a file name")
    }

    // MARK: Freshness

    func testValidUntilDecidesFreshness() {
        let snapshot = TodaySnapshot(
            generatedAt: now,
            validUntil: now.addingTimeInterval(600)
        )
        XCTAssertTrue(snapshot.isFresh(at: now))
        XCTAssertFalse(snapshot.isFresh(at: now.addingTimeInterval(900)))

        // No expiry means it does not go off by itself — a task list is wrong
        // only when something changes it.
        XCTAssertTrue(TodaySnapshot(generatedAt: now).isFresh(at: .distantFuture))
    }
}
