import AssistantAI
import Foundation

/// Everything the app can truthfully say about the on-device model right now.
///
/// ## Why this exists
///
/// `AIProviderAvailability` is deliberately coarse — four cases, provider
/// neutral, with a human sentence attached. That is the right shape for a
/// settings list that has to describe a cloud endpoint, a downloaded GGUF file
/// and Apple Intelligence in the same vocabulary.
///
/// It is the wrong shape for debugging one of them. Four distinct Apple
/// conditions —
///
///   * this hardware cannot run Apple Intelligence,
///   * this OS predates the framework,
///   * this *build* has no framework in its SDK,
///   * Apple reported a reason released after this build,
///
/// — all arrive at the UI as `.unsupported(reason:)`, and `modelNotReady`
/// arrives as `.temporarilyUnavailable(reason:)`, which looks exactly like a
/// rate-limited cloud provider. Somebody holding a phone that says
/// "Apple On-Device — Unavailable" cannot tell which of six situations they are
/// in, and neither can anyone reading a bug report about it.
///
/// So this carries the whole picture, on demand, for one provider.
///
/// ## What it is not
///
/// Not a second source of truth. Every field is read through the same
/// `AppleModelAvailabilityReading` the provider uses for its real decisions —
/// there is no path where the diagnostic says one thing and `respond(to:)`
/// does another.
///
/// Not persisted. It describes this instant on this device; storing a history
/// of it in SwiftData would be device telemetry the app has no use for.
///
/// Not a leak. No identifiers, no serial numbers, no model names, no prompts,
/// no memories, no credentials. Every field below is either a Boolean, an OS
/// version string, a locale identifier, or a token from a fixed vocabulary.
public struct AppleFoundationModelsDiagnostic: Sendable, Equatable {

    /// When this snapshot was taken. Shown so a stale reading is obvious.
    public let capturedAt: Date

    /// Whether `#if canImport(FoundationModels)` was true when this binary was
    /// compiled.
    ///
    /// The single most valuable field here. If this is `false` in a TestFlight
    /// build, no amount of Apple Intelligence on the device will help — the
    /// integration is not in the binary at all, and every other field below is
    /// describing a code path that does not exist.
    public let frameworkCompiled: Bool

    /// Whether the OS this app is running on satisfies the `#available` guard
    /// the provider actually uses.
    ///
    /// Read from the same guard rather than re-stated, so the UI cannot claim a
    /// different threshold than the code enforces.
    public let runtimeSupported: Bool

    /// Which `AIProvider` implementation answered. Names the type, so a
    /// build that had somehow composed a mock is obvious rather than inferred.
    public let providerImplementation: String

    public let osName: String
    public let osVersion: String

    /// `SystemLanguageModel.default.isAvailable`, exposed for comparison only.
    ///
    /// Nil when the framework is absent or the OS is too old, because in those
    /// cases nothing was asked. The interesting reading is the *pair*:
    /// `isAvailable == false` alongside a specific reason is what tells you
    /// whether the model is missing, downloading, or switched off.
    public let systemModelIsAvailable: Bool?

    /// Apple's own description of the availability value, lightly trimmed.
    ///
    /// Kept verbatim rather than re-derived so that a future OS reporting a
    /// reason this build has never heard of still produces something a human
    /// can read and search for.
    public let rawAvailability: String

    /// A stable token from a fixed vocabulary: `available`,
    /// `appleIntelligenceNotEnabled`, `deviceNotEligible`, `modelNotReady`,
    /// `unknown`, `frameworkMissingFromSDK`, `operatingSystemTooOld`.
    public let reasonToken: String

    /// The app's own mapped state.
    public let state: AppleModelAvailabilityState

    /// What the provider reports upward. Included so the collapse this type
    /// exists to expose is visible *next to* the thing it collapsed.
    public let mappedAvailability: AIProviderAvailability

    public let currentLocaleIdentifier: String

    /// Whether the model claims to support the device's current language.
    ///
    /// Nil when it could not be asked. Deliberately separate from eligibility:
    /// an unsupported language is not `deviceNotEligible`, and conflating them
    /// would send someone to buy a phone they already own.
    public let currentLocaleSupported: Bool?

    /// How many languages the model reports. A count, not the list — the list
    /// is long, changes by OS version, and says nothing the count does not.
    public let supportedLanguageCount: Int?

    public init(
        capturedAt: Date,
        frameworkCompiled: Bool,
        runtimeSupported: Bool,
        providerImplementation: String,
        osName: String,
        osVersion: String,
        systemModelIsAvailable: Bool?,
        rawAvailability: String,
        reasonToken: String,
        state: AppleModelAvailabilityState,
        mappedAvailability: AIProviderAvailability,
        currentLocaleIdentifier: String,
        currentLocaleSupported: Bool?,
        supportedLanguageCount: Int?
    ) {
        self.capturedAt = capturedAt
        self.frameworkCompiled = frameworkCompiled
        self.runtimeSupported = runtimeSupported
        self.providerImplementation = providerImplementation
        self.osName = osName
        self.osVersion = osVersion
        self.systemModelIsAvailable = systemModelIsAvailable
        self.rawAvailability = rawAvailability
        self.reasonToken = reasonToken
        self.state = state
        self.mappedAvailability = mappedAvailability
        self.currentLocaleIdentifier = currentLocaleIdentifier
        self.currentLocaleSupported = currentLocaleSupported
        self.supportedLanguageCount = supportedLanguageCount
    }

    /// The same snapshot, attributed to the provider that produced it.
    ///
    /// The reader cannot know which `AIProvider` asked it; the provider cannot
    /// gather the framework state without the reader. This is the seam.
    public func namingProvider(_ implementation: String) -> AppleFoundationModelsDiagnostic {
        AppleFoundationModelsDiagnostic(
            capturedAt: capturedAt,
            frameworkCompiled: frameworkCompiled,
            runtimeSupported: runtimeSupported,
            providerImplementation: implementation,
            osName: osName,
            osVersion: osVersion,
            systemModelIsAvailable: systemModelIsAvailable,
            rawAvailability: rawAvailability,
            reasonToken: reasonToken,
            state: state,
            mappedAvailability: mappedAvailability,
            currentLocaleIdentifier: currentLocaleIdentifier,
            currentLocaleSupported: currentLocaleSupported,
            supportedLanguageCount: supportedLanguageCount
        )
    }

    /// A sentence for a person, rather than a token for a search.
    ///
    /// Both are shown. The token is what makes a bug report actionable; the
    /// sentence is what stops the screen being hostile to whoever is reading it.
    public var headline: String {
        switch state {
        case .ready:
            return "Apple Intelligence is on and the on-device model is ready."
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence is not enabled for Foundation Models."
        case .deviceNotEligible:
            return "This device is not eligible for Apple Intelligence Foundation Models."
        case .modelNotReady:
            return "The Foundation Models on-device model is not ready yet. "
                + "It may still be downloading."
        case .operatingSystemTooOld:
            return "This version of iOS does not include the Foundation Models framework. "
                + "Apple Intelligence features elsewhere on the device can still work."
        case .frameworkMissingFromSDK:
            return "This build of the app was compiled without the Foundation Models "
                + "framework, so the on-device model cannot be reached at all."
        case .unrecognised:
            return "Apple reported an availability reason this version of the app does "
                + "not recognise."
        }
    }

    /// A sanitized report, for pasting into a bug report or a message.
    ///
    /// Every line is one of the fields above. Nothing is added here that is not
    /// already on screen — a copy action that quietly gathered more than the
    /// page showed would be a surprise, and this one is offered precisely
    /// because troubleshooting a real device needs the whole set at once.
    public var report: String {
        var lines = [
            "MetisAI Apple Foundation Models Diagnostics",
            "Captured: \(Self.timestampFormatter.string(from: capturedAt))",
            "\(osName): \(osVersion)",
            "Framework compiled: \(frameworkCompiled)",
            "Runtime supported: \(runtimeSupported)",
            "Provider active: \(providerImplementation)",
            "isAvailable: \(systemModelIsAvailable.map(String.init) ?? "not read")",
            "availability: \(reasonToken)",
            "raw availability: \(rawAvailability)",
            "Mapped state: \(mappedAvailabilityToken)",
            "Locale: \(currentLocaleIdentifier)",
        ]
        if let currentLocaleSupported {
            lines.append("Locale supported: \(currentLocaleSupported)")
        }
        if let supportedLanguageCount {
            lines.append("Supported languages: \(supportedLanguageCount)")
        }
        return lines.joined(separator: "\n")
    }

    /// The provider-neutral case as a token, so the report shows both halves of
    /// the translation.
    public var mappedAvailabilityToken: String {
        switch mappedAvailability {
        case .available: return "available"
        case .configurationRequired: return "configurationRequired"
        case .temporarilyUnavailable: return "temporarilyUnavailable"
        case .unsupported: return "unsupported"
        }
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}

extension AppleModelAvailabilityState {
    /// A stable token from a fixed vocabulary.
    ///
    /// Distinct from ``diagnosticName``, which embeds the raw Apple string for
    /// an unrecognised case and is therefore unsuitable as a value anything
    /// compares against. Section 6 requires these exact spellings to survive to
    /// the UI, so they are defined once and asserted in tests.
    public var reasonToken: String {
        switch self {
        case .ready: return "available"
        case .appleIntelligenceNotEnabled: return "appleIntelligenceNotEnabled"
        case .deviceNotEligible: return "deviceNotEligible"
        case .modelNotReady: return "modelNotReady"
        case .unrecognised: return "unknown"
        case .frameworkMissingFromSDK: return "frameworkMissingFromSDK"
        case .operatingSystemTooOld: return "operatingSystemTooOld"
        }
    }
}
