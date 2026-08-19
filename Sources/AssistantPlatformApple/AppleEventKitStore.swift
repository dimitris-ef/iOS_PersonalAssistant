import AssistantDomain
import AssistantPlatform
import Foundation

#if canImport(EventKit)
import EventKit

/// The one `EKEventStore` in the app, and everything that touches it.
///
/// ## Why one actor rather than two services
///
/// Apple's guidance is a single `EKEventStore` for the process: creating them
/// per request is expensive and, worse, each one holds its own change
/// notifications and cached state. But `EKEventStore` and every object it
/// vends — `EKEvent`, `EKReminder`, `EKCalendar` — are reference types with no
/// `Sendable` conformance, so a store shared between two independent actors
/// would be a data race dressed up as a dependency.
///
/// So both services delegate here. This actor is the only place an EventKit
/// object exists, every method returns domain values, and nothing that crosses
/// its boundary is a class. Calendar and reminders remain separate services
/// with separate permissions above it; they simply share the one store, which
/// is what EventKit wants.
actor AppleEventKitStore {
    private let store = EKEventStore()

    /// Domain id → EventKit identifier, for events.
    ///
    /// A cache, not a record. Every entry can be rebuilt by reading the
    /// calendar again, because the domain id is *derived* from the EventKit
    /// one — see `AppleExternalIdentity`. That is what makes it safe for this
    /// to be empty after a relaunch: a miss triggers a rescan, not a loss.
    private var eventIdentifiers: [UUID: String] = [:]
    private var reminderIdentifiers: [UUID: String] = [:]

    // MARK: Authorization

    nonisolated func calendarAuthorization() -> AppleCalendarAuthorization {
        Self.map(EKEventStore.authorizationStatus(for: .event))
    }

    nonisolated func reminderAuthorization() -> AppleReminderAuthorization {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .fullAccess: return .fullAccess
        // Reminders have no write-only tier of their own, so this case only
        // arises if the system ever reports one; full access is the closest
        // truthful reading.
        //
        // `.authorized`, the pre-iOS-17 spelling, is deliberately absent: the
        // SDK defines it as an alias *of* `.fullAccess` rather than a distinct
        // case, so listing it here would be a duplicate.
        case .writeOnly: return .fullAccess
        @unknown default: return .denied
        }
    }

    /// Asks for full calendar access, and only for full access.
    ///
    /// Write-only would be the smaller ask, and this layer deliberately does
    /// not make it. `CalendarService` declares `events(in:)` and
    /// `AssistantEngine` calls it on every single turn to build context: the
    /// assistant's whole reason for existing is knowing that there is already
    /// something at three o'clock before it agrees to anything. An app that
    /// held write-only access would answer that question with silence and
    /// advise confidently around an empty calendar.
    ///
    /// The user can still answer "Add Events Only", and iOS will. That arrives
    /// as `.writeOnly`, becomes `PermissionStatus.limited`, and is reported as
    /// partial access rather than quietly treated as either yes or no.
    func requestCalendarAccess() async -> AppleCalendarAuthorization {
        do {
            _ = try await store.requestFullAccessToEvents()
        } catch {
            // The throw carries an EventKit error whose description can quote
            // calendar state. Only the fact of failure is logged; the resulting
            // status is then read from the system, which is authoritative
            // anyway.
            ApplePlatformLog.error("Calendar access request failed")
        }
        return calendarAuthorization()
    }

    func requestReminderAccess() async -> AppleReminderAuthorization {
        do {
            _ = try await store.requestFullAccessToReminders()
        } catch {
            ApplePlatformLog.error("Reminder access request failed")
        }
        return reminderAuthorization()
    }

    private nonisolated static func map(
        _ status: EKAuthorizationStatus
    ) -> AppleCalendarAuthorization {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .fullAccess: return .fullAccess
        case .writeOnly: return .writeOnly
        // Not a guess and not an optimistic default: an authorization case a
        // future OS adds is treated as no access until this code understands
        // it. Failing closed on permissions is the only safe direction.
        @unknown default: return .denied
        }
    }

    // MARK: Events

    func createEvent(_ item: CalendarItem) throws -> (CalendarItem, PlatformReceipt) {
        guard let calendar = store.defaultCalendarForNewEvents else {
            throw PlatformError.notAvailable(
                capability: .calendar,
                reason: "No calendar is available to add events to."
            )
        }

        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        apply(item, to: event)

        do {
            try store.save(event, span: .futureEvents, commit: true)
        } catch {
            throw PlatformError.underlying("The event could not be saved to the calendar.")
        }

        guard let externalIdentifier = event.eventIdentifier else {
            throw PlatformError.underlying("The calendar did not return an identifier for the event.")
        }

        var saved = Self.item(from: event, externalIdentifier: externalIdentifier)
        // Carried across because EventKit has nowhere to put them. See
        // `apply(_:to:)`.
        saved.importance = item.importance
        saved.travelDuration = item.travelDuration
        saved.preparationDuration = item.preparationDuration

        remember(domainID: saved.id.rawValue, external: externalIdentifier, isEvent: true)
        // Also under the id the caller asked for, so a follow-up call naming
        // the requested id resolves rather than 404ing on the identifier this
        // layer replaced it with.
        remember(domainID: item.id.rawValue, external: externalIdentifier, isEvent: true)

        return (saved, receipt(
            "Added to your calendar: \(saved.title)",
            identifier: externalIdentifier
        ))
    }

    func updateEvent(_ item: CalendarItem) throws -> (CalendarItem, PlatformReceipt) {
        guard let event = try eventObject(for: item.id) else {
            throw PlatformError.notFound(identifier: item.id.description)
        }
        apply(item, to: event)

        do {
            try store.save(event, span: .futureEvents, commit: true)
        } catch {
            throw PlatformError.underlying("The change could not be saved to the calendar.")
        }

        let externalIdentifier = event.eventIdentifier ?? item.externalIdentifier ?? ""
        var saved = Self.item(from: event, externalIdentifier: externalIdentifier)
        saved.importance = item.importance
        saved.travelDuration = item.travelDuration
        saved.preparationDuration = item.preparationDuration

        return (saved, receipt("Updated in your calendar: \(saved.title)", identifier: externalIdentifier))
    }

    func deleteEvent(id: CalendarItem.ID) throws -> PlatformReceipt {
        guard let event = try eventObject(for: id) else {
            throw PlatformError.notFound(identifier: id.description)
        }
        let title = event.title ?? "Event"
        do {
            try store.remove(event, span: .futureEvents, commit: true)
        } catch {
            throw PlatformError.underlying("The event could not be removed from the calendar.")
        }
        eventIdentifiers.removeValue(forKey: id.rawValue)
        return receipt("Removed from your calendar: \(title)")
    }

    func event(id: CalendarItem.ID) throws -> CalendarItem? {
        guard let event = try eventObject(for: id) else { return nil }
        guard let externalIdentifier = event.eventIdentifier else { return nil }
        return Self.item(from: event, externalIdentifier: externalIdentifier)
    }

    func events(in window: TimeWindow) throws -> [CalendarItem] {
        try requireCalendarRead()
        let predicate = store.predicateForEvents(
            withStart: window.start,
            end: window.end,
            calendars: nil
        )
        let events = store.events(matching: predicate)

        var items: [CalendarItem] = []
        items.reserveCapacity(events.count)
        for event in events {
            guard let externalIdentifier = event.eventIdentifier else { continue }
            let item = Self.item(from: event, externalIdentifier: externalIdentifier)
            remember(domainID: item.id.rawValue, external: externalIdentifier, isEvent: true)
            items.append(item)
        }
        return items.sorted { $0.start < $1.start }
    }

    // MARK: Reminders

    func createReminder(_ item: ReminderItem) throws -> (ReminderItem, PlatformReceipt) {
        guard let list = reminderList(named: item.listName) else {
            throw PlatformError.notAvailable(
                capability: .reminders,
                reason: "No reminders list is available to add to."
            )
        }

        let reminder = EKReminder(eventStore: store)
        reminder.calendar = list
        reminder.title = item.title
        reminder.notes = item.notes
        if let due = item.dueDate {
            reminder.dueDateComponents = Self.dateComponents(from: due)
            // Without an alarm a due date in Reminders is decoration: the list
            // shows it and nothing ever fires. The assistant's own follow-up
            // ladder does the chasing, but a reminder the user opens in Apple's
            // app should behave the way they expect it to there.
            reminder.addAlarm(EKAlarm(absoluteDate: due))
        }
        reminder.isCompleted = item.isCompleted

        do {
            try store.save(reminder, commit: true)
        } catch {
            throw PlatformError.underlying("The reminder could not be saved.")
        }

        let externalIdentifier = reminder.calendarItemIdentifier
        var saved = Self.item(from: reminder, externalIdentifier: externalIdentifier)
        saved.relatedTaskID = item.relatedTaskID

        remember(domainID: saved.id.rawValue, external: externalIdentifier, isEvent: false)
        remember(domainID: item.id.rawValue, external: externalIdentifier, isEvent: false)

        return (saved, receipt(
            "Added to your reminders: \(saved.title)",
            identifier: externalIdentifier
        ))
    }

    func completeReminder(id: ReminderItem.ID) throws -> PlatformReceipt {
        guard let reminder = try reminderObject(for: id) else {
            throw PlatformError.notFound(identifier: id.description)
        }
        reminder.isCompleted = true
        do {
            try store.save(reminder, commit: true)
        } catch {
            throw PlatformError.underlying("The reminder could not be marked complete.")
        }
        return receipt("Marked complete in your reminders: \(reminder.title ?? "Reminder")")
    }

    func reminders(includingCompleted: Bool) async throws -> [ReminderItem] {
        try requireReminderAccess()
        let predicate = includingCompleted
            ? store.predicateForReminders(in: nil)
            : store.predicateForIncompleteReminders(
                withDueDateStarting: nil,
                ending: nil,
                calendars: nil
            )

        // Mapped to domain values *inside* the completion handler, before the
        // continuation resumes. `EKReminder` is a non-Sendable class, and this
        // is what stops one crossing a concurrency boundary.
        let items: [ReminderItem] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                let mapped = (reminders ?? []).map {
                    Self.item(from: $0, externalIdentifier: $0.calendarItemIdentifier)
                }
                continuation.resume(returning: mapped)
            }
        }

        for item in items {
            if let external = item.externalIdentifier {
                remember(domainID: item.id.rawValue, external: external, isEvent: false)
            }
        }
        return items
    }

    // MARK: Lookup

    /// The EventKit event behind a domain id, rescanning once if unknown.
    ///
    /// The rescan is what makes the derived-identifier scheme work across
    /// launches. On a cold start the cache is empty, so the first lookup for
    /// an event nobody has read yet misses; scanning a two-year window and
    /// re-deriving every id fills it in. EventKit refuses predicates spanning
    /// more than four years, and two is comfortably inside that.
    private func eventObject(for id: CalendarItem.ID) throws -> EKEvent? {
        try requireCalendarRead()
        if let external = eventIdentifiers[id.rawValue],
           let event = store.event(withIdentifier: external) {
            return event
        }

        let now = Date()
        _ = try events(in: TimeWindow(
            start: now.addingTimeInterval(-TimeSpan.days(365)),
            end: now.addingTimeInterval(TimeSpan.days(365))
        ))

        guard let external = eventIdentifiers[id.rawValue] else { return nil }
        return store.event(withIdentifier: external)
    }

    private func reminderObject(for id: ReminderItem.ID) throws -> EKReminder? {
        try requireReminderAccess()
        guard let external = reminderIdentifiers[id.rawValue] else { return nil }
        return store.calendarItem(withIdentifier: external) as? EKReminder
    }

    private func reminderList(named name: String?) -> EKCalendar? {
        guard let name, !name.isEmpty else {
            return store.defaultCalendarForNewReminders()
        }
        let match = store.calendars(for: .reminder).first {
            $0.title.caseInsensitiveCompare(name) == .orderedSame
        }
        // Falling back to the default list rather than failing. A list name
        // comes from a language model repeating what the user said, and
        // "Groceries" not existing is not a reason to lose the reminder — it
        // ends up somewhere the user will actually see it.
        return match ?? store.defaultCalendarForNewReminders()
    }

    // MARK: Guards

    /// Reads need full access, and saying so is the point.
    ///
    /// Write-only access makes `store.events(matching:)` return an empty array
    /// rather than fail. Left unguarded, this app would report an empty
    /// schedule to a user whose day is full — the single most damaging thing a
    /// planning assistant can get wrong — and every layer above would believe
    /// it. So the emptiness is turned back into an error here.
    private func requireCalendarRead() throws {
        switch calendarAuthorization() {
        case .fullAccess:
            return
        case .writeOnly:
            throw PlatformError.notAvailable(
                capability: .calendar,
                reason: "Reading your calendar needs full access; only adding events was allowed."
            )
        case .denied, .restricted, .notDetermined:
            throw PlatformError.permissionDenied(capability: .calendar)
        }
    }

    private func requireReminderAccess() throws {
        guard reminderAuthorization() == .fullAccess else {
            throw PlatformError.permissionDenied(capability: .reminders)
        }
    }

    // MARK: Mapping

    private func apply(_ item: CalendarItem, to event: EKEvent) {
        event.title = item.title
        event.startDate = item.start
        event.endDate = item.end
        event.isAllDay = item.isAllDay
        event.location = item.location
        event.notes = item.notes

        // `importance`, `travelDuration` and `preparationDuration` are not
        // written. EventKit has no field for any of them on an event, and the
        // available near-misses would be worse than dropping them: encoding
        // preparation time into `notes` would put machine text in front of the
        // user in Apple's Calendar app, and moving `startDate` earlier to
        // account for travel would tell everyone in a shared calendar that the
        // meeting starts at a time it does not.
        //
        // They stay in the app's own store, where the planner reads them. The
        // returned item carries them back so no caller sees them vanish.

        for existing in event.recurrenceRules ?? [] {
            event.removeRecurrenceRule(existing)
        }
        if let recurrence = item.recurrence,
           let rule = Self.recurrenceRule(for: recurrence) {
            event.addRecurrenceRule(rule)
        }
    }

    private nonisolated static func item(
        from event: EKEvent,
        externalIdentifier: String
    ) -> CalendarItem {
        CalendarItem(
            id: CalendarItem.ID(AppleExternalIdentity.domainUUID(
                namespace: AppleExternalIdentity.calendarNamespace,
                externalIdentifier: externalIdentifier
            )),
            title: event.title ?? "Untitled",
            start: event.startDate ?? Date(),
            end: event.endDate ?? event.startDate ?? Date(),
            isAllDay: event.isAllDay,
            location: event.location,
            notes: event.notes,
            externalIdentifier: externalIdentifier
        )
    }

    private nonisolated static func item(
        from reminder: EKReminder,
        externalIdentifier: String
    ) -> ReminderItem {
        ReminderItem(
            id: ReminderItem.ID(AppleExternalIdentity.domainUUID(
                namespace: AppleExternalIdentity.reminderNamespace,
                externalIdentifier: externalIdentifier
            )),
            title: reminder.title ?? "Untitled",
            notes: reminder.notes,
            dueDate: reminder.dueDateComponents.flatMap {
                Calendar.current.date(from: $0)
            },
            isCompleted: reminder.isCompleted,
            listName: reminder.calendar?.title,
            externalIdentifier: externalIdentifier
        )
    }

    private nonisolated static func dateComponents(from date: Date) -> DateComponents {
        Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
    }

    /// Built from the already-validated specification.
    ///
    /// `EKRecurrenceRule` raises an Objective-C exception for an interval below
    /// 1, which no `do/catch` in Swift can survive. `AppleRecurrenceMapping`
    /// clamps first, so nothing invalid reaches this initialiser.
    private nonisolated static func recurrenceRule(
        for rule: RecurrenceRule
    ) -> EKRecurrenceRule? {
        let spec = AppleRecurrenceMapping.specification(for: rule)

        let frequency: EKRecurrenceFrequency
        switch spec.frequency {
        case .daily: frequency = .daily
        case .weekly: frequency = .weekly
        case .monthly: frequency = .monthly
        case .yearly: frequency = .yearly
        }

        let days = spec.weekdays.compactMap { number -> EKRecurrenceDayOfWeek? in
            guard let weekday = EKWeekday(rawValue: number) else { return nil }
            return EKRecurrenceDayOfWeek(weekday)
        }

        return EKRecurrenceRule(
            recurrenceWith: frequency,
            interval: spec.interval,
            daysOfTheWeek: days.isEmpty ? nil : days,
            daysOfTheMonth: spec.dayOfMonth.map { [NSNumber(value: $0)] },
            monthsOfTheYear: nil,
            weeksOfTheYear: nil,
            daysOfTheYear: nil,
            setPositions: nil,
            end: nil
        )
    }

    // MARK: Bookkeeping

    private func remember(domainID: UUID, external: String, isEvent: Bool) {
        if isEvent {
            eventIdentifiers[domainID] = external
        } else {
            reminderIdentifiers[domainID] = external
        }
    }

    private func receipt(_ description: String, identifier: String? = nil) -> PlatformReceipt {
        PlatformReceipt(
            description: description,
            fidelity: .live,
            platformName: "EventKit",
            externalIdentifier: identifier
        )
    }
}
#endif
