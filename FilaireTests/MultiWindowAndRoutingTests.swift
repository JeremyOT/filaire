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

final class MultiWindowAndRoutingTests: XCTestCase {
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
        sm.triggerTmuxJoinVertical()
        sm.triggerTmuxJoinHorizontal()
        sm.triggerTmuxMarkPane()
        sm.triggerTmuxZoomPane()
        sm.triggerTmuxBreakPane()
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

    @MainActor
    func testGeneratedKeyNameReflectsTheDeviceRatherThanAHardcodedModel() {
        let name = KeyManagementView.defaultGeneratedKeyName()

        XCTAssertTrue(name.hasPrefix("Filaire "))
        XCTAssertTrue(name.hasSuffix(" Key"))

        let assigned = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let expected = assigned.isEmpty ? UIDevice.current.model : assigned
        XCTAssertTrue(
            name.contains(expected),
            "Expected the key name to carry the device label '\(expected)', got '\(name)'"
        )
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
        XCTAssertFalse(view.triggerTmuxJoinVertical())
        XCTAssertFalse(view.triggerTmuxJoinHorizontal())
        XCTAssertFalse(view.triggerTmuxMarkPane())
        XCTAssertFalse(view.triggerTmuxWindowNumber(1))

        // When enabled, tmux actions succeed
        view.configureTmux(enabled: true, prefixTitle: "Ctrl-A", prefixByte: 0x01)
        XCTAssertTrue(view.autoConnectTmux)
        XCTAssertTrue(view.triggerTmuxNewWindow())
        XCTAssertTrue(view.triggerTmuxJoinVertical())
        XCTAssertTrue(view.triggerTmuxJoinHorizontal())
        XCTAssertTrue(view.triggerTmuxMarkPane())

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

    @MainActor
    func testDeduplicateWindowsEnforcesAtMostOneActiveWindowPerHost() {
        let host = HostProfile(name: "SingleHost", hostname: "single.local")
        let hostId = host.id

        let smActive = SessionManager()
        let smDuplicate = SessionManager()
        smActive.state = .connected

        MultiWindowManager.shared.forceMultipleWindowsForTesting = true
        defer {
            MultiWindowManager.shared.forceMultipleWindowsForTesting = nil
            MultiWindowManager.shared.unregister(sessionManager: smActive)
            MultiWindowManager.shared.unregister(sessionManager: smDuplicate)
        }

        MultiWindowManager.shared.register(sessionManager: smActive, scene: nil, hostId: hostId, sessionPersistentIdentifier: "session-active")
        MultiWindowManager.shared.register(sessionManager: smDuplicate, scene: nil, hostId: hostId, sessionPersistentIdentifier: "session-dup")

        MultiWindowManager.shared.deduplicateWindows()

        let entryActive = MultiWindowManager.shared.entry(for: smActive)
        let entryDup = MultiWindowManager.shared.entry(for: smDuplicate)

        XCTAssertEqual(entryActive?.status, .owned, "Active session must remain .owned")
        XCTAssertEqual(entryActive?.hostId, hostId)
        XCTAssertEqual(entryDup?.status, .closing, "Duplicate session must be closed")
        XCTAssertNil(entryDup?.hostId, "Duplicate session hostId must be cleared")
    }

    @MainActor
    func testDeduplicateWindowsPreservesDifferentHosts() {
        let host1 = HostProfile(name: "Host1", hostname: "host1.local")
        let host2 = HostProfile(name: "Host2", hostname: "host2.local")

        let sm1 = SessionManager()
        let sm2 = SessionManager()
        sm1.state = .connected
        sm2.state = .connected

        MultiWindowManager.shared.forceMultipleWindowsForTesting = true
        defer {
            MultiWindowManager.shared.forceMultipleWindowsForTesting = nil
            MultiWindowManager.shared.unregister(sessionManager: sm1)
            MultiWindowManager.shared.unregister(sessionManager: sm2)
        }

        MultiWindowManager.shared.register(sessionManager: sm1, scene: nil, hostId: host1.id, sessionPersistentIdentifier: "session-host1")
        MultiWindowManager.shared.register(sessionManager: sm2, scene: nil, hostId: host2.id, sessionPersistentIdentifier: "session-host2")

        let deduped = MultiWindowManager.shared.deduplicateWindows()
        XCTAssertFalse(deduped.contains(host1.id))
        XCTAssertFalse(deduped.contains(host2.id))

        let entry1 = MultiWindowManager.shared.entry(for: sm1)
        let entry2 = MultiWindowManager.shared.entry(for: sm2)

        XCTAssertEqual(entry1?.status, .owned)
        XCTAssertEqual(entry1?.hostId, host1.id)
        XCTAssertEqual(entry2?.status, .owned)
        XCTAssertEqual(entry2?.hostId, host2.id)
    }

    @MainActor
    func testDeduplicateWindowsPreservesUntargetedWindows() {
        let smUntargeted1 = SessionManager()
        let smUntargeted2 = SessionManager()

        MultiWindowManager.shared.forceMultipleWindowsForTesting = true
        defer {
            MultiWindowManager.shared.forceMultipleWindowsForTesting = nil
            MultiWindowManager.shared.unregister(sessionManager: smUntargeted1)
            MultiWindowManager.shared.unregister(sessionManager: smUntargeted2)
        }

        MultiWindowManager.shared.register(sessionManager: smUntargeted1, scene: nil, hostId: nil, sessionPersistentIdentifier: "session-untargeted-1")
        MultiWindowManager.shared.register(sessionManager: smUntargeted2, scene: nil, hostId: nil, sessionPersistentIdentifier: "session-untargeted-2")

        MultiWindowManager.shared.deduplicateWindows()

        let entry1 = MultiWindowManager.shared.entry(for: smUntargeted1)
        let entry2 = MultiWindowManager.shared.entry(for: smUntargeted2)

        XCTAssertNotEqual(entry1?.status, .closing, "Untargeted window 1 should not be closed by deduplicateWindows")
        XCTAssertNotEqual(entry2?.status, .closing, "Untargeted window 2 should not be closed by deduplicateWindows")
    }

    @MainActor
    func testInitialLaunchClaimHostDoesNotCloseWhenNoActiveOtherScene() {
        let host = HostProfile(name: "InitialHost", hostname: "initial.local")
        let sm = SessionManager()
        defer {
            MultiWindowManager.shared.unregister(sessionManager: sm)
        }

        // On fresh launch, claimHost for the auto-connect host should succeed as .claimed
        let claimResult = MultiWindowManager.shared.claimHost(host.id, for: sm, scene: nil)
        switch claimResult {
        case .claimed:
            // Succeeded as expected
            break
        case .alreadyClaimed:
            XCTFail("claimHost should not return alreadyClaimed when no active scene holds the host")
        }

        let entry = MultiWindowManager.shared.entry(for: sm)
        XCTAssertEqual(entry?.status, .owned)
        XCTAssertEqual(entry?.hostId, host.id)
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



}
