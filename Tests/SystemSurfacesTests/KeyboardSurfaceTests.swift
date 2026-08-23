import Foundation
import XCTest

@testable import SystemSurfaces

/// The keyboard, minus UIKit.
///
/// Every decision a custom keyboard makes that is worth being sure about — what
/// a key inserts, what shift does next, what happens when the assistant is not
/// reachable — is a pure function here, so it is a unit test rather than
/// something you learn by installing a keyboard on a phone and typing.
final class KeyboardSurfaceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    // MARK: Layout

    /// Section 11. A keyboard the user cannot leave is a keyboard they
    /// uninstall, so the control is not optional and this asserts it exists on
    /// every plane rather than trusting that it does.
    func testEveryPlaneOffersTheNextKeyboardControl() {
        for plane in KeyboardPlane.allCases {
            let layout = KeyboardLayout(plane: plane, shift: .off)
            let keys = layout.rows.flatMap { $0 }
            XCTAssertTrue(
                keys.contains(.nextKeyboard),
                "\(plane) has no way out to another keyboard"
            )
        }
    }

    /// Section 10: the basics are all present, on the letter plane, always.
    func testTheLetterPlaneHasTheKeysTypingNeeds() {
        let keys = KeyboardLayout().rows.flatMap { $0 }

        XCTAssertTrue(keys.contains(.space))
        XCTAssertTrue(keys.contains(.backspace))
        XCTAssertTrue(keys.contains(.returnKey))
        XCTAssertTrue(keys.contains(.shift))
        XCTAssertTrue(keys.contains(.character("q")) || keys.contains(.character("Q")))
    }

    func testShiftChangesWhatTheLetterKeysInsert() {
        let lower = KeyboardLayout(shift: .off)
        let upper = KeyboardLayout(shift: .oneShot)

        XCTAssertTrue(lower.rows[0].contains(.character("q")))
        XCTAssertTrue(upper.rows[0].contains(.character("Q")))
    }

    /// A one-shot shift is one capital, then back to lower case — the behaviour
    /// every iOS user already has in their fingers.
    func testAOneShotShiftFallsBackAfterOneLetter() {
        let shifted = KeyboardLayout(shift: .oneShot)
        let after = shifted.applying(.character("Q"))

        XCTAssertEqual(after.shift, .off)
        XCTAssertTrue(after.rows[0].contains(.character("q")))
    }

    /// A locked shift does not.
    func testALockedShiftSurvivesTyping() {
        let locked = KeyboardLayout(shift: .off).lockingShift()
        XCTAssertEqual(locked.shift, .locked)
        XCTAssertEqual(locked.applying(.character("Q")).shift, .locked)
        XCTAssertEqual(locked.lockingShift().shift, .off)
    }

    func testSwitchingPlanesResetsTheShiftSensibly() {
        let numbers = KeyboardLayout(shift: .locked).applying(.plane(.numbers))
        XCTAssertEqual(numbers.plane, .numbers)
        XCTAssertEqual(numbers.shift, .off, "a locked shift means nothing on the number plane")

        let back = numbers.applying(.plane(.letters))
        XCTAssertEqual(back.plane, .letters)
        XCTAssertEqual(back.shift, .oneShot, "sentences start with a capital")
    }

    func testKeysInsertWhatTheyLookLike() {
        let layout = KeyboardLayout()

        XCTAssertEqual(layout.text(for: .character("a")), "a")
        XCTAssertEqual(layout.text(for: .space), " ")
        XCTAssertEqual(layout.text(for: .returnKey), "\n")
        // The controls insert nothing; the view controller acts on them.
        XCTAssertNil(layout.text(for: .backspace))
        XCTAssertNil(layout.text(for: .shift))
        XCTAssertNil(layout.text(for: .nextKeyboard))
        XCTAssertNil(layout.text(for: .plane(.numbers)))
    }

    /// Section 126. The symbols above are meaningless read aloud, so every key
    /// carries a word.
    func testEveryKeyHasAnAccessibleName() {
        for plane in KeyboardPlane.allCases {
            for key in KeyboardLayout(plane: plane).rows.flatMap({ $0 }) {
                XCTAssertFalse(
                    key.accessibilityLabel.trimmingCharacters(in: .whitespaces).isEmpty,
                    "\(key) would be read as nothing"
                )
            }
        }
    }

    // MARK: Local transforms

    /// Section 24. What the extension is allowed to do alone: whitespace and
    /// capitalisation, deterministically, with no model anywhere near it.
    func testLocalTidyingIsWhitespaceAndCapitalisationOnly() {
        XCTAssertEqual(
            KeyboardTextTransform.tidy("hi  there.  how are  you?"),
            "Hi there. How are you?"
        )
        XCTAssertEqual(KeyboardTextTransform.tidy("  spaced out  "), "Spaced out")
    }

    /// It never changes a word — that is the line between this and the model.
    func testLocalTidyingNeverRewritesWords() {
        let original = "can u send me the report tomorrow"
        let tidied = KeyboardTextTransform.tidy(original)

        XCTAssertEqual(tidied, "Can u send me the report tomorrow")
        XCTAssertTrue(tidied.lowercased().contains("can u send me the report tomorrow"))
    }

    /// Replacing text moves the insertion point, so "nothing would change" is
    /// worth knowing before doing it.
    func testWouldChangeIsFalseForAlreadyTidyText() {
        XCTAssertFalse(KeyboardTextTransform.wouldChange("This is already fine."))
        XCTAssertTrue(KeyboardTextTransform.wouldChange("this  is not"))
    }

    // MARK: The exchange

    /// Section 21. A minimal request: an operation, the text, an identifier and
    /// a time. Notably *not* a provider, a prompt or a model.
    func testAKeyboardRequestCarriesFourFieldsAndNoProvider() throws {
        let request = KeyboardAssistantRequest(
            operation: .improve,
            inputText: "can u send me the report tomorrow",
            createdAt: now
        )

        let json = try String(decoding: SystemSurfaceCoding.encode(
            KeyboardExchange(generatedAt: now, request: request)
        ), as: UTF8.self)

        for forbidden in ["provider", "apiKey", "api_key", "endpoint", "model", "prompt", "token"] {
            XCTAssertFalse(
                json.lowercased().contains(forbidden.lowercased()),
                "the keyboard exchange leaked a '\(forbidden)' field"
            )
        }
    }

    func testTheExchangeRoundTripsThroughTheStore() throws {
        let store = InMemorySystemSurfaceStore()
        let request = KeyboardAssistantRequest(
            operation: .shorten, inputText: "a long sentence", createdAt: now
        )
        try store.write(KeyboardExchange(generatedAt: now, request: request))

        let loaded = try store.read(KeyboardExchange.self)
        XCTAssertEqual(loaded.request, request)
        XCTAssertNil(loaded.result)
    }

    /// Section 28. Failure carries a sentence, never a diagnostic, and never
    /// replacement text — because there is no replacement to make.
    func testAnUnavailableResultCarriesAReasonAndNoText() {
        let result = KeyboardAssistantResult.unavailable(UUID(), reason: "Assistant unavailable")

        XCTAssertEqual(result.status, .unavailable)
        XCTAssertNil(result.text)
        XCTAssertEqual(result.error, "Assistant unavailable")
    }

    /// Section 12 and 13. Without shared access the keyboard still exists — it
    /// just has nothing to offer beyond typing, and says so rather than
    /// hiding the buttons and looking broken.
    func testWithoutSharedAccessTheConfigurationOffersNothingButStillDecodes() {
        let configuration = KeyboardConfigurationSnapshot.withoutSharedAccess(at: now)

        XCTAssertFalse(configuration.assistantActionsEnabled)
        XCTAssertTrue(configuration.operations.isEmpty)
        XCTAssertEqual(configuration.snapshotVersion, KeyboardConfigurationSnapshot.currentVersion)
    }

    /// Section 17: a small set, and every one of them is a text transformation
    /// or a question — never a command that changes anything.
    func testTheOperationSetIsSmallAndContainsNoCommands() {
        XCTAssertEqual(KeyboardAssistantOperation.allCases.count, 4)
        for operation in KeyboardAssistantOperation.allCases {
            XCTAssertFalse(operation.title.isEmpty)
            // Section 24: none of them claims to be satisfiable locally, which
            // is what stops a second model stack appearing in the extension.
            XCTAssertFalse(operation.isLocallySatisfiable)
        }
    }
}
