import AssistantAI
import Foundation

/// What went wrong talking to a remote service.
///
/// Typed rather than a single "network error", because the answer to each of
/// these is different: a bad key needs Settings, a 429 needs waiting, a 404
/// usually means the endpoint or model name is wrong. Every case carries a
/// sentence written for the person reading it.
///
/// No case ever carries the API key. `RemoteAIError` is safe to log.
public enum RemoteAIError: Error, Hashable, Sendable {
    /// Endpoint, key or model missing before any request was attempted.
    case notConfigured(missing: [RemoteAIConfiguration.Requirement])
    /// The configured endpoint is not a usable URL.
    case invalidEndpoint(String)

    /// 401 / 403.
    case authenticationFailed(detail: String?)
    /// 404 — usually a wrong endpoint path or an unknown model.
    case notFound(detail: String?)
    /// 429.
    case rateLimited(detail: String?, retryAfter: TimeInterval?)
    /// Other 4xx — a request the service rejected.
    case requestRejected(status: Int, detail: String?)
    /// 5xx.
    case serverError(status: Int, detail: String?)

    /// The service says it cannot do tool calling with this model.
    case toolCallingUnsupported(detail: String?)

    /// Transport-level failure: offline, DNS, TLS, connection reset.
    case network(detail: String)
    case timedOut
    case cancelled

    /// HTTP succeeded but the body was not something we can use.
    case malformedResponse(detail: String)

    /// A sentence to show the user. Never contains credentials.
    public var userFacingDescription: String {
        switch self {
        case .notConfigured(let missing):
            guard !missing.isEmpty else { return "Remote AI is not configured yet." }
            let labels = missing.map(\.label)
            let list: String
            if labels.count == 1 {
                list = labels[0]
            } else {
                list = labels.dropLast().joined(separator: ", ") + " and " + labels[labels.count - 1]
            }
            return "Remote AI needs \(list)."
        case .invalidEndpoint(let value):
            return "That endpoint isn't a valid URL: \(value)"
        case .authenticationFailed(let detail):
            return detail.map { "The service rejected the API key: \($0)" }
                ?? "The service rejected the API key."
        case .notFound(let detail):
            return detail.map { "Not found — check the endpoint and model name. \($0)" }
                ?? "Not found — check the endpoint and model name."
        case .rateLimited(let detail, let retryAfter):
            let wait = retryAfter.map { " Try again in about \(Int($0))s." } ?? ""
            return (detail.map { "Rate limited: \($0)." } ?? "Rate limited.") + wait
        case .requestRejected(let status, let detail):
            return detail.map { "The service rejected the request (\(status)): \($0)" }
                ?? "The service rejected the request (HTTP \(status))."
        case .serverError(let status, let detail):
            return detail.map { "The service had a problem (\(status)): \($0)" }
                ?? "The service had a problem (HTTP \(status))."
        case .toolCallingUnsupported(let detail):
            return detail.map { "This model doesn't support tool calling: \($0)" }
                ?? "This model doesn't support tool calling, so the assistant can't take actions with it."
        case .network(let detail):
            return "Couldn't reach the service: \(detail)"
        case .timedOut:
            return "The service took too long to answer."
        case .cancelled:
            return "Cancelled."
        case .malformedResponse(let detail):
            return "The service sent something unexpected: \(detail)"
        }
    }

    /// A short, non-sensitive category for logs and metrics.
    public var category: String {
        switch self {
        case .notConfigured: return "not-configured"
        case .invalidEndpoint: return "invalid-endpoint"
        case .authenticationFailed: return "auth"
        case .notFound: return "not-found"
        case .rateLimited: return "rate-limited"
        case .requestRejected: return "rejected"
        case .serverError: return "server-error"
        case .toolCallingUnsupported: return "tools-unsupported"
        case .network: return "network"
        case .timedOut: return "timeout"
        case .cancelled: return "cancelled"
        case .malformedResponse: return "malformed-response"
        }
    }

    /// How this surfaces to the rest of the app, which only knows
    /// `AIProviderError`.
    public var asProviderError: AIProviderError {
        switch self {
        case .notConfigured, .invalidEndpoint:
            return .missingCredentials(userFacingDescription)
        case .network, .timedOut:
            return .transport(userFacingDescription)
        case .cancelled:
            return .cancelled
        case .authenticationFailed, .notFound, .rateLimited, .requestRejected,
             .serverError, .toolCallingUnsupported, .malformedResponse:
            return .invalidResponse(userFacingDescription)
        }
    }

    /// Maps an HTTP status and a parsed service error into a typed case.
    public static func from(
        status: Int,
        apiError: OpenAICompatibleErrorBody.APIError?,
        retryAfter: TimeInterval? = nil
    ) -> RemoteAIError {
        let detail = apiError?.message

        // Some services report an unsupported capability as a plain 400.
        if let detail, status == 400 {
            let lowered = detail.lowercased()
            if lowered.contains("tool") || lowered.contains("function") {
                if lowered.contains("not supported") || lowered.contains("unsupported")
                    || lowered.contains("does not support") {
                    return .toolCallingUnsupported(detail: detail)
                }
            }
        }

        switch status {
        case 401, 403:
            return .authenticationFailed(detail: detail)
        case 404:
            return .notFound(detail: detail)
        case 429:
            return .rateLimited(detail: detail, retryAfter: retryAfter)
        case 400..<500:
            return .requestRejected(status: status, detail: detail)
        default:
            return .serverError(status: status, detail: detail)
        }
    }

    /// Classifies a `URLError`-shaped transport failure.
    ///
    /// Matched on `URLError` where available, falling back to the bridged
    /// `NSError` domain/code so this also works on the Linux Foundation used
    /// during Windows-stage development.
    public static func from(transport error: any Error) -> RemoteAIError {
        if error is CancellationError { return .cancelled }

        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else {
            return .network(detail: nsError.localizedDescription)
        }

        switch nsError.code {
        case NSURLErrorTimedOut:
            return .timedOut
        case NSURLErrorCancelled:
            return .cancelled
        case NSURLErrorNotConnectedToInternet:
            return .network(detail: "no internet connection")
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return .network(detail: "the host could not be found")
        case NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost:
            return .network(detail: "the connection failed")
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted:
            return .network(detail: "the secure connection failed")
        default:
            return .network(detail: nsError.localizedDescription)
        }
    }
}
