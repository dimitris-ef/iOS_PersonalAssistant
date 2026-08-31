import Foundation

/// How many times a turn may re-ask the model for a usable action.
///
/// ## Why one object rather than one counter per path
///
/// Section 39. There are now two ways a local turn can decide the model's
/// output was not a usable action — the older tool-envelope parser and the
/// semantic parser — and each of them arrived with its own "exactly one repair"
/// rule. Two separate rules, each correct on its own, add up to two extra
/// generations: the semantic pass repairs, hands its result on, and the tool
/// pass repairs again. On a phone that is not a subtle inefficiency; it is the
/// difference between a reply and a reply the user gave up waiting for.
///
/// So the budget is a value that belongs to the *turn*, is passed to whichever
/// path wants to spend it, and is spent once. The structural part is that it is
/// consumed by mutation rather than checked by convention: a path that asks
/// twice gets `false` the second time without anybody having to remember to
/// forbid it.
public struct LocalActionRecoveryPolicy: Hashable, Sendable {

    /// One. Section 33: a small model that produced an unusable action twice is
    /// not going to produce a usable one on the third attempt, and every extra
    /// generation is several seconds of a person waiting.
    public static let maximumAttempts = 1

    public private(set) var attemptsUsed: Int

    public init(attemptsUsed: Int = 0) {
        self.attemptsUsed = attemptsUsed
    }

    public var mayRetry: Bool { attemptsUsed < Self.maximumAttempts }

    /// Spends one attempt, or reports that there was none to spend.
    public mutating func consume() -> Bool {
        guard mayRetry else { return false }
        attemptsUsed += 1
        return true
    }
}
