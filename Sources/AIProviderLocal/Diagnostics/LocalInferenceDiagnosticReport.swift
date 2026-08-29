import Foundation

/// The text a person copies, shares or exports.
///
/// Built here rather than in the view for the usual reason — `iOS/` has no test
/// target, and "the export contains no prompt text" is precisely the assertion
/// that must not depend on somebody remembering. Section 116 tests this file.
///
/// Everything it prints comes from ``LocalInferenceDiagnosticEvent``, whose
/// metadata keys are a closed allowlist, so the report cannot contain content
/// the events could not contain. There is no path from a conversation to here.
public enum LocalInferenceDiagnosticReport {

    /// A privacy-safe report: header, summary, then the session's lines.
    public static func text(
        header: LocalInferenceReportHeader,
        recovery: LocalInferenceRecoverySummary?,
        session: LocalInferenceDecodedSession,
        sessionID: LocalInferenceSessionID,
        writerFailure: String?
    ) -> String {
        var lines: [String] = []

        lines.append("MetisAI Local AI Diagnostic Report")
        lines.append(String(repeating: "=", count: 34))
        lines.append("Generated: \(LocalInferenceDiagnosticCoding.timestampFormatter.string(from: header.generatedAt))")
        lines.append("App version: \(header.appVersion)")
        lines.append("Build: \(header.buildNumber)")
        lines.append("iOS: \(header.osVersion)")
        lines.append("Device: \(header.deviceModel)")
        lines.append("Physical memory: \(byteLabel(header.physicalMemoryBytes))")
        lines.append("Session: \(sessionID.rawValue)")
        if let writerFailure {
            lines.append("Diagnostic writer failed: \(writerFailure)")
        }
        lines.append("")

        if let recovery {
            lines.append("Previous session")
            lines.append(String(repeating: "-", count: 34))
            lines.append("ID: \(recovery.sessionID.rawValue)")
            lines.append("Clean shutdown recorded: \(recovery.endedCleanly ? "Yes" : "No")")
            lines.append("Reached local inference: \(recovery.enteredLocalInference ? "Yes" : "No")")
            if let completed = recovery.lastCompletedDescription { lines.append(completed) }
            if let stage = recovery.stageDescription { lines.append(stage) }
            if recovery.unreadableLineCount > 0 {
                lines.append(
                    "Unreadable log lines: \(recovery.unreadableLineCount) "
                        + "(consistent with a write interrupted by termination)"
                )
            }
            lines.append(LocalInferenceRecoverySummary.terminationReasonCaveat)
            lines.append("")
        }

        lines.append("Events (\(session.events.count))")
        lines.append(String(repeating: "-", count: 34))
        if session.events.isEmpty {
            lines.append("No events recorded.")
        }
        for event in session.events {
            lines.append(line(for: event))
        }
        if session.unreadableLineCount > 0 {
            lines.append("(\(session.unreadableLineCount) unreadable line(s) skipped)")
        }
        lines.append("")
        lines.append("No prompt, response, memory or credential content is recorded.")
        return lines.joined(separator: "\n")
    }

    /// One event, as it appears in the report and on screen.
    ///
    /// `000004 +2.481s EXIT model_load op=8F4A21C0B7D3 actualContextSize=2048`
    public static func line(for event: LocalInferenceDiagnosticEvent) -> String {
        var parts: [String] = []
        parts.append(String(format: "%06d", event.sequence))
        parts.append(String(format: "%+.3fs", event.elapsed))
        parts.append(event.type.rawValue)

        switch event.type {
        case .enter, .exit:
            parts.append(event.stage?.rawValue ?? event.name.rawValue)
        case .info, .warning, .error, .state:
            parts.append(event.name.rawValue)
            if let stage = event.stage { parts.append("[\(stage.rawValue)]") }
        }
        if let operation = event.operationID { parts.append("op=\(operation.rawValue)") }

        let metadata = event.metadata.values
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.rawValue)=\(describe($0.value))" }
        parts.append(contentsOf: metadata)
        return parts.joined(separator: " ")
    }

    /// One metadata value as it appears in a report or on screen.
    ///
    /// Public because the diagnostics screen renders individual values in
    /// labelled rows as well as whole lines, and a second formatter in the view
    /// would be a second thing to keep in step — with the drift showing up as a
    /// number that reads differently in the UI and in the export somebody sent.
    public static func describe(_ value: LocalInferenceMetadataValue) -> String {
        switch value {
        case .int(let number): return String(number)
        case .int64(let number): return String(number)
        case .double(let number): return String(format: "%g", number)
        case .bool(let flag): return flag ? "true" : "false"
        case .text(let text): return text
        }
    }

    /// The raw JSONL for a session, for an export somebody will parse.
    public static func jsonl(_ session: LocalInferenceDecodedSession) -> Data {
        session.events.reduce(into: Data()) { data, event in
            data.append(LocalInferenceDiagnosticCoding.encode(event))
        }
    }

    /// `metis-local-diagnostics-20260830-002014.jsonl` (section 65).
    public static func exportFileName(
        at date: Date,
        extension fileExtension: String = "jsonl"
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "metis-local-diagnostics-\(formatter.string(from: date)).\(fileExtension)"
    }

    public static func byteLabel(_ bytes: Int64?) -> String {
        guard let bytes, bytes > 0 else { return "unknown" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
    }
}

/// The build and device facts at the top of a report.
///
/// A plain value rather than something that reads `Bundle` and `ProcessInfo`
/// itself, so the report is testable and so the device-identifier lookup stays
/// where it belongs — in `iOS/`, next to the `uname` call.
public struct LocalInferenceReportHeader: Hashable, Sendable {
    public var appVersion: String
    public var buildNumber: String
    public var osVersion: String
    /// `iPhone17,1`. Section 60 — the `uname` machine identifier, which is
    /// public API, not a private hardware lookup.
    public var deviceModel: String
    public var physicalMemoryBytes: Int64
    public var generatedAt: Date

    public init(
        appVersion: String,
        buildNumber: String,
        osVersion: String,
        deviceModel: String,
        physicalMemoryBytes: Int64,
        generatedAt: Date
    ) {
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.osVersion = osVersion
        self.deviceModel = deviceModel
        self.physicalMemoryBytes = physicalMemoryBytes
        self.generatedAt = generatedAt
    }

    public func metadata() -> LocalInferenceMetadata {
        LocalInferenceMetadata()
            .setting(.appVersion, appVersion)
            .setting(.buildNumber, buildNumber)
            .setting(.osVersion, osVersion)
            .setting(.deviceModel, deviceModel)
            .setting(.physicalMemoryBytes, physicalMemoryBytes)
    }
}
