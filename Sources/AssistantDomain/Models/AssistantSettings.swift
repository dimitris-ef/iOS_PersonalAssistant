import Foundation

/// Stable identifier for an AI provider (e.g. "apple.foundation-models").
///
/// Lives in the domain layer so settings can reference a provider without the
/// domain depending on the AI module.
public struct AIProviderIdentifier: Hashable, Codable, Sendable, CustomStringConvertible,
                                    ExpressibleByStringLiteral {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public var description: String { rawValue }
}

/// Stable identifier for a model offered by a provider.
public struct AIModelIdentifier: Hashable, Codable, Sendable, CustomStringConvertible,
                                 ExpressibleByStringLiteral {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public var description: String { rawValue }
}

/// How to choose a provider when several are available.
public enum ModelRoutingPolicy: String, Hashable, Codable, Sendable, CaseIterable {
    /// Prefer on-device inference; fall back only if nothing local is ready.
    case preferOnDevice
    /// Prefer the most capable provider available.
    case preferMostCapable
    /// Use exactly the provider named in settings, and fail if it is unavailable.
    case explicit
}

/// Tunables the reminder planner reads. Changing these changes the shape of
/// generated plans without touching planner code.
public struct SupportPreferences: Hashable, Codable, Sendable {
    /// How many days ahead to give first notice for important commitments.
    public var advanceNoticeDays: [Int]
    /// When the "you have this today" reminder lands.
    public var morningOfTime: TimeOfDay
    /// Lead time for the "start getting ready" stage, on top of travel time.
    public var preparationLeadDefault: TimeInterval
    /// Lead time for the final "starting soon" nudge.
    public var finalCallLead: TimeInterval
    public var defaultEscalation: EscalationLevel
    public var followUp: FollowUpPolicy
    public var snooze: SnoozePolicy
    public var completion: CompletionPolicy
    /// Nudges generated per day for flexible, deadline-only work.
    public var flexibleNudgesPerDay: Int

    public init(
        advanceNoticeDays: [Int] = [3],
        morningOfTime: TimeOfDay = TimeOfDay(hour: 8),
        preparationLeadDefault: TimeInterval = TimeSpan.minutes(30),
        finalCallLead: TimeInterval = TimeSpan.minutes(10),
        defaultEscalation: EscalationLevel = .standard,
        followUp: FollowUpPolicy = FollowUpPolicy(),
        snooze: SnoozePolicy = SnoozePolicy(),
        completion: CompletionPolicy = CompletionPolicy(),
        flexibleNudgesPerDay: Int = 1
    ) {
        self.advanceNoticeDays = advanceNoticeDays
        self.morningOfTime = morningOfTime
        self.preparationLeadDefault = preparationLeadDefault
        self.finalCallLead = finalCallLead
        self.defaultEscalation = defaultEscalation
        self.followUp = followUp
        self.snooze = snooze
        self.completion = completion
        self.flexibleNudgesPerDay = flexibleNudgesPerDay
    }
}

/// How the assistant should sound, and whether it should.
///
/// Conservative by default: nothing is ever read aloud until the user asks for
/// it. An assistant that starts talking on a train because someone typed a
/// question is an assistant people turn off.
public struct VoicePreferences: Hashable, Codable, Sendable {
    /// Read replies aloud after the user *spoke* to the assistant.
    ///
    /// Off by default. When on, it applies only to spoken requests, which is
    /// the conversational case where a reply you have to read defeats the point
    /// of having talked.
    public var speaksReplies: Bool
    /// Also read replies to messages that were typed.
    ///
    /// Separate, and off by default even when `speaksReplies` is on. Typing is
    /// what people do when they cannot or do not want to make noise, and
    /// answering out loud misreads the room — literally.
    public var speaksTypedReplies: Bool
    /// BCP-47 identifier for recognition and synthesis, or nil to follow the
    /// system.
    ///
    /// Nil by default rather than "en-US". The assistant's whole value is
    /// understanding how someone actually talks, and a default that forces a
    /// second language on them is a default that excludes them.
    public var localeIdentifier: String?

    public init(
        speaksReplies: Bool = false,
        speaksTypedReplies: Bool = false,
        localeIdentifier: String? = nil
    ) {
        self.speaksReplies = speaksReplies
        self.speaksTypedReplies = speaksTypedReplies
        self.localeIdentifier = localeIdentifier
    }

    /// Whether this reply should be spoken, given how the request arrived.
    ///
    /// One function, so the rule cannot drift between the composer, the
    /// settings screen and whatever asks next.
    public func shouldSpeak(replyTo source: MessageInputSource) -> Bool {
        switch source {
        case .voice: return speaksReplies
        case .typed: return speaksReplies && speaksTypedReplies
        }
    }
}

/// How a message reached the assistant.
///
/// Presentation metadata, deliberately not stored: a message is a message, and
/// forking the conversation into spoken and typed halves would mean every
/// reader had to handle both. It exists only so the reply can decide whether to
/// speak.
public enum MessageInputSource: String, Hashable, Codable, Sendable {
    case typed
    case voice
}

/// How the assistant should behave. Owned by the application; never by a provider.
public struct AssistantSettings: Hashable, Codable, Sendable {
    public var preferredProviderID: AIProviderIdentifier?
    public var preferredModelID: AIModelIdentifier?
    /// Which downloaded model Local AI should use.
    ///
    /// Separate from ``preferredModelID`` on purpose. That one names the model
    /// for whichever provider is selected — a cloud model name, say. This one
    /// survives switching away to the cloud and back, so a user who tries the
    /// remote model for an afternoon does not come back to Local AI having lost
    /// which of their downloaded models they were using.
    ///
    /// Section 64: it holds the model's *logical identifier* and nothing about
    /// the loaded runtime. There is no native state that can be persisted, and
    /// pretending otherwise would mean storing a pointer.
    public var selectedLocalModelID: AIModelIdentifier?
    public var routingPolicy: ModelRoutingPolicy
    /// Per-tool authorization. Anything absent falls back to `defaultAuthorization`.
    public var toolAuthorizations: [ToolKind: ToolAuthorization]
    public var defaultAuthorization: ToolAuthorization
    public var support: SupportPreferences
    /// How many past messages to include as provider context.
    public var conversationContextLimit: Int
    public var memoryContextLimit: Int
    public var voice: VoicePreferences
    /// Which model interprets phone actions (Part 3, section 1).
    ///
    /// Deliberately its own value rather than another loose field beside
    /// `selectedLocalModelID`: the two are next to each other in this struct
    /// and must never be read as interchangeable, and a named type is what
    /// makes a call site say which one it meant.
    public var actionModel: ActionModelConfiguration

    public init(
        preferredProviderID: AIProviderIdentifier? = nil,
        preferredModelID: AIModelIdentifier? = nil,
        selectedLocalModelID: AIModelIdentifier? = nil,
        routingPolicy: ModelRoutingPolicy = .preferOnDevice,
        toolAuthorizations: [ToolKind: ToolAuthorization] = AssistantSettings.defaultToolAuthorizations,
        defaultAuthorization: ToolAuthorization = .allowed,
        support: SupportPreferences = SupportPreferences(),
        conversationContextLimit: Int = 20,
        memoryContextLimit: Int = 10,
        voice: VoicePreferences = VoicePreferences(),
        actionModel: ActionModelConfiguration = ActionModelConfiguration()
    ) {
        self.preferredProviderID = preferredProviderID
        self.preferredModelID = preferredModelID
        self.selectedLocalModelID = selectedLocalModelID
        self.routingPolicy = routingPolicy
        self.toolAuthorizations = toolAuthorizations
        self.defaultAuthorization = defaultAuthorization
        self.support = support
        self.conversationContextLimit = conversationContextLimit
        self.memoryContextLimit = memoryContextLimit
        self.voice = voice
        self.actionModel = actionModel
    }

    /// Destructive tools ask first; everything else runs.
    public static let defaultToolAuthorizations: [ToolKind: ToolAuthorization] = [
        .deleteCalendarEvent: .requiresConfirmation,
        .updateCalendarEvent: .requiresConfirmation,
        .cancelAlarm: .requiresConfirmation,
    ]

    public func authorization(for kind: ToolKind) -> ToolAuthorization {
        toolAuthorizations[kind] ?? defaultAuthorization
    }
}
