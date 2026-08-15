import Foundation

/// Diagnostics for remote calls.
///
/// Records what is useful for working out why a call failed — host, model,
/// status, duration, which tools the model asked for — and nothing that could
/// leak. The API key, the `Authorization` header and message content never
/// reach this type, because none of the call sites pass them.
public protocol RemoteAILogging: Sendable {
    func log(_ event: RemoteAIEvent)
}

public enum RemoteAIEvent: Sendable {
    /// A request is about to be sent. `host` only — a full URL can carry a
    /// token in its path on some services.
    case requestStarted(host: String, model: String, toolCount: Int)
    case responseReceived(status: Int, duration: TimeInterval, toolNames: [String])
    case failed(category: String, status: Int?)
}

/// Prints to standard output in debug builds and does nothing otherwise.
public struct ConsoleRemoteAILogger: RemoteAILogging {
    public init() {}

    public func log(_ event: RemoteAIEvent) {
        #if DEBUG
        switch event {
        case .requestStarted(let host, let model, let toolCount):
            print("[RemoteAI] → \(host) model=\(model) tools=\(toolCount)")
        case .responseReceived(let status, let duration, let toolNames):
            let tools = toolNames.isEmpty ? "" : " calls=\(toolNames.joined(separator: ","))"
            print("[RemoteAI] ← \(status) in \(String(format: "%.2f", duration))s\(tools)")
        case .failed(let category, let status):
            let code = status.map { " status=\($0)" } ?? ""
            print("[RemoteAI] ✕ \(category)\(code)")
        }
        #endif
    }
}

/// Discards everything. The default, so nothing is logged unless asked for.
public struct SilentRemoteAILogger: RemoteAILogging {
    public init() {}
    public func log(_ event: RemoteAIEvent) {}
}
