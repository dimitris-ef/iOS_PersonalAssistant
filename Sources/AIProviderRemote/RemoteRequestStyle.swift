import Foundation

/// Which optional settings a chat-completions request carries.
///
/// ## Why this exists
///
/// "OpenAI-compatible" services agree on the shape of a request but not on
/// every setting. OpenAI's recent reasoning models refuse `max_tokens` (they
/// want `max_completion_tokens`) and refuse any temperature but their own,
/// while many other compatible servers know only `max_tokens`. One fixed
/// request fails somewhere either way — and a refused setting is a failed
/// turn, not a degraded one.
///
/// So the request starts from the best guess for the host, and when the
/// service answers 400 naming a setting, that one setting is changed and the
/// request sent again. The service's own error message is the evidence; no
/// model names are hard-coded, so a new model does not need an app update.
public struct RemoteRequestStyle: Hashable, Sendable {

    public enum TokenLimitField: String, Hashable, Sendable {
        case maxTokens = "max_tokens"
        case maxCompletionTokens = "max_completion_tokens"
    }

    public var tokenLimitField: TokenLimitField
    public var sendsTemperature: Bool
    /// Sent only when a service has said it needs one.
    public var reasoningEffort: String?

    public init(
        tokenLimitField: TokenLimitField,
        sendsTemperature: Bool,
        reasoningEffort: String? = nil
    ) {
        self.tokenLimitField = tokenLimitField
        self.sendsTemperature = sendsTemperature
        self.reasoningEffort = reasoningEffort
    }

    /// What most compatible servers (local servers, routers) understand.
    public static let classic = RemoteRequestStyle(
        tokenLimitField: .maxTokens, sendsTemperature: true
    )

    /// What OpenAI's own API accepts for every current chat model.
    public static let openAI = RemoteRequestStyle(
        tokenLimitField: .maxCompletionTokens, sendsTemperature: false
    )

    /// The first guess, from the host alone.
    public static func initial(forHost host: String) -> RemoteRequestStyle {
        host.lowercased() == "api.openai.com" ? .openAI : .classic
    }

    /// The style to retry with after a 400 whose message names a setting, or
    /// nil when the message names none this type can change — in which case
    /// the error is real and goes to the person.
    public func adjusted(afterRejection message: String?) -> RemoteRequestStyle? {
        guard let text = message?.lowercased(), !text.isEmpty else { return nil }
        var next = self

        // The field currently sent is the one being complained about.
        switch tokenLimitField {
        case .maxTokens where text.contains("max_tokens"):
            next.tokenLimitField = .maxCompletionTokens
        case .maxCompletionTokens where text.contains("max_completion_tokens"):
            next.tokenLimitField = .maxTokens
        default:
            break
        }
        if sendsTemperature, text.contains("temperature") {
            next.sendsTemperature = false
        }
        if text.contains("reasoning_effort") || text.contains("reasoning effort") {
            // Asked for one (e.g. tools need "none"), or refused the one sent.
            next.reasoningEffort = reasoningEffort == nil ? "none" : nil
        }
        return next == self ? nil : next
    }
}
