import AssistantDomain
import XCTest

@testable import AssistantCore

/// Build 28: the Serres circuit event. Its reminder plan held one id and the
/// calendar another, so the card said "Event not found" and Up Next said "No
/// reminders are planned for this yet".
final class EventLinkRepairTests: XCTestCase {

    private let nineAM = Date(timeIntervalSince1970: 1_794_906_000)

    private func plan(_ title: String, at date: Date, event: CalendarItem.ID) -> ReminderPlan {
        ReminderPlan(
            subject: ReminderSubject(reference: .calendarItem(event), title: title, anchor: .moment(date)),
            stages: [],
            createdAt: date.addingTimeInterval(-86_400),
            generatedBy: "test"
        )
    }

    private func event(_ title: String, at date: Date) -> CalendarItem {
        CalendarItem(title: title, start: date, end: date.addingTimeInterval(3_600))
    }

    func testAnOrphanedPlanIsLinkedToItsEvent() {
        let planned = CalendarItem.ID()
        let serres = event("Serres Racing Circuit", at: nineAM)

        let links = EventLinkRepair.links(
            plans: [plan("Serres racing circuit", at: nineAM, event: planned)],
            events: [serres, event("Barber", at: nineAM.addingTimeInterval(-86_400))]
        )

        XCTAssertEqual(links, [EventLinkRepair.Link(existing: serres.id, appID: planned)])
    }

    func testAPlanThatAlreadyFindsItsEventIsLeftAlone() {
        let serres = event("Serres Racing Circuit", at: nineAM)
        let links = EventLinkRepair.links(
            plans: [plan("Serres Racing Circuit", at: nineAM, event: serres.id)],
            events: [serres]
        )
        XCTAssertTrue(links.isEmpty)
    }

    /// Two events that both match: a guess could attach the reminders to the
    /// wrong one, so nothing is linked.
    func testAnAmbiguousMatchIsNotLinked() {
        let links = EventLinkRepair.links(
            plans: [plan("Barber", at: nineAM, event: CalendarItem.ID())],
            events: [event("Barber", at: nineAM), event("Barber", at: nineAM.addingTimeInterval(30))]
        )
        XCTAssertTrue(links.isEmpty)
    }

    func testADifferentTitleOrTimeIsNotAMatch() {
        let planned = CalendarItem.ID()
        let links = EventLinkRepair.links(
            plans: [plan("Barber", at: nineAM, event: planned)],
            events: [event("Dentist", at: nineAM), event("Barber", at: nineAM.addingTimeInterval(7_200))]
        )
        XCTAssertTrue(links.isEmpty)
    }
}
