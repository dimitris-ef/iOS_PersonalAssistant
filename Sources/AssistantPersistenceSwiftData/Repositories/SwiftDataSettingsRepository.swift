#if canImport(SwiftData)

import AssistantDomain
import AssistantPersistence
import Foundation
import SwiftData

/// `SettingsRepository`, backed by SwiftData.
///
/// Settings are one record. `fetch-or-create` against a fixed identifier —
/// rather than "take the first row" — is what stops a second set of settings
/// appearing on a launch that races itself, and the unique constraint on the id
/// means storage enforces it too.
@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
public struct SwiftDataSettingsRepository: SettingsRepository {
    private let persistence: AssistantPersistenceActor

    public init(persistence: AssistantPersistenceActor) {
        self.persistence = persistence
    }

    /// The stored settings, or the defaults.
    ///
    /// A first launch reads defaults without writing them. Defaults are
    /// configuration, not content: a new user's store should be empty, and
    /// writing a row here just to have one would make "has this user ever
    /// changed anything" unanswerable.
    public func settings() async throws -> AssistantSettings {
        try await persistence.read { context in
            guard let row = try context.first(Self.descriptor(), entity: SettingsMapper.entity) else {
                return AssistantSettings()
            }
            return try SettingsMapper.makeDomain(from: row)
        }
    }

    public func update(_ settings: AssistantSettings) async throws {
        try await persistence.mutate(entity: SettingsMapper.entity) { context in
            if let existing = try context.first(Self.descriptor(), entity: SettingsMapper.entity) {
                SettingsMapper.update(existing, from: settings)
            } else {
                context.insert(SettingsMapper.makeRow(from: settings))
            }
        }
    }

    private static func descriptor() -> FetchDescriptor<SDAssistantSettings> {
        let id = SingletonRecord.settings
        return FetchDescriptor<SDAssistantSettings>(predicate: #Predicate { $0.id == id })
    }
}

/// `UserProfileRepository`, backed by SwiftData. Also a single record.
@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
public struct SwiftDataUserProfileRepository: UserProfileRepository {
    private let persistence: AssistantPersistenceActor

    public init(persistence: AssistantPersistenceActor) {
        self.persistence = persistence
    }

    public func profile() async throws -> UserProfile {
        try await persistence.read { context in
            guard let row = try context.first(Self.descriptor(), entity: UserProfileMapper.entity) else {
                // A profile whose id is the singleton id, so the first `update`
                // writes the row this read was looking for instead of creating
                // a second profile under a fresh identifier.
                return UserProfile(id: UserProfile.ID(SingletonRecord.profile))
            }
            return UserProfileMapper.makeDomain(from: row)
        }
    }

    public func update(_ profile: UserProfile) async throws {
        try await persistence.mutate(entity: UserProfileMapper.entity) { context in
            if let existing = try context.first(Self.descriptor(), entity: UserProfileMapper.entity) {
                UserProfileMapper.update(existing, from: profile)
            } else {
                context.insert(UserProfileMapper.makeRow(from: profile))
            }
        }
    }

    private static func descriptor() -> FetchDescriptor<SDUserProfile> {
        let id = SingletonRecord.profile
        return FetchDescriptor<SDUserProfile>(predicate: #Predicate { $0.id == id })
    }
}

#endif
