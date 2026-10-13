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

final class FilePreviewAndOSCTests: XCTestCase {
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



}
