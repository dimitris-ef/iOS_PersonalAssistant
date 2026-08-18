import AssistantDomain
import Foundation

/// Every number that decides what the assistant recalls.
///
/// One value type, so tuning retrieval means editing one file and a test can
/// pin the whole policy. Weights sprinkled through a ranker are how a system
/// ends up with nobody able to say why the camera preference keeps turning up
/// in scheduling questions.
public struct MemoryRelevancePolicy: Hashable, Sendable {
    // MARK: Weights
    //
    // Relevance dominates by design. Salience, recency and confidence adjust
    // the order of things that are *already* on topic; none of them can carry
    // an unrelated memory into the prompt on its own, which is exactly the
    // failure this milestone exists to fix.

    public var relevanceWeight: Double
    public var salienceWeight: Double
    public var recencyWeight: Double
    public var confidenceWeight: Double
    public var categoryWeight: Double

    // MARK: Selection

    /// Below this final score, a memory is not worth the context it costs.
    ///
    /// The reason five slots do not mean five memories: if only one thing is
    /// relevant, one is what gets sent.
    public var minimumScore: Double

    /// The relevance a memory must reach before anything else about it counts.
    ///
    /// A weighted sum alone does not give relevance the veto the design claims
    /// for it. A memory with nothing to do with the request still collects
    /// salience, confidence and category points, and enough of those clear any
    /// score threshold on their own — which is exactly the failure this
    /// milestone exists to fix, arriving by a different route. So relevance is
    /// a gate as well as a weight: no lexical connection to the request, no
    /// place in the prompt, however important or certain the memory is.
    ///
    /// Set just above zero on purpose. The matcher already returns zero when
    /// two texts share no content word, so this asks only "is there any
    /// connection at all?" — judging *how strong* that connection needs to be
    /// is ``minimumScore``'s job, weighed against everything else.
    public var minimumRelevance: Double

    /// The most memories injected into any one request.
    public var maximumMemories: Int

    /// Roughly how much text the memory section may occupy.
    ///
    /// Characters rather than tokens: token counting is provider-specific and
    /// there is no abstraction for it, whereas a character budget is honest
    /// about being approximate and works identically everywhere.
    public var characterBudget: Int

    /// How long until a memory's recency contribution halves.
    ///
    /// Long on purpose. A commute time learned a year ago is more useful than
    /// yesterday's note about shampoo, and a decay that forgot that would make
    /// the assistant worse the longer it knew someone.
    public var recencyHalfLife: TimeInterval

    /// The floor recency can decay to.
    ///
    /// Never zero: an old memory loses its recency bonus, it does not become
    /// ineligible.
    public var recencyFloor: Double

    public init(
        relevanceWeight: Double = 1.0,
        salienceWeight: Double = 0.25,
        recencyWeight: Double = 0.15,
        confidenceWeight: Double = 0.2,
        categoryWeight: Double = 0.2,
        minimumScore: Double = 0.18,
        minimumRelevance: Double = 0.05,
        maximumMemories: Int = 5,
        characterBudget: Int = 600,
        recencyHalfLife: TimeInterval = TimeSpan.days(180),
        recencyFloor: Double = 0.25
    ) {
        self.relevanceWeight = relevanceWeight
        self.salienceWeight = salienceWeight
        self.recencyWeight = recencyWeight
        self.confidenceWeight = confidenceWeight
        self.categoryWeight = categoryWeight
        self.minimumScore = minimumScore
        self.minimumRelevance = minimumRelevance
        self.maximumMemories = maximumMemories
        self.characterBudget = characterBudget
        self.recencyHalfLife = recencyHalfLife
        self.recencyFloor = recencyFloor
    }

    public static let `default` = MemoryRelevancePolicy()

    /// Recency as a 0...1 factor, halving every `recencyHalfLife`.
    public func recency(of date: Date, now: Date) -> Double {
        let age = max(0, now.timeIntervalSince(date))
        let decayed = pow(0.5, age / recencyHalfLife)
        return max(recencyFloor, min(1, decayed))
    }
}

/// What the current request seems to be about.
///
/// Deliberately a handful of broad situations rather than an intent classifier.
/// The goal is a nudge — a scheduling question should prefer routines and
/// places over camera preferences — not a taxonomy of everything a person might
/// ask. Anything unrecognised is `.general`, which weights every category
/// equally and lets relevance decide alone.
public enum MemoryQueryIntent: String, Hashable, Sendable, CaseIterable {
    /// Times, leaving, arriving, getting ready.
    case scheduling
    /// How the assistant should behave — reminders, tone, notifications.
    case assistantBehaviour
    /// Somebody other than the user.
    case people
    /// Somewhere.
    case location
    /// No strong signal.
    case general

    /// Reads the intent from the request text.
    ///
    /// Cue words only, and the same word may serve two intents; the strongest
    /// count wins and ties fall to `.general`. Cheap enough to run per turn and
    /// simple enough that a wrong guess only removes a small bonus.
    public static func detect(in profile: MemoryTextProfile) -> MemoryQueryIntent {
        var counts: [MemoryQueryIntent: Int] = [:]
        for term in profile.terms {
            for (intent, cues) in cueWords where cues.contains(term) {
                counts[intent, default: 0] += 1
            }
        }
        // A duration in the question is a strong scheduling signal on its own:
        // "how long before I leave" often shares no cue word with a memory.
        if !profile.durations.isEmpty {
            counts[.scheduling, default: 0] += 1
        }

        guard let best = counts.max(by: { $0.value < $1.value }), best.value > 0 else {
            return .general
        }
        let tied = counts.filter { $0.value == best.value }
        return tied.count == 1 ? best.key : .general
    }

    /// Cue words, stemmed to match `MemoryTextProfile.terms`.
    private static let cueWords: [MemoryQueryIntent: Set<String>] = [
        .scheduling: [
            "leav", "leave", "readi", "ready", "wake", "time", "late", "earli",
            "early", "arriv", "arrive", "start", "schedul", "schedule", "commut",
            "commute", "drive", "travel", "prepar", "prepare", "minut", "minute",
            "hour", "tomorrow", "today", "shift", "appoint", "appointment",
        ],
        .assistantBehaviour: [
            "remind", "reminder", "notifi", "notify", "notification", "alarm",
            "nudg", "nudge", "snooz", "snooze", "prefer", "preference", "repeat",
            "confirm", "alert", "tone", "concis", "concise",
        ],
        .people: [
            "girlfriend", "boyfriend", "wife", "husband", "partner", "friend",
            "mum", "mom", "dad", "brother", "sister", "colleagu", "colleague",
            "name", "birthday", "anniversari", "anniversary", "famili", "family",
        ],
        .location: [
            "work", "offic", "office", "home", "gym", "shop", "store", "address",
            "near", "far", "distanc", "distance", "away", "place", "route",
        ],
    ]

    /// How much a memory of this category is worth to this kind of request.
    ///
    /// A multiplier from 0 to 1 applied to `categoryWeight`, never a filter.
    /// A memory of the "wrong" category that genuinely matches the words still
    /// ranks — category is a thumb on the scale, not a gate, because people do
    /// not file their lives the way an enum does.
    public func affinity(for kind: MemoryKind) -> Double {
        switch self {
        case .scheduling:
            switch kind {
            case .routine, .place: return 1.0
            case .recurringCommitment: return 0.8
            case .preference: return 0.4
            case .fact: return 0.3
            case .person: return 0.2
            }
        case .assistantBehaviour:
            switch kind {
            case .preference: return 1.0
            case .routine: return 0.4
            case .fact: return 0.3
            case .recurringCommitment, .place, .person: return 0.2
            }
        case .people:
            switch kind {
            case .person: return 1.0
            case .fact: return 0.7
            case .preference: return 0.4
            case .routine, .recurringCommitment, .place: return 0.2
            }
        case .location:
            switch kind {
            case .place: return 1.0
            case .routine: return 0.6
            case .recurringCommitment: return 0.4
            case .fact, .preference, .person: return 0.3
            }
        case .general:
            // No opinion. Relevance, salience and confidence decide.
            return 0.5
        }
    }
}
