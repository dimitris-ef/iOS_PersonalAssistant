import AssistantAI
import AssistantDomain
import Foundation

/// Whether an installed model may be used to interpret actions.
public enum ActionModelCompatibility: Hashable, Sendable {
    /// Everything checked passed, and the architecture is one whose constrained
    /// output this app has reason to trust.
    case compatible
    /// Usable, with the honest label. Nothing disqualifying was found, but the
    /// evidence is weaker than a recognised family — which for a *constrained*
    /// extractor is a smaller risk than it would be for free generation, since
    /// the grammar decides the shape either way.
    case experimental
    case incompatible(reason: ActionModelIncompatibility)

    public var isUsable: Bool {
        switch self {
        case .compatible, .experimental: return true
        case .incompatible: return false
        }
    }

    /// For the log and the picker's grouping. A symbol, never a sentence.
    public var symbol: String {
        switch self {
        case .compatible: return "compatible"
        case .experimental: return "experimental"
        case .incompatible(let reason): return "incompatible.\(reason.rawValue)"
        }
    }

    /// What the settings screen shows.
    public var label: String {
        switch self {
        case .compatible: return "Compatible"
        case .experimental: return "Experimental"
        case .incompatible: return "Incompatible"
        }
    }
}

/// Why a model cannot interpret actions.
///
/// Section 51: each case is a sentence a person can act on, and none of them is
/// a native error. "Unsupported architecture" tells somebody to pick a
/// different model; `ggml_backend_metal_device_init failed` tells them nothing.
public enum ActionModelIncompatibility: String, Hashable, Sendable {
    /// The file is gone — deleted, or never finished installing.
    case modelMissing
    /// The header could not be read, or declared nothing usable.
    case invalidModelFile
    /// A family whose behaviour under a grammar this build cannot vouch for.
    case unsupportedArchitecture
    /// This build has no inference runtime at all.
    case runtimeUnavailable
    /// The runtime cannot constrain generation, so an action request could only
    /// be answered freely — which section 17 of Part 2 forbids outright.
    case structuredDecodingUnavailable

    public var message: String {
        switch self {
        case .modelMissing:
            return "The selected model is no longer installed."
        case .invalidModelFile:
            return "This model file could not be read."
        case .unsupportedArchitecture:
            return "This model's architecture is not supported for actions."
        case .runtimeUnavailable:
            return "This build has no local inference runtime."
        case .structuredDecodingUnavailable:
            return "This runtime cannot constrain output, which actions require."
        }
    }
}

/// Decides whether an installed model can do the action job.
///
/// ## What it checks, and the one thing it must not
///
/// Section 6 lists the checks: the file is really there, the header parsed,
/// the architecture is one this build supports, the runtime exists, and the
/// runtime can constrain generation.
///
/// Section 7 is the prohibition, and it is the one worth stating loudly:
/// **parameter count is not a criterion.** A 300M model is not disqualified for
/// being small, and a 7B one is not qualified for being large. What decides an
/// action model's fitness is whether it can follow a short instruction and emit
/// a structured object under a grammar — and under a grammar the *shape* is
/// guaranteed regardless, so size buys accuracy of interpretation, not
/// validity. `ActionModelCompatibilityTests` asserts that two records
/// identical but for their size resolve identically.
///
/// ## Why it is separate from `LocalModelCapabilityResolver`
///
/// That one answers "may this model be offered tools in a chat turn?" — a
/// question about free-form tool calling. This answers "may this model be asked
/// for a constrained semantic action?" They come apart in both directions: a
/// model too unreliable to hand nineteen tool schemas can be perfectly good at
/// filling two fields under a grammar, and that is much of the reason the
/// dedicated action path exists at all.
public enum ActionModelCompatibilityResolver {

    /// Architectures whose instruct tunes follow a short extraction instruction
    /// well enough to be called compatible rather than experimental.
    ///
    /// Broader than the chat-tools list on purpose: a grammar removes the
    /// failure mode that list is conservative about.
    public static let supportedFamilies: Set<String> = [
        "qwen2", "qwen3", "llama", "smollm", "smollm2", "smollm3",
        "gemma", "gemma2", "gemma3", "phi2", "phi3", "mistral", "stablelm",
    ]

    /// Families this build will not run under a grammar.
    ///
    /// Empty, and deliberately so: an unknown architecture is `experimental`,
    /// not `incompatible`. Refusing an architecture nobody has tried yet would
    /// make every new model release a reason to ship an app update, and the
    /// grammar already bounds what it can produce. The case exists for a family
    /// found to be genuinely broken.
    public static let refusedFamilies: Set<String> = []

    /// Resolves compatibility for one installed model.
    ///
    /// - Parameters:
    ///   - record: what was written at install, including the architecture read
    ///     from the file's own header.
    ///   - fileExists: whether the file is on disk *now*. Passed in rather than
    ///     checked here so this stays a pure function — the caller owns the
    ///     filesystem.
    ///   - runtime: what the inference runtime can do, or nil when this build
    ///     has none.
    public static func resolve(
        record: LocalModelRecord?,
        fileExists: Bool,
        runtime: LocalRuntimeCapabilities?
    ) -> ActionModelCompatibility {
        guard let runtime else { return .incompatible(reason: .runtimeUnavailable) }
        guard runtime.supportsConstrainedGeneration else {
            return .incompatible(reason: .structuredDecodingUnavailable)
        }
        guard let record else { return .incompatible(reason: .modelMissing) }
        guard fileExists else { return .incompatible(reason: .modelMissing) }
        guard let architecture = record.architecture?.lowercased(), !architecture.isEmpty else {
            // No architecture means the GGUF header never parsed. That is a
            // file problem, not a family problem, and saying so points at the
            // right fix (re-download) rather than the wrong one (pick another
            // model).
            return .incompatible(reason: .invalidModelFile)
        }
        if refusedFamilies.contains(where: { architecture.hasPrefix($0) }) {
            return .incompatible(reason: .unsupportedArchitecture)
        }
        if supportedFamilies.contains(where: { architecture.hasPrefix($0) }) {
            return .compatible
        }
        // Section 50: still selectable, in the honest group. The grammar bounds
        // what it can emit whatever family it is.
        return .experimental
    }
}
