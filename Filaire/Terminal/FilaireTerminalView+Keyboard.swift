import UIKit
import SwiftTerm
import GameController

// MARK: - Hardware Keyboard & Shortcuts
extension FilaireTerminalView {
    // MARK: - Key Commands for Hardware Keyboard Passthrough & Tmux Shortcuts



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
             #selector(handleTmuxBreakPane(_:)),
             #selector(handleTmuxRenameWindow(_:)),
             #selector(handleTmuxNextWindow(_:)),
             #selector(handleTmuxPrevWindow(_:)),
             #selector(handleTmuxSplitVertical(_:)),
             #selector(handleTmuxSplitHorizontal(_:)),
             #selector(handleTmuxJoinVertical(_:)),
             #selector(handleTmuxJoinHorizontal(_:)),
             #selector(handleTmuxMarkPane(_:)),
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
             #selector(handleOpenComposer(_:)),
             #selector(handleOpenSnippets(_:)),
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
        RunLoop.main.add(timer, forMode: .common)
    }

    open override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !hasReceivedPhysicalKeyPress && presses.contains(where: { $0.key != nil }) {
            hasReceivedPhysicalKeyPress = true
            updateAccessoryBarVisibility()
        }
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

            // Cmd+J: Join vertically
            if lowercasedIgnoring == "j" || keyCode == .keyboardJ {
                return triggerTmuxJoinVertical()
            }

            // Cmd+M: Mark pane
            if lowercasedIgnoring == "m" || keyCode == .keyboardM {
                return triggerTmuxMarkPane()
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

            // Cmd+Shift+J: Join horizontally
            if lowercasedIgnoring == "j" || keyCode == .keyboardJ {
                return triggerTmuxJoinHorizontal()
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

            // Cmd+Shift+B: Break the current pane into its own tmux window
            if (lowercasedIgnoring == "b" || keyCode == .keyboardB) && autoConnectTmux {
                return triggerTmuxBreakPane()
            }

            // Cmd+Shift+E: Open the command composer
            if lowercasedIgnoring == "e" || keyCode == .keyboardE {
                return triggerOpenComposer()
            }

            // Cmd+Shift+S: Open the snippet library
            if lowercasedIgnoring == "s" || keyCode == .keyboardS {
                return triggerOpenSnippets()
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

            let cmdM = UIKeyCommand(input: "m", modifierFlags: .command, action: #selector(handleTmuxMarkPane(_:)))
            cmdM.title = "Mark Pane"
            cmdM.discoverabilityTitle = "Mark Pane"
            cmdM.wantsPriorityOverSystemBehavior = true
            commands.append(cmdM)

            let cmdJ = UIKeyCommand(input: "j", modifierFlags: .command, action: #selector(handleTmuxJoinVertical(_:)))
            cmdJ.title = "Join Pane Vertically"
            cmdJ.discoverabilityTitle = "Join Pane Vertically"
            cmdJ.wantsPriorityOverSystemBehavior = true
            commands.append(cmdJ)

            let cmdShiftJ = UIKeyCommand(input: "J", modifierFlags: [.command, .shift], action: #selector(handleTmuxJoinHorizontal(_:)))
            cmdShiftJ.title = "Join Pane Horizontally"
            cmdShiftJ.discoverabilityTitle = "Join Pane Horizontally"
            cmdShiftJ.wantsPriorityOverSystemBehavior = true
            commands.append(cmdShiftJ)

            let cmdShiftJLower = UIKeyCommand(input: "j", modifierFlags: [.command, .shift], action: #selector(handleTmuxJoinHorizontal(_:)))
            cmdShiftJLower.wantsPriorityOverSystemBehavior = true
            commands.append(cmdShiftJLower)

            let cmdShiftR = UIKeyCommand(input: "R", modifierFlags: [.command, .shift], action: #selector(handleTmuxRenameWindow(_:)))
            cmdShiftR.title = "Rename Tmux Window"
            cmdShiftR.discoverabilityTitle = "Rename Tmux Window"
            cmdShiftR.wantsPriorityOverSystemBehavior = true
            commands.append(cmdShiftR)

            let cmdShiftRLower = UIKeyCommand(input: "r", modifierFlags: [.command, .shift], action: #selector(handleTmuxRenameWindow(_:)))
            cmdShiftRLower.wantsPriorityOverSystemBehavior = true
            commands.append(cmdShiftRLower)

            let cmdShiftB = UIKeyCommand(input: "B", modifierFlags: [.command, .shift], action: #selector(handleTmuxBreakPane(_:)))
            cmdShiftB.title = "Break Pane Into Window"
            cmdShiftB.discoverabilityTitle = "Break Pane Into Window"
            cmdShiftB.wantsPriorityOverSystemBehavior = true
            commands.append(cmdShiftB)

            let cmdShiftBLower = UIKeyCommand(input: "b", modifierFlags: [.command, .shift], action: #selector(handleTmuxBreakPane(_:)))
            cmdShiftBLower.wantsPriorityOverSystemBehavior = true
            commands.append(cmdShiftBLower)

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

        let cmdShiftE = UIKeyCommand(
            input: "E",
            modifierFlags: [.command, .shift],
            action: #selector(handleOpenComposer(_:))
        )
        cmdShiftE.title = "Compose Command"
        cmdShiftE.discoverabilityTitle = "Compose Command"
        cmdShiftE.wantsPriorityOverSystemBehavior = true
        commands.append(cmdShiftE)

        let cmdShiftELower = UIKeyCommand(
            input: "e",
            modifierFlags: [.command, .shift],
            action: #selector(handleOpenComposer(_:))
        )
        cmdShiftELower.wantsPriorityOverSystemBehavior = true
        commands.append(cmdShiftELower)

        let cmdShiftS = UIKeyCommand(
            input: "S",
            modifierFlags: [.command, .shift],
            action: #selector(handleOpenSnippets(_:))
        )
        cmdShiftS.title = "Snippets"
        cmdShiftS.discoverabilityTitle = "Snippets"
        cmdShiftS.wantsPriorityOverSystemBehavior = true
        commands.append(cmdShiftS)

        let cmdShiftSLower = UIKeyCommand(
            input: "s",
            modifierFlags: [.command, .shift],
            action: #selector(handleOpenSnippets(_:))
        )
        cmdShiftSLower.wantsPriorityOverSystemBehavior = true
        commands.append(cmdShiftSLower)

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

    /// tmux break-pane: moves the current pane into a window of its own, which is far easier to work with
    /// than a split on a phone-sized screen.
    @discardableResult
    public func triggerTmuxBreakPane() -> Bool {
        guard autoConnectTmux else { return false }
        guard shouldExecuteShortcut(id: "breakPane") else { return true }
        send([tmuxPrefixByte, UInt8(ascii: "!")])
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
        // Bound to split-window -h -c "#{pane_current_path}" by HostProfile.tmuxStartupCommand
        send(Array("\u{1b}[9990~".utf8))
        return true
    }

    @discardableResult
    public func triggerTmuxSplitHorizontal() -> Bool {
        guard autoConnectTmux else { return false }
        guard shouldExecuteShortcut(id: "splitHoriz") else { return true }
        // Bound to split-window -v -c "#{pane_current_path}" by HostProfile.tmuxStartupCommand
        send(Array("\u{1b}[9991~".utf8))
        return true
    }

    @discardableResult
    public func triggerTmuxJoinVertical() -> Bool {
        guard autoConnectTmux else { return false }
        guard shouldExecuteShortcut(id: "joinVert") else { return true }
        // Bound to join-pane -h by HostProfile.tmuxStartupCommand
        send(Array("\u{1b}[9992~".utf8))
        return true
    }

    @discardableResult
    public func triggerTmuxJoinHorizontal() -> Bool {
        guard autoConnectTmux else { return false }
        guard shouldExecuteShortcut(id: "joinHoriz") else { return true }
        // Bound to join-pane -v by HostProfile.tmuxStartupCommand
        send(Array("\u{1b}[9993~".utf8))
        return true
    }

    @discardableResult
    public func triggerTmuxMarkPane() -> Bool {
        guard autoConnectTmux else { return false }
        guard shouldExecuteShortcut(id: "markPane") else { return true }
        send([tmuxPrefixByte, UInt8(ascii: "m")])
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

    /// Asks this view's owning context to present the command composer. Routed through a callback rather than
    /// a broadcast, so only the originating scene opens an editor.
    @discardableResult
    public func triggerOpenComposer() -> Bool {
        guard shouldExecuteShortcut(id: "openComposer") else { return true }
        onComposerRequested?()
        return true
    }

    /// Asks this view's owning context to present the snippet library.
    @discardableResult
    public func triggerOpenSnippets() -> Bool {
        guard shouldExecuteShortcut(id: "openSnippets") else { return true }
        onSnippetsRequested?()
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

    @objc open func handleOpenComposer(_ sender: Any?) {
        _ = triggerOpenComposer()
    }

    @objc open func handleOpenSnippets(_ sender: Any?) {
        _ = triggerOpenSnippets()
    }

    @objc open func handleTmuxBreakPane(_ sender: Any?) {
        _ = triggerTmuxBreakPane()
    }

    @objc open func handleTmuxSplitVertical(_ sender: Any?) {
        _ = triggerTmuxSplitVertical()
    }

    @objc open func handleTmuxSplitHorizontal(_ sender: Any?) {
        _ = triggerTmuxSplitHorizontal()
    }

    @objc open func handleTmuxJoinVertical(_ sender: Any?) {
        _ = triggerTmuxJoinVertical()
    }

    @objc open func handleTmuxJoinHorizontal(_ sender: Any?) {
        _ = triggerTmuxJoinHorizontal()
    }

    @objc open func handleTmuxMarkPane(_ sender: Any?) {
        _ = triggerTmuxMarkPane()
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
