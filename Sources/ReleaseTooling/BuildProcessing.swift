import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Where a build is in App Store Connect's processing pipeline.
///
/// The values are Apple's, spelled exactly as the API returns them. An unknown
/// state is kept rather than mapped to a default, because guessing here would
/// mean reporting a build as shipped on the strength of a string nobody has
/// seen before.
public enum BuildProcessingState: Equatable, Sendable {
    /// Apple has the binary and is still working on it.
    case processing
    /// Processing finished and the build is usable in TestFlight. The target.
    case valid
    /// Processing failed. The build will never appear; a new upload is needed.
    case failed
    /// Apple rejected the binary — a missing icon, a bad entitlement, a
    /// disallowed API. Also terminal.
    case invalid
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue.uppercased() {
        case "PROCESSING": self = .processing
        case "VALID": self = .valid
        case "FAILED": self = .failed
        case "INVALID": self = .invalid
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .processing: return "PROCESSING"
        case .valid: return "VALID"
        case .failed: return "FAILED"
        case .invalid: return "INVALID"
        case .unknown(let value): return value
        }
    }

    /// Whether waiting longer could change the answer.
    ///
    /// `unknown` is treated as terminal on purpose. Continuing to poll a state
    /// this code does not understand would burn the whole timeout and then
    /// report a timeout, which is a less accurate description of what happened
    /// than "Apple said something we do not recognise".
    public var isTerminal: Bool {
        if case .processing = self { return false }
        return true
    }

    public var isSuccess: Bool { self == .valid }
}

/// One build, as far as this milestone cares.
public struct BuildRecord: Equatable, Sendable {
    /// App Store Connect's own identifier for the build.
    public let id: String
    /// `CFBundleVersion` — the build number.
    public let version: String
    public let processingState: BuildProcessingState
    public let uploadedDate: Date?

    public init(
        id: String,
        version: String,
        processingState: BuildProcessingState,
        uploadedDate: Date? = nil
    ) {
        self.id = id
        self.version = version
        self.processingState = processingState
        self.uploadedDate = uploadedDate
    }
}

// MARK: - Decoding

/// Reads the API's JSON:API envelope.
///
/// Written by hand against a small, stable slice of the response rather than
/// modelled in full: the Builds resource has forty-odd attributes and
/// relationships, and a `Decodable` over all of them would start failing the
/// day Apple adds one.
public enum AppStoreConnectDecoder {

    public static func apps(from data: Data) throws -> [(id: String, bundleID: String)] {
        let envelope = try envelope(data)
        return envelope.compactMap { item in
            guard
                let id = item["id"] as? String,
                let attributes = item["attributes"] as? [String: Any],
                let bundleID = attributes["bundleId"] as? String
            else { return nil }
            return (id, bundleID)
        }
    }

    public static func builds(from data: Data) throws -> [BuildRecord] {
        let envelope = try envelope(data)
        return envelope.compactMap { item in
            guard
                let id = item["id"] as? String,
                let attributes = item["attributes"] as? [String: Any],
                let version = attributes["version"] as? String
            else { return nil }
            let state = attributes["processingState"] as? String ?? "UNKNOWN"
            return BuildRecord(
                id: id,
                version: version,
                processingState: BuildProcessingState(rawValue: state),
                uploadedDate: (attributes["uploadedDate"] as? String).flatMap(iso8601)
            )
        }
    }

    /// Apple's error envelope, flattened into printable sentences.
    ///
    /// Worth decoding rather than dumping the body: a 401 from a bad token and
    /// a 403 from a key without the App Manager role are the same HTTP failure
    /// to a caller and completely different problems to a human.
    public static func errors(from data: Data) -> [String] {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let errors = object["errors"] as? [[String: Any]]
        else { return [] }
        return errors.compactMap { error in
            let title = error["title"] as? String
            let detail = error["detail"] as? String
            return [title, detail].compactMap { $0 }.joined(separator: ": ")
        }
    }

    private static func envelope(_ data: Data) throws -> [[String: Any]] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BuildPollError.malformedResponse
        }
        guard let items = object["data"] as? [[String: Any]] else {
            // A single-resource response nests one object rather than an array.
            if let item = object["data"] as? [String: Any] { return [item] }
            throw BuildPollError.malformedResponse
        }
        return items
    }

    private static func iso8601(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }
}

// MARK: - Polling

/// The outcome of waiting for a build.
public enum BuildPollOutcome: Equatable, Sendable {
    /// Apple finished processing and the build reached this state.
    case settled(BuildRecord)
    /// The build never appeared in App Store Connect within the deadline.
    case neverAppeared
    /// The build appeared but was still processing when the deadline passed.
    case stillProcessing(BuildRecord)
}

public enum BuildPollError: Error, Equatable, CustomStringConvertible {
    case malformedResponse
    case httpFailure(status: Int, messages: [String])
    case appRecordNotFound(bundleID: String)

    public var description: String {
        switch self {
        case .malformedResponse:
            return "App Store Connect returned a response this tool could not read."
        case .httpFailure(let status, let messages):
            let detail = messages.isEmpty ? "" : " — " + messages.joined(separator: "; ")
            return "App Store Connect returned HTTP \(status)\(detail)"
        case .appRecordNotFound(let bundleID):
            return "No App Store Connect app record exists for \(bundleID). Create the "
                + "app in App Store Connect before uploading a build to it."
        }
    }
}

/// A minimal HTTP surface, so the polling loop can be tested without a network.
///
/// The logic worth testing is the *loop* — when it stops, what it stops on,
/// how it treats a build that has not appeared yet — and none of that needs a
/// real request.
public protocol AppStoreConnectTransport: Sendable {
    func get(_ url: URL, token: String) async throws -> (Data, Int)
}

public struct URLSessionAppStoreConnectTransport: AppStoreConnectTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func get(_ url: URL, token: String) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (data, status)
    }
}

/// Asks App Store Connect about one specific build until it stops changing.
///
/// ## Why "one specific build" is the whole point
///
/// The obvious implementation asks for the app's most recent build, and it is
/// wrong in the way that matters: two deploy runs racing, or a build uploaded
/// by hand from a laptop, and the newest build is not the one this run
/// produced. Reporting *that* build's success as this run's success is exactly
/// the false green Part 14 section 73 is written against. So the filter is on
/// the exact `CFBundleVersion` this run signed, and a build with any other
/// version is not looked at.
public struct BuildProcessingPoller: Sendable {
    private let transport: any AppStoreConnectTransport
    private let baseURL = URL(string: "https://api.appstoreconnect.apple.com/v1")!

    public init(transport: any AppStoreConnectTransport) {
        self.transport = transport
    }

    /// Finds the app record, failing with a message that says what to do.
    ///
    /// Called before the archive as well as during polling. Section 33: an app
    /// record that does not exist turns a forty-minute build into an upload
    /// error, and there is nothing the workflow can do about it — only a human
    /// with an App Store Connect login can create one.
    public func appID(forBundleID bundleID: String, token: String) async throws -> String {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("apps"), resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "filter[bundleId]", value: bundleID),
            URLQueryItem(name: "limit", value: "10"),
        ]

        let (data, status) = try await transport.get(components.url!, token: token)
        guard (200..<300).contains(status) else {
            throw BuildPollError.httpFailure(
                status: status, messages: AppStoreConnectDecoder.errors(from: data)
            )
        }

        // The filter is a prefix match on Apple's side, so an exact comparison
        // is done here as well: `…MetisAI` and `…MetisAI.widgets` would both
        // come back, and uploading to the extension's record is not a mistake
        // that announces itself.
        let apps = try AppStoreConnectDecoder.apps(from: data)
        guard let match = apps.first(where: { $0.bundleID == bundleID }) else {
            throw BuildPollError.appRecordNotFound(bundleID: bundleID)
        }
        return match.id
    }

    /// One look at the build, or nil when App Store Connect has not registered
    /// it yet.
    public func build(
        appID: String,
        buildNumber: String,
        token: String
    ) async throws -> BuildRecord? {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("builds"), resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "filter[app]", value: appID),
            URLQueryItem(name: "filter[version]", value: buildNumber),
            URLQueryItem(name: "limit", value: "10"),
        ]

        let (data, status) = try await transport.get(components.url!, token: token)
        guard (200..<300).contains(status) else {
            throw BuildPollError.httpFailure(
                status: status, messages: AppStoreConnectDecoder.errors(from: data)
            )
        }
        return try AppStoreConnectDecoder.builds(from: data)
            .first { $0.version == buildNumber }
    }

    /// Polls until the build settles or the deadline passes.
    ///
    /// - Parameters:
    ///   - deadline: how long to wait in total. Processing usually takes five
    ///     to fifteen minutes and occasionally much longer; the workflow's own
    ///     job timeout is the real ceiling.
    ///   - interval: seconds between requests. Deliberately not aggressive —
    ///     App Store Connect rate-limits per key, and a tight loop would spend
    ///     the budget getting 429s instead of answers.
    ///   - onPoll: called with each observation so the caller can log progress.
    ///     A job that prints nothing for twenty minutes looks hung.
    public func wait(
        appID: String,
        buildNumber: String,
        token: @Sendable () async throws -> String,
        deadline: TimeInterval,
        interval: TimeInterval = 30,
        sleep: @Sendable (TimeInterval) async throws -> Void,
        now: @Sendable () -> Date = { Date() },
        onPoll: @Sendable (BuildRecord?) -> Void = { _ in }
    ) async throws -> BuildPollOutcome {
        let start = now()
        var lastSeen: BuildRecord?

        while true {
            // Minted per poll rather than once. A token lives fifteen minutes
            // and processing can take longer; reusing one would turn a slow
            // build into a 401 that reads like an authentication problem.
            let bearer = try await token()
            let record = try await build(appID: appID, buildNumber: buildNumber, token: bearer)
            onPoll(record)

            if let record {
                lastSeen = record
                if record.processingState.isTerminal {
                    return .settled(record)
                }
            }

            if now().timeIntervalSince(start) + interval >= deadline {
                if let lastSeen { return .stillProcessing(lastSeen) }
                return .neverAppeared
            }
            try await sleep(interval)
        }
    }
}
