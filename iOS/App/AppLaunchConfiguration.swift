import AssistantPersistenceSwiftData
import Foundation

/// How this launch should behave.
///
/// There is exactly one production answer — an on-disk store with nothing in it
/// but the user's own data — and a debug-only alternative for previews,
/// screenshots and CI. Keeping the decision in one type means "does this launch
/// seed demo content" has a single, greppable answer rather than being implied
/// by whichever bootstrap path happened to run.
struct AppLaunchConfiguration {
    /// Where user data goes.
    var persistence: PersistenceLocation
    /// Whether to write the demo dataset into it.
    var seedsDemoData: Bool

    /// The real thing: a persistent store, and no fabricated content in it.
    ///
    /// A new user gets empty conversations, an empty task list and no memories.
    /// They do get default settings and a default profile, because the app
    /// cannot plan reminders without a wake time or a preparation duration —
    /// that is configuration, not content, and the distinction matters: a fake
    /// haircut in someone's real task list is a bug, a default 30-minute
    /// preparation allowance is the app working.
    static let production = AppLaunchConfiguration(
        persistence: .applicationDefault,
        seedsDemoData: false
    )

    /// Reads the launch environment.
    ///
    /// Demo seeding is available **only in debug builds**, and only when asked
    /// for explicitly. A release build ignores the flag entirely — the branch
    /// is compiled out — so there is no argument anyone can pass to a shipped
    /// app that fills their database with example data.
    static func current(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AppLaunchConfiguration {
        #if DEBUG
        let requested = arguments.contains(demoDataFlag)
            || environment[demoDataVariable] == "1"

        guard requested else { return production }

        // Demo mode deliberately does not touch the real store. It is used by
        // CI screenshots and by developers, and neither should be able to write
        // example data into a database a real user might later open.
        return AppLaunchConfiguration(persistence: .inMemory, seedsDemoData: true)
        #else
        return production
        #endif
    }

    /// Passed by the CI simulator workflow. See `.github/workflows/`.
    static let demoDataFlag = "-seed-demo-data"
    static let demoDataVariable = "ASSISTANT_SEED_DEMO_DATA"
}
