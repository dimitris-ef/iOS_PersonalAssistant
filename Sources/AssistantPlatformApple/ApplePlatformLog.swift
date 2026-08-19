import Foundation

#if canImport(os)
import os
#endif

/// Development logging for the Apple platform layer.
///
/// Same contract as `AppleProviderLog`, and it matters more here. The values
/// flowing through this layer are the user's actual appointments, the titles of
/// things they have not managed to do, and the times of day they need waking
/// up. A device log is readable from a connected Mac and is captured by
/// sysdiagnose, so none of that goes into one.
///
/// Every function takes a fixed, caller-authored string. The call sites pass
/// operation names, capability names and permission states — never an event
/// title, a reminder body, a note, a location, or an identifier that could be
/// correlated back to one.
enum ApplePlatformLog {

    #if canImport(os)
    private static let logger = Logger(
        subsystem: "PersonalAssistant",
        category: "ApplePlatform"
    )
    #endif

    static func debug(_ message: String) {
        #if canImport(os)
        // `.public` is safe only because of the rule above: these strings are
        // written in this codebase, not taken from the user's data.
        logger.debug("\(message, privacy: .public)")
        #endif
    }

    static func error(_ message: String) {
        #if canImport(os)
        logger.error("\(message, privacy: .public)")
        #endif
    }
}
