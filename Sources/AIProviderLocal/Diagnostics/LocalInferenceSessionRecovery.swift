import Foundation

/// Reads what the last process left behind.
///
/// ## The question this answers
///
/// The app dies inside a native call and there is no console, no exception and
/// no stack. On the next launch the only thing that exists is a file of
/// breadcrumbs that stops abruptly. This turns that file into one sentence:
///
/// ```
/// last successful stage
///   ↓
/// next critical ENTER stage
///   ↓
/// process died before EXIT
/// ```
///
/// ## What it refuses to say
///
/// Sections 50 and 51. An unclean session with an open `context_create` is
/// evidence that the process stopped during context creation. It is **not**
/// evidence of an out-of-memory kill: a native abort, a watchdog termination, a
/// user force-quit and a jetsam kill all look identical from in here, because
/// iOS does not tell an app why its predecessor died. So every word this
/// produces is about *where*, never about *why*, and the UI wording follows.
public enum LocalInferenceSessionRecovery {

    /// Looks at the newest session that is not the current one.
    public static func recoverPreviousSession(
        in store: LocalInferenceDiagnosticStore,
        excluding current: LocalInferenceSessionID
    ) -> LocalInferenceRecoverySummary? {
        let candidates = store.sessionFiles().filter { $0.id != current }
        guard let previous = candidates.first else { return nil }
        guard let decoded = store.read(session: previous.id) else { return nil }
        return summarize(
            decoded,
            sessionID: previous.id,
            endedAt: previous.modifiedAt,
            sidecar: readCurrentStage(in: store)
        )
    }

    /// Builds the summary for one decoded session.
    public static func summarize(
        _ session: LocalInferenceDecodedSession,
        sessionID: LocalInferenceSessionID,
        endedAt: Date,
        sidecar: LocalInferenceCurrentStageRecord? = nil
    ) -> LocalInferenceRecoverySummary {
        let events = session.events
        let cleanMarker = events.last {
            $0.name == .sessionEnd && $0.metadata[.clean] == .bool(true)
        }

        let unresolved = unresolvedOperations(in: events)
        // The innermost open stage is the one execution was actually inside.
        // With `inference → generation → prompt_decode` all open, the answer is
        // `prompt_decode`; naming `inference` would be true and useless.
        let deepest = unresolved.last

        // The sidecar is a cross-check, not the source of truth. If it names an
        // operation the JSONL scan also found open, that raises confidence; if
        // the JSONL tail was lost it may be the only thing left.
        let recovered = deepest ?? sidecar.flatMap { record -> LocalInferenceOpenStage? in
            guard record.appSessionID == sessionID.rawValue else { return nil }
            guard let stage = LocalInferenceStage(rawValue: record.stage) else { return nil }
            return LocalInferenceOpenStage(
                stage: stage,
                operationID: LocalInferenceOperationID(rawValue: record.operationID),
                sequence: record.sequence,
                timestamp: record.timestamp,
                metadata: .empty
            )
        }

        return LocalInferenceRecoverySummary(
            sessionID: sessionID,
            endedAt: endedAt,
            endedCleanly: cleanMarker != nil,
            // Stages are only ever emitted by the local inference pipeline, so
            // "any staged event" is the same question as "did this session use
            // Local AI" — and it is the question section 97 turns the banner on.
            enteredLocalInference: events.contains {
                $0.name == .inferenceSessionStart || $0.stage != nil
            },
            unresolvedStages: unresolved,
            deepestUnresolvedStage: recovered,
            lastCompletedStage: lastCompletedStage(in: events, before: recovered?.sequence),
            lastEvent: events.last,
            eventCount: events.count,
            unreadableLineCount: session.unreadableLineCount,
            modelID: lastValue(in: events, key: .modelID),
            configuration: configurationSnapshot(in: events)
        )
    }

    // MARK: Pairing

    /// Every ENTER with no matching EXIT, in the order they were entered.
    ///
    /// ## The algorithm, and why it is not "match by stage name"
    ///
    /// Sections 15 and 16. Stages nest — `generation` contains
    /// `generation_decode` — and they repeat: `model_load` runs again when the
    /// user switches models, and `prompt_decode` runs once per message. Pairing
    /// by name would resolve the second ENTER against the first EXIT and report
    /// a completed stage as the crash site, or the reverse.
    ///
    /// So each ENTER carries an operation identifier and each EXIT quotes it.
    /// Walk the events in sequence order, add on ENTER, remove by identifier on
    /// EXIT, and whatever is left never came back. Order is preserved, so the
    /// last element is the innermost stage that was still running.
    public static func unresolvedOperations(
        in events: [LocalInferenceDiagnosticEvent]
    ) -> [LocalInferenceOpenStage] {
        var open: [LocalInferenceOpenStage] = []

        for event in events.sorted(by: { $0.sequence < $1.sequence }) {
            guard let stage = event.stage, let operation = event.operationID else { continue }
            switch event.type {
            case .enter:
                open.append(
                    LocalInferenceOpenStage(
                        stage: stage,
                        operationID: operation,
                        sequence: event.sequence,
                        timestamp: event.timestamp,
                        metadata: event.metadata
                    )
                )
            case .exit:
                // A stage that threw still *returned*, so it is resolved. It is
                // not where the process died, and saying it was would send the
                // investigation to the wrong place.
                open.removeAll { $0.operationID == operation }
            case .info, .warning, .error, .state:
                continue
            }
        }
        return open
    }

    /// The last stage that completed before things stopped — the "last known
    /// good" half of the trail.
    static func lastCompletedStage(
        in events: [LocalInferenceDiagnosticEvent],
        before sequence: Int?
    ) -> LocalInferenceStage? {
        let limit = sequence ?? Int.max
        return events
            .filter { $0.type == .exit && $0.sequence < limit && $0.level != .error }
            .max(by: { $0.sequence < $1.sequence })?
            .stage
    }

    static func lastValue(
        in events: [LocalInferenceDiagnosticEvent],
        key: LocalInferenceMetadataKey
    ) -> String? {
        for event in events.reversed() {
            if case .text(let value)? = event.metadata[key] { return value }
        }
        return nil
    }

    /// The runtime numbers the crashing session was actually using (section 90).
    static func configurationSnapshot(
        in events: [LocalInferenceDiagnosticEvent]
    ) -> LocalInferenceMetadata? {
        events.last { $0.name == .runtimeConfiguration }?.metadata
    }

    // MARK: The sidecar

    /// Reads `current-stage.json`, if it is there and parses.
    public static func readCurrentStage(
        in store: LocalInferenceDiagnosticStore
    ) -> LocalInferenceCurrentStageRecord? {
        guard
            let data = try? Data(contentsOf: store.currentStageURL),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let appSessionID = object["appSessionID"] as? String,
            let operationID = object["operationID"] as? String,
            let stage = object["stage"] as? String
        else { return nil }

        return LocalInferenceCurrentStageRecord(
            appSessionID: appSessionID,
            operationID: operationID,
            stage: stage,
            sequence: (object["sequence"] as? Int) ?? 0,
            timestamp: (object["timestamp"] as? String)
                .flatMap(LocalInferenceDiagnosticCoding.timestampFormatter.date(from:))
                ?? Date(timeIntervalSince1970: 0)
        )
    }
}

/// An ENTER that never came back.
public struct LocalInferenceOpenStage: Hashable, Sendable {
    public let stage: LocalInferenceStage
    public let operationID: LocalInferenceOperationID
    public let sequence: Int
    public let timestamp: Date
    /// Whatever the ENTER recorded — the context size it was about to allocate,
    /// the token count it was about to decode. Often the most useful line in
    /// the whole report.
    public let metadata: LocalInferenceMetadata

    public init(
        stage: LocalInferenceStage,
        operationID: LocalInferenceOperationID,
        sequence: Int,
        timestamp: Date,
        metadata: LocalInferenceMetadata
    ) {
        self.stage = stage
        self.operationID = operationID
        self.sequence = sequence
        self.timestamp = timestamp
        self.metadata = metadata
    }
}

public struct LocalInferenceCurrentStageRecord: Hashable, Sendable {
    public let appSessionID: String
    public let operationID: String
    public let stage: String
    public let sequence: Int
    public let timestamp: Date
}

/// What the previous process left behind, as the UI needs it.
public struct LocalInferenceRecoverySummary: Sendable {
    public let sessionID: LocalInferenceSessionID
    public let endedAt: Date
    /// True only when a `SESSION_END clean=true` marker was found.
    public let endedCleanly: Bool
    /// Whether that session ever got as far as local inference.
    ///
    /// Section 97: if it did not, nothing here is about Local AI and the banner
    /// must not appear. Blaming the local model for a crash in the calendar
    /// code would send somebody down a week-long blind alley.
    public let enteredLocalInference: Bool
    public let unresolvedStages: [LocalInferenceOpenStage]
    public let deepestUnresolvedStage: LocalInferenceOpenStage?
    public let lastCompletedStage: LocalInferenceStage?
    public let lastEvent: LocalInferenceDiagnosticEvent?
    public let eventCount: Int
    public let unreadableLineCount: Int
    public let modelID: String?
    public let configuration: LocalInferenceMetadata?

    public init(
        sessionID: LocalInferenceSessionID,
        endedAt: Date,
        endedCleanly: Bool,
        enteredLocalInference: Bool,
        unresolvedStages: [LocalInferenceOpenStage],
        deepestUnresolvedStage: LocalInferenceOpenStage?,
        lastCompletedStage: LocalInferenceStage?,
        lastEvent: LocalInferenceDiagnosticEvent?,
        eventCount: Int,
        unreadableLineCount: Int,
        modelID: String?,
        configuration: LocalInferenceMetadata?
    ) {
        self.sessionID = sessionID
        self.endedAt = endedAt
        self.endedCleanly = endedCleanly
        self.enteredLocalInference = enteredLocalInference
        self.unresolvedStages = unresolvedStages
        self.deepestUnresolvedStage = deepestUnresolvedStage
        self.lastCompletedStage = lastCompletedStage
        self.lastEvent = lastEvent
        self.eventCount = eventCount
        self.unreadableLineCount = unreadableLineCount
        self.modelID = modelID
        self.configuration = configuration
    }

    /// True when this is worth putting in front of somebody.
    ///
    /// Both halves are required: the session must have ended without a clean
    /// marker *and* it must have reached local inference. Section 97.
    public var isReportable: Bool {
        !endedCleanly && enteredLocalInference
    }

    /// The headline. Careful wording is the whole point (sections 13 and 50).
    public var headline: String {
        "Previous session terminated unexpectedly."
    }

    /// The stage sentence, or nil when the trail names no open stage.
    public var stageDescription: String? {
        guard let deepest = deepestUnresolvedStage else { return nil }
        return "Termination occurred after: ENTER \(deepest.stage.rawValue). "
            + "No matching EXIT was recorded."
    }

    public var lastCompletedDescription: String? {
        lastCompletedStage.map { "Last successful stage: \($0.rawValue)" }
    }

    /// Said once, plainly, so nobody reads a missing EXIT as a diagnosis.
    ///
    /// Sections 50 and 51: iOS does not hand an app the reason its predecessor
    /// died, so an out-of-memory kill, a native abort, a watchdog termination
    /// and the user swiping the app away are indistinguishable from in here.
    public static let terminationReasonCaveat =
        "The exact reason iOS ended the previous session is not available to the app. "
        + "This report shows where execution stopped, not why."
}
