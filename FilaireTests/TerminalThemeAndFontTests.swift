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

final class TerminalThemeAndFontTests: XCTestCase {
    // MARK: - Solarized Dark Theme

    func testSolarizedDarkTheme() {
        XCTAssertEqual(SolarizedDarkTheme.ansiPalette.count, 16)

        // Base03 background: #002b36
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        SolarizedDarkTheme.terminalBackground.getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertEqual(round(r * 255), 0x00)
        XCTAssertEqual(round(g * 255), 0x2b)
        XCTAssertEqual(round(b * 255), 0x36)

        // Base0 foreground: #839496
        SolarizedDarkTheme.terminalForeground.getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertEqual(round(r * 255), 0x83)
        XCTAssertEqual(round(g * 255), 0x94)
        XCTAssertEqual(round(b * 255), 0x96)
    }


    // MARK: - Font Manager & Sizing

    func testFontManager() {
        let manager = FontManager.shared

        // Verify size clamping
        manager.fontSize = 5.0
        XCTAssertEqual(manager.fontSize, 9.0)

        manager.fontSize = 50.0
        XCTAssertEqual(manager.fontSize, 32.0)

        manager.fontSize = 14.0
        XCTAssertEqual(manager.fontSize, 14.0)

        // Verify font construction does not crash and returns non-nil font
        let font = manager.makeFont(family: .systemMono, size: 14.0)
        XCTAssertEqual(font.pointSize, 14.0)

        let nerd = manager.makeFont(family: .nerdFont, size: 14.0)
        XCTAssertEqual(nerd.pointSize, 14.0)

        // Verify defaultFontSize and resetFontSize()
        let defaultSize = manager.defaultFontSize
        XCTAssertTrue(defaultSize == 13.0 || defaultSize == 15.0)
        manager.fontSize = 24.0
        XCTAssertEqual(manager.fontSize, 24.0)
        manager.resetFontSize()
        XCTAssertEqual(manager.fontSize, defaultSize)
    }


    // MARK: - Theme Manager & Themes

    @MainActor
    func testThemeManagerAndThemes() {
        let themes: [TerminalThemeType] = [.solarizedDark, .solarizedLight, .dracula, .nord, .monokai]
        XCTAssertEqual(TerminalThemeType.allCases.count, 5)

        for themeType in themes {
            let theme = ThemeManager.theme(for: themeType)
            XCTAssertEqual(theme.ansiPalette.count, 16, "\(theme.name) must have 16 ANSI colors")
            XCTAssertNotNil(theme.background)
            XCTAssertNotNil(theme.foreground)
            XCTAssertNotNil(theme.cursor)
            XCTAssertNotNil(theme.selection)
        }

        // Verify ThemeManager switching
        ThemeManager.shared.selectedThemeType = .dracula
        XCTAssertEqual(ThemeManager.shared.currentTheme.name, "Dracula")

        ThemeManager.shared.selectedThemeType = .solarizedDark
        XCTAssertEqual(ThemeManager.shared.currentTheme.name, "Solarized Dark")
    }


    // MARK: - Build Version & Commit Hash Debugging Tests

    func testCommitHashResolution() {
        // Case 1: Full 40-character commit hash provided directly
        let fullCommit = "210bd35103a2b4f33531698c97ca3f7165ac2044"
        XCTAssertEqual(
            HostListView.resolveCommitHash(gitCommit: fullCommit, buildNumber: "260908.1348.8459"),
            fullCommit
        )

        // Case 2: Dirty commit hash
        let dirtyCommit = "210bd35103a2b4f33531698c97ca3f7165ac2044-dirty"
        XCTAssertEqual(
            HostListView.resolveCommitHash(gitCommit: dirtyCommit, buildNumber: "260908.1348.8459"),
            dirtyCommit
        )

        // Case 3: GitCommit is missing/empty, but buildNumber contains 3rd segment decimal (8459 == 0x210b)
        XCTAssertEqual(
            HostListView.resolveCommitHash(gitCommit: "", buildNumber: "260908.1348.8459"),
            "210b"
        )
        XCTAssertEqual(
            HostListView.resolveCommitHash(gitCommit: nil, buildNumber: "260908.1348.8459"),
            "210b"
        )

        // Case 4: Unexpanded template string "$(GIT_COMMIT)" falls back to 3rd segment
        XCTAssertEqual(
            HostListView.resolveCommitHash(gitCommit: "$(GIT_COMMIT)", buildNumber: "260908.1348.8459"),
            "210b"
        )

        // Case 5: Missing GitCommit and no 3rd segment in buildNumber -> "local"
        XCTAssertEqual(
            HostListView.resolveCommitHash(gitCommit: nil, buildNumber: nil),
            "local"
        )
        XCTAssertEqual(
            HostListView.resolveCommitHash(gitCommit: "", buildNumber: ""),
            "local"
        )
        XCTAssertEqual(
            HostListView.resolveCommitHash(gitCommit: "local", buildNumber: "0.0"),
            "local"
        )
    }

    func testCommitHashHexDecimalRoundTrip() {
        // Test first 4 hex digits converted to decimal and recovered
        let originalHex = "210b"
        guard let decimalValue = Int(originalHex, radix: 16) else {
            XCTFail("Failed to parse hex string as integer")
            return
        }
        XCTAssertEqual(decimalValue, 8459)

        let recoveredHex = String(format: "%04x", decimalValue)
        XCTAssertEqual(recoveredHex, originalHex)
    }

    func testBuildNumberLengthConstraint() {
        // Format: YYmmDD.HHMM.<hash>
        // YYmmDD is 6 chars, HHMM is 4 chars.
        // Timestamp prefix: 6 + 1 + 4 + 1 = 12 chars ("260908.1348.")
        let sampleDatePrefix = "260908.1348"

        // Exhaustive boundary test: 0x0000 (0) to 0xFFFF (65535)
        let minDec = 0
        let maxDec = 0xFFFF // 65535 (5 digits)

        let minBuild = "\(sampleDatePrefix).\(minDec)"
        let maxBuild = "\(sampleDatePrefix).\(maxDec)"

        XCTAssertLessThanOrEqual(minBuild.count, 18, "Build number '\(minBuild)' must be <= 18 chars")
        XCTAssertLessThanOrEqual(maxBuild.count, 18, "Build number '\(maxBuild)' must be <= 18 chars")
        XCTAssertEqual(minBuild.count, 13) // "260908.1348.0"
        XCTAssertEqual(maxBuild.count, 17) // "260908.1348.65535"
    }

    func testBuildNumberZeroPadding() {
        // Case 1: 3-digit middle component (e.g. 9:20am -> "920") padded to 4 digits ("0920")
        XCTAssertEqual(HostListView.formatBuildNumber("260908.920.8459"), "260908.0920.8459")
        XCTAssertEqual(HostListView.formatBuildNumber("x.920.y"), "x.0920.y")

        // Case 2: 1-digit middle component (e.g. 12:05am -> "5") padded to 4 digits ("0005")
        XCTAssertEqual(HostListView.formatBuildNumber("260908.5.8459"), "260908.0005.8459")

        // Case 3: 2-digit middle component (e.g. 12:45am -> "45") padded to 4 digits ("0045")
        XCTAssertEqual(HostListView.formatBuildNumber("260908.45.8459"), "260908.0045.8459")

        // Case 4: 0 middle component (e.g. 12:00am -> "0") padded to 4 digits ("0000")
        XCTAssertEqual(HostListView.formatBuildNumber("260908.0.8459"), "260908.0000.8459")

        // Case 5: Already 4 digits (e.g. 1:48pm -> "1348", 9:20am pre-padded -> "0920")
        XCTAssertEqual(HostListView.formatBuildNumber("260908.1348.8459"), "260908.1348.8459")
        XCTAssertEqual(HostListView.formatBuildNumber("260908.0920.8459"), "260908.0920.8459")

        // Case 6: 2 components (e.g. "YYmmDD.HHMM")
        XCTAssertEqual(HostListView.formatBuildNumber("260908.920"), "260908.0920")

        // Case 7: Edge cases: nil, empty, single component, non-numeric
        XCTAssertEqual(HostListView.formatBuildNumber(nil), "")
        XCTAssertEqual(HostListView.formatBuildNumber(""), "")
        XCTAssertEqual(HostListView.formatBuildNumber("123"), "123")
        XCTAssertEqual(HostListView.formatBuildNumber("x.abc.y"), "x.abc.y")

        // Case 8: Verify commit hash resolution remains unaffected with padded build number
        XCTAssertEqual(
            HostListView.resolveCommitHash(gitCommit: "", buildNumber: "260908.920.8459"),
            "210b"
        )
        XCTAssertEqual(
            HostListView.resolveCommitHash(gitCommit: "", buildNumber: "260908.0920.8459"),
            "210b"
        )
    }

    @MainActor
    func testArrowKeyCommandCodes() {
        let terminalView = FilaireTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
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
        let delegate = MockDelegate()
        terminalView.terminalDelegate = delegate

        terminalView.handleArrowKeyCommand(UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(FilaireTerminalView.handleArrowKeyCommand(_:))))
        XCTAssertEqual(delegate.sentData.last, [0x1b, 0x5b, 0x41], "Up arrow must emit ESC [ A")

        terminalView.handleArrowKeyCommand(UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(FilaireTerminalView.handleArrowKeyCommand(_:))))
        XCTAssertEqual(delegate.sentData.last, [0x1b, 0x5b, 0x42], "Down arrow must emit ESC [ B")

        terminalView.handleArrowKeyCommand(UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(FilaireTerminalView.handleArrowKeyCommand(_:))))
        XCTAssertEqual(delegate.sentData.last, [0x1b, 0x5b, 0x44], "Left arrow must emit ESC [ D")

        terminalView.handleArrowKeyCommand(UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(FilaireTerminalView.handleArrowKeyCommand(_:))))
        XCTAssertEqual(delegate.sentData.last, [0x1b, 0x5b, 0x43], "Right arrow must emit ESC [ C")

        // Extended Navigation Keys
        terminalView.handleNavigationKeyCommand(UIKeyCommand(input: UIKeyCommand.inputHome, modifierFlags: [], action: #selector(FilaireTerminalView.handleNavigationKeyCommand(_:))))
        XCTAssertEqual(delegate.sentData.last, [0x1b, 0x5b, 0x48], "Home must emit ESC [ H")

        terminalView.handleNavigationKeyCommand(UIKeyCommand(input: UIKeyCommand.inputEnd, modifierFlags: [], action: #selector(FilaireTerminalView.handleNavigationKeyCommand(_:))))
        XCTAssertEqual(delegate.sentData.last, [0x1b, 0x5b, 0x46], "End must emit ESC [ F")

        terminalView.handleNavigationKeyCommand(UIKeyCommand(input: UIKeyCommand.inputPageUp, modifierFlags: [], action: #selector(FilaireTerminalView.handleNavigationKeyCommand(_:))))
        XCTAssertEqual(delegate.sentData.last, [0x1b, 0x5b, 0x35, 0x7e], "PageUp must emit ESC [ 5 ~")

        terminalView.handleNavigationKeyCommand(UIKeyCommand(input: UIKeyCommand.inputPageDown, modifierFlags: [], action: #selector(FilaireTerminalView.handleNavigationKeyCommand(_:))))
        XCTAssertEqual(delegate.sentData.last, [0x1b, 0x5b, 0x36, 0x7e], "PageDown must emit ESC [ 6 ~")

        // Option / Cmd Word & Line Navigation Key Commands
        terminalView.handleNavigationKeyCommand(UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: .alternate, action: #selector(FilaireTerminalView.handleNavigationKeyCommand(_:))))
        XCTAssertEqual(delegate.sentData.last, [0x1b, 0x62], "Option+Left must emit ESC b")

        terminalView.handleNavigationKeyCommand(UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: .alternate, action: #selector(FilaireTerminalView.handleNavigationKeyCommand(_:))))
        XCTAssertEqual(delegate.sentData.last, [0x1b, 0x66], "Option+Right must emit ESC f")

        terminalView.handleNavigationKeyCommand(UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: .command, action: #selector(FilaireTerminalView.handleNavigationKeyCommand(_:))))
        XCTAssertEqual(delegate.sentData.last, [0x01], "Cmd+Left must emit Ctrl-A (0x01)")

        terminalView.handleNavigationKeyCommand(UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: .command, action: #selector(FilaireTerminalView.handleNavigationKeyCommand(_:))))
        XCTAssertEqual(delegate.sentData.last, [0x05], "Cmd+Right must emit Ctrl-E (0x05)")
    }

    @MainActor
    func testHardwareKeyEditingShortcuts() {
        let terminalView = FilaireTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        final class MockDelegate: NSObject, TerminalViewDelegate {
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
        let delegate = MockDelegate()
        terminalView.terminalDelegate = delegate

        // Option shortcuts (Word jumping & deletion)
        let handledOptLeft = terminalView.handleKeyShortcut(characters: "", charactersIgnoringModifiers: UIKeyCommand.inputLeftArrow, modifierFlags: .alternate, keyCode: .keyboardLeftArrow)
        XCTAssertTrue(handledOptLeft)
        XCTAssertEqual(delegate.sentData.last, [0x1b, 0x62], "Option+Left shortcut must emit ESC b")

        let handledOptRight = terminalView.handleKeyShortcut(characters: "", charactersIgnoringModifiers: UIKeyCommand.inputRightArrow, modifierFlags: .alternate, keyCode: .keyboardRightArrow)
        XCTAssertTrue(handledOptRight)
        XCTAssertEqual(delegate.sentData.last, [0x1b, 0x66], "Option+Right shortcut must emit ESC f")

        let handledOptBksp = terminalView.handleKeyShortcut(characters: "", charactersIgnoringModifiers: "\u{7f}", modifierFlags: .alternate, keyCode: .keyboardDeleteOrBackspace)
        XCTAssertTrue(handledOptBksp)
        XCTAssertEqual(delegate.sentData.last, [0x1b, 0x7f], "Option+Backspace shortcut must emit ESC DEL")

        let handledOptDelFwd = terminalView.handleKeyShortcut(characters: "", charactersIgnoringModifiers: "", modifierFlags: .alternate, keyCode: .keyboardDeleteForward)
        XCTAssertTrue(handledOptDelFwd)
        XCTAssertEqual(delegate.sentData.last, [0x1b, 0x64], "Option+DeleteForward shortcut must emit ESC d")

        // Cmd shortcuts (Line jumping & deletion)
        let handledCmdLeft = terminalView.handleKeyShortcut(characters: "", charactersIgnoringModifiers: UIKeyCommand.inputLeftArrow, modifierFlags: .command, keyCode: .keyboardLeftArrow)
        XCTAssertTrue(handledCmdLeft)
        XCTAssertEqual(delegate.sentData.last, [0x01], "Cmd+Left shortcut must emit Ctrl-A")

        let handledCmdRight = terminalView.handleKeyShortcut(characters: "", charactersIgnoringModifiers: UIKeyCommand.inputRightArrow, modifierFlags: .command, keyCode: .keyboardRightArrow)
        XCTAssertTrue(handledCmdRight)
        XCTAssertEqual(delegate.sentData.last, [0x05], "Cmd+Right shortcut must emit Ctrl-E")

        let handledCmdBksp = terminalView.handleKeyShortcut(characters: "", charactersIgnoringModifiers: "\u{7f}", modifierFlags: .command, keyCode: .keyboardDeleteOrBackspace)
        XCTAssertTrue(handledCmdBksp)
        XCTAssertEqual(delegate.sentData.last, [0x15], "Cmd+Backspace shortcut must emit Ctrl-U")

        let handledCmdDelFwd = terminalView.handleKeyShortcut(characters: "", charactersIgnoringModifiers: "", modifierFlags: .command, keyCode: .keyboardDeleteForward)
        XCTAssertTrue(handledCmdDelFwd)
        XCTAssertEqual(delegate.sentData.last, [0x0b], "Cmd+DeleteForward shortcut must emit Ctrl-K")

        // Cmd+Opt+Left (tmux pane navigation)
        terminalView.configureTmux(enabled: true, prefixTitle: "Ctrl-B", prefixByte: 0x02)
        let handledCmdOptLeft = terminalView.handleKeyShortcut(characters: "", charactersIgnoringModifiers: UIKeyCommand.inputLeftArrow, modifierFlags: [.command, .alternate], keyCode: .keyboardLeftArrow)
        XCTAssertTrue(handledCmdOptLeft)
        XCTAssertEqual(delegate.sentData.last, [0x02, 0x1b, 0x5b, 0x44], "Cmd+Opt+Left must emit tmux prefix + Left Arrow")
    }

    @MainActor
    func testPlainNavigationKeysPassThroughToSwiftTerm() {
        let terminalView = FilaireTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))

        // Plain arrow keys must NOT be consumed as custom shortcuts so they pass through to SwiftTerm
        let plainArrowKeys: [UIKeyboardHIDUsage] = [
            .keyboardUpArrow,
            .keyboardDownArrow,
            .keyboardLeftArrow,
            .keyboardRightArrow,
            .keyboardHome,
            .keyboardEnd,
            .keyboardPageUp,
            .keyboardPageDown,
            .keyboardDeleteForward
        ]

        for keyCode in plainArrowKeys {
            let handled = terminalView.handleKeyShortcut(
                characters: "",
                charactersIgnoringModifiers: "",
                modifierFlags: [],
                keyCode: keyCode
            )
            XCTAssertFalse(handled, "Plain key \(keyCode) must not be consumed by handleKeyShortcut so it flows to SwiftTerm super.pressesBegan")
        }
    }

    func testSSHServiceActivityTracking() async {
        let service = SSHService()
        // Fresh service with no activity in future threshold is not idle
        let isIdleImmediate = await service.isConnectionIdle(for: 10.0)
        XCTAssertFalse(isIdleImmediate, "Freshly created service must not be considered idle for a 10s window")

        // Send data to record activity
        try? await service.send(data: [0x41, 0x42])
        let isIdleAfterSend = await service.isConnectionIdle(for: 10.0)
        XCTAssertFalse(isIdleAfterSend, "Connection must not be idle immediately after sending data")
    }


    // MARK: - Terminal Bell Settings & Visual Flash

    @MainActor
    func testTerminalBellSettingsAndVisualBell() {
        let settings = TerminalSettings.shared
        let originalStyle = settings.bellStyle

        // Verify all enum cases and display names
        XCTAssertEqual(BellStyle.visualAndHaptic.rawValue, "Visual Flash & Haptic")
        XCTAssertEqual(BellStyle.visualOnly.rawValue, "Visual Flash Only")
        XCTAssertEqual(BellStyle.hapticOnly.rawValue, "Haptic Only")
        XCTAssertEqual(BellStyle.disabled.rawValue, "Disabled")

        settings.bellStyle = .visualOnly
        XCTAssertEqual(settings.bellStyle, .visualOnly)

        settings.bellStyle = .disabled
        XCTAssertEqual(settings.bellStyle, .disabled)

        // Restore original
        settings.bellStyle = originalStyle

        // Test FilaireTerminalView.triggerVisualBell execution
        let terminalView = FilaireTerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        terminalView.triggerVisualBell()

        // Test luminance detection for bell flash contrast
        XCTAssertTrue(FilaireTerminalView.isLightColor(UIColor.white))
        XCTAssertFalse(FilaireTerminalView.isLightColor(UIColor.black))
        XCTAssertTrue(FilaireTerminalView.isLightColor(SolarizedLightPalette().background))
        XCTAssertFalse(FilaireTerminalView.isLightColor(SolarizedDarkPalette().background))
    }



}
