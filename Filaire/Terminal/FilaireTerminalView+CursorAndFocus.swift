import UIKit
import SwiftTerm

// MARK: - Cursor Animation & Focus Management
extension FilaireTerminalView {
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
        updateAccessoryBarVisibility()
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


    internal func removeWindowObservers() {
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        windowObservers.removeAll()
    }

    internal func setupWindowObservers(for window: UIWindow) {
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

