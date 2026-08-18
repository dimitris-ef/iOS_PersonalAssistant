import AssistantAI
import Foundation

/// Failures raised by the Apple provider itself, before or around the model.
///
/// Separate from Apple's own errors: these are conditions this integration
/// detects, and each maps to an `AIProviderError` the rest of the app already
/// understands.
public enum AppleFoundationModelsError: Error, Hashable, Sendable {
    /// The model reported itself unusable when a request arrived.
    case modelUnavailable(reason: String)
    /// Tool arguments came back as something that is not representable JSON.
    case unreadableToolArguments
    /// The model asked for a tool this build does not expose.
    ///
    /// Should be unreachable — the framework only offers the model the tools it
    /// was given — which is exactly why it is an error and not a silent skip.
    case unknownTool(String)

    /// The provider-neutral form. The UI never sees an Apple type.
    public var providerError: AIProviderError {
        switch self {
        case .modelUnavailable(let reason):
            return .unavailable(reason)
        case .unreadableToolArguments:
            return .invalidResponse("The on-device model returned arguments the app could not read.")
        case .unknownTool(let name):
            return .invalidResponse("The on-device model asked for an unknown tool '\(name)'.")
        }
    }
}

#if canImport(FoundationModels)

import FoundationModels

/// Turns a Foundation Models failure into the application's vocabulary.
///
/// Two rules shape this mapping:
///
/// - **Nothing raw reaches the user.** Apple's errors carry `Context` objects
///   with prompt excerpts and internal detail. A refusal context in particular
///   can quote what the person just typed. Only the short strings written here
///   are ever surfaced.
/// - **A refusal is an answer, not a crash.** The model declining is a normal
///   outcome of asking a safety-filtered model something, and the app shows it
///   as a message rather than an error state.
@available(iOS 26.0, macOS 26.0, *)
enum AppleFoundationModelsErrorMapper {

    /// The text to show when the model declines. Non-fatal by design.
    static let refusalText =
        "I can't help with that one. Apple's on-device model declined the request."

    /// True when the failure means "the model said no", which the provider
    /// turns into a normal reply carrying `.refusal`.
    static func isRefusal(_ error: any Error) -> Bool {
        guard let generation = error as? LanguageModelSession.GenerationError else { return false }
        switch generation {
        case .guardrailViolation, .refusal:
            return true
        default:
            return false
        }
    }

    static func providerError(for error: any Error) -> AIProviderError {
        if error is CancellationError {
            return .cancelled
        }

        if let apple = error as? AppleFoundationModelsError {
            return apple.providerError
        }

        if let toolCall = error as? LanguageModelSession.ToolCallError {
            // The underlying error is one of ours — the adapters only ever
            // throw `AppleFoundationModelsError` — but unwrap defensively
            // rather than assume.
            if let apple = toolCall.underlyingError as? AppleFoundationModelsError {
                return apple.providerError
            }
            return .invalidResponse(
                "The on-device model's request to use '\(toolCall.tool.name)' could not be read."
            )
        }

        guard let generation = error as? LanguageModelSession.GenerationError else {
            // Deliberately vague. An unrecognised error's description can
            // contain anything, including prompt text.
            return .transport("The on-device model could not complete the request.")
        }

        switch generation {
        case .exceededContextWindowSize:
            return .invalidResponse(
                "That conversation is too long for the on-device model. Starting a new one will help."
            )
        case .assetsUnavailable:
            return .unavailable(
                "The on-device model's files aren't available. They may still be downloading."
            )
        case .rateLimited:
            return .unavailable("The on-device model is busy. Try again in a moment.")
        case .concurrentRequests:
            return .unavailable("The on-device model is already answering something else.")
        case .unsupportedLanguageOrLocale:
            return .unavailable("The on-device model doesn't support this language yet.")
        case .decodingFailure:
            return .invalidResponse("The on-device model's reply could not be read.")
        case .unsupportedGuide:
            // A schema this build generated that the framework rejected. A bug
            // here, not something the user did.
            return .invalidResponse("A tool definition wasn't accepted by the on-device model.")
        case .guardrailViolation, .refusal:
            // Callers check `isRefusal` first; reaching here means a refusal
            // arrived somewhere that cannot present it as a reply.
            return .invalidResponse(refusalText)
        @unknown default:
            return .transport("The on-device model could not complete the request.")
        }
    }
}

#endif
