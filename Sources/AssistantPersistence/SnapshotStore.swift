import Foundation

/// Raw byte storage behind the repositories.
///
/// Deliberately dumb: the repositories own the encoding, so replacing this with
/// SwiftData, SQLite or the Keychain later does not touch repository logic.
public protocol SnapshotStore: Sendable {
    func read(key: String) async throws -> Data?
    func write(_ data: Data, key: String) async throws
    func removeAll() async throws
}

/// Non-persistent store, for tests and ephemeral sessions.
public actor EphemeralSnapshotStore: SnapshotStore {
    private var storage: [String: Data] = [:]

    public init() {}

    public func read(key: String) async throws -> Data? { storage[key] }

    public func write(_ data: Data, key: String) async throws { storage[key] = data }

    public func removeAll() async throws { storage.removeAll() }
}

/// JSON files in a directory. Good enough for the Windows development stage.
///
/// On iOS this is replaced rather than shipped — see the persistence notes in
/// `Docs/ARCHITECTURE.md`.
public actor JSONFileSnapshotStore: SnapshotStore {
    private let directory: URL
    private let fileManager: FileManager

    public init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    public func read(key: String) async throws -> Data? {
        let url = fileURL(for: key)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw RepositoryError.storageFailure("Could not read \(key): \(error)")
        }
    }

    public func write(_ data: Data, key: String) async throws {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL(for: key), options: .atomic)
        } catch {
            throw RepositoryError.storageFailure("Could not write \(key): \(error)")
        }
    }

    public func removeAll() async throws {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.removeItem(at: directory)
    }

    private func fileURL(for key: String) -> URL {
        directory.appendingPathComponent("\(key).json")
    }
}
