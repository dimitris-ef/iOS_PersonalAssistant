#if canImport(FoundationModels)

import AssistantAI
import AssistantDomain
import Foundation
import FoundationModels

/// Holds the tool calls the model proposed during one generation.
///
/// Apple's tool calling is a *callback*: the framework invokes a Swift function
/// in the middle of generating, and expects a result it can keep reasoning
/// about. The rest of this application is built the other way round — a
/// provider returns proposed calls, and `AssistantEngine` decides what happens
/// to them.
///
/// This actor is the join between the two shapes. It exists so the adapter can
/// answer the framework immediately while the real decision is deferred to the
/// engine, and it is internal to the provider: nothing outside this module can
/// see it, so no other code can start treating it as a place where actions
/// happen.
@available(iOS 26.0, macOS 26.0, *)
actor AppleFoundationToolCollector {
    private var calls: [AIToolCall] = []

    init() {}

    func record(_ call: AIToolCall) {
        calls.append(call)
    }

    /// Everything proposed so far, clearing the buffer.
    ///
    /// Draining rather than reading means a collector reused across rounds
    /// cannot report a previous round's calls a second time — which would make
    /// the engine execute the same action twice.
    func drain() -> [AIToolCall] {
        defer { calls = [] }
        return calls
    }
}

/// One application tool, as Foundation Models sees it.
///
/// **This type never performs the action.** It converts the model's arguments
/// into an `AIToolCall`, hands it to the collector, and tells the model the
/// request has been passed on. Everything that actually happens — decoding into
/// a typed request, validation, authorization, confirmation, planning,
/// execution — happens afterwards in `AssistantEngine`, exactly as it does for
/// the remote provider.
///
/// That is a security boundary, not a stylistic preference. If this function
/// created the calendar event, then the model's output would *be* the action,
/// and the tool authorizer, the confirmation rules and the platform permission
/// checks would all be bypassed by the one path that most needs them. Hence no
/// EventKit, no AlarmKit, no UserNotifications, no repositories, and no imports
/// that would make any of them reachable from this file.
///
/// It is generic over nothing: one adapter type serves every tool in the
/// catalogue, because `Arguments` is `GeneratedContent` and the parameter
/// schema is built at runtime. See `AppleGenerationSchemaBridge` for why that
/// matters.
@available(iOS 26.0, macOS 26.0, *)
struct AppleFoundationToolAdapter: FoundationModels.Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let name: String
    let description: String
    let parameters: GenerationSchema

    private let collector: AppleFoundationToolCollector

    init(
        name: String,
        description: String,
        parameters: GenerationSchema,
        collector: AppleFoundationToolCollector
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.collector = collector
    }

    /// What the model is told after asking for a tool.
    ///
    /// Carefully worded. The model has to keep reasoning after this, and if it
    /// reads the message as success it will write "Done — I've set that
    /// reminder" to someone whose reminder does not exist yet. The one thing
    /// this app must never do is claim an action happened when it did not.
    ///
    /// It is also not a failure: saying the call failed would invite the model
    /// to apologise, or to try again with different arguments and propose the
    /// same action twice.
    static let proposedOutput = """
        Received. The app has this request and will check it, ask the person to \
        confirm if needed, and carry it out. Nothing has happened yet, so do not \
        tell the person it is done — acknowledge that you have passed it on.
        """

    func call(arguments: GeneratedContent) async throws -> String {
        // Converted, not interpreted. What the arguments *mean* is the
        // application's question, answered by `ToolRequestDecoder` against the
        // same schema every other provider is held to. Deciding here whether a
        // date was sensible would be a second, weaker validator competing with
        // the real one.
        let json = try AppleGenerationSchemaBridge.jsonValue(from: arguments)
        await collector.record(AIToolCall(name: name, arguments: json))
        return Self.proposedOutput
    }
}

@available(iOS 26.0, macOS 26.0, *)
extension AppleFoundationToolAdapter {

    /// Adapters for exactly the tools in this request, and nothing else.
    ///
    /// The model is only ever offered tools built from `AIRequest.tools`, which
    /// the application filled from `ToolCatalog`. There is no name-to-selector
    /// lookup and no dynamic dispatch by string anywhere in this provider, so
    /// there is no mechanism by which the model could reach a function that was
    /// not deliberately published to it.
    ///
    /// A tool whose schema cannot be translated is dropped rather than offered
    /// in a broken state — better for the model not to know about a tool than
    /// to be told about one it cannot call correctly.
    static func adapters(
        for tools: [AIToolSchema],
        collector: AppleFoundationToolCollector
    ) -> [any FoundationModels.Tool] {
        tools.compactMap { tool in
            guard let parameters = try? AppleGenerationSchemaBridge.generationSchema(for: tool)
            else { return nil }
            return AppleFoundationToolAdapter(
                name: tool.name,
                description: tool.description,
                parameters: parameters,
                collector: collector
            )
        }
    }
}

#endif
