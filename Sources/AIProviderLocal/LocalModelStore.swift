import AssistantAI
import AssistantDomain
import Foundation

/// Where model files live on disk.
///
/// ## Why Application Support and not somewhere else
///
/// Section 25, and each exclusion has a concrete failure behind it:
///
/// - **Not Documents.** On a phone with file sharing enabled, Documents is
///   what the Files app shows the user. A 2 GB blob they did not create,
///   cannot read and might delete does not belong there.
/// - **Not Caches.** iOS empties Caches when space runs low, without warning
///   and without telling the app. A model that vanishes on a full phone is a
///   model the user has to download again, having been told it was installed.
/// - **Not SwiftData.** Section 26. Multi-gigabyte blobs in a database are
///   loaded, copied and migrated by machinery designed for rows.
///
/// Application Support is app-owned and not shown to the user. It is also
/// backed up by default, which model files are explicitly opted out of below:
/// they are large, published and re-downloadable, which is the exact profile of
/// something that should not consume someone's iCloud quota.
///
/// ## Why paths are relative
///
/// Section 27. The absolute path of an app container changes between installs
/// and across device restores, so what is stored is `"qwen3-1.7b.gguf"` and the
/// full URL is rebuilt from the current container each time it is needed.
public struct LocalModelStore: Sendable {
    /// The directory holding model files. Resolved once per process.
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `FileManager` is not `Sendable`, so it is reached rather than stored.
    ///
    /// Storing one would make this whole type non-`Sendable` — it is passed to
    /// an actor and captured in async work — and the only thing an injected
    /// file manager would buy is a mocking seam that no test here wants: the
    /// tests use a real temporary directory, which exercises the real
    /// filesystem behaviour that matters (atomic moves, cross-volume copies,
    /// a file already at the destination).
    private var fileManager: FileManager { .default }

    /// The production location: `Application Support/Models`.
    public static func applicationSupport(
        fileManager: FileManager = .default
    ) throws -> LocalModelStore {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return LocalModelStore(directory: base.appendingPathComponent("Models", isDirectory: true))
    }

    /// A throwaway directory. For tests and previews.
    public static func temporary(name: String = UUID().uuidString) -> LocalModelStore {
        LocalModelStore(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("local-models-\(name)", isDirectory: true)
        )
    }

    public func prepareDirectory() throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue { return }
            throw LocalModelDownloadError.diskWrite(
                reason: "A file is in the way of the models folder."
            )
        }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw LocalModelDownloadError.diskWrite(reason: error.localizedDescription)
        }
        applyProtection(to: directory)
    }

    /// The absolute URL for a stored relative path, resolved now.
    public func url(forRelativePath path: String) -> URL {
        directory.appendingPathComponent(path)
    }

    public func url(for model: LocalModelRecord) -> URL {
        url(forRelativePath: model.relativePath)
    }

    public func fileExists(_ model: LocalModelRecord) -> Bool {
        fileManager.fileExists(atPath: url(for: model).path)
    }

    public func fileSize(atRelativePath path: String) -> Int64? {
        let attributes = try? fileManager.attributesOfItem(atPath: url(forRelativePath: path).path)
        return (attributes?[.size] as? NSNumber)?.int64Value
    }

    /// Moves a verified download into place, replacing anything already there.
    ///
    /// Atomic where the filesystem allows it: the temporary file is on the same
    /// volume, so this is a rename rather than a copy, and there is no window
    /// in which a half-written model exists at the final path.
    public func install(_ temporaryFile: URL, as relativePath: String) throws -> URL {
        try prepareDirectory()
        let destination = url(forRelativePath: relativePath)
        do {
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: temporaryFile, to: destination)
        } catch {
            // A cross-volume move fails; fall back to copying rather than
            // failing the install. The temporary directory is usually on the
            // same volume as the container, but "usually" is not a guarantee
            // worth a failed download.
            do {
                try fileManager.copyItem(at: temporaryFile, to: destination)
                try? fileManager.removeItem(at: temporaryFile)
            } catch {
                throw LocalModelDownloadError.diskWrite(reason: error.localizedDescription)
            }
        }
        applyProtection(to: destination)
        return destination
    }

    /// Removes a model's file. Missing is success — the caller wanted it gone.
    public func remove(relativePath: String) throws {
        let target = url(forRelativePath: relativePath)
        guard fileManager.fileExists(atPath: target.path) else { return }
        do {
            try fileManager.removeItem(at: target)
        } catch {
            throw LocalModelDownloadError.diskWrite(reason: error.localizedDescription)
        }
    }

    /// Files in the models directory that no install record claims.
    ///
    /// Section 114. A download interrupted by the app being killed leaves a
    /// `.part` file nobody owns, and without this they accumulate silently
    /// until the user wonders where their storage went.
    public func orphanedFiles(knownPaths: Set<String>) -> [URL] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return [] }
        return contents.filter { !knownPaths.contains($0.lastPathComponent) }
    }

    @discardableResult
    public func removeOrphanedFiles(knownPaths: Set<String>) -> Int {
        var removed = 0
        for file in orphanedFiles(knownPaths: knownPaths) {
            if (try? fileManager.removeItem(at: file)) != nil { removed += 1 }
        }
        return removed
    }

    /// Total bytes the models directory occupies.
    public func totalBytesUsed() -> Int64 {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return contents.reduce(into: Int64(0)) { total, file in
            let attributes = try? fileManager.attributesOfItem(atPath: file.path)
            total += (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        }
    }

    /// Marks model files so they are not copied into iCloud or iTunes backups,
    /// and readable while the device is locked.
    ///
    /// Section 113. Model weights are large, public, and re-downloadable — they
    /// are the definition of what should not be in a backup, and putting a
    /// gigabyte of published weights in someone's iCloud quota would be rude.
    ///
    /// The protection class is `completeUntilFirstUserAuthentication` rather
    /// than the stronger `complete`, because a Shortcut or a background
    /// notification response can reach the assistant while the phone is locked,
    /// and a model file that cannot be read then is a model that fails at
    /// exactly the moment the app is most useful. These are not secrets; the
    /// user's data is, and that lives in the Keychain and the database.
    private func applyProtection(to url: URL) {
        // Both keys are Apple-only. On Linux and Windows there is no backup to
        // be excluded from and no data-protection class, and the guard is what
        // keeps this file compiling where the memory and download layers are
        // developed.
        #if canImport(Darwin)
        var resourceURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? resourceURL.setResourceValues(values)
        #endif

        #if os(iOS) || os(tvOS) || os(watchOS)
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #endif
    }
}
