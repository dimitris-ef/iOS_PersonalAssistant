import Foundation

#if canImport(os)
import os
#endif

/// Development logging for the Apple provider.
///
/// Two jobs, and the second is the important one.
///
/// **It compiles everywhere.** `os` is an Apple module; the core package builds
/// on Linux and Windows, so the import is guarded here once rather than at
/// every call site.
///
/// **It cannot leak the user's life.** Every function below takes a fixed,
/// caller-authored string, and the call sites pass category names — an
/// availability state, a tool name, a mapped error case. Nothing here accepts
/// or formats a prompt, a reply, a memory, a task title or tool arguments,
/// because a logging helper that *could* take them is a logging helper that
/// eventually does. What the assistant knows about someone is the most
/// sensitive data in the app and none of it belongs in a device log.
enum AppleProviderLog {

    #if canImport(os)
    private static let logger = Logger(
        subsystem: "PersonalAssistant",
        category: "AppleFoundationModels"
    )
    #endif

    /// Routine progress: availability, session creation, tool names proposed.
    static func debug(_ message: String) {
        #if canImport(os)
        // `.public` is deliberate and safe *because* of the rule above: these
        // strings are written in this codebase, not taken from the user.
        logger.debug("\(message, privacy: .public)")
        #endif
    }

    /// A failure, already reduced to a provider-neutral case name.
    static func error(_ message: String) {
        #if canImport(os)
        logger.error("\(message, privacy: .public)")
        #endif
    }
}
