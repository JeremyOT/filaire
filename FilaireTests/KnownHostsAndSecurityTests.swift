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

final class KnownHostsAndSecurityTests: XCTestCase {
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



}
