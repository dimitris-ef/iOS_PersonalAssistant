import Foundation

/// One key.
///
/// A value, not a view. The whole layout is decided here — in a package target
/// with tests — and the extension turns it into buttons. That split is what
/// lets "does the shift key change the letters" be a unit test rather than
/// something you find out by installing a keyboard on a phone.
public enum KeyboardKey: Hashable, Sendable {
    case character(String)
    case space
    case backspace
    case shift
    case returnKey
    /// The system's own control for switching keyboards. Required (section 11)
    /// — a keyboard the user cannot leave is a keyboard they uninstall.
    case nextKeyboard
    /// Switches between the letter and symbol planes.
    case plane(KeyboardPlane)

    /// What to draw on it.
    public var label: String {
        switch self {
        case .character(let text): return text
        case .space: return "space"
        case .backspace: return "⌫"
        case .shift: return "⇧"
        case .returnKey: return "return"
        case .nextKeyboard: return "🌐"
        case .plane(let plane): return plane.switchLabel
        }
    }

    /// Spoken by VoiceOver. Section 126: the symbol keys above are meaningless
    /// read literally, so every one of them has a word here.
    public var accessibilityLabel: String {
        switch self {
        case .character(let text): return text == " " ? "space" : text
        case .space: return "space"
        case .backspace: return "delete"
        case .shift: return "shift"
        case .returnKey: return "return"
        case .nextKeyboard: return "next keyboard"
        case .plane(let plane): return "switch to \(plane.accessibilityName)"
        }
    }
}

/// Which set of keys is showing.
public enum KeyboardPlane: String, Hashable, Sendable, CaseIterable {
    case letters
    case numbers
    case symbols

    var switchLabel: String {
        switch self {
        case .letters: return "ABC"
        case .numbers: return "123"
        case .symbols: return "#+="
        }
    }

    var accessibilityName: String {
        switch self {
        case .letters: return "letters"
        case .numbers: return "numbers"
        case .symbols: return "symbols"
        }
    }
}

/// Whether letters come out capitalised.
public enum KeyboardShiftState: String, Hashable, Sendable, CaseIterable {
    case off
    /// One capital, then back to off. What tapping shift does.
    case oneShot
    /// Until switched off. What double-tapping shift does.
    case locked

    public var producesUppercase: Bool { self != .off }
}

/// The keys, arranged.
///
/// ## Scope
///
/// Section 10: a compact practical keyboard, and section 131 is explicit that
/// this is not an attempt to reproduce Apple's. There is no autocorrect, no
/// predictive bar, no swipe typing and no per-key hit-target widening — all of
/// which are years of work and none of which is what Part 12 is about. What is
/// here is a keyboard someone can genuinely type a sentence on.
public struct KeyboardLayout: Hashable, Sendable {
    public var plane: KeyboardPlane
    public var shift: KeyboardShiftState

    public init(plane: KeyboardPlane = .letters, shift: KeyboardShiftState = .oneShot) {
        self.plane = plane
        self.shift = shift
    }

    /// The rows to draw, top to bottom.
    public var rows: [[KeyboardKey]] {
        switch plane {
        case .letters:
            return [
                characters("qwertyuiop"),
                characters("asdfghjkl"),
                [.shift] + characters("zxcvbnm") + [.backspace],
                bottomRow(planeSwitch: .numbers),
            ]
        case .numbers:
            return [
                characters("1234567890", uppercasing: false),
                characters("-/:;()£&@\"", uppercasing: false),
                [.plane(.symbols)] + characters(".,?!'", uppercasing: false) + [.backspace],
                bottomRow(planeSwitch: .letters),
            ]
        case .symbols:
            return [
                characters("[]{}#%^*+=", uppercasing: false),
                characters("_\\|~<>$€¥•", uppercasing: false),
                [.plane(.numbers)] + characters(".,?!'", uppercasing: false) + [.backspace],
                bottomRow(planeSwitch: .letters),
            ]
        }
    }

    /// What a character key inserts, given the current shift state.
    public func text(for key: KeyboardKey) -> String? {
        switch key {
        case .character(let value):
            return value
        case .space:
            return " "
        case .returnKey:
            return "\n"
        case .backspace, .shift, .nextKeyboard, .plane:
            return nil
        }
    }

    /// The layout after a key is pressed.
    ///
    /// Pure, and total: every key has a defined effect on the layout, including
    /// the ones that have none. A one-shot shift falling back to off after a
    /// letter lives here rather than in the view controller, which is why it
    /// can be asserted without a keyboard.
    public func applying(_ key: KeyboardKey) -> KeyboardLayout {
        var next = self
        switch key {
        case .shift:
            next.shift = shift == .off ? .oneShot : .off
        case .plane(let target):
            next.plane = target
            // Leaving the letter plane and coming back should not arrive
            // shifted from three keys ago.
            next.shift = target == .letters ? .oneShot : .off
        case .character:
            if shift == .oneShot { next.shift = .off }
        case .space, .backspace, .returnKey, .nextKeyboard:
            break
        }
        return next
    }

    /// Double-tapping shift locks it.
    public func lockingShift() -> KeyboardLayout {
        var next = self
        next.shift = shift == .locked ? .off : .locked
        return next
    }

    private func characters(_ letters: String, uppercasing: Bool = true) -> [KeyboardKey] {
        letters.map { character in
            let text = uppercasing && shift.producesUppercase
                ? String(character).uppercased()
                : String(character)
            return .character(text)
        }
    }

    private func bottomRow(planeSwitch: KeyboardPlane) -> [KeyboardKey] {
        [.plane(planeSwitch), .nextKeyboard, .space, .returnKey]
    }
}
