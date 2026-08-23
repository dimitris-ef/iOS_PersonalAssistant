import SystemSurfaces
import UIKit

/// The Personal Assistant keyboard.
///
/// ## What it is
///
/// A real keyboard. Section 9 is explicit that this must not be "an AI button
/// pretending to be a keyboard", and section 10 lists the floor: characters,
/// backspace, space, return, and the control that switches to another keyboard.
/// All of it works with Full Access switched off, because a keyboard that
/// cannot type until you grant it network access is not a keyboard.
///
/// ## What it is not
///
/// Section 131: not an AI chat surface. There is one row of buttons above the
/// keys, each of which sends the selected text to the *application* and waits.
/// The main app remains the rich assistant environment.
///
/// ## What it deliberately does not contain
///
/// Sections 15 and 16: no provider, no runtime, no `SupportPlanner`, no
/// SwiftData. This target links `SystemSurfaces` and UIKit, and that is the
/// whole of its graph — which is why it cannot load a three-billion-parameter
/// model even by accident.
///
/// ## Memory
///
/// A keyboard extension gets a fraction of what an app gets, and being killed
/// mid-sentence is what the user experiences as the keyboard "disappearing".
/// Everything here is views and value types.
class KeyboardViewController: UIInputViewController {

    private var layout = KeyboardLayout()
    private var keyboardStack: UIStackView?
    private var assistantBar: KeyboardAssistantBar?
    private let bridge = KeyboardAssistantBridge()
    /// Repeats backspace while it is held, the way every keyboard does.
    private var backspaceTimer: Timer?

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        buildInterface()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Read afresh every time the keyboard appears: the user may have
        // changed the setting, or granted Full Access, since it was last shown.
        assistantBar?.apply(bridge.configuration())
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        // Section 18: the proxy exposes what the host chooses to expose, and a
        // secure field exposes nothing. The bar reflects what is actually
        // available rather than offering an action that cannot work.
        assistantBar?.setHasText(!(textDocumentProxy.documentContextBeforeInput ?? "").isEmpty)
    }

    // MARK: Interface

    private func buildInterface() {
        let bar = KeyboardAssistantBar()
        bar.onOperation = { [weak self] operation in self?.perform(operation) }
        bar.onAccept = { [weak self] text in self?.accept(text) }
        bar.onCancel = { [weak self] in self?.cancelAssistant() }
        assistantBar = bar

        let keys = UIStackView()
        keys.axis = .vertical
        keys.distribution = .fillEqually
        keys.spacing = 6
        keyboardStack = keys

        let root = UIStackView(arrangedSubviews: [bar, keys])
        root.axis = .vertical
        root.spacing = 6
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 3),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -3),
            root.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -4),
            bar.heightAnchor.constraint(equalToConstant: 40),
            keys.heightAnchor.constraint(greaterThanOrEqualToConstant: 190),
        ])

        renderKeys()
    }

    /// Rebuilds the key rows from the layout value.
    ///
    /// The layout is the model — which letters, which plane, shifted or not —
    /// and it is decided in a package target with tests. This turns it into
    /// buttons and nothing else.
    private func renderKeys() {
        guard let keyboardStack else { return }
        keyboardStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        for row in layout.rows {
            let rowStack = UIStackView()
            rowStack.axis = .horizontal
            rowStack.distribution = .fillProportionally
            rowStack.spacing = 5

            for key in row {
                rowStack.addArrangedSubview(button(for: key))
            }
            keyboardStack.addArrangedSubview(rowStack)
        }
    }

    private func button(for key: KeyboardKey) -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.title = key.label
        configuration.baseBackgroundColor = isControl(key)
            ? .secondarySystemFill
            : .systemBackground
        configuration.baseForegroundColor = .label
        configuration.cornerStyle = .medium
        // Dynamic Type: the label scales with the user's chosen size rather
        // than being pinned to a number (section 126).
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            var attributes = $0
            attributes.font = UIFont.preferredFont(forTextStyle: isControl(key) ? .footnote : .title3)
            return attributes
        }

        let button = UIButton(configuration: configuration)
        button.accessibilityLabel = key.accessibilityLabel
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)

        switch key {
        case .nextKeyboard:
            // Section 11. The system's own action — the keyboard does not
            // decide what "next" means, and must not try to.
            button.addTarget(
                self,
                action: #selector(handleInputModeList(from:with:)),
                for: .allTouchEvents
            )
        case .backspace:
            button.addAction(UIAction { [weak self] _ in self?.deleteBackward() }, for: .touchUpInside)
            let hold = UILongPressGestureRecognizer(
                target: self,
                action: #selector(handleBackspaceHold(_:))
            )
            button.addGestureRecognizer(hold)
        case .shift:
            button.addAction(UIAction { [weak self] _ in self?.press(.shift) }, for: .touchUpInside)
            let double = UITapGestureRecognizer(target: self, action: #selector(handleShiftLock))
            double.numberOfTapsRequired = 2
            button.addGestureRecognizer(double)
        default:
            button.addAction(UIAction { [weak self] _ in self?.press(key) }, for: .touchUpInside)
        }
        return button
    }

    private func isControl(_ key: KeyboardKey) -> Bool {
        switch key {
        case .character: return false
        case .space, .backspace, .shift, .returnKey, .nextKeyboard, .plane: return true
        }
    }

    // MARK: Input

    private func press(_ key: KeyboardKey) {
        if let text = layout.text(for: key) {
            textDocumentProxy.insertText(text)
        }
        let updated = layout.applying(key)
        let needsRedraw = updated.plane != layout.plane
            || updated.shift.producesUppercase != layout.shift.producesUppercase
        layout = updated
        if needsRedraw { renderKeys() }
    }

    private func deleteBackward() {
        textDocumentProxy.deleteBackward()
    }

    @objc private func handleShiftLock() {
        layout = layout.lockingShift()
        renderKeys()
    }

    @objc private func handleBackspaceHold(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            backspaceTimer?.invalidate()
            backspaceTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                // On the main run loop, in the foreground, while the user's
                // finger is down. Not a background timer — see the note in
                // `AppLifecycleCoordinator` about why those do not exist here.
                self?.textDocumentProxy.deleteBackward()
            }
        case .ended, .cancelled, .failed:
            backspaceTimer?.invalidate()
            backspaceTimer = nil
        default:
            break
        }
    }

    // MARK: Assistant

    /// Sends the text the keyboard legitimately has to the application.
    ///
    /// Section 18 and 93: `documentContextBeforeInput` is what the host chose
    /// to expose, and it is all that is read. Nothing walks the document,
    /// nothing accumulates what was typed earlier, and nothing is kept after
    /// the operation finishes (section 94).
    private func perform(_ operation: KeyboardAssistantOperation) {
        let text = textDocumentProxy.documentContextBeforeInput ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        assistantBar?.showWorking()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await bridge.submit(operation: operation, text: text)
            // Section 28 and 105: whatever came back, the user's text is still
            // where they left it. Nothing is replaced without them saying so.
            self.assistantBar?.show(result: result, original: text)
        }
    }

    /// Replaces the text — only ever after the user taps Accept.
    ///
    /// Section 134's last step, and the reason it is a separate method from
    /// `perform`. The deletion loop is bounded by the length of the text the
    /// request was made about, so a proxy that reports something unexpected
    /// cannot turn this into an unbounded delete of the host's document.
    private func accept(_ replacement: KeyboardAssistantAcceptance) {
        for _ in 0..<replacement.charactersToDelete {
            textDocumentProxy.deleteBackward()
        }
        textDocumentProxy.insertText(replacement.text)
        assistantBar?.reset()
    }

    private func cancelAssistant() {
        // Section 27: cancelling leaves the text exactly as it was. There is
        // nothing to undo, because nothing was changed.
        bridge.cancel()
        assistantBar?.reset()
    }
}
