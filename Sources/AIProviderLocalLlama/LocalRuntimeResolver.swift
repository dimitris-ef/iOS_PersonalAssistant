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
    public static func best() -> any LocalModelRuntime {
        LlamaCppRuntime()
    }
}
