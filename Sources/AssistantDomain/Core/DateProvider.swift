import Foundation

/// Supplies "now" and the calendar to use for date arithmetic.
///
/// Everything that reasons about time takes one of these rather than calling
/// `Date()` directly, so reminder planning is deterministic under test.
/// (Named `DateProvider` rather than `Clock` to avoid colliding with the
/// standard library's `Clock` protocol.)
public protocol DateProvider: Sendable {
    var now: Date { get }
    var calendar: Calendar { get }
}

public struct SystemDateProvider: DateProvider {
    public let calendar: Calendar

    public init(timeZone: TimeZone = .current) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.calendar = calendar
    }

    public var now: Date { Date() }
}

/// A date provider pinned to a fixed instant, for tests and the dev harness.
public struct FixedDateProvider: DateProvider {
    public let now: Date
    public let calendar: Calendar

    public init(now: Date, timeZone: TimeZone = TimeZone(identifier: "UTC") ?? .current) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.calendar = calendar
        self.now = now
    }
}
