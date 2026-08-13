// TODO-XCODE: this file is part of the iOS app target, not the Swift package.
// It does not compile during Windows-stage development.

import AIProviderApple
import AIProviderLocal
import AssistantAI
import AssistantDomain
import AssistantCore
import AssistantPersistence
import AssistantPlatform
import Foundation

/// Builds the object graph for the app.
///
/// This is the single place where concrete implementations are chosen. Note
/// that switching the whole app from mock services to real Apple frameworks is
/// a change to `platformServices` alone — nothing in `AssistantEngine`,
/// the tool system or the reminder planner is aware of the difference.
enum AssistantComposition {
    static func makeEngine() -> AssistantEngine {
        let dateProvider = SystemDateProvider()

        // TODO-XCODE: replace with a SwiftData- or SQLite-backed store. The
        // JSON snapshot store is a development convenience and will not scale
        // to a real message history.
        let store = JSONFileSnapshotStore(directory: applicationSupportDirectory())
        let repositories = AssistantRepositories.snapshot(store: store)

        let registry = AIProviderRegistry(providers: [
            AppleFoundationModelsProvider(),
            LocalModelProvider(),
            // TODO-XCODE: register a RemoteAIProvider once an adapter exists,
            // with a Keychain-backed CredentialProvider.
        ])

        return AssistantEngine(
            providers: registry,
            repositories: repositories,
            services: platformServices(),
            dateProvider: dateProvider
        )
    }

    /// TODO-XCODE: return the real Apple-backed services here.
    ///
    /// Until each one is written, the mock is used — and because the mocks
    /// report `.simulated`, the UI can show the user plainly that nothing was
    /// actually scheduled.
    private static func platformServices() -> PlatformServices {
        fatalError("TODO-XCODE: wire EventKit, UserNotifications and AlarmKit services")
    }

    private static func applicationSupportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        return (base.first ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("PersonalAssistant", isDirectory: true)
    }
}
