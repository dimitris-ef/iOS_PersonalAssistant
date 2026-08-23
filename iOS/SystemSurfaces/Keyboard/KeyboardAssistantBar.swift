import SystemSurfaces
import UIKit

/// The one row above the keys.
///
/// Section 17 and 131: a small set of actions and a place to show what came
/// back. Not a chat window, not a conversation, not a second app.
///
/// It has four states and they are all visible in the code below: offering
/// actions, working, showing a suggestion to accept or reject, and explaining
/// that it cannot help right now. The fourth is the one that matters most —
/// section 28 requires that a failure leave the user's text alone and say so
/// compactly, and this is where that is honoured.
final class KeyboardAssistantBar: UIView {

    var onOperation: ((KeyboardAssistantOperation) -> Void)?
    var onAccept: ((KeyboardAssistantAcceptance) -> Void)?
    var onCancel: (() -> Void)?

    private let actionStack = UIStackView()
    private let statusLabel = UILabel()
    private let suggestionLabel = UILabel()
    private let acceptButton = UIButton(configuration: .filled())
    private let dismissButton = UIButton(configuration: .plain())
    private let spinner = UIActivityIndicatorView(style: .medium)

    private var configuration = KeyboardConfigurationSnapshot(generatedAt: .now)
    private var hasText = false
    private var suggestion: KeyboardAssistantAcceptance?

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Building

    private func build() {
        actionStack.axis = .horizontal
        actionStack.spacing = 6
        actionStack.distribution = .fillProportionally

        statusLabel.font = .preferredFont(forTextStyle: .caption1)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textColor = .secondaryLabel
        statusLabel.isHidden = true

        suggestionLabel.font = .preferredFont(forTextStyle: .footnote)
        suggestionLabel.adjustsFontForContentSizeCategory = true
        suggestionLabel.numberOfLines = 1
        suggestionLabel.lineBreakMode = .byTruncatingTail
        suggestionLabel.isHidden = true

        acceptButton.configuration?.title = "Use"
        acceptButton.configuration?.cornerStyle = .capsule
        acceptButton.isHidden = true
        acceptButton.accessibilityLabel = "Use the suggested text"
        acceptButton.addAction(
            UIAction { [weak self] _ in
                guard let suggestion = self?.suggestion else { return }
                self?.onAccept?(suggestion)
            },
            for: .touchUpInside
        )

        dismissButton.configuration?.image = UIImage(systemName: "xmark")
        dismissButton.isHidden = true
        dismissButton.accessibilityLabel = "Dismiss"
        dismissButton.addAction(
            UIAction { [weak self] _ in self?.onCancel?() },
            for: .touchUpInside
        )

        spinner.hidesWhenStopped = true

        let row = UIStackView(arrangedSubviews: [
            actionStack, spinner, statusLabel, suggestionLabel, acceptButton, dismissButton,
        ])
        row.axis = .horizontal
        row.spacing = 8
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: State

    /// Section 12 and 14. With no shared access the row explains itself rather
    /// than disappearing — a button that vanishes teaches the user the feature
    /// is broken; one that says what to do teaches them what to do.
    func apply(_ configuration: KeyboardConfigurationSnapshot) {
        self.configuration = configuration
        reset()
    }

    func setHasText(_ hasText: Bool) {
        self.hasText = hasText
        updateActionAvailability()
    }

    func reset() {
        suggestion = nil
        spinner.stopAnimating()
        suggestionLabel.isHidden = true
        acceptButton.isHidden = true
        dismissButton.isHidden = true

        actionStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        guard configuration.assistantActionsEnabled, !configuration.operations.isEmpty else {
            actionStack.isHidden = true
            statusLabel.isHidden = false
            statusLabel.text = "Assistant actions need Full Access"
            return
        }

        statusLabel.isHidden = true
        actionStack.isHidden = false
        for operation in configuration.operations {
            actionStack.addArrangedSubview(button(for: operation))
        }
        updateActionAvailability()
    }

    func showWorking() {
        actionStack.isHidden = true
        suggestionLabel.isHidden = true
        acceptButton.isHidden = true
        statusLabel.isHidden = false
        statusLabel.text = "Working…"
        spinner.startAnimating()
        dismissButton.isHidden = false
    }

    /// Section 28 and 105. Whatever happened, the original text is untouched —
    /// this only ever *offers* a replacement.
    func show(result: KeyboardAssistantResult, original: String) {
        spinner.stopAnimating()

        switch result.status {
        case .completed:
            guard let text = result.text, !text.isEmpty else {
                showFailure("Assistant unavailable")
                return
            }
            suggestion = KeyboardAssistantAcceptance(
                text: text,
                charactersToDelete: original.count
            )
            statusLabel.isHidden = true
            actionStack.isHidden = true
            suggestionLabel.isHidden = false
            suggestionLabel.text = text
            suggestionLabel.accessibilityLabel = "Suggested: \(text)"
            acceptButton.isHidden = false
            dismissButton.isHidden = false

        case .cancelled:
            reset()

        case .failed, .unavailable, .pending:
            // Offer the deterministic tidy-up, clearly labelled as what it is
            // rather than as the assistant's answer (section 24).
            if let tidied = KeyboardAssistantBridge.localFallback(for: original) {
                suggestion = KeyboardAssistantAcceptance(
                    text: tidied,
                    charactersToDelete: original.count
                )
                statusLabel.isHidden = false
                statusLabel.text = result.error ?? "Assistant unavailable"
                actionStack.isHidden = true
                suggestionLabel.isHidden = false
                suggestionLabel.text = "Tidy up instead"
                acceptButton.isHidden = false
                dismissButton.isHidden = false
            } else {
                showFailure(result.error ?? "Assistant unavailable")
            }
        }
    }

    private func showFailure(_ message: String) {
        suggestion = nil
        spinner.stopAnimating()
        actionStack.isHidden = true
        suggestionLabel.isHidden = true
        acceptButton.isHidden = true
        dismissButton.isHidden = false
        statusLabel.isHidden = false
        statusLabel.text = message
    }

    private func updateActionAvailability() {
        // Section 18 and 19: a secure field exposes nothing to the proxy, so
        // there is nothing to improve. The buttons disable rather than lie.
        for view in actionStack.arrangedSubviews {
            (view as? UIButton)?.isEnabled = hasText
        }
    }

    private func button(for operation: KeyboardAssistantOperation) -> UIButton {
        var configuration = UIButton.Configuration.gray()
        configuration.title = operation.title
        configuration.cornerStyle = .capsule
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            var attributes = $0
            attributes.font = UIFont.preferredFont(forTextStyle: .caption1)
            return attributes
        }

        let button = UIButton(configuration: configuration)
        button.accessibilityLabel = operation.title
        button.addAction(
            UIAction { [weak self] _ in self?.onOperation?(operation) },
            for: .touchUpInside
        )
        return button
    }
}
