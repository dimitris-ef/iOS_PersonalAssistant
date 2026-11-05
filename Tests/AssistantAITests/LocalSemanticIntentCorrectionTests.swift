import XCTest

@testable import AssistantAI

/// Build 24: "I have an appointment with a dentist, 18th of November, 6 p.m."
/// came back from the action model as a change to an existing appointment.
final class LocalSemanticIntentCorrectionTests: XCTestCase {

    private let misread = LocalSemanticAction(
        intent: .calendarUpdate,
        arguments: [.targetDescription: "dentist appointment"],
        requestedChanges: [.timeExpression: "18th of November, 6 p.m."]
    )

    func testStatingAnAppointmentBecomesANewEvent() {
        let corrected = LocalSemanticIntentCorrection.corrected(
            misread,
            userRequest: "I have an appointment with a dentist 18th of November, 6 p.m."
        )
        XCTAssertEqual(corrected.intent, .calendarCreate)
        XCTAssertEqual(corrected[.title], "dentist appointment")
        XCTAssertEqual(corrected[.timeExpression], "18th of November, 6 p.m.")
        XCTAssertTrue(corrected.requestedChanges.isEmpty)
    }

    func testARealChangeIsLeftAlone() {
        for sentence in [
            "Move the dentist appointment to 15 November, 5 p.m.",
            "Reschedule my dentist appointment to Friday",
            "Postpone the dentist to the 20th",
            "Change the dentist appointment to 6",
        ] {
            XCTAssertEqual(
                LocalSemanticIntentCorrection.corrected(misread, userRequest: sentence),
                misread,
                sentence
            )
        }
    }

    func testAnUpdateWithoutATimeIsLeftAlone() {
        let rename = LocalSemanticAction(
            intent: .calendarUpdate,
            arguments: [.targetDescription: "dentist"],
            requestedChanges: [.title: "check-up"]
        )
        XCTAssertEqual(
            LocalSemanticIntentCorrection.corrected(rename, userRequest: "the dentist is a check-up"),
            rename
        )
    }

    func testOtherIntentsAreNeverTouched() {
        let reminder = LocalSemanticAction(
            intent: .reminderCreate,
            arguments: [.title: "fix the bottles", .timeExpression: "in 10 minutes"]
        )
        XCTAssertEqual(
            LocalSemanticIntentCorrection.corrected(reminder, userRequest: "remind me in 10 minutes"),
            reminder
        )
    }

    func testDurationAndPlaceAreCarriedOver() {
        let withDetails = LocalSemanticAction(
            intent: .calendarUpdate,
            arguments: [.targetDescription: "dentist"],
            requestedChanges: [
                .timeExpression: "Friday at 5",
                .durationExpression: "an hour",
                .locationExpression: "Kifisia",
            ]
        )
        let corrected = LocalSemanticIntentCorrection.corrected(
            withDetails, userRequest: "dentist Friday at 5 for an hour in Kifisia"
        )
        XCTAssertEqual(corrected.intent, .calendarCreate)
        XCTAssertEqual(corrected[.durationExpression], "an hour")
        XCTAssertEqual(corrected[.locationExpression], "Kifisia")
    }
}
