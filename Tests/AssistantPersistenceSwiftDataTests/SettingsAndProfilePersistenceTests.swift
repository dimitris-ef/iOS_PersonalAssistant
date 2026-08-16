#if canImport(SwiftData)

import AssistantDomain
import AssistantPersistence
import AssistantPersistenceSwiftData
import SwiftData
import XCTest

@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
final class SettingsAndProfilePersistenceTests: PersistenceTestCase {

    // MARK: Settings

    func testFirstLaunchReadsDefaultsWithoutWritingThem() async throws {
        let settings = try await repositories.settings.settings()
        XCTAssertEqual(settings, AssistantSettings())

        // Reading defaults must not create a row. A new user's store should be
        // empty until they change something.
        let persistence = AssistantPersistenceActor(modelContainer: store.container)
        let rows = try await persistence.read { context in
            try context.fetchCount(FetchDescriptor<SDAssistantSettings>())
        }
        XCTAssertEqual(rows, 0)
    }

    func testSavesAndReloadsSettings() async throws {
        var settings = AssistantSettings()
        settings.preferredProviderID = "remote.openai-compatible"
        settings.preferredModelID = "some-model"
        settings.routingPolicy = .preferMostCapable
        settings.conversationContextLimit = 42
        settings.memoryContextLimit = 7
        settings.defaultAuthorization = .requiresConfirmation
        settings.toolAuthorizations[.createAlarm] = .denied
        settings.support.morningOfTime = TimeOfDay(hour: 6, minute: 45)
        settings.support.advanceNoticeDays = [1, 3, 7]
        settings.support.flexibleNudgesPerDay = 3
        settings.support.completion.requiresExplicitConfirmation = true

        try await repositories.settings.update(settings)

        try relaunch()

        let loaded = try await repositories.settings.settings()
        XCTAssertEqual(loaded, settings)
    }

    /// Settings are one record. Saving repeatedly must rewrite it, or the store
    /// would accumulate a new set of preferences on every change and "which one
    /// is current" would become a guess.
    func testUpdatingSettingsNeverCreatesASecondRecord() async throws {
        for limit in [10, 20, 30] {
            var settings = try await repositories.settings.settings()
            settings.conversationContextLimit = limit
            try await repositories.settings.update(settings)
        }

        try relaunch()

        let loaded = try await repositories.settings.settings().conversationContextLimit
        XCTAssertEqual(loaded, 30)

        let persistence = AssistantPersistenceActor(modelContainer: store.container)
        let rows = try await persistence.read { context in
            try context.fetchCount(FetchDescriptor<SDAssistantSettings>())
        }
        XCTAssertEqual(rows, 1)
    }

    func testEveryRoutingPolicySurvives() async throws {
        for policy in ModelRoutingPolicy.allCases {
            var settings = try await repositories.settings.settings()
            settings.routingPolicy = policy
            try await repositories.settings.update(settings)
            let loaded = try await repositories.settings.settings().routingPolicy
            XCTAssertEqual(loaded, policy)
        }
    }

    // MARK: Profile

    func testSavesAndReloadsTheProfile() async throws {
        var profile = try await repositories.profile.profile()
        profile.displayName = "Sam"
        profile.timeZoneIdentifier = "Europe/Athens"
        profile.wakeTime = TimeOfDay(hour: 6, minute: 30)
        profile.sleepTime = TimeOfDay(hour: 23)
        profile.defaultPreparationDuration = TimeSpan.minutes(45)
        profile.defaultTravelDuration = TimeSpan.minutes(25)
        profile.quietHours = DayWindow(start: TimeOfDay(hour: 23), end: TimeOfDay(hour: 7))

        try await repositories.profile.update(profile)

        try relaunch()

        let loaded = try await repositories.profile.profile()
        XCTAssertEqual(loaded, profile)
    }

    func testUpdatingTheProfileNeverCreatesASecondRecord() async throws {
        for name in ["A", "B", "C"] {
            var profile = try await repositories.profile.profile()
            profile.displayName = name
            try await repositories.profile.update(profile)
        }

        try relaunch()

        let loaded = try await repositories.profile.profile().displayName
        XCTAssertEqual(loaded, "C")

        let persistence = AssistantPersistenceActor(modelContainer: store.container)
        let rows = try await persistence.read { context in
            try context.fetchCount(FetchDescriptor<SDUserProfile>())
        }
        XCTAssertEqual(rows, 1)
    }

    /// Optional time-of-day fields have to come back as `nil`, not as midnight.
    /// A profile with no quiet hours must not acquire a window from 00:00 to
    /// 00:00, which would suppress every reminder at midnight.
    func testAbsentTimesStayAbsent() async throws {
        var profile = try await repositories.profile.profile()
        profile.displayName = "Sam"
        profile.wakeTime = nil
        profile.sleepTime = nil
        profile.quietHours = nil
        try await repositories.profile.update(profile)

        try relaunch()

        let loaded = try await repositories.profile.profile()
        XCTAssertNil(loaded.wakeTime)
        XCTAssertNil(loaded.sleepTime)
        XCTAssertNil(loaded.quietHours)
    }
}

#endif
