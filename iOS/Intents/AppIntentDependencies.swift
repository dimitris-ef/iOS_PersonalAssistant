import AssistantCore
import Foundation

/// The production object graph, for code that runs without a window.
///
/// ## The problem this solves
///
/// An App Intent can run when the app is not open. Siri wakes the process,
/// calls `perform()`, and there is no `WindowGroup`, no `RootView` and no
/// `AppModel` — those are SwiftUI things and SwiftUI has not been asked to do
/// anything. But the intent still needs the repositories, the provider
/// registry, the platform services and the engine.
///
/// ## Why this is not a second composition
///
/// It calls `AppEnvironment.makePersistent()` — the same function
/// `PersonalAssistantApp.init` calls. Not a copy of it, not a slimmer variant:
/// the identical composition, so an intent and the app cannot end up with
/// different providers, different platform services or, most importantly,
/// different databases. A task created by Siri is in the store the app opens
/// because it is the store the app opens.
///
/// ## Lifetime
///
/// Built once per process and cached. The environment opens a SwiftData
/// container, and opening a second one against the same file from the same
/// process is how you get two contexts disagreeing about what is saved. If the
/// app is already running, `shared` was built by the app and the intent reuses
/// it; if the intent woke the process, the app reuses what the intent built.
///
/// `@MainActor` because `AppEnvironment.makePersistent` is — the SwiftData
/// container is main-actor bound. App Intent `perform()` is async, so awaiting
/// a hop is free.
@MainActor
enum AppIntentDependencies {

    /// What every intent talks to. Deliberately narrow: intents get the command
    /// service and nothing else, so none of them can reach a repository, a
    /// provider or a platform service directly even by accident.
    static func commands() throws -> AssistantCommandService {
        try environment().commands
    }

    /// The one environment this process has.
    ///
    /// Failure is thrown rather than swallowed. An intent that cannot open the
    /// store must say so — quietly succeeding while writing nowhere is the
    /// worst outcome available, because Siri would confirm a task that does not
    /// exist.
    /// TODO-DEVICE: opening the store from a background launch, when Siri
    /// started the process rather than the user, has never run. The foreground
    /// path is exercised on every app launch; this one is not.
    static func environment() throws -> AppEnvironment {
        if let cached { return cached }
        let created = try AppEnvironment.makePersistent()
        cached = created
        return created
    }

    /// Adopts the environment the app already built.
    ///
    /// Called from `PersonalAssistantApp.init`. Without it, launching the app
    /// and then running an intent would build a second environment — and a
    /// second `ModelContainer` over the same file, which is the concurrency
    /// mistake SwiftData is least forgiving about.
    static func adopt(_ environment: AppEnvironment) {
        cached = environment
    }

    private static var cached: AppEnvironment?
}
