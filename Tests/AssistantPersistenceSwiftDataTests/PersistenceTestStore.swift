#if canImport(SwiftData)

import AssistantPersistence
import AssistantPersistenceSwiftData
import Foundation
import SwiftData
import XCTest

/// A throwaway SwiftData store for one test.
///
/// Every test gets its own directory, so nothing leaks between tests and
/// nothing anywhere near the store a real app would open. The file is on disk
/// rather than in memory because most of what is being tested here is whether
/// data survives the container that wrote it — and an in-memory store cannot
/// answer that question. It dies with the process either way, which is what
/// makes it safe.
@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
final class PersistenceTestStore {
    let directory: URL
    let url: URL

    private(set) var container: ModelContainer

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("assistant-persistence-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        url = directory.appendingPathComponent("store.sqlite")
        container = try AssistantPersistenceContainer.make(location: .file(url))
    }

    /// Repositories over the current container.
    func makeRepositories() -> AssistantRepositories {
        AssistantRepositories.persistent(container: container)
    }

    /// Drops the container and opens a new one over the same file.
    ///
    /// This is the closest a test can get to quitting and reopening the app:
    /// every cached object and context goes away, and the next read has to come
    /// off disk. A test that reuses one container proves only that a dictionary
    /// remembers what was put in it.
    func relaunch() throws {
        container = try AssistantPersistenceContainer.make(location: .file(url))
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Base class that wires the store up and cleans it up.
@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
class PersistenceTestCase: XCTestCase {
    private(set) var store: PersistenceTestStore!
    private(set) var repositories: AssistantRepositories!

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = try PersistenceTestStore()
        repositories = store.makeRepositories()
    }

    override func tearDown() {
        store?.tearDown()
        store = nil
        repositories = nil
        super.tearDown()
    }

    /// Reopens the store and rebuilds the repositories against it.
    func relaunch() throws {
        try store.relaunch()
        repositories = store.makeRepositories()
    }

    /// A fixed instant, so nothing here depends on when the test runs.
    static let referenceDate = Date(timeIntervalSince1970: 1_760_000_000)
}

#endif
