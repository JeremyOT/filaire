import UIKit
import SwiftTerm

public enum SceneFocusIntent: Equatable, Sendable {
    case terminal
    case hostEditorOrSearch
    case securityPrompt
    case preview
    case modalPresentation
    case none
}

@MainActor
public protocol FilaireFocusGate: AnyObject {
    func canPromoteTerminalFocus() -> Bool
    func terminalDidReceiveUserInput()
}

open class FilaireTerminalView: TerminalView, FilaireAccessoryDelegate, UIGestureRecognizerDelegate {
    public static let detectedUrlParamKey = "filaire-detected-url"
    public private(set) var customAccessoryView: FilaireAccessoryView?
    public weak var focusGate: (any FilaireFocusGate)?
    public var onInteraction: (() -> Void)?
    public var focusIntent: SceneFocusIntent = .terminal
    private var focusGeneration: Int = 0

    public func cancelPendingFocusRequests() {
        focusGeneration &+= 1
    }

    public func scheduleFocusPromotion(delay: TimeInterval, reason: String = "") {
        let currentGen = focusGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            guard self.focusGeneration == currentGen else { return }
            self.requestKeyboardPromotion()
        }
    }

    public func requestKeyboardPromotion() {
        guard let win = self.window else { return }
        if let scene = win.windowScene {
            guard scene.activationState == .foregroundActive else { return }
        }
        guard win.isKeyWindow else { return }
        guard win.rootViewController?.presentedViewController == nil else { return }
        if let activeResponder = win.findFirstResponder(), activeResponder !== self {
            return
        }
        if let gate = focusGate, !gate.canPromoteTerminalFocus() {
            return
        }
        guard self.focusIntent == .terminal else { return }
        guard self.canBecomeFirstResponder else { return }
        guard !self.isFirstResponder else { return }
        _ = self.becomeFirstResponder()
    }

    private var pinchBaseFontSize: CGFloat = 13.0
    private var accumulatedScrollDeltaY: CGFloat = 0
    private var twoFingerScrollGesture: UIPanGestureRecognizer?
    public var currentTouchType: UITouch.TouchType = .direct
    private var pinchGesture: UIPinchGestureRecognizer?
    private var trackpadScrollGesture: UIPanGestureRecognizer?
    private var urlTapGesture: UITapGestureRecognizer?
    private var customHoverGesture: UIHoverGestureRecognizer?
    private var threeFingerSwipeLeft: UISwipeGestureRecognizer?
    private var threeFingerSwipeRight: UISwipeGestureRecognizer?
    private var currentHoveredMatch: DetectedUrlMatch?
    private var lastHoverGridPosition: Position?
    private var cachedCellDimension: (font: UIFont, scale: CGFloat, size: CGSize)?
    private let urlHighlightLayer = CAShapeLayer()
    private let urlUnderlineLayer = CAShapeLayer()
    private let visualBellLayer = CALayer()
    private var accumulatedTwoFingerDeltaY: CGFloat = 0
    public var isStatusExpanded: Bool = false
    public var topOverlayHeight: CGFloat = 44
    public var autoConnectTmux: Bool = true
    public var tmuxPrefixByte: UInt8 = 0x02
    public var tmuxPrefixTitle: String = "Ctrl-B"

    public func configureTmux(enabled: Bool, prefixTitle: String, prefixByte: UInt8) {
        let changed = (self.autoConnectTmux != enabled)
        self.autoConnectTmux = enabled
        self.tmuxPrefixTitle = prefixTitle
        self.tmuxPrefixByte = prefixByte
        customAccessoryView?.configureTmux(enabled: enabled, prefixTitle: prefixTitle, prefixByte: prefixByte)
        if changed && isFirstResponder {
            reloadInputViews()
        }
    }

    public let escapeSequenceFilter = TerminalEscapeSequenceFilter()

    public static let cursorBlinkAnimationKey = "FilaireCaretBlinkAnimation"
    private weak var cachedCaretView: UIView?
    private var windowObservers: [any NSObjectProtocol] = []
    private var terminalSettingsObserver: (any NSObjectProtocol)?

    public var caretSubView: UIView? {
        if let cached = cachedCaretView, cached.superview === self {
            return cached
        }
        let found = subviews.first { String(describing: type(of: $0)).contains("CaretView") }
        cachedCaretView = found
        return found
    }

    public func feedBounded(byteArray: ArraySlice<UInt8>) {
        escapeSequenceFilter.filter(bytes: byteArray) { [weak self] safeBytes in
            self?.feed(byteArray: safeBytes)
        }
    }

    public func feedBounded(text: String) {
        feedBounded(byteArray: Array(text.utf8)[...])
    }

    public override init(frame: CGRect) {
        TerminalView.filaire_ensurePressesSwizzled()
        super.init(frame: frame)
        configureFilaireDefaults()
    }

    public required init?(coder: NSCoder) {
        TerminalView.filaire_ensurePressesSwizzled()
        super.init(coder: coder)
        configureFilaireDefaults()
    }

    deinit {
        stopModifierKeyRepeat()
        removeWindowObservers()
        if let observer = terminalSettingsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    open override func layoutSubviews() {
        super.layoutSubviews()
        clearUrlHighlight()
        visualBellLayer.frame = bounds
        if let window = window, self.contentScaleFactor != window.screen.scale {
            self.contentScaleFactor = window.screen.scale
        }
        ensureCursorActive()
    }

    open override func didMoveToWindow() {
        super.didMoveToWindow()
        if let window = window {
            self.contentScaleFactor = window.screen.scale
            setupWindowObservers(for: window)
        } else {
            removeWindowObservers()
        }
        updateSizeIfNeeded()
        refreshCursorAnimation()
    }

    public func updateSizeIfNeeded() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        clearUrlHighlight()
        setNeedsLayout()
        layoutIfNeeded()
    }

    /// Notifies the delegate of the current terminal column and row dimensions
    public func notifyCurrentDimensions() {
        let terminal = getTerminal()
        if terminal.cols > 0 && terminal.rows > 0 {
            terminalDelegate?.sizeChanged(source: self, newCols: terminal.cols, newRows: terminal.rows)
        }
    }

    public static func isLightColor(_ color: UIColor) -> Bool {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if color.getRed(&r, green: &g, blue: &b, alpha: &a) {
            let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
            return luminance > 0.5
        }
        return false
    }

    private var appliedThemeType: TerminalThemeType?
    internal private(set) var appliedScrollback: Int?
    internal var memoryScrollbackCap: Int?
    public private(set) var hasTrimmedHistory: Bool = false

    public func applyCurrentTheme() {
        let themeType = ThemeManager.shared.selectedThemeType
        guard themeType != appliedThemeType else { return }
        appliedThemeType = themeType
        let theme = ThemeManager.shared.currentTheme
        ThemeManager.shared.applyTheme(to: self)
        let highlightColor = SolarizedDarkTheme.cyan
        urlHighlightLayer.fillColor = highlightColor.withAlphaComponent(0.12).cgColor
        urlUnderlineLayer.strokeColor = highlightColor.withAlphaComponent(0.85).cgColor

        let isLight = Self.isLightColor(theme.background)
        visualBellLayer.backgroundColor = (isLight ? UIColor.black : UIColor.white).cgColor
    }

    public func applyScrollbackLimit() {
        var limit = TerminalSettings.shared.scrollbackLimit.rawValue
        if let cap = memoryScrollbackCap {
            limit = min(limit, cap)
        }
        guard limit != appliedScrollback else { return }
        appliedScrollback = limit
        self.changeScrollback(limit)
    }

    /// Applies configured font family and size from FontManager
    public func applyFontSetting() {
        let newFont = FontManager.shared.currentFont()
        if self.font != newFont {
            self.font = newFont
            clearUrlHighlight()
            updateSizeIfNeeded()
            notifyCurrentDimensions()
        }
    }

    /// Public helper to retrieve total lines in terminal buffer without accessing internal buffer lines directly.
    public var bufferLineCount: Int {
        let terminal = getTerminal()
        if terminal.bufferLine(atRow: 0) == nil { return 0 }
        var low = 0
        var step = 1
        while terminal.bufferLine(atRow: step) != nil {
            low = step
            step *= 2
        }
        var high = step
        while low + 1 < high {
            let mid = (low + high) / 2
            if terminal.bufferLine(atRow: mid) != nil {
                low = mid
            } else {
                high = mid
            }
        }
        return low + 1
    }

    /// Sheds scrollback memory when low memory pressure occurs; the cap stays in force for this view
    public func shedMemoryPressure(cap: Int = 1000) {
        let beforeCount = bufferLineCount
        memoryScrollbackCap = cap
        applyScrollbackLimit()
        let afterCount = bufferLineCount
        if afterCount < beforeCount || beforeCount > cap {
            hasTrimmedHistory = true
        }
    }

    /// Restores configured scrollback limit capacity for future output
    public func restoreScrollbackLimit() {
        guard memoryScrollbackCap != nil else { return }
        memoryScrollbackCap = nil
        applyScrollbackLimit()
    }

    public func acknowledgeTrimNotice() {
        hasTrimmedHistory = false
    }

    private func configureFilaireDefaults() {
        self.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        self.contentMode = .redraw
        if #available(iOS 13.0, *) {
            self.contentScaleFactor = UIScreen.main.scale
        }

        // Disable automatic scroll to top on status bar tap so status bar gestures expand overlay
        self.scrollsToTop = false

        // Disable SwiftTerm's built-in single-line hover highlighting so our multi-line
        // highlight layer can underline and highlight all lines of wrapped URLs together
        self.linkHighlightMode = .hoverWithModifier
        self.linkReporting = .none

        // Setup custom multi-line URL highlight overlay layers
        let highlightColor = SolarizedDarkTheme.cyan
        urlHighlightLayer.fillColor = highlightColor.withAlphaComponent(0.12).cgColor
        urlHighlightLayer.strokeColor = nil
        urlHighlightLayer.zPosition = 100
        layer.addSublayer(urlHighlightLayer)

        urlUnderlineLayer.fillColor = nil
        urlUnderlineLayer.strokeColor = highlightColor.withAlphaComponent(0.85).cgColor
        urlUnderlineLayer.lineWidth = 1.2
        urlUnderlineLayer.zPosition = 101
        layer.addSublayer(urlUnderlineLayer)

        // Setup visual bell flash overlay layer
        visualBellLayer.backgroundColor = UIColor.white.cgColor
        visualBellLayer.opacity = 0.0
        visualBellLayer.zPosition = 105
        layer.addSublayer(visualBellLayer)

        // Apply active theme (defaults to Solarized Dark)
        applyCurrentTheme()

        // Apply scrollback memory limit (defaults to 10,000 lines)
        applyScrollbackLimit()

        // Set Nerd Font / configured font
        self.font = FontManager.shared.currentFont()

        // Explicitly enable mouse reporting for tmux (set -g mouse on)
        self.allowMouseReporting = true

        // Setup custom input accessory view according to settings
        applyAccessoryBarSetting()

        terminalSettingsObserver = NotificationCenter.default.addObserver(
            forName: .terminalSettingsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyAccessoryBarSetting()
            self?.applyFontSetting()
            self?.applyScrollbackLimit()
            self?.applyCurrentTheme()
        }

        // Setup gestures for font scaling, 2-finger window scrolling & trackpad mouse scrolling
        setupGestures()

        // Setup pointer interaction for iPadOS I-beam cursor
        setupCustomPointerInteraction()
    }

    public func applyAccessoryBarSetting() {
        if TerminalSettings.shared.showKeyboardAccessoryBar {
            if self.customAccessoryView == nil {
                let accessory = FilaireAccessoryView(
                    frame: CGRect(x: 0, y: 0, width: bounds.width, height: 38),
                    delegate: self
                )
                accessory.configureTmux(
                    enabled: autoConnectTmux,
                    prefixTitle: tmuxPrefixTitle,
                    prefixByte: tmuxPrefixByte
                )
                self.customAccessoryView = accessory
            }
            if self.inputAccessoryView !== self.customAccessoryView {
                self.inputAccessoryView = self.customAccessoryView
                if isFirstResponder {
                    reloadInputViews()
                }
            }
        } else {
            if self.inputAccessoryView != nil {
                self.inputAccessoryView = nil
                if isFirstResponder {
                    reloadInputViews()
                }
            }
        }
    }

    func isMouseOrSelectionPanGesture(_ gesture: UIGestureRecognizer) -> Bool {
        guard let pan = gesture as? UIPanGestureRecognizer else { return false }
        return pan !== twoFingerScrollGesture && pan !== trackpadScrollGesture
    }

    open override func addGestureRecognizer(_ gestureRecognizer: UIGestureRecognizer) {
        super.addGestureRecognizer(gestureRecognizer)
        if isMouseOrSelectionPanGesture(gestureRecognizer) {
            gestureRecognizer.delegate = self
        }
        if let twoFinger = twoFingerScrollGesture,
           gestureRecognizer !== twoFinger,
           gestureRecognizer !== pinchGesture,
           gestureRecognizer !== trackpadScrollGesture,
           !isMouseOrSelectionPanGesture(gestureRecognizer) {
            gestureRecognizer.require(toFail: twoFinger)
        }
        if let urlTap = urlTapGesture,
           let tap = gestureRecognizer as? UITapGestureRecognizer,
           tap !== urlTap,
           tap.numberOfTapsRequired == 1 && tap.numberOfTouchesRequired == 1 {
            tap.require(toFail: urlTap)
        }
    }

    private func setupGestures() {
        // Pinch-to-zoom font scaling
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinchGesture(_:)))
        addGestureRecognizer(pinch)
        self.pinchGesture = pinch

        // Continuous trackpad scroll support
        let trackpadScroll = UIPanGestureRecognizer(target: self, action: #selector(handleTrackpadScroll(_:)))
        trackpadScroll.allowedScrollTypesMask = .continuous
        addGestureRecognizer(trackpadScroll)
        self.trackpadScrollGesture = trackpadScroll

        // Two-finger touch drag to scroll terminal buffer / tmux window instead of selecting text
        let twoFinger = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerDrag(_:)))
        twoFinger.minimumNumberOfTouches = 2
        twoFinger.maximumNumberOfTouches = 2
        twoFinger.cancelsTouchesInView = true
        twoFinger.delaysTouchesBegan = true
        twoFinger.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        twoFinger.delegate = self
        addGestureRecognizer(twoFinger)
        self.twoFingerScrollGesture = twoFinger

        // URL tap gesture for single-tap link opening (including line-wrapped tmux pane URLs)
        let urlTap = UITapGestureRecognizer(target: self, action: #selector(handleUrlTap(_:)))
        urlTap.numberOfTapsRequired = 1
        urlTap.numberOfTouchesRequired = 1
        urlTap.cancelsTouchesInView = true
        urlTap.delegate = self
        addGestureRecognizer(urlTap)
        self.urlTapGesture = urlTap

        // Hover gesture for multi-line URL highlighting across wrapped lines
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleFilaireHover(_:)))
        addGestureRecognizer(hover)
        self.customHoverGesture = hover

        // Three-finger swipe gestures for fast tmux window navigation
        let swipeLeft = UISwipeGestureRecognizer(target: self, action: #selector(handleThreeFingerSwipeLeft(_:)))
        swipeLeft.direction = .left
        swipeLeft.numberOfTouchesRequired = 3
        swipeLeft.cancelsTouchesInView = true
        swipeLeft.delegate = self
        addGestureRecognizer(swipeLeft)
        self.threeFingerSwipeLeft = swipeLeft

        let swipeRight = UISwipeGestureRecognizer(target: self, action: #selector(handleThreeFingerSwipeRight(_:)))
        swipeRight.direction = .right
        swipeRight.numberOfTouchesRequired = 3
        swipeRight.cancelsTouchesInView = true
        swipeRight.delegate = self
        addGestureRecognizer(swipeRight)
        self.threeFingerSwipeRight = swipeRight

        // Require single-touch and selection gestures to wait for two-finger drag to fail
        for existing in gestureRecognizers ?? [] {
            if isMouseOrSelectionPanGesture(existing) {
                existing.delegate = self
            }
            if existing !== twoFinger, existing !== pinch, existing !== trackpadScroll,
               existing !== swipeLeft, existing !== swipeRight,
               !isMouseOrSelectionPanGesture(existing) {
                existing.require(toFail: twoFinger)
            }
            if let tap = existing as? UITapGestureRecognizer,
               tap !== urlTap,
               tap.numberOfTapsRequired == 1 && tap.numberOfTouchesRequired == 1 {
                tap.require(toFail: urlTap)
            }
        }
    }

    @objc private func handlePinchGesture(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            pinchBaseFontSize = FontManager.shared.fontSize
        case .changed:
            let targetSize = pinchBaseFontSize * gesture.scale
            let clamped = max(9.0, min(targetSize, 32.0))
            if abs(clamped - FontManager.shared.fontSize) >= 0.5 {
                clearUrlHighlight()
                FontManager.shared.fontSize = clamped
                self.font = FontManager.shared.currentFont()
            }
        case .ended, .cancelled:
            clearUrlHighlight()
            updateSizeIfNeeded()
            notifyCurrentDimensions()
        default:
            break
        }
    }

    @objc private func handleTwoFingerDrag(_ gesture: UIPanGestureRecognizer) {
        let terminal = getTerminal()
        switch gesture.state {
        case .began:
            clearUrlHighlight()
            accumulatedTwoFingerDeltaY = 0
            // Clear any text selection that might have started
            selection.selectNone()
            selection.active = false
            // Release button 1 in tmux if mouse reporting was active
            if terminal.mouseMode != .off && allowMouseReporting {
                let loc = gesture.location(in: self)
                let cellWidth = max(1, bounds.width / CGFloat(max(1, terminal.cols)))
                let cellHeight = max(1, bounds.height / CGFloat(max(1, terminal.rows)))
                let col = Int(loc.x / cellWidth)
                let row = Int(loc.y / cellHeight)
                terminal.sendEvent(buttonFlags: 3, x: max(0, col), y: max(0, row))
            }
        case .changed:
            let translation = gesture.translation(in: self)
            gesture.setTranslation(.zero, in: self)
            accumulatedTwoFingerDeltaY += translation.y

            let cellHeight = max(1, bounds.height / CGFloat(max(1, terminal.rows)))
            let cellWidth = max(1, bounds.width / CGFloat(max(1, terminal.cols)))
            // On high-DPI touchscreens, physical touch drag deltas accumulate quickly.
            // Require 2x finger travel distance per line to provide smooth, controlled 2-finger scrolling.
            let threshold = max(28.0, cellHeight * 2.0)

            var steps = 0
            while abs(accumulatedTwoFingerDeltaY) >= threshold && steps < 6 {
                steps += 1
                clearUrlHighlight()
                let isUp = accumulatedTwoFingerDeltaY > 0
                if isUp {
                    accumulatedTwoFingerDeltaY -= threshold
                } else {
                    accumulatedTwoFingerDeltaY += threshold
                }

                if terminal.mouseMode != .off && allowMouseReporting {
                    let loc = gesture.location(in: self)
                    let col = Int(loc.x / cellWidth)
                    let row = Int(loc.y / cellHeight)
                    // SGR mouse wheel up: 64, down: 65
                    let buttonFlag = isUp ? 64 : 65
                    terminal.sendEvent(buttonFlags: buttonFlag, x: max(0, col), y: max(0, row))
                } else {
                    if isUp {
                        scrollUp(lines: 1)
                    } else {
                        scrollDown(lines: 1)
                    }
                }
            }
            if abs(accumulatedTwoFingerDeltaY) >= threshold {
                accumulatedTwoFingerDeltaY = 0
            }
            selection.selectNone()
            selection.active = false
        case .ended, .cancelled:
            accumulatedTwoFingerDeltaY = 0
            selection.selectNone()
            selection.active = false
        default:
            break
        }
    }

    @objc private func handleTrackpadScroll(_ gesture: UIPanGestureRecognizer) {
        let terminal = getTerminal()
        let translation = gesture.translation(in: self)
        gesture.setTranslation(.zero, in: self)

        accumulatedScrollDeltaY += translation.y
        let threshold: CGFloat = 12.0

        if abs(accumulatedScrollDeltaY) >= threshold {
            clearUrlHighlight()
            let isUp = accumulatedScrollDeltaY > 0
            if terminal.mouseMode != .off && allowMouseReporting {
                let loc = gesture.location(in: self)
                let cellWidth = max(1, bounds.width / CGFloat(max(1, terminal.cols)))
                let cellHeight = max(1, bounds.height / CGFloat(max(1, terminal.rows)))
                let col = Int(loc.x / cellWidth)
                let row = Int(loc.y / cellHeight)
                // SGR mouse wheel up: 64, down: 65
                let buttonFlag = isUp ? 64 : 65
                terminal.sendEvent(buttonFlags: buttonFlag, x: max(0, col), y: max(0, row))
            } else {
                if isUp {
                    scrollUp(lines: 1)
                } else {
                    scrollDown(lines: 1)
                }
            }
            accumulatedScrollDeltaY = 0
        }
    }

    // MARK: - Key Commands for Hardware Keyboard Passthrough & Tmux Shortcuts

    private var lastHandledShortcutTime: TimeInterval = 0
    private var lastHandledShortcutId: String = ""

    private func shouldExecuteShortcut(id: String) -> Bool {
        let now = CACurrentMediaTime()
        if lastHandledShortcutId == id && (now - lastHandledShortcutTime) < 0.08 {
            return false
        }
        lastHandledShortcutTime = now
        lastHandledShortcutId = id
        return true
    }

    // MARK: - UIResponder Action Whitelist
    // SwiftTerm overrides canPerformAction to return false for all actions other than copy/paste/select.
    // By overriding target(forAction:withSender:), UIKit's responder chain directly finds FilaireTerminalView
    // as the target for our custom key commands and actions.
    open override func target(forAction action: Selector, withSender sender: Any?) -> Any? {
        switch action {
        case #selector(handleControlKeyCommand(_:)),
             #selector(handleTmuxNumberShortcut(_:)),
             #selector(handleTmuxNewWindow(_:)),
             #selector(handleTmuxClosePane(_:)),
             #selector(handleTmuxRenameWindow(_:)),
             #selector(handleTmuxNextWindow(_:)),
             #selector(handleTmuxPrevWindow(_:)),
             #selector(handleTmuxSplitVertical(_:)),
             #selector(handleTmuxSplitHorizontal(_:)),
             #selector(handleTmuxSelectPaneUp(_:)),
             #selector(handleTmuxSelectPaneDown(_:)),
             #selector(handleTmuxSelectPaneLeft(_:)),
             #selector(handleTmuxSelectPaneRight(_:)),
             #selector(handleTmuxCyclePaneNext(_:)),
             #selector(handleTmuxCyclePanePrev(_:)),
             #selector(handleTmuxCopyMode(_:)),
             #selector(handleClearScreen(_:)),
             #selector(handlePaste(_:)),
             #selector(handlePasteCommand(_:)),
             #selector(handleOpenSettingsShortcut(_:)),
             #selector(handleNewWindowShortcut(_:)),
             #selector(handleCloseWindowShortcut(_:)),
             #selector(handleZoomInCommand(_:)),
             #selector(handleZoomOutCommand(_:)),
             #selector(handleZoomResetCommand(_:)),
             #selector(handleArrowKeyCommand(_:)),
             #selector(handleNavigationKeyCommand(_:)):
            return self
        default:
            return super.target(forAction: action, withSender: sender)
        }
    }

    open override func paste(_ sender: Any?) {
        _ = triggerPaste()
    }

    // MARK: - Hardware Keystroke Interception (pressesBegan & swizzled pressesEnded)
    // Direct interception in pressesBegan ensures hardware Cmd/Option shortcuts reliably fire on iPadOS,
    // bypassing any UIHostingController or SwiftUI responder-chain swallowing.
    // Unmodified navigation and terminal keys flow to SwiftTerm's super.pressesBegan for native terminal dispatch.
    internal private(set) var modifierKeyRepeatTimer: Timer?
    internal var modifierKeyRepeatInitialDelay: TimeInterval = 0.4
    internal var modifierKeyRepeatInterval: TimeInterval = 0.1
    internal private(set) var activeRepeatKeyCode: UIKeyboardHIDUsage?

    internal func stopModifierKeyRepeat() {
        modifierKeyRepeatTimer?.invalidate()
        modifierKeyRepeatTimer = nil
        activeRepeatKeyCode = nil
    }

    internal func startModifierKeyRepeat(data: [UInt8], keyCode: UIKeyboardHIDUsage) {
        stopModifierKeyRepeat()
        activeRepeatKeyCode = keyCode
        let timer = Timer(
            fire: Date().addingTimeInterval(modifierKeyRepeatInitialDelay),
            interval: modifierKeyRepeatInterval,
            repeats: true
        ) { [weak self] _ in
            self?.send(data)
        }
        modifierKeyRepeatTimer = timer
        RunLoop.current.add(timer, forMode: .common)
    }

    open override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // Stop repeat if a *different* key is pressed (not the currently repeating key or Option modifier)
        if let activeCode = activeRepeatKeyCode {
            for press in presses {
                if let key = press.key, key.keyCode != activeCode,
                   key.keyCode != .keyboardLeftAlt, key.keyCode != .keyboardRightAlt {
                    stopModifierKeyRepeat()
                    break
                }
            }
        }
        ensureCursorActive()
        for press in presses {
            if let key = press.key, handleHardwareKeyPress(key) {
                return
            }
        }
        super.pressesBegan(presses, with: event)
    }

    internal func handleTerminalPressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard activeRepeatKeyCode != nil else { return }
        var releasedCodes = Set<UIKeyboardHIDUsage>()
        for press in presses {
            if let key = press.key {
                if key.keyCode != .keyboardErrorUndefined {
                    releasedCodes.insert(key.keyCode)
                }
                if key.charactersIgnoringModifiers == UIKeyCommand.inputLeftArrow {
                    releasedCodes.insert(.keyboardLeftArrow)
                } else if key.charactersIgnoringModifiers == UIKeyCommand.inputRightArrow {
                    releasedCodes.insert(.keyboardRightArrow)
                } else if key.charactersIgnoringModifiers == "\u{7f}" || key.charactersIgnoringModifiers == "\u{8}" {
                    releasedCodes.insert(.keyboardDeleteOrBackspace)
                }
                if !key.modifierFlags.contains(.alternate) {
                    releasedCodes.insert(.keyboardLeftAlt)
                }
            }
        }
        if let eventFlags = event?.modifierFlags, !eventFlags.contains(.alternate) {
            releasedCodes.insert(.keyboardLeftAlt)
        }
        handleHardwarePressesEnded(releasedCodes: releasedCodes)
    }

    internal func handleTerminalPressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        stopModifierKeyRepeat()
    }

    internal func handleHardwarePressesEnded(releasedCodes: Set<UIKeyboardHIDUsage>) {
        guard let activeCode = activeRepeatKeyCode else { return }
        // Releasing ANY single key involved in the repeated set stops repetition immediately:
        // 1. The repeating key itself
        if releasedCodes.contains(activeCode) {
            stopModifierKeyRepeat()
            return
        }
        // 2. Either Option/Alt modifier
        if releasedCodes.contains(.keyboardLeftAlt) || releasedCodes.contains(.keyboardRightAlt) {
            stopModifierKeyRepeat()
            return
        }
    }

    open override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let firstTouch = touches.first {
            currentTouchType = firstTouch.type
        }
        self.focusIntent = .terminal
        onInteraction?()
        focusGate?.terminalDidReceiveUserInput()
        if !isFirstResponder && canBecomeFirstResponder {
            _ = becomeFirstResponder()
        }
        ensureCursorActive()
        super.touchesBegan(touches, with: event)
    }

    public func handleHardwareKeyPress(_ key: UIKey) -> Bool {
        return handleKeyShortcut(
            characters: key.characters,
            charactersIgnoringModifiers: key.charactersIgnoringModifiers,
            modifierFlags: key.modifierFlags,
            keyCode: key.keyCode
        )
    }

    public func handleKeyShortcut(
        characters: String,
        charactersIgnoringModifiers: String,
        modifierFlags: UIKeyModifierFlags,
        keyCode: UIKeyboardHIDUsage = .keyboardErrorUndefined
    ) -> Bool {
        let hasShift = modifierFlags.contains(.shift)
        let hasOpt = modifierFlags.contains(.alternate)
        let hasCmd = modifierFlags.contains(.command)
        let hasCtrl = modifierFlags.contains(.control)

        // None of our Cmd or Option shortcuts use Control
        guard !hasCtrl else {
            return false
        }

        // Option (Alternate) without Command or Shift: Word jumping & editing
        if hasOpt && !hasCmd && !hasShift {
            if keyCode == .keyboardLeftArrow || charactersIgnoringModifiers == UIKeyCommand.inputLeftArrow {
                let data: [UInt8] = [0x1b, 0x62] // Esc-b (backward-word)
                send(data)
                let effectiveCode = keyCode != .keyboardErrorUndefined ? keyCode : .keyboardLeftArrow
                startModifierKeyRepeat(data: data, keyCode: effectiveCode)
                return true
            }
            if keyCode == .keyboardRightArrow || charactersIgnoringModifiers == UIKeyCommand.inputRightArrow {
                let data: [UInt8] = [0x1b, 0x66] // Esc-f (forward-word)
                send(data)
                let effectiveCode = keyCode != .keyboardErrorUndefined ? keyCode : .keyboardRightArrow
                startModifierKeyRepeat(data: data, keyCode: effectiveCode)
                return true
            }
            if keyCode == .keyboardDeleteOrBackspace || charactersIgnoringModifiers == "\u{7f}" || charactersIgnoringModifiers == "\u{8}" {
                let data: [UInt8] = [0x1b, 0x7f] // Alt-Backspace (word delete backward)
                send(data)
                let effectiveCode = keyCode != .keyboardErrorUndefined ? keyCode : .keyboardDeleteOrBackspace
                startModifierKeyRepeat(data: data, keyCode: effectiveCode)
                return true
            }
            if keyCode == .keyboardDeleteForward {
                let data: [UInt8] = [0x1b, 0x64] // Alt-DeleteForward (word delete forward)
                send(data)
                startModifierKeyRepeat(data: data, keyCode: .keyboardDeleteForward)
                return true
            }
        }

        guard hasCmd else {
            return false
        }

        let lowercasedIgnoring = charactersIgnoringModifiers.lowercased()

        // 1. Plain Cmd (no Shift, no Option)
        if !hasShift && !hasOpt {
            // Line navigation & deletion
            if keyCode == .keyboardLeftArrow || charactersIgnoringModifiers == UIKeyCommand.inputLeftArrow {
                send([0x01]) // Ctrl-A (beginning of line)
                return true
            }
            if keyCode == .keyboardRightArrow || charactersIgnoringModifiers == UIKeyCommand.inputRightArrow {
                send([0x05]) // Ctrl-E (end of line)
                return true
            }
            if keyCode == .keyboardDeleteOrBackspace || charactersIgnoringModifiers == "\u{7f}" || charactersIgnoringModifiers == "\u{8}" {
                send([0x15]) // Ctrl-U (delete to start of line)
                return true
            }
            if keyCode == .keyboardDeleteForward {
                send([0x0b]) // Ctrl-K (delete to end of line)
                return true
            }
            // Numbers 1...9 -> Switch to tmux window 1..9
            if let num = Int(charactersIgnoringModifiers), (1...9).contains(num) {
                return triggerTmuxWindowNumber(num)
            }
            if keyCode.rawValue >= UIKeyboardHIDUsage.keyboard1.rawValue && keyCode.rawValue <= UIKeyboardHIDUsage.keyboard9.rawValue {
                let num = Int(keyCode.rawValue - UIKeyboardHIDUsage.keyboard1.rawValue + 1)
                return triggerTmuxWindowNumber(num)
            }
            if keyCode.rawValue >= UIKeyboardHIDUsage.keypad1.rawValue && keyCode.rawValue <= UIKeyboardHIDUsage.keypad9.rawValue {
                let num = Int(keyCode.rawValue - UIKeyboardHIDUsage.keypad1.rawValue + 1)
                return triggerTmuxWindowNumber(num)
            }

            // Cmd+T: New tmux window
            if lowercasedIgnoring == "t" || keyCode == .keyboardT {
                return triggerTmuxNewWindow()
            }

            // Cmd+W: Close tmux pane
            if lowercasedIgnoring == "w" || keyCode == .keyboardW {
                return triggerTmuxClosePane()
            }

            // Cmd+N or Cmd+]: Next tmux window
            if lowercasedIgnoring == "n" || keyCode == .keyboardN ||
               lowercasedIgnoring == "]" || keyCode == .keyboardCloseBracket {
                return triggerTmuxNextWindow()
            }

            // Cmd+P or Cmd+[: Previous tmux window
            if lowercasedIgnoring == "p" || keyCode == .keyboardP ||
               lowercasedIgnoring == "[" || keyCode == .keyboardOpenBracket {
                return triggerTmuxPrevWindow()
            }

            // Cmd+D: Split vertically
            if lowercasedIgnoring == "d" || keyCode == .keyboardD {
                return triggerTmuxSplitVertical()
            }

            // Cmd+K: Clear screen
            if lowercasedIgnoring == "k" || keyCode == .keyboardK {
                return triggerClearScreen()
            }

            // Cmd+,: Open Connection Settings
            if lowercasedIgnoring == "," || keyCode == .keyboardComma {
                return triggerOpenSettings()
            }

            // Cmd+V: Paste
            if lowercasedIgnoring == "v" || keyCode == .keyboardV {
                return triggerPaste()
            }

            // Cmd+= or Cmd++: Zoom In (Font Size Up)
            if charactersIgnoringModifiers == "=" || charactersIgnoringModifiers == "+" || keyCode == .keyboardEqualSign {
                return triggerZoomIn()
            }

            // Cmd+-: Zoom Out (Font Size Down)
            if charactersIgnoringModifiers == "-" || keyCode == .keyboardHyphen {
                return triggerZoomOut()
            }

            // Cmd+0: Reset Zoom (Default Font Size)
            if charactersIgnoringModifiers == "0" || keyCode == .keyboard0 {
                return triggerResetZoom()
            }
        }

        // 2. Cmd + Shift (no Option)
        if hasShift && !hasOpt {
            // Cmd+Shift+= (Cmd++): Zoom In
            if charactersIgnoringModifiers == "=" || charactersIgnoringModifiers == "+" || keyCode == .keyboardEqualSign {
                return triggerZoomIn()
            }

            // Cmd+Shift+D: Split horizontally
            if lowercasedIgnoring == "d" || keyCode == .keyboardD {
                return triggerTmuxSplitHorizontal()
            }

            // Cmd+Shift+N: New Window
            if lowercasedIgnoring == "n" || keyCode == .keyboardN {
                return triggerOpenNewWindow()
            }

            // Cmd+Shift+W: Close Window
            if lowercasedIgnoring == "w" || keyCode == .keyboardW {
                return triggerCloseCurrentWindow()
            }

            // Cmd+Shift+R: Rename tmux window
            if (lowercasedIgnoring == "r" || keyCode == .keyboardR) && autoConnectTmux {
                return triggerTmuxRenameWindow()
            }
        }

        // 3. Cmd + Option (no Shift)
        if hasOpt && !hasShift {
            // Cmd+Opt+Up: Pane above
            if keyCode == .keyboardUpArrow || charactersIgnoringModifiers == UIKeyCommand.inputUpArrow {
                return triggerTmuxSelectPaneUp()
            }

            // Cmd+Opt+Down: Pane below
            if keyCode == .keyboardDownArrow || charactersIgnoringModifiers == UIKeyCommand.inputDownArrow {
                return triggerTmuxSelectPaneDown()
            }

            // Cmd+Opt+Left: Pane left
            if keyCode == .keyboardLeftArrow || charactersIgnoringModifiers == UIKeyCommand.inputLeftArrow {
                return triggerTmuxSelectPaneLeft()
            }

            // Cmd+Opt+Right: Pane right
            if keyCode == .keyboardRightArrow || charactersIgnoringModifiers == UIKeyCommand.inputRightArrow {
                return triggerTmuxSelectPaneRight()
            }

            // Cmd+Opt+]: Cycle next pane
            if lowercasedIgnoring == "]" || keyCode == .keyboardCloseBracket {
                return triggerTmuxCyclePaneNext()
            }

            // Cmd+Opt+[: Cycle previous pane
            if lowercasedIgnoring == "[" || keyCode == .keyboardOpenBracket {
                return triggerTmuxCyclePanePrev()
            }

            // Cmd+Opt+0: Switch to Window 0
            if (lowercasedIgnoring == "0" || keyCode == .keyboard0) && autoConnectTmux {
                return triggerTmuxWindowNumber(0)
            }

            // Cmd+Opt+C: Enter tmux copy mode
            if lowercasedIgnoring == "c" || keyCode == .keyboardC {
                return triggerTmuxCopyMode()
            }
        }

        return false
    }

    open override var keyCommands: [UIKeyCommand]? {
        var commands: [UIKeyCommand] = []

        // 1. Register all Ctrl + [a-z] combinations with wantsPriorityOverSystemBehavior
        // so iPadOS hardware keyboards don't swallow or misroute control keystrokes
        let letters = "abcdefghijklmnopqrstuvwxyz"
        for char in letters {
            let cmd = UIKeyCommand(
                input: String(char),
                modifierFlags: .control,
                action: #selector(handleControlKeyCommand(_:))
            )
            cmd.wantsPriorityOverSystemBehavior = true
            commands.append(cmd)
        }

        // Special control keys
        let specialKeys = [
            "[": UInt8(0x1b), // Ctrl-[ -> Escape
            "\\": UInt8(0x1c), // Ctrl-\ -> SIGQUIT
            "]": UInt8(0x1d), // Ctrl-]
            "^": UInt8(0x1e), // Ctrl-^
            "_": UInt8(0x1f), // Ctrl-_
            " ": UInt8(0x00)  // Ctrl-Space -> NUL
        ]

        for (input, _) in specialKeys {
            let cmd = UIKeyCommand(
                input: input,
                modifierFlags: .control,
                action: #selector(handleControlKeyCommand(_:))
            )
            cmd.wantsPriorityOverSystemBehavior = true
            commands.append(cmd)
        }

        // 2. Hardware Cmd Shortcuts for Tmux Navigation (when tmux auto-connect is active)
        if autoConnectTmux {
            for num in 1...9 {
                let cmd = UIKeyCommand(
                    input: "\(num)",
                    modifierFlags: .command,
                    action: #selector(handleTmuxNumberShortcut(_:))
                )
                cmd.title = "Switch to Window \(num)"
                cmd.discoverabilityTitle = "Switch to Window \(num)"
                cmd.wantsPriorityOverSystemBehavior = true
                commands.append(cmd)
            }

            let cmdOpt0 = UIKeyCommand(
                input: "0",
                modifierFlags: [.command, .alternate],
                action: #selector(handleTmuxNumberShortcut(_:))
            )
            cmdOpt0.title = "Switch to Window 0"
            cmdOpt0.discoverabilityTitle = "Switch to Window 0"
            cmdOpt0.wantsPriorityOverSystemBehavior = true
            commands.append(cmdOpt0)

            let cmdT = UIKeyCommand(input: "t", modifierFlags: .command, action: #selector(handleTmuxNewWindow(_:)))
            cmdT.title = "New Tmux Window"
            cmdT.discoverabilityTitle = "New Tmux Window"
            cmdT.wantsPriorityOverSystemBehavior = true
            commands.append(cmdT)

            let cmdW = UIKeyCommand(input: "w", modifierFlags: .command, action: #selector(handleTmuxClosePane(_:)))
            cmdW.title = "Close Tmux Pane"
            cmdW.discoverabilityTitle = "Close Tmux Pane"
            cmdW.wantsPriorityOverSystemBehavior = true
            commands.append(cmdW)

            let cmdN = UIKeyCommand(input: "n", modifierFlags: .command, action: #selector(handleTmuxNextWindow(_:)))
            cmdN.title = "Next Tmux Window"
            cmdN.discoverabilityTitle = "Next Tmux Window"
            cmdN.wantsPriorityOverSystemBehavior = true
            commands.append(cmdN)

            let cmdBracketRight = UIKeyCommand(input: "]", modifierFlags: .command, action: #selector(handleTmuxNextWindow(_:)))
            cmdBracketRight.title = "Next Tmux Window"
            cmdBracketRight.discoverabilityTitle = "Next Tmux Window"
            cmdBracketRight.wantsPriorityOverSystemBehavior = true
            commands.append(cmdBracketRight)

            let cmdP = UIKeyCommand(input: "p", modifierFlags: .command, action: #selector(handleTmuxPrevWindow(_:)))
            cmdP.title = "Previous Tmux Window"
            cmdP.discoverabilityTitle = "Previous Tmux Window"
            cmdP.wantsPriorityOverSystemBehavior = true
            commands.append(cmdP)

            let cmdBracketLeft = UIKeyCommand(input: "[", modifierFlags: .command, action: #selector(handleTmuxPrevWindow(_:)))
            cmdBracketLeft.title = "Previous Tmux Window"
            cmdBracketLeft.discoverabilityTitle = "Previous Tmux Window"
            cmdBracketLeft.wantsPriorityOverSystemBehavior = true
            commands.append(cmdBracketLeft)

            let cmdD = UIKeyCommand(input: "d", modifierFlags: .command, action: #selector(handleTmuxSplitVertical(_:)))
            cmdD.title = "Split Pane Vertically"
            cmdD.discoverabilityTitle = "Split Pane Vertically"
            cmdD.wantsPriorityOverSystemBehavior = true
            commands.append(cmdD)

            // Split Horizontally: register uppercase "D" and lowercase "d" with Shift
            let cmdShiftD = UIKeyCommand(input: "D", modifierFlags: [.command, .shift], action: #selector(handleTmuxSplitHorizontal(_:)))
            cmdShiftD.title = "Split Pane Horizontally"
            cmdShiftD.discoverabilityTitle = "Split Pane Horizontally"
            cmdShiftD.wantsPriorityOverSystemBehavior = true
            commands.append(cmdShiftD)

            let cmdShiftDLower = UIKeyCommand(input: "d", modifierFlags: [.command, .shift], action: #selector(handleTmuxSplitHorizontal(_:)))
            cmdShiftDLower.wantsPriorityOverSystemBehavior = true
            commands.append(cmdShiftDLower)

            let cmdShiftR = UIKeyCommand(input: "R", modifierFlags: [.command, .shift], action: #selector(handleTmuxRenameWindow(_:)))
            cmdShiftR.title = "Rename Tmux Window"
            cmdShiftR.discoverabilityTitle = "Rename Tmux Window"
            cmdShiftR.wantsPriorityOverSystemBehavior = true
            commands.append(cmdShiftR)

            let cmdShiftRLower = UIKeyCommand(input: "r", modifierFlags: [.command, .shift], action: #selector(handleTmuxRenameWindow(_:)))
            cmdShiftRLower.wantsPriorityOverSystemBehavior = true
            commands.append(cmdShiftRLower)

            // Tmux Pane Navigation Shortcuts:
            let cmdOptUp = UIKeyCommand(
                input: UIKeyCommand.inputUpArrow,
                modifierFlags: [.command, .alternate],
                action: #selector(handleTmuxSelectPaneUp(_:))
            )
            cmdOptUp.title = "Select Pane Above"
            cmdOptUp.discoverabilityTitle = "Select Pane Above"
            cmdOptUp.wantsPriorityOverSystemBehavior = true
            commands.append(cmdOptUp)

            let cmdOptDown = UIKeyCommand(
                input: UIKeyCommand.inputDownArrow,
                modifierFlags: [.command, .alternate],
                action: #selector(handleTmuxSelectPaneDown(_:))
            )
            cmdOptDown.title = "Select Pane Below"
            cmdOptDown.discoverabilityTitle = "Select Pane Below"
            cmdOptDown.wantsPriorityOverSystemBehavior = true
            commands.append(cmdOptDown)

            let cmdOptLeft = UIKeyCommand(
                input: UIKeyCommand.inputLeftArrow,
                modifierFlags: [.command, .alternate],
                action: #selector(handleTmuxSelectPaneLeft(_:))
            )
            cmdOptLeft.title = "Select Pane Left"
            cmdOptLeft.discoverabilityTitle = "Select Pane Left"
            cmdOptLeft.wantsPriorityOverSystemBehavior = true
            commands.append(cmdOptLeft)

            let cmdOptRight = UIKeyCommand(
                input: UIKeyCommand.inputRightArrow,
                modifierFlags: [.command, .alternate],
                action: #selector(handleTmuxSelectPaneRight(_:))
            )
            cmdOptRight.title = "Select Pane Right"
            cmdOptRight.discoverabilityTitle = "Select Pane Right"
            cmdOptRight.wantsPriorityOverSystemBehavior = true
            commands.append(cmdOptRight)

            let cmdOptBracketRight = UIKeyCommand(
                input: "]",
                modifierFlags: [.command, .alternate],
                action: #selector(handleTmuxCyclePaneNext(_:))
            )
            cmdOptBracketRight.title = "Cycle Next Pane"
            cmdOptBracketRight.discoverabilityTitle = "Cycle Next Pane"
            cmdOptBracketRight.wantsPriorityOverSystemBehavior = true
            commands.append(cmdOptBracketRight)

            let cmdOptBracketLeft = UIKeyCommand(
                input: "[",
                modifierFlags: [.command, .alternate],
                action: #selector(handleTmuxCyclePanePrev(_:))
            )
            cmdOptBracketLeft.title = "Cycle Previous Pane"
            cmdOptBracketLeft.discoverabilityTitle = "Cycle Previous Pane"
            cmdOptBracketLeft.wantsPriorityOverSystemBehavior = true
            commands.append(cmdOptBracketLeft)

            let cmdOptC = UIKeyCommand(
                input: "c",
                modifierFlags: [.command, .alternate],
                action: #selector(handleTmuxCopyMode(_:))
            )
            cmdOptC.title = "Enter Copy Mode"
            cmdOptC.discoverabilityTitle = "Enter Copy Mode"
            cmdOptC.wantsPriorityOverSystemBehavior = true
            commands.append(cmdOptC)
        }

        // 3. Non-Tmux Command Shortcuts (always registered)
        let cmdK = UIKeyCommand(input: "k", modifierFlags: .command, action: #selector(handleClearScreen(_:)))
        cmdK.title = "Clear Screen"
        cmdK.discoverabilityTitle = "Clear Screen"
        cmdK.wantsPriorityOverSystemBehavior = true
        commands.append(cmdK)

        let cmdV = UIKeyCommand(input: "v", modifierFlags: .command, action: #selector(handlePasteCommand(_:)))
        cmdV.title = "Paste"
        cmdV.discoverabilityTitle = "Paste"
        cmdV.wantsPriorityOverSystemBehavior = true
        commands.append(cmdV)

        let cmdComma = UIKeyCommand(input: ",", modifierFlags: .command, action: #selector(handleOpenSettingsShortcut(_:)))
        cmdComma.title = "Connection Settings"
        cmdComma.discoverabilityTitle = "Connection Settings"
        cmdComma.wantsPriorityOverSystemBehavior = true
        commands.append(cmdComma)

        let cmdShiftN = UIKeyCommand(
            input: "N",
            modifierFlags: [.command, .shift],
            action: #selector(handleNewWindowShortcut(_:))
        )
        cmdShiftN.title = "New Window"
        cmdShiftN.discoverabilityTitle = "New Window"
        cmdShiftN.wantsPriorityOverSystemBehavior = true
        commands.append(cmdShiftN)

        let cmdShiftNLower = UIKeyCommand(
            input: "n",
            modifierFlags: [.command, .shift],
            action: #selector(handleNewWindowShortcut(_:))
        )
        cmdShiftNLower.wantsPriorityOverSystemBehavior = true
        commands.append(cmdShiftNLower)

        let cmdShiftW = UIKeyCommand(
            input: "W",
            modifierFlags: [.command, .shift],
            action: #selector(handleCloseWindowShortcut(_:))
        )
        cmdShiftW.title = "Close Window"
        cmdShiftW.discoverabilityTitle = "Close Window"
        cmdShiftW.wantsPriorityOverSystemBehavior = true
        commands.append(cmdShiftW)

        let cmdShiftWLower = UIKeyCommand(
            input: "w",
            modifierFlags: [.command, .shift],
            action: #selector(handleCloseWindowShortcut(_:))
        )
        cmdShiftWLower.wantsPriorityOverSystemBehavior = true
        commands.append(cmdShiftWLower)

        // 4. Font Zoom Shortcuts (Cmd +, Cmd =, Cmd -, Cmd 0)
        let cmdPlus = UIKeyCommand(input: "+", modifierFlags: .command, action: #selector(handleZoomInCommand(_:)))
        cmdPlus.title = "Zoom In"
        cmdPlus.discoverabilityTitle = "Zoom In"
        cmdPlus.wantsPriorityOverSystemBehavior = true
        commands.append(cmdPlus)

        let cmdEqual = UIKeyCommand(input: "=", modifierFlags: .command, action: #selector(handleZoomInCommand(_:)))
        cmdEqual.wantsPriorityOverSystemBehavior = true
        commands.append(cmdEqual)

        let cmdMinus = UIKeyCommand(input: "-", modifierFlags: .command, action: #selector(handleZoomOutCommand(_:)))
        cmdMinus.title = "Zoom Out"
        cmdMinus.discoverabilityTitle = "Zoom Out"
        cmdMinus.wantsPriorityOverSystemBehavior = true
        commands.append(cmdMinus)

        let cmdZero = UIKeyCommand(input: "0", modifierFlags: .command, action: #selector(handleZoomResetCommand(_:)))
        cmdZero.title = "Reset Zoom"
        cmdZero.discoverabilityTitle = "Reset Zoom"
        cmdZero.wantsPriorityOverSystemBehavior = true
        commands.append(cmdZero)

        // 5. Word & Line Navigation (Option / Cmd + Left/Right)
        let optLeft = UIKeyCommand(
            input: UIKeyCommand.inputLeftArrow,
            modifierFlags: .alternate,
            action: #selector(handleNavigationKeyCommand(_:))
        )
        optLeft.title = "Move Word Left"
        optLeft.discoverabilityTitle = "Move Word Left"
        optLeft.wantsPriorityOverSystemBehavior = true
        commands.append(optLeft)

        let optRight = UIKeyCommand(
            input: UIKeyCommand.inputRightArrow,
            modifierFlags: .alternate,
            action: #selector(handleNavigationKeyCommand(_:))
        )
        optRight.title = "Move Word Right"
        optRight.discoverabilityTitle = "Move Word Right"
        optRight.wantsPriorityOverSystemBehavior = true
        commands.append(optRight)

        let cmdLeft = UIKeyCommand(
            input: UIKeyCommand.inputLeftArrow,
            modifierFlags: .command,
            action: #selector(handleNavigationKeyCommand(_:))
        )
        cmdLeft.title = "Move to Beginning of Line"
        cmdLeft.discoverabilityTitle = "Move to Beginning of Line"
        cmdLeft.wantsPriorityOverSystemBehavior = true
        commands.append(cmdLeft)

        let cmdRight = UIKeyCommand(
            input: UIKeyCommand.inputRightArrow,
            modifierFlags: .command,
            action: #selector(handleNavigationKeyCommand(_:))
        )
        cmdRight.title = "Move to End of Line"
        cmdRight.discoverabilityTitle = "Move to End of Line"
        cmdRight.wantsPriorityOverSystemBehavior = true
        commands.append(cmdRight)

        return commands
    }

    // MARK: - Shortcut Trigger Actions

    @discardableResult
    public func triggerTmuxNewWindow() -> Bool {
        guard autoConnectTmux else { return false }
        guard shouldExecuteShortcut(id: "newWindow") else { return true }
        send([tmuxPrefixByte, UInt8(ascii: "c")])
        return true
    }

    @discardableResult
    public func triggerTmuxClosePane() -> Bool {
        guard autoConnectTmux else { return false }
        guard shouldExecuteShortcut(id: "closePane") else { return true }
        send([tmuxPrefixByte, UInt8(ascii: "x")])
        return true
    }

    @discardableResult
    public func triggerTmuxRenameWindow() -> Bool {
        guard autoConnectTmux else { return false }
        guard shouldExecuteShortcut(id: "renameWindow") else { return true }
        send([tmuxPrefixByte, UInt8(ascii: ",")])
        return true
    }

    @discardableResult
    public func triggerTmuxNextWindow() -> Bool {
        guard autoConnectTmux else { return false }
        guard shouldExecuteShortcut(id: "nextWindow") else { return true }
        send([tmuxPrefixByte, UInt8(ascii: "n")])
        return true
    }

    @discardableResult
    public func triggerTmuxPrevWindow() -> Bool {
        guard autoConnectTmux else { return false }
        guard shouldExecuteShortcut(id: "prevWindow") else { return true }
        send([tmuxPrefixByte, UInt8(ascii: "p")])
        return true
    }

    @discardableResult
    public func triggerTmuxSplitVertical() -> Bool {
        guard autoConnectTmux else { return false }
        guard shouldExecuteShortcut(id: "splitVert") else { return true }
        send([tmuxPrefixByte, UInt8(ascii: "%")])
        return true
    }

    @discardableResult
    public func triggerTmuxSplitHorizontal() -> Bool {
        guard autoConnectTmux else { return false }
        guard shouldExecuteShortcut(id: "splitHoriz") else { return true }
        send([tmuxPrefixByte, UInt8(ascii: "\"")])
        return true
    }

    @discardableResult
    public func triggerTmuxSelectPaneUp() -> Bool {
        guard autoConnectTmux else { return false }
        guard shouldExecuteShortcut(id: "paneUp") else { return true }
        send([tmuxPrefixByte, 0x1b, 0x5b, 0x41])
        return true
    }

    @discardableResult
    public func triggerTmuxSelectPaneDown() -> Bool {
        guard autoConnectTmux else { return false }
        guard shouldExecuteShortcut(id: "paneDown") else { return true }
        send([tmuxPrefixByte, 0x1b, 0x5b, 0x42])
        return true
    }

    @discardableResult
    public func triggerTmuxSelectPaneLeft() -> Bool {
        guard autoConnectTmux else { return false }
        guard shouldExecuteShortcut(id: "paneLeft") else { return true }
        send([tmuxPrefixByte, 0x1b, 0x5b, 0x44])
        return true
    }

    @discardableResult
    public func triggerTmuxSelectPaneRight() -> Bool {
        guard autoConnectTmux else { return false }
        guard shouldExecuteShortcut(id: "paneRight") else { return true }
        send([tmuxPrefixByte, 0x1b, 0x5b, 0x43])
        return true
    }

    @discardableResult
    public func triggerTmuxCyclePaneNext() -> Bool {
        guard autoConnectTmux else { return false }
        guard shouldExecuteShortcut(id: "cycleNext") else { return true }
        send([tmuxPrefixByte, UInt8(ascii: "o")])
        return true
    }

    @discardableResult
    public func triggerTmuxNextPane() -> Bool {
        triggerTmuxCyclePaneNext()
    }

    @discardableResult
    public func triggerTmuxCyclePanePrev() -> Bool {
        guard autoConnectTmux else { return false }
        guard shouldExecuteShortcut(id: "cyclePrev") else { return true }
        send([tmuxPrefixByte, UInt8(ascii: ";")])
        return true
    }

    @discardableResult
    public func triggerTmuxLastPane() -> Bool {
        triggerTmuxCyclePanePrev()
    }

    @discardableResult
    public func triggerTmuxCopyMode() -> Bool {
        guard autoConnectTmux else { return false }
        guard shouldExecuteShortcut(id: "copyMode") else { return true }
        send([tmuxPrefixByte, UInt8(ascii: "[")])
        return true
    }

    @discardableResult
    public func triggerTmuxWindowNumber(_ num: Int) -> Bool {
        guard autoConnectTmux, (0...9).contains(num) else { return false }
        guard shouldExecuteShortcut(id: "winNum_\(num)") else { return true }
        guard let ascii = "\(num)".first?.asciiValue else { return false }
        send([tmuxPrefixByte, ascii])
        return true
    }

    @discardableResult
    public func triggerClearScreen() -> Bool {
        guard shouldExecuteShortcut(id: "clearScreen") else { return true }
        send([0x0c])
        return true
    }

    @discardableResult
    public func triggerPaste() -> Bool {
        guard shouldExecuteShortcut(id: "paste") else { return true }
        if let string = UIPasteboard.general.string {
            send(Self.pastePayload(for: string, bracketedPasteMode: getTerminal().bracketedPasteMode))
        }
        return true
    }

    /// Wraps pasted text in bracketed-paste markers when the remote app requested them, so the shell
    /// treats it as literal text instead of executing embedded newlines. ESC characters are stripped
    /// so pasted content cannot emit its own end marker and break out of the bracket.
    static func pastePayload(for text: String, bracketedPasteMode: Bool) -> [UInt8] {
        guard bracketedPasteMode else { return Array(text.utf8) }
        let sanitized = text.replacingOccurrences(of: "\u{1B}", with: "")
        return EscapeSequences.bracketedPasteStart + Array(sanitized.utf8) + EscapeSequences.bracketedPasteEnd
    }

    @discardableResult
    public func triggerOpenSettings() -> Bool {
        guard shouldExecuteShortcut(id: "openSettings") else { return true }
        NotificationCenter.default.post(name: .openSettingsRequested, object: self.window)
        return true
    }

    @discardableResult
    public func triggerOpenNewWindow() -> Bool {
        NotificationCenter.default.post(name: .openNewWindowRequested, object: self.window)
        return true
    }

    @discardableResult
    public func triggerCloseCurrentWindow() -> Bool {
        NotificationCenter.default.post(name: .closeCurrentWindowRequested, object: self.window)
        return true
    }

    /// Triggers a brief, non-intrusive visual screen flash to signal terminal bell in quiet environments
    public func triggerVisualBell() {
        CATransaction.begin()
        visualBellLayer.removeAllAnimations()
        visualBellLayer.opacity = 0.22
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0.22
        animation.toValue = 0.0
        animation.duration = 0.18
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        visualBellLayer.add(animation, forKey: "visualBellFlash")
        visualBellLayer.opacity = 0.0
        CATransaction.commit()
    }

    // MARK: - UIKeyCommand Handlers

    @objc open func handleControlKeyCommand(_ command: UIKeyCommand) {
        guard let input = command.input?.lowercased().first else { return }

        let byte: UInt8?
        switch input {
        case "a"..."z":
            let asciiA: UInt8 = 97
            byte = (input.asciiValue ?? asciiA) - asciiA + 1
        case "[":
            byte = 0x1b // ESC
        case "\\":
            byte = 0x1c
        case "]":
            byte = 0x1d
        case "^":
            byte = 0x1e
        case "_":
            byte = 0x1f
        case " ":
            byte = 0x00
        default:
            byte = nil
        }

        if let byte = byte {
            send([byte])
        }
    }

    @objc open func handleTmuxNumberShortcut(_ sender: Any?) {
        if let command = sender as? UIKeyCommand,
           let input = command.input?.first,
           let num = Int(String(input)) {
            _ = triggerTmuxWindowNumber(num)
        }
    }

    @objc open func handleTmuxNewWindow(_ sender: Any?) {
        _ = triggerTmuxNewWindow()
    }

    @objc open func handleTmuxClosePane(_ sender: Any?) {
        _ = triggerTmuxClosePane()
    }

    @objc open func handleTmuxRenameWindow(_ sender: Any?) {
        _ = triggerTmuxRenameWindow()
    }

    @objc open func handleTmuxNextWindow(_ sender: Any?) {
        _ = triggerTmuxNextWindow()
    }

    @objc open func handleTmuxPrevWindow(_ sender: Any?) {
        _ = triggerTmuxPrevWindow()
    }

    @objc open func handleTmuxSplitVertical(_ sender: Any?) {
        _ = triggerTmuxSplitVertical()
    }

    @objc open func handleTmuxSplitHorizontal(_ sender: Any?) {
        _ = triggerTmuxSplitHorizontal()
    }

    @objc open func handleTmuxSelectPaneUp(_ sender: Any?) {
        _ = triggerTmuxSelectPaneUp()
    }

    @objc open func handleTmuxSelectPaneDown(_ sender: Any?) {
        _ = triggerTmuxSelectPaneDown()
    }

    @objc open func handleTmuxSelectPaneLeft(_ sender: Any?) {
        _ = triggerTmuxSelectPaneLeft()
    }

    @objc open func handleTmuxSelectPaneRight(_ sender: Any?) {
        _ = triggerTmuxSelectPaneRight()
    }

    @objc open func handleTmuxCyclePaneNext(_ sender: Any?) {
        _ = triggerTmuxCyclePaneNext()
    }

    @objc open func handleTmuxCyclePanePrev(_ sender: Any?) {
        _ = triggerTmuxCyclePanePrev()
    }

    @objc open func handleTmuxCopyMode(_ sender: Any?) {
        _ = triggerTmuxCopyMode()
    }

    @objc open func handleClearScreen(_ sender: Any?) {
        _ = triggerClearScreen()
    }

    @objc open func handlePaste(_ sender: Any?) {
        _ = triggerPaste()
    }

    @objc open func handlePasteCommand(_ sender: Any?) {
        _ = triggerPaste()
    }

    @objc open func handleOpenSettingsShortcut(_ sender: Any?) {
        _ = triggerOpenSettings()
    }

    @objc open func handleNewWindowShortcut(_ sender: Any?) {
        _ = triggerOpenNewWindow()
    }

    @objc open func handleCloseWindowShortcut(_ sender: Any?) {
        _ = triggerCloseCurrentWindow()
    }

    @objc open func handleArrowKeyCommand(_ command: UIKeyCommand) {
        handleNavigationKeyCommand(command)
    }

    @objc open func handleNavigationKeyCommand(_ command: UIKeyCommand) {
        guard let input = command.input else { return }
        let modifiers = command.modifierFlags

        if modifiers.contains(.alternate) {
            switch input {
            case UIKeyCommand.inputLeftArrow:
                send([0x1b, 0x62]) // Esc-b (move word backward)
            case UIKeyCommand.inputRightArrow:
                send([0x1b, 0x66]) // Esc-f (move word forward)
            default:
                break
            }
            return
        }

        if modifiers.contains(.command) {
            switch input {
            case UIKeyCommand.inputLeftArrow:
                send([0x01]) // Ctrl-A (move to start of line)
            case UIKeyCommand.inputRightArrow:
                send([0x05]) // Ctrl-E (move to end of line)
            default:
                break
            }
            return
        }

        switch input {
        case UIKeyCommand.inputUpArrow:
            send([0x1b, 0x5b, 0x41])
        case UIKeyCommand.inputDownArrow:
            send([0x1b, 0x5b, 0x42])
        case UIKeyCommand.inputLeftArrow:
            send([0x1b, 0x5b, 0x44])
        case UIKeyCommand.inputRightArrow:
            send([0x1b, 0x5b, 0x43])
        case UIKeyCommand.inputHome:
            send([0x1b, 0x5b, 0x48]) // ESC [ H
        case UIKeyCommand.inputEnd:
            send([0x1b, 0x5b, 0x46]) // ESC [ F
        case UIKeyCommand.inputPageUp:
            send([0x1b, 0x5b, 0x35, 0x7e]) // ESC [ 5 ~
        case UIKeyCommand.inputPageDown:
            send([0x1b, 0x5b, 0x36, 0x7e]) // ESC [ 6 ~
        default:
            break
        }
    }

    @discardableResult
    public func triggerZoomIn() -> Bool {
        let current = FontManager.shared.fontSize
        let newSize = min(current + 1.0, 32.0)
        guard newSize != current else { return true }
        FontManager.shared.fontSize = newSize
        applyFontSetting()
        return true
    }

    @discardableResult
    public func triggerZoomOut() -> Bool {
        let current = FontManager.shared.fontSize
        let newSize = max(current - 1.0, 9.0)
        guard newSize != current else { return true }
        FontManager.shared.fontSize = newSize
        applyFontSetting()
        return true
    }

    @discardableResult
    public func triggerResetZoom() -> Bool {
        let defaultSize: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 15.0 : 13.0
        guard FontManager.shared.fontSize != defaultSize else { return true }
        FontManager.shared.fontSize = defaultSize
        applyFontSetting()
        return true
    }

    @objc open func handleZoomInCommand(_ command: UIKeyCommand) {
        _ = triggerZoomIn()
    }

    @objc open func handleZoomOutCommand(_ command: UIKeyCommand) {
        _ = triggerZoomOut()
    }

    @objc open func handleZoomResetCommand(_ command: UIKeyCommand) {
        _ = triggerResetZoom()
    }

    // MARK: - Text Input & Sticky Modifiers

    open override func insertText(_ text: String) {
        if let accessory = customAccessoryView, accessory.isControlActive {
            if let first = text.lowercased().first, first >= "a" && first <= "z" {
                let asciiA: UInt8 = 97
                let byte = (first.asciiValue ?? asciiA) - asciiA + 1
                send([byte])
            } else if let first = text.first {
                switch first {
                case "@", " ":
                    send([0x00]) // NUL / Ctrl-@ / Ctrl-Space
                case "[":
                    send([0x1B]) // ESC / Ctrl-[
                case "\\":
                    send([0x1C]) // FS / Ctrl-\
                case "]":
                    send([0x1D]) // GS / Ctrl-]
                case "^":
                    send([0x1E]) // RS / Ctrl-^
                case "_":
                    send([0x1F]) // US / Ctrl-_
                case "?":
                    send([0x7F]) // DEL / Ctrl-?
                default:
                    send(Array(text.utf8))
                }
            } else {
                send(Array(text.utf8))
            }
            accessory.resetStickyModifiers()
            return
        }

        if let accessory = customAccessoryView, accessory.isAltActive {
            send([0x1b])
            send(Array(text.utf8))
            accessory.resetStickyModifiers()
            return
        }

        super.insertText(text)
    }

    open override func deleteBackward() {
        if let accessory = customAccessoryView, accessory.isControlActive {
            accessory.resetStickyModifiers()
            send([0x08]) // Backspace / Ctrl-H
            return
        }
        if let accessory = customAccessoryView, accessory.isAltActive {
            accessory.resetStickyModifiers()
            send([0x1b, 0x7f]) // Alt-Backspace (word delete backward)
            return
        }
        super.deleteBackward()
    }

    // MARK: - Motion Event Throttling & Deduplication

    private var lastSentSgrMotion: [UInt8]?

    func isDuplicateSgrMotion(_ data: ArraySlice<UInt8>) -> Bool {
        // SGR format: ESC [ < flags ; col ; row M
        guard data.count >= 10,
              data.starts(with: [0x1B, 0x5B, 0x3C]), // \e[<
              data.last == 0x4D                      // 'M'
        else {
            return false
        }

        // Parse flags before first ';'
        let slice = data.dropFirst(3) // skip \e[<
        guard let firstSemi = slice.firstIndex(of: 0x3B) else { return false } // ';'
        let flagsSlice = slice[..<firstSemi]
        guard let flagsStr = String(bytes: flagsSlice, encoding: .ascii),
              let flags = Int(flagsStr)
        else {
            return false
        }

        // Motion events have bit 32 set and bit 64 unset (wheel events have bit 64 set)
        guard (flags & 32) != 0 && (flags & 64) == 0 else {
            return false
        }

        return true
    }

    open override func send(source: Terminal, data: ArraySlice<UInt8>) {
        if isDuplicateSgrMotion(data) {
            if let last = lastSentSgrMotion, last.elementsEqual(data) {
                // Drop duplicate motion event within the same terminal cell
                return
            }
            lastSentSgrMotion = Array(data)
        } else {
            lastSentSgrMotion = nil
        }

        super.send(source: source, data: data)
    }

    // MARK: - FilaireAccessoryDelegate

    public func accessoryDidSendBytes(_ bytes: [UInt8]) {
        send(bytes)
    }

    public func accessoryDidInsertText(_ text: String) {
        insertText(text)
    }

    public func accessoryDidToggleControl(isActive: Bool) {}

    public func accessoryDidToggleAlt(isActive: Bool) {}

    public func accessoryDidRequestDismissKeyboard() {
        self.focusIntent = .none
        cancelPendingFocusRequests()
        _ = resignFirstResponder()
    }

    public func accessoryDidRequestPaste() {
        _ = triggerPaste()
    }

    // MARK: - URL Tap & Pane Wrap Expansion

    public func cellDimension() -> CGSize {
        let scale = contentScaleFactor > 0 ? contentScaleFactor : (window?.screen.scale ?? UIScreen.main.scale)
        if let cached = cachedCellDimension, cached.font == font, cached.scale == scale {
            return cached.size
        }
        let font = self.font
        let ctFont = font as CTFont
        let ascent = CTFontGetAscent(ctFont)
        let descent = CTFontGetDescent(ctFont)
        let leading = CTFontGetLeading(ctFont)
        let cellHeight = ceil(ascent + descent + leading)
        let cellWidth = "W".size(withAttributes: [.font: font]).width
        let snappedWidth = max(1, (cellWidth * scale).rounded() / scale)
        let snappedHeight = max(1, ceil(cellHeight * scale) / scale)
        let size = CGSize(width: snappedWidth, height: snappedHeight)
        cachedCellDimension = (font, scale, size)
        return size
    }

    public func gridPosition(for point: CGPoint) -> Position {
        let dim = cellDimension()
        let col = Int(point.x / dim.width)
        let row = Int(point.y / dim.height)
        let terminal = getTerminal()
        let clampedCol = max(0, min(terminal.cols - 1, col))
        let clampedRow = max(0, min(terminal.rows - 1, row))
        return Position(col: clampedCol, row: clampedRow)
    }

    public func expandUrlIfWrapped(link: String) -> String {
        TerminalUrlDetector.expandUrlIfWrapped(link: link, in: getTerminal())
    }

    @objc private func handleUrlTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        clearUrlHighlight()
        if !isFirstResponder {
            _ = becomeFirstResponder()
        }
        let point = gesture.location(in: self)
        let gridPos = gridPosition(for: point)
        if let url = TerminalUrlDetector.detectUrl(at: gridPos.col, row: gridPos.row, in: getTerminal()) {
            terminalDelegate?.requestOpenLink(source: self, link: url, params: [Self.detectedUrlParamKey: "1"])
        }
    }

    // MARK: - Hit Testing for Top Status Overlay

    open override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard self.point(inside: point, with: event) else { return nil }

        // If status menu is expanded, yield hit testing to SwiftUI so menu buttons work
        // and tapping anywhere outside the menu hits the backdrop to dismiss cleanly.
        if isStatusExpanded {
            return nil
        }

        // When minimized, yield hit testing in the top 44pt pull-down area to SwiftUI
        // so the expansion handle receives taps and clicks cleanly.
        if point.y < topOverlayHeight {
            return nil
        }

        return super.hitTest(point, with: event)
    }

    // MARK: - UIGestureRecognizerDelegate

    open override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === threeFingerSwipeLeft || gestureRecognizer === threeFingerSwipeRight {
            return autoConnectTmux
        }
        if gestureRecognizer === urlTapGesture {
            let point = gestureRecognizer.location(in: self)
            let gridPos = gridPosition(for: point)
            return TerminalUrlDetector.detectUrl(at: gridPos.col, row: gridPos.row, in: getTerminal()) != nil
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    @objc private func handleThreeFingerSwipeLeft(_ gesture: UISwipeGestureRecognizer) {
        guard gesture.state == .ended, autoConnectTmux else { return }
        if triggerTmuxNextWindow() {
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.prepare()
            generator.impactOccurred()
        }
    }

    @objc private func handleThreeFingerSwipeRight(_ gesture: UISwipeGestureRecognizer) {
        guard gesture.state == .ended, autoConnectTmux else { return }
        if triggerTmuxPrevWindow() {
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.prepare()
            generator.impactOccurred()
        }
    }

    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        return false
    }

    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        currentTouchType = touch.type
        if gestureRecognizer === twoFingerScrollGesture {
            return touch.type == .direct
        }
        return true
    }

    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        if gestureRecognizer === twoFingerScrollGesture {
            if currentTouchType != .direct {
                return false
            }
            if otherGestureRecognizer is UIPinchGestureRecognizer ||
               otherGestureRecognizer is UISwipeGestureRecognizer ||
               otherGestureRecognizer === trackpadScrollGesture {
                return false
            }
            return true
        }
        return false
    }

    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        if otherGestureRecognizer === twoFingerScrollGesture {
            if currentTouchType != .direct {
                return false
            }
            if gestureRecognizer is UIPinchGestureRecognizer ||
               gestureRecognizer is UISwipeGestureRecognizer ||
               gestureRecognizer === trackpadScrollGesture {
                return false
            }
            return true
        }
        return false
    }

    // MARK: - Multi-line URL Hover Highlighting

    @objc private func handleFilaireHover(_ gesture: UIHoverGestureRecognizer) {
        switch gesture.state {
        case .began, .changed:
            let point = gesture.location(in: self)
            let gridPos = gridPosition(for: point)
            guard gridPos != lastHoverGridPosition else { return }
            lastHoverGridPosition = gridPos
            let match = TerminalUrlDetector.detectUrlMatch(at: gridPos.col, row: gridPos.row, in: getTerminal())

            if match != currentHoveredMatch {
                currentHoveredMatch = match
                renderUrlHighlight(match: match)
            }
        case .ended, .cancelled:
            clearUrlHighlight()
        default:
            break
        }
    }

    public func clearUrlHighlight() {
        if currentHoveredMatch != nil || urlHighlightLayer.path != nil {
            currentHoveredMatch = nil
            urlHighlightLayer.path = nil
            urlUnderlineLayer.path = nil
            lastHoverGridPosition = nil
        }
        lastHoverGridPosition = nil
    }

    public func wipeScreen() {
        escapeSequenceFilter.reset()
        feed(byteArray: [0x1B, UInt8(ascii: "c")][...])
        clearUrlHighlight()
    }

    public func resetParserState() {
        escapeSequenceFilter.reset()
    }

    private func renderUrlHighlight(match: DetectedUrlMatch?) {
        guard let match = match, !match.segments.isEmpty else {
            clearUrlHighlight()
            return
        }

        let dim = cellDimension()
        let bgPath = UIBezierPath()
        let underlinePath = UIBezierPath()

        for segment in match.segments {
            let x = CGFloat(segment.colRange.lowerBound) * dim.width
            let width = CGFloat(segment.colRange.count) * dim.width
            let y = CGFloat(segment.row) * dim.height
            let height = dim.height

            // 1. Subtle rounded background highlight for all lines of the URL
            let rect = CGRect(x: x, y: y, width: width, height: height)
            bgPath.append(UIBezierPath(roundedRect: rect, cornerRadius: 2))

            // 2. Underline spanning the full width of every line segment
            let underlineY = y + height - 1.0
            underlinePath.move(to: CGPoint(x: x, y: underlineY))
            underlinePath.addLine(to: CGPoint(x: x + width, y: underlineY))
        }

        urlHighlightLayer.path = bgPath.cgPath
        urlUnderlineLayer.path = underlinePath.cgPath
    }

    // MARK: - Pointer Interaction (I-Beam Cursor & URL Pointer)

    private var filairePointerDelegate: Any?
    private var filairePointerInteraction: Any?

    private func setupCustomPointerInteraction() {
        let delegate = FilairePointerDelegate(terminalView: self)
        self.filairePointerDelegate = delegate
        let interaction = UIPointerInteraction(delegate: delegate)
        addInteraction(interaction)
        self.filairePointerInteraction = interaction
    }

    public func pointerStyle(for region: UIPointerRegion) -> UIPointerStyle? {
        if let id = region.identifier as? String, id == "url" {
            // Over links, yield to standard pointer to signal clickability
            return nil
        }
        let dim = cellDimension()
        let beamHeight = max(12.0, min(dim.height, 36.0))
        return UIPointerStyle(shape: .verticalBeam(length: beamHeight))
    }

    // MARK: - Cursor Animation Resilience & Multi-Window Focus Management

    public func refreshCursorAnimation() {
        guard let caret = caretSubView, caret.superview === self else { return }

        // Always reset model layer opacity to 1.0 so that whenever UIKit cancels in-flight
        // animations during window/scene switches, the cursor remains 100% visible instead of 0.0.
        caret.layer.opacity = 1.0
        caret.isHidden = false

        let isWindowActive: Bool = {
            guard let win = self.window else {
                #if DEBUG
                if NSClassFromString("XCTestCase") != nil { return isFirstResponder }
                #endif
                return false
            }
            if let scene = win.windowScene {
                return scene.activationState == .foregroundActive
            }
            return true
        }()

        let isFocused = isWindowActive && (isFirstResponder || (window?.isKeyWindow ?? false))

        let shouldBlink: Bool = {
            guard isFocused else { return false }
            switch getTerminal().options.cursorStyle {
            case .blinkBlock, .blinkUnderline, .blinkBar:
                return true
            case .steadyBlock, .steadyUnderline, .steadyBar:
                return false
            }
        }()

        if shouldBlink {
            if caret.layer.animation(forKey: Self.cursorBlinkAnimationKey) == nil {
                caret.layer.removeAnimation(forKey: "opacity")
                caret.layer.removeAllAnimations()
                caret.layer.opacity = 1.0

                let blink = CABasicAnimation(keyPath: "opacity")
                blink.fromValue = 1.0
                blink.toValue = 0.0
                blink.duration = 0.7
                blink.autoreverses = true
                blink.repeatCount = .infinity
                blink.timingFunction = CAMediaTimingFunction(name: .easeIn)
                blink.isRemovedOnCompletion = false
                caret.layer.add(blink, forKey: Self.cursorBlinkAnimationKey)
            }
        } else {
            caret.layer.removeAnimation(forKey: Self.cursorBlinkAnimationKey)
            caret.layer.removeAnimation(forKey: "opacity")
            caret.layer.removeAllAnimations()
            caret.layer.opacity = 1.0
        }
        caret.setNeedsDisplay()
    }

    public func ensureCursorActive() {
        guard let caret = caretSubView, caret.superview != nil else { return }
        let shouldBlink: Bool = {
            switch getTerminal().options.cursorStyle {
            case .blinkBlock, .blinkUnderline, .blinkBar:
                return true
            case .steadyBlock, .steadyUnderline, .steadyBar:
                return false
            }
        }()
        if caret.layer.opacity == 0 || (shouldBlink && isFirstResponder && caret.layer.animation(forKey: Self.cursorBlinkAnimationKey) == nil) {
            refreshCursorAnimation()
        }
    }

    @discardableResult
    open override func becomeFirstResponder() -> Bool {
        #if DEBUG
        if CommandLine.arguments.contains("--demo") { return false }
        #endif
        let result = super.becomeFirstResponder()
        if result {
            self.focusIntent = .terminal
            onInteraction?()
            focusGate?.terminalDidReceiveUserInput()
        }
        refreshCursorAnimation()
        return result
    }

    @discardableResult
    open override func resignFirstResponder() -> Bool {
        stopModifierKeyRepeat()
        let result = super.resignFirstResponder()
        refreshCursorAnimation()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let win = self.window {
                let active = win.findFirstResponder()
                if active != nil && active !== self {
                    self.focusIntent = .hostEditorOrSearch
                    self.cancelPendingFocusRequests()
                }
            }
        }
        return result
    }

    open override func cursorStyleChanged(source: Terminal, newStyle: CursorStyle) {
        super.cursorStyleChanged(source: source, newStyle: newStyle)
        refreshCursorAnimation()
    }

    open override func showCursor(source: Terminal) {
        super.showCursor(source: source)
        refreshCursorAnimation()
    }

    open override func hideCursor(source: Terminal) {
        super.hideCursor(source: source)
        caretSubView?.layer.removeAnimation(forKey: Self.cursorBlinkAnimationKey)
        caretSubView?.layer.removeAnimation(forKey: "opacity")
    }

    private func removeWindowObservers() {
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        windowObservers.removeAll()
    }

    private func setupWindowObservers(for window: UIWindow) {
        removeWindowObservers()

        // 1. UIWindow became key: refresh cursor animation, and schedule promotion only if terminal is intended responder
        let becomeKeyObserver = NotificationCenter.default.addObserver(
            forName: UIWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            guard let self = self, let win = window, self.window === win else { return }
            self.refreshCursorAnimation()
            if self.focusIntent == .terminal {
                self.scheduleFocusPromotion(delay: 0.25, reason: "window became key")
            }
        }
        windowObservers.append(becomeKeyObserver)

        // 2. UIWindow resigned key: stop blinking, display steady unfocused cursor, cancel pending promotions
        let resignKeyObserver = NotificationCenter.default.addObserver(
            forName: UIWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            guard let self = self, self.window === window else { return }
            self.cancelPendingFocusRequests()
            self.refreshCursorAnimation()
        }
        windowObservers.append(resignKeyObserver)

        // 3. UIScene became active: refresh cursor animation, and schedule promotion only if terminal is intended responder
        let sceneActivateObserver = NotificationCenter.default.addObserver(
            forName: UIScene.didActivateNotification,
            object: nil,
            queue: .main
        ) { [weak self, weak window] notification in
            guard let self = self,
                  let win = window,
                  self.window === win,
                  let scene = win.windowScene,
                  notification.object as? UIWindowScene === scene else { return }
            self.refreshCursorAnimation()
            if self.focusIntent == .terminal {
                self.scheduleFocusPromotion(delay: 0.25, reason: "scene did activate")
            }
        }
        windowObservers.append(sceneActivateObserver)

        // 4. UIScene will deactivate: cancel pending promotions and update cursor
        let sceneDeactivateObserver = NotificationCenter.default.addObserver(
            forName: UIScene.willDeactivateNotification,
            object: nil,
            queue: .main
        ) { [weak self, weak window] notification in
            guard let self = self,
                  let win = window,
                  self.window === win,
                  let scene = win.windowScene,
                  notification.object as? UIWindowScene === scene else { return }
            self.cancelPendingFocusRequests()
            self.refreshCursorAnimation()
        }
        windowObservers.append(sceneDeactivateObserver)

        // 5. UIApplication did become active: ensure cursor blinks
        let appActiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.refreshCursorAnimation()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.refreshCursorAnimation()
            }
        }
        windowObservers.append(appActiveObserver)
    }
}

extension UIView {
    public func findFirstResponder() -> UIResponder? {
        if isFirstResponder { return self }
        for subview in subviews {
            if let responder = subview.findFirstResponder() {
                return responder
            }
        }
        return nil
    }
}

private final class FilairePointerDelegate: NSObject, UIPointerInteractionDelegate {
    private weak var terminalView: FilaireTerminalView?
    private var lastRegionKey: (col: Int, row: Int, bounds: CGRect)?
    private var lastRegion: UIPointerRegion?

    init(terminalView: FilaireTerminalView) {
        self.terminalView = terminalView
        super.init()
    }

    func pointerInteraction(
        _ interaction: UIPointerInteraction,
        regionFor request: UIPointerRegionRequest,
        defaultRegion: UIPointerRegion
    ) -> UIPointerRegion? {
        guard let view = terminalView, view.bounds.contains(request.location) else { return nil }

        let gridPos = view.gridPosition(for: request.location)
        if let key = lastRegionKey, key.col == gridPos.col, key.row == gridPos.row, key.bounds == view.bounds,
           let region = lastRegion {
            return region
        }

        let region: UIPointerRegion
        if TerminalUrlDetector.detectUrl(at: gridPos.col, row: gridPos.row, in: view.getTerminal()) != nil {
            let dim = view.cellDimension()
            let rect = CGRect(
                x: CGFloat(gridPos.col) * dim.width,
                y: CGFloat(gridPos.row) * dim.height,
                width: dim.width,
                height: dim.height
            )
            region = UIPointerRegion(rect: rect, identifier: "url")
        } else {
            region = UIPointerRegion(rect: view.bounds, identifier: "terminal")
        }

        lastRegionKey = (gridPos.col, gridPos.row, view.bounds)
        lastRegion = region
        return region
    }

    func pointerInteraction(
        _ interaction: UIPointerInteraction,
        styleFor region: UIPointerRegion
    ) -> UIPointerStyle? {
        return terminalView?.pointerStyle(for: region)
    }
}

// MARK: - TerminalView Presses Swizzling
// SwiftTerm declares pressesEnded as public override (non-open), which prevents external subclasses
// from overriding it in Swift. We use Objective-C runtime method swizzling so FilaireTerminalView
// receives pressesEnded and pressesCancelled callbacks when keys are released on hardware keyboards.
extension TerminalView {
    private static var filaireSwizzlePressesOnce: Void = {
        let originalEnded = #selector(UIResponder.pressesEnded(_:with:))
        let swizzledEnded = #selector(TerminalView.filaire_pressesEnded(_:with:))
        filaire_swizzle(original: originalEnded, swizzled: swizzledEnded)

        let originalCancelled = #selector(UIResponder.pressesCancelled(_:with:))
        let swizzledCancelled = #selector(TerminalView.filaire_pressesCancelled(_:with:))
        filaire_swizzle(original: originalCancelled, swizzled: swizzledCancelled)
    }()

    static func filaire_ensurePressesSwizzled() {
        _ = filaireSwizzlePressesOnce
    }

    private static func filaire_swizzle(original: Selector, swizzled: Selector) {
        guard let originalMethod = class_getInstanceMethod(TerminalView.self, original),
              let swizzledMethod = class_getInstanceMethod(TerminalView.self, swizzled) else { return }
        if class_addMethod(TerminalView.self, original, method_getImplementation(swizzledMethod), method_getTypeEncoding(swizzledMethod)) {
            class_replaceMethod(TerminalView.self, swizzled, method_getImplementation(originalMethod), method_getTypeEncoding(originalMethod))
        } else {
            method_exchangeImplementations(originalMethod, swizzledMethod)
        }
    }

    @objc func filaire_pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        filaire_pressesEnded(presses, with: event)
        if let filaire = self as? FilaireTerminalView {
            filaire.handleTerminalPressesEnded(presses, with: event)
        }
    }

    @objc func filaire_pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        filaire_pressesCancelled(presses, with: event)
        if let filaire = self as? FilaireTerminalView {
            filaire.handleTerminalPressesCancelled(presses, with: event)
        }
    }
}
