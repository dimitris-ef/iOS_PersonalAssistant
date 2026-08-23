import AssistantDomain
import ExecutiveSupport
import Foundation
import XCTest

/// What the app wants iOS to be holding, against what iOS is actually holding.
///
/// Section 97, and the reason there is a diff at all: section 29 rules out
/// `removeAllPendingNotificationRequests()`. Clearing everything removes
/// notifications this app never scheduled, leaves a window with no reminders at
/// all, and makes duplicate detection impossible because everything is always
/// both new and obsolete.
final class PlatformScheduleDiffTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    func testAMissingRequestIsScheduled() {
        let entry = desired(at: now.addingTimeInterval(TimeSpan.hours(1)))
        let diff = PlatformScheduleDiff.between(desired: [entry], existing: [])

        XCTAssertEqual(diff.toSchedule.map(\.stageID), [entry.stageID])
        XCTAssertTrue(diff.toCancel.isEmpty)
        XCTAssertTrue(diff.unchanged.isEmpty)
    }

    /// The case that matters most for cost: nothing changed, so nothing is
    /// touched. This is what makes reconciling on every foreground affordable.
    func testAnIdenticalRequestIsLeftCompletelyAlone() {
        let entry = desired(at: now.addingTimeInterval(TimeSpan.hours(1)))
        let diff = PlatformScheduleDiff.between(
            desired: [entry],
            existing: [existing(for: entry)]
        )

        XCTAssertTrue(diff.isEmpty)
        XCTAssertEqual(diff.unchanged, [entry.stageID])
    }

    /// Section 27's fourth case. A reminder that moved is one withdrawal
    /// followed by one addition — in that order, because the identifier is the
    /// same and a cancellation applied afterwards would delete the replacement.
    func testAMovedRequestIsCancelledAndRescheduled() {
        let entry = desired(at: now.addingTimeInterval(TimeSpan.hours(2)))
        var stale = existing(for: entry)
        stale.fireDate = now.addingTimeInterval(TimeSpan.hours(1))

        let diff = PlatformScheduleDiff.between(desired: [entry], existing: [stale])

        XCTAssertEqual(diff.toCancel, [entry.stageID])
        XCTAssertEqual(diff.toSchedule.map(\.stageID), [entry.stageID])
        XCTAssertTrue(diff.unchanged.isEmpty)
    }

    /// Sub-second differences come from rounding a `Date` through the OS and
    /// back. Treating them as changes would make every pass rewrite every
    /// request — a reminder that is briefly not scheduled, on every foreground.
    func testSubSecondDriftIsNotAChange() {
        let entry = desired(at: now.addingTimeInterval(TimeSpan.hours(1)))
        var jittered = existing(for: entry)
        jittered.fireDate = entry.fireDate.addingTimeInterval(0.4)

        let diff = PlatformScheduleDiff.between(desired: [entry], existing: [jittered])
        XCTAssertEqual(diff.unchanged, [entry.stageID])
    }

    /// A wording change is not worth tearing down a notification for. Only
    /// time, loudness, channel and revision decide.
    func testADifferentBodyIsNotAChange() {
        var entry = desired(at: now.addingTimeInterval(TimeSpan.hours(1)))
        let current = existing(for: entry)
        entry.body = "Reworded, but the same reminder at the same moment"

        let diff = PlatformScheduleDiff.between(desired: [entry], existing: [current])
        XCTAssertEqual(diff.unchanged, [entry.stageID])
    }

    func testAChangedEscalationIsAChange() {
        let entry = desired(at: now.addingTimeInterval(TimeSpan.hours(1)), escalation: .insistent)
        var quieter = existing(for: entry)
        quieter.escalation = .gentle

        let diff = PlatformScheduleDiff.between(desired: [entry], existing: [quieter])
        XCTAssertEqual(diff.toSchedule.count, 1)
        XCTAssertEqual(diff.toCancel, [entry.stageID])
    }

    /// Section 17. A request scheduled under an older revision describes a plan
    /// that has since been replaced, even if its date happens to be unchanged.
    func testAStaleRevisionIsRescheduled() {
        let entry = desired(at: now.addingTimeInterval(TimeSpan.hours(1)), revision: 5)
        var older = existing(for: entry)
        older.revision = 4

        let diff = PlatformScheduleDiff.between(desired: [entry], existing: [older])
        XCTAssertEqual(diff.toSchedule.count, 1)
    }

    /// A request from a build that predates revisions cannot be proven current,
    /// so it is replaced rather than trusted.
    func testARequestWithNoRecordedRevisionIsReplaced() {
        let entry = desired(at: now.addingTimeInterval(TimeSpan.hours(1)), revision: 2)
        var unknown = existing(for: entry)
        unknown.revision = nil

        let diff = PlatformScheduleDiff.between(desired: [entry], existing: [unknown])
        XCTAssertEqual(diff.toSchedule.count, 1)
        XCTAssertEqual(diff.toCancel, [entry.stageID])
    }

    /// Sections 57 and 58: the completed task's leftover request, the switched
    /// off routine's future occurrences. What iOS holds is never evidence that
    /// the domain still wants it.
    func testAnUnwantedRequestIsCancelled() {
        let orphan = ExistingScheduleEntry(
            stageID: ReminderStage.ID(),
            fireDate: now.addingTimeInterval(TimeSpan.hours(3)),
            channel: .notification,
            escalation: .standard,
            revision: 1
        )

        let diff = PlatformScheduleDiff.between(desired: [], existing: [orphan])

        XCTAssertEqual(diff.toCancel, [orphan.stageID])
        XCTAssertTrue(diff.toSchedule.isEmpty)
    }

    /// Section 59. The same inputs produce the same diff, so a pass is
    /// reproducible and a log of one is comparable between runs.
    func testTheDiffIsDeterministicRegardlessOfInputOrder() {
        let first = desired(at: now.addingTimeInterval(TimeSpan.hours(3)))
        let second = desired(at: now.addingTimeInterval(TimeSpan.hours(1)))
        let third = desired(at: now.addingTimeInterval(TimeSpan.hours(2)))

        let one = PlatformScheduleDiff.between(desired: [first, second, third], existing: [])
        let two = PlatformScheduleDiff.between(desired: [third, first, second], existing: [])

        XCTAssertEqual(one.toSchedule.map(\.stageID), two.toSchedule.map(\.stageID))
        XCTAssertEqual(
            one.toSchedule.map(\.fireDate),
            [second.fireDate, third.fireDate, first.fireDate],
            "the diff should be ordered by when the reminders actually fire"
        )
    }

    /// Alarms and notifications are different channels with different meanings
    /// (section 65), so a stage that moved between them is not the same request.
    func testAChangedChannelIsAChange() {
        let entry = desired(at: now.addingTimeInterval(TimeSpan.hours(1)), escalation: .alarm)
        var asNotification = existing(for: entry)
        asNotification.channel = .notification

        let diff = PlatformScheduleDiff.between(desired: [entry], existing: [asNotification])
        XCTAssertEqual(diff.toSchedule.count, 1)
    }

    // MARK: Fixtures

    private func desired(
        at fireDate: Date,
        escalation: EscalationLevel = .standard,
        revision: Int = 1
    ) -> DesiredScheduleEntry {
        DesiredScheduleEntry(
            stageID: ReminderStage.ID(),
            taskID: TaskItem.ID(),
            planID: ReminderPlan.ID(),
            fireDate: fireDate,
            channel: escalation >= .alarm ? .alarm : .notification,
            title: "Pay the electricity bill",
            body: "Still open",
            escalation: escalation,
            requiresConfirmation: true,
            revision: revision
        )
    }

    private func existing(for entry: DesiredScheduleEntry) -> ExistingScheduleEntry {
        ExistingScheduleEntry(
            stageID: entry.stageID,
            fireDate: entry.fireDate,
            channel: entry.channel,
            escalation: entry.escalation,
            revision: entry.revision
        )
    }
}
