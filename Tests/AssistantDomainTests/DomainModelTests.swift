import XCTest
@testable import AssistantDomain

final class DomainModelTests: XCTestCase {
    func testIdentifierRoundTripsThroughJSONAsAPlainString() throws {
        let id = Conversation.ID()
        // Wrapped in an array so the payload is not a top-level JSON fragment.
        let data = try JSONCoding.encoder.encode([id])
        let text = String(data: data, encoding: .utf8)

        XCTAssertEqual(text, "[\"\(id.rawValue.uuidString)\"]")
        XCTAssertEqual(try JSONCoding.decoder.decode([Conversation.ID].self, from: data), [id])
    }

    func testTimeOfDayResolvesOnTheGivenDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let resolved = TimeOfDay(hour: 8, minute: 30).resolved(on: day, calendar: calendar)

        let components = calendar.dateComponents([.hour, .minute], from: resolved)
        XCTAssertEqual(components.hour, 8)
        XCTAssertEqual(components.minute, 30)
        XCTAssertTrue(calendar.isDate(resolved, inSameDayAs: day))
    }

    func testDayWindowHandlesWrappingMidnight() {
        let quietHours = DayWindow(start: TimeOfDay(hour: 23), end: TimeOfDay(hour: 7))

        XCTAssertTrue(quietHours.contains(TimeOfDay(hour: 23, minute: 30)))
        XCTAssertTrue(quietHours.contains(TimeOfDay(hour: 2)))
        XCTAssertFalse(quietHours.contains(TimeOfDay(hour: 12)))
    }

    func testTaskStatusDistinguishesOutstandingFromTerminal() {
        XCTAssertTrue(TaskStatus.reminded.isOutstanding)
        XCTAssertTrue(TaskStatus.needsFollowUp.isOutstanding)
        XCTAssertTrue(TaskStatus.missed.isOutstanding)
        XCTAssertFalse(TaskStatus.completed.isOutstanding)
        XCTAssertFalse(TaskStatus.cancelled.isOutstanding)
    }

    /// The published tool schema declares these as string enums, so their JSON
    /// representation has to match or a model's arguments will not decode.
    func testImportanceAndEscalationEncodeAsStrings() throws {
        let importance = try JSONCoding.encoder.encode([Importance.high])
        XCTAssertEqual(String(data: importance, encoding: .utf8), "[\"high\"]")

        let escalation = try JSONCoding.encoder.encode([EscalationLevel.insistent])
        XCTAssertEqual(String(data: escalation, encoding: .utf8), "[\"insistent\"]")
    }

    func testEscalationSaturatesAtAlarm() {
        XCTAssertEqual(EscalationLevel.gentle.escalated, .standard)
        XCTAssertEqual(EscalationLevel.insistent.escalated, .alarm)
        XCTAssertEqual(EscalationLevel.alarm.escalated, .alarm)
    }

    func testTaskFilterMatchesOnStatusAndWindow() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let task = TaskItem(
            title: "Pay bill",
            status: .reminded,
            timing: .fixed(now.addingTimeInterval(Duration.hours(2))),
            createdAt: now
        )

        let inWindow = TaskFilter(
            statuses: [.reminded],
            window: TimeWindow(start: now, end: now.addingTimeInterval(Duration.day))
        )
        XCTAssertTrue(inWindow.matches(task))

        let wrongStatus = TaskFilter(statuses: [.completed])
        XCTAssertFalse(wrongStatus.matches(task))

        let outOfWindow = TaskFilter(
            window: TimeWindow(
                start: now.addingTimeInterval(Duration.days(3)),
                end: now.addingTimeInterval(Duration.days(4))
            )
        )
        XCTAssertFalse(outOfWindow.matches(task))
    }

    func testJSONValueDecodesIntoTypedValues() throws {
        struct Payload: Codable, Equatable {
            var title: String
            var count: Int
        }

        let json = JSONValue.object([
            "title": .string("Haircut"),
            "count": .number(3),
        ])

        XCTAssertEqual(try json.decode(as: Payload.self), Payload(title: "Haircut", count: 3))
        XCTAssertEqual(json["title"]?.stringValue, "Haircut")
    }

    func testJSONSchemaRendersObjectShape() {
        let schema = JSONSchema.object(
            properties: ["title": .string(description: "Name")],
            required: ["title"]
        )
        let rendered = schema.jsonValue()

        XCTAssertEqual(rendered["type"]?.stringValue, "object")
        XCTAssertEqual(rendered["required"]?.arrayValue?.first?.stringValue, "title")
        XCTAssertEqual(rendered["properties"]?["title"]?["type"]?.stringValue, "string")
    }
}
