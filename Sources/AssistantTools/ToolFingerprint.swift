import AssistantDomain
import Foundation

/// A stable identity for "this exact action, in this turn".
///
/// The problem it solves: a model that is shown a tool result and asked to
/// continue will sometimes propose the same action again — because a network
/// retry replayed the request, because it lost track, or because it simply
/// repeats itself. Provider call ids do not help there; a regenerated request
/// carries regenerated ids. What is stable across all of it is the *content* of
/// the call.
///
/// ## Canonicalization
///
/// The fingerprint is taken from the **typed, decoded** request rather than
/// from the raw JSON the model sent. That is deliberate, and it is what makes
/// the comparison mean something:
///
/// - Field order cannot matter — the request is re-encoded with sorted keys.
/// - Formatting cannot matter — whitespace, number spelling, key order in
///   nested objects all normalise away.
/// - Types cannot matter — `"2026-08-21T10:00:00Z"` and any other spelling of
///   that instant have both already become one `Date` by this point.
///
/// Comparing raw argument strings would fail all four.
///
/// ## What is deliberately *not* normalised
///
/// An omitted optional and an explicitly passed default are different
/// fingerprints, even though they mean the same thing. That is the conservative
/// direction: the cost of treating two identical actions as different is one
/// duplicate the ledger's call-id check usually catches anyway, and the cost of
/// the opposite mistake is silently swallowing an action the user genuinely
/// asked for twice.
public struct ToolFingerprint: Hashable, Sendable, CustomStringConvertible {
    public let value: String

    public init(value: String) {
        self.value = value
    }

    /// - Parameters:
    ///   - scope: What the identity is relative to — in practice the
    ///     conversation and the turn. Scoping to the turn is what allows
    ///     "remind me to call the dentist" to work again tomorrow: a repeat in
    ///     a *later* turn is a new request, not a duplicate.
    ///   - request: The decoded call, before the planner fills in identifiers.
    public init(scope: String, request: ToolRequest) {
        let arguments: String
        if let data = try? JSONCoding.encoder.encode(request),
           let text = String(data: data, encoding: .utf8) {
            arguments = text
        } else {
            // Unreachable for every input type in the catalogue, all of which
            // are plainly encodable. Falling back to the summary keeps a
            // fingerprint that is stable for identical requests rather than
            // returning something that would collide with everything.
            arguments = request.summary
        }

        self.value = Self.digest(of: "\(scope)|\(request.kind.rawValue)|\(arguments)")
    }

    public var description: String { value }

    /// FNV-1a, 64-bit, rendered as hex.
    ///
    /// Not `Hasher`: Swift seeds that per process, so the same arguments would
    /// fingerprint differently after a relaunch — which is exactly when a
    /// duplicate check needs to still hold. Not a cryptographic hash either;
    /// nothing here defends against a chosen collision, and pulling in CryptoKit
    /// for a dictionary key would be the wrong trade.
    static func digest(of text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let prime: UInt64 = 0x1000_0000_01b3
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return String(hash, radix: 16)
    }
}
