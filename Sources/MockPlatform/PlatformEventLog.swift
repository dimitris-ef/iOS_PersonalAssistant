import AssistantPlatform
import Foundation

/// Records everything the mock services were asked to do.
///
/// The development harness prints this so we can see the assistant's effects
/// without any of them being real. Every entry carries its fidelity, so the
/// output can never be mistaken for something that happened on a phone.
public actor PlatformEventLog {
    public struct Entry: Hashable, Sendable {
        public let timestamp: Date
        public let platformName: String
        public let fidelity: PlatformFidelity
        public let description: String

        public init(
            timestamp: Date,
            platformName: String,
            fidelity: PlatformFidelity,
            description: String
        ) {
            self.timestamp = timestamp
            self.platformName = platformName
            self.fidelity = fidelity
            self.description = description
        }

        /// e.g. `[simulated:MockCalendar] Calendar event created: Haircut — Sun 22:00`
        public var formatted: String {
            "[\(fidelity.rawValue):\(platformName)] \(description)"
        }
    }

    private var entries: [Entry] = []

    public init() {}

    public func record(_ receipt: PlatformReceipt, at date: Date = Date()) {
        entries.append(
            Entry(
                timestamp: date,
                platformName: receipt.platformName,
                fidelity: receipt.fidelity,
                description: receipt.description
            )
        )
    }

    public func allEntries() -> [Entry] { entries }

    public func drain() -> [Entry] {
        let current = entries
        entries.removeAll()
        return current
    }

    public func clear() { entries.removeAll() }
}
