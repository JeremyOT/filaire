import UIKit
import SwiftUI
import Combine
import Network
import LocalAuthentication
import Citadel

public enum ConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case reconnecting(attempt: Int)
    case failed(String)

    public var isBusy: Bool {
        switch self {
        case .connecting, .reconnecting:
            return true
        default:
            return false
        }
    }

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    public var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    public var description: String {
        switch self {
        case .disconnected:
            return "Disconnected"
        case .connecting:
            return "Connecting..."
        case .connected:
            return "Connected"
        case .reconnecting(let attempt):
            return "Reconnecting (attempt \(attempt))..."
        case .failed(let msg):
            return "Connection Failed: \(msg)"
        }
    }
}

public struct InAppToast: Identifiable, Equatable {
    public let id = UUID()
    public let title: String
    public let message: String

    public init(title: String, message: String) {
        self.title = title
        self.message = message
    }
}

public struct SecurityPrompt: Identifiable {
    public let id = UUID()
    public let attemptId: UUID?
    public let title: String
    public let message: String
    public let primaryButtonTitle: String
    public let onAllow: () -> Void
    public let onCancel: (() -> Void)?

    public init(
        attemptId: UUID? = nil,
        title: String,
        message: String,
        primaryButtonTitle: String = "Allow",
        onAllow: @escaping () -> Void,
        onCancel: (() -> Void)? = nil
    ) {
        self.attemptId = attemptId
        self.title = title
        self.message = message
        self.primaryButtonTitle = primaryButtonTitle
        self.onAllow = onAllow
        self.onCancel = onCancel
    }
}

/// Guarantees a host-key decision continuation is resumed exactly once.
private final class HostKeyDecision: @unchecked Sendable {
    private var continuation: CheckedContinuation<Bool, Never>?
    private let lock = NSLock()
    public let attemptId: UUID?

    init(_ continuation: CheckedContinuation<Bool, Never>, attemptId: UUID? = nil) {
        self.continuation = continuation
        self.attemptId = attemptId
    }

    func resume(_ value: Bool) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

public protocol BackgroundTaskProvider: AnyObject, Sendable {
    func beginBackgroundTask(withName name: String?, expirationHandler handler: (() -> Void)?) -> UIBackgroundTaskIdentifier
    func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier)
}

public final class UIKitBackgroundTaskProvider: BackgroundTaskProvider, @unchecked Sendable {
    public static let shared = UIKitBackgroundTaskProvider()
    public init() {}

    public func beginBackgroundTask(withName name: String?, expirationHandler handler: (() -> Void)?) -> UIBackgroundTaskIdentifier {
        UIApplication.shared.beginBackgroundTask(withName: name, expirationHandler: handler)
    }

    public func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier) {
        UIApplication.shared.endBackgroundTask(identifier)
    }
}

@MainActor
@Observable
public final class SessionManager {
    public var state: ConnectionState = .disconnected {
        didSet {
            if oldValue != state {
                onStateChange?(state)
                if state == .disconnected || (!state.isConnected && !state.isBusy) {
                    onDisconnect?()
                }
            }
        }
    }
    public var activeHost: HostProfile? {
        didSet {
            if oldValue?.id != activeHost?.id {
                onActiveHostChange?(activeHost)
            }
        }
    }
    public var allHosts: [HostProfile] = []
    public var availableKeys: [SSHKeyModel] = []
    public var lastError: String?
    public private(set) var lastAttemptedAuth: AttemptedAuthInfo?
    public var onKeyMigrated: ((UUID, String, String) -> Void)?
    public var activeToast: InAppToast? = nil
    public var pendingSecurityPrompt: SecurityPrompt? = nil
    public var onDataSent: (([UInt8]) -> Void)? = nil
    public var onClearTerminal: (() -> Void)? = nil
    public var onIntentionalDisconnect: (() -> Void)? = nil
    public var onTeardownComplete: (@MainActor () -> Void)? = nil
    public var onDisconnect: (() -> Void)? = nil
    public var onStateChange: ((ConnectionState) -> Void)? = nil
    public var onActiveHostChange: ((HostProfile?) -> Void)? = nil
    public private(set) var lastConnectedHostId: UUID? = nil
    private var toastDismissTask: Task<Void, Never>? = nil
    private var currentHostKeyDecision: HostKeyDecision? = nil

    public func cancelPendingSecurityPrompt(for attemptId: UUID? = nil) {
        if let attemptId = attemptId {
            guard pendingSecurityPrompt?.attemptId == attemptId else { return }
        }
        let prompt = pendingSecurityPrompt
        pendingSecurityPrompt = nil
        currentHostKeyDecision?.resume(false)
        currentHostKeyDecision = nil
        prompt?.onCancel?()
    }

    internal func confirmUnknownHostKey(_ entry: KnownHostEntry, attemptId: UUID? = nil) async -> Bool {
        await withCheckedContinuation { continuation in
            MainActor.assumeIsolated {
                if let attemptId = attemptId, self.currentConnectionId != attemptId {
                    continuation.resume(returning: false)
                    return
                }
                cancelPendingSecurityPrompt()
                let once = HostKeyDecision(continuation, attemptId: attemptId)
                self.currentHostKeyDecision = once
                self.pendingSecurityPrompt = SecurityPrompt(
                    attemptId: attemptId,
                    title: "Trust New Host Key?",
                    message: "The authenticity of \(entry.hostname):\(entry.port) can’t be verified.\n\n\(entry.keyType) key fingerprint:\n\(entry.fingerprintSHA256)\n\nOnly trust this key if it matches the server’s fingerprint (e.g. ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub on the server).",
                    primaryButtonTitle: "Trust",
                    onAllow: { [weak self] in
                        if let attemptId = attemptId, self?.currentConnectionId != attemptId {
                            self?.pendingSecurityPrompt = nil
                            self?.currentHostKeyDecision = nil
                            once.resume(false)
                            return
                        }
                        if let host = self?.activeHost, QuickActionManager.shared.isHostDeleted(host.id) {
                            self?.pendingSecurityPrompt = nil
                            self?.currentHostKeyDecision = nil
                            once.resume(false)
                            return
                        }
                        self?.pendingSecurityPrompt = nil
                        self?.currentHostKeyDecision = nil
                        once.resume(true)
                    },
                    onCancel: { [weak self] in
                        self?.pendingSecurityPrompt = nil
                        self?.currentHostKeyDecision = nil
                        once.resume(false)
                    }
                )
            }
        }
    }

    public func wipeTerminal() {
        onClearTerminal?()
    }

    public func showToast(title: String, message: String) {
        toastDismissTask?.cancel()
        withAnimation(.easeInOut(duration: 0.25)) {
            self.activeToast = InAppToast(title: title, message: message)
        }
        toastDismissTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                self.activeToast = nil
            }
        }
    }

    public func requestClipboardReadPermission(hostName: String, onAllow: @escaping () -> Void) {
        self.pendingSecurityPrompt = SecurityPrompt(
            title: "Clipboard Access Request",
            message: "“\(hostName)” is requesting to read your clipboard. If you allow, its current contents will be sent to the server.",
            primaryButtonTitle: "Allow",
            onAllow: onAllow
        )
    }

    public func requestUrlOpenPermission(url: URL, hostName: String, onAllow: @escaping () -> Void) {
        self.pendingSecurityPrompt = SecurityPrompt(
            title: "Open Remote URL",
            message: "“\(hostName)” wants to open:\n\(url.absoluteString)",
            primaryButtonTitle: "Open",
            onAllow: onAllow
        )
    }

    /// Answers a remote OSC 52 clipboard query. The clipboard is only read after the user taps Allow,
    /// so a disabled or declined request never touches it.
    @discardableResult
    public func handleClipboardReadRequest(
        hasStrings: @autoclosure () -> Bool = UIPasteboard.general.hasStrings,
        readPasteboard: @escaping () -> String? = { UIPasteboard.general.string }
    ) -> Data? {
        guard let host = activeHost, host.allowClipboardRead else {
            return nil
        }
        guard hasStrings() else {
            return nil
        }
        guard pendingSecurityPrompt == nil else {
            return nil
        }
        requestClipboardReadPermission(hostName: host.displayName) { [weak self] in
            guard let self = self else { return }
            let currentString = readPasteboard() ?? ""
            if let data = currentString.data(using: .utf8) {
                let base64 = data.base64EncodedString()
                let oscResponse = "\u{1B}]52;c;\(base64)\u{1B}\\"
                self.send(data: Array(oscResponse.utf8))
            }
        }
        return nil
    }

    @discardableResult
    public func handleClipboardWrite(_ content: Data, writePasteboard: (String) -> Void = { UIPasteboard.general.string = $0 }) -> Bool {
        guard let host = activeHost, host.allowClipboardWrite,
              let string = String(data: content, encoding: .utf8) else {
            return false
        }
        writePasteboard(string)
        showToast(title: "Clipboard Updated", message: "Copied \(string.count) characters from \(host.displayName)")
        return true
    }

    public func handleRemoteUrlOpen(_ url: URL, openHandler: @escaping (URL) -> Void = { UIApplication.shared.open($0) }) {
        let policy = activeHost?.urlOpeningPolicy ?? .denyUnusualSchemes
        let hostName = activeHost?.displayName ?? "Remote Host"
        switch policy.action(for: url) {
        case .openImmediately:
            openHandler(url)
        case .promptUser:
            guard pendingSecurityPrompt == nil else { return }
            requestUrlOpenPermission(url: url, hostName: hostName) {
                openHandler(url)
            }
        case .deny:
            break
        }
    }

    /// Handles a link the user tapped. Only plain URLs detected in visible text open without confirmation;
    /// explicit hyperlinks (OSC 8, whose label can differ from the target) and non-web schemes always confirm.
    public func handleTappedLink(_ url: URL, isDetectedPlainUrl: Bool, openHandler: @escaping (URL) -> Void = { UIApplication.shared.open($0) }) {
        let scheme = url.scheme?.lowercased() ?? ""
        if isDetectedPlainUrl && (scheme == "http" || scheme == "https") {
            openHandler(url)
            return
        }
        guard pendingSecurityPrompt == nil else { return }
        requestUrlOpenPermission(url: url, hostName: activeHost?.displayName ?? "Remote Host") {
            openHandler(url)
        }
    }

    public func requestLargePreviewPermission(
        filename: String,
        size: Int64,
        hostName: String,
        onAllow: @escaping () -> Void,
        onCancel: (() -> Void)? = nil
    ) {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let sizeStr = formatter.string(fromByteCount: size)
        self.pendingSecurityPrompt = SecurityPrompt(
            title: "Large File Preview",
            message: "“\(hostName)” is sending “\(filename)” (\(sizeStr)). Previewing large files may affect performance. Do you want to open this preview?",
            primaryButtonTitle: "Preview",
            onAllow: onAllow,
            onCancel: onCancel
        )
    }

    public func handleFilePreview(
        _ data: ArraySlice<UInt8>,
        filePreviewManager: FilePreviewManager? = nil
    ) {
        guard let host = activeHost, host.allowFilePreview else {
            return
        }
        let manager = filePreviewManager ?? self.filePreviewManager
        self.filePreviewManager = manager
        let connectionId = self.currentConnectionId
        let sessionId = connectionId?.uuidString ?? "default"
        manager.handleOscData(
            data,
            sessionId: sessionId,
            onPressureChanged: { [weak self] isPaused in
                DispatchQueue.main.async {
                    self?.updateTerminalReadPaused(preview: isPaused, connectionId: connectionId)
                }
            },
            promptLargePreviewWithCancel: { [weak self] filename, size, onConfirm, onCancel in
                DispatchQueue.main.async {
                    guard let self = self, self.currentConnectionId == connectionId else {
                        onCancel()
                        return
                    }
                    guard self.pendingSecurityPrompt == nil else {
                        onCancel()
                        return
                    }
                    self.requestLargePreviewPermission(
                        filename: filename,
                        size: size,
                        hostName: self.activeHost?.displayName ?? "Remote Host",
                        onAllow: onConfirm,
                        onCancel: onCancel
                    )
                }
            }
        )
    }

    nonisolated(unsafe) public var filePreviewManager: FilePreviewManager = FilePreviewManager()
    internal private(set) var isCoalescerPaused: Bool = false
    internal private(set) var isPreviewPaused: Bool = false

    internal func updateTerminalReadPaused(
        coalescer: Bool? = nil,
        preview: Bool? = nil,
        connectionId: UUID?
    ) {
        guard connectionId == self.currentConnectionId else { return }
        if let coalescer = coalescer {
            self.isCoalescerPaused = coalescer
        }
        if let preview = preview {
            self.isPreviewPaused = preview
        }
        let shouldPause = self.isCoalescerPaused || self.isPreviewPaused
        let service = self.sshService
        Task {
            await service.setTerminalReadPaused(shouldPause)
        }
    }

    internal let sshService: SSHService
    public let notificationCenter: NotificationCenter
    public var backgroundTaskProvider: BackgroundTaskProvider
    nonisolated(unsafe) internal var lifecycleObserverTokens: [NSObjectProtocol] = []
    public var isCoordinatedByWindowManager: Bool = false
    public private(set) var lifecycleGeneration: Int = 0
    public private(set) var isShutdown: Bool = false
    private var activeBackgroundTasks: Set<UIBackgroundTaskIdentifier> = []
    private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
    internal var reconnectTask: Task<Void, Never>?
    public var maxReconnectAttempts: Int = 10
    public internal(set) var reconnectAttempt = 0
    internal var stableConnectionThreshold: TimeInterval = 10.0
    private var connectionEstablishedTime: ContinuousClock.Instant?
    internal var nowProvider: @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    internal private(set) var isIntentionalDisconnect = false
    public private(set) var isAppInBackground = false

    /// Computes sensible fallback terminal column/row counts using screen geometry and font size
    public static func estimatedTerminalDimensions() -> (cols: Int, rows: Int) {
        let screen = UIScreen.main.bounds
        let width = max(320, screen.width)
        let height = max(480, screen.height - 100) // account for status overlay and keyboard accessories
        let fontSize = FontManager.shared.fontSize
        let charWidth = max(6.0, fontSize * 0.6)
        let charHeight = max(12.0, fontSize * 1.25)
        let cols = max(40, Int(width / charWidth))
        let rows = max(20, Int(height / charHeight))
        return (cols, rows)
    }

    // Network Handover Monitoring
    private let pathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "io.o-t.filaire.networkmonitor")
    private var lastPathStatus: NWPath.Status?
    private var lastInterfaceType: NWInterface.InterfaceType?

    // High-Throughput Stream Coalescing
    private var outputCoalescer: OutputCoalescer?

    // Resize Throttling (Debouncing Stage Manager & rotation reflow storms)
    private var pendingResizeTask: Task<Void, Never>?
    public private(set) var pendingCols: Int?
    public private(set) var pendingRows: Int?
    private var lastResizeDispatchTime: ContinuousClock.Instant?
    private let clock = ContinuousClock()

    /// Closure invoked when output is received from SSH, to be fed into TerminalView
    public var onTerminalOutput: (([UInt8]) -> Void)?

    /// Closure invoked when a new transport begins or reconnection occurs, resetting parser boundary state
    public var onResetParser: (() -> Void)?

    /// Closure invoked when low memory warning occurs, to shed non-essential terminal buffers
    public var onMemoryWarning: (() -> Void)?

    /// Closure invoked to proactively shed excess scrollback to reduce memory footprint
    public var onShedMemory: (() -> Void)?

    /// Closure invoked to restore the full configured scrollback limit
    public var onRestoreMemory: (() -> Void)?

    /// Closure invoked when the remote terminal updates the window title (via OSC 0/2)
    public var onTerminalTitleChanged: ((String) -> Void)?

    /// Sanitizes remote terminal window titles by stripping non-printable control characters,
    /// trimming whitespace, and bounding maximum length.
    nonisolated public static func sanitizeTerminalTitle(_ title: String) -> String {
        let cleaned = title.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .map(String.init)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(cleaned.prefix(100))
    }

    private var backgroundMemoryShedTask: Task<Void, Never>?

    public func scheduleBackgroundMemoryShed(after seconds: TimeInterval = 120) {
        guard TerminalSettings.shared.aggressiveBackgroundTrimmingEnabled else { return }
        backgroundMemoryShedTask?.cancel()
        backgroundMemoryShedTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.onShedMemory?()
        }
    }

    public func cancelBackgroundMemoryShed() {
        backgroundMemoryShedTask?.cancel()
        backgroundMemoryShedTask = nil
    }

    public func shedMemory() {
        cancelBackgroundMemoryShed()
        onShedMemory?()
    }

    public func restoreMemory() {
        cancelBackgroundMemoryShed()
        onRestoreMemory?()
    }

    public init(
        sshService: SSHService = SSHService(),
        notificationCenter: NotificationCenter = .default,
        backgroundTaskProvider: BackgroundTaskProvider = UIKitBackgroundTaskProvider.shared
    ) {
        self.sshService = sshService
        self.notificationCenter = notificationCenter
        self.backgroundTaskProvider = backgroundTaskProvider
        self.outputCoalescer = OutputCoalescer(
            onFlush: { [weak self] chunk in
                MainActor.assumeIsolated {
                    self?.onTerminalOutput?(chunk)
                }
            },
            onBackpressure: { [weak self] isPaused in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.updateTerminalReadPaused(coalescer: isPaused, connectionId: self.currentConnectionId)
                }
            }
        )
        setupNetworkMonitoring()
        setupLifecycleObservers()
    }

    deinit {
        pathMonitor.cancel()
        for token in lifecycleObserverTokens {
            notificationCenter.removeObserver(token)
        }
        lifecycleObserverTokens.removeAll()
        filePreviewManager.shutdown()
        let service = self.sshService
        Task {
            await service.disconnect()
        }
    }

    public func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true

        isConnecting = false
        connectTask?.cancel()
        connectTask = nil
        healthCheckTask?.cancel()
        healthCheckTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        pendingResizeTask?.cancel()
        pendingResizeTask = nil
        toastDismissTask?.cancel()
        toastDismissTask = nil
        outboundDrainTask?.cancel()
        outboundDrainTask = nil
        cancelBackgroundMemoryShed()
        cancelPendingSecurityPrompt()

        removeLifecycleObservers()
        pathMonitor.cancel()
        endBackgroundTask()
        filePreviewManager.shutdown()

        outputCoalescer?.reset()
        outputCoalescer?.releaseStorage()
        clearOutbound()

        let service = self.sshService
        Task {
            await service.disconnect()
        }

        self.state = .disconnected
        self.activeHost = nil
        self.lastConnectedHostId = nil
        self.activeToast = nil
    }

    public func discard() {
        shutdown()
    }

    internal var isConnecting = false
    internal var connectTask: Task<Void, Never>?
    private var healthCheckTask: Task<Void, Never>?
    internal var currentConnectionId: UUID? = nil

    // MARK: - Public Control API

    public enum DisconnectReason: Equatable {
        case userInitiated
        case hostDeleted
        case connectionReplaced
        case sessionDiscarded
        case error
    }

    public func connect(
        to host: HostProfile,
        allHosts: [HostProfile] = [],
        allKeys: [SSHKeyModel] = [],
        cols: Int? = nil,
        rows: Int? = nil,
        isResume: Bool = false
    ) {
        let isDeleted = QuickActionManager.shared.isHostDeleted(host.id)
        guard !isDeleted else {
            self.isConnecting = false
            self.state = .disconnected
            self.activeHost = nil
            return
        }

        let targetHost = allHosts.first(where: { $0.id == host.id }) ?? self.allHosts.first(where: { $0.id == host.id }) ?? host

        let isHostSwitch = (activeHost != nil && activeHost?.id != targetHost.id)
        if isHostSwitch {
            cancelPendingSecurityPrompt()
            if let oldId = self.currentConnectionId?.uuidString {
                filePreviewManager.cancelSession(oldId)
            }
            self.currentConnectionId = nil
            self.isCoalescerPaused = false
            self.isPreviewPaused = false
            self.clearOutbound()
        }
        self.isResumingSession = isResume
        if isConnecting {
            if activeHost?.id == targetHost.id {
                return
            }
            cancelPendingSecurityPrompt()
            connectTask?.cancel()
            connectTask = nil
            isConnecting = false
        }
        self.isIntentionalDisconnect = false
        self.lifecycleGeneration += 1
        self.activeHost = targetHost
        if !allHosts.isEmpty {
            self.allHosts = allHosts
        }
        if !allKeys.isEmpty {
            self.availableKeys = allKeys
        }
        self.state = .connecting
        self.lastError = nil
        self.reconnectAttempt = 0
        self.reconnectTask?.cancel()
        self.reconnectTask = nil
        self.healthCheckTask?.cancel()
        self.healthCheckTask = nil
        self.isConnecting = true

        let defaultDim = SessionManager.estimatedTerminalDimensions()
        let effectiveCols = cols ?? self.pendingCols ?? defaultDim.cols
        let effectiveRows = rows ?? self.pendingRows ?? defaultDim.rows

        connectTask?.cancel()
        connectTask = Task {
            await performConnect(host: targetHost, cols: effectiveCols, rows: effectiveRows)
        }
    }

    public func reconnect() {
        guard let host = activeHost, !isConnecting else { return }
        guard !QuickActionManager.shared.isHostDeleted(host.id) else {
            cancelReconnect()
            self.activeHost = nil
            self.state = .disconnected
            return
        }
        reconnectAttempt = 0
        connect(to: host, allHosts: self.allHosts, isResume: true)
    }

    public func cancelReconnect() {
        self.reconnectTask?.cancel()
        self.reconnectTask = nil
        self.reconnectAttempt = 0
        if case .reconnecting = self.state {
            self.state = .disconnected
        }
    }

    public func disconnect(
        clearActiveHost: Bool = false,
        isUserInitiated: Bool = true,
        reason: DisconnectReason? = nil
    ) {
        let isDeletion = (reason == .hostDeleted)
        let effectiveClearActiveHost = clearActiveHost || isDeletion
        let effectiveUserInitiated = isDeletion ? false : isUserInitiated

        if let oldId = self.currentConnectionId?.uuidString {
            filePreviewManager.cancelSession(oldId)
        }
        self.currentConnectionId = nil
        self.isCoalescerPaused = false
        self.isPreviewPaused = false
        self.isIntentionalDisconnect = true
        self.isConnecting = false
        self.connectTask?.cancel()
        self.connectTask = nil
        self.healthCheckTask?.cancel()
        self.healthCheckTask = nil
        self.pendingResizeTask?.cancel()
        self.pendingResizeTask = nil
        cancelBackgroundMemoryShed()
        endBackgroundTask()
        cancelPendingSecurityPrompt()
        cancelReconnect()
        self.state = .disconnected
        if effectiveClearActiveHost {
            self.activeHost = nil
            self.lastConnectedHostId = nil
            if isDeletion {
                self.lastError = nil
            }
        }
        outputCoalescer?.reset()
        clearOutbound()

        Task {
            await sshService.disconnect()
            await MainActor.run {
                self.onTeardownComplete?()
                self.onTeardownComplete = nil
            }
        }
        if effectiveUserInitiated {
            onIntentionalDisconnect?()
        }
    }

    public static let maxOutboundBufferSize: Int = 512 * 1024 // 512 KB
    private var outboundQueue: [[UInt8]] = []
    private var outboundReadIndex: Int = 0
    private var queuedBytes: Int = 0
    private var inFlightBytes: Int = 0
    private var isSendingOutbound = false
    private var outboundDrainTask: Task<Void, Never>? = nil
    private var isResumingSession = false
    private var didWarnDiscardedInput = false
    private var didWarnDroppedInput = false
    internal var sshWriterForTesting: (([UInt8]) async throws -> Void)? = nil

    /// Total pending outbound bytes: queued in memory plus currently in flight to the SSH transport.
    public var pendingOutboundBufferSize: Int {
        queuedBytes + inFlightBytes
    }

    internal func clearOutbound() {
        outboundDrainTask?.cancel()
        outboundDrainTask = nil
        outboundQueue.removeAll()
        outboundReadIndex = 0
        queuedBytes = 0
        inFlightBytes = 0
        isSendingOutbound = false
    }

    /// Input is only accepted for an established session or a fresh connect; keystrokes typed while a
    /// session is down would otherwise replay out of context into the next shell.
    internal var acceptsInput: Bool {
        switch state {
        case .connected:
            return true
        case .connecting:
            return !isResumingSession
        case .disconnected, .reconnecting, .failed:
            return false
        }
    }

    public func send(data: [UInt8]) {
        guard !data.isEmpty else { return }
        onDataSent?(data)
        guard acceptsInput else {
            if !didWarnDiscardedInput {
                didWarnDiscardedInput = true
                showToast(title: "Not Connected", message: "Input typed while disconnected was discarded.")
            }
            return
        }

        let (totalPending, overflow1) = queuedBytes.addingReportingOverflow(inFlightBytes)
        let (projected, overflow2) = totalPending.addingReportingOverflow(data.count)
        if overflow1 || overflow2 || projected > Self.maxOutboundBufferSize {
            if !didWarnDroppedInput {
                didWarnDroppedInput = true
                showToast(title: "Input Dropped", message: "The input exceeds available buffer capacity and was discarded.")
            }
            return
        }

        outboundQueue.append(data)
        queuedBytes += data.count

        if state == .connected && !isSendingOutbound {
            if currentConnectionId == nil {
                currentConnectionId = UUID()
            }
            drainOutbound(for: currentConnectionId)
        }
    }

    private func drainOutbound(for connectionId: UUID?) {
        guard let connectionId = connectionId, connectionId == self.currentConnectionId else {
            isSendingOutbound = false
            return
        }
        guard state == .connected else {
            isSendingOutbound = false
            return
        }
        guard outboundReadIndex < outboundQueue.count else {
            isSendingOutbound = false
            didWarnDroppedInput = false
            return
        }

        isSendingOutbound = true
        let chunk = outboundQueue[outboundReadIndex]
        outboundReadIndex += 1
        queuedBytes -= chunk.count
        inFlightBytes = chunk.count

        if outboundReadIndex == outboundQueue.count {
            outboundQueue.removeAll(keepingCapacity: false)
            outboundReadIndex = 0
        }

        outboundDrainTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                if let writer = self.sshWriterForTesting {
                    try await writer(chunk)
                } else {
                    try await self.sshService.send(data: chunk)
                }
                guard !Task.isCancelled, self.currentConnectionId == connectionId else {
                    self.inFlightBytes = 0
                    self.isSendingOutbound = false
                    return
                }
                self.inFlightBytes = 0
                self.drainOutbound(for: connectionId)
            } catch {
                guard !Task.isCancelled, self.currentConnectionId == connectionId else {
                    self.inFlightBytes = 0
                    self.isSendingOutbound = false
                    return
                }
                self.inFlightBytes = 0
                self.handleWriteFailure(error: error, connectionId: connectionId)
            }
        }
    }

    internal func handleWriteFailure(error: Error, connectionId: UUID) {
        guard self.currentConnectionId == connectionId else { return }
        clearOutbound()
        showToast(title: "Write Failed", message: "Failed to send input to host. Unsent input was discarded.")
        Task {
            await sshService.disconnect()
        }
        handleDisconnect(error: error)
    }

    // MARK: - Tmux Quick Actions

    public func triggerTmuxWindowNumber(_ num: Int) {
        guard let host = activeHost, host.autoConnectTmux else { return }
        guard let char = String(num).utf8.first else { return }
        send(data: [host.tmuxPrefixByte, char])
    }

    public func triggerTmuxNextWindow() {
        guard let host = activeHost, host.autoConnectTmux else { return }
        send(data: [host.tmuxPrefixByte, UInt8(ascii: "n")])
    }

    public func triggerTmuxPrevWindow() {
        guard let host = activeHost, host.autoConnectTmux else { return }
        send(data: [host.tmuxPrefixByte, UInt8(ascii: "p")])
    }

    public func triggerTmuxNewWindow() {
        guard let host = activeHost, host.autoConnectTmux else { return }
        send(data: [host.tmuxPrefixByte, UInt8(ascii: "c")])
    }

    public func triggerTmuxSplitVertical() {
        guard let host = activeHost, host.autoConnectTmux else { return }
        // Bound to split-window -h -c "#{pane_current_path}" by HostProfile.tmuxStartupCommand
        send(data: Array("\u{1b}[9990~".utf8))
    }

    public func triggerTmuxSplitHorizontal() {
        guard let host = activeHost, host.autoConnectTmux else { return }
        // Bound to split-window -v -c "#{pane_current_path}" by HostProfile.tmuxStartupCommand
        send(data: Array("\u{1b}[9991~".utf8))
    }

    public func triggerTmuxZoomPane() {
        guard let host = activeHost, host.autoConnectTmux else { return }
        send(data: [host.tmuxPrefixByte, UInt8(ascii: "z")])
    }

    public func triggerTmuxClosePane() {
        guard let host = activeHost, host.autoConnectTmux else { return }
        send(data: [host.tmuxPrefixByte, UInt8(ascii: "x")])
    }

    public func triggerTmuxNextPane() {
        guard let host = activeHost, host.autoConnectTmux else { return }
        send(data: [host.tmuxPrefixByte, UInt8(ascii: "o")])
    }

    public func triggerTmuxLastPane() {
        guard let host = activeHost, host.autoConnectTmux else { return }
        send(data: [host.tmuxPrefixByte, UInt8(ascii: ";")])
    }

    public func triggerTmuxRenameWindow() {
        guard let host = activeHost, host.autoConnectTmux else { return }
        send(data: [host.tmuxPrefixByte, UInt8(ascii: ",")])
    }

    public func resize(cols: Int, rows: Int) {
        pendingCols = cols
        pendingRows = rows
        let now = clock.now
        let shouldDispatchImmediately: Bool
        if let last = lastResizeDispatchTime {
            shouldDispatchImmediately = (now - last) > .milliseconds(150)
        } else {
            shouldDispatchImmediately = true
        }

        pendingResizeTask?.cancel()
        if shouldDispatchImmediately {
            lastResizeDispatchTime = now
            Task {
                await self.sshService.resize(cols: cols, rows: rows)
            }
        } else {
            pendingResizeTask = Task {
                try? await Task.sleep(for: .milliseconds(60))
                guard !Task.isCancelled, let c = self.pendingCols, let r = self.pendingRows else { return }
                self.lastResizeDispatchTime = self.clock.now
                await self.sshService.resize(cols: c, rows: r)
            }
        }
    }

    // MARK: - Internal Connection Lifecycle

    private func performConnect(host: HostProfile, cols: Int, rows: Int) async {
        guard !QuickActionManager.shared.isHostDeleted(host.id) else {
            self.isConnecting = false
            self.state = .disconnected
            self.activeHost = nil
            return
        }

        let connectionId = UUID()
        self.currentConnectionId = connectionId

        // On host switches, clear old terminal contents before connecting to avoid erasing the new host's prompt
        if self.lastConnectedHostId != nil && self.lastConnectedHostId != host.id {
            self.onClearTerminal?()
        }
        self.lastConnectedHostId = host.id

        // Close any existing session before authenticating, so a cancelled or failed attempt never
        // leaves the previous connection, port forwards, or agent forwarding running in the background
        await sshService.disconnect()

        guard !Task.isCancelled, self.currentConnectionId == connectionId else {
            if self.currentConnectionId == connectionId {
                self.isConnecting = false
            }
            return
        }

        let coalescer = self.outputCoalescer
        coalescer?.reset()

        do {
            var effectiveContext: LAContext? = nil
            if host.requireBiometrics {
                effectiveContext = try await BiometricAuthService.authenticate(
                    reason: "Authenticate with \(BiometricAuthService.biometryName) to connect to \(host.displayName)"
                )
            }

            guard !Task.isCancelled, self.currentConnectionId == connectionId else {
                if self.currentConnectionId == connectionId {
                    self.isConnecting = false
                }
                return
            }

            self.onResetParser?()
            let coalescerGen = coalescer?.currentGeneration
            try await sshService.connect(
                host: host,
                allHosts: self.allHosts,
                allKeys: self.availableKeys,
                initialCols: cols,
                initialRows: rows,
                authContext: effectiveContext,
                onKeyResolved: { [weak self] keyId, keyType, pubKey in
                    Task { @MainActor in
                        self?.onKeyMigrated?(keyId, keyType, pubKey)
                    }
                },
                onUnknownHostKey: { [weak self] entry in
                    guard let self = self else { return false }
                    return await self.confirmUnknownHostKey(entry, attemptId: connectionId)
                },
                onOutput: { [weak coalescer] bytes in
                    coalescer?.append(bytes, generation: coalescerGen)
                },
                onDisconnect: { [weak self] error in
                    Task { @MainActor in
                        guard let self = self, self.currentConnectionId == connectionId else {
                            return
                        }
                        self.handleDisconnect(error: error, connectionId: connectionId)
                    }
                },
                onPortForwardFailed: { [weak self] rule, error in
                    Task { @MainActor in
                        guard let self = self, self.currentConnectionId == connectionId else { return }
                        self.showToast(title: "Port Forward Failed", message: "Local port \(rule.localPort): \(error.localizedDescription)")
                    }
                }
            )

            guard !Task.isCancelled, self.currentConnectionId == connectionId else {
                if self.currentConnectionId == connectionId {
                    self.isConnecting = false
                }
                return
            }

            self.connectionEstablishedTime = self.nowProvider()
            self.lastAttemptedAuth = await sshService.lastAttemptedAuth
            self.state = .connected
            self.didWarnDiscardedInput = false
            self.isResumingSession = false
            self.isConnecting = false

            // Drain any keystrokes that accumulated while connecting or reconnecting
            if !self.outboundQueue.isEmpty && !self.isSendingOutbound {
                self.drainOutbound(for: connectionId)
            }

            // Ensure SSH service is synchronized with latest terminal dimensions
            if let c = self.pendingCols, let r = self.pendingRows {
                Task {
                    await self.sshService.resize(cols: c, rows: r)
                }
            }
        } catch {
            guard !Task.isCancelled, self.currentConnectionId == connectionId else {
                if self.currentConnectionId == connectionId {
                    self.isConnecting = false
                }
                return
            }
            self.isConnecting = false
            await handleConnectFailure(error: error, attemptId: connectionId)
        }
    }

    internal func handleConnectFailure(error: Error, attemptId: UUID? = nil) async {
        // Capture before resetting: was this attempt part of an auto-reconnect cycle or a session resume?
        let attemptsSoFar = self.reconnectAttempt
        let wasResuming = self.isResumingSession

        if let oldId = self.currentConnectionId?.uuidString {
            filePreviewManager.cancelSession(oldId)
        }
        cancelPendingSecurityPrompt(for: attemptId)
        self.currentConnectionId = nil
        self.isCoalescerPaused = false
        self.isPreviewPaused = false
        self.connectionEstablishedTime = nil
        self.isConnecting = false
        self.reconnectTask?.cancel()
        self.reconnectTask = nil
        self.reconnectAttempt = 0

        guard !isIntentionalDisconnect else {
            self.state = .disconnected
            return
        }

        let auth = await self.sshService.lastAttemptedAuth
        self.lastAttemptedAuth = auth

        // Cleanly handle user cancellation across BiometricError, LAError, CancellationError, or error string
        if let bioErr = error as? BiometricError, bioErr == .userCancelled {
            self.state = .disconnected
            self.lastError = bioErr.localizedDescription
            return
        }

        if let laError = error as? LAError,
           (laError.code == .userCancel || laError.code == .appCancel || laError.code == .systemCancel) {
            self.state = .disconnected
            self.lastError = "Authentication was cancelled by the user."
            return
        }

        if let hostKeyError = error as? HostKeyMismatchError, case .hostKeyNotTrusted = hostKeyError {
            self.isIntentionalDisconnect = true
            self.state = .disconnected
            self.lastError = hostKeyError.localizedDescription
            return
        }

        if error is CancellationError {
            self.state = .disconnected
            self.lastError = "Connection cancelled"
            return
        }

        let errorMessage = SessionManager.formatErrorMessage(error, for: activeHost, authInfo: auth)
        if errorMessage.lowercased().contains("cancel") {
            self.state = .disconnected
            self.lastError = errorMessage
            return
        }

        if attemptsSoFar > 0 || wasResuming,
           Self.isRetryableConnectError(error),
           !isAppInBackground,
           attemptsSoFar < maxReconnectAttempts,
           activeHost != nil {
            let attempt = attemptsSoFar + 1
            self.reconnectAttempt = attempt
            self.lastError = errorMessage
            self.state = .reconnecting(attempt: attempt)
            let retryId = UUID()
            self.currentConnectionId = retryId
            scheduleReconnect(delaySeconds: Self.reconnectDelay(forAttempt: attempt), connectionId: retryId)
            return
        }

        self.lastError = errorMessage
        self.state = .failed(errorMessage)
    }

    /// Whether a failed connection attempt is worth retrying automatically. Credential, host-key,
    /// biometric and cancellation failures need the user; network-level failures do not.
    nonisolated static func isRetryableConnectError(_ error: Error) -> Bool {
        if error is CancellationError || error is BiometricError || error is LAError ||
            error is HostKeyMismatchError || error is SSHClientError {
            return false
        }
        if let sshError = error as? SSHError {
            switch sshError {
            case .channelClosed, .notConnected:
                return true
            case .invalidCredentials, .keyNotFound, .negotiationFailed, .terminalSetupFailed, .terminalSetupTimedOut:
                return false
            }
        }
        if "\(error)".contains("allAuthenticationOptionsFailed") {
            return false
        }
        return true
    }

    nonisolated public static func formatErrorMessage(
        _ error: Error,
        for host: HostProfile?,
        authInfo: AttemptedAuthInfo? = nil
    ) -> String {
        if let sshError = error as? SSHError {
            return sshError.localizedDescription
        }

        let username = host?.username ?? "user"
        let raw = "\(error)"
        let desc = error.localizedDescription

        if let clientError = error as? SSHClientError {
            switch clientError {
            case .allAuthenticationOptionsFailed:
                if let auth = authInfo, auth.rawKeyType == "ssh-rsa" {
                    let keyName = auth.keyName ?? "RSA Key"
                    return "Authentication failed: Remote server rejected RSA key '\(keyName)' for user '\(username)' (Citadel.SSHClientError 4).\n\n⚠️ OpenSSH 8.8+ (Debian 12+, Ubuntu 22.04+, macOS) disables 'ssh-rsa' (SHA-1) by default.\n\nRecommended Solutions:\n1. Generate an Ed25519 key in Filaire and add its public key to ~/.ssh/authorized_keys.\n2. Or to keep using RSA, on your server add 'PubkeyAcceptedAlgorithms +ssh-rsa' to /etc/ssh/sshd_config and restart sshd."
                } else if let auth = authInfo, let pubKey = auth.publicKey {
                    let keyName = auth.keyName ?? "key"
                    return "Authentication failed: Remote server rejected key '\(keyName)' for user '\(username)' (Citadel.SSHClientError 4).\n\nEnsure this EXACT public key is in ~/.ssh/authorized_keys on your server:\n\(pubKey)"
                }
                return "Authentication failed: Remote server rejected credentials for user '\(username)' (Citadel.SSHClientError 4). Verify your username and that your public key is in ~/.ssh/authorized_keys."
            case .unsupportedPasswordAuthentication:
                return "Authentication failed: Remote server does not support password authentication (Citadel.SSHClientError 0)."
            case .unsupportedPrivateKeyAuthentication:
                return "Authentication failed: Remote server does not support public key authentication (Citadel.SSHClientError 1)."
            case .unsupportedHostBasedAuthentication:
                return "Authentication failed: Remote server does not support host-based authentication (Citadel.SSHClientError 2)."
            case .channelCreationFailed:
                return "Connection established, but server refused to open an SSH channel (Citadel.SSHClientError 3)."
            }
        }

        if raw.contains("allAuthenticationOptionsFailed") || raw.contains("SSHClientError 4") || desc.contains("SSHClientError 4") {
            if let auth = authInfo, auth.rawKeyType == "ssh-rsa" {
                let keyName = auth.keyName ?? "RSA Key"
                return "Authentication failed: Remote server rejected RSA key '\(keyName)' for user '\(username)' (Citadel.SSHClientError 4).\n\n⚠️ OpenSSH 8.8+ (Debian 12+, Ubuntu 22.04+, macOS) disables 'ssh-rsa' (SHA-1) by default.\n\nRecommended Solutions:\n1. Generate an Ed25519 key in Filaire and add its public key to ~/.ssh/authorized_keys.\n2. Or to keep using RSA, on your server add 'PubkeyAcceptedAlgorithms +ssh-rsa' to /etc/ssh/sshd_config and restart sshd."
            } else if let auth = authInfo, let pubKey = auth.publicKey {
                let keyName = auth.keyName ?? "key"
                return "Authentication failed: Remote server rejected key '\(keyName)' for user '\(username)' (Citadel.SSHClientError 4).\n\nEnsure this EXACT public key is in ~/.ssh/authorized_keys on your server:\n\(pubKey)"
            }
            return "Authentication failed: Remote server rejected credentials for user '\(username)' (Citadel.SSHClientError 4). Verify your username and that your public key is in ~/.ssh/authorized_keys."
        }

        return desc
    }

    internal func markConnectedForTesting() {
        self.state = .connected
        self.connectionEstablishedTime = self.nowProvider()
    }

    internal func forceStateForTesting(_ newState: ConnectionState) {
        self.state = newState
    }

    internal func handleDisconnect(error: Error?, connectionId: UUID? = nil) {
        if let connId = connectionId {
            cancelPendingSecurityPrompt(for: connId)
        }
        guard !isIntentionalDisconnect else {
            self.connectionEstablishedTime = nil
            self.state = .disconnected
            return
        }

        let connectedDuration: Duration? = {
            guard let established = self.connectionEstablishedTime else { return nil }
            return self.nowProvider() - established
        }()
        self.connectionEstablishedTime = nil

        if let duration = connectedDuration, duration >= .seconds(self.stableConnectionThreshold) {
            self.reconnectAttempt = 0
        }

        if let error = error {
            self.lastError = SessionManager.formatErrorMessage(error, for: activeHost, authInfo: lastAttemptedAuth)
        }

        // If disconnected while app is in background, avoid spinning suspended reconnect timers.
        // Upon returning to foreground, handleAppForegrounded() will automatically reconnect.
        if isAppInBackground {
            self.currentConnectionId = nil
            self.state = .failed(self.lastError ?? "Connection timed out in background")
            return
        }

        // Auto-reconnect ONLY when an active session dropped unexpectedly
        if let _ = self.currentConnectionId, reconnectAttempt < maxReconnectAttempts {
            reconnectAttempt += 1
            self.state = .reconnecting(attempt: reconnectAttempt)
            let retryId = UUID()
            self.currentConnectionId = retryId
            scheduleReconnect(delaySeconds: Self.reconnectDelay(forAttempt: reconnectAttempt), connectionId: retryId)
        } else {
            self.currentConnectionId = nil
            self.state = .failed(self.lastError ?? "Disconnected")
        }
    }

    /// Exponential backoff (1.5x, capped at 20 s) with jitter for the given 1-based attempt
    nonisolated static func reconnectDelay(forAttempt attempt: Int) -> Double {
        let baseDelay = min(pow(1.5, Double(max(1, attempt) - 1)), 20.0)
        return baseDelay + Double.random(in: 0.1...0.6)
    }

    private func scheduleReconnect(delaySeconds: Double, connectionId: UUID) {
        reconnectTask?.cancel()
        reconnectTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            guard !Task.isCancelled,
                  self.currentConnectionId == connectionId,
                  let host = self.activeHost,
                  !self.isIntentionalDisconnect,
                  !QuickActionManager.shared.isHostDeleted(host.id) else { return }
            await self.performConnect(host: host, cols: self.pendingCols ?? 80, rows: self.pendingRows ?? 24)
        }
    }

    // MARK: - App Lifecycle & Foreground Validation

    private func setupLifecycleObservers() {
        let fgToken = notificationCenter.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, !self.isShutdown else { return }
                guard !self.isCoordinatedByWindowManager else { return }
                self.handleAppForegrounded()
            }
        }
        lifecycleObserverTokens.append(fgToken)

        let bgToken = notificationCenter.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, !self.isShutdown else { return }
                guard !self.isCoordinatedByWindowManager else { return }
                self.handleAppBackgrounded()
            }
        }
        lifecycleObserverTokens.append(bgToken)

        let memToken = notificationCenter.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, !self.isShutdown else { return }
                guard !self.isCoordinatedByWindowManager else { return }
                self.handleMemoryWarning()
            }
        }
        lifecycleObserverTokens.append(memToken)

        let termToken = notificationCenter.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, !self.isShutdown else { return }
                self.handleAppTerminating()
            }
        }
        lifecycleObserverTokens.append(termToken)
    }

    public func removeLifecycleObservers() {
        for token in lifecycleObserverTokens {
            notificationCenter.removeObserver(token)
        }
        lifecycleObserverTokens.removeAll()
    }

    /// Gracefully closes session before process termination
    public func handleAppTerminating() {
        isIntentionalDisconnect = true
        reconnectTask?.cancel()
        Task {
            await sshService.disconnect()
        }
    }

    /// Sheds non-essential memory buffers under system memory pressure
    public func handleMemoryWarning() {
        outputCoalescer?.releaseStorage()
        onMemoryWarning?()
    }

    /// Validates active session on foreground and automatically reconnects if connection dropped in background
    public func handleAppForegrounded() {
        guard isAppInBackground else { return }
        isAppInBackground = false
        endBackgroundTask()

        guard activeHost != nil, !isIntentionalDisconnect else { return }

        switch state {
        case .connected:
            // Session was active; actively probe remote host with deadline to detect dropped TCP
            let connectionId = self.currentConnectionId
            healthCheckTask?.cancel()
            healthCheckTask = Task {
                let healthy = await sshService.ping(timeout: 3.0)
                guard !Task.isCancelled,
                      let connectionId = connectionId,
                      self.currentConnectionId == connectionId,
                      self.state == .connected,
                      !self.isIntentionalDisconnect else { return }
                if !healthy {
                    reconnect()
                } else if let c = pendingCols, let r = pendingRows {
                    await sshService.resize(cols: c, rows: r)
                }
            }
        case .reconnecting:
            // App was suspended while reconnect was pending; trigger immediate reconnect
            reconnectTask?.cancel()
            reconnectTask = nil
            reconnect()
        case .failed, .disconnected:
            // Connection dropped or failed while in the background; automatically reconnect
            reconnect()
        case .connecting:
            // Ongoing connection attempt in progress
            break
        }
    }

    public func handleAppBackgrounded() {
        guard !isAppInBackground else { return }
        isAppInBackground = true
        if TerminalSettings.shared.aggressiveBackgroundTrimmingEnabled {
            shedMemory()
        }

        // Do not begin a keep-alive task for a session that has no transport or connection work to protect.
        guard state.isConnected || state.isBusy || isConnecting else { return }

        // Avoid beginning a new background task while an old token is still outstanding.
        if backgroundTaskId != .invalid {
            endBackgroundTask()
        }

        lifecycleGeneration += 1
        let currentGen = lifecycleGeneration

        var taskId: UIBackgroundTaskIdentifier = .invalid
        taskId = backgroundTaskProvider.beginBackgroundTask(withName: "FilaireKeepAlive") { [weak self] in
            let cleanupBlock: @MainActor () -> Void = {
                guard let self = self else { return }
                // Promptly relinquish background task token
                self.endBackgroundTask(taskId)

                // Guard cleanup with lifecycle generation and background state
                guard self.lifecycleGeneration == currentGen, self.isAppInBackground else { return }

                // Initiate transport cleanup without holding the token
                Task {
                    await self.sshService.disconnect()
                }
            }

            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    cleanupBlock()
                }
            } else {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        cleanupBlock()
                    }
                }
            }
        }
        if taskId != .invalid {
            backgroundTaskId = taskId
            activeBackgroundTasks.insert(taskId)
        }
    }

    public func endBackgroundTask(_ id: UIBackgroundTaskIdentifier? = nil) {
        if let id = id {
            if activeBackgroundTasks.remove(id) != nil {
                if backgroundTaskId == id {
                    backgroundTaskId = .invalid
                }
                backgroundTaskProvider.endBackgroundTask(id)
            }
        } else if backgroundTaskId != .invalid {
            let id = backgroundTaskId
            backgroundTaskId = .invalid
            if activeBackgroundTasks.remove(id) != nil {
                backgroundTaskProvider.endBackgroundTask(id)
            }
        }
    }

    // MARK: - Network Path Monitoring & Handover

    private func setupNetworkMonitoring() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.handlePathUpdate(path)
            }
        }
        pathMonitor.start(queue: monitorQueue)
    }

    public func handlePathUpdate(_ path: NWPath) {
        let currentType: NWInterface.InterfaceType? = {
            if path.usesInterfaceType(.wifi) { return .wifi }
            if path.usesInterfaceType(.cellular) { return .cellular }
            if path.usesInterfaceType(.wiredEthernet) { return .wiredEthernet }
            return nil
        }()
        handleNetworkPathChange(status: path.status, interfaceType: currentType)
    }

    internal func handleNetworkPathChange(status: NWPath.Status, interfaceType: NWInterface.InterfaceType?) {
        let wasSatisfied = lastPathStatus == .satisfied
        let isSatisfied = status == .satisfied
        let previousType = lastInterfaceType
        let hasPriorState = lastPathStatus != nil

        self.lastPathStatus = status
        self.lastInterfaceType = interfaceType

        // Avoid triggering reconnection on the initial cold start evaluation
        guard hasPriorState else { return }
        guard activeHost != nil, !isIntentionalDisconnect else { return }

        // 1. Interface Handover (e.g. Wi-Fi <-> Cellular)
        if isSatisfied, let prev = previousType, let curr = interfaceType, prev != curr {
            if state.isConnected {
                reconnect()
            }
        }
        // 2. Network Restored (after total drop)
        else if isSatisfied && !wasSatisfied {
            if case .reconnecting = state {
                reconnect()
            } else if state.isConnected {
                let connectionId = self.currentConnectionId
                healthCheckTask?.cancel()
                healthCheckTask = Task {
                    let healthy = await sshService.ping(timeout: 3.0)
                    guard !Task.isCancelled,
                          let connectionId = connectionId,
                          self.currentConnectionId == connectionId,
                          self.state == .connected,
                          !self.isIntentionalDisconnect else { return }
                    if !healthy {
                        reconnect()
                    }
                }
            } else if case .failed = state {
                reconnect()
            }
        }
        // 3. Network Lost (became unsatisfied / dropped connection)
        else if !isSatisfied && wasSatisfied {
            if state.isConnected {
                self.state = .reconnecting(attempt: 1)
                Task {
                    await sshService.disconnect()
                }
            }
        }
    }
}
