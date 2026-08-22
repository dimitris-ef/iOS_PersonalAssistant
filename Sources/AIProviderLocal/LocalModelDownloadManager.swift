import AssistantDomain
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Why a download did not produce a file.
public enum LocalModelDownloadError: Error, Hashable, Sendable, CustomStringConvertible {
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
/// A protocol because sections 94, 95 and 96 ask for download success, download
/// failure and download cancellation to be *tested*, and none of those is
/// testable against the real internet: a test that needs a 2 GB transfer to
/// fail halfway is a test nobody runs. The production conformer is a thin
/// wrapper over `URLSession`; tests substitute one that produces bytes, errors
/// or a hang on demand.
public protocol ModelDownloadTransport: Sendable {
    /// Downloads `url`, reporting progress, and returns where the bytes landed.
    ///
    /// - Parameter resumeData: opaque state from a previous cancellation.
    /// - Parameter onProgress: called on an unspecified executor; already
    ///   throttled by the manager before it reaches the UI.
    func download(
        from url: URL,
        resumeData: Data?,
        onProgress: @Sendable @escaping (LocalModelDownloadProgress) -> Void
    ) async throws -> DownloadedFile

    /// Stops the in-flight download for `url`, returning resume data when the
    /// transport can produce it.
    func cancel(url: URL) async -> Data?
}

/// `URLSession`, wrapped.
///
/// Native networking, as section 18 asks — no third-party downloader, and
/// nothing clever. The complicated parts of a large download (background
/// transfer, resume data, progress) are things `URLSession` already does
/// correctly, and reimplementing them over `URLRequest` range headers is the
/// fragile custom logic section 21 warns against.
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
        onProgress: @Sendable @escaping (LocalModelDownloadProgress) -> Void
    ) async throws -> DownloadedFile {
        guard url.scheme?.lowercased() == "https" else {
            // Section 75. A model file is executable content in every sense
            // that matters; fetching one over a channel anybody on the network
            // can rewrite is not a thing this app does.
            throw LocalModelDownloadError.invalidURL(
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
                // rather than as an error (section 21).
                task.cancel { data in continuation.resume(returning: data) }
            }
        }
    }
}

/// The `URLSession` delegate for one transfer.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (LocalModelDownloadProgress) -> Void
    private var continuation: CheckedContinuation<DownloadedFile, Error>?
    private var wasResumed = false
    private var hasFinished = false
    private let lock = NSLock()

    init(onProgress: @Sendable @escaping (LocalModelDownloadProgress) -> Void) {
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
            LocalModelDownloadProgress(
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
            finish(.failure(LocalModelDownloadError.httpStatus(response.statusCode)))
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
            finish(.failure(LocalModelDownloadError.diskWrite(reason: error.localizedDescription)))
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
            finish(.failure(LocalModelDownloadError.cancelled))
        } else {
            finish(.failure(LocalModelDownloadError.transport(reason: error.localizedDescription)))
        }
    }
}

/// Runs one model download at a time, start to verified file.
///
/// ## What it owns
///
/// The transfer, the temporary file, progress throttling, cancellation and
/// resume state. It does **not** decide whether the model is a good idea
/// (compatibility), where it finally lives (the store), or what happens next
/// (the manager). Section 17 asks for a dedicated component and this is
/// deliberately a narrow one.
///
/// ## Why progress is throttled here
///
/// `URLSession` calls back per chunk, which for a 2 GB file over a fast
/// connection is thousands of times a second. Section 19: a SwiftUI view driven
/// at that rate spends more time laying out a progress bar than the download
/// spends downloading. The throttle is time-based rather than percentage-based
/// so a slow connection still shows movement.
public actor LocalModelDownloadManager {
    private let transport: any ModelDownloadTransport
    private let dateProvider: any DateProvider
    /// Resume data kept across a cancellation, per model.
    private var resumeData: [AIModelIdentifier: Data] = [:]
    private var inFlight: Set<AIModelIdentifier> = []

    /// Shortest gap between two progress callbacks.
    public static let progressInterval: TimeInterval = 0.2
    /// …or this much of the file, whichever happens first. Keeps a slow
    /// download from looking frozen and a fast one from flooding the UI.
    public static let progressFractionStep = 0.01

    public init(
        transport: any ModelDownloadTransport = URLSessionModelDownloadTransport(),
        dateProvider: any DateProvider = SystemDateProvider()
    ) {
        self.transport = transport
        self.dateProvider = dateProvider
    }

    public func isDownloading(_ id: AIModelIdentifier) -> Bool {
        inFlight.contains(id)
    }

    /// True when a cancelled download left something worth resuming from.
    public func canResume(_ id: AIModelIdentifier) -> Bool {
        resumeData[id] != nil
    }

    /// Fetches a model's weights into a temporary file.
    ///
    /// Returns the temporary file. Verification and installation are the
    /// caller's — nothing here decides a model is usable.
    public func download(
        _ descriptor: LocalModelDescriptor,
        onProgress: @Sendable @escaping (LocalModelDownloadProgress) -> Void
    ) async throws -> DownloadedFile {
        guard let url = descriptor.downloadURL else {
            throw LocalModelDownloadError.invalidURL(
                reason: "\(descriptor.displayName) has no download address."
            )
        }
        guard url.scheme?.lowercased() == "https" else {
            throw LocalModelDownloadError.invalidURL(
                reason: "Model downloads must use a secure (HTTPS) address."
            )
        }
        guard !inFlight.contains(descriptor.id) else {
            throw LocalModelDownloadError.transport(reason: "This model is already downloading.")
        }

        inFlight.insert(descriptor.id)
        defer { inFlight.remove(descriptor.id) }

        let throttle = ProgressThrottle(
            interval: Self.progressInterval,
            fractionStep: Self.progressFractionStep,
            dateProvider: dateProvider,
            downstream: onProgress
        )

        let file = try await transport.download(
            from: url,
            resumeData: resumeData[descriptor.id],
            onProgress: { throttle.report($0) }
        )
        // A completed transfer invalidates whatever we were resuming from.
        resumeData[descriptor.id] = nil
        // One final, unthrottled callback, so the bar always finishes at 100%
        // instead of stopping at whatever the last throttled tick happened to be.
        onProgress(
            LocalModelDownloadProgress(
                bytesReceived: file.byteCount,
                bytesExpected: file.byteCount
            )
        )
        return file
    }

    /// Stops the download and keeps resume state where the transport gave any.
    ///
    /// Section 20: this leaves the model *not installed*. The temporary file is
    /// the transport's and is discarded; nothing partial is ever presented as a
    /// model, which is the failure mode that would matter.
    public func cancel(_ id: AIModelIdentifier, url: URL?) async {
        guard let url else { return }
        if let data = await transport.cancel(url: url) {
            resumeData[id] = data
        } else {
            resumeData[id] = nil
        }
    }

    /// Throws away resume state, so the next attempt starts clean.
    public func discardResumeData(for id: AIModelIdentifier) {
        resumeData[id] = nil
    }
}

/// Rate-limits progress callbacks.
///
/// A class with a lock rather than an actor: it is called from `URLSession`'s
/// delegate queue on every chunk, and hopping onto an actor thousands of times
/// a second to decide *not* to report progress would cost more than the
/// reporting it is trying to avoid.
private final class ProgressThrottle: @unchecked Sendable {
    private let interval: TimeInterval
    private let fractionStep: Double
    private let dateProvider: any DateProvider
    private let downstream: @Sendable (LocalModelDownloadProgress) -> Void
    private let lock = NSLock()
    private var lastReportedAt: Date?
    private var lastFraction: Double = -1

    init(
        interval: TimeInterval,
        fractionStep: Double,
        dateProvider: any DateProvider,
        downstream: @Sendable @escaping (LocalModelDownloadProgress) -> Void
    ) {
        self.interval = interval
        self.fractionStep = fractionStep
        self.dateProvider = dateProvider
        self.downstream = downstream
    }

    func report(_ progress: LocalModelDownloadProgress) {
        let now = dateProvider.now
        let fraction = progress.fractionComplete ?? 0

        lock.lock()
        let elapsed = lastReportedAt.map { now.timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        let moved = abs(fraction - lastFraction)
        let shouldReport = elapsed >= interval || moved >= fractionStep
        if shouldReport {
            lastReportedAt = now
            lastFraction = fraction
        }
        lock.unlock()

        if shouldReport { downstream(progress) }
    }
}
