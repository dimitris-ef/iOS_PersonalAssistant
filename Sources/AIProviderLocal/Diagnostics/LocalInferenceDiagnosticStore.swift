import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Where diagnostic files live, and the rules that keep them bounded.
///
/// One directory, one file per app session, plus one small sidecar naming the
/// stage currently open. Deliberately not SwiftData (section 5): the store this
/// has to survive is a process being killed, and a database that must be opened,
/// migrated and saved through is the opposite of what that needs. A file
/// descriptor and `write(2)` is the whole mechanism.
public struct LocalInferenceDiagnosticStore: Sendable {

    /// Sessions kept on disk. Section 78.
    public static let retainedSessionCount = 8
    /// Total bytes the directory may occupy. Section 78 — small, because this
    /// competes for space with multi-gigabyte model files.
    public static let totalSizeLimitBytes: Int64 = 8 * 1024 * 1024
    /// A single session's cap. A runaway generation loop must not fill the disk
    /// before rotation gets a chance to run.
    public static let sessionSizeLimitBytes: Int64 = 2 * 1024 * 1024

    public let directory: URL

    /// The real location: `Application Support/Diagnostics/LocalInference`.
    ///
    /// Application Support rather than Caches, because the system may evict
    /// Caches under storage pressure — and storage pressure is correlated with
    /// exactly the conditions being investigated. Losing the trail to the same
    /// pressure that caused the crash would be a poor design.
    public static func applicationSupport() -> LocalInferenceDiagnosticStore {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return LocalInferenceDiagnosticStore(
            directory: base
                .appendingPathComponent("Diagnostics", isDirectory: true)
                .appendingPathComponent("LocalInference", isDirectory: true)
        )
    }

    /// A throwaway directory, for tests and previews.
    public static func temporary() -> LocalInferenceDiagnosticStore {
        LocalInferenceDiagnosticStore(
            directory: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("metis-diagnostics-\(UUID().uuidString)", isDirectory: true)
        )
    }

    public init(directory: URL) {
        self.directory = directory
    }

    // MARK: Layout

    public func url(forSession id: LocalInferenceSessionID) -> URL {
        directory.appendingPathComponent("session-\(id.rawValue).jsonl", isDirectory: false)
    }

    /// The sidecar naming the stage that is currently open (section 91).
    public var currentStageURL: URL {
        directory.appendingPathComponent("current-stage.json", isDirectory: false)
    }

    public func prepareDirectory() throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            // Not readable by other apps. The sandbox already guarantees that;
            // saying so costs nothing and documents the intent.
            attributes: [.posixPermissions: 0o700]
        )
    }

    /// Session files, newest first.
    public func sessionFiles() -> [LocalInferenceSessionFile] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return contents
            .compactMap { url -> LocalInferenceSessionFile? in
                let name = url.lastPathComponent
                guard name.hasPrefix("session-"), name.hasSuffix(".jsonl") else { return nil }
                let id = String(name.dropFirst("session-".count).dropLast(".jsonl".count))
                guard !id.isEmpty else { return nil }
                let attributes = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey, .fileSizeKey]
                )
                return LocalInferenceSessionFile(
                    id: LocalInferenceSessionID(rawValue: id),
                    url: url,
                    modifiedAt: attributes?.contentModificationDate ?? .distantPast,
                    sizeBytes: Int64(attributes?.fileSize ?? 0)
                )
            }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    public func read(session id: LocalInferenceSessionID) -> LocalInferenceDecodedSession? {
        guard let data = try? Data(contentsOf: url(forSession: id), options: [.mappedIfSafe])
        else { return nil }
        return LocalInferenceDiagnosticCoding.decode(data)
    }

    // MARK: Rotation

    /// Deletes the oldest completed sessions until the limits are met.
    ///
    /// Sections 80 and 81. Two files are never eligible: the session being
    /// written right now, and the most recent session that ended without a
    /// clean marker — that one is the evidence, and overwriting it on the very
    /// next launch would destroy the trail on the way to reading it. It ages
    /// out normally once it is no longer the newest unclean session.
    @discardableResult
    public func rotate(
        keeping current: LocalInferenceSessionID?,
        protecting protected: LocalInferenceSessionID? = nil
    ) -> [LocalInferenceSessionID] {
        var files = sessionFiles()
        let pinned = Set([current?.rawValue, protected?.rawValue].compactMap { $0 })
        var removed: [LocalInferenceSessionID] = []

        func delete(_ file: LocalInferenceSessionFile) {
            try? FileManager.default.removeItem(at: file.url)
            removed.append(file.id)
            files.removeAll { $0.url == file.url }
        }

        // Oldest first for both passes: "delete the oldest eligible" is the
        // whole policy, and the newest is what somebody is about to read.
        var eligible = files.filter { !pinned.contains($0.id.rawValue) }.reversed().map { $0 }

        while files.count > Self.retainedSessionCount, let oldest = eligible.first {
            delete(oldest)
            eligible.removeFirst()
        }
        while files.reduce(0, { $0 + $1.sizeBytes }) > Self.totalSizeLimitBytes,
            let oldest = eligible.first
        {
            delete(oldest)
            eligible.removeFirst()
        }
        return removed
    }

    /// Removes every diagnostic file. Section 66 — and nothing else: no models,
    /// no settings, no conversations.
    public func clear(keeping current: LocalInferenceSessionID?) {
        for file in sessionFiles() where file.id.rawValue != current?.rawValue {
            try? FileManager.default.removeItem(at: file.url)
        }
        try? FileManager.default.removeItem(at: currentStageURL)
    }
}

public struct LocalInferenceSessionFile: Hashable, Sendable {
    public let id: LocalInferenceSessionID
    public let url: URL
    public let modifiedAt: Date
    public let sizeBytes: Int64
}

/// An append-only file, written with `write(2)` and nothing above it.
///
/// ## Why not `FileHandle`
///
/// Section 10 is right to warn about it. `FileHandle.write` on Darwin does not
/// buffer in userspace today, but the guarantee this system needs is not "does
/// not buffer today" — it is that the bytes have left the process before the
/// next line of Swift executes. A raw `write(2)` on a descriptor opened
/// `O_APPEND` gives exactly that, in one syscall, with no object in between
/// that could hold anything back.
///
/// ## What a plain write already survives, and what it does not
///
/// Worth being precise, because it decides how much `fsync` is worth. Once
/// `write(2)` returns, the bytes are in the kernel's page cache and belong to
/// the *file*, not to the process. A process that is then killed — by a Swift
/// trap, by a native abort, by jetsam — loses nothing: the data is already
/// outside it. `fsync` protects against something else entirely, the device
/// losing power before the cache is flushed to storage.
///
/// So `write` is what makes the breadcrumb survive the crash, and `fsync` on
/// critical events is the belt to that pair of braces — it costs milliseconds
/// and buys durability across a hard power loss during a hang.
final class LocalInferenceFileWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private(set) var bytesWritten: Int64 = 0
    /// Set once writing has failed. Section 83: diagnostics must never become a
    /// second crash source, so a broken writer goes quiet rather than retrying
    /// a failing syscall on every breadcrumb.
    private(set) var failure: String?

    let url: URL

    init(url: URL) {
        self.url = url
    }

    deinit {
        if descriptor >= 0 { POSIXFile.close(descriptor) }
    }

    var hasFailed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return failure != nil
    }

    var failureDescription: String? {
        lock.lock()
        defer { lock.unlock() }
        return failure
    }

    /// Appends bytes, optionally flushing all the way to storage.
    ///
    /// Returns false when the write did not happen, which the caller records in
    /// memory rather than acting on. Never throws: a throwing logger would put
    /// a `try` on the line before `llama_decode`, and an unhandled diagnostic
    /// error is a worse outcome than a missing diagnostic.
    @discardableResult
    func append(_ data: Data, synchronize: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard failure == nil else { return false }

        if descriptor < 0, !open() { return false }

        var written = false
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                // `write` can legally write less than asked, and can be
                // interrupted by a signal. Looping is the only correct use of
                // it; a single call that ignores the return value is how a
                // breadcrumb ends up truncated.
                let result = POSIXFile.write(descriptor, base + offset, buffer.count - offset)
                if result > 0 {
                    offset += result
                    continue
                }
                if result < 0, errno == EINTR { continue }
                failure = "write failed with errno \(errno)"
                return
            }
            written = true
        }
        guard written else { return false }

        bytesWritten += Int64(data.count)
        if synchronize {
            // `fsync`, not `F_FULLFSYNC`. The latter waits for the storage
            // device to empty its own cache and costs tens of milliseconds — on
            // the path immediately before every native call, that would change
            // the timing of the thing being measured. See the type's note: the
            // crash survival comes from `write`, not from either of these.
            POSIXFile.synchronize(descriptor)
        }
        return true
    }

    private func open() -> Bool {
        // O_APPEND so every write lands at the end regardless of what else has
        // the file open, and 0o600 so the file is the app's alone.
        let opened = POSIXFile.openForAppend(url.path)
        guard opened >= 0 else {
            failure = "could not open the diagnostic file (errno \(errno))"
            return false
        }
        descriptor = opened
        return true
    }

    func closeFile() {
        lock.lock()
        defer { lock.unlock() }
        if descriptor >= 0 {
            POSIXFile.synchronize(descriptor)
            POSIXFile.close(descriptor)
            descriptor = -1
        }
    }
}

/// The three syscalls this file needs, named once.
///
/// Wrapped rather than called inline so the platform conditionals live in one
/// place, and so `close` cannot be confused with the writer's own method of the
/// same name.
enum POSIXFile {
    static func openForAppend(_ path: String) -> Int32 {
        path.withCString { pointer in
            #if canImport(Darwin)
            return Darwin.open(pointer, O_WRONLY | O_CREAT | O_APPEND, 0o600)
            #elseif canImport(Glibc)
            return Glibc.open(pointer, O_WRONLY | O_CREAT | O_APPEND, 0o600)
            #else
            return -1
            #endif
        }
    }

    static func write(_ descriptor: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
        #if canImport(Darwin)
        return Darwin.write(descriptor, buffer, count)
        #elseif canImport(Glibc)
        return Glibc.write(descriptor, buffer, count)
        #else
        return -1
        #endif
    }

    static func synchronize(_ descriptor: Int32) {
        #if canImport(Darwin)
        _ = Darwin.fsync(descriptor)
        #elseif canImport(Glibc)
        _ = Glibc.fsync(descriptor)
        #endif
    }

    static func close(_ descriptor: Int32) {
        #if canImport(Darwin)
        _ = Darwin.close(descriptor)
        #elseif canImport(Glibc)
        _ = Glibc.close(descriptor)
        #endif
    }
}
