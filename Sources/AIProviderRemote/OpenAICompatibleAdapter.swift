import AssistantAI
import AssistantDomain
import Foundation

/// Speaks the OpenAI chat-completions protocol.
///
/// This is the only type in the application that knows what `tool_calls`,
/// `finish_reason` or `Authorization: Bearer` mean. Everything above it deals
/// in `AIRequest` / `AIResponse`, which is what makes the service swappable:
/// pointing the endpoint at a self-hosted server, a proxy or another vendor
/// implementing the same protocol needs no change anywhere else.
///
/// It is called "compatible" rather than "OpenAI" on purpose — the protocol is
/// the contract, not the company.
public struct OpenAICompatibleAdapter: RemoteAPIAdapter {
    public let providerID: AIProviderIdentifier
    public let displayName: String
    public let capabilityRank: Int

    public init(
        providerID: AIProviderIdentifier = "remote.openai-compatible",
        displayName: String = "Cloud Model",
        capabilityRank: Int = 100
    ) {
        self.providerID = providerID
        self.displayName = displayName
        self.capabilityRank = capabilityRank
    }

    /// Compatible services expose `/models`, but the list is long, unstable and
    /// mostly irrelevant. The configured model name is the answer.
    public func availableModels(configuration: RemoteAIConfiguration) async throws -> [AIModel] {
        let name = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return [] }
        return [
            AIModel(
                id: AIModelIdentifier(name),
                displayName: name,
                contextWindow: nil,
                // Assumed, not verified. If the service disagrees it says so,
                // and `RemoteAIError.toolCallingUnsupported` surfaces it.
                supportsNativeToolCalling: true,
                isOnDevice: false
            )
        ]
    }

    // MARK: Request

    public func makeRequest(
        from request: AIRequest,
        configuration: RemoteAIConfiguration,
        credential: String
    ) throws -> HTTPRequest {
        guard let endpoint = RemoteAIEndpoint(baseURL: configuration.baseURL) else {
            throw RemoteAIError.invalidEndpoint(configuration.baseURL)
        }

        let model = request.model?.rawValue ?? configuration.model
        let payload = OpenAIChatRequest(
            model: model,
            messages: messages(for: request),
            tools: request.tools.isEmpty ? nil : request.tools.map(tool(from:)),
            toolChoice: request.tools.isEmpty ? nil : "auto",
            temperature: request.options.temperature ?? configuration.temperature,
            maxTokens: request.options.maximumOutputTokens ?? configuration.maximumOutputTokens
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body: Data
        do {
            body = try encoder.encode(payload)
        } catch {
            throw RemoteAIError.malformedResponse(
                detail: "could not encode the request: \(error)"
            )
        }

        return HTTPRequest(
            url: endpoint.chatCompletionsURL(),
            method: "POST",
            headers: [
                "Content-Type": "application/json",
                // Bearer auth is a protocol detail and stays in this file.
                "Authorization": "Bearer \(credential)",
            ],
            body: body,
            timeout: configuration.timeout
        )
    }

    /// Maps the app's messages onto the protocol's roles.
    ///
    /// The system prompt comes from `AssistantEngine`'s prompt builder — this
    /// adapter never writes instructions of its own. Its job is transport.
    private func messages(for request: AIRequest) -> [OpenAIChatRequest.Message] {
        var result: [OpenAIChatRequest.Message] = []

        let systemPrompt = request.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !systemPrompt.isEmpty {
            result.append(
                OpenAIChatRequest.Message(role: "system", content: request.systemPrompt)
            )
        }

        for message in request.messages {
            switch message.role {
            case .system:
                result.append(.init(role: "system", content: message.content))
            case .user:
                result.append(.init(role: "user", content: message.content))
            case .assistant:
                result.append(
                    .init(
                        role: "assistant",
                        // Null rather than "" when the turn was only tool calls.
                        content: message.content.isEmpty ? nil : message.content,
                        toolCalls: message.toolCalls.isEmpty
                            ? nil
                            : message.toolCalls.map { call in
                                OpenAIChatRequest.ToolCall(
                                    id: call.id.description,
                                    function: .init(
                                        name: call.name,
                                        arguments: Self.encodeArguments(call.arguments)
                                    )
                                )
                            }
                    )
                )
            case .tool:
                // The protocol requires the id of the call being answered.
                result.append(
                    .init(
                        role: "tool",
                        content: Self.toolContent(for: message),
                        toolCallID: message.toolCallID?.description
                    )
                )
            }
        }

        return result
    }

    /// Converts one of the application's existing tool schemas into the
    /// protocol's function shape.
    ///
    /// There is no second set of tool definitions: `JSONSchema.jsonValue()` is
    /// the same rendering the app already uses, so a tool added to
    /// `ToolCatalog` is automatically offered to the model with its real
    /// parameters, types, enums and required fields.
    private func tool(from schema: AIToolSchema) -> OpenAIChatRequest.Tool {
        OpenAIChatRequest.Tool(
            function: .init(
                name: schema.name,
                description: schema.description,
                parameters: schema.parameters.jsonValue()
            )
        )
    }

    /// A tool result in this protocol's shape.
    ///
    /// This is the adapter half of the provider-neutral result contract: the
    /// engine hands over an ``AIToolResult``, and turning it into something a
    /// particular model can read is this file's business and nowhere else's.
    /// The protocol's tool message carries a string, so the structure is
    /// rendered as compact JSON — models parse that far more reliably than
    /// prose, and the fields are named the same way the tool schemas are.
    ///
    /// The rendered sentence goes in alongside it rather than being replaced,
    /// because it is where the plain statement of "this was only simulated"
    /// lives, and losing that would let a model tell someone their phone did
    /// something it did not.
    ///
    /// Falls back to the message's own text when there is no structured result,
    /// which is what a caller that built the message by hand gets.
    static func toolContent(for message: AIMessage) -> String {
        guard let result = message.toolResult else { return message.content }

        var object: [String: JSONValue] = [
            "tool": .string(result.toolName),
            "status": .string(result.status.rawValue),
            "summary": .string(result.message),
        ]
        if let failure = result.failure {
            object["error"] = .string(failure.rawValue)
            object["recovery"] = .string(failure.recovery.rawValue)
        }
        if result.wasAlreadyPerformed {
            object["alreadyPerformed"] = .bool(true)
        }
        for (key, value) in result.payload {
            object[key] = .string(value)
        }

        guard
            let data = try? JSONCoding.encoder.encode(JSONValue.object(object)),
            let text = String(data: data, encoding: .utf8)
        else {
            return result.renderedForModel
        }
        return text
    }

    private static func encodeArguments(_ value: JSONValue) -> String {
        guard
            let data = try? JSONCoding.encoder.encode(value),
            let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }

    // MARK: Response

    public func parse(_ response: HTTPResponse, for request: AIRequest) throws -> AIResponse {
        let decoded: OpenAIChatResponse
        do {
            decoded = try JSONDecoder().decode(OpenAIChatResponse.self, from: response.body)
        } catch {
            throw RemoteAIError.malformedResponse(detail: "the reply was not valid JSON")
        }

        guard let choice = decoded.choices?.first else {
            throw RemoteAIError.malformedResponse(detail: "the reply contained no choices")
        }
        guard let message = choice.message else {
            throw RemoteAIError.malformedResponse(detail: "the reply contained no message")
        }

        let toolCalls = parseToolCalls(message.toolCalls)
        let text = message.content ?? ""

        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && toolCalls.isEmpty {
            throw RemoteAIError.malformedResponse(
                detail: "the reply contained no text and no actions"
            )
        }

        return AIResponse(
            text: text,
            toolCalls: toolCalls,
            stopReason: Self.stopReason(from: choice.finishReason, hasToolCalls: !toolCalls.isEmpty),
            usage: AIUsage(
                inputTokens: decoded.usage?.promptTokens,
                outputTokens: decoded.usage?.completionTokens
            ),
            providerID: providerID,
            // Spelled out rather than `map(AIModelIdentifier.init)`: the type
            // has both a plain and a string-literal initialiser, so the
            // unapplied reference is ambiguous.
            modelID: decoded.model.map { AIModelIdentifier($0) } ?? request.model
        )
    }

    /// Turns wire tool calls into the app's neutral shape.
    ///
    /// Nothing is validated here beyond "is this JSON" — deciding whether a
    /// call is *acceptable* belongs to `ToolRequestDecoder` and the
    /// authorization layer, which are authoritative. A call whose arguments
    /// cannot be parsed is passed on with null arguments precisely so the
    /// decoder rejects it and it appears in the plan's rejected list, rather
    /// than being silently dropped here.
    private func parseToolCalls(_ calls: [OpenAIChatResponse.ToolCall]?) -> [AIToolCall] {
        guard let calls else { return [] }

        return calls.compactMap { call in
            guard let name = call.function?.name, !name.isEmpty else { return nil }

            let arguments: JSONValue
            if let text = call.function?.arguments,
               let data = text.data(using: .utf8),
               let parsed = try? JSONCoding.decoder.decode(JSONValue.self, from: data),
               parsed.objectValue != nil {
                arguments = parsed
            } else {
                arguments = .null
            }

            return AIToolCall(
                id: Self.identifier(from: call.id),
                name: name,
                arguments: arguments
            )
        }
    }

    /// The service's call id is an opaque string; the app uses UUID-backed
    /// identifiers. A deterministic mapping keeps the association stable for
    /// the follow-up round without the app adopting the service's id format.
    private static func identifier(from remoteID: String?) -> ToolCallID {
        guard let remoteID, let uuid = UUID(uuidString: remoteID) else {
            return ToolCallID()
        }
        return ToolCallID(uuid)
    }

    private static func stopReason(from finishReason: String?, hasToolCalls: Bool) -> AIStopReason {
        switch finishReason {
        case "tool_calls", "function_call":
            return .toolCalls
        case "length":
            return .maximumTokens
        case "content_filter":
            return .refusal
        case "stop":
            return hasToolCalls ? .toolCalls : .endTurn
        default:
            return hasToolCalls ? .toolCalls : .endTurn
        }
    }
}
