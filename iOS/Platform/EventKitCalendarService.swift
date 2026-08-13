// TODO-XCODE: this file is part of the iOS app target, not the Swift package.
// It does not compile during Windows-stage development.

import AssistantDomain
import AssistantPlatform
import EventKit
import Foundation

/// EventKit-backed calendar.
///
/// Nothing here is implemented — EventKit does not exist outside an Apple SDK,
/// and pretending otherwise would produce an app that silently drops the user's
/// appointments. Note that `fidelity` stays `.simulated` until the methods are
/// real: the value that travels up to the user must never say `.live` while the
/// implementation is a stub.
actor EventKitCalendarService: CalendarService {
    nonisolated var platformName: String { "EventKit" }
    nonisolated var fidelity: PlatformFidelity { .simulated } // TODO-XCODE: .live once implemented

    private let store = EKEventStore()

    func createEvent(
        _ item: CalendarItem
    ) async throws -> (item: CalendarItem, receipt: PlatformReceipt) {
        // TODO-XCODE:
        //   1. Ensure write access (`requestWriteOnlyAccessToEvents`).
        //   2. Build an `EKEvent` on `store.defaultCalendarForNewEvents`.
        //   3. Map `item.recurrence` onto `EKRecurrenceRule`.
        //   4. Save, then return `event.eventIdentifier` as `externalIdentifier`.
        throw PlatformError.notAvailable(capability: .calendar, reason: "TODO-XCODE: EventKit not implemented")
    }

    func updateEvent(
        _ item: CalendarItem
    ) async throws -> (item: CalendarItem, receipt: PlatformReceipt) {
        // TODO-XCODE: fetch by `externalIdentifier`, apply changes, save.
        throw PlatformError.notAvailable(capability: .calendar, reason: "TODO-XCODE: EventKit not implemented")
    }

    func deleteEvent(id: CalendarItem.ID) async throws -> PlatformReceipt {
        // TODO-XCODE: fetch by `externalIdentifier`, remove, save.
        throw PlatformError.notAvailable(capability: .calendar, reason: "TODO-XCODE: EventKit not implemented")
    }

    func event(id: CalendarItem.ID) async throws -> CalendarItem? {
        // TODO-XCODE: `store.event(withIdentifier:)`, mapped back to CalendarItem.
        throw PlatformError.notAvailable(capability: .calendar, reason: "TODO-XCODE: EventKit not implemented")
    }

    func events(in window: TimeWindow) async throws -> [CalendarItem] {
        // TODO-XCODE: `store.predicateForEvents(withStart:end:calendars:)`.
        throw PlatformError.notAvailable(capability: .calendar, reason: "TODO-XCODE: EventKit not implemented")
    }
}
