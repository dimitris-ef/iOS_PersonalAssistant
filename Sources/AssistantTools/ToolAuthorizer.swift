import AssistantDomain
import Foundation

/// Decides whether a proposed action may run.
///
/// Separated from both the decoder and the executor so authorization policy can
/// grow (per-tool rules, time-of-day rules, "never delete anything") without
/// touching either.
public protocol ToolAuthorizing: Sendable {
    func authorization(for request: ToolRequest, settings: AssistantSettings) -> ToolAuthorization
}

/// The default policy: read-only tools always run, everything else follows
/// whatever the user configured in settings.
public struct SettingsToolAuthorizer: ToolAuthorizing {
    public init() {}

    public func authorization(
        for request: ToolRequest,
        settings: AssistantSettings
    ) -> ToolAuthorization {
        if request.kind.isReadOnly { return .allowed }
        return settings.authorization(for: request.kind)
    }
}
