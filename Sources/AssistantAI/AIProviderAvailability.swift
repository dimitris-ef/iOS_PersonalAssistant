import AssistantDomain
import Foundation

/// Whether a provider can serve a request, and if not, why.
///
/// The cases are deliberately coarse and provider-neutral. UI branches on the
/// case, never on the reason string — the reason is for the person reading the
/// screen, not for the code deciding what to draw.
public enum AIProviderAvailability: Hashable, Sendable {
    /// Ready to answer.
    case available

    /// Everything needed to run it exists, but the user has not supplied it —
    /// an endpoint, a credential, a model name, a downloaded file. Actionable:
    /// the UI should offer a way to fix it.
    case configurationRequired(reason: String)

    /// Configured and implemented, but not usable right now — offline, rate
    /// limited, a model still downloading. Worth retrying later.
    case temporarilyUnavailable(reason: String)

    /// Cannot work on this build at all: the integration is unimplemented, or
    /// the device/OS does not support it. Not actionable by the user.
    case unsupported(reason: String)

    public var isAvailable: Bool {
        self == .available
    }

    /// The explanation to show, when there is one.
    public var reason: String? {
        switch self {
        case .available:
            return nil
        case .configurationRequired(let reason),
             .temporarilyUnavailable(let reason),
             .unsupported(let reason):
            return reason
        }
    }

    /// True when the user can do something about it.
    public var isUserResolvable: Bool {
        if case .configurationRequired = self { return true }
        return false
    }
}
