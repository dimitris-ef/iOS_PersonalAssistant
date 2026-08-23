import Foundation

/// A projection of application state, prepared for one system surface.
///
/// ## What a snapshot is for
///
/// A widget process cannot open the app's database, run `DailyPriorityRanker`,
/// resolve a `ReminderPlan` and decide what "up next" means — and it must not
/// try. Section 33: the main application does that work once, writes the
/// answer, and every surface reads it.
///
/// ## What a snapshot is not
///
/// Not a source of truth. Section 5: SwiftData remains authoritative and a
/// snapshot is a cache that can be rebuilt from it at any time. Deleting every
/// snapshot file costs the user one widget refresh and nothing else.
public protocol SystemSurfaceSnapshot: Codable, Sendable, Equatable {
    /// The file name inside the shared container. Stable, and unique per kind.
    static var storageKey: String { get }
    /// The schema this value was written with.
    var snapshotVersion: Int { get }
    /// When the main app built it.
    var generatedAt: Date { get }
    /// After this, the content is known to be stale. Nil when it does not go
    /// off — a task list is wrong only when something changes it, whereas a
    /// countdown is wrong the moment it passes.
    var validUntil: Date? { get }
}

extension SystemSurfaceSnapshot {
    /// The version this build writes.
    ///
    /// Section 71. Bumped when the *meaning* of a field changes, not when one
    /// is added — an added optional is readable by an older build, which is the
    /// whole reason to prefer adding one.
    public static var currentVersion: Int { 1 }

    /// Whether a reader from this build should trust the content.
    ///
    /// A *newer* snapshot is refused rather than guessed at: during an app
    /// update the extension binary and the app binary are briefly different
    /// versions, and an extension that half-understands a future format is how
    /// a widget shows something wrong rather than showing nothing.
    public var isReadable: Bool { snapshotVersion <= Self.currentVersion }

    public func isFresh(at date: Date) -> Bool {
        guard let validUntil else { return true }
        return date < validUntil
    }
}

/// Why a snapshot could not be read.
///
/// Every case is recoverable by showing a placeholder. Section 73: an
/// unreadable projection is never a reason to touch the authoritative store.
public enum SystemSurfaceStoreError: Error, Hashable, Sendable {
    /// Nothing has been written yet. The normal state before the app's first
    /// launch, and not an error worth reporting to anyone.
    case missing
    /// The bytes are not valid JSON, or not this shape. A half-written file, a
    /// truncated write, or a build that wrote something else entirely.
    case corrupt
    /// Written by a newer build than this one.
    case unsupportedVersion(found: Int, supported: Int)
    /// The shared container is not reachable — no App Group entitlement, or a
    /// keyboard without Full Access.
    case containerUnavailable
}
