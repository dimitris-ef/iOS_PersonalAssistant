import AssistantCore
import AssistantPersistence
import AssistantPersistenceSwiftData
import AssistantPlatform
import AssistantPlatformApple
import Foundation
import SystemSurfaces

/// The narrow object graph a system surface is allowed to build.
///
/// ## What is deliberately missing
///
/// Section 2: *do not inject the entire production `AssistantEngine` graph into
/// every extension unless the execution environment genuinely supports and
/// requires it.* A widget's Done button requires the repositories, the status
/// machine and the support planner — that is the whole of what section 39 asks
/// for. It does not require an `AIProviderRegistry`, and giving it one would
/// pull the remote provider, Apple Foundation Models and, on a device build,
/// llama.cpp into a process iOS gives a few tens of megabytes and a few
/// seconds.
///
/// So this composes exactly four things: the SwiftData container, the
/// repositories over it, the live platform services, and
/// `SystemSurfaceCommandService`. **No engine, no providers, no model.**
/// Sections 15, 16, 120 and 121 are satisfied by the dependency list rather
/// than by a promise.
///
/// ## Why it can open the store at all
///
/// Because the store is in the App Group container — see `SharedStoreLocation`.
/// An interactive widget's App Intent runs in the widget extension's process,
/// which is a fact about iOS rather than a design choice, and an extension that
/// cannot reach the database cannot route anything through the domain.
///
/// ## Lifetime
///
/// One per process, cached. Two `ModelContainer`s over one file is the
/// concurrency mistake SwiftData is least forgiving about, and an extension is
/// asked to perform several intents in quick succession.
@MainActor
enum SystemSurfaceBridge {

    /// The three buttons a surface may press.
    static func commands() throws -> SystemSurfaceCommandService {
        try composition().commands
    }

    /// The projection writer, so an action can refresh what it changed.
    static func surfaces() throws -> SystemSurfaceService {
        try composition().surfaces
    }

    /// Everything a surface has. Nothing else is reachable from here.
    struct Composition {
        let repositories: AssistantRepositories
        let services: PlatformServices
        let commands: SystemSurfaceCommandService
        let surfaces: SystemSurfaceService
    }

    static func composition() throws -> Composition {
        if let cached { return cached }

        let container = try AssistantPersistenceContainer.make(
            location: SharedStoreLocation.resolve()
        )
        let repositories = AssistantRepositories.persistent(container: container)
        // The same live services the app builds, so a reminder cancelled from a
        // widget is cancelled with the same notification centre the app used to
        // schedule it. Not a second implementation — the identical function.
        let platform = PlatformServices.live()

        let created = Composition(
            repositories: repositories,
            services: platform.services,
            commands: SystemSurfaceCommandService(
                repositories: repositories,
                services: platform.services
            ),
            surfaces: SystemSurfaceService(
                repositories: repositories,
                store: FileSystemSurfaceStore.appGroup(),
                reloader: WidgetCenterReloader(),
                // Deliberately no live-activity coordinator here. An extension
                // may not start or end a Live Activity for someone else's
                // session — ActivityKit requests belong to the app, and section
                // 54 keeps the registry in one process.
                activities: nil
            )
        )
        cached = created
        return created
    }

    /// Adopted by the app, so an intent performed while the app is open reuses
    /// the app's composition rather than opening a second container.
    static func adopt(
        repositories: AssistantRepositories,
        services: PlatformServices,
        surfaces: SystemSurfaceService
    ) {
        cached = Composition(
            repositories: repositories,
            services: services,
            commands: SystemSurfaceCommandService(
                repositories: repositories,
                services: services
            ),
            surfaces: surfaces
        )
    }

    private static var cached: Composition?
}
