import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Why a download did not produce a file.
///
/// Named for *native model files* rather than for language models, because two
/// unrelated subsystems now fetch large binaries onto the phone: Part 10's
/// llama.cpp weights and Part 13's Whisper weights. The failures are identical —
/// a reset connection is a reset connection — while the things being downloaded
/// are not, which is exactly the line section 82 draws between sharing generic
/// infrastructure and pretending two domains are one.
public enum NativeDownloadError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The catalog entry has no URL, or one this app refuses to fetch.
    case invalidURL(reason: String)
    /// The transfer failed: no network, a reset, a timeout.
    case transport(reason: String)
    /// The server answered, but not with a file.
    case httpStatus(Int)
    /// Could not write to disk — full, or a permissions problem.
    case diskWrite(reason: String)
    case cancelled
    /// The bytes arrived and were not what was promised.
    case checksumMismatch(expected: String, actual: String)
    /// The bytes arrived and are not a model.
    case notAModel(reason: String)
    /// The file is a model, but not the one the catalog described.
    case modelMismatch(reason: String)
    case insufficientStorage(reason: String)

    public var description: String {
        switch self {
        case .invalidURL(let reason): return reason
        case .transport(let reason): return "The download failed: \(reason)"
        case .httpStatus(let code): return "The download failed (HTTP \(code))."
        case .diskWrite(let reason): return "The model could not be saved: \(reason)"
        case .cancelled: return "The download was cancelled."
        case .checksumMismatch:
            // Never the two digests: a 64-character hex string in an alert is
            // noise to everyone who reads it. The actionable half is "retry".
            return "The downloaded file is damaged. Try downloading it again."
        case .notAModel(let reason): return "The downloaded file is not a usable model: \(reason)"
        case .modelMismatch(let reason): return reason
        case .insufficientStorage(let reason): return reason
        }
    }

    /// Whether offering "Try again" makes sense.
    public var isRetryable: Bool {
        switch self {
        case .transport, .httpStatus, .checksumMismatch, .cancelled, .diskWrite:
            return true
        case .invalidURL, .notAModel, .modelMismatch, .insufficientStorage:
            return false
        }
    }
}

/// How far a transfer has got.
public struct NativeDownloadProgress: Hashable, Sendable, Codable {
    public var bytesReceived: Int64
    /// Nil when the server did not send a content length.
    public var bytesExpected: Int64?

    public init(bytesReceived: Int64, bytesExpected: Int64?) {
        self.bytesReceived = bytesReceived
        self.bytesExpected = bytesExpected
    }

    public var fractionComplete: Double? {
        guard let bytesExpected, bytesExpected > 0 else { return nil }
        return min(1, max(0, Double(bytesReceived) / Double(bytesExpected)))
    }

    public var percentLabel: String {
        guard let fraction = fractionComplete else { return "" }
        return "\(Int(fraction * 100))%"
    }

    public static let zero = NativeDownloadProgress(bytesReceived: 0, bytesExpected: nil)
}

/// Where a completed transfer left its bytes.
public struct DownloadedFile: Sendable {
    /// A temporary location the caller owns and must move or delete.
    public var url: URL
    public var byteCount: Int64
    /// Set when the transfer was resumed rather than started fresh.
    public var wasResumed: Bool

    public init(url: URL, byteCount: Int64, wasResumed: Bool = false) {
        self.url = url
        self.byteCount = byteCount
        self.wasResumed = wasResumed
    }
}

/// Moving bytes from a URL to a temporary file.
///
/// A protocol because download success, download failure and download
/// cancellation all have to be *tested*, and none of those is testable against
/// the real internet: a test that needs a 2 GB transfer to fail halfway is a
/// test nobody runs. The production conformer is a thin wrapper over
/// `URLSession`; tests substitute one that produces bytes, errors or a hang on
/// demand.
public protocol ModelDownloadTransport: Sendable {
    /// Downloads `url`, reporting progress, and returns where the bytes landed.
    ///
    /// - Parameter resumeData: opaque state from a previous cancellation.
    /// - Parameter onProgress: called on an unspecified executor; already
    ///   throttled by the manager before it reaches the UI.
    func download(
        from url: URL,
        resumeData: Data?,
        onProgress: @Sendable @escaping (NativeDownloadProgress) -> Void
    ) async throws -> DownloadedFile

    /// Stops the in-flight download for `url`, returning resume data when the
    /// transport can produce it.
    func cancel(url: URL) async -> Data?
}

/// `URLSession`, wrapped.
///
/// Native networking — no third-party downloader, and nothing clever. The
/// complicated parts of a large download (background transfer, resume data,
/// progress) are things `URLSession` already does correctly, and reimplementing
/// them over `URLRequest` range headers is fragile custom logic.
///
/// - Note: the configuration arrives as a factory rather than an instance.
///   `URLSessionConfiguration` is a mutable Foundation class and is not
///   `Sendable`, so storing one would make this transport non-`Sendable` and
///   force an `@unchecked` escape hatch on a type that does not need one.
public final class URLSessionModelDownloadTransport: ModelDownloadTransport {
    private let makeConfiguration: @Sendable () -> URLSessionConfiguration
    private let state = TransportState()

    public init(
        configuration: @Sendable @escaping () -> URLSessionConfiguration = { .default }
    ) {
        self.makeConfiguration = configuration
    }

    public func download(
        from url: URL,
        resumeData: Data?,
        onProgress: @Sendable @escaping (NativeDownloadProgress) -> Void
    ) async throws -> DownloadedFile {
        guard url.scheme?.lowercased() == "https" else {
            // A model file is executable content in every sense that matters;
            // fetching one over a channel anybody on the network can rewrite is
            // not a thing this app does.
            throw NativeDownloadError.invalidURL(
                reason: "Model downloads must use a secure (HTTPS) address."
            )
        }

        let delegate = DownloadDelegate(onProgress: onProgress)
        let session = URLSession(
            configuration: makeConfiguration(),
            delegate: delegate,
            delegateQueue: nil
        )
        // The session holds its delegate strongly until invalidated. Without
        // this the delegate outlives the transfer and the session leaks — one
        // per download, each holding a connection.
        defer { session.finishTasksAndInvalidate() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task: URLSessionDownloadTask
                if let resumeData {
                    task = session.downloadTask(withResumeData: resumeData)
                } else {
                    task = session.downloadTask(with: url)
                }
                delegate.prepare(
                    continuation: continuation,
                    wasResumed: resumeData != nil
                )
                Task { await self.state.register(task: task, for: url) }
                task.resume()
            }
        } onCancel: {
            Task { await self.state.cancelTask(for: url) }
        }
    }

    public func cancel(url: URL) async -> Data? {
        await state.cancelTask(for: url)
    }

    /// Tasks in flight, so a cancel from the UI can reach one.
    private actor TransportState {
        private var tasks: [URL: URLSessionDownloadTask] = [:]

        func register(task: URLSessionDownloadTask, for url: URL) {
            tasks[url] = task
        }

        func cancelTask(for url: URL) async -> Data? {
            guard let task = tasks.removeValue(forKey: url) else { return nil }
            return await withCheckedContinuation { continuation in
                // Resume data where the server supports it; nil where it does
                // not, which the manager reads as "start again next time"
                // rather than as an error.
                task.cancel { data in continuation.resume(returning: data) }
            }
        }
    }
}

/// The `URLSession` delegate for one transfer.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (NativeDownloadProgress) -> Void
    private var continuation: CheckedContinuation<DownloadedFile, Error>?
    private var wasResumed = false
    private var hasFinished = false
    private let lock = NSLock()

    init(onProgress: @Sendable @escaping (NativeDownloadProgress) -> Void) {
        self.onProgress = onProgress
    }

    func prepare(continuation: CheckedContinuation<DownloadedFile, Error>, wasResumed: Bool) {
        lock.lock()
        defer { lock.unlock() }
        self.continuation = continuation
        self.wasResumed = wasResumed
    }

    /// Resumes the continuation exactly once.
    ///
    /// `URLSession` can call both `didFinishDownloadingTo` and
    /// `didCompleteWithError`, and resuming a continuation twice is a crash,
    /// not a warning.
    private func finish(_ result: Result<DownloadedFile, Error>) {
        lock.lock()
        guard !hasFinished, let continuation else {
            lock.unlock()
            return
        }
        hasFinished = true
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        onProgress(
            NativeDownloadProgress(
                bytesReceived: totalBytesWritten,
                bytesExpected: totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
            )
        )
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let response = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(response.statusCode) {
            // A 404 page is still "a successful download" to URLSession. It is
            // not one here — the alternative is installing an HTML error page
            // as a model.
            try? FileManager.default.removeItem(at: location)
            finish(.failure(NativeDownloadError.httpStatus(response.statusCode)))
            return
        }

        // The temporary file is deleted the moment this method returns, so it
        // has to be moved now, synchronously, before anything is reported.
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-download-\(UUID().uuidString).part")
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            finish(.success(DownloadedFile(url: destination, byteCount: size, wasResumed: wasResumed)))
        } catch {
            finish(.failure(NativeDownloadError.diskWrite(reason: error.localizedDescription)))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            finish(.failure(NativeDownloadError.cancelled))
        } else {
            finish(.failure(NativeDownloadError.transport(reason: error.localizedDescription)))
        }
    }
}
