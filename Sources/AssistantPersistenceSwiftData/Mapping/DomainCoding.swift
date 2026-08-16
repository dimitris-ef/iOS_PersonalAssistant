#if canImport(SwiftData)

import AssistantDomain
import Foundation

// Shared pieces used by every mapper.
//
// The mappers are deliberately explicit and hand-written. A generic
// reflection-based mapper would be shorter and would also make every future
// schema change silent: renaming a domain property would quietly stop
// persisting it. Here, the compiler points at the mapper.

/// Decodes a `RawRepresentable` enum from storage, failing loudly.
///
/// A raw value we do not recognise means the store was written by a version
/// that knew something this one does not. That is a real event worth an error,
/// not something to paper over with a default that silently rewrites the
/// user's data on the next save.
func decodeEnum<T: RawRepresentable>(
    _ type: T.Type,
    from raw: T.RawValue,
    entity: String,
    field: String
) throws -> T {
    guard let value = T(rawValue: raw) else {
        throw PersistenceError.mappingFailed(
            entity: entity,
            detail: "\(field) holds an unrecognised value"
        )
    }
    return value
}

extension TimeOfDay {
    /// Rebuilds a time of day from two nullable columns.
    ///
    /// A named factory rather than a failable `init`, so it can never be
    /// confused with `TimeOfDay(hour:minute:)` at a call site where both would
    /// type-check — the difference between them is whether "no wake time"
    /// comes back as `nil` or as midnight, and midnight is a real time someone
    /// could have chosen.
    static func from(hour: Int?, minute: Int?) -> TimeOfDay? {
        guard let hour else { return nil }
        return TimeOfDay(hour: hour, minute: minute ?? 0)
    }
}

// MARK: - Discriminators
//
// String cases for the enums that carry associated values. They are spelled out
// as constants rather than derived, because these strings are on disk: renaming
// a Swift case must not silently change what a stored row means.

enum TimingKindColumn {
    static let fixed = "fixed"
    static let flexible = "flexible"
    static let dueBy = "dueBy"
    static let unscheduled = "unscheduled"
}

enum RecurrenceKindColumn {
    static let daily = "daily"
    static let weekly = "weekly"
    static let monthly = "monthly"
    static let yearly = "yearly"
}

enum AnchorKindColumn {
    static let moment = "moment"
    static let deadline = "deadline"
    static let window = "window"
    static let unscheduled = "unscheduled"
}

enum OffsetKindColumn {
    static let beforeAnchor = "beforeAnchor"
    static let afterAnchor = "afterAnchor"
    static let daysBefore = "daysBefore"
    static let morningOf = "morningOf"
    static let absolute = "absolute"
}

enum ReferenceKindColumn {
    static let task = "task"
    static let calendarItem = "calendarItem"
    static let freeform = "freeform"
}

enum OutcomeKindColumn {
    static let executed = "executed"
    static let simulated = "simulated"
    static let awaitingConfirmation = "awaitingConfirmation"
    static let denied = "denied"
    static let failed = "failed"
    static let unsupported = "unsupported"
}

#endif
