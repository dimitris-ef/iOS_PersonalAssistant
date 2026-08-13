import AssistantAI
import AssistantDomain
import AssistantTools
import Foundation

/// A deterministic stand-in for a real model.
///
/// It exists so the architecture can be run and tested end to end on a machine
/// with no Apple SDK and no API key. It reports its kind as `.development` and
/// its display name says what it is — nothing in the app treats it as an AI, and
/// it must not be registered in a shipping build.
public struct ScriptedDevProvider: AIProvider {
    public static let providerID: AIProviderIdentifier = "dev.scripted"

    public let metadata: AIProviderMetadata
    private let parser: DevPhraseParser
    private let dateProvider: any DateProvider

    public init(dateProvider: any DateProvider = SystemDateProvider()) {
        self.dateProvider = dateProvider
        self.parser = DevPhraseParser(calendar: dateProvider.calendar)
        self.metadata = AIProviderMetadata(
            id: Self.providerID,
            displayName: "Scripted development provider (not a real model)",
            kind: .development,
            requiresNetwork: false,
            requiresCredentials: false,
            capabilityRank: 1
        )
    }

    public func availability() async -> AIProviderAvailability { .available }

    public func availableModels() async throws -> [AIModel] {
        [
            AIModel(
                id: "dev.scripted",
                displayName: "Scripted rules",
                contextWindow: nil,
                supportsNativeToolCalling: true,
                isOnDevice: true
            )
        ]
    }

    public func respond(to request: AIRequest) async throws -> AIResponse {
        guard let lastUserMessage = request.messages.last(where: { $0.role == .user }) else {
            return AIResponse(
                text: "I did not catch that.",
                providerID: metadata.id
            )
        }

        let now = dateProvider.now
        let intent = parser.parse(lastUserMessage.content, now: now)

        switch intent {
        case .calendarEvent(let title, let start, let location):
            let input = CreateCalendarEventInput(
                title: title,
                start: start,
                location: location,
                wantsReminderSupport: true
            )
            return try response(
                text: "I've added \(title) for \(Self.describe(start, calendar: dateProvider.calendar)).",
                tool: .createCalendarEvent,
                input: input
            )

        case .task(let title, let timing):
            var input = CreateTaskInput(title: title, wantsReminderSupport: true)
            switch timing {
            case .fixed(let date): input.fixedDate = date
            case .dueBy(let date): input.dueDate = date
            case .window(let window): input.flexibleWindow = window
            case .unspecified: break
            }
            return try response(
                text: "I'll keep track of \"\(title)\" and remind you.",
                tool: .createTask,
                input: input
            )

        case .alarm(let label, let fireDate):
            let input = CreateAlarmInput(label: label, fireDate: fireDate, allowsSnooze: true)
            return try response(
                text: "Alarm set for \(Self.describe(fireDate, calendar: dateProvider.calendar)).",
                tool: .createAlarm,
                input: input
            )

        case .memory(let content, let kind):
            let input = StoreMemoryInput(content: content, kind: kind, salience: 0.7)
            return try response(text: "Noted — I'll remember that.", tool: .storeMemory, input: input)

        case .upcomingSchedule:
            let input = GetUpcomingScheduleInput(limit: 10)
            return try response(
                text: "Here's what's coming up.",
                tool: .getUpcomingSchedule,
                input: input
            )

        case .unknown:
            return AIResponse(
                text: "I didn't understand that well enough to act on it. "
                    + "(The scripted development provider only recognises a few phrasings.)",
                providerID: metadata.id
            )
        }
    }

    private func response<Input: Encodable>(
        text: String,
        tool: ToolKind,
        input: Input
    ) throws -> AIResponse {
        let arguments = try JSONValue.encoding(input)
        return AIResponse(
            text: text,
            toolCalls: [AIToolCall(name: tool.rawValue, arguments: arguments)],
            stopReason: .toolCalls,
            providerID: metadata.id,
            modelID: "dev.scripted"
        )
    }

    static func describe(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEEE d MMMM 'at' HH:mm"
        return formatter.string(from: date)
    }
}
