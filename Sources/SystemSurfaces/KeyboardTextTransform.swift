import Foundation

/// The transformations the keyboard is allowed to do by itself.
///
/// ## The line this file draws
///
/// Section 24 permits a small deterministic tidy-up inside the extension, and
/// section 16 forbids a model there. The distinction is not "how clever" but
/// "how much does it need to know": collapsing repeated spaces needs the string
/// and nothing else, whereas rewriting a sentence needs to understand what it
/// means. Everything in this file is in the first category, is pure, and would
/// give the same answer on any device with no network and no model.
///
/// Nothing here is offered to the user as an AI feature. It runs *before* a
/// request is sent, so what the assistant is asked to improve is not full of
/// double spaces, and it runs as the fallback when a request cannot be sent at
/// all — which is honest, because the result is exactly what it looks like.
public enum KeyboardTextTransform {
    /// Whitespace only. Never changes a word.
    public static func tidyWhitespace(_ text: String) -> String {
        let collapsed = text
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Capitalises the first letter of each sentence.
    ///
    /// Sentence ends are `.`, `!` and `?`. Deliberately naive: "e.g." will
    /// capitalise the next letter, and that is the cost of a rule that never
    /// needs a dictionary. Anything smarter belongs to the model.
    public static func capitalizeSentences(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var startOfSentence = true

        for character in text {
            if startOfSentence, character.isLetter {
                result.append(contentsOf: String(character).uppercased())
                startOfSentence = false
            } else {
                result.append(character)
            }
            if character == "." || character == "!" || character == "?" || character == "\n" {
                startOfSentence = true
            }
        }
        return result
    }

    /// Both, in the order that makes them commute.
    ///
    /// Whitespace first: capitalisation looks at the character after a full
    /// stop, and " . x" and ". x" should not disagree about what that is.
    public static func tidy(_ text: String) -> String {
        capitalizeSentences(tidyWhitespace(text))
    }

    /// Whether tidying would change anything.
    ///
    /// Lets the keyboard avoid replacing the user's text with an identical
    /// copy — which sounds harmless and is not, because replacing text moves
    /// the insertion point.
    public static func wouldChange(_ text: String) -> Bool {
        tidy(text) != text
    }
}
