import AIProviderLocal
import Foundation

#if canImport(llama)
import llama
#endif

// A build that *intends* to link llama.cpp says so, and finds out here if it
// did not.
//
// Without this, the `#if canImport(llama)` guards that make this target
// compile everywhere would also make a broken integration compile silently:
// the binary target fails to resolve, every guarded branch disappears, the
// build goes green, and the app ships a runtime that reports itself
// unavailable on every device. The `Local model runtime` workflow passes
// `-DPPAI_REQUIRE_LLAMA`, which turns that into a build failure.
#if PPAI_REQUIRE_LLAMA && !canImport(llama)
#error("llama.cpp was expected but is not linked. Is PPAI_LLAMA_RUNTIME=1 set?")
#endif

/// Picks the inference runtime this build actually has.
///
/// The composition root calls this once and hands the result to
/// ``LocalModelManager``. Everything below sees only ``LocalModelRuntime``,
/// which is what section 4 asks for: adding MLX or ExecuTorch later means
/// another conformance and another branch here, and no change to
/// `AssistantEngine`, the tool pipeline, memory or the provider.
///
/// ## Why this returns a runtime rather than nil
///
/// Because "no runtime" and "a runtime that reports itself unavailable" are the
/// same thing to every caller, and only one of them needs an optional threaded
/// through the app. ``LlamaCppRuntime`` compiled without the binary answers
/// `unavailable` to every question and throws from `loadModel`; Settings shows
/// Local AI as unsupported with that reason, and nothing else changes.
public enum LocalRuntimeResolver {
    /// True when this build links a real inference engine.
    public static var hasNativeRuntime: Bool {
        #if canImport(llama)
        return true
        #else
        return false
        #endif
    }

    /// A one-line description for the debug screen and for bug reports.
    public static var runtimeDescription: String {
        #if canImport(llama)
        return "llama.cpp \(LlamaCppRuntime.pinnedVersion)"
        #else
        return "none (this build has no on-device inference runtime)"
        #endif
    }

    /// The runtime to use.
    ///
    /// Deliberately unconditional. There is no `#if DEBUG` here and there must
    /// never be one: a Release build that selected a stub on purpose is exactly
    /// the failure this file exists to make impossible, and it would look
    /// identical from the outside to a build whose binary target failed to
    /// resolve. `LlamaCppRuntime` decides for itself whether it has an engine.
    public static func best() -> any LocalModelRuntime {
        LlamaCppRuntime()
    }

    /// What this build actually has, for the settings screen and bug reports.
    ///
    /// ## Why this exists
    ///
    /// Every TestFlight build before this one reported "this build does not
    /// include the on-device inference runtime", and that message was *true* —
    /// the archive really had been built without llama.cpp, because the
    /// manifest flag that adds it was set in one CI workflow and not in the one
    /// that ships. Nothing in the app could say so, because from inside the app
    /// "no runtime linked" and "runtime linked but broken" are indistinguishable
    /// unless somebody writes down which is which.
    ///
    /// So this reports the compile-time fact separately from the runtime one.
    public static func diagnostic() async -> LocalRuntimeDiagnostic {
        let runtime = LlamaCppRuntime()
        let availability = await runtime.runtimeAvailability()
        return LocalRuntimeDiagnostic(
            isCompiledIn: hasNativeRuntime,
            implementation: hasNativeRuntime ? "llama.cpp" : "none",
            pinnedVersion: hasNativeRuntime ? LlamaCppRuntime.pinnedVersion : nil,
            platform: Self.platform,
            usesMetal: LlamaCppRuntime.hasMetal,
            availability: availability
        )
    }

    private static var platform: String {
        #if targetEnvironment(simulator)
        return "iOS Simulator"
        #elseif os(iOS)
        return "iPhone"
        #elseif os(macOS)
        return "Mac"
        #else
        return "other"
        #endif
    }
}

/// What the on-device inference runtime is, and whether it works.
///
/// Two separate questions, kept separate. "Not included in this build" is a
/// packaging mistake somebody has to fix in CI; "included but would not
/// initialize" is a bug on the device. Collapsing them into one warning is
/// what made the original problem take a round-trip through TestFlight to
/// diagnose.
public struct LocalRuntimeDiagnostic: Sendable, Equatable {
    /// Whether `#if canImport(llama)` was true when this binary was compiled.
    public let isCompiledIn: Bool
    /// `llama.cpp`, or `none`.
    public let implementation: String
    /// The pinned upstream build tag, when there is one.
    public let pinnedVersion: String?
    /// iPhone, iOS Simulator or Mac. The simulator has no llama slice, so a
    /// stub there is expected rather than a defect.
    public let platform: String
    /// Whether GPU offload is on. Metal is enabled for real device builds;
    /// `n_gpu_layers` follows this exact value.
    public let usesMetal: Bool
    public let availability: LocalRuntimeAvailability

    public init(
        isCompiledIn: Bool,
        implementation: String,
        pinnedVersion: String?,
        platform: String,
        usesMetal: Bool,
        availability: LocalRuntimeAvailability
    ) {
        self.isCompiledIn = isCompiledIn
        self.implementation = implementation
        self.pinnedVersion = pinnedVersion
        self.platform = platform
        self.usesMetal = usesMetal
        self.availability = availability
    }

    /// True when this build has an engine and that engine came up.
    ///
    /// Both halves matter, and they fail differently: the first is a CI
    /// mistake, the second is a device problem.
    public var isReadyToRun: Bool { isCompiledIn && availability.canRun }

    /// The headline for the settings row.
    public var title: String {
        if !isCompiledIn { return "Not included in this build" }
        return availability.canRun ? "Ready" : "Failed to initialize"
    }

    /// The distinction section 18 insists on: a runtime that is absent and a
    /// runtime that is present but broken must not read the same.
    public var detail: String {
        guard isCompiledIn else {
            return "This build of MetisAI was compiled without the on-device "
                + "inference engine, so no local model can run. This is a build "
                + "problem rather than something to fix on this iPhone."
        }
        switch availability {
        case .available, .idle:
            return "llama.cpp is linked and ready. Download or import a compatible "
                + "GGUF model to use it."
        case .unavailable(let reason):
            return "llama.cpp is included in this build but reported: \(reason)"
        }
    }

    /// A sanitized report, safe to paste into a message.
    ///
    /// No filesystem paths, no model names, no prompts — the runtime facts and
    /// nothing else.
    public func report(installedModels: Int, runnableModels: Int) -> String {
        [
            "MetisAI Local Runtime",
            "Platform: \(platform)",
            "Runtime compiled: \(isCompiledIn)",
            "Runtime implementation: \(implementation)"
                + (pinnedVersion.map { " \($0)" } ?? ""),
            "Runtime initialized: \(availability.canRun)",
            "Metal: \(usesMetal ? "enabled" : "disabled")",
            "Installed models: \(installedModels)",
            "Runnable models: \(runnableModels)",
        ].joined(separator: "\n")
    }
}
