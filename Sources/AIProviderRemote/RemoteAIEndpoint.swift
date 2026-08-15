import Foundation

/// A validated service root, and the routes derived from it.
///
/// People paste endpoints in every shape: with and without a scheme, with and
/// without `/v1`, with and without a trailing slash, and sometimes with the
/// full `/v1/chat/completions` path already on the end. All of those should
/// work, and none of them should produce `/v1/v1/chat/completions`.
///
/// The normalisation lives here rather than in the adapter so it can be tested
/// on its own, which is the only way to be confident about a rule set this
/// fiddly.
public struct RemoteAIEndpoint: Hashable, Sendable {
    /// The normalised root, without a trailing slash.
    public let baseURL: URL

    public init?(baseURL raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // A bare host is a common paste. Assume HTTPS rather than rejecting it.
        if !text.contains("://") {
            text = "https://" + text
        }

        while text.hasSuffix("/") {
            text.removeLast()
        }

        // Tolerate someone pasting the full chat-completions URL.
        for suffix in ["/chat/completions", "/completions"] where text.hasSuffix(suffix) {
            text.removeLast(suffix.count)
            break
        }

        guard
            let url = URL(string: text),
            let scheme = url.scheme?.lowercased(),
            let host = url.host,
            !host.isEmpty
        else { return nil }

        // http is allowed so a self-hosted server on a local network stays
        // usable; anything else is not a web endpoint.
        guard scheme == "https" || scheme == "http" else { return nil }

        self.baseURL = url
    }

    public var host: String { baseURL.host ?? "" }

    /// True for a plaintext endpoint, which the UI warns about rather than
    /// blocking — local inference servers are usually http.
    public var isInsecure: Bool { baseURL.scheme?.lowercased() == "http" }

    /// The OpenAI-compatible chat-completions route.
    ///
    /// `/v1` is appended only when the configured root does not already end in
    /// a version segment, so both `…/openai.com` and `…/openai.com/v1` work.
    public func chatCompletionsURL() -> URL {
        var url = baseURL
        if !hasVersionSuffix {
            url.appendPathComponent("v1")
        }
        url.appendPathComponent("chat")
        url.appendPathComponent("completions")
        return url
    }

    /// Matches `/v1`, `/v1beta`, `/openai/v1` and similar tails.
    private var hasVersionSuffix: Bool {
        guard let last = baseURL.pathComponents.last else { return false }
        return last.range(of: "^v[0-9]+", options: [.regularExpression, .caseInsensitive]) != nil
    }
}
