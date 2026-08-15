import AssistantAI
import AssistantDomain
import Foundation

/// Provider backed by Apple's on-device Foundation Models framework.
///
/// **The implementation is not written.** It cannot be: the framework only
/// exists inside the Apple SDKs, so it needs Xcode and a device or simulator.
/// What exists here is the shape — identity, metadata, availability reporting —
/// so the rest of the application can already be wired against it, select it in
/// settings, and route around it while it reports itself unavailable.
///
/// TODO-XCODE: implement `respond(to:)` against `FoundationModels`
/// (`SystemLanguageModel`, `LanguageModelSession`, and the framework's guided
/// generation / tool calling APIs). The mapping work is:
///   - `AIRequest.systemPrompt` → session instructions
///   - `AIRequest.messages` → the session transcript
///   - `AIRequest.tools` → framework tool definitions built from `JSONSchema`
///   - framework tool invocations → `AIToolCall` with JSON arguments
/// Deployment target and availability annotations must be raised at that point.
public struct AppleFoundationModelsProvider: AIProvider {
    public static let providerID: AIProviderIdentifier = "apple.foundation-models"

    public let metadata: AIProviderMetadata

    public init() {
        self.metadata = AIProviderMetadata(
            id: Self.providerID,
            displayName: "Apple Foundation Models",
            kind: .appleFoundationModels,
            requiresNetwork: false,
            requiresCredentials: false,
            capabilityRank: 60
        )
    }

    public func availability() async -> AIProviderAvailability {
        #if canImport(FoundationModels)
        // TODO-XCODE: ask `SystemLanguageModel.default.availability` here and
        // translate its cases (device not eligible, model not downloaded,
        // Apple Intelligence disabled) into a reason string.
        return .unsupported(reason: "Apple Foundation Models integration is not implemented yet.")
        #else
        return .unsupported(
            reason: "Apple Foundation Models is only available in an Apple SDK build."
        )
        #endif
    }

    public func availableModels() async throws -> [AIModel] {
        // The framework exposes a single system model rather than a list. It is
        // declared here so provider/model selection UI has something real to
        // show, but nothing can be run against it yet.
        [
            AIModel(
                id: "apple.system-language-model",
                displayName: "On-device system model",
                contextWindow: nil,
                supportsNativeToolCalling: true,
                isOnDevice: true
            )
        ]
    }

    public func respond(to request: AIRequest) async throws -> AIResponse {
        // Deliberately fails rather than returning fabricated output. Nothing in
        // the app should ever look like it worked when it did not.
        throw AIProviderError.notImplemented(
            "Apple Foundation Models requires Xcode and an Apple SDK. TODO-XCODE."
        )
    }
}
