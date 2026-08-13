import AssistantDomain
import Foundation

public struct AIGenerationOptions: Hashable, Codable, Sendable {
    public var temperature: Double?
    public var maximumOutputTokens: Int?
    /// Hard ceiling on how many tool calls one turn may produce.
    public var maximumToolCalls: Int

    public init(
        temperature: Double? = nil,
        maximumOutputTokens: Int? = nil,
        maximumToolCalls: Int = 8
    ) {
        self.temperature = temperature
        self.maximumOutputTokens = maximumOutputTokens
        self.maximumToolCalls = maximumToolCalls
    }
}

/// Everything a provider needs for one turn.
///
/// Note what is *not* here: no repositories, no platform services, no app
/// state. Providers are given a rendered view of context and nothing else.
public struct AIRequest: Hashable, Codable, Sendable {
    public var model: AIModelIdentifier?
    public var systemPrompt: String
    public var messages: [AIMessage]
    public var tools: [AIToolSchema]
    public var options: AIGenerationOptions

    public init(
        model: AIModelIdentifier? = nil,
        systemPrompt: String,
        messages: [AIMessage],
        tools: [AIToolSchema] = [],
        options: AIGenerationOptions = AIGenerationOptions()
    ) {
        self.model = model
        self.systemPrompt = systemPrompt
        self.messages = messages
        self.tools = tools
        self.options = options
    }
}

public enum AIStopReason: String, Hashable, Codable, Sendable {
    case endTurn
    case toolCalls
    case maximumTokens
    case refusal
    case other
}

public struct AIUsage: Hashable, Codable, Sendable {
    public var inputTokens: Int?
    public var outputTokens: Int?

    public init(inputTokens: Int? = nil, outputTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

public struct AIResponse: Hashable, Codable, Sendable {
    /// What the assistant says to the user. Never parsed for behaviour.
    public var text: String
    /// Structured actions the model is asking for.
    public var toolCalls: [AIToolCall]
    public var stopReason: AIStopReason
    public var usage: AIUsage
    /// Which provider/model actually served this, for audit and debugging.
    public var providerID: AIProviderIdentifier
    public var modelID: AIModelIdentifier?

    public init(
        text: String,
        toolCalls: [AIToolCall] = [],
        stopReason: AIStopReason = .endTurn,
        usage: AIUsage = AIUsage(),
        providerID: AIProviderIdentifier,
        modelID: AIModelIdentifier? = nil
    ) {
        self.text = text
        self.toolCalls = toolCalls
        self.stopReason = stopReason
        self.usage = usage
        self.providerID = providerID
        self.modelID = modelID
    }
}
