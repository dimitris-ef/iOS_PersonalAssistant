import AssistantAI
import AssistantDomain
import Foundation

/// A provider that returns exactly what a test tells it to.
///
/// It also records the requests it received, which is how the provider-swap
/// tests prove that context is rebuilt from the app's own stores rather than
/// carried inside any provider.
final class StubAIProvider: AIProvider, @unchecked Sendable {
    let metadata: AIProviderMetadata
    private let responses: [AIResponse]
    private let lock = NSLock()
    private var callCount = 0
    private(set) var receivedRequests: [AIRequest] = []

    init(
        id: AIProviderIdentifier,
        kind: AIProviderKind = .development,
        capabilityRank: Int = 10,
        responses: [AIResponse]
    ) {
        self.metadata = AIProviderMetadata(
            id: id,
            displayName: "Stub \(id)",
            kind: kind,
            requiresNetwork: false,
            requiresCredentials: false,
            capabilityRank: capabilityRank
        )
        self.responses = responses
    }

    convenience init(
        id: AIProviderIdentifier = "test.stub",
        text: String = "Done.",
        toolCalls: [AIToolCall] = []
    ) {
        self.init(
            id: id,
            responses: [
                AIResponse(
                    text: text,
                    toolCalls: toolCalls,
                    stopReason: toolCalls.isEmpty ? .endTurn : .toolCalls,
                    providerID: id
                )
            ]
        )
    }

    func availability() async -> AIProviderAvailability { .available }

    func availableModels() async throws -> [AIModel] {
        [
            AIModel(
                id: AIModelIdentifier(metadata.id.rawValue),
                displayName: metadata.displayName,
                supportsNativeToolCalling: true,
                isOnDevice: true
            )
        ]
    }

    func respond(to request: AIRequest) async throws -> AIResponse {
        lock.lock()
        defer { lock.unlock() }
        receivedRequests.append(request)
        let index = min(callCount, responses.count - 1)
        callCount += 1
        return responses[index]
    }

    var lastSystemPrompt: String? {
        lock.lock()
        defer { lock.unlock() }
        return receivedRequests.last?.systemPrompt
    }
}

/// A provider that is registered but never usable, for routing tests.
struct UnavailableProvider: AIProvider {
    let metadata: AIProviderMetadata
    let reason: String

    init(id: AIProviderIdentifier, reason: String = "not implemented") {
        self.metadata = AIProviderMetadata(
            id: id,
            displayName: "Unavailable \(id)",
            kind: .appleFoundationModels,
            requiresNetwork: false,
            requiresCredentials: false,
            capabilityRank: 100
        )
        self.reason = reason
    }

    func availability() async -> AIProviderAvailability { .unavailable(reason: reason) }

    func availableModels() async throws -> [AIModel] { [] }

    func respond(to request: AIRequest) async throws -> AIResponse {
        throw AIProviderError.notImplemented(reason)
    }
}

enum ToolCallFactory {
    static func make<Input: Encodable>(_ kind: ToolKind, _ input: Input) throws -> AIToolCall {
        AIToolCall(name: kind.rawValue, arguments: try JSONValue.encoding(input))
    }
}
