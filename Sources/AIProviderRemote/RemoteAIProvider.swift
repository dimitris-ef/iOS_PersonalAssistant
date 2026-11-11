import AssistantAI
import AssistantDomain
import Foundation

/// Provider for models reached over the network.
///
/// The provider is vendor-neutral. Everything specific to one API lives in the
/// injected ``RemoteAPIAdapter``, everything specific to transport in the
/// injected ``HTTPTransport``, the endpoint and model in a
/// ``RemoteAIConfigurationSource``, and the secret in a ``CredentialProvider``.
/// Swapping any of those is a composition change; none of them is visible to
/// `AssistantEngine`, the tool system or the UI.
public struct RemoteAIProvider: AIProvider {
    public let metadata: AIProviderMetadata

    private let adapter: any RemoteAPIAdapter
    private let transport: any HTTPTransport
    private let credentials: any CredentialProvider
    private let configurationSource: any RemoteAIConfigurationSource
    private let logger: any RemoteAILogging
    /// Settings that worked, per host and model, so a refusal is paid for on
    /// the first message rather than on every one.
    private let learnedStyles = RemoteRequestStyleMemory()

    public init(
        adapter: any RemoteAPIAdapter = OpenAICompatibleAdapter(),
        configuration: any RemoteAIConfigurationSource,
        credentials: any CredentialProvider,
        transport: any HTTPTransport = URLSessionHTTPTransport(),
        logger: any RemoteAILogging = SilentRemoteAILogger()
    ) {
        self.adapter = adapter
        self.configurationSource = configuration
        self.credentials = credentials
        self.transport = transport
        self.logger = logger
        self.metadata = AIProviderMetadata(
            id: adapter.providerID,
            displayName: adapter.displayName,
            kind: .remoteAPI,
            requiresNetwork: true,
            requiresCredentials: true,
            capabilityRank: adapter.capabilityRank,
            // The protocol carries tool results back, so the engine may show
            // this provider what its actions did and ask for a final reply.
            supportsToolResultContinuation: true
        )
    }

    // MARK: Availability

    /// Reports readiness from configuration alone.
    ///
    /// Deliberately does not probe the network: this runs before every turn and
    /// must stay cheap, and "is the service up" is not something to answer
    /// speculatively. A service that is configured but unreachable surfaces as
    /// an error on the turn that needs it.
    public func availability() async -> AIProviderAvailability {
        let configuration = await configurationSource.configuration()
        let credential = await credentials.credential(for: adapter.providerID)
        let missing = configuration.missingRequirements(
            hasCredential: credential?.isEmpty == false
        )

        guard missing.isEmpty else {
            return .configurationRequired(
                reason: RemoteAIError.notConfigured(missing: missing).userFacingDescription
            )
        }
        return .available
    }

    public func availableModels() async throws -> [AIModel] {
        let configuration = await configurationSource.configuration()
        return try await adapter.availableModels(configuration: configuration)
    }

    // MARK: Turn

    public func respond(to request: AIRequest) async throws -> AIResponse {
        let configuration = await configurationSource.configuration()
        let credential = await credentials.credential(for: adapter.providerID)

        let missing = configuration.missingRequirements(hasCredential: credential?.isEmpty == false)
        guard missing.isEmpty, let credential else {
            let error = RemoteAIError.notConfigured(missing: missing)
            logger.log(.failed(category: error.category, status: nil))
            throw error.asProviderError
        }

        // Starts from the host's best guess and, if the service refuses a
        // setting by name, changes that setting and asks again — at most
        // twice. See `RemoteRequestStyle`.
        let host = RemoteAIEndpoint(baseURL: configuration.baseURL)?.host ?? ""
        let styleKey = "\(host)|\(request.model?.rawValue ?? configuration.model)"
        var style = await learnedStyles.style(for: styleKey) ?? .initial(forHost: host)
        var adjustments = 0

        while true {
            let httpRequest: HTTPRequest
            do {
                httpRequest = try adapter.makeRequest(
                    from: request,
                    configuration: configuration,
                    credential: credential,
                    style: style
                )
            } catch let error as RemoteAIError {
                logger.log(.failed(category: error.category, status: nil))
                throw error.asProviderError
            }

            logger.log(
                .requestStarted(
                    host: httpRequest.url.host ?? "?",
                    model: request.model?.rawValue ?? configuration.model,
                    toolCount: request.tools.count
                )
            )

            let started = Date()
            let httpResponse: HTTPResponse
            do {
                httpResponse = try await transport.send(httpRequest)
            } catch {
                let mapped = RemoteAIError.from(transport: error)
                logger.log(.failed(category: mapped.category, status: nil))
                throw mapped.asProviderError
            }

            // Honours cancellation between the network returning and parsing,
            // so an abandoned turn does not do pointless work.
            try Task.checkCancellation()

            guard httpResponse.isSuccess else {
                let apiError = OpenAICompatibleErrorBody.parse(httpResponse.body)
                if httpResponse.statusCode == 400, adjustments < 2,
                    let next = style.adjusted(afterRejection: apiError?.message)
                {
                    style = next
                    adjustments += 1
                    continue
                }
                let mapped = RemoteAIError.from(
                    status: httpResponse.statusCode,
                    apiError: apiError,
                    retryAfter: Self.retryAfter(from: httpResponse)
                )
                logger.log(.failed(category: mapped.category, status: httpResponse.statusCode))
                throw mapped.asProviderError
            }

            do {
                let response = try adapter.parse(httpResponse, for: request)
                if adjustments > 0 { await learnedStyles.remember(style, for: styleKey) }
                logger.log(
                    .responseReceived(
                        status: httpResponse.statusCode,
                        duration: Date().timeIntervalSince(started),
                        toolNames: response.toolCalls.map(\.name)
                    )
                )
                return response
            } catch let error as RemoteAIError {
                logger.log(.failed(category: error.category, status: httpResponse.statusCode))
                throw error.asProviderError
            }
        }
    }

    private static func retryAfter(from response: HTTPResponse) -> TimeInterval? {
        guard let value = response.header("Retry-After") else { return nil }
        return TimeInterval(value.trimmingCharacters(in: .whitespaces))
    }
}

/// What `RemoteAIProvider` has learned about each host and model this run.
///
/// In memory only: a new app version or a changed model starts from the
/// host's best guess again, which costs one refused request at most.
actor RemoteRequestStyleMemory {
    private var styles: [String: RemoteRequestStyle] = [:]

    func style(for key: String) -> RemoteRequestStyle? { styles[key] }

    func remember(_ style: RemoteRequestStyle, for key: String) { styles[key] = style }
}
