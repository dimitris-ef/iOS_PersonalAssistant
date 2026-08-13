import AssistantDomain
import XCTest
@testable import AssistantTools

final class ToolRequestDecoderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private var decoder: ToolRequestDecoder {
        ToolRequestDecoder(dateProvider: FixedDateProvider(now: now))
    }

    private func isoString(_ offset: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: now.addingTimeInterval(offset))
    }

    func testDecodesAValidCalendarEventCall() throws {
        let arguments = JSONValue.object([
            "title": .string("Haircut"),
            "start": .string(isoString(TimeSpan.days(3))),
            "importance": .string("high"),
        ])

        let request = try decoder.decode(name: "createCalendarEvent", arguments: arguments)

        guard case .createCalendarEvent(let input) = request else {
            return XCTFail("Expected a calendar event request, got \(request)")
        }
        XCTAssertEqual(input.title, "Haircut")
        XCTAssertEqual(input.importance, .high)
        XCTAssertNil(input.eventID, "The model must not supply identifiers")
    }

    func testRejectsAnUnknownToolName() {
        XCTAssertThrowsError(
            try decoder.decode(name: "launchMissiles", arguments: .object([:]))
        ) { error in
            XCTAssertEqual(error as? ToolDecodingError, .unknownTool(name: "launchMissiles"))
        }
    }

    func testRejectsMalformedArguments() {
        // `start` is required and missing.
        XCTAssertThrowsError(
            try decoder.decode(
                name: "createCalendarEvent",
                arguments: .object(["title": .string("Haircut")])
            )
        ) { error in
            guard case .malformedArguments(let kind, _)? = error as? ToolDecodingError else {
                return XCTFail("Expected malformedArguments, got \(error)")
            }
            XCTAssertEqual(kind, .createCalendarEvent)
        }
    }

    func testRejectsAnEmptyTitle() {
        XCTAssertThrowsError(
            try decoder.decode(
                name: "createCalendarEvent",
                arguments: .object([
                    "title": .string("   "),
                    "start": .string(isoString(TimeSpan.days(1))),
                ])
            )
        ) { error in
            guard case .failedValidation(let kind, _)? = error as? ToolDecodingError else {
                return XCTFail("Expected failedValidation, got \(error)")
            }
            XCTAssertEqual(kind, .createCalendarEvent)
        }
    }

    func testRejectsAlarmsScheduledInThePast() {
        XCTAssertThrowsError(
            try decoder.decode(
                name: "createAlarm",
                arguments: .object([
                    "label": .string("Wake up"),
                    "fireDate": .string(isoString(-TimeSpan.hour)),
                ])
            )
        ) { error in
            guard case .failedValidation(let kind, _)? = error as? ToolDecodingError else {
                return XCTFail("Expected failedValidation, got \(error)")
            }
            XCTAssertEqual(kind, .createAlarm)
        }
    }

    func testBatchDecodingSeparatesAcceptedFromRejected() {
        let calls = [
            AIToolCallEnvelope(
                name: "storeMemory",
                arguments: .object([
                    "content": .string("Needs 30 minutes to get ready"),
                    "kind": .string("routine"),
                ])
            ),
            AIToolCallEnvelope(name: "notATool", arguments: .object([:])),
        ]

        let outcome = decoder.decode(calls)

        XCTAssertEqual(outcome.accepted.count, 1)
        XCTAssertEqual(outcome.rejected.count, 1)
        XCTAssertEqual(outcome.accepted.first?.request.kind, .storeMemory)
        XCTAssertEqual(outcome.rejected.first?.name, "notATool")
    }

    func testEveryToolKindHasASpecificationWithAMatchingName() {
        for kind in ToolKind.allCases {
            let specification = ToolCatalog.specification(for: kind)
            XCTAssertEqual(specification.name, kind.rawValue)
            XCTAssertFalse(specification.summary.isEmpty)
        }
        XCTAssertEqual(ToolCatalog.all.count, ToolKind.allCases.count)
    }
}

final class ToolAuthorizationTests: XCTestCase {
    private let authorizer = SettingsToolAuthorizer()

    func testReadOnlyToolsAreAlwaysAllowed() {
        var settings = AssistantSettings()
        settings.defaultAuthorization = .denied

        let authorization = authorizer.authorization(
            for: .getUpcomingSchedule(GetUpcomingScheduleInput()),
            settings: settings
        )
        XCTAssertEqual(authorization, .allowed)
    }

    func testDestructiveToolsRequireConfirmationByDefault() {
        let authorization = authorizer.authorization(
            for: .deleteCalendarEvent(DeleteCalendarEventInput(eventID: CalendarItem.ID())),
            settings: AssistantSettings()
        )
        XCTAssertEqual(authorization, .requiresConfirmation)
    }

    func testExplicitDenialWins() {
        var settings = AssistantSettings()
        settings.toolAuthorizations[.createAlarm] = .denied

        let authorization = authorizer.authorization(
            for: .createAlarm(CreateAlarmInput(label: "Wake up", fireDate: Date())),
            settings: settings
        )
        XCTAssertEqual(authorization, .denied)
    }
}
