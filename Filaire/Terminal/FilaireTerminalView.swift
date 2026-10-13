import UIKit
import SwiftTerm
import GameController

public enum SceneFocusIntent: Equatable, Sendable {
    case terminal
    case hostEditorOrSearch
    case securityPrompt
    case preview
    case modalPresentation
    /// A local editor in this scene (command composer or snippets) owns the keyboard; the terminal must not
    /// take first responder back while it is up.
    case localEditor
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
    /// Set by the owning terminal context, so a composer request reaches that context's scene only.
    public var onComposerRequested: (() -> Void)?
    /// Same routing for the snippet library: one scene's shortcut opens only that scene's library.
    public var onSnippetsRequested: (() -> Void)?

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

    internal var pinchBaseFontSize: CGFloat = 13.0
    internal var accumulatedScrollDeltaY: CGFloat = 0
    internal var twoFingerScrollGesture: UIPanGestureRecognizer?
    public var currentTouchType: UITouch.TouchType = .direct
    internal var pinchGesture: UIPinchGestureRecognizer?
    internal var trackpadScrollGesture: UIPanGestureRecognizer?
    internal var urlTapGesture: UITapGestureRecognizer?
    internal var customHoverGesture: UIHoverGestureRecognizer?
    internal var threeFingerSwipeLeft: UISwipeGestureRecognizer?
    internal var threeFingerSwipeRight: UISwipeGestureRecognizer?
    internal var currentHoveredMatch: DetectedUrlMatch?
    internal var lastHoverGridPosition: Position?
    internal var cachedCellDimension: (font: UIFont, scale: CGFloat, size: CGSize)?
    internal let urlHighlightLayer = CAShapeLayer()
    internal let urlUnderlineLayer = CAShapeLayer()
    internal let visualBellLayer = CALayer()
    internal var lastHandledShortcutTime: TimeInterval = 0
    internal var lastHandledShortcutId: String = ""
    internal var modifierKeyRepeatTimer: Timer?
    internal var modifierKeyRepeatInitialDelay: TimeInterval = 0.4
    internal var modifierKeyRepeatInterval: TimeInterval = 0.1
    internal var activeRepeatKeyCode: UIKeyboardHIDUsage?
    internal var filairePointerDelegate: Any?
    internal var filairePointerInteraction: Any?

    internal var accumulatedTwoFingerDeltaY: CGFloat = 0
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
    internal weak var cachedCaretView: UIView?
    internal var windowObservers: [any NSObjectProtocol] = []
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
        removeKeyboardAccessoryObservers()
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
        let highlightColor = theme.accent
        urlHighlightLayer.fillColor = highlightColor.withAlphaComponent(0.12).cgColor
        urlUnderlineLayer.strokeColor = highlightColor.withAlphaComponent(0.85).cgColor

        let isLight = theme.isLight
        visualBellLayer.backgroundColor = (isLight ? UIColor.black : UIColor.white).cgColor

        customAccessoryView?.applyTheme(theme)
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
        let highlightColor = ThemeManager.shared.currentTheme.accent
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

        // Setup keyboard accessory observers and configure bar according to settings & hardware state
        setupKeyboardAccessoryObservers()
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

    /// Matches `FilaireAccessoryView.intrinsicContentSize` (44pt).
    private var accessoryBarHeight: CGFloat {
        44
    }

    internal var isHardwareKeyboardConnectedOverride: Bool?
    internal var isOnScreenKeyboardDisplayedOverride: Bool?

    internal var hasReceivedPhysicalKeyPress: Bool = false
    private var isOnScreenKeyboardDisplayed: Bool = false
    private var keyboardAccessoryObservers: [NSObjectProtocol] = []

    public var isHardwareKeyboardConnected: Bool {
        if let override = isHardwareKeyboardConnectedOverride {
            return override
        }
        #if targetEnvironment(macCatalyst)
        return true
        #else
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            return false
        }
        if hasReceivedPhysicalKeyPress {
            return true
        }
        if GCKeyboard.coalesced != nil {
            return true
        }
        if let ctx = UITextInputContext.current(), ctx.isHardwareKeyboardInputExpected {
            return true
        }
        return false
        #endif
    }

    public var isSoftwareKeyboardVisible: Bool {
        if let override = isOnScreenKeyboardDisplayedOverride {
            return override
        }
        return isOnScreenKeyboardDisplayed
    }

    public var shouldShowAccessoryBar: Bool {
        guard TerminalSettings.shared.showKeyboardAccessoryBar else {
            return false
        }
        if UIDevice.current.userInterfaceIdiom == .phone {
            return true
        }
        // On iPad: when a hardware keyboard (e.g. Magic Keyboard) is active,
        // show the toolbar only when the on-screen keyboard is currently displayed.
        if isHardwareKeyboardConnected {
            return isSoftwareKeyboardVisible
        }
        return true
    }

    private func removeKeyboardAccessoryObservers() {
        for observer in keyboardAccessoryObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        keyboardAccessoryObservers.removeAll()
    }

    private func setupKeyboardAccessoryObservers() {
        removeKeyboardAccessoryObservers()

        let frameObserver = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillChangeFrameNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleKeyboardFrameChange(notification)
        }
        keyboardAccessoryObservers.append(frameObserver)

        let hideObserver = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillHideNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleKeyboardWillHide(notification)
        }
        keyboardAccessoryObservers.append(hideObserver)

        let connectObserver = NotificationCenter.default.addObserver(
            forName: .GCKeyboardDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateAccessoryBarVisibility()
        }
        keyboardAccessoryObservers.append(connectObserver)

        let disconnectObserver = NotificationCenter.default.addObserver(
            forName: .GCKeyboardDidDisconnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.hasReceivedPhysicalKeyPress = false
            self?.updateAccessoryBarVisibility()
        }
        keyboardAccessoryObservers.append(disconnectObserver)
    }

    private func handleKeyboardFrameChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let endFrame = (userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else {
            return
        }

        let screenHeight = window?.windowScene?.screen.bounds.height ?? UIScreen.main.bounds.height
        // An on-screen keyboard has a substantial height (>= 100pt) and its frame is on-screen.
        // A hardware keyboard without an on-screen keyboard has height 0 or is off-screen,
        // or if only an accessory bar is present, its height is <= 60pt.
        let isShowingOnScreen = endFrame.origin.y < screenHeight && endFrame.height > 100

        if self.isOnScreenKeyboardDisplayed != isShowingOnScreen {
            self.isOnScreenKeyboardDisplayed = isShowingOnScreen
            updateAccessoryBarVisibility()
        }
    }

    private func handleKeyboardWillHide(_ notification: Notification) {
        if self.isOnScreenKeyboardDisplayed {
            self.isOnScreenKeyboardDisplayed = false
            updateAccessoryBarVisibility()
        }
    }

    public func updateAccessoryBarVisibility() {
        #if !os(visionOS)
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []
        #endif

        guard TerminalSettings.shared.showKeyboardAccessoryBar else {
            if self.inputAccessoryView != nil {
                self.inputAccessoryView = nil
                if isFirstResponder {
                    reloadInputViews()
                }
            }
            return
        }

        if self.customAccessoryView == nil {
            let accessory = FilaireAccessoryView(
                frame: CGRect(x: 0, y: 0, width: bounds.width, height: accessoryBarHeight),
                delegate: self
            )
            accessory.configureTmux(
                enabled: autoConnectTmux,
                prefixTitle: tmuxPrefixTitle,
                prefixByte: tmuxPrefixByte
            )
            accessory.applyTheme(ThemeManager.shared.currentTheme)
            self.customAccessoryView = accessory
        }

        let desiredAccessory: UIView? = shouldShowAccessoryBar ? self.customAccessoryView : nil
        if self.inputAccessoryView !== desiredAccessory {
            self.inputAccessoryView = desiredAccessory
            if isFirstResponder {
                reloadInputViews()
            }
        }
    }

    public func applyAccessoryBarSetting() {
        updateAccessoryBarVisibility()
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

    public func accessoryDidRequestComposer() {
        _ = triggerOpenComposer()
    }

    public func accessoryDidRequestSnippets() {
        _ = triggerOpenSnippets()
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




    // MARK: - Cursor State Overrides

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
}
