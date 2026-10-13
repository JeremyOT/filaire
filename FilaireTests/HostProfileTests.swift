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

final class HostProfileTests: XCTestCase {
    // MARK: - Host Profile & Tmux Commands

    func testHostProfileTmuxDefaults() {
        let profile = HostProfile(
            name: "Dev Box",
            hostname: "dev.internal",
            port: 22,
            username: "dev"
        )

        // Split and join bindings for Cmd+D / Cmd+Shift+D / Cmd+J / Cmd+Shift+J, chained after new-session
        let splitBindings = " \\; set -s 'user-keys[900]' \"$(printf '\\033[9990~')\" \\; set -s 'user-keys[901]' \"$(printf '\\033[9991~')\" \\; set -s 'user-keys[902]' \"$(printf '\\033[9992~')\" \\; set -s 'user-keys[903]' \"$(printf '\\033[9993~')\" \\; bind -n User900 split-window -h -c '#{pane_current_path}' \\; bind -n User901 split-window -v -c '#{pane_current_path}' \\; bind -n User902 join-pane -h \\; bind -n User903 join-pane -v"

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



}
