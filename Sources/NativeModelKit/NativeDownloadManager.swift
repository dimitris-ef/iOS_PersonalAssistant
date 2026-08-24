import AssistantDomain
import Foundation

/// Runs one download at a time per key, start to temporary file.
///
/// ## What it owns
///
/// The transfer, the temporary file, progress throttling, cancellation and
/// resume state. It does **not** decide whether the file is a good idea
/// (compatibility), where it finally lives (the store), or what happens next
/// (a domain-specific manager).
///
/// ## Why it is generic over the key
///
/// Part 10 keys downloads by `AIModelIdentifier` and Part 13 by
/// `SpeechModelIdentifier`. Those are deliberately different types — a Whisper
/// model is not a chat model and the app must never be able to confuse them —
/// but the *download* is byte-for-byte the same problem. Making the key a
/// parameter is what lets one implementation serve both without either domain
/// borrowing the other's vocabulary.
///
/// ## Why progress is throttled here
///
/// `URLSession` calls back per chunk, which for a large file over a fast
/// connection is thousands of times a second. A SwiftUI view driven at that
/// rate spends more time laying out a progress bar than the download spends
/// downloading. The throttle is time-based as well as percentage-based so a
/// slow connection still shows movement.
public actor NativeDownloadManager<Key: Hashable & Sendable> {
    private let transport: any ModelDownloadTransport
    private let dateProvider: any DateProvider
    /// Resume data kept across a cancellation, per key.
    private var resumeData: [Key: Data] = [:]
    private var inFlight: Set<Key> = []

    /// Shortest gap between two progress callbacks.
    public static var progressInterval: TimeInterval { 0.2 }
    /// …or this much of the file, whichever happens first. Keeps a slow
    /// download from looking frozen and a fast one from flooding the UI.
    public static var progressFractionStep: Double { 0.01 }

    public init(
        transport: any ModelDownloadTransport = URLSessionModelDownloadTransport(),
        dateProvider: any DateProvider = SystemDateProvider()
    ) {
        self.transport = transport
        self.dateProvider = dateProvider
    }

    public func isDownloading(_ id: Key) -> Bool {
        inFlight.contains(id)
    }

    /// True when a cancelled download left something worth resuming from.
    public func canResume(_ id: Key) -> Bool {
        resumeData[id] != nil
    }

    /// Fetches a file into a temporary location.
    ///
    /// Returns the temporary file. Verification and installation are the
    /// caller's — nothing here decides a file is usable.
    ///
    /// - Parameter displayName: used only to write a readable message when the
    ///   entry has no address. The manager never renders anything itself.
    public func download(
        id: Key,
        from url: URL?,
        displayName: String,
        onProgress: @Sendable @escaping (NativeDownloadProgress) -> Void
    ) async throws -> DownloadedFile {
        guard let url else {
            throw NativeDownloadError.invalidURL(
                reason: "\(displayName) has no download address."
            )
        }
        guard url.scheme?.lowercased() == "https" else {
            throw NativeDownloadError.invalidURL(
                reason: "Model downloads must use a secure (HTTPS) address."
            )
        }
        guard !inFlight.contains(id) else {
            throw NativeDownloadError.transport(reason: "This model is already downloading.")
        }

        inFlight.insert(id)
        defer { inFlight.remove(id) }

        let throttle = ProgressThrottle(
            interval: Self.progressInterval,
            fractionStep: Self.progressFractionStep,
            dateProvider: dateProvider,
            downstream: onProgress
        )

        let file = try await transport.download(
            from: url,
            resumeData: resumeData[id],
            onProgress: { throttle.report($0) }
        )
        // A completed transfer invalidates whatever we were resuming from.
        resumeData[id] = nil
        // One final, unthrottled callback, so the bar always finishes at 100%
        // instead of stopping at whatever the last throttled tick happened to be.
        onProgress(
            NativeDownloadProgress(
                bytesReceived: file.byteCount,
                bytesExpected: file.byteCount
            )
        )
        return file
    }

    /// Stops the download and keeps resume state where the transport gave any.
    ///
    /// This leaves the model *not installed*. The temporary file is the
    /// transport's and is discarded; nothing partial is ever presented as a
    /// model, which is the failure mode that would matter.
    public func cancel(_ id: Key, url: URL?) async {
        guard let url else { return }
        if let data = await transport.cancel(url: url) {
            resumeData[id] = data
        } else {
            resumeData[id] = nil
        }
    }

    /// Throws away resume state, so the next attempt starts clean.
    public func discardResumeData(for id: Key) {
        resumeData[id] = nil
    }
}

/// Rate-limits progress callbacks.
///
/// A class with a lock rather than an actor: it is called from `URLSession`'s
/// delegate queue on every chunk, and hopping onto an actor thousands of times
/// a second to decide *not* to report progress would cost more than the
/// reporting it is trying to avoid.
final class ProgressThrottle: @unchecked Sendable {
    private let interval: TimeInterval
    private let fractionStep: Double
    private let dateProvider: any DateProvider
    private let downstream: @Sendable (NativeDownloadProgress) -> Void
    private let lock = NSLock()
    private var lastReportedAt: Date?
    private var lastFraction: Double = -1

    init(
        interval: TimeInterval,
        fractionStep: Double,
        dateProvider: any DateProvider,
        downstream: @Sendable @escaping (NativeDownloadProgress) -> Void
    ) {
        self.interval = interval
        self.fractionStep = fractionStep
        self.dateProvider = dateProvider
        self.downstream = downstream
    }

    func report(_ progress: NativeDownloadProgress) {
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
