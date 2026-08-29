import Foundation

/// Turns events into JSONL lines and back.
///
/// ## Why JSONL
///
/// Section 6. One self-contained JSON object per line, appended and never
/// rewritten. It is machine-parseable, it is readable in a terminal, appending
/// is a single `write`, and — the property that matters here — a file whose
/// last line was cut off mid-write still has every earlier line intact. A JSON
/// array would need a closing bracket the crashing process never got to write,
/// and would be unparseable in exactly the situation it exists for.
///
/// ## Why the writer is hand-rolled
///
/// `JSONEncoder` would do, but the encoded shape is a wire format that a person
/// reads in a bug report and a parser reads on the next launch, and writing it
/// by hand keeps the field names short and the ordering stable. Decoding uses
/// `JSONSerialization`, which is tolerant of field order and of fields a newer
/// build added.
public enum LocalInferenceDiagnosticCoding {

    /// Field names. Short: they repeat on every line, and a generation writes a
    /// few hundred lines.
    enum Field {
        static let sequence = "seq"
        static let timestamp = "ts"
        static let elapsed = "el"
        static let level = "lvl"
        static let category = "cat"
        static let type = "event"
        static let name = "name"
        static let stage = "stage"
        static let operation = "op"
        static let appSession = "app"
        static let inferenceSession = "inf"
        static let metadata = "meta"
    }

    static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        // Fractional seconds because two breadcrumbs around one native call can
        // land in the same second, and the whole point is knowing which came
        // first. The sequence number is the authority; this is for a human
        // correlating against a wall clock.
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    // MARK: Encoding

    /// One event as a single line, newline included.
    public static func encode(_ event: LocalInferenceDiagnosticEvent) -> Data {
        var object: [String: Any] = [
            Field.sequence: event.sequence,
            Field.timestamp: timestampFormatter.string(from: event.timestamp),
            Field.elapsed: (event.elapsed * 1000).rounded() / 1000,
            Field.level: event.level.rawValue,
            Field.category: event.category.rawValue,
            Field.type: event.type.rawValue,
            Field.name: event.name.rawValue,
            Field.appSession: event.appSessionID.rawValue,
        ]
        if let stage = event.stage { object[Field.stage] = stage.rawValue }
        if let operation = event.operationID { object[Field.operation] = operation.rawValue }
        if let inference = event.inferenceSessionID {
            object[Field.inferenceSession] = inference.rawValue
        }
        if !event.metadata.isEmpty {
            object[Field.metadata] = encodeMetadata(event.metadata)
        }

        // `sortedKeys` so two runs of the same events produce the same bytes,
        // which is what makes a diff between a working and a crashing run
        // readable.
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]
            )
        else {
            // Never expected: every value above is a String, Int, Double or
            // Bool. A line saying the encoder failed is still better than a
            // silent gap in the trail.
            return Data(#"{"event":"ERROR","name":"WRITER_FAILURE"}"#.utf8) + Data("\n".utf8)
        }
        return data + Data("\n".utf8)
    }

    static func encodeMetadata(_ metadata: LocalInferenceMetadata) -> [String: Any] {
        var object: [String: Any] = [:]
        for (key, value) in metadata.values {
            switch value {
            case .int(let number): object[key.rawValue] = number
            case .int64(let number): object[key.rawValue] = number
            case .double(let number): object[key.rawValue] = (number * 1000).rounded() / 1000
            case .bool(let flag): object[key.rawValue] = flag
            case .text(let text): object[key.rawValue] = text
            }
        }
        return object
    }

    // MARK: Decoding

    /// Every event a file contains, skipping anything unreadable.
    ///
    /// Section 82. The last line of a file written by a process that was killed
    /// is frequently a partial JSON object, and the correct response is to drop
    /// that one line — not to fail the file, which would discard the entire
    /// trail leading up to the crash being investigated. Any line that does not
    /// parse is skipped, wherever it is: a torn write in the middle is just as
    /// possible and just as survivable.
    public static func decode(_ data: Data) -> LocalInferenceDecodedSession {
        var events: [LocalInferenceDiagnosticEvent] = []
        var skipped = 0

        for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            guard let event = decodeLine(Data(line)) else {
                skipped += 1
                continue
            }
            events.append(event)
        }
        // Sequence order rather than file order. They agree in practice — the
        // writer is serialized — but the sequence number is the guarantee and
        // the file order is a consequence, so pairing works off the guarantee.
        events.sort { $0.sequence < $1.sequence }
        return LocalInferenceDecodedSession(events: events, unreadableLineCount: skipped)
    }

    static func decodeLine(_ line: Data) -> LocalInferenceDiagnosticEvent? {
        guard
            let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            let sequence = object[Field.sequence] as? Int,
            let typeRaw = object[Field.type] as? String,
            let type = LocalInferenceEventType(rawValue: typeRaw),
            let nameRaw = object[Field.name] as? String,
            let name = LocalInferenceEventName(rawValue: nameRaw),
            let appRaw = object[Field.appSession] as? String
        else { return nil }

        let timestamp = (object[Field.timestamp] as? String)
            .flatMap { timestampFormatter.date(from: $0) } ?? Date(timeIntervalSince1970: 0)

        return LocalInferenceDiagnosticEvent(
            appSessionID: LocalInferenceSessionID(rawValue: appRaw),
            inferenceSessionID: (object[Field.inferenceSession] as? String)
                .map(LocalInferenceSessionID.init(rawValue:)),
            sequence: sequence,
            timestamp: timestamp,
            elapsed: (object[Field.elapsed] as? Double) ?? 0,
            level: (object[Field.level] as? String).flatMap(LocalInferenceDiagnosticLevel.init)
                ?? .info,
            category: (object[Field.category] as? String)
                .flatMap(LocalInferenceDiagnosticCategory.init) ?? .diagnostics,
            type: type,
            name: name,
            stage: (object[Field.stage] as? String).flatMap(LocalInferenceStage.init),
            operationID: (object[Field.operation] as? String)
                .map(LocalInferenceOperationID.init(rawValue:)),
            metadata: decodeMetadata(object[Field.metadata] as? [String: Any] ?? [:])
        )
    }

    static func decodeMetadata(_ object: [String: Any]) -> LocalInferenceMetadata {
        var values: [LocalInferenceMetadataKey: LocalInferenceMetadataValue] = [:]
        for (rawKey, value) in object {
            // Re-checked on the way in as well as on the way out. A file could
            // have been written by a different build, or edited; nothing that
            // is not on today's allowlist gets displayed or re-exported.
            guard let key = LocalInferenceMetadataKey(rawValue: rawKey) else { continue }
            // Bool before Int, and not as a style choice: `JSONSerialization`
            // hands back `NSNumber` for both, and an `NSNumber` wrapping `true`
            // casts to `Int` just as happily as to `Bool` — giving 1. Testing
            // Int first would turn every boolean in the file into a number.
            switch value {
            case let flag as Bool: values[key] = .bool(flag)
            case let number as Int: values[key] = .int(number)
            case let number as Int64: values[key] = .int64(number)
            case let number as Double: values[key] = .double(number)
            case let text as String: values[key] = .text(LocalInferenceRedaction.sanitizeText(text))
            default: continue
            }
        }
        return LocalInferenceMetadata(values)
    }
}

/// What came out of one session file.
public struct LocalInferenceDecodedSession: Sendable {
    public let events: [LocalInferenceDiagnosticEvent]
    /// Lines that could not be parsed. Reported rather than hidden — a non-zero
    /// count on the last session is itself evidence the process was killed
    /// mid-write.
    public let unreadableLineCount: Int

    public init(events: [LocalInferenceDiagnosticEvent], unreadableLineCount: Int) {
        self.events = events
        self.unreadableLineCount = unreadableLineCount
    }
}
