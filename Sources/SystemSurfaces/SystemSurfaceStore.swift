import Foundation

/// Where extension-safe projections live.
///
/// Deliberately a narrow protocol over four operations, not a database. Section
/// 3: an App Group existing is not a reason to expose the application's store
/// to every extension. What crosses this boundary is a handful of small values
/// whose fields are each listed in a type in this module, and nothing else can
/// cross it because there is no API to write anything else.
public protocol SystemSurfaceStore: Sendable {
    func read<Snapshot: SystemSurfaceSnapshot>(
        _ type: Snapshot.Type
    ) throws -> Snapshot
    func write<Snapshot: SystemSurfaceSnapshot>(_ snapshot: Snapshot) throws
    func remove<Snapshot: SystemSurfaceSnapshot>(_ type: Snapshot.Type) throws
    /// Whether the container is reachable at all.
    ///
    /// False in a keyboard without Full Access, and in any build whose App
    /// Group entitlement did not make it into the signature. Checked rather
    /// than discovered through a thrown error, because "the user has not
    /// granted access" is a state to explain, not a failure to report.
    var isAvailable: Bool { get }
}

extension SystemSurfaceStore {
    /// The snapshot, or a placeholder, never an error.
    ///
    /// Section 73. Every caller is a piece of presentation with a deadline
    /// measured in milliseconds and no way to ask the user anything, so the
    /// only useful contract is "give me something safe to draw".
    public func readOrPlaceholder<Snapshot: SystemSurfaceSnapshot>(
        _ type: Snapshot.Type,
        fallback: Snapshot
    ) -> Snapshot {
        (try? read(type)) ?? fallback
    }
}

/// The real one: JSON files in the App Group container.
///
/// ## Why files rather than shared `UserDefaults`
///
/// Shared defaults are a single property list that every writer rewrites in
/// full, which makes a partial write a corrupted *everything* rather than a
/// corrupted one thing. Separate files mean a bad today-snapshot cannot take
/// the keyboard configuration down with it, and mean a widget decodes 400 bytes
/// instead of all of it.
///
/// It also keeps a rule enforceable that section 8 states as a prohibition:
/// there is no key-value API here at all, so there is no way to put an API key
/// in "just this once".
public struct FileSystemSurfaceStore: SystemSurfaceStore {
    private let directory: URL?

    /// - Parameter directory: the shared container, or nil when there is none.
    public init(directory: URL?) {
        self.directory = directory
    }

    /// Resolves the App Group container, if this process is entitled to it.
    ///
    /// Returns a store with no directory when it is not — every read then
    /// yields `.containerUnavailable` and every write is refused, which is
    /// exactly the behaviour a keyboard without Full Access needs.
    public static func appGroup(
        identifier: String = SystemSurfaceIdentifiers.appGroup,
        fileManager: FileManager = .default
    ) -> FileSystemSurfaceStore {
        let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: identifier)
        return FileSystemSurfaceStore(directory: container?.appendingPathComponent(
            Self.directoryName,
            isDirectory: true
        ))
    }

    /// A subdirectory rather than the container root, so the projections are
    /// obviously separable from anything else that ever shares the group.
    public static let directoryName = "SystemSurfaces"

    public var isAvailable: Bool { directory != nil }

    public func read<Snapshot: SystemSurfaceSnapshot>(_ type: Snapshot.Type) throws -> Snapshot {
        guard let url = url(for: type) else { throw SystemSurfaceStoreError.containerUnavailable }
        guard let data = try? Data(contentsOf: url) else {
            throw SystemSurfaceStoreError.missing
        }
        return try SystemSurfaceCoding.decode(type, from: data)
    }

    public func write<Snapshot: SystemSurfaceSnapshot>(_ snapshot: Snapshot) throws {
        guard let directory, let url = url(for: Snapshot.self) else {
            throw SystemSurfaceStoreError.containerUnavailable
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try SystemSurfaceCoding.encode(snapshot)
        // Section 72. `.atomic` writes to a temporary file and renames it, so a
        // widget reading at the same moment sees either the whole previous file
        // or the whole new one — never the first half of a JSON object, which
        // decodes to a corruption error and a blank widget.
        try data.write(to: url, options: .atomic)
    }

    public func remove<Snapshot: SystemSurfaceSnapshot>(_ type: Snapshot.Type) throws {
        guard let url = url(for: type) else { throw SystemSurfaceStoreError.containerUnavailable }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private func url<Snapshot: SystemSurfaceSnapshot>(for type: Snapshot.Type) -> URL? {
        directory?.appendingPathComponent(type.storageKey + ".json", isDirectory: false)
    }
}

/// For tests, previews and any process with no container.
public final class InMemorySystemSurfaceStore: SystemSurfaceStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]
    private let available: Bool
    /// Every write that has happened, in order. Lets a test assert that a
    /// refresh was targeted rather than a rebuild of everything.
    public private(set) var writtenKeys: [String] = []

    public init(isAvailable: Bool = true) {
        self.available = isAvailable
    }

    public var isAvailable: Bool { available }

    public func read<Snapshot: SystemSurfaceSnapshot>(_ type: Snapshot.Type) throws -> Snapshot {
        guard available else { throw SystemSurfaceStoreError.containerUnavailable }
        lock.lock()
        let data = storage[type.storageKey]
        lock.unlock()
        guard let data else { throw SystemSurfaceStoreError.missing }
        return try SystemSurfaceCoding.decode(type, from: data)
    }

    public func write<Snapshot: SystemSurfaceSnapshot>(_ snapshot: Snapshot) throws {
        guard available else { throw SystemSurfaceStoreError.containerUnavailable }
        let data = try SystemSurfaceCoding.encode(snapshot)
        lock.lock()
        storage[Snapshot.storageKey] = data
        writtenKeys.append(Snapshot.storageKey)
        lock.unlock()
    }

    public func remove<Snapshot: SystemSurfaceSnapshot>(_ type: Snapshot.Type) throws {
        guard available else { throw SystemSurfaceStoreError.containerUnavailable }
        lock.lock()
        storage.removeValue(forKey: type.storageKey)
        lock.unlock()
    }

    /// Overwrites a slot with arbitrary bytes, to exercise the corruption path.
    public func writeRaw(_ data: Data, forKey key: String) {
        lock.lock()
        storage[key] = data
        lock.unlock()
    }
}

/// One encoder and one decoder, configured once.
///
/// Dates as ISO-8601 rather than as a `Double` since the reference date: the
/// files are read by a different binary than the one that wrote them, possibly
/// a different app version, and a format a human can read in a bug report is
/// worth more than the handful of bytes.
public enum SystemSurfaceCoding {
    public static func encode<Snapshot: SystemSurfaceSnapshot>(_ snapshot: Snapshot) throws -> Data {
        try encoder.encode(snapshot)
    }

    /// Decodes, and refuses anything this build cannot claim to understand.
    public static func decode<Snapshot: SystemSurfaceSnapshot>(
        _ type: Snapshot.Type,
        from data: Data
    ) throws -> Snapshot {
        let snapshot: Snapshot
        do {
            snapshot = try decoder.decode(type, from: data)
        } catch {
            // Every decoding failure is the same thing to a caller that can
            // only draw a placeholder, and the underlying error would carry
            // the offending value — which is the user's own text.
            throw SystemSurfaceStoreError.corrupt
        }
        guard snapshot.isReadable else {
            throw SystemSurfaceStoreError.unsupportedVersion(
                found: snapshot.snapshotVersion,
                supported: Snapshot.currentVersion
            )
        }
        return snapshot
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Stable key order, so an unchanged snapshot produces identical bytes
        // and a test can assert that a refresh really did change something.
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
