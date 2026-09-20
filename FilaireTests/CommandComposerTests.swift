import XCTest
import UIKit
@testable import Filaire

/// Draft lifecycle and composer shortcut dispatch. Presentation itself is checked on device.
@MainActor
final class CommandComposerTests: XCTestCase {

    private let hostA = UUID()
    private let hostB = UUID()

    // MARK: - Draft lifecycle

    func testDraftSurvivesCloseAndReopenForTheSameHost() {
        let state = TerminalInteractionState()
        state.openComposer(forHost: hostA, origin: .shortcut)
        state.draftText = "kubectl get pods"
        state.closeComposer()

        XCTAssertFalse(state.isComposerPresented)
        state.openComposer(forHost: hostA, origin: .accessoryBar)
        XCTAssertEqual(state.draftText, "kubectl get pods")
    }

    func testDraftsAreIsolatedPerHostAndNeverTransfer() {
        let state = TerminalInteractionState()
        state.openComposer(forHost: hostA, origin: .shortcut)
        state.draftText = "host A command"

        state.openComposer(forHost: hostB, origin: .shortcut)
        XCTAssertEqual(state.draftText, "", "A different host must not inherit the previous draft")

        state.draftText = "host B command"
        state.openComposer(forHost: hostA, origin: .shortcut)
        XCTAssertEqual(state.draftText, "host A command")
    }

    func testHostSwitchClosesTheComposerWithoutCarryingText() {
        let state = TerminalInteractionState()
        state.openComposer(forHost: hostA, origin: .shortcut)
        state.draftText = "half typed"

        state.hostDidChange(to: hostB)

        XCTAssertFalse(state.isComposerPresented)
        XCTAssertEqual(state.draftText, "")
        XCTAssertEqual(state.retainedDraftText(forHost: hostA), "half typed")
    }

    func testEmptyDraftIsNotRetained() {
        let state = TerminalInteractionState()
        state.openComposer(forHost: hostA, origin: .shortcut)
        state.draftText = ""
        state.closeComposer()

        XCTAssertEqual(state.retainedDraftCount(), 0)
    }

    func testSecretDraftIsDiscardedOnCloseInsteadOfCached() {
        let state = TerminalInteractionState()
        state.openComposer(with: "mysql -p hunter2", containsSecretValues: true, forHost: hostA)
        XCTAssertTrue(state.isDraftEphemeral)

        state.closeComposer()

        XCTAssertNil(state.retainedDraftText(forHost: hostA))
        XCTAssertEqual(state.retainedDraftCount(), 0)
    }

    func testDeletingHostsClearsTheirDrafts() {
        let state = TerminalInteractionState()
        state.openComposer(forHost: hostA, origin: .shortcut)
        state.draftText = "gone soon"
        state.closeComposer()

        state.removeDrafts(for: [hostA])

        XCTAssertNil(state.retainedDraftText(forHost: hostA))
    }

    func testDraftCacheEvictsLeastRecentlyUsedBeyondTheBound() {
        let state = TerminalInteractionState()
        var hostIDs: [UUID] = []
        for index in 0..<(TerminalInteractionState.maxRetainedDrafts + 2) {
            let hostID = UUID()
            hostIDs.append(hostID)
            state.openComposer(forHost: hostID, origin: .shortcut)
            state.draftText = "draft \(index)"
            state.closeComposer()
        }

        XCTAssertLessThanOrEqual(state.retainedDraftCount(), TerminalInteractionState.maxRetainedDrafts)
        XCTAssertNil(state.retainedDraftText(forHost: hostIDs[0]), "The oldest draft should have been evicted")
        XCTAssertNotNil(state.retainedDraftText(forHost: hostIDs[hostIDs.count - 1]))
        XCTAssertNotNil(state.evictionNotice, "Eviction must be visible to the user")
    }

    func testTeardownDropsEveryDraft() {
        let state = TerminalInteractionState()
        state.openComposer(forHost: hostA, origin: .shortcut)
        state.draftText = "temporary"
        state.closeComposer()

        state.teardown()

        XCTAssertEqual(state.retainedDraftCount(), 0)
        XCTAssertNil(state.retainedDraftText(forHost: hostA))
    }

    // MARK: - Snippet prefill

    func testPrefillIntoAnEmptyDraftIsAdoptedDirectly() {
        let state = TerminalInteractionState()
        state.openComposer(with: "uptime", containsSecretValues: false, forHost: hostA)

        XCTAssertEqual(state.draftText, "uptime")
        XCTAssertNil(state.pendingPrefill)
    }

    func testPrefillOverAnExistingDraftAsksBeforeReplacing() {
        let state = TerminalInteractionState()
        state.openComposer(forHost: hostA, origin: .shortcut)
        state.draftText = "existing"

        state.openComposer(with: "from snippet", containsSecretValues: false, forHost: hostA)

        XCTAssertEqual(state.draftText, "existing", "Prefill must not silently replace a draft")
        XCTAssertEqual(state.pendingPrefill?.text, "from snippet")
    }

    func testAppendJoinsWithAVisibleNewlineBoundary() {
        let state = TerminalInteractionState()
        state.openComposer(forHost: hostA, origin: .shortcut)
        state.draftText = "first"
        state.openComposer(with: "second", containsSecretValues: false, forHost: hostA)

        state.resolvePendingPrefill(.append)

        XCTAssertEqual(state.draftText, "first\nsecond")
    }

    func testReplaceSwapsTheDraftEntirely() {
        let state = TerminalInteractionState()
        state.openComposer(forHost: hostA, origin: .shortcut)
        state.draftText = "first"
        state.openComposer(with: "second", containsSecretValues: false, forHost: hostA)

        state.resolvePendingPrefill(.replace)

        XCTAssertEqual(state.draftText, "second")
    }

    // MARK: - Size bound

    func testDraftAtTheLimitIsWithinBoundsAndBeyondItIsNot() {
        let state = TerminalInteractionState()
        state.openComposer(forHost: hostA, origin: .shortcut)

        state.draftText = String(repeating: "a", count: TerminalInputSubmission.maxDraftBytes)
        XCTAssertTrue(state.isDraftWithinSizeLimit)

        state.draftText = String(repeating: "a", count: TerminalInputSubmission.maxDraftBytes + 1)
        XCTAssertFalse(state.isDraftWithinSizeLimit)
    }

    // MARK: - Shortcut dispatch

    func testCmdShiftERequestsTheComposerFromTheKeyShortcutPath() {
        let terminalView = FilaireTerminalView(frame: .zero)
        var requests = 0
        terminalView.onComposerRequested = { requests += 1 }

        XCTAssertTrue(terminalView.handleKeyShortcut(
            characters: "E",
            charactersIgnoringModifiers: "e",
            modifierFlags: [.command, .shift]
        ))
        XCTAssertEqual(requests, 1)
    }

    func testCmdShiftEIsRegisteredAsAKeyCommandInBothCases() {
        let terminalView = FilaireTerminalView(frame: .zero)
        let composerCommands = (terminalView.keyCommands ?? []).filter {
            $0.action == #selector(FilaireTerminalView.handleOpenComposer(_:))
        }

        XCTAssertEqual(composerCommands.count, 2, "Uppercase and lowercase E should both be registered")
        for command in composerCommands {
            XCTAssertEqual(command.modifierFlags, [.command, .shift])
        }
        XCTAssertTrue(composerCommands.contains { $0.discoverabilityTitle == "Compose Command" })
    }

    func testComposerSelectorResolvesThroughTheResponderWhitelist() {
        let terminalView = FilaireTerminalView(frame: .zero)
        let target = terminalView.target(
            forAction: #selector(FilaireTerminalView.handleOpenComposer(_:)),
            withSender: nil
        ) as AnyObject?
        XCTAssertTrue(target === terminalView)
    }

    func testAccessoryComposeRequestReachesTheCallback() {
        let terminalView = FilaireTerminalView(frame: .zero)
        var requests = 0
        terminalView.onComposerRequested = { requests += 1 }

        terminalView.accessoryDidRequestComposer()

        XCTAssertEqual(requests, 1)
    }
}
