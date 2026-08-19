import AssistantDomain
import AssistantPlatform
import AssistantPlatformApple
import XCTest

/// Identifiers, escalation and recurrence: the translations that decide whether
/// a reminder can be cancelled, how loudly it arrives, and whether a repeating
/// event repeats correctly.
final class AppleMappingTests: XCTestCase {

    // MARK: Identifiers

    func testANotificationIdentifierRoundTrips() throws {
        let id = NotificationRequest.ID()
        let system = AppleNotificationIdentity.systemIdentifier(for: id)

        XCTAssertEqual(AppleNotificationIdentity.requestIdentifier(from: system), id)
        XCTAssertTrue(AppleNotificationIdentity.isOurs(system))
    }

    /// The property cancellation depends on. If the same reminder produced a
    /// different string on a later launch, withdrawing it would silently fail
    /// and the user would be chased about something they had finished.
    func testTheSameRequestAlwaysProducesTheSameIdentifier() {
        let id = NotificationRequest.ID()
        XCTAssertEqual(
            AppleNotificationIdentity.systemIdentifier(for: id),
            AppleNotificationIdentity.systemIdentifier(for: id)
        )
    }

    func testAnotherAppsIdentifierIsNotClaimed() {
        for foreign in [
            "com.apple.something",
            "assistant.reminder.not-a-uuid",
            "",
            "assistant.reminder.",
            NotificationRequest.ID().rawValue.uuidString,
        ] {
            XCTAssertFalse(
                AppleNotificationIdentity.isOurs(foreign),
                "\(foreign) is not one of ours and must never be removed as though it were"
            )
        }
    }

    // MARK: Derived identity

    func testADerivedIdentifierIsStableForTheSameExternalIdentifier() {
        let first = AppleExternalIdentity.domainUUID(
            namespace: AppleExternalIdentity.calendarNamespace,
            externalIdentifier: "EK-1234-ABCD"
        )
        let second = AppleExternalIdentity.domainUUID(
            namespace: AppleExternalIdentity.calendarNamespace,
            externalIdentifier: "EK-1234-ABCD"
        )
        XCTAssertEqual(first, second)
    }

    func testDifferentEventsGetDifferentIdentifiers() {
        var seen = Set<UUID>()
        for index in 0..<2_000 {
            let uuid = AppleExternalIdentity.domainUUID(
                namespace: AppleExternalIdentity.calendarNamespace,
                // EventKit identifiers differ mostly in their tail, which is
                // the case the second hash pass exists to spread out.
                externalIdentifier: "8A1F0C22-0000-0000-0000-\(String(format: "%012d", index))"
            )
            XCTAssertTrue(seen.insert(uuid).inserted, "Collision at \(index)")
        }
    }

    /// An event and a reminder can carry the same EventKit identifier string.
    /// Without the namespace they would become one domain object.
    func testNamespacesKeepEventsAndRemindersApart() {
        let external = "shared-identifier"
        XCTAssertNotEqual(
            AppleExternalIdentity.domainUUID(
                namespace: AppleExternalIdentity.calendarNamespace,
                externalIdentifier: external
            ),
            AppleExternalIdentity.domainUUID(
                namespace: AppleExternalIdentity.reminderNamespace,
                externalIdentifier: external
            )
        )
    }

    func testTheDerivedIdentifierIsAWellFormedVersionFiveUUID() {
        let uuid = AppleExternalIdentity.domainUUID(
            namespace: AppleExternalIdentity.calendarNamespace,
            externalIdentifier: "anything"
        )
        let bytes = withUnsafeBytes(of: uuid.uuid) { Array($0) }
        XCTAssertEqual(bytes[6] >> 4, 0x5, "version nibble")
        XCTAssertEqual(bytes[8] >> 6, 0b10, "RFC 4122 variant")
    }

    // MARK: Escalation

    func testEscalationRisesWithInsistence() {
        let levels = EscalationLevel.allCases.sorted().map {
            AppleEscalationMapping.delivery(for: $0).interruptionLevel
        }
        XCTAssertEqual(levels, [.passive, .active, .timeSensitive, .timeSensitive])
    }

    /// Critical alerts need an entitlement this app does not hold, and asking
    /// for one you do not have fails quietly — which would produce code that
    /// looks like it delivers an unmissable alert and does not.
    func testNoEscalationLevelEverRequestsACriticalAlert() {
        for level in EscalationLevel.allCases {
            XCTAssertNotEqual(
                AppleEscalationMapping.delivery(for: level).interruptionLevel, .critical,
                "\(level.rawValue) must not claim an entitlement this build lacks"
            )
        }
    }

    func testAskingANotificationForAnAlarmSaysSoOutLoud() throws {
        let delivery = AppleEscalationMapping.delivery(for: .alarm)
        let note = try XCTUnwrap(
            delivery.downgradeNote,
            "A notification cannot be an alarm, and the receipt has to admit it"
        )
        XCTAssertTrue(note.contains("not an alarm"))
        XCTAssertTrue(AppleEscalationMapping.exceedsNotificationCapability(.alarm))
    }

    func testOnlyTheQuietestLevelIsSilent() {
        XCTAssertFalse(AppleEscalationMapping.delivery(for: .gentle).playsSound)
        for level: EscalationLevel in [.standard, .insistent, .alarm] {
            XCTAssertTrue(AppleEscalationMapping.delivery(for: level).playsSound)
        }
    }

    // MARK: Recurrence

    /// `EKRecurrenceRule` raises an Objective-C exception — not a Swift error —
    /// for an interval below 1, which terminates the process. Clamping here is
    /// what keeps a language model's zero out of that initialiser.
    func testAnIntervalBelowOneIsClampedRatherThanPassedOn() {
        for rule: RecurrenceRule in [
            .daily(interval: 0),
            .weekly(interval: -3, weekdays: [2]),
            .monthly(interval: 0, day: 5),
            .yearly(interval: 0),
        ] {
            XCTAssertGreaterThanOrEqual(
                AppleRecurrenceMapping.specification(for: rule).interval, 1
            )
        }
    }

    func testImpossibleWeekdaysAreDroppedRatherThanClamped() {
        let spec = AppleRecurrenceMapping.specification(
            for: .weekly(interval: 1, weekdays: [0, 2, 4, 9])
        )
        // A weekday of 9 has no nearest sensible meaning, so it goes; 2 and 4
        // are real and stay.
        XCTAssertEqual(spec.weekdays, [2, 4])
    }

    func testADayOfMonthIsHeldInsideACalendarMonth() {
        XCTAssertEqual(
            AppleRecurrenceMapping.specification(for: .monthly(interval: 1, day: 99)).dayOfMonth,
            31
        )
        XCTAssertEqual(
            AppleRecurrenceMapping.specification(for: .monthly(interval: 1, day: 0)).dayOfMonth,
            1
        )
    }

    func testFrequenciesTranslateOneForOne() {
        XCTAssertEqual(
            AppleRecurrenceMapping.specification(for: .daily(interval: 2)).frequency, .daily
        )
        XCTAssertEqual(
            AppleRecurrenceMapping.specification(for: .weekly(interval: 1, weekdays: [])).frequency,
            .weekly
        )
        XCTAssertEqual(
            AppleRecurrenceMapping.specification(for: .monthly(interval: 1, day: 1)).frequency,
            .monthly
        )
        XCTAssertEqual(
            AppleRecurrenceMapping.specification(for: .yearly(interval: 1)).frequency, .yearly
        )
    }
}
