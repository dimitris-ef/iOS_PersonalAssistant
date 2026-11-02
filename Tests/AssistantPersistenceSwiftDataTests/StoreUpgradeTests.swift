#if canImport(SwiftData)

import AssistantDomain
import AssistantPersistence
import Foundation
import SwiftData
import XCTest

@testable import AssistantPersistenceSwiftData

/// Opening a store written by the previous version — what a phone does on the
/// first launch after an update.
///
/// ## Why this file exists
///
/// Build 16 crashed on launch for everyone who had the app installed, and every
/// test passed. Every test created a fresh store at the newest version; none
/// ever *migrated* one. These write the old store through the old, frozen
/// classes — exactly as builds 1 to 15 did — and open it with the current
/// container, the way the app does.
@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
final class StoreUpgradeTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("store-upgrade-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
    }

    private static let memoryID = UUID()
    private static let memoryText = "My dentist is Dr Alvarez."

    /// What TestFlight builds 1 to 15 left on disk: a V9 store written through
    /// V9's own classes, with a settings row and a memory in it.
    ///
    /// Its own function so the container is released before the store is
    /// reopened, as it is across an app update.
    @discardableResult
    private func writeVersion9Store(at url: URL) throws -> UUID {
        // Built from the app's real defaults first, so every raw value is one
        // the mapper understands, then copied into V9's frozen shape.
        let current = SettingsMapper.makeRow(
            from: AssistantSettings(selectedLocalModelID: "chat-a")
        )

        let schema = Schema(
            PersonalAssistantSchemaV9.models, version: PersonalAssistantSchemaV9.versionIdentifier
        )
        let container = try ModelContainer(
            for: schema, configurations: [ModelConfiguration(schema: schema, url: url)]
        )
        let context = ModelContext(container)

        context.insert(
            PersonalAssistantSchemaV9.SDAssistantSettings(
                id: current.id,
                preferredProviderID: current.preferredProviderID,
                preferredModelID: current.preferredModelID,
                routingPolicyRaw: current.routingPolicyRaw,
                toolAuthorizations: current.toolAuthorizations,
                defaultAuthorizationRaw: current.defaultAuthorizationRaw,
                conversationContextLimit: current.conversationContextLimit,
                memoryContextLimit: current.memoryContextLimit,
                supportAdvanceNoticeDays: current.supportAdvanceNoticeDays,
                supportMorningOfHour: current.supportMorningOfHour,
                supportMorningOfMinute: current.supportMorningOfMinute,
                supportPreparationLeadDefault: current.supportPreparationLeadDefault,
                supportFinalCallLead: current.supportFinalCallLead,
                supportDefaultEscalationRaw: current.supportDefaultEscalationRaw,
                supportFlexibleNudgesPerDay: current.supportFlexibleNudgesPerDay,
                supportFollowUpIsEnabled: current.supportFollowUpIsEnabled,
                supportFollowUpMaximum: current.supportFollowUpMaximum,
                supportFollowUpInterval: current.supportFollowUpInterval,
                supportFollowUpEscalatesEachTime: current.supportFollowUpEscalatesEachTime,
                supportSnoozeIsAllowed: current.supportSnoozeIsAllowed,
                supportSnoozeDefaultDuration: current.supportSnoozeDefaultDuration,
                supportSnoozeMaximum: current.supportSnoozeMaximum,
                supportSnoozeEscalateAfter: current.supportSnoozeEscalateAfter,
                supportCompletionRequiresExplicitConfirmation:
                    current.supportCompletionRequiresExplicitConfirmation,
                supportCompletionMarkMissedAfter: current.supportCompletionMarkMissedAfter,
                voiceSpeaksReplies: current.voiceSpeaksReplies,
                voiceSpeaksTypedReplies: current.voiceSpeaksTypedReplies,
                voiceLocaleIdentifier: current.voiceLocaleIdentifier,
                selectedLocalModelID: current.selectedLocalModelID
            )
        )
        context.insert(
            SDMemory(
                id: Self.memoryID,
                kindRaw: "fact",
                content: Self.memoryText,
                salience: 0.5,
                tags: [],
                createdAt: Date(timeIntervalSince1970: 0),
                updatedAt: Date(timeIntervalSince1970: 0),
                lastUsedAt: nil,
                sourceRaw: "user"
            )
        )
        try context.save()
        return current.id
    }

    /// The build 16 crash, as a test. Before the fix this did not fail — it
    /// trapped inside SwiftData with duplicate version checksums.
    func testAVersion9StoreOpensAndKeepsEverything() throws {
        let url = directory.appendingPathComponent("store.sqlite")
        let settingsID = try writeVersion9Store(at: url)

        let container = try AssistantPersistenceContainer.make(location: .file(url))
        XCTAssertEqual(container.schema.version, PersonalAssistantSchemaV10.versionIdentifier)

        let context = ModelContext(container)
        let settings = try context.fetch(FetchDescriptor<SDAssistantSettings>())
        XCTAssertEqual(settings.map(\.id), [settingsID], "one settings row, the same one")
        let row = try XCTUnwrap(settings.first)
        XCTAssertEqual(row.selectedLocalModelID, "chat-a", "the chat model choice survived")
        // The two V10 columns: no action model chosen, and the path enabled.
        XCTAssertNil(row.selectedActionModelID)
        XCTAssertTrue(row.actionModelEnabled)

        let memories = try context.fetch(FetchDescriptor<SDMemory>())
        XCTAssertEqual(memories.map(\.id), [Self.memoryID], "a memory written before the update")
        XCTAssertEqual(memories.first?.content, Self.memoryText)
    }

    /// The same upgrade, read the way the app reads it: through the repository
    /// and the mapper, into the domain type.
    func testTheUpgradedSettingsReadBackThroughTheRepository() async throws {
        let url = directory.appendingPathComponent("store.sqlite")
        try writeVersion9Store(at: url)

        let container = try AssistantPersistenceContainer.make(location: .file(url))
        let repositories = AssistantRepositories.persistent(container: container)
        let settings = try await repositories.settings.settings()

        XCTAssertEqual(settings.selectedLocalModelID, "chat-a")
        XCTAssertEqual(settings.actionModel, ActionModelConfiguration())
        XCTAssertFalse(settings.actionModel.isConfigured, "an upgrade does not pick an action model")
    }

    /// The upgraded store is a normal V10 store from then on: reopening it
    /// migrates nothing and loses nothing.
    func testAnUpgradedStoreReopensCleanly() throws {
        let url = directory.appendingPathComponent("store.sqlite")
        let settingsID = try writeVersion9Store(at: url)

        do {
            _ = try AssistantPersistenceContainer.make(location: .file(url))
        }
        let reopened = try AssistantPersistenceContainer.make(location: .file(url))
        let rows = try ModelContext(reopened).fetch(FetchDescriptor<SDAssistantSettings>())
        XCTAssertEqual(rows.map(\.id), [settingsID])
    }
}

#endif
