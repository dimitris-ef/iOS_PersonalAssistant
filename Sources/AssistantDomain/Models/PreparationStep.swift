import Foundation

/// How much a preparation step matters when time runs short.
///
/// The reason this exists is compression. When someone should have started
/// getting ready twenty minutes ago, the honest response is not to repeat the
/// original plan — it is to say which parts still fit. That requires knowing
/// which parts can go, and only the person who wrote the step down can say.
public enum StepNecessity: String, Hashable, Codable, Sendable, CaseIterable, Comparable {
    /// Without this the thing does not happen. Bring the ID. Leave the house.
    case required
    /// Genuinely helpful, first to go under pressure after `optional`.
    case recommended
    /// Nice if there is time.
    case optional

    /// Ordered by what survives compression: required outranks everything.
    public var rank: Int {
        switch self {
        case .required: return 2
        case .recommended: return 1
        case .optional: return 0
        }
    }

    public static func < (lhs: StepNecessity, rhs: StepNecessity) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// One concrete thing to do before something else.
///
/// ## Why a type and not a string
///
/// "Shower, get dressed, pack documents, leave" as a reminder body is a
/// sentence the app cannot reason about. As four steps with durations it can
/// answer the questions that matter: when should this person start, what is the
/// next thing to do, what gets dropped now that they are late, and is this
/// still achievable at all. Section 17's rule — do not flatten structure the
/// domain can express — is what separates a reminder from support.
///
/// Steps are also what "Help me start" hands back. A task whose first step is
/// written down does not need a language model to be broken down.
public struct PreparationStep: Identifiable, Hashable, Codable, Sendable {
    public typealias ID = Identifier<PreparationStep>

    public var id: ID
    public var title: String
    /// How long this person needs for it. Never negative; bounded at the tool
    /// boundary so a model cannot propose a four-day shower.
    public var estimatedDuration: TimeInterval
    public var necessity: StepNecessity
    /// Position in the sequence. Lower runs first.
    public var sequence: Int
    public var isCompleted: Bool
    public var completedAt: Date?
    /// When the timeline says this step should begin.
    ///
    /// Computed by ``PreparationTimeline`` and written back, so the Today list
    /// and a notification body agree about when to start packing without either
    /// recomputing it.
    public var scheduledStart: Date?

    public init(
        id: ID = ID(),
        title: String,
        estimatedDuration: TimeInterval = 0,
        necessity: StepNecessity = .required,
        sequence: Int = 0,
        isCompleted: Bool = false,
        completedAt: Date? = nil,
        scheduledStart: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.estimatedDuration = max(0, estimatedDuration)
        self.necessity = necessity
        self.sequence = sequence
        self.isCompleted = isCompleted
        self.completedAt = completedAt
        self.scheduledStart = scheduledStart
    }

    /// The identity a step of this name under this parent must have.
    ///
    /// Replanning happens constantly — the event moves, a step is completed,
    /// recovery compresses the plan — and each pass rebuilds the timeline. With
    /// allocated ids every pass would append another "Leave home"; with derived
    /// ones it updates the one that is already there. Section 107, as a
    /// function.
    public static func identity(parent: String, title: String) -> ID {
        ID.deterministic(
            namespace: "preparation-step/\(parent)",
            name: title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )
    }

    public mutating func complete(at date: Date) {
        isCompleted = true
        completedAt = date
    }
}

extension Array where Element == PreparationStep {
    /// In the order they should be done.
    public var ordered: [PreparationStep] {
        sorted { lhs, rhs in
            lhs.sequence == rhs.sequence ? lhs.title < rhs.title : lhs.sequence < rhs.sequence
        }
    }

    /// The next thing to actually do.
    public var nextIncomplete: PreparationStep? {
        ordered.first { !$0.isCompleted }
    }

    /// How long the unfinished steps still need.
    public var remainingDuration: TimeInterval {
        filter { !$0.isCompleted }.reduce(0) { $0 + $1.estimatedDuration }
    }

    public var allCompleted: Bool {
        !isEmpty && allSatisfy(\.isCompleted)
    }
}
