import Foundation

/// How hot the device is.
///
/// Mirrors `ProcessInfo.ThermalState` without importing it, so the policy that
/// reads it stays testable on a machine that has no such concept (section 119).
public enum DeviceThermalState: Int, Hashable, Sendable, Comparable, CaseIterable {
    case nominal = 0
    case fair = 1
    case serious = 2
    case critical = 3

    public static func < (lhs: DeviceThermalState, rhs: DeviceThermalState) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Whether starting a long inference now is a reasonable thing to do.
    ///
    /// The app does not throttle, reschedule or fight the system — section 119
    /// is explicit that overriding thermal management is not wanted. It warns,
    /// and at `critical` it declines to start something that would take
    /// seconds of sustained GPU work.
    public var permitsInference: Bool { self != .critical }
}

/// What the device has, as the compatibility check needs to see it.
///
/// A protocol rather than direct `ProcessInfo` calls for one reason worth
/// stating: section 91 asks for the "8 GB device accepts a 2 GB model, 3 GB
/// device does not" behaviour to be *tested*, and a test that reads the CI
/// machine's real RAM asserts whatever GitHub happened to allocate that
/// morning. Injected, the same test asserts the policy.
public protocol DeviceResourceProvider: Sendable {
    /// Total physical RAM. Not what the app may use — see
    /// ``LocalModelResourceEstimator``.
    var physicalMemoryBytes: Int64 { get }
    /// Free space the app could actually write to, right now.
    ///
    /// Deliberately a function and not a cached property: storage changes while
    /// the user is looking at the screen (section 115).
    func availableStorageBytes() -> Int64
    var thermalState: DeviceThermalState { get }
    /// Cores available for inference threads.
    var processorCount: Int { get }
}

/// The real device.
public struct SystemDeviceResources: DeviceResourceProvider {
    /// Where free space is measured. The models directory's volume, because
    /// that is the volume the file has to fit on.
    private let volumeURL: URL

    public init(volumeURL: URL? = nil) {
        self.volumeURL = volumeURL
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
    }

    public var physicalMemoryBytes: Int64 {
        Int64(ProcessInfo.processInfo.physicalMemory)
    }

    public func availableStorageBytes() -> Int64 {
        // `volumeAvailableCapacityForImportantUsageKey` is the right key and not
        // the obvious one. It reports what iOS would free up for something the
        // user asked for — purgeable caches included — which is exactly what a
        // model download is. `volumeAvailableCapacityKey` under-reports on a
        // phone that is full of evictable content and would refuse downloads
        // that would in fact have succeeded.
        #if os(iOS) || os(macOS) || os(tvOS) || os(watchOS)
        if let values = try? volumeURL.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ), let capacity = values.volumeAvailableCapacityForImportantUsage {
            return Int64(capacity)
        }
        #endif
        if let attributes = try? FileManager.default.attributesOfFileSystem(
            forPath: volumeURL.path
        ), let free = attributes[.systemFreeSize] as? NSNumber {
            return free.int64Value
        }
        return 0
    }

    public var thermalState: DeviceThermalState {
        #if os(iOS) || os(macOS) || os(tvOS) || os(watchOS)
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .fair
        }
        #else
        return .nominal
        #endif
    }

    public var processorCount: Int {
        ProcessInfo.processInfo.activeProcessorCount
    }
}

/// A device described by hand. For tests, previews and the dev harness.
public struct FixedDeviceResources: DeviceResourceProvider {
    public var physicalMemoryBytes: Int64
    public var storageBytes: Int64
    public var thermalState: DeviceThermalState
    public var processorCount: Int

    public init(
        physicalMemoryBytes: Int64,
        storageBytes: Int64,
        thermalState: DeviceThermalState = .nominal,
        processorCount: Int = 6
    ) {
        self.physicalMemoryBytes = physicalMemoryBytes
        self.storageBytes = storageBytes
        self.thermalState = thermalState
        self.processorCount = processorCount
    }

    public func availableStorageBytes() -> Int64 { storageBytes }

    // Named after what they represent rather than after specific phones, which
    // would date badly and imply a precision this does not have.
    public static let smallPhone = FixedDeviceResources(
        physicalMemoryBytes: 3 * .gigabyte,
        storageBytes: 8 * .gigabyte
    )
    public static let midPhone = FixedDeviceResources(
        physicalMemoryBytes: 6 * .gigabyte,
        storageBytes: 32 * .gigabyte
    )
    public static let largePhone = FixedDeviceResources(
        physicalMemoryBytes: 8 * .gigabyte,
        storageBytes: 64 * .gigabyte
    )
}

extension Int64 {
    /// Binary gigabytes, because that is what `physicalMemory` reports in.
    public static let gigabyte: Int64 = 1024 * 1024 * 1024
    public static let megabyte: Int64 = 1024 * 1024
}
