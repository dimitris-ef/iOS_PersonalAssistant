import Foundation
import SpeechToText

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One transcription request, in this provider's own vocabulary.
///
/// Deliberately not `HTTPRequest` from `AIProviderRemote`. Section 42 and 71:
/// the two providers may share *networking utilities*, not identity — and
/// reaching into the assistant provider's module for a request type would make
/// `SpeechToTextOpenAI` depend on `RemoteAIProvider`'s target, which is
/// precisely what the architecture test in section 97 forbids. The shape below
/// is small enough that owning it costs less than the coupling would.
public struct OpenAITranscriptionRequest: Sendable {
    public var url: URL
    public var apiKey: String
    /// A complete multipart body. Built by the encoder, not here.
    public var body: Data
    public var boundary: String
    public var timeout: TimeInterval

    public init(
        url: URL,
        apiKey: String,
        body: Data,
        boundary: String,
        timeout: TimeInterval
    ) {
        self.url = url
        self.apiKey = apiKey
        self.body = body
        self.boundary = boundary
        self.timeout = timeout
    }

    /// Headers, assembled at the last moment.
    ///
    /// The key is interpolated here and nowhere else, and this value is never
    /// logged — `redactedDescription` is what diagnostics print.
    var headers: [String: String] {
        [
            "Authorization": "Bearer \(apiKey)",
            "Content-Type": "multipart/form-data; boundary=\(boundary)",
        ]
    }

    /// What may safely be written to a log.
    ///
    /// The standing rule across this project: never log the key, the
    /// Authorization header, or the audio. Section 79 adds the transcript to
    /// that list. What is left — the endpoint and the payload size — is enough
    /// to diagnose a failing upload and reveals nothing about the person using
    /// it.
    public var redactedDescription: String {
        "POST \(url.path) (\(body.count) bytes, Authorization: <redacted>)"
    }
}

public struct OpenAITranscriptionResponse: Sendable {
    public var statusCode: Int
    public var body: Data

    public init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }

    public var isSuccess: Bool { (200..<300).contains(statusCode) }
}

/// Sending a transcription request.
///
/// A seam so every test in sections 110 to 113 — a successful transcription, a
/// timeout, a refused key, a cancellation — runs with no network and no
/// credential. Section 116 requires exactly that: CI must never need a real
/// OpenAI key or make a real request.
public protocol OpenAITranscriptionTransport: Sendable {
    func send(_ request: OpenAITranscriptionRequest) async throws -> OpenAITranscriptionResponse
}

/// `URLSession`, wrapped.
///
/// Uses the completion-handler API inside a continuation rather than the
/// `async` overloads, because those are not uniformly available on the Linux
/// Foundation this project develops against. The cancellation handler is what
/// makes section 51 work: cancelling the Swift task cancels the upload, rather
/// than leaving the user's audio in flight to a server they just decided not to
/// send it to.
public struct URLSessionTranscriptionTransport: OpenAITranscriptionTransport {
    private let makeSession: @Sendable () -> URLSession

    public init(session: @Sendable @escaping () -> URLSession = { .shared }) {
        self.makeSession = session
    }

    public func send(
        _ request: OpenAITranscriptionRequest
    ) async throws -> OpenAITranscriptionResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = request.timeout
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        let session = makeSession()
        let box = TaskBox()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: urlRequest) { data, response, error in
                    if let error {
                        let nsError = error as NSError
                        if nsError.domain == NSURLErrorDomain,
                           nsError.code == NSURLErrorCancelled {
                            continuation.resume(throwing: SpeechToTextError.cancelled)
                        } else {
                            continuation.resume(throwing: Self.map(nsError))
                        }
                        return
                    }
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    continuation.resume(
                        returning: OpenAITranscriptionResponse(
                            statusCode: status,
                            body: data ?? Data()
                        )
                    )
                }
                box.store(task)
                task.resume()
            }
        } onCancel: {
            box.cancel()
        }
    }

    /// Turns a URL-loading failure into something the voice UI can say.
    ///
    /// Section 52: no `NSError` domain, no numeric code, no host name reaches
    /// SwiftUI.
    static func map(_ error: NSError) -> SpeechToTextError {
        guard error.domain == NSURLErrorDomain else {
            return .transcriptionFailed(reason: "Transcription didn't complete.")
        }
        switch error.code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
             NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost,
             NSURLErrorDNSLookupFailed, NSURLErrorInternationalRoamingOff,
             NSURLErrorDataNotAllowed:
            return .networkUnavailable
        case NSURLErrorTimedOut:
            return .transcriptionFailed(
                reason: "Transcription timed out. Check your connection and try again."
            )
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted:
            return .transcriptionFailed(
                reason: "A secure connection to the transcription service couldn't be made."
            )
        default:
            return .transcriptionFailed(reason: "Transcription didn't complete.")
        }
    }

    /// Holds the in-flight task so the cancellation handler can reach it.
    ///
    /// A locked box rather than an actor: the cancellation handler is
    /// synchronous and cannot await, and a task that is cancelled a moment late
    /// is a request that has already uploaded the audio.
    private final class TaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionDataTask?
        private var cancelled = false

        func store(_ task: URLSessionDataTask) {
            lock.lock()
            defer { lock.unlock() }
            if cancelled {
                task.cancel()
            } else {
                self.task = task
            }
        }

        func cancel() {
            lock.lock()
            defer { lock.unlock() }
            cancelled = true
            task?.cancel()
            task = nil
        }
    }
}

/// A transport a test drives by hand.
public actor MockTranscriptionTransport: OpenAITranscriptionTransport {

    public enum Behaviour: Sendable {
        case returns(statusCode: Int, body: Data)
        case fails(SpeechToTextError)
        /// Blocks until the task is cancelled.
        case hangs
    }

    private var behaviour: Behaviour
    public private(set) var sentRequests: [OpenAITranscriptionRequest] = []
    public var sendCount: Int { sentRequests.count }

    public init(behaviour: Behaviour = .returns(statusCode: 200, body: Data())) {
        self.behaviour = behaviour
    }

    /// A well-formed success response with this transcript.
    public static func transcribing(_ text: String) -> MockTranscriptionTransport {
        let payload = try? JSONSerialization.data(withJSONObject: ["text": text])
        return MockTranscriptionTransport(
            behaviour: .returns(statusCode: 200, body: payload ?? Data())
        )
    }

    public func send(
        _ request: OpenAITranscriptionRequest
    ) async throws -> OpenAITranscriptionResponse {
        sentRequests.append(request)
        switch behaviour {
        case .returns(let statusCode, let body):
            return OpenAITranscriptionResponse(statusCode: statusCode, body: body)
        case .fails(let error):
            throw error
        case .hangs:
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            throw SpeechToTextError.cancelled
        }
    }

    public func setBehaviour(_ behaviour: Behaviour) { self.behaviour = behaviour }
}
