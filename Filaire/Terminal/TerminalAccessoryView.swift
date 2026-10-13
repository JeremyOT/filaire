import UIKit
import SwiftTerm

public protocol FilaireAccessoryDelegate: AnyObject {
    func accessoryDidSendBytes(_ bytes: [UInt8])
    func accessoryDidInsertText(_ text: String)
    func accessoryDidToggleControl(isActive: Bool)
    func accessoryDidToggleAlt(isActive: Bool)
    func accessoryDidRequestDismissKeyboard()
    func accessoryDidRequestPaste()
    func accessoryDidRequestComposer()
    func accessoryDidRequestSnippets()
}

public extension FilaireAccessoryDelegate {
    func accessoryDidRequestPaste() {}
    func accessoryDidRequestComposer() {}
    func accessoryDidRequestSnippets() {}
}

public final class FilaireAccessoryView: UIInputView, UIInputViewAudioFeedback {
    public weak var accessoryDelegate: FilaireAccessoryDelegate?

    public var enableInputClicksWhenVisible: Bool { true }

    public private(set) var isControlActive: Bool = false {
        didSet {
            updateModifierButtonStates()
            accessoryDelegate?.accessoryDidToggleControl(isActive: isControlActive)
        }
    }

    public private(set) var isAltActive: Bool = false {
        didSet {
            updateModifierButtonStates()
            accessoryDelegate?.accessoryDidToggleAlt(isActive: isAltActive)
        }
    }

    private var normalButtons: [UIButton] = []
    private var separatorView: UIView?
    private var currentTheme: any TerminalTheme = ThemeManager.shared.currentTheme

    private let scrollView = UIScrollView()
    private let stackView = UIStackView()
    private var tmuxPrefixByte: UInt8 = 0x02

    private lazy var tmuxPrefixButton: UIButton = makeButton(
        title: "Ctrl-B",
        isAccent: true,
        action: #selector(didTapTmuxPrefix)
    )

    private lazy var tmuxCopyModeButton: UIButton = makeButton(
        title: "Copy",
        action: #selector(didTapTmuxCopyMode)
    )

    public func configureTmux(enabled: Bool, prefixTitle: String = "Ctrl-B", prefixByte: UInt8 = 0x02) {
        self.tmuxPrefixByte = prefixByte
        var config = tmuxPrefixButton.configuration ?? .plain()
        config.title = prefixTitle
        tmuxPrefixButton.configuration = config
        tmuxPrefixButton.isHidden = !enabled
        tmuxCopyModeButton.isHidden = !enabled
    }

    private lazy var escButton: UIButton = makeButton(
        title: "Esc",
        action: #selector(didTapEsc)
    )

    private lazy var tabButton: UIButton = makeButton(
        title: "Tab",
        action: #selector(didTapTab)
    )

    private lazy var ctrlButton: UIButton = makeButton(
        title: "Ctrl",
        action: #selector(didTapCtrl)
    )

    private lazy var altButton: UIButton = makeButton(
        title: "Alt",
        action: #selector(didTapAlt)
    )

    private lazy var pasteButton: UIButton = makeButton(
        title: "Paste",
        action: #selector(didTapPaste)
    )

    private lazy var composeButton: UIButton = makeButton(
        title: "Compose",
        action: #selector(didTapCompose)
    )

    private lazy var snippetsButton: UIButton = makeButton(
        title: "Snippets",
        action: #selector(didTapSnippets)
    )

    /// Pinned outside the scrolling row: as the last item in a long scroll view it was unreachable on a
    /// phone without scrolling to the far end, leaving no way to put the keyboard away.
    private lazy var dismissKeyboardButton: UIButton = makeIconButton(
        systemName: "keyboard.chevron.compact.down",
        action: #selector(didTapDismissKeyboard)
    )

    private lazy var ctrlCButton: UIButton = makeButton(
        title: "Ctrl-C",
        action: #selector(didTapCtrlC)
    )

    private lazy var ctrlDButton: UIButton = makeButton(
        title: "Ctrl-D",
        action: #selector(didTapCtrlD)
    )

    private lazy var ctrlZButton: UIButton = makeButton(
        title: "Ctrl-Z",
        action: #selector(didTapCtrlZ)
    )

    private lazy var ctrlLButton: UIButton = makeButton(
        title: "Ctrl-L",
        action: #selector(didTapCtrlL)
    )

    public init(frame: CGRect = .zero, delegate: FilaireAccessoryDelegate? = nil) {
        self.accessoryDelegate = delegate
        super.init(frame: frame, inputViewStyle: .keyboard)
        allowsSelfSizing = true
        setupView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupView() {
        backgroundColor = currentTheme.secondarySurface
        autoresizingMask = [.flexibleWidth, .flexibleHeight]

        // Top separator line
        let separator = UIView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.backgroundColor = currentTheme.separator.withAlphaComponent(0.4)
        self.separatorView = separator
        addSubview(separator)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        addSubview(scrollView)

        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .horizontal
        stackView.spacing = 6
        stackView.alignment = .fill
        stackView.distribution = .fill
        scrollView.addSubview(stackView)

        // 1. Composing tools: Compose and Snippets
        stackView.addArrangedSubview(composeButton)
        stackView.addArrangedSubview(snippetsButton)

        // 2. Dedicated Tmux prefix and copy mode buttons
        stackView.addArrangedSubview(tmuxPrefixButton)
        stackView.addArrangedSubview(tmuxCopyModeButton)

        // 3. Modifiers & Clipboard
        stackView.addArrangedSubview(ctrlButton)
        stackView.addArrangedSubview(altButton)
        stackView.addArrangedSubview(pasteButton)

        // 4. Essential terminal keys
        stackView.addArrangedSubview(escButton)
        stackView.addArrangedSubview(tabButton)
        stackView.addArrangedSubview(ctrlCButton)
        stackView.addArrangedSubview(ctrlDButton)
        stackView.addArrangedSubview(ctrlZButton)
        stackView.addArrangedSubview(ctrlLButton)

        // 5. Directional arrows
        stackView.addArrangedSubview(makeArrowButton(symbol: "arrow.left", action: #selector(didTapLeft)))
        stackView.addArrangedSubview(makeArrowButton(symbol: "arrow.up", action: #selector(didTapUp)))
        stackView.addArrangedSubview(makeArrowButton(symbol: "arrow.down", action: #selector(didTapDown)))
        stackView.addArrangedSubview(makeArrowButton(symbol: "arrow.right", action: #selector(didTapRight)))

        // 6. Common terminal symbols
        for symbol in ["|", "~", "/", "\\", "-", "_", "$", "`"] {
            stackView.addArrangedSubview(makeSymbolButton(symbol: symbol))
        }

        // 7. Dismiss keyboard, pinned beside the scrolling row so it never scrolls out of reach.
        //
        // The scroll view stays a direct subview: it has no intrinsic width, so priorities rather than
        // structure decide who yields. Without these the solver was free to starve the scroll view to zero
        // and leave only this button, which persisted because the bar is built once and reused across
        // keyboard presentations.
        addSubview(dismissKeyboardButton)
        dismissKeyboardButton.setContentHuggingPriority(.required, for: .horizontal)
        dismissKeyboardButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        scrollView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        scrollView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let height: CGFloat = 44

        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 0.5),

            // No fixed height here: pinning top-and-bottom *and* a constant made the view 44.5pt tall while
            // intrinsicContentSize declared 44, so Auto Layout had to break one of them on every relayout,
            // and the one it dropped could be the trailing edge that gives the row its width.
            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            scrollView.trailingAnchor.constraint(equalTo: dismissKeyboardButton.leadingAnchor, constant: -6),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            dismissKeyboardButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            dismissKeyboardButton.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            dismissKeyboardButton.heightAnchor.constraint(equalToConstant: height - 4),
            dismissKeyboardButton.widthAnchor.constraint(equalToConstant: height - 4),

            stackView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            stackView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            stackView.heightAnchor.constraint(equalTo: scrollView.heightAnchor)
        ])

        applyTheme(ThemeManager.shared.currentTheme)
    }

    public override var intrinsicContentSize: CGSize {
        return CGSize(width: UIView.noIntrinsicMetric, height: 44)
    }

    public func resetStickyModifiers() {
        if isControlActive { isControlActive = false }
        if isAltActive { isAltActive = false }
    }

    public func applyTheme(_ theme: any TerminalTheme) {
        self.currentTheme = theme
        backgroundColor = theme.secondarySurface
        separatorView?.backgroundColor = theme.separator.withAlphaComponent(0.4)

        for button in normalButtons {
            button.backgroundColor = theme.tertiarySurface
            button.layer.borderColor = theme.separator.cgColor
            var config = button.configuration
            config?.baseForegroundColor = theme.secondaryText
            button.configuration = config
        }

        // tmuxPrefixButton is accent
        tmuxPrefixButton.backgroundColor = theme.accent.withAlphaComponent(0.25)
        tmuxPrefixButton.layer.borderColor = theme.accent.cgColor
        var prefixConfig = tmuxPrefixButton.configuration
        prefixConfig?.baseForegroundColor = theme.accent
        tmuxPrefixButton.configuration = prefixConfig

        // dismissKeyboardButton
        dismissKeyboardButton.backgroundColor = theme.tertiarySurface
        dismissKeyboardButton.layer.borderColor = theme.separator.cgColor
        var dismissConfig = dismissKeyboardButton.configuration
        dismissConfig?.baseForegroundColor = theme.mutedText
        dismissKeyboardButton.configuration = dismissConfig

        updateModifierButtonStates()
    }

    private func updateModifierButtonStates() {
        let theme = currentTheme
        ctrlButton.backgroundColor = isControlActive ? theme.warning : theme.tertiarySurface
        ctrlButton.setTitleColor(isControlActive ? theme.surfaceBackground : theme.secondaryText, for: .normal)
        var ctrlConfig = ctrlButton.configuration
        ctrlConfig?.baseForegroundColor = isControlActive ? theme.surfaceBackground : theme.secondaryText
        ctrlButton.configuration = ctrlConfig

        altButton.backgroundColor = isAltActive ? theme.altAccent : theme.tertiarySurface
        altButton.setTitleColor(isAltActive ? theme.surfaceBackground : theme.secondaryText, for: .normal)
        var altConfig = altButton.configuration
        altConfig?.baseForegroundColor = isAltActive ? theme.surfaceBackground : theme.secondaryText
        altButton.configuration = altConfig
    }

    // MARK: - Button Factory

    private func makeButton(
        title: String,
        isAccent: Bool = false,
        action: Selector
    ) -> UIButton {
        let theme = currentTheme
        var config = UIButton.Configuration.plain()
        config.title = title
        config.titleLineBreakMode = .byClipping
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFont.monospacedSystemFont(ofSize: 12, weight: isAccent ? .bold : .medium)
            return outgoing
        }
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
        config.baseForegroundColor = isAccent ? theme.accent : theme.secondaryText

        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.titleLabel?.numberOfLines = 1
        button.titleLabel?.lineBreakMode = .byClipping

        let bg = isAccent ? theme.accent.withAlphaComponent(0.25) : theme.tertiarySurface
        button.backgroundColor = bg
        button.layer.cornerRadius = 6
        button.layer.borderWidth = isAccent ? 1.5 : 0.5
        button.layer.borderColor = (isAccent ? theme.accent : theme.separator).cgColor
        button.addTarget(self, action: action, for: .touchUpInside)
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        if !isAccent {
            normalButtons.append(button)
        }
        return button
    }

    private func makeArrowButton(symbol: String, action: Selector) -> UIButton {
        let theme = currentTheme
        var config = UIButton.Configuration.plain()
        let imageConfig = UIImage.SymbolConfiguration(pointSize: 11, weight: .bold)
        config.image = UIImage(systemName: symbol, withConfiguration: imageConfig)
        config.baseForegroundColor = theme.secondaryText
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)

        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.backgroundColor = theme.tertiarySurface
        button.layer.cornerRadius = 6
        button.layer.borderWidth = 0.5
        button.layer.borderColor = theme.separator.cgColor
        button.addTarget(self, action: action, for: .touchUpInside)
        button.widthAnchor.constraint(equalToConstant: 44).isActive = true
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        normalButtons.append(button)
        return button
    }

    private func makeIconButton(systemName: String, action: Selector) -> UIButton {
        let theme = currentTheme
        var config = UIButton.Configuration.plain()
        let imageConfig = UIImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        config.image = UIImage(systemName: systemName, withConfiguration: imageConfig)
        config.baseForegroundColor = theme.mutedText
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)

        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.backgroundColor = theme.tertiarySurface
        button.layer.cornerRadius = 6
        button.layer.borderWidth = 0.5
        button.layer.borderColor = theme.separator.cgColor
        button.addTarget(self, action: action, for: .touchUpInside)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    private func makeSymbolButton(symbol: String) -> UIButton {
        let theme = currentTheme
        var config = UIButton.Configuration.plain()
        config.title = symbol
        config.titleLineBreakMode = .byClipping
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .medium)
            return outgoing
        }
        config.baseForegroundColor = theme.secondaryText
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)

        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.titleLabel?.numberOfLines = 1
        button.titleLabel?.lineBreakMode = .byClipping
        button.backgroundColor = theme.tertiarySurface
        button.layer.cornerRadius = 6
        button.layer.borderWidth = 0.5
        button.layer.borderColor = theme.separator.cgColor
        button.addAction(UIAction { [weak self] _ in
            self?.playClick()
            self?.accessoryDelegate?.accessoryDidInsertText(symbol)
        }, for: .touchUpInside)
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        normalButtons.append(button)
        return button
    }

    private func playClick() {
        UIDevice.current.playInputClick()
    }

    // MARK: - Actions

    @objc private func didTapTmuxPrefix() {
        playClick()
        accessoryDelegate?.accessoryDidSendBytes([tmuxPrefixByte])
    }

    @objc private func didTapTmuxCopyMode() {
        playClick()
        accessoryDelegate?.accessoryDidSendBytes([tmuxPrefixByte, UInt8(ascii: "[")])
    }

    @objc private func didTapEsc() {
        playClick()
        accessoryDelegate?.accessoryDidSendBytes([0x1b])
    }

    @objc private func didTapTab() {
        playClick()
        accessoryDelegate?.accessoryDidSendBytes([0x09])
    }

    public func toggleControl() {
        didTapCtrl()
    }

    public func toggleAlt() {
        didTapAlt()
    }

    @objc private func didTapCtrl() {
        playClick()
        isControlActive.toggle()
    }

    @objc private func didTapAlt() {
        playClick()
        isAltActive.toggle()
    }

    @objc private func didTapPaste() {
        playClick()
        accessoryDelegate?.accessoryDidRequestPaste()
    }

    @objc private func didTapCompose() {
        playClick()
        accessoryDelegate?.accessoryDidRequestComposer()
    }

    @objc private func didTapSnippets() {
        playClick()
        accessoryDelegate?.accessoryDidRequestSnippets()
    }

    @objc private func didTapCtrlC() {
        playClick()
        // Ctrl-C is ASCII 3 (0x03)
        accessoryDelegate?.accessoryDidSendBytes([0x03])
    }

    @objc private func didTapCtrlD() {
        playClick()
        // Ctrl-D is ASCII 4 (0x04)
        accessoryDelegate?.accessoryDidSendBytes([0x04])
    }

    @objc private func didTapCtrlZ() {
        playClick()
        // Ctrl-Z is ASCII 26 (0x1A)
        accessoryDelegate?.accessoryDidSendBytes([0x1a])
    }

    @objc private func didTapCtrlL() {
        playClick()
        // Ctrl-L is ASCII 12 (0x0C) - form feed / clear screen
        accessoryDelegate?.accessoryDidSendBytes([0x0c])
    }

    @objc private func didTapLeft() {
        playClick()
        if isAltActive {
            resetStickyModifiers()
            accessoryDelegate?.accessoryDidSendBytes([0x1b, 0x62]) // Esc-b (move word backward)
            return
        }
        if isControlActive {
            resetStickyModifiers()
            accessoryDelegate?.accessoryDidSendBytes([0x01]) // Ctrl-A (beginning of line)
            return
        }
        accessoryDelegate?.accessoryDidSendBytes([0x1b, 0x5b, 0x44]) // \e[D
    }

    @objc private func didTapUp() {
        playClick()
        resetStickyModifiers()
        accessoryDelegate?.accessoryDidSendBytes([0x1b, 0x5b, 0x41]) // \e[A
    }

    @objc private func didTapDown() {
        playClick()
        resetStickyModifiers()
        accessoryDelegate?.accessoryDidSendBytes([0x1b, 0x5b, 0x42]) // \e[B
    }

    @objc private func didTapRight() {
        playClick()
        if isAltActive {
            resetStickyModifiers()
            accessoryDelegate?.accessoryDidSendBytes([0x1b, 0x66]) // Esc-f (move word forward)
            return
        }
        if isControlActive {
            resetStickyModifiers()
            accessoryDelegate?.accessoryDidSendBytes([0x05]) // Ctrl-E (end of line)
            return
        }
        accessoryDelegate?.accessoryDidSendBytes([0x1b, 0x5b, 0x43]) // \e[C
    }

    @objc private func didTapDismissKeyboard() {
        playClick()
        accessoryDelegate?.accessoryDidRequestDismissKeyboard()
    }
}
