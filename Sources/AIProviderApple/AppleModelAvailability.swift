import AssistantAI
import Foundation

/// Why the on-device model can or cannot be used right now.
///
/// Deliberately declared without importing FoundationModels. Two reasons:
///
/// 1. **It is testable.** Apple's `SystemLanguageModel.Availability` cannot be
///    constructed by a test — it reflects real hardware, a real OS and whether
///    a real person has switched Apple Intelligence on. Translating through a
///    plain enum means the mapping that decides what the user is told can be
///    exercised in CI, on a machine that has none of those things.
/// 2. **It compiles everywhere.** The core package builds on Windows and Linux,
///    where the framework does not exist at all.
///
/// The framework's own enum is converted into this one in a single place, and
/// nothing outside this file ever sees an Apple type.
public enum AppleModelAvailabilityState: Hashable, Sendable {
    /// Apple Intelligence is on, the hardware qualifies, the assets are here.
    case ready

    /// This hardware cannot run Apple Intelligence. Not fixable by the user.
    case deviceNotEligible

    /// The device could, but Apple Intelligence is switched off. The one
    /// unavailable state the user can actually resolve.
    case appleIntelligenceNotEnabled

    /// Enabled, but the model assets are not on the device yet — usually still
    /// downloading. Worth trying again later.
    case modelNotReady

    /// A reason this build does not know about.
    ///
    /// Apple's reason enum is not frozen, so a future OS can add cases. Failing
    /// closed with an honest "cannot use it" beats crashing, and beats
    /// pretending the model is ready.
    case unrecognised(String)

    /// Built against an SDK with no FoundationModels framework.
    case frameworkMissingFromSDK

    /// The framework exists in the SDK, but this device is running an OS
    /// released before it.
    case operatingSystemTooOld

    /// The same fact in the application's provider-neutral vocabulary.
    ///
    /// The distinction that matters to the UI is not "why" in Apple's terms but
    /// "can the person do anything about it": only
    /// ``appleIntelligenceNotEnabled`` is actionable, and only it maps to
    /// `.configurationRequired`. Note what none of these say — nothing here
    /// mentions an API key, because the on-device model has never needed one.
    public var providerAvailability: AIProviderAvailability {
        switch self {
        case .ready:
            return .available

        case .appleIntelligenceNotEnabled:
            return .configurationRequired(
                reason: "Turn on Apple Intelligence in the Settings app to use the on-device model."
            )

        case .modelNotReady:
            return .temporarilyUnavailable(
                reason: "The on-device model is still downloading. This usually finishes on its own."
            )

        case .deviceNotEligible:
            return .unsupported(
                reason: "This device doesn't support Apple Intelligence."
            )

        case .operatingSystemTooOld:
            return .unsupported(
                reason: "Apple Intelligence needs a newer version of iOS than this device is running."
            )

        case .frameworkMissingFromSDK:
            return .unsupported(
                reason: "This build of the app was made without Apple Intelligence support."
            )

        case .unrecognised:
            // The raw reason is deliberately not shown. It is an Apple
            // implementation detail that would mean nothing to the reader, and
            // a case this build has never heard of is not one it can explain.
            return .unsupported(
                reason: "Apple Intelligence isn't available on this device right now."
            )
        }
    }

    /// A short, non-sensitive token for development logging.
    ///
    /// Never contains anything the user typed, remembered or was told.
    public var diagnosticName: String {
        switch self {
        case .ready: return "ready"
        case .deviceNotEligible: return "deviceNotEligible"
        case .appleIntelligenceNotEnabled: return "appleIntelligenceNotEnabled"
        case .modelNotReady: return "modelNotReady"
        case .unrecognised(let raw): return "unrecognised(\(raw))"
        case .frameworkMissingFromSDK: return "frameworkMissingFromSDK"
        case .operatingSystemTooOld: return "operatingSystemTooOld"
        }
    }
}

/// Reads the current state of the on-device model.
///
/// A protocol so the provider can be handed a fixed state in a test. The
/// production reader is ``SystemLanguageModelAvailabilityReader``, which asks
/// the framework — see the note there about why nothing else may.
public protocol AppleModelAvailabilityReading: Sendable {
    func currentState() -> AppleModelAvailabilityState
}

/// The only place in the application that asks Apple whether the model is
/// usable.
///
/// Both guards are load-bearing and neither is redundant:
///
/// - `#if canImport` covers the *SDK*: on Linux, on Windows, and in an Xcode
///   whose SDK predates the framework, this file must still compile.
/// - `#available` covers the *device*: the app deploys to iOS 17, so a real
///   phone running an older OS will execute this code with no framework loaded.
///
/// Getting only one of them right produces a build that either will not compile
/// or will not launch.
public struct SystemLanguageModelAvailabilityReader: AppleModelAvailabilityReading {
    public init() {}

    public func currentState() -> AppleModelAvailabilityState {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            return AppleModelAvailabilityState(SystemLanguageModel.default.availability)
        } else {
            return .operatingSystemTooOld
        }
        #else
        return .frameworkMissingFromSDK
        #endif
    }
}

/// A reader that reports whatever it was given.
///
/// For tests and for previews. Production code never constructs one — the
/// provider defaults to the real reader.
public struct FixedAppleModelAvailabilityReader: AppleModelAvailabilityReading {
    private let state: AppleModelAvailabilityState

    public init(_ state: AppleModelAvailabilityState) {
        self.state = state
    }

    public func currentState() -> AppleModelAvailabilityState { state }
}

#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, macOS 26.0, *)
extension AppleModelAvailabilityState {
    /// Translates Apple's answer into ours.
    ///
    /// `Availability` is frozen, so the two cases below are the whole set and
    /// an `@unknown default` would be dead code. `UnavailableReason` is *not*
    /// frozen, which is why that inner switch has one.
    init(_ availability: SystemLanguageModel.Availability) {
        switch availability {
        case .available:
            self = .ready
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                self = .deviceNotEligible
            case .appleIntelligenceNotEnabled:
                self = .appleIntelligenceNotEnabled
            case .modelNotReady:
                self = .modelNotReady
            @unknown default:
                self = .unrecognised(String(describing: reason))
            }
        }
    }
}
#endif
