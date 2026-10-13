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

final class PortForwardingAndTunnelTests: XCTestCase {
    // MARK: - Port Forwarding & Jump Host

    func testPortForwardRuleAndJumpHost() throws {
        let rule = PortForwardRule(localPort: 8080, remoteHost: "db.internal", remotePort: 5432)
        XCTAssertEqual(rule.localPort, 8080)
        XCTAssertEqual(rule.remoteHost, "db.internal")
        XCTAssertEqual(rule.remotePort, 5432)
        XCTAssertTrue(rule.isEnabled)
        XCTAssertEqual(rule.name, "8080 → db.internal:5432")

        let jumpId = UUID()
        let profile = HostProfile(
            name: "App Server",
            hostname: "app.internal",
            jumpHostId: jumpId,
            portForwards: [rule]
        )
        XCTAssertEqual(profile.jumpHostId, jumpId)
        XCTAssertEqual(profile.portForwards.count, 1)

        // Encode to JSON and decode back
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(HostProfile.self, from: data)
        XCTAssertEqual(decoded.id, profile.id)
        XCTAssertEqual(decoded.jumpHostId, jumpId)
        XCTAssertEqual(decoded.portForwards.count, 1)
        XCTAssertEqual(decoded.portForwards.first?.remoteHost, "db.internal")

        // Test backward compatibility when JSON does not have jumpHostId or portForwards
        let legacyJSON = """
        {
            "id": "\(UUID().uuidString)",
            "name": "Legacy Host",
            "hostname": "legacy.internal",
            "port": 22,
            "username": "admin",
            "authMethod": "SSH Key",
            "autoConnect": true,
            "keepAliveInterval": 15
        }
        """.data(using: .utf8)!

        let legacyDecoded = try JSONDecoder().decode(HostProfile.self, from: legacyJSON)
        XCTAssertEqual(legacyDecoded.name, "Legacy Host")
        XCTAssertNil(legacyDecoded.jumpHostId)
        XCTAssertTrue(legacyDecoded.portForwards.isEmpty)
        XCTAssertTrue(legacyDecoded.autoConnectTmux)
        XCTAssertEqual(legacyDecoded.tmuxPrefix, "ctrl-b")
        XCTAssertFalse(legacyDecoded.detachExistingTmux)
        XCTAssertNil(legacyDecoded.connectionCommand)
    }

    func testPortBoundariesAndClamping() throws {
        // Test HostProfile port clamping on init
        let zeroPortHost = HostProfile(name: "Zero", hostname: "zero.local", port: 0)
        XCTAssertEqual(zeroPortHost.port, 22)

        let negativePortHost = HostProfile(name: "Neg", hostname: "neg.local", port: -10)
        XCTAssertEqual(negativePortHost.port, 22)

        let overflowPortHost = HostProfile(name: "High", hostname: "high.local", port: 70000)
        XCTAssertEqual(overflowPortHost.port, 22)

        let validPortHost = HostProfile(name: "Valid", hostname: "valid.local", port: 2222)
        XCTAssertEqual(validPortHost.port, 2222)

        // Test PortForwardRule port clamping
        let invalidLocalRule = PortForwardRule(localPort: 0, remoteHost: "db", remotePort: 90000)
        XCTAssertEqual(invalidLocalRule.localPort, 8080)
        XCTAssertEqual(invalidLocalRule.remotePort, 8080)

        let validRule = PortForwardRule(localPort: 3000, remoteHost: "api", remotePort: 4000)
        XCTAssertEqual(validRule.localPort, 3000)
        XCTAssertEqual(validRule.remotePort, 4000)
    }


    // MARK: - Dynamic Port Forwarding & SOCKS5 Tests

    func testPortForwardRuleCodableBackwardCompatibility() throws {
        // Legacy JSON without ruleType
        let legacyJson = """
        {
            "id": "11111111-2222-3333-4444-555555555555",
            "name": "Local DB",
            "localPort": 5432,
            "remoteHost": "db.internal",
            "remotePort": 5432,
            "isEnabled": true
        }
        """.data(using: .utf8)!

        let decodedLegacy = try JSONDecoder().decode(PortForwardRule.self, from: legacyJson)
        XCTAssertEqual(decodedLegacy.ruleType, .local, "Missing ruleType must decode to .local")
        XCTAssertEqual(decodedLegacy.localPort, 5432)
        XCTAssertEqual(decodedLegacy.remoteHost, "db.internal")
        XCTAssertEqual(decodedLegacy.remotePort, 5432)

        // Dynamic SOCKS5 rule encoding and decoding
        let dynamicRule = PortForwardRule(
            localPort: 1080,
            remoteHost: "",
            remotePort: 0,
            isEnabled: true,
            ruleType: .dynamic
        )
        XCTAssertTrue(dynamicRule.name.contains("SOCKS5 Proxy"))

        let encoded = try JSONEncoder().encode(dynamicRule)
        let decoded = try JSONDecoder().decode(PortForwardRule.self, from: encoded)
        XCTAssertEqual(decoded.ruleType, .dynamic)
        XCTAssertEqual(decoded.localPort, 1080)
    }

    func testHostProfileAgentForwardingField() throws {
        let profile = HostProfile(name: "AgentHost", hostname: "server.com", port: 22, username: "user")
        XCTAssertFalse(profile.enableAgentForwarding, "Default enableAgentForwarding must be false")

        var enabledProfile = profile
        enabledProfile.enableAgentForwarding = true

        let data = try JSONEncoder().encode(enabledProfile)
        let decoded = try JSONDecoder().decode(HostProfile.self, from: data)
        XCTAssertTrue(decoded.enableAgentForwarding)
    }

    func testHostProfileClipboardWriteDefaults() throws {
        // 1. Defaults on fresh instance
        let profile = HostProfile(name: "Test", hostname: "localhost")
        XCTAssertTrue(profile.allowClipboardWrite, "allowClipboardWrite must default to true")

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
        XCTAssertTrue(decodedLegacy.allowClipboardWrite)

        // 3. Round-trip false stays false
        var disabledProfile = profile
        disabledProfile.allowClipboardWrite = false
        let data = try JSONEncoder().encode(disabledProfile)
        let decoded = try JSONDecoder().decode(HostProfile.self, from: data)
        XCTAssertFalse(decoded.allowClipboardWrite)
    }

    func testHostProfileTmuxSetClipboardToggle() throws {
        var profile = HostProfile(name: "Dev Box", hostname: "dev.internal", username: "dev")
        XCTAssertFalse(profile.tmuxStartupCommand.contains("set-clipboard"))

        // Enabled: set-clipboard runs before attaching
        let splitBindings = " \\; set -s 'user-keys[900]' \"$(printf '\\033[9990~')\" \\; set -s 'user-keys[901]' \"$(printf '\\033[9991~')\" \\; set -s 'user-keys[902]' \"$(printf '\\033[9992~')\" \\; set -s 'user-keys[903]' \"$(printf '\\033[9993~')\" \\; bind -n User900 split-window -h -c '#{pane_current_path}' \\; bind -n User901 split-window -v -c '#{pane_current_path}' \\; bind -n User902 join-pane -h \\; bind -n User903 join-pane -v"
        profile.enableTmuxSetClipboard = true
        XCTAssertEqual(profile.tmuxStartupCommand, "tmux set -s set-clipboard on 2>/dev/null; exec tmux new-session -A -s dev\(splitBindings)\n")
        profile.detachExistingTmux = true
        XCTAssertEqual(profile.startupCommand, "tmux set -s set-clipboard on 2>/dev/null; exec tmux new-session -A -D -s dev\(splitBindings)\n")

        // Never applied to a custom command when tmux auto-connect is off
        profile.autoConnectTmux = false
        profile.connectionCommand = "htop"
        XCTAssertEqual(profile.startupCommand, "htop\n")

        // Decoding JSON without the key defaults to false
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
        XCTAssertFalse(decodedLegacy.enableTmuxSetClipboard)

        // Round-trip true stays true
        let data = try JSONEncoder().encode(profile)
        XCTAssertTrue(try JSONDecoder().decode(HostProfile.self, from: data).enableTmuxSetClipboard)
    }

    @MainActor
    func testSessionManagerHandleClipboardWrite() {
        let manager = SessionManager()
        let testData = Data("hello world".utf8)
        var writtenString: String? = nil

        // 1. No active host -> false, closure not called
        let resNoHost = manager.handleClipboardWrite(testData) { str in
            writtenString = str
        }
        XCTAssertFalse(resNoHost)
        XCTAssertNil(writtenString)

        // 2. Host with toggle off -> false
        var host = HostProfile(name: "TestHost", hostname: "test.local")
        host.allowClipboardWrite = false
        manager.activeHost = host
        let resDisabled = manager.handleClipboardWrite(testData) { str in
            writtenString = str
        }
        XCTAssertFalse(resDisabled)
        XCTAssertNil(writtenString)

        // 3. Toggle on -> true, closure receives the string, activeToast?.title == "Clipboard Updated"
        host.allowClipboardWrite = true
        manager.activeHost = host
        let resEnabled = manager.handleClipboardWrite(testData) { str in
            writtenString = str
        }
        XCTAssertTrue(resEnabled)
        XCTAssertEqual(writtenString, "hello world")
        XCTAssertEqual(manager.activeToast?.title, "Clipboard Updated")
        XCTAssertTrue(manager.activeToast?.message.contains("11 characters") == true)
        XCTAssertTrue(manager.activeToast?.message.contains("TestHost") == true)
    }

    @MainActor
    func testClipboardReadNeverTouchesPasteboardUntilAllowed() {
        let manager = SessionManager()
        var presenceChecks = 0
        var reads = 0
        func hasText() -> Bool { presenceChecks += 1; return true }
        let read: () -> String? = { reads += 1; return "secret" }
        var sent: [UInt8]? = nil
        manager.onDataSent = { sent = $0 }

        // Read disabled for this host: nothing is checked, read, prompted, or sent
        manager.activeHost = HostProfile(name: "Host", hostname: "test.local")
        manager.handleClipboardReadRequest(hasStrings: hasText(), readPasteboard: read)
        XCTAssertNil(manager.pendingSecurityPrompt)
        XCTAssertEqual(presenceChecks, 0)
        XCTAssertEqual(reads, 0)

        var allowedHost = HostProfile(name: "Host", hostname: "test.local")
        allowedHost.allowClipboardRead = true
        manager.activeHost = allowedHost

        // Empty clipboard: no prompt
        manager.handleClipboardReadRequest(hasStrings: false, readPasteboard: read)
        XCTAssertNil(manager.pendingSecurityPrompt)

        // Enabled: prompts without reading; declining reads and sends nothing
        manager.handleClipboardReadRequest(hasStrings: hasText(), readPasteboard: read)
        XCTAssertNotNil(manager.pendingSecurityPrompt)
        XCTAssertEqual(reads, 0, "Clipboard must not be read before the user allows it")
        manager.cancelPendingSecurityPrompt()
        XCTAssertEqual(reads, 0)
        XCTAssertNil(sent)

        // Allowing reads once, at that moment, and replies with that content
        manager.handleClipboardReadRequest(hasStrings: hasText(), readPasteboard: read)
        manager.pendingSecurityPrompt?.onAllow()
        XCTAssertEqual(reads, 1)
        let expected = "\u{1B}]52;c;\(Data("secret".utf8).base64EncodedString())\u{1B}\\"
        XCTAssertEqual(sent, Array(expected.utf8))
        manager.pendingSecurityPrompt = nil
    }

    func testHostProfileLegacyAlgorithmsDefaults() throws {
        // 1. Defaults on fresh instance
        let profile = HostProfile(name: "Test", hostname: "localhost")
        XCTAssertFalse(profile.allowLegacyAlgorithms, "allowLegacyAlgorithms must default to false")

        // 2. Decoding JSON without the key defaults to false
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
        XCTAssertFalse(decodedLegacy.allowLegacyAlgorithms)

        // 3. Round-trip true stays true
        var legacyProfile = profile
        legacyProfile.allowLegacyAlgorithms = true
        let data = try JSONEncoder().encode(legacyProfile)
        let decoded = try JSONDecoder().decode(HostProfile.self, from: data)
        XCTAssertTrue(decoded.allowLegacyAlgorithms)
    }

    func testUsesLegacyAlgorithms() {
        var profile = HostProfile(name: "Test", hostname: "localhost")
        profile.allowLegacyAlgorithms = false

        // toggle off + "ssh-ed25519" -> false
        XCTAssertFalse(SSHService.usesLegacyAlgorithms(host: profile, rawKeyType: "ssh-ed25519"))

        // toggle off + nil -> false
        XCTAssertFalse(SSHService.usesLegacyAlgorithms(host: profile, rawKeyType: nil))

        // toggle off + "ssh-rsa" -> true
        XCTAssertTrue(SSHService.usesLegacyAlgorithms(host: profile, rawKeyType: "ssh-rsa"))

        // toggle on + "ssh-ed25519" -> true
        profile.allowLegacyAlgorithms = true
        XCTAssertTrue(SSHService.usesLegacyAlgorithms(host: profile, rawKeyType: "ssh-ed25519"))
    }

    func testSOCKS5ParserGreeting() throws {
        // Valid greeting: VER 5, 2 methods (0x02, 0x00)
        let validGreeting = Data([0x05, 0x02, 0x02, 0x00])
        let (method, consumed) = try SOCKS5Parser.parseGreeting(validGreeting)
        XCTAssertEqual(method, 0x00)
        XCTAssertEqual(consumed, 4)

        // Incomplete greeting
        let incomplete = Data([0x05, 0x02, 0x00])
        XCTAssertThrowsError(try SOCKS5Parser.parseGreeting(incomplete)) { error in
            XCTAssertEqual(error as? SOCKS5Parser.ParseError, .incompleteData)
        }

        // Invalid version (e.g. SOCKS4)
        let socks4 = Data([0x04, 0x01, 0x00])
        XCTAssertThrowsError(try SOCKS5Parser.parseGreeting(socks4)) { error in
            XCTAssertEqual(error as? SOCKS5Parser.ParseError, .invalidVersion(0x04))
        }

        // No acceptable auth (only GSSAPI / username-password)
        let noNoAuth = Data([0x05, 0x01, 0x02])
        XCTAssertThrowsError(try SOCKS5Parser.parseGreeting(noNoAuth)) { error in
            XCTAssertEqual(error as? SOCKS5Parser.ParseError, .noAcceptableAuth)
        }
    }

    func testSOCKS5ParserRequestIPv4() throws {
        // VER 5, CMD 1 (CONNECT), RSV 0, ATYP 1 (IPv4: 192.168.1.100), Port 8080 (0x1F90)
        let req = Data([0x05, 0x01, 0x00, 0x01, 192, 168, 1, 100, 0x1F, 0x90])
        let (target, consumed) = try SOCKS5Parser.parseRequest(req)
        XCTAssertEqual(target.host, "192.168.1.100")
        XCTAssertEqual(target.port, 8080)
        XCTAssertEqual(consumed, 10)
    }

    func testSOCKS5ParserRequestDomain() throws {
        // VER 5, CMD 1, RSV 0, ATYP 3 (Domain: "github.com"), Port 443 (0x01BB)
        var req = Data([0x05, 0x01, 0x00, 0x03, 10])
        req.append("github.com".data(using: .utf8)!)
        req.append(contentsOf: [0x01, 0xBB])

        let (target, consumed) = try SOCKS5Parser.parseRequest(req)
        XCTAssertEqual(target.host, "github.com")
        XCTAssertEqual(target.port, 443)
        XCTAssertEqual(consumed, req.count)
    }

    func testSOCKS5ParserRequestUnsupportedCommand() {
        // CMD 3 (UDP ASSOCIATE)
        let req = Data([0x05, 0x03, 0x00, 0x01, 127, 0, 0, 1, 0x00, 0x50])
        XCTAssertThrowsError(try SOCKS5Parser.parseRequest(req)) { error in
            XCTAssertEqual(error as? SOCKS5Parser.ParseError, .unsupportedCommand(0x03))
        }
    }

    func testSOCKS5ParserRequestEmptyDomain() {
        // ATYP 3 with domain length 0
        let req = Data([0x05, 0x01, 0x00, 0x03, 0x00, 0x00, 0x50])
        XCTAssertThrowsError(try SOCKS5Parser.parseRequest(req)) { error in
            XCTAssertEqual(error as? SOCKS5Parser.ParseError, .invalidDomain)
        }
    }

    func testSOCKS5ParserRequestIPv6() throws {
        // ATYP 4 (IPv6: ::1 loopback), Port 22 (0x0016)
        var req = Data([0x05, 0x01, 0x00, 0x04])
        req.append(contentsOf: [UInt8](repeating: 0, count: 15))
        req.append(1) // ::1
        req.append(contentsOf: [0x00, 0x16])

        let (target, consumed) = try SOCKS5Parser.parseRequest(req)
        XCTAssertEqual(target.host, "0:0:0:0:0:0:0:1")
        XCTAssertEqual(target.port, 22)
        XCTAssertEqual(consumed, 22)
    }


    // MARK: - Port Forward Deadline and Cancellation Tests

    private final class MockSSHDirectChannelCreator: SSHDirectChannelCreator, @unchecked Sendable {
        var delayNanoseconds: UInt64 = 0
        var shouldHang: Bool = false
        var shouldFail: Bool = false
        var createdChannels: [Channel] = []
        let lock = NSLock()
        var onChannelRequested: (() -> Void)?

        init(delayNanoseconds: UInt64 = 0, shouldHang: Bool = false, shouldFail: Bool = false) {
            self.delayNanoseconds = delayNanoseconds
            self.shouldHang = shouldHang
            self.shouldFail = shouldFail
        }

        func createDirectTCPIPChannel(
            using settings: SSHChannelType.DirectTCPIP,
            initialize: @escaping (Channel) -> EventLoopFuture<Void>
        ) async throws -> Channel {
            lock.lock()
            onChannelRequested?()
            lock.unlock()

            if shouldHang {
                while true {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }

            if delayNanoseconds > 0 {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            }

            if shouldFail {
                throw POSIXError(.ECONNREFUSED)
            }

            let channel = EmbeddedChannel()
            lock.lock()
            createdChannels.append(channel)
            lock.unlock()

            try await initialize(channel).get()
            return channel
        }
    }

    private static func findUnusedLocalPort() -> Int {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = Darwin.bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(sock, $0, &len)
            }
        }
        close(sock)
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    private static func connectClientSocket(port: Int) -> Int32 {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let res = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(res, 0, "Socket connect failed")
        return sock
    }

    func testSOCKSHandshakeNoGreetingTimeoutCancelsSocket() async throws {
        let port = Self.findUnusedLocalPort()
        let manager = PortForwardManager(handshakeTimeout: 0.15, directChannelTimeout: 1.0)
        let mockCreator = MockSSHDirectChannelCreator()
        let rule = PortForwardRule(localPort: port, ruleType: .dynamic)
        await manager.start(rules: [rule], client: mockCreator)
        defer { Task { await manager.stopAll() } }

        // Give listener a moment to start
        try await Task.sleep(nanoseconds: 30_000_000)

        let sock = Self.connectClientSocket(port: port)
        defer { close(sock) }

        let start = CFAbsoluteTimeGetCurrent()
        var buf = [UInt8](repeating: 0, count: 1)
        let n = Darwin.read(sock, &buf, 1)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        // Server must close socket on deadline
        XCTAssertTrue(n == 0 || n == -1, "Read should return 0 (EOF) or -1 upon server cancellation, got \(n)")
        XCTAssertGreaterThanOrEqual(elapsed, 0.10, "Should wait for at least handshake deadline")
        XCTAssertLessThan(elapsed, 1.5, "Should close promptly on deadline")

        // Wait a brief moment for cleanup
        try await Task.sleep(nanoseconds: 30_000_000)
        let pending = await manager.pendingConnectionCount()
        XCTAssertEqual(pending, 0, "Pending connection count must be 0 after timeout")
    }

    func testSOCKSHandshakePartialGreetingTimeout() async throws {
        let port = Self.findUnusedLocalPort()
        let manager = PortForwardManager(handshakeTimeout: 0.15, directChannelTimeout: 1.0)
        let mockCreator = MockSSHDirectChannelCreator()
        let rule = PortForwardRule(localPort: port, ruleType: .dynamic)
        await manager.start(rules: [rule], client: mockCreator)
        defer { Task { await manager.stopAll() } }

        try await Task.sleep(nanoseconds: 30_000_000)

        let sock = Self.connectClientSocket(port: port)
        defer { close(sock) }

        // Send only 1 byte of greeting (need at least 2: VER, NMETHODS)
        var oneByte: [UInt8] = [0x05]
        Darwin.write(sock, &oneByte, 1)

        let start = CFAbsoluteTimeGetCurrent()
        var buf = [UInt8](repeating: 0, count: 1)
        let n = Darwin.read(sock, &buf, 1)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertTrue(n == 0 || n == -1, "Read should return 0 or -1 upon server cancellation, got \(n)")
        XCTAssertGreaterThanOrEqual(elapsed, 0.10)
        XCTAssertLessThan(elapsed, 1.5)

        try await Task.sleep(nanoseconds: 30_000_000)
        let pending = await manager.pendingConnectionCount()
        XCTAssertEqual(pending, 0)
    }

    func testSOCKSHandshakePartialAddressTimeout() async throws {
        let port = Self.findUnusedLocalPort()
        let manager = PortForwardManager(handshakeTimeout: 0.15, directChannelTimeout: 1.0)
        let mockCreator = MockSSHDirectChannelCreator()
        let rule = PortForwardRule(localPort: port, ruleType: .dynamic)
        await manager.start(rules: [rule], client: mockCreator)
        defer { Task { await manager.stopAll() } }

        try await Task.sleep(nanoseconds: 30_000_000)

        let sock = Self.connectClientSocket(port: port)
        defer { close(sock) }

        // Send valid greeting: VER 5, 1 method: NO AUTH
        var greeting: [UInt8] = [0x05, 0x01, 0x00]
        Darwin.write(sock, &greeting, greeting.count)

        // Read method reply: 2 bytes (0x05, 0x00)
        var reply = [UInt8](repeating: 0, count: 2)
        let replyCount = Darwin.read(sock, &reply, 2)
        XCTAssertEqual(replyCount, 2)
        XCTAssertEqual(reply, [0x05, 0x00])

        // Send partial request: ATYP=3 (domain), domain length = 10, but only send 2 bytes of domain and no port
        var partialReq: [UInt8] = [0x05, 0x01, 0x00, 0x03, 0x0A, 0x61, 0x62]
        Darwin.write(sock, &partialReq, partialReq.count)

        let start = CFAbsoluteTimeGetCurrent()
        var buf = [UInt8](repeating: 0, count: 1)
        let n = Darwin.read(sock, &buf, 1)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertTrue(n == 0 || n == -1, "Read should return 0 or -1 upon server cancellation, got \(n)")
        XCTAssertGreaterThanOrEqual(elapsed, 0.10)
        XCTAssertLessThan(elapsed, 1.5)

        try await Task.sleep(nanoseconds: 30_000_000)
        let pending = await manager.pendingConnectionCount()
        XCTAssertEqual(pending, 0)
    }

    func testSOCKSChannelOpenTimeout() async throws {
        let port = Self.findUnusedLocalPort()
        let manager = PortForwardManager(handshakeTimeout: 1.0, directChannelTimeout: 0.15)
        let mockCreator = MockSSHDirectChannelCreator(shouldHang: true)
        let rule = PortForwardRule(localPort: port, ruleType: .dynamic)
        await manager.start(rules: [rule], client: mockCreator)
        defer { Task { await manager.stopAll() } }

        try await Task.sleep(nanoseconds: 30_000_000)

        let sock = Self.connectClientSocket(port: port)
        defer { close(sock) }

        // Send valid greeting: VER 5, 1 method: NO AUTH
        var greeting: [UInt8] = [0x05, 0x01, 0x00]
        Darwin.write(sock, &greeting, greeting.count)

        var reply = [UInt8](repeating: 0, count: 2)
        let replyCount = Darwin.read(sock, &reply, 2)
        XCTAssertEqual(replyCount, 2)
        XCTAssertEqual(reply, [0x05, 0x00])

        // Send valid request: connect to 127.0.0.1:80
        var req: [UInt8] = [0x05, 0x01, 0x00, 0x01, 127, 0, 0, 1, 0, 80]
        Darwin.write(sock, &req, req.count)

        let start = CFAbsoluteTimeGetCurrent()
        var resp = [UInt8](repeating: 0, count: 10)
        let n = Darwin.read(sock, &resp, 10)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        // Channel creation hung, so directChannelTimeout fired.
        // Server sends SOCKS Connection Refused (0x05) or closes connection.
        if n > 0 {
            XCTAssertEqual(resp[0], 0x05)
            XCTAssertEqual(resp[1], 0x05) // Connection refused
        }
        XCTAssertGreaterThanOrEqual(elapsed, 0.10)
        XCTAssertLessThan(elapsed, 1.5)

        try await Task.sleep(nanoseconds: 30_000_000)
        let pending = await manager.pendingConnectionCount()
        XCTAssertEqual(pending, 0)
        let bridges = await manager.activeBridgeCount()
        XCTAssertEqual(bridges, 0)
    }

    func testStopForwardingDuringHandshakeCancelsAll() async throws {
        let port = Self.findUnusedLocalPort()
        let manager = PortForwardManager(handshakeTimeout: 10.0, directChannelTimeout: 10.0)
        let mockCreator = MockSSHDirectChannelCreator()
        let rule = PortForwardRule(localPort: port, ruleType: .dynamic)
        await manager.start(rules: [rule], client: mockCreator)

        try await Task.sleep(nanoseconds: 30_000_000)

        let sock1 = Self.connectClientSocket(port: port)
        let sock2 = Self.connectClientSocket(port: port)
        defer {
            close(sock1)
            close(sock2)
        }

        // Send partial greetings
        var b: [UInt8] = [0x05]
        Darwin.write(sock1, &b, 1)
        Darwin.write(sock2, &b, 1)

        try await Task.sleep(nanoseconds: 30_000_000)
        let pendingBefore = await manager.pendingConnectionCount()
        XCTAssertGreaterThanOrEqual(pendingBefore, 1)

        // Stop all forwarding
        await manager.stopAll()

        let pendingAfter = await manager.pendingConnectionCount()
        XCTAssertEqual(pendingAfter, 0)
        let bridges = await manager.activeBridgeCount()
        XCTAssertEqual(bridges, 0)

        // Sockets must receive EOF or error promptly
        var buf = [UInt8](repeating: 0, count: 1)
        let n1 = Darwin.read(sock1, &buf, 1)
        let n2 = Darwin.read(sock2, &buf, 1)
        XCTAssertTrue(n1 == 0 || n1 == -1)
        XCTAssertTrue(n2 == 0 || n2 == -1)
    }

    func testMaxPendingConnectionsRejection() async throws {
        let port = Self.findUnusedLocalPort()
        let manager = PortForwardManager(handshakeTimeout: 5.0, directChannelTimeout: 5.0, maxPendingConnections: 1)
        let mockCreator = MockSSHDirectChannelCreator()
        let rule = PortForwardRule(localPort: port, ruleType: .dynamic)
        await manager.start(rules: [rule], client: mockCreator)
        defer { Task { await manager.stopAll() } }

        try await Task.sleep(nanoseconds: 30_000_000)

        let sock1 = Self.connectClientSocket(port: port)
        defer { close(sock1) }

        // Give server time to register sock1 as pending
        try await Task.sleep(nanoseconds: 30_000_000)
        let pending = await manager.pendingConnectionCount()
        XCTAssertEqual(pending, 1)

        // Connect sock2 while sock1 is pending; should be rejected immediately because maxPendingConnections = 1
        let sock2 = Self.connectClientSocket(port: port)
        defer { close(sock2) }

        var buf = [UInt8](repeating: 0, count: 1)
        let n2 = Darwin.read(sock2, &buf, 1)
        XCTAssertTrue(n2 == 0 || n2 == -1, "Second connection must be closed immediately when limit reached")
    }

    func testContinuationGateThreadSafety() async {
        let gate = ContinuationGate<Int, Error>()
        let resumed = OSAllocatedUnfairLock(initialState: 0)

        let task = Task {
            try await withCheckedThrowingContinuation { continuation in
                gate.register(continuation)
            }
        }

        // Concurrently attempt to resume from multiple tasks
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    if gate.resume(returning: i) {
                        resumed.withLock { $0 += 1 }
                    }
                }
            }
        }

        let val = try? await task.value
        XCTAssertNotNil(val)
        XCTAssertEqual(resumed.withLock { $0 }, 1, "Exactly one resume call must succeed")
    }

    func testFilaireTerminalViewWipeScreen() {
        let terminalView = FilaireTerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        terminalView.feed(text: "Hello World\r\nSecond Line\r\n")

        // Cursor moved after feeding text
        let term = terminalView.getTerminal()
        XCTAssertGreaterThan(term.buffer.y, 0)

        // Wipe screen
        terminalView.wipeScreen()

        // Cursor returns to (0, 0) and buffer is reset
        XCTAssertEqual(term.buffer.x, 0)
        XCTAssertEqual(term.buffer.y, 0)
    }

    @MainActor
    func testSessionManagerWipeTerminalCallback() {
        let manager = SessionManager()
        var wiped = false
        manager.onClearTerminal = {
            wiped = true
        }
        manager.wipeTerminal()
        XCTAssertTrue(wiped)
    }

    @MainActor
    func testHostSwitchingDoesNotTriggerReconnectLoop() async {
        let manager = SessionManager()
        let host1 = HostProfile(name: "Host 1", hostname: "host1.local")
        let host2 = HostProfile(name: "Host 2", hostname: "host2.local")

        // Connect to host1
        manager.connect(to: host1)
        XCTAssertEqual(manager.activeHost?.id, host1.id)

        // Switching to host2
        manager.connect(to: host2)
        XCTAssertEqual(manager.activeHost?.id, host2.id)

        // Reconnect attempt must be 0 and no reconnect loop scheduled
        XCTAssertEqual(manager.reconnectAttempt, 0)
        manager.cancelReconnect()
        XCTAssertEqual(manager.reconnectAttempt, 0)
    }

    @MainActor
    func testCompanionToolGuideView() {
        XCTAssertTrue(CompanionToolGuideView.cargoCommand.contains("cargo install --git https://github.com/JeremyOT/filaire fil"))
        XCTAssertTrue(CompanionToolGuideView.sourceCommand.contains("git clone https://github.com/JeremyOT/filaire.git"))
        XCTAssertTrue(CompanionToolGuideView.sourceCommand.contains("cargo build --release"))

        let view = CompanionToolGuideView()
        _ = view.body
    }

    @MainActor
    func testPastePayloadHonorsBracketedPasteMode() {
        // Without bracketed paste mode, text is sent unchanged
        XCTAssertEqual(FilaireTerminalView.pastePayload(for: "ls\n", bracketedPasteMode: false), Array("ls\n".utf8))

        // With bracketed paste mode, text is wrapped in ESC[200~ ... ESC[201~
        XCTAssertEqual(
            FilaireTerminalView.pastePayload(for: "ls\n", bracketedPasteMode: true),
            Array("\u{1B}[200~ls\n\u{1B}[201~".utf8)
        )

        // Embedded end marker must not terminate the paste early
        XCTAssertEqual(
            FilaireTerminalView.pastePayload(for: "a\u{1B}[201~rm -rf ~\n", bracketedPasteMode: true),
            Array("\u{1B}[200~a[201~rm -rf ~\n\u{1B}[201~".utf8)
        )

        // The terminal tracks the mode the remote app requests (DECSET 2004)
        let terminalView = FilaireTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertFalse(terminalView.getTerminal().bracketedPasteMode)
        terminalView.feed(text: "\u{1B}[?2004h")
        XCTAssertTrue(terminalView.getTerminal().bracketedPasteMode)
    }

    func testRemoteTextSanitize() {
        XCTAssertEqual(RemoteText.sanitize("hello", maxLength: 10), "hello")
        XCTAssertEqual(RemoteText.sanitize("a\u{1B}[31mb\u{07}", maxLength: 10), "a[31mb")
        XCTAssertEqual(RemoteText.sanitize("abc\u{202E}def", maxLength: 10), "abcdef")
        XCTAssertEqual(RemoteText.sanitize("abcdefghij", maxLength: 4), "abcd…")
    }



}
