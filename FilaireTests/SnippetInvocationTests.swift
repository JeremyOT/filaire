import XCTest
import UIKit
@testable import Filaire

/// Invocation lifecycle and snippet shortcut dispatch. The forms themselves are checked on device.
@MainActor
final class SnippetInvocationTests: XCTestCase {

    private let hostA = UUID()
    private let hostB = UUID()

    private func snippet(secret: Bool = false) -> CommandSnippet {
        CommandSnippet(
            name: "Curl",
            template: "curl -H {{token}} {{url}}",
            parameters: [
                SnippetParameter(name: "token", label: "Token", isSecret: secret),
                SnippetParameter(name: "url", label: "URL", defaultValue: "https://example.com")
            ]
        )
    }

    func testInvocationSeedsNonsecretDefaultsOnly() {
        let state = TerminalInteractionState()
        state.beginInvocation(of: snippet(secret: true), forHost: hostA)

        XCTAssertEqual(state.snippetInvocation?.value(for: "url"), "https://example.com")
        XCTAssertEqual(state.snippetInvocation?.value(for: "token"), "", "A secret field always starts empty")
    }

    func testCancellingDiscardsEveryEnteredValue() {
        let state = TerminalInteractionState()
        state.beginInvocation(of: snippet(secret: true), forHost: hostA)
        state.updateInvocationValue("s3cret", for: "token")

        state.cancelInvocation()

        XCTAssertNil(state.snippetInvocation)
    }

    func testHostChangeDropsSecretValuesButKeepsTheRest() {
        let state = TerminalInteractionState()
        state.beginInvocation(of: snippet(secret: true), forHost: hostA)
        state.updateInvocationValue("s3cret", for: "token")
        state.updateInvocationValue("https://internal", for: "url")
        state.setRevealSecrets(true)

        state.hostDidChange(to: hostB)

        XCTAssertEqual(state.snippetInvocation?.value(for: "url"), "https://internal")
        XCTAssertEqual(state.snippetInvocation?.value(for: "token"), "")
        XCTAssertEqual(state.snippetInvocation?.revealSecrets, false)
        XCTAssertEqual(state.snippetInvocation?.hostID, hostA, "The form remembers where it was opened")
    }

    func testHostChangeClosesTheLibrary() {
        let state = TerminalInteractionState()
        state.openSnippetLibrary()
        state.hostDidChange(to: hostB)
        XCTAssertFalse(state.isSnippetLibraryPresented)
    }

    func testTeardownClearsInvocationAndEditorState() {
        let state = TerminalInteractionState()
        state.beginInvocation(of: snippet(secret: true), forHost: hostA)
        state.updateInvocationValue("s3cret", for: "token")
        state.beginSnippetEditor(snippet())
        state.openSnippetLibrary()

        state.teardown()

        XCTAssertNil(state.snippetInvocation)
        XCTAssertNil(state.snippetEditorDraft)
        XCTAssertFalse(state.isSnippetLibraryPresented)
    }

    func testPreviewMatchesTheTextHandedToTheComposer() {
        let target = snippet(secret: true)
        let values = ["token": "s3cret", "url": "https://example.com"]
        guard case .success(let rendered) = SnippetTemplateRenderer.render(
            template: target.template,
            parameters: target.parameters,
            values: values
        ) else {
            return XCTFail("expected a render")
        }

        // The masked preview is presentation only; the command text is unchanged.
        XCTAssertEqual(rendered.text, "curl -H 's3cret' 'https://example.com'")
        XCTAssertFalse(rendered.maskedText().contains("s3cret"))
        XCTAssertTrue(rendered.containsSecretValues)
    }

    // MARK: - Shortcut dispatch

    func testCmdShiftSRequestsTheLibraryFromTheKeyShortcutPath() {
        let terminalView = FilaireTerminalView(frame: .zero)
        var requests = 0
        terminalView.onSnippetsRequested = { requests += 1 }

        XCTAssertTrue(terminalView.handleKeyShortcut(
            characters: "S",
            charactersIgnoringModifiers: "s",
            modifierFlags: [.command, .shift]
        ))
        XCTAssertEqual(requests, 1)
    }

    func testCmdShiftSIsRegisteredAsAKeyCommandInBothCases() {
        let terminalView = FilaireTerminalView(frame: .zero)
        let commands = (terminalView.keyCommands ?? []).filter {
            $0.action == #selector(FilaireTerminalView.handleOpenSnippets(_:))
        }

        XCTAssertEqual(commands.count, 2)
        for command in commands {
            XCTAssertEqual(command.modifierFlags, [.command, .shift])
        }
    }

    func testSnippetSelectorResolvesThroughTheResponderWhitelist() {
        let terminalView = FilaireTerminalView(frame: .zero)
        let target = terminalView.target(
            forAction: #selector(FilaireTerminalView.handleOpenSnippets(_:)),
            withSender: nil
        ) as AnyObject?
        XCTAssertTrue(target === terminalView)
    }

    func testComposerAndSnippetShortcutsDoNotCollide() {
        let terminalView = FilaireTerminalView(frame: .zero)
        var composerRequests = 0
        var snippetRequests = 0
        terminalView.onComposerRequested = { composerRequests += 1 }
        terminalView.onSnippetsRequested = { snippetRequests += 1 }

        _ = terminalView.handleKeyShortcut(
            characters: "E",
            charactersIgnoringModifiers: "e",
            modifierFlags: [.command, .shift]
        )
        _ = terminalView.handleKeyShortcut(
            characters: "S",
            charactersIgnoringModifiers: "s",
            modifierFlags: [.command, .shift]
        )

        XCTAssertEqual(composerRequests, 1)
        XCTAssertEqual(snippetRequests, 1)
    }

    func testAccessorySnippetsRequestReachesTheCallback() {
        let terminalView = FilaireTerminalView(frame: .zero)
        var requests = 0
        terminalView.onSnippetsRequested = { requests += 1 }

        terminalView.accessoryDidRequestSnippets()

        XCTAssertEqual(requests, 1)
    }
}
