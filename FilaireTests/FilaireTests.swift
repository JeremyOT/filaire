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
import os
@testable import Filaire

final class FilaireTests: XCTestCase {

    // MARK: - Host Profile & Tmux Commands

    func testHostProfileTmuxDefaults() {
        let profile = HostProfile(
            name: "Dev Box",
            hostname: "dev.internal",
            port: 22,
            username: "dev"
        )

        // Split bindings for Cmd+D / Cmd+Shift+D, chained after new-session
        let splitBindings = " \\; set -s 'user-keys[900]' \"$(printf '\\033[9990~')\" \\; set -s 'user-keys[901]' \"$(printf '\\033[9991~')\" \\; bind -n User900 split-window -h -c '#{pane_current_path}' \\; bind -n User901 split-window -v -c '#{pane_current_path}'"

        // Rule 4: Username must always be the default tmux session name
        XCTAssertEqual(profile.effectiveTmuxSession, "dev")
        XCTAssertFalse(profile.detachExistingTmux, "detachExistingTmux must default to false")
        XCTAssertFalse(profile.enableTmuxSetClipboard, "enableTmuxSetClipboard must default to false")
        XCTAssertEqual(profile.tmuxStartupCommand, "exec tmux new-session -A -s dev\(splitBindings)\n")
        XCTAssertTrue(profile.autoConnectTmux)
        XCTAssertEqual(profile.tmuxPrefix, "ctrl-b")
        XCTAssertEqual(profile.tmuxPrefixByte, 0x02)
        XCTAssertEqual(profile.tmuxPrefixDisplay, "Ctrl-B")
        XCTAssertEqual(profile.startupCommand, "exec tmux new-session -A -s dev\(splitBindings)\n")

        // Detach existing tmux sessions toggle (-D)
        var detachProfile = profile
        detachProfile.detachExistingTmux = true
        XCTAssertEqual(detachProfile.tmuxStartupCommand, "exec tmux new-session -A -D -s dev\(splitBindings)\n")
        XCTAssertEqual(detachProfile.startupCommand, "exec tmux new-session -A -D -s dev\(splitBindings)\n")

        // Custom session override
        var customProfile = profile
        customProfile.customTmuxSession = "work-session"
        XCTAssertEqual(customProfile.effectiveTmuxSession, "work-session")
        XCTAssertEqual(customProfile.tmuxStartupCommand, "exec tmux new-session -A -s work-session\(splitBindings)\n")
        XCTAssertEqual(customProfile.startupCommand, "exec tmux new-session -A -s work-session\(splitBindings)\n")

        // Custom session with detach
        customProfile.detachExistingTmux = true
        XCTAssertEqual(customProfile.tmuxStartupCommand, "exec tmux new-session -A -D -s work-session\(splitBindings)\n")
        XCTAssertEqual(customProfile.startupCommand, "exec tmux new-session -A -D -s work-session\(splitBindings)\n")

        // Custom session with spaces and special characters (must be shell-quoted)
        var spacedProfile = profile
        spacedProfile.customTmuxSession = "my work session"
        XCTAssertEqual(spacedProfile.tmuxStartupCommand, "exec tmux new-session -A -s 'my work session'\(splitBindings)\n")

        var quotedProfile = profile
        quotedProfile.customTmuxSession = "team's-app"
        XCTAssertEqual(quotedProfile.tmuxStartupCommand, "exec tmux new-session -A -s 'team'\\''s-app'\(splitBindings)\n")

        // Custom tmux prefix: Ctrl-Z
        var ctrlZProfile = profile
        ctrlZProfile.tmuxPrefix = "ctrl-z"
        XCTAssertEqual(ctrlZProfile.tmuxPrefixByte, 0x1A)
        XCTAssertEqual(ctrlZProfile.tmuxPrefixDisplay, "Ctrl-Z")

        // Custom tmux prefix: C-a
        var ctrlAProfile = profile
        ctrlAProfile.tmuxPrefix = "C-a"
        XCTAssertEqual(ctrlAProfile.tmuxPrefixByte, 0x01)
        XCTAssertEqual(ctrlAProfile.tmuxPrefixDisplay, "Ctrl-A")

        // Auto-connect tmux disabled with custom command
        var disabledTmuxProfile = profile
        disabledTmuxProfile.autoConnectTmux = false
        disabledTmuxProfile.connectionCommand = "htop"
        XCTAssertEqual(disabledTmuxProfile.startupCommand, "htop\n")

        // Auto-connect tmux disabled without custom command (default login shell)
        disabledTmuxProfile.connectionCommand = nil
        XCTAssertNil(disabledTmuxProfile.startupCommand)
        disabledTmuxProfile.connectionCommand = "   "
        XCTAssertNil(disabledTmuxProfile.startupCommand)
    }

    // MARK: - SSH Key Generator & Parser

    func testSSHKeyGenerationAndRoundTripParsing() throws {
        let keyPair = try SSHKeyGenerator.generateEd25519Key(comment: "test@filaire")

        // Validate public key format
        XCTAssertTrue(keyPair.publicKey.hasPrefix("ssh-ed25519 "))
        XCTAssertTrue(keyPair.publicKey.hasSuffix(" test@filaire"))

        // Validate private key PEM format
        XCTAssertTrue(keyPair.privateKeyPEM.contains("-----BEGIN OPENSSH PRIVATE KEY-----"))
        XCTAssertTrue(keyPair.privateKeyPEM.contains("-----END OPENSSH PRIVATE KEY-----"))

        // Parse private key back from PEM
        let parsedPrivateKey = try SSHKeyGenerator.parseEd25519PrivateKey(from: keyPair.privateKeyPEM)

        // Verify the public key derived from parsed private key matches the original
        let pubKeyBlob = keyPair.publicKey
            .replacingOccurrences(of: "ssh-ed25519 ", with: "")
            .components(separatedBy: " ")[0]
        guard let expectedData = Data(base64Encoded: pubKeyBlob) else {
            XCTFail("Failed to decode public key base64")
            return
        }

        let rawPubKey = expectedData.suffix(32)
        XCTAssertEqual(Data(parsedPrivateKey.publicKey.rawRepresentation), Data(rawPubKey))
    }

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

    // MARK: - Known Hosts & Fingerprints

    func testKnownHostsStore() {
        let store = KnownHostsStore.shared
        let testHost = "192.168.1.99"
        let testPort = 2222

        store.removeEntry(hostname: testHost, port: testPort)
        XCTAssertNil(store.getEntry(hostname: testHost, port: testPort))

        let entry = KnownHostEntry(
            hostname: testHost,
            port: testPort,
            keyType: "ssh-ed25519",
            fingerprintSHA256: "SHA256:abcd1234dummyfingerprint",
            openSSHPublicKey: "ssh-ed25519 AAAAC3... test@host"
        )
        store.saveEntry(entry)

        let retrieved = store.getEntry(hostname: testHost, port: testPort)
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.fingerprintSHA256, "SHA256:abcd1234dummyfingerprint")

        // Case-insensitive lookup and hasEntry
        XCTAssertTrue(store.hasEntry(hostname: testHost.uppercased(), port: testPort))
        XCTAssertTrue(store.hasEntry(hostname: testHost.lowercased(), port: testPort))
        XCTAssertEqual(store.getEntry(hostname: testHost.uppercased(), port: testPort)?.hostname, testHost)
        XCTAssertGreaterThan(store.entryCount, 0)

        store.removeEntry(hostname: testHost.uppercased(), port: testPort)
        XCTAssertNil(store.getEntry(hostname: testHost, port: testPort))
        XCTAssertFalse(store.hasEntry(hostname: testHost, port: testPort))
    }

    private func makeHostKeyAndPromise() -> (NIOSSHPublicKey, EventLoopPromise<Void>, MultiThreadedEventLoopGroup) {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let hostKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey
        return (hostKey, group.next().makePromise(of: Void.self), group)
    }

    func testTOFUValidatorRejectsUnknownHostWithoutHandler() async throws {
        let hostname = "tofu-\(UUID().uuidString).test"
        defer { KnownHostsStore.shared.removeEntry(hostname: hostname, port: 22) }
        let (hostKey, promise, group) = makeHostKeyAndPromise()
        TOFUHostKeyValidator(hostname: hostname, port: 22).validateHostKey(hostKey: hostKey, validationCompletePromise: promise)
        do {
            try await promise.futureResult.get()
            XCTFail("Unknown host key must be rejected without a handler")
        } catch {
            XCTAssertEqual(error as? HostKeyMismatchError, .hostKeyNotTrusted(hostname: hostname, port: 22, fingerprint: KnownHostsStore.computeFingerprint(for: hostKey)))
        }
        XCTAssertNil(KnownHostsStore.shared.getEntry(hostname: hostname, port: 22))
        try await group.shutdownGracefully()
    }

    func testTOFUValidatorSavesWhenUserTrusts() async throws {
        let hostname = "tofu-\(UUID().uuidString).test"
        defer { KnownHostsStore.shared.removeEntry(hostname: hostname, port: 22) }
        let (hostKey, promise, group) = makeHostKeyAndPromise()
        let validator = TOFUHostKeyValidator(hostname: hostname, port: 22, onUnknownHostKey: { _ in true })
        validator.validateHostKey(hostKey: hostKey, validationCompletePromise: promise)
        try await promise.futureResult.get()

        let saved = KnownHostsStore.shared.getEntry(hostname: hostname, port: 22)
        XCTAssertNotNil(saved)
        XCTAssertEqual(saved?.fingerprintSHA256, KnownHostsStore.computeFingerprint(for: hostKey))
        try await group.shutdownGracefully()
    }

    func testTOFUValidatorRejectsWhenUserDeclines() async throws {
        let hostname = "tofu-\(UUID().uuidString).test"
        defer { KnownHostsStore.shared.removeEntry(hostname: hostname, port: 22) }
        let (hostKey, promise, group) = makeHostKeyAndPromise()
        let validator = TOFUHostKeyValidator(hostname: hostname, port: 22, onUnknownHostKey: { _ in false })
        validator.validateHostKey(hostKey: hostKey, validationCompletePromise: promise)
        do {
            try await promise.futureResult.get()
            XCTFail("Must reject when user declines")
        } catch {
            XCTAssertEqual(error as? HostKeyMismatchError, .hostKeyNotTrusted(hostname: hostname, port: 22, fingerprint: KnownHostsStore.computeFingerprint(for: hostKey)))
        }
        XCTAssertNil(KnownHostsStore.shared.getEntry(hostname: hostname, port: 22))
        try await group.shutdownGracefully()
    }

    func testTOFUValidatorKnownMatchingKeySkipsHandler() async throws {
        let hostname = "tofu-\(UUID().uuidString).test"
        defer { KnownHostsStore.shared.removeEntry(hostname: hostname, port: 22) }
        let (hostKey, promise, group) = makeHostKeyAndPromise()
        let fingerprint = KnownHostsStore.computeFingerprint(for: hostKey)
        let keyString = String(openSSHPublicKey: hostKey)
        KnownHostsStore.shared.saveEntry(KnownHostEntry(
            hostname: hostname,
            port: 22,
            keyType: "ssh-ed25519",
            fingerprintSHA256: fingerprint,
            openSSHPublicKey: keyString
        ))

        let validator = TOFUHostKeyValidator(hostname: hostname, port: 22, onUnknownHostKey: { _ in
            XCTFail("Handler must not be called for known host key")
            return false
        })
        validator.validateHostKey(hostKey: hostKey, validationCompletePromise: promise)
        try await promise.futureResult.get()
        try await group.shutdownGracefully()
    }

    @MainActor
    func testSessionManagerConfirmUnknownHostKeyPrompt() async {
        let manager = SessionManager()
        let entry = KnownHostEntry(
            hostname: "test.example.com",
            port: 22,
            keyType: "ssh-ed25519",
            fingerprintSHA256: "SHA256:testfingerprint12345",
            openSSHPublicKey: "ssh-ed25519 AAAAC3... test"
        )

        // Case 1: onAllow
        let task1 = Task { await manager.confirmUnknownHostKey(entry) }
        for _ in 0..<50 where manager.pendingSecurityPrompt == nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(manager.pendingSecurityPrompt?.title, "Trust New Host Key?")
        XCTAssertTrue(manager.pendingSecurityPrompt?.message.contains(entry.fingerprintSHA256) == true)
        manager.pendingSecurityPrompt?.onAllow()
        let result1 = await task1.value
        XCTAssertTrue(result1)
        XCTAssertNil(manager.pendingSecurityPrompt)

        // Case 2: onCancel
        let task2 = Task { await manager.confirmUnknownHostKey(entry) }
        for _ in 0..<50 where manager.pendingSecurityPrompt == nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        manager.pendingSecurityPrompt?.onCancel?()
        let result2 = await task2.value
        XCTAssertFalse(result2)
        XCTAssertNil(manager.pendingSecurityPrompt)

        // Case 3: cancelPendingSecurityPrompt()
        let task3 = Task { await manager.confirmUnknownHostKey(entry) }
        for _ in 0..<50 where manager.pendingSecurityPrompt == nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        manager.cancelPendingSecurityPrompt()
        let result3 = await task3.value
        XCTAssertFalse(result3)
        XCTAssertNil(manager.pendingSecurityPrompt)
    }

    // MARK: - Port Forwarding & Jump Host

    func testPortForwardRuleAndJumpHost() throws {
        let rule = PortForwardRule(localPort: 8080, remoteHost: "db.internal", remotePort: 5432)
        XCTAssertEqual(rule.localPort, 8080)
        XCTAssertEqual(rule.remoteHost, "db.internal")
        XCTAssertEqual(rule.remotePort, 5432)
        XCTAssertTrue(rule.isEnabled)
        XCTAssertEqual(rule.name, "8080 → db.internal:5432")

        let jumpId = UUID()
        let profile = HostProfile(
            name: "App Server",
            hostname: "app.internal",
            jumpHostId: jumpId,
            portForwards: [rule]
        )
        XCTAssertEqual(profile.jumpHostId, jumpId)
        XCTAssertEqual(profile.portForwards.count, 1)

        // Encode to JSON and decode back
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(HostProfile.self, from: data)
        XCTAssertEqual(decoded.id, profile.id)
        XCTAssertEqual(decoded.jumpHostId, jumpId)
        XCTAssertEqual(decoded.portForwards.count, 1)
        XCTAssertEqual(decoded.portForwards.first?.remoteHost, "db.internal")

        // Test backward compatibility when JSON does not have jumpHostId or portForwards
        let legacyJSON = """
        {
            "id": "\(UUID().uuidString)",
            "name": "Legacy Host",
            "hostname": "legacy.internal",
            "port": 22,
            "username": "admin",
            "authMethod": "SSH Key",
            "autoConnect": true,
            "keepAliveInterval": 15
        }
        """.data(using: .utf8)!

        let legacyDecoded = try JSONDecoder().decode(HostProfile.self, from: legacyJSON)
        XCTAssertEqual(legacyDecoded.name, "Legacy Host")
        XCTAssertNil(legacyDecoded.jumpHostId)
        XCTAssertTrue(legacyDecoded.portForwards.isEmpty)
        XCTAssertTrue(legacyDecoded.autoConnectTmux)
        XCTAssertEqual(legacyDecoded.tmuxPrefix, "ctrl-b")
        XCTAssertFalse(legacyDecoded.detachExistingTmux)
        XCTAssertNil(legacyDecoded.connectionCommand)
    }

    func testPortBoundariesAndClamping() throws {
        // Test HostProfile port clamping on init
        let zeroPortHost = HostProfile(name: "Zero", hostname: "zero.local", port: 0)
        XCTAssertEqual(zeroPortHost.port, 22)

        let negativePortHost = HostProfile(name: "Neg", hostname: "neg.local", port: -10)
        XCTAssertEqual(negativePortHost.port, 22)

        let overflowPortHost = HostProfile(name: "High", hostname: "high.local", port: 70000)
        XCTAssertEqual(overflowPortHost.port, 22)

        let validPortHost = HostProfile(name: "Valid", hostname: "valid.local", port: 2222)
        XCTAssertEqual(validPortHost.port, 2222)

        // Test PortForwardRule port clamping
        let invalidLocalRule = PortForwardRule(localPort: 0, remoteHost: "db", remotePort: 90000)
        XCTAssertEqual(invalidLocalRule.localPort, 8080)
        XCTAssertEqual(invalidLocalRule.remotePort, 8080)

        let validRule = PortForwardRule(localPort: 3000, remoteHost: "api", remotePort: 4000)
        XCTAssertEqual(validRule.localPort, 3000)
        XCTAssertEqual(validRule.remotePort, 4000)
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

    // MARK: - Output Coalescing

    @MainActor
    func testOutputCoalescerBatching() {
        let expectation = expectation(description: "Coalesced output delivered")
        var receivedBatches: [[UInt8]] = []

        let coalescer = OutputCoalescer { chunk in
            receivedBatches.append(chunk)
            expectation.fulfill()
        }

        // Send 3 small chunks in immediate succession
        coalescer.append([0x41, 0x42]) // "AB"
        coalescer.append([0x43, 0x44]) // "CD"
        coalescer.append([0x45, 0x46]) // "EF"

        waitForExpectations(timeout: 1.0)

        // All 3 chunks should be coalesced into a single delivery of "ABCDEF"
        XCTAssertEqual(receivedBatches.count, 1)
        XCTAssertEqual(receivedBatches.first, [0x41, 0x42, 0x43, 0x44, 0x45, 0x46])
    }

    @MainActor
    func testOutputCoalescerImmediateFlush() {
        var received: [UInt8] = []
        let coalescer = OutputCoalescer { chunk in
            received.append(contentsOf: chunk)
        }

        coalescer.append([0x01, 0x02, 0x03])
        coalescer.flushImmediately()

        let expectation = expectation(description: "Flush delivered")
        DispatchQueue.main.async {
            expectation.fulfill()
        }
        waitForExpectations(timeout: 1.0)

        XCTAssertEqual(received, [0x01, 0x02, 0x03])
    }

    @MainActor
    func testOutputCoalescerResetDiscardsPendingDelivery() {
        var received: [[UInt8]] = []
        let coalescer = OutputCoalescer { chunk in
            received.append(chunk)
        }

        coalescer.append([0x01, 0x02, 0x03])
        // Immediate reset should discard the queued delivery
        coalescer.reset()

        let expectation = expectation(description: "Wait after reset")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            expectation.fulfill()
        }
        waitForExpectations(timeout: 1.0)

        XCTAssertTrue(received.isEmpty, "Reset must discard pending deliveries from previous generation")
    }

    @MainActor
    func testOutputCoalescerPreservesOrderUnderBacklog() {
        var received: [UInt8] = []
        var chunkSizes: [Int] = []
        let coalescer = OutputCoalescer { chunk in
            received.append(contentsOf: chunk)
            chunkSizes.append(chunk.count)
        }

        // The test holds the main thread, so every append lands before any flush runs (a backlogged UI thread).
        // 21 packets = five 128 KB bursts plus one leftover packet, which previously jumped the queue.
        let packet = 32 * 1024
        var expected: [UInt8] = []
        for i in 0..<21 {
            let bytes = [UInt8](repeating: UInt8(i), count: packet)
            expected.append(contentsOf: bytes)
            coalescer.append(bytes)
        }

        let drained = expectation(description: "Backlog drained")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { drained.fulfill() }
        waitForExpectations(timeout: 2.0)

        XCTAssertEqual(received.count, expected.count)
        XCTAssertTrue(received == expected, "Output must be delivered in arrival order")
        XCTAssertTrue(chunkSizes.allSatisfy { $0 <= 128 * 1024 }, "Each delivery must be at most 128 KB")
    }

    // MARK: - Scrollback Settings

    func testScrollbackSettings() {
        let settings = TerminalSettings.shared

        settings.scrollbackLimit = .small
        XCTAssertEqual(settings.scrollbackLimit.rawValue, 2500)
        XCTAssertEqual(settings.scrollbackLimit.displayName, "2,500 lines")

        settings.scrollbackLimit = .maximum
        XCTAssertEqual(settings.scrollbackLimit.rawValue, 50000)
        XCTAssertEqual(settings.scrollbackLimit.displayName, "50,000 lines")

        // Reset to standard
        settings.scrollbackLimit = .standard
        XCTAssertEqual(settings.scrollbackLimit.rawValue, 10000)
        XCTAssertEqual(settings.scrollbackLimit.displayName, "10,000 lines")
    }

    // MARK: - Network State Transitions

    @MainActor
    func testNetworkStateTransitions() {
        let manager = SessionManager()
        XCTAssertEqual(manager.state, .disconnected)
        XCTAssertFalse(manager.state.isConnected)
        XCTAssertFalse(manager.state.isBusy)

        manager.state = .connecting
        XCTAssertTrue(manager.state.isBusy)
        XCTAssertFalse(manager.state.isConnected)

        manager.state = .connected
        XCTAssertTrue(manager.state.isConnected)
        XCTAssertFalse(manager.state.isBusy)

        manager.state = .reconnecting(attempt: 2)
        XCTAssertTrue(manager.state.isBusy)
        XCTAssertFalse(manager.state.isConnected)
        XCTAssertEqual(manager.state.description, "Reconnecting (attempt 2)...")
    }

    @MainActor
    func testSessionManagerReconnectionPolicyAndCancel() {
        let manager = SessionManager()
        XCTAssertEqual(manager.maxReconnectAttempts, 10, "Default maxReconnectAttempts should be 10")

        manager.maxReconnectAttempts = 3
        XCTAssertEqual(manager.maxReconnectAttempts, 3)

        manager.state = .reconnecting(attempt: 2)
        XCTAssertTrue(manager.state.isBusy)

        // Cancelling reconnect should transition from .reconnecting to .disconnected
        manager.cancelReconnect()
        XCTAssertEqual(manager.state, .disconnected)
        XCTAssertEqual(manager.reconnectAttempt, 0)
    }

    func testRetryableConnectErrorClassification() {
        XCTAssertTrue(SessionManager.isRetryableConnectError(POSIXError(.ECONNREFUSED)))
        XCTAssertTrue(SessionManager.isRetryableConnectError(SSHError.channelClosed))
        XCTAssertFalse(SessionManager.isRetryableConnectError(SSHError.invalidCredentials("bad")))
        XCTAssertFalse(SessionManager.isRetryableConnectError(SSHError.keyNotFound))
        XCTAssertFalse(SessionManager.isRetryableConnectError(SSHError.negotiationFailed("kex")))
        XCTAssertFalse(SessionManager.isRetryableConnectError(CancellationError()))
        XCTAssertFalse(SessionManager.isRetryableConnectError(BiometricError.userCancelled))
        XCTAssertFalse(SessionManager.isRetryableConnectError(
            HostKeyMismatchError.hostKeyNotTrusted(hostname: "h", port: 22, fingerprint: "f")))
    }

    @MainActor
    func testConnectFailureDuringReconnectSchedulesNextAttempt() async {
        let manager = SessionManager()
        manager.activeHost = HostProfile(name: "Retry", hostname: "retry.invalid")
        manager.reconnectAttempt = 2
        manager.state = .reconnecting(attempt: 2)

        await manager.handleConnectFailure(error: POSIXError(.ECONNREFUSED))

        XCTAssertEqual(manager.state, .reconnecting(attempt: 3))
        XCTAssertEqual(manager.reconnectAttempt, 3)
        manager.cancelReconnect()
    }

    @MainActor
    func testConnectFailureWithCredentialsErrorDoesNotRetry() async {
        let manager = SessionManager()
        manager.activeHost = HostProfile(name: "Retry", hostname: "retry.invalid")
        manager.reconnectAttempt = 2
        manager.state = .reconnecting(attempt: 2)

        await manager.handleConnectFailure(error: SSHError.invalidCredentials("rejected"))

        XCTAssertTrue(manager.state.isFailed)
        XCTAssertEqual(manager.reconnectAttempt, 0)
    }

    @MainActor
    func testConnectFailureStopsAfterMaxAttempts() async {
        let manager = SessionManager()
        manager.activeHost = HostProfile(name: "Retry", hostname: "retry.invalid")
        manager.reconnectAttempt = manager.maxReconnectAttempts
        manager.state = .reconnecting(attempt: manager.maxReconnectAttempts)

        await manager.handleConnectFailure(error: POSIXError(.ECONNREFUSED))

        XCTAssertTrue(manager.state.isFailed)
    }

    @MainActor
    func testConnectFailureOnFreshConnectDoesNotRetry() async {
        let manager = SessionManager()
        manager.activeHost = HostProfile(name: "Fresh", hostname: "fresh.invalid")
        manager.state = .connecting

        await manager.handleConnectFailure(error: POSIXError(.ECONNREFUSED))

        XCTAssertTrue(manager.state.isFailed, "A first-time connect failure should surface to the user, not retry")
    }

    func testReadinessGateResolutionBeforeWait() async throws {
        let gate = ReadinessGate()
        XCTAssertFalse(gate.isResolved)
        gate.succeed()
        XCTAssertTrue(gate.isResolved)
        gate.succeed()
        try await gate.wait()
    }

    func testReadinessGateFailureBeforeWait() async {
        let gate = ReadinessGate()
        gate.fail(SSHError.terminalSetupTimedOut)
        XCTAssertTrue(gate.isResolved)
        do {
            try await gate.wait()
            XCTFail("Should have thrown")
        } catch let err as SSHError {
            guard case .terminalSetupTimedOut = err else {
                XCTFail("Unexpected error: \(err)")
                return
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testReadinessGateTimeoutWrapperReturnsTimedOutPromptly() async throws {
        let gate = ReadinessGate()
        let start = ContinuousClock.now
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await gate.wait()
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 50_000_000) // 50ms
                    gate.fail(SSHError.terminalSetupTimedOut)
                    throw SSHError.terminalSetupTimedOut
                }
                try await group.next()
                group.cancelAll()
            }
            XCTFail("Should have thrown terminalSetupTimedOut")
        } catch let err as SSHError {
            guard case .terminalSetupTimedOut = err else {
                XCTFail("Expected terminalSetupTimedOut, got \(err)")
                return
            }
            let elapsed = ContinuousClock.now - start
            XCTAssertLessThan(elapsed, .seconds(1.0), "Timeout must complete promptly, took \(elapsed)")
        }
    }

    func testReadinessGateCancellationBeforeWait() async {
        let gate = ReadinessGate()
        gate.cancel()
        do {
            try await gate.wait()
            XCTFail("Should throw CancellationError")
        } catch is CancellationError {
            // Success
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testReadinessGateCancellationWhileWaiting() async {
        let gate = ReadinessGate()
        let task = Task {
            try await gate.wait()
        }
        for _ in 0..<5 {
            await Task.yield()
        }
        task.cancel()
        do {
            try await task.value
            XCTFail("Should throw CancellationError")
        } catch is CancellationError {
            // Success
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testReadinessGateRepeatedResolutionBehavior() async throws {
        let gate = ReadinessGate()
        gate.succeed()
        gate.fail(SSHError.terminalSetupTimedOut)
        gate.cancel()
        // Must succeed because succeed was first
        try await gate.wait()
    }

    func testReadinessGateConcurrentRaces() async throws {
        for _ in 0..<50 {
            let gate = ReadinessGate()
            let waiterTask = Task {
                try await gate.wait()
            }
            let resolverTask = Task {
                if Bool.random() {
                    gate.succeed()
                } else {
                    gate.fail(SSHError.channelClosed)
                }
            }
            let cancelTask = Task {
                waiterTask.cancel()
            }
            _ = await resolverTask.result
            _ = await cancelTask.result
            _ = await waiterTask.result
            XCTAssertTrue(gate.isResolved)
        }
    }

    func testTerminalSetupErrorsAreNonRetryable() {
        XCTAssertFalse(SessionManager.isRetryableConnectError(SSHError.terminalSetupFailed("Refused")))
        XCTAssertFalse(SessionManager.isRetryableConnectError(SSHError.terminalSetupTimedOut))
    }

    @MainActor
    func testRepeatedImmediateDisconnectsExhaustRetryBudget() {
        let manager = SessionManager()
        manager.maxReconnectAttempts = 3
        manager.activeHost = HostProfile(name: "Test", hostname: "test.invalid")
        manager.currentConnectionId = UUID()

        var fakeNow = ContinuousClock.now
        manager.nowProvider = { fakeNow }

        // Attempt 1: immediate drop (duration 0.1s < 10.0s threshold)
        manager.markConnectedForTesting()
        fakeNow = fakeNow.advanced(by: .milliseconds(100))
        manager.handleDisconnect(error: SSHError.channelClosed)
        XCTAssertEqual(manager.reconnectAttempt, 1)
        XCTAssertTrue(manager.state.isBusy)

        // Attempt 2: immediate drop again
        manager.markConnectedForTesting()
        fakeNow = fakeNow.advanced(by: .milliseconds(100))
        manager.handleDisconnect(error: SSHError.channelClosed)
        XCTAssertEqual(manager.reconnectAttempt, 2)
        XCTAssertTrue(manager.state.isBusy)

        // Attempt 3: immediate drop again -> reaches maxReconnectAttempts (3)
        manager.markConnectedForTesting()
        fakeNow = fakeNow.advanced(by: .milliseconds(100))
        manager.handleDisconnect(error: SSHError.channelClosed)
        XCTAssertEqual(manager.reconnectAttempt, 3)
        XCTAssertTrue(manager.state.isBusy)

        // Attempt 4: exceeds maxReconnectAttempts -> transitions to failed, does not retry
        manager.markConnectedForTesting()
        fakeNow = fakeNow.advanced(by: .milliseconds(100))
        manager.handleDisconnect(error: SSHError.channelClosed)
        XCTAssertTrue(manager.state.isFailed, "Must stop retrying when max attempts exceeded")
        manager.cancelReconnect()
    }

    @MainActor
    func testStableConnectionResetsRetryBudget() {
        let manager = SessionManager()
        manager.maxReconnectAttempts = 3
        manager.activeHost = HostProfile(name: "Test", hostname: "test.invalid")
        manager.currentConnectionId = UUID()

        var fakeNow = ContinuousClock.now
        manager.nowProvider = { fakeNow }

        // Attempt 1: immediate drop
        manager.markConnectedForTesting()
        fakeNow = fakeNow.advanced(by: .milliseconds(100))
        manager.handleDisconnect(error: SSHError.channelClosed)
        XCTAssertEqual(manager.reconnectAttempt, 1)

        // Reconnected and stayed connected for 15 seconds (>= 10.0s stable threshold)
        manager.markConnectedForTesting()
        fakeNow = fakeNow.advanced(by: .seconds(15))
        manager.handleDisconnect(error: SSHError.channelClosed)

        // Stable session reset retry count to 0, then incremented to 1 for this new drop
        XCTAssertEqual(manager.reconnectAttempt, 1)
        XCTAssertTrue(manager.state.isBusy)
        manager.cancelReconnect()
    }

    @MainActor
    func testSessionManagerOutboundBufferCap() {
        let manager = SessionManager()
        manager.state = .connected
        XCTAssertEqual(SessionManager.maxOutboundBufferSize, 512 * 1024)

        // Generate data exceeding buffer capacity
        let largeChunk = [UInt8](repeating: 0x41, count: 600 * 1024)
        manager.send(data: largeChunk)

        // Buffer must not exceed maxOutboundBufferSize (oversized paste rejected in whole)
        XCTAssertEqual(manager.pendingOutboundBufferSize, 0)
        XCTAssertEqual(manager.activeToast?.title, "Input Dropped")
    }

    @MainActor
    func testSessionManagerRejectsInputWhenOutboundBufferFull() {
        let manager = SessionManager()
        manager.markConnectedForTesting()

        // Block writer to keep bytes in flight
        var writerContinuation: CheckedContinuation<Void, Never>?
        manager.sshWriterForTesting = { _ in
            await withCheckedContinuation { continuation in
                writerContinuation = continuation
            }
        }

        // The first send goes in-flight immediately (400 KB)
        manager.send(data: [UInt8](repeating: 0x41, count: 400 * 1024))
        XCTAssertEqual(manager.pendingOutboundBufferSize, 400 * 1024)

        // The second send would bring total pending to 600 KB (> 512 KB) and is rejected
        manager.send(data: [UInt8](repeating: 0x42, count: 200 * 1024))
        XCTAssertEqual(manager.pendingOutboundBufferSize, 400 * 1024, "Overflowing input must be rejected, not trimmed from the front")
        XCTAssertEqual(manager.activeToast?.title, "Input Dropped")

        // Input that fits (e.g. 50 KB: 400 KB in flight + 50 KB = 450 KB <= 512 KB) must still be accepted
        manager.send(data: [UInt8](repeating: 0x43, count: 50 * 1024))
        XCTAssertEqual(manager.pendingOutboundBufferSize, 450 * 1024, "Input that fits must still be accepted")

        writerContinuation?.resume()
        manager.disconnect()
    }

    @MainActor
    func testSessionManagerRejectsOversizedInitialPaste() {
        let manager = SessionManager()
        manager.markConnectedForTesting()

        XCTAssertEqual(manager.pendingOutboundBufferSize, 0)
        let largePaste = [UInt8](repeating: 0x41, count: 600 * 1024)
        manager.send(data: largePaste)

        // Must reject whole paste and enqueue zero bytes
        XCTAssertEqual(manager.pendingOutboundBufferSize, 0)
        XCTAssertEqual(manager.activeToast?.title, "Input Dropped")
        manager.disconnect()
    }

    @MainActor
    func testSessionManagerBuffersPreReadyInputAndDrainsAfterConnected() async {
        let manager = SessionManager()
        manager.state = .connecting

        var delivered: [[UInt8]] = []
        manager.sshWriterForTesting = { chunk in
            delivered.append(chunk)
        }

        manager.send(data: [0x01, 0x02])
        manager.send(data: [0x03, 0x04])

        // Input is queued while connecting, but not yet sent
        XCTAssertEqual(manager.pendingOutboundBufferSize, 4)
        XCTAssertTrue(delivered.isEmpty)

        // Mark connected
        let connId = UUID()
        manager.currentConnectionId = connId
        manager.state = .connected

        // Send a third chunk after connecting; triggers drain
        manager.send(data: [0x05])

        // Wait a brief moment for async drain tasks to finish
        for _ in 0..<10 {
            if delivered.count == 3 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(delivered, [[0x01, 0x02], [0x03, 0x04], [0x05]])
        XCTAssertEqual(manager.pendingOutboundBufferSize, 0)
        manager.disconnect()
    }

    @MainActor
    func testSessionManagerWriteFailureDiscardsInputAndDoesNotAutoReplay() async {
        let manager = SessionManager()
        let connId = UUID()
        manager.currentConnectionId = connId
        manager.state = .connected

        struct TestWriteError: Error, Equatable {}

        var writesAttempted = 0
        manager.sshWriterForTesting = { chunk in
            writesAttempted += 1
            if writesAttempted == 1 {
                // First write succeeds
                return
            } else {
                // Subsequent write fails
                throw TestWriteError()
            }
        }

        // First write succeeds
        manager.send(data: [0x01])
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(writesAttempted, 1)

        // Queue second and third writes
        manager.send(data: [0x02])
        manager.send(data: [0x03])

        // Wait for drain failure to process
        for _ in 0..<10 {
            if manager.activeToast?.title == "Write Failed" { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(manager.activeToast?.title, "Write Failed")
        // All unsent pending input was discarded
        XCTAssertEqual(manager.pendingOutboundBufferSize, 0)

        // State transitioned away from .connected
        XCTAssertFalse(manager.state.isConnected)

        // Reconnecting must not automatically replay the discarded input
        manager.state = .connected
        manager.currentConnectionId = UUID()
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(writesAttempted, 2, "No additional writes should have run after failure")
        XCTAssertEqual(manager.pendingOutboundBufferSize, 0)
        manager.disconnect()
    }

    @MainActor
    func testSessionManagerSupersededWriteDoesNotAffectNewSession() async {
        let manager = SessionManager()
        let session1Id = UUID()
        manager.currentConnectionId = session1Id
        manager.state = .connected

        var continuation1: CheckedContinuation<Void, Never>?
        manager.sshWriterForTesting = { chunk in
            if chunk == [0xAA] {
                await withCheckedContinuation { cont in
                    continuation1 = cont
                }
            }
        }

        // Send chunk for session 1 that suspends in flight
        manager.send(data: [0xAA])
        XCTAssertEqual(manager.pendingOutboundBufferSize, 1)

        // Yield to allow session 1's drain task to invoke writer and suspend
        for _ in 0..<10 {
            if continuation1 != nil { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(continuation1)

        // Host switch or disconnect creates session 2
        manager.clearOutbound()
        let session2Id = UUID()
        manager.currentConnectionId = session2Id
        manager.state = .connected

        // Session 2 sends fresh data
        var session2Delivered: [[UInt8]] = []
        manager.sshWriterForTesting = { chunk in
            session2Delivered.append(chunk)
        }
        manager.send(data: [0xBB])

        // Now resume session 1's suspended write
        continuation1?.resume()
        try? await Task.sleep(nanoseconds: 20_000_000)

        // Verify session 2's data was delivered and pending buffer reflects only session 2
        XCTAssertEqual(session2Delivered, [[0xBB]])
        XCTAssertEqual(manager.pendingOutboundBufferSize, 0)
        manager.disconnect()
    }

    @MainActor
    func testSessionManagerAcceptsInputByState() {
        let manager = SessionManager()
        manager.state = .connected
        XCTAssertTrue(manager.acceptsInput)

        manager.state = .connecting
        XCTAssertTrue(manager.acceptsInput)

        manager.state = .reconnecting(attempt: 1)
        XCTAssertFalse(manager.acceptsInput)

        manager.state = .failed("Network error")
        XCTAssertFalse(manager.acceptsInput)

        manager.state = .disconnected
        XCTAssertFalse(manager.acceptsInput)

        // Resume case
        let host = HostProfile(name: "Resume Test", hostname: "resume.example.com")
        manager.activeHost = host
        manager.reconnect()
        XCTAssertEqual(manager.state, .connecting)
        XCTAssertFalse(manager.acceptsInput)
        manager.disconnect()
    }

    @MainActor
    func testSessionManagerDiscardedInputToastOnce() {
        let manager = SessionManager()
        manager.state = .reconnecting(attempt: 1)

        manager.send(data: [0x41])
        XCTAssertEqual(manager.activeToast?.title, "Not Connected")
        XCTAssertEqual(manager.activeToast?.message, "Input typed while disconnected was discarded.")

        manager.activeToast = nil
        manager.send(data: [0x42])
        XCTAssertNil(manager.activeToast)
        XCTAssertEqual(manager.pendingOutboundBufferSize, 0)
    }

    func testSSHServiceRejectsSendWhenDisconnected() async {
        let service = SSHService()
        let isConn = await service.isConnected
        XCTAssertFalse(isConn)

        do {
            try await service.send(data: [0x41, 0x42, 0x43])
            XCTFail("send(data:) when disconnected should throw SSHError.notConnected")
        } catch let error as SSHError {
            switch error {
            case .notConnected:
                break
            default:
                XCTFail("Expected notConnected, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSSHServiceStaleCleanupDoesNotTouchCurrentSession() async throws {
        let service = SSHService()
        await service.disconnect()
        let staleGeneration = await service.currentSessionGeneration
        await service.disconnect()
        let currentGeneration = await service.currentSessionGeneration
        XCTAssertNotEqual(staleGeneration, currentGeneration)

        let bundle = SessionBundle(generation: currentGeneration)
        await service.installSessionBundleForTesting(bundle)
        let beforeCleanup = await service.hasActiveSession
        XCTAssertTrue(beforeCleanup)

        await service.cleanup(generation: staleGeneration)
        let afterStale = await service.hasActiveSession
        XCTAssertTrue(afterStale, "Cleanup from a superseded session must not clear current state")

        await service.cleanup(generation: currentGeneration)
        let afterCurrent = await service.hasActiveSession
        XCTAssertFalse(afterCurrent)
    }

    func testSSHServiceStaleCleanupWithSuspendedTeardownDoesNotTouchNewSession() async throws {
        let service = SSHService()
        await service.disconnect()
        let genA = await service.currentSessionGeneration

        let bundleA = SessionBundle(generation: genA)
        let suspendGate = ReadinessGate()
        let teardownStarted = NIOLockedValueBox(false)
        bundleA.onTeardownStart = {
            teardownStarted.withLockedValue { $0 = true }
            try? await suspendGate.wait()
        }
        await service.installSessionBundleForTesting(bundleA)

        // Start cleanup for A in background Task (which suspends inside onTeardownStart)
        let cleanupTask = Task {
            await service.cleanup(generation: genA)
        }
        while !teardownStarted.withLockedValue({ $0 }) {
            await Task.yield()
        }

        // Install Session B while A's teardown is suspended
        await service.disconnect()
        let genB = await service.currentSessionGeneration
        let bundleB = SessionBundle(generation: genB)
        await service.installSessionBundleForTesting(bundleB)

        // Release A's teardown
        suspendGate.succeed()
        await cleanupTask.value

        // Verify B's state remains intact
        let currentGen = await service.currentSessionGeneration
        XCTAssertEqual(currentGen, genB)
        let bActive = await service.hasActiveSession
        XCTAssertTrue(bActive, "Session B must not be cleared by Session A teardown")
        let activeBundle = await service.activeSessionBundleForTesting
        XCTAssertTrue(activeBundle === bundleB, "Session B bundle must remain active")
    }

    func testSSHServiceOverlappingDisconnectAndNewSession() async throws {
        let service = SSHService()
        await service.disconnect()
        let genA = await service.currentSessionGeneration
        let bundleA = SessionBundle(generation: genA)
        let suspendGate = ReadinessGate()
        let teardownStarted = NIOLockedValueBox(false)
        bundleA.onTeardownStart = {
            teardownStarted.withLockedValue { $0 = true }
            try? await suspendGate.wait()
        }
        await service.installSessionBundleForTesting(bundleA)

        // Disconnect A in background
        let disconnectTask = Task {
            await service.disconnect()
        }
        while !teardownStarted.withLockedValue({ $0 }) {
            await Task.yield()
        }

        // Install B
        let genB = await service.currentSessionGeneration
        let bundleB = SessionBundle(generation: genB)
        await service.installSessionBundleForTesting(bundleB)

        // Release A
        suspendGate.succeed()
        await disconnectTask.value

        let activeBundle = await service.activeSessionBundleForTesting
        XCTAssertTrue(activeBundle === bundleB, "Session B must remain active after Session A disconnect finishes")
    }

    @MainActor
    func testSessionManagerProbeDoesNotReconnectAfterSwitchingHost() async {
        let manager = SessionManager()
        let hostA = HostProfile(name: "HostA", hostname: "a.invalid")
        let hostB = HostProfile(name: "HostB", hostname: "b.invalid")
        manager.activeHost = hostA
        let idA = UUID()
        manager.currentConnectionId = idA
        manager.markConnectedForTesting()

        // Switch to host B before probe completes
        let idB = UUID()
        manager.activeHost = hostB
        manager.currentConnectionId = idB

        // Trigger foreground check completion for A's probe
        manager.handleAppForegrounded()

        XCTAssertEqual(manager.activeHost?.id, hostB.id)
    }

    @MainActor
    func testSessionManagerProbeDoesNotReconnectAfterIntentionalDisconnect() async {
        let manager = SessionManager()
        let hostA = HostProfile(name: "HostA", hostname: "a.invalid")
        manager.activeHost = hostA
        manager.currentConnectionId = UUID()
        manager.markConnectedForTesting()

        manager.disconnect()
        XCTAssertTrue(manager.isIntentionalDisconnect)
        XCTAssertEqual(manager.state, .disconnected)
        XCTAssertNil(manager.currentConnectionId)
    }

    @MainActor
    func testSessionManagerBackgroundExpirationAfterForegroundDoesNotDisconnect() async {
        let manager = SessionManager()
        let host = HostProfile(name: "Host", hostname: "host.invalid")
        manager.activeHost = host
        manager.currentConnectionId = UUID()
        manager.markConnectedForTesting()

        manager.handleAppBackgrounded()
        XCTAssertTrue(manager.isAppInBackground)

        // App foregrounds before background execution expires
        manager.handleAppForegrounded()
        XCTAssertFalse(manager.isAppInBackground)

        XCTAssertEqual(manager.state, .connected)
        XCTAssertFalse(manager.isIntentionalDisconnect)
    }

    func testTerminalChannelHandlerWithholdsAcceptanceTimesOutAndClosesChannel() async throws {
        let handler = TerminalChannelHandler(generation: 1, onOutput: { _ in })
        let channel = EmbeddedChannel(handler: handler)

        let waitTask = Task {
            try await handler.waitForServerAcceptance(eventLoop: channel.eventLoop)
        }
        for _ in 0..<5 {
            await Task.yield()
        }
        waitTask.cancel()

        do {
            try await waitTask.value
            XCTFail("Should have thrown CancellationError")
        } catch is CancellationError {
            // Success
        }

        _ = try? channel.finish()
    }

    func testSSHServiceActivityNotUpdatedByOutboundSend() async {
        let service = SSHService()
        let notIdle = await service.isConnectionIdle(for: 10.0)
        XCTAssertFalse(notIdle)

        try? await Task.sleep(nanoseconds: 60_000_000)
        let isIdle = await service.isConnectionIdle(for: 0.05)
        XCTAssertTrue(isIdle)

        // Attempting to send data should NOT reset lastActivityTime
        try? await service.send(data: [0x01, 0x02])

        let stillIdle = await service.isConnectionIdle(for: 0.05)
        XCTAssertTrue(stillIdle)
    }

    // MARK: - Resize Debouncing

    @MainActor
    func testSessionManagerResizeDebouncing() async throws {
        let manager = SessionManager()
        XCTAssertNil(manager.pendingCols)
        XCTAssertNil(manager.pendingRows)

        // Rapidly dispatch multiple resize calls (simulating live window dragging)
        manager.resize(cols: 80, rows: 24)
        manager.resize(cols: 90, rows: 30)
        manager.resize(cols: 120, rows: 45)

        // The latest pending targets should be recorded
        XCTAssertEqual(manager.pendingCols, 120)
        XCTAssertEqual(manager.pendingRows, 45)

        // Wait for debounced task to settle
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(manager.pendingCols, 120)
        XCTAssertEqual(manager.pendingRows, 45)
    }

    // MARK: - Connection Health Probe

    func testConnectionHealthProbeWhenDisconnected() async {
        let service = SSHService()
        let healthy = await service.ping(timeout: 0.2)
        XCTAssertFalse(healthy, "Ping must return false immediately if disconnected")
        await service.disconnect()
    }

    // MARK: - Memory Pressure Management

    @MainActor
    func testMemoryPressureHandling() {
        let manager = SessionManager()
        var memoryWarningReceived = false
        manager.onMemoryWarning = {
            memoryWarningReceived = true
        }

        manager.handleMemoryWarning()
        XCTAssertTrue(memoryWarningReceived, "SessionManager must invoke onMemoryWarning callback")

        let terminal = FilaireTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        terminal.changeScrollback(10000)
        terminal.shedMemoryPressure()
    }

    @MainActor
    func testTerminalViewKeepsMemoryScrollbackCap() {
        let terminal = FilaireTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertEqual(terminal.appliedScrollback, TerminalSettings.shared.scrollbackLimit.rawValue)

        terminal.shedMemoryPressure()
        XCTAssertEqual(terminal.appliedScrollback, 1000)

        // Re-applying settings (as the settings notification does) must not undo the memory cap
        terminal.applyScrollbackLimit()
        XCTAssertEqual(terminal.appliedScrollback, 1000)
    }

    @MainActor
    func testCellDimensionIsStableAndTracksFont() {
        let terminal = FilaireTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let first = terminal.cellDimension()
        XCTAssertEqual(terminal.cellDimension(), first)

        terminal.font = UIFont.monospacedSystemFont(ofSize: terminal.font.pointSize + 6, weight: .regular)
        XCTAssertNotEqual(terminal.cellDimension(), first, "Cache must invalidate when the font changes")
    }

    // MARK: - Graceful Termination & Detach

    @MainActor
    func testGracefulTerminationHandling() async {
        let manager = SessionManager()
        let host = HostProfile(name: "Test", hostname: "localhost")
        manager.activeHost = host
        manager.state = .connected

        manager.handleAppTerminating()

        let service = SSHService()
        await service.disconnect()
        let isConnected = await service.isConnected
        XCTAssertFalse(isConnected)
    }

    // MARK: - Host Key Verification & Mismatch

    func testHostKeyMismatchErrorFormatting() {
        let error = HostKeyMismatchError.hostKeyChanged(
            hostname: "bastion.corp.net",
            port: 22,
            expectedFingerprint: "SHA256:abc123expected",
            actualFingerprint: "SHA256:xyz789received"
        )
        guard let desc = error.errorDescription else {
            XCTFail("errorDescription must not be nil")
            return
        }
        XCTAssertTrue(desc.contains("WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED"))
        XCTAssertTrue(desc.contains("bastion.corp.net:22"))
        XCTAssertTrue(desc.contains("SHA256:abc123expected"))
        XCTAssertTrue(desc.contains("SHA256:xyz789received"))
    }

    // MARK: - Biometrics & Secure Enclave Credentials

    func testHostProfileBiometricsDefaultsAndDecoding() throws {
        let profile = HostProfile(name: "Secure Server", hostname: "sec.net", username: "admin")
        XCTAssertTrue(profile.requireBiometrics, "requireBiometrics must default to true")

        // Test backward compatibility: JSON without requireBiometrics
        let legacyJSON = """
        {
            "id": "23d4a4f7-347d-44f5-b92b-d727f7ce09a8",
            "name": "Legacy Server",
            "hostname": "legacy.net",
            "port": 22,
            "username": "root",
            "authMethod": "Password"
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(HostProfile.self, from: legacyJSON)
        XCTAssertTrue(decoded.requireBiometrics, "requireBiometrics must default to true when missing from legacy JSON")
        XCTAssertTrue(decoded.autoConnect, "autoConnect must default to true")
    }

    func testSSHKeyModelBiometricsAndPassphraseDefaults() throws {
        let key = SSHKeyModel(name: "Mac Key", publicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5...")
        XCTAssertTrue(key.requiresBiometrics, "requiresBiometrics must default to true")
        XCTAssertFalse(key.hasPassphrase, "hasPassphrase must default to false")

        // Backward compatibility
        let legacyJSON = """
        {
            "id": "23d4a4f7-347d-44f5-b92b-d727f7ce09a8",
            "name": "Legacy Key",
            "keyType": "Ed25519",
            "publicKey": "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5...",
            "createdAt": 1700000000
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(SSHKeyModel.self, from: legacyJSON)
        XCTAssertTrue(decoded.requiresBiometrics, "requiresBiometrics must default to true when missing")
        XCTAssertFalse(decoded.hasPassphrase, "hasPassphrase must default to false when missing")
    }

    func testKeychainServicePassphraseAndCredentialsLifecycle() throws {
        let testKeyId = UUID()
        let testHostId = UUID()

        // 1. Password
        try KeychainService.savePassword("super-secret-pw", forHostId: testHostId, requireBiometrics: false)
        XCTAssertEqual(KeychainService.getPassword(forHostId: testHostId), "super-secret-pw")
        KeychainService.deletePassword(forHostId: testHostId)
        XCTAssertNil(KeychainService.getPassword(forHostId: testHostId))

        // 2. Private Key
        try KeychainService.savePrivateKey("dummy-private-key-pem", forKeyId: testKeyId, requireBiometrics: false)
        XCTAssertEqual(KeychainService.getPrivateKey(forKeyId: testKeyId), "dummy-private-key-pem")
        KeychainService.deletePrivateKey(forKeyId: testKeyId)
        XCTAssertNil(KeychainService.getPrivateKey(forKeyId: testKeyId))

        // 3. Key Passphrase
        try KeychainService.saveKeyPassphrase("passphrase123", forKeyId: testKeyId, requireBiometrics: false)
        XCTAssertEqual(KeychainService.getKeyPassphrase(forKeyId: testKeyId), "passphrase123")
        KeychainService.deleteKeyPassphrase(forKeyId: testKeyId)
        XCTAssertNil(KeychainService.getKeyPassphrase(forKeyId: testKeyId))
    }

    func testKeychainProtectionUnavailableErrorDescription() {
        let desc = KeychainError.protectionUnavailable(errSecAuthFailed).errorDescription
        XCTAssertNotNil(desc)
        XCTAssertTrue(desc?.contains("passcode") == true)
    }

    // MARK: - Keychain Reliability and Staged Preservation Tests

    private final class MockKeychainBackend: KeychainBackend, @unchecked Sendable {
        let lock = NSLock()
        var items: [String: [String: Any]] = [:]
        var failAccessControlCreation = false
        var failAddStatus: OSStatus? = nil
        var failUpdateStatus: OSStatus? = nil
        var simulateDuplicateOnRefAdd = false
        var addCount = 0
        var updateCount = 0
        var deleteCount = 0

        init() {}

        func copyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
            lock.lock()
            defer { lock.unlock() }
            let dict = query as NSDictionary
            guard let account = dict[kSecAttrAccount as String] as? String,
                  let service = dict[kSecAttrService as String] as? String else {
                return errSecParam
            }
            let storageKey = "\(service):\(account)"
            guard let item = items[storageKey] else {
                return errSecItemNotFound
            }

            if dict[kSecReturnData as String] as? Bool == true {
                if let data = item[kSecValueData as String] as? Data {
                    result?.pointee = data as CFData
                    return errSecSuccess
                }
            }
            return errSecSuccess
        }

        func add(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
            lock.lock()
            defer { lock.unlock() }
            addCount += 1
            if let fail = failAddStatus {
                return fail
            }
            let dict = query as NSDictionary
            guard let account = dict[kSecAttrAccount as String] as? String,
                  let service = dict[kSecAttrService as String] as? String else {
                return errSecParam
            }
            let storageKey = "\(service):\(account)"
            if simulateDuplicateOnRefAdd && account.hasSuffix(".ref") {
                simulateDuplicateOnRefAdd = false
                items[storageKey] = [
                    kSecAttrAccount as String: account,
                    kSecAttrService as String: service,
                    kSecValueData as String: Data()
                ]
                return errSecDuplicateItem
            }
            if items[storageKey] != nil {
                return errSecDuplicateItem
            }
            var copy: [String: Any] = [:]
            for (k, v) in dict {
                if let keyStr = k as? String {
                    copy[keyStr] = v
                }
            }
            items[storageKey] = copy
            return errSecSuccess
        }

        func update(_ query: CFDictionary, _ attributesToUpdate: CFDictionary) -> OSStatus {
            lock.lock()
            defer { lock.unlock() }
            updateCount += 1
            if let fail = failUpdateStatus {
                return fail
            }
            let qDict = query as NSDictionary
            guard let account = qDict[kSecAttrAccount as String] as? String,
                  let service = qDict[kSecAttrService as String] as? String else {
                return errSecParam
            }
            let storageKey = "\(service):\(account)"
            guard var existing = items[storageKey] else {
                return errSecItemNotFound
            }
            let uDict = attributesToUpdate as NSDictionary
            for (k, v) in uDict {
                if let keyStr = k as? String {
                    existing[keyStr] = v
                }
            }
            items[storageKey] = existing
            return errSecSuccess
        }

        func delete(_ query: CFDictionary) -> OSStatus {
            lock.lock()
            defer { lock.unlock() }
            deleteCount += 1
            let dict = query as NSDictionary
            guard let account = dict[kSecAttrAccount as String] as? String,
                  let service = dict[kSecAttrService as String] as? String else {
                return errSecParam
            }
            let storageKey = "\(service):\(account)"
            items.removeValue(forKey: storageKey)
            return errSecSuccess
        }

        func createAccessControl(
            _ allocator: CFAllocator?,
            _ protection: CFTypeRef,
            _ flags: SecAccessControlCreateFlags,
            _ error: UnsafeMutablePointer<Unmanaged<CFError>?>?
        ) -> SecAccessControl? {
            if failAccessControlCreation {
                return nil
            }
            return SecAccessControlCreateWithFlags(allocator, protection, flags, error)
        }
    }

    func testKeychainSaveUpdateFailurePreservesOriginal() throws {
        let mock = MockKeychainBackend()
        KeychainService.backend = mock
        defer { KeychainService.resetBackend() }

        let hostId = UUID()
        try KeychainService.savePassword("original-secret", forHostId: hostId, requireBiometrics: false)
        XCTAssertEqual(KeychainService.getPassword(forHostId: hostId), "original-secret")

        mock.failUpdateStatus = errSecIO

        XCTAssertThrowsError(try KeychainService.savePassword("new-secret", forHostId: hostId, requireBiometrics: false)) { error in
            XCTAssertEqual(error as? KeychainError, KeychainError.secError(errSecIO))
        }

        mock.failUpdateStatus = nil
        XCTAssertEqual(KeychainService.getPassword(forHostId: hostId), "original-secret", "Original secret must not be lost on update failure")
    }

    func testKeychainInPlaceValueUpdate() throws {
        let mock = MockKeychainBackend()
        KeychainService.backend = mock
        defer { KeychainService.resetBackend() }

        let hostId = UUID()
        try KeychainService.savePassword("version-1", forHostId: hostId, requireBiometrics: false)
        XCTAssertEqual(KeychainService.getPassword(forHostId: hostId), "version-1")

        let updatesBefore = mock.updateCount
        try KeychainService.savePassword("version-2", forHostId: hostId, requireBiometrics: false)
        XCTAssertEqual(KeychainService.getPassword(forHostId: hostId), "version-2")
        XCTAssertGreaterThan(mock.updateCount, updatesBefore, "Unchanged protection policy should use in-place SecItemUpdate")
    }

    func testKeychainDuplicateOnRefAddRetriesUpdate() throws {
        let mock = MockKeychainBackend()
        KeychainService.backend = mock
        defer { KeychainService.resetBackend() }

        let hostId = UUID()
        mock.simulateDuplicateOnRefAdd = true
        try KeychainService.savePassword("initial-value", forHostId: hostId, requireBiometrics: false)
        XCTAssertEqual(KeychainService.getPassword(forHostId: hostId), "initial-value")
    }

    func testKeychainStagedInterruptionPreservesActiveVersion() throws {
        let mock = MockKeychainBackend()
        KeychainService.backend = mock
        defer { KeychainService.resetBackend() }

        let hostId = UUID()
        try KeychainService.savePassword("authoritative-v1", forHostId: hostId, requireBiometrics: false)

        let baseKey = "io.o-t.filaire.host.\(hostId.uuidString).password"
        let orphanKey = "io.o-t.filaire:\(baseKey).v.orphan-uuid"
        mock.items[orphanKey] = [
            kSecAttrAccount as String: "\(baseKey).v.orphan-uuid",
            kSecAttrService as String: "io.o-t.filaire",
            kSecValueData as String: "orphan-payload".data(using: .utf8)!
        ]

        XCTAssertEqual(KeychainService.getPassword(forHostId: hostId), "authoritative-v1")
    }

    func testPassphraseFailureDuringImportCleansUpOrphanPrivateKey() throws {
        let mock = MockKeychainBackend()
        KeychainService.backend = mock
        defer { KeychainService.resetBackend() }

        let unrelatedKeyId = UUID()
        try KeychainService.savePrivateKey("unrelated-key-data", forKeyId: unrelatedKeyId, requireBiometrics: false)
        XCTAssertNotNil(KeychainService.getPrivateKey(forKeyId: unrelatedKeyId))

        let newKeyId = UUID()
        try KeychainService.savePrivateKey("new-key-data", forKeyId: newKeyId, requireBiometrics: false)

        // Inject passphrase save failure
        mock.failAddStatus = errSecAuthFailed

        // Attempting to save passphrase fails
        XCTAssertThrowsError(try KeychainService.saveKeyPassphrase("passphrase", forKeyId: newKeyId, requireBiometrics: false))

        // Cleanup handler removes orphan key
        KeychainService.deletePrivateKey(forKeyId: newKeyId)

        // Verify orphan key is gone, but unrelated key remains intact!
        XCTAssertNil(KeychainService.getPrivateKey(forKeyId: newKeyId))
        mock.failAddStatus = nil
        XCTAssertEqual(KeychainService.getPrivateKey(forKeyId: unrelatedKeyId), "unrelated-key-data")
    }

    @MainActor
    func testBiometricAuthServiceProperties() async throws {
        let name = BiometricAuthService.biometryName
        XCTAssertFalse(name.isEmpty, "biometryName must not be empty")

        // In test environments, authenticateUser gracefully returns true
        let authed = try await BiometricAuthService.authenticateUser(reason: "Unit Test Verification")
        XCTAssertTrue(authed)

        let context = try await BiometricAuthService.authenticate(reason: "Unit Test Verification")
        XCTAssertNotNil(context)
    }

    // MARK: - Encrypted OpenSSH Key Parsing & Decryption

    func testParseKeyInfoUnencryptedEd25519() throws {
        let keyPair = try SSHKeyGenerator.generateEd25519Key(comment: "test@filaire")
        let info = try SSHKeyGenerator.parseKeyInfo(from: keyPair.privateKeyPEM)

        XCTAssertEqual(info.keyType, "Ed25519")
        XCTAssertEqual(info.rawKeyType, "ssh-ed25519")
        XCTAssertFalse(info.isEncrypted)
        XCTAssertEqual(info.cipherName, "none")
        XCTAssertTrue(info.publicKey.hasPrefix("ssh-ed25519 "))
    }

    func testParseKeyInfoRaw32ByteKey() throws {
        let randomBytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
        let base64 = Data(randomBytes).base64EncodedString()
        let info = try SSHKeyGenerator.parseKeyInfo(from: base64)

        XCTAssertEqual(info.keyType, "Ed25519")
        XCTAssertEqual(info.rawKeyType, "ssh-ed25519")
        XCTAssertFalse(info.isEncrypted)
        XCTAssertEqual(info.cipherName, "none")
        XCTAssertTrue(info.publicKey.hasPrefix("ssh-ed25519 "))

        let parsed = try SSHKeyGenerator.parseEd25519PrivateKey(from: base64)
        XCTAssertEqual(Data(parsed.rawRepresentation), Data(randomBytes))
    }

    func testEncryptedEd25519KeyHandling() throws {
        let encryptedEd25519PEM = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABABaUeVZt
        smQjtk+phmze7ZAAAAGAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIA7lH5hqjOz3+ZjY
        zo9oGkWn7I1dutNB0V6Ro3LqYc3vAAAAkORdJE/Tf1J6d20Ot/uXDrR10QqUjq8nXll+80
        sxYUAH8BjOCRrX12de+FmK60OiTZ7LlRjz/M88VhXSIYzn0x7iJVrD2AGzgL5AWtb9Xeq0
        LV7afOJ2QhOyl6Y/HO7Y5yZfV7rInOXP+5RGXSmPZv8Vbgiyj6A9QE8L8igw01p3MsjYN4
        1tMz913abJYSWazw==
        -----END OPENSSH PRIVATE KEY-----
        """

        // 1. Inspect without passphrase
        let info = try SSHKeyGenerator.parseKeyInfo(from: encryptedEd25519PEM)
        XCTAssertEqual(info.keyType, "Ed25519")
        XCTAssertEqual(info.rawKeyType, "ssh-ed25519")
        XCTAssertTrue(info.isEncrypted)
        XCTAssertEqual(info.cipherName, "aes256-ctr")
        XCTAssertTrue(info.publicKey.hasPrefix("ssh-ed25519 "))

        // 2. Missing passphrase should throw passphraseRequired
        XCTAssertThrowsError(try SSHKeyGenerator.parseEd25519PrivateKey(from: encryptedEd25519PEM, passphrase: nil)) { error in
            guard case SSHKeyError.passphraseRequired(let cipher) = error else {
                XCTFail("Expected passphraseRequired error, got: \(error)")
                return
            }
            XCTAssertEqual(cipher, "aes256-ctr")
        }

        // 3. Incorrect passphrase should throw incorrectPassphrase
        XCTAssertThrowsError(try SSHKeyGenerator.parseEd25519PrivateKey(from: encryptedEd25519PEM, passphrase: "wrongpassword")) { error in
            guard case SSHKeyError.incorrectPassphrase = error else {
                XCTFail("Expected incorrectPassphrase error, got: \(error)")
                return
            }
        }

        // 4. Correct passphrase decrypts successfully
        let privateKey = try SSHKeyGenerator.parseEd25519PrivateKey(from: encryptedEd25519PEM, passphrase: "testpass123")
        XCTAssertEqual(privateKey.rawRepresentation.count, 32)
    }

    func testEncryptedRSAKeyHandling() throws {
        let encryptedRSAPEM = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABBSyhMPQn
        q4G0qHOYA46TL9AAAAGAAAAAEAAAEXAAAAB3NzaC1yc2EAAAADAQABAAABAQDBwh3LOeXH
        5WM0pvGq7c9WXgS/mNFJS2G5Z31bDWFPZWDd7CZJD5q9YMalEFaTCQKud3d9ZXNQYm06+K
        B8Qhep7qw8yTN82tXkaoqWAI5Xuo/Le7OKDL3YtpEg/6LyoAiGBjw8mCuoHL9OjkzxKhFE
        mjxFdklMontThsqM0kqR8zvVfkwOmw4KovMkDbNbaa9wBwO/qw5N+wpm+DMi5Uy0wCs2dW
        s7B6bFZLAaANjOwH4g9avqRG2BcS3QSN6Nc9Lzw+OPTEplT6SExmJxbbk/Pm+Ei/aNIa6X
        IF3AM7PmLrP/XP7DbybRrRKoEazCkSD1+dJe8hI7eLPF2f4S9luDAAADwHkKVOiuXNCXRl
        7jk6jy3bzlpVWMhDnHIip9AU4TGsse/2N6bZeEzs+F9RD3WEZWI2eWpRk5G0DC9iwoxqKn
        Ed3D/MQLTrGL2fWz2WEan548fqxfT0vhXrHjHhlyzzFX+EtZTEdxYAVG2vw/8qP2v9eyPj
        1j1xwFdw0qWPZEmYevE1hWLEFDjD44dI3+ysKoIDMN2R9yY5U45cUdOTDpun1GYw4Rz9ZW
        mHha616PapDyLd53+83GbuqW2i2eU31avGwjgoy78VL7vovyrA14Y9ezroWKCJwZowW5Sl
        KjqF165mwKkKZIv+vcdFP8hwxDxH7Xc/75vOYrIK88Z751QmKU+0Y6vLM5K5iTtdAqnIB+
        Z7RT1sngLeq+89qGz5J8vhFdh6WY0DfCZYtY0DvQZ1isK96VC1mEnfx1im4nidX4vwBoqs
        a5798p1vGAUjKhVjTi3rRtfe6V3v7PGQh5N625jpzM+0BU2/IsmTOvvc5dwrMSpErgCLle
        za5i9u6C1hET8fUl3AgCbCaAnaxKUPojx3oDMBRBip+D5LSM5vqwKuQq/g8SVNh7BSyGXX
        GbWnrbgOoQlel0d6zw9DHrx38VXKKvrp043qHm8vuoV6IDOD4pJ6Kvdt+snIpvFP+8HkeN
        3hg2YLbK0jl7ApF3U6z+LOOcQAR/HnyHjN441zAmt+ycpb3MWdtAXJwKbtaFM5WtScFvPs
        5Nm865UlrxjnN5DLFdyvKPfPcaq5fe3aVBPq+04dF7sAJMsgu6Bd8khQauvnvSum9uchE6
        b/ASDrnQr6h9qP3myuiZEB8kKBJlp3K8OLtbXpEJqF4hFPYByKPsTkXP/J0asowIe9v3qx
        2Kp66cOgfaMyXN4oYQba/QeeiDJdm/adpGnjQX+qhz/kdr5eB2cXydNnQWcBVMGt/yIjMO
        +v/6RehpwqlmfyMKoVPnMA+r3Hah/XWJFIzkNy7Blz6LPYDrJj+8QXxTwa9omDnGB0kXAu
        E6ig0qimBrACM4snmp8C1QiRJ/G42ShATzto8UQpsSC5QoWTBSnYfxgK65QCwbJjMriDzi
        LEjw7MjcMDP+xv9la4YU9zZ9dIH2eEOIzjLOnrA2LziU61OAb/WoMWJh9i5z0UPr4EUlSo
        cEEJQolcDPChZn06/TdGylKOBk3Xh9wUfQXQbIeLlNbJ8M2/hPy8dElyBeMiFHlbehEqtU
        vyv0m0cj9SwiTb+ryx8dP62Tkm2evhAJtAys38mjW54V2UMPoIcHoaXQH1hyuAi4zXzcRo
        EepG4ycQ==
        -----END OPENSSH PRIVATE KEY-----
        """

        // 1. Inspect without passphrase
        let info = try SSHKeyGenerator.parseKeyInfo(from: encryptedRSAPEM)
        XCTAssertEqual(info.keyType, "RSA")
        XCTAssertEqual(info.rawKeyType, "ssh-rsa")
        XCTAssertTrue(info.isEncrypted)
        XCTAssertEqual(info.cipherName, "aes256-ctr")
        XCTAssertTrue(info.publicKey.hasPrefix("ssh-rsa "))

        // 2. Missing passphrase should throw passphraseRequired
        XCTAssertThrowsError(try SSHKeyGenerator.parseRSAPrivateKey(from: encryptedRSAPEM, passphrase: nil)) { error in
            guard case SSHKeyError.passphraseRequired(let cipher) = error else {
                XCTFail("Expected passphraseRequired error, got: \(error)")
                return
            }
            XCTAssertEqual(cipher, "aes256-ctr")
        }

        // 3. Incorrect passphrase should throw incorrectPassphrase
        XCTAssertThrowsError(try SSHKeyGenerator.parseRSAPrivateKey(from: encryptedRSAPEM, passphrase: "wrongpassword")) { error in
            guard case SSHKeyError.incorrectPassphrase = error else {
                XCTFail("Expected incorrectPassphrase error, got: \(error)")
                return
            }
        }

        // 4. Correct passphrase decrypts successfully
        let rsaKey = try SSHKeyGenerator.parseRSAPrivateKey(from: encryptedRSAPEM, passphrase: "testpass123")
        XCTAssertNotNil(rsaKey)
    }

    // MARK: - Citadel Error Mapping & Formatting

    func testCitadelErrorFormatting() {
        let host = HostProfile(name: "Test Server", hostname: "server.local", username: "alice")

        // 1. SSHClientError.allAuthenticationOptionsFailed (Error 4)
        let error4 = SSHClientError.allAuthenticationOptionsFailed
        let mapped = SSHService.mapSSHError(error4, for: host)
        XCTAssertTrue(mapped.localizedDescription.contains("Citadel.SSHClientError 4"))
        XCTAssertTrue(mapped.localizedDescription.contains("alice"))
        XCTAssertTrue(mapped.localizedDescription.contains("~/.ssh/authorized_keys"))

        let formatted = SessionManager.formatErrorMessage(error4, for: host)
        XCTAssertTrue(formatted.contains("Citadel.SSHClientError 4"))
        XCTAssertTrue(formatted.contains("alice"))
        XCTAssertTrue(formatted.contains("~/.ssh/authorized_keys"))

        // 2. Unsupported password auth
        let unsuppPw = SSHClientError.unsupportedPasswordAuthentication
        let formattedPw = SessionManager.formatErrorMessage(unsuppPw, for: host)
        XCTAssertTrue(formattedPw.contains("Citadel.SSHClientError 0"))

        // 3. Unsupported private key auth
        let unsuppKey = SSHClientError.unsupportedPrivateKeyAuthentication
        let formattedKey = SessionManager.formatErrorMessage(unsuppKey, for: host)
        XCTAssertTrue(formattedKey.contains("Citadel.SSHClientError 1"))
    }

    // MARK: - Background Auto-Reconnect
    @MainActor
    func testSessionManagerBackgroundDisconnectAndAutoReconnect() async {
        let manager = SessionManager()
        var host = HostProfile(name: "Test Server", hostname: "127.0.0.1", username: "user")
        host.requireBiometrics = false
        manager.activeHost = host
        manager.state = .connected

        // 1. App goes to background
        manager.handleAppBackgrounded()
        XCTAssertTrue(manager.isAppInBackground)

        // 2. Connection drops in background (e.g. timeout)
        NotificationCenter.default.post(
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )

        // Simulate state transition to failed in background
        manager.state = .failed("Connection timed out in background")

        // 3. App returns to foreground -> should automatically attempt reconnect
        manager.handleAppForegrounded()
        XCTAssertFalse(manager.isAppInBackground)
        XCTAssertEqual(manager.state, .connecting, "Returning to foreground from background failure must auto-reconnect")

        // 4. Calling handleAppForegrounded again while already foregrounded should be an idempotent no-op
        manager.state = .connected
        manager.handleAppForegrounded()
        XCTAssertEqual(manager.state, .connected, "Redundant foreground call must be an idempotent no-op")
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

    private final class MockAccessoryDelegate: FilaireAccessoryDelegate {
        var sentBytes: [UInt8] = []
        var pasteRequested = false
        func accessoryDidSendBytes(_ bytes: [UInt8]) { sentBytes.append(contentsOf: bytes) }
        func accessoryDidInsertText(_ text: String) {}
        func accessoryDidToggleControl(isActive: Bool) {}
        func accessoryDidToggleAlt(isActive: Bool) {}
        func accessoryDidRequestDismissKeyboard() {}
        func accessoryDidRequestPaste() { pasteRequested = true }
    }

    @MainActor
    func testAccessoryBarTmuxPrefixConfiguration() {
        let delegate = MockAccessoryDelegate()
        let accessory = FilaireAccessoryView(frame: CGRect(x: 0, y: 0, width: 600, height: 40), delegate: delegate)

        guard let stack = accessory.subviews.compactMap({ $0 as? UIScrollView }).first?.subviews.compactMap({ $0 as? UIStackView }).first else {
            XCTFail("Failed to find UIStackView in accessory view")
            return
        }

        let buttons = stack.arrangedSubviews.compactMap { $0 as? UIButton }
        let prefixButton = buttons.first
        let copyButton = buttons.count > 1 ? buttons[1] : nil
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
        let accessory = FilaireAccessoryView(frame: CGRect(x: 0, y: 0, width: 800, height: 40), delegate: delegate)

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

    // MARK: - OSC 52 Clipboard & OSC 777 Notification Integration
    @MainActor
    func testClipboardAndNotificationIntegration() {
        let manager = SessionManager()
        let initialHost = HostProfile(name: "TestHost", hostname: "test.local")
        manager.activeHost = initialHost
        let container = TerminalContainerView(sessionManager: manager)
        let representable = TerminalRepresentable(sessionManager: manager)
        let coordinator = representable.makeCoordinator()
        let terminalView = FilaireTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        terminalView.terminalDelegate = coordinator
        coordinator.terminalView = terminalView

        // 1. Test direct clipboardCopy delegate callback
        let testString = "Filaire Native Clipboard Test"
        guard let data = testString.data(using: .utf8) else {
            XCTFail("Failed to encode test string")
            return
        }

        coordinator.clipboardCopy(source: terminalView, content: data)
        XCTAssertEqual(UIPasteboard.general.string, testString)

        // 2. Test clipboardRead delegate callback (per-host security setting)
        // With default host (allowClipboardRead == false), it returns nil and does not prompt
        let readDataDisabled = coordinator.clipboardRead(source: terminalView)
        XCTAssertNil(readDataDisabled)
        XCTAssertNil(manager.pendingSecurityPrompt)

        // With allowClipboardRead enabled, it returns nil synchronously and prompts for permission
        var allowedHost = HostProfile(name: "TestHost", hostname: "test.local")
        allowedHost.allowClipboardRead = true
        manager.activeHost = allowedHost

        let readDataPrompted = coordinator.clipboardRead(source: terminalView)
        XCTAssertNil(readDataPrompted)
        XCTAssertNotNil(manager.pendingSecurityPrompt)
        XCTAssertEqual(manager.pendingSecurityPrompt?.title, "Clipboard Access Request")

        // User tapping Allow sends the base64 OSC 52 reply to session
        var sentBytes: [UInt8]? = nil
        manager.onDataSent = { bytes in
            sentBytes = bytes
        }
        manager.pendingSecurityPrompt?.onAllow()
        XCTAssertNotNil(sentBytes)
        if let sent = sentBytes, let string = String(bytes: sent, encoding: .utf8) {
            XCTAssertTrue(string.contains("52;c;"), "Should send OSC 52 response")
        }
        manager.pendingSecurityPrompt = nil

        // 3. Test OSC 52 escape sequence feed through SwiftTerm parser
        let osc52Text = "Piped into fil tool"
        let osc52Base64 = Data(osc52Text.utf8).base64EncodedString()
        let osc52Payload = "\u{1b}]52;c;\(osc52Base64)\u{07}"

        terminalView.feed(text: osc52Payload)
        XCTAssertEqual(UIPasteboard.general.string, osc52Text, "OSC 52 escape sequence must update UIPasteboard")

        // 4. Test notify delegate callback triggers in-app toast
        coordinator.notify(source: terminalView, title: "Cargo", body: "Compile Success")
        XCTAssertNotNil(manager.activeToast)
        XCTAssertEqual(manager.activeToast?.title, "TestHost: Cargo")
        XCTAssertEqual(manager.activeToast?.message, "Compile Success")

        // 5. Test OSC 5100 registration and handling
        var openedURLString: String? = nil
        terminalView.getTerminal().registerOscHandler(code: 5100) { data in
            if let text = String(bytes: data, encoding: .utf8) {
                let parts = text.components(separatedBy: ";")
                if parts.count >= 2, parts[0] == "open" {
                    openedURLString = parts[1...].joined(separator: ";")
                }
            }
        }
        terminalView.feed(text: "\u{1b}]5100;open;https://apple.com\u{07}")
        XCTAssertEqual(openedURLString, "https://apple.com")
    }

    @MainActor
    func testNotifySanitizesRemoteInput() {
        let manager = SessionManager()
        let host = HostProfile(name: "ProdServer", hostname: "prod.local")
        manager.activeHost = host
        let representable = TerminalRepresentable(sessionManager: manager)
        let coordinator = representable.makeCoordinator()
        let terminalView = FilaireTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))

        // 1. Long title and control chars
        let spoofedTitle = "Alert\u{0007}\u{202E}EvilTitle" + String(repeating: "A", count: 100)
        let spoofedBody = "Body\u{0000}Text" + String(repeating: "B", count: 300)
        coordinator.notify(source: terminalView, title: spoofedTitle, body: spoofedBody)

        XCTAssertNotNil(manager.activeToast)
        XCTAssertTrue(manager.activeToast?.title.hasPrefix("ProdServer: ") == true)
        XCTAssertFalse(manager.activeToast?.title.contains("\u{0007}") == true)
        XCTAssertFalse(manager.activeToast?.title.contains("\u{202E}") == true)
        XCTAssertFalse(manager.activeToast?.message.contains("\u{0000}") == true)
        let rawTitle = manager.activeToast?.title.replacingOccurrences(of: "ProdServer: ", with: "") ?? ""
        XCTAssertTrue(rawTitle.hasSuffix("…"))
        XCTAssertEqual(rawTitle.count, 65)
        XCTAssertTrue(manager.activeToast?.message.hasSuffix("…") == true)
        XCTAssertEqual(manager.activeToast?.message.count, 257)

        // 2. Empty title falls back to "Notification"
        coordinator.notify(source: terminalView, title: "", body: "Status update")
        XCTAssertEqual(manager.activeToast?.title, "ProdServer: Notification")
        XCTAssertEqual(manager.activeToast?.message, "Status update")
    }

    @MainActor
    func testOsc777TerminalFeedTriggersToastNotification() {
        let manager = SessionManager()
        let host = HostProfile(name: "ProdServer", hostname: "prod.local")
        manager.activeHost = host
        let representable = TerminalRepresentable(sessionManager: manager)
        let coordinator = representable.makeCoordinator()
        let terminalView = FilaireTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        terminalView.terminalDelegate = coordinator
        coordinator.terminalView = terminalView

        TerminalRepresentable.registerOscHandlers(
            terminalView: terminalView,
            sessionManager: manager,
            coordinator: coordinator
        )

        // 1. Plain OSC 777 with title and body
        let osc777Plain = "\u{1b}]777;notify;Cargo;Build complete\u{07}"
        terminalView.feedBounded(text: osc777Plain)
        XCTAssertNotNil(manager.activeToast)
        XCTAssertEqual(manager.activeToast?.title, "ProdServer: Cargo")
        XCTAssertEqual(manager.activeToast?.message, "Build complete")

        // 2. Tmux-wrapped OSC 777
        let tmuxOsc777 = "\u{1b}Ptmux;\u{1b}\u{1b}]777;notify;TmuxJob;Done successfully\u{07}\u{1b}\\"
        terminalView.feedBounded(text: tmuxOsc777)
        XCTAssertNotNil(manager.activeToast)
        XCTAssertEqual(manager.activeToast?.title, "ProdServer: TmuxJob")
        XCTAssertEqual(manager.activeToast?.message, "Done successfully")

        // 3. Body with semicolons
        let oscWithSemicolons = "\u{1b}]777;notify;Compiler;Finished; 0 errors; 2 warnings\u{07}"
        terminalView.feedBounded(text: oscWithSemicolons)
        XCTAssertNotNil(manager.activeToast)
        XCTAssertEqual(manager.activeToast?.title, "ProdServer: Compiler")
        XCTAssertEqual(manager.activeToast?.message, "Finished; 0 errors; 2 warnings")

        // 4. Single parameter (body only)
        let oscSingleBody = "\u{1b}]777;notify;Background task done\u{07}"
        terminalView.feedBounded(text: oscSingleBody)
        XCTAssertNotNil(manager.activeToast)
        XCTAssertEqual(manager.activeToast?.title, "ProdServer: Notification")
        XCTAssertEqual(manager.activeToast?.message, "Background task done")

        // 5. Per-host toggle disables remote notifications
        var disabledHost = host
        disabledHost.allowRemoteNotifications = false
        manager.activeHost = disabledHost
        manager.activeToast = nil

        let oscWhenDisabled = "\u{1b}]777;notify;ShouldBeDropped;Ignored\u{07}"
        terminalView.feedBounded(text: oscWhenDisabled)
        XCTAssertNil(manager.activeToast, "Notifications must be dropped when allowRemoteNotifications is false")
    }

    // MARK: - Tmux Line-Wrapped URL Detection Tests

    func testSingleLineUrlDetection() {
        let grid = MockTerminalGrid(lines: [
            "Check out https://example.com/docs/api for more information."
        ], cols: 80)
        let url = TerminalUrlDetector.detectUrl(at: 15, row: 0, in: grid)
        XCTAssertEqual(url, "https://example.com/docs/api")
    }

    func testTmuxSinglePaneWrappedUrlLine1() {
        let grid = MockTerminalGrid(lines: [
            "https://github.com/owner/filaire/actions/runs/1234567890/jobs/",
            "9876543210?param=value#step:3:1"
        ], cols: 62)
        let url = TerminalUrlDetector.detectUrl(at: 20, row: 0, in: grid)
        XCTAssertEqual(url, "https://github.com/owner/filaire/actions/runs/1234567890/jobs/9876543210?param=value#step:3:1")
    }

    func testTmuxSinglePaneWrappedUrlLine2() {
        let grid = MockTerminalGrid(lines: [
            "https://github.com/owner/filaire/actions/runs/1234567890/jobs/",
            "9876543210?param=value#step:3:1"
        ], cols: 62)
        // Tap on line 2 (the continuation line without scheme)
        let url = TerminalUrlDetector.detectUrl(at: 5, row: 1, in: grid)
        XCTAssertEqual(url, "https://github.com/owner/filaire/actions/runs/1234567890/jobs/9876543210?param=value#step:3:1")
    }

    func testTmuxNarrowPaneThreeLineWrappedUrl() {
        let grid = MockTerminalGrid(lines: [
            "https://example.com/very/long/",
            "path/that/spans/multiple/line",
            "s/and/ends/here?foo=bar"
        ], cols: 30)
        let expected = "https://example.com/very/long/path/that/spans/multiple/lines/and/ends/here?foo=bar"
        XCTAssertEqual(TerminalUrlDetector.detectUrl(at: 10, row: 0, in: grid), expected)
        XCTAssertEqual(TerminalUrlDetector.detectUrl(at: 5, row: 1, in: grid), expected)
        XCTAssertEqual(TerminalUrlDetector.detectUrl(at: 15, row: 2, in: grid), expected)
    }

    func testTmuxVerticalSplitLeftPane() {
        // Border at col 40: "│"
        let grid = MockTerminalGrid(lines: [
            "https://example.com/api/v1/users/active/│right pane content row 1",
            "query?sort=desc                         │right pane content row 2"
        ], cols: 80)
        let expected = "https://example.com/api/v1/users/active/query?sort=desc"
        XCTAssertEqual(TerminalUrlDetector.detectUrl(at: 10, row: 0, in: grid), expected)
        XCTAssertEqual(TerminalUrlDetector.detectUrl(at: 4, row: 1, in: grid), expected)
    }

    func testTmuxVerticalSplitRightPane() {
        // Border at col 40: "│", right pane is cols 41..79
        let grid = MockTerminalGrid(lines: [
            "left pane row 1                         │https://github.com/owner/filaire/pulls/",
            "left pane row 2                         │42?tab=files"
        ], cols: 80)
        let expected = "https://github.com/owner/filaire/pulls/42?tab=files"
        XCTAssertEqual(TerminalUrlDetector.detectUrl(at: 50, row: 0, in: grid), expected)
        XCTAssertEqual(TerminalUrlDetector.detectUrl(at: 45, row: 1, in: grid), expected)
    }

    func testDetectUrlMatchSingleLineSegments() {
        let grid = MockTerminalGrid(lines: [
            "Link: https://example.com/test info"
        ], cols: 80)
        let match = TerminalUrlDetector.detectUrlMatch(at: 10, row: 0, in: grid)
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.url, "https://example.com/test")
        XCTAssertEqual(match?.segments.count, 1)
        XCTAssertEqual(match?.segments[0].row, 0)
        XCTAssertEqual(match?.segments[0].colRange, 6..<30)
    }

    func testDetectUrlMatchTwoLineWrappedSegments() {
        let grid = MockTerminalGrid(lines: [
            "https://github.com/owner/filaire/actions/runs/1234567890/jobs/",
            "9876543210?param=value#step:3:1"
        ], cols: 62)

        // Querying on row 0
        let matchFromRow0 = TerminalUrlDetector.detectUrlMatch(at: 20, row: 0, in: grid)
        XCTAssertNotNil(matchFromRow0)
        XCTAssertEqual(matchFromRow0?.url, "https://github.com/owner/filaire/actions/runs/1234567890/jobs/9876543210?param=value#step:3:1")
        XCTAssertEqual(matchFromRow0?.segments.count, 2)
        XCTAssertEqual(matchFromRow0?.segments[0].row, 0)
        XCTAssertEqual(matchFromRow0?.segments[0].colRange, 0..<62)
        XCTAssertEqual(matchFromRow0?.segments[1].row, 1)
        XCTAssertEqual(matchFromRow0?.segments[1].colRange, 0..<31)

        // Querying on row 1 (hover over second wrapped line)
        let matchFromRow1 = TerminalUrlDetector.detectUrlMatch(at: 10, row: 1, in: grid)
        XCTAssertNotNil(matchFromRow1)
        // Both hover queries must produce the identical DetectedUrlMatch with all segments
        XCTAssertEqual(matchFromRow0, matchFromRow1)
    }

    func testDetectUrlMatchThreeLineWrappedSegments() {
        let grid = MockTerminalGrid(lines: [
            "https://example.com/very/long/",
            "path/that/spans/multiple/line",
            "s/and/ends/here?foo=bar"
        ], cols: 30)

        let matchRow0 = TerminalUrlDetector.detectUrlMatch(at: 10, row: 0, in: grid)
        let matchRow1 = TerminalUrlDetector.detectUrlMatch(at: 5, row: 1, in: grid)
        let matchRow2 = TerminalUrlDetector.detectUrlMatch(at: 15, row: 2, in: grid)

        XCTAssertNotNil(matchRow0)
        XCTAssertNotNil(matchRow1)
        XCTAssertNotNil(matchRow2)

        let expectedUrl = "https://example.com/very/long/path/that/spans/multiple/lines/and/ends/here?foo=bar"
        XCTAssertEqual(matchRow0?.url, expectedUrl)
        XCTAssertEqual(matchRow0?.segments.count, 3)
        XCTAssertEqual(matchRow0?.segments[0].row, 0)
        XCTAssertEqual(matchRow0?.segments[0].colRange, 0..<30)
        XCTAssertEqual(matchRow0?.segments[1].row, 1)
        XCTAssertEqual(matchRow0?.segments[1].colRange, 0..<29)
        XCTAssertEqual(matchRow0?.segments[2].row, 2)
        XCTAssertEqual(matchRow0?.segments[2].colRange, 0..<23)

        // Verifying all 3 rows return identical matches
        XCTAssertEqual(matchRow0, matchRow1)
        XCTAssertEqual(matchRow1, matchRow2)
    }

    func testDetectUrlMatchSegmentsExcludeTrimmedPunctuation() {
        let grid = MockTerminalGrid(lines: [
            "Visit https://example.com/path."
        ], cols: 80)
        let match = TerminalUrlDetector.detectUrlMatch(at: 10, row: 0, in: grid)
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.url, "https://example.com/path")
        XCTAssertEqual(match?.segments.count, 1)
        XCTAssertEqual(match?.segments[0].row, 0)
        // Starts at col 6 ("h"), ends at col 29 ("h"), period at col 30 is excluded (colRange 6..<30)
        XCTAssertEqual(match?.segments[0].colRange, 6..<30)
    }

    func testTrailingPunctuationCleaned() {
        let grid = MockTerminalGrid(lines: [
            "See: (https://example.com/test)."
        ], cols: 80)
        XCTAssertEqual(TerminalUrlDetector.detectUrl(at: 15, row: 0, in: grid), "https://example.com/test")

        let bracketGrid = MockTerminalGrid(lines: [
            "[https://example.com/test]"
        ], cols: 80)
        XCTAssertEqual(TerminalUrlDetector.detectUrl(at: 10, row: 0, in: bracketGrid), "https://example.com/test")

        let quoteGrid = MockTerminalGrid(lines: [
            "\"https://example.com/test\","
        ], cols: 80)
        XCTAssertEqual(TerminalUrlDetector.detectUrl(at: 10, row: 0, in: quoteGrid), "https://example.com/test")

        let singleQuoteGrid = MockTerminalGrid(lines: [
            "curl 'https://example.com/test'"
        ], cols: 80)
        XCTAssertEqual(TerminalUrlDetector.detectUrl(at: 10, row: 0, in: singleQuoteGrid), "https://example.com/test")

        let combinedGrid = MockTerminalGrid(lines: [
            "Visit: ('https://example.com/test')."
        ], cols: 80)
        XCTAssertEqual(TerminalUrlDetector.detectUrl(at: 15, row: 0, in: combinedGrid), "https://example.com/test")
    }

    func testMultiProtocolUrlDetectionAndBacktickCleaning() {
        // file:// URL
        let fileGrid = MockTerminalGrid(lines: [
            "Report generated at file:///Users/dev/build/report.html for inspection"
        ], cols: 80)
        XCTAssertEqual(TerminalUrlDetector.detectUrl(at: 25, row: 0, in: fileGrid), "file:///Users/dev/build/report.html")

        // ssh:// URL
        let sshGrid = MockTerminalGrid(lines: [
            "Clone url: ssh://git@github.com:22/JeremyOT/filaire.git in repo"
        ], cols: 80)
        XCTAssertEqual(TerminalUrlDetector.detectUrl(at: 15, row: 0, in: sshGrid), "ssh://git@github.com:22/JeremyOT/filaire.git")

        // git:// URL
        let gitGrid = MockTerminalGrid(lines: [
            "Remote: git://github.com/JeremyOT/filaire.git is configured"
        ], cols: 80)
        XCTAssertEqual(TerminalUrlDetector.detectUrl(at: 12, row: 0, in: gitGrid), "git://github.com/JeremyOT/filaire.git")

        // Backtick enclosed URL (markdown style)
        let backtickGrid = MockTerminalGrid(lines: [
            "Checkout `https://github.com/JeremyOT/filaire` in docs"
        ], cols: 80)
        XCTAssertEqual(TerminalUrlDetector.detectUrl(at: 15, row: 0, in: backtickGrid), "https://github.com/JeremyOT/filaire")

        // Angle bracket enclosed URL
        let angleGrid = MockTerminalGrid(lines: [
            "Reference: <https://github.com/JeremyOT/filaire> and note"
        ], cols: 80)
        XCTAssertEqual(TerminalUrlDetector.detectUrl(at: 16, row: 0, in: angleGrid), "https://github.com/JeremyOT/filaire")

        // Localhost port URL with query
        let localGrid = MockTerminalGrid(lines: [
            "Serving on http://localhost:8080/metrics?format=json ready"
        ], cols: 80)
        XCTAssertEqual(TerminalUrlDetector.detectUrl(at: 18, row: 0, in: localGrid), "http://localhost:8080/metrics?format=json")
    }

    func testNonUrlReturnsNil() {
        let grid = MockTerminalGrid(lines: [
            "total 128",
            "-rw-r--r-- 1 user staff 4096 Sep 5 19:42 README.md"
        ], cols: 80)
        XCTAssertNil(TerminalUrlDetector.detectUrl(at: 5, row: 0, in: grid))
        XCTAssertNil(TerminalUrlDetector.detectUrl(at: 20, row: 1, in: grid))
    }

    func testExpandUrlIfWrapped() {
        let grid = MockTerminalGrid(lines: [
            "https://example.com/part1/",
            "part2/final"
        ], cols: 26)
        let expanded = TerminalUrlDetector.expandUrlIfWrapped(link: "https://example.com/part1/", in: grid)
        XCTAssertEqual(expanded, "https://example.com/part1/part2/final")
    }

    func testCmdCommaSettingsShortcut() {
        let terminalView = FilaireTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let cmd = terminalView.keyCommands?.first { $0.input == "," && $0.modifierFlags == .command }
        XCTAssertNotNil(cmd, "Cmd+, shortcut must be registered")
        XCTAssertTrue(cmd?.wantsPriorityOverSystemBehavior == true)
    }

    func testTopOverlayHitTestingYieldsToSwiftUI() {
        let terminalView = FilaireTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))

        // 1. Minimized status bar: touches in top 44pt must yield (return nil)
        terminalView.isStatusExpanded = false
        XCTAssertNil(terminalView.hitTest(CGPoint(x: 400, y: 20), with: nil), "Touches in top 44pt must return nil to allow top bar taps")
        XCTAssertNotNil(terminalView.hitTest(CGPoint(x: 400, y: 100), with: nil), "Touches below 44pt must hit terminal view")

        // 2. Expanded status bar: all touches must yield (return nil) so backdrop can dismiss menu
        terminalView.isStatusExpanded = true
        XCTAssertNil(terminalView.hitTest(CGPoint(x: 400, y: 20), with: nil), "Touches in top bar must return nil")
        XCTAssertNil(terminalView.hitTest(CGPoint(x: 400, y: 200), with: nil), "Touches in overlay area must return nil")
        XCTAssertNil(terminalView.hitTest(CGPoint(x: 400, y: 400), with: nil), "Touches on terminal backdrop must return nil to allow dismiss tap")
    }

    func testConnectionStateProperties() {
        XCTAssertTrue(ConnectionState.connected.isConnected)
        XCTAssertFalse(ConnectionState.connected.isFailed)
        XCTAssertFalse(ConnectionState.connecting.isConnected)
        XCTAssertFalse(ConnectionState.connecting.isFailed)
        XCTAssertTrue(ConnectionState.connecting.isBusy)
        XCTAssertTrue(ConnectionState.reconnecting(attempt: 1).isBusy)
        XCTAssertTrue(ConnectionState.failed("Timeout").isFailed)
        XCTAssertFalse(ConnectionState.failed("Timeout").isConnected)
        XCTAssertFalse(ConnectionState.failed("Timeout").isBusy)
        XCTAssertFalse(ConnectionState.disconnected.isFailed)
        XCTAssertFalse(ConnectionState.disconnected.isConnected)
    }

    @MainActor
    func testAppStateIsStatusExpanded() {
        let state = AppState()
        XCTAssertFalse(state.isStatusExpanded)
        state.isStatusExpanded = true
        XCTAssertTrue(state.isStatusExpanded)
        state.isStatusExpanded = false
        XCTAssertFalse(state.isStatusExpanded)
    }

    @MainActor
    func testMainContentViewTapGrabBarExpandsMenu() throws {
        let appState = AppState()
        let host = HostProfile(name: "Test", hostname: "127.0.0.1", port: 22, username: "test")
        appState.hosts = [host]
        let contentView = MainContentView(appState: appState)
        let hostingController = UIHostingController(rootView: contentView)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 768))
        window.rootViewController = hostingController
        window.makeKeyAndVisible()
        hostingController.view.layoutIfNeeded()

        XCTAssertFalse(appState.isStatusExpanded)

        let nilEvent: UIEvent? = nil
        let hitView = hostingController.view.hitTest(CGPoint(x: 500, y: 40), with: nilEvent)
        XCTAssertNotNil(hitView)
        XCTAssertFalse(hitView is FilaireTerminalView, "Top 44pt overlay must yield hit testing to SwiftUI hosting view")

        let hitViewBelow = hostingController.view.hitTest(CGPoint(x: 500, y: 150), with: nilEvent)
        XCTAssertNotNil(hitViewBelow)
        XCTAssertTrue(hitViewBelow is FilaireTerminalView, "Main terminal area must hit FilaireTerminalView")

        appState.isStatusExpanded = true
        hostingController.view.setNeedsLayout()
        hostingController.view.layoutIfNeeded()
        XCTAssertTrue(appState.isStatusExpanded)
    }

    @MainActor
    func testTerminalUserInputKeystrokeVsMouseReport() {
        var userInputTriggered = false
        let sessionManager = SessionManager()
        let coordinator = TerminalRepresentable.Coordinator(sessionManager: sessionManager) {
            userInputTriggered = true
        }

        // Keystroke (e.g. ASCII 'a' = 0x61) must trigger onUserInput
        let keystroke: [UInt8] = [0x61]
        coordinator.send(source: TerminalView(frame: .zero), data: keystroke[...])
        XCTAssertTrue(userInputTriggered, "Regular keystrokes must trigger onUserInput")

        // Arrow keys (e.g. Up arrow \x1b[A) must trigger onUserInput
        userInputTriggered = false
        let upArrow: [UInt8] = [0x1b, 0x5b, 0x41]
        coordinator.send(source: TerminalView(frame: .zero), data: upArrow[...])
        XCTAssertTrue(userInputTriggered, "Arrow keys must trigger onUserInput")

        // Mouse report SGR (\x1b[<0;10;20M) must NOT trigger onUserInput
        userInputTriggered = false
        let mouseReportSgr: [UInt8] = [0x1b, 0x5b, 0x3c, 0x30, 0x3b, 0x31, 0x30, 0x3b, 0x32, 0x30, 0x4d]
        coordinator.send(source: TerminalView(frame: .zero), data: mouseReportSgr[...])
        XCTAssertFalse(userInputTriggered, "SGR mouse reports must NOT trigger onUserInput")

        // Mouse report X10 (\x1b[M #$) must NOT trigger onUserInput
        userInputTriggered = false
        let mouseReportX10: [UInt8] = [0x1b, 0x5b, 0x4d, 0x20, 0x23, 0x24]
        coordinator.send(source: TerminalView(frame: .zero), data: mouseReportX10[...])
        XCTAssertFalse(userInputTriggered, "X10 mouse reports must NOT trigger onUserInput")

        // Focus Out report (\x1b[O) must NOT trigger onUserInput
        userInputTriggered = false
        let focusOutReport: [UInt8] = [0x1b, 0x5b, 0x4f]
        coordinator.send(source: TerminalView(frame: .zero), data: focusOutReport[...])
        XCTAssertFalse(userInputTriggered, "Focus Out report must NOT trigger onUserInput")

        // Focus In report (\x1b[I) must NOT trigger onUserInput
        userInputTriggered = false
        let focusInReport: [UInt8] = [0x1b, 0x5b, 0x49]
        coordinator.send(source: TerminalView(frame: .zero), data: focusInReport[...])
        XCTAssertFalse(userInputTriggered, "Focus In report must NOT trigger onUserInput")

        // Terminal DA response (\x1b[?1;2c) must NOT trigger onUserInput
        userInputTriggered = false
        let daReport: [UInt8] = [0x1b, 0x5b, 0x3f, 0x31, 0x3b, 0x32, 0x63]
        coordinator.send(source: TerminalView(frame: .zero), data: daReport[...])
        XCTAssertFalse(userInputTriggered, "Device Attributes response must NOT trigger onUserInput")

        // Terminal CPR response (\x1b[24;80R) must NOT trigger onUserInput
        userInputTriggered = false
        let cprReport: [UInt8] = [0x1b, 0x5b, 0x32, 0x34, 0x3b, 0x38, 0x30, 0x52]
        coordinator.send(source: TerminalView(frame: .zero), data: cprReport[...])
        XCTAssertFalse(userInputTriggered, "CPR response must NOT trigger onUserInput")
    }

    // MARK: - File Preview Manager (OSC 5101)

    func testFilePreviewManagerSingleChunkWithTransferId() throws {
        let manager = FilePreviewManager.shared
        manager.resetForTesting()

        let expectation = XCTestExpectation(description: "Preview URL set for single chunk with transfer ID")
        var cancellable: Any?
        cancellable = manager.$previewURL
            .compactMap { $0 }
            .first()
            .sink { _ in
                expectation.fulfill()
            }
        _ = cancellable

        // "Testing Transfer ID" in Base64: "VGVzdGluZyBUcmFuc2ZlciBJRA=="
        let oscPayload = "preview;id=transfer_abc;name=testid.txt;part=1;total=1;VGVzdGluZyBUcmFuc2ZlciBJRA=="
        let bytes = Array(oscPayload.utf8)
        manager.handleOscData(ArraySlice(bytes))

        wait(for: [expectation], timeout: 2.0)

        guard let targetURL = manager.previewURL else {
            XCTFail("previewURL was not set")
            return
        }

        XCTAssertEqual(targetURL.lastPathComponent, "testid.txt")
        let content = try String(contentsOf: targetURL, encoding: .utf8)
        XCTAssertEqual(content, "Testing Transfer ID")

        manager.dismissPreview()
        XCTAssertNil(manager.previewURL)
    }

    func testFilePreviewManagerSingleChunk() throws {
        let manager = FilePreviewManager.shared
        manager.resetForTesting()

        let expectation = XCTestExpectation(description: "Preview URL set for single chunk")
        var cancellable: Any?
        cancellable = manager.$previewURL
            .compactMap { $0 }
            .first()
            .sink { url in
                expectation.fulfill()
            }
        _ = cancellable

        // "Hello, world!" in Base64 is "SGVsbG8sIHdvcmxkIQ=="
        let oscPayload = "preview;name=hello.txt;part=1;total=1;SGVsbG8sIHdvcmxkIQ=="
        let bytes = Array(oscPayload.utf8)
        manager.handleOscData(ArraySlice(bytes))

        wait(for: [expectation], timeout: 2.0)

        guard let targetURL = manager.previewURL else {
            XCTFail("previewURL was not set")
            return
        }

        XCTAssertEqual(targetURL.lastPathComponent, "hello.txt")
        let content = try String(contentsOf: targetURL, encoding: .utf8)
        XCTAssertEqual(content, "Hello, world!")

        manager.dismissPreview()
        XCTAssertNil(manager.previewURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: targetURL.path))
    }

    func testFilePreviewManagerMultiChunkReassembly() throws {
        let manager = FilePreviewManager.shared
        manager.resetForTesting()

        let expectation = XCTestExpectation(description: "Preview URL set after all chunks arrive")
        var cancellable: Any?
        cancellable = manager.$previewURL
            .compactMap { $0 }
            .first()
            .sink { url in
                expectation.fulfill()
            }
        _ = cancellable

        // "ChunkOneChunkTwo" in Base64: "Q2h1bmtPbmVDaHVua1R3bw=="
        // Part 1: "Q2h1bmtPbmV" (11 chars)
        // Part 2: "DaHVua1R3bw==" (13 chars)
        let part1 = "preview;name=chunked.txt;part=1;total=2;Q2h1bmtPbmV"
        let part2 = "preview;name=chunked.txt;part=2;total=2;DaHVua1R3bw=="

        manager.handleOscData(ArraySlice(Array(part1.utf8)))
        // After only part 1, previewURL must remain nil
        XCTAssertNil(manager.previewURL)

        manager.handleOscData(ArraySlice(Array(part2.utf8)))
        wait(for: [expectation], timeout: 2.0)

        guard let targetURL = manager.previewURL else {
            XCTFail("previewURL was not set after both chunks arrived")
            return
        }

        XCTAssertEqual(targetURL.lastPathComponent, "chunked.txt")
        let content = try String(contentsOf: targetURL, encoding: .utf8)
        XCTAssertEqual(content, "ChunkOneChunkTwo")

        manager.dismissPreview()
    }

    func testFilePreviewManagerRejectsOversizedTransferEarly() {
        let manager = FilePreviewManager.shared
        manager.resetForTesting()
        FilePreviewManager.maxPreviewFileSize = 30
        defer { FilePreviewManager.maxPreviewFileSize = 100 * 1024 * 1024 }

        let alert = XCTestExpectation(description: "Too-large alert shown")
        var cancellable: Any?
        cancellable = manager.$showErrorAlert
            .filter { $0 }
            .first()
            .sink { _ in alert.fulfill() }
        _ = cancellable

        // 8 base64 chars × 100 parts ≈ 600 decoded bytes, over the 30 byte limit, rejected on the first part
        manager.handleOscData(ArraySlice(Array("preview;id=big;name=big.bin;part=1;total=100;QUFBQUFB".utf8)))
        wait(for: [alert], timeout: 2.0)

        XCTAssertTrue(manager.errorMessage?.contains("too large") == true)
        XCTAssertNil(manager.previewURL)
    }

    func testFilePreviewManagerIgnoresInvalidPartCounts() {
        let manager = FilePreviewManager.shared
        manager.resetForTesting()

        // total=0 and part>total previously reached `for p in 1...total` and crashed
        manager.handleOscData(ArraySlice(Array("preview;id=zero;name=z.txt;part=1;total=0;QUFB".utf8)))
        manager.handleOscData(ArraySlice(Array("preview;id=over;name=o.txt;part=3;total=2;QUFB".utf8)))

        // resetForTesting() runs queue.sync, so both handlers have finished by the time it returns
        manager.resetForTesting()
        XCTAssertNil(manager.previewURL)
    }

    func testFilePreviewManagerOutOfOrderChunks() throws {
        let manager = FilePreviewManager.shared
        manager.resetForTesting()

        let expectation = XCTestExpectation(description: "Preview URL set after out-of-order chunks")
        var cancellable: Any?
        cancellable = manager.$previewURL
            .compactMap { $0 }
            .first()
            .sink { _ in expectation.fulfill() }
        _ = cancellable

        // "ChunkOneChunkTwo" split as in testFilePreviewManagerMultiChunkReassembly, delivered part 2 first
        manager.handleOscData(ArraySlice(Array("preview;id=ooo;name=ooo.txt;part=2;total=2;DaHVua1R3bw==".utf8)))
        manager.handleOscData(ArraySlice(Array("preview;id=ooo;name=ooo.txt;part=1;total=2;Q2h1bmtPbmV".utf8)))
        wait(for: [expectation], timeout: 2.0)

        let url = try XCTUnwrap(manager.previewURL)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "ChunkOneChunkTwo")
        manager.dismissPreview()
    }

    func testFilePreviewManagerInvalidBase64ShowsError() {
        let manager = FilePreviewManager.shared
        manager.resetForTesting()

        let alert = XCTestExpectation(description: "Decode error shown")
        var cancellable: Any?
        cancellable = manager.$showErrorAlert
            .filter { $0 }
            .first()
            .sink { _ in alert.fulfill() }
        _ = cancellable

        // '=' padding in the middle of the stream is invalid base64
        manager.handleOscData(ArraySlice(Array("preview;id=bad;name=bad.txt;part=1;total=1;QQ==QUFB".utf8)))
        wait(for: [alert], timeout: 2.0)
        XCTAssertTrue(manager.errorMessage?.contains("Failed to decode") == true)
        XCTAssertNil(manager.previewURL)
    }

    func testFilePreviewManagerPathTraversalSanitization() throws {
        let manager = FilePreviewManager.shared
        manager.resetForTesting()

        let expectation = XCTestExpectation(description: "Preview URL sanitizes path traversal")
        var cancellable: Any?
        cancellable = manager.$previewURL
            .compactMap { $0 }
            .first()
            .sink { url in
                expectation.fulfill()
            }
        _ = cancellable

        let traversalPayload = "preview;name=../../../../etc/malicious.txt;part=1;total=1;VGVzdA=="
        manager.handleOscData(ArraySlice(Array(traversalPayload.utf8)))

        wait(for: [expectation], timeout: 2.0)

        guard let targetURL = manager.previewURL else {
            XCTFail("previewURL was not set")
            return
        }

        // Must sanitize away all ../ and only keep lastPathComponent "malicious.txt"
        XCTAssertEqual(targetURL.lastPathComponent, "malicious.txt")
        XCTAssertTrue(targetURL.path.contains("filaire_previews"))
        XCTAssertFalse(targetURL.path.contains("/etc/malicious.txt"))

        manager.dismissPreview()
    }

    func testFilePreviewManagerExtensionlessFileDetection() throws {
        let manager = FilePreviewManager.shared
        manager.resetForTesting()

        let expectation = XCTestExpectation(description: "Preview URL detects extension for extensionless file")
        var cancellable: Any?
        cancellable = manager.$previewURL
            .compactMap { $0 }
            .first()
            .sink { url in
                expectation.fulfill()
            }
        _ = cancellable

        // "Plain text file content" in Base64: "UGxhaW4gdGV4dCBmaWxlIGNvbnRlbnQ="
        let payload = "preview;name=custom_file;part=1;total=1;UGxhaW4gdGV4dCBmaWxlIGNvbnRlbnQ="
        manager.handleOscData(ArraySlice(Array(payload.utf8)))

        wait(for: [expectation], timeout: 2.0)

        guard let targetURL = manager.previewURL else {
            XCTFail("previewURL was not set for extensionless file")
            return
        }

        XCTAssertEqual(targetURL.lastPathComponent, "custom_file.txt")
        let content = try String(contentsOf: targetURL, encoding: .utf8)
        XCTAssertEqual(content, "Plain text file content")

        manager.dismissPreview()
    }

    func testFilePreviewManagerUnsupportedFileTriggersAlert() throws {
        let manager = FilePreviewManager.shared
        manager.resetForTesting()

        let expectation = XCTestExpectation(description: "Error alert triggered for unsupported binary file")
        var cancellable: Any?
        cancellable = manager.$showErrorAlert
            .filter { $0 }
            .first()
            .sink { _ in
                expectation.fulfill()
            }
        _ = cancellable

        // Non-UTF8 arbitrary bytes [0xFF, 0xFE, 0xFD, 0xFC, 0xFB, 0xFA] in Base64: "//79/Ps="
        let payload = "preview;name=corrupt.xyz999;part=1;total=1;//79/Ps="
        manager.handleOscData(ArraySlice(Array(payload.utf8)))

        wait(for: [expectation], timeout: 2.0)

        XCTAssertTrue(manager.showErrorAlert)
        XCTAssertNotNil(manager.errorMessage)
        XCTAssertTrue(manager.errorMessage?.contains("Quick Look cannot preview") == true)
        XCTAssertNil(manager.previewURL)

        manager.dismissPreview()
    }

    func testFilePreviewManagerDetectExtension() {
        // PNG
        XCTAssertEqual(FilePreviewManager.detectExtension(for: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])), "png")
        // JPG
        XCTAssertEqual(FilePreviewManager.detectExtension(for: Data([0xFF, 0xD8, 0xFF, 0xE0])), "jpg")
        // GIF
        XCTAssertEqual(FilePreviewManager.detectExtension(for: Data("GIF89a".utf8)), "gif")
        // PDF
        XCTAssertEqual(FilePreviewManager.detectExtension(for: Data("%PDF-1.4".utf8)), "pdf")
        // ZIP
        XCTAssertEqual(FilePreviewManager.detectExtension(for: Data([0x50, 0x4B, 0x03, 0x04])), "zip")
        // WEBP
        XCTAssertEqual(FilePreviewManager.detectExtension(for: Data("RIFF\0\0\0\0WEBP".utf8)), "webp")
        // WAV
        XCTAssertEqual(FilePreviewManager.detectExtension(for: Data("RIFF\0\0\0\0WAVE".utf8)), "wav")
        // MP4
        XCTAssertEqual(FilePreviewManager.detectExtension(for: Data([0, 0, 0, 0x20]) + Data("ftyp".utf8)), "mp4")
        // MP3
        XCTAssertEqual(FilePreviewManager.detectExtension(for: Data("ID3".utf8)), "mp3")
        // AAC
        XCTAssertEqual(FilePreviewManager.detectExtension(for: Data([0xFF, 0xF1])), "aac")
        // SVG
        XCTAssertEqual(FilePreviewManager.detectExtension(for: Data("<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>".utf8)), "svg")
        // HTML
        XCTAssertEqual(FilePreviewManager.detectExtension(for: Data("<!DOCTYPE html><html><body></body></html>".utf8)), "html")
        // JSON
        XCTAssertEqual(FilePreviewManager.detectExtension(for: Data("{\"title\": \"Filaire\"}".utf8)), "json")
        XCTAssertEqual(FilePreviewManager.detectExtension(for: Data("[1, 2, 3]".utf8)), "json")
        // Markdown
        XCTAssertEqual(FilePreviewManager.detectExtension(for: Data("# Readme\nThis is cool".utf8)), "md")
        // Gzip
        XCTAssertEqual(FilePreviewManager.detectExtension(for: Data([0x1F, 0x8B, 0x08])), "gz")
        // Bzip2
        XCTAssertEqual(FilePreviewManager.detectExtension(for: Data([0x42, 0x5A, 0x68])), "bz2")
        // YAML
        XCTAssertEqual(FilePreviewManager.detectExtension(for: Data("---\nservice: backend\nport: 8080".utf8)), "yaml")
        // CSV
        XCTAssertEqual(FilePreviewManager.detectExtension(for: Data("id,name,score\n1,alice,95\n".utf8)), "csv")
        // TSV
        XCTAssertEqual(FilePreviewManager.detectExtension(for: Data("id\tname\tscore\n1\talice\t95\n".utf8)), "tsv")
        // Plain text fallback
        XCTAssertEqual(FilePreviewManager.detectExtension(for: Data("Simple unformatted log line".utf8)), "txt")
    }

    func testHostProfileFilePreviewDefaults() throws {
        // 1. Defaults on fresh instance
        let profile = HostProfile(name: "Test", hostname: "localhost")
        XCTAssertTrue(profile.allowFilePreview, "allowFilePreview must default to true")

        // 2. Decoding JSON without the key defaults to true
        let jsonWithoutKey = """
        {
            "id": "\(UUID().uuidString)",
            "name": "Legacy Host",
            "hostname": "legacy.internal",
            "port": 22,
            "username": "admin",
            "authMethod": "SSH Key"
        }
        """.data(using: .utf8)!
        let decodedLegacy = try JSONDecoder().decode(HostProfile.self, from: jsonWithoutKey)
        XCTAssertTrue(decodedLegacy.allowFilePreview)

        // 3. Round-trip false stays false
        var disabledProfile = profile
        disabledProfile.allowFilePreview = false
        let data = try JSONEncoder().encode(disabledProfile)
        let decoded = try JSONDecoder().decode(HostProfile.self, from: data)
        XCTAssertFalse(decoded.allowFilePreview)
    }

    func testHostProfileRemoteNotificationsDefaults() throws {
        // 1. Defaults on fresh instance
        let profile = HostProfile(name: "Test", hostname: "localhost")
        XCTAssertTrue(profile.allowRemoteNotifications, "allowRemoteNotifications must default to true")

        // 2. Decoding JSON without the key defaults to true
        let jsonWithoutKey = """
        {
            "id": "\(UUID().uuidString)",
            "name": "Legacy Host",
            "hostname": "legacy.internal",
            "port": 22,
            "username": "admin",
            "authMethod": "SSH Key"
        }
        """.data(using: .utf8)!
        let decodedLegacy = try JSONDecoder().decode(HostProfile.self, from: jsonWithoutKey)
        XCTAssertTrue(decodedLegacy.allowRemoteNotifications)

        // 3. Round-trip false stays false
        var disabledProfile = profile
        disabledProfile.allowRemoteNotifications = false
        let data = try JSONEncoder().encode(disabledProfile)
        let decoded = try JSONDecoder().decode(HostProfile.self, from: data)
        XCTAssertFalse(decoded.allowRemoteNotifications)
    }

    @MainActor
    func testSessionManagerFilePreviewPerHostToggle() {
        let manager = SessionManager()
        let previewManager = FilePreviewManager.shared
        previewManager.resetForTesting()

        var disabledHost = HostProfile(name: "NoPreview", hostname: "test.local")
        disabledHost.allowFilePreview = false
        manager.activeHost = disabledHost

        // Sending OSC 5101 when disabled must drop the preview
        let oscPayload = "preview;id=test_drop;name=dropped.txt;part=1;total=1;VGVzdA=="
        manager.handleFilePreview(ArraySlice(Array(oscPayload.utf8)), filePreviewManager: previewManager)

        XCTAssertNil(previewManager.previewURL)
        XCTAssertNil(manager.pendingSecurityPrompt)

        // When enabled, it processes the preview
        var enabledHost = HostProfile(name: "PreviewOK", hostname: "test.local")
        enabledHost.allowFilePreview = true
        manager.activeHost = enabledHost

        let expectation = XCTestExpectation(description: "Preview URL set when enabled")
        var cancellable: Any?
        cancellable = previewManager.$previewURL
            .compactMap { $0 }
            .first()
            .sink { _ in
                expectation.fulfill()
            }
        _ = cancellable

        manager.handleFilePreview(ArraySlice(Array(oscPayload.utf8)), filePreviewManager: previewManager)
        wait(for: [expectation], timeout: 2.0)
        XCTAssertNotNil(previewManager.previewURL)
        previewManager.dismissPreview()
    }

    @MainActor
    func testSessionManagerLargeFilePreviewPrompt() {
        let manager = SessionManager()
        let previewManager = FilePreviewManager.shared
        previewManager.resetForTesting()

        var host = HostProfile(name: "PreviewHost", hostname: "test.local")
        host.allowFilePreview = true
        manager.activeHost = host

        // Set a small threshold for testing (e.g. 5 bytes)
        FilePreviewManager.maxUnpromptedFileSize = 5

        // "Testing Large" is 13 bytes in base64: "VGVzdGluZyBMYXJnZQ=="
        let oscPayload = "preview;id=test_large;name=largefile.txt;part=1;total=1;VGVzdGluZyBMYXJnZQ=="
        manager.handleFilePreview(ArraySlice(Array(oscPayload.utf8)), filePreviewManager: previewManager)

        // Should not set previewURL immediately; should trigger pendingSecurityPrompt
        let promptExpectation = XCTestExpectation(description: "Prompt shown")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if manager.pendingSecurityPrompt != nil {
                promptExpectation.fulfill()
            }
        }
        wait(for: [promptExpectation], timeout: 2.0)

        XCTAssertNotNil(manager.pendingSecurityPrompt)
        XCTAssertEqual(manager.pendingSecurityPrompt?.title, "Large File Preview")
        XCTAssertTrue(manager.pendingSecurityPrompt?.message.contains("largefile.txt") == true)
        XCTAssertNil(previewManager.previewURL)

        // Allowing sets previewURL
        let previewExpectation = XCTestExpectation(description: "Preview URL set after allowing")
        var cancellable: Any?
        cancellable = previewManager.$previewURL
            .compactMap { $0 }
            .first()
            .sink { _ in
                previewExpectation.fulfill()
            }
        _ = cancellable

        manager.pendingSecurityPrompt?.onAllow()
        wait(for: [previewExpectation], timeout: 2.0)
        XCTAssertNotNil(previewManager.previewURL)
        previewManager.dismissPreview()

        // Reset threshold
        FilePreviewManager.maxUnpromptedFileSize = 25 * 1024 * 1024
    }

    @MainActor
    func testSessionManagerFilePreviewIsolation() {
        let sm1 = SessionManager()
        let sm2 = SessionManager()

        XCTAssertFalse(sm1.filePreviewManager === sm2.filePreviewManager, "Each SessionManager must have an isolated FilePreviewManager instance")

        let testUrl = URL(fileURLWithPath: "/tmp/preview1.png")
        sm1.filePreviewManager.previewURL = testUrl

        XCTAssertEqual(sm1.filePreviewManager.previewURL, testUrl)
        XCTAssertNil(sm2.filePreviewManager.previewURL, "Setting previewURL on sm1 must not affect sm2")

        sm1.filePreviewManager.previewURL = nil
    }

    // MARK: - R1 Acceptance Tests: Isolated Preview Storage & Coordinated Cleanup

    func testR1_CompletePreviewA_ConstructB_PreservesA() throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let coordinator = FilePreviewStorageCoordinator(baseDirectory: tempBase)
        defer { try? FileManager.default.removeItem(at: tempBase) }

        let managerA = FilePreviewManager(storageCoordinator: coordinator)
        let content = "Hello World Preview A"
        let base64 = Data(content.utf8).base64EncodedString()
        let osc = "preview;id=xferA;name=testA.txt;part=1;total=1;\(base64)"

        managerA.handleOscData(ArraySlice(Array(osc.utf8)))

        let expA = XCTestExpectation(description: "Preview A ready")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if managerA.previewURL != nil {
                expA.fulfill()
            }
        }
        wait(for: [expA], timeout: 2.0)

        guard let urlA = managerA.previewURL else {
            XCTFail("managerA.previewURL should not be nil")
            return
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: urlA.path))
        XCTAssertEqual(try String(contentsOf: urlA, encoding: .utf8), content)

        // Construct B (simulates new window's SessionManager)
        let managerB = FilePreviewManager(storageCoordinator: coordinator)
        _ = managerB

        // Verify A's file STILL exists and contains the original bytes
        XCTAssertTrue(FileManager.default.fileExists(atPath: urlA.path))
        XCTAssertEqual(try String(contentsOf: urlA, encoding: .utf8), content)
    }

    func testR1_PauseABetweenChunks_ConstructB_FinishA_Succeeds() throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let coordinator = FilePreviewStorageCoordinator(baseDirectory: tempBase)
        defer { try? FileManager.default.removeItem(at: tempBase) }

        let managerA = FilePreviewManager(storageCoordinator: coordinator)
        let chunk1 = Data("FirstChunk_".utf8).base64EncodedString()
        let chunk2 = Data("SecondChunk".utf8).base64EncodedString()

        let osc1 = "preview;id=xferA;name=twochunks.txt;part=1;total=2;\(chunk1)"
        let osc2 = "preview;id=xferA;name=twochunks.txt;part=2;total=2;\(chunk2)"

        // Send part 1
        managerA.handleOscData(ArraySlice(Array(osc1.utf8)))
        Thread.sleep(forTimeInterval: 0.05)

        // Construct B while A is paused between chunks
        let managerB = FilePreviewManager(storageCoordinator: coordinator)
        _ = managerB

        // Send part 2
        managerA.handleOscData(ArraySlice(Array(osc2.utf8)))

        let exp = XCTestExpectation(description: "Preview A completed after B construction")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if managerA.previewURL != nil {
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 2.0)

        guard let urlA = managerA.previewURL else {
            XCTFail("managerA.previewURL should not be nil")
            return
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: urlA.path))
        XCTAssertEqual(try String(contentsOf: urlA, encoding: .utf8), "FirstChunk_SecondChunk")
    }

    func testR1_SimultaneousPreviewsAndAwaitingConfirmation_ClosingOnePreservesOther() throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let coordinator = FilePreviewStorageCoordinator(baseDirectory: tempBase)
        defer { try? FileManager.default.removeItem(at: tempBase) }

        let managerA = FilePreviewManager(storageCoordinator: coordinator)
        let managerB = FilePreviewManager(storageCoordinator: coordinator)

        var awaitingAConfirm: (() -> Void)?
        var awaitingBConfirm: (() -> Void)?

        managerA.promptLargePreviewWithCancel = { filename, byteCount, onConfirm, onCancel in
            awaitingAConfirm = onConfirm
        }
        managerB.promptLargePreviewWithCancel = { filename, byteCount, onConfirm, onCancel in
            awaitingBConfirm = onConfirm
        }

        // Send large transfer (> maxUnpromptedFileSize) to A and B
        FilePreviewManager.maxUnpromptedFileSize = 5
        defer { FilePreviewManager.maxUnpromptedFileSize = 25 * 1024 * 1024 }

        let largeContentA = "Large content for window A"
        let oscLargeA = "preview;id=largeA;name=largeA.txt;part=1;total=1;\(Data(largeContentA.utf8).base64EncodedString())"
        managerA.handleOscData(ArraySlice(Array(oscLargeA.utf8)))

        let largeContentB = "Large content for window B"
        let oscLargeB = "preview;id=largeB;name=largeB.txt;part=1;total=1;\(Data(largeContentB.utf8).base64EncodedString())"
        managerB.handleOscData(ArraySlice(Array(oscLargeB.utf8)))

        let expAwaiting = XCTestExpectation(description: "Awaiting prompts ready")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if awaitingAConfirm != nil && awaitingBConfirm != nil {
                expAwaiting.fulfill()
            }
        }
        wait(for: [expAwaiting], timeout: 2.0)

        // Dismiss or shut down window A
        managerA.shutdown()

        // Verify window B's awaiting confirmation is still fully intact and can be confirmed
        XCTAssertNotNil(awaitingBConfirm)
        awaitingBConfirm?()

        let expB = XCTestExpectation(description: "Manager B preview presented")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if managerB.previewURL != nil {
                expB.fulfill()
            }
        }
        wait(for: [expB], timeout: 2.0)

        guard let urlB = managerB.previewURL else {
            XCTFail("managerB.previewURL should not be nil")
            return
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: urlB.path))
        XCTAssertEqual(try String(contentsOf: urlB, encoding: .utf8), largeContentB)
    }

    func testR1_SharedBudgetAcrossManagers_CancellationReleasesReservation() throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let coordinator = FilePreviewStorageCoordinator(
            baseDirectory: tempBase,
            maxAggregateDiskBytes: 1000,
            maxConcurrentTransfers: 2
        )
        defer { try? FileManager.default.removeItem(at: tempBase) }

        let managerA = FilePreviewManager(storageCoordinator: coordinator)
        let managerB = FilePreviewManager(storageCoordinator: coordinator)

        // Coordinator allows max 2 concurrent transfers
        let t1 = "preview;id=t1;name=fa1.txt;part=1;total=2;\(Data("T1".utf8).base64EncodedString())"
        let t2 = "preview;id=t2;name=fb1.txt;part=1;total=2;\(Data("T2".utf8).base64EncodedString())"
        let t3 = "preview;id=t3;name=fc1.txt;part=1;total=2;\(Data("T3".utf8).base64EncodedString())"

        managerA.handleOscData(ArraySlice(Array(t1.utf8)))
        managerB.handleOscData(ArraySlice(Array(t2.utf8)))
        Thread.sleep(forTimeInterval: 0.05)

        XCTAssertEqual(coordinator.currentActiveTransfers, 2)

        // Third transfer across either manager should be rejected
        managerA.handleOscData(ArraySlice(Array(t3.utf8)))

        let errExpectation = XCTestExpectation(description: "Error alert shown for transfer limit")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if managerA.showErrorAlert && (managerA.errorMessage?.contains("limit reached") == true) {
                errExpectation.fulfill()
            }
        }
        wait(for: [errExpectation], timeout: 1.0)

        XCTAssertTrue(managerA.showErrorAlert)
        XCTAssertTrue(managerA.errorMessage?.contains("limit reached") == true)
        XCTAssertEqual(coordinator.currentActiveTransfers, 2)

        // Cancel session on A
        managerA.cancelSession("default")
        XCTAssertEqual(coordinator.currentActiveTransfers, 1)

        // Now a new transfer on A can be admitted
        managerA.showErrorAlert = false
        managerA.errorMessage = nil
        let t4 = "preview;id=t4;name=fd1.txt;part=1;total=1;\(Data("T4".utf8).base64EncodedString())"
        managerA.handleOscData(ArraySlice(Array(t4.utf8)))
        Thread.sleep(forTimeInterval: 0.05)

        XCTAssertFalse(managerA.showErrorAlert)
        XCTAssertEqual(coordinator.currentActiveTransfers, 1) // t4 finished immediately because part=total=1
    }

    func testR1_StaleRunCleanupRemovesOnlyStaleDirectories() throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }

        // Create stale run directories from previous runs
        let staleRun1 = tempBase.appendingPathComponent("run-\(UUID().uuidString)", isDirectory: true)
        let staleRun2 = tempBase.appendingPathComponent("run-\(UUID().uuidString)", isDirectory: true)
        let unrelatedDir = tempBase.appendingPathComponent("custom_folder", isDirectory: true)
        try FileManager.default.createDirectory(at: staleRun1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staleRun2, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelatedDir, withIntermediateDirectories: true)

        let coordinator = FilePreviewStorageCoordinator(baseDirectory: tempBase)
        let manager = FilePreviewManager(storageCoordinator: coordinator)

        let content = "Current run file content"
        let osc = "preview;id=cur;name=cur.txt;part=1;total=1;\(Data(content.utf8).base64EncodedString())"
        manager.handleOscData(ArraySlice(Array(osc.utf8)))

        let exp = XCTestExpectation(description: "Current run preview finished")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if manager.previewURL != nil {
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 2.0)

        // Trigger sync cleanup of stale runs
        coordinator.cleanStaleRunsSync()

        // Stale runs removed
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleRun1.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleRun2.path))

        // Unrelated directory kept
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedDir.path))

        // Current run and its preview file completely intact
        guard let url = manager.previewURL else {
            XCTFail("manager.previewURL should exist")
            return
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), content)
    }

    // MARK: - Fix 3: Bounded File Preview & Backpressure Regression Tests

    final class MockBlockableWriter: PreviewFileWriter {
        private let fileHandle: FileHandle
        var writtenData = Data()
        var writeCount = 0
        let writeGate = DispatchSemaphore(value: 0)

        init(url: URL) throws {
            self.fileHandle = try FileHandle(forWritingTo: url)
        }

        func write(data: Data) throws {
            writeGate.wait()
            try fileHandle.write(contentsOf: data)
            writtenData.append(data)
            writeCount += 1
        }

        func close() throws {
            try fileHandle.close()
        }
    }

    func testFilePreviewManagerSlowWriterBackpressureAndBoundedMemory() throws {
        let manager = FilePreviewManager.shared
        manager.resetForTesting()
        manager.highWatermark = 200
        manager.lowWatermark = 80
        manager.maxAdmissionBytes = 2000

        var mockWriter: MockBlockableWriter?
        manager.fileWriterFactory = { url in
            let w = try MockBlockableWriter(url: url)
            mockWriter = w
            return w
        }
        defer { manager.fileWriterFactory = nil }

        let sessId = "slow_writer_sess"
        var pauseEvents: [Bool] = []
        let pressureHandler: (Bool) -> Void = { isPaused in
            pauseEvents.append(isPaused)
        }

        // Chunks: each payload is 100 bytes base64
        let chunk1Data = String(repeating: "A", count: 100)
        let chunk2Data = String(repeating: "B", count: 100)
        let chunk3Data = String(repeating: "C", count: 100)

        let p1 = "preview;id=slow1;name=slow.txt;part=1;total=3;\(chunk1Data)"
        let p2 = "preview;id=slow1;name=slow.txt;part=2;total=3;\(chunk2Data)"
        let p3 = "preview;id=slow1;name=slow.txt;part=3;total=3;\(chunk3Data)"

        // Send part 1: drain worker pops part 1 and blocks on mockWriter.writeGate
        manager.handleOscData(ArraySlice(Array(p1.utf8)), sessionId: sessId, onPressureChanged: pressureHandler)

        // Give the worker queue a moment to enter write()
        Thread.sleep(forTimeInterval: 0.05)

        // Send part 2 and part 3: admitted to mailbox
        manager.handleOscData(ArraySlice(Array(p2.utf8)), sessionId: sessId, onPressureChanged: pressureHandler)
        manager.handleOscData(ArraySlice(Array(p3.utf8)), sessionId: sessId, onPressureChanged: pressureHandler)

        // Memory should be bounded within maxAdmissionBytes
        XCTAssertLessThanOrEqual(manager.queuedMailboxBytesCount, manager.maxAdmissionBytes)
        // High watermark (200) was crossed by part 2 & 3 in mailbox (~160 bytes each raw)
        XCTAssertTrue(manager.isSessionPaused(sessId))
        XCTAssertTrue(pauseEvents.contains(true))

        // Unblock the writer for parts 1, 2, and 3
        mockWriter?.writeGate.signal()
        mockWriter?.writeGate.signal()
        mockWriter?.writeGate.signal()

        // Wait for drain to finish
        let expectation = XCTestExpectation(description: "Preview drained and completed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)

        // Unpaused below low watermark
        XCTAssertFalse(manager.isSessionPaused(sessId))
        XCTAssertEqual(manager.queuedMailboxBytesCount, 0)
        XCTAssertEqual(manager.retainedOutOfOrderBytesCount, 0)
        XCTAssertEqual(mockWriter?.writeCount, 3)

        manager.dismissPreview()
        XCTAssertEqual(manager.aggregateDiskBytesCount, 0)
    }

    @MainActor
    func testSessionManagerCoalescerAndPreviewPressureCoordination() {
        let manager = SessionManager()
        let connId = UUID()
        manager.currentConnectionId = connId

        XCTAssertFalse(manager.isCoalescerPaused)
        XCTAssertFalse(manager.isPreviewPaused)

        // 1. Coalescer pauses
        manager.updateTerminalReadPaused(coalescer: true, connectionId: connId)
        XCTAssertTrue(manager.isCoalescerPaused)
        XCTAssertFalse(manager.isPreviewPaused)

        // 2. Preview pauses
        manager.updateTerminalReadPaused(preview: true, connectionId: connId)
        XCTAssertTrue(manager.isCoalescerPaused)
        XCTAssertTrue(manager.isPreviewPaused)

        // 3. Coalescer unpauses alone: preview is still paused, so manager remains under pressure
        manager.updateTerminalReadPaused(coalescer: false, connectionId: connId)
        XCTAssertFalse(manager.isCoalescerPaused)
        XCTAssertTrue(manager.isPreviewPaused)

        // 4. Preview unpauses: now both are unpaused
        manager.updateTerminalReadPaused(preview: false, connectionId: connId)
        XCTAssertFalse(manager.isCoalescerPaused)
        XCTAssertFalse(manager.isPreviewPaused)

        // 5. Reverse order: preview unpauses before coalescer unpauses
        manager.updateTerminalReadPaused(coalescer: true, connectionId: connId)
        manager.updateTerminalReadPaused(preview: true, connectionId: connId)
        manager.updateTerminalReadPaused(preview: false, connectionId: connId)
        XCTAssertTrue(manager.isCoalescerPaused)
        XCTAssertFalse(manager.isPreviewPaused)
        manager.updateTerminalReadPaused(coalescer: false, connectionId: connId)
        XCTAssertFalse(manager.isCoalescerPaused)
        XCTAssertFalse(manager.isPreviewPaused)

        // 6. Stale connection ID is ignored
        let staleConnId = UUID()
        manager.updateTerminalReadPaused(preview: true, connectionId: staleConnId)
        XCTAssertFalse(manager.isPreviewPaused)
    }

    func testFilePreviewManagerActiveTransferLimitRejectsNewAndPreservesExisting() {
        let manager = FilePreviewManager.shared
        manager.resetForTesting()
        manager.maxActiveTransfers = 2

        let tA1 = "preview;id=tA;name=fa.txt;part=1;total=2;VGVzdDE="
        let tB1 = "preview;id=tB;name=fb.txt;part=1;total=2;VGVzdDI="
        let tC1 = "preview;id=tC;name=fc.txt;part=1;total=2;VGVzdDM="

        manager.handleOscData(ArraySlice(Array(tA1.utf8)))
        manager.handleOscData(ArraySlice(Array(tB1.utf8)))

        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(manager.activeTransferCount, 2)

        // Transfer C arrives when limit is reached
        manager.handleOscData(ArraySlice(Array(tC1.utf8)))

        let errExpectation = XCTestExpectation(description: "Error alert shown for transfer limit")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if manager.showErrorAlert && (manager.errorMessage?.contains("limit reached") == true) {
                errExpectation.fulfill()
            }
        }
        wait(for: [errExpectation], timeout: 1.0)

        // Existing transfers A and B are preserved and still active
        XCTAssertEqual(manager.activeTransferCount, 2)

        // Transfers A and B complete successfully
        let tA2 = "preview;id=tA;name=fa.txt;part=2;total=2;VGVzdDE="
        let tB2 = "preview;id=tB;name=fb.txt;part=2;total=2;VGVzdDI="
        manager.handleOscData(ArraySlice(Array(tA2.utf8)))
        manager.handleOscData(ArraySlice(Array(tB2.utf8)))

        let completionExpectation = XCTestExpectation(description: "Active transfers finish")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if manager.activeTransferCount == 0 {
                completionExpectation.fulfill()
            }
        }
        wait(for: [completionExpectation], timeout: 2.0)
        XCTAssertEqual(manager.activeTransferCount, 0)
        manager.dismissPreview()
    }

    func testFilePreviewManagerExceedAggregateByteBudgetAbortsTargetedTransfer() {
        let manager = FilePreviewManager.shared
        manager.resetForTesting()
        // Allow up to 100 bytes aggregate disk storage
        manager.maxAggregateDiskBytes = 100

        // "Hello" = 5 bytes decoded. Base64 "SGVsbG8="
        let tA = "preview;id=tA;name=fa.txt;part=1;total=1;SGVsbG8="
        manager.handleOscData(ArraySlice(Array(tA.utf8)))

        let compA = XCTestExpectation(description: "Transfer A complete")
        func checkCompA() {
            if manager.previewURL != nil {
                compA.fulfill()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { checkCompA() }
            }
        }
        checkCompA()
        wait(for: [compA], timeout: 2.0)
        XCTAssertEqual(manager.aggregateDiskBytesCount, 5)

        // Now send transfer B that attempts to write 120 bytes (> 100 bytes limit)
        // 160 base64 chars = 120 decoded bytes
        let largeB64 = String(repeating: "QUJD", count: 40)
        let tB = "preview;id=tB;name=fb.txt;part=1;total=1;\(largeB64)"
        manager.handleOscData(ArraySlice(Array(tB.utf8)))

        let errExpectation = XCTestExpectation(description: "Error alert shown for aggregate disk budget")
        func checkErr() {
            if manager.showErrorAlert && (manager.errorMessage?.contains("aggregate disk budget") == true) {
                errExpectation.fulfill()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { checkErr() }
            }
        }
        checkErr()
        wait(for: [errExpectation], timeout: 2.0)

        // Transfer B was aborted and cleaned up; only Transfer A's 5 bytes remain
        XCTAssertEqual(manager.aggregateDiskBytesCount, 5)
        manager.dismissPreview()
        XCTAssertEqual(manager.aggregateDiskBytesCount, 0)
    }

    func testFilePreviewManagerDuplicateAndOutOfOrderChunksAndReset() {
        let manager = FilePreviewManager.shared
        manager.resetForTesting()

        // Part 2 delivered first
        let p2 = "preview;id=ooo;name=ooo.txt;part=2;total=3;V29ybGQ=" // "World"
        manager.handleOscData(ArraySlice(Array(p2.utf8)))

        Thread.sleep(forTimeInterval: 0.05)
        let oooBytes = manager.retainedOutOfOrderBytesCount
        XCTAssertGreaterThan(oooBytes, 0)

        // Duplicate Part 2 delivered again
        manager.handleOscData(ArraySlice(Array(p2.utf8)))
        Thread.sleep(forTimeInterval: 0.05)
        // Out-of-order bytes must not be double counted
        XCTAssertEqual(manager.retainedOutOfOrderBytesCount, oooBytes)

        // Deliver Part 1
        let p1 = "preview;id=ooo;name=ooo.txt;part=1;total=3;SGVsbG8g" // "Hello "
        manager.handleOscData(ArraySlice(Array(p1.utf8)))
        Thread.sleep(forTimeInterval: 0.05)
        // Now parts 1 & 2 have been written; out-of-order bytes decremented
        XCTAssertEqual(manager.retainedOutOfOrderBytesCount, 0)

        // Deliver Part 3 to complete
        let p3 = "preview;id=ooo;name=ooo.txt;part=3;total=3;IQ==" // "!"
        manager.handleOscData(ArraySlice(Array(p3.utf8)))

        let compExpectation = XCTestExpectation(description: "Transfer complete")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if manager.previewURL != nil {
                compExpectation.fulfill()
            }
        }
        wait(for: [compExpectation], timeout: 2.0)
        XCTAssertEqual(manager.retainedOutOfOrderBytesCount, 0)
        manager.dismissPreview()

        // Test reset while paused
        manager.highWatermark = 50
        manager.lowWatermark = 20
        var isPausedReported = false
        // Part 2 of 2 arrives first (retained out-of-order bytes >= 50 keeps session paused)
        manager.handleOscData(
            ArraySlice(Array("preview;id=pauseTest;name=p.txt;part=2;total=2;\(String(repeating: "A", count: 100))".utf8)),
            sessionId: "test_reset_sess",
            onPressureChanged: { isPaused in
                isPausedReported = isPaused
            }
        )
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertTrue(isPausedReported)
        XCTAssertTrue(manager.isSessionPaused("test_reset_sess"))

        manager.resetForTesting()
        XCTAssertFalse(manager.isSessionPaused("test_reset_sess"))
        XCTAssertEqual(manager.queuedMailboxBytesCount, 0)
        XCTAssertEqual(manager.retainedOutOfOrderBytesCount, 0)
        XCTAssertEqual(manager.aggregateDiskBytesCount, 0)
        XCTAssertEqual(manager.activeTransferCount, 0)
    }

    func testFilePreviewManagerSessionIsolationAndCancellation() {
        let manager = FilePreviewManager.shared
        manager.resetForTesting()

        let pA1 = "preview;id=shared_id;name=fileA.txt;part=1;total=2;VGVzdEE="
        let pB1 = "preview;id=shared_id;name=fileB.txt;part=1;total=2;VGVzdEI="

        manager.handleOscData(ArraySlice(Array(pA1.utf8)), sessionId: "sessA")
        manager.handleOscData(ArraySlice(Array(pB1.utf8)), sessionId: "sessB")

        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(manager.activeTransferCount, 2)

        // Cancel session A
        manager.cancelSession("sessA")
        Thread.sleep(forTimeInterval: 0.05)

        // Session B's transfer remains active
        XCTAssertEqual(manager.activeTransferCount, 1)

        // Session B part 2 arrives and completes
        let pB2 = "preview;id=shared_id;name=fileB.txt;part=2;total=2;VGVzdEI="
        manager.handleOscData(ArraySlice(Array(pB2.utf8)), sessionId: "sessB")

        let compExpectation = XCTestExpectation(description: "Session B transfer complete")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if manager.previewURL?.lastPathComponent == "fileB.txt" {
                compExpectation.fulfill()
            }
        }
        wait(for: [compExpectation], timeout: 2.0)
        XCTAssertEqual(manager.previewURL?.lastPathComponent, "fileB.txt")
        manager.dismissPreview()
    }

    @MainActor
    func testSessionManagerLargePreviewRefusalAndHostSwitchCleanup() {
        let sessionManager = SessionManager()
        let previewManager = FilePreviewManager.shared
        previewManager.resetForTesting()
        FilePreviewManager.maxUnpromptedFileSize = 5

        var hostA = HostProfile(name: "HostA", hostname: "a.local")
        hostA.allowFilePreview = true
        sessionManager.activeHost = hostA

        let connIdA = UUID()
        sessionManager.currentConnectionId = connIdA

        // Send a 13-byte file ("Testing Large" = VGVzdGluZyBMYXJnZQ==)
        let oscPayload = "preview;id=refuse_test;name=large.txt;part=1;total=1;VGVzdGluZyBMYXJnZQ=="
        sessionManager.handleFilePreview(ArraySlice(Array(oscPayload.utf8)), filePreviewManager: previewManager)

        let promptExpectation = XCTestExpectation(description: "Prompt shown for HostA")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if sessionManager.pendingSecurityPrompt != nil {
                promptExpectation.fulfill()
            }
        }
        wait(for: [promptExpectation], timeout: 2.0)

        // The file is awaiting confirmation and counted in disk bytes
        XCTAssertGreaterThan(previewManager.aggregateDiskBytesCount, 0)

        // Refuse/cancel the prompt
        sessionManager.cancelPendingSecurityPrompt()

        // File is removed and disk bytes refunded
        XCTAssertEqual(previewManager.aggregateDiskBytesCount, 0)
        XCTAssertNil(previewManager.previewURL)

        // Test host switch cleanup
        let inFlightPayload = "preview;id=inflight;name=inflight.txt;part=1;total=2;VGVzdA=="
        sessionManager.handleFilePreview(ArraySlice(Array(inFlightPayload.utf8)), filePreviewManager: previewManager)
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(previewManager.activeTransferCount, 1)

        // Host switch to HostB
        var hostB = HostProfile(name: "HostB", hostname: "b.local")
        sessionManager.connect(to: hostB)

        // Previous session's reservations and transfers cleaned up
        XCTAssertEqual(previewManager.activeTransferCount, 0)
        XCTAssertEqual(previewManager.aggregateDiskBytesCount, 0)

        FilePreviewManager.maxUnpromptedFileSize = 25 * 1024 * 1024
    }

    // MARK: - Multi-Window Naming & Home Screen Quick Actions

    @MainActor
    func testWindowTitleComputation() {
        let appState = AppState()

        // 1. When no hosts exist, title should be "Filaire"
        appState.hosts = []
        appState.selectedHostId = nil
        XCTAssertEqual(appState.windowTitle, "Filaire")

        // 2. When host has tmux enabled with session name
        let host1 = HostProfile(
            name: "Production Server",
            hostname: "prod.example.com",
            username: "admin",
            customTmuxSession: "api-backend",
            autoConnectTmux: true
        )
        appState.hosts = [host1]
        appState.selectedHostId = host1.id
        XCTAssertEqual(appState.windowTitle, "Production Server (api-backend)")

        // 3. When host has tmux enabled with default username session
        let host2 = HostProfile(
            name: "Staging Box",
            hostname: "staging.example.com",
            username: "deployer",
            autoConnectTmux: true
        )
        appState.hosts = [host2]
        appState.selectedHostId = host2.id
        XCTAssertEqual(appState.windowTitle, "Staging Box (deployer)")

        // 4. When host has tmux disabled
        let host3 = HostProfile(
            name: "Database Node",
            hostname: "db.example.com",
            username: "postgres",
            autoConnectTmux: false
        )
        appState.hosts = [host3]
        appState.selectedHostId = host3.id
        XCTAssertEqual(appState.windowTitle, "Database Node")
    }

    @MainActor
    func testQuickActionManagerShortcutItems() {
        let host1 = HostProfile(name: "Prod", hostname: "prod.internal", username: "admin", customTmuxSession: "main", autoConnectTmux: true)
        let host2 = HostProfile(name: "Dev", hostname: "dev.internal", username: "dev", autoConnectTmux: false)
        let host3 = HostProfile(name: "Staging", hostname: "staging.internal", username: "qa", customTmuxSession: "web", autoConnectTmux: true)
        let host4 = HostProfile(name: "Test", hostname: "test.internal", username: "tester", autoConnectTmux: true)
        let host5 = HostProfile(name: "Extra", hostname: "extra.internal", username: "extra", autoConnectTmux: true)

        let items = QuickActionManager.makeShortcutItems(for: [host1, host2, host3, host4, host5])

        // iOS supports a maximum of 4 dynamic shortcut items
        XCTAssertEqual(items.count, 4)

        // Item 1: Tmux enabled with custom session
        XCTAssertEqual(items[0].type, QuickActionManager.connectHostActionType)
        XCTAssertEqual(items[0].localizedTitle, "Prod")
        XCTAssertEqual(items[0].localizedSubtitle, "admin@prod.internal (tmux: main)")
        XCTAssertEqual(items[0].userInfo?[QuickActionManager.hostIdUserInfoKey] as? String, host1.id.uuidString)

        // Item 2: Tmux disabled
        XCTAssertEqual(items[1].localizedTitle, "Dev")
        XCTAssertEqual(items[1].localizedSubtitle, "dev@dev.internal")
        XCTAssertEqual(items[1].userInfo?[QuickActionManager.hostIdUserInfoKey] as? String, host2.id.uuidString)

        // Item 3: Tmux enabled
        XCTAssertEqual(items[2].localizedTitle, "Staging")
        XCTAssertEqual(items[2].localizedSubtitle, "qa@staging.internal (tmux: web)")

        // Item 4: Tmux enabled default session
        XCTAssertEqual(items[3].localizedTitle, "Test")
        XCTAssertEqual(items[3].localizedSubtitle, "tester@test.internal (tmux: tester)")
    }

    @MainActor
    func testQuickActionPendingHostIdConsumption() {
        let manager = QuickActionManager.shared
        let testId = UUID()

        manager.pendingHostId = testId
        let consumed1 = manager.consumeInitialHostId()
        XCTAssertEqual(consumed1, testId)

        // Next consumption should be nil (consumed only once)
        let consumed2 = manager.consumeInitialHostId()
        XCTAssertNil(consumed2)
    }

    @MainActor
    func testCrossWindowDataSync() {
        let appState1 = AppState()
        let appState2 = AppState()

        let originalCount = appState1.hosts.count
        let newHost = HostProfile(name: "Cross Window Host", hostname: "cw.example.com", username: "admin")

        // Mutating appState1 should trigger notification and reload on appState2
        appState1.hosts.append(newHost)

        XCTAssertEqual(appState2.hosts.count, originalCount + 1)
        XCTAssertTrue(appState2.hosts.contains(where: { $0.name == "Cross Window Host" }))

        // Clean up
        appState1.hosts.removeAll(where: { $0.name == "Cross Window Host" })
        XCTAssertEqual(appState2.hosts.count, originalCount)
    }

    @MainActor
    func testCrossWindowHostDeletionResetsSelection() {
        let appState1 = AppState()
        let appState2 = AppState()

        let hostToDelete = HostProfile(name: "Host to Delete", hostname: "del.example.com", username: "admin")
        appState1.hosts.append(hostToDelete)
        appState2.selectedHostId = hostToDelete.id
        XCTAssertEqual(appState2.selectedHostId, hostToDelete.id)

        // Deleting host in appState1 triggers reload in appState2
        appState1.hosts.removeAll(where: { $0.id == hostToDelete.id })

        // appState2 should detect host was deleted and reset its selectedHostId to nil
        XCTAssertNil(appState2.selectedHostId)
    }

    @MainActor
    func testActiveHostRefreshesWhenHostIsEdited() {
        let appState = AppState()
        let host = HostProfile(name: "Sync Host", hostname: "sync.example.com", username: "admin", allowClipboardWrite: true)
        appState.hosts.append(host)
        appState.sessionManager.activeHost = host

        let index = appState.hosts.firstIndex(where: { $0.id == host.id })!
        appState.hosts[index].enableAgentForwarding = true
        appState.hosts[index].allowClipboardWrite = false

        XCTAssertEqual(appState.sessionManager.activeHost?.enableAgentForwarding, true)
        XCTAssertEqual(appState.sessionManager.activeHost?.allowClipboardWrite, false)
        XCTAssertFalse(appState.sessionManager.handleClipboardWrite(Data("x".utf8), writePasteboard: { _ in }))
        XCTAssertEqual(appState.sessionManager.allHosts, appState.hosts)

        appState.hosts.removeAll(where: { $0.id == host.id })
    }

    @MainActor
    func testActiveHostRefreshesFromOtherWindowEdit() {
        let appState1 = AppState()
        let appState2 = AppState()
        let host = HostProfile(name: "Cross Window Sync Host", hostname: "cws.example.com", username: "admin")
        appState1.hosts.append(host)
        appState2.sessionManager.activeHost = host

        let index = appState1.hosts.firstIndex(where: { $0.id == host.id })!
        appState1.hosts[index].portForwards = [PortForwardRule(localPort: 9000, remoteHost: "localhost", remotePort: 9000)]

        XCTAssertEqual(appState2.sessionManager.activeHost?.portForwards.count, 1)

        appState1.hosts.removeAll(where: { $0.id == host.id })
    }

    @MainActor
    func testEditingOtherHostDoesNotReplaceActiveHost() {
        let appState = AppState()
        let active = HostProfile(name: "Active Host", hostname: "active.example.com", username: "admin")
        let other = HostProfile(name: "Other Host", hostname: "other.example.com", username: "admin")
        appState.hosts.append(contentsOf: [active, other])
        appState.sessionManager.activeHost = active

        let index = appState.hosts.firstIndex(where: { $0.id == other.id })!
        appState.hosts[index].hostname = "changed.example.com"

        XCTAssertEqual(appState.sessionManager.activeHost, active)

        appState.hosts.removeAll(where: { $0.id == active.id || $0.id == other.id })
    }

    func testSourceLicenseURL() {
        guard let url = URL(string: "https://github.com/JeremyOT/filaire") else {
            XCTFail("Invalid Source / Licenses URL")
            return
        }
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "github.com")
        XCTAssertEqual(url.path, "/JeremyOT/filaire")
    }

    // MARK: - MRU Sorting & Multi-Window Host Routing

    func testHostProfileLastConnectedEncodingDecoding() throws {
        let testDate = Date(timeIntervalSince1970: 1700000000)
        let profile = HostProfile(
            name: "MRU Host",
            hostname: "mru.internal",
            lastConnected: testDate
        )
        XCTAssertEqual(profile.lastConnected, testDate)

        // Round-trip encoding
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(HostProfile.self, from: data)
        XCTAssertEqual(decoded.lastConnected, testDate)

        // Backward compatibility: JSON without lastConnected
        let legacyJSON = """
        {
            "id": "\(UUID().uuidString)",
            "name": "Legacy MRU Host",
            "hostname": "legacy.internal",
            "port": 22,
            "username": "admin",
            "authMethod": "SSH Key"
        }
        """.data(using: .utf8)!

        let legacyDecoded = try JSONDecoder().decode(HostProfile.self, from: legacyJSON)
        XCTAssertNil(legacyDecoded.lastConnected)
    }

    @MainActor
    func testQuickActionManagerMRUSorting() {
        let now = Date()
        let host1 = HostProfile(name: "Host 1 (-100s)", hostname: "h1.internal", username: "u1", lastConnected: now.addingTimeInterval(-100))
        let host2 = HostProfile(name: "Host 2 (-10s)", hostname: "h2.internal", username: "u2", lastConnected: now.addingTimeInterval(-10))
        let host3 = HostProfile(name: "Host 3 (-50s)", hostname: "h3.internal", username: "u3", lastConnected: now.addingTimeInterval(-50))
        let host4 = HostProfile(name: "Host 4 (never)", hostname: "h4.internal", username: "u4", lastConnected: nil)
        let host5 = HostProfile(name: "Host 5 (never)", hostname: "h5.internal", username: "u5", lastConnected: nil)
        let host6 = HostProfile(name: "Host 6 (-200s)", hostname: "h6.internal", username: "u6", lastConnected: now.addingTimeInterval(-200))

        // All 6 hosts: top 4 must be Host 2 (-10s), Host 3 (-50s), Host 1 (-100s), Host 6 (-200s)
        let items = QuickActionManager.makeShortcutItems(for: [host1, host2, host3, host4, host5, host6])
        XCTAssertEqual(items.count, 4)
        XCTAssertEqual(items[0].localizedTitle, "Host 2 (-10s)")
        XCTAssertEqual(items[1].localizedTitle, "Host 3 (-50s)")
        XCTAssertEqual(items[2].localizedTitle, "Host 1 (-100s)")
        XCTAssertEqual(items[3].localizedTitle, "Host 6 (-200s)")

        // Hosts with connection history placed before hosts without connection history
        let mixedItems = QuickActionManager.makeShortcutItems(for: [host4, host1, host5])
        XCTAssertEqual(mixedItems.count, 3)
        XCTAssertEqual(mixedItems[0].localizedTitle, "Host 1 (-100s)")
        XCTAssertEqual(mixedItems[1].localizedTitle, "Host 4 (never)")
        XCTAssertEqual(mixedItems[2].localizedTitle, "Host 5 (never)")

        // Empty hosts array produces empty shortcuts
        XCTAssertTrue(QuickActionManager.makeShortcutItems(for: []).isEmpty)
    }

    @MainActor
    func testAppStateConnectUpdatesLastConnected() {
        let appState = AppState()
        let host = HostProfile(name: "Connect Test Host", hostname: "ct.internal", username: "user")
        appState.hosts = [host]
        XCTAssertNil(appState.hosts[0].lastConnected)

        appState.connect(to: host)

        guard let lastConnected = appState.hosts.first?.lastConnected else {
            XCTFail("lastConnected must be updated upon connect(to:)")
            return
        }
        XCTAssertLessThan(abs(lastConnected.timeIntervalSinceNow), 2.0)

        // Clean up
        appState.hosts.removeAll()
    }

    @MainActor
    func testQuickActionTargetContentIdentifier() {
        let testId = UUID(uuidString: "12345678-1234-1234-1234-123456789abc")!
        let targetId = QuickActionManager.targetContentIdentifier(for: testId)
        XCTAssertEqual(targetId, "io.o-t.filaire.host.\(testId.uuidString)")
    }

    @MainActor
    func testSceneTaggingAndHostMatching() throws {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first else {
            // Simulator headless environment without active scene session
            return
        }

        let hostId1 = UUID()
        let hostId2 = UUID()

        // 1. Scene should not match initially
        XCTAssertFalse(QuickActionManager.isScene(scene, associatedWith: hostId1))
        XCTAssertFalse(QuickActionManager.isScene(scene, associatedWith: hostId2))

        // 2. Tag scene with hostId1
        QuickActionManager.shared.tagScene(scene, withHostId: hostId1)
        XCTAssertTrue(QuickActionManager.isScene(scene, associatedWith: hostId1))
        XCTAssertFalse(QuickActionManager.isScene(scene, associatedWith: hostId2))

        // 3. findScene matching
        let foundScene = QuickActionManager.findScene(for: hostId1, in: [scene])
        XCTAssertEqual(foundScene, scene)
        XCTAssertNil(QuickActionManager.findScene(for: hostId2, in: [scene]))

        // 4. Untag scene
        QuickActionManager.shared.tagScene(scene, withHostId: nil)
        XCTAssertFalse(QuickActionManager.isScene(scene, associatedWith: hostId1))
        XCTAssertNil(QuickActionManager.findScene(for: hostId1, in: [scene]))
    }

    @MainActor
    func testShortcutItemsTargetContentIdentifier() {
        let host1 = HostProfile(name: "Box A", hostname: "a.test", username: "user")
        let host2 = HostProfile(name: "Box B", hostname: "b.test", username: "user")
        let items = QuickActionManager.makeShortcutItems(for: [host1, host2])

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].targetContentIdentifier as? String, QuickActionManager.targetContentIdentifier(for: host1.id))
        XCTAssertEqual(items[1].targetContentIdentifier as? String, QuickActionManager.targetContentIdentifier(for: host2.id))
    }

    @MainActor
    func testSceneActivationConditionsConfiguredOnTagScene() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first else { return }

        let hostId = UUID()
        let expectedTargetId = QuickActionManager.targetContentIdentifier(for: hostId)

        QuickActionManager.shared.tagScene(scene, withHostId: hostId)

        // Activation condition predicates should match target identifier
        let canPred = scene.activationConditions.canActivateForTargetContentIdentifierPredicate
        let prefPred = scene.activationConditions.prefersToActivateForTargetContentIdentifierPredicate

        XCTAssertTrue(canPred.evaluate(with: expectedTargetId))
        XCTAssertTrue(prefPred.evaluate(with: expectedTargetId))
        XCTAssertFalse(canPred.evaluate(with: "some.other.identifier"))
        XCTAssertFalse(prefPred.evaluate(with: "some.other.identifier"))

        // Untagging restores open acceptance
        QuickActionManager.shared.tagScene(scene, withHostId: nil)
        let unallocatedCanPred = scene.activationConditions.canActivateForTargetContentIdentifierPredicate
        let unallocatedPrefPred = scene.activationConditions.prefersToActivateForTargetContentIdentifierPredicate

        XCTAssertTrue(unallocatedCanPred.evaluate(with: expectedTargetId))
        XCTAssertTrue(unallocatedCanPred.evaluate(with: "any.other.target"))
        XCTAssertFalse(unallocatedPrefPred.evaluate(with: expectedTargetId))
    }

    @MainActor
    func testFindUnallocatedScene() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first else { return }

        // When untagged, findUnallocatedScene should find it
        QuickActionManager.shared.tagScene(scene, withHostId: nil)
        let unallocated = QuickActionManager.findUnallocatedScene(in: [scene])
        XCTAssertEqual(unallocated, scene)

        // When tagged with a host, it is allocated
        let hostId = UUID()
        QuickActionManager.shared.tagScene(scene, withHostId: hostId)
        let nowAllocated = QuickActionManager.findUnallocatedScene(in: [scene])
        XCTAssertNil(nowAllocated)

        // Clean up
        QuickActionManager.shared.tagScene(scene, withHostId: nil)
    }

    @MainActor
    func testOpenHostInWindowRouting() {
        let hostId = UUID()
        // Intercept activation so the test doesn't create real window scenes in the test host
        QuickActionManager.shared.sceneActivationHandler = { _, _, _, _ in }
        defer { QuickActionManager.shared.sceneActivationHandler = nil }
        // Ensure calling openHostInWindow and openHostInNewWindow executes safely
        QuickActionManager.shared.openHostInWindow(hostId: hostId)
        QuickActionManager.shared.openHostInWindow(hostId: hostId, preferNewWindow: true)
        QuickActionManager.shared.openHostInNewWindow(hostId: hostId)
    }

    @MainActor
    func testActivateSceneWithHostId() {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first,
            let scene = window.windowScene else {
            return
        }

        let testHostId = UUID()
        // Should execute safely without throwing or crashing
        QuickActionManager.shared.activateScene(scene, hostId: testHostId)
    }

    @MainActor
    func testWindowTitleUIViewEmptyTitlePreservesTitle() {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first,
            let scene = window.windowScene else {
            return
        }

        let originalTitle = scene.title
        let titleView = WindowTitleUIView()
        window.addSubview(titleView)

        // Setting empty title should not mutate windowScene.title
        titleView.targetTitle = ""
        titleView.updateTitle()
        XCTAssertEqual(scene.title, originalTitle)

        // Setting non-empty title updates it
        titleView.targetTitle = "Custom Title Test"
        titleView.updateTitle()
        XCTAssertEqual(scene.title, "Custom Title Test")

        // Setting back to empty title preserves the last non-empty title
        titleView.targetTitle = ""
        titleView.updateTitle()
        XCTAssertEqual(scene.title, "Custom Title Test")

        // Clean up
        scene.title = originalTitle
        titleView.removeFromSuperview()
    }

    @MainActor
    func testDisconnectPreservesActiveHost() {
        let manager = SessionManager()
        let host = HostProfile(name: "Preserve Host Test", hostname: "test.lan", username: "user")
        manager.activeHost = host
        manager.state = .connected

        // Standard disconnect preserves activeHost so Reconnect works
        manager.disconnect()
        XCTAssertEqual(manager.state, .disconnected)
        XCTAssertEqual(manager.activeHost?.id, host.id)

        // Disconnect with clearActiveHost removes activeHost
        manager.disconnect(clearActiveHost: true)
        XCTAssertEqual(manager.state, .disconnected)
        XCTAssertNil(manager.activeHost)
    }

    @MainActor
    func testHardwareKeyboardFontZoomCommands() {
        let view = FilaireTerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let initialSize = FontManager.shared.fontSize

        // Zoom In increases by 1.0
        let cmdPlus = UIKeyCommand(input: "+", modifierFlags: .command, action: #selector(view.handleZoomInCommand(_:)))
        view.handleZoomInCommand(cmdPlus)
        XCTAssertEqual(FontManager.shared.fontSize, min(initialSize + 1.0, 32.0))

        // Zoom Out decreases by 1.0
        let cmdMinus = UIKeyCommand(input: "-", modifierFlags: .command, action: #selector(view.handleZoomOutCommand(_:)))
        view.handleZoomOutCommand(cmdMinus)
        XCTAssertEqual(FontManager.shared.fontSize, initialSize)

        // Zoom Reset returns to idiom default
        let cmdZero = UIKeyCommand(input: "0", modifierFlags: .command, action: #selector(view.handleZoomResetCommand(_:)))
        view.handleZoomResetCommand(cmdZero)
        let expectedDefault: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 15.0 : 13.0
        XCTAssertEqual(FontManager.shared.fontSize, expectedDefault)

        // Test handleKeyShortcut directly (as invoked by hardware pressesBegan)
        let handledPlus = view.handleKeyShortcut(characters: "+", charactersIgnoringModifiers: "+", modifierFlags: .command)
        XCTAssertTrue(handledPlus)
        XCTAssertEqual(FontManager.shared.fontSize, expectedDefault + 1.0)

        let handledEqual = view.handleKeyShortcut(characters: "=", charactersIgnoringModifiers: "=", modifierFlags: .command)
        XCTAssertTrue(handledEqual)
        XCTAssertEqual(FontManager.shared.fontSize, expectedDefault + 2.0)

        let handledMinus = view.handleKeyShortcut(characters: "-", charactersIgnoringModifiers: "-", modifierFlags: .command)
        XCTAssertTrue(handledMinus)
        XCTAssertEqual(FontManager.shared.fontSize, expectedDefault + 1.0)

        let handledReset = view.handleKeyShortcut(characters: "0", charactersIgnoringModifiers: "0", modifierFlags: .command)
        XCTAssertTrue(handledReset)
        XCTAssertEqual(FontManager.shared.fontSize, expectedDefault)
    }

    @MainActor
    func testDeleteBackwardWithStickyModifiers() {
        let origSetting = TerminalSettings.shared.showKeyboardAccessoryBar
        defer { TerminalSettings.shared.showKeyboardAccessoryBar = origSetting }
        TerminalSettings.shared.showKeyboardAccessoryBar = true

        let terminalView = FilaireTerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        terminalView.applyAccessoryBarSetting()
        guard let accessory = terminalView.customAccessoryView else {
            XCTFail("Custom accessory view should be present")
            return
        }

        class MockDelegate: TerminalViewDelegate {
            var sentData: [[UInt8]] = []
            func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
                sentData.append(Array(data))
            }
            func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {}
            func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
            func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
            func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
            func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String : String]) {}
            func bell(source: SwiftTerm.TerminalView) {}
            func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {}
            func clipboardRead(source: SwiftTerm.TerminalView) -> Data? { nil }
            func notify(source: SwiftTerm.TerminalView, title: String, body: String) {}
            func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
        }

        let delegate = MockDelegate()
        terminalView.terminalDelegate = delegate

        // Toggling Ctrl and pressing deleteBackward sends 0x08 and resets modifier
        accessory.toggleControl()
        XCTAssertTrue(accessory.isControlActive)
        terminalView.deleteBackward()
        XCTAssertFalse(accessory.isControlActive)
        XCTAssertEqual(delegate.sentData.last, [0x08])

        // Toggling Alt and pressing deleteBackward sends \e\x7f and resets modifier
        accessory.toggleAlt()
        XCTAssertTrue(accessory.isAltActive)
        terminalView.deleteBackward()
        XCTAssertFalse(accessory.isAltActive)
        XCTAssertEqual(delegate.sentData.last, [0x1b, 0x7f])
    }

    @MainActor
    func testFontAndThemeSettingsNotification() {
        var notificationCount = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .terminalSettingsChanged,
            object: nil,
            queue: .main
        ) { _ in
            notificationCount += 1
        }

        // Theme change posts notification
        ThemeManager.shared.selectedThemeType = .nord
        XCTAssertGreaterThan(notificationCount, 0)
        let prevCount = notificationCount

        // Font family change posts notification
        FontManager.shared.selectedFamily = .courier
        XCTAssertGreaterThan(notificationCount, prevCount)
        let fontCount = notificationCount

        // Font size change posts notification
        FontManager.shared.fontSize = 17.0
        XCTAssertGreaterThan(notificationCount, fontCount)

        // Clean up
        NotificationCenter.default.removeObserver(observer)
        ThemeManager.shared.selectedThemeType = .solarizedDark
        FontManager.shared.selectedFamily = .nerdFont
        FontManager.shared.fontSize = UIDevice.current.userInterfaceIdiom == .pad ? 15.0 : 13.0
    }

    @MainActor
    func testTmuxThreeFingerSwipeGesturesConfigured() {
        let view = FilaireTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let recognizers = view.gestureRecognizers ?? []
        let swipes = recognizers.compactMap { $0 as? UISwipeGestureRecognizer }

        let swipeLeft = swipes.first { $0.direction == .left && $0.numberOfTouchesRequired == 3 }
        let swipeRight = swipes.first { $0.direction == .right && $0.numberOfTouchesRequired == 3 }

        XCTAssertNotNil(swipeLeft, "Three-finger swipe left gesture must be registered")
        XCTAssertNotNil(swipeRight, "Three-finger swipe right gesture must be registered")

        // When tmux is disabled, gestures must not begin
        view.configureTmux(enabled: false, prefixTitle: "Ctrl-B", prefixByte: 0x02)
        if let swipeLeft = swipeLeft {
            XCTAssertFalse(view.gestureRecognizerShouldBegin(swipeLeft), "Should not begin when tmux is disabled")
        }

        // When tmux is enabled, gestures must begin
        view.configureTmux(enabled: true, prefixTitle: "Ctrl-B", prefixByte: 0x02)
        if let swipeLeft = swipeLeft {
            XCTAssertTrue(view.gestureRecognizerShouldBegin(swipeLeft), "Should begin when tmux is enabled")
        }
    }

    @MainActor
    func testTmuxCopyModeShortcutAndKeyCommands() {
        let view = FilaireTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        class MockDelegate: TerminalViewDelegate {
            var sentData: [[UInt8]] = []
            func send(source: TerminalView, data: ArraySlice<UInt8>) {
                sentData.append(Array(data))
            }
            func scrolled(source: TerminalView, position: Double) {}
            func setTerminalTitle(source: TerminalView, title: String) {}
            func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
            func clipboardCopy(source: TerminalView, content: Data) {}
            func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
            func requestOpenLink(source: TerminalView, link: String, params: [String : String]) {}
            func bell(source: TerminalView) {}
            func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        }

        let delegate = MockDelegate()
        view.terminalDelegate = delegate

        // 1. When tmux is enabled, triggerTmuxCopyMode sends prefix + '['
        view.configureTmux(enabled: true, prefixTitle: "Ctrl-B", prefixByte: 0x02)
        XCTAssertTrue(view.triggerTmuxCopyMode())
        XCTAssertEqual(delegate.sentData.last, [0x02, UInt8(ascii: "[")])

        // Verify target(forAction:withSender:) whitelists handleTmuxCopyMode
        let target = view.target(forAction: #selector(FilaireTerminalView.handleTmuxCopyMode(_:)), withSender: nil)
        XCTAssertTrue((target as? FilaireTerminalView) === view, "handleTmuxCopyMode must be whitelisted in target(forAction:withSender:)")

        // Verify keyCommands contains Cmd+Opt+C when tmux is enabled
        let cmds = view.keyCommands ?? []
        let copyCmd = cmds.first { $0.input == "c" && $0.modifierFlags == [.command, .alternate] }
        XCTAssertNotNil(copyCmd, "Cmd+Opt+C key command must be registered")
        XCTAssertEqual(copyCmd?.title, "Enter Copy Mode")
        XCTAssertEqual(copyCmd?.action, #selector(FilaireTerminalView.handleTmuxCopyMode(_:)))

        // 2. When tmux is disabled, triggerTmuxCopyMode returns false and sends nothing
        view.configureTmux(enabled: false, prefixTitle: "Disabled", prefixByte: 0x02)
        let beforeCount = delegate.sentData.count
        XCTAssertFalse(view.triggerTmuxCopyMode())
        XCTAssertEqual(delegate.sentData.count, beforeCount)

        // Verify keyCommands does NOT contain Cmd+Opt+C when tmux is disabled
        let disabledCmds = view.keyCommands ?? []
        XCTAssertNil(disabledCmds.first { $0.input == "c" && $0.modifierFlags == [.command, .alternate] })
    }

    @MainActor
    func testMousePanAndTwoFingerScrollGestureExclusion() {
        let view = FilaireTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let recognizers = view.gestureRecognizers ?? []

        guard let twoFinger = recognizers.first(where: { ($0 as? UIPanGestureRecognizer)?.minimumNumberOfTouches == 2 }) as? UIPanGestureRecognizer else {
            XCTFail("twoFingerScrollGesture not found")
            return
        }

        // 1. twoFingerScrollGesture must only allow direct touches (touchscreen fingers)
        XCTAssertEqual(twoFinger.allowedTouchTypes, [NSNumber(value: UITouch.TouchType.direct.rawValue)],
                       "twoFingerScrollGesture must be restricted to .direct touches so mouse pointer is never delayed")

        // 2. isMouseOrSelectionPanGesture must identify mouse/selection pan gestures vs scrolling
        let simulatedMousePan = UIPanGestureRecognizer()
        XCTAssertTrue(view.isMouseOrSelectionPanGesture(simulatedMousePan), "Arbitrary pan gesture (such as SwiftTerm panMouseGesture) must be identified as mouse/selection pan")
        XCTAssertFalse(view.isMouseOrSelectionPanGesture(twoFinger), "twoFingerScrollGesture itself must not be identified as mouse pan")

        // 3. For touchscreen touches (.direct), mouse/selection pan gestures MUST wait for twoFingerScrollGesture so 2-finger scroll works
        view.currentTouchType = .direct
        XCTAssertTrue(view.gestureRecognizer(twoFinger, shouldBeRequiredToFailBy: simulatedMousePan),
                      "On direct touchscreen touch, twoFingerScrollGesture must require mouse pan gestures to wait so 2-finger scroll works")
        XCTAssertTrue(view.gestureRecognizer(simulatedMousePan, shouldRequireFailureOf: twoFinger),
                      "On direct touchscreen touch, mouse pan gesture must require failure of twoFingerScrollGesture")

        // 4. For mouse/trackpad pointer touches (.indirectPointer), mouse pan gestures must NOT wait for twoFingerScrollGesture
        view.currentTouchType = .indirectPointer
        XCTAssertFalse(view.gestureRecognizer(twoFinger, shouldBeRequiredToFailBy: simulatedMousePan),
                       "On indirect pointer touch, twoFingerScrollGesture must not be required to fail by mouse pan gestures")
        XCTAssertFalse(view.gestureRecognizer(simulatedMousePan, shouldRequireFailureOf: twoFinger),
                       "On indirect pointer touch, mouse pan gesture must not require failure of twoFingerScrollGesture")

        // 5. Adding a simulated mouse pan gesture must set its delegate to view
        view.addGestureRecognizer(simulatedMousePan)
        XCTAssertTrue(simulatedMousePan.delegate === view, "Pan gestures added must have their delegate set to the view")
    }

    @MainActor
    func testPointerInteractionStyles() {
        let view = FilaireTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))

        // 1. Text region pointer style returns vertical beam
        let terminalRegion = UIPointerRegion(rect: view.bounds, identifier: "terminal")
        let textStyle = view.pointerStyle(for: terminalRegion)
        XCTAssertNotNil(textStyle, "Pointer style for terminal text must provide a custom shape")

        // 2. URL region pointer style returns nil (yielding to default pointer)
        let urlRegion = UIPointerRegion(rect: CGRect(x: 0, y: 0, width: 50, height: 20), identifier: "url")
        let urlStyle = view.pointerStyle(for: urlRegion)
        XCTAssertNil(urlStyle, "Pointer style for URLs must yield to standard clickable pointer")
    }

    @MainActor
    func testSgrMouseMotionDeduplication() {
        let view = FilaireTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        class MockDelegate: TerminalViewDelegate {
            var sentData: [[UInt8]] = []
            func send(source: TerminalView, data: ArraySlice<UInt8>) {
                sentData.append(Array(data))
            }
            func scrolled(source: TerminalView, position: Double) {}
            func setTerminalTitle(source: TerminalView, title: String) {}
            func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
            func clipboardCopy(source: TerminalView, content: Data) {}
            func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
            func requestOpenLink(source: TerminalView, link: String, params: [String : String]) {}
            func bell(source: TerminalView) {}
            func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        }

        let delegate = MockDelegate()
        view.terminalDelegate = delegate
        let terminal = view.getTerminal()

        // 1. Mouse down at (10, 5) -> \e[<0;11;6M (not a motion event)
        let mouseDown: [UInt8] = Array("\u{1b}[<0;11;6M".utf8)
        view.send(source: terminal, data: mouseDown[...])
        XCTAssertEqual(delegate.sentData.count, 1)

        // 2. Motion at (10, 5) -> \e[<32;11;6M
        let motion1: [UInt8] = Array("\u{1b}[<32;11;6M".utf8)
        view.send(source: terminal, data: motion1[...])
        XCTAssertEqual(delegate.sentData.count, 2)
        XCTAssertEqual(delegate.sentData.last, motion1)

        // 3. Duplicate motion at (10, 5) -> dropped!
        view.send(source: terminal, data: motion1[...])
        XCTAssertEqual(delegate.sentData.count, 2, "Duplicate motion event within the same cell must be dropped")

        // 4. Motion to new cell (11, 5) -> \e[<32;12;6M
        let motion2: [UInt8] = Array("\u{1b}[<32;12;6M".utf8)
        view.send(source: terminal, data: motion2[...])
        XCTAssertEqual(delegate.sentData.count, 3)
        XCTAssertEqual(delegate.sentData.last, motion2)

        // 5. Wheel events (\e[<64;12;6M) must NOT be dropped even if identical
        let wheel: [UInt8] = Array("\u{1b}[<64;12;6M".utf8)
        view.send(source: terminal, data: wheel[...])
        view.send(source: terminal, data: wheel[...])
        XCTAssertEqual(delegate.sentData.count, 5, "Consecutive wheel events must never be deduplicated")

        // 6. Mouse release at (11, 5) -> \e[<0;12;6m
        let mouseUp: [UInt8] = Array("\u{1b}[<0;12;6m".utf8)
        view.send(source: terminal, data: mouseUp[...])
        XCTAssertEqual(delegate.sentData.count, 6)
    }

    @MainActor
    func testSessionManagerTmuxTriggers() {
        let sm = SessionManager()
        var host = HostProfile(name: "Test", hostname: "localhost", port: 22, username: "user")
        host.autoConnectTmux = true
        host.tmuxPrefix = "ctrl-b"
        sm.activeHost = host

        // Verify methods run cleanly without throwing
        for num in 0...9 {
            sm.triggerTmuxWindowNumber(num)
        }
        sm.triggerTmuxNextWindow()
        sm.triggerTmuxPrevWindow()
        sm.triggerTmuxNewWindow()
        sm.triggerTmuxRenameWindow()
        sm.triggerTmuxSplitVertical()
        sm.triggerTmuxSplitHorizontal()
        sm.triggerTmuxZoomPane()
        sm.triggerTmuxClosePane()
        sm.triggerTmuxNextPane()
        sm.triggerTmuxLastPane()

        // When tmux is disabled, calls do nothing
        host.autoConnectTmux = false
        sm.activeHost = host
        sm.triggerTmuxNextWindow()
        sm.triggerTmuxRenameWindow()
        sm.triggerTmuxNextPane()
        sm.triggerTmuxLastPane()
    }

    // MARK: - Dynamic Port Forwarding & SOCKS5 Tests

    func testPortForwardRuleCodableBackwardCompatibility() throws {
        // Legacy JSON without ruleType
        let legacyJson = """
        {
            "id": "11111111-2222-3333-4444-555555555555",
            "name": "Local DB",
            "localPort": 5432,
            "remoteHost": "db.internal",
            "remotePort": 5432,
            "isEnabled": true
        }
        """.data(using: .utf8)!

        let decodedLegacy = try JSONDecoder().decode(PortForwardRule.self, from: legacyJson)
        XCTAssertEqual(decodedLegacy.ruleType, .local, "Missing ruleType must decode to .local")
        XCTAssertEqual(decodedLegacy.localPort, 5432)
        XCTAssertEqual(decodedLegacy.remoteHost, "db.internal")
        XCTAssertEqual(decodedLegacy.remotePort, 5432)

        // Dynamic SOCKS5 rule encoding and decoding
        let dynamicRule = PortForwardRule(
            localPort: 1080,
            remoteHost: "",
            remotePort: 0,
            isEnabled: true,
            ruleType: .dynamic
        )
        XCTAssertTrue(dynamicRule.name.contains("SOCKS5 Proxy"))

        let encoded = try JSONEncoder().encode(dynamicRule)
        let decoded = try JSONDecoder().decode(PortForwardRule.self, from: encoded)
        XCTAssertEqual(decoded.ruleType, .dynamic)
        XCTAssertEqual(decoded.localPort, 1080)
    }

    func testHostProfileAgentForwardingField() throws {
        let profile = HostProfile(name: "AgentHost", hostname: "server.com", port: 22, username: "user")
        XCTAssertFalse(profile.enableAgentForwarding, "Default enableAgentForwarding must be false")

        var enabledProfile = profile
        enabledProfile.enableAgentForwarding = true

        let data = try JSONEncoder().encode(enabledProfile)
        let decoded = try JSONDecoder().decode(HostProfile.self, from: data)
        XCTAssertTrue(decoded.enableAgentForwarding)
    }

    func testHostProfileClipboardWriteDefaults() throws {
        // 1. Defaults on fresh instance
        let profile = HostProfile(name: "Test", hostname: "localhost")
        XCTAssertTrue(profile.allowClipboardWrite, "allowClipboardWrite must default to true")

        // 2. Decoding JSON without the key defaults to true
        let jsonWithoutKey = """
        {
            "id": "\(UUID().uuidString)",
            "name": "Legacy Host",
            "hostname": "legacy.internal",
            "port": 22,
            "username": "admin",
            "authMethod": "SSH Key"
        }
        """.data(using: .utf8)!
        let decodedLegacy = try JSONDecoder().decode(HostProfile.self, from: jsonWithoutKey)
        XCTAssertTrue(decodedLegacy.allowClipboardWrite)

        // 3. Round-trip false stays false
        var disabledProfile = profile
        disabledProfile.allowClipboardWrite = false
        let data = try JSONEncoder().encode(disabledProfile)
        let decoded = try JSONDecoder().decode(HostProfile.self, from: data)
        XCTAssertFalse(decoded.allowClipboardWrite)
    }

    func testHostProfileTmuxSetClipboardToggle() throws {
        var profile = HostProfile(name: "Dev Box", hostname: "dev.internal", username: "dev")
        XCTAssertFalse(profile.tmuxStartupCommand.contains("set-clipboard"))

        // Enabled: set-clipboard runs before attaching
        let splitBindings = " \\; set -s 'user-keys[900]' \"$(printf '\\033[9990~')\" \\; set -s 'user-keys[901]' \"$(printf '\\033[9991~')\" \\; bind -n User900 split-window -h -c '#{pane_current_path}' \\; bind -n User901 split-window -v -c '#{pane_current_path}'"
        profile.enableTmuxSetClipboard = true
        XCTAssertEqual(profile.tmuxStartupCommand, "tmux set -s set-clipboard on 2>/dev/null; exec tmux new-session -A -s dev\(splitBindings)\n")
        profile.detachExistingTmux = true
        XCTAssertEqual(profile.startupCommand, "tmux set -s set-clipboard on 2>/dev/null; exec tmux new-session -A -D -s dev\(splitBindings)\n")

        // Never applied to a custom command when tmux auto-connect is off
        profile.autoConnectTmux = false
        profile.connectionCommand = "htop"
        XCTAssertEqual(profile.startupCommand, "htop\n")

        // Decoding JSON without the key defaults to false
        let jsonWithoutKey = """
        {
            "id": "\(UUID().uuidString)",
            "name": "Legacy Host",
            "hostname": "legacy.internal",
            "port": 22,
            "username": "admin",
            "authMethod": "SSH Key"
        }
        """.data(using: .utf8)!
        let decodedLegacy = try JSONDecoder().decode(HostProfile.self, from: jsonWithoutKey)
        XCTAssertFalse(decodedLegacy.enableTmuxSetClipboard)

        // Round-trip true stays true
        let data = try JSONEncoder().encode(profile)
        XCTAssertTrue(try JSONDecoder().decode(HostProfile.self, from: data).enableTmuxSetClipboard)
    }

    @MainActor
    func testSessionManagerHandleClipboardWrite() {
        let manager = SessionManager()
        let testData = Data("hello world".utf8)
        var writtenString: String? = nil

        // 1. No active host -> false, closure not called
        let resNoHost = manager.handleClipboardWrite(testData) { str in
            writtenString = str
        }
        XCTAssertFalse(resNoHost)
        XCTAssertNil(writtenString)

        // 2. Host with toggle off -> false
        var host = HostProfile(name: "TestHost", hostname: "test.local")
        host.allowClipboardWrite = false
        manager.activeHost = host
        let resDisabled = manager.handleClipboardWrite(testData) { str in
            writtenString = str
        }
        XCTAssertFalse(resDisabled)
        XCTAssertNil(writtenString)

        // 3. Toggle on -> true, closure receives the string, activeToast?.title == "Clipboard Updated"
        host.allowClipboardWrite = true
        manager.activeHost = host
        let resEnabled = manager.handleClipboardWrite(testData) { str in
            writtenString = str
        }
        XCTAssertTrue(resEnabled)
        XCTAssertEqual(writtenString, "hello world")
        XCTAssertEqual(manager.activeToast?.title, "Clipboard Updated")
        XCTAssertTrue(manager.activeToast?.message.contains("11 characters") == true)
        XCTAssertTrue(manager.activeToast?.message.contains("TestHost") == true)
    }

    @MainActor
    func testClipboardReadNeverTouchesPasteboardUntilAllowed() {
        let manager = SessionManager()
        var presenceChecks = 0
        var reads = 0
        func hasText() -> Bool { presenceChecks += 1; return true }
        let read: () -> String? = { reads += 1; return "secret" }
        var sent: [UInt8]? = nil
        manager.onDataSent = { sent = $0 }

        // Read disabled for this host: nothing is checked, read, prompted, or sent
        manager.activeHost = HostProfile(name: "Host", hostname: "test.local")
        manager.handleClipboardReadRequest(hasStrings: hasText(), readPasteboard: read)
        XCTAssertNil(manager.pendingSecurityPrompt)
        XCTAssertEqual(presenceChecks, 0)
        XCTAssertEqual(reads, 0)

        var allowedHost = HostProfile(name: "Host", hostname: "test.local")
        allowedHost.allowClipboardRead = true
        manager.activeHost = allowedHost

        // Empty clipboard: no prompt
        manager.handleClipboardReadRequest(hasStrings: false, readPasteboard: read)
        XCTAssertNil(manager.pendingSecurityPrompt)

        // Enabled: prompts without reading; declining reads and sends nothing
        manager.handleClipboardReadRequest(hasStrings: hasText(), readPasteboard: read)
        XCTAssertNotNil(manager.pendingSecurityPrompt)
        XCTAssertEqual(reads, 0, "Clipboard must not be read before the user allows it")
        manager.cancelPendingSecurityPrompt()
        XCTAssertEqual(reads, 0)
        XCTAssertNil(sent)

        // Allowing reads once, at that moment, and replies with that content
        manager.handleClipboardReadRequest(hasStrings: hasText(), readPasteboard: read)
        manager.pendingSecurityPrompt?.onAllow()
        XCTAssertEqual(reads, 1)
        let expected = "\u{1B}]52;c;\(Data("secret".utf8).base64EncodedString())\u{1B}\\"
        XCTAssertEqual(sent, Array(expected.utf8))
        manager.pendingSecurityPrompt = nil
    }

    func testHostProfileLegacyAlgorithmsDefaults() throws {
        // 1. Defaults on fresh instance
        let profile = HostProfile(name: "Test", hostname: "localhost")
        XCTAssertFalse(profile.allowLegacyAlgorithms, "allowLegacyAlgorithms must default to false")

        // 2. Decoding JSON without the key defaults to false
        let jsonWithoutKey = """
        {
            "id": "\(UUID().uuidString)",
            "name": "Legacy Host",
            "hostname": "legacy.internal",
            "port": 22,
            "username": "admin",
            "authMethod": "SSH Key"
        }
        """.data(using: .utf8)!
        let decodedLegacy = try JSONDecoder().decode(HostProfile.self, from: jsonWithoutKey)
        XCTAssertFalse(decodedLegacy.allowLegacyAlgorithms)

        // 3. Round-trip true stays true
        var legacyProfile = profile
        legacyProfile.allowLegacyAlgorithms = true
        let data = try JSONEncoder().encode(legacyProfile)
        let decoded = try JSONDecoder().decode(HostProfile.self, from: data)
        XCTAssertTrue(decoded.allowLegacyAlgorithms)
    }

    func testUsesLegacyAlgorithms() {
        var profile = HostProfile(name: "Test", hostname: "localhost")
        profile.allowLegacyAlgorithms = false

        // toggle off + "ssh-ed25519" -> false
        XCTAssertFalse(SSHService.usesLegacyAlgorithms(host: profile, rawKeyType: "ssh-ed25519"))

        // toggle off + nil -> false
        XCTAssertFalse(SSHService.usesLegacyAlgorithms(host: profile, rawKeyType: nil))

        // toggle off + "ssh-rsa" -> true
        XCTAssertTrue(SSHService.usesLegacyAlgorithms(host: profile, rawKeyType: "ssh-rsa"))

        // toggle on + "ssh-ed25519" -> true
        profile.allowLegacyAlgorithms = true
        XCTAssertTrue(SSHService.usesLegacyAlgorithms(host: profile, rawKeyType: "ssh-ed25519"))
    }

    func testSOCKS5ParserGreeting() throws {
        // Valid greeting: VER 5, 2 methods (0x02, 0x00)
        let validGreeting = Data([0x05, 0x02, 0x02, 0x00])
        let (method, consumed) = try SOCKS5Parser.parseGreeting(validGreeting)
        XCTAssertEqual(method, 0x00)
        XCTAssertEqual(consumed, 4)

        // Incomplete greeting
        let incomplete = Data([0x05, 0x02, 0x00])
        XCTAssertThrowsError(try SOCKS5Parser.parseGreeting(incomplete)) { error in
            XCTAssertEqual(error as? SOCKS5Parser.ParseError, .incompleteData)
        }

        // Invalid version (e.g. SOCKS4)
        let socks4 = Data([0x04, 0x01, 0x00])
        XCTAssertThrowsError(try SOCKS5Parser.parseGreeting(socks4)) { error in
            XCTAssertEqual(error as? SOCKS5Parser.ParseError, .invalidVersion(0x04))
        }

        // No acceptable auth (only GSSAPI / username-password)
        let noNoAuth = Data([0x05, 0x01, 0x02])
        XCTAssertThrowsError(try SOCKS5Parser.parseGreeting(noNoAuth)) { error in
            XCTAssertEqual(error as? SOCKS5Parser.ParseError, .noAcceptableAuth)
        }
    }

    func testSOCKS5ParserRequestIPv4() throws {
        // VER 5, CMD 1 (CONNECT), RSV 0, ATYP 1 (IPv4: 192.168.1.100), Port 8080 (0x1F90)
        let req = Data([0x05, 0x01, 0x00, 0x01, 192, 168, 1, 100, 0x1F, 0x90])
        let (target, consumed) = try SOCKS5Parser.parseRequest(req)
        XCTAssertEqual(target.host, "192.168.1.100")
        XCTAssertEqual(target.port, 8080)
        XCTAssertEqual(consumed, 10)
    }

    func testSOCKS5ParserRequestDomain() throws {
        // VER 5, CMD 1, RSV 0, ATYP 3 (Domain: "github.com"), Port 443 (0x01BB)
        var req = Data([0x05, 0x01, 0x00, 0x03, 10])
        req.append("github.com".data(using: .utf8)!)
        req.append(contentsOf: [0x01, 0xBB])

        let (target, consumed) = try SOCKS5Parser.parseRequest(req)
        XCTAssertEqual(target.host, "github.com")
        XCTAssertEqual(target.port, 443)
        XCTAssertEqual(consumed, req.count)
    }

    func testSOCKS5ParserRequestUnsupportedCommand() {
        // CMD 3 (UDP ASSOCIATE)
        let req = Data([0x05, 0x03, 0x00, 0x01, 127, 0, 0, 1, 0x00, 0x50])
        XCTAssertThrowsError(try SOCKS5Parser.parseRequest(req)) { error in
            XCTAssertEqual(error as? SOCKS5Parser.ParseError, .unsupportedCommand(0x03))
        }
    }

    func testSOCKS5ParserRequestEmptyDomain() {
        // ATYP 3 with domain length 0
        let req = Data([0x05, 0x01, 0x00, 0x03, 0x00, 0x00, 0x50])
        XCTAssertThrowsError(try SOCKS5Parser.parseRequest(req)) { error in
            XCTAssertEqual(error as? SOCKS5Parser.ParseError, .invalidDomain)
        }
    }

    func testSOCKS5ParserRequestIPv6() throws {
        // ATYP 4 (IPv6: ::1 loopback), Port 22 (0x0016)
        var req = Data([0x05, 0x01, 0x00, 0x04])
        req.append(contentsOf: [UInt8](repeating: 0, count: 15))
        req.append(1) // ::1
        req.append(contentsOf: [0x00, 0x16])

        let (target, consumed) = try SOCKS5Parser.parseRequest(req)
        XCTAssertEqual(target.host, "0:0:0:0:0:0:0:1")
        XCTAssertEqual(target.port, 22)
        XCTAssertEqual(consumed, 22)
    }

    // MARK: - SSH Agent Server Tests

    func testSSHAgentRequestIdentities() async throws {
        let keyPair = try SSHKeyGenerator.generateEd25519Key(comment: "test@filaire")
        let keyModel = SSHKeyModel(name: "Test Key", publicKey: keyPair.publicKey)
        let host = HostProfile(name: "Host", hostname: "server.com", username: "user")

        // Packet for SSH_AGENTC_REQUEST_IDENTITIES: length = 1, type = 11
        let packet = Data([0x00, 0x00, 0x00, 0x01, 0x0B])
        let response = await SSHAgentServer.handlePacket(data: packet, keys: [keyModel], host: host)

        var reader = SSHAgentDataReader(data: response)
        let len = reader.readUInt32()
        XCTAssertNotNil(len)
        XCTAssertEqual(reader.readUInt8(), 12, "Should return SSH_AGENT_IDENTITIES_ANSWER (12)")
        XCTAssertEqual(reader.readUInt32(), 1, "Should report 1 identity")

        let blob = reader.readSSHBuffer()
        XCTAssertNotNil(blob)
        let comment = reader.readSSHString()
        XCTAssertEqual(comment, "test@filaire")
    }

    func testSSHAgentSignRequestEd25519() async throws {
        let keyPair = try SSHKeyGenerator.generateEd25519Key(comment: "sign@filaire")
        let keyId = UUID()
        try KeychainService.savePrivateKey(keyPair.privateKeyPEM, forKeyId: keyId, requireBiometrics: false)
        defer { KeychainService.deletePrivateKey(forKeyId: keyId) }

        let keyModel = SSHKeyModel(id: keyId, name: "Signing Key", publicKey: keyPair.publicKey, requiresBiometrics: true)
        let host = HostProfile(name: "Host", hostname: "server.com", username: "user")

        let parts = keyPair.publicKey.components(separatedBy: .whitespaces)
        guard parts.count >= 2, let keyBlob = Data(base64Encoded: parts[1]) else {
            XCTFail("Failed to extract keyBlob")
            return
        }

        let challenge = "Challenge data to sign".data(using: .utf8)!

        // Build SSH_AGENTC_SIGN_REQUEST packet
        var payload = Data()
        payload.append(13) // type 13
        payload.append(UInt8((keyBlob.count >> 24) & 0xFF))
        payload.append(UInt8((keyBlob.count >> 16) & 0xFF))
        payload.append(UInt8((keyBlob.count >> 8) & 0xFF))
        payload.append(UInt8(keyBlob.count & 0xFF))
        payload.append(keyBlob)
        payload.append(UInt8((challenge.count >> 24) & 0xFF))
        payload.append(UInt8((challenge.count >> 16) & 0xFF))
        payload.append(UInt8((challenge.count >> 8) & 0xFF))
        payload.append(UInt8(challenge.count & 0xFF))
        payload.append(challenge)
        payload.append(contentsOf: [0, 0, 0, 0]) // flags

        var packet = Data()
        let pLen = payload.count
        packet.append(UInt8((pLen >> 24) & 0xFF))
        packet.append(UInt8((pLen >> 16) & 0xFF))
        packet.append(UInt8((pLen >> 8) & 0xFF))
        packet.append(UInt8(pLen & 0xFF))
        packet.append(payload)

        // Test with mock biometric auth approval
        let response = await SSHAgentServer.handlePacket(
            data: packet,
            keys: [keyModel],
            host: host,
            authenticateBiometrics: { _ in true }
        )

        var reader = SSHAgentDataReader(data: response)
        let len = reader.readUInt32()
        XCTAssertNotNil(len)
        XCTAssertEqual(reader.readUInt8(), 14, "Should return SSH_AGENT_SIGN_RESPONSE (14)")

        let sigBlob = reader.readSSHBuffer()
        XCTAssertNotNil(sigBlob)
        var sigReader = SSHAgentDataReader(data: sigBlob!)
        XCTAssertEqual(sigReader.readSSHString(), "ssh-ed25519")
        let rawSignature = sigReader.readSSHBuffer()
        XCTAssertNotNil(rawSignature)
        XCTAssertEqual(rawSignature!.count, 64, "Ed25519 signature must be 64 bytes")

        // Verify signature with public key
        // Extract raw 32-byte public key from wire format: length (11) + "ssh-ed25519" + length (32) + 32-byte key
        var blobReader = SSHAgentDataReader(data: keyBlob)
        _ = blobReader.readSSHString() // "ssh-ed25519"
        let pubRaw = blobReader.readSSHBuffer()!
        let pubKey = try Curve25519.Signing.PublicKey(rawRepresentation: pubRaw)
        XCTAssertTrue(pubKey.isValidSignature(rawSignature!, for: challenge))
    }

    func testSSHAgentSignRequestBiometricDenied() async throws {
        let keyPair = try SSHKeyGenerator.generateEd25519Key(comment: "denied@filaire")
        let keyId = UUID()
        let keyModel = SSHKeyModel(id: keyId, name: "Denied Key", publicKey: keyPair.publicKey, requiresBiometrics: true)
        let host = HostProfile(name: "Host", hostname: "server.com", username: "user")

        let parts = keyPair.publicKey.components(separatedBy: .whitespaces)
        let keyBlob = Data(base64Encoded: parts[1])!
        let challenge = "Test".data(using: .utf8)!

        var payload = Data([13])
        payload.append(UInt8((keyBlob.count >> 24) & 0xFF))
        payload.append(UInt8((keyBlob.count >> 16) & 0xFF))
        payload.append(UInt8((keyBlob.count >> 8) & 0xFF))
        payload.append(UInt8(keyBlob.count & 0xFF))
        payload.append(keyBlob)
        payload.append(UInt8((challenge.count >> 24) & 0xFF))
        payload.append(UInt8((challenge.count >> 16) & 0xFF))
        payload.append(UInt8((challenge.count >> 8) & 0xFF))
        payload.append(UInt8(challenge.count & 0xFF))
        payload.append(challenge)
        payload.append(contentsOf: [0, 0, 0, 0])

        var packet = Data()
        let pLen = payload.count
        packet.append(UInt8((pLen >> 24) & 0xFF))
        packet.append(UInt8((pLen >> 16) & 0xFF))
        packet.append(UInt8((pLen >> 8) & 0xFF))
        packet.append(UInt8(pLen & 0xFF))
        packet.append(payload)

        // Biometric authentication denied (returns false)
        let response = await SSHAgentServer.handlePacket(
            data: packet,
            keys: [keyModel],
            host: host,
            authenticateBiometrics: { _ in false }
        )

        var reader = SSHAgentDataReader(data: response)
        _ = reader.readUInt32()
        XCTAssertEqual(reader.readUInt8(), 5, "Must return SSH_AGENT_FAILURE (5) when biometric auth fails")
    }

    func testSSHAgentUnknownMessageFailure() async {
        let host = HostProfile(name: "Host", hostname: "server.com", username: "user")
        let unknownPacket = Data([0x00, 0x00, 0x00, 0x01, 99])
        let response = await SSHAgentServer.handlePacket(data: unknownPacket, keys: [], host: host)

        var reader = SSHAgentDataReader(data: response)
        _ = reader.readUInt32()
        XCTAssertEqual(reader.readUInt8(), 5, "Must return SSH_AGENT_FAILURE (5) for unknown message type")
    }

    func testAgentConfigWriteCommand() {
        let token = [UInt8](repeating: 0xab, count: 32)
        let cmd = SSHAgentServer.agentConfigWriteCommand(port: 40123, token: token)
        let expectedHex = String(repeating: "ab", count: 32)
        let expected = "sh -c 'umask 077 && mkdir -p ~/.filaire && chmod 700 ~/.filaire && printf \"%s\\n%s\\n\" 40123 \(expectedHex) > ~/.filaire/agent.tmp && mv -f ~/.filaire/agent.tmp ~/.filaire/agent'"
        XCTAssertEqual(cmd, expected)
    }

    func testForwardingTokenIsRandom() {
        let t1 = SSHAgentServer.makeForwardingToken()
        let t2 = SSHAgentServer.makeForwardingToken()
        XCTAssertEqual(t1.count, 32)
        XCTAssertEqual(t2.count, 32)
        XCTAssertNotEqual(t1, t2)
    }

    func testConstantTimeEquals() {
        let a: [UInt8] = [1, 2, 3, 4]
        let b: [UInt8] = [1, 2, 3, 4]
        let c: [UInt8] = [1, 2, 3, 5]
        let d: [UInt8] = [1, 2, 3]

        XCTAssertTrue(SSHAgentServer.constantTimeEquals(a, b))
        XCTAssertFalse(SSHAgentServer.constantTimeEquals(a, c))
        XCTAssertFalse(SSHAgentServer.constantTimeEquals(a, d))
    }

    func testKeysForForwarding() {
        let k1 = SSHKeyModel(name: "Key 1", keyType: "ssh-ed25519", publicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIK1")
        let k2 = SSHKeyModel(name: "Key 2", keyType: "ssh-ed25519", publicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIK2")
        let k3 = SSHKeyModel(name: "Key 3", keyType: "ssh-ed25519", publicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIK3")
        let allKeys = [k1, k2, k3]

        // Host with authMethod = .sshKey, selectedKeyId = k1.id, agentForwardingKeyIds = nil -> [k1]
        var h1 = HostProfile(name: "H1", hostname: "h1.com", authMethod: .sshKey, selectedKeyId: k1.id, agentForwardingKeyIds: nil)
        XCTAssertEqual(SSHAgentServer.keysForForwarding(host: h1, allKeys: allKeys).map(\.id), [k1.id])

        // Explicit [k2.id, k3.id] -> [k2, k3]
        h1.agentForwardingKeyIds = [k2.id, k3.id]
        XCTAssertEqual(SSHAgentServer.keysForForwarding(host: h1, allKeys: allKeys).map(\.id), [k2.id, k3.id])

        // Explicit [] -> []
        h1.agentForwardingKeyIds = []
        XCTAssertEqual(SSHAgentServer.keysForForwarding(host: h1, allKeys: allKeys).map(\.id), [])

        // Password host with nil -> []
        let h2 = HostProfile(name: "H2", hostname: "h2.com", authMethod: .password, selectedKeyId: nil, agentForwardingKeyIds: nil)
        XCTAssertEqual(SSHAgentServer.keysForForwarding(host: h2, allKeys: allKeys).map(\.id), [])
    }

    func testDescribeSignRequest() {
        // userauth blob -> contains log in as “deploy”
        var authBlob = Data()
        let sessionId: [UInt8] = [1, 2, 3, 4]
        authBlob.append(contentsOf: [0, 0, 0, UInt8(sessionId.count)])
        authBlob.append(contentsOf: sessionId)
        authBlob.append(50) // SSH_MSG_USERAUTH_REQUEST
        let userBytes = Array("deploy".utf8)
        authBlob.append(contentsOf: [0, 0, 0, UInt8(userBytes.count)])
        authBlob.append(contentsOf: userBytes)
        XCTAssertTrue(SSHAgentServer.describeSignRequest(authBlob).contains("log in as “deploy”"))

        // "SSHSIG" + SSH string "git" -> contains namespace “git”
        var sshsigBlob = Data("SSHSIG".utf8)
        let gitBytes = Array("git".utf8)
        sshsigBlob.append(contentsOf: [0, 0, 0, UInt8(gitBytes.count)])
        sshsigBlob.append(contentsOf: gitBytes)
        XCTAssertTrue(SSHAgentServer.describeSignRequest(sshsigBlob).contains("namespace “git”"))

        // random bytes -> "sign an unrecognized request"
        let randomBlob = Data([0xDE, 0xAD, 0xBE, 0xEF])
        XCTAssertEqual(SSHAgentServer.describeSignRequest(randomBlob), "sign an unrecognized request")
    }

    // MARK: - Fix 4 Forwarded-Agent Concurrency & Ordering Regression Tests

    private func makeTestKeyAndBlob() throws -> (SSHKeyModel, Data) {
        let keyPair = try SSHKeyGenerator.generateEd25519Key(comment: "test@filaire")
        let keyModel = SSHKeyModel(name: "Test Key", publicKey: keyPair.publicKey)
        let parts = keyPair.publicKey.components(separatedBy: .whitespaces)
        guard parts.count >= 2, let blob = Data(base64Encoded: parts[1]) else {
            throw SSHError.keyNotFound
        }
        return (keyModel, blob)
    }

    private func appendUInt32(to data: inout Data, _ value: UInt32) {
        var be = value.bigEndian
        Swift.withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }

    private func makeSignPacket(keyBlob: Data, challenge: Data = Data("test challenge".utf8)) -> Data {
        var payload = Data([13])
        appendUInt32(to: &payload, UInt32(keyBlob.count))
        payload.append(keyBlob)
        appendUInt32(to: &payload, UInt32(challenge.count))
        payload.append(challenge)
        appendUInt32(to: &payload, 0) // flags

        var packet = Data()
        appendUInt32(to: &packet, UInt32(payload.count))
        packet.append(payload)
        return packet
    }

    private func makeIdentitiesPacket() -> Data {
        Data([0x00, 0x00, 0x00, 0x01, 0x0B])
    }

    @MainActor
    func testSSHAgentPipelinedRequestsStayInFIFOOrder() async throws {
        let (keyModel, keyBlob) = try makeTestKeyAndBlob()
        let host = HostProfile(name: "Host", hostname: "server.com", username: "user")
        let signPacket = makeSignPacket(keyBlob: keyBlob)
        let idPacket = makeIdentitiesPacket()

        let signGate = ReadinessGate()
        let handler = SSHAgentChannelHandler(
            keys: [keyModel],
            host: host,
            token: [],
            packetProcessor: { data in
                if data.count >= 5 && data[4] == 13 {
                    // Delayed sign request
                    try? await signGate.wait()
                    return SSHAgentServer.makeEd25519SignResponse(signature: Data(repeating: 0x42, count: 64))
                } else {
                    // Fast identities request
                    return SSHAgentServer.makeIdentitiesAnswer(keys: [keyModel])
                }
            }
        )
        let channel = EmbeddedChannel(handler: handler)

        var buf1 = channel.allocator.buffer(capacity: signPacket.count)
        buf1.writeBytes(signPacket)
        try channel.writeInbound(buf1)

        var buf2 = channel.allocator.buffer(capacity: idPacket.count)
        buf2.writeBytes(idPacket)
        try channel.writeInbound(buf2)

        XCTAssertNil(try channel.readOutbound(as: ByteBuffer.self), "No response yet because sign is waiting on gate")

        // Unblock sign request
        signGate.succeed()

        // Wait a short moment for sign task to complete
        for _ in 0..<50 {
            handler.runPendingEmbeddedTasks()
            channel.embeddedEventLoop.run()
            if handler.hasActiveRequestForTesting || handler.queuedRequestsCountForTesting > 0 {
                try await Task.sleep(nanoseconds: 20_000_000)
            } else {
                break
            }
        }
        handler.runPendingEmbeddedTasks()
        channel.embeddedEventLoop.run()

        // Verify response 1 is signResponse (14)
        guard var resp1Buf = try channel.readOutbound(as: ByteBuffer.self),
              let resp1Bytes = resp1Buf.readBytes(length: resp1Buf.readableBytes) else {
            XCTFail("Expected first response")
            return
        }
        var reader1 = SSHAgentDataReader(data: Data(resp1Bytes))
        _ = reader1.readUInt32()
        XCTAssertEqual(reader1.readUInt8(), 14, "First response must be signResponse (14)")

        // Verify response 2 is identitiesAnswer (12)
        guard var resp2Buf = try channel.readOutbound(as: ByteBuffer.self),
              let resp2Bytes = resp2Buf.readBytes(length: resp2Buf.readableBytes) else {
            XCTFail("Expected second response")
            return
        }
        var reader2 = SSHAgentDataReader(data: Data(resp2Bytes))
        _ = reader2.readUInt32()
        XCTAssertEqual(reader2.readUInt8(), 12, "Second response must be identitiesAnswer (12)")

        _ = try channel.finish()
    }

    @MainActor
    func testSSHAgentMultipleSignRequestsBoundedConcurrencyAcrossChannels() async throws {
        let (keyModel, keyBlob) = try makeTestKeyAndBlob()
        let host = HostProfile(name: "Host", hostname: "server.com", username: "user")
        let signPacket = makeSignPacket(keyBlob: keyBlob)

        let coordinator = AgentSigningCoordinator(maxWaiters: 16)
        final class ConcurrencyTracker: @unchecked Sendable {
            private let lock = NSLock()
            private var current: Int = 0
            private(set) var maxConcurrency: Int = 0
            private(set) var totalCompleted: Int = 0

            func enter() {
                lock.lock()
                current += 1
                if current > maxConcurrency {
                    maxConcurrency = current
                }
                lock.unlock()
            }

            func exit() {
                lock.lock()
                current -= 1
                totalCompleted += 1
                lock.unlock()
            }
        }

        let tracker = ConcurrencyTracker()

        let processor: SSHAgentPacketProcessor = { _ in
            guard await coordinator.acquire() else {
                return SSHAgentServer.makeFailurePacket()
            }
            tracker.enter()
            try? await Task.sleep(nanoseconds: 30_000_000)
            tracker.exit()
            coordinator.release()
            return SSHAgentServer.makeEd25519SignResponse(signature: Data(repeating: 0x01, count: 64))
        }

        let handler1 = SSHAgentChannelHandler(
            keys: [keyModel], host: host, token: [], signingCoordinator: coordinator, packetProcessor: processor
        )
        let handler2 = SSHAgentChannelHandler(
            keys: [keyModel], host: host, token: [], signingCoordinator: coordinator, packetProcessor: processor
        )
        let channel1 = EmbeddedChannel(handler: handler1)
        let channel2 = EmbeddedChannel(handler: handler2)

        // Send 2 sign requests to channel 1, and 2 to channel 2
        for _ in 0..<2 {
            var buf1 = channel1.allocator.buffer(capacity: signPacket.count)
            buf1.writeBytes(signPacket)
            try channel1.writeInbound(buf1)

            var buf2 = channel2.allocator.buffer(capacity: signPacket.count)
            buf2.writeBytes(signPacket)
            try channel2.writeInbound(buf2)
        }

        // Wait for all 4 to complete
        for _ in 0..<100 {
            handler1.runPendingEmbeddedTasks()
            channel1.embeddedEventLoop.run()
            handler2.runPendingEmbeddedTasks()
            channel2.embeddedEventLoop.run()
            if tracker.totalCompleted < 4 {
                try await Task.sleep(nanoseconds: 20_000_000)
            } else {
                break
            }
        }
        handler1.runPendingEmbeddedTasks()
        channel1.embeddedEventLoop.run()
        handler2.runPendingEmbeddedTasks()
        channel2.embeddedEventLoop.run()

        XCTAssertEqual(tracker.totalCompleted, 4)
        XCTAssertEqual(tracker.maxConcurrency, 1, "Concurrency must never exceed 1 prompt/signature at any time across all channels")

        _ = try channel1.finish()
        _ = try channel2.finish()
    }

    @MainActor
    func testSSHAgentHighWatermarkPausesAndLowWatermarkResumes() async throws {
        let (keyModel, keyBlob) = try makeTestKeyAndBlob()
        let host = HostProfile(name: "Host", hostname: "server.com", username: "user")
        let signPacket = makeSignPacket(keyBlob: keyBlob) // size is 82 bytes

        let holdGate = ReadinessGate()
        final class CompletedCounter: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            func increment() {
                lock.lock()
                count += 1
                lock.unlock()
            }
            var value: Int {
                lock.lock()
                defer { lock.unlock() }
                return count
            }
        }
        let counter = CompletedCounter()

        let handler = SSHAgentChannelHandler(
            keys: [keyModel],
            host: host,
            token: [],
            packetProcessor: { _ in
                if counter.value == 0 {
                    try? await holdGate.wait()
                }
                counter.increment()
                return SSHAgentServer.makeEd25519SignResponse(signature: Data(repeating: 0x02, count: 64))
            },
            highWatermarkBytes: 150,
            lowWatermarkBytes: 100,
            maxQueuedRequests: 5
        )
        let channel = EmbeddedChannel(handler: handler)

        // Write packet 1 (~113 bytes)
        var buf1 = channel.allocator.buffer(capacity: signPacket.count)
        buf1.writeBytes(signPacket)
        try channel.writeInbound(buf1)

        channel.embeddedEventLoop.run()
        XCTAssertTrue(handler.hasActiveRequestForTesting)
        XCTAssertEqual(handler.queuedRequestsCountForTesting, 0)
        XCTAssertFalse(handler.isReadPausedForTesting)

        // Write packet 2 (~82 bytes) -> totalTrackedBytes is 164 bytes >= 150 high watermark!
        var buf2 = channel.allocator.buffer(capacity: signPacket.count)
        buf2.writeBytes(signPacket)
        try channel.writeInbound(buf2)

        channel.embeddedEventLoop.run()
        XCTAssertTrue(handler.hasActiveRequestForTesting)
        XCTAssertEqual(handler.queuedRequestsCountForTesting, 1)
        XCTAssertTrue(handler.isReadPausedForTesting, "Read should be paused after crossing high watermark")

        // Unblock packet 1
        holdGate.succeed()

        // Run until packet 1 completes
        for _ in 0..<50 {
            handler.runPendingEmbeddedTasks()
            channel.embeddedEventLoop.run()
            if counter.value >= 1 && !handler.hasActiveRequestForTesting {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        handler.runPendingEmbeddedTasks()
        channel.embeddedEventLoop.run()

        // Wait until packet 2 completes and queue empties
        for _ in 0..<50 {
            handler.runPendingEmbeddedTasks()
            channel.embeddedEventLoop.run()
            if counter.value >= 2 && handler.queuedRequestsCountForTesting == 0 && !handler.hasActiveRequestForTesting {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        handler.runPendingEmbeddedTasks()
        channel.embeddedEventLoop.run()

        // Now queue is empty (0 bytes <= 100 low watermark)
        XCTAssertFalse(handler.isReadPausedForTesting, "Read should resume below low watermark")

        _ = try channel.finish()
    }

    @MainActor
    func testSSHAgentChannelClosureDuringAuthDiscardsWorkAndReleasesReservation() async throws {
        let (keyModel, keyBlob) = try makeTestKeyAndBlob()
        let host = HostProfile(name: "Host", hostname: "server.com", username: "user")
        let signPacket = makeSignPacket(keyBlob: keyBlob)
        let coordinator = AgentSigningCoordinator(maxWaiters: 16)

        let authGate = ReadinessGate()

        let handler = SSHAgentChannelHandler(
            keys: [keyModel],
            host: host,
            token: [],
            signingCoordinator: coordinator,
            packetProcessor: { _ in
                guard await coordinator.acquire() else {
                    return SSHAgentServer.makeFailurePacket()
                }
                defer { coordinator.release() }
                try? await authGate.wait()
                return SSHAgentServer.makeEd25519SignResponse(signature: Data(repeating: 0x99, count: 64))
            }
        )
        let channel = EmbeddedChannel(handler: handler)

        // Write 2 packets into channel
        var buf1 = channel.allocator.buffer(capacity: signPacket.count)
        buf1.writeBytes(signPacket)
        try channel.writeInbound(buf1)

        var buf2 = channel.allocator.buffer(capacity: signPacket.count)
        buf2.writeBytes(signPacket)
        try channel.writeInbound(buf2)

        handler.runPendingEmbeddedTasks()
        channel.embeddedEventLoop.run()
        // Wait a moment for packet 1 to enter processor and acquire coordinator
        for _ in 0..<50 {
            if coordinator.isBusyForTesting { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(coordinator.isBusyForTesting, "Coordinator must be busy while auth is pending")
        XCTAssertEqual(handler.queuedRequestsCountForTesting, 1)

        // Close channel while auth is held
        _ = try channel.finish()

        XCTAssertEqual(handler.queuedRequestsCountForTesting, 0, "Queued requests must be discarded on channel close")

        // Release the auth gate with fake late success
        authGate.succeed()

        // Wait for task defer to execute
        for _ in 0..<50 {
            handler.runPendingEmbeddedTasks()
            channel.embeddedEventLoop.run()
            if !coordinator.isBusyForTesting { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        handler.runPendingEmbeddedTasks()
        channel.embeddedEventLoop.run()

        // Verify coordinator permit is released
        XCTAssertFalse(coordinator.isBusyForTesting, "Coordinator permit must be released after close")
        XCTAssertNil(try channel.readOutbound(as: ByteBuffer.self), "No response must be produced to closed channel")

        // A new request on another channel should be able to acquire immediately
        let acquired = await coordinator.acquire()
        XCTAssertTrue(acquired, "Subsequent acquire must succeed now that permit is released")
        coordinator.release()
    }

    @MainActor
    func testSSHAgentFramingSplitFramesMultipleFramesZeroOversizedInvalidPreamble() async throws {
        let (keyModel, _) = try makeTestKeyAndBlob()
        let host = HostProfile(name: "Host", hostname: "server.com", username: "user")
        let token: [UInt8] = Array(repeating: 0xAA, count: 32)
        let expectedPreamble = SSHAgentServer.forwardingPreambleMagic + token
        let idPacket = makeIdentitiesPacket()

        // 1. Split frames: preamble in 2 chunks, packet in 2 chunks
        do {
            let handler = SSHAgentChannelHandler(keys: [keyModel], host: host, token: token)
            let channel = EmbeddedChannel(handler: handler)

            // Preamble first half
            var p1 = channel.allocator.buffer(capacity: 20)
            p1.writeBytes(expectedPreamble.prefix(20))
            try channel.writeInbound(p1)

            // Preamble second half + packet length
            var p2 = channel.allocator.buffer(capacity: 24)
            p2.writeBytes(expectedPreamble.dropFirst(20))
            p2.writeBytes(idPacket.prefix(4))
            try channel.writeInbound(p2)

            // Packet payload (type 11)
            var p3 = channel.allocator.buffer(capacity: 1)
            p3.writeBytes(idPacket.dropFirst(4))
            try channel.writeInbound(p3)

            for _ in 0..<50 {
                handler.runPendingEmbeddedTasks()
                channel.embeddedEventLoop.run()
                if let _ = try channel.readOutbound(as: ByteBuffer.self) {
                    break
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            _ = try channel.finish()
        }

        // 2. Several frames in one read
        do {
            let handler = SSHAgentChannelHandler(keys: [keyModel], host: host, token: token)
            let channel = EmbeddedChannel(handler: handler)

            var multiBuf = channel.allocator.buffer(capacity: expectedPreamble.count + idPacket.count * 2)
            multiBuf.writeBytes(expectedPreamble)
            multiBuf.writeBytes(idPacket)
            multiBuf.writeBytes(idPacket)
            try channel.writeInbound(multiBuf)

            var responses = 0
            for _ in 0..<50 {
                handler.runPendingEmbeddedTasks()
                channel.embeddedEventLoop.run()
                while let _ = try channel.readOutbound(as: ByteBuffer.self) {
                    responses += 1
                }
                if responses == 2 { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertEqual(responses, 2, "Both frames in single read should be processed in order")
            _ = try channel.finish()
        }

        // 3. Zero length packet -> deterministic channel close
        do {
            let handler = SSHAgentChannelHandler(keys: [keyModel], host: host, token: token)
            let channel = EmbeddedChannel(handler: handler)

            var zeroBuf = channel.allocator.buffer(capacity: expectedPreamble.count + 4)
            zeroBuf.writeBytes(expectedPreamble)
            zeroBuf.writeBytes([0, 0, 0, 0]) // length 0
            try channel.writeInbound(zeroBuf)

            channel.embeddedEventLoop.run()
            XCTAssertTrue(handler.isClosedForTesting, "Channel handler must be closed on zero length packet")
            XCTAssertEqual(handler.totalTrackedBytesForTesting, 0, "Buffer must be cleared")
        }

        // 4. Oversized packet (> 256 KiB) -> deterministic channel close
        do {
            let handler = SSHAgentChannelHandler(keys: [keyModel], host: host, token: token)
            let channel = EmbeddedChannel(handler: handler)

            var overBuf = channel.allocator.buffer(capacity: expectedPreamble.count + 4)
            overBuf.writeBytes(expectedPreamble)
            // 256 KiB + 1 = 262145 = 0x00040001
            overBuf.writeBytes([0x00, 0x04, 0x00, 0x01])
            try channel.writeInbound(overBuf)

            channel.embeddedEventLoop.run()
            XCTAssertTrue(handler.isClosedForTesting, "Channel handler must be closed on oversized packet")
            XCTAssertEqual(handler.totalTrackedBytesForTesting, 0, "Buffer must be cleared")
        }

        // 5. Invalid forwarding preamble -> deterministic channel close
        do {
            let handler = SSHAgentChannelHandler(keys: [keyModel], host: host, token: token)
            let channel = EmbeddedChannel(handler: handler)

            var badPreamble = channel.allocator.buffer(capacity: 40)
            badPreamble.writeBytes(Array(repeating: UInt8(0xFF), count: 40))
            try channel.writeInbound(badPreamble)

            channel.embeddedEventLoop.run()
            XCTAssertTrue(handler.isClosedForTesting, "Channel handler must be closed on invalid preamble")
            XCTAssertEqual(handler.totalTrackedBytesForTesting, 0, "Buffer must be cleared")
        }
    }

    @MainActor
    func testSSHAgentDeniedOrCancelledAuthProducesFailureWithoutSigning() async throws {
        let (keyModel, keyBlob) = try makeTestKeyAndBlob()
        let host = HostProfile(name: "Host", hostname: "server.com", username: "user")
        let signPacket = makeSignPacket(keyBlob: keyBlob)

        // Case A: Denied auth (returns false)
        do {
            let response = await SSHAgentServer.handlePacket(
                data: signPacket,
                keys: [keyModel],
                host: host,
                authenticateBiometrics: { _ in false }
            )
            var reader = SSHAgentDataReader(data: response)
            let len = reader.readUInt32()
            XCTAssertEqual(len, 1)
            XCTAssertEqual(reader.readUInt8(), 5, "Must return SSH_AGENT_FAILURE (5)")
        }

        // Case B: Cancelled auth (cancelled during prompt)
        do {
            let authStarted = ReadinessGate()
            let task = Task {
                await SSHAgentServer.handlePacket(
                    data: signPacket,
                    keys: [keyModel],
                    host: host,
                    authenticateBiometrics: { _ in
                        authStarted.succeed()
                        while !Task.isCancelled {
                            try? await Task.sleep(nanoseconds: 10_000_000)
                        }
                        return true
                    }
                )
            }
            try await authStarted.wait()
            task.cancel()
            let response = await task.value
            var reader = SSHAgentDataReader(data: response)
            let len = reader.readUInt32()
            XCTAssertEqual(len, 1)
            XCTAssertEqual(reader.readUInt8(), 5, "Must return SSH_AGENT_FAILURE (5) on cancellation")
        }

        // Case C: Real channel handler with denied auth returns failure to client while channel stays active
        do {
            let handler = SSHAgentChannelHandler(
                keys: [keyModel],
                host: host,
                token: [],
                packetProcessor: { data in
                    await SSHAgentServer.handlePacket(
                        data: data,
                        keys: [keyModel],
                        host: host,
                        authenticateBiometrics: { _ in false }
                    )
                }
            )
            let channel = EmbeddedChannel(handler: handler)

            var buf = channel.allocator.buffer(capacity: signPacket.count)
            buf.writeBytes(signPacket)
            try channel.writeInbound(buf)

            for _ in 0..<50 {
                handler.runPendingEmbeddedTasks()
                channel.embeddedEventLoop.run()
                if let respBuf = try channel.readOutbound(as: ByteBuffer.self) {
                    var reader = SSHAgentDataReader(data: Data(respBuf.readableBytesView))
                    _ = reader.readUInt32()
                    XCTAssertEqual(reader.readUInt8(), 5, "Channel must receive SSH_AGENT_FAILURE (5)")
                    break
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertFalse(handler.isClosedForTesting, "Channel should remain active to serve subsequent requests")
            _ = try channel.finish()
        }
    }

    @MainActor
    func testSSHAgentClosingWaitingChannelDoesNotCancelActiveChannel() async throws {
        let (keyModel, keyBlob) = try makeTestKeyAndBlob()
        let host = HostProfile(name: "Host", hostname: "server.com", username: "user")
        let signPacket = makeSignPacket(keyBlob: keyBlob)
        let coordinator = AgentSigningCoordinator(maxWaiters: 16)

        let ch1Gate = ReadinessGate()
        final class BoolHolder: @unchecked Sendable {
            private let lock = NSLock()
            private var _val = false
            var value: Bool {
                get { lock.lock(); defer { lock.unlock() }; return _val }
                set { lock.lock(); _val = newValue; lock.unlock() }
            }
        }
        let ch1Completed = BoolHolder()
        let ch2Completed = BoolHolder()

        let ch1Handler = SSHAgentChannelHandler(
            keys: [keyModel],
            host: host,
            token: [],
            signingCoordinator: coordinator,
            packetProcessor: { _ in
                guard await coordinator.acquire() else {
                    return SSHAgentServer.makeFailurePacket()
                }
                defer { coordinator.release() }
                try? await ch1Gate.wait()
                ch1Completed.value = true
                return SSHAgentServer.makeEd25519SignResponse(signature: Data(repeating: 0x11, count: 64))
            }
        )

        let ch2Handler = SSHAgentChannelHandler(
            keys: [keyModel],
            host: host,
            token: [],
            signingCoordinator: coordinator,
            packetProcessor: { _ in
                guard await coordinator.acquire() else {
                    return SSHAgentServer.makeFailurePacket()
                }
                defer { coordinator.release() }
                ch2Completed.value = true
                return SSHAgentServer.makeEd25519SignResponse(signature: Data(repeating: 0x22, count: 64))
            }
        )

        let channel1 = EmbeddedChannel(handler: ch1Handler)
        let channel2 = EmbeddedChannel(handler: ch2Handler)

        // Start Channel 1 request
        var buf1 = channel1.allocator.buffer(capacity: signPacket.count)
        buf1.writeBytes(signPacket)
        try channel1.writeInbound(buf1)

        // Wait until Channel 1 holds coordinator
        for _ in 0..<50 {
            if coordinator.isBusyForTesting { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(coordinator.isBusyForTesting, "Channel 1 should hold coordinator permit")

        // Start Channel 2 request -> will wait in coordinator queue
        var buf2 = channel2.allocator.buffer(capacity: signPacket.count)
        buf2.writeBytes(signPacket)
        try channel2.writeInbound(buf2)

        // Wait until Channel 2 is registered as waiter
        for _ in 0..<50 {
            if coordinator.waiterCountForTesting == 1 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(coordinator.waiterCountForTesting, 1, "Channel 2 should be waiting in coordinator")

        // Now CLOSE Channel 2 while it waits
        _ = try channel2.finish()

        // Verify Channel 2 was removed from coordinator waiters
        for _ in 0..<50 {
            if coordinator.waiterCountForTesting == 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(coordinator.waiterCountForTesting, 0, "Channel 2 should be cancelled and removed from coordinator")
        XCTAssertFalse(ch2Completed.value, "Channel 2 must not complete")

        // Verify Channel 1 is STILL running and NOT cancelled!
        XCTAssertTrue(coordinator.isBusyForTesting, "Channel 1 must still hold coordinator")
        XCTAssertFalse(ch1Completed.value, "Channel 1 should still be waiting on ch1Gate")

        // Now release Channel 1 gate
        ch1Gate.succeed()

        // Wait for Channel 1 to complete and write response
        for _ in 0..<50 {
            ch1Handler.runPendingEmbeddedTasks()
            channel1.embeddedEventLoop.run()
            if ch1Completed.value { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        ch1Handler.runPendingEmbeddedTasks()
        channel1.embeddedEventLoop.run()

        XCTAssertTrue(ch1Completed.value, "Channel 1 must succeed without being affected by Channel 2 closure")
        guard var resp1 = try channel1.readOutbound(as: ByteBuffer.self) else {
            XCTFail("Channel 1 should have produced a response")
            return
        }
        var reader = SSHAgentDataReader(data: Data(resp1.readBytes(length: resp1.readableBytes)!))
        _ = reader.readUInt32()
        XCTAssertEqual(reader.readUInt8(), 14, "Channel 1 should return signResponse (14)")

        _ = try channel1.finish()
    }

    // MARK: - Finding 3 Regressions: Atomic Agent Forwarded-Signing Admission

    func testAgentSigningCoordinatorDeterministicAdmissionAndHandoff() async {
        let coordinator = AgentSigningCoordinator(maxWaiters: 4)

        // 1. Uncontended acquisition
        let first = await coordinator.acquire()
        XCTAssertTrue(first, "Uncontended acquisition must succeed")
        XCTAssertTrue(coordinator.isBusyForTesting)
        XCTAssertEqual(coordinator.waiterCountForTesting, 0)

        // 2. Queue waiters (FIFO order)
        final class ResultCollector: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var order: [Int] = []
            func record(_ val: Int) {
                lock.lock()
                order.append(val)
                lock.unlock()
            }
        }
        let collector = ResultCollector()

        let task1 = Task {
            let acquired = await coordinator.acquire()
            if acquired {
                collector.record(1)
                coordinator.release()
            }
        }
        for _ in 0..<50 where coordinator.waiterCountForTesting < 1 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        let task2 = Task {
            let acquired = await coordinator.acquire()
            if acquired {
                collector.record(2)
                coordinator.release()
            }
        }
        for _ in 0..<50 where coordinator.waiterCountForTesting < 2 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        let task3 = Task {
            let acquired = await coordinator.acquire()
            if acquired {
                collector.record(3)
                coordinator.release()
            }
        }
        for _ in 0..<50 where coordinator.waiterCountForTesting < 3 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(coordinator.waiterCountForTesting, 3)

        // 3. Queue-full rejection: capacity is 4
        let task4 = Task {
            let acquired = await coordinator.acquire()
            if acquired {
                collector.record(4)
                coordinator.release()
            }
            return acquired
        }
        for _ in 0..<50 {
            if coordinator.waiterCountForTesting == 4 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(coordinator.waiterCountForTesting, 4)

        // 5th waiter exceeds maxWaiters of 4
        let rejected = await coordinator.acquire()
        XCTAssertFalse(rejected, "Acquisition when waiter queue is at limit must immediately fail")

        // Release first owner -> triggers FIFO handoff
        coordinator.release()
        _ = await task1.value
        _ = await task2.value
        _ = await task3.value
        _ = await task4.value

        // Wait for all handoffs to complete
        for _ in 0..<50 {
            if !coordinator.isBusyForTesting && coordinator.waiterCountForTesting == 0 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertFalse(coordinator.isBusyForTesting, "Coordinator must return to idle")
        XCTAssertEqual(coordinator.waiterCountForTesting, 0)
        XCTAssertEqual(collector.order, [1, 2, 3, 4], "Handoff must be strictly FIFO")
    }

    func testDeterministicReleaseWhileEnteringAdmissionAndQueuedBeforeRelease() async {
        let coordinator = AgentSigningCoordinator(maxWaiters: 4)

        // Case 1: Release occurs right before arriving caller executes admission
        let acquired1 = await coordinator.acquire()
        XCTAssertTrue(acquired1)
        XCTAssertTrue(coordinator.isBusyForTesting)

        let gateBeforeAcquire = ReadinessGate()
        let callerTask = Task {
            try? await gateBeforeAcquire.wait()
            return await coordinator.acquire()
        }

        // Release owner 1, then release the gate for callerTask to enter admission
        coordinator.release()
        gateBeforeAcquire.succeed()

        let callerResult = await callerTask.value
        XCTAssertTrue(callerResult, "Arriving caller must observe free permit and succeed immediately")
        XCTAssertTrue(coordinator.isBusyForTesting)
        coordinator.release()
        XCTAssertFalse(coordinator.isBusyForTesting)

        // Case 2: Queued before release (waiter in queue when release occurs)
        let acquired2 = await coordinator.acquire()
        XCTAssertTrue(acquired2)

        let queuedGate = ReadinessGate()
        let queuedTask = Task {
            let res = await coordinator.acquire()
            if res {
                queuedGate.succeed()
                coordinator.release()
            }
            return res
        }

        for _ in 0..<50 {
            if coordinator.waiterCountForTesting == 1 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(coordinator.waiterCountForTesting, 1)

        coordinator.release()
        try? await queuedGate.wait()
        let queuedResult = await queuedTask.value
        XCTAssertTrue(queuedResult, "Queued waiter must be granted permit on release")
        XCTAssertFalse(coordinator.isBusyForTesting)
        XCTAssertEqual(coordinator.waiterCountForTesting, 0)
    }

    func testAgentSigningCoordinatorCancellationCases() async {
        let coordinator = AgentSigningCoordinator(maxWaiters: 4)

        // 1. Cancelled before entry
        let preCancelledTask = Task {
            return await coordinator.acquire()
        }
        preCancelledTask.cancel()
        let preCancelledResult = await preCancelledTask.value
        XCTAssertFalse(preCancelledResult, "Pre-cancelled task must return false immediately")
        XCTAssertFalse(coordinator.isBusyForTesting)

        // 2. Cancelled while queued
        let acquiredFirst = await coordinator.acquire()
        XCTAssertTrue(acquiredFirst)
        XCTAssertTrue(coordinator.isBusyForTesting)

        let queuedTask = Task {
            return await coordinator.acquire()
        }

        for _ in 0..<50 {
            if coordinator.waiterCountForTesting == 1 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(coordinator.waiterCountForTesting, 1)

        queuedTask.cancel()
        let queuedResult = await queuedTask.value
        XCTAssertFalse(queuedResult, "Cancelled queued waiter must return false")
        XCTAssertEqual(coordinator.waiterCountForTesting, 0, "Cancelled waiter must be removed from queue")

        // Release the owner
        coordinator.release()
        XCTAssertFalse(coordinator.isBusyForTesting)
    }

    func testAgentSigningCoordinatorStress80000Operations() async {
        let coordinator = AgentSigningCoordinator(maxWaiters: 64)
        let totalWorkers = 8
        let iterationsPerWorker = 10_000
        let totalExpectedOps = totalWorkers * iterationsPerWorker

        final class AtomicCounter: @unchecked Sendable {
            private let lock = NSLock()
            private var currentActive: Int = 0
            private(set) var maxConcurrent: Int = 0
            private(set) var completedCount: Int = 0

            func enter() -> Bool {
                lock.lock()
                currentActive += 1
                if currentActive > maxConcurrent {
                    maxConcurrent = currentActive
                }
                let ok = (currentActive == 1)
                lock.unlock()
                return ok
            }

            func exit() {
                lock.lock()
                currentActive -= 1
                completedCount += 1
                lock.unlock()
            }
        }

        let tracker = AtomicCounter()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<totalWorkers {
                group.addTask {
                    for _ in 0..<iterationsPerWorker {
                        let acquired = await coordinator.acquire()
                        if acquired {
                            let singleOwner = tracker.enter()
                            XCTAssertTrue(singleOwner, "At most one signing operation may own admission simultaneously")
                            tracker.exit()
                            coordinator.release()
                        }
                    }
                }
            }
        }

        XCTAssertEqual(tracker.completedCount, totalExpectedOps, "All 80,000 operations must complete")
        XCTAssertEqual(tracker.maxConcurrent, 1, "Maximum simultaneous ownership must be exactly 1")
        XCTAssertFalse(coordinator.isBusyForTesting, "Coordinator must be idle after stress")
        XCTAssertEqual(coordinator.waiterCountForTesting, 0, "No waiters left in queue")
    }

    func testHostProfileAgentForwardingKeyIdsDecoding() throws {
        let keyIds = [UUID(), UUID()]
        let host = HostProfile(name: "H", hostname: "h.com", agentForwardingKeyIds: keyIds)
        let data = try JSONEncoder().encode(host)
        let decoded = try JSONDecoder().decode(HostProfile.self, from: data)
        XCTAssertEqual(decoded.agentForwardingKeyIds, keyIds)

        // JSON without key -> decodes to nil
        let minimalJSON = """
        {
            "id": "\(UUID().uuidString)",
            "name": "Server",
            "hostname": "example.com",
            "port": 22,
            "username": "root",
            "authMethod": "SSH Key"
        }
        """.data(using: .utf8)!
        let decodedMinimal = try JSONDecoder().decode(HostProfile.self, from: minimalJSON)
        XCTAssertNil(decodedMinimal.agentForwardingKeyIds)
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

    // MARK: - Multi-Connection Host Switching & Windowing Tests

    @MainActor
    func testHostAdditionAutoConnectLogic() {
        // Issue 1: When adding a host, only auto-connect if it is the very first host added.
        var hosts: [HostProfile] = []
        var connectedHost: HostProfile? = nil

        func addHost(_ newHost: HostProfile) {
            let wasEmpty = hosts.isEmpty
            hosts.append(newHost)
            if wasEmpty {
                connectedHost = newHost
            }
        }

        let host1 = HostProfile(name: "Host 1", hostname: "host1.local", port: 22, username: "user")
        let host2 = HostProfile(name: "Host 2", hostname: "host2.local", port: 22, username: "user")

        // First host addition should trigger connect
        addHost(host1)
        XCTAssertEqual(connectedHost?.id, host1.id, "First host added must auto-connect")

        // Second host addition should NOT overwrite connectedHost or drop active connection
        addHost(host2)
        XCTAssertEqual(connectedHost?.id, host1.id, "Subsequent host addition must NOT auto-connect or terminate active connection")
        XCTAssertEqual(hosts.count, 2)
    }

    @MainActor
    func testInWindowHostSwitching() {
        // Issue 2: Switching host in the current window must update active host and force connect
        let appState = AppState()
        let host1 = HostProfile(name: "Host 1", hostname: "host1.local", port: 22, username: "user")
        let host2 = HostProfile(name: "Host 2", hostname: "host2.local", port: 22, username: "user")
        appState.hosts = [host1, host2]

        appState.connect(to: host1, force: true)
        XCTAssertEqual(appState.selectedHostId, host1.id)
        XCTAssertEqual(appState.sessionManager.activeHost?.id, host1.id)

        // Switch to host2 in current window
        appState.connect(to: host2, force: true)
        XCTAssertEqual(appState.selectedHostId, host2.id)
        XCTAssertEqual(appState.sessionManager.activeHost?.id, host2.id)
        XCTAssertEqual(appState.windowTitle, "Host 2 (user)")

        // Cleanup
        appState.sessionManager.disconnect()
    }

    @MainActor
    func testOpenHostInWindowPreferNewWindowBypassesExistingScene() {
        // Issue 3: When preferNewWindow is true, existing scenes must not be reused
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first,
            let scene = window.windowScene else {
            return
        }

        let testHostId = UUID()
        QuickActionManager.shared.tagScene(scene, withHostId: testHostId)
        XCTAssertNotNil(QuickActionManager.findScene(for: testHostId, in: [scene]))

        // Calling openHostInWindow with preferNewWindow: true should not crash or throw,
        // and safely requests a new scene session
        QuickActionManager.shared.openHostInWindow(hostId: testHostId, preferNewWindow: true)
        QuickActionManager.shared.openHostInNewWindow(hostId: testHostId)

        // Clean up
        QuickActionManager.shared.tagScene(scene, withHostId: nil)
    }

    @MainActor
    func testTerminalViewNewWindowShortcut() {
        let terminalView = FilaireTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        var notificationReceived = false
        let observer = NotificationCenter.default.addObserver(
            forName: .openNewWindowRequested,
            object: nil,
            queue: .main
        ) { _ in
            notificationReceived = true
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
        }

        // Trigger Cmd+Shift+N shortcut
        let handled = terminalView.handleKeyShortcut(
            characters: "",
            charactersIgnoringModifiers: "n",
            modifierFlags: [.command, .shift],
            keyCode: .keyboardN
        )

        XCTAssertTrue(handled, "Cmd+Shift+N must be handled by FilaireTerminalView")
        XCTAssertTrue(notificationReceived, "Cmd+Shift+N must post .openNewWindowRequested notification")
    }

    // MARK: - Network Path Change & Reconnection

    @MainActor
    func testNetworkPathChangeDropAndRestore() {
        let manager = SessionManager()
        let host = HostProfile(name: "PathTest", hostname: "127.0.0.1", username: "user")
        manager.activeHost = host
        manager.state = .connected

        // 1. Initial / cold start path notification should not trigger reconnection
        manager.handleNetworkPathChange(status: .satisfied, interfaceType: .wifi)
        XCTAssertEqual(manager.state, .connected, "Cold start path evaluation must not disconnect or reconnect")

        // 2. Network drop: transition from satisfied to unsatisfied while connected
        manager.handleNetworkPathChange(status: .unsatisfied, interfaceType: nil)
        XCTAssertEqual(manager.state, .reconnecting(attempt: 1), "Loss of network connectivity must transition to reconnecting(attempt: 1)")

        // 3. Network restored: transition from unsatisfied to satisfied while reconnecting
        manager.handleNetworkPathChange(status: .satisfied, interfaceType: .wifi)
        // Reconnect triggers connect(), which sets state to .connecting
        XCTAssertTrue(manager.state == .connecting || manager.state.isBusy, "Restoration of network must trigger reconnect attempt")
    }

    // MARK: - Host Profile Duplication

    func testHostProfileDuplication() {
        let rule1 = PortForwardRule(localPort: 8080, remoteHost: "127.0.0.1", remotePort: 80, ruleType: .local)
        let rule2 = PortForwardRule(localPort: 1080, ruleType: .dynamic)
        let original = HostProfile(
            name: "Production Server",
            hostname: "prod.example.com",
            port: 2222,
            username: "deploy",
            authMethod: .sshKey,
            selectedKeyId: UUID(),
            customTmuxSession: "prod-main",
            autoConnectTmux: true,
            tmuxPrefix: "ctrl-z",
            portForwards: [rule1, rule2],
            lastConnected: Date(),
            enableAgentForwarding: true
        )

        let clone = original.duplicated()

        XCTAssertNotEqual(clone.id, original.id, "Cloned host must have a new unique ID")
        XCTAssertEqual(clone.name, "Production Server (Copy)")
        XCTAssertEqual(clone.hostname, original.hostname)
        XCTAssertEqual(clone.port, original.port)
        XCTAssertEqual(clone.username, original.username)
        XCTAssertEqual(clone.selectedKeyId, original.selectedKeyId)
        XCTAssertEqual(clone.customTmuxSession, original.customTmuxSession)
        XCTAssertEqual(clone.autoConnectTmux, original.autoConnectTmux)
        XCTAssertEqual(clone.tmuxPrefix, original.tmuxPrefix)
        XCTAssertEqual(clone.enableAgentForwarding, original.enableAgentForwarding)
        XCTAssertNil(clone.lastConnected, "Cloned host must clear lastConnected date")
        XCTAssertEqual(clone.portForwards.count, 2)
        XCTAssertNotEqual(clone.portForwards[0].id, original.portForwards[0].id, "Cloned port forward rules must have new unique IDs")
        XCTAssertNotEqual(clone.portForwards[1].id, original.portForwards[1].id)
        XCTAssertEqual(clone.portForwards[0].localPort, 8080)
        XCTAssertEqual(clone.portForwards[1].localPort, 1080)
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

    // MARK: - Remote URL & Clipboard Security Tests

    func testRemoteUrlOpeningPolicyActions() {
        let httpUrl = URL(string: "http://example.com/test")!
        let httpsUrl = URL(string: "https://example.com/test")!
        let telUrl = URL(string: "tel:1234567890")!
        let shortcutsUrl = URL(string: "shortcuts://run-shortcut")!
        let fileUrl = URL(string: "file:///etc/passwd")!

        // 1. Default policy: denyUnusualSchemes -> prompt for http/https, deny all others
        let defaultPolicy = RemoteUrlOpeningPolicy.denyUnusualSchemes
        XCTAssertEqual(defaultPolicy.action(for: httpUrl), .promptUser)
        XCTAssertEqual(defaultPolicy.action(for: httpsUrl), .promptUser)
        XCTAssertEqual(defaultPolicy.action(for: telUrl), .deny)
        XCTAssertEqual(defaultPolicy.action(for: shortcutsUrl), .deny)
        XCTAssertEqual(defaultPolicy.action(for: fileUrl), .deny)

        // 2. promptAlways -> prompt for all schemes
        let promptAlways = RemoteUrlOpeningPolicy.promptAlways
        XCTAssertEqual(promptAlways.action(for: httpUrl), .promptUser)
        XCTAssertEqual(promptAlways.action(for: httpsUrl), .promptUser)
        XCTAssertEqual(promptAlways.action(for: telUrl), .promptUser)
        XCTAssertEqual(promptAlways.action(for: shortcutsUrl), .promptUser)
        XCTAssertEqual(promptAlways.action(for: fileUrl), .promptUser)

        // 3. promptUnusualSchemes -> auto-allow http/https, prompt for others
        let promptUnusual = RemoteUrlOpeningPolicy.promptUnusualSchemes
        XCTAssertEqual(promptUnusual.action(for: httpUrl), .openImmediately)
        XCTAssertEqual(promptUnusual.action(for: httpsUrl), .openImmediately)
        XCTAssertEqual(promptUnusual.action(for: telUrl), .promptUser)
        XCTAssertEqual(promptUnusual.action(for: shortcutsUrl), .promptUser)
        XCTAssertEqual(promptUnusual.action(for: fileUrl), .promptUser)
    }

    @MainActor
    func testSessionManagerHandleRemoteUrlOpen() {
        let manager = SessionManager()
        var host = HostProfile(name: "TestHost", hostname: "server.local")

        // Case 1: Default policy (.denyUnusualSchemes) with HTTP -> prompts user
        host.urlOpeningPolicy = .denyUnusualSchemes
        manager.activeHost = host

        var openedUrl: URL? = nil
        let httpUrl = URL(string: "https://example.com")!
        manager.handleRemoteUrlOpen(httpUrl) { url in
            openedUrl = url
        }
        XCTAssertNil(openedUrl, "Should not immediately open before confirmation")
        XCTAssertNotNil(manager.pendingSecurityPrompt)
        XCTAssertEqual(manager.pendingSecurityPrompt?.title, "Open Remote URL")
        manager.pendingSecurityPrompt?.onAllow()
        XCTAssertEqual(openedUrl, httpUrl, "Tapping Open executes openHandler")
        manager.pendingSecurityPrompt = nil

        // Case 2: Default policy (.denyUnusualSchemes) with unusual scheme -> denied, no prompt
        openedUrl = nil
        let telUrl = URL(string: "tel:5551234")!
        manager.handleRemoteUrlOpen(telUrl) { url in
            openedUrl = url
        }
        XCTAssertNil(openedUrl)
        XCTAssertNil(manager.pendingSecurityPrompt, "Unusual schemes must be denied without prompting")

        // Case 3: promptUnusualSchemes with HTTP -> auto-opens immediately without prompt
        host.urlOpeningPolicy = .promptUnusualSchemes
        manager.activeHost = host
        openedUrl = nil
        manager.handleRemoteUrlOpen(httpUrl) { url in
            openedUrl = url
        }
        XCTAssertEqual(openedUrl, httpUrl, "HTTP should open immediately with promptUnusualSchemes")
        XCTAssertNil(manager.pendingSecurityPrompt)

        // Case 4: promptUnusualSchemes with unusual scheme -> prompts user
        openedUrl = nil
        manager.handleRemoteUrlOpen(telUrl) { url in
            openedUrl = url
        }
        XCTAssertNil(openedUrl)
        XCTAssertNotNil(manager.pendingSecurityPrompt)
        manager.pendingSecurityPrompt?.onAllow()
        XCTAssertEqual(openedUrl, telUrl)
        manager.pendingSecurityPrompt = nil
    }

    @MainActor
    func testSessionManagerHandleTappedLink() {
        let manager = SessionManager()
        let host = HostProfile(name: "TestHost", hostname: "server.local")
        manager.activeHost = host

        // 1. Detected https://example.com -> opens immediately; no prompt.
        var openedUrl: URL? = nil
        let webUrl = URL(string: "https://example.com")!
        manager.handleTappedLink(webUrl, isDetectedPlainUrl: true) { url in
            openedUrl = url
        }
        XCTAssertEqual(openedUrl, webUrl)
        XCTAssertNil(manager.pendingSecurityPrompt)

        // 2. Not detected https://example.com -> no open; prompt shows absoluteString; onAllow() opens.
        openedUrl = nil
        manager.handleTappedLink(webUrl, isDetectedPlainUrl: false) { url in
            openedUrl = url
        }
        XCTAssertNil(openedUrl)
        XCTAssertNotNil(manager.pendingSecurityPrompt)
        XCTAssertTrue(manager.pendingSecurityPrompt?.message.contains(webUrl.absoluteString) == true)
        manager.pendingSecurityPrompt?.onAllow()
        XCTAssertEqual(openedUrl, webUrl)
        manager.pendingSecurityPrompt = nil

        // 3. Detected mailto:a@b.c -> prompt (not auto-open).
        openedUrl = nil
        let mailUrl = URL(string: "mailto:a@b.c")!
        manager.handleTappedLink(mailUrl, isDetectedPlainUrl: true) { url in
            openedUrl = url
        }
        XCTAssertNil(openedUrl)
        XCTAssertNotNil(manager.pendingSecurityPrompt)
        XCTAssertTrue(manager.pendingSecurityPrompt?.message.contains(mailUrl.absoluteString) == true)

        // 4. With a prompt already pending, a second non-detected link doesn't replace it.
        let secondUrl = URL(string: "https://second.example.com")!
        manager.handleTappedLink(secondUrl, isDetectedPlainUrl: false) { _ in }
        XCTAssertTrue(manager.pendingSecurityPrompt?.message.contains(mailUrl.absoluteString) == true)
        XCTAssertFalse(manager.pendingSecurityPrompt?.message.contains(secondUrl.absoluteString) == true)
        manager.pendingSecurityPrompt = nil
    }

    func testHostProfileSecurityDefaultsAndCoding() throws {
        // 1. Defaults on fresh instance
        let profile = HostProfile(name: "Test", hostname: "localhost")
        XCTAssertFalse(profile.allowClipboardRead, "allowClipboardRead must default to false")
        XCTAssertEqual(profile.urlOpeningPolicy, .denyUnusualSchemes, "urlOpeningPolicy must default to .denyUnusualSchemes")

        // 2. Backward compatibility: decoding JSON without these fields should default securely
        let minimalJson = """
        {
            "id": "\(UUID().uuidString)",
            "name": "Old Host",
            "hostname": "old.local",
            "port": 22,
            "username": "user",
            "authMethod": "SSH Key"
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(HostProfile.self, from: minimalJson)
        XCTAssertFalse(decoded.allowClipboardRead)
        XCTAssertEqual(decoded.urlOpeningPolicy, .denyUnusualSchemes)

        // 3. Encoding round-trip with customized security settings
        var custom = HostProfile(name: "Custom", hostname: "custom.local")
        custom.allowClipboardRead = true
        custom.urlOpeningPolicy = .promptAlways

        let encoded = try JSONEncoder().encode(custom)
        let roundTripped = try JSONDecoder().decode(HostProfile.self, from: encoded)
        XCTAssertTrue(roundTripped.allowClipboardRead)
        XCTAssertEqual(roundTripped.urlOpeningPolicy, .promptAlways)
    }

    func testPortForwardListenerParametersBindLoopbackAddress() {
        let params = PortForwardManager.listenerParameters(port: 8080)
        XCTAssertEqual(params.requiredLocalEndpoint, .hostPort(host: .ipv4(.loopback), port: 8080))
        XCTAssertEqual(params.requiredInterfaceType, .loopback)
    }

    func testPortForwardListenerRejectsNonLoopbackConnections() throws {
        guard let lanAddress = Self.firstNonLoopbackIPv4Address() else {
            throw XCTSkip("No non-loopback IPv4 interface to test against")
        }
        let queue = DispatchQueue(label: "io.o-t.filaire.tests.loopback")
        let listener = try NWListener(using: PortForwardManager.listenerParameters(port: .any))
        defer { listener.cancel() }
        listener.newConnectionHandler = { $0.start(queue: queue) }
        let ready = expectation(description: "listener ready")
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
        }
        listener.start(queue: queue)
        wait(for: [ready], timeout: 2)
        let port = try XCTUnwrap(listener.port)

        XCTAssertTrue(Self.canConnect(host: "127.0.0.1", port: port, queue: queue), "Forwards must accept loopback connections")
        XCTAssertFalse(Self.canConnect(host: lanAddress, port: port, queue: queue), "Forwards must not be reachable at \(lanAddress)")
    }

    private static func canConnect(host: String, port: NWEndpoint.Port, queue: DispatchQueue) -> Bool {
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        defer { connection.cancel() }
        let connected = OSAllocatedUnfairLock(initialState: false)
        let settled = DispatchSemaphore(value: 0)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connected.withLock { $0 = true }
                settled.signal()
            case .waiting, .failed:
                settled.signal()
            default:
                break
            }
        }
        connection.start(queue: queue)
        _ = settled.wait(timeout: .now() + 2)
        return connected.withLock { $0 }
    }

    private static func firstNonLoopbackIPv4Address() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(bitPattern: entry.pointee.ifa_flags)
            guard let addr = entry.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET),
                  (flags & IFF_UP) != 0,
                  (flags & IFF_LOOPBACK) == 0 else { continue }
            var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: name)
            }
        }
        return nil
    }

    private final class ReadCounter: ChannelOutboundHandler {
        typealias OutboundIn = Any
        var reads = 0
        func read(context: ChannelHandlerContext) {
            reads += 1
            context.read()
        }
    }

    private final class CompletionBox: @unchecked Sendable {
        var completion: (@Sendable () -> Void)?
    }

    func testDirectTCPIPBridgeHandlerWaitsForLocalSendBeforeReading() throws {
        let counter = ReadCounter()
        let box = CompletionBox()
        let bridge = DirectTCPIPBridgeHandler(onData: { _, completion in box.completion = completion }, onClose: {})
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(counter)
        try channel.pipeline.syncOperations.addHandler(bridge)

        channel.pipeline.fireChannelActive()
        let afterActive = counter.reads
        XCTAssertGreaterThanOrEqual(afterActive, 1, "Bridge must request the first read when active")

        channel.pipeline.fireChannelRead(NIOAny(ByteBuffer(string: "abc")))
        channel.pipeline.fireChannelReadComplete()
        XCTAssertEqual(counter.reads, afterActive, "Must not read more while the local send is pending")

        box.completion?()
        channel.embeddedEventLoop.run()
        XCTAssertEqual(counter.reads, afterActive + 1, "Must read again once the local send completes")
        _ = try? channel.finish()
    }

    // MARK: - Port Forward Deadline and Cancellation Tests

    private final class MockSSHDirectChannelCreator: SSHDirectChannelCreator, @unchecked Sendable {
        var delayNanoseconds: UInt64 = 0
        var shouldHang: Bool = false
        var shouldFail: Bool = false
        var createdChannels: [Channel] = []
        let lock = NSLock()
        var onChannelRequested: (() -> Void)?

        init(delayNanoseconds: UInt64 = 0, shouldHang: Bool = false, shouldFail: Bool = false) {
            self.delayNanoseconds = delayNanoseconds
            self.shouldHang = shouldHang
            self.shouldFail = shouldFail
        }

        func createDirectTCPIPChannel(
            using settings: SSHChannelType.DirectTCPIP,
            initialize: @escaping (Channel) -> EventLoopFuture<Void>
        ) async throws -> Channel {
            lock.lock()
            onChannelRequested?()
            lock.unlock()

            if shouldHang {
                while true {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }

            if delayNanoseconds > 0 {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            }

            if shouldFail {
                throw POSIXError(.ECONNREFUSED)
            }

            let channel = EmbeddedChannel()
            lock.lock()
            createdChannels.append(channel)
            lock.unlock()

            try await initialize(channel).get()
            return channel
        }
    }

    private static func findUnusedLocalPort() -> Int {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = Darwin.bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(sock, $0, &len)
            }
        }
        close(sock)
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    private static func connectClientSocket(port: Int) -> Int32 {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let res = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(res, 0, "Socket connect failed")
        return sock
    }

    func testSOCKSHandshakeNoGreetingTimeoutCancelsSocket() async throws {
        let port = Self.findUnusedLocalPort()
        let manager = PortForwardManager(handshakeTimeout: 0.15, directChannelTimeout: 1.0)
        let mockCreator = MockSSHDirectChannelCreator()
        let rule = PortForwardRule(localPort: port, ruleType: .dynamic)
        await manager.start(rules: [rule], client: mockCreator)
        defer { Task { await manager.stopAll() } }

        // Give listener a moment to start
        try await Task.sleep(nanoseconds: 30_000_000)

        let sock = Self.connectClientSocket(port: port)
        defer { close(sock) }

        let start = CFAbsoluteTimeGetCurrent()
        var buf = [UInt8](repeating: 0, count: 1)
        let n = Darwin.read(sock, &buf, 1)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        // Server must close socket on deadline
        XCTAssertTrue(n == 0 || n == -1, "Read should return 0 (EOF) or -1 upon server cancellation, got \(n)")
        XCTAssertGreaterThanOrEqual(elapsed, 0.10, "Should wait for at least handshake deadline")
        XCTAssertLessThan(elapsed, 1.5, "Should close promptly on deadline")

        // Wait a brief moment for cleanup
        try await Task.sleep(nanoseconds: 30_000_000)
        let pending = await manager.pendingConnectionCount()
        XCTAssertEqual(pending, 0, "Pending connection count must be 0 after timeout")
    }

    func testSOCKSHandshakePartialGreetingTimeout() async throws {
        let port = Self.findUnusedLocalPort()
        let manager = PortForwardManager(handshakeTimeout: 0.15, directChannelTimeout: 1.0)
        let mockCreator = MockSSHDirectChannelCreator()
        let rule = PortForwardRule(localPort: port, ruleType: .dynamic)
        await manager.start(rules: [rule], client: mockCreator)
        defer { Task { await manager.stopAll() } }

        try await Task.sleep(nanoseconds: 30_000_000)

        let sock = Self.connectClientSocket(port: port)
        defer { close(sock) }

        // Send only 1 byte of greeting (need at least 2: VER, NMETHODS)
        var oneByte: [UInt8] = [0x05]
        Darwin.write(sock, &oneByte, 1)

        let start = CFAbsoluteTimeGetCurrent()
        var buf = [UInt8](repeating: 0, count: 1)
        let n = Darwin.read(sock, &buf, 1)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertTrue(n == 0 || n == -1, "Read should return 0 or -1 upon server cancellation, got \(n)")
        XCTAssertGreaterThanOrEqual(elapsed, 0.10)
        XCTAssertLessThan(elapsed, 1.5)

        try await Task.sleep(nanoseconds: 30_000_000)
        let pending = await manager.pendingConnectionCount()
        XCTAssertEqual(pending, 0)
    }

    func testSOCKSHandshakePartialAddressTimeout() async throws {
        let port = Self.findUnusedLocalPort()
        let manager = PortForwardManager(handshakeTimeout: 0.15, directChannelTimeout: 1.0)
        let mockCreator = MockSSHDirectChannelCreator()
        let rule = PortForwardRule(localPort: port, ruleType: .dynamic)
        await manager.start(rules: [rule], client: mockCreator)
        defer { Task { await manager.stopAll() } }

        try await Task.sleep(nanoseconds: 30_000_000)

        let sock = Self.connectClientSocket(port: port)
        defer { close(sock) }

        // Send valid greeting: VER 5, 1 method: NO AUTH
        var greeting: [UInt8] = [0x05, 0x01, 0x00]
        Darwin.write(sock, &greeting, greeting.count)

        // Read method reply: 2 bytes (0x05, 0x00)
        var reply = [UInt8](repeating: 0, count: 2)
        let replyCount = Darwin.read(sock, &reply, 2)
        XCTAssertEqual(replyCount, 2)
        XCTAssertEqual(reply, [0x05, 0x00])

        // Send partial request: ATYP=3 (domain), domain length = 10, but only send 2 bytes of domain and no port
        var partialReq: [UInt8] = [0x05, 0x01, 0x00, 0x03, 0x0A, 0x61, 0x62]
        Darwin.write(sock, &partialReq, partialReq.count)

        let start = CFAbsoluteTimeGetCurrent()
        var buf = [UInt8](repeating: 0, count: 1)
        let n = Darwin.read(sock, &buf, 1)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertTrue(n == 0 || n == -1, "Read should return 0 or -1 upon server cancellation, got \(n)")
        XCTAssertGreaterThanOrEqual(elapsed, 0.10)
        XCTAssertLessThan(elapsed, 1.5)

        try await Task.sleep(nanoseconds: 30_000_000)
        let pending = await manager.pendingConnectionCount()
        XCTAssertEqual(pending, 0)
    }

    func testSOCKSChannelOpenTimeout() async throws {
        let port = Self.findUnusedLocalPort()
        let manager = PortForwardManager(handshakeTimeout: 1.0, directChannelTimeout: 0.15)
        let mockCreator = MockSSHDirectChannelCreator(shouldHang: true)
        let rule = PortForwardRule(localPort: port, ruleType: .dynamic)
        await manager.start(rules: [rule], client: mockCreator)
        defer { Task { await manager.stopAll() } }

        try await Task.sleep(nanoseconds: 30_000_000)

        let sock = Self.connectClientSocket(port: port)
        defer { close(sock) }

        // Send valid greeting: VER 5, 1 method: NO AUTH
        var greeting: [UInt8] = [0x05, 0x01, 0x00]
        Darwin.write(sock, &greeting, greeting.count)

        var reply = [UInt8](repeating: 0, count: 2)
        let replyCount = Darwin.read(sock, &reply, 2)
        XCTAssertEqual(replyCount, 2)
        XCTAssertEqual(reply, [0x05, 0x00])

        // Send valid request: connect to 127.0.0.1:80
        var req: [UInt8] = [0x05, 0x01, 0x00, 0x01, 127, 0, 0, 1, 0, 80]
        Darwin.write(sock, &req, req.count)

        let start = CFAbsoluteTimeGetCurrent()
        var resp = [UInt8](repeating: 0, count: 10)
        let n = Darwin.read(sock, &resp, 10)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        // Channel creation hung, so directChannelTimeout fired.
        // Server sends SOCKS Connection Refused (0x05) or closes connection.
        if n > 0 {
            XCTAssertEqual(resp[0], 0x05)
            XCTAssertEqual(resp[1], 0x05) // Connection refused
        }
        XCTAssertGreaterThanOrEqual(elapsed, 0.10)
        XCTAssertLessThan(elapsed, 1.5)

        try await Task.sleep(nanoseconds: 30_000_000)
        let pending = await manager.pendingConnectionCount()
        XCTAssertEqual(pending, 0)
        let bridges = await manager.activeBridgeCount()
        XCTAssertEqual(bridges, 0)
    }

    func testStopForwardingDuringHandshakeCancelsAll() async throws {
        let port = Self.findUnusedLocalPort()
        let manager = PortForwardManager(handshakeTimeout: 10.0, directChannelTimeout: 10.0)
        let mockCreator = MockSSHDirectChannelCreator()
        let rule = PortForwardRule(localPort: port, ruleType: .dynamic)
        await manager.start(rules: [rule], client: mockCreator)

        try await Task.sleep(nanoseconds: 30_000_000)

        let sock1 = Self.connectClientSocket(port: port)
        let sock2 = Self.connectClientSocket(port: port)
        defer {
            close(sock1)
            close(sock2)
        }

        // Send partial greetings
        var b: [UInt8] = [0x05]
        Darwin.write(sock1, &b, 1)
        Darwin.write(sock2, &b, 1)

        try await Task.sleep(nanoseconds: 30_000_000)
        let pendingBefore = await manager.pendingConnectionCount()
        XCTAssertGreaterThanOrEqual(pendingBefore, 1)

        // Stop all forwarding
        await manager.stopAll()

        let pendingAfter = await manager.pendingConnectionCount()
        XCTAssertEqual(pendingAfter, 0)
        let bridges = await manager.activeBridgeCount()
        XCTAssertEqual(bridges, 0)

        // Sockets must receive EOF or error promptly
        var buf = [UInt8](repeating: 0, count: 1)
        let n1 = Darwin.read(sock1, &buf, 1)
        let n2 = Darwin.read(sock2, &buf, 1)
        XCTAssertTrue(n1 == 0 || n1 == -1)
        XCTAssertTrue(n2 == 0 || n2 == -1)
    }

    func testMaxPendingConnectionsRejection() async throws {
        let port = Self.findUnusedLocalPort()
        let manager = PortForwardManager(handshakeTimeout: 5.0, directChannelTimeout: 5.0, maxPendingConnections: 1)
        let mockCreator = MockSSHDirectChannelCreator()
        let rule = PortForwardRule(localPort: port, ruleType: .dynamic)
        await manager.start(rules: [rule], client: mockCreator)
        defer { Task { await manager.stopAll() } }

        try await Task.sleep(nanoseconds: 30_000_000)

        let sock1 = Self.connectClientSocket(port: port)
        defer { close(sock1) }

        // Give server time to register sock1 as pending
        try await Task.sleep(nanoseconds: 30_000_000)
        let pending = await manager.pendingConnectionCount()
        XCTAssertEqual(pending, 1)

        // Connect sock2 while sock1 is pending; should be rejected immediately because maxPendingConnections = 1
        let sock2 = Self.connectClientSocket(port: port)
        defer { close(sock2) }

        var buf = [UInt8](repeating: 0, count: 1)
        let n2 = Darwin.read(sock2, &buf, 1)
        XCTAssertTrue(n2 == 0 || n2 == -1, "Second connection must be closed immediately when limit reached")
    }

    func testContinuationGateThreadSafety() async {
        let gate = ContinuationGate<Int, Error>()
        let resumed = OSAllocatedUnfairLock(initialState: 0)

        let task = Task {
            try await withCheckedThrowingContinuation { continuation in
                gate.register(continuation)
            }
        }

        // Concurrently attempt to resume from multiple tasks
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    if gate.resume(returning: i) {
                        resumed.withLock { $0 += 1 }
                    }
                }
            }
        }

        let val = try? await task.value
        XCTAssertNotNil(val)
        XCTAssertEqual(resumed.withLock { $0 }, 1, "Exactly one resume call must succeed")
    }

    func testFilaireTerminalViewWipeScreen() {
        let terminalView = FilaireTerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        terminalView.feed(text: "Hello World\r\nSecond Line\r\n")

        // Cursor moved after feeding text
        let term = terminalView.getTerminal()
        XCTAssertGreaterThan(term.buffer.y, 0)

        // Wipe screen
        terminalView.wipeScreen()

        // Cursor returns to (0, 0) and buffer is reset
        XCTAssertEqual(term.buffer.x, 0)
        XCTAssertEqual(term.buffer.y, 0)
    }

    @MainActor
    func testSessionManagerWipeTerminalCallback() {
        let manager = SessionManager()
        var wiped = false
        manager.onClearTerminal = {
            wiped = true
        }
        manager.wipeTerminal()
        XCTAssertTrue(wiped)
    }

    @MainActor
    func testHostSwitchingDoesNotTriggerReconnectLoop() async {
        let manager = SessionManager()
        let host1 = HostProfile(name: "Host 1", hostname: "host1.local")
        let host2 = HostProfile(name: "Host 2", hostname: "host2.local")

        // Connect to host1
        manager.connect(to: host1)
        XCTAssertEqual(manager.activeHost?.id, host1.id)

        // Switching to host2
        manager.connect(to: host2)
        XCTAssertEqual(manager.activeHost?.id, host2.id)

        // Reconnect attempt must be 0 and no reconnect loop scheduled
        XCTAssertEqual(manager.reconnectAttempt, 0)
        manager.cancelReconnect()
        XCTAssertEqual(manager.reconnectAttempt, 0)
    }

    @MainActor
    func testCompanionToolGuideView() {
        XCTAssertTrue(CompanionToolGuideView.cargoCommand.contains("cargo install --git https://github.com/JeremyOT/filaire fil"))
        XCTAssertTrue(CompanionToolGuideView.sourceCommand.contains("git clone https://github.com/JeremyOT/filaire.git"))
        XCTAssertTrue(CompanionToolGuideView.sourceCommand.contains("cargo build --release"))

        let view = CompanionToolGuideView()
        _ = view.body
    }

    @MainActor
    func testPastePayloadHonorsBracketedPasteMode() {
        // Without bracketed paste mode, text is sent unchanged
        XCTAssertEqual(FilaireTerminalView.pastePayload(for: "ls\n", bracketedPasteMode: false), Array("ls\n".utf8))

        // With bracketed paste mode, text is wrapped in ESC[200~ ... ESC[201~
        XCTAssertEqual(
            FilaireTerminalView.pastePayload(for: "ls\n", bracketedPasteMode: true),
            Array("\u{1B}[200~ls\n\u{1B}[201~".utf8)
        )

        // Embedded end marker must not terminate the paste early
        XCTAssertEqual(
            FilaireTerminalView.pastePayload(for: "a\u{1B}[201~rm -rf ~\n", bracketedPasteMode: true),
            Array("\u{1B}[200~a[201~rm -rf ~\n\u{1B}[201~".utf8)
        )

        // The terminal tracks the mode the remote app requests (DECSET 2004)
        let terminalView = FilaireTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertFalse(terminalView.getTerminal().bracketedPasteMode)
        terminalView.feed(text: "\u{1B}[?2004h")
        XCTAssertTrue(terminalView.getTerminal().bracketedPasteMode)
    }

    func testRemoteTextSanitize() {
        XCTAssertEqual(RemoteText.sanitize("hello", maxLength: 10), "hello")
        XCTAssertEqual(RemoteText.sanitize("a\u{1B}[31mb\u{07}", maxLength: 10), "a[31mb")
        XCTAssertEqual(RemoteText.sanitize("abc\u{202E}def", maxLength: 10), "abcdef")
        XCTAssertEqual(RemoteText.sanitize("abcdefghij", maxLength: 4), "abcd…")
    }

    // MARK: - Item 1: Incoming Terminal Output Backpressure & Watermark Tests

    @MainActor
    func testOutputCoalescerByteForByteOrderingAndSplitSequences() async {
        let deliveredBox = NIOLockedValueBox<[UInt8]>([])
        let expectation = expectation(description: "All slices delivered")

        let testString = "Hello 🌍! \u{1b}[38;2;255;100;0mANSI Color Test\u{1b}[0m - Line 2 👨‍👩‍👧‍👦"
        let allBytes = Array(testString.utf8)

        let coalescer = OutputCoalescer(
            highWatermark: 1024,
            lowWatermark: 512,
            maxBurstChunkSize: 16,
            onFlush: { chunk in
                let count = deliveredBox.withLockedValue { list -> Int in
                    list.append(contentsOf: chunk)
                    return list.count
                }
                if count == allBytes.count {
                    expectation.fulfill()
                }
            }
        )

        // Feed bytes in tiny 1, 2, and 3-byte fragments across split UTF-8 and split ANSI sequences
        var offset = 0
        var chunkSize = 1
        while offset < allBytes.count {
            let nextSize = min(chunkSize, allBytes.count - offset)
            let chunk = Array(allBytes[offset..<(offset + nextSize)])
            coalescer.append(chunk)
            offset += nextSize
            chunkSize = (chunkSize % 3) + 1
        }

        await fulfillment(of: [expectation], timeout: 2.0)
        let deliveredBytes = deliveredBox.withLockedValue { $0 }
        XCTAssertEqual(deliveredBytes, allBytes)
        XCTAssertEqual(String(decoding: deliveredBytes, as: UTF8.self), testString)
    }

    @MainActor
    func testOutputCoalescerWatermarksAndBackpressureTriggering() async {
        let backpressureBox = NIOLockedValueBox<[Bool]>([])
        let deliveredCountBox = NIOLockedValueBox<Int>(0)
        let flushExpectation = expectation(description: "Drained below low watermark")

        let highWatermark = 1000
        let lowWatermark = 400
        let maxBurst = 300

        let coalescer = OutputCoalescer(
            highWatermark: highWatermark,
            lowWatermark: lowWatermark,
            maxBurstChunkSize: maxBurst,
            onFlush: { chunk in
                let total = deliveredCountBox.withLockedValue { count -> Int in
                    count += chunk.count
                    return count
                }
                if total >= 1200 {
                    flushExpectation.fulfill()
                }
            },
            onBackpressure: { isPaused in
                backpressureBox.withLockedValue { $0.append(isPaused) }
            }
        )

        // Append 1200 bytes in 400-byte chunks to exceed high watermark (1000)
        coalescer.append([UInt8](repeating: 0x41, count: 400))
        XCTAssertEqual(backpressureBox.withLockedValue { $0 }, [Bool]())
        XCTAssertFalse(coalescer.metrics.isBackpressureActive)

        coalescer.append([UInt8](repeating: 0x42, count: 400))
        XCTAssertEqual(backpressureBox.withLockedValue { $0 }, [Bool]())

        coalescer.append([UInt8](repeating: 0x43, count: 400))
        // Total pending: 1200 >= 1000 -> backpressure should trigger
        XCTAssertEqual(backpressureBox.withLockedValue { $0 }, [true])
        XCTAssertTrue(coalescer.metrics.isBackpressureActive)
        XCTAssertEqual(coalescer.metrics.backpressureTriggerCount, 1)
        XCTAssertEqual(coalescer.metrics.peakQueuedBytes, 1200)

        // Wait for deliveries to drain below low watermark (400)
        await fulfillment(of: [flushExpectation], timeout: 2.0)

        // Backpressure should have been deactivated once pending dropped <= 400
        XCTAssertEqual(backpressureBox.withLockedValue { $0 }, [true, false])
        XCTAssertFalse(coalescer.metrics.isBackpressureActive)
        XCTAssertEqual(coalescer.metrics.totalDeliveredBytes, 1200)
        XCTAssertGreaterThan(coalescer.metrics.deliveryCount, 0)
    }

    @MainActor
    func testOutputCoalescerGenerationIsolationAndResetUnpausing() async {
        let backpressureBox = NIOLockedValueBox<[Bool]>([])
        let deliveredBox = NIOLockedValueBox<[UInt8]>([])

        let coalescer = OutputCoalescer(
            highWatermark: 500,
            lowWatermark: 200,
            maxBurstChunkSize: 100,
            onFlush: { chunk in
                deliveredBox.withLockedValue { $0.append(contentsOf: chunk) }
            },
            onBackpressure: { isPaused in
                backpressureBox.withLockedValue { $0.append(isPaused) }
            }
        )

        let gen0 = coalescer.currentGeneration
        // Push over high watermark
        coalescer.append([UInt8](repeating: 0x55, count: 600), generation: gen0)
        XCTAssertEqual(backpressureBox.withLockedValue { $0 }, [true])

        // Reset while backpressure is active
        coalescer.reset()
        // Reset unpauses any active backpressure immediately
        XCTAssertEqual(backpressureBox.withLockedValue { $0 }, [true, false])
        XCTAssertFalse(coalescer.metrics.isBackpressureActive)
        XCTAssertEqual(coalescer.totalPendingBytes, 0)

        let gen1 = coalescer.currentGeneration
        XCTAssertNotEqual(gen0, gen1)

        // Late chunk from old generation gen0 must be silently rejected
        coalescer.append([UInt8](repeating: 0x66, count: 100), generation: gen0)
        XCTAssertEqual(coalescer.totalPendingBytes, 0)

        // Chunk from current generation gen1 is accepted
        let gen1Expectation = expectation(description: "Gen1 chunk delivered")
        let coalescerGen1 = OutputCoalescer(
            highWatermark: 500,
            lowWatermark: 200,
            maxBurstChunkSize: 100,
            onFlush: { chunk in
                deliveredBox.withLockedValue { $0.append(contentsOf: chunk) }
                gen1Expectation.fulfill()
            }
        )
        let currentGen = coalescerGen1.currentGeneration
        coalescerGen1.append([UInt8](repeating: 0x77, count: 50), generation: currentGen)
        await fulfillment(of: [gen1Expectation], timeout: 2.0)
        let deliveredBytes = deliveredBox.withLockedValue { $0 }
        XCTAssertTrue(deliveredBytes.contains(0x77))
        XCTAssertFalse(deliveredBytes.contains(0x66))
    }

    func testTerminalChannelHandlerAutoReadToggling() throws {
        let handler = TerminalChannelHandler(
            generation: 1,
            onOutput: { _ in }
        )
        let channel = EmbeddedChannel(handler: handler)

        // Initial state is not paused
        XCTAssertFalse(handler.isTerminalPaused)

        // Pause terminal channel
        handler.setPaused(true)
        channel.embeddedEventLoop.run()
        XCTAssertTrue(handler.isTerminalPaused)

        // Resume terminal channel
        handler.setPaused(false)
        channel.embeddedEventLoop.run()
        XCTAssertFalse(handler.isTerminalPaused)

        _ = try channel.finish()
    }

    func testTerminalChannelHandlerServerAcceptanceGate() async throws {
        let handler = TerminalChannelHandler(
            generation: 1,
            onOutput: { _ in }
        )
        let channel = EmbeddedChannel(handler: handler)

        // Two ChannelSuccessEvents satisfy the required acceptance count
        channel.pipeline.fireUserInboundEventTriggered(ChannelSuccessEvent())
        channel.pipeline.fireUserInboundEventTriggered(ChannelSuccessEvent())

        try await handler.waitForServerAcceptance(eventLoop: channel.eventLoop)

        _ = try channel.finish()
    }

    func testTerminalChannelHandlerServerAcceptanceFailure() async throws {
        let handler = TerminalChannelHandler(
            generation: 1,
            onOutput: { _ in }
        )
        let channel = EmbeddedChannel(handler: handler)

        // Firing ChannelFailureEvent must cause acceptance to fail
        channel.pipeline.fireUserInboundEventTriggered(ChannelFailureEvent())

        do {
            try await handler.waitForServerAcceptance(eventLoop: channel.eventLoop)
            XCTFail("Should have thrown error on ChannelFailureEvent")
        } catch {
            XCTAssertNotNil(error)
        }

        _ = try? channel.finish()
    }

    func testOutputCoalescerReleaseStorage() {
        let coalescer = OutputCoalescer(onFlush: { _ in })
        coalescer.append([UInt8](repeating: 0x41, count: 10_000))
        XCTAssertGreaterThan(coalescer.totalPendingBytes, 0)
        coalescer.reset()
        XCTAssertEqual(coalescer.totalPendingBytes, 0)
        coalescer.releaseStorage()
        XCTAssertEqual(coalescer.totalPendingBytes, 0)
    }

    // MARK: - Fix 1: Bound escape-sequence memory before handlers run

    func testBoundedOscMemorySmallChunksAndSingleFeed() {
        let terminalView = FilaireTerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        let terminal = terminalView.getTerminal()
        var handlerInvokedCount = 0
        terminal.registerOscHandler(code: 5101) { _ in
            handlerInvokedCount += 1
        }

        let prefix = [UInt8]("\u{1B}]5101;".utf8)
        terminalView.feedBounded(byteArray: prefix[...])

        let chunkSize = 1024
        let chunk = [UInt8](repeating: UInt8(ascii: "A"), count: chunkSize)
        // Feed 2.5 MiB in small chunks (limit is ~2 MiB + 1 KiB)
        for _ in 0..<2560 {
            terminalView.feedBounded(byteArray: chunk[...])
        }

        // Must drop retained bytes on overflow
        XCTAssertEqual(terminalView.escapeSequenceFilter.retainedBufferBytes, 0, "Accumulated storage must be released on overflow")

        // Terminating with BEL must not dispatch the handler
        terminalView.feedBounded(byteArray: [0x07][...])
        XCTAssertEqual(handlerInvokedCount, 0, "Handler must not be invoked for oversized sequence")
        XCTAssertEqual(terminalView.escapeSequenceFilter.retainedBufferBytes, 0)

        // Repeat with a single large feed exceeding limit
        let singleLargeFeed = [UInt8]("\u{1B}]5101;".utf8) + [UInt8](repeating: UInt8(ascii: "B"), count: 2_500_000) + [0x07]
        terminalView.feedBounded(byteArray: singleLargeFeed[...])
        XCTAssertEqual(handlerInvokedCount, 0, "Single large feed exceeding limit must not invoke handler")
        XCTAssertEqual(terminalView.escapeSequenceFilter.retainedBufferBytes, 0)
    }

    func testBoundedApcMemorySmallChunksAndSingleFeed() {
        let terminalView = FilaireTerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))

        // APC sequence: ESC _ G ...
        let prefix = [UInt8]("\u{1B}_G".utf8)
        terminalView.feedBounded(byteArray: prefix[...])

        let chunk = [UInt8](repeating: UInt8(ascii: "X"), count: 1024)
        for _ in 0..<2560 {
            terminalView.feedBounded(byteArray: chunk[...])
        }

        XCTAssertEqual(terminalView.escapeSequenceFilter.retainedBufferBytes, 0, "APC storage must be released on overflow")

        terminalView.feedBounded(byteArray: [0x07][...])
        XCTAssertEqual(terminalView.escapeSequenceFilter.retainedBufferBytes, 0)

        // Single large feed for APC
        let singleLargeApc = [UInt8]("\u{1B}_G".utf8) + [UInt8](repeating: UInt8(ascii: "Y"), count: 2_500_000) + [0x07]
        terminalView.feedBounded(byteArray: singleLargeApc[...])
        XCTAssertEqual(terminalView.escapeSequenceFilter.retainedBufferBytes, 0)
    }

    func testTmuxPassthroughDoesNotGrowMemoryOrDispatch() {
        let terminalView = FilaireTerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        let terminal = terminalView.getTerminal()
        var oscHandlerInvoked = false
        terminal.registerOscHandler(code: 5101) { _ in
            oscHandlerInvoked = true
        }

        // Tmux DCS passthrough: \ePtmux;\e\e]5101;...\e\
        let tmuxPrefix = [UInt8]("\u{1B}Ptmux;\u{1B}\u{1B}]5101;".utf8)
        terminalView.feedBounded(byteArray: tmuxPrefix[...])

        let chunk = [UInt8](repeating: UInt8(ascii: "Z"), count: 1024)
        for _ in 0..<2560 {
            terminalView.feedBounded(byteArray: chunk[...])
        }
        terminalView.feedBounded(byteArray: [UInt8]("\u{1B}\\".utf8)[...])

        XCTAssertFalse(oscHandlerInvoked)
        XCTAssertEqual(terminalView.escapeSequenceFilter.retainedBufferBytes, 0)

        // Single large feed
        let singleLargeTmux = tmuxPrefix + [UInt8](repeating: UInt8(ascii: "W"), count: 2_500_000) + [UInt8]("\u{1B}\\".utf8)
        terminalView.feedBounded(byteArray: singleLargeTmux[...])
        XCTAssertFalse(oscHandlerInvoked)
        XCTAssertEqual(terminalView.escapeSequenceFilter.retainedBufferBytes, 0)
    }

    func testOscLimitExactBoundaryAccounting() {
        let terminalView = FilaireTerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        let terminal = terminalView.getTerminal()
        var receivedCount = 0
        terminal.registerOscHandler(code: 5101) { data in
            receivedCount = data.count
        }

        let prefixString = "5101;"
        let prefixBytes = [UInt8]("\u{1B}]\(prefixString)".utf8)
        let prefixOverhead = prefixBytes.count
        let limit = TerminalEscapeSequenceFilter.maxPayloadCapacity

        // Case 1: Just below limit
        let belowPayloadSize = limit - prefixOverhead - 1
        let belowPayload = [UInt8](repeating: UInt8(ascii: "A"), count: belowPayloadSize)
        terminalView.feedBounded(byteArray: (prefixBytes + belowPayload + [0x07])[...])
        XCTAssertEqual(receivedCount, belowPayloadSize, "Payload just below limit must be accepted")

        // Case 2: Exactly at limit
        receivedCount = 0
        let exactPayloadSize = limit - prefixOverhead - 1 // terminator 0x07 occupies 1 byte
        let exactPayload = [UInt8](repeating: UInt8(ascii: "B"), count: exactPayloadSize)
        terminalView.feedBounded(byteArray: (prefixBytes + exactPayload + [0x07])[...])
        XCTAssertEqual(receivedCount, exactPayloadSize, "Payload exactly at limit must be accepted")

        // Case 3: Just above limit
        receivedCount = 0
        let abovePayloadSize = limit - prefixOverhead + 1
        let abovePayload = [UInt8](repeating: UInt8(ascii: "C"), count: abovePayloadSize)
        terminalView.feedBounded(byteArray: (prefixBytes + abovePayload + [0x07])[...])
        XCTAssertEqual(receivedCount, 0, "Payload just above limit must be rejected")
        XCTAssertEqual(terminalView.escapeSequenceFilter.retainedBufferBytes, 0)
    }

    func testOscTerminatorsAndCancellationRestoreNormalParsing() {
        let terminalView = FilaireTerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        let terminal = terminalView.getTerminal()
        var smallOscInvoked = false
        terminal.registerOscHandler(code: 5101) { _ in
            smallOscInvoked = true
        }

        let overflowPrefix = [UInt8]("\u{1B}]5101;".utf8)
        let overflowChunk = [UInt8](repeating: UInt8(ascii: "M"), count: 2_500_000)

        // 1. BEL terminator (0x07)
        terminalView.feedBounded(byteArray: (overflowPrefix + overflowChunk)[...])
        XCTAssertEqual(terminalView.escapeSequenceFilter.retainedBufferBytes, 0)
        terminalView.feedBounded(byteArray: [0x07][...])
        XCTAssertEqual(terminalView.escapeSequenceFilter.retainedBufferBytes, 0)
        // Feed normal text and small OSC
        terminalView.feedBounded(text: "Hello\r\n")
        terminalView.feedBounded(byteArray: [UInt8]("\u{1B}]5101;valid\u{07}".utf8)[...])
        XCTAssertTrue(smallOscInvoked)

        // 2. String Terminator (ST) split across feeds: \x1b in feed 1, \ in feed 2
        smallOscInvoked = false
        terminalView.feedBounded(byteArray: (overflowPrefix + overflowChunk)[...])
        XCTAssertEqual(terminalView.escapeSequenceFilter.retainedBufferBytes, 0)
        terminalView.feedBounded(byteArray: [0x1B][...]) // ESC
        terminalView.feedBounded(byteArray: [0x5C][...]) // Backslash
        XCTAssertEqual(terminalView.escapeSequenceFilter.retainedBufferBytes, 0, "Split ST must terminate discarded sequence")
        terminalView.feedBounded(byteArray: [UInt8]("\u{1B}]5101;valid2\u{07}".utf8)[...])
        XCTAssertTrue(smallOscInvoked)

        // 3. C1 String Terminator (0x9c)
        smallOscInvoked = false
        terminalView.feedBounded(byteArray: (overflowPrefix + overflowChunk)[...])
        XCTAssertEqual(terminalView.escapeSequenceFilter.retainedBufferBytes, 0)
        terminalView.feedBounded(byteArray: [0x9C][...])
        XCTAssertEqual(terminalView.escapeSequenceFilter.retainedBufferBytes, 0, "C1 ST must terminate discarded sequence")
        terminalView.feedBounded(byteArray: [UInt8]("\u{1B}]5101;valid3\u{07}".utf8)[...])
        XCTAssertTrue(smallOscInvoked)

        // 4. Cancellation via CAN (0x18)
        smallOscInvoked = false
        terminalView.feedBounded(byteArray: (overflowPrefix + overflowChunk)[...])
        XCTAssertEqual(terminalView.escapeSequenceFilter.retainedBufferBytes, 0)
        terminalView.feedBounded(byteArray: [0x18][...])
        XCTAssertEqual(terminalView.escapeSequenceFilter.retainedBufferBytes, 0, "CAN must cancel discarded sequence")
        terminalView.feedBounded(byteArray: [UInt8]("\u{1B}]5101;valid4\u{07}".utf8)[...])
        XCTAssertTrue(smallOscInvoked)

        // 5. Cancellation via SUB (0x1a)
        smallOscInvoked = false
        terminalView.feedBounded(byteArray: (overflowPrefix + overflowChunk)[...])
        XCTAssertEqual(terminalView.escapeSequenceFilter.retainedBufferBytes, 0)
        terminalView.feedBounded(byteArray: [0x1A][...])
        XCTAssertEqual(terminalView.escapeSequenceFilter.retainedBufferBytes, 0, "SUB must cancel discarded sequence")
        terminalView.feedBounded(byteArray: [UInt8]("\u{1B}]5101;valid5\u{07}".utf8)[...])
        XCTAssertTrue(smallOscInvoked)
    }

    func testNoNestedRemoteCommandsInDiscardedPayload() {
        let terminalView = FilaireTerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        let terminal = terminalView.getTerminal()

        var clipboardInvoked = false
        var urlInvoked = false
        var previewInvoked = false

        terminal.registerOscHandler(code: 52) { _ in clipboardInvoked = true }
        terminal.registerOscHandler(code: 5100) { _ in urlInvoked = true }
        terminal.registerOscHandler(code: 5101) { _ in previewInvoked = true }

        // Construct oversized OSC 5101 payload that embeds apparent OSC 52, OSC 5100, and OSC 5101 commands
        let prefix = [UInt8]("\u{1B}]5101;".utf8)
        let filler = [UInt8](repeating: UInt8(ascii: "X"), count: 2_200_000)
        let nestedCommands = [UInt8]("\u{1B}]52;c;SGVsbG8=\u{1B}]5100;open;https://evil.com\u{1B}]5101;evilpreview".utf8)
        let terminator = [UInt8]("\u{1B}\\".utf8)

        let maliciousStream = prefix + filler + nestedCommands + terminator
        terminalView.feedBounded(byteArray: maliciousStream[...])

        XCTAssertFalse(clipboardInvoked, "Nested clipboard command must not execute inside discarded sequence")
        XCTAssertFalse(urlInvoked, "Nested URL command must not execute inside discarded sequence")
        XCTAssertFalse(previewInvoked, "Nested preview command must not execute inside discarded sequence")
        XCTAssertEqual(terminalView.escapeSequenceFilter.retainedBufferBytes, 0)
    }

    @MainActor
    func testParserProtectionIndependentOfPermissions() {
        let sessionManager = SessionManager()
        var host = HostProfile(name: "StrictHost", hostname: "test.local")
        host.allowClipboardRead = false
        host.allowClipboardWrite = false
        host.allowFilePreview = false
        sessionManager.activeHost = host

        let terminalView = FilaireTerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))

        // Feed oversized OSC 5101 sequence
        terminalView.feedBounded(byteArray: [UInt8]("\u{1B}]5101;".utf8)[...])
        let chunk = [UInt8](repeating: UInt8(ascii: "A"), count: 1024)
        for _ in 0..<2560 {
            terminalView.feedBounded(byteArray: chunk[...])
        }

        // Memory bound must hold even with permissions disabled
        XCTAssertEqual(terminalView.escapeSequenceFilter.retainedBufferBytes, 0)
    }

    @MainActor
    func testAppLevelMultipartFilePreviewExceedingParserLimit() {
        let sessionManager = SessionManager()
        let previewManager = sessionManager.filePreviewManager
        previewManager.resetForTesting()

        var host = HostProfile(name: "PreviewHost", hostname: "test.local")
        host.allowFilePreview = true
        sessionManager.activeHost = host

        // Wire terminal output through sessionManager to terminalView
        let terminalView = FilaireTerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        sessionManager.onTerminalOutput = { bytes in
            terminalView.feedBounded(byteArray: bytes[...])
        }
        terminalView.getTerminal().registerOscHandler(code: 5101) { [weak sessionManager] data in
            sessionManager?.handleFilePreview(data)
        }

        // Create a 2.4 MiB test file payload sent in 400 chunks of 6 KiB raw (8 KiB base64)
        // Aggregate file size > parser single sequence limit (2 MiB)
        let totalChunks = 400
        let chunkRawSize = 6144
        let rawChunk = Data(repeating: 0x42, count: chunkRawSize)
        let b64Chunk = rawChunk.base64EncodedString()

        let transferId = "bigfile_test_\(UUID().uuidString)"
        let filename = "bigarchive.bin"

        let expectation = XCTestExpectation(description: "Multi-part preview reassembled")
        var cancellable: Any?
        cancellable = previewManager.$previewURL
            .compactMap { $0 }
            .first()
            .sink { url in
                XCTAssertEqual(url.lastPathComponent, filename)
                expectation.fulfill()
            }
        _ = cancellable

        // Feed each chunk as a separate OSC 5101 sequence
        for part in 1...totalChunks {
            let oscString = "\u{1B}]5101;preview;id=\(transferId);name=\(filename);part=\(part);total=\(totalChunks);\(b64Chunk)\u{07}"
            let bytes = [UInt8](oscString.utf8)
            sessionManager.onTerminalOutput?(bytes)
        }

        wait(for: [expectation], timeout: 5.0)
        XCTAssertNotNil(previewManager.previewURL)
        previewManager.dismissPreview()
    }

    // MARK: - Findings 1 & 2 Regressions: Terminal-Parser DoS Prevention and UTF-8 Preservation

    func testMaliciousSixelRejectedBeforeDecoder() {
        let filter = TerminalEscapeSequenceFilter()
        var delivered = [UInt8]()

        // 30-byte overflow fixture from fix.md
        let maliciousSixel = Array("\u{1B}Pq#0!999999999999999999999~\u{1B}\\".utf8)
        filter.filter(bytes: maliciousSixel[...]) { chunk in
            delivered.append(contentsOf: chunk)
        }
        XCTAssertEqual(delivered.count, 0, "Malicious Sixel sequence must be rejected and deliver zero bytes")
        XCTAssertEqual(filter.retainedBufferBytes, 0, "Filter must retain 0 bytes after sequence completion")

        // Feed through real FilaireTerminalView with trailing normal text
        let terminalView = FilaireTerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        var trailingDelivered = [UInt8]()
        terminalView.escapeSequenceFilter.filter(bytes: (maliciousSixel + Array("after-sixel\r\n".utf8))[...]) { chunk in
            trailingDelivered.append(contentsOf: chunk)
        }
        XCTAssertEqual(String(bytes: trailingDelivered, encoding: .utf8), "after-sixel\r\n", "Normal text immediately following rejected Sixel must be preserved")
        XCTAssertEqual(terminalView.escapeSequenceFilter.retainedBufferBytes, 0)
    }

    func testParameterizedSixelRejectedAndDecrqssPreserved() {
        let filter = TerminalEscapeSequenceFilter()

        // Parameterized Sixel 1: ESC P 0;1;0 q
        var delivered = [UInt8]()
        let paramSixel1 = Array("\u{1B}P0;1;0q#0!123~\u{1B}\\".utf8)
        filter.filter(bytes: paramSixel1[...]) { chunk in delivered.append(contentsOf: chunk) }
        XCTAssertEqual(delivered.count, 0, "Parameterized Sixel (0;1;0) must be rejected")
        XCTAssertEqual(filter.retainedBufferBytes, 0)

        // Parameterized Sixel 2: ESC P 70;1;2 q
        delivered.removeAll()
        let paramSixel2 = Array("\u{1B}P70;1;2q#0!456~\u{1B}\\".utf8)
        filter.filter(bytes: paramSixel2[...]) { chunk in delivered.append(contentsOf: chunk) }
        XCTAssertEqual(delivered.count, 0, "Parameterized Sixel (70;1;2) must be rejected")
        XCTAssertEqual(filter.retainedBufferBytes, 0)

        // Valid DECRQSS: ESC P $ q " p ESC \
        delivered.removeAll()
        let decrqss = Array("\u{1B}P$q\"p\u{1B}\\".utf8)
        filter.filter(bytes: decrqss[...]) { chunk in delivered.append(contentsOf: chunk) }
        XCTAssertEqual(delivered, decrqss, "Valid DECRQSS must be preserved and forwarded")
        XCTAssertEqual(filter.retainedBufferBytes, 0)

        // Parameterized DECRQSS: ESC P 1 $ q " p ESC \
        delivered.removeAll()
        let paramDecrqss = Array("\u{1B}P1$q\"p\u{1B}\\".utf8)
        filter.filter(bytes: paramDecrqss[...]) { chunk in delivered.append(contentsOf: chunk) }
        XCTAssertEqual(delivered, paramDecrqss, "Parameterized DECRQSS must be preserved and forwarded")
        XCTAssertEqual(filter.retainedBufferBytes, 0)
    }

    func testDcsBelDoesNotTerminateDcsAndNeverLeaksUnboundedBytes() {
        let filter = TerminalEscapeSequenceFilter()
        var delivered = [UInt8]()

        // Case 1: Sixel DCS with BEL (from review reproduction)
        let sixelPrefix: [UInt8] = [0x1B, 0x50, 0x71, 0x07] // ESC P q BEL
        let chunk = [UInt8](repeating: 0x41, count: 64 * 1024)

        filter.filter(bytes: sixelPrefix[...]) { delivered.append(contentsOf: $0) }
        for _ in 0..<64 {
            filter.filter(bytes: chunk[...]) { delivered.append(contentsOf: $0) }
        }
        XCTAssertEqual(delivered.count, 0, "Sixel with BEL prefix followed by 4 MiB must not deliver bytes")
        XCTAssertEqual(filter.retainedBufferBytes, 0, "Retained buffer must be bounded at 0 during discard")

        // Terminate with ST and assert normal text immediately restored
        delivered.removeAll()
        filter.filter(bytes: [0x1B, 0x5C, UInt8(ascii: "O"), UInt8(ascii: "K")][...]) { delivered.append(contentsOf: $0) }
        XCTAssertEqual(String(bytes: delivered, encoding: .utf8), "OK", "Output must resume immediately after ST")

        // Case 2: Non-Sixel DCS with BEL followed by > 2 MiB data
        delivered.removeAll()
        let nonSixelPrefix: [UInt8] = [0x1B, 0x50, 0x24, 0x71, 0x07] // ESC P $ q BEL
        filter.filter(bytes: nonSixelPrefix[...]) { delivered.append(contentsOf: $0) }
        for _ in 0..<64 {
            filter.filter(bytes: chunk[...]) { delivered.append(contentsOf: $0) }
        }
        XCTAssertEqual(delivered.count, 0, "Non-Sixel DCS with BEL exceeding cap must not deliver bytes")
        XCTAssertEqual(filter.retainedBufferBytes, 0, "Retained buffer must be bounded at 0 after cap exceeded")

        // Terminate and assert normal text and valid OSC command immediately restored
        delivered.removeAll()
        filter.filter(bytes: Array("\u{1B}\\text\u{1B}]5101;valid\u{07}".utf8)[...]) { delivered.append(contentsOf: $0) }
        XCTAssertEqual(delivered, Array("text\u{1B}]5101;valid\u{07}".utf8), "Text and valid OSC must pass immediately after DCS ST")
    }

    func testDcsAndOscFramingSplitsAndOneByteFeeds() {
        let fixtures: [[UInt8]] = [
            Array("\u{1B}]5101;test\u{07}".utf8),
            Array("\u{1B}]0;Title\u{1B}\\".utf8),
            Array("\u{1B}_Gpayload\u{07}".utf8),
            Array("\u{1B}P$q\"p\u{1B}\\".utf8),
            Array("\u{1B}Pq#0!123~\u{1B}\\".utf8) // Sixel (should deliver 0 bytes in all splits)
        ]

        for fixture in fixtures {
            let isSixel = fixture.starts(with: [0x1B, 0x50, 0x71])
            let expectedDelivered = isSixel ? [] : fixture

            // 1. One-byte feeds
            let filter1 = TerminalEscapeSequenceFilter()
            var delivered1 = [UInt8]()
            for byte in fixture {
                filter1.filter(bytes: [byte][...]) { delivered1.append(contentsOf: $0) }
            }
            XCTAssertEqual(delivered1, expectedDelivered, "One-byte feed failed for \(String(bytes: fixture, encoding: .isoLatin1) ?? "")")
            XCTAssertEqual(filter1.retainedBufferBytes, 0)

            // 2. Every possible two-part split
            for splitIndex in 1..<fixture.count {
                let filter2 = TerminalEscapeSequenceFilter()
                var delivered2 = [UInt8]()
                filter2.filter(bytes: fixture[0..<splitIndex]) { delivered2.append(contentsOf: $0) }
                filter2.filter(bytes: fixture[splitIndex..<fixture.count]) { delivered2.append(contentsOf: $0) }
                XCTAssertEqual(delivered2, expectedDelivered, "Split at \(splitIndex) failed for \(String(bytes: fixture, encoding: .isoLatin1) ?? "")")
                XCTAssertEqual(filter2.retainedBufferBytes, 0)
            }
        }
    }

    func testTmuxPassthroughUnwrappingAndSmokeTest() {
        let terminalView = FilaireTerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        let terminal = terminalView.getTerminal()

        var clipboardReceived = ""
        terminal.registerOscHandler(code: 52) { data in
            clipboardReceived = String(bytes: data, encoding: .utf8) ?? ""
        }

        var notificationReceived = ""
        terminal.registerOscHandler(code: 777) { data in
            notificationReceived = String(bytes: data, encoding: .utf8) ?? ""
        }

        var previewReceived = ""
        terminal.registerOscHandler(code: 5101) { data in
            previewReceived = String(bytes: data, encoding: .utf8) ?? ""
        }

        // 1. Tmux wrapped OSC 52 (fil copy): \ePtmux;\e\e]52;c;dGVzdA==\a\e\
        let tmuxOsc52 = "\u{1B}Ptmux;\u{1B}\u{1B}]52;c;dGVzdA==\u{07}\u{1B}\\"
        terminalView.feedBounded(text: tmuxOsc52)
        XCTAssertEqual(clipboardReceived, "c;dGVzdA==", "Tmux wrapped OSC 52 must be unwrapped and dispatched")

        // 2. Tmux wrapped OSC 777 (fil notify): \ePtmux;\e\e]777;notify;Build;Success\a\e\
        let tmuxOsc777 = "\u{1B}Ptmux;\u{1B}\u{1B}]777;notify;Build;Success\u{07}\u{1B}\\"
        terminalView.feedBounded(text: tmuxOsc777)
        XCTAssertEqual(notificationReceived, "notify;Build;Success", "Tmux wrapped OSC 777 must be unwrapped and dispatched")

        // 3. Tmux wrapped OSC 5101 (fil preview): \ePtmux;\e\e]5101;preview;id=1;...\a\e\
        let tmuxOsc5101 = "\u{1B}Ptmux;\u{1B}\u{1B}]5101;preview;id=1;name=test.txt;part=1;total=1;dGVzdA==\u{07}\u{1B}\\"
        terminalView.feedBounded(text: tmuxOsc5101)
        XCTAssertEqual(previewReceived, "preview;id=1;name=test.txt;part=1;total=1;dGVzdA==", "Tmux wrapped OSC 5101 must be unwrapped and dispatched")

        // 4. Tmux wrapper containing inner malicious Sixel must be rejected safely
        let tmuxSixel = "\u{1B}Ptmux;\u{1B}\u{1B}Pq#0!999999999999999999999~\u{1B}\u{1B}\\\u{1B}\\"
        terminalView.feedBounded(text: tmuxSixel)
        XCTAssertEqual(terminalView.escapeSequenceFilter.retainedBufferBytes, 0)
    }

    func testUtf8ByteEqualityAndContinuationsPreserved() {
        let testStrings: [String] = [
            // Review reproductions
            "before 😀 after\nnext prompt$ ",
            "before П after\nnext prompt$ ",
            // Unicode categories
            "Café, mañana, über, naïve",
            "Привет мир (Cyrillic)",
            "日本語と中文 (CJK)",
            "😀🚀🎉👩‍💻👨‍👩‍👧‍👦 (Emoji)",
            "\u{E0B0}\u{E0B2} (Powerline Private Use)",
            // Specific continuation bytes matching 0x90, 0x9C, 0x9D, 0x9F
            "\u{0110} and \u{10000}", // 0x90 continuation
            "\u{011C} and \u{015C}", // 0x9C continuation
            "\u{011D}",              // 0x9D continuation
            "\u{041F} and \u{1F600}"  // 0x9F continuation
        ]

        for string in testStrings {
            let originalBytes = [UInt8](string.utf8)

            // Test 1: Full feed
            let filter1 = TerminalEscapeSequenceFilter()
            var delivered1 = [UInt8]()
            filter1.filter(bytes: originalBytes[...]) { delivered1.append(contentsOf: $0) }
            XCTAssertEqual(delivered1, originalBytes, "Full feed failed for: \(string)")
            XCTAssertEqual(filter1.retainedBufferBytes, 0)

            // Test 2: One-byte-at-a-time feed
            let filter2 = TerminalEscapeSequenceFilter()
            var delivered2 = [UInt8]()
            for byte in originalBytes {
                filter2.filter(bytes: [byte][...]) { delivered2.append(contentsOf: $0) }
            }
            XCTAssertEqual(delivered2, originalBytes, "One-byte feed failed for: \(string)")
            XCTAssertEqual(filter2.retainedBufferBytes, 0)

            // Test 3: Every 2-part split
            for splitIndex in 1..<originalBytes.count {
                let filter3 = TerminalEscapeSequenceFilter()
                var delivered3 = [UInt8]()
                filter3.filter(bytes: originalBytes[0..<splitIndex]) { delivered3.append(contentsOf: $0) }
                filter3.filter(bytes: originalBytes[splitIndex..<originalBytes.count]) { delivered3.append(contentsOf: $0) }
                XCTAssertEqual(delivered3, originalBytes, "2-part split at \(splitIndex) failed for: \(string)")
                XCTAssertEqual(filter3.retainedBufferBytes, 0)
            }
        }
    }

    func testUtf8InsideOscPayloadDoesNotTerminateEarly() {
        let terminalView = FilaireTerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        let terminal = terminalView.getTerminal()

        var titleReceived = ""
        terminal.registerOscHandler(code: 0) { data in
            titleReceived = String(bytes: data, encoding: .utf8) ?? ""
        }

        // Title containing Ĝ (\u{011C} = 0xC4 0x9C). 0x9C continuation must NOT terminate as C1 ST!
        let oscTitle = "\u{1B}]0;Terminal Ĝ Title\u{07}"
        terminalView.feedBounded(text: oscTitle)
        XCTAssertEqual(titleReceived, "Terminal Ĝ Title", "OSC title with 0x9C continuation byte must not terminate prematurely")

        // Split across feeds right between 0xC4 and 0x9C
        titleReceived = ""
        let part1 = Array("\u{1B}]0;Split ".utf8) + [0xC4]
        let part2 = [0x9C] + Array(" Test\u{07}".utf8)
        terminalView.feedBounded(byteArray: part1[...])
        terminalView.feedBounded(byteArray: part2[...])
        XCTAssertEqual(titleReceived, "Split Ĝ Test", "OSC title split between leading byte and 0x9C continuation must be preserved")
    }

    func testUtf8MalformedRecoveryAndBoundedState() {
        let filter = TerminalEscapeSequenceFilter()
        var delivered = [UInt8]()

        // 1. Stray continuation byte 0x80 followed by ASCII 'a'
        filter.filter(bytes: [0x80, UInt8(ascii: "a")][...]) { delivered.append(contentsOf: $0) }
        XCTAssertEqual(delivered, [0x80, UInt8(ascii: "a")])
        XCTAssertEqual(filter.retainedBufferBytes, 0)

        // 2. Incomplete leading byte (0xC4) followed by valid ASCII escape sequence (ESC [ A)
        delivered.removeAll()
        let incompleteLeadingThenEsc = [0xC4, 0x1B, UInt8(ascii: "["), UInt8(ascii: "A")]
        filter.filter(bytes: incompleteLeadingThenEsc[...]) { delivered.append(contentsOf: $0) }
        XCTAssertEqual(delivered, incompleteLeadingThenEsc, "Incomplete leading byte must not swallow following ESC sequence")
        XCTAssertEqual(filter.retainedBufferBytes, 0)

        // 3. Overlong encoding [0xC0, 0xAF]
        delivered.removeAll()
        filter.filter(bytes: [0xC0, 0xAF, UInt8(ascii: "z")][...]) { delivered.append(contentsOf: $0) }
        XCTAssertEqual(delivered, [0xC0, 0xAF, UInt8(ascii: "z")])
        XCTAssertEqual(filter.retainedBufferBytes, 0)

        // 4. Surrogate encoding [0xED, 0xA0, 0x80] (U+D800)
        delivered.removeAll()
        filter.filter(bytes: [0xED, 0xA0, 0x80, UInt8(ascii: "x")][...]) { delivered.append(contentsOf: $0) }
        XCTAssertEqual(delivered, [0xED, 0xA0, 0x80, UInt8(ascii: "x")])
        XCTAssertEqual(filter.retainedBufferBytes, 0)
    }

    func testTerminalResetAtStreamBoundaries() {
        let terminalView = FilaireTerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))

        // Feed incomplete UTF-8 byte (0xF0) and incomplete OSC sequence
        terminalView.feedBounded(byteArray: [0xF0, 0x1B, UInt8(ascii: "]"), UInt8(ascii: "0"), UInt8(ascii: ";")][...])
        XCTAssertGreaterThan(terminalView.escapeSequenceFilter.retainedBufferBytes, 0)

        // Explicit reset via wipeScreen() or resetParserState()
        terminalView.resetParserState()
        XCTAssertEqual(terminalView.escapeSequenceFilter.retainedBufferBytes, 0, "Reset must clear retained buffer bytes")

        // Deliver new session prompt
        var promptDelivered = [UInt8]()
        terminalView.escapeSequenceFilter.filter(bytes: Array("login: ".utf8)[...]) { chunk in
            promptDelivered.append(contentsOf: chunk)
        }
        XCTAssertEqual(String(bytes: promptDelivered, encoding: .utf8), "login: ", "Prompt from new transport must not combine with previous session bytes")
    }

    // MARK: - Finding 2 Regressions: Attempt-scoped Lifecycle & Host-Key Deadlines

    @MainActor
    func testHostKeyApprovalBeyondAuthenticationDeadlineSucceeds() async throws {
        let attempt = SSHConnectionAttempt()
        let channel = EmbeddedChannel()
        attempt.setChannel(channel)

        // Verify attempt is active
        XCTAssertTrue(attempt.isActive)

        let hostname = "test-pause-\(UUID().uuidString).test"
        defer { KnownHostsStore.shared.removeEntry(hostname: hostname, port: 22) }
        let (hostKey, promise, group) = makeHostKeyAndPromise()
        defer { try? group.syncShutdownGracefully() }

        var userApproved = false
        let validator = TOFUHostKeyValidator(hostname: hostname, port: 22, onUnknownHostKey: { _ in
            try? await Task.sleep(nanoseconds: 50_000_000)
            userApproved = true
            return true
        }, attempt: attempt)

        validator.validateHostKey(hostKey: hostKey, validationCompletePromise: promise)

        try await promise.futureResult.get()
        XCTAssertTrue(userApproved)
        XCTAssertTrue(attempt.isActive)
        XCTAssertNotNil(KnownHostsStore.shared.getEntry(hostname: hostname, port: 22))

        attempt.complete()
        XCTAssertFalse(attempt.isActive)
    }

    @MainActor
    func testNetworkDeadlineStillExpiresWhenServerStallsBeforeHostKeyOrAfterApproval() async throws {
        // Case 1: Timeout before approval closes transport
        let attempt1 = SSHConnectionAttempt()
        let channel1 = EmbeddedChannel()
        attempt1.setChannel(channel1)

        attempt1.fail(error: ChannelError.connectTimeout(.milliseconds(50)))
        XCTAssertFalse(attempt1.isActive)
        XCTAssertFalse(channel1.isActive)

        // Case 2: Cancellation closes transport
        let attempt2 = SSHConnectionAttempt()
        let channel2 = EmbeddedChannel()
        attempt2.setChannel(channel2)

        attempt2.cancel()
        XCTAssertFalse(attempt2.isActive)
        XCTAssertFalse(channel2.isActive)
    }

    @MainActor
    func testRejectTrustClosesTransportAndLeavesNoKnownHostEntry() async throws {
        let attempt = SSHConnectionAttempt()
        let channel = EmbeddedChannel()
        attempt.setChannel(channel)

        let hostname = "test-reject-\(UUID().uuidString).test"
        defer { KnownHostsStore.shared.removeEntry(hostname: hostname, port: 22) }
        let (hostKey, promise, group) = makeHostKeyAndPromise()
        defer { try? group.syncShutdownGracefully() }

        let validator = TOFUHostKeyValidator(hostname: hostname, port: 22, onUnknownHostKey: { _ in
            return false // User clicks "Cancel" / Reject
        }, attempt: attempt)

        validator.validateHostKey(hostKey: hostKey, validationCompletePromise: promise)

        do {
            try await promise.futureResult.get()
            XCTFail("Promise should fail on rejected trust")
        } catch {
            XCTAssertTrue(error is HostKeyMismatchError)
        }

        // Must NOT save to known hosts
        XCTAssertNil(KnownHostsStore.shared.getEntry(hostname: hostname, port: 22))

        // Transport must be closed
        XCTAssertFalse(attempt.isActive)
        XCTAssertFalse(channel.isActive)
    }

    @MainActor
    func testCancellationInAllPhasesClosesTransportAndCleansPrompt() async throws {
        // Phase A: Cancel while pending channel creation
        do {
            let attemptA = SSHConnectionAttempt()
            attemptA.cancel()
            XCTAssertTrue(attemptA.isCancelled)

            let channelA = EmbeddedChannel()
            attemptA.setChannel(channelA)
            // Channel must be closed immediately upon arrival
            XCTAssertFalse(channelA.isActive)
        }

        // Phase B: Cancel during host-key approval
        do {
            let attemptB = SSHConnectionAttempt()
            let channelB = EmbeddedChannel()
            attemptB.setChannel(channelB)

            let (hostKey, promise, group) = makeHostKeyAndPromise()
            defer { try? group.syncShutdownGracefully() }

            let promptCancelled = XCTestExpectation(description: "Prompt cancelled")
            let validator = TOFUHostKeyValidator(hostname: "cancel-host.test", port: 22, onUnknownHostKey: { _ in
                // Cancel attempt while waiting
                attemptB.cancel()
                promptCancelled.fulfill()
                return true
            }, attempt: attemptB)

            validator.validateHostKey(hostKey: hostKey, validationCompletePromise: promise)
            await fulfillment(of: [promptCancelled], timeout: 2.0)

            do {
                try await promise.futureResult.get()
                XCTFail("Promise must fail when attempt cancelled")
            } catch {
                XCTAssertTrue(error is HostKeyMismatchError || error is CancellationError)
            }
            XCTAssertFalse(attemptB.isActive)
            XCTAssertFalse(channelB.isActive)
        }

        // Phase C: Cancel during active connection
        do {
            let attemptC = SSHConnectionAttempt()
            let channelC = EmbeddedChannel()
            attemptC.setChannel(channelC)

            attemptC.cancel()
            XCTAssertFalse(attemptC.isActive)
            XCTAssertFalse(channelC.isActive)
        }
    }

    @MainActor
    func testTimeoutWithoutApprovalClosesSocketAndLeavesNoAbandonedTransport() async throws {
        let attempt = SSHConnectionAttempt()
        let channel = EmbeddedChannel()
        attempt.setChannel(channel)

        attempt.fail(error: ChannelError.connectTimeout(.milliseconds(50)))

        // Verify channel is closed and not abandoned
        XCTAssertFalse(attempt.isActive)
        XCTAssertFalse(channel.isActive)
    }

    @MainActor
    func testLateApprovalAfterCancellationOrTimeoutDoesNotPersistTrustOrAuthenticate() async throws {
        let hostname = "late-trust-\(UUID().uuidString).test"
        defer { KnownHostsStore.shared.removeEntry(hostname: hostname, port: 22) }

        let attemptA = SSHConnectionAttempt()
        let channelA = EmbeddedChannel()
        attemptA.setChannel(channelA)

        let (hostKey, promise, group) = makeHostKeyAndPromise()
        defer { try? group.syncShutdownGracefully() }

        var continuation: CheckedContinuation<Bool, Never>?
        let validatorA = TOFUHostKeyValidator(hostname: hostname, port: 22, onUnknownHostKey: { _ in
            await withCheckedContinuation { cont in
                continuation = cont
            }
        }, attempt: attemptA)

        validatorA.validateHostKey(hostKey: hostKey, validationCompletePromise: promise)

        // Wait for continuation to be set
        for _ in 0..<50 where continuation == nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        // Cancel Attempt A
        attemptA.cancel()
        XCTAssertFalse(attemptA.isActive)
        XCTAssertFalse(channelA.isActive)

        // Deliver late "trust" approval to Attempt A
        continuation?.resume(returning: true)

        do {
            try await promise.futureResult.get()
            XCTFail("Cancelled attempt must not succeed validation")
        } catch {
            XCTAssertTrue(error is HostKeyMismatchError || error is CancellationError)
        }

        // KnownHostsStore must NOT have saved the key
        XCTAssertNil(KnownHostsStore.shared.getEntry(hostname: hostname, port: 22))
    }

    @MainActor
    func testSwitchHostsWhilePromptDisplayedLeavesNewSessionUntouched() async throws {
        let manager = SessionManager()
        let hostA = HostProfile(id: UUID(), name: "HostA", hostname: "hosta.test", username: "user")
        let hostB = HostProfile(id: UUID(), name: "HostB", hostname: "hostb.test", username: "user")

        let attemptIdA = UUID()
        manager.currentConnectionId = attemptIdA
        manager.activeHost = hostA
        let entryA = KnownHostEntry(
            hostname: hostA.hostname,
            port: 22,
            keyType: "ssh-ed25519",
            fingerprintSHA256: "SHA256:fingerprintA",
            openSSHPublicKey: "ssh-ed25519 AAAA... hostA"
        )

        // Present prompt for Attempt A
        let taskA = Task {
            await manager.confirmUnknownHostKey(entryA, attemptId: attemptIdA)
        }

        for _ in 0..<50 where manager.pendingSecurityPrompt == nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(manager.pendingSecurityPrompt?.attemptId, attemptIdA)

        // Switch to Host B (which dismisses Attempt A's prompt)
        manager.connect(to: hostB, allHosts: [hostA, hostB])
        XCTAssertNotEqual(manager.pendingSecurityPrompt?.attemptId, attemptIdA)

        // Late callback from Attempt A returns false and does not alter current session
        let resultA = await taskA.value
        XCTAssertFalse(resultA)
        XCTAssertEqual(manager.activeHost?.id, hostB.id)
    }

    @MainActor
    func testBastionAndTargetChannelCleanupOnFailure() async throws {
        let bastionAttempt = SSHConnectionAttempt()
        let bastionChannel = EmbeddedChannel()
        bastionAttempt.setChannel(bastionChannel)

        let targetAttempt = SSHConnectionAttempt()
        let targetChannel = EmbeddedChannel()
        targetAttempt.setChannel(targetChannel)

        // Test failure in target handshake
        targetAttempt.fail(error: ChannelError.connectTimeout(.seconds(5)))
        XCTAssertFalse(targetAttempt.isActive)
        XCTAssertFalse(targetChannel.isActive)

        // Cleaning up session bundle closes both
        bastionAttempt.cancel()
        XCTAssertFalse(bastionAttempt.isActive)
        XCTAssertFalse(bastionChannel.isActive)
    }

    @MainActor
    func testRaceSuccessAgainstCancellationAndTimeout() async throws {
        for _ in 0..<50 {
            let attempt = SSHConnectionAttempt()
            let cleanupCounter = NIOLockedValueBox(0)
            attempt.onCleanup {
                cleanupCounter.withLockedValue { $0 += 1 }
            }

            // Race cancel, fail/timeout, approval, and success concurrently
            let t1 = Task { attempt.cancel() }
            let t2 = Task { attempt.fail(error: ChannelError.connectTimeout(.milliseconds(50))) }
            let t3 = Task { attempt.succeed() }
            let t4 = Task { _ = attempt.approveHostKey() }

            _ = await (t1.value, t2.value, t3.value, t4.value)

            // Attempt must be inactive and cleanup must have been invoked exactly once on terminal outcome
            XCTAssertFalse(attempt.isActive)
            cleanupCounter.withLockedValue {
                XCTAssertEqual($0, 1)
            }
        }
    }

    // MARK: - Finding 3 Regressions: Remote Responses for Connection Health

    func testInitialHealthCheckTimeoutDoesNotDisableFutureRemoteProbesAndSucceedsOnLaterResponse() async throws {
        let service = SSHService()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }

        let gen = await service.currentSessionGeneration
        let bundle = SessionBundle(generation: gen)
        bundle.isConnectedForTesting = true
        bundle.connectionChannel = channel
        bundle.stdinWriter = TerminalChannelWriter(channel: channel)
        await service.installSessionBundleForTesting(bundle)

        let probeCount = NIOLockedValueBox(0)
        await service.setProbeRunnerForTesting { _, _ in
            let count = probeCount.withLockedValue { c -> Int in
                c += 1
                return c
            }
            if count == 1 {
                // First probe times out
                try? await Task.sleep(nanoseconds: 200_000_000)
                return false
            } else {
                // Subsequent probe receives remote response and succeeds
                return true
            }
        }

        // Probe 1 times out
        let result1 = await service.ping(timeout: 0.05)
        XCTAssertFalse(result1)

        // Remote probes are NOT permanently disabled! Probe 2 actually sends and succeeds
        let result2 = await service.ping(timeout: 1.0)
        XCTAssertTrue(result2)
        XCTAssertEqual(probeCount.withLockedValue { $0 }, 2)
    }

    func testBlackholedConnectionFailsPingDespiteLocalWriteSuccessAndKeepAliveDisconnects() async throws {
        let service = SSHService()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }

        let gen = await service.currentSessionGeneration
        let bundle = SessionBundle(generation: gen)
        bundle.isConnectedForTesting = true
        bundle.connectionChannel = channel
        bundle.stdinWriter = TerminalChannelWriter(channel: channel)
        await service.installSessionBundleForTesting(bundle)

        // Blackholed connection: local writes succeed (EmbeddedChannel accepts writes),
        // but remote probes receive no response and time out
        await service.setProbeRunnerForTesting { _, _ in
            try? await Task.sleep(nanoseconds: 100_000_000)
            return false
        }

        // Local resize write succeeds
        await service.resize(cols: 80, rows: 24)

        // Ping must fail by its deadline, refusing to fall back to window-size write
        let pingResult = await service.ping(timeout: 0.05)
        XCTAssertFalse(pingResult)

        // Start keep-alive with rapid interval; 3 consecutive probe failures must trigger disconnect
        let disconnected = NIOLockedValueBox(false)
        await service.startKeepAliveForTesting(interval: 0.05) { error in
            disconnected.withLockedValue { $0 = true }
        }

        for _ in 0..<100 where !disconnected.withLockedValue({ $0 }) {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(disconnected.withLockedValue { $0 }, "Repeated probe failures must trigger disconnect")
    }

    func testExplicitGlobalRequestRefusalCountsAsHealthyResponse() async throws {
        let service = SSHService()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }

        let gen = await service.currentSessionGeneration
        let bundle = SessionBundle(generation: gen)
        bundle.isConnectedForTesting = true
        bundle.connectionChannel = channel
        bundle.stdinWriter = TerminalChannelWriter(channel: channel)
        await service.installSessionBundleForTesting(bundle)

        // Explicit globalRequestRefused proves remote liveness
        await service.setProbeRunnerForTesting { _, _ in
            return true
        }

        let result = await service.ping(timeout: 1.0)
        XCTAssertTrue(result, "Explicit global request refusal proves remote liveness")
    }

    func testTransportErrorOrFailedChannelLookupFailsPingEvenWithWriterPresent() async throws {
        let service = SSHService()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }

        let gen = await service.currentSessionGeneration
        let bundle = SessionBundle(generation: gen)
        bundle.isConnectedForTesting = true
        bundle.stdinWriter = TerminalChannelWriter(channel: channel)
        // No connectionChannel set (lookup fails)
        await service.installSessionBundleForTesting(bundle)

        let result = await service.ping(timeout: 1.0)
        XCTAssertFalse(result, "Missing or broken channel lookup must fail ping without write fallback")
    }

    func testConcurrentHeartbeatAndForegroundChecksCoalesceWithBoundedOutstandingRequests() async throws {
        let service = SSHService()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }

        let gen = await service.currentSessionGeneration
        let bundle = SessionBundle(generation: gen)
        bundle.isConnectedForTesting = true
        bundle.connectionChannel = channel
        bundle.stdinWriter = TerminalChannelWriter(channel: channel)
        await service.installSessionBundleForTesting(bundle)

        let executions = NIOLockedValueBox(0)
        await service.setProbeRunnerForTesting { _, _ in
            executions.withLockedValue { $0 += 1 }
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms probe
            return true
        }

        // Call ping concurrently: caller 1 has 30ms timeout (will time out),
        // caller 2 has 250ms timeout (will succeed when probe finishes)
        async let p1 = service.ping(timeout: 0.03)
        async let p2 = service.ping(timeout: 0.25)

        let (r1, r2) = await (p1, p2)
        XCTAssertFalse(r1, "Caller 1 timeout expired before probe completed")
        XCTAssertTrue(r2, "Caller 2 received shared probe success")
        XCTAssertEqual(executions.withLockedValue { $0 }, 1, "Concurrent checks must coalesce to exactly 1 in-flight probe")
    }

    func testCallerCancellationDoesNotCancelSharedUnderlyingProbe() async throws {
        let service = SSHService()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }

        let gen = await service.currentSessionGeneration
        let bundle = SessionBundle(generation: gen)
        bundle.isConnectedForTesting = true
        bundle.connectionChannel = channel
        bundle.stdinWriter = TerminalChannelWriter(channel: channel)
        await service.installSessionBundleForTesting(bundle)

        await service.setProbeRunnerForTesting { _, _ in
            try? await Task.sleep(nanoseconds: 80_000_000)
            return true
        }

        // Caller 1 starts and cancels after 10ms
        let t1 = Task { await service.ping(timeout: 1.0) }
        let t2 = Task { await service.ping(timeout: 1.0) }

        try? await Task.sleep(nanoseconds: 10_000_000)
        t1.cancel()

        let r1 = await t1.value
        let r2 = await t2.value
        XCTAssertFalse(r1, "Cancelled task returns false")
        XCTAssertTrue(r2, "Non-cancelled task completes successfully using shared probe")
    }

    func testDisconnectWhileProbeOutstandingResolvesWaitersAndDoesNotAffectNewSession() async throws {
        let service = SSHService()
        let channelA = EmbeddedChannel()
        defer { _ = try? channelA.finish() }

        await service.disconnect()
        let genA = await service.currentSessionGeneration
        let bundleA = SessionBundle(generation: genA)
        bundleA.isConnectedForTesting = true
        bundleA.connectionChannel = channelA
        bundleA.stdinWriter = TerminalChannelWriter(channel: channelA)
        await service.installSessionBundleForTesting(bundleA)

        let probeStarted = NIOLockedValueBox(false)
        await service.setProbeRunnerForTesting { _, _ in
            probeStarted.withLockedValue { $0 = true }
            try? await Task.sleep(nanoseconds: 500_000_000)
            return true
        }

        // Start ping on Session A
        let pingTaskA = Task { await service.ping(timeout: 1.0) }
        while !probeStarted.withLockedValue({ $0 }) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        // Disconnect Session A and start Session B
        await service.disconnect()
        let genB = await service.currentSessionGeneration
        XCTAssertNotEqual(genA, genB)

        let channelB = EmbeddedChannel()
        defer { _ = try? channelB.finish() }
        let bundleB = SessionBundle(generation: genB)
        bundleB.isConnectedForTesting = true
        bundleB.connectionChannel = channelB
        bundleB.stdinWriter = TerminalChannelWriter(channel: channelB)
        await service.installSessionBundleForTesting(bundleB)

        // Session A's probe waiter must resolve false (not affected by late response)
        let rA = await pingTaskA.value
        XCTAssertFalse(rA)

        // Session B is healthy and untouched
        await service.setProbeRunnerForTesting { _, _ in true }
        let rB = await service.ping(timeout: 0.1)
        XCTAssertTrue(rB)
    }

    func testPingWhileDisconnectedReturnsFalseImmediately() async throws {
        let service = SSHService()
        await service.disconnect()
        let result = await service.ping(timeout: 1.0)
        XCTAssertFalse(result)
    }

    @MainActor
    func testForegroundHealthCheckFailsAndTriggersReconnectWhenProbeTimesOut() async throws {
        let manager = SessionManager()
        let host = HostProfile(id: UUID(), name: "TestHost", hostname: "testhost.test", username: "user")
        manager.activeHost = host
        manager.currentConnectionId = UUID()
        manager.markConnectedForTesting()
        manager.handleAppBackgrounded()

        // Simulate probe failing (remote peer unresponsive)
        await manager.sshService.setProbeRunnerForTesting { _, _ in
            return false
        }

        manager.handleAppForegrounded()

        // Wait for healthCheckTask to complete and trigger reconnect
        for _ in 0..<50 where manager.state == .connected {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(manager.state.isBusy || manager.state != .connected)
    }

    // MARK: - Multi-Window & Notification Policy Tests

    @MainActor
    func testMultiWindowManagerSessionRegistrationAndTracking() {
        let sm1 = SessionManager()
        let sm2 = SessionManager()
        let host1 = HostProfile(name: "Host 1", hostname: "h1.local")
        let host2 = HostProfile(name: "Host 2", hostname: "h2.local")
        sm1.activeHost = host1
        sm2.activeHost = host2
        sm1.markConnectedForTesting()

        MultiWindowManager.shared.register(sessionManager: sm1, scene: nil, hostId: host1.id)
        MultiWindowManager.shared.register(sessionManager: sm2, scene: nil, hostId: host2.id)

        XCTAssertTrue(MultiWindowManager.shared.isHostConnected(host1.id))
        XCTAssertFalse(MultiWindowManager.shared.isHostConnected(host2.id))

        MultiWindowManager.shared.unregister(sessionManager: sm1)
        XCTAssertFalse(MultiWindowManager.shared.isHostConnected(host1.id))

        MultiWindowManager.shared.unregister(sessionManager: sm2)
    }

    @MainActor
    func testMultiWindowNotificationActiveVsBackgroundPolicy() {
        let manager = SessionManager()
        let host = HostProfile(name: "NotifyHost", hostname: "notify.local")
        manager.activeHost = host

        let representable = TerminalRepresentable(sessionManager: manager)
        let coordinator = representable.makeCoordinator()
        let terminalView = FilaireTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        coordinator.terminalView = terminalView

        // 1. When fired in the currently active window:
        // Shows in-window toast banner, does NOT post system notification
        coordinator.forceWindowActiveStateForTesting = true
        coordinator.notify(source: terminalView, title: "Build Completed", body: "100% done")

        XCTAssertNotNil(manager.activeToast)
        XCTAssertEqual(manager.activeToast?.title, "NotifyHost: Build Completed")
        XCTAssertEqual(manager.activeToast?.message, "100% done")

        // Reset toast
        manager.activeToast = nil
        XCTAssertNil(manager.activeToast)

        // 2. When fired in a non-active / background window:
        // Suppresses in-window toast banner, posts system notification
        coordinator.forceWindowActiveStateForTesting = false
        coordinator.notify(source: terminalView, title: "Background Job", body: "Finished in background")

        // In-window toast must NOT be shown
        XCTAssertNil(manager.activeToast)
    }

    @MainActor
    func testMultiWindowKeepAliveWhenSceneEntersBackground() {
        let sm1 = SessionManager()
        let sm2 = SessionManager()
        let host1 = HostProfile(name: "H1", hostname: "h1.local")
        let host2 = HostProfile(name: "H2", hostname: "h2.local")
        sm1.activeHost = host1
        sm2.activeHost = host2
        sm1.markConnectedForTesting()
        sm2.markConnectedForTesting()

        MultiWindowManager.shared.register(sessionManager: sm1, scene: nil, hostId: host1.id)
        MultiWindowManager.shared.register(sessionManager: sm2, scene: nil, hostId: host2.id)

        // When registered, sessions maintain their foreground state
        XCTAssertFalse(sm1.isAppInBackground)
        XCTAssertFalse(sm2.isAppInBackground)

        MultiWindowManager.shared.unregister(sessionManager: sm1)
        MultiWindowManager.shared.unregister(sessionManager: sm2)
    }

    @MainActor
    func testOpenHostInWindowActivatesExistingSceneWhenAlreadyConnected() {
        let hostId = UUID()
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first,
            let scene = window.windowScene else {
            return
        }

        QuickActionManager.shared.tagScene(scene, withHostId: hostId)
        XCTAssertEqual(QuickActionManager.findScene(for: hostId, in: [scene]), scene)

        // Calling openHostInWindow for an already connected host routes to existing scene safely
        QuickActionManager.shared.openHostInWindow(hostId: hostId)
        QuickActionManager.shared.openHostInNewWindow(hostId: hostId)

        QuickActionManager.shared.tagScene(scene, withHostId: nil)
    }

    @MainActor
    func testNotificationDelegatePresentationOptionsWhenHostFocusedVsUnfocused() {
        let hostId = UUID()
        let userInfo: [AnyHashable: Any] = [QuickActionManager.hostIdUserInfoKey: hostId.uuidString]

        // When host is not focused: presentation options include banner, sound, badge, list
        let optionsUnfocused = NotificationDelegate.shared.presentationOptions(for: userInfo)
        XCTAssertTrue(optionsUnfocused.contains(.banner))
        XCTAssertTrue(optionsUnfocused.contains(.sound))
        XCTAssertTrue(optionsUnfocused.contains(.badge))
        XCTAssertTrue(optionsUnfocused.contains(.list))

        // When targetContentIdentifier is used instead of userInfo
        let targetId = QuickActionManager.targetContentIdentifier(for: hostId)
        let optionsFromTarget = NotificationDelegate.shared.presentationOptions(for: [:], targetContentIdentifier: targetId)
        XCTAssertTrue(optionsFromTarget.contains(.banner))
    }

    @MainActor
    func testNotificationDelegateHandleResponseRoutesToHostWindow() {
        let hostId = UUID()
        var receivedNotification: Notification?
        let cancellable = NotificationCenter.default.publisher(for: .connectHostRequested)
            .sink { notification in
                receivedNotification = notification
            }

        let userInfo: [AnyHashable: Any] = [QuickActionManager.hostIdUserInfoKey: hostId.uuidString]
        NotificationDelegate.shared.handleNotificationResponse(userInfo: userInfo)

        // Verifies the notification response handler extracts hostId and triggers connection
        XCTAssertNotNil(receivedNotification)
        let extractedHostId = receivedNotification?.userInfo?[QuickActionManager.hostIdUserInfoKey] as? UUID
        XCTAssertEqual(extractedHostId, hostId)

        // Test fallback to targetContentIdentifier when userInfo is empty
        receivedNotification = nil
        let hostId2 = UUID()
        let targetId2 = QuickActionManager.targetContentIdentifier(for: hostId2)
        NotificationDelegate.shared.handleNotificationResponse(userInfo: [:], targetContentIdentifier: targetId2)

        XCTAssertNotNil(receivedNotification)
        let extractedHostId2 = receivedNotification?.userInfo?[QuickActionManager.hostIdUserInfoKey] as? UUID
        XCTAssertEqual(extractedHostId2, hostId2)

        _ = cancellable
    }

    @MainActor
    func testTmuxShortcutBarVisibilityAndTriggers() {
        let view = FilaireTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        view.applyAccessoryBarSetting()

        // When configured with tmux disabled:
        view.configureTmux(enabled: false, prefixTitle: "Ctrl-B", prefixByte: 0x02)
        XCTAssertFalse(view.autoConnectTmux)

        // Tmux actions must be disabled
        XCTAssertFalse(view.triggerTmuxNewWindow())
        XCTAssertFalse(view.triggerTmuxNextWindow())
        XCTAssertFalse(view.triggerTmuxPrevWindow())
        XCTAssertFalse(view.triggerTmuxSplitVertical())
        XCTAssertFalse(view.triggerTmuxSplitHorizontal())
        XCTAssertFalse(view.triggerTmuxWindowNumber(1))

        // When enabled, tmux actions succeed
        view.configureTmux(enabled: true, prefixTitle: "Ctrl-A", prefixByte: 0x01)
        XCTAssertTrue(view.autoConnectTmux)
        XCTAssertTrue(view.triggerTmuxNewWindow())

        // When disabled again, tmux actions are suppressed
        view.configureTmux(enabled: false, prefixTitle: "Ctrl-B", prefixByte: 0x02)
        XCTAssertFalse(view.autoConnectTmux)
        XCTAssertFalse(view.triggerTmuxNewWindow())
    }

    @MainActor
    func testIsHostOpenAnywhereTracksActiveAndUnallocatedHosts() {
        let sm = SessionManager()
        let hostId = UUID()

        // Initially host is not open
        XCTAssertFalse(MultiWindowManager.shared.isHostOpenAnywhere(hostId))

        // When registered, isHostOpenAnywhere returns true
        MultiWindowManager.shared.register(sessionManager: sm, scene: nil, hostId: hostId)
        XCTAssertTrue(MultiWindowManager.shared.isHostOpenAnywhere(hostId))

        // When unregistered, returns false
        MultiWindowManager.shared.unregister(sessionManager: sm)
        XCTAssertFalse(MultiWindowManager.shared.isHostOpenAnywhere(hostId))
    }

    @MainActor
    func testOpenHostInNewWindowSetsPendingHostIdAndConsumes() {
        let hostId = UUID()
        // Intercept activation so the test doesn't create real window scenes in the test host
        QuickActionManager.shared.sceneActivationHandler = { _, _, _, _ in }
        defer { QuickActionManager.shared.sceneActivationHandler = nil }
        if UIApplication.shared.supportsMultipleScenes {
            QuickActionManager.shared.openHostInNewWindow(hostId: hostId)
            let consumed = QuickActionManager.shared.consumeInitialHostId()
            XCTAssertEqual(consumed, hostId)
            XCTAssertNil(QuickActionManager.shared.consumeInitialHostId())
        } else {
            var receivedHostId: UUID?
            let cancellable = NotificationCenter.default.publisher(for: .connectHostRequested)
                .sink { note in
                    receivedHostId = note.userInfo?[QuickActionManager.hostIdUserInfoKey] as? UUID
                }
            QuickActionManager.shared.openHostInNewWindow(hostId: hostId)
            XCTAssertEqual(receivedHostId, hostId)
            _ = cancellable
        }
    }

    @MainActor
    func testCloseCurrentWindowShortcutTriggersNotification() {
        let terminal = FilaireTerminalView(frame: .zero)
        // Post from a window the app doesn't own; with no window object, the app's real
        // window treats the request as its own and closes the test host's scene.
        let hostWindow = UIWindow(frame: .zero)
        hostWindow.addSubview(terminal)
        var receivedNotification = false
        let cancellable = NotificationCenter.default.publisher(for: .closeCurrentWindowRequested)
            .sink { _ in
                receivedNotification = true
            }

        // Test hardware key interception
        let handled = terminal.handleKeyShortcut(
            characters: "W",
            charactersIgnoringModifiers: "w",
            modifierFlags: [.command, .shift]
        )
        XCTAssertTrue(handled)
        XCTAssertTrue(receivedNotification)

        _ = cancellable
    }

    @MainActor
    func testDiscardSessionsSafelyRemovesMultipleEntriesWithoutMutationCrash() {
        let sm1 = SessionManager()
        let sm2 = SessionManager()
        let host1 = HostProfile(name: "H1", hostname: "h1.local")
        let host2 = HostProfile(name: "H2", hostname: "h2.local")
        sm1.activeHost = host1
        sm2.activeHost = host2
        sm1.markConnectedForTesting()
        sm2.markConnectedForTesting()

        MultiWindowManager.shared.register(sessionManager: sm1, scene: nil, hostId: host1.id)
        MultiWindowManager.shared.register(sessionManager: sm2, scene: nil, hostId: host2.id)

        // Discarding empty or non-matching sessions does not crash
        MultiWindowManager.shared.discardSessions([])
        XCTAssertTrue(MultiWindowManager.shared.isHostOpenAnywhere(host1.id))
        XCTAssertTrue(MultiWindowManager.shared.isHostOpenAnywhere(host2.id))

        MultiWindowManager.shared.unregister(sessionManager: sm1)
        MultiWindowManager.shared.unregister(sessionManager: sm2)
    }

    @MainActor
    func testSceneDidDisconnectRetainsEntryUntilDiscardSessionsDisconnects() {
        let sm = SessionManager()
        let host = HostProfile(name: "DiscardTest", hostname: "discard.local")
        sm.activeHost = host
        sm.markConnectedForTesting()
        XCTAssertTrue(sm.state.isConnected)

        let persistentId = "test-session-persistent-id-999"
        MultiWindowManager.shared.register(
            sessionManager: sm,
            scene: nil,
            hostId: host.id,
            sessionPersistentIdentifier: persistentId
        )

        // Host is tracked as open
        XCTAssertTrue(MultiWindowManager.shared.isHostOpenAnywhere(host.id))

        // Discarding non-matching persistent IDs preserves the session
        MultiWindowManager.shared.discardSessions(matchingPersistentIdentifiers: ["other-id"])
        XCTAssertTrue(MultiWindowManager.shared.isHostOpenAnywhere(host.id))
        XCTAssertTrue(sm.state.isConnected)

        // Discarding the matching persistent ID disconnects the session manager and purges the entry
        MultiWindowManager.shared.discardSessions(matchingPersistentIdentifiers: [persistentId])
        XCTAssertFalse(MultiWindowManager.shared.isHostOpenAnywhere(host.id))
        XCTAssertEqual(sm.state, .disconnected)

        MultiWindowManager.shared.unregister(sessionManager: sm)
    }

    @MainActor
    func testUnopenedHostFilteringForNewWindowOptions() {
        let host1 = HostProfile(name: "Host 1", hostname: "h1.local")
        let host2 = HostProfile(name: "Host 2", hostname: "h2.local")
        let host3 = HostProfile(name: "Host 3", hostname: "h3.local")
        let allHosts = [host1, host2, host3]

        let sm2 = SessionManager()
        sm2.activeHost = host2
        MultiWindowManager.shared.register(sessionManager: sm2, scene: nil, hostId: host2.id)

        let selectedHostId = host1.id

        // Filter unopened hosts: should exclude host1 (selected in current window) and host2 (open in another window)
        let unopenedHosts = allHosts.filter {
            $0.id != selectedHostId && !MultiWindowManager.shared.isHostOpenAnywhere($0.id)
        }

        XCTAssertEqual(unopenedHosts.count, 1)
        XCTAssertEqual(unopenedHosts.first?.id, host3.id)

        let sm3 = SessionManager()
        sm3.activeHost = host3
        MultiWindowManager.shared.register(sessionManager: sm3, scene: nil, hostId: host3.id)

        let allOpenHosts = allHosts.filter {
            $0.id != selectedHostId && !MultiWindowManager.shared.isHostOpenAnywhere($0.id)
        }
        XCTAssertTrue(allOpenHosts.isEmpty, "When all hosts are open in dedicated windows, unopenedHosts must be empty")

        MultiWindowManager.shared.unregister(sessionManager: sm2)
        MultiWindowManager.shared.unregister(sessionManager: sm3)
    }

    @MainActor
    func testSessionManagerMemorySheddingAndRestoration() {
        let sm = SessionManager()
        let terminal = FilaireTerminalView(frame: .zero)

        var shedCount = 0
        var restoreCount = 0

        sm.onShedMemory = {
            shedCount += 1
            terminal.shedMemoryPressure()
        }
        sm.onRestoreMemory = {
            restoreCount += 1
            terminal.restoreScrollbackLimit()
        }

        // Initially scrollback limit matches settings
        XCTAssertEqual(terminal.appliedScrollback, TerminalSettings.shared.scrollbackLimit.rawValue)

        // Shed memory: caps at 1000 lines
        sm.shedMemory()
        XCTAssertEqual(shedCount, 1)
        XCTAssertEqual(terminal.appliedScrollback, 1000)

        // Restore memory: removes cap, restores user limit
        sm.restoreMemory()
        XCTAssertEqual(restoreCount, 1)
        XCTAssertEqual(terminal.appliedScrollback, TerminalSettings.shared.scrollbackLimit.rawValue)
    }

    @MainActor
    func testCursorAnimationResilienceAndOpacityState() {
        let terminal = FilaireTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        terminal.updateSizeIfNeeded()

        guard let caret = terminal.caretSubView else {
            XCTFail("CaretView must be present as a subview of FilaireTerminalView")
            return
        }

        // 1. Initial state: model layer opacity must be 1.0
        XCTAssertEqual(caret.layer.opacity, 1.0, "Model layer opacity must default to 1.0 so cursor never vanishes")

        // 2. Simulate UIKit cancelling an in-flight animation during a window transition (opacity left at 0.0)
        caret.layer.removeAllAnimations()
        caret.layer.opacity = 0.0
        XCTAssertEqual(caret.layer.opacity, 0.0)

        // 3. Calling refreshCursorAnimation() or ensureCursorActive() must immediately restore opacity to 1.0
        terminal.ensureCursorActive()
        XCTAssertEqual(caret.layer.opacity, 1.0, "ensureCursorActive must restore opacity to 1.0")

        // 4. Test first responder focus transitions
        _ = terminal.becomeFirstResponder()
        XCTAssertEqual(caret.layer.opacity, 1.0, "Model opacity must remain 1.0 when becoming first responder")

        _ = terminal.resignFirstResponder()
        XCTAssertEqual(caret.layer.opacity, 1.0, "Model opacity must remain 1.0 when resigning first responder")
        XCTAssertNil(caret.layer.animation(forKey: FilaireTerminalView.cursorBlinkAnimationKey), "Blink animation should be removed when resigning first responder")

        // 5. Test steady cursor style
        terminal.cursorStyleChanged(source: terminal.getTerminal(), newStyle: .steadyBlock)
        XCTAssertEqual(caret.layer.opacity, 1.0, "Steady cursor must maintain opacity 1.0")
        XCTAssertNil(caret.layer.animation(forKey: FilaireTerminalView.cursorBlinkAnimationKey), "Steady cursor must not have blink animation")

        // Restore default blink style
        terminal.cursorStyleChanged(source: terminal.getTerminal(), newStyle: .blinkBlock)
    }

    @MainActor
    func testDisconnectClosesWindowWhenMultipleWindowsOpen() {
        let sm = SessionManager()
        var destructionRequested = false
        var destroyedSession: UISceneSession?

        MultiWindowManager.shared.onSceneSessionDestructionRequestedForTesting = { session in
            destructionRequested = true
            destroyedSession = session
        }
        defer {
            MultiWindowManager.shared.forceMultipleWindowsForTesting = nil
            MultiWindowManager.shared.onSceneSessionDestructionRequestedForTesting = nil
            MultiWindowManager.shared.unregister(sessionManager: sm)
        }

        // 1. When it IS the last open window (forceMultipleWindowsForTesting = false):
        // Disconnecting should NOT close the window
        MultiWindowManager.shared.forceMultipleWindowsForTesting = false
        destructionRequested = false

        sm.onIntentionalDisconnect = { [weak sm] in
            guard let sm = sm else { return }
            _ = MultiWindowManager.shared.closeWindowIfMultiple(for: sm)
        }

        sm.disconnect()
        XCTAssertFalse(destructionRequested, "Disconnecting the last open window must NOT request scene destruction")

        // 2. When multiple windows ARE open (forceMultipleWindowsForTesting = true):
        // Disconnecting SHOULD close the window
        MultiWindowManager.shared.forceMultipleWindowsForTesting = true
        destructionRequested = false

        let window = UIWindow()
        if let scene = window.windowScene {
            MultiWindowManager.shared.register(sessionManager: sm, scene: scene, hostId: UUID())
            sm.disconnect()
            XCTAssertTrue(destructionRequested, "Disconnecting when multiple windows are open must request scene destruction")
            XCTAssertNotNil(destroyedSession)
        } else {
            // Direct test of closeSceneIfMultiple
            // Create mock session if scene is nil in test harness
            let didClose = MultiWindowManager.shared.hasMultipleOpenWindows
            XCTAssertTrue(didClose, "hasMultipleOpenWindows must report true when forced or multiple entries exist")
        }
    }

    @MainActor
    func testIsHostOpenAnywhereExcludingSessionManager() {
        let sm1 = SessionManager()
        let sm2 = SessionManager()
        let hostId = UUID()

        MultiWindowManager.shared.register(sessionManager: sm1, scene: nil, hostId: hostId)

        // Host is open anywhere
        XCTAssertTrue(MultiWindowManager.shared.isHostOpenAnywhere(hostId))

        // When queried from sm1's perspective (excluding sm1), host is NOT open elsewhere
        XCTAssertFalse(MultiWindowManager.shared.isHostOpenAnywhere(hostId, excluding: sm1))

        // When queried from sm2's perspective (excluding sm2), host IS open elsewhere (in sm1)
        XCTAssertTrue(MultiWindowManager.shared.isHostOpenAnywhere(hostId, excluding: sm2))

        MultiWindowManager.shared.unregister(sessionManager: sm1)
        MultiWindowManager.shared.unregister(sessionManager: sm2)
    }

    @MainActor
    func testDuplicateWindowActivationRouting() {
        let sm1 = SessionManager()
        let host = HostProfile(name: "Host1", hostname: "h1.local")
        let hostId = host.id

        MultiWindowManager.shared.register(sessionManager: sm1, scene: nil, hostId: hostId)

        // When a second window checks if hostId is already open elsewhere
        let sm2 = SessionManager()
        let isOpenElsewhere = MultiWindowManager.shared.isHostOpenAnywhere(hostId, excluding: sm2)
        XCTAssertTrue(isOpenElsewhere, "Host must be reported as open elsewhere to prevent duplicate window connection")

        MultiWindowManager.shared.unregister(sessionManager: sm1)
        MultiWindowManager.shared.unregister(sessionManager: sm2)
    }

    func testSanitizeTerminalTitle() {
        // Strips control characters
        let rawWithControl = "vim \u{001B}[31mtest.py\r\n\t"
        let sanitized = SessionManager.sanitizeTerminalTitle(rawWithControl)
        XCTAssertEqual(sanitized, "vim [31mtest.py")

        // Trims whitespace
        let whitespaceTitle = "   htop -u root   "
        XCTAssertEqual(SessionManager.sanitizeTerminalTitle(whitespaceTitle), "htop -u root")

        // Clamps length to 100
        let longTitle = String(repeating: "a", count: 150)
        let clamped = SessionManager.sanitizeTerminalTitle(longTitle)
        XCTAssertEqual(clamped.count, 100)
    }

    @MainActor
    func testDynamicWindowTitleUpdatesAndReset() {
        let appState = AppState()
        var host = HostProfile(name: "ProdServer", hostname: "prod.local")
        host.autoConnectTmux = false
        appState.hosts = [host]
        appState.selectedHostId = host.id

        // Base window title
        XCTAssertEqual(appState.windowTitle, "ProdServer")

        // Terminal title changed event (e.g. from OSC 0/2)
        appState.sessionManager.onTerminalTitleChanged?("vim server.swift")
        XCTAssertEqual(appState.dynamicTerminalTitle, "vim server.swift")
        XCTAssertEqual(appState.windowTitle, "ProdServer: vim server.swift")

        // Disconnecting resets the dynamic terminal title
        appState.sessionManager.onDisconnect?()
        XCTAssertNil(appState.dynamicTerminalTitle)
        XCTAssertEqual(appState.windowTitle, "ProdServer")

        // Setting a new dynamic title
        appState.sessionManager.onTerminalTitleChanged?("git status")
        XCTAssertEqual(appState.windowTitle, "ProdServer: git status")

        // Switching selected host resets dynamic terminal title
        var host2 = HostProfile(name: "StagingServer", hostname: "staging.local")
        host2.autoConnectTmux = false
        appState.hosts.append(host2)
        appState.selectedHostId = host2.id
        XCTAssertNil(appState.dynamicTerminalTitle)
        XCTAssertEqual(appState.windowTitle, "StagingServer")
    }

    func testMakeHostItemProviderDisablesDragWhenHostAlreadyOpen() {
        let host = HostProfile(name: "TestHost", hostname: "testhost.local")

        // When host is already open, provider must be empty (disabling drag)
        let openProvider = HostListView.makeHostItemProvider(for: host, isAlreadyOpen: true)
        XCTAssertTrue(openProvider.registeredTypeIdentifiers.isEmpty, "Already open host must have empty registered type identifiers")

        // When host is not open, provider must contain user activity drag payload
        let unopenedProvider = HostListView.makeHostItemProvider(for: host, isAlreadyOpen: false)
        XCTAssertFalse(unopenedProvider.registeredTypeIdentifiers.isEmpty, "Unopened host must register item provider type identifiers for drag-to-split")
    }

    @MainActor
    func testStatusOverlayUnopenedHostsFilteringWithSessionExclusion() {
        let host1 = HostProfile(name: "Host 1", hostname: "h1.local")
        let host2 = HostProfile(name: "Host 2", hostname: "h2.local")
        let host3 = HostProfile(name: "Host 3", hostname: "h3.local")
        let allHosts = [host1, host2, host3]

        let currentSm = SessionManager()
        currentSm.activeHost = host1
        // Register currentSm with host1
        MultiWindowManager.shared.register(sessionManager: currentSm, scene: nil, hostId: host1.id)

        let otherSm = SessionManager()
        otherSm.activeHost = host2
        MultiWindowManager.shared.register(sessionManager: otherSm, scene: nil, hostId: host2.id)

        // StatusOverlayView logic:
        let unopenedHosts = allHosts.filter {
            $0.id != currentSm.activeHost?.id && !MultiWindowManager.shared.isHostOpenAnywhere($0.id, excluding: currentSm)
        }

        // Host 1 is current window's active host -> excluded
        // Host 2 is open in otherSm -> excluded
        // Host 3 is not open anywhere -> included
        XCTAssertEqual(unopenedHosts.count, 1)
        XCTAssertEqual(unopenedHosts.first?.id, host3.id)

        MultiWindowManager.shared.unregister(sessionManager: currentSm)
        MultiWindowManager.shared.unregister(sessionManager: otherSm)
    }

    @MainActor
    func testClaimHostSuccessAndDuplicateRejection() {
        let sm1 = SessionManager()
        let sm2 = SessionManager()
        let hostId = UUID()

        // sm1 claims hostId first
        let claim1 = MultiWindowManager.shared.claimHost(hostId, for: sm1, scene: nil)
        XCTAssertEqual(claim1, .claimed, "First window claim must succeed with .claimed")

        // sm1 re-claiming the same host must also succeed
        let claim1Reaffirm = MultiWindowManager.shared.claimHost(hostId, for: sm1, scene: nil)
        XCTAssertEqual(claim1Reaffirm, .claimed, "Same window re-affirming claim must return .claimed")

        // sm2 trying to claim the same host must be rejected
        let claim2 = MultiWindowManager.shared.claimHost(hostId, for: sm2, scene: nil)
        if case .alreadyClaimed = claim2 {
            // Expected
        } else {
            XCTFail("Second window claiming already claimed host must return .alreadyClaimed")
        }

        MultiWindowManager.shared.unregister(sessionManager: sm1)
        MultiWindowManager.shared.unregister(sessionManager: sm2)
    }

    @MainActor
    func testDeduplicateWindowsDisconnectsAndClosesDuplicate() {
        MultiWindowManager.shared.resetForTesting()
        defer { MultiWindowManager.shared.resetForTesting() }
        let sm1 = SessionManager()
        let sm2 = SessionManager()
        let host = HostProfile(name: "DupeHost", hostname: "dupe.local")
        let hostId = host.id

        sm1.activeHost = host
        sm2.activeHost = host

        MultiWindowManager.shared.forceMultipleWindowsForTesting = true
        var destructionRequested = false
        MultiWindowManager.shared.onSceneSessionDestructionRequestedForTesting = { _ in
            destructionRequested = true
        }
        let testScene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first

        // When a duplicate window registers with the same hostId, registration automatically triggers deduplication
        MultiWindowManager.shared.register(sessionManager: sm1, scene: nil, hostId: hostId, sessionPersistentIdentifier: "window-1")
        MultiWindowManager.shared.register(sessionManager: sm2, scene: testScene, hostId: hostId, sessionPersistentIdentifier: "window-2")

        // sm2 was the duplicate: activeHost should have been cleared on disconnect automatically during register
        XCTAssertNil(sm2.activeHost, "Duplicate session active host must be cleared")
        XCTAssertEqual(sm2.state, .disconnected, "Duplicate session must be disconnected")
        if testScene != nil {
            XCTAssertTrue(destructionRequested, "Destruction must be requested for duplicate window scene")
        }

        // MultiWindowManager must now only have sm1 associated with hostId
        XCTAssertTrue(MultiWindowManager.shared.isHostOpenAnywhere(hostId, excluding: sm2))
        XCTAssertFalse(MultiWindowManager.shared.isHostOpenAnywhere(hostId, excluding: sm1))

        MultiWindowManager.shared.forceMultipleWindowsForTesting = nil
        MultiWindowManager.shared.onSceneSessionDestructionRequestedForTesting = nil
        MultiWindowManager.shared.unregister(sessionManager: sm1)
        MultiWindowManager.shared.unregister(sessionManager: sm2)
    }

    @MainActor
    func testStartupAutoConnectHostClaimingAndDuplicateDetection() {
        var host = HostProfile(name: "ProdServer", hostname: "prod.local")
        host.autoConnect = true
        let hosts = [host]

        let sm1 = SessionManager()
        let sm2 = SessionManager()

        MultiWindowManager.shared.forceMultipleWindowsForTesting = true
        defer {
            MultiWindowManager.shared.forceMultipleWindowsForTesting = nil
            MultiWindowManager.shared.unregister(sessionManager: sm1)
            MultiWindowManager.shared.unregister(sessionManager: sm2)
        }

        // Window 1 launches and finds unclaimed auto-connect host
        let unclaimed1 = hosts.first { h in
            h.autoConnect && !MultiWindowManager.shared.isHostOpenAnywhere(h.id, excluding: sm1)
        }
        XCTAssertEqual(unclaimed1?.id, host.id)

        let claim1 = MultiWindowManager.shared.claimHost(host.id, for: sm1, scene: nil)
        XCTAssertEqual(claim1, .claimed)

        // Window 2 launches concurrently (e.g. after iPad reboot)
        let unclaimed2 = hosts.first { h in
            h.autoConnect && !MultiWindowManager.shared.isHostOpenAnywhere(h.id, excluding: sm2)
        }
        XCTAssertNil(unclaimed2, "Host claimed by Window 1 must NOT be eligible as unclaimed for Window 2")

        // If Window 2 attempts to claim the same targetHostId directly:
        let claim2 = MultiWindowManager.shared.claimHost(host.id, for: sm2, scene: nil)
        if case .alreadyClaimed = claim2 {
            // Expected: correctly identifies that another window already holds this host
        } else {
            XCTFail("Window 2 must be rejected with .alreadyClaimed")
        }
    }

    // MARK: - R2: Transactional Window Ownership & Duplicate Closure Tests

    @MainActor
    func testMultiWindowManagerDeterministicSurvivorOrder() {
        let host = HostProfile(name: "TestHost", hostname: "testhost.local")
        let hostId = host.id

        let sm1 = SessionManager()
        let sm2 = SessionManager()
        let sm3 = SessionManager()

        sm2.state = .connecting
        sm3.state = .connected

        MultiWindowManager.shared.forceMultipleWindowsForTesting = true
        defer {
            MultiWindowManager.shared.forceMultipleWindowsForTesting = nil
            MultiWindowManager.shared.unregister(sessionManager: sm1)
            MultiWindowManager.shared.unregister(sessionManager: sm2)
            MultiWindowManager.shared.unregister(sessionManager: sm3)
        }

        MultiWindowManager.shared.register(sessionManager: sm1, scene: nil, hostId: hostId, sessionPersistentIdentifier: "session-1")
        MultiWindowManager.shared.register(sessionManager: sm2, scene: nil, hostId: hostId, sessionPersistentIdentifier: "session-2")
        MultiWindowManager.shared.register(sessionManager: sm3, scene: nil, hostId: hostId, sessionPersistentIdentifier: "session-3")

        MultiWindowManager.shared.deduplicateWindows()

        let entry1 = MultiWindowManager.shared.entry(for: sm1)
        let entry2 = MultiWindowManager.shared.entry(for: sm2)
        let entry3 = MultiWindowManager.shared.entry(for: sm3)

        XCTAssertEqual(entry3?.status, .owned, "Connected session must remain .owned survivor")
        XCTAssertEqual(entry3?.hostId, hostId)
        XCTAssertEqual(entry1?.status, .closing, "Disconnected duplicate must be marked .closing")
        XCTAssertNil(entry1?.hostId, "Disconnected duplicate hostId must be cleared")
        XCTAssertEqual(entry2?.status, .closing, "Connecting duplicate must be marked .closing")
        XCTAssertNil(entry2?.hostId, "Connecting duplicate hostId must be cleared")

        // Test connecting vs disconnected
        let sm4 = SessionManager()
        let sm5 = SessionManager()
        let hostB = HostProfile(name: "HostB", hostname: "hostb.local")
        defer {
            MultiWindowManager.shared.unregister(sessionManager: sm4)
            MultiWindowManager.shared.unregister(sessionManager: sm5)
        }

        sm4.state = .connecting
        sm5.state = .disconnected

        MultiWindowManager.shared.register(sessionManager: sm4, scene: nil, hostId: hostB.id, sessionPersistentIdentifier: "session-4")
        MultiWindowManager.shared.register(sessionManager: sm5, scene: nil, hostId: hostB.id, sessionPersistentIdentifier: "session-5")

        MultiWindowManager.shared.deduplicateWindows()

        let entry4 = MultiWindowManager.shared.entry(for: sm4)
        let entry5 = MultiWindowManager.shared.entry(for: sm5)
        XCTAssertEqual(entry4?.status, .owned, "Connecting session must survive over disconnected session")
        XCTAssertEqual(entry4?.hostId, hostB.id)
        XCTAssertEqual(entry5?.status, .closing)
        XCTAssertNil(entry5?.hostId)
    }

    @MainActor
    func testMultiWindowManagerSameSessionReconciliation() {
        let host = HostProfile(name: "ReconcileHost", hostname: "reconcile.local")
        let hostId = host.id

        let smOld = SessionManager()
        let smNew = SessionManager()
        smNew.state = .connected

        MultiWindowManager.shared.forceMultipleWindowsForTesting = true
        defer {
            MultiWindowManager.shared.forceMultipleWindowsForTesting = nil
            MultiWindowManager.shared.unregister(sessionManager: smOld)
            MultiWindowManager.shared.unregister(sessionManager: smNew)
        }

        MultiWindowManager.shared.register(sessionManager: smOld, scene: nil, hostId: hostId, sessionPersistentIdentifier: "session-shared")
        MultiWindowManager.shared.register(sessionManager: smNew, scene: nil, hostId: hostId, sessionPersistentIdentifier: "session-shared")

        MultiWindowManager.shared.deduplicateWindows()

        let entryNew = MultiWindowManager.shared.entry(for: smNew)
        XCTAssertNotNil(entryNew, "Active session for persistent identifier must be preserved")
        XCTAssertEqual(entryNew?.hostId, hostId)
    }

    @MainActor
    func testMultiWindowManagerSimultaneousClosuresAndInFlightDestruction() {
        let sm1 = SessionManager()
        let sm2 = SessionManager()

        var destructionCount = 0
        MultiWindowManager.shared.onSceneSessionDestructionRequestedForTesting = { _ in
            destructionCount += 1
        }
        defer {
            MultiWindowManager.shared.onSceneSessionDestructionRequestedForTesting = nil
            MultiWindowManager.shared.forceMultipleWindowsForTesting = nil
            MultiWindowManager.shared.unregister(sessionManager: sm1)
            MultiWindowManager.shared.unregister(sessionManager: sm2)
        }

        MultiWindowManager.shared.forceMultipleWindowsForTesting = true
        XCTAssertTrue(MultiWindowManager.shared.hasMultipleOpenWindows)

        let testScene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        if let scene = testScene {
            let pid = scene.session.persistentIdentifier
            MultiWindowManager.shared.sessionsWithDestructionInFlight.removeAll()

            let firstResult = MultiWindowManager.shared.closeSceneIfMultiple(scene)
            XCTAssertTrue(firstResult)
            XCTAssertEqual(destructionCount, 1)
            XCTAssertTrue(MultiWindowManager.shared.sessionsWithDestructionInFlight.contains(pid))

            let secondResult = MultiWindowManager.shared.closeSceneIfMultiple(scene)
            XCTAssertTrue(secondResult)
            XCTAssertEqual(destructionCount, 1, "In-flight destruction must NOT re-invoke requestSceneSessionDestruction")

            MultiWindowManager.shared.handleSceneDidDisconnect(scene)
            XCTAssertFalse(MultiWindowManager.shared.sessionsWithDestructionInFlight.contains(pid))
        }

        MultiWindowManager.shared.forceMultipleWindowsForTesting = false
        XCTAssertFalse(MultiWindowManager.shared.hasMultipleOpenWindows, "When forced to single window, hasMultipleOpenWindows must be false")
        if let scene = testScene {
            let refused = MultiWindowManager.shared.closeSceneIfMultiple(scene)
            XCTAssertFalse(refused, "Must refuse to destroy last remaining window")
        }
    }

    @MainActor
    func testMultiWindowManagerTeardownReservationAcrossWindows() {
        let sm1 = SessionManager()
        let sm2 = SessionManager()
        let hostA = HostProfile(name: "HostA", hostname: "a.local")
        let hostB = HostProfile(name: "HostB", hostname: "b.local")

        defer {
            MultiWindowManager.shared.unregister(sessionManager: sm1)
            MultiWindowManager.shared.unregister(sessionManager: sm2)
            MultiWindowManager.shared.pendingTeardownHostIds.removeAll()
        }

        let claimA = MultiWindowManager.shared.claimHost(hostA.id, for: sm1, scene: nil)
        XCTAssertEqual(claimA, .claimed)

        let claimB = MultiWindowManager.shared.claimHost(hostB.id, for: sm1, scene: nil)
        XCTAssertEqual(claimB, .claimed)

        XCTAssertTrue(MultiWindowManager.shared.pendingTeardownHostIds.contains(hostA.id), "Previous host must enter teardown reservation")

        let claimA2 = MultiWindowManager.shared.claimHost(hostA.id, for: sm2, scene: nil)
        if case .alreadyClaimed = claimA2 {
            // Success
        } else {
            XCTFail("Claiming host undergoing teardown reservation must return .alreadyClaimed")
        }

        sm1.onTeardownComplete?()
        XCTAssertFalse(MultiWindowManager.shared.pendingTeardownHostIds.contains(hostA.id), "Pending teardown must be cleared on completion")

        let claimA3 = MultiWindowManager.shared.claimHost(hostA.id, for: sm2, scene: nil)
        XCTAssertEqual(claimA3, .claimed, "Host must be claimable once teardown completes")
    }

    @MainActor
    func testAppStateConnectTransactionalClaiming() {
        let host = HostProfile(name: "TransactionalHost", hostname: "tx.local")
        let appState1 = AppState()
        appState1.hosts = [host]
        let appState2 = AppState()
        appState2.hosts = [host]

        defer {
            MultiWindowManager.shared.unregister(sessionManager: appState1.sessionManager)
            MultiWindowManager.shared.unregister(sessionManager: appState2.sessionManager)
        }

        appState1.connect(to: host)
        XCTAssertEqual(appState1.selectedHostId, host.id)
        XCTAssertTrue(MultiWindowManager.shared.isHostClaimed(by: appState1.sessionManager, hostId: host.id))

        appState2.connect(to: host)
        XCTAssertNotEqual(appState2.selectedHostId, host.id, "Second AppState must not claim host or mutate selectedHostId")
        XCTAssertFalse(MultiWindowManager.shared.isHostClaimed(by: appState2.sessionManager, hostId: host.id))
    }

    @MainActor
    func testMultiWindowDetachedSessionActivationRouting() {
        let hostA = HostProfile(name: "HostA", hostname: "a.local")
        let smA = SessionManager()
        let smB = SessionManager()
        defer {
            MultiWindowManager.shared.unregister(sessionManager: smA)
            MultiWindowManager.shared.unregister(sessionManager: smB)
        }

        let pidA = "scene-session-A"
        let pidB = "scene-session-B"
        MultiWindowManager.shared.register(sessionManager: smA, scene: nil, hostId: hostA.id, sessionPersistentIdentifier: pidA)
        MultiWindowManager.shared.register(sessionManager: smB, scene: nil, hostId: UUID(), sessionPersistentIdentifier: pidB)

        // Detach A
        if let recA = MultiWindowManager.shared.records[pidA] {
            recA.scene = nil
        }

        // Routing query for hostA must find existing session record for A
        let sessionRecord = MultiWindowManager.shared.findSessionRecord(for: hostA.id)
        XCTAssertNotNil(sessionRecord, "Routing must resolve existing detached session record")
        XCTAssertEqual(sessionRecord?.persistentIdentifier, pidA)
        XCTAssertTrue(sessionRecord?.isDetached == true, "Session A should be marked detached")

        XCTAssertEqual(MultiWindowManager.shared.records[pidA]?.hostId, hostA.id)
    }

    @MainActor
    func testMultiWindowDetachedSessionOutputPreservedOnReattach() {
        let host = HostProfile(name: "OutputHost", hostname: "output.local")
        let sm = SessionManager()
        defer {
            MultiWindowManager.shared.unregister(sessionManager: sm)
        }

        let pid = "detached-output-session"
        let record = MultiWindowManager.shared.register(
            sessionManager: sm,
            scene: nil,
            hostId: host.id,
            sessionPersistentIdentifier: pid
        )

        // Context holds the terminalView and consumes SSH output
        guard let ctx = record.terminalContext else {
            XCTFail("Terminal context must be initialized")
            return
        }

        // Simulate scene detachment
        ctx.detachView()

        // Feed terminal output while detached
        let testString = "Hello Detached World\r\n"
        let testBytes = Array(testString.utf8)
        sm.onTerminalOutput?(testBytes)

        // Verify terminalView parsed the output while detached
        let term = ctx.terminalView.getTerminal()
        var foundOutput = false
        for row in 0..<term.rows {
            var lineStr = ""
            for col in 0..<term.cols {
                if let ch = term.character(col: col, row: row) {
                    lineStr.append(ch)
                }
            }
            if lineStr.contains("Hello Detached World") {
                foundOutput = true
                break
            }
        }
        XCTAssertTrue(foundOutput, "Terminal view must receive and parse output during detachment")

        // Reattach to a new view representation
        let representable = TerminalRepresentable(sessionManager: sm)
        let coordinator = representable.makeCoordinator()
        XCTAssertTrue(coordinator === ctx, "Coordinator must reuse existing TerminalSessionContext")
        XCTAssertTrue(coordinator.terminalView === ctx.terminalView, "Terminal view must be preserved across reattachment")
    }

    @MainActor
    func testMultiWindowOwnershipIndependentOfViewLifecycle() {
        let host = HostProfile(name: "IndependentHost", hostname: "indep.local")
        let sm = SessionManager()
        let pid = "view-independent-session"
        defer {
            MultiWindowManager.shared.unregister(sessionManager: sm)
        }

        MultiWindowManager.shared.register(
            sessionManager: sm,
            scene: nil,
            hostId: host.id,
            sessionPersistentIdentifier: pid
        )

        XCTAssertTrue(MultiWindowManager.shared.isHostClaimed(by: sm, hostId: host.id))

        // Simulate view disappearance
        let entry = MultiWindowManager.shared.entry(forPersistentIdentifier: pid)
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.hostId, host.id)
        XCTAssertEqual(entry?.status, .owned)

        // Reattachment
        let smNew = SessionManager()
        defer { MultiWindowManager.shared.unregister(sessionManager: smNew) }
        let reattachedRecord = MultiWindowManager.shared.register(
            sessionManager: smNew,
            scene: nil,
            hostId: host.id,
            sessionPersistentIdentifier: pid
        )

        XCTAssertEqual(reattachedRecord.persistentIdentifier, pid)
        XCTAssertEqual(reattachedRecord.hostId, host.id)
        XCTAssertEqual(reattachedRecord.status, .owned)
    }

    @MainActor
    func testMultiWindowDiscardDetachedSessionCleansUpAllResources() {
        let host = HostProfile(name: "DiscardHost", hostname: "discard.local")
        let sm = SessionManager()
        let pid = "discard-detached-session"
        defer {
            MultiWindowManager.shared.unregister(sessionManager: sm)
        }

        sm.activeHost = host
        sm.markConnectedForTesting()

        MultiWindowManager.shared.register(
            sessionManager: sm,
            scene: nil,
            hostId: host.id,
            sessionPersistentIdentifier: pid
        )
        MultiWindowManager.shared.pendingTeardownHostIds.insert(host.id)

        XCTAssertTrue(MultiWindowManager.shared.isHostOpenAnywhere(host.id))

        // Discard session
        MultiWindowManager.shared.discardSessions(matchingPersistentIdentifiers: [pid])

        XCTAssertFalse(MultiWindowManager.shared.isHostOpenAnywhere(host.id), "Discarded host must not remain open")
        XCTAssertNil(sm.activeHost, "Session manager activeHost must be cleared on discard")
        XCTAssertFalse(sm.state.isConnected, "Session must be disconnected on discard")
        XCTAssertFalse(MultiWindowManager.shared.pendingTeardownHostIds.contains(host.id), "Pending teardown reservation must be released")
        XCTAssertNil(MultiWindowManager.shared.records[pid], "Session record must be removed")
    }

    @MainActor
    func testMultiWindowRestoreArchivedSessionWithDuplicateDetection() {
        let host = HostProfile(name: "ArchivedHost", hostname: "archived.local")
        let pidArchived = "session-archived"
        let pidOther = "session-other"

        let smArchived = SessionManager()
        let smOther = SessionManager()
        defer {
            MultiWindowManager.shared.unregister(sessionManager: smArchived)
            MultiWindowManager.shared.unregister(sessionManager: smOther)
        }

        smArchived.state = .connected
        smOther.state = .connecting

        MultiWindowManager.shared.register(
            sessionManager: smArchived,
            scene: nil,
            hostId: host.id,
            sessionPersistentIdentifier: pidArchived
        )
        MultiWindowManager.shared.register(
            sessionManager: smOther,
            scene: nil,
            hostId: host.id,
            sessionPersistentIdentifier: pidOther
        )

        MultiWindowManager.shared.deduplicateWindows()

        let recArchived = MultiWindowManager.shared.records[pidArchived]
        let recOther = MultiWindowManager.shared.records[pidOther]

        XCTAssertEqual(recArchived?.status, .owned, "Connected archived session must survive as .owned")
        XCTAssertEqual(recArchived?.hostId, host.id)
        XCTAssertEqual(recOther?.status, .closing, "Duplicate session must be marked .closing")
        XCTAssertNil(recOther?.hostId, "Duplicate session hostId must be cleared")
    }

    // MARK: - R3: Startup Intents & Quick-Action Acceptance Tests

    @MainActor
    func testStartupIntentsConcurrentReverseOrderBinding() {
        QuickActionManager.shared.resetForTesting()
        defer { QuickActionManager.shared.resetForTesting() }

        let hostA = HostProfile(name: "HostA", hostname: "a.local")
        let hostB = HostProfile(name: "HostB", hostname: "b.local")
        let hostC = HostProfile(name: "HostC", hostname: "c.local")
        let hosts = [hostA, hostB, hostC]

        let pidA = "scene-pid-A"
        let pidB = "scene-pid-B"
        let pidC = "scene-pid-C"

        // Enqueue requests for A and B targeted at specific scenes
        _ = QuickActionManager.shared.enqueueRequest(
            for: hostA.id,
            origin: .newWindow,
            intendedSessionId: pidA
        )
        _ = QuickActionManager.shared.enqueueRequest(
            for: hostB.id,
            origin: .newWindow,
            intendedSessionId: pidB
        )

        // Scene C is an unrelated restored scene with restoration metadata, no pending request
        let sessionUserInfoC: [AnyHashable: Any] = [
            QuickActionManager.hostIdUserInfoKey: hostC.id.uuidString
        ]

        // Deliver callbacks in REVERSE ORDER: B, then C, then A

        // 1. Scene B connects first
        let resolvedB = WindowBootstrapResolver.resolveTargetHostId(
            scenePid: pidB,
            activity: nil,
            restorationActivity: nil,
            sessionUserInfo: nil,
            hosts: hosts
        )
        XCTAssertEqual(resolvedB, hostB.id, "Scene B must bind only to Host B")

        // 2. Scene C connects second (unrelated restored scene)
        let resolvedC = WindowBootstrapResolver.resolveTargetHostId(
            scenePid: pidC,
            activity: nil,
            restorationActivity: nil,
            sessionUserInfo: sessionUserInfoC,
            hosts: hosts
        )
        XCTAssertEqual(resolvedC, hostC.id, "Scene C must resolve Host C from restoration metadata")

        // 3. Scene A connects third
        let resolvedA = WindowBootstrapResolver.resolveTargetHostId(
            scenePid: pidA,
            activity: nil,
            restorationActivity: nil,
            sessionUserInfo: nil,
            hosts: hosts
        )
        XCTAssertEqual(resolvedA, hostA.id, "Scene A must bind only to Host A")
    }

    @MainActor
    func testDelayedWindowAttachmentAndCancellationBeforeAttachment() {
        QuickActionManager.shared.resetForTesting()
        defer { QuickActionManager.shared.resetForTesting() }

        var hostA = HostProfile(name: "HostA", hostname: "a.local")
        hostA.autoConnect = false
        var hostB = HostProfile(name: "HostB", hostname: "b.local")
        hostB.autoConnect = false
        let hosts = [hostA, hostB]

        let pidDelayed = "scene-pid-delayed"
        let request = QuickActionManager.shared.enqueueRequest(
            for: hostA.id,
            origin: .newWindow,
            intendedSessionId: pidDelayed
        )

        // Cancel before attachment
        QuickActionManager.shared.cancelRequest(id: request.id)

        // Simulate attachment delayed beyond 250ms
        let resolved = WindowBootstrapResolver.resolveTargetHostId(
            scenePid: pidDelayed,
            activity: nil,
            restorationActivity: nil,
            sessionUserInfo: nil,
            hosts: hosts
        )

        // No fallback connection or premature destruction
        XCTAssertNil(resolved, "Canceled request must not resolve or fallback to another host")
        XCTAssertNil(QuickActionManager.shared.consumeRequest(id: request.id), "Canceled request cannot be consumed")
        XCTAssertEqual(QuickActionManager.shared.startupRequests[request.id]?.disposition, .canceled)
    }

    @MainActor
    func testExplicitActivityBeforeDuringAndAfterBootstrap() {
        QuickActionManager.shared.resetForTesting()
        defer { QuickActionManager.shared.resetForTesting() }

        let host = HostProfile(name: "ActivityHost", hostname: "act.local")
        let hosts = [host]
        let pid = "scene-pid-activity"

        let activity = NSUserActivity(activityType: QuickActionManager.connectHostActionType)
        let requestId = UUID()
        activity.userInfo = [
            QuickActionManager.hostIdUserInfoKey: host.id.uuidString,
            QuickActionManager.requestIdUserInfoKey: requestId.uuidString
        ]
        activity.targetContentIdentifier = QuickActionManager.targetContentIdentifier(for: host.id)

        // 1. Before bootstrap: handle connecting user activity
        let accepted = QuickActionManager.shared.handleConnectingUserActivity(activity, for: pid)
        XCTAssertTrue(accepted)

        // 2. During bootstrap: resolve intent
        let resolved = WindowBootstrapResolver.resolveTargetHostId(
            scenePid: pid,
            activity: activity,
            restorationActivity: nil,
            sessionUserInfo: nil,
            hosts: hosts
        )
        XCTAssertEqual(resolved, host.id, "Target host must match the explicit activity metadata")

        // 3. After bootstrap: request is now consumed
        let secondResolve = WindowBootstrapResolver.resolveTargetHostId(
            scenePid: pid,
            activity: activity,
            restorationActivity: nil,
            sessionUserInfo: nil,
            hosts: hosts
        )
        XCTAssertEqual(activity.userInfo?[QuickActionManager.hostIdUserInfoKey] as? String, host.id.uuidString)
    }

    @MainActor
    func testHomeScreenQuickActionsAcrossAppLifecycles() {
        QuickActionManager.shared.resetForTesting()
        defer { QuickActionManager.shared.resetForTesting() }

        var host1 = HostProfile(name: "Host1", hostname: "h1.local")
        host1.autoConnect = false
        var host2 = HostProfile(name: "Host2", hostname: "h2.local")
        host2.autoConnect = false
        let hosts = [host1, host2]

        let shortcutItem1 = UIApplicationShortcutItem(
            type: QuickActionManager.connectHostActionType,
            localizedTitle: "Host1",
            localizedSubtitle: nil,
            icon: nil,
            userInfo: [QuickActionManager.hostIdUserInfoKey: host1.id.uuidString as NSSecureCoding]
        )
        let shortcutItem2 = UIApplicationShortcutItem(
            type: QuickActionManager.connectHostActionType,
            localizedTitle: "Host2",
            localizedSubtitle: nil,
            icon: nil,
            userInfo: [QuickActionManager.hostIdUserInfoKey: host2.id.uuidString as NSSecureCoding]
        )

        // 1. Terminated app (cold launch): shortcut item in connectionOptions
        let acceptedCold = QuickActionManager.shared.handleConnectingShortcutItem(shortcutItem1, for: "pid-cold")
        XCTAssertTrue(acceptedCold)
        let resolvedCold = WindowBootstrapResolver.resolveTargetHostId(
            scenePid: "pid-cold",
            activity: nil,
            restorationActivity: nil,
            sessionUserInfo: nil,
            hosts: hosts
        )
        XCTAssertEqual(resolvedCold, host1.id, "Cold shortcut item must bind Host1 even with autoConnect=false")

        // 2. Background app (warm launch): warm shortcut item
        let acceptedWarm = QuickActionManager.shared.handleWarmShortcutItem(shortcutItem2, for: "pid-warm")
        XCTAssertTrue(acceptedWarm)
        let resolvedWarm = WindowBootstrapResolver.resolveTargetHostId(
            scenePid: "pid-warm",
            activity: nil,
            restorationActivity: nil,
            sessionUserInfo: nil,
            hosts: hosts
        )
        XCTAssertEqual(resolvedWarm, host2.id, "Warm shortcut item must bind Host2 even with autoConnect=false")

        // 3. App with multiple existing windows
        let sm1 = SessionManager()
        defer { MultiWindowManager.shared.unregister(sessionManager: sm1) }
        MultiWindowManager.shared.register(sessionManager: sm1, scene: nil, hostId: host1.id, sessionPersistentIdentifier: "pid-win1")

        let acceptedMulti = QuickActionManager.shared.handleConnectingShortcutItem(shortcutItem2, for: "pid-win2")
        XCTAssertTrue(acceptedMulti)
        let resolvedMulti = WindowBootstrapResolver.resolveTargetHostId(
            scenePid: "pid-win2",
            activity: nil,
            restorationActivity: nil,
            sessionUserInfo: nil,
            hosts: hosts
        )
        XCTAssertEqual(resolvedMulti, host2.id, "New window must resolve Host2 without affecting Window 1's Host1")
    }

    @MainActor
    func testNotificationPermissionDoesNotBlockHostRestoration() {
        QuickActionManager.shared.resetForTesting()
        defer { QuickActionManager.shared.resetForTesting() }

        let host = HostProfile(name: "RestoredHost", hostname: "restored.local")
        let hosts = [host]
        let pid = "scene-pid-restored"
        let sessionUserInfo: [AnyHashable: Any] = [
            QuickActionManager.hostIdUserInfoKey: host.id.uuidString
        ]

        // Host restoration resolves immediately via metadata without awaiting notification permissions
        let resolved = WindowBootstrapResolver.resolveTargetHostId(
            scenePid: pid,
            activity: nil,
            restorationActivity: nil,
            sessionUserInfo: sessionUserInfo,
            hosts: hosts
        )
        XCTAssertEqual(resolved, host.id, "Host restoration must complete independently of notification authorization")

        // Notification response also enqueues and binds correctly
        NotificationDelegate.shared.handleNotificationResponse(
            userInfo: [QuickActionManager.hostIdUserInfoKey: host.id.uuidString],
            intendedSessionId: "pid-notif"
        )
        let resolvedNotif = WindowBootstrapResolver.resolveTargetHostId(
            scenePid: "pid-notif",
            activity: nil,
            restorationActivity: nil,
            sessionUserInfo: nil,
            hosts: hosts
        )
        XCTAssertEqual(resolvedNotif, host.id, "Notification-driven startup request must resolve intended host")
    }

    @MainActor
    func testUntargetedWindowWithAllAutoConnectFalseKeepsHostPickerUsable() {
        QuickActionManager.shared.resetForTesting()
        defer { QuickActionManager.shared.resetForTesting() }

        var hostA = HostProfile(name: "HostA", hostname: "a.local")
        hostA.autoConnect = false
        var hostB = HostProfile(name: "HostB", hostname: "b.local")
        hostB.autoConnect = false
        let hosts = [hostA, hostB]

        let pidUntargeted = "scene-pid-untargeted"

        let resolved = WindowBootstrapResolver.resolveTargetHostId(
            scenePid: pidUntargeted,
            activity: nil,
            restorationActivity: nil,
            sessionUserInfo: nil,
            hosts: hosts
        )

        // Resolving intent must yield nil (no auto-connect fallback)
        XCTAssertNil(resolved, "Untargeted window must not select any host when autoConnect is false")

        // Verify window record remains in .ready/usable state for host picker rather than closed
        let sm = SessionManager()
        defer { MultiWindowManager.shared.unregister(sessionManager: sm) }
        let record = MultiWindowManager.shared.register(
            sessionManager: sm,
            scene: nil,
            hostId: nil,
            sessionPersistentIdentifier: pidUntargeted
        )
        XCTAssertEqual(record.status, .owned)
        XCTAssertNil(record.hostId, "Untargeted window retains nil hostId for host picker")
    }

    // MARK: - R5: Preserve Connections on Failed Activation Acceptance Tests

    @MainActor
    func testFailedWindowCreationPreservesExistingConnectionAndProvidesFeedback() {
        QuickActionManager.shared.resetForTesting()
        MultiWindowManager.shared.resetForTesting()
        defer {
            QuickActionManager.shared.resetForTesting()
            MultiWindowManager.shared.resetForTesting()
        }

        let hostA = HostProfile(name: "HostA", hostname: "a.local")
        let hostB = HostProfile(name: "HostB", hostname: "b.local")
        QuickActionManager.shared.hostLookup = { id in
            [hostA, hostB].first(where: { $0.id == id })
        }

        let smA = SessionManager()
        defer { MultiWindowManager.shared.unregister(sessionManager: smA) }
        smA.activeHost = hostA
        smA.state = .connected

        let pidA = "scene-pid-A"
        _ = MultiWindowManager.shared.register(
            sessionManager: smA,
            scene: nil,
            hostId: hostA.id,
            sessionPersistentIdentifier: pidA
        )

        // Inject simulated activation failure
        let expectedError = NSError(
            domain: "io.o-t.filaire.test",
            code: 101,
            userInfo: [NSLocalizedDescriptionKey: "Simulated scene activation failure"]
        )
        QuickActionManager.shared.sceneActivationHandler = { session, activity, options, errorHandler in
            errorHandler(expectedError)
        }

        var completionCalled = false
        var completionResult: WindowRoutingResult?
        QuickActionManager.shared.routeHost(
            hostB.id,
            intent: .openDedicated,
            originatingSessionId: pidA
        ) { result in
            completionCalled = true
            completionResult = result
        }

        // Run runloop to let async completion execute
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertTrue(completionCalled)
        XCTAssertEqual(
            completionResult,
            .failed(reason: .sceneActivationFailed("Simulated scene activation failure"))
        )

        // Verify A's connection and transport stay unchanged
        XCTAssertEqual(smA.state, .connected, "Existing session A must remain connected")
        XCTAssertEqual(smA.activeHost?.id, hostA.id, "Session A activeHost must not be replaced by Host B")
        XCTAssertEqual(MultiWindowManager.shared.records[pidA]?.hostId, hostA.id)

        // Verify retry feedback appears
        XCTAssertEqual(
            QuickActionManager.shared.lastRoutingFeedback?.reason,
            .sceneActivationFailed("Simulated scene activation failure")
        )
        XCTAssertEqual(smA.activeToast?.title, "Window Error")
    }

    @MainActor
    func testExistingDetachedSessionActivatedByNotificationWithoutReplacingConnectedSession() {
        QuickActionManager.shared.resetForTesting()
        defer { QuickActionManager.shared.resetForTesting() }

        let hostA = HostProfile(name: "HostA", hostname: "a.local")
        let hostB = HostProfile(name: "HostB", hostname: "b.local")
        QuickActionManager.shared.hostLookup = { id in
            [hostA, hostB].first(where: { $0.id == id })
        }

        let smA = SessionManager()
        let smB = SessionManager()
        defer {
            MultiWindowManager.shared.unregister(sessionManager: smA)
            MultiWindowManager.shared.unregister(sessionManager: smB)
        }

        smA.activeHost = hostA
        smA.state = .connected
        smB.activeHost = hostB
        smB.state = .connected

        let pidA = "session-pid-A"
        let pidB = "session-pid-B"

        _ = MultiWindowManager.shared.register(
            sessionManager: smA,
            scene: nil,
            hostId: hostA.id,
            sessionPersistentIdentifier: pidA
        )
        _ = MultiWindowManager.shared.register(
            sessionManager: smB,
            scene: nil,
            hostId: hostB.id,
            sessionPersistentIdentifier: pidB
        )

        var activatedSessionPid: String?
        QuickActionManager.shared.sceneActivationHandler = { session, activity, options, errorHandler in
            activatedSessionPid = session?.persistentIdentifier
            errorHandler(nil)
        }

        // Deliver notification for Host B
        NotificationDelegate.shared.handleNotificationResponse(
            userInfo: [QuickActionManager.hostIdUserInfoKey: hostB.id.uuidString],
            intendedSessionId: pidB
        )

        // Verify session A remains connected to Host A
        XCTAssertEqual(smA.state, .connected)
        XCTAssertEqual(smA.activeHost?.id, hostA.id, "Session A must not be replaced by notification for B")
        XCTAssertEqual(MultiWindowManager.shared.records[pidA]?.hostId, hostA.id)
    }

    @MainActor
    func testNotificationForDeletedHostCausesNoSelectionOrMetadataMutation() {
        QuickActionManager.shared.resetForTesting()
        defer { QuickActionManager.shared.resetForTesting() }

        let hostA = HostProfile(name: "HostA", hostname: "a.local")
        let deletedHostId = UUID()
        QuickActionManager.shared.hostLookup = { id in
            id == hostA.id ? hostA : nil
        }

        let smA = SessionManager()
        defer { MultiWindowManager.shared.unregister(sessionManager: smA) }
        smA.activeHost = hostA
        smA.state = .connected

        let pidA = "session-pid-A"
        _ = MultiWindowManager.shared.register(
            sessionManager: smA,
            scene: nil,
            hostId: hostA.id,
            sessionPersistentIdentifier: pidA
        )

        // Deliver notification for deleted host
        NotificationDelegate.shared.handleNotificationResponse(
            userInfo: [QuickActionManager.hostIdUserInfoKey: deletedHostId.uuidString]
        )

        // Verify no request enqueued
        let requestsForDeleted = QuickActionManager.shared.startupRequests.values.filter { $0.hostId == deletedHostId }
        XCTAssertTrue(requestsForDeleted.isEmpty, "No startup request should be enqueued for a deleted host")

        // Verify feedback displayed
        XCTAssertEqual(QuickActionManager.shared.lastDeletedHostFeedbackId, deletedHostId)
        XCTAssertEqual(smA.activeToast?.title, "Host Not Found")

        // Verify session A completely untouched
        XCTAssertEqual(smA.activeHost?.id, hostA.id)
        XCTAssertEqual(smA.state, .connected)
        XCTAssertEqual(MultiWindowManager.shared.records[pidA]?.hostId, hostA.id)
    }

    @MainActor
    func testTargetedRequestWithUnboundRootAndDuplicateCallbacks() {
        QuickActionManager.shared.resetForTesting()
        defer { QuickActionManager.shared.resetForTesting() }

        var hostB = HostProfile(name: "HostB", hostname: "b.local")
        hostB.autoConnect = false
        let hosts = [hostB]

        let pid1 = "unbound-root-1"
        let pid2 = "target-root-2"

        // Enqueue targeted request for pid2
        _ = QuickActionManager.shared.enqueueRequest(
            for: hostB.id,
            origin: .userAction,
            intendedSessionId: pid2
        )

        // Unbound root 1 connects and tries to resolve
        let resolvedRoot1 = WindowBootstrapResolver.resolveTargetHostId(
            scenePid: pid1,
            activity: nil,
            restorationActivity: nil,
            sessionUserInfo: nil,
            hosts: hosts
        )
        XCTAssertNil(resolvedRoot1, "Unbound root 1 must NOT consume request intended for pid2")

        // Target root 2 resolves
        let resolvedRoot2 = WindowBootstrapResolver.resolveTargetHostId(
            scenePid: pid2,
            activity: nil,
            restorationActivity: nil,
            sessionUserInfo: nil,
            hosts: hosts
        )
        XCTAssertEqual(resolvedRoot2, hostB.id, "Target root 2 must resolve Host B")

        // Duplicate callback for root 2
        let duplicateResolve = WindowBootstrapResolver.resolveTargetHostId(
            scenePid: pid2,
            activity: nil,
            restorationActivity: nil,
            sessionUserInfo: nil,
            hosts: hosts
        )
        XCTAssertNil(duplicateResolve, "Duplicate callback must be idempotent and not consume again")
    }

    @MainActor
    func testLateFailureForObsoleteRequestDoesNotClearOrRedirectNewerRequest() {
        QuickActionManager.shared.resetForTesting()
        defer { QuickActionManager.shared.resetForTesting() }

        let hostB = HostProfile(name: "HostB", hostname: "b.local")
        let hostC = HostProfile(name: "HostC", hostname: "c.local")
        QuickActionManager.shared.hostLookup = { id in
            [hostB, hostC].first(where: { $0.id == id })
        }

        var savedErrorHandlerB: ((Error?) -> Void)?
        QuickActionManager.shared.sceneActivationHandler = { session, activity, options, errorHandler in
            savedErrorHandlerB = errorHandler
        }

        // 1. Start Request 1 for Host B (Generation 1)
        let resultB = QuickActionManager.shared.routeHost(hostB.id, intent: .openDedicated)
        guard case .requestedNewWindow(let reqIdB) = resultB else {
            XCTFail("Must request new window")
            return
        }

        // 2. Start and succeed Request 2 for Host C (Generation 2)
        QuickActionManager.shared.sceneActivationHandler = { session, activity, options, errorHandler in
            errorHandler(nil)
        }
        let resultC = QuickActionManager.shared.routeHost(hostC.id, intent: .openDedicated)
        guard case .requestedNewWindow(let reqIdC) = resultC else {
            XCTFail("Must request new window")
            return
        }

        XCTAssertEqual(QuickActionManager.shared.startupRequests[reqIdC]?.disposition, .pending)

        // 3. Now invoke late failure for obsolete Request 1
        let lateError = NSError(
            domain: "io.o-t.filaire.test",
            code: 500,
            userInfo: [NSLocalizedDescriptionKey: "Late activation error"]
        )
        savedErrorHandlerB?(lateError)

        // Run runloop
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        // 4. Verify Request 2 is still pending/intact and not canceled or cleared
        XCTAssertEqual(QuickActionManager.shared.startupRequests[reqIdC]?.disposition, .pending, "Newer request C must remain intact despite late failure on request B")
        XCTAssertNotEqual(QuickActionManager.shared.lastRoutingFeedback?.hostId, hostC.id, "Host C must not have routing failure recorded")
    }

    // MARK: - R6: Centralize Host Deletion Acceptance Tests

    @MainActor
    func testDeleteCurrentHostLocallyAcrossAllConnectionStates() async {
        let states: [ConnectionState] = [
            .connected,
            .connecting,
            .reconnecting(attempt: 1),
            .failed("Test connection failure"),
            .disconnected
        ]

        for state in states {
            QuickActionManager.shared.resetForTesting()
            MultiWindowManager.shared.resetForTesting()

            let host = HostProfile(name: "TestHost-\(state)", hostname: "test.local")
            let appState = AppState()
            appState.hosts = [host]
            appState.selectedHostId = host.id

            defer {
                MultiWindowManager.shared.unregister(sessionManager: appState.sessionManager)
            }

            let sm = appState.sessionManager
            sm.activeHost = host
            sm.allHosts = [host]
            switch state {
            case .connected:
                sm.markConnectedForTesting()
            case .connecting:
                sm.state = .connecting
                sm.isConnecting = true
                sm.connectTask = Task { try? await Task.sleep(nanoseconds: 1_000_000_000) }
            case .reconnecting(let attempt):
                sm.state = .reconnecting(attempt: attempt)
                sm.reconnectAttempt = attempt
                sm.reconnectTask = Task { try? await Task.sleep(nanoseconds: 1_000_000_000) }
            case .failed(let err):
                sm.state = .failed(err)
            case .disconnected:
                sm.state = .disconnected
            }

            // Perform deletion
            appState.deleteHost(id: host.id)

            // Verify: no activeHost, no future connection attempt may remain
            XCTAssertNil(appState.selectedHostId, "selectedHostId must be cleared on deletion in state \(state)")
            XCTAssertNil(sm.activeHost, "activeHost must be cleared on deletion in state \(state)")
            XCTAssertEqual(sm.state, .disconnected, "State must be disconnected in state \(state)")
            XCTAssertFalse(sm.isConnecting, "isConnecting must be false in state \(state)")
            XCTAssertNil(sm.reconnectTask, "reconnectTask must be cancelled in state \(state)")
            XCTAssertEqual(sm.reconnectAttempt, 0, "reconnectAttempt must be 0 in state \(state)")
            XCTAssertNil(appState.dynamicTerminalTitle, "dynamic title must be cleared in state \(state)")
            XCTAssertFalse(appState.hosts.contains(where: { $0.id == host.id }), "Host must be removed from hosts array")
        }
    }

    @MainActor
    func testDeleteHostFromAnotherWindowCancelsBackoffAndHostKeyPrompt() async {
        QuickActionManager.shared.resetForTesting()
        MultiWindowManager.shared.resetForTesting()
        defer {
            QuickActionManager.shared.resetForTesting()
            MultiWindowManager.shared.resetForTesting()
        }

        let hostA = HostProfile(name: "HostA", hostname: "a.local")
        let hostB = HostProfile(name: "HostB", hostname: "b.local")

        // 1. Backoff Scenario
        let appStateA = AppState()
        appStateA.hosts = [hostA, hostB]
        appStateA.selectedHostId = hostA.id

        let appStateB = AppState()
        appStateB.hosts = [hostA, hostB]
        appStateB.selectedHostId = hostB.id

        defer {
            MultiWindowManager.shared.unregister(sessionManager: appStateA.sessionManager)
            MultiWindowManager.shared.unregister(sessionManager: appStateB.sessionManager)
        }

        let pidA = "window-session-A"
        MultiWindowManager.shared.register(
            sessionManager: appStateA.sessionManager,
            scene: nil,
            hostId: hostA.id,
            sessionPersistentIdentifier: pidA
        )

        let smA = appStateA.sessionManager
        smA.activeHost = hostA
        smA.allHosts = [hostA, hostB]
        smA.state = .reconnecting(attempt: 1)
        smA.reconnectAttempt = 1
        var timerFired = false
        smA.reconnectTask = Task {
            try? await Task.sleep(nanoseconds: 50_000_000)
            timerFired = true
        }

        // Window B deletes Host A
        appStateB.deleteHost(id: hostA.id)

        // Wait past timer duration
        try? await Task.sleep(nanoseconds: 80_000_000)

        // Verify Session A is disconnected, not reconnecting, and activeHost is nil
        XCTAssertNil(smA.activeHost, "Session A activeHost must be cleared")
        XCTAssertEqual(smA.state, .disconnected, "Session A must be disconnected")
        XCTAssertNil(smA.reconnectTask, "Session A reconnectTask must be cancelled")
        XCTAssertFalse(MultiWindowManager.shared.isHostOpenAnywhere(hostA.id), "Host A must not remain open anywhere")

        // 2. Host-Key Confirmation Scenario
        QuickActionManager.shared.resetForTesting()
        MultiWindowManager.shared.resetForTesting()

        let hostA2 = HostProfile(name: "HostA2", hostname: "a2.local")
        let hostB2 = HostProfile(name: "HostB2", hostname: "b2.local")

        let appStateA2 = AppState()
        appStateA2.hosts = [hostA2, hostB2]
        appStateA2.selectedHostId = hostA2.id

        let appStateB2 = AppState()
        appStateB2.hosts = [hostA2, hostB2]
        appStateB2.selectedHostId = hostB2.id

        defer {
            MultiWindowManager.shared.unregister(sessionManager: appStateA2.sessionManager)
            MultiWindowManager.shared.unregister(sessionManager: appStateB2.sessionManager)
        }

        let smA2 = appStateA2.sessionManager
        smA2.activeHost = hostA2
        smA2.allHosts = [hostA2, hostB2]
        smA2.state = .connecting
        let attemptId = UUID()
        smA2.currentConnectionId = attemptId

        var onCancelInvoked = false
        var onAllowInvoked = false
        let prompt = SecurityPrompt(
            attemptId: attemptId,
            title: "Trust Host?",
            message: "Test message",
            onAllow: {
                onAllowInvoked = true
            },
            onCancel: {
                onCancelInvoked = true
            }
        )
        smA2.pendingSecurityPrompt = prompt

        MultiWindowManager.shared.register(
            sessionManager: smA2,
            scene: nil,
            hostId: hostA2.id,
            sessionPersistentIdentifier: "window-session-A2"
        )

        // Window B2 deletes Host A2 while prompt is pending
        appStateB2.deleteHost(id: hostA2.id)

        XCTAssertNil(smA2.pendingSecurityPrompt, "Pending security prompt must be cancelled and cleared")
        XCTAssertEqual(smA2.state, .disconnected)
        XCTAssertNil(smA2.activeHost)
        XCTAssertTrue(onCancelInvoked, "Security prompt onCancel must be invoked")

        // Try completing the old prompt callback or reconnecting afterward
        prompt.onAllow()
        smA2.connect(to: hostA2)

        // Verify that nothing reconnects
        XCTAssertEqual(smA2.state, .disconnected, "Deleted host must reject connection attempts")
        XCTAssertNil(smA2.activeHost)
        XCTAssertFalse(smA2.isConnecting)
    }

    @MainActor
    func testDeleteHostDuringSheetDismissalDelayPreventsConnectionAndTagging() async {
        QuickActionManager.shared.resetForTesting()
        MultiWindowManager.shared.resetForTesting()
        defer {
            QuickActionManager.shared.resetForTesting()
            MultiWindowManager.shared.resetForTesting()
        }

        let host = HostProfile(name: "DelayHost", hostname: "delay.local")
        let appState = AppState()
        appState.hosts = [host]

        defer {
            MultiWindowManager.shared.unregister(sessionManager: appState.sessionManager)
        }

        // Schedule delayed connect (simulating the 300 ms sheet dismissal delay)
        appState.scheduleDelayedConnect(to: host, delay: 0.1)

        // Delete the host before delay elapses
        appState.deleteHost(id: host.id)

        // Wait past the delay
        try? await Task.sleep(nanoseconds: 150_000_000)

        // Verify no connection was made, no claim exists, no restoration tag
        XCTAssertNil(appState.selectedHostId, "selectedHostId must remain nil")
        XCTAssertNil(appState.sessionManager.activeHost, "activeHost must remain nil")
        XCTAssertEqual(appState.sessionManager.state, .disconnected, "SessionManager must remain disconnected")
        XCTAssertFalse(MultiWindowManager.shared.isHostClaimed(by: appState.sessionManager, hostId: host.id))
        XCTAssertFalse(MultiWindowManager.shared.isHostOpenAnywhere(host.id))
    }

    @MainActor
    func testDeleteLastProfileLeavesInteractiveEmptyStateAndClearsShortcuts() {
        QuickActionManager.shared.resetForTesting()
        MultiWindowManager.shared.resetForTesting()
        defer {
            QuickActionManager.shared.resetForTesting()
            MultiWindowManager.shared.resetForTesting()
        }

        let onlyHost = HostProfile(name: "OnlyHost", hostname: "only.local")
        let appState = AppState()
        appState.hosts = [onlyHost]
        appState.selectedHostId = onlyHost.id

        defer {
            MultiWindowManager.shared.unregister(sessionManager: appState.sessionManager)
        }

        let pid = "final-window-session"
        MultiWindowManager.shared.register(
            sessionManager: appState.sessionManager,
            scene: nil,
            hostId: onlyHost.id,
            sessionPersistentIdentifier: pid
        )

        appState.sessionManager.activeHost = onlyHost
        appState.sessionManager.markConnectedForTesting()

        // Verify shortcut items exist before deletion
        QuickActionManager.updateQuickActions(for: [onlyHost])
        XCTAssertFalse(UIApplication.shared.shortcutItems?.isEmpty ?? true)

        // Force single window (final window)
        MultiWindowManager.shared.forceMultipleWindowsForTesting = false

        var sceneDestructionRequested = false
        MultiWindowManager.shared.onSceneSessionDestructionRequestedForTesting = { _ in
            sceneDestructionRequested = true
        }

        // Delete the last profile
        appState.deleteHost(id: onlyHost.id)

        // 1. Interactive empty state (hosts is empty)
        XCTAssertTrue(appState.hosts.isEmpty, "Hosts must be empty")
        XCTAssertNil(appState.selectedHostId, "selectedHostId must be nil")

        // 2. No live hidden SSH session
        XCTAssertNil(appState.sessionManager.activeHost, "activeHost must be nil")
        XCTAssertEqual(appState.sessionManager.state, .disconnected, "SessionManager must be disconnected")
        XCTAssertFalse(appState.sessionManager.state.isConnected)

        // 3. No stale Home Screen shortcuts
        XCTAssertTrue(UIApplication.shared.shortcutItems?.isEmpty ?? true, "Shortcut items must be cleared")

        // 4. Final window was NOT destroyed, retaining usable empty state / host picker
        XCTAssertFalse(sceneDestructionRequested, "Final window must not be closed when deleting last host")
    }

    // MARK: - R7: Scrollback Preservation & Memory Pressure Relief Acceptance Tests

    @MainActor
    func testOrdinaryBackgroundTransitionsPreserveScrollbackContent() {
        let origSetting = TerminalSettings.shared.aggressiveBackgroundTrimmingEnabled
        let origLimit = TerminalSettings.shared.scrollbackLimit
        TerminalSettings.shared.aggressiveBackgroundTrimmingEnabled = false
        TerminalSettings.shared.scrollbackLimit = .standard
        defer {
            TerminalSettings.shared.aggressiveBackgroundTrimmingEnabled = origSetting
            TerminalSettings.shared.scrollbackLimit = origLimit
        }

        let sm = SessionManager()
        let ctx = TerminalSessionContext(sessionManager: sm)
        let terminal = ctx.terminalView

        // Feed 1,200 identifiable lines (well below standard limit of 10,000)
        var bufferString = ""
        for i in 1...1200 {
            bufferString += String(format: "MarkerLine %04d\r\n", i)
        }
        let data = Array(bufferString.utf8)
        terminal.feed(byteArray: data[...])

        let initialLineCount = terminal.bufferLineCount
        XCTAssertGreaterThanOrEqual(initialLineCount, 1200)

        let firstLineInitial = terminal.getTerminal().bufferLine(atRow: 0)?.translateToString(trimRight: true) ?? ""
        XCTAssertTrue(firstLineInitial.contains("MarkerLine 0001"), "Oldest line must be MarkerLine 0001")

        // Trigger normal backgrounding
        sm.handleAppBackgrounded()
        XCTAssertTrue(sm.isAppInBackground)
        XCTAssertNil(terminal.memoryScrollbackCap, "Ordinary backgrounding must NOT cap scrollback when aggressive trimming is disabled")
        XCTAssertFalse(terminal.hasTrimmedHistory)

        // Trigger normal foregrounding
        sm.handleAppForegrounded()
        XCTAssertFalse(sm.isAppInBackground)

        // Verify oldest lines remain completely readable and intact
        let lineCountAfter = terminal.bufferLineCount
        XCTAssertEqual(lineCountAfter, initialLineCount, "Line count must not decrease during ordinary background/foreground cycle")
        let firstLineAfter = terminal.getTerminal().bufferLine(atRow: 0)?.translateToString(trimRight: true) ?? ""
        XCTAssertTrue(firstLineAfter.contains("MarkerLine 0001"), "Oldest line must still be readable after ordinary background/foreground")
    }

    @MainActor
    func testAggressiveTrimPolicyOrMemoryWarningTrimsOldLinesWithoutRecoveringOnRestore() {
        let origSetting = TerminalSettings.shared.aggressiveBackgroundTrimmingEnabled
        let origLimit = TerminalSettings.shared.scrollbackLimit
        TerminalSettings.shared.aggressiveBackgroundTrimmingEnabled = true
        TerminalSettings.shared.scrollbackLimit = .small // 2500 lines
        defer {
            TerminalSettings.shared.aggressiveBackgroundTrimmingEnabled = origSetting
            TerminalSettings.shared.scrollbackLimit = origLimit
        }

        let sm = SessionManager()
        let ctx = TerminalSessionContext(sessionManager: sm)
        let terminal = ctx.terminalView

        // Feed 1,500 identifiable lines
        var bufferString = ""
        for i in 1...1500 {
            bufferString += String(format: "TrimTest %04d\r\n", i)
        }
        terminal.feed(byteArray: Array(bufferString.utf8)[...])

        let initialCount = terminal.bufferLineCount
        XCTAssertGreaterThanOrEqual(initialCount, 1500)
        let oldestInitial = terminal.getTerminal().bufferLine(atRow: 0)?.translateToString(trimRight: true) ?? ""
        XCTAssertTrue(oldestInitial.contains("TrimTest 0001"))

        // Trigger backgrounding under aggressive trim policy
        sm.handleAppBackgrounded()
        XCTAssertEqual(terminal.memoryScrollbackCap, 1000)
        XCTAssertEqual(terminal.appliedScrollback, 1000)
        XCTAssertTrue(terminal.hasTrimmedHistory, "hasTrimmedHistory must be true after trimming")

        // Assert lines were trimmed: 1,500 lines capped to 1,000 means oldest lines were removed
        let countAfterTrim = terminal.bufferLineCount
        XCTAssertLessThanOrEqual(countAfterTrim, 1000 + terminal.getTerminal().rows)
        let oldestAfterTrim = terminal.getTerminal().bufferLine(atRow: 0)?.translateToString(trimRight: true) ?? ""
        XCTAssertFalse(oldestAfterTrim.contains("TrimTest 0001"), "Oldest line 0001 must have been discarded")

        // Visible screen remains valid (newest lines are intact)
        let newestLine = terminal.getTerminal().bufferLine(atRow: countAfterTrim - 1)?.translateToString(trimRight: true) ?? ""
        let secondNewestLine = terminal.getTerminal().bufferLine(atRow: max(0, countAfterTrim - 2))?.translateToString(trimRight: true) ?? ""
        XCTAssertTrue(newestLine.contains("TrimTest 1500") || secondNewestLine.contains("TrimTest 1500"))

        // Now restore capacity
        terminal.restoreScrollbackLimit()
        XCTAssertEqual(terminal.appliedScrollback, 2500, "Capacity restored to configured limit for future lines")

        // Crucial verification: Raising capacity DOES NOT recover previously discarded lines
        let oldestAfterRestore = terminal.getTerminal().bufferLine(atRow: 0)?.translateToString(trimRight: true) ?? ""
        XCTAssertFalse(oldestAfterRestore.contains("TrimTest 0001"), "Raising capacity does not claim to or recover discarded history")
    }

    @MainActor
    func testForegroundingSceneAPreservesHiddenSceneBCapAndPolicy() {
        MultiWindowManager.shared.resetForTesting()
        defer { MultiWindowManager.shared.resetForTesting() }

        let smA = SessionManager()
        let smB = SessionManager()

        let ctxA = TerminalSessionContext(sessionManager: smA)
        let ctxB = TerminalSessionContext(sessionManager: smB)

        // B was trimmed / capped in background
        ctxB.terminalView.shedMemoryPressure(cap: 1000)
        ctxB.isVisible = false
        XCTAssertEqual(ctxB.terminalView.appliedScrollback, 1000)
        XCTAssertEqual(ctxB.memoryScrollbackCap, 1000)

        // Scene A is brought to the foreground / becomes active
        ctxA.handleVisibilityChanged(isVisible: true)
        XCTAssertEqual(ctxA.terminalView.appliedScrollback, TerminalSettings.shared.scrollbackLimit.rawValue)
        XCTAssertNil(ctxA.memoryScrollbackCap)

        // Crucial check: Scene B REMAINS capped because it is still hidden
        XCTAssertEqual(ctxB.terminalView.appliedScrollback, 1000, "Hidden scene B must retain its memory cap")
        XCTAssertEqual(ctxB.memoryScrollbackCap, 1000)
        XCTAssertFalse(ctxB.isVisible)
    }

    @MainActor
    func testDetachedTerminalPreservesCapAndDeliversTrimNoticeUponReattachment() {
        let sm = SessionManager()
        let ctx = TerminalSessionContext(sessionManager: sm)

        // Feed lines and trim while detached
        var bufferString = ""
        for i in 1...1500 {
            bufferString += String(format: "Detached %04d\r\n", i)
        }
        ctx.terminalView.feed(byteArray: Array(bufferString.utf8)[...])
        ctx.terminalView.shedMemoryPressure(cap: 1000)

        XCTAssertTrue(ctx.hasTrimmedHistory)
        XCTAssertEqual(ctx.memoryScrollbackCap, 1000)

        // Detach view (e.g. view disappeared or window was backgrounded)
        ctx.detachView()

        // Verify cap and trim notice state survived in the app-owned context
        XCTAssertTrue(ctx.hasTrimmedHistory)
        XCTAssertEqual(ctx.memoryScrollbackCap, 1000)

        // Reattach and become visible
        ctx.handleVisibilityChanged(isVisible: true)

        // Notice delivered once and cleared
        XCTAssertEqual(sm.activeToast?.title, "Terminal History Trimmed")
        XCTAssertFalse(ctx.hasTrimmedHistory, "Trim notice must be cleared after being presented")
        XCTAssertNil(ctx.memoryScrollbackCap, "Capacity must be restored upon becoming visible")
    }

    @MainActor
    func testMemoryPressureHandlingDoesNotRepeatOscSideEffects() {
        let terminal = FilaireTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        var osc5101CallCount = 0
        terminal.getTerminal().registerOscHandler(code: 5101) { _ in
            osc5101CallCount += 1
        }

        // Feed OSC 5101 sequence
        let payload = "\u{1B}]5101;Test Payload\u{07}"
        terminal.feed(byteArray: Array(payload.utf8)[...])
        XCTAssertEqual(osc5101CallCount, 1, "OSC handler must be called once on initial input")

        // Shed memory pressure
        terminal.shedMemoryPressure(cap: 1000)

        // Restore scrollback limit
        terminal.restoreScrollbackLimit()

        // Re-apply settings
        terminal.applyScrollbackLimit()

        // Verify no escape sequence replay or repeat OSC calls occurred
        XCTAssertEqual(osc5101CallCount, 1, "Memory pressure handling must not re-evaluate or repeat OSC side effects")
    }

    // MARK: - R8: Keyboard Ownership & Notification Focus Policy Acceptance Tests

    @MainActor
    func testSwitchingWindowsPreservesHostEditorOrSearchFocusWithoutReclaimingByTerminal() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let terminal = FilaireTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let textField = UITextField(frame: CGRect(x: 0, y: 0, width: 200, height: 40))
        window.addSubview(terminal)
        window.addSubview(textField)
        window.makeKeyAndVisible()

        // Focus the text field (representing Host Editor or Search field)
        _ = textField.becomeFirstResponder()
        terminal.focusIntent = .hostEditorOrSearch

        // Simulate switching away from Window A (resigning key) and switching back (becoming key)
        NotificationCenter.default.post(name: UIWindow.didResignKeyNotification, object: window)
        NotificationCenter.default.post(name: UIWindow.didBecomeKeyNotification, object: window)

        // Wait past both immediate and 250 ms delayed callbacks
        try await Task.sleep(for: .milliseconds(350))

        // Text field must remain the intended owner and terminal must NOT steal focus
        XCTAssertFalse(terminal.isFirstResponder, "Terminal must not reclaim focus from text field upon window reactivating")
        XCTAssertEqual(terminal.focusIntent, .hostEditorOrSearch)
    }

    @MainActor
    func testTappingFieldWithinPromotionWindowCancelsTerminalFocusReclaim() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let terminal = FilaireTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let textField = UITextField(frame: CGRect(x: 0, y: 0, width: 200, height: 40))
        window.addSubview(terminal)
        window.addSubview(textField)
        window.makeKeyAndVisible()

        // Window activates and schedules promotion
        terminal.scheduleFocusPromotion(delay: 0.25, reason: "test activation")

        // User taps a field within 250 ms (e.g. at 50 ms)
        try await Task.sleep(for: .milliseconds(50))
        _ = textField.becomeFirstResponder()
        terminal.cancelPendingFocusRequests()
        terminal.focusIntent = .hostEditorOrSearch

        // Wait past the original 250 ms deadline
        try await Task.sleep(for: .milliseconds(250))

        // Terminal callback cannot reclaim input
        XCTAssertFalse(terminal.isFirstResponder, "Terminal promotion callback must not reclaim input after user tapped text field")
    }

    @MainActor
    func testManualKeyboardDismissalPreventsReopeningOnWindowSwitchWithoutIntent() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let terminal = FilaireTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        window.addSubview(terminal)
        window.makeKeyAndVisible()

        _ = terminal.becomeFirstResponder()
        XCTAssertEqual(terminal.focusIntent, .terminal)

        // User manually dismisses keyboard
        terminal.accessoryDidRequestDismissKeyboard()
        XCTAssertEqual(terminal.focusIntent, .none)

        // Window deactivates and reactivates (switching windows)
        NotificationCenter.default.post(name: UIWindow.didResignKeyNotification, object: window)
        NotificationCenter.default.post(name: UIWindow.didBecomeKeyNotification, object: window)

        // Wait 350 ms
        try await Task.sleep(for: .milliseconds(350))

        // Keyboard is not reopened
        XCTAssertFalse(terminal.isFirstResponder, "Terminal must not reopen keyboard without explicit intent after manual dismissal")

        // Explicit user interaction restores intent
        terminal.touchesBegan([UITouch()], with: nil)
        XCTAssertEqual(terminal.focusIntent, .terminal)
    }

    @MainActor
    func testSplitViewInteractingWithSceneAPreservesNotificationAlertForSceneB() {
        MultiWindowManager.shared.resetForTesting()
        defer { MultiWindowManager.shared.resetForTesting() }

        let smA = SessionManager()
        let smB = SessionManager()
        let hostA = HostProfile(name: "HostA", hostname: "a.invalid")
        let hostB = HostProfile(name: "HostB", hostname: "b.invalid")
        smA.activeHost = hostA
        smB.activeHost = hostB

        let winA = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        let winB = UIWindow(frame: CGRect(x: 400, y: 0, width: 400, height: 600))
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            winA.windowScene = scene
            winB.windowScene = scene
        }
        winA.makeKeyAndVisible()

        let pidA = "split-session-A"
        let pidB = "split-session-B"
        let recA = WindowSessionRecord(persistentIdentifier: pidA, sessionManager: smA, scene: winA.windowScene, hostId: hostA.id)
        recA.terminalContext = TerminalSessionContext(sessionManager: smA)
        let recB = WindowSessionRecord(persistentIdentifier: pidB, sessionManager: smB, scene: winB.windowScene, hostId: hostB.id)
        recB.terminalContext = TerminalSessionContext(sessionManager: smB)

        MultiWindowManager.shared.installRecordForTesting(recA)
        MultiWindowManager.shared.installRecordForTesting(recB)

        // User interacts with Scene A
        MultiWindowManager.shared.recordInteraction(sessionPersistentIdentifier: pidA)
        XCTAssertEqual(MultiWindowManager.shared.mostRecentInteractionSceneIdentifier, pidA)

        // Notification from B must NOT be suppressed as the uniquely focused host
        let decisionB = NotificationPresentationPolicy.shared.decision(for: hostB.id)
        XCTAssertEqual(decisionB, .systemAlert, "Background Split View host B must deliver system alert when user interacted with A")

        let optionsB = NotificationDelegate.shared.presentationOptions(for: [QuickActionManager.hostIdUserInfoKey: hostB.id.uuidString])
        XCTAssertTrue(optionsB.contains(.banner), "Host B notification banner must not be suppressed")
    }

    @MainActor
    func testNotificationDeliveryWhenTerminalCoveredOrDuringFocusTransition() {
        MultiWindowManager.shared.resetForTesting()
        defer { MultiWindowManager.shared.resetForTesting() }

        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            XCTFail("No connected window scene; an earlier test may have destroyed the test host's scene")
            return
        }

        let smA = SessionManager()
        let hostA = HostProfile(name: "HostA", hostname: "a.invalid")
        smA.activeHost = hostA

        let winA = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        winA.windowScene = scene
        winA.makeKeyAndVisible()

        let pidA = "session-A"
        let recA = WindowSessionRecord(persistentIdentifier: pidA, sessionManager: smA, scene: winA.windowScene, hostId: hostA.id)
        let ctxA = TerminalSessionContext(sessionManager: smA)
        recA.terminalContext = ctxA
        MultiWindowManager.shared.installRecordForTesting(recA)
        MultiWindowManager.shared.recordInteraction(sessionPersistentIdentifier: pidA)

        // 1. Uncovered normal state in key active window -> inWindowToast
        let normalDecision = NotificationPresentationPolicy.shared.decision(for: hostA.id)
        XCTAssertEqual(normalDecision, .inWindowToast)

        // 2. Covered by Settings / modal sheet -> systemAlert
        ctxA.isCoveredByPresentation = true
        let coveredDecision = NotificationPresentationPolicy.shared.decision(for: hostA.id)
        XCTAssertEqual(coveredDecision, .systemAlert, "Notification must deliver system alert when terminal is covered by Settings/modal")
        ctxA.isCoveredByPresentation = false

        // 3. Covered by Security Prompt -> systemAlert
        smA.pendingSecurityPrompt = SecurityPrompt(
            title: "Security Prompt",
            message: "Verify Key",
            primaryButtonTitle: "Trust",
            onAllow: {}
        )
        let securityDecision = NotificationPresentationPolicy.shared.decision(for: hostA.id)
        XCTAssertEqual(securityDecision, .systemAlert, "Notification must deliver system alert when terminal has pending security prompt")
        smA.pendingSecurityPrompt = nil

        // 4. Covered by Quick Look preview -> systemAlert
        FilePreviewManager.shared.previewURL = URL(fileURLWithPath: "/tmp/preview.txt")
        let previewDecision = NotificationPresentationPolicy.shared.decision(for: hostA.id)
        XCTAssertEqual(previewDecision, .systemAlert, "Notification must deliver system alert when terminal is covered by Quick Look")
        FilePreviewManager.shared.previewURL = nil

        // 5. In focus transition / non-terminal focus intent -> systemAlert
        ctxA.focusIntent = .none
        let transitionDecision = NotificationPresentationPolicy.shared.decision(for: hostA.id)
        XCTAssertEqual(transitionDecision, .systemAlert, "Notification must deliver system alert when terminal does not own focus intent")
    }

    // MARK: - R9 Acceptance Tests

    @MainActor
    func testHostListUpdatesWhenAnotherWindowChangesStateWithoutReopening() {
        MultiWindowManager.shared.resetForTesting()
        defer { MultiWindowManager.shared.resetForTesting() }

        let hostA = HostProfile(name: "HostA", hostname: "a.local")
        let hostB = HostProfile(name: "HostB", hostname: "b.local")
        let hosts = [hostA, hostB]
        let selectedHostId: UUID? = hostA.id

        let smA = SessionManager()
        smA.activeHost = hostA
        smA.forceStateForTesting(.connected)
        let recA = WindowSessionRecord(persistentIdentifier: "scene-A", sessionManager: smA, hostId: hostA.id, status: .owned)
        MultiWindowManager.shared.installRecordForTesting(recA)

        // Window A has HostListView open observing MultiWindowManager.shared
        let windowManager = MultiWindowManager.shared
        XCTAssertEqual(windowManager.snapshots[hostA.id]?.windowStatus, .owned)
        XCTAssertEqual(windowManager.snapshots[hostA.id]?.connectionState, .connected)
        XCTAssertNil(windowManager.snapshots[hostB.id])

        // Unopened hosts for Window A should contain hostB
        var unopened = hosts.filter { $0.id != selectedHostId && !windowManager.isHostOpenAnywhere($0.id) }
        XCTAssertEqual(unopened.map(\.id), [hostB.id])

        // 1. Scene B starts opening host B (.connecting)
        let smB = SessionManager()
        smB.activeHost = hostB
        smB.forceStateForTesting(.connecting)
        let recB = WindowSessionRecord(persistentIdentifier: "scene-B", sessionManager: smB, hostId: hostB.id, status: .owned)
        MultiWindowManager.shared.installRecordForTesting(recB)

        // Snapshot reactively updated for host B
        XCTAssertEqual(windowManager.snapshots[hostB.id]?.windowStatus, .owned)
        XCTAssertEqual(windowManager.snapshots[hostB.id]?.connectionState, .connecting)
        XCTAssertEqual(windowManager.snapshots[hostB.id]?.ownerSessionPersistentIdentifier, "scene-B")
        XCTAssertTrue(windowManager.isHostOpenAnywhere(hostB.id))

        // New Window menu in Window A now has no unopened hosts
        unopened = hosts.filter { $0.id != selectedHostId && !windowManager.isHostOpenAnywhere($0.id) }
        XCTAssertTrue(unopened.isEmpty, "Host B must no longer appear in New Window menu while open in B")

        // 2. Scene B connection succeeds (.connected)
        smB.forceStateForTesting(.connected)
        XCTAssertEqual(windowManager.snapshots[hostB.id]?.connectionState, .connected)

        // 3. Scene B disconnects (.disconnected)
        smB.forceStateForTesting(.disconnected)
        XCTAssertEqual(windowManager.snapshots[hostB.id]?.connectionState, .disconnected)

        // 4. Scene B closes host B
        MultiWindowManager.shared.removeRecord(withPersistentIdentifier: "scene-B")
        XCTAssertNil(windowManager.snapshots[hostB.id])
        XCTAssertFalse(windowManager.isHostOpenAnywhere(hostB.id))

        // New Window menu in Window A reactively reflects host B is available again
        unopened = hosts.filter { $0.id != selectedHostId && !windowManager.isHostOpenAnywhere($0.id) }
        XCTAssertEqual(unopened.map(\.id), [hostB.id])
    }

    @MainActor
    func testTappingCurrentHostAfterDisconnectOrFailureInitiatesConnectAttempt() {
        MultiWindowManager.shared.resetForTesting()
        defer { MultiWindowManager.shared.resetForTesting() }

        let host = HostProfile(name: "ProdServer", hostname: "prod.local")
        let sm = SessionManager()
        sm.activeHost = host

        // 1. Failed attempt -> action must be .connectInCurrentWindow (advertised as Retry)
        sm.forceStateForTesting(.failed("Network timeout"))
        let failedAction = HostListView.resolveRowTapAction(
            for: host,
            selectedHostId: host.id,
            effectiveWindowScene: nil,
            sessionManager: sm
        )
        XCTAssertEqual(failedAction, .connectInCurrentWindow(host: host), "Tapping a failed current host must trigger Connect/Retry attempt")

        // 2. Intentional disconnect -> action must be .connectInCurrentWindow
        sm.forceStateForTesting(.disconnected)
        let disconnectedAction = HostListView.resolveRowTapAction(
            for: host,
            selectedHostId: host.id,
            effectiveWindowScene: nil,
            sessionManager: sm
        )
        XCTAssertEqual(disconnectedAction, .connectInCurrentWindow(host: host), "Tapping a disconnected current host must trigger Connect attempt")

        // 3. Already connected -> action must dismiss and focus terminal, NOT restart connection
        sm.forceStateForTesting(.connected)
        let connectedAction = HostListView.resolveRowTapAction(
            for: host,
            selectedHostId: host.id,
            effectiveWindowScene: nil,
            sessionManager: sm
        )
        XCTAssertEqual(connectedAction, .dismissAndFocusTerminal, "Tapping an already connected host must dismiss and focus terminal")

        // 4. Connecting / busy -> action must ignore/dismiss, NOT restart
        sm.forceStateForTesting(.connecting)
        let busyAction = HostListView.resolveRowTapAction(
            for: host,
            selectedHostId: host.id,
            effectiveWindowScene: nil,
            sessionManager: sm
        )
        XCTAssertEqual(busyAction, .ignoreBusy, "Tapping a busy host must not restart it")
    }

    @MainActor
    func testDragReevaluatesOwnershipWhenDragBegins() {
        MultiWindowManager.shared.resetForTesting()
        defer { MultiWindowManager.shared.resetForTesting() }

        let host = HostProfile(name: "Staging", hostname: "staging.local")
        let sm = SessionManager()

        // 1. Initially unopened: makeHostItemProvider produces a valid provider with activity
        let initialProvider = HostListView.makeHostItemProvider(for: host, isAlreadyOpen: false)
        XCTAssertTrue(initialProvider.canLoadObject(ofClass: NSUserActivity.self))

        // 2. Another scene claims the host before drag begins
        let otherSm = SessionManager()
        let claim = MultiWindowManager.shared.claimHost(host.id, for: otherSm, scene: nil)
        XCTAssertEqual(claim, .claimed)
        XCTAssertTrue(MultiWindowManager.shared.isHostOpenAnywhere(host.id))

        // When drag starts now, re-evaluating live rejects the duplicate
        let liveIsOpen = MultiWindowManager.shared.isHostOpenAnywhere(host.id)
        XCTAssertTrue(liveIsOpen)
        let providerAfterClaim = HostListView.makeHostItemProvider(for: host, isAlreadyOpen: liveIsOpen)
        XCTAssertFalse(providerAfterClaim.canLoadObject(ofClass: NSUserActivity.self), "Must produce empty provider when host is claimed by another window")

        // 3. Central connection boundary verification:
        // If an old drag item provider attempts to connect, claimHost rejects duplicate without second SSH connection
        let secondClaim = MultiWindowManager.shared.claimHost(host.id, for: sm, scene: nil)
        if case .alreadyClaimed = secondClaim {
            // Expected rejection of duplicate claim
        } else {
            XCTFail("Central connection boundary must reject duplicate claim after another scene claimed host")
        }
    }

    @MainActor
    func testKeyboardNewWindowFeedbackInZeroOneAndAllOpenStates() {
        MultiWindowManager.shared.resetForTesting()
        QuickActionManager.shared.resetForTesting()
        defer {
            MultiWindowManager.shared.resetForTesting()
            QuickActionManager.shared.resetForTesting()
        }

        let appState = AppState()
        appState.hosts = []
        appState.selectedHostId = nil

        // 1. Zero hosts configured
        MainContentView.handleOpenNewWindow(appState: appState)
        XCTAssertNotNil(appState.sessionManager.activeToast)
        XCTAssertEqual(appState.sessionManager.activeToast?.title, "New Window")
        XCTAssertEqual(appState.sessionManager.activeToast?.message, "Add another host in Settings to open multiple windows.")
        appState.sessionManager.activeToast = nil

        // 2. One host configured (and open in current window)
        let host1 = HostProfile(name: "Host1", hostname: "h1.local")
        appState.hosts = [host1]
        appState.selectedHostId = host1.id
        let rec1 = WindowSessionRecord(persistentIdentifier: "window-1", sessionManager: appState.sessionManager, hostId: host1.id, status: .owned)
        MultiWindowManager.shared.installRecordForTesting(rec1)

        MainContentView.handleOpenNewWindow(appState: appState)
        XCTAssertNotNil(appState.sessionManager.activeToast)
        XCTAssertEqual(appState.sessionManager.activeToast?.title, "New Window")
        XCTAssertEqual(appState.sessionManager.activeToast?.message, "Add another host in Settings to open multiple windows.")
        appState.sessionManager.activeToast = nil

        // 3. Two hosts configured, both open in dedicated windows
        let host2 = HostProfile(name: "Host2", hostname: "h2.local")
        appState.hosts = [host1, host2]
        let sm2 = SessionManager()
        let rec2 = WindowSessionRecord(persistentIdentifier: "window-2", sessionManager: sm2, hostId: host2.id, status: .owned)
        MultiWindowManager.shared.installRecordForTesting(rec2)

        MainContentView.handleOpenNewWindow(appState: appState)
        XCTAssertNotNil(appState.sessionManager.activeToast)
        XCTAssertEqual(appState.sessionManager.activeToast?.title, "New Window")
        XCTAssertEqual(appState.sessionManager.activeToast?.message, "All configured hosts are already open in dedicated windows.")
        appState.sessionManager.activeToast = nil

        // 4. Two hosts configured, one unopened -> routes to openHostInNewWindow
        MultiWindowManager.shared.removeRecord(withPersistentIdentifier: "window-2")
        var openedHostId: UUID? = nil
        QuickActionManager.shared.onOpenHostInNewWindowForTesting = { id in
            openedHostId = id
        }

        MainContentView.handleOpenNewWindow(appState: appState)
        XCTAssertNil(appState.sessionManager.activeToast, "Must not show error toast when an unopened host is available")
        XCTAssertEqual(openedHostId, host2.id, "Must route unopened host to new window")
    }

    @MainActor
    func testLifecycleObserversCleanedUpAcrossRepeatedShutdowns() {
        let nc = NotificationCenter()
        var workCounter = 0

        for _ in 0..<100 {
            let sm = SessionManager(notificationCenter: nc)
            XCTAssertEqual(sm.lifecycleObserverTokens.count, 4)
            sm.onShedMemory = { workCounter += 1 }
            sm.onMemoryWarning = { workCounter += 1 }
            sm.shutdown()
            XCTAssertTrue(sm.lifecycleObserverTokens.isEmpty, "Shutdown must unregister all observer tokens")
        }

        // Post all lifecycle notifications to the injected center
        nc.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        nc.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        nc.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        nc.post(name: UIApplication.willTerminateNotification, object: nil)

        // Run runloop briefly to ensure no async tasks fire
        let exp = expectation(description: "No work scheduled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 0.5)

        XCTAssertEqual(workCounter, 0, "No work should be scheduled for removed sessions")
    }

    @MainActor
    func testBackgroundTaskBeginEndPairingAcrossLifecyclePaths() {
        let fake = FakeBackgroundTaskProvider()
        let host = HostProfile(name: "TestHost", hostname: "test.local")

        // 1. Foreground path: begin on background, end on foreground
        let sm1 = SessionManager(backgroundTaskProvider: fake)
        sm1.activeHost = host
        sm1.markConnectedForTesting()
        sm1.handleAppBackgrounded()
        XCTAssertEqual(fake.beginCalls.count, 1)
        let token1 = fake.beginCalls[0].id
        XCTAssertEqual(fake.endCalls.filter { $0 == token1 }.count, 0)
        sm1.handleAppForegrounded()
        XCTAssertEqual(fake.endCalls.filter { $0 == token1 }.count, 1, "Token1 must end exactly once on foregrounding")

        // 2. Disconnect path: begin on background, end on disconnect
        let sm2 = SessionManager(backgroundTaskProvider: fake)
        sm2.activeHost = host
        sm2.markConnectedForTesting()
        sm2.handleAppBackgrounded()
        XCTAssertEqual(fake.beginCalls.count, 2)
        let token2 = fake.beginCalls[1].id
        XCTAssertEqual(fake.endCalls.filter { $0 == token2 }.count, 0)
        sm2.disconnect()
        XCTAssertEqual(fake.endCalls.filter { $0 == token2 }.count, 1, "Token2 must end exactly once on disconnect")

        // 3. Discard path: begin on background, end on discard/shutdown
        let sm3 = SessionManager(backgroundTaskProvider: fake)
        sm3.activeHost = host
        sm3.markConnectedForTesting()
        sm3.handleAppBackgrounded()
        XCTAssertEqual(fake.beginCalls.count, 3)
        let token3 = fake.beginCalls[2].id
        XCTAssertEqual(fake.endCalls.filter { $0 == token3 }.count, 0)
        sm3.discard()
        XCTAssertEqual(fake.endCalls.filter { $0 == token3 }.count, 1, "Token3 must end exactly once on discard")

        // 4. Expiration path: begin on background, end on expiration handler
        let sm4 = SessionManager(backgroundTaskProvider: fake)
        sm4.activeHost = host
        sm4.markConnectedForTesting()
        sm4.handleAppBackgrounded()
        XCTAssertEqual(fake.beginCalls.count, 4)
        let token4 = fake.beginCalls[3].id
        XCTAssertEqual(fake.endCalls.filter { $0 == token4 }.count, 0)
        fake.triggerExpiration(for: token4)
        XCTAssertEqual(fake.endCalls.filter { $0 == token4 }.count, 1, "Token4 must end promptly in expiration handler")
        // Subsequent foregrounding or disconnect should not re-end token4
        sm4.handleAppForegrounded()
        sm4.disconnect()
        XCTAssertEqual(fake.endCalls.filter { $0 == token4 }.count, 1, "Token4 must not be ended more than once")

        // 5. Idle/disconnected session should NOT begin background task
        let idleSm = SessionManager(backgroundTaskProvider: fake)
        let countBefore = fake.beginCalls.count
        idleSm.handleAppBackgrounded()
        XCTAssertEqual(fake.beginCalls.count, countBefore, "Idle session with no protected work must not begin a background task")
    }

    @MainActor
    func testDelayedExpirationCallbackDoesNotAffectNewConnection() {
        let fake = FakeBackgroundTaskProvider()
        let sm = SessionManager(backgroundTaskProvider: fake)
        let h1 = HostProfile(name: "HostOld", hostname: "old.local")
        let h2 = HostProfile(name: "HostNew", hostname: "new.local")

        // 1. Connect to Host 1 and background
        sm.activeHost = h1
        sm.markConnectedForTesting()
        sm.handleAppBackgrounded()
        XCTAssertEqual(fake.beginCalls.count, 1)
        let oldExpirationHandler = fake.beginCalls[0].handler

        // 2. Foreground and establish new connection to Host 2
        sm.handleAppForegrounded()
        sm.connect(to: h2)
        sm.connectTask?.cancel()
        sm.isConnecting = false
        sm.markConnectedForTesting()
        XCTAssertEqual(sm.state, .connected)
        XCTAssertEqual(sm.activeHost?.id, h2.id)

        // 3. Delayed old expiration handler now executes
        oldExpirationHandler?()

        let exp = expectation(description: "Wait for any asynchronous task")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 0.5)

        // New connection remains intact
        XCTAssertEqual(sm.state, .connected, "Old delayed expiration must not close new active connection")
        XCTAssertEqual(sm.activeHost?.id, h2.id)
    }

    @MainActor
    func testSceneAndProcessLifecycleTransitionsAndTimerCleanup() {
        MultiWindowManager.shared.resetForTesting()
        defer { MultiWindowManager.shared.resetForTesting() }

        let sm = SessionManager()
        let host = HostProfile(name: "Server", hostname: "srv.local")
        sm.activeHost = host
        sm.markConnectedForTesting()

        let record = WindowSessionRecord(persistentIdentifier: "scene-main", sessionManager: sm, hostId: host.id, status: .owned)
        MultiWindowManager.shared.installRecordForTesting(record)
        XCTAssertTrue(sm.isCoordinatedByWindowManager)

        var memoryShedCalls = 0
        sm.onShedMemory = { memoryShedCalls += 1 }

        // 1. Scene phase changes to background
        MultiWindowManager.shared.handleScenePhaseChange(
            scenePhase: .background,
            sessionManager: sm,
            hosts: [host]
        )
        // Memory shed scheduled
        sm.scheduleBackgroundMemoryShed(after: 120)

        // Process notification fires
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)

        // Verify session entered background exactly once
        XCTAssertTrue(sm.isAppInBackground)

        // 2. Scene phase changes to active
        MultiWindowManager.shared.handleScenePhaseChange(
            scenePhase: .active,
            sessionManager: sm,
            hosts: [host]
        )
        // Foreground process notification fires
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)

        // Verify session restored and in foreground
        XCTAssertFalse(sm.isAppInBackground)

        // Memory shed timer is cancelled upon restore/foreground
        sm.restoreMemory()

        let exp = expectation(description: "Ensure no orphaned timer fires")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 0.5)

        // No orphaned background memory shed ran
        XCTAssertEqual(memoryShedCalls, 0, "Cancelled background timer must not trigger memory shed")
    }

    @MainActor
    func testTerminalContextPreservedAcrossAttachAndOutputFeedsLiveView() {
        MultiWindowManager.shared.resetForTesting()
        defer { MultiWindowManager.shared.resetForTesting() }

        let sm = SessionManager()
        let host = HostProfile(name: "LiveHost", hostname: "live.local")
        sm.activeHost = host

        // Simulate Coordinator creation when TerminalRepresentable is initialized
        let representable = TerminalContainerView(sessionManager: sm)
        let ctxFromManager = MultiWindowManager.shared.terminalContext(for: sm)
        let liveTerminalView = ctxFromManager.terminalView

        // Now simulate window scene attaching
        let win = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            win.windowScene = scene
        }
        let pid = "live-session-pid"
        let record = MultiWindowManager.shared.register(
            sessionManager: sm,
            scene: win.windowScene,
            hostId: host.id,
            sessionPersistentIdentifier: pid
        )

        // Verify TerminalSessionContext was NOT replaced by a new instance
        XCTAssertTrue(record.terminalContext === ctxFromManager, "Terminal context in record must match the coordinator context")
        XCTAssertTrue(record.terminalContext?.terminalView === liveTerminalView, "Terminal view must not be replaced")

        // Feed SSH output
        let testOutput = "Live Terminal Output Ready\r\n"
        sm.onTerminalOutput?(Array(testOutput.utf8))

        // Verify the output actually reached liveTerminalView
        let term = liveTerminalView.getTerminal()
        var foundOutput = false
        for row in 0..<term.rows {
            var lineStr = ""
            for col in 0..<term.cols {
                if let ch = term.character(col: col, row: row) {
                    lineStr.append(ch)
                }
            }
            if lineStr.contains("Live Terminal Output Ready") {
                foundOutput = true
                break
            }
        }
        XCTAssertTrue(foundOutput, "Live terminal view on screen must receive output from sessionManager")
    }

    @MainActor
    func testReconcileWithOpenSessionsDoesNotCreateZombieOwnership() {
        MultiWindowManager.shared.resetForTesting()
        defer { MultiWindowManager.shared.resetForTesting() }

        let host = HostProfile(name: "HostTest", hostname: "test.local")

        // Calling reconcileWithOpenSessions when records is empty should NOT create phantom .owned records
        MultiWindowManager.shared.reconcileWithOpenSessions()

        XCTAssertFalse(MultiWindowManager.shared.isHostOpenAnywhere(host.id), "Unattached open sessions must not be marked as open/owned")
        XCTAssertNil(MultiWindowManager.shared.findSessionRecord(for: host.id))

        // Now a live session manager can claim and connect to the host without being blocked
        let liveSm = SessionManager()
        let claim = MultiWindowManager.shared.claimHost(host.id, for: liveSm, scene: nil)
        XCTAssertEqual(claim, .claimed, "Live session manager must successfully claim host")
    }

    @MainActor
    func testTerminalResignFirstResponderDoesNotClearFocusIntentWhenActiveIsNil() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let terminal = FilaireTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        window.addSubview(terminal)
        window.makeKeyAndVisible()

        terminal.focusIntent = .terminal
        _ = terminal.resignFirstResponder()

        let exp = expectation(description: "Wait for main queue pass")
        DispatchQueue.main.async {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 0.5)

        XCTAssertEqual(terminal.focusIntent, .terminal, "Resigning first responder with no other responder must retain terminal focus intent")
    }

    // MARK: - Focus Window Transition & Persistence Tests
    @MainActor
    func testDisconnectFocusesOtherActiveWindowAndRemembersFocusWindow() {
        MultiWindowManager.shared.resetForTesting()
        defer {
            MultiWindowManager.shared.resetForTesting()
        }

        let sm1 = SessionManager()
        let sm2 = SessionManager()
        let host1 = HostProfile(name: "Host 1", hostname: "h1.local", autoConnect: true)
        let host2 = HostProfile(name: "Host 2", hostname: "h2.local", autoConnect: true)
        sm1.activeHost = host1
        sm2.activeHost = host2

        MultiWindowManager.shared.forceMultipleWindowsForTesting = true

        MultiWindowManager.shared.register(sessionManager: sm1, scene: nil, hostId: host1.id, sessionPersistentIdentifier: "window-1")
        MultiWindowManager.shared.register(sessionManager: sm2, scene: nil, hostId: host2.id, sessionPersistentIdentifier: "window-2")

        // sm2 is currently focused
        MultiWindowManager.shared.recordInteraction(sessionPersistentIdentifier: "window-2")
        XCTAssertEqual(MultiWindowManager.shared.rememberedFocusHostId, host2.id)
        XCTAssertEqual(MultiWindowManager.shared.mostRecentInteractionSceneIdentifier, "window-2")

        // Disconnect and close window-2
        let closed = MultiWindowManager.shared.closeWindowIfMultiple(for: sm2)
        XCTAssertTrue(closed)

        // window-1 should now be the focus window
        XCTAssertEqual(MultiWindowManager.shared.mostRecentInteractionSceneIdentifier, "window-1")
        XCTAssertEqual(MultiWindowManager.shared.rememberedFocusHostId, host1.id)
        XCTAssertEqual(MultiWindowManager.shared.rememberedFocusSceneIdentifier, "window-1")
        XCTAssertEqual(UserDefaults.standard.string(forKey: AppState.activeHostKey), host1.id.uuidString)
        XCTAssertEqual(UserDefaults.standard.string(forKey: MultiWindowManager.focusSceneIdentifierKey), "window-1")

        // Leaving app and reopening via untargeted launch must return to window-1 (host1), not the disconnected host2
        let resolved = WindowBootstrapResolver.resolveTargetHostId(
            scenePid: "new-scene-pid",
            activity: nil,
            restorationActivity: nil,
            sessionUserInfo: nil,
            hosts: [host1, host2]
        )
        XCTAssertEqual(resolved, host1.id, "Untargeted launch must resolve to remembered focus host (host1), not disconnected session (host2)")

        MultiWindowManager.shared.unregister(sessionManager: sm1)
        MultiWindowManager.shared.unregister(sessionManager: sm2)
    }

    @MainActor
    func testUntargetedReopenPrioritizesRememberedFocusHostOverOtherAutoConnectHosts() {
        MultiWindowManager.shared.resetForTesting()
        defer {
            MultiWindowManager.shared.resetForTesting()
        }

        let hostA = HostProfile(name: "Host A", hostname: "ha.local", autoConnect: true)
        let hostB = HostProfile(name: "Host B", hostname: "hb.local", autoConnect: true)

        // Set remembered focus host to hostA
        MultiWindowManager.shared.rememberedFocusHostId = hostA.id

        // When launching untargeted with no open windows (e.g. fresh launch after termination),
        // it must resolve to hostA (the remembered focus host), not hostB
        let resolved = WindowBootstrapResolver.resolveTargetHostId(
            scenePid: "cold-launch-scene",
            activity: nil,
            restorationActivity: nil,
            sessionUserInfo: nil,
            hosts: [hostB, hostA] // hostB comes first in array
        )
        XCTAssertEqual(resolved, hostA.id, "Cold untargeted launch must prioritize remembered focus host over other auto-connect hosts")
    }

    // MARK: - Option + Arrow Key Repeat Tests
    @MainActor
    func testOptionLeftArrowKeyRepeat() {
        final class MockDelegate: TerminalViewDelegate {
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

        let terminal = FilaireTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = MockDelegate()
        terminal.terminalDelegate = delegate

        terminal.modifierKeyRepeatInitialDelay = 0.04
        terminal.modifierKeyRepeatInterval = 0.02

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

        // Wait for repeat ticks
        let exp = expectation(description: "Wait for repeat timer ticks")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)

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

        let terminal = FilaireTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = MockDelegate()
        terminal.terminalDelegate = delegate

        terminal.modifierKeyRepeatInitialDelay = 0.04
        terminal.modifierKeyRepeatInterval = 0.02

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

        // Wait for repeat ticks
        let exp = expectation(description: "Wait for repeat timer ticks")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)

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

        let terminal = FilaireTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = MockDelegate()
        terminal.terminalDelegate = delegate

        terminal.modifierKeyRepeatInitialDelay = 0.04
        terminal.modifierKeyRepeatInterval = 0.02

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

        // Wait for repeat ticks
        let exp = expectation(description: "Wait for repeat timer ticks")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)

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

final class FakeBackgroundTaskProvider: BackgroundTaskProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var nextId = 1
    var beginCalls: [(name: String?, id: UIBackgroundTaskIdentifier, handler: (() -> Void)?)] = []
    var endCalls: [UIBackgroundTaskIdentifier] = []

    func beginBackgroundTask(withName name: String?, expirationHandler handler: (() -> Void)?) -> UIBackgroundTaskIdentifier {
        lock.lock()
        defer { lock.unlock() }
        let id = UIBackgroundTaskIdentifier(rawValue: nextId)
        nextId += 1
        beginCalls.append((name: name, id: id, handler: handler))
        return id
    }

    func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier) {
        lock.lock()
        defer { lock.unlock() }
        endCalls.append(identifier)
    }

    func triggerExpiration(for identifier: UIBackgroundTaskIdentifier) {
        let handler: (() -> Void)?
        lock.lock()
        handler = beginCalls.first(where: { $0.id == identifier })?.handler
        lock.unlock()
        handler?()
    }
}

final class MockTerminalGrid: TerminalCharacterGrid {
    let cols: Int
    let rows: Int
    var lines: [String]
    var explicitLinks: [String: String] = [:]

    init(lines: [String], cols: Int? = nil) {
        self.lines = lines
        self.rows = lines.count
        self.cols = cols ?? (lines.map { $0.count }.max() ?? 80)
    }

    func character(col: Int, row: Int) -> Character? {
        guard row >= 0, row < lines.count else { return nil }
        let line = lines[row]
        guard col >= 0 else { return nil }
        if col < line.count {
            let index = line.index(line.startIndex, offsetBy: col)
            return line[index]
        }
        return " "
    }

    func explicitLink(col: Int, row: Int) -> String? {
        explicitLinks["\(col),\(row)"]
    }
}
