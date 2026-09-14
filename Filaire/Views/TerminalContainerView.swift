import SwiftUI
import UIKit
import SwiftTerm
import UserNotifications

public struct TerminalContainerView: View {
    public let sessionManager: SessionManager
    public var isStatusExpanded: Bool = false
    public var isCoveredByPresentation: Bool = false
    public var onUserInput: (() -> Void)?

    public init(sessionManager: SessionManager, isStatusExpanded: Bool = false, isCoveredByPresentation: Bool = false, onUserInput: (() -> Void)? = nil) {
        self.sessionManager = sessionManager
        self.isStatusExpanded = isStatusExpanded
        self.isCoveredByPresentation = isCoveredByPresentation
        self.onUserInput = onUserInput
    }

    public var body: some View {
        @Bindable var session = sessionManager
        let host = session.activeHost
        let autoConnectTmux = host?.autoConnectTmux ?? false
        let tmuxPrefixDisplay = host?.tmuxPrefixDisplay ?? "Ctrl-B"
        let tmuxPrefixByte = host?.tmuxPrefixByte ?? 0x02

        TerminalRepresentable(
            sessionManager: sessionManager,
            isStatusExpanded: isStatusExpanded,
            isCoveredByPresentation: isCoveredByPresentation,
            autoConnectTmux: autoConnectTmux,
            tmuxPrefixDisplay: tmuxPrefixDisplay,
            tmuxPrefixByte: tmuxPrefixByte,
            onUserInput: onUserInput
        )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .alert(
                session.pendingSecurityPrompt?.title ?? "",
                isPresented: Binding(
                    get: { session.pendingSecurityPrompt != nil },
                    set: { if !$0 { session.cancelPendingSecurityPrompt() } }
                ),
                presenting: session.pendingSecurityPrompt
            ) { prompt in
                Button(prompt.primaryButtonTitle) {
                    session.pendingSecurityPrompt = nil
                    prompt.onAllow()
                }
                Button("Cancel", role: .cancel) {
                    session.cancelPendingSecurityPrompt()
                }
            } message: { prompt in
                Text(prompt.message)
            }
    }
}

struct TerminalRepresentable: UIViewRepresentable {
    let sessionManager: SessionManager
    var isStatusExpanded: Bool = false
    var isCoveredByPresentation: Bool = false
    var autoConnectTmux: Bool = false
    var tmuxPrefixDisplay: String = "Ctrl-B"
    var tmuxPrefixByte: UInt8 = 0x02
    var onUserInput: (() -> Void)?

    public typealias Coordinator = TerminalSessionContext

    func makeCoordinator() -> Coordinator {
        let ctx = MultiWindowManager.shared.terminalContext(for: sessionManager)
        ctx.onUserInput = onUserInput
        return ctx
    }

    func makeUIView(context: Context) -> FilaireTerminalView {
        let terminalView = context.coordinator.terminalView
        terminalView.removeFromSuperview()
        terminalView.isStatusExpanded = isStatusExpanded
        terminalView.configureTmux(
            enabled: autoConnectTmux,
            prefixTitle: tmuxPrefixDisplay,
            prefixByte: tmuxPrefixByte
        )

        #if DEBUG
        if CommandLine.arguments.contains("--demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                terminalView.feed(text: TerminalRepresentable.demoOutput)
            }
        } else {
            terminalView.scheduleFocusPromotion(delay: 0.1, reason: "initial appearance")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                terminalView.notifyCurrentDimensions()
            }
        }
        #else
        terminalView.scheduleFocusPromotion(delay: 0.1, reason: "initial appearance")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            terminalView.notifyCurrentDimensions()
        }
        #endif
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            terminalView.notifyCurrentDimensions()
        }

        return terminalView
    }

    func updateUIView(_ uiView: FilaireTerminalView, context: Context) {
        context.coordinator.onUserInput = onUserInput
        context.coordinator.isCoveredByPresentation = isCoveredByPresentation
        if isCoveredByPresentation {
            uiView.cancelPendingFocusRequests()
        }
        uiView.isStatusExpanded = isStatusExpanded
        uiView.configureTmux(
            enabled: autoConnectTmux,
            prefixTitle: tmuxPrefixDisplay,
            prefixByte: tmuxPrefixByte
        )
        uiView.updateSizeIfNeeded()
        uiView.refreshCursorAnimation()
    }

    static func dismantleUIView(_ uiView: FilaireTerminalView, coordinator: Coordinator) {
        uiView.removeFromSuperview()
    }

    static func registerOscHandlers(
        terminalView: FilaireTerminalView,
        sessionManager: SessionManager,
        coordinator: Coordinator
    ) {
        let terminal = terminalView.getTerminal()

        // Register OSC 5100 handler for URL opening (fil open <URL>)
        terminal.registerOscHandler(code: 5100) { [weak sessionManager] data in
            guard let text = String(bytes: data, encoding: .utf8) else { return }
            let parts = text.components(separatedBy: ";")
            guard parts.count >= 2, parts[0] == "open" else { return }
            let urlString = parts[1...].joined(separator: ";").trimmingCharacters(in: .whitespacesAndNewlines)
            let url = URL(string: urlString) ?? URL(string: urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")
            guard let validUrl = url else { return }
            DispatchQueue.main.async {
                sessionManager?.handleRemoteUrlOpen(validUrl)
            }
        }

        // Register OSC 5101 handler for native Apple Quick Look file preview (fil preview <file>)
        terminal.registerOscHandler(code: 5101) { [weak sessionManager] data in
            sessionManager?.handleFilePreview(data)
        }

        // Register OSC 777 handler for native notifications (fil notify <msg> [-t title])
        terminal.registerOscHandler(code: 777) { [weak coordinator, weak terminalView, weak sessionManager] data in
            guard sessionManager?.activeHost?.allowRemoteNotifications ?? true else { return }
            guard let text = String(bytes: data, encoding: .utf8) else { return }
            let parts = text.components(separatedBy: ";")
            guard !parts.isEmpty else { return }

            let title: String
            let body: String
            if parts[0] == "notify" {
                if parts.count >= 3 {
                    title = parts[1]
                    body = parts[2...].joined(separator: ";")
                } else if parts.count == 2 {
                    title = ""
                    body = parts[1]
                } else {
                    title = ""
                    body = ""
                }
            } else {
                title = parts[0]
                body = parts.count > 1 ? parts[1...].joined(separator: ";") : ""
            }

            let notifyAction = {
                guard let coordinator = coordinator, let terminalView = terminalView else { return }
                coordinator.notify(source: terminalView, title: title, body: body)
            }
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    notifyAction()
                }
            } else {
                DispatchQueue.main.async(execute: notifyAction)
            }
        }
    }

    static func isAutomatedTerminalResponse(_ data: ArraySlice<UInt8>) -> Bool {
        guard !data.isEmpty else { return true }

        // Mouse reports (SGR: \x1b[<..., X10: \x1b[M...)
        if data.starts(with: [0x1B, 0x5B, 0x3C]) || (data.count >= 3 && data[0] == 0x1B && data[1] == 0x5B && data[2] == 0x4D) {
            return true
        }

        // Focus reports (DECSET 1004): \x1b[I (focus-in) or \x1b[O (focus-out)
        if data == [0x1B, 0x5B, 0x49][...] || data == [0x1B, 0x5B, 0x4F][...] {
            return true
        }

        // OSC query replies: \x1b]...
        if data.starts(with: [0x1B, 0x5D]) {
            return true
        }

        // DCS query replies: \x1bP...
        if data.starts(with: [0x1B, 0x50]) {
            return true
        }

        // CSI automated replies: \x1b[... (DA, DSR, CPR, window ops, mode replies)
        if data.starts(with: [0x1B, 0x5B]), let last = data.last {
            // 'c' = Device Attributes, 'n' = DSR, 'R' = CPR, 't' = Window ops reply, 'y' = Mode reply, 'u' = Kitty keyboard query reply, '{' = DECREQTSR
            if last == UInt8(ascii: "c") || last == UInt8(ascii: "n") || last == UInt8(ascii: "R") ||
               last == UInt8(ascii: "t") || last == UInt8(ascii: "y") || last == UInt8(ascii: "u") ||
               last == UInt8(ascii: "{") {
                return true
            }
        }

        return false
    }

}

@MainActor
public final class TerminalSessionContext: NSObject, @preconcurrency TerminalViewDelegate, FilaireFocusGate {
    public let sessionManager: SessionManager
    public var onUserInput: (() -> Void)?
    public var terminalView: FilaireTerminalView
    public var forceWindowActiveStateForTesting: Bool? = nil

    public init(sessionManager: SessionManager, onUserInput: (() -> Void)? = nil) {
        self.sessionManager = sessionManager
        self.onUserInput = onUserInput
        let view = FilaireTerminalView(frame: .zero)
        self.terminalView = view
        super.init()

        view.terminalDelegate = self
        view.focusGate = self
        view.onInteraction = { [weak self] in
            self?.terminalDidReceiveUserInput()
        }

        // Wire incoming SSH output through bounded filter into SwiftTerm
        sessionManager.onTerminalOutput = { [weak self] bytes in
            self?.terminalView.feedBounded(byteArray: bytes[...])
        }

        sessionManager.onClearTerminal = { [weak self] in
            self?.terminalView.wipeScreen()
        }

        sessionManager.onResetParser = { [weak self] in
            self?.terminalView.resetParserState()
        }

        // Shed memory pressure on system memory warnings or background idle
        sessionManager.onMemoryWarning = { [weak self] in
            self?.terminalView.shedMemoryPressure()
        }

        sessionManager.onShedMemory = { [weak self] in
            self?.terminalView.shedMemoryPressure()
        }

        sessionManager.onRestoreMemory = { [weak self] in
            self?.terminalView.restoreScrollbackLimit()
        }

        TerminalRepresentable.registerOscHandlers(
            terminalView: view,
            sessionManager: sessionManager,
            coordinator: self
        )
    }

    public var focusIntent: SceneFocusIntent = .terminal
    public var isCoveredByPresentation: Bool = false {
        didSet {
            if isCoveredByPresentation {
                focusIntent = .modalPresentation
                terminalView.cancelPendingFocusRequests()
            }
        }
    }

    public func canPromoteTerminalFocus() -> Bool {
        guard !isCoveredByPresentation else { return false }
        guard sessionManager.pendingSecurityPrompt == nil else { return false }
        guard focusIntent == .terminal else { return false }
        return true
    }

    public func terminalDidReceiveUserInput() {
        self.focusIntent = .terminal
        if let hostId = sessionManager.activeHost?.id,
           let scene = MultiWindowManager.shared.findScene(for: hostId) {
            MultiWindowManager.shared.recordInteraction(sessionPersistentIdentifier: scene.session.persistentIdentifier)
        }
    }

    public var memoryScrollbackCap: Int? {
        get { terminalView.memoryScrollbackCap }
        set { terminalView.memoryScrollbackCap = newValue }
    }

    public var hasTrimmedHistory: Bool {
        get { terminalView.hasTrimmedHistory }
        set { if !newValue { terminalView.acknowledgeTrimNotice() } }
    }

    public var isVisible: Bool = false

    public func handleVisibilityChanged(isVisible: Bool) {
        self.isVisible = isVisible
        if isVisible {
            if terminalView.hasTrimmedHistory {
                terminalView.acknowledgeTrimNotice()
                sessionManager.showToast(
                    title: "Terminal History Trimmed",
                    message: "Older scrollback was discarded to free memory while in the background."
                )
            }
            if !MultiWindowManager.shared.isSystemMemoryWarningActive {
                terminalView.restoreScrollbackLimit()
            }
        }
    }

    public func detachView() {
        terminalView.removeFromSuperview()
    }

    public func teardown() {
        detachView()
        terminalView.terminalDelegate = nil
    }

    // Forward user keystrokes to SSH stdin
    public func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if !TerminalRepresentable.isAutomatedTerminalResponse(data) {
            onUserInput?()
            terminalDidReceiveUserInput()
            (source as? FilaireTerminalView)?.ensureCursorActive()
        }
        sessionManager.send(data: Array(data))
    }

    // Forward viewport size changes to SSH PTY
    public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        sessionManager.resize(cols: newCols, rows: newRows)
    }

    public func setTerminalTitle(source: TerminalView, title: String) {
        let sanitized = SessionManager.sanitizeTerminalTitle(title)
        sessionManager.onTerminalTitleChanged?(sanitized)
    }

    public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    public func scrolled(source: TerminalView, position: Double) {
        terminalView.clearUrlHighlight()
    }

    public func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        let effectiveLink = (source as? FilaireTerminalView)?.expandUrlIfWrapped(link: link) ?? link
        guard let url = URL(string: effectiveLink) else { return }
        let isDetectedPlainUrl = params[FilaireTerminalView.detectedUrlParamKey] != nil
        sessionManager.handleTappedLink(url, isDetectedPlainUrl: isDetectedPlainUrl)
    }

    public func bell(source: TerminalView) {
        let style = TerminalSettings.shared.bellStyle
        if style == .visualAndHaptic || style == .hapticOnly {
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.warning)
        }
        if style == .visualAndHaptic || style == .visualOnly {
            (source as? FilaireTerminalView)?.triggerVisualBell()
        }
    }

    public func clipboardCopy(source: TerminalView, content: Data) {
        if sessionManager.handleClipboardWrite(content) {
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
        }
    }

    public func clipboardRead(source: TerminalView) -> Data? {
        sessionManager.handleClipboardReadRequest()
    }

    public func notify(source: TerminalView, title: String, body: String) {
        guard sessionManager.activeHost?.allowRemoteNotifications ?? true else {
            return
        }

        let hostName = sessionManager.activeHost?.displayName ?? "Remote Host"
        let safeTitle = RemoteText.sanitize(title, maxLength: 64)
        let safeBody = RemoteText.sanitize(body, maxLength: 256)
        let effectiveTitle = safeTitle.isEmpty ? "Notification" : safeTitle

        let decision: NotificationPresentationDecision = {
            if let forced = forceWindowActiveStateForTesting {
                return forced ? .inWindowToast : .systemAlert
            }
            #if DEBUG
            if NSClassFromString("XCTestCase") != nil && source.window == nil {
                if let hostId = sessionManager.activeHost?.id,
                   MultiWindowManager.shared.findScene(for: hostId) != nil {
                    return NotificationPresentationPolicy.shared.decision(for: hostId)
                }
                return .inWindowToast
            }
            #endif
            return NotificationPresentationPolicy.shared.decision(for: sessionManager.activeHost?.id)
        }()

        if decision == .inWindowToast {
            // 1. In-window HUD toast banner: ONLY when fired in the currently focused, unobstructed window
            sessionManager.showToast(title: "\(hostName): \(effectiveTitle)", message: safeBody)
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)
        } else {
            // 2. System notification: when covered, backgrounded, or another window is focused
            let content = UNMutableNotificationContent()
            content.title = effectiveTitle
            content.subtitle = "From \(hostName)"
            content.body = safeBody
            content.sound = .default
            if let host = sessionManager.activeHost {
                content.targetContentIdentifier = QuickActionManager.targetContentIdentifier(for: host.id)
                content.userInfo = [QuickActionManager.hostIdUserInfoKey: host.id.uuidString]
            }

            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }
    }

    public func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

#if DEBUG
extension TerminalRepresentable {
    static var demoOutput: String {
        let esc = "\u{1B}"
        if UIDevice.current.userInterfaceIdiom == .phone {
            return """
            \r
            \r
            \r
              \(esc)[1;36m╭────────────╮\(esc)[0m   \(esc)[1;32mdeploy\(esc)[0m\(esc)[38;5;244m@\(esc)[0m\(esc)[1;34mapi-prod-01\(esc)[0m\r
              \(esc)[1;36m│   ######   │\(esc)[0m   \(esc)[1;33mOS:\(esc)[0m Ubuntu 24.04 (ARM64)\r
              \(esc)[1;36m│  ########  │\(esc)[0m   \(esc)[1;33mHost:\(esc)[0m Cloud Compute\r
              \(esc)[1;36m│  ##    ##  │\(esc)[0m   \(esc)[1;33mUptime:\(esc)[0m 28d 14h\r
              \(esc)[1;36m╰────────────╯\(esc)[0m   \(esc)[1;33mShell:\(esc)[0m zsh 5.9 (tmux)\r
            \r
            \(esc)[1;32mdeploy@api\(esc)[0m:\(esc)[1;34m~/api-backend\(esc)[0m \(esc)[35m(main)\(esc)[0m$ \(esc)[1mfil status\(esc)[0m\r
              \(esc)[32m[✓]\(esc)[0m Active tmux: \(esc)[1;36m'k8s-prod'\(esc)[0m (3 windows)\r
              \(esc)[32m[✓]\(esc)[0m SSH Agent: \(esc)[32mconnected\(esc)[0m (\(esc)[1mFace ID\(esc)[0m)\r
              \(esc)[32m[✓]\(esc)[0m CLI bridge: \(esc)[32mready\(esc)[0m (OSC 52/5100/777)\r
            \r
            \(esc)[1;32mdeploy@api\(esc)[0m:\(esc)[1;34m~/api-backend\(esc)[0m \(esc)[35m(main)\(esc)[0m$ \(esc)[1mcargo test\(esc)[0m\r
               \(esc)[1;32mCompiling\(esc)[0m api-backend v1.4.0\r
                \(esc)[1;32mFinished\(esc)[0m test [optimized] in 2.84s\r
            \r
            running 16 tests\r
            test auth::test_jwt ... \(esc)[32mok\(esc)[0m\r
            test cluster::test_leader ... \(esc)[32mok\(esc)[0m\r
            test crypto::test_ed25519 ... \(esc)[32mok\(esc)[0m\r
            test proxy::test_tunnel ... \(esc)[32mok\(esc)[0m\r
            test routes::test_health ... \(esc)[32mok\(esc)[0m\r
            \r
            test result: \(esc)[1;32mok\(esc)[0m. 16 passed; 0 failed\r
            \r
            \(esc)[1;32mdeploy@api\(esc)[0m:\(esc)[1;34m~/api-backend\(esc)[0m \(esc)[35m(main)\(esc)[0m$ █\r
            """
        } else {
            return """
            \r
            \r
              \(esc)[1;36m╭────────────╮\(esc)[0m   \(esc)[1;32mdeploy\(esc)[0m\(esc)[38;5;244m@\(esc)[0m\(esc)[1;34mapi-prod-01\(esc)[0m\r
              \(esc)[1;36m│   ######   │\(esc)[0m   \(esc)[38;5;240m──────────────────────────────\(esc)[0m\r
              \(esc)[1;36m│  ########  │\(esc)[0m   \(esc)[1;33mOS:\(esc)[0m        Ubuntu 24.04 LTS (ARM64)\r
              \(esc)[1;36m│  ##    ##  │\(esc)[0m   \(esc)[1;33mHost:\(esc)[0m      Cloud Compute Instance\r
              \(esc)[1;36m│  ########  │\(esc)[0m   \(esc)[1;33mKernel:\(esc)[0m    Linux 6.8.0-40-generic\r
              \(esc)[1;36m│  ######    │\(esc)[0m   \(esc)[1;33mUptime:\(esc)[0m    28 days, 14 hours, 32 mins\r
              \(esc)[1;36m│            │\(esc)[0m   \(esc)[1;33mPackages:\(esc)[0m  1,428 (dpkg), 12 (snap)\r
              \(esc)[1;36m╰────────────╯\(esc)[0m   \(esc)[1;33mShell:\(esc)[0m     zsh 5.9 (with tmux 3.4)\r
                              \(esc)[1;33mTerminal:\(esc)[0m  Filaire (Solarized Dark)\r
                              \(esc)[1;33mCPU:\(esc)[0m       8 vCPU @ 3.20GHz\r
                              \(esc)[1;33mMemory:\(esc)[0m    4.82 GiB / 31.36 GiB (\(esc)[32m15%\(esc)[0m)\r
                              \(esc)[1;33mDisk (/):\(esc)[0m   42.1 GiB / 120.0 GiB (\(esc)[32m35%\(esc)[0m)\r
            \r
            \(esc)[1;32mdeploy@api-prod-01\(esc)[0m:\(esc)[1;34m~/services/api-backend\(esc)[0m \(esc)[35m(main)\(esc)[0m$ \(esc)[1mfil status\(esc)[0m\r
              \(esc)[32m[✓]\(esc)[0m Active tmux session: \(esc)[1;36m'k8s-prod'\(esc)[0m (3 windows)\r
              \(esc)[32m[✓]\(esc)[0m Biometric SSH Agent: \(esc)[32mconnected\(esc)[0m (\(esc)[1mFace ID\(esc)[0m enabled)\r
              \(esc)[32m[✓]\(esc)[0m Remote companion bridge: \(esc)[32mready\(esc)[0m (OSC 52, 5100, 5101, 777)\r
            \r
            \(esc)[1;32mdeploy@api-prod-01\(esc)[0m:\(esc)[1;34m~/services/api-backend\(esc)[0m \(esc)[35m(main)\(esc)[0m$ \(esc)[1mcargo test --release\(esc)[0m\r
               \(esc)[1;32mCompiling\(esc)[0m api-backend v1.4.0 (/home/deploy/services/api-backend)\r
                \(esc)[1;32mFinished\(esc)[0m release [optimized] target(s) in 2.84s\r
                 \(esc)[1;34mRunning\(esc)[0m unittests src/main.rs (target/release/deps/api-backend)\r
            \r
            running 16 tests\r
            test auth::tests::test_jwt_validation ... \(esc)[32mok\(esc)[0m\r
            test cluster::tests::test_leader_election ... \(esc)[32mok\(esc)[0m\r
            test crypto::tests::test_ed25519_signature ... \(esc)[32mok\(esc)[0m\r
            test proxy::tests::test_tunnel_forwarding ... \(esc)[32mok\(esc)[0m\r
            test routes::tests::test_health_probe ... \(esc)[32mok\(esc)[0m\r
            \r
            test result: \(esc)[1;32mok\(esc)[0m. 16 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out\r
            \r
            \(esc)[1;32mdeploy@api-prod-01\(esc)[0m:\(esc)[1;34m~/services/api-backend\(esc)[0m \(esc)[35m(main)\(esc)[0m$ █\r
            """
        }
    }
}
#endif
