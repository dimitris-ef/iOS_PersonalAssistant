import Foundation

/// An event on the user's calendar.
///
/// `externalIdentifier` is the handle given back by whatever actually stores the
/// event. On iOS that will be the EventKit identifier; on the mock platform it
/// is a locally generated string. The core never interprets it.
public struct CalendarItem: Identifiable, Hashable, Codable, Sendable {
    public typealias ID = Identifier<CalendarItem>

    public var id: ID
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var location: String?
    public var notes: String?
    public var importance: Importance
    public var travelDuration: TimeInterval?
    public var preparationDuration: TimeInterval?
    public var recurrence: RecurrenceRule?
    public var externalIdentifier: String?

    public init(
        id: ID = ID(),
        title: String,
        start: Date,
        end: Date,
        isAllDay: Bool = false,
        location: String? = nil,
        notes: String? = nil,
        importance: Importance = .normal,
        travelDuration: TimeInterval? = nil,
        preparationDuration: TimeInterval? = nil,
        recurrence: RecurrenceRule? = nil,
        externalIdentifier: String? = nil
    ) {
        self.id = id
        self.title = title
        self.start = start
        self.end = max(start, end)
        self.isAllDay = isAllDay
        self.location = location
        self.notes = notes
        self.importance = importance
        self.travelDuration = travelDuration
        self.preparationDuration = preparationDuration
        self.recurrence = recurrence
        self.externalIdentifier = externalIdentifier
    }

    /// The moment the user needs to leave, given travel time.
    public func leaveTime(defaultTravel: TimeInterval) -> Date {
        start.addingTimeInterval(-(travelDuration ?? defaultTravel))
    }
}
