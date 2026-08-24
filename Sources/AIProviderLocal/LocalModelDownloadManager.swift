import AssistantDomain
import Foundation
import NativeModelKit

/// Part 10's download vocabulary, now supplied by `NativeModelKit`.
///
/// Part 13 needs the same downloader for Whisper weights, so the transfer
/// machinery moved to a target neither AI domain owns. These aliases exist so
/// that move stayed invisible to every call site in Part 10 — the names below
/// are what the catalog, the manager, the installer and the model-management UI
/// have always called these things.
public typealias LocalModelDownloadError = NativeDownloadError
public typealias LocalModelDownloadProgress = NativeDownloadProgress

/// Runs one model download at a time, start to verified file.
///
/// A thin facade over `NativeDownloadManager<AIModelIdentifier>`: the transfer,
/// throttling, resume and cancellation all live there now, and what remains
/// here is the part that is genuinely about *language* models — that a download
/// is described by a `LocalModelDescriptor`.
///
/// Keeping the facade rather than exposing the generic type directly is what
/// stops a `SpeechModelIdentifier` ever being passed where a chat model belongs.
/// The two managers cannot be confused because they are different types.
public actor LocalModelDownloadManager {
    private let inner: NativeDownloadManager<AIModelIdentifier>

    /// Shortest gap between two progress callbacks.
    public static let progressInterval: TimeInterval =
        NativeDownloadManager<AIModelIdentifier>.progressInterval
    /// …or this much of the file, whichever happens first.
    public static let progressFractionStep =
        NativeDownloadManager<AIModelIdentifier>.progressFractionStep

    public init(
        transport: any ModelDownloadTransport = URLSessionModelDownloadTransport(),
        dateProvider: any DateProvider = SystemDateProvider()
    ) {
        self.inner = NativeDownloadManager(transport: transport, dateProvider: dateProvider)
    }

    public func isDownloading(_ id: AIModelIdentifier) async -> Bool {
        await inner.isDownloading(id)
    }

    /// True when a cancelled download left something worth resuming from.
    public func canResume(_ id: AIModelIdentifier) async -> Bool {
        await inner.canResume(id)
    }

    /// Fetches a model's weights into a temporary file.
    ///
    /// Returns the temporary file. Verification and installation are the
    /// caller's — nothing here decides a model is usable.
    public func download(
        _ descriptor: LocalModelDescriptor,
        onProgress: @Sendable @escaping (LocalModelDownloadProgress) -> Void
    ) async throws -> DownloadedFile {
        try await inner.download(
            id: descriptor.id,
            from: descriptor.downloadURL,
            displayName: descriptor.displayName,
            onProgress: onProgress
        )
    }

    /// Stops the download and keeps resume state where the transport gave any.
    public func cancel(_ id: AIModelIdentifier, url: URL?) async {
        await inner.cancel(id, url: url)
    }

    /// Throws away resume state, so the next attempt starts clean.
    public func discardResumeData(for id: AIModelIdentifier) async {
        await inner.discardResumeData(for: id)
    }
}
