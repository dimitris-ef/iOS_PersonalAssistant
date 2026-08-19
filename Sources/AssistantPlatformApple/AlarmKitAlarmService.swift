import AssistantDomain
import AssistantPlatform
import Foundation

#if canImport(AlarmKit)
import AlarmKit
import SwiftUI

/// The metadata attached to every alarm this app schedules.
///
/// Empty, and that is the design. `AlarmMetadata` is handed to the system and
/// surfaced in alarm UI outside this app's process, so nothing about the task
/// goes in it — not the title, not the deadline, not the identifier of anything
/// the assistant knows. The alarm's label is already visible because the user
/// asked for it to be; nothing else needs to leave.
@available(iOS 26.0, *)
struct AssistantAlarmMetadata: AlarmMetadata {
    init() {}
}

/// Real alarms: the ones that sound through the ringer switch and through
/// Focus, and that have to be dismissed rather than noticed.
///
/// This is a genuinely different capability from a notification, which is why
/// `AlarmService` is its own protocol. "Remind me at ten" is a notification.
/// "Make sure I actually wake up" is this — and the difference between them is
/// the difference between a suggestion and something that works.
@available(iOS 26.0, *)
actor AlarmKitAlarmService: AlarmService {
    nonisolated let platformName = "AlarmKit"
    nonisolated let fidelity: PlatformFidelity = .live

    /// Labels for alarms this process scheduled.
    ///
    /// AlarmKit's `Alarm` carries an id, a schedule and a state — not the text
    /// that was shown. The label lives in the app's own store (a reminder
    /// stage, or a task title), and this is a convenience mirror so
    /// `scheduledAlarms()` can return something readable without a round trip.
    /// It is not a source of truth: after a relaunch it is empty, and an alarm
    /// the system still holds is reported with a neutral label rather than a
    /// guessed one.
    private var labels: [UUID: String] = [:]

    private var manager: AlarmManager { AlarmManager.shared }

    func schedule(_ request: AlarmRequest) async throws -> PlatformReceipt {
        guard await ensureAuthorized() else {
            throw PlatformError.permissionDenied(capability: .alarms)
        }
        guard request.fireDate.timeIntervalSinceNow > 0 else {
            throw PlatformError.invalidRequest("An alarm cannot be set for a time that has passed.")
        }

        let configuration = try self.configuration(for: request)

        do {
            _ = try await manager.schedule(id: request.id.rawValue, configuration: configuration)
        } catch {
            // The thrown value is an `AlarmError`; its description is not
            // surfaced, because the point of failing here is that the caller
            // must not be told the alarm was set.
            ApplePlatformLog.error("Alarm scheduling failed")
            throw PlatformError.underlying("The alarm could not be set.")
        }

        labels[request.id.rawValue] = request.label

        var description = "Alarm set: \(request.label) — \(Self.format(request.fireDate))"
        if request.recurrence != nil {
            // Said plainly rather than silently dropped. The user asked for a
            // repeating alarm and is getting one occurrence.
            description += " (this one time only — repeating alarms are not set up yet)"
        }
        return receipt(description, identifier: request.id.rawValue.uuidString)
    }

    func update(
        _ request: AlarmRequest
    ) async throws -> (request: AlarmRequest, receipt: PlatformReceipt) {
        // Cancel then reschedule under the same id. AlarmKit has no mutate
        // call, and doing it in this order means the worst outcome of a failure
        // halfway through is no alarm rather than two.
        _ = try? cancelAlarm(id: request.id)
        let receipt = try await schedule(request)
        return (request, receipt)
    }

    func cancel(id: AlarmRequest.ID) async throws -> PlatformReceipt {
        try cancelAlarm(id: id)
    }

    func scheduledAlarms() async throws -> [AlarmRequest] {
        let alarms: [Alarm]
        do {
            alarms = try manager.alarms
        } catch {
            throw PlatformError.underlying("The scheduled alarms could not be read.")
        }

        return alarms.compactMap { alarm -> AlarmRequest? in
            guard let fireDate = Self.fireDate(of: alarm) else { return nil }
            return AlarmRequest(
                id: AlarmRequest.ID(alarm.id),
                label: labels[alarm.id] ?? "Alarm",
                fireDate: fireDate
            )
        }
        .sorted { $0.fireDate < $1.fireDate }
    }

    // MARK: Authorization

    func authorization() -> AppleAlarmAuthorization {
        switch manager.authorizationState {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized: return .authorized
        @unknown default: return .denied
        }
    }

    func requestAuthorization() async -> AppleAlarmAuthorization {
        do {
            _ = try await manager.requestAuthorization()
        } catch {
            ApplePlatformLog.error("Alarm authorization request failed")
        }
        return authorization()
    }

    private func ensureAuthorized() async -> Bool {
        let current = authorization()
        guard current == .notDetermined else { return current == .authorized }
        return await requestAuthorization() == .authorized
    }

    // MARK: Building

    private func configuration(
        for request: AlarmRequest
    ) throws -> AlarmManager.AlarmConfiguration<AssistantAlarmMetadata> {
        let stopButton = AlarmButton(
            text: LocalizedStringResource(stringLiteral: "Done"),
            textColor: .white,
            systemImageName: "checkmark"
        )

        let snoozeButton: AlarmButton? = request.allowsSnooze
            ? AlarmButton(
                text: LocalizedStringResource(stringLiteral: "Snooze"),
                textColor: .white,
                systemImageName: "zzz"
            )
            : nil

        // The deprecated initialiser, on purpose. Its replacement drops
        // `stopButton`, and it arrived partway through the iOS 26 line — using
        // it would fail to compile against the earlier SDKs in that same line,
        // while the deprecated form compiles against all of them.
        // TODO-XCODE: switch to `init(title:secondaryButton:secondaryButtonBehavior:)`
        // once the minimum Xcode for this project is past the change.
        let alert = AlarmPresentation.Alert(
            title: LocalizedStringResource(stringLiteral: request.label),
            stopButton: stopButton,
            secondaryButton: snoozeButton,
            secondaryButtonBehavior: request.allowsSnooze ? .countdown : nil
        )

        let attributes = AlarmAttributes<AssistantAlarmMetadata>(
            presentation: AlarmPresentation(alert: alert),
            metadata: AssistantAlarmMetadata(),
            tintColor: Color.accentColor
        )

        // `postAlert` is the snooze interval: how long the countdown runs after
        // the user presses Snooze. `preAlert` stays nil because this is an
        // alarm at a fixed time, not a timer counting down to one.
        //
        // `maximumSnoozes` is not expressed here, because AlarmKit does not
        // have it — the system will let someone snooze indefinitely. The limit
        // is enforced where it can be: the follow-up ladder counts snoozes and
        // escalates, which is a better answer than a cap the OS silently
        // ignores.
        let countdown = request.allowsSnooze
            ? Alarm.CountdownDuration(preAlert: nil, postAlert: request.snoozeDuration)
            : nil

        return AlarmManager.AlarmConfiguration(
            countdownDuration: countdown,
            schedule: .fixed(request.fireDate),
            attributes: attributes
        )
    }

    private func cancelAlarm(id: AlarmRequest.ID) throws -> PlatformReceipt {
        do {
            try manager.cancel(id: id.rawValue)
        } catch {
            throw PlatformError.notFound(identifier: id.description)
        }
        let label = labels.removeValue(forKey: id.rawValue) ?? "Alarm"
        return receipt("Alarm cancelled: \(label)", identifier: id.rawValue.uuidString)
    }

    private static func fireDate(of alarm: Alarm) -> Date? {
        switch alarm.schedule {
        case .fixed(let date):
            return date
        default:
            // A relative schedule has no single absolute date, and this layer
            // never creates one. Reporting nothing beats reporting a time that
            // is not when the alarm will sound.
            return nil
        }
    }

    private static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE d MMM HH:mm"
        return formatter.string(from: date)
    }

    private nonisolated func receipt(
        _ description: String,
        identifier: String? = nil
    ) -> PlatformReceipt {
        PlatformReceipt(
            description: description,
            fidelity: fidelity,
            platformName: platformName,
            externalIdentifier: identifier
        )
    }
}
#endif
