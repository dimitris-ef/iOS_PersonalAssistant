import Foundation

/// What the user asked the keyboard to do with some text.
///
/// Section 17: a small set. Every one of these is a transformation of text the
/// keyboard legitimately has, and none of them is a command that changes
/// anything in the app — that distinction is what keeps the keyboard out of the
/// tool pipeline (section 25).
public enum KeyboardAssistantOperation: String, Codable, Sendable, CaseIterable {
    /// Same meaning, better sentence.
    case improve
    /// Shorter.
    case shorten
    /// Punctuation, spelling and agreement only.
    case grammar
    /// The one that is not a transformation: a question for the assistant.
    case assistantQuery

    public var title: String {
        switch self {
        case .improve: return "Improve"
        case .shorten: return "Shorten"
        case .grammar: return "Fix Grammar"
        case .assistantQuery: return "Ask Assistant"
        }
    }

    /// Whether this can be answered without a model.
    ///
    /// Section 24: a deterministic tidy-up is allowed to happen inside the
    /// extension. Actual rewriting is not, because doing it well needs a model
    /// and a second model stack in the keyboard is what section 16 forbids.
    public var isLocallySatisfiable: Bool { false }
}

/// One request handed from the keyboard to the application.
///
/// ## Why this exists rather than an `AIRequest`
///
/// Section 21. An `AIRequest` carries a system prompt, assembled memory
/// context, a tool catalogue and a provider identifier. Serializing one into a
/// shared container would put the user's retrieved memories and the app's
/// prompt into a file the keyboard process can read — for a feature that needs
/// four fields.
///
/// It also has the wrong shape: the keyboard must not know which provider will
/// answer (section 26). It states an operation and some text; routing is the
/// application's business and stays there.
public struct KeyboardAssistantRequest: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var operation: KeyboardAssistantOperation
    /// Exactly the text the user selected or typed, and nothing else.
    ///
    /// Section 93: not the document, not the surrounding context, not anything
    /// typed earlier. The keyboard reads what `textDocumentProxy` exposes for
    /// this operation and sends that.
    public var inputText: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        operation: KeyboardAssistantOperation,
        inputText: String,
        createdAt: Date
    ) {
        self.id = id
        self.operation = operation
        self.inputText = inputText
        self.createdAt = createdAt
    }
}

/// What came back.
public struct KeyboardAssistantResult: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable, CaseIterable {
        case pending
        case completed
        case failed
        case cancelled
        /// The environment could not run it — no Full Access, or the app was
        /// never opened to service the request. Distinct from `failed` because
        /// the remedy is different and the user should be told which it is.
        case unavailable
    }

    public var requestID: UUID
    public var status: Status
    /// The replacement text, on success. Never applied automatically — the user
    /// accepts it (section 134).
    public var text: String?
    /// One short sentence. Never a provider diagnostic, a stack trace or a
    /// model name (section 22).
    public var error: String?
    public var completedAt: Date?

    public init(
        requestID: UUID,
        status: Status,
        text: String? = nil,
        error: String? = nil,
        completedAt: Date? = nil
    ) {
        self.requestID = requestID
        self.status = status
        self.text = text
        self.error = error
        self.completedAt = completedAt
    }

    public static func unavailable(_ requestID: UUID, reason: String) -> KeyboardAssistantResult {
        KeyboardAssistantResult(requestID: requestID, status: .unavailable, error: reason)
    }
}

/// The keyboard's half of the shared container.
///
/// One pending request and one result. Not a queue: a keyboard shows one
/// suggestion at a time, and a backlog of transformations nobody is waiting for
/// is a backlog of the user's text sitting in a file.
public struct KeyboardExchange: SystemSurfaceSnapshot {
    public static let storageKey = "keyboard-exchange"

    public var snapshotVersion: Int
    public var generatedAt: Date
    public var validUntil: Date?
    public var request: KeyboardAssistantRequest?
    public var result: KeyboardAssistantResult?

    public init(
        snapshotVersion: Int = KeyboardExchange.currentVersion,
        generatedAt: Date,
        validUntil: Date? = nil,
        request: KeyboardAssistantRequest? = nil,
        result: KeyboardAssistantResult? = nil
    ) {
        self.snapshotVersion = snapshotVersion
        self.generatedAt = generatedAt
        self.validUntil = validUntil
        self.request = request
        self.result = result
    }
}

/// What the keyboard is allowed to offer, decided by the app.
///
/// The keyboard reads this instead of deciding for itself, so "the user turned
/// assistant features off" is answered in one place. Notably it carries **no**
/// provider identifier, endpoint or credential — section 8, and section 26.
public struct KeyboardConfigurationSnapshot: SystemSurfaceSnapshot {
    public static let storageKey = "keyboard-configuration"

    public var snapshotVersion: Int
    public var generatedAt: Date
    public var validUntil: Date?
    /// False when the user has switched assistant help off in Settings.
    public var assistantActionsEnabled: Bool
    /// The operations to show, in order.
    public var operations: [KeyboardAssistantOperation]

    public init(
        snapshotVersion: Int = KeyboardConfigurationSnapshot.currentVersion,
        generatedAt: Date,
        validUntil: Date? = nil,
        assistantActionsEnabled: Bool = true,
        operations: [KeyboardAssistantOperation] = KeyboardAssistantOperation.allCases
    ) {
        self.snapshotVersion = snapshotVersion
        self.generatedAt = generatedAt
        self.validUntil = validUntil
        self.assistantActionsEnabled = assistantActionsEnabled
        self.operations = operations
    }

    /// What a keyboard with no shared container should assume.
    ///
    /// Section 12: typing works, assistant actions are shown as unavailable
    /// rather than hidden — a button that vanishes teaches the user the feature
    /// is broken, where a button that explains itself teaches them what to do.
    public static func withoutSharedAccess(at date: Date) -> KeyboardConfigurationSnapshot {
        KeyboardConfigurationSnapshot(
            generatedAt: date,
            assistantActionsEnabled: false,
            operations: []
        )
    }
}
