import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPRequest: Sendable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data?
    /// Per-request timeout. Kept on the request rather than baked into the
    /// transport so configuration owns it, not the networking code.
    public var timeout: TimeInterval?

    public init(
        url: URL,
        method: String = "POST",
        headers: [String: String] = [:],
        body: Data? = nil,
        timeout: TimeInterval? = nil
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }

    /// Headers with anything sensitive removed. Use this when logging.
    public var redactedHeaders: [String: String] {
        var copy = headers
        for name in copy.keys where name.lowercased() == "authorization" || name.lowercased() == "api-key" {
            copy[name] = "<redacted>"
        }
        return copy
    }
}

public struct HTTPResponse: Sendable {
    public var statusCode: Int
    public var body: Data
    public var headers: [String: String]

    public init(statusCode: Int, body: Data, headers: [String: String] = [:]) {
        self.statusCode = statusCode
        self.body = body
        self.headers = headers
    }

    public var isSuccess: Bool { (200..<300).contains(statusCode) }

    /// Case-insensitive header lookup — servers are inconsistent about case.
    public func header(_ name: String) -> String? {
        let wanted = name.lowercased()
        for (key, value) in headers where key.lowercased() == wanted {
            return value
        }
        return nil
    }
}

/// Minimal HTTP seam.
///
/// A protocol rather than direct `URLSession` use so the provider is testable
/// without a network and so the iOS build can substitute its own session
/// (background configuration, pinning, proxying) without touching provider code.
public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// `URLSession`-backed transport.
///
/// Uses the completion-handler API wrapped in a continuation rather than the
/// `async` overloads, because those are not uniformly available across the
/// Linux Foundation used for Windows-stage development. The cancellation
/// handler makes Swift task cancellation cancel the underlying HTTP request,
/// so abandoning a turn does not leave a request in flight.
public struct URLSessionHTTPTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        if let timeout = request.timeout {
            urlRequest.timeoutInterval = timeout
        }
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        let handle = TaskHandle()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: urlRequest) { data, response, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }

                    let httpResponse = response as? HTTPURLResponse
                    var headers: [String: String] = [:]
                    for (key, value) in httpResponse?.allHeaderFields ?? [:] {
                        if let name = key as? String, let text = value as? String {
                            headers[name] = text
                        }
                    }

                    continuation.resume(
                        returning: HTTPResponse(
                            statusCode: httpResponse?.statusCode ?? 0,
                            body: data ?? Data(),
                            headers: headers
                        )
                    )
                }
                handle.adopt(task)
                task.resume()
            }
        } onCancel: {
            handle.cancel()
        }
    }
}

/// Holds the in-flight task so the cancellation handler can reach it.
private final class TaskHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var isCancelled = false

    func adopt(_ task: URLSessionDataTask) {
        lock.lock()
        defer { lock.unlock() }
        // Cancellation can arrive before the task is created.
        if isCancelled {
            task.cancel()
        } else {
            self.task = task
        }
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        isCancelled = true
        task?.cancel()
    }
}
