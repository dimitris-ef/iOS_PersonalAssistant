import Foundation

/// A parser and matcher for the GBNF subset MetisAI generates.
///
/// ## Why this exists
///
/// Two reasons, and the second is the interesting one.
///
/// **Section 18** asks that a generated grammar be validated *before*
/// inference. `llama_sampler_init_grammar` returns NULL on a grammar it cannot
/// parse, which is a fine last line of defence and a poor first one: by then a
/// model is loaded, a prompt is built, and the failure arrives as a null
/// pointer with no explanation. Parsing it here first turns that into a named
/// error, on the device, before anything expensive happens.
///
/// **The claims in the tests would otherwise be untestable.** "Prose cannot
/// escape the grammar" and "`relatedTaskID` cannot be emitted" are properties
/// of the grammar *string*, and CI has no llama.cpp: there is no iOS Simulator
/// slice and no model. Without this, those tests could only assert what a mock
/// was told to return, which proves nothing about the constraint. With it they
/// assert the real artefact — the exact bytes handed to
/// `llama_sampler_init_grammar` — accepts the valid action and rejects the
/// prose.
///
/// ## What it is not
///
/// Not a general GBNF engine, and not the thing that constrains generation on
/// a phone. llama.cpp does that. This covers exactly the constructs
/// ``SemanticActionGrammar`` emits — literals, character classes, references,
/// sequence, alternation and bounded repetition — and rejects anything else
/// rather than guessing, so a grammar that grew a construct this cannot read
/// fails validation loudly instead of being silently half-checked.
public struct GBNFGrammar: Sendable {

    public enum ValidationFailure: Error, Hashable, Sendable, CustomStringConvertible {
        case emptyGrammar
        case malformedRule(String)
        case duplicateRule(String)
        case unsupportedSyntax(String)
        case missingRoot(String)
        case undefinedRule(String)

        public var symbol: String {
            switch self {
            case .emptyGrammar: return "emptyGrammar"
            case .malformedRule: return "malformedRule"
            case .duplicateRule: return "duplicateRule"
            case .unsupportedSyntax: return "unsupportedSyntax"
            case .missingRoot: return "missingRoot"
            case .undefinedRule: return "undefinedRule"
            }
        }

        public var description: String {
            switch self {
            case .emptyGrammar: return "the grammar is empty"
            case .malformedRule(let name): return "malformed rule \(name)"
            case .duplicateRule(let name): return "rule \(name) is defined twice"
            case .unsupportedSyntax(let detail): return "unsupported grammar syntax: \(detail)"
            case .missingRoot(let name): return "no rule named \(name)"
            case .undefinedRule(let name): return "rule \(name) is referenced and never defined"
            }
        }
    }

    indirect enum Node: Sendable {
        case literal([UnicodeScalar])
        case characterClass(negated: Bool, ranges: [ClosedRange<UInt32>])
        case reference(String)
        case sequence([Node])
        case alternation([Node])
        case repetition(Node, minimum: Int, maximum: Int?)
    }

    let rules: [String: Node]
    let root: String

    // MARK: Validation

    /// Parses and checks a grammar, or says exactly what is wrong with it.
    public static func validate(_ text: String, root: String) throws -> GBNFGrammar {
        var rules: [String: Node] = [:]

        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            guard let separator = trimmed.range(of: "::=") else {
                throw ValidationFailure.malformedRule(String(trimmed.prefix(24)))
            }
            let name = String(trimmed[trimmed.startIndex..<separator.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else {
                throw ValidationFailure.malformedRule(String(trimmed.prefix(24)))
            }
            guard rules[name] == nil else { throw ValidationFailure.duplicateRule(name) }

            var parser = Parser(Array(String(trimmed[separator.upperBound...]).unicodeScalars))
            rules[name] = try parser.parseAlternation()
            try parser.expectEnd()
        }

        guard !rules.isEmpty else { throw ValidationFailure.emptyGrammar }
        guard rules[root] != nil else { throw ValidationFailure.missingRoot(root) }

        // Every reference must resolve. A grammar with a dangling name parses
        // fine and then matches nothing, which is the worst of both.
        for node in rules.values {
            try checkReferences(node, against: rules)
        }
        return GBNFGrammar(rules: rules, root: root)
    }

    private static func checkReferences(_ node: Node, against rules: [String: Node]) throws {
        switch node {
        case .literal, .characterClass:
            return
        case .reference(let name):
            guard rules[name] != nil else { throw ValidationFailure.undefinedRule(name) }
        case .sequence(let nodes), .alternation(let nodes):
            for child in nodes { try checkReferences(child, against: rules) }
        case .repetition(let child, _, _):
            try checkReferences(child, against: rules)
        }
    }

    // MARK: Matching

    /// Whether the whole string is in the language of this grammar.
    ///
    /// Backtracking, and deliberately so: the grammars here are a few dozen
    /// productions and the inputs are one short JSON object, so the simple
    /// algorithm that is obviously correct beats the fast one that is not.
    public func matches(_ input: String) -> Bool {
        let scalars = Array(input.unicodeScalars)
        return match(.reference(root), scalars, 0, depth: 0).contains(scalars.count)
    }

    /// Every index the node could consume up to, starting from `index`.
    private func match(
        _ node: Node, _ input: [UnicodeScalar], _ index: Int, depth: Int
    ) -> Set<Int> {
        // A grammar with a left-recursive cycle would otherwise recurse until
        // the stack ran out. Ours has none; a future one might.
        guard depth < 128 else { return [] }

        switch node {
        case .literal(let scalars):
            guard index + scalars.count <= input.count else { return [] }
            for (offset, scalar) in scalars.enumerated()
            where input[index + offset] != scalar {
                return []
            }
            return [index + scalars.count]

        case .characterClass(let negated, let ranges):
            guard index < input.count else { return [] }
            let value = input[index].value
            let inside = ranges.contains { $0.contains(value) }
            return inside != negated ? [index + 1] : []

        case .reference(let name):
            guard let rule = rules[name] else { return [] }
            return match(rule, input, index, depth: depth + 1)

        case .sequence(let nodes):
            var positions: Set<Int> = [index]
            for child in nodes {
                var next: Set<Int> = []
                for position in positions {
                    next.formUnion(match(child, input, position, depth: depth + 1))
                }
                if next.isEmpty { return [] }
                positions = next
            }
            return positions

        case .alternation(let nodes):
            var positions: Set<Int> = []
            for child in nodes {
                positions.formUnion(match(child, input, index, depth: depth + 1))
            }
            return positions

        case .repetition(let child, let minimum, let maximum):
            var positions: Set<Int> = [index]
            var reached: Set<Int> = minimum == 0 ? [index] : []
            var count = 0
            // Bounded by the input length as well as by `maximum`, so a rule
            // that can match the empty string cannot loop forever.
            let ceiling = maximum ?? (input.count - index + 1)
            while count < ceiling, !positions.isEmpty {
                var next: Set<Int> = []
                for position in positions {
                    next.formUnion(match(child, input, position, depth: depth + 1))
                }
                next.subtract(positions)
                if next.isEmpty { break }
                count += 1
                positions = next
                if count >= minimum { reached.formUnion(next) }
            }
            return reached
        }
    }

    // MARK: Parsing

    private struct Parser {
        private let scalars: [UnicodeScalar]
        private var index = 0

        init(_ scalars: [UnicodeScalar]) { self.scalars = scalars }

        mutating func parseAlternation() throws -> Node {
            var branches = [try parseSequence()]
            while peek() == "|" {
                advance()
                branches.append(try parseSequence())
            }
            return branches.count == 1 ? branches[0] : .alternation(branches)
        }

        mutating func parseSequence() throws -> Node {
            var terms: [Node] = []
            skipWhitespace()
            while let scalar = peek(), scalar != "|", scalar != ")" {
                terms.append(try parseTerm())
                skipWhitespace()
            }
            guard !terms.isEmpty else {
                throw ValidationFailure.unsupportedSyntax("empty sequence")
            }
            return terms.count == 1 ? terms[0] : .sequence(terms)
        }

        mutating func parseTerm() throws -> Node {
            let atom = try parseAtom()
            switch peek() {
            case "?": advance(); return .repetition(atom, minimum: 0, maximum: 1)
            case "*": advance(); return .repetition(atom, minimum: 0, maximum: nil)
            case "+": advance(); return .repetition(atom, minimum: 1, maximum: nil)
            case "{": return try parseBoundedRepetition(of: atom)
            default: return atom
            }
        }

        mutating func parseBoundedRepetition(of atom: Node) throws -> Node {
            advance()  // {
            var minimumText = "", maximumText = ""
            var seenComma = false
            while let scalar = peek(), scalar != "}" {
                if scalar == "," {
                    seenComma = true
                } else if CharacterSet.decimalDigits.contains(scalar) {
                    if seenComma { maximumText.unicodeScalars.append(scalar) }
                    else { minimumText.unicodeScalars.append(scalar) }
                } else {
                    throw ValidationFailure.unsupportedSyntax("repetition bound")
                }
                advance()
            }
            guard peek() == "}" else {
                throw ValidationFailure.unsupportedSyntax("unterminated repetition")
            }
            advance()
            guard let minimum = Int(minimumText) else {
                throw ValidationFailure.unsupportedSyntax("repetition bound")
            }
            let maximum = seenComma ? Int(maximumText) : minimum
            return .repetition(atom, minimum: minimum, maximum: maximum)
        }

        mutating func parseAtom() throws -> Node {
            skipWhitespace()
            guard let scalar = peek() else {
                throw ValidationFailure.unsupportedSyntax("unexpected end of rule")
            }
            switch scalar {
            case "\"": return try parseLiteral()
            case "[": return try parseCharacterClass()
            case "(":
                advance()
                let inner = try parseAlternation()
                guard peek() == ")" else {
                    throw ValidationFailure.unsupportedSyntax("unclosed group")
                }
                advance()
                return inner
            default: return try parseReference()
            }
        }

        mutating func parseLiteral() throws -> Node {
            advance()  // opening quote
            var value: [UnicodeScalar] = []
            while let scalar = peek(), scalar != "\"" {
                if scalar == "\\" {
                    advance()
                    guard let escaped = peek() else {
                        throw ValidationFailure.unsupportedSyntax("dangling escape")
                    }
                    value.append(Self.unescape(escaped))
                } else {
                    value.append(scalar)
                }
                advance()
            }
            guard peek() == "\"" else {
                throw ValidationFailure.unsupportedSyntax("unterminated literal")
            }
            advance()
            skipWhitespace()
            return .literal(value)
        }

        mutating func parseCharacterClass() throws -> Node {
            advance()  // [
            var negated = false
            if peek() == "^" { negated = true; advance() }

            var ranges: [ClosedRange<UInt32>] = []
            while let scalar = peek(), scalar != "]" {
                var lower = scalar
                if scalar == "\\" {
                    advance()
                    guard let escaped = peek() else {
                        throw ValidationFailure.unsupportedSyntax("dangling escape")
                    }
                    lower = Self.unescape(escaped)
                }
                advance()
                if peek() == "-", let after = peek(offset: 1), after != "]" {
                    advance()  // -
                    var upper = after
                    if after == "\\" {
                        advance()
                        guard let escaped = peek() else {
                            throw ValidationFailure.unsupportedSyntax("dangling escape")
                        }
                        upper = Self.unescape(escaped)
                    }
                    advance()
                    ranges.append(min(lower.value, upper.value)...max(lower.value, upper.value))
                } else {
                    ranges.append(lower.value...lower.value)
                }
            }
            guard peek() == "]" else {
                throw ValidationFailure.unsupportedSyntax("unterminated character class")
            }
            advance()
            skipWhitespace()
            guard !ranges.isEmpty else {
                throw ValidationFailure.unsupportedSyntax("empty character class")
            }
            return .characterClass(negated: negated, ranges: ranges)
        }

        mutating func parseReference() throws -> Node {
            var name = ""
            while let scalar = peek(), Self.isNameScalar(scalar) {
                name.unicodeScalars.append(scalar)
                advance()
            }
            guard !name.isEmpty else {
                throw ValidationFailure.unsupportedSyntax("unrecognized token")
            }
            skipWhitespace()
            return .reference(name)
        }

        mutating func expectEnd() throws {
            skipWhitespace()
            guard peek() == nil else {
                throw ValidationFailure.unsupportedSyntax("trailing input")
            }
        }

        // MARK: Scanning

        private func peek(offset: Int = 0) -> UnicodeScalar? {
            let position = index + offset
            return position < scalars.count ? scalars[position] : nil
        }

        private mutating func advance() { index += 1 }

        private mutating func skipWhitespace() {
            while let scalar = peek(), scalar == " " || scalar == "\t" { advance() }
        }

        static func isNameScalar(_ scalar: UnicodeScalar) -> Bool {
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_"
        }

        static func unescape(_ scalar: UnicodeScalar) -> UnicodeScalar {
            switch scalar {
            case "n": return "\n"
            case "t": return "\t"
            case "r": return "\r"
            default: return scalar
            }
        }
    }
}
