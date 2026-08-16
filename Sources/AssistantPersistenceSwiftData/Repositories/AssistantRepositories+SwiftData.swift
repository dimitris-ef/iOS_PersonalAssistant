#if canImport(SwiftData)

import AssistantPersistence
import Foundation
import SwiftData

@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
extension AssistantRepositories {
    /// The production repository set: every store backed by SwiftData.
    ///
    /// All seven share one `AssistantPersistenceActor`, and therefore one
    /// context over one container. Giving each repository its own would give
    /// each its own cache of the same rows, and a task completed through one
    /// would be invisible to another until something forced a refetch.
    ///
    /// This is the substitution the architecture was built for: the type of
    /// every value here is a protocol the core already depended on, so nothing
    /// above this line changes.
    public static func persistent(persistence: AssistantPersistenceActor) -> AssistantRepositories {
        AssistantRepositories(
            conversations: SwiftDataConversationRepository(persistence: persistence),
            memories: SwiftDataMemoryRepository(persistence: persistence),
            tasks: SwiftDataTaskRepository(persistence: persistence),
            reminderPlans: SwiftDataReminderPlanRepository(persistence: persistence),
            settings: SwiftDataSettingsRepository(persistence: persistence),
            profile: SwiftDataUserProfileRepository(persistence: persistence),
            actionPlans: SwiftDataActionPlanRepository(persistence: persistence)
        )
    }

    /// Convenience for a container you already opened.
    public static func persistent(container: ModelContainer) -> AssistantRepositories {
        persistent(persistence: AssistantPersistenceActor(modelContainer: container))
    }
}

#endif
