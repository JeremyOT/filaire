import Foundation
import Network
import NIO
import NIOCore
import NIOSSH
import Citadel

/// All mutable state is only touched on the channel's event loop.
final class DirectTCPIPBridgeHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let onData: @Sendable (Data, @escaping @Sendable () -> Void) -> Void
    private let onClose: @Sendable () -> Void
    private var pendingSends = 0
    private var readWanted = false

    /// - Parameter onData: Delivers bytes to the local connection; must call the completion once they are sent.
    init(
        onData: @escaping @Sendable (Data, @escaping @Sendable () -> Void) -> Void,
        onClose: @escaping @Sendable () -> Void
    ) {
        self.onData = onData
        self.onClose = onClose
    }

    func handlerAdded(context: ChannelHandlerContext) {
        if context.channel.isActive {
            context.read()
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        context.read()
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        guard let bytes = buffer.readBytes(length: buffer.readableBytes), !bytes.isEmpty else { return }
        pendingSends += 1
        let eventLoop = context.eventLoop
        let channel = context.channel
        onData(Data(bytes)) { [weak self] in
            eventLoop.execute {
                guard let self = self else { return }
                self.pendingSends -= 1
                if self.pendingSends == 0 && self.readWanted {
                    self.readWanted = false
                    channel.read()
                }
            }
        }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        if pendingSends == 0 {
            context.read()
        } else {
            readWanted = true
        }
        context.fireChannelReadComplete()
    }

    func channelInactive(context: ChannelHandlerContext) {
        onClose()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        onClose()
        context.close(promise: nil)
    }
}

final class LocalConnectionBridge: @unchecked Sendable {
    private let connection: NWConnection
    private let sshChannel: Channel
    private let onCloseHandler: (@Sendable (LocalConnectionBridge) -> Void)?
    private let lock = NSLock()
    private var isClosed = false

    init(
        connection: NWConnection,
        sshChannel: Channel,
        onClose: (@Sendable (LocalConnectionBridge) -> Void)? = nil
    ) {
        self.connection = connection
        self.sshChannel = sshChannel
        self.onCloseHandler = onClose
    }

    func start() {
        readNext()
    }

    private func readNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self = self else { return }

            guard let data = content, !data.isEmpty else {
                if isComplete || error != nil {
                    self.close()
                } else {
                    self.readNext()
                }
                return
            }

            var buffer = self.sshChannel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            // Wait for the SSH channel to accept this block before reading more, so a slow remote applies backpressure
            self.sshChannel.writeAndFlush(buffer).whenComplete { [weak self] result in
                guard let self = self else { return }
                if case .failure = result {
                    self.close()
                } else if isComplete || error != nil {
                    self.close()
                } else {
                    self.readNext()
                }
            }
        }
    }

    func close() {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        isClosed = true
        lock.unlock()

        _ = sshChannel.close()
        connection.cancel()
        onCloseHandler?(self)
    }
}

final class BridgeHolder: @unchecked Sendable {
    weak var bridge: LocalConnectionBridge?
}

public enum PortForwardError: LocalizedError, Equatable {
    case handshakeTimeout
    case channelOpenTimeout
    case forwardingCancelled
    case maxPendingConnectionsReached
    case closed

    public var errorDescription: String? {
        switch self {
        case .handshakeTimeout:
            return "SOCKS5 handshake timed out"
        case .channelOpenTimeout:
            return "SSH direct-tcpip channel open timed out"
        case .forwardingCancelled:
            return "Port forwarding was cancelled"
        case .maxPendingConnectionsReached:
            return "Maximum pending connections limit reached"
        case .closed:
            return "Connection closed"
        }
    }
}

final class ContinuationGate<T, E: Error>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, E>?
    private var isResolved = false
    private var earlyResult: Result<T, E>?

    func register(_ continuation: CheckedContinuation<T, E>) {
        lock.lock()
        if let early = earlyResult {
            lock.unlock()
            continuation.resume(with: early)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    @discardableResult
    func resume(returning value: T) -> Bool {
        lock.lock()
        guard !isResolved else {
            lock.unlock()
            return false
        }
        isResolved = true
        if let cont = continuation {
            continuation = nil
            lock.unlock()
            cont.resume(returning: value)
            return true
        } else {
            earlyResult = .success(value)
            lock.unlock()
            return true
        }
    }

    @discardableResult
    func resume(throwing error: E) -> Bool {
        lock.lock()
        guard !isResolved else {
            lock.unlock()
            return false
        }
        isResolved = true
        if let cont = continuation {
            continuation = nil
            lock.unlock()
            cont.resume(throwing: error)
            return true
        } else {
            earlyResult = .failure(error)
            lock.unlock()
            return true
        }
    }
}

public final class PendingConnection: @unchecked Sendable {
    public let id: UUID
    public let connection: NWConnection
    public let generation: UInt64
    private let lock = NSLock()
    private var _task: Task<Void, Never>?
    private var _sshChannel: Channel?
    private var _isCancelled = false

    public init(id: UUID, connection: NWConnection, generation: UInt64) {
        self.id = id
        self.connection = connection
        self.generation = generation
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isCancelled
    }

    public func setTask(_ task: Task<Void, Never>) {
        lock.lock()
        _task = task
        let shouldCancel = _isCancelled
        lock.unlock()
        if shouldCancel {
            task.cancel()
        }
    }

    public func setChannel(_ channel: Channel) {
        lock.lock()
        _sshChannel = channel
        let shouldClose = _isCancelled
        lock.unlock()
        if shouldClose {
            _ = channel.close(mode: .all, promise: nil)
        }
    }

    public func cancel() {
        lock.lock()
        guard !_isCancelled else {
            lock.unlock()
            return
        }
        _isCancelled = true
        let task = _task
        let channel = _sshChannel
        lock.unlock()

        connection.cancel()
        task?.cancel()
        _ = channel?.close(mode: .all, promise: nil)
    }
}

public protocol SSHDirectChannelCreator: AnyObject, Sendable {
    func createDirectTCPIPChannel(
        using settings: SSHChannelType.DirectTCPIP,
        initialize: @escaping (Channel) -> EventLoopFuture<Void>
    ) async throws -> Channel
}

extension SSHClient: SSHDirectChannelCreator {}

public enum SOCKS5Parser {
    public struct Target: Equatable {
        public let host: String
        public let port: Int

        public init(host: String, port: Int) {
            self.host = host
            self.port = port
        }
    }

    public enum ParseError: Error, Equatable {
        case invalidVersion(UInt8)
        case unsupportedCommand(UInt8)
        case unsupportedAddressType(UInt8)
        case incompleteData
        case invalidDomain
        case noAcceptableAuth
    }

    public static func parseGreeting(_ data: Data) throws -> (selectedMethod: UInt8, bytesConsumed: Int) {
        guard data.count >= 2 else { throw ParseError.incompleteData }
        let ver = data[0]
        guard ver == 0x05 else { throw ParseError.invalidVersion(ver) }
        let nmethods = Int(data[1])
        guard data.count >= 2 + nmethods else { throw ParseError.incompleteData }
        let methods = Array(data[2..<(2 + nmethods)])
        if methods.contains(0x00) {
            return (0x00, 2 + nmethods)
        } else {
            throw ParseError.noAcceptableAuth
        }
    }

    public static func parseRequest(_ data: Data) throws -> (target: Target, bytesConsumed: Int) {
        guard data.count >= 4 else { throw ParseError.incompleteData }
        guard data[0] == 0x05 else { throw ParseError.invalidVersion(data[0]) }
        guard data[1] == 0x01 else { throw ParseError.unsupportedCommand(data[1]) }
        let atyp = data[3]
        var offset = 4

        let host: String
        switch atyp {
        case 0x01: // IPv4
            guard data.count >= offset + 4 + 2 else { throw ParseError.incompleteData }
            let ipBytes = data[offset..<(offset + 4)]
            host = ipBytes.map { String($0) }.joined(separator: ".")
            offset += 4

        case 0x03: // Domain name
            guard data.count >= offset + 1 else { throw ParseError.incompleteData }
            let len = Int(data[offset])
            guard len > 0 else { throw ParseError.invalidDomain }
            offset += 1
            guard data.count >= offset + len + 2 else { throw ParseError.incompleteData }
            let domainData = data[offset..<(offset + len)]
            guard let str = String(data: domainData, encoding: .utf8) else {
                throw ParseError.invalidDomain
            }
            host = str
            offset += len

        case 0x04: // IPv6
            guard data.count >= offset + 16 + 2 else { throw ParseError.incompleteData }
            var parts: [String] = []
            for i in 0..<8 {
                let idx = offset + (i * 2)
                let chunk = (UInt16(data[idx]) << 8) | UInt16(data[idx + 1])
                parts.append(String(chunk, radix: 16))
            }
            host = parts.joined(separator: ":")
            offset += 16

        default:
            throw ParseError.unsupportedAddressType(atyp)
        }

        let portData = data[offset..<(offset + 2)]
        let port = Int(portData.reduce(0) { ($0 << 8) | UInt16($1) })
        offset += 2

        return (Target(host: host, port: port), offset)
    }
}

private extension NWConnection {
    func receiveExact(count: Int) async throws -> Data {
        var accumulated = Data()
        while accumulated.count < count {
            try Task.checkCancellation()
            let needed = count - accumulated.count
            let gate = ContinuationGate<Data, Error>()
            let chunk: Data = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    gate.register(continuation)
                    self.receive(minimumIncompleteLength: 1, maximumLength: needed) { content, _, isComplete, error in
                        if let error = error {
                            gate.resume(throwing: error)
                        } else if let data = content, !data.isEmpty {
                            gate.resume(returning: data)
                        } else if isComplete {
                            gate.resume(throwing: POSIXError(.ECONNRESET))
                        } else {
                            gate.resume(returning: Data())
                        }
                    }
                }
            } onCancel: {
                self.cancel()
            }
            if chunk.isEmpty {
                throw POSIXError(.ECONNRESET)
            }
            accumulated.append(chunk)
        }
        return accumulated
    }

    func sendData(_ data: Data) async throws {
        try Task.checkCancellation()
        let gate = ContinuationGate<Void, Error>()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                gate.register(continuation)
                self.send(content: data, completion: .contentProcessed { error in
                    if let error = error {
                        gate.resume(throwing: error)
                    } else {
                        gate.resume(returning: ())
                    }
                })
            }
        } onCancel: {
            self.cancel()
        }
    }
}

public actor PortForwardManager {
    private var listeners: [UUID: NWListener] = [:]
    private var activeBridges: [LocalConnectionBridge] = []
    private var pendingConnections: [UUID: PendingConnection] = [:]
    private var forwardingGeneration: UInt64 = 0
    private let queue = DispatchQueue(label: "io.o-t.filaire.portforward", attributes: .concurrent)

    public let handshakeTimeout: TimeInterval
    public let directChannelTimeout: TimeInterval
    public let maxPendingConnections: Int

    public init(
        handshakeTimeout: TimeInterval = 10.0,
        directChannelTimeout: TimeInterval = 15.0,
        maxPendingConnections: Int = 128
    ) {
        self.handshakeTimeout = handshakeTimeout
        self.directChannelTimeout = directChannelTimeout
        self.maxPendingConnections = maxPendingConnections
    }

    /// Listener parameters bound to 127.0.0.1, so forwards (including the unauthenticated SOCKS proxy) are never reachable from the network.
    static func listenerParameters(port: NWEndpoint.Port) -> NWParameters {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredInterfaceType = .loopback
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        return params
    }

    public func start(
        rules: [PortForwardRule],
        client: any SSHDirectChannelCreator,
        onListenerFailed: (@Sendable (PortForwardRule, Error) -> Void)? = nil
    ) async {
        stopAll()

        for rule in rules where rule.isEnabled {
            guard let nwPort = NWEndpoint.Port(rawValue: UInt16(rule.localPort)) else {
                continue
            }
            do {
                let listener = try NWListener(using: Self.listenerParameters(port: nwPort))
                let ruleId = rule.id

                listener.newConnectionHandler = { [weak self, weak client] connection in
                    guard let self = self, let client = client else {
                        connection.cancel()
                        return
                    }
                    var connectionTask: Task<Void, Never>?
                    connectionTask = Task { [weak self, weak client] in
                        guard let self = self, let client = client else {
                            connection.cancel()
                            return
                        }
                        await self.handleNewConnection(connection, for: rule, client: client, task: connectionTask)
                    }
                }

                listener.stateUpdateHandler = { [weak self] state in
                    if case .failed(let error) = state {
                        onListenerFailed?(rule, error)
                        Task { [weak self] in
                            await self?.removeListener(id: ruleId)
                        }
                    }
                }

                listener.start(queue: queue)
                listeners[ruleId] = listener
            } catch {
                onListenerFailed?(rule, error)
                // If the port cannot be bound (e.g. permission or already in use), continue with other rules
            }
        }
    }

    public func start(
        rules: [PortForwardRule],
        client: SSHClient,
        onListenerFailed: (@Sendable (PortForwardRule, Error) -> Void)? = nil
    ) async {
        await start(rules: rules, client: client as any SSHDirectChannelCreator, onListenerFailed: onListenerFailed)
    }

    private func removeListener(id: UUID) {
        listeners.removeValue(forKey: id)?.cancel()
    }

    private func openDirectChannel(
        client: any SSHDirectChannelCreator,
        direct: SSHChannelType.DirectTCPIP,
        timeout: TimeInterval,
        pending: PendingConnection,
        holder: BridgeHolder,
        connection: NWConnection
    ) async throws -> Channel {
        let channelGate = ContinuationGate<Channel, Error>()

        let channelTask = Task { () -> Void in
            do {
                let channel = try await client.createDirectTCPIPChannel(using: direct) { channel in
                    pending.setChannel(channel)
                    let handler = DirectTCPIPBridgeHandler(
                        onData: { data, completion in
                            connection.send(content: data, completion: .contentProcessed { [weak connection] err in
                                if err != nil {
                                    connection?.cancel()
                                }
                                completion()
                            })
                        },
                        onClose: { [weak connection, weak holder] in
                            connection?.cancel()
                            holder?.bridge?.close()
                        }
                    )
                    return channel.setOption(ChannelOptions.autoRead, value: false).flatMap {
                        channel.pipeline.addHandler(handler)
                    }
                }
                if !channelGate.resume(returning: channel) {
                    _ = channel.close(mode: .all, promise: nil)
                }
            } catch {
                _ = channelGate.resume(throwing: error)
            }
        }

        let timeoutNanos = UInt64(max(timeout, 0.001) * 1_000_000_000)
        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: timeoutNanos)
            if channelGate.resume(throwing: PortForwardError.channelOpenTimeout) {
                channelTask.cancel()
                pending.cancel()
            }
        }

        do {
            let channel = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Channel, Error>) in
                    channelGate.register(continuation)
                }
            } onCancel: {
                if channelGate.resume(throwing: PortForwardError.forwardingCancelled) {
                    channelTask.cancel()
                    pending.cancel()
                }
            }
            timeoutTask.cancel()
            return channel
        } catch {
            timeoutTask.cancel()
            channelTask.cancel()
            pending.cancel()
            throw error
        }
    }

    private func handleNewConnection(
        _ connection: NWConnection,
        for rule: PortForwardRule,
        client: any SSHDirectChannelCreator,
        task: Task<Void, Never>? = nil
    ) async {
        guard pendingConnections.count < maxPendingConnections else {
            connection.cancel()
            return
        }

        let connectionId = UUID()
        let currentGeneration = self.forwardingGeneration
        let pending = PendingConnection(id: connectionId, connection: connection, generation: currentGeneration)
        if let task = task {
            pending.setTask(task)
        }
        pendingConnections[connectionId] = pending

        defer {
            pendingConnections.removeValue(forKey: connectionId)
        }

        connection.start(queue: queue)

        do {
            guard self.forwardingGeneration == currentGeneration, !pending.isCancelled else {
                pending.cancel()
                return
            }

            let targetHost: String
            let targetPort: Int

            if rule.ruleType == .dynamic {
                let target = try await withThrowingTaskGroup(of: SOCKS5Parser.Target.self) { group in
                    group.addTask {
                        // 1. Negotiation Greeting: VER (1 byte), NMETHODS (1 byte)
                        let greetingHeader = try await connection.receiveExact(count: 2)
                        let nmethods = Int(greetingHeader[1])
                        let methodsData = try await connection.receiveExact(count: nmethods)
                        let method: UInt8
                        do {
                            (method, _) = try SOCKS5Parser.parseGreeting(greetingHeader + methodsData)
                        } catch SOCKS5Parser.ParseError.noAcceptableAuth {
                            try? await connection.sendData(Data([0x05, 0xFF]))
                            throw SOCKS5Parser.ParseError.noAcceptableAuth
                        }

                        // Accept negotiation (NO AUTH: 0x05, 0x00)
                        try await connection.sendData(Data([0x05, method]))

                        // 2. Client Request Header: VER, CMD, RSV, ATYP (4 bytes)
                        let reqHeader = try await connection.receiveExact(count: 4)
                        let atyp = reqHeader[3]
                        var reqData = reqHeader

                        switch atyp {
                        case 0x01: // IPv4: 4 bytes IP + 2 bytes port
                            let rest = try await connection.receiveExact(count: 6)
                            reqData.append(rest)
                        case 0x03: // Domain: 1 byte len + N bytes + 2 bytes port
                            let lenData = try await connection.receiveExact(count: 1)
                            reqData.append(lenData)
                            let domainLen = Int(lenData[0])
                            guard domainLen > 0 else {
                                try? await connection.sendData(Data([0x05, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0]))
                                throw SOCKS5Parser.ParseError.invalidDomain
                            }
                            let rest = try await connection.receiveExact(count: domainLen + 2)
                            reqData.append(rest)
                        case 0x04: // IPv6: 16 bytes IP + 2 bytes port
                            let rest = try await connection.receiveExact(count: 18)
                            reqData.append(rest)
                        default:
                            try? await connection.sendData(Data([0x05, 0x08, 0x00, 0x01, 0, 0, 0, 0, 0, 0]))
                            throw SOCKS5Parser.ParseError.unsupportedAddressType(atyp)
                        }

                        let parsedTarget: SOCKS5Parser.Target
                        do {
                            (parsedTarget, _) = try SOCKS5Parser.parseRequest(reqData)
                        } catch SOCKS5Parser.ParseError.unsupportedCommand {
                            try? await connection.sendData(Data([0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0]))
                            throw SOCKS5Parser.ParseError.unsupportedCommand(reqHeader[1])
                        }
                        return parsedTarget
                    }

                    group.addTask {
                        let timeoutNanos = UInt64(max(self.handshakeTimeout, 0.001) * 1_000_000_000)
                        try await Task.sleep(nanoseconds: timeoutNanos)
                        connection.cancel()
                        throw PortForwardError.handshakeTimeout
                    }

                    guard let res = try await group.next() else {
                        connection.cancel()
                        throw PortForwardError.handshakeTimeout
                    }
                    group.cancelAll()
                    return res
                }

                targetHost = target.host
                targetPort = target.port
            } else {
                targetHost = rule.remoteHost
                targetPort = rule.remotePort
            }

            guard self.forwardingGeneration == currentGeneration, !pending.isCancelled else {
                pending.cancel()
                return
            }

            let originator = try SocketAddress(ipAddress: "127.0.0.1", port: rule.localPort)
            let direct = SSHChannelType.DirectTCPIP(
                targetHost: targetHost,
                targetPort: targetPort,
                originatorAddress: originator
            )

            let holder = BridgeHolder()

            let sshChannel: Channel
            do {
                sshChannel = try await openDirectChannel(
                    client: client,
                    direct: direct,
                    timeout: directChannelTimeout,
                    pending: pending,
                    holder: holder,
                    connection: connection
                )
            } catch {
                if rule.ruleType == .dynamic {
                    // Send SOCKS5 Connection Refused (0x05)
                    try? await connection.sendData(Data([0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0]))
                }
                pending.cancel()
                return
            }

            guard self.forwardingGeneration == currentGeneration, !pending.isCancelled else {
                _ = sshChannel.close(mode: .all, promise: nil)
                pending.cancel()
                return
            }

            if rule.ruleType == .dynamic {
                // Send SOCKS5 Success (0x00)
                try await connection.sendData(Data([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]))
            }

            guard self.forwardingGeneration == currentGeneration, !pending.isCancelled else {
                _ = sshChannel.close(mode: .all, promise: nil)
                pending.cancel()
                return
            }

            let bridge = LocalConnectionBridge(
                connection: connection,
                sshChannel: sshChannel,
                onClose: { [weak self] closedBridge in
                    Task { [weak self] in
                        await self?.removeBridge(closedBridge)
                    }
                }
            )
            holder.bridge = bridge
            activeBridges.append(bridge)
            bridge.start()
        } catch {
            pending.cancel()
        }
    }

    private func removeBridge(_ bridge: LocalConnectionBridge) {
        activeBridges.removeAll { $0 === bridge }
    }

    public func pendingConnectionCount() -> Int {
        pendingConnections.count
    }

    public func activeBridgeCount() -> Int {
        activeBridges.count
    }

    public func stopAll() {
        forwardingGeneration &+= 1

        for (_, listener) in listeners {
            listener.cancel()
        }
        listeners.removeAll()

        for (_, pending) in pendingConnections {
            pending.cancel()
        }
        pendingConnections.removeAll()

        for bridge in activeBridges {
            bridge.close()
        }
        activeBridges.removeAll()
    }
}
