import AssistantPersistenceSwiftData
import Foundation
import SystemSurfaces

/// Where the one database lives, now that more than one process opens it.
///
/// ## Why the store moved
///
/// Section 5 says the application database stays authoritative, and section 70
/// says a widget's Done routes through an App Intent into the existing
/// services rather than mutating a shared file. Those two together have a
/// consequence iOS does not let you avoid: an interactive widget's App Intent
/// **runs in the widget extension's process**, so that process has to be able
/// to open the store. A file inside the app's own container is not reachable
/// from an extension, whatever entitlement it has.
///
/// So the store lives in the App Group container. It is the same SwiftData
/// file, the same schema and the same migration plan — only the directory
/// changed.
///
/// ## Migration
///
/// Anyone who installed an earlier build has their data in the old location.
/// The first launch after the update copies it across, once, before the
/// container is opened. Copy rather than move: if anything goes wrong the
/// original is still there, and a user's entire task history is not something
/// to be clever with.
///
/// ## When there is no group
///
/// An unsigned CI build has no App Group entitlement, so
/// `containerURL(forSecurityApplicationGroupIdentifier:)` returns nil. That is
/// not an error — the app falls back to its own container and works exactly as
/// it did before, minus the widget actions. Section 123: the entitlement is a
/// signing-time fact, and this is what makes the code path that depends on it
/// compile and run without one.
enum SharedStoreLocation {

    /// The store the app and its extensions should open.
    static func resolve(
        groupIdentifier: String = SystemSurfaceIdentifiers.appGroup,
        fileManager: FileManager = .default
    ) -> PersistenceLocation {
        guard let shared = sharedStoreURL(groupIdentifier: groupIdentifier, fileManager: fileManager)
        else {
            // No group container: unsigned build, or an entitlement that did
            // not make it into the signature. The app still runs.
            return .applicationDefault
        }

        migrateIfNeeded(to: shared, fileManager: fileManager)
        return .file(shared)
    }

    /// The App Group file, when this process is entitled to one.
    static func sharedStoreURL(
        groupIdentifier: String = SystemSurfaceIdentifiers.appGroup,
        fileManager: FileManager = .default
    ) -> URL? {
        guard
            let container = fileManager.containerURL(
                forSecurityApplicationGroupIdentifier: groupIdentifier
            )
        else { return nil }

        let directory = container.appendingPathComponent("Database", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(storeFileName, isDirectory: false)
    }

    /// Copies an existing app-container store into the group, once.
    ///
    /// Does nothing when the destination already exists — which is every launch
    /// after the first — and nothing when there is no source, which is a fresh
    /// install.
    private static func migrateIfNeeded(to destination: URL, fileManager: FileManager) {
        guard !fileManager.fileExists(atPath: destination.path) else { return }
        guard
            let legacyDirectory = try? fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
            )
        else { return }

        let legacy = legacyDirectory.appendingPathComponent(storeFileName, isDirectory: false)
        guard fileManager.fileExists(atPath: legacy.path) else { return }

        // SQLite keeps a write-ahead log and a shared-memory file beside the
        // database. Copying only the `.store` would produce a store missing
        // every transaction that had not been checkpointed — which is to say,
        // most of a recent session.
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: legacy.path + suffix)
            let target = URL(fileURLWithPath: destination.path + suffix)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            try? fileManager.copyItem(at: source, to: target)
        }
    }

    /// The name SwiftData gives the app's store by default. Reused so the
    /// migration above has something to look for.
    private static let storeFileName = "default.store"
}
