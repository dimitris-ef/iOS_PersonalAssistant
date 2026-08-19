import Foundation

/// Domain identifiers derived from Apple's, deterministically.
///
/// ## The problem this solves
///
/// The domain keys a calendar event by `CalendarItem.ID`, a UUID this app
/// owns. EventKit keys the same event by `eventIdentifier`, a string EventKit
/// owns. `CalendarService.event(id:)` is given the first and has to find the
/// second, and there is no repository of calendar events to look it up in — the
/// user's calendar *is* the store.
///
/// Inventing a fresh UUID each time an event is read would make identifiers
/// unstable: the same appointment would have a different id after every
/// refresh, and `TaskItem.linkedCalendarItemID` would point at nothing an hour
/// later. Storing a mapping table instead means a second source of truth that
/// can be lost, and that has to be migrated and reconciled.
///
/// So the domain id is *derived* from the external one. Same event, same id,
/// on every read, in every launch, forever — with no table to keep.
///
/// ## Why not a real UUIDv5
///
/// Namespaced UUIDv5 is the textbook answer and it needs SHA-1, which on Apple
/// platforms means CryptoKit, which does not exist on Linux, which would put
/// this file behind a `canImport` guard and take the derivation out of reach of
/// the tests. The hash below is not cryptographic and does not need to be: this
/// is an identifier for events on one person's phone, not a security boundary.
/// Nothing is authenticated by it and nothing is authorised by it. What it has
/// to be is *stable* and *well distributed*, and FNV-1a is both.
///
/// The result is stamped with the RFC 4122 version and variant bits so it is a
/// well-formed UUID that anything reading it will treat as version 5, rather
/// than sixteen arbitrary bytes that happen to fit.
public enum AppleExternalIdentity {

    /// The UUID for one external identifier within one namespace.
    ///
    /// `namespace` keeps event ids and reminder ids apart. Without it an
    /// EventKit calendar item identifier — which is the same string for an
    /// event and for a reminder in some EventKit versions — could produce one
    /// UUID standing for two different things.
    public static func domainUUID(namespace: String, externalIdentifier: String) -> UUID {
        let seed = namespace + "\u{0}" + externalIdentifier

        // Two independent FNV-1a passes give the 128 bits a UUID needs. The
        // second runs over the reversed bytes with a different offset basis so
        // the halves cannot move together for inputs that differ only in their
        // tail — which is exactly how EventKit identifiers differ.
        let high = fnv1a(seed.utf8, offsetBasis: 0xcbf2_9ce4_8422_2325)
        let low = fnv1a(seed.utf8.reversed(), offsetBasis: 0x8422_2325_cbf2_9ce4)

        var bytes = [UInt8]()
        bytes.reserveCapacity(16)
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(truncatingByte(high >> UInt64(shift)))
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(truncatingByte(low >> UInt64(shift)))
        }

        // Version 5, variant RFC 4122.
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80

        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// The namespace for EventKit events.
    public static let calendarNamespace = "assistant.eventkit.event"
    /// The namespace for EventKit reminders.
    public static let reminderNamespace = "assistant.eventkit.reminder"

    private static func fnv1a<Bytes: Sequence>(
        _ bytes: Bytes,
        offsetBasis: UInt64
    ) -> UInt64 where Bytes.Element == UInt8 {
        let prime: UInt64 = 0x100_0000_01b3
        var hash = offsetBasis
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return hash
    }

    private static func truncatingByte(_ value: UInt64) -> UInt8 {
        UInt8(value & 0xFF)
    }
}
