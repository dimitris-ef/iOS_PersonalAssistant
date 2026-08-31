import Foundation
import NativeModelKit

/// What normal inference asks for, before anybody overrides anything.
///
/// ## Why this type exists at all
///
/// Section 29. Production behaviour and diagnostic handicaps had become the
/// same object: the only description of "how inference is configured" was
/// ``LocalInferenceDiagnosticOverrides``, whose whole purpose is to make
/// inference slower on purpose. Nothing said what the app wanted when nobody
/// was investigating anything, so "no opinion" and "CPU-only for a crash hunt"
/// were represented by the same absence.
///
/// The composition is now explicit and one-directional:
///
/// ```
/// LocalInferenceProductionPolicy     ← what the app wants
///   ↓ apply diagnostic overrides     ← what an investigator asked for
/// LocalInferenceConfiguration        ← what the runtime is given
/// ```
///
/// A diagnostic override can only ever take capability *away*. It cannot turn
/// the GPU on, because production already asked for it.
public struct LocalInferenceProductionPolicy: Hashable, Sendable {

    /// Whether normal inference should ask for Metal offload.
    ///
    /// True, unconditionally, and this is the point of the whole type. Section
    /// 22 and 24: a user who has never opened Advanced Diagnostics gets GPU
    /// acceleration, and the absence of a setting is never read as a request
    /// for CPU-only.
    public var requestsGPUOffload: Bool

    public init(requestsGPUOffload: Bool = true) {
        self.requestsGPUOffload = requestsGPUOffload
    }

    /// What every device gets unless somebody deliberately says otherwise.
    public static let production = LocalInferenceProductionPolicy()

    /// The final answer for one load: production, then overrides.
    ///
    /// Section 23: `forceCPUOnly` still wins, because an investigator turning
    /// the GPU off has to be able to rely on it being off.
    public func wantsGPUOffload(with overrides: LocalInferenceDiagnosticOverrides) -> Bool {
        guard requestsGPUOffload else { return false }
        return overrides.wantsGPUOffload
    }

    /// Whether this load is running the product's own configuration.
    ///
    /// Drives the "Inference profile: Production / Diagnostic override" row
    /// (section 45), which exists so that a phone left in CPU-only mode after
    /// an investigation says so on the screen somebody looks at when they ask
    /// why it is slow.
    public func isProductionProfile(with overrides: LocalInferenceDiagnosticOverrides) -> Bool {
        requestsGPUOffload && !overrides.isActive
    }
}

/// The version of the diagnostic settings a build wrote.
///
/// ## The problem this solves
///
/// Section 25. During the crash investigation the advice was to turn CPU-only
/// on, disable GPU offload, and force conservative batches and low threads —
/// and testers did. Those choices are still on their phones. They were correct
/// for finding a crash in `llama_decode` and they are wrong for using the app,
/// and nothing would ever have turned them off: the app cannot tell "I chose
/// this" from "I chose this three builds ago for a reason that no longer
/// applies".
///
/// So the settings carry a version. A blob written before performance was
/// restored is treated as investigation residue and reset once; a blob written
/// after it is a current, deliberate choice and is left alone (section 59).
public enum LocalInferenceSettingsVersion {
    /// Written by builds up to and including the crash investigation. Anything
    /// at this version predates the restoration of production defaults.
    public static let crashInvestigation = 1
    /// Written by this build and later. Overrides at this version are current
    /// deliberate choices.
    public static let productionRestored = 2

    public static let current = productionRestored
}

/// Decides whether persisted overrides are a current choice or old residue.
///
/// Section 27 asks for the distinction to be recovered where possible and for a
/// one-time migration where it is not. The version is exactly that recovery:
/// it is written whenever a person changes a setting, so its presence at the
/// current value *is* the evidence that somebody chose these values with this
/// build's behaviour in front of them.
public enum LocalInferenceSettingsMigration {

    /// What a migration decided, so it can be logged and tested.
    public struct Outcome: Hashable, Sendable {
        public var overrides: LocalInferenceDiagnosticOverrides
        public var didReset: Bool
        public var fromVersion: Int

        public init(
            overrides: LocalInferenceDiagnosticOverrides,
            didReset: Bool,
            fromVersion: Int
        ) {
            self.overrides = overrides
            self.didReset = didReset
            self.fromVersion = fromVersion
        }
    }

    /// Migrates one stored blob.
    ///
    /// Only the performance axes are reset (section 27). Verbose logging is not
    /// touched: it costs nothing at production speed, somebody who turned it on
    /// probably still wants it, and quietly turning it off would remove the
    /// evidence trail from under an investigation that is still running.
    public static func migrate(
        _ stored: LocalInferenceDiagnosticOverrides,
        storedVersion: Int
    ) -> Outcome {
        guard storedVersion < LocalInferenceSettingsVersion.current else {
            // Section 59: written by this build or later. A deliberate,
            // informed choice, and resetting it on every launch would make the
            // switch unusable.
            return Outcome(overrides: stored, didReset: false, fromVersion: storedVersion)
        }
        guard stored.isActive else {
            // Nothing to undo. Still counts as migrated, so this does not run
            // again on every launch.
            return Outcome(overrides: stored, didReset: false, fromVersion: storedVersion)
        }
        return Outcome(overrides: .none, didReset: true, fromVersion: storedVersion)
    }
}
