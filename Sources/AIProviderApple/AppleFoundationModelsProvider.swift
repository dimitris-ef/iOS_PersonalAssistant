import AssistantAI
import AssistantDomain
import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Provider backed by Apple's on-device Foundation Models framework.
///
/// One more implementation of `AIProvider`, and nothing above it changed to
/// accommodate it: the engine, the context assembler, the memory ranking, the
/// tool catalogue and the repositories are all exactly as the remote provider
/// finds them. What this type does is translate, in both directions, between
/// the application's vocabulary and Apple's.
///
/// Two properties are worth stating plainly because they are the reasons
/// someone would choose this provider:
///
/// - **Nothing leaves the device.** There is no transport here, no endpoint and
///   no credential. If the on-device model cannot answer, the request fails —
///   it is never quietly sent to the cloud provider instead. Somebody who picks
///   this because they do not want their life sent to a server gets that.
/// - **It proposes; it does not act.** The model can ask for a tool, and the
///   framework will call into `AppleFoundationToolAdapter`, but that adapter
///   only records the request. Validation, authorization, confirmation and
///   execution stay in `AssistantEngine`, where they are for every provider.
///
/// TODO-DEVICE: none of the generation path below has ever executed. It
/// compiles against the iOS 26 SDK in CI, which is as far as a runner can go —
/// Apple Intelligence inference needs eligible hardware with the model
/// downloaded. What needs a real device: that a generation returns text at all,
/// which availability case a given phone reports, whether a guardrail refusal
/// arrives as `.refusal` or `.guardrailViolation`, and whether the framework
/// pairs a `Transcript.ToolCall` with its `ToolOutput` by the shared id this
/// code gives them. See `Docs/APPLE-ON-DEVICE.md`.
public struct AppleFoundationModelsProvider: AIProvider {
    /// Unchanged from when this was a stub. It is written into settings when
    /// the user picks this provider, so changing it would silently reset the
    /// choice of anyone who had already made it.
    public static let providerID: AIProviderIdentifier = "apple.foundation-models"

    /// The framework exposes one system model rather than a catalogue.
    public static let systemModelID: AIModelIdentifier = "apple.system-language-model"

    public let metadata: AIProviderMetadata

    private let availabilityReader: any AppleModelAvailabilityReading

    public init(availabilityReader: any AppleModelAvailabilityReading = SystemLanguageModelAvailabilityReader()) {
        self.availabilityReader = availabilityReader
        self.metadata = AIProviderMetadata(
            id: Self.providerID,
            // What the user sees. The framework's name is an implementation
            // detail; "on-device" is the thing they are choosing.
            displayName: "Apple On-Device",
            kind: .appleFoundationModels,
            requiresNetwork: false,
            requiresCredentials: false,
            capabilityRank: 60,
            // The framework runs tools during generation and keeps reasoning
            // afterwards, so it can be shown what the app actually did and
            // asked for a closing reply. That is the engine's existing
            // multi-round loop; this provider joins it rather than having one
            // of its own.
            supportsToolResultContinuation: true
        )
    }

    public func availability() async -> AIProviderAvailability {
        let state = availabilityReader.currentState()
        // Safe to log: a category name, never a prompt, a memory or a reply.
        AppleProviderLog.debug("availability: " + state.diagnosticName)
        return state.providerAvailability
    }

    public func availableModels() async throws -> [AIModel] {
        [
            AIModel(
                id: Self.systemModelID,
                displayName: "On-device system model",
                // Deliberately not reported. `SystemLanguageModel.contextSize`
                // exists, but reading it means touching the framework on a
                // device that may not have it, for a number nothing currently
                // uses. The engine bounds context by message count instead.
                contextWindow: nil,
                supportsNativeToolCalling: true,
                isOnDevice: true
            )
        ]
    }

    public func respond(to request: AIRequest) async throws -> AIResponse {
        // Checked before every request, not once at launch. Apple Intelligence
        // can be switched off, and the model's assets can be evicted, while the
        // app is running.
        let state = availabilityReader.currentState()
        guard state == .ready else {
            let availability = state.providerAvailability
            throw AppleFoundationModelsError
                .modelUnavailable(reason: availability.reason ?? "The on-device model is unavailable.")
                .providerError
        }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            return try await generate(request)
        } else {
            throw AppleFoundationModelsError
                .modelUnavailable(reason: AppleModelAvailabilityState.operatingSystemTooOld.providerAvailability.reason ?? "")
                .providerError
        }
        #else
        // Unreachable: the availability check above already returned
        // `.frameworkMissingFromSDK` on a build without the framework. Kept so
        // the function has a return on every path rather than relying on that.
        throw AppleFoundationModelsError
            .modelUnavailable(reason: AppleModelAvailabilityState.frameworkMissingFromSDK.providerAvailability.reason ?? "")
            .providerError
        #endif
    }
}

#if canImport(FoundationModels)

@available(iOS 26.0, macOS 26.0, *)
extension AppleFoundationModelsProvider {

    /// One round: build a session, ask, collect whatever tools were proposed.
    fileprivate func generate(_ request: AIRequest) async throws -> AIResponse {
        let collector = AppleFoundationToolCollector()
        let tools = AppleFoundationToolAdapter.adapters(for: request.tools, collector: collector)
        let definitions = tools.map { Transcript.ToolDefinition(tool: $0) }

        let prepared = try AppleFoundationSessionAdapter.prepare(request, toolDefinitions: definitions)

        let session = LanguageModelSession(
            model: .default,
            tools: tools,
            transcript: prepared.transcript
        )
        AppleProviderLog.debug("session created with \(tools.count) tools")

        do {
            let response = try await session.respond(to: prepared.prompt, options: prepared.options)
            // Drained *after* the response, by which point the framework has
            // finished calling tools for this generation.
            let proposed = await collector.drain()

            for call in proposed {
                // The tool name is from a fixed catalogue, so it is safe to
                // log. The arguments are not — they can carry anything the
                // person said.
                AppleProviderLog.debug("proposed tool: " + call.name)
            }

            return AIResponse(
                text: response.content,
                toolCalls: proposed,
                stopReason: proposed.isEmpty ? .endTurn : .toolCalls,
                // Token counts are reported by the framework in its own
                // structured form; the app has nowhere to show them and
                // guessing at a mapping would put made-up numbers in an audit
                // trail. Left empty rather than approximated.
                usage: AIUsage(),
                providerID: Self.providerID,
                modelID: Self.systemModelID
            )
        } catch {
            // A refusal is an answer. The model declining is a normal result of
            // asking a safety-filtered model something, and the person should
            // see a sentence rather than an error banner.
            if AppleFoundationModelsErrorMapper.isRefusal(error) {
                AppleProviderLog.debug("the model declined the request")
                return AIResponse(
                    text: AppleFoundationModelsErrorMapper.refusalText,
                    toolCalls: [],
                    stopReason: .refusal,
                    usage: AIUsage(),
                    providerID: Self.providerID,
                    modelID: Self.systemModelID
                )
            }

            // Anything the model asked for before failing is deliberately
            // dropped. A half-finished generation's proposals were never
            // reasoned through to a conclusion, and executing them would be
            // acting on an interrupted thought.
            _ = await collector.drain()

            let mapped = AppleFoundationModelsErrorMapper.providerError(for: error)
            // The mapped case only; Apple's own error descriptions can quote
            // the prompt, which is the user's own words.
            AppleProviderLog.error("generation failed: \(mapped)")
            throw mapped
        }
    }
}

#endif
