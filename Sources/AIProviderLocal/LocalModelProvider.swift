import AssistantAI
import AssistantDomain
import Foundation

/// Provider for a model the user downloaded onto the device.
///
/// Fully implemented *except* for inference itself, which is delegated to a
/// ``LocalModelRuntime``. Until a runtime is chosen and registered, the provider
/// reports itself unavailable and refuses to generate — it never pretends.
public struct LocalModelProvider: AIProvider {
    public static let providerID: AIProviderIdentifier = "local.downloaded-model"

    public let metadata: AIProviderMetadata
    private let catalog: LocalModelCatalog
    private let runtime: (any LocalModelRuntime)?
    private let defaultModelID: AIModelIdentifier?

    public init(
        catalog: LocalModelCatalog = LocalModelCatalog(),
        runtime: (any LocalModelRuntime)? = nil,
        defaultModelID: AIModelIdentifier? = nil
    ) {
        self.catalog = catalog
        self.runtime = runtime
        self.defaultModelID = defaultModelID
        self.metadata = AIProviderMetadata(
            id: Self.providerID,
            displayName: "Downloaded local model",
            kind: .downloadedLocalModel,
            requiresNetwork: false,
            requiresCredentials: false,
            capabilityRank: 40
        )
    }

    public func availability() async -> AIProviderAvailability {
        guard let runtime else {
            // TODO: choose an inference runtime. Deliberately unresolved — see
            // `LocalModelRuntime`.
            return .unavailable(reason: "No local inference runtime is configured.")
        }
        guard let model = await resolveModel() else {
            return .unavailable(reason: "No local model has been downloaded.")
        }
        switch await runtime.state(of: model) {
        case .ready:
            return .available
        case .notDownloaded:
            return .unavailable(reason: "\(model.displayName) is not downloaded.")
        case .downloading(let fraction):
            return .unavailable(
                reason: "\(model.displayName) is downloading (\(Int(fraction * 100))%)."
            )
        case .failed(let reason):
            return .unavailable(reason: reason)
        }
    }

    public func availableModels() async throws -> [AIModel] {
        await catalog.all().map { descriptor in
            AIModel(
                id: descriptor.id,
                displayName: descriptor.displayName,
                contextWindow: descriptor.contextWindow,
                supportsNativeToolCalling: descriptor.supportsNativeToolCalling,
                isOnDevice: true
            )
        }
    }

    public func respond(to request: AIRequest) async throws -> AIResponse {
        guard let runtime else {
            throw AIProviderError.notImplemented(
                "No local inference runtime has been chosen yet."
            )
        }
        let requested = request.model ?? defaultModelID
        guard let descriptor = await resolveModel(requested) else {
            throw AIProviderError.modelNotFound(requested ?? "unspecified")
        }
        try await runtime.load(descriptor)
        return try await runtime.generate(request, model: descriptor)
    }

    private func resolveModel(_ id: AIModelIdentifier? = nil) async -> LocalModelDescriptor? {
        if let id = id ?? defaultModelID, let descriptor = await catalog.descriptor(for: id) {
            return descriptor
        }
        return await catalog.all().first
    }
}
