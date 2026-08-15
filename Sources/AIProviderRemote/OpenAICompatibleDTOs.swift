import AssistantDomain
import Foundation

// Wire types for OpenAI-compatible chat-completions APIs.
//
// Everything in this file is protocol detail and must not escape the adapter.
// Nothing outside `AIProviderRemote` imports these types: the rest of the app
// only ever sees `AIRequest` / `AIResponse`.
//
// Field names follow the wire format, not Swift convention, via CodingKeys.

// MARK: - Request

struct OpenAIChatRequest: Encodable {
    var model: String
    var messages: [Message]
    var tools: [Tool]?
    var toolChoice: String?
    var temperature: Double?
    var maxTokens: Int?

    enum CodingKeys: String, CodingKey {
        case model, messages, tools, temperature
        case toolChoice = "tool_choice"
        case maxTokens = "max_tokens"
    }

    struct Message: Encodable {
        var role: String
        /// Nullable on the wire: an assistant turn that only calls tools has no
        /// text. Encoded explicitly as null rather than omitted, because some
        /// compatible servers require the key to be present.
        var content: String?
        var toolCalls: [ToolCall]?
        var toolCallID: String?

        enum CodingKeys: String, CodingKey {
            case role, content
            case toolCalls = "tool_calls"
            case toolCallID = "tool_call_id"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(role, forKey: .role)
            try container.encode(content, forKey: .content)
            try container.encodeIfPresent(toolCalls, forKey: .toolCalls)
            try container.encodeIfPresent(toolCallID, forKey: .toolCallID)
        }
    }

    struct ToolCall: Encodable {
        var id: String
        var type: String = "function"
        var function: Function

        struct Function: Encodable {
            var name: String
            /// A JSON *string*, not an object — that is what the protocol says.
            var arguments: String
        }
    }

    struct Tool: Encodable {
        var type: String = "function"
        var function: Function

        struct Function: Encodable {
            var name: String
            var description: String
            var parameters: JSONValue
        }
    }
}

// MARK: - Response

struct OpenAIChatResponse: Decodable {
    var id: String?
    var model: String?
    var choices: [Choice]?
    var usage: Usage?

    struct Choice: Decodable {
        var index: Int?
        var message: Message?
        var finishReason: String?

        enum CodingKeys: String, CodingKey {
            case index, message
            case finishReason = "finish_reason"
        }
    }

    struct Message: Decodable {
        var role: String?
        var content: String?
        var toolCalls: [ToolCall]?

        enum CodingKeys: String, CodingKey {
            case role, content
            case toolCalls = "tool_calls"
        }
    }

    struct ToolCall: Decodable {
        var id: String?
        var type: String?
        var function: Function?

        struct Function: Decodable {
            var name: String?
            /// JSON encoded as a string. Parsed — carefully — by the adapter.
            var arguments: String?
        }
    }

    struct Usage: Decodable {
        var promptTokens: Int?
        var completionTokens: Int?

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
        }
    }
}

// MARK: - Errors

/// The error envelope compatible services usually return.
///
/// Every field is optional and decoding never throws in a way that matters:
/// a service that returns a different shape must not turn a useful HTTP status
/// into a parsing crash.
public struct OpenAICompatibleErrorBody: Decodable, Sendable {
    public var error: APIError?

    public struct APIError: Decodable, Sendable {
        public var message: String?
        public var type: String?
        /// String on most services, an integer on some. Normalised to a string.
        public var code: String?

        enum CodingKeys: String, CodingKey {
            case message, type, code
        }

        public init(message: String?, type: String?, code: String?) {
            self.message = message
            self.type = type
            self.code = code
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            message = try? container.decodeIfPresent(String.self, forKey: .message)
            type = try? container.decodeIfPresent(String.self, forKey: .type)

            if let text = try? container.decodeIfPresent(String.self, forKey: .code) {
                code = text
            } else if let number = try? container.decodeIfPresent(Int.self, forKey: .code) {
                code = String(number)
            } else {
                code = nil
            }
        }
    }

    /// Best-effort parse. Returns nil rather than throwing, so error handling
    /// can always fall back to the HTTP status.
    public static func parse(_ data: Data) -> APIError? {
        if let body = try? JSONDecoder().decode(OpenAICompatibleErrorBody.self, from: data),
           let error = body.error,
           error.message?.isEmpty == false {
            return error
        }

        // Some servers return a bare string, or `{"message": "..."}`.
        if let object = try? JSONDecoder().decode([String: JSONValue].self, from: data),
           let message = object["message"]?.stringValue ?? object["detail"]?.stringValue {
            return APIError(message: message, type: nil, code: nil)
        }

        guard
            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else { return nil }

        // Don't paste an entire HTML error page into the UI.
        return APIError(message: String(text.prefix(200)), type: nil, code: nil)
    }
}
