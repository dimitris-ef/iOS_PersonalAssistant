#if canImport(SwiftData)

import AssistantDomain
import Foundation
import SwiftData

/// `AssistantSettings` ↔ `SDAssistantSettings`.
///
/// `preferredProviderID` is stored here, so the chosen model survives a
/// relaunch. It is an identifier and nothing else — the endpoint and model name
/// live in `UserDefaults` and the API key lives in the Keychain. Selecting a
/// provider therefore rewrites one string in this row and touches no user data
/// at all: conversations, tasks, memories and the profile are in their own
/// tables, unaware that a provider exists.
@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
enum SettingsMapper {
    static let entity = "settings"

    static func makeRow(from settings: AssistantSettings) -> SDAssistantSettings {
        let support = settings.support

        return SDAssistantSettings(
            id: SingletonRecord.settings,
            preferredProviderID: settings.preferredProviderID?.rawValue,
            preferredModelID: settings.preferredModelID?.rawValue,
            routingPolicyRaw: settings.routingPolicy.rawValue,
            toolAuthorizations: encodeAuthorizations(settings.toolAuthorizations),
            defaultAuthorizationRaw: settings.defaultAuthorization.rawValue,
            conversationContextLimit: settings.conversationContextLimit,
            memoryContextLimit: settings.memoryContextLimit,
            supportAdvanceNoticeDays: support.advanceNoticeDays,
            supportMorningOfHour: support.morningOfTime.hour,
            supportMorningOfMinute: support.morningOfTime.minute,
            supportPreparationLeadDefault: support.preparationLeadDefault,
            supportFinalCallLead: support.finalCallLead,
            supportDefaultEscalationRaw: support.defaultEscalation.rawValue,
            supportFlexibleNudgesPerDay: support.flexibleNudgesPerDay,
            supportFollowUpIsEnabled: support.followUp.isEnabled,
            supportFollowUpMaximum: support.followUp.maximumFollowUps,
            supportFollowUpInterval: support.followUp.interval,
            supportFollowUpEscalatesEachTime: support.followUp.escalatesEachTime,
            supportSnoozeIsAllowed: support.snooze.isAllowed,
            supportSnoozeDefaultDuration: support.snooze.defaultDuration,
            supportSnoozeMaximum: support.snooze.maximumSnoozes,
            supportSnoozeEscalateAfter: support.snooze.escalateAfterSnoozes,
            supportCompletionRequiresExplicitConfirmation:
                support.completion.requiresExplicitConfirmation,
            supportCompletionMarkMissedAfter: support.completion.markMissedAfter,
            voiceSpeaksReplies: settings.voice.speaksReplies,
            voiceSpeaksTypedReplies: settings.voice.speaksTypedReplies,
            voiceLocaleIdentifier: settings.voice.localeIdentifier,
            selectedLocalModelID: settings.selectedLocalModelID?.rawValue,
            selectedActionModelID: settings.actionModel.selectedModelID?.rawValue,
            actionModelEnabled: settings.actionModel.isEnabled
        )
    }

    /// Overwrites the single settings row.
    ///
    /// There is exactly one, at `SingletonRecord.settings`, so changing a
    /// preference updates it rather than appending another set of settings on
    /// every launch.
    static func update(_ row: SDAssistantSettings, from settings: AssistantSettings) {
        let support = settings.support

        row.preferredProviderID = settings.preferredProviderID?.rawValue
        row.preferredModelID = settings.preferredModelID?.rawValue
        row.routingPolicyRaw = settings.routingPolicy.rawValue
        row.toolAuthorizations = encodeAuthorizations(settings.toolAuthorizations)
        row.defaultAuthorizationRaw = settings.defaultAuthorization.rawValue
        row.conversationContextLimit = settings.conversationContextLimit
        row.memoryContextLimit = settings.memoryContextLimit
        row.supportAdvanceNoticeDays = support.advanceNoticeDays
        row.supportMorningOfHour = support.morningOfTime.hour
        row.supportMorningOfMinute = support.morningOfTime.minute
        row.supportPreparationLeadDefault = support.preparationLeadDefault
        row.supportFinalCallLead = support.finalCallLead
        row.supportDefaultEscalationRaw = support.defaultEscalation.rawValue
        row.supportFlexibleNudgesPerDay = support.flexibleNudgesPerDay
        row.supportFollowUpIsEnabled = support.followUp.isEnabled
        row.supportFollowUpMaximum = support.followUp.maximumFollowUps
        row.supportFollowUpInterval = support.followUp.interval
        row.supportFollowUpEscalatesEachTime = support.followUp.escalatesEachTime
        row.supportSnoozeIsAllowed = support.snooze.isAllowed
        row.supportSnoozeDefaultDuration = support.snooze.defaultDuration
        row.supportSnoozeMaximum = support.snooze.maximumSnoozes
        row.supportSnoozeEscalateAfter = support.snooze.escalateAfterSnoozes
        row.supportCompletionRequiresExplicitConfirmation = support.completion.requiresExplicitConfirmation
        row.supportCompletionMarkMissedAfter = support.completion.markMissedAfter
        row.voiceSpeaksReplies = settings.voice.speaksReplies
        row.voiceSpeaksTypedReplies = settings.voice.speaksTypedReplies
        row.voiceLocaleIdentifier = settings.voice.localeIdentifier
        row.selectedLocalModelID = settings.selectedLocalModelID?.rawValue
        // Written beside the chat model and never *from* it: two columns, two
        // preferences (Part 3, section 1).
        row.selectedActionModelID = settings.actionModel.selectedModelID?.rawValue
        row.actionModelEnabled = settings.actionModel.isEnabled
    }

    static func makeDomain(from row: SDAssistantSettings) throws -> AssistantSettings {
        AssistantSettings(
            preferredProviderID: row.preferredProviderID.map { AIProviderIdentifier($0) },
            preferredModelID: row.preferredModelID.map { AIModelIdentifier($0) },
            selectedLocalModelID: row.selectedLocalModelID.map { AIModelIdentifier($0) },
            routingPolicy: try decodeEnum(
                ModelRoutingPolicy.self,
                from: row.routingPolicyRaw,
                entity: entity,
                field: "routing policy"
            ),
            toolAuthorizations: try decodeAuthorizations(row.toolAuthorizations),
            defaultAuthorization: try decodeEnum(
                ToolAuthorization.self,
                from: row.defaultAuthorizationRaw,
                entity: entity,
                field: "default authorization"
            ),
            support: SupportPreferences(
                advanceNoticeDays: row.supportAdvanceNoticeDays,
                morningOfTime: TimeOfDay(hour: row.supportMorningOfHour, minute: row.supportMorningOfMinute),
                preparationLeadDefault: row.supportPreparationLeadDefault,
                finalCallLead: row.supportFinalCallLead,
                defaultEscalation: try decodeEnum(
                    EscalationLevel.self,
                    from: row.supportDefaultEscalationRaw,
                    entity: entity,
                    field: "default escalation"
                ),
                followUp: FollowUpPolicy(
                    isEnabled: row.supportFollowUpIsEnabled,
                    maximumFollowUps: row.supportFollowUpMaximum,
                    interval: row.supportFollowUpInterval,
                    escalatesEachTime: row.supportFollowUpEscalatesEachTime
                ),
                snooze: SnoozePolicy(
                    isAllowed: row.supportSnoozeIsAllowed,
                    defaultDuration: row.supportSnoozeDefaultDuration,
                    maximumSnoozes: row.supportSnoozeMaximum,
                    escalateAfterSnoozes: row.supportSnoozeEscalateAfter
                ),
                completion: CompletionPolicy(
                    requiresExplicitConfirmation: row.supportCompletionRequiresExplicitConfirmation,
                    markMissedAfter: row.supportCompletionMarkMissedAfter
                ),
                flexibleNudgesPerDay: row.supportFlexibleNudgesPerDay
            ),
            conversationContextLimit: row.conversationContextLimit,
            memoryContextLimit: row.memoryContextLimit,
            voice: VoicePreferences(
                speaksReplies: row.voiceSpeaksReplies,
                speaksTypedReplies: row.voiceSpeaksTypedReplies,
                localeIdentifier: row.voiceLocaleIdentifier
            ),
            actionModel: ActionModelConfiguration(
                selectedModelID: row.selectedActionModelID.map { AIModelIdentifier($0) },
                isEnabled: row.actionModelEnabled
            )
        )
    }

    // MARK: Tool authorizations

    private static func encodeAuthorizations(
        _ authorizations: [ToolKind: ToolAuthorization]
    ) -> [String: String] {
        var encoded: [String: String] = [:]
        for (kind, authorization) in authorizations {
            encoded[kind.rawValue] = authorization.rawValue
        }
        return encoded
    }

    private static func decodeAuthorizations(
        _ stored: [String: String]
    ) throws -> [ToolKind: ToolAuthorization] {
        var decoded: [ToolKind: ToolAuthorization] = [:]
        for (rawKind, rawAuthorization) in stored {
            // A tool this build does not have is skipped rather than treated as
            // an error: an authorization for a removed tool is harmless, and
            // refusing to load settings because of one would be worse.
            guard let kind = ToolKind(rawValue: rawKind) else { continue }
            decoded[kind] = try decodeEnum(
                ToolAuthorization.self,
                from: rawAuthorization,
                entity: entity,
                field: "authorization for \(rawKind)"
            )
        }
        return decoded
    }
}

/// `UserProfile` ↔ `SDUserProfile`. Also a singleton row.
@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
enum UserProfileMapper {
    static let entity = "profile"

    static func makeRow(from profile: UserProfile) -> SDUserProfile {
        SDUserProfile(
            id: SingletonRecord.profile,
            displayName: profile.displayName,
            timeZoneIdentifier: profile.timeZoneIdentifier,
            wakeHour: profile.wakeTime?.hour,
            wakeMinute: profile.wakeTime?.minute,
            sleepHour: profile.sleepTime?.hour,
            sleepMinute: profile.sleepTime?.minute,
            defaultPreparationDuration: profile.defaultPreparationDuration,
            defaultTravelDuration: profile.defaultTravelDuration,
            quietHoursStartHour: profile.quietHours?.start.hour,
            quietHoursStartMinute: profile.quietHours?.start.minute,
            quietHoursEndHour: profile.quietHours?.end.hour,
            quietHoursEndMinute: profile.quietHours?.end.minute
        )
    }

    static func update(_ row: SDUserProfile, from profile: UserProfile) {
        row.displayName = profile.displayName
        row.timeZoneIdentifier = profile.timeZoneIdentifier
        row.wakeHour = profile.wakeTime?.hour
        row.wakeMinute = profile.wakeTime?.minute
        row.sleepHour = profile.sleepTime?.hour
        row.sleepMinute = profile.sleepTime?.minute
        row.defaultPreparationDuration = profile.defaultPreparationDuration
        row.defaultTravelDuration = profile.defaultTravelDuration
        row.quietHoursStartHour = profile.quietHours?.start.hour
        row.quietHoursStartMinute = profile.quietHours?.start.minute
        row.quietHoursEndHour = profile.quietHours?.end.hour
        row.quietHoursEndMinute = profile.quietHours?.end.minute
    }

    static func makeDomain(from row: SDUserProfile) -> UserProfile {
        let quietHours: DayWindow?
        if let start = TimeOfDay.from(hour: row.quietHoursStartHour, minute: row.quietHoursStartMinute),
           let end = TimeOfDay.from(hour: row.quietHoursEndHour, minute: row.quietHoursEndMinute) {
            quietHours = DayWindow(start: start, end: end)
        } else {
            quietHours = nil
        }

        return UserProfile(
            // The profile's own identifier is the singleton id, so the domain
            // value and the row agree about which profile this is.
            id: UserProfile.ID(row.id),
            displayName: row.displayName,
            timeZoneIdentifier: row.timeZoneIdentifier,
            wakeTime: TimeOfDay.from(hour: row.wakeHour, minute: row.wakeMinute),
            sleepTime: TimeOfDay.from(hour: row.sleepHour, minute: row.sleepMinute),
            defaultPreparationDuration: row.defaultPreparationDuration,
            defaultTravelDuration: row.defaultTravelDuration,
            quietHours: quietHours
        )
    }
}

#endif
