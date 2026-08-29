import AIProviderLocal
import Foundation
import Observation
import UIKit

/// The app's one diagnostic logger, plus everything only `iOS/` can see.
///
/// ## Why this lives here and not in the package
///
/// Three things the logger deliberately does not know about: `Bundle`,
/// `UIDevice`, and `UIApplication`'s notifications. Keeping them out means the
/// logger, the recovery scan, the pairing algorithm and the report are all
/// testable in a package target with no UIKit — which matters, because `iOS/`
/// has no test target and everything that ends up here is code no test will
/// ever see.
///
/// So this file is deliberately thin: it builds the header, owns the settings,
/// forwards two system notifications, and gets out of the way.
@MainActor
@Observable
final class LocalInferenceDiagnosticsCentre {

    let logger: LocalInferenceDiagnosticLogger
    private let store: LocalInferenceDiagnosticStore
    private let defaults: UserDefaults

    /// What the previous process left behind, resolved once at launch.
    private(set) var recovery: LocalInferenceRecoverySummary?
    /// Set once the banner has been seen, so it does not follow the user around
    /// (section 96). The log stays; only the nagging stops.
    private(set) var hasAcknowledgedRecovery: Bool

    private var thermalObserver: (any NSObjectProtocol)?
    private var memoryObserver: (any NSObjectProtocol)?
    private var lastThermalState: ProcessInfo.ThermalState

    /// Takes the logger the composition root already built.
    ///
    /// Never creates one: a second `LocalInferenceDiagnosticLogger` would open
    /// a second file with its own sequence counter, and the trail this whole
    /// system exists to produce would be split across two files that cannot be
    /// ordered against each other.
    init(
        logger: LocalInferenceDiagnosticLogger,
        store: LocalInferenceDiagnosticStore,
        defaults: UserDefaults = .standard
    ) {
        self.logger = logger
        self.store = store
        self.defaults = defaults
        self.recovery = logger.recovery
        self.hasAcknowledgedRecovery = defaults.string(forKey: Keys.acknowledgedSession)
            == logger.recovery?.sessionID.rawValue
        self.lastThermalState = ProcessInfo.processInfo.thermalState
    }

    /// The overrides on disk, readable before an instance exists.
    ///
    /// The composition root needs them while building `LocalModelManager`,
    /// which happens before any view — and therefore before this object.
    static func storedOverrides(
        defaults: UserDefaults = .standard
    ) -> LocalInferenceDiagnosticOverrides {
        guard
            let data = defaults.data(forKey: Keys.overrides),
            let decoded = try? JSONDecoder().decode(
                LocalInferenceDiagnosticOverrides.self, from: data
            )
        else { return .none }
        return decoded
    }

    // MARK: Launch

    /// Section 17. Everything about this process that is safe to record.
    func recordLaunch() {
        logger.startSession(
            metadata: header().metadata()
                .setting(.processorCount, ProcessInfo.processInfo.processorCount)
                .setting(.thermalState, Self.describe(ProcessInfo.processInfo.thermalState))
                .setting(.verboseLoggingEnabled, logger.isVerbose)
                .setting(.previousSessionID, ifPresent: recovery?.sessionID.rawValue)
        )
        logger.info(
            .appLaunch,
            category: .lifecycle,
            metadata: header().metadata()
                .setting(.verboseLoggingEnabled, logger.isVerbose)
                .merging(overrides.metadata())
        )
        observeSystemNotifications()
    }

    /// Section 93. Best effort, and known to be: iOS often terminates without
    /// delivering `willTerminate` at all, which is exactly why the *absence* of
    /// this marker is reported as "no clean shutdown recorded" rather than as a
    /// crash.
    func recordCleanShutdown(reason: String) {
        logger.endSession(clean: true, reason: reason)
    }

    /// Section 94: backgrounding is not a shutdown. A suspended app resumes,
    /// and marking it clean here would hide every crash that happens after the
    /// user switches away. Nothing is written.
    func applicationDidEnterBackground() {}

    // MARK: Observers

    private func observeSystemNotifications() {
        guard memoryObserver == nil else { return }

        // Section 48. A memory warning arriving between `ENTER context_create`
        // and its missing EXIT is the closest thing to evidence of an
        // out-of-memory kill this app can legitimately collect — and it is
        // still only close, which is why nothing here concludes anything.
        memoryObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.logger.record(
                .memoryWarning, type: .warning, level: .warning, category: .memory,
                stage: nil,
                metadata: LocalInferenceMetadata()
                    .setting(.physicalMemoryBytes, Int64(ProcessInfo.processInfo.physicalMemory))
                    .setting(.thermalState, Self.describe(ProcessInfo.processInfo.thermalState))
            )
        }

        // Section 49. Transitions only — the state is polled by the OS and
        // logging every notification would repeat the same value.
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let state = ProcessInfo.processInfo.thermalState
            guard state != self.lastThermalState else { return }
            let previous = self.lastThermalState
            self.lastThermalState = state
            self.logger.record(
                .thermalStateChanged,
                type: state == .critical ? .warning : .info,
                // Critical is written whatever the verbose setting, because a
                // device that throttled itself mid-generation is a real
                // explanation for a stall (section 68).
                level: state == .critical ? .warning : .debug,
                category: .thermal,
                stage: nil,
                metadata: LocalInferenceMetadata()
                    .setting(.thermalState, Self.describe(state))
                    .setting(.reason, "from \(Self.describe(previous))")
            )
        }
    }

    // MARK: Settings

    /// Section 67. Off by default: progress lines are noise during normal use.
    /// Critical breadcrumbs are unaffected by this and always written.
    var isVerbose: Bool {
        get { defaults.bool(forKey: Keys.verbose) }
        set {
            defaults.set(newValue, forKey: Keys.verbose)
            logger.setVerbose(newValue)
            logger.info(
                .diagnosticOverrides,
                category: .configuration,
                metadata: LocalInferenceMetadata().setting(.verboseLoggingEnabled, newValue)
            )
        }
    }

    /// Diagnostic handicaps.
    ///
    /// `UserDefaults` rather than the SwiftData settings store, deliberately.
    /// These are debug overrides for one investigation, not user preferences:
    /// they do not belong in the model that syncs, migrates and is backed up
    /// alongside the user's tasks and memories, and section 76 asks for them to
    /// override rather than to become defaults.
    var overrides: LocalInferenceDiagnosticOverrides {
        get { Self.storedOverrides(defaults: defaults) }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Keys.overrides)
        }
    }

    func acknowledgeRecovery() {
        guard let recovery else { return }
        defaults.set(recovery.sessionID.rawValue, forKey: Keys.acknowledgedSession)
        hasAcknowledgedRecovery = true
    }

    /// True when a banner is worth showing (sections 96 and 97).
    var shouldShowRecoveryBanner: Bool {
        guard let recovery else { return false }
        return recovery.isReportable && !hasAcknowledgedRecovery
    }

    // MARK: Reading

    func sessions() -> [LocalInferenceSessionFile] { store.sessionFiles() }

    func read(_ id: LocalInferenceSessionID) -> LocalInferenceDecodedSession {
        store.read(session: id) ?? LocalInferenceDecodedSession(events: [], unreadableLineCount: 0)
    }

    func report(for id: LocalInferenceSessionID) -> String {
        LocalInferenceDiagnosticReport.text(
            header: header(),
            recovery: recovery,
            session: read(id),
            sessionID: id,
            writerFailure: logger.writerFailureDescription
        )
    }

    /// Writes the export to a temporary file and hands back its URL.
    ///
    /// A real file rather than a string, because the share sheet's useful
    /// destinations — Files, Mail, AirDrop — take files, and because section 64
    /// is explicit that nothing is uploaded anywhere. The only way this leaves
    /// the device is a person choosing where it goes.
    func exportFile(for id: LocalInferenceSessionID) -> URL? {
        let name = LocalInferenceDiagnosticReport.exportFileName(at: Date(), extension: "txt")
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
        guard let data = report(for: id).data(using: .utf8) else { return nil }
        guard (try? data.write(to: url, options: [.atomic])) != nil else { return nil }
        return url
    }

    /// Section 66: diagnostic files only. Not models, not settings, not
    /// conversations.
    func clearLogs() {
        store.clear(keeping: logger.appSessionID)
        recovery = nil
        hasAcknowledgedRecovery = true
    }

    // MARK: Facts about this build

    func header() -> LocalInferenceReportHeader {
        LocalInferenceReportHeader(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String ?? "unknown",
            buildNumber: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
                as? String ?? "unknown",
            osVersion: UIDevice.current.systemVersion,
            deviceModel: Self.deviceModelIdentifier,
            physicalMemoryBytes: Int64(ProcessInfo.processInfo.physicalMemory),
            generatedAt: Date()
        )
    }

    /// `iPhone17,1`.
    ///
    /// Section 60: `uname`, which is public API and returns the same string
    /// Apple's own crash reports use. No private hardware lookup, and nothing
    /// that identifies the *device* — the model, not the phone.
    static let deviceModelIdentifier: String = {
        #if targetEnvironment(simulator)
        return ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]
            ?? "Simulator"
        #else
        var info = utsname()
        uname(&info)
        // `withUnsafeBytes(of:)` rather than the more common
        // `withMemoryRebound` incantation: that one reads
        // `MemoryLayout.size(ofValue: info.machine)` *inside* a closure that
        // already holds `info.machine` exclusively, which is an overlapping
        // access and a compile error. This form borrows once and asks the
        // buffer for its own length.
        //
        // The tuple is a fixed-size C char array, so it is padded with zeros —
        // taking the prefix up to the first zero is the string.
        let identifier = withUnsafeBytes(of: &info.machine) { buffer -> String in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
        return identifier.isEmpty ? UIDevice.current.model : identifier
        #endif
    }()

    static func describe(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private enum Keys {
        static let verbose = "metisai.diagnostics.local.verbose"
        static let overrides = "metisai.diagnostics.local.overrides"
        static let acknowledgedSession = "metisai.diagnostics.local.acknowledgedSession"
    }
}
