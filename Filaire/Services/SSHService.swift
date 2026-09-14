import Foundation
import Security
import NIO
import NIOCore
import NIOConcurrencyHelpers
import NIOSSH
import Crypto
import Citadel
import LocalAuthentication

public enum SSHError: LocalizedError {
    case invalidCredentials(String)
    case channelClosed
    case notConnected
    case keyNotFound
    case negotiationFailed(String)
    case terminalSetupFailed(String)
    case terminalSetupTimedOut

    public var errorDescription: String? {
        switch self {
        case .invalidCredentials(let msg):
            return "SSH Credentials Error: \(msg)"
        case .channelClosed:
            return "SSH Channel was closed."
        case .notConnected:
            return "Not connected to SSH server."
        case .keyNotFound:
            return "Configured SSH key not found in Keychain."
        case .negotiationFailed(let msg):
            return msg
        case .terminalSetupFailed(let msg):
            return "Terminal setup failed: \(msg)"
        case .terminalSetupTimedOut:
            return "Terminal setup timed out waiting for server response."
        }
    }
}

public struct AttemptedAuthInfo: Sendable, Equatable {
    public let username: String
    public let keyId: UUID?
    public let keyName: String?
    public let keyType: String?
    public let rawKeyType: String?
    public let publicKey: String?

    public init(
        username: String,
        keyId: UUID? = nil,
        keyName: String? = nil,
        keyType: String? = nil,
        rawKeyType: String? = nil,
        publicKey: String? = nil
    ) {
        self.username = username
        self.keyId = keyId
        self.keyName = keyName
        self.keyType = keyType
        self.rawKeyType = rawKeyType
        self.publicKey = publicKey
    }
}

/// Carries the connection channel out of a NIO initializer closure.
private final class ChannelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var channel: Channel?

    func set(_ value: Channel?) {
        lock.lock()
        channel = value
        lock.unlock()
    }

    func get() -> Channel? {
        lock.lock()
        defer { lock.unlock() }
        return channel
    }
}

/// Thread-safe one-shot gate that safely handles resolution before waiting, exactly-once resolution, and thread-safe signaling.
public final class ReadinessGate: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, Error>?
    private var continuation: CheckedContinuation<Void, Error>?

    public init() {}

    public var isResolved: Bool {
        lock.lock()
        defer { lock.unlock() }
        return result != nil
    }

    public func succeed() {
        resolve(.success(()))
    }

    public func fail(_ error: Error) {
        resolve(.failure(error))
    }

    public func cancel() {
        resolve(.failure(CancellationError()))
    }

    @discardableResult
    public func resolve(_ newResult: Result<Void, Error>) -> Bool {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return false
        }
        result = newResult
        let cont = continuation
        continuation = nil
        lock.unlock()
        switch newResult {
        case .success:
            cont?.resume(returning: ())
        case .failure(let error):
            cont?.resume(throwing: error)
        }
        return true
    }

    public func wait() async throws {
        if Task.isCancelled {
            cancel()
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                lock.lock()
                if let result = self.result {
                    lock.unlock()
                    switch result {
                    case .success:
                        cont.resume(returning: ())
                    case .failure(let error):
                        cont.resume(throwing: error)
                    }
                    return
                }
                guard self.continuation == nil else {
                    lock.unlock()
                    cont.resume(throwing: SSHError.terminalSetupFailed("Multiple concurrent waiters on ReadinessGate are not supported"))
                    return
                }
                self.continuation = cont
                lock.unlock()
            }
        } onCancel: {
            self.cancel()
        }
    }
}

internal final class TerminalChannelWriter: Sendable {
    let channel: Channel

    init(channel: Channel) {
        self.channel = channel
    }

    func write(_ buffer: ByteBuffer) async throws {
        try await channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer)))
    }

    func changeSize(cols: Int, rows: Int, pixelWidth: Int = 0, pixelHeight: Int = 0) async throws {
        try await channel.triggerUserOutboundEvent(
            SSHChannelRequestEvent.WindowChangeRequest(
                terminalCharacterWidth: cols,
                terminalRowHeight: rows,
                terminalPixelWidth: pixelWidth,
                terminalPixelHeight: pixelHeight
            )
        )
    }

    func close() async throws {
        try await channel.close()
    }
}

internal final class TerminalChannelHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = Never

    private let generation: UInt64
    private let onOutput: @Sendable ([UInt8]) -> Void
    private var handlerContext: ChannelHandlerContext?
    private var isPaused = false
    private let lock = NSLock()
    private let recordedError = NIOLockedValueBox<Error?>(nil)

    private struct AcceptanceState {
        var successCount: Int = 0
        var promise: EventLoopPromise<Void>?
        var isResolved: Bool = false
    }
    private let acceptanceBox = NIOLockedValueBox(AcceptanceState())

    init(
        generation: UInt64,
        onOutput: @escaping @Sendable ([UInt8]) -> Void
    ) {
        self.generation = generation
        self.onOutput = onOutput
    }

    deinit {
        acceptanceBox.withLockedValue { state in
            if !state.isResolved {
                state.isResolved = true
                state.promise?.fail(SSHError.channelClosed)
                state.promise = nil
            }
        }
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.handlerContext = context
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { _ in }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.handlerContext = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = self.unwrapInboundIn(data)
        switch channelData.type {
        case .channel, .stdErr:
            guard case .byteBuffer(var buffer) = channelData.data else { return }
            if let bytes = buffer.readBytes(length: buffer.readableBytes), !bytes.isEmpty {
                onOutput(bytes)
            }
        default:
            break
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            acceptanceBox.withLockedValue { state in
                state.successCount += 1
                if state.successCount >= 2 && !state.isResolved {
                    state.isResolved = true
                    state.promise?.succeed(())
                    state.promise = nil
                }
            }
        case is ChannelFailureEvent:
            let error = CitadelError.channelFailure
            recordedError.withLockedValue { if $0 == nil { $0 = error } }
            acceptanceBox.withLockedValue { state in
                if !state.isResolved {
                    state.isResolved = true
                    state.promise?.fail(error)
                    state.promise = nil
                }
            }
            context.close(promise: nil)
        case is SSHChannelRequestEvent.ExitStatus:
            break
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        acceptanceBox.withLockedValue { state in
            if !state.isResolved {
                state.isResolved = true
                state.promise?.fail(SSHError.channelClosed)
                state.promise = nil
            }
        }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        recordedError.withLockedValue { if $0 == nil { $0 = error } }
        acceptanceBox.withLockedValue { state in
            if !state.isResolved {
                state.isResolved = true
                state.promise?.fail(error)
                state.promise = nil
            }
        }
        context.close(promise: nil)
    }

    func getRecordedError() -> Error? {
        recordedError.withLockedValue { $0 }
    }

    func waitForServerAcceptance(eventLoop: EventLoop) async throws {
        if Task.isCancelled {
            throw CancellationError()
        }

        var promiseToAwait: EventLoopPromise<Void>?
        var immediateResult: Result<Void, Error>?

        acceptanceBox.withLockedValue { state in
            if state.isResolved {
                if let err = recordedError.withLockedValue({ $0 }) {
                    immediateResult = .failure(err)
                } else {
                    immediateResult = .success(())
                }
            } else {
                let promise = eventLoop.makePromise(of: Void.self)
                state.promise = promise
                promiseToAwait = promise
            }
        }

        if let result = immediateResult {
            return try result.get()
        }
        guard let promise = promiseToAwait else { return }

        try await withTaskCancellationHandler {
            try await promise.futureResult.get()
        } onCancel: {
            acceptanceBox.withLockedValue { state in
                if !state.isResolved {
                    state.isResolved = true
                    state.promise?.fail(CancellationError())
                    state.promise = nil
                }
            }
        }
    }

    func setPaused(_ paused: Bool) {
        lock.lock()
        guard paused != isPaused else {
            lock.unlock()
            return
        }
        isPaused = paused
        let context = handlerContext
        lock.unlock()

        guard let context = context else { return }
        context.eventLoop.execute {
            context.channel.setOption(ChannelOptions.autoRead, value: !paused).whenComplete { _ in
                if !paused {
                    context.channel.read()
                }
            }
        }
    }

    internal var isTerminalPaused: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isPaused
    }
}

internal final class SessionBundle: @unchecked Sendable {
    let generation: UInt64
    var attempt: SSHConnectionAttempt?
    var bastionAttempt: SSHConnectionAttempt?
    var client: SSHClient?
    var bastionClient: SSHClient?
    var connectionChannel: Channel?
    var stdinWriter: TerminalChannelWriter?
    var terminalHandler: TerminalChannelHandler?
    var sessionTask: Task<Void, Never>?
    var keepAliveTask: Task<Void, Never>?
    var agentForwardTask: Task<Void, Never>?
    let portForwardManager: PortForwardManager
    var inFlightProbeTask: Task<Bool, Never>?
    var isConnectedForTesting: Bool = false
    private(set) var isTornDown = false
    private let teardownLock = NSLock()
    var onTeardownStart: (@Sendable () async -> Void)?

    init(generation: UInt64, portForwardManager: PortForwardManager = PortForwardManager()) {
        self.generation = generation
        self.portForwardManager = portForwardManager
    }

    func tearDown() async {
        teardownLock.lock()
        guard !isTornDown else {
            teardownLock.unlock()
            return
        }
        isTornDown = true
        teardownLock.unlock()

        if let onTeardownStart = onTeardownStart {
            await onTeardownStart()
        }

        bastionAttempt?.cancel()
        bastionAttempt = nil
        attempt?.cancel()
        attempt = nil

        inFlightProbeTask?.cancel()
        inFlightProbeTask = nil
        keepAliveTask?.cancel()
        keepAliveTask = nil
        agentForwardTask?.cancel()
        agentForwardTask = nil
        sessionTask?.cancel()
        sessionTask = nil

        await portForwardManager.stopAll()

        if let writer = stdinWriter {
            try? await writer.close()
            stdinWriter = nil
        }
        terminalHandler = nil
        connectionChannel = nil

        if let client = client {
            try? await client.close()
            self.client = nil
        }
        if let bastion = bastionClient {
            try? await bastion.close()
            self.bastionClient = nil
        }
    }
}

public actor SSHService {
    private var activeSession: SessionBundle?
    private var nextAttemptId: UInt64 = 0
    private var sessionGeneration: UInt64 = 0
    private static let keepAliveProbeHost = "keepalive.filaire.invalid"
    private var currentCols: Int = 80
    private var currentRows: Int = 24
    public private(set) var lastAttemptedAuth: AttemptedAuthInfo?

    internal var currentSessionGeneration: UInt64 {
        sessionGeneration
    }

    private var tmuxPrefixByte: UInt8 = 0x02
    private let lastActivityTime = NIOLockedValueBox<ContinuousClock.Instant>(ContinuousClock.now)
    private let clock = ContinuousClock()

    nonisolated private func recordActivity() {
        lastActivityTime.withLockedValue { $0 = ContinuousClock.now }
    }

    internal func isConnectionIdle(for thresholdSeconds: TimeInterval) -> Bool {
        let last = lastActivityTime.withLockedValue { $0 }
        let elapsed = ContinuousClock.now - last
        return elapsed >= Duration.seconds(thresholdSeconds)
    }

    internal var hasActiveSession: Bool {
        activeSession != nil
    }

    internal var isCurrentProbeInFlight: Bool {
        activeSession?.inFlightProbeTask != nil
    }

    internal var probeRunnerForTesting: ((Channel, TimeInterval) async -> Bool)? = nil

    internal func setProbeRunnerForTesting(_ runner: ((Channel, TimeInterval) async -> Bool)?) {
        self.probeRunnerForTesting = runner
    }

    internal func setTerminalHandlerForTesting(_ handler: TerminalChannelHandler) {
        if activeSession == nil {
            activeSession = SessionBundle(generation: sessionGeneration)
        }
        activeSession?.terminalHandler = handler
    }

    internal func installSessionBundleForTesting(_ bundle: SessionBundle) {
        self.activeSession = bundle
    }

    internal var activeSessionBundleForTesting: SessionBundle? {
        self.activeSession
    }

    public func setTerminalReadPaused(_ isPaused: Bool) async {
        activeSession?.terminalHandler?.setPaused(isPaused)
    }

    public var isConnected: Bool {
        (activeSession?.client != nil || activeSession?.isConnectedForTesting == true) && activeSession?.stdinWriter != nil
    }

    internal func startKeepAliveForTesting(interval: TimeInterval, onDisconnect: @escaping @Sendable (Error?) -> Void) {
        guard let bundle = activeSession else { return }
        startKeepAlive(interval: interval, generation: bundle.generation, onDisconnect: onDisconnect)
    }

    public init() {}

    /// Legacy SHA-1 algorithms are only offered when the host opts in or authenticates with an RSA key (Citadel's RSA auth requires them).
    public static func usesLegacyAlgorithms(host: HostProfile, rawKeyType: String?) -> Bool {
        host.allowLegacyAlgorithms || rawKeyType == "ssh-rsa"
    }

    private static func algorithms(for host: HostProfile, rawKeyType: String?) -> SSHAlgorithms {
        usesLegacyAlgorithms(host: host, rawKeyType: rawKeyType) ? .all : SSHAlgorithms()
    }

    /// Connects to the remote SSH server (directly or via Jump Host), requests PTY, launches tmux startup command, and loops output
    public func connect(
        host: HostProfile,
        allHosts: [HostProfile] = [],
        allKeys: [SSHKeyModel] = [],
        initialCols: Int = 80,
        initialRows: Int = 24,
        authContext: LAContext? = nil,
        onKeyResolved: (@Sendable (UUID, String, String) -> Void)? = nil,
        onUnknownHostKey: UnknownHostKeyHandler? = nil,
        onOutput: @escaping @Sendable ([UInt8]) -> Void,
        onDisconnect: @escaping @Sendable (Error?) -> Void,
        onPortForwardFailed: (@Sendable (PortForwardRule, Error) -> Void)? = nil,
        terminalSetupTimeout: TimeInterval = 15.0
    ) async throws {
        nextAttemptId &+= 1
        let attemptId = nextAttemptId

        // Disconnect existing session if any; never carry queued keystrokes into a new session
        await disconnect(preserveOutboundQueue: false)
        guard attemptId == nextAttemptId else {
            throw CancellationError()
        }

        sessionGeneration &+= 1
        let generation = sessionGeneration

        self.currentCols = initialCols
        self.currentRows = initialRows
        self.tmuxPrefixByte = host.tmuxPrefixByte

        let sessionBundle = SessionBundle(generation: generation)
        self.activeSession = sessionBundle

        let targetAttempt = SSHConnectionAttempt()
        sessionBundle.attempt = targetAttempt
        targetAttempt.onChannelCreated { [weak sessionBundle] ch in
            if sessionBundle?.connectionChannel == nil {
                sessionBundle?.connectionChannel = ch
            }
        }

        var targetClient: SSHClient
        var connectedBastion: SSHClient? = nil

        do {
            // Jump Host / Bastion routing if configured
            if let jumpId = host.jumpHostId, let bastionHost = allHosts.first(where: { $0.id == jumpId }) {
                let bastionAttempt = SSHConnectionAttempt()
                sessionBundle.bastionAttempt = bastionAttempt

                let bastionAuth = try resolveAuthMethod(for: bastionHost, allKeys: allKeys, authContext: authContext, onKeyResolved: onKeyResolved)
                let bastionAlgorithms = Self.algorithms(for: bastionHost, rawKeyType: self.lastAttemptedAuth?.rawKeyType)
                let bastionValidator = SSHHostKeyValidator.custom(
                    TOFUHostKeyValidator(hostname: bastionHost.hostname, port: bastionHost.port, onUnknownHostKey: onUnknownHostKey, attempt: bastionAttempt)
                )

                var bastionSettings = SSHClientSettings(
                    host: bastionHost.hostname,
                    port: bastionHost.port,
                    authenticationMethod: { bastionAuth },
                    hostKeyValidator: bastionValidator
                )
                bastionSettings.algorithms = bastionAlgorithms

                let bastionBootstrap = ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                    .connectTimeout(bastionSettings.connectTimeout)
                    .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
                    .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)

                let bastionChannel = try await bastionBootstrap.connect(host: bastionSettings.host, port: bastionSettings.port).get()
                bastionAttempt.setChannel(bastionChannel)

                let bastion = try await SSHClient.connect(on: bastionChannel, settings: bastionSettings)

                guard generation == sessionGeneration, self.activeSession === sessionBundle else {
                    bastionAttempt.cancel()
                    try? await bastion.close()
                    throw CancellationError()
                }

                connectedBastion = bastion
                sessionBundle.bastionClient = bastion
                bastionAttempt.succeed()

                let targetAuth = try resolveAuthMethod(for: host, allKeys: allKeys, authContext: authContext, onKeyResolved: onKeyResolved)
                let targetValidator = SSHHostKeyValidator.custom(
                    TOFUHostKeyValidator(hostname: host.hostname, port: host.port, onUnknownHostKey: onUnknownHostKey, attempt: targetAttempt)
                )
                var targetSettings = SSHClientSettings(
                    host: host.hostname,
                    port: host.port,
                    authenticationMethod: { targetAuth },
                    hostKeyValidator: targetValidator
                )
                targetSettings.algorithms = Self.algorithms(for: host, rawKeyType: self.lastAttemptedAuth?.rawKeyType)

                let originatorAddress = try SocketAddress(ipAddress: "fe80::1", port: 22)
                let targetChannel = try await bastion.createDirectTCPIPChannel(
                    using: SSHChannelType.DirectTCPIP(
                        targetHost: targetSettings.host,
                        targetPort: targetSettings.port,
                        originatorAddress: originatorAddress
                    ),
                    initialize: { channel in
                        channel.eventLoop.makeSucceededVoidFuture()
                    }
                )
                targetAttempt.setChannel(targetChannel)

                let target = try await SSHClient.connect(on: targetChannel, settings: targetSettings)

                guard generation == sessionGeneration, self.activeSession === sessionBundle else {
                    targetAttempt.cancel()
                    try? await target.close()
                    try? await bastion.close()
                    throw CancellationError()
                }

                targetClient = target
                sessionBundle.client = target
                targetAttempt.succeed()
            } else {
                // Direct connection
                let authMethod = try resolveAuthMethod(for: host, allKeys: allKeys, authContext: authContext, onKeyResolved: onKeyResolved)
                let hostValidator = SSHHostKeyValidator.custom(
                    TOFUHostKeyValidator(hostname: host.hostname, port: host.port, onUnknownHostKey: onUnknownHostKey, attempt: targetAttempt)
                )

                var directSettings = SSHClientSettings(
                    host: host.hostname,
                    port: host.port,
                    authenticationMethod: { authMethod },
                    hostKeyValidator: hostValidator
                )
                directSettings.algorithms = Self.algorithms(for: host, rawKeyType: self.lastAttemptedAuth?.rawKeyType)

                let bootstrap = ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                    .connectTimeout(directSettings.connectTimeout)
                    .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
                    .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)

                let channel = try await bootstrap.connect(host: directSettings.host, port: directSettings.port).get()
                targetAttempt.setChannel(channel)

                let target = try await SSHClient.connect(on: channel, settings: directSettings)

                guard generation == sessionGeneration, self.activeSession === sessionBundle else {
                    targetAttempt.cancel()
                    try? await target.close()
                    throw CancellationError()
                }

                targetClient = target
                sessionBundle.client = target
                targetAttempt.succeed()
            }
        } catch {
            targetAttempt.cancel()
            sessionBundle.bastionAttempt?.cancel()
            try? await connectedBastion?.close()
            await cleanup(generation: generation)
            throw Self.mapSSHError(error, for: host, authInfo: self.lastAttemptedAuth)
        }

        guard generation == sessionGeneration, self.activeSession === sessionBundle else {
            try? await targetClient.close()
            try? await connectedBastion?.close()
            throw CancellationError()
        }

        guard let rootChannel = await resolveConnectionChannel(for: targetClient) else {
            try? await targetClient.close()
            try? await connectedBastion?.close()
            await cleanup(generation: generation)
            throw SSHError.terminalSetupFailed("Failed to resolve connection channel")
        }

        guard generation == sessionGeneration, self.activeSession === sessionBundle else {
            try? await targetClient.close()
            try? await connectedBastion?.close()
            throw CancellationError()
        }

        sessionBundle.connectionChannel = rootChannel

        let readinessGate = ReadinessGate()

        // Setup PTY Session
        let effectiveCols = self.currentCols > 0 ? self.currentCols : initialCols
        let effectiveRows = self.currentRows > 0 ? self.currentRows : initialRows
        let ptyRequest = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: effectiveCols,
            terminalRowHeight: effectiveRows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )

        let terminalHandler = TerminalChannelHandler(
            generation: generation,
            onOutput: { [weak self] bytes in
                self?.recordActivity()
                onOutput(bytes)
            }
        )

        let eventLoop = rootChannel.eventLoop

        // Run PTY loop in an isolated Task
        let task = Task { [weak self, weak sessionBundle, targetClient, eventLoop, terminalHandler, generation, readinessGate] in
            var childChannel: Channel?
            do {
                let sshHandler = try await rootChannel.pipeline.handler(type: NIOSSHHandler.self).get()
                let createdChild = try await eventLoop.flatSubmit {
                    let createPromise = eventLoop.makePromise(of: Channel.self)
                    sshHandler.createChannel(createPromise, channelType: .session) { channel, _ in
                        channel.pipeline.addHandler(terminalHandler)
                    }
                    let scheduledTimeout = eventLoop.scheduleTask(in: .seconds(15)) {
                        createPromise.fail(CitadelError.channelCreationFailed)
                    }
                    createPromise.futureResult.whenComplete { _ in
                        scheduledTimeout.cancel()
                    }
                    return createPromise.futureResult
                }.get()

                if Task.isCancelled || readinessGate.isResolved {
                    try? await createdChild.close()
                    throw CancellationError()
                }

                childChannel = createdChild

                try await createdChild.triggerUserOutboundEvent(ptyRequest)
                try await createdChild.triggerUserOutboundEvent(SSHChannelRequestEvent.ShellRequest(wantReply: true))

                try await terminalHandler.waitForServerAcceptance(eventLoop: eventLoop)

                if Task.isCancelled || readinessGate.isResolved {
                    try? await createdChild.close()
                    throw CancellationError()
                }

                let writer = TerminalChannelWriter(channel: createdChild)

                guard let self = self, let bundle = sessionBundle, !bundle.isTornDown else {
                    readinessGate.fail(CancellationError())
                    try? await createdChild.close()
                    return
                }

                // Ensure remote PTY matches current terminal dimensions
                let currentC = await self.currentCols
                let currentR = await self.currentRows
                let activeCols = currentC > 0 ? currentC : effectiveCols
                let activeRows = currentR > 0 ? currentR : effectiveRows
                try? await writer.changeSize(cols: activeCols, rows: activeRows, pixelWidth: 0, pixelHeight: 0)

                // Execute startup command if configured (tmux session or custom command)
                if let startupCmd = host.startupCommand {
                    var buffer = ByteBuffer()
                    buffer.writeString(startupCmd)
                    try await writer.write(buffer)
                }

                // Expose the writer only after the startup command so queued input never runs ahead of it
                guard await self.setStdinWriter(writer, handler: terminalHandler, generation: generation) else {
                    readinessGate.fail(CancellationError())
                    try? await createdChild.close()
                    return
                }

                // Terminal setup is accepted and writer is attached
                readinessGate.succeed()
                targetAttempt.complete()
                sessionBundle?.bastionAttempt?.complete()

                // Deliver staggered SIGWINCH signals to ensure tmux receives the window size
                // after shell process replacement and session attachment across varying network latencies
                for delayMs in [100, 350, 800, 1500] {
                    Task { [weak self, weak sessionBundle, writer] in
                        try? await Task.sleep(nanoseconds: UInt64(delayMs * 1_000_000))
                        guard let self = self, let bundle = sessionBundle else { return }
                        let currentGen = await self.currentSessionGeneration
                        guard currentGen == generation, !bundle.isTornDown else { return }
                        let c = await self.currentCols
                        let r = await self.currentRows
                        let finalCols = c > 0 ? c : activeCols
                        let finalRows = r > 0 ? r : activeRows
                        try? await writer.changeSize(cols: finalCols, rows: finalRows, pixelWidth: 0, pixelHeight: 0)
                    }
                }

                // Start Keep-Alive Heartbeat if enabled
                if host.keepAliveInterval > 0 {
                    await self.startKeepAlive(interval: host.keepAliveInterval, generation: generation, onDisconnect: onDisconnect)
                }

                _ = try await withTaskCancellationHandler {
                    try await createdChild.closeFuture.get()
                } onCancel: {
                    createdChild.close(promise: nil)
                }

                let recordedError = terminalHandler.getRecordedError()
                if readinessGate.isResolved {
                    if let err = recordedError {
                        let authInfo = await self.lastAttemptedAuth
                        onDisconnect(Self.mapSSHError(err, for: host, authInfo: authInfo))
                    } else {
                        onDisconnect(nil)
                    }
                } else {
                    readinessGate.fail(recordedError ?? SSHError.channelClosed)
                }
            } catch {
                if !readinessGate.isResolved {
                    readinessGate.fail(error)
                } else {
                    let authInfo = await self?.lastAttemptedAuth
                    onDisconnect(Self.mapSSHError(error, for: host, authInfo: authInfo))
                }
            }
            if let childChannel = childChannel {
                try? await childChannel.close()
            }
            if let self = self {
                await self.cleanup(generation: generation)
            }
        }

        sessionBundle.sessionTask = task

        // Await readiness with bounded deadline
        do {
            let timeoutSeconds: Double
            if !terminalSetupTimeout.isFinite || terminalSetupTimeout < 0 {
                timeoutSeconds = 15.0
            } else {
                timeoutSeconds = terminalSetupTimeout
            }
            let timeoutNanoseconds = UInt64(min(timeoutSeconds, 3600.0) * 1_000_000_000)

            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await readinessGate.wait()
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    readinessGate.fail(SSHError.terminalSetupTimedOut)
                    throw SSHError.terminalSetupTimedOut
                }
                try await group.next()
                group.cancelAll()
            }
        } catch {
            readinessGate.fail(error)
            task.cancel()
            try? await targetClient.close()
            try? await connectedBastion?.close()
            await cleanup(generation: generation)
            throw Self.mapSSHError(error, for: host, authInfo: self.lastAttemptedAuth)
        }

        guard generation == sessionGeneration, self.activeSession === sessionBundle else {
            task.cancel()
            await cleanup(generation: generation)
            throw CancellationError()
        }

        // Start Local Port Forwarding if any rules are defined (only after terminal readiness)
        if !host.portForwards.isEmpty {
            await sessionBundle.portForwardManager.start(rules: host.portForwards, client: targetClient, onListenerFailed: onPortForwardFailed)
        }

        // Start SSH Agent Forwarding if enabled (only after terminal readiness)
        if host.enableAgentForwarding {
            let keys = allKeys
            let hostCopy = host
            let target = targetClient
            let agentTask = Task { [weak self] in
                guard let self = self else { return }
                await self.startAgentForwarding(client: target, host: hostCopy, keys: keys, generation: generation)
            }
            sessionBundle.agentForwardTask = agentTask
        }
    }

    private func setStdinWriter(
        _ writer: TerminalChannelWriter,
        handler: TerminalChannelHandler,
        generation: UInt64
    ) async -> Bool {
        guard let bundle = activeSession, bundle.generation == generation, !bundle.isTornDown else { return false }
        bundle.stdinWriter = writer
        bundle.terminalHandler = handler
        return true
    }

    private func startKeepAlive(interval: TimeInterval, generation: UInt64, onDisconnect: @escaping @Sendable (Error?) -> Void) {
        guard let bundle = activeSession, bundle.generation == generation, !bundle.isTornDown else { return }
        bundle.keepAliveTask?.cancel()
        bundle.keepAliveTask = Task { [weak self, weak bundle] in
            let nano = UInt64(max(0.01, interval) * 1_000_000_000)
            var consecutiveFailures = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: nano)
                guard !Task.isCancelled, let self = self, let bundle = bundle else { break }

                let currentGen = await self.currentSessionGeneration
                guard currentGen == generation, !bundle.isTornDown else { break }

                // Only send keep-alive probe if connection has been idle for the interval
                let isIdle = await self.isConnectionIdle(for: interval * 0.9)
                if !isIdle {
                    consecutiveFailures = 0
                    continue
                }

                let alive = await self.ping(timeout: min(max(interval / 2, 0.01), 10.0))
                guard !Task.isCancelled else { break }
                let genAfter = await self.currentSessionGeneration
                guard genAfter == generation, !bundle.isTornDown else { break }

                if alive {
                    consecutiveFailures = 0
                    self.recordActivity()
                } else {
                    consecutiveFailures += 1
                    if consecutiveFailures >= 3 {
                        onDisconnect(SSHError.channelClosed)
                        break
                    }
                }
            }
        }
    }

    /// Actively probes connection health requiring evidence received from the remote endpoint.
    /// Never falls back to local writes. Concurrent callers coalesce around a shared in-flight probe
    /// while preserving each caller's timeout deadline and cancellation.
    public func ping(timeout: TimeInterval = 3.0) async -> Bool {
        guard let bundle = activeSession, isConnected, (bundle.client != nil || bundle.isConnectedForTesting) else { return false }
        let generation = bundle.generation
        let client = bundle.client

        let probeTask: Task<Bool, Never>
        if let existing = bundle.inFlightProbeTask {
            probeTask = existing
        } else {
            let task = Task<Bool, Never> { [weak self, weak bundle] in
                guard let self = self, let bundle = bundle else { return false }
                guard let channel = await self.resolveConnectionChannel(for: client) else {
                    return false
                }
                let result = await self.sendServerProbe(on: channel, timeout: 10.0)
                if !result {
                    // When an underlying probe fails (times out after max budget or errors),
                    // the remote peer is unresponsive and global request ordering in NIOSSHHandler
                    // can no longer be safely reused. Close the channel to flush pending state.
                    channel.close(mode: .all, promise: nil)
                }
                await self.clearInFlightProbe(bundle: bundle)
                return result
            }
            bundle.inFlightProbeTask = task
            probeTask = task
        }

        let timeoutNanoseconds = UInt64(max(0.1, timeout) * 1_000_000_000)
        let outcome = await withTaskCancellationHandler {
            await withThrowingTaskGroup(of: Bool.self) { group in
                group.addTask {
                    try Task.checkCancellation()
                    return await probeTask.value
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    return false
                }
                let first = try? await group.next()
                group.cancelAll()
                return first ?? false
            }
        } onCancel: {
            // Caller cancellation does not cancel the shared underlying probe task
        }

        // Recheck session generation after async wait
        guard let current = activeSession, current.generation == generation, !bundle.isTornDown else {
            return false
        }
        return outcome
    }

    private func clearInFlightProbe(bundle: SessionBundle) {
        if activeSession === bundle {
            bundle.inFlightProbeTask = nil
        }
    }

    /// Finds the channel carrying this SSH connection without sending anything to the server: the direct-tcpip
    /// initializer runs before SSH_MSG_CHANNEL_OPEN is written, and failing it aborts the open locally.
    private func resolveConnectionChannel(for client: SSHClient?) async -> Channel? {
        if let bundle = activeSession, (bundle.client === client || bundle.isConnectedForTesting), let channel = bundle.connectionChannel {
            return channel
        }
        guard let client = client else { return nil }
        let box = ChannelBox()
        do {
            let target = SSHChannelType.DirectTCPIP(
                targetHost: "127.0.0.1",
                targetPort: 1,
                originatorAddress: try SocketAddress(ipAddress: "127.0.0.1", port: 0)
            )
            _ = try await client.createDirectTCPIPChannel(using: target) { channel in
                box.set(channel.parent)
                return channel.eventLoop.makeFailedFuture(ChannelError.inappropriateOperationForState)
            }
        } catch {
            // Expected: the initializer always fails
        }
        guard let bundle = activeSession, bundle.client === client, !bundle.isTornDown else { return nil }
        let resolved = box.get()
        bundle.connectionChannel = resolved
        return resolved
    }

    /// Sends a global request the server must answer (cancel of a forward that does not exist).
    /// Any reply, including a refusal, proves the connection is alive.
    internal func sendServerProbe(on channel: Channel, timeout: TimeInterval) async -> Bool {
        if let runner = probeRunnerForTesting {
            return await runner(channel, timeout)
        }
        let eventLoop = channel.eventLoop
        let promise = eventLoop.makePromise(of: Void.self)
        let timeoutAmount = TimeAmount.milliseconds(Int64(max(0.1, timeout) * 1000))
        let timeoutTask = eventLoop.scheduleTask(in: timeoutAmount) {
            promise.fail(ChannelError.connectTimeout(timeoutAmount))
        }
        let probeHost = Self.keepAliveProbeHost
        eventLoop.execute {
            do {
                let handler = try channel.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                let reply = eventLoop.makePromise(of: GlobalRequest.TCPForwardingResponse?.self)
                handler.sendTCPForwardingRequest(.cancel(host: probeHost, port: 1), promise: reply)
                reply.futureResult.whenComplete { result in
                    switch result {
                    case .success:
                        promise.succeed(())
                    case .failure(let error as NIOSSHError) where error.type == .globalRequestRefused:
                        promise.succeed(())
                    case .failure(let error):
                        promise.fail(error)
                    }
                }
            } catch {
                promise.fail(error)
            }
        }
        defer { timeoutTask.cancel() }
        do {
            try await promise.futureResult.get()
            return true
        } catch {
            return false
        }
    }

    internal func cleanup(generation: UInt64) async {
        guard let bundle = activeSession, bundle.generation == generation else { return }
        activeSession = nil
        await bundle.tearDown()
    }

    /// Sends raw keyboard/input bytes into the SSH channel stdin
    public func send(data: [UInt8]) async throws {
        guard !data.isEmpty else { return }
        guard let writer = activeSession?.stdinWriter else {
            throw SSHError.notConnected
        }
        var buffer = ByteBuffer()
        buffer.writeBytes(data)
        try await writer.write(buffer)
    }

    /// Informs the remote PTY and tmux of window size changes
    public func resize(cols: Int, rows: Int) async {
        guard cols > 0, rows > 0 else { return }
        self.currentCols = cols
        self.currentRows = rows
        guard let writer = activeSession?.stdinWriter else { return }
        do {
            try await writer.changeSize(cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0)
        } catch {
            // Ignore resize errors if channel is terminating
        }
    }

    /// Gracefully closes the SSH session, tearing down channels and sockets.
    /// Remote tmux detaches automatically upon SIGHUP/EOF when the client PTY closes.
    public func disconnect(preserveOutboundQueue: Bool = false) async {
        sessionGeneration &+= 1
        guard let bundle = activeSession else { return }
        activeSession = nil
        await bundle.tearDown()
    }

    private func startAgentForwarding(client: SSHClient, host: HostProfile, keys: [SSHKeyModel], generation: UInt64) async {
        guard let bundle = activeSession, bundle.generation == generation, !bundle.isTornDown else { return }
        let token = SSHAgentServer.makeForwardingToken()
        let forwardedKeys = SSHAgentServer.keysForForwarding(host: host, allKeys: keys)
        do {
            try await client.withRemotePortForward(
                host: "127.0.0.1",
                port: 0,
                onOpen: { forward in
                    // Publish port + token to ~/.filaire/agent so only the remote user can reach the agent
                    _ = try await client.executeCommand(
                        SSHAgentServer.agentConfigWriteCommand(port: forward.boundPort, token: token)
                    )
                }
            ) { channel, _ in
                let handler = SSHAgentChannelHandler(keys: forwardedKeys, host: host, token: token)
                return channel.pipeline.addHandler(handler)
            }
        } catch {
            // Non-fatal if remote port forwarding or config publishing fails or is rejected
        }
    }

    // MARK: - Authentication Resolver
 
    private func resolveAuthMethod(
        for host: HostProfile,
        allKeys: [SSHKeyModel] = [],
        authContext: LAContext? = nil,
        onKeyResolved: (@Sendable (UUID, String, String) -> Void)? = nil
    ) throws -> SSHAuthenticationMethod {
        switch host.authMethod {
        case .password:
            self.lastAttemptedAuth = AttemptedAuthInfo(username: host.username)
            guard let password = KeychainService.getPassword(forHostId: host.id, context: authContext) else {
                throw SSHError.invalidCredentials("No password found in Keychain for \(host.displayName).")
            }
            return SSHAuthenticationMethod.passwordBased(username: host.username, password: password)

        case .sshKey:
            guard let keyId = host.selectedKeyId else {
                self.lastAttemptedAuth = AttemptedAuthInfo(username: host.username)
                throw SSHError.invalidCredentials("No SSH key selected for host.")
            }
            guard let privateKeyStr = KeychainService.getPrivateKey(forKeyId: keyId, context: authContext) else {
                self.lastAttemptedAuth = AttemptedAuthInfo(username: host.username, keyId: keyId)
                throw SSHError.keyNotFound
            }

            let keyModel = allKeys.first(where: { $0.id == keyId })
            let keyName = keyModel?.name ?? "SSH Key"
            let passphrase = KeychainService.getKeyPassphrase(forKeyId: keyId, context: authContext)

            let keyInfo: SSHKeyGenerator.ParsedKeyInfo
            do {
                keyInfo = try SSHKeyGenerator.parseKeyInfo(from: privateKeyStr)
            } catch {
                self.lastAttemptedAuth = AttemptedAuthInfo(
                    username: host.username,
                    keyId: keyId,
                    keyName: keyName
                )
                throw SSHError.invalidCredentials("Failed to parse private key: \(error.localizedDescription)")
            }

            self.lastAttemptedAuth = AttemptedAuthInfo(
                username: host.username,
                keyId: keyId,
                keyName: keyName,
                keyType: keyInfo.keyType,
                rawKeyType: keyInfo.rawKeyType,
                publicKey: keyInfo.publicKey
            )

            // If key model had legacy placeholder or mismatched public key, notify caller of resolved real public key
            if let model = keyModel, model.publicKey != keyInfo.publicKey {
                onKeyResolved?(keyId, keyInfo.keyType, keyInfo.publicKey)
            }

            if keyInfo.rawKeyType == "ssh-rsa" {
                do {
                    let rsaKey = try SSHKeyGenerator.parseRSAPrivateKey(from: privateKeyStr, passphrase: passphrase)
                    return SSHAuthenticationMethod.rsa(username: host.username, privateKey: rsaKey)
                } catch {
                    throw SSHError.invalidCredentials("Failed to unlock RSA private key: \(error.localizedDescription)")
                }
            } else {
                do {
                    let edKey = try SSHKeyGenerator.parseEd25519PrivateKey(from: privateKeyStr, passphrase: passphrase)
                    return SSHAuthenticationMethod.ed25519(username: host.username, privateKey: edKey)
                } catch {
                    throw SSHError.invalidCredentials("Failed to unlock Ed25519 private key: \(error.localizedDescription)")
                }
            }
        }
    }

    public static func mapSSHError(_ error: Error, for host: HostProfile, authInfo: AttemptedAuthInfo? = nil) -> Error {
        if let sshError = error as? SSHError {
            return sshError
        }

        if let clientError = error as? SSHClientError {
            switch clientError {
            case .allAuthenticationOptionsFailed:
                if let auth = authInfo, auth.rawKeyType == "ssh-rsa" {
                    let keyName = auth.keyName ?? "RSA Key"
                    return SSHError.invalidCredentials(
                        "Remote server rejected RSA key '\(keyName)' for user '\(host.username)' (Citadel.SSHClientError 4).\n\n⚠️ OpenSSH 8.8+ (Debian 12+, Ubuntu 22.04+, macOS) disables 'ssh-rsa' (SHA-1) by default.\n\nRecommended Solutions:\n1. Generate an Ed25519 key in Filaire and add its public key to ~/.ssh/authorized_keys.\n2. Or to keep using RSA, on your server add 'PubkeyAcceptedAlgorithms +ssh-rsa' to /etc/ssh/sshd_config and restart sshd."
                    )
                } else if let auth = authInfo, let pubKey = auth.publicKey {
                    let keyName = auth.keyName ?? "key"
                    return SSHError.invalidCredentials(
                        "Remote server rejected key '\(keyName)' for user '\(host.username)' (Citadel.SSHClientError 4).\n\nEnsure this EXACT public key is in ~/.ssh/authorized_keys:\n\(pubKey)"
                    )
                } else {
                    return SSHError.invalidCredentials(
                        "Remote server rejected credentials for user '\(host.username)' (Citadel.SSHClientError 4). Verify username and that your public key is added to ~/.ssh/authorized_keys."
                    )
                }
            case .unsupportedPasswordAuthentication:
                return SSHError.invalidCredentials(
                    "Remote server does not support password authentication (Citadel.SSHClientError 0)."
                )
            case .unsupportedPrivateKeyAuthentication:
                return SSHError.invalidCredentials(
                    "Remote server does not support public key authentication (Citadel.SSHClientError 1)."
                )
            case .unsupportedHostBasedAuthentication:
                return SSHError.invalidCredentials(
                    "Remote server does not support host-based authentication (Citadel.SSHClientError 2)."
                )
            case .channelCreationFailed:
                return SSHError.terminalSetupFailed("Server refused to open an SSH channel (Citadel.SSHClientError 3).")
            }
        }

        let desc = error.localizedDescription
        let repr = "\(error)"
        if repr.contains("allAuthenticationOptionsFailed") || repr.contains("SSHClientError 4") || desc.contains("SSHClientError 4") {
            if let auth = authInfo, auth.rawKeyType == "ssh-rsa" {
                let keyName = auth.keyName ?? "RSA Key"
                return SSHError.invalidCredentials(
                    "Remote server rejected RSA key '\(keyName)' for user '\(host.username)' (Citadel.SSHClientError 4).\n\n⚠️ OpenSSH 8.8+ (Debian 12+, Ubuntu 22.04+, macOS) disables 'ssh-rsa' (SHA-1) by default.\n\nRecommended Solutions:\n1. Generate an Ed25519 key in Filaire and add its public key to ~/.ssh/authorized_keys.\n2. Or to keep using RSA, on your server add 'PubkeyAcceptedAlgorithms +ssh-rsa' to /etc/ssh/sshd_config and restart sshd."
                )
            } else if let auth = authInfo, let pubKey = auth.publicKey {
                let keyName = auth.keyName ?? "key"
                return SSHError.invalidCredentials(
                    "Remote server rejected key '\(keyName)' for user '\(host.username)' (Citadel.SSHClientError 4).\n\nEnsure this EXACT public key is in ~/.ssh/authorized_keys:\n\(pubKey)"
                )
            }
            return SSHError.invalidCredentials(
                "Remote server rejected credentials for user '\(host.username)' (Citadel.SSHClientError 4). Verify username and that your public key is added to ~/.ssh/authorized_keys."
            )
        }

        if let nioError = error as? NIOSSHError, nioError.type == .keyExchangeNegotiationFailure {
            return SSHError.negotiationFailed(
                "Could not agree on encryption algorithms with \(host.displayName). If this is an older server, enable “Allow Legacy Algorithms (SHA-1)” for this host."
            )
        } else if "\(error)".contains("keyExchangeNegotiationFailure") {
            return SSHError.negotiationFailed(
                "Could not agree on encryption algorithms with \(host.displayName). If this is an older server, enable “Allow Legacy Algorithms (SHA-1)” for this host."
            )
        }

        if let channelError = error as? ChannelError, case .connectTimeout = channelError {
            return SSHError.negotiationFailed(
                "Connection timed out waiting for authentication or response from \(host.displayName)."
            )
        }

        return error
    }
}

// MARK: - SSH Agent Forwarding Server (RFC Draft / OpenSSH Agent Protocol)

public struct SSHAgentDataReader {
    public let data: Data
    public var offset: Int = 0

    public init(data: Data) {
        self.data = data
    }

    public mutating func readBytes(count: Int) -> [UInt8]? {
        guard offset + count <= data.count else { return nil }
        let sub = data[offset..<(offset + count)]
        offset += count
        return Array(sub)
    }

    public mutating func readUInt8() -> UInt8? {
        guard offset < data.count else { return nil }
        let byte = data[offset]
        offset += 1
        return byte
    }

    public mutating func readUInt32() -> UInt32? {
        guard let bytes = readBytes(count: 4) else { return nil }
        return bytes.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
    }

    public mutating func readSSHBuffer() -> Data? {
        guard let length = readUInt32() else { return nil }
        guard let bytes = readBytes(count: Int(length)) else { return nil }
        return Data(bytes)
    }

    public mutating func readSSHString() -> String? {
        guard let buf = readSSHBuffer() else { return nil }
        return String(data: buf, encoding: .utf8)
    }
}

fileprivate extension Data {
    mutating func appendUInt32(_ value: UInt32) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { self.append(contentsOf: $0) }
    }

    mutating func appendSSHBuffer(_ buffer: Data) {
        appendUInt32(UInt32(buffer.count))
        append(buffer)
    }

    mutating func appendSSHString(_ string: String) {
        let strData = string.data(using: .utf8) ?? Data()
        appendSSHBuffer(strData)
    }
}

public struct SSHAgentServer {
    public enum MessageType: UInt8 {
        case failure = 5
        case success = 6
        case requestIdentities = 11
        case identitiesAnswer = 12
        case signRequest = 13
        case signResponse = 14
    }

    public static let forwardingPreambleMagic: [UInt8] = Array("FIL1".utf8)
    public static let forwardingTokenLength = 32

    public static func makeForwardingToken() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: forwardingTokenLength)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return bytes
    }

    /// Shell command (run over an exec channel) that stores the forward port and token in ~/.filaire/agent (0700 dir, 0600 file).
    /// Port and token are digits/hex only, so no quoting of user input is involved.
    public static func agentConfigWriteCommand(port: Int, token: [UInt8]) -> String {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        return #"sh -c 'umask 077 && mkdir -p ~/.filaire && chmod 700 ~/.filaire && printf "%s\n%s\n" \#(port) \#(hex) > ~/.filaire/agent.tmp && mv -f ~/.filaire/agent.tmp ~/.filaire/agent'"#
    }

    public static func constantTimeEquals(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }

    /// Keys offered to the forwarded agent: an explicit per-host list, or by default only the host's own login key.
    public static func keysForForwarding(host: HostProfile, allKeys: [SSHKeyModel]) -> [SSHKeyModel] {
        let allowedIds: Set<UUID>
        if let explicit = host.agentForwardingKeyIds {
            allowedIds = Set(explicit)
        } else if host.authMethod == .sshKey, let selected = host.selectedKeyId {
            allowedIds = [selected]
        } else {
            allowedIds = []
        }
        return allKeys.filter { allowedIds.contains($0.id) }
    }

    /// Human-readable description of what a sign request is for, used in the biometric prompt.
    public static func describeSignRequest(_ data: Data) -> String {
        let sshsigMagic = Array("SSHSIG".utf8)
        if data.starts(with: sshsigMagic) {
            var reader = SSHAgentDataReader(data: data)
            reader.offset = sshsigMagic.count
            let namespace = reader.readSSHString().map { RemoteText.sanitize($0, maxLength: 64) } ?? "unknown"
            return "sign data (namespace “\(namespace)”)"
        }
        var reader = SSHAgentDataReader(data: data)
        if reader.readSSHBuffer() != nil,          // session identifier
           reader.readUInt8() == 50,               // SSH_MSG_USERAUTH_REQUEST
           let user = reader.readSSHString() {
            return "log in as “\(RemoteText.sanitize(user, maxLength: 64))”"
        }
        return "sign an unrecognized request"
    }


    public static func handlePacket(
        data: Data,
        keys: [SSHKeyModel],
        host: HostProfile,
        signingCoordinator: AgentSigningCoordinator = .shared,
        authenticateBiometrics: (@Sendable (String) async -> Bool)? = nil
    ) async -> Data {
        guard data.count >= 5 else {
            return makeFailurePacket()
        }

        var reader = SSHAgentDataReader(data: data)
        guard let length = reader.readUInt32(), length > 0 else {
            return makeFailurePacket()
        }
        guard let msgTypeRaw = reader.readUInt8(), let msgType = MessageType(rawValue: msgTypeRaw) else {
            return makeFailurePacket()
        }

        switch msgType {
        case .requestIdentities:
            return makeIdentitiesAnswer(keys: keys)

        case .signRequest:
            guard let keyBlob = reader.readSSHBuffer(),
                  let dataToSign = reader.readSSHBuffer(),
                  let _ = reader.readUInt32() /* flags */ else {
                return makeFailurePacket()
            }

            // Find matching key by public key blob
            guard let matchingKey = keys.first(where: { key in
                let parts = key.publicKey.components(separatedBy: .whitespaces)
                guard parts.count >= 2, parts[0] == "ssh-ed25519", let blob = Data(base64Encoded: parts[1]) else { return false }
                return blob == keyBlob
            }) else {
                return makeFailurePacket()
            }

            // Acquire signing admission across channels
            guard await signingCoordinator.acquire() else {
                return makeFailurePacket()
            }
            defer {
                signingCoordinator.release()
            }

            guard !Task.isCancelled else {
                return makeFailurePacket()
            }

            // Forwarded-agent requests originate on the remote host, so every signature requires user presence.
            // Approvals are never cached: any process on the remote that can reach the agent could reuse one.
            var authContext: LAContext? = nil
            let reason = "Allow “\(host.displayName)” to \(describeSignRequest(dataToSign)) using key “\(matchingKey.name)”"
            let localContext = LAContext()

            if let customAuth = authenticateBiometrics {
                let success = await withTaskCancellationHandler {
                    await customAuth(reason)
                } onCancel: {
                    localContext.invalidate()
                }
                guard success, !Task.isCancelled else {
                    return makeFailurePacket()
                }
            } else {
                do {
                    authContext = try await BiometricAuthService.authenticate(reason: reason, context: localContext)
                } catch {
                    return makeFailurePacket()
                }
            }

            guard !Task.isCancelled else {
                return makeFailurePacket()
            }

            // Retrieve private key
            guard let privKeyStr = KeychainService.getPrivateKey(forKeyId: matchingKey.id, context: authContext) else {
                return makeFailurePacket()
            }

            guard !Task.isCancelled else {
                return makeFailurePacket()
            }

            let passphrase = KeychainService.getKeyPassphrase(forKeyId: matchingKey.id, context: authContext)

            guard !Task.isCancelled else {
                return makeFailurePacket()
            }

            do {
                let edKey = try SSHKeyGenerator.parseEd25519PrivateKey(from: privKeyStr, passphrase: passphrase)
                let signature = try edKey.signature(for: dataToSign)
                guard !Task.isCancelled else {
                    return makeFailurePacket()
                }
                return makeEd25519SignResponse(signature: Data(signature))
            } catch {
                return makeFailurePacket()
            }

        default:
            return makeFailurePacket()
        }
    }

    public static func makeFailurePacket() -> Data {
        var out = Data()
        out.appendUInt32(1)
        out.append(MessageType.failure.rawValue)
        return out
    }

    public static func makeIdentitiesAnswer(keys: [SSHKeyModel]) -> Data {
        var payload = Data()
        payload.append(MessageType.identitiesAnswer.rawValue)

        var validKeys: [(blob: Data, comment: String)] = []
        for key in keys {
            let parts = key.publicKey.components(separatedBy: .whitespaces)
            guard parts.count >= 2, parts[0] == "ssh-ed25519", let blob = Data(base64Encoded: parts[1]) else { continue }
            let comment = parts.count > 2 ? parts.dropFirst(2).joined(separator: " ") : key.name
            validKeys.append((blob, comment))
        }

        payload.appendUInt32(UInt32(validKeys.count))
        for item in validKeys {
            payload.appendSSHBuffer(item.blob)
            payload.appendSSHString(item.comment)
        }

        var packet = Data()
        packet.appendUInt32(UInt32(payload.count))
        packet.append(payload)
        return packet
    }

    public static func makeEd25519SignResponse(signature: Data) -> Data {
        // Inner signature blob: string "ssh-ed25519" + string signature (64 bytes)
        var sigBlob = Data()
        sigBlob.appendSSHString("ssh-ed25519")
        sigBlob.appendSSHBuffer(signature)

        // Response payload: byte 14 + string sigBlob
        var payload = Data()
        payload.append(MessageType.signResponse.rawValue)
        payload.appendSSHBuffer(sigBlob)

        var packet = Data()
        packet.appendUInt32(UInt32(payload.count))
        packet.append(payload)
        return packet
    }
}

/// Coordinates forwarded-agent biometric authentication across channels to ensure at most one active prompt.
public final class AgentSigningCoordinator: @unchecked Sendable {
    public static let shared = AgentSigningCoordinator()

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let lock = NSLock()
    private let maxWaiters: Int
    private var isBusy: Bool = false
    private var queue: [Waiter] = []

    public init(maxWaiters: Int = 16) {
        self.maxWaiters = maxWaiters
    }

    public func acquire() async -> Bool {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                var immediateResult: Bool?
                lock.lock()
                if Task.isCancelled {
                    immediateResult = false
                } else if !isBusy {
                    isBusy = true
                    immediateResult = true
                } else if queue.count >= maxWaiters {
                    immediateResult = false
                } else {
                    queue.append(Waiter(id: id, continuation: continuation))
                }
                lock.unlock()

                if let result = immediateResult {
                    continuation.resume(returning: result)
                }
            }
        } onCancel: {
            self.cancelWaiter(id: id)
        }
    }

    private func cancelWaiter(id: UUID) {
        var toResume: CheckedContinuation<Bool, Never>?
        lock.lock()
        if let idx = queue.firstIndex(where: { $0.id == id }) {
            let waiter = queue.remove(at: idx)
            toResume = waiter.continuation
        }
        lock.unlock()

        toResume?.resume(returning: false)
    }

    public func release() {
        var toResume: CheckedContinuation<Bool, Never>?
        lock.lock()
        if !queue.isEmpty {
            let nextWaiter = queue.removeFirst()
            toResume = nextWaiter.continuation
            // isBusy remains true during handoff to nextWaiter
        } else {
            isBusy = false
        }
        lock.unlock()

        toResume?.resume(returning: true)
    }

    public var isBusyForTesting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isBusy
    }

    public var waiterCountForTesting: Int {
        lock.lock()
        defer { lock.unlock() }
        return queue.count
    }
}

public typealias SSHAgentPacketProcessor = @Sendable (Data) async -> Data

public final class SSHAgentChannelHandler: ChannelInboundHandler, @unchecked Sendable {
    public typealias InboundIn = ByteBuffer
    public typealias OutboundOut = ByteBuffer

    private let keys: [SSHKeyModel]
    private let host: HostProfile
    private let expectedPreamble: [UInt8]
    private let signingCoordinator: AgentSigningCoordinator
    private let packetProcessor: SSHAgentPacketProcessor
    private let maxPacketSize: Int
    private let highWatermarkBytes: Int
    private let lowWatermarkBytes: Int
    private let maxQueuedBytes: Int
    private let maxQueuedRequests: Int

    private var isAuthenticated = false
    private var buffer = Data()
    private var requestQueue: [Data] = []
    private var queuedBytes: Int = 0
    private var activeRequest: Data? = nil
    private var activeTask: Task<Void, Never>? = nil
    private var isClosed = false
    private var isReadPaused = false

    private let embeddedLock = NSLock()
    private var pendingEmbeddedTasks: [@Sendable () -> Void] = []

    var isReadPausedForTesting: Bool { isReadPaused }
    var totalTrackedBytesForTesting: Int { totalTrackedBytes }
    var queuedRequestsCountForTesting: Int { requestQueue.count }
    var hasActiveRequestForTesting: Bool { activeRequest != nil }
    var isClosedForTesting: Bool { isClosed }

    public func runPendingEmbeddedTasks() {
        embeddedLock.lock()
        let tasks = pendingEmbeddedTasks
        pendingEmbeddedTasks.removeAll()
        embeddedLock.unlock()
        for task in tasks {
            task()
        }
    }

    public init(
        keys: [SSHKeyModel],
        host: HostProfile,
        token: [UInt8],
        signingCoordinator: AgentSigningCoordinator = .shared,
        packetProcessor: SSHAgentPacketProcessor? = nil,
        maxPacketSize: Int = 256 * 1024,
        highWatermarkBytes: Int = 512 * 1024,
        lowWatermarkBytes: Int = 128 * 1024,
        maxQueuedBytes: Int = 1024 * 1024,
        maxQueuedRequests: Int = 16
    ) {
        self.keys = keys
        self.host = host
        if token.isEmpty {
            self.expectedPreamble = []
            self.isAuthenticated = true
        } else {
            self.expectedPreamble = SSHAgentServer.forwardingPreambleMagic + token
            self.isAuthenticated = false
        }
        self.signingCoordinator = signingCoordinator
        self.maxPacketSize = maxPacketSize
        self.highWatermarkBytes = highWatermarkBytes
        self.lowWatermarkBytes = lowWatermarkBytes
        self.maxQueuedBytes = maxQueuedBytes
        self.maxQueuedRequests = maxQueuedRequests

        let keysCopy = keys
        let hostCopy = host
        let coordinator = signingCoordinator
        self.packetProcessor = packetProcessor ?? { data in
            await SSHAgentServer.handlePacket(
                data: data,
                keys: keysCopy,
                host: hostCopy,
                signingCoordinator: coordinator
            )
        }
    }

    private var totalTrackedBytes: Int {
        buffer.count + queuedBytes + (activeRequest?.count ?? 0)
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !isClosed else { return }
        var byteBuffer = unwrapInboundIn(data)
        guard let bytes = byteBuffer.readBytes(length: byteBuffer.readableBytes), !bytes.isEmpty else { return }

        // Protocol error / hard overflow check
        if totalTrackedBytes + bytes.count > maxQueuedBytes {
            closeAndCleanup(context: context, closeChannel: true)
            return
        }

        buffer.append(contentsOf: bytes)

        if !isAuthenticated {
            if buffer.count < expectedPreamble.count {
                updateFlowControl(context: context)
                return
            }
            let received = [UInt8](buffer.prefix(expectedPreamble.count))
            if SSHAgentServer.constantTimeEquals(received, expectedPreamble) {
                buffer.removeSubrange(0..<expectedPreamble.count)
                isAuthenticated = true
            } else {
                closeAndCleanup(context: context, closeChannel: true)
                return
            }
        }

        while isAuthenticated && buffer.count >= 4 {
            let msgLength = Int(
                (UInt32(buffer[0]) << 24) |
                (UInt32(buffer[1]) << 16) |
                (UInt32(buffer[2]) << 8) |
                UInt32(buffer[3])
            )
            guard msgLength > 0, msgLength <= maxPacketSize else {
                closeAndCleanup(context: context, closeChannel: true)
                return
            }
            let totalPacketSize = 4 + msgLength
            guard buffer.count >= totalPacketSize else {
                break
            }

            let packet = buffer.subdata(in: 0..<totalPacketSize)
            buffer.removeSubrange(0..<totalPacketSize)

            requestQueue.append(packet)
            queuedBytes += packet.count
        }

        updateFlowControl(context: context)
        processNextIfNeeded(context: context)
    }

    private func updateFlowControl(context: ChannelHandlerContext) {
        guard !isClosed else { return }
        let currentBytes = totalTrackedBytes
        let currentRequests = requestQueue.count + (activeRequest != nil ? 1 : 0)

        if !isReadPaused {
            if currentBytes >= highWatermarkBytes || currentRequests >= maxQueuedRequests {
                isReadPaused = true
                _ = context.channel.setOption(ChannelOptions.autoRead, value: false)
            }
        } else {
            if currentBytes <= lowWatermarkBytes && currentRequests < maxQueuedRequests {
                isReadPaused = false
                _ = context.channel.setOption(ChannelOptions.autoRead, value: true)
                context.read()
            }
        }
    }

    private func processNextIfNeeded(context: ChannelHandlerContext) {
        guard !isClosed else { return }
        guard activeRequest == nil else { return }
        guard !requestQueue.isEmpty else { return }

        let packet = requestQueue.removeFirst()
        queuedBytes -= packet.count
        activeRequest = packet

        let processor = self.packetProcessor

        activeTask = Task { [weak self] in
            let response = await processor(packet)

            if let self = self {
                if context.eventLoop is EmbeddedEventLoop {
                    self.embeddedLock.lock()
                    self.pendingEmbeddedTasks.append { [weak self] in
                        self?.handleResponse(response, for: packet, context: context)
                    }
                    self.embeddedLock.unlock()
                } else {
                    context.eventLoop.execute { [weak self] in
                        self?.handleResponse(response, for: packet, context: context)
                    }
                }
            }
        }
    }

    private func handleResponse(_ response: Data, for packet: Data, context: ChannelHandlerContext) {
        guard !isClosed else {
            closeAndCleanup(context: context, closeChannel: false)
            return
        }
        guard self.activeRequest == packet else { return }

        var outBuffer = context.channel.allocator.buffer(capacity: response.count)
        outBuffer.writeBytes(response)

        context.channel.writeAndFlush(outBuffer).whenComplete { [weak self] result in
            guard let self = self, !self.isClosed else {
                self?.closeAndCleanup(context: context, closeChannel: false)
                return
            }
            switch result {
            case .success:
                self.activeRequest = nil
                self.activeTask = nil
                self.updateFlowControl(context: context)
                self.processNextIfNeeded(context: context)
            case .failure:
                self.closeAndCleanup(context: context, closeChannel: true)
            }
        }
    }

    private func closeAndCleanup(context: ChannelHandlerContext, closeChannel: Bool = true) {
        guard !isClosed else { return }
        isClosed = true
        buffer.removeAll()
        requestQueue.removeAll()
        queuedBytes = 0
        activeRequest = nil
        activeTask?.cancel()
        activeTask = nil
        embeddedLock.lock()
        pendingEmbeddedTasks.removeAll()
        embeddedLock.unlock()
        if closeChannel {
            context.close(promise: nil)
        }
    }

    public func channelInactive(context: ChannelHandlerContext) {
        closeAndCleanup(context: context, closeChannel: false)
        context.fireChannelInactive()
    }

    public func handlerRemoved(context: ChannelHandlerContext) {
        closeAndCleanup(context: context, closeChannel: false)
    }
}
