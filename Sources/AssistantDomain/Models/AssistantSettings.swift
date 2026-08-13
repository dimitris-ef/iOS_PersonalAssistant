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

/// How the assistant should behave. Owned by the application; never by a provider.
public struct AssistantSettings: Hashable, Codable, Sendable {
    public var preferredProviderID: AIProviderIdentifier?
    public var preferredModelID: AIModelIdentifier?
    public var routingPolicy: ModelRoutingPolicy
    /// Per-tool authorization. Anything absent falls back to `defaultAuthorization`.
    public var toolAuthorizations: [ToolKind: ToolAuthorization]
    public var defaultAuthorization: ToolAuthorization
    public var support: SupportPreferences
    /// How many past messages to include as provider context.
    public var conversationContextLimit: Int
    public var memoryContextLimit: Int

    public init(
        preferredProviderID: AIProviderIdentifier? = nil,
        preferredModelID: AIModelIdentifier? = nil,
        routingPolicy: ModelRoutingPolicy = .preferOnDevice,
        toolAuthorizations: [ToolKind: ToolAuthorization] = AssistantSettings.defaultToolAuthorizations,
        defaultAuthorization: ToolAuthorization = .allowed,
        support: SupportPreferences = SupportPreferences(),
        conversationContextLimit: Int = 20,
        memoryContextLimit: Int = 10
    ) {
        self.preferredProviderID = preferredProviderID
        self.preferredModelID = preferredModelID
        self.routingPolicy = routingPolicy
        self.toolAuthorizations = toolAuthorizations
        self.defaultAuthorization = defaultAuthorization
        self.support = support
        self.conversationContextLimit = conversationContextLimit
        self.memoryContextLimit = memoryContextLimit
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
