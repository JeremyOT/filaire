import XCTest
import SwiftUI
import UIKit
import Crypto
import NIOSSH
import NIO
import NIOConcurrencyHelpers
import Citadel
import SwiftTerm
import Network
import GameController
import os
@testable import Filaire

final class TerminalGesturesAndKeyboardTests: XCTestCase {
    // MARK: - Hardware Keyboard Passthrough & Cmd Tmux Shortcuts

    func testHardwareKeyboardPassthroughCommands() {
        let terminalView = FilaireTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let commands = terminalView.keyCommands

        XCTAssertNotNil(commands)
        guard let cmds = commands else { return }

        // Verify all 26 Ctrl + [a-z] combinations are registered with priority
        let letters = "abcdefghijklmnopqrstuvwxyz"
        for char in letters {
            let matching = cmds.first { $0.input == String(char) && $0.modifierFlags == .control }
            XCTAssertNotNil(matching, "Missing UIKeyCommand for Ctrl-\(char)")
            XCTAssertTrue(matching?.wantsPriorityOverSystemBehavior == true, "Ctrl-\(char) must prioritize over system")
        }

        // Specifically test Ctrl-Z (process suspend / job control)
        let ctrlZ = cmds.first { $0.input == "z" && $0.modifierFlags == .control }
        XCTAssertNotNil(ctrlZ, "Ctrl-Z must be registered")
        XCTAssertTrue(ctrlZ?.wantsPriorityOverSystemBehavior == true)

        // Specifically test Ctrl-C (cancel)
        let ctrlC = cmds.first { $0.input == "c" && $0.modifierFlags == .control }
        XCTAssertNotNil(ctrlC, "Ctrl-C must be registered")
        XCTAssertTrue(ctrlC?.wantsPriorityOverSystemBehavior == true)

        // Verify Cmd+1 through Cmd+9 for tmux window switching
        for num in 1...9 {
            let cmdNum = cmds.first { $0.input == "\(num)" && $0.modifierFlags == .command }
            XCTAssertNotNil(cmdNum, "Cmd+\(num) must be registered for tmux window switching")
            XCTAssertTrue(cmdNum?.wantsPriorityOverSystemBehavior == true)
        }

        // Verify Cmd+T (new window), Cmd+W (close pane), Cmd+N/P, Cmd+D (split)
        XCTAssertNotNil(cmds.first { $0.input == "t" && $0.modifierFlags == .command })
        XCTAssertNotNil(cmds.first { $0.input == "w" && $0.modifierFlags == .command })
        XCTAssertNotNil(cmds.first { $0.input == "n" && $0.modifierFlags == .command })
        XCTAssertNotNil(cmds.first { $0.input == "p" && $0.modifierFlags == .command })
        XCTAssertNotNil(cmds.first { $0.input == "d" && $0.modifierFlags == .command })
        XCTAssertNotNil(cmds.first { $0.input == "k" && $0.modifierFlags == .command })
        XCTAssertNotNil(cmds.first { $0.input == "v" && $0.modifierFlags == .command })

        // Verify Cmd+Option+Arrow for tmux split pane navigation
        let optCmdArrows = [
            UIKeyCommand.inputUpArrow,
            UIKeyCommand.inputDownArrow,
            UIKeyCommand.inputLeftArrow,
            UIKeyCommand.inputRightArrow
        ]
        for arrow in optCmdArrows {
            let matching = cmds.first { $0.input == arrow && $0.modifierFlags == [.command, .alternate] }
            XCTAssertNotNil(matching, "Cmd+Option+\(arrow) must be registered for tmux pane navigation")
            XCTAssertTrue(matching?.wantsPriorityOverSystemBehavior == true)
        }

        // Verify Cmd+Option+] / [ for tmux pane cycling
        let cycleNext = cmds.first { $0.input == "]" && $0.modifierFlags == [.command, .alternate] }
        XCTAssertNotNil(cycleNext, "Cmd+Option+] must be registered for tmux pane cycling")
        XCTAssertTrue(cycleNext?.wantsPriorityOverSystemBehavior == true)

        let cyclePrev = cmds.first { $0.input == "[" && $0.modifierFlags == [.command, .alternate] }
        XCTAssertNotNil(cyclePrev, "Cmd+Option+[ must be registered for tmux pane cycling")
        XCTAssertTrue(cyclePrev?.wantsPriorityOverSystemBehavior == true)

        // Verify discoverabilityTitle and title on key commands
        let cmdT = cmds.first { $0.input == "t" && $0.modifierFlags == .command }
        XCTAssertEqual(cmdT?.discoverabilityTitle, "New Tmux Window")
        XCTAssertEqual(cmdT?.title, "New Tmux Window")

        let cmdW = cmds.first { $0.input == "w" && $0.modifierFlags == .command }
        XCTAssertEqual(cmdW?.discoverabilityTitle, "Close Tmux Pane")

        let cmdShiftD = cmds.first { $0.input == "D" && $0.modifierFlags == [.command, .shift] }
        XCTAssertNotNil(cmdShiftD, "Cmd+Shift+D must be registered with uppercase D")
        XCTAssertEqual(cmdShiftD?.discoverabilityTitle, "Split Pane Horizontally")

        let cmdShiftR = cmds.first { $0.input == "R" && $0.modifierFlags == [.command, .shift] }
        XCTAssertNotNil(cmdShiftR, "Cmd+Shift+R must be registered with uppercase R")
        XCTAssertEqual(cmdShiftR?.discoverabilityTitle, "Rename Tmux Window")
    }

    func testTargetForActionWhitelist() {
        let terminalView = FilaireTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))

        let actions: [Selector] = [
            #selector(FilaireTerminalView.handleControlKeyCommand(_:)),
            #selector(FilaireTerminalView.handleTmuxNumberShortcut(_:)),
            #selector(FilaireTerminalView.handleTmuxNewWindow(_:)),
            #selector(FilaireTerminalView.handleTmuxClosePane(_:)),
            #selector(FilaireTerminalView.handleTmuxRenameWindow(_:)),
            #selector(FilaireTerminalView.handleTmuxNextWindow(_:)),
            #selector(FilaireTerminalView.handleTmuxPrevWindow(_:)),
            #selector(FilaireTerminalView.handleTmuxSplitVertical(_:)),
            #selector(FilaireTerminalView.handleTmuxSplitHorizontal(_:)),
            #selector(FilaireTerminalView.handleTmuxSelectPaneUp(_:)),
            #selector(FilaireTerminalView.handleTmuxSelectPaneDown(_:)),
            #selector(FilaireTerminalView.handleTmuxSelectPaneLeft(_:)),
            #selector(FilaireTerminalView.handleTmuxSelectPaneRight(_:)),
            #selector(FilaireTerminalView.handleTmuxCyclePaneNext(_:)),
            #selector(FilaireTerminalView.handleTmuxCyclePanePrev(_:)),
            #selector(FilaireTerminalView.handleClearScreen(_:)),
            #selector(FilaireTerminalView.handlePaste(_:)),
            #selector(FilaireTerminalView.handlePasteCommand(_:)),
            #selector(FilaireTerminalView.handleOpenSettingsShortcut(_:)),
            #selector(FilaireTerminalView.handleZoomInCommand(_:)),
            #selector(FilaireTerminalView.handleZoomOutCommand(_:)),
            #selector(FilaireTerminalView.handleZoomResetCommand(_:)),
            #selector(FilaireTerminalView.handleArrowKeyCommand(_:))
        ]

        for action in actions {
            let target = terminalView.target(forAction: action, withSender: nil)
            XCTAssertTrue((target as AnyObject?) === terminalView, "target(forAction: \(action)) must return terminalView so responder chain dispatches it")
        }
    }

    func testHardwareKeyboardInterceptionAndActions() {
        class MockDelegate: TerminalViewDelegate {
            var sentData: [[UInt8]] = []
            func send(source: TerminalView, data: ArraySlice<UInt8>) {
                sentData.append(Array(data))
            }
            func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
            func setTerminalTitle(source: TerminalView, title: String) {}
            func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
            func scrolled(source: TerminalView, position: Double) {}
            func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
            func bell(source: TerminalView) {}
            func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        }

        let terminalView = FilaireTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = MockDelegate()
        terminalView.terminalDelegate = delegate

        // Default prefix is Ctrl-B (0x02)
        terminalView.configureTmux(enabled: true, prefixTitle: "Ctrl-B", prefixByte: 0x02)

        // 1. Cmd+T: New Window -> [0x02, 'c']
        XCTAssertTrue(terminalView.handleKeyShortcut(characters: "t", charactersIgnoringModifiers: "t", modifierFlags: .command))
        XCTAssertEqual(delegate.sentData.last, [0x02, UInt8(ascii: "c")])

        // 2. Cmd+W: Close Pane -> [0x02, 'x']
        XCTAssertTrue(terminalView.handleKeyShortcut(characters: "w", charactersIgnoringModifiers: "w", modifierFlags: .command))
        XCTAssertEqual(delegate.sentData.last, [0x02, UInt8(ascii: "x")])

        // 3. Cmd+N: Next Window -> [0x02, 'n']
        XCTAssertTrue(terminalView.handleKeyShortcut(characters: "n", charactersIgnoringModifiers: "n", modifierFlags: .command))
        XCTAssertEqual(delegate.sentData.last, [0x02, UInt8(ascii: "n")])

        // 4. Cmd+]: Next Window -> [0x02, 'n']
        XCTAssertTrue(terminalView.handleKeyShortcut(characters: "]", charactersIgnoringModifiers: "]", modifierFlags: .command))
        XCTAssertEqual(delegate.sentData.last, [0x02, UInt8(ascii: "n")])

        // 5. Cmd+P: Previous Window -> [0x02, 'p']
        XCTAssertTrue(terminalView.handleKeyShortcut(characters: "p", charactersIgnoringModifiers: "p", modifierFlags: .command))
        XCTAssertEqual(delegate.sentData.last, [0x02, UInt8(ascii: "p")])

        // 6. Cmd+[: Previous Window -> [0x02, 'p']
        XCTAssertTrue(terminalView.handleKeyShortcut(characters: "[", charactersIgnoringModifiers: "[", modifierFlags: .command))
        XCTAssertEqual(delegate.sentData.last, [0x02, UInt8(ascii: "p")])

        // 7. Cmd+D: Split Vertically -> ESC [9990~ (bound by the tmux startup command)
        XCTAssertTrue(terminalView.handleKeyShortcut(characters: "d", charactersIgnoringModifiers: "d", modifierFlags: .command))
        XCTAssertEqual(delegate.sentData.last, Array("\u{1b}[9990~".utf8))

        // 8. Cmd+Shift+D: Split Horizontally -> ESC [9991~ (bound by the tmux startup command)
        XCTAssertTrue(terminalView.handleKeyShortcut(characters: "D", charactersIgnoringModifiers: "d", modifierFlags: [.command, .shift]))
        XCTAssertEqual(delegate.sentData.last, Array("\u{1b}[9991~".utf8))

        // 8b. Cmd+Shift+R: Rename Window -> [0x02, ',']
        XCTAssertTrue(terminalView.handleKeyShortcut(characters: "R", charactersIgnoringModifiers: "r", modifierFlags: [.command, .shift]))
        XCTAssertEqual(delegate.sentData.last, [0x02, UInt8(ascii: ",")])

        // 8c. Cmd+Shift+B: Break Pane Into Window -> [0x02, '!']
        XCTAssertTrue(terminalView.handleKeyShortcut(characters: "B", charactersIgnoringModifiers: "b", modifierFlags: [.command, .shift]))
        XCTAssertEqual(delegate.sentData.last, [0x02, UInt8(ascii: "!")])

        // 8d. Cmd+M: Mark Pane -> [0x02, 'm']
        XCTAssertTrue(terminalView.handleKeyShortcut(characters: "m", charactersIgnoringModifiers: "m", modifierFlags: .command))
        XCTAssertEqual(delegate.sentData.last, [0x02, UInt8(ascii: "m")])

        // 8e. Cmd+J: Join Vertically -> ESC [9992~ (bound by tmux startup command)
        XCTAssertTrue(terminalView.handleKeyShortcut(characters: "j", charactersIgnoringModifiers: "j", modifierFlags: .command))
        XCTAssertEqual(delegate.sentData.last, Array("\u{1b}[9992~".utf8))

        // 8f. Cmd+Shift+J: Join Horizontally -> ESC [9993~ (bound by tmux startup command)
        XCTAssertTrue(terminalView.handleKeyShortcut(characters: "J", charactersIgnoringModifiers: "j", modifierFlags: [.command, .shift]))
        XCTAssertEqual(delegate.sentData.last, Array("\u{1b}[9993~".utf8))

        // 9. Cmd+3: Switch to Window 3 -> [0x02, '3']
        XCTAssertTrue(terminalView.handleKeyShortcut(characters: "3", charactersIgnoringModifiers: "3", modifierFlags: .command))
        XCTAssertEqual(delegate.sentData.last, [0x02, UInt8(ascii: "3")])

        // 10. Cmd+Opt+Up: Pane Above -> [0x02, ESC, '[', 'A']
        XCTAssertTrue(terminalView.handleKeyShortcut(characters: "", charactersIgnoringModifiers: UIKeyCommand.inputUpArrow, modifierFlags: [.command, .alternate], keyCode: .keyboardUpArrow))
        XCTAssertEqual(delegate.sentData.last, [0x02, 0x1b, 0x5b, 0x41])

        // 11. Cmd+Opt+]: Cycle Next Pane -> [0x02, 'o']
        XCTAssertTrue(terminalView.handleKeyShortcut(characters: "]", charactersIgnoringModifiers: "]", modifierFlags: [.command, .alternate]))
        XCTAssertEqual(delegate.sentData.last, [0x02, UInt8(ascii: "o")])

        // 12. Cmd+Opt+[: Cycle Previous Pane -> [0x02, ';']
        XCTAssertTrue(terminalView.handleKeyShortcut(characters: "[", charactersIgnoringModifiers: "[", modifierFlags: [.command, .alternate]))
        XCTAssertEqual(delegate.sentData.last, [0x02, UInt8(ascii: ";")])

        // 13. Cmd+Opt+C: Enter Copy Mode -> [0x02, '[']
        XCTAssertTrue(terminalView.handleKeyShortcut(characters: "c", charactersIgnoringModifiers: "c", modifierFlags: [.command, .alternate]))
        XCTAssertEqual(delegate.sentData.last, [0x02, UInt8(ascii: "[")])

        // 14. Cmd+K: Clear Screen -> [0x0c]
        XCTAssertTrue(terminalView.handleKeyShortcut(characters: "k", charactersIgnoringModifiers: "k", modifierFlags: .command))
        XCTAssertEqual(delegate.sentData.last, [0x0c])

        // 15. Cmd+,: Settings notification
        var settingsOpened = false
        let observer = NotificationCenter.default.addObserver(forName: .openSettingsRequested, object: nil, queue: nil) { _ in
            settingsOpened = true
        }
        XCTAssertTrue(terminalView.handleKeyShortcut(characters: ",", charactersIgnoringModifiers: ",", modifierFlags: .command))
        XCTAssertTrue(settingsOpened, "Cmd+, must post openSettingsRequested notification")
        NotificationCenter.default.removeObserver(observer)

        // 16. Custom prefix byte (e.g. Ctrl-Z: 0x1A)
        terminalView.configureTmux(enabled: true, prefixTitle: "Ctrl-Z", prefixByte: 0x1A)
        XCTAssertTrue(terminalView.handleKeyShortcut(characters: "t", charactersIgnoringModifiers: "t", modifierFlags: .command))
        XCTAssertEqual(delegate.sentData.last, [0x1A, UInt8(ascii: "c")], "Cmd+T must use configured Ctrl-Z prefix byte 0x1A")

        // 17. Auto-connect disabled: tmux shortcuts return false (passthrough), non-tmux still handled
        terminalView.configureTmux(enabled: false, prefixTitle: "Disabled", prefixByte: 0x02)
        let beforeCount = delegate.sentData.count
        XCTAssertFalse(terminalView.handleKeyShortcut(characters: "t", charactersIgnoringModifiers: "t", modifierFlags: .command))
        XCTAssertEqual(delegate.sentData.count, beforeCount, "Disabled tmux must not send bytes for Cmd+T")
        XCTAssertFalse(terminalView.handleKeyShortcut(characters: "c", charactersIgnoringModifiers: "c", modifierFlags: [.command, .alternate]), "Disabled tmux must not send bytes for Cmd+Opt+C")

        XCTAssertTrue(terminalView.handleKeyShortcut(characters: "k", charactersIgnoringModifiers: "k", modifierFlags: .command))
        XCTAssertEqual(delegate.sentData.last, [0x0c], "Cmd+K must still clear screen even when tmux is disabled")
    }


    // MARK: - Two-Finger Scroll Gesture & iPad Status Bar Configuration

    @MainActor
    func testTwoFingerScrollGestureConfigured() {
        let terminalView = FilaireTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))

        // scrollsToTop must be false so status bar taps expand our status overlay
        XCTAssertFalse(terminalView.scrollsToTop, "scrollsToTop must be false to allow status bar taps to expand overlay")

        // Must have a pan gesture recognizer configured with 2 touches
        let twoFingerPan = terminalView.gestureRecognizers?.compactMap { $0 as? UIPanGestureRecognizer }.first {
            $0.minimumNumberOfTouches == 2 && $0.maximumNumberOfTouches == 2
        }
        XCTAssertNotNil(twoFingerPan, "A dedicated 2-finger pan gesture recognizer must be registered")
        XCTAssertTrue(twoFingerPan?.cancelsTouchesInView == true)
        XCTAssertTrue(twoFingerPan?.delaysTouchesBegan == true)
    }

    func testPinchGestureConfigured() {
        let terminalView = FilaireTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let pinch = terminalView.gestureRecognizers?.compactMap { $0 as? UIPinchGestureRecognizer }.first
        XCTAssertNotNil(pinch, "A dedicated pinch gesture recognizer must be registered on FilaireTerminalView")
    }


    // MARK: - Keyboard Accessory Bar Settings
    func testKeyboardAccessoryBarSettingsToggle() {
        let original = TerminalSettings.shared.showKeyboardAccessoryBar
        defer {
            TerminalSettings.shared.showKeyboardAccessoryBar = original
        }

        TerminalSettings.shared.showKeyboardAccessoryBar = true
        XCTAssertTrue(TerminalSettings.shared.showKeyboardAccessoryBar)

        TerminalSettings.shared.showKeyboardAccessoryBar = false
        XCTAssertFalse(TerminalSettings.shared.showKeyboardAccessoryBar)
    }

    func testKeyboardAccessoryBarDefaultsToTrueOnAllPlatforms() {
        let key = "io.o-t.filaire.show_keyboard_accessory_bar"
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved = saved {
                UserDefaults.standard.set(saved, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertTrue(TerminalSettings.shared.showKeyboardAccessoryBar, "Keyboard helper bar must default to true on all devices including iPad")
    }

    @MainActor
    func testFilaireTerminalViewAccessoryBarConfiguredByDefault() {
        let key = "io.o-t.filaire.show_keyboard_accessory_bar"
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved = saved {
                UserDefaults.standard.set(saved, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        UserDefaults.standard.removeObject(forKey: key)

        let terminalView = FilaireTerminalView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        terminalView.isHardwareKeyboardConnectedOverride = false
        terminalView.updateAccessoryBarVisibility()

        XCTAssertNotNil(terminalView.customAccessoryView, "customAccessoryView must be present by default")
        XCTAssertNotNil(terminalView.inputAccessoryView, "inputAccessoryView must be present by default when no hardware keyboard is connected")
        guard let accessory = terminalView.customAccessoryView else {
            XCTFail("customAccessoryView should not be nil")
            return
        }
        XCTAssertTrue(accessory.allowsSelfSizing, "FilaireAccessoryView must have allowsSelfSizing enabled for Auto Layout on iPad")
        XCTAssertEqual(accessory.intrinsicContentSize.height, 44.0)
    }

    @MainActor
    func testAccessoryBarHiddenWhenMagicKeyboardPresentWithoutOnScreenKeyboard() {
        let key = "io.o-t.filaire.show_keyboard_accessory_bar"
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved = saved {
                UserDefaults.standard.set(saved, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        UserDefaults.standard.removeObject(forKey: key)

        let terminalView = FilaireTerminalView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        terminalView.isHardwareKeyboardConnectedOverride = true
        terminalView.isOnScreenKeyboardDisplayedOverride = false
        terminalView.updateAccessoryBarVisibility()

        XCTAssertFalse(terminalView.shouldShowAccessoryBar, "Accessory bar should not be shown when Magic Keyboard is present without onscreen keyboard")
        XCTAssertNil(terminalView.inputAccessoryView, "inputAccessoryView must be nil when using Magic Keyboard without onscreen keyboard")
        XCTAssertNotNil(terminalView.customAccessoryView, "customAccessoryView should still be instantiated for when needed")
    }

    @MainActor
    func testAccessoryBarShownWhenMagicKeyboardPresentWithOnScreenKeyboard() {
        let key = "io.o-t.filaire.show_keyboard_accessory_bar"
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved = saved {
                UserDefaults.standard.set(saved, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        UserDefaults.standard.removeObject(forKey: key)

        let terminalView = FilaireTerminalView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        terminalView.isHardwareKeyboardConnectedOverride = true
        terminalView.isOnScreenKeyboardDisplayedOverride = true
        terminalView.updateAccessoryBarVisibility()

        XCTAssertTrue(terminalView.shouldShowAccessoryBar, "Accessory bar should be shown when onscreen keyboard is displayed even if Magic Keyboard is present")
        XCTAssertNotNil(terminalView.inputAccessoryView, "inputAccessoryView must be present when onscreen keyboard is displayed")
        XCTAssertTrue(terminalView.inputAccessoryView === terminalView.customAccessoryView)
    }

    private final class MockAccessoryDelegate: FilaireAccessoryDelegate {
        var sentBytes: [UInt8] = []
        var pasteRequested = false
        var composerRequested = false
        var snippetsRequested = false
        func accessoryDidSendBytes(_ bytes: [UInt8]) { sentBytes.append(contentsOf: bytes) }
        func accessoryDidInsertText(_ text: String) {}
        func accessoryDidToggleControl(isActive: Bool) {}
        func accessoryDidToggleAlt(isActive: Bool) {}
        func accessoryDidRequestDismissKeyboard() {}
        func accessoryDidRequestPaste() { pasteRequested = true }
        func accessoryDidRequestComposer() { composerRequested = true }
        func accessoryDidRequestSnippets() { snippetsRequested = true }
    }

    @MainActor
    func testAccessoryBarTmuxPrefixConfiguration() {
        let delegate = MockAccessoryDelegate()
        let accessory = FilaireAccessoryView(frame: CGRect(x: 0, y: 0, width: 600, height: 44), delegate: delegate)

        guard let stack = accessory.subviews.compactMap({ $0 as? UIScrollView }).first?.subviews.compactMap({ $0 as? UIStackView }).first else {
            XCTFail("Failed to find UIStackView in accessory view")
            return
        }

        let buttons = stack.arrangedSubviews.compactMap { $0 as? UIButton }
        XCTAssertEqual(buttons.first?.configuration?.title, "Compose", "Compose must be the 1st button in the keyboard accessory bar")
        XCTAssertEqual(buttons.count > 1 ? buttons[1].configuration?.title : nil, "Snippets", "Snippets must be the 2nd button in the keyboard accessory bar")

        let prefixButton = buttons.first { $0.configuration?.title == "Ctrl-B" || $0.configuration?.title == "Ctrl-Z" }
        let copyButton = buttons.first { $0.configuration?.title == "Copy" }
        XCTAssertNotNil(prefixButton)
        XCTAssertNotNil(copyButton)
        XCTAssertFalse(prefixButton?.isHidden ?? true)
        XCTAssertFalse(copyButton?.isHidden ?? true)
        XCTAssertEqual(prefixButton?.configuration?.title, "Ctrl-B")
        XCTAssertEqual(copyButton?.configuration?.title, "Copy")

        // 1. Configure with Ctrl-Z
        accessory.configureTmux(enabled: true, prefixTitle: "Ctrl-Z", prefixByte: 0x1A)
        XCTAssertFalse(prefixButton?.isHidden ?? true)
        XCTAssertFalse(copyButton?.isHidden ?? true)
        XCTAssertEqual(prefixButton?.configuration?.title, "Ctrl-Z")

        // Send prefix action
        prefixButton?.sendActions(for: .touchUpInside)
        XCTAssertEqual(delegate.sentBytes.last, 0x1A)

        // Send copy mode action -> sends [prefix, '[']
        delegate.sentBytes.removeAll()
        copyButton?.sendActions(for: .touchUpInside)
        XCTAssertEqual(delegate.sentBytes, [0x1A, UInt8(ascii: "[")])

        // 2. Configure with auto-connect disabled
        accessory.configureTmux(enabled: false)
        XCTAssertTrue(prefixButton?.isHidden ?? false, "tmux prefix button must be hidden when tmux auto-connect is disabled")
        XCTAssertTrue(copyButton?.isHidden ?? false, "tmux copy button must be hidden when tmux auto-connect is disabled")

        // 3. Configure back to Ctrl-B
        accessory.configureTmux(enabled: true, prefixTitle: "Ctrl-B", prefixByte: 0x02)
        XCTAssertFalse(prefixButton?.isHidden ?? true)
        XCTAssertFalse(copyButton?.isHidden ?? true)
        XCTAssertEqual(prefixButton?.configuration?.title, "Ctrl-B")

        delegate.sentBytes.removeAll()
        copyButton?.sendActions(for: .touchUpInside)
        XCTAssertEqual(delegate.sentBytes, [0x02, UInt8(ascii: "[")])
    }

    @MainActor
    func testAccessoryBarEnhancedButtonsAndStickyModifiers() {
        let delegate = MockAccessoryDelegate()
        let accessory = FilaireAccessoryView(frame: CGRect(x: 0, y: 0, width: 800, height: 44), delegate: delegate)

        guard let stack = accessory.subviews.compactMap({ $0 as? UIScrollView }).first?.subviews.compactMap({ $0 as? UIStackView }).first else {
            XCTFail("Failed to find UIStackView in accessory view")
            return
        }

        let buttons = stack.arrangedSubviews.compactMap { $0 as? UIButton }

        // Find Ctrl-Z button
        let ctrlZ = buttons.first { $0.configuration?.title == "Ctrl-Z" }
        XCTAssertNotNil(ctrlZ, "Accessory bar must include Ctrl-Z button")
        delegate.sentBytes.removeAll()
        ctrlZ?.sendActions(for: .touchUpInside)
        XCTAssertEqual(delegate.sentBytes, [0x1A], "Ctrl-Z button must send 0x1A")

        // Find Ctrl-L button
        let ctrlL = buttons.first { $0.configuration?.title == "Ctrl-L" }
        XCTAssertNotNil(ctrlL, "Accessory bar must include Ctrl-L button")
        delegate.sentBytes.removeAll()
        ctrlL?.sendActions(for: .touchUpInside)
        XCTAssertEqual(delegate.sentBytes, [0x0C], "Ctrl-L button must send 0x0C (form feed / clear screen)")

        // Find Paste button
        let paste = buttons.first { $0.configuration?.title == "Paste" }
        XCTAssertNotNil(paste, "Accessory bar must include Paste button")
        XCTAssertFalse(delegate.pasteRequested)
        paste?.sendActions(for: .touchUpInside)
        XCTAssertTrue(delegate.pasteRequested, "Paste button must request paste from accessory delegate")

        // Find Compose button
        let compose = buttons.first { $0.configuration?.title == "Compose" }
        XCTAssertNotNil(compose, "Accessory bar must include Compose button")
        XCTAssertFalse(delegate.composerRequested)
        compose?.sendActions(for: .touchUpInside)
        XCTAssertTrue(delegate.composerRequested, "Compose button must request composer from accessory delegate")

        // Find Snippets button
        let snippets = buttons.first { $0.configuration?.title == "Snippets" }
        XCTAssertNotNil(snippets, "Accessory bar must include Snippets button")
        XCTAssertFalse(delegate.snippetsRequested)
        snippets?.sendActions(for: .touchUpInside)
        XCTAssertTrue(delegate.snippetsRequested, "Snippets button must request snippets from accessory delegate")

        // Arrow navigation with sticky Alt (Word navigation)
        // Find arrow buttons: Left arrow
        let leftArrow = buttons.first { $0.configuration?.image != nil && ($0.configuration?.title == nil || $0.configuration?.title?.isEmpty == true) }
        XCTAssertNotNil(leftArrow, "Accessory bar must have arrow buttons")

        // 1. Without Alt or Ctrl -> sends \e[D
        delegate.sentBytes.removeAll()
        leftArrow?.sendActions(for: .touchUpInside)
        XCTAssertEqual(delegate.sentBytes, [0x1B, 0x5B, 0x44], "Plain left arrow must send \u{1b}[D")

        // 2. With Alt active -> sends \eb (word backward) and resets Alt
        accessory.toggleAlt()
        XCTAssertTrue(accessory.isAltActive)
        delegate.sentBytes.removeAll()
        leftArrow?.sendActions(for: .touchUpInside)
        XCTAssertEqual(delegate.sentBytes, [0x1B, 0x62], "Alt + Left arrow must send Esc-b (word backward)")
        XCTAssertFalse(accessory.isAltActive, "Sticky Alt must reset after arrow navigation")

        // 3. With Ctrl active -> sends \u{01} (start of line) and resets Ctrl
        accessory.toggleControl()
        XCTAssertTrue(accessory.isControlActive)
        delegate.sentBytes.removeAll()
        leftArrow?.sendActions(for: .touchUpInside)
        XCTAssertEqual(delegate.sentBytes, [0x01], "Ctrl + Left arrow must send Ctrl-A (start of line)")
        XCTAssertFalse(accessory.isControlActive, "Sticky Ctrl must reset after arrow navigation")
    }

    @MainActor
    func testAccessoryBarButtonDimensions() {
        let delegate = MockAccessoryDelegate()
        for width in [390.0, 834.0, 1376.0] {
            let accessory = FilaireAccessoryView(frame: CGRect(x: 0, y: 0, width: width, height: 44), delegate: delegate)
            XCTAssertEqual(accessory.intrinsicContentSize.height, 44.0, "Accessory view height should be 44pt on all device sizes")
            accessory.layoutIfNeeded()
            guard let scroll = accessory.subviews.compactMap({ $0 as? UIScrollView }).first,
                  let stack = scroll.subviews.compactMap({ $0 as? UIStackView }).first else {
                XCTFail("Missing scroll or stack view in accessory bar")
                return
            }
            let buttons = stack.arrangedSubviews.compactMap({ $0 as? UIButton })
            // All buttons should have at least 44pt touch width and comfortable height (~43.5pt in a 44pt bar)
            for button in buttons {
                XCTAssertGreaterThanOrEqual(button.frame.width, 44.0, "Each button should have minimum 44pt width for touch target: \(button.configuration?.title ?? "symbol")")
                XCTAssertGreaterThanOrEqual(button.frame.height, 40.0, "Each button should fill bar height for touch target: \(button.configuration?.title ?? "symbol")")
            }
            // Buttons with longer text must expand to fit their single-line content without wrapping
            if let composeButton = buttons.first(where: { $0.configuration?.title == "Compose" }) {
                XCTAssertGreaterThan(composeButton.frame.width, 65.0, "Compose button must size to fit its content on a single line without wrapping")
                XCTAssertEqual(composeButton.titleLabel?.numberOfLines, 1, "Compose button must be single line")
            }
            if let snippetsButton = buttons.first(where: { $0.configuration?.title == "Snippets" }) {
                XCTAssertGreaterThan(snippetsButton.frame.width, 65.0, "Snippets button must size to fit its content on a single line without wrapping")
                XCTAssertEqual(snippetsButton.titleLabel?.numberOfLines, 1, "Snippets button must be single line")
            }
            if let ctrlBButton = buttons.first(where: { $0.configuration?.title == "Ctrl-B" }) {
                XCTAssertGreaterThan(ctrlBButton.frame.width, 55.0, "Ctrl-B button must size to fit its content on a single line without wrapping")
                XCTAssertEqual(ctrlBButton.titleLabel?.numberOfLines, 1, "Ctrl-B button must be single line")
            }
            // Arrow buttons: all four arrow buttons (buttons with images and no title) must be identical in size
            let arrowButtons = buttons.filter { $0.configuration?.image != nil && ($0.configuration?.title == nil || $0.configuration?.title?.isEmpty == true) }
            XCTAssertEqual(arrowButtons.count, 4, "Should have 4 arrow buttons")
            if arrowButtons.count == 4 {
                let left = arrowButtons[0]
                let up = arrowButtons[1]
                let down = arrowButtons[2]
                let right = arrowButtons[3]
                XCTAssertEqual(left.frame.width, 44.0, accuracy: 1.0, "Left arrow should be 44pt wide")
                XCTAssertEqual(up.frame.width, 44.0, accuracy: 1.0, "Up arrow should be 44pt wide")
                XCTAssertEqual(down.frame.width, 44.0, accuracy: 1.0, "Down arrow should be 44pt wide")
                XCTAssertEqual(right.frame.width, 44.0, accuracy: 1.0, "Right arrow should be 44pt wide")
                XCTAssertEqual(left.frame.width, up.frame.width, accuracy: 0.5, "Left and up arrows must be same size")
                XCTAssertEqual(left.frame.width, down.frame.width, accuracy: 0.5, "Left and down arrows must be same size")
                XCTAssertEqual(left.frame.width, right.frame.width, accuracy: 0.5, "Left and right arrows must be same size")
            }
        }
    }


    // MARK: - Option + Arrow Key Repeat Tests
    @MainActor
    func testOptionLeftArrowKeyRepeat() {
        final class MockDelegate: TerminalViewDelegate {
            var sentData: [[UInt8]] = []
            var onSend: (() -> Void)?
            func send(source: TerminalView, data: ArraySlice<UInt8>) {
                sentData.append(Array(data))
                onSend?()
            }
            func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
            func setTerminalTitle(source: TerminalView, title: String) {}
            func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
            func scrolled(source: TerminalView, position: Double) {}
            func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
            func bell(source: TerminalView) {}
            func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        }

        let terminal = FilaireTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = MockDelegate()
        terminal.terminalDelegate = delegate

        terminal.modifierKeyRepeatInitialDelay = 0.04
        terminal.modifierKeyRepeatInterval = 0.02

        // Wait for repeat ticks
        let exp = expectation(description: "Wait for repeat timer ticks")
        var fulfilled = false
        delegate.onSend = {
            if !fulfilled && delegate.sentData.count > 2 {
                fulfilled = true
                exp.fulfill()
            }
        }

        // Press Option + Left Arrow
        let handled = terminal.handleKeyShortcut(
            characters: "",
            charactersIgnoringModifiers: UIKeyCommand.inputLeftArrow,
            modifierFlags: .alternate,
            keyCode: .keyboardLeftArrow
        )
        XCTAssertTrue(handled)
        XCTAssertEqual(delegate.sentData.count, 1)
        XCTAssertEqual(delegate.sentData.first, [0x1b, 0x62], "Initial press must send Esc-b immediately")
        XCTAssertNotNil(terminal.modifierKeyRepeatTimer, "Repeat timer must be scheduled")
        XCTAssertEqual(terminal.activeRepeatKeyCode, .keyboardLeftArrow)

        wait(for: [exp], timeout: 2.0)

        XCTAssertGreaterThan(delegate.sentData.count, 2, "Timer must fire repeated Esc-b sequences")
        for data in delegate.sentData {
            XCTAssertEqual(data, [0x1b, 0x62], "All repeats must be Esc-b")
        }

        // Release the left arrow key — repeat must stop immediately
        terminal.handleHardwarePressesEnded(releasedCodes: [.keyboardLeftArrow])
        XCTAssertNil(terminal.modifierKeyRepeatTimer, "Releasing arrow key must invalidate repeat timer")
        XCTAssertNil(terminal.activeRepeatKeyCode)

        let countAfterRelease = delegate.sentData.count
        let exp2 = expectation(description: "Verify timer stopped")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            exp2.fulfill()
        }
        wait(for: [exp2], timeout: 1.0)

        XCTAssertEqual(delegate.sentData.count, countAfterRelease, "No further repetitions after arrow key release")
    }

    @MainActor
    func testOptionRightArrowKeyRepeatAndResignFirstResponder() {
        final class MockDelegate: TerminalViewDelegate {
            var sentData: [[UInt8]] = []
            var onSend: (() -> Void)?
            func send(source: TerminalView, data: ArraySlice<UInt8>) {
                sentData.append(Array(data))
                onSend?()
            }
            func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
            func setTerminalTitle(source: TerminalView, title: String) {}
            func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
            func scrolled(source: TerminalView, position: Double) {}
            func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
            func bell(source: TerminalView) {}
            func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        }

        let terminal = FilaireTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = MockDelegate()
        terminal.terminalDelegate = delegate

        terminal.modifierKeyRepeatInitialDelay = 0.04
        terminal.modifierKeyRepeatInterval = 0.02

        // Wait for repeat ticks
        let exp = expectation(description: "Wait for repeat timer ticks")
        var fulfilled = false
        delegate.onSend = {
            if !fulfilled && delegate.sentData.count > 2 {
                fulfilled = true
                exp.fulfill()
            }
        }

        // Press Option + Right Arrow
        let handled = terminal.handleKeyShortcut(
            characters: "",
            charactersIgnoringModifiers: UIKeyCommand.inputRightArrow,
            modifierFlags: .alternate,
            keyCode: .keyboardRightArrow
        )
        XCTAssertTrue(handled)
        XCTAssertEqual(delegate.sentData.first, [0x1b, 0x66], "Initial press must send Esc-f immediately")
        XCTAssertNotNil(terminal.modifierKeyRepeatTimer)

        wait(for: [exp], timeout: 2.0)

        XCTAssertGreaterThan(delegate.sentData.count, 2, "Timer must fire repeated Esc-f sequences")
        for data in delegate.sentData {
            XCTAssertEqual(data, [0x1b, 0x66], "All repeats must be Esc-f")
        }

        // Resigning first responder should stop repeat
        _ = terminal.resignFirstResponder()
        XCTAssertNil(terminal.modifierKeyRepeatTimer, "Resigning first responder must stop repeat timer")
        XCTAssertNil(terminal.activeRepeatKeyCode)
    }

    @MainActor
    func testOptionModifierReleaseStopsRepeatImmediately() {
        let terminal = FilaireTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        terminal.modifierKeyRepeatInitialDelay = 0.5

        // Start repeat with Option + Left Arrow
        _ = terminal.handleKeyShortcut(
            characters: "",
            charactersIgnoringModifiers: UIKeyCommand.inputLeftArrow,
            modifierFlags: .alternate,
            keyCode: .keyboardLeftArrow
        )
        XCTAssertNotNil(terminal.modifierKeyRepeatTimer)
        XCTAssertEqual(terminal.activeRepeatKeyCode, .keyboardLeftArrow)

        // Releasing left Option key stops repeat immediately
        terminal.handleHardwarePressesEnded(releasedCodes: [.keyboardLeftAlt])
        XCTAssertNil(terminal.modifierKeyRepeatTimer, "Releasing left Option modifier must stop repeat immediately")
        XCTAssertNil(terminal.activeRepeatKeyCode)

        // Start repeat with Option + Right Arrow
        _ = terminal.handleKeyShortcut(
            characters: "",
            charactersIgnoringModifiers: UIKeyCommand.inputRightArrow,
            modifierFlags: .alternate,
            keyCode: .keyboardRightArrow
        )
        XCTAssertNotNil(terminal.modifierKeyRepeatTimer)

        // Releasing right Option key stops repeat immediately
        terminal.handleHardwarePressesEnded(releasedCodes: [.keyboardRightAlt])
        XCTAssertNil(terminal.modifierKeyRepeatTimer, "Releasing right Option modifier must stop repeat immediately")
        XCTAssertNil(terminal.activeRepeatKeyCode)
    }

    @MainActor
    func testUnrelatedKeyReleaseDoesNotStopRepeat() {
        let terminal = FilaireTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        terminal.modifierKeyRepeatInitialDelay = 0.5

        // Start repeat with Option + Left Arrow
        _ = terminal.handleKeyShortcut(
            characters: "",
            charactersIgnoringModifiers: UIKeyCommand.inputLeftArrow,
            modifierFlags: .alternate,
            keyCode: .keyboardLeftArrow
        )
        XCTAssertNotNil(terminal.modifierKeyRepeatTimer)

        // Releasing an unrelated key (e.g. 'A') must NOT stop repeat
        terminal.handleHardwarePressesEnded(releasedCodes: [.keyboardA])
        XCTAssertNotNil(terminal.modifierKeyRepeatTimer, "Releasing unrelated key must not stop repeat")

        // But releasing the arrow key stops it
        terminal.handleHardwarePressesEnded(releasedCodes: [.keyboardLeftArrow])
        XCTAssertNil(terminal.modifierKeyRepeatTimer, "Releasing arrow key must stop repeat")
    }

    @MainActor
    func testOptionArrowRepeatCancelledByDifferentKey() {
        let terminal = FilaireTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        terminal.modifierKeyRepeatInitialDelay = 0.5

        // Start repeat with Option + Left Arrow
        _ = terminal.handleKeyShortcut(
            characters: "",
            charactersIgnoringModifiers: UIKeyCommand.inputLeftArrow,
            modifierFlags: .alternate,
            keyCode: .keyboardLeftArrow
        )
        XCTAssertNotNil(terminal.modifierKeyRepeatTimer)

        // Pressing another shortcut (e.g. Cmd+K) cancels repeat
        terminal.stopModifierKeyRepeat()
        XCTAssertNil(terminal.modifierKeyRepeatTimer, "Pressing another key must cancel repeat")
    }

    @MainActor
    func testOptionDeleteKeyRepeat() {
        final class MockDelegate: TerminalViewDelegate {
            var sentData: [[UInt8]] = []
            var onSend: (() -> Void)?
            func send(source: TerminalView, data: ArraySlice<UInt8>) {
                sentData.append(Array(data))
                onSend?()
            }
            func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
            func setTerminalTitle(source: TerminalView, title: String) {}
            func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
            func scrolled(source: TerminalView, position: Double) {}
            func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
            func bell(source: TerminalView) {}
            func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        }

        let terminal = FilaireTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = MockDelegate()
        terminal.terminalDelegate = delegate

        terminal.modifierKeyRepeatInitialDelay = 0.04
        terminal.modifierKeyRepeatInterval = 0.02

        // Wait for repeat ticks
        let exp = expectation(description: "Wait for repeat timer ticks")
        var fulfilled = false
        delegate.onSend = {
            if !fulfilled && delegate.sentData.count > 2 {
                fulfilled = true
                exp.fulfill()
            }
        }

        // Press Option + Delete (backward word delete)
        let handled = terminal.handleKeyShortcut(
            characters: "",
            charactersIgnoringModifiers: "\u{7f}",
            modifierFlags: .alternate,
            keyCode: .keyboardDeleteOrBackspace
        )
        XCTAssertTrue(handled)
        XCTAssertEqual(delegate.sentData.first, [0x1b, 0x7f], "Initial press must send Esc-DEL immediately")
        XCTAssertNotNil(terminal.modifierKeyRepeatTimer)
        XCTAssertEqual(terminal.activeRepeatKeyCode, .keyboardDeleteOrBackspace)

        wait(for: [exp], timeout: 2.0)

        XCTAssertGreaterThan(delegate.sentData.count, 2, "Timer must fire repeated Esc-DEL sequences")
        for data in delegate.sentData {
            XCTAssertEqual(data, [0x1b, 0x7f], "All repeats must be Esc-DEL")
        }

        // Release delete key — repeat must stop immediately
        terminal.handleHardwarePressesEnded(releasedCodes: [.keyboardDeleteOrBackspace])
        XCTAssertNil(terminal.modifierKeyRepeatTimer, "Releasing delete key must stop repeat immediately")

        // Also test Option + Delete Forward
        let handled2 = terminal.handleKeyShortcut(
            characters: "",
            charactersIgnoringModifiers: "",
            modifierFlags: .alternate,
            keyCode: .keyboardDeleteForward
        )
        XCTAssertTrue(handled2)
        XCTAssertEqual(delegate.sentData.last, [0x1b, 0x64], "Opt+DelFwd must send Esc-d")
        XCTAssertEqual(terminal.activeRepeatKeyCode, .keyboardDeleteForward)

        // Release Option key — repeat must stop immediately
        terminal.handleHardwarePressesEnded(releasedCodes: [.keyboardLeftAlt])
        XCTAssertNil(terminal.modifierKeyRepeatTimer, "Releasing Option key must stop repeat immediately")
    }
}
