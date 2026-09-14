import UIKit
import SwiftTerm

public protocol FilaireAccessoryDelegate: AnyObject {
    func accessoryDidSendBytes(_ bytes: [UInt8])
    func accessoryDidInsertText(_ text: String)
    func accessoryDidToggleControl(isActive: Bool)
    func accessoryDidToggleAlt(isActive: Bool)
    func accessoryDidRequestDismissKeyboard()
    func accessoryDidRequestPaste()
}

public extension FilaireAccessoryDelegate {
    func accessoryDidRequestPaste() {}
}

public final class FilaireAccessoryView: UIInputView, UIInputViewAudioFeedback {
    public weak var accessoryDelegate: FilaireAccessoryDelegate?

    public var enableInputClicksWhenVisible: Bool { true }

    public private(set) var isControlActive: Bool = false {
        didSet {
            ctrlButton.backgroundColor = isControlActive ? SolarizedDarkTheme.yellow : SolarizedDarkTheme.base03
            ctrlButton.setTitleColor(isControlActive ? SolarizedDarkTheme.base03 : SolarizedDarkTheme.base0, for: .normal)
            accessoryDelegate?.accessoryDidToggleControl(isActive: isControlActive)
        }
    }

    public private(set) var isAltActive: Bool = false {
        didSet {
            altButton.backgroundColor = isAltActive ? SolarizedDarkTheme.orange : SolarizedDarkTheme.base03
            altButton.setTitleColor(isAltActive ? SolarizedDarkTheme.base03 : SolarizedDarkTheme.base0, for: .normal)
            accessoryDelegate?.accessoryDidToggleAlt(isActive: isAltActive)
        }
    }

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
        setupView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupView() {
        backgroundColor = SolarizedDarkTheme.base02
        autoresizingMask = [.flexibleWidth, .flexibleHeight]

        // Top separator line
        let separator = UIView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.backgroundColor = SolarizedDarkTheme.base01.withAlphaComponent(0.4)
        addSubview(separator)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        addSubview(scrollView)

        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .horizontal
        stackView.spacing = 6
        stackView.alignment = .center
        stackView.distribution = .fill
        scrollView.addSubview(stackView)

        // 1. Dedicated Tmux prefix and copy mode buttons
        stackView.addArrangedSubview(tmuxPrefixButton)
        stackView.addArrangedSubview(tmuxCopyModeButton)

        // 2. Modifiers & Clipboard
        stackView.addArrangedSubview(ctrlButton)
        stackView.addArrangedSubview(altButton)
        stackView.addArrangedSubview(pasteButton)

        // 3. Essential terminal keys
        stackView.addArrangedSubview(escButton)
        stackView.addArrangedSubview(tabButton)
        stackView.addArrangedSubview(ctrlCButton)
        stackView.addArrangedSubview(ctrlDButton)
        stackView.addArrangedSubview(ctrlZButton)
        stackView.addArrangedSubview(ctrlLButton)

        // 4. Directional arrows
        stackView.addArrangedSubview(makeArrowButton(symbol: "arrow.left", action: #selector(didTapLeft)))
        stackView.addArrangedSubview(makeArrowButton(symbol: "arrow.up", action: #selector(didTapUp)))
        stackView.addArrangedSubview(makeArrowButton(symbol: "arrow.down", action: #selector(didTapDown)))
        stackView.addArrangedSubview(makeArrowButton(symbol: "arrow.right", action: #selector(didTapRight)))

        // 5. Common terminal symbols
        for symbol in ["|", "~", "/", "\\", "-", "_", "$", "`"] {
            stackView.addArrangedSubview(makeSymbolButton(symbol: symbol))
        }

        // 6. Dismiss keyboard
        let dismissButton = makeIconButton(
            systemName: "keyboard.chevron.compact.down",
            action: #selector(didTapDismissKeyboard)
        )
        stackView.addArrangedSubview(dismissButton)

        let height: CGFloat = UIDevice.current.userInterfaceIdiom == .phone ? 38 : 40

        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 0.5),

            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: height),

            stackView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            stackView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            stackView.heightAnchor.constraint(equalTo: scrollView.heightAnchor)
        ])
    }

    public override var intrinsicContentSize: CGSize {
        let height: CGFloat = UIDevice.current.userInterfaceIdiom == .phone ? 38 : 40
        return CGSize(width: UIView.noIntrinsicMetric, height: height)
    }

    public func resetStickyModifiers() {
        if isControlActive { isControlActive = false }
        if isAltActive { isAltActive = false }
    }

    // MARK: - Button Factory

    private func makeButton(
        title: String,
        isAccent: Bool = false,
        action: Selector
    ) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.title = title
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
        config.baseForegroundColor = isAccent ? SolarizedDarkTheme.cyan : SolarizedDarkTheme.base0

        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.titleLabel?.font = UIFont.monospacedSystemFont(ofSize: 12, weight: isAccent ? .bold : .medium)

        let bg = isAccent ? SolarizedDarkTheme.cyan.withAlphaComponent(0.25) : SolarizedDarkTheme.base03
        button.backgroundColor = bg
        button.layer.cornerRadius = 6
        button.layer.borderWidth = isAccent ? 1.5 : 0.5
        button.layer.borderColor = (isAccent ? SolarizedDarkTheme.cyan : SolarizedDarkTheme.base01).cgColor
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    private func makeArrowButton(symbol: String, action: Selector) -> UIButton {
        var config = UIButton.Configuration.plain()
        let imageConfig = UIImage.SymbolConfiguration(pointSize: 11, weight: .bold)
        config.image = UIImage(systemName: symbol, withConfiguration: imageConfig)
        config.baseForegroundColor = SolarizedDarkTheme.base0
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)

        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.backgroundColor = SolarizedDarkTheme.base03
        button.layer.cornerRadius = 6
        button.layer.borderWidth = 0.5
        button.layer.borderColor = SolarizedDarkTheme.base01.cgColor
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    private func makeIconButton(systemName: String, action: Selector) -> UIButton {
        var config = UIButton.Configuration.plain()
        let imageConfig = UIImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        config.image = UIImage(systemName: systemName, withConfiguration: imageConfig)
        config.baseForegroundColor = SolarizedDarkTheme.base01
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)

        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.backgroundColor = SolarizedDarkTheme.base03
        button.layer.cornerRadius = 6
        button.layer.borderWidth = 0.5
        button.layer.borderColor = SolarizedDarkTheme.base01.cgColor
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    private func makeSymbolButton(symbol: String) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.title = symbol
        config.baseForegroundColor = SolarizedDarkTheme.base0
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)

        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.titleLabel?.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .medium)
        button.backgroundColor = SolarizedDarkTheme.base03
        button.layer.cornerRadius = 6
        button.layer.borderWidth = 0.5
        button.layer.borderColor = SolarizedDarkTheme.base01.cgColor
        button.addAction(UIAction { [weak self] _ in
            self?.playClick()
            self?.accessoryDelegate?.accessoryDidInsertText(symbol)
        }, for: .touchUpInside)
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
