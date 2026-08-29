import Foundation

/// The on-device model's readiness, in the vocabulary the status screen speaks.
///
/// ## Why a third representation
///
/// There are now three, and each earns its place:
///
/// * `AppleModelAvailabilityState` — what Apple said, plus the two conditions
///   Apple cannot report because they are decided before the framework is
///   reached (no framework in the SDK, an OS that predates it).
/// * `AIProviderAvailability` — the provider-neutral vocabulary the model
///   selector uses to describe a cloud endpoint and an on-device model in the
///   same list.
/// * This — what a person waiting for a download needs to read.
///
/// The distinction that matters here and nowhere else is **is this worth
/// waiting for**. `modelPreparing` is the one state that resolves itself, and
/// it is the only one this app polls on. Everything else is a fact about the
/// device or the build, and re-asking every ten seconds would be pointless
/// battery use.
///
/// ## What it will not do
///
/// Apple exposes availability and nothing else — no byte count, no percentage,
/// no rate, no estimate. So neither does this. A progress bar here would be an
/// invention, and an invented progress bar that stalls at 60% is worse than an
/// honest spinner, because the person watching it concludes the app is broken
/// rather than that iOS is still working.
public enum AppleModelStatus: Equatable, Sendable {
    /// Apple Intelligence is on, the hardware qualifies, the assets are here.
    case ready

    /// The device could run it; Apple Intelligence is switched off. The one
    /// state the person can resolve themselves.
    case appleIntelligenceDisabled

    /// This hardware cannot run Apple Intelligence.
    case deviceNotEligible

    /// iOS is fetching or preparing the model. Transient, and the only state
    /// worth re-checking on a timer.
    case modelPreparing

    /// Unavailable for a reason this build cannot explain — a future Apple
    /// case, an OS older than the framework, or a build compiled without it.
    /// The raw token is carried so the screen can still name it.
    case unknownUnavailable(reason: String)

    /// Reading the availability failed inside this app's own code.
    ///
    /// Deliberately its own case. Section: an integration error must never be
    /// dressed up as `modelNotReady` — one means "wait, iOS is working on it"
    /// and the other means "MetisAI has a bug", and telling a tester to wait
    /// for a download that was never happening wastes their afternoon.
    case checkFailed(String)

    /// Built from what the availability reader reported.
    public init(_ state: AppleModelAvailabilityState) {
        switch state {
        case .ready:
            self = .ready
        case .appleIntelligenceNotEnabled:
            self = .appleIntelligenceDisabled
        case .deviceNotEligible:
            self = .deviceNotEligible
        case .modelNotReady:
            self = .modelPreparing
        // Neither of these comes from Apple's enum — both are decided before
        // the framework is asked — so neither is `deviceNotEligible`, which
        // means the hardware. The token says which it really is.
        case .operatingSystemTooOld, .frameworkMissingFromSDK, .unrecognised:
            self = .unknownUnavailable(reason: state.reasonToken)
        }
    }

    /// The heading, exactly as the brief specifies it.
    public var title: String {
        switch self {
        case .ready:
            return "Ready"
        case .appleIntelligenceDisabled:
            return "Apple Intelligence disabled"
        case .deviceNotEligible:
            return "Device not eligible"
        case .modelPreparing:
            return "Preparing / downloading Apple on-device model"
        case .unknownUnavailable:
            return "Apple on-device model unavailable"
        case .checkFailed:
            return "Could not read the model status"
        }
    }

    /// The sentence underneath.
    public var detail: String {
        switch self {
        case .ready:
            return "Apple Foundation Models is available on this device."
        case .appleIntelligenceDisabled:
            return "Enable Apple Intelligence in iOS Settings before using Apple On-Device."
        case .deviceNotEligible:
            return "Apple Foundation Models is not available on this device."
        case .modelPreparing:
            // The second sentence is the important one. Saying plainly that the
            // numbers do not exist is what stops the absence of a progress bar
            // reading as a missing feature.
            return "iOS is preparing the Apple on-device model. Apple does not expose "
                + "exact download progress, download speed, remaining bytes, or an ETA."
        case .unknownUnavailable(let reason):
            return "Reason: \(reason)"
        case .checkFailed(let message):
            return "This is a problem in MetisAI rather than in iOS. \(message)"
        }
    }

    /// Whether to show an indeterminate spinner.
    ///
    /// True only while preparing. Indeterminate is the honest shape: something
    /// is happening and nobody can say how much of it is left.
    public var showsActivityIndicator: Bool {
        self == .modelPreparing
    }

    /// Whether re-asking on a timer could change the answer.
    ///
    /// Only `modelPreparing`. Ineligible hardware will not become eligible
    /// while the screen is open, and Apple Intelligence is switched on in iOS
    /// Settings — which means leaving the app, which the foreground refresh
    /// already covers.
    public var pollsAutomatically: Bool {
        self == .modelPreparing
    }

    public var isReady: Bool { self == .ready }

    /// A short token for logs and tests.
    public var token: String {
        switch self {
        case .ready: return "ready"
        case .appleIntelligenceDisabled: return "appleIntelligenceDisabled"
        case .deviceNotEligible: return "deviceNotEligible"
        case .modelPreparing: return "modelPreparing"
        case .unknownUnavailable: return "unknownUnavailable"
        case .checkFailed: return "checkFailed"
        }
    }
}
