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

final class SSHAgentForwardingTests: XCTestCase {
    // MARK: - SSH Agent Server Tests

    func testSSHAgentRequestIdentities() async throws {
        let keyPair = try SSHKeyGenerator.generateEd25519Key(comment: "test@filaire")
        let keyModel = SSHKeyModel(name: "Test Key", publicKey: keyPair.publicKey)
        let host = HostProfile(name: "Host", hostname: "server.com", username: "user")

        // Packet for SSH_AGENTC_REQUEST_IDENTITIES: length = 1, type = 11
        let packet = Data([0x00, 0x00, 0x00, 0x01, 0x0B])
        let response = await SSHAgentServer.handlePacket(data: packet, keys: [keyModel], host: host)

        var reader = SSHAgentDataReader(data: response)
        let len = reader.readUInt32()
        XCTAssertNotNil(len)
        XCTAssertEqual(reader.readUInt8(), 12, "Should return SSH_AGENT_IDENTITIES_ANSWER (12)")
        XCTAssertEqual(reader.readUInt32(), 1, "Should report 1 identity")

        let blob = reader.readSSHBuffer()
        XCTAssertNotNil(blob)
        let comment = reader.readSSHString()
        XCTAssertEqual(comment, "test@filaire")
    }

    func testSSHAgentSignRequestEd25519() async throws {
        let keyPair = try SSHKeyGenerator.generateEd25519Key(comment: "sign@filaire")
        let keyId = UUID()
        try KeychainService.savePrivateKey(keyPair.privateKeyPEM, forKeyId: keyId, requireBiometrics: false)
        defer { KeychainService.deletePrivateKey(forKeyId: keyId) }

        let keyModel = SSHKeyModel(id: keyId, name: "Signing Key", publicKey: keyPair.publicKey, requiresBiometrics: true)
        let host = HostProfile(name: "Host", hostname: "server.com", username: "user")

        let parts = keyPair.publicKey.components(separatedBy: .whitespaces)
        guard parts.count >= 2, let keyBlob = Data(base64Encoded: parts[1]) else {
            XCTFail("Failed to extract keyBlob")
            return
        }

        let challenge = "Challenge data to sign".data(using: .utf8)!

        // Build SSH_AGENTC_SIGN_REQUEST packet
        var payload = Data()
        payload.append(13) // type 13
        payload.append(UInt8((keyBlob.count >> 24) & 0xFF))
        payload.append(UInt8((keyBlob.count >> 16) & 0xFF))
        payload.append(UInt8((keyBlob.count >> 8) & 0xFF))
        payload.append(UInt8(keyBlob.count & 0xFF))
        payload.append(keyBlob)
        payload.append(UInt8((challenge.count >> 24) & 0xFF))
        payload.append(UInt8((challenge.count >> 16) & 0xFF))
        payload.append(UInt8((challenge.count >> 8) & 0xFF))
        payload.append(UInt8(challenge.count & 0xFF))
        payload.append(challenge)
        payload.append(contentsOf: [0, 0, 0, 0]) // flags

        var packet = Data()
        let pLen = payload.count
        packet.append(UInt8((pLen >> 24) & 0xFF))
        packet.append(UInt8((pLen >> 16) & 0xFF))
        packet.append(UInt8((pLen >> 8) & 0xFF))
        packet.append(UInt8(pLen & 0xFF))
        packet.append(payload)

        // Test with mock biometric auth approval
        let response = await SSHAgentServer.handlePacket(
            data: packet,
            keys: [keyModel],
            host: host,
            authenticateBiometrics: { _ in true }
        )

        var reader = SSHAgentDataReader(data: response)
        let len = reader.readUInt32()
        XCTAssertNotNil(len)
        XCTAssertEqual(reader.readUInt8(), 14, "Should return SSH_AGENT_SIGN_RESPONSE (14)")

        let sigBlob = reader.readSSHBuffer()
        XCTAssertNotNil(sigBlob)
        var sigReader = SSHAgentDataReader(data: sigBlob!)
        XCTAssertEqual(sigReader.readSSHString(), "ssh-ed25519")
        let rawSignature = sigReader.readSSHBuffer()
        XCTAssertNotNil(rawSignature)
        XCTAssertEqual(rawSignature!.count, 64, "Ed25519 signature must be 64 bytes")

        // Verify signature with public key
        // Extract raw 32-byte public key from wire format: length (11) + "ssh-ed25519" + length (32) + 32-byte key
        var blobReader = SSHAgentDataReader(data: keyBlob)
        _ = blobReader.readSSHString() // "ssh-ed25519"
        let pubRaw = blobReader.readSSHBuffer()!
        let pubKey = try Curve25519.Signing.PublicKey(rawRepresentation: pubRaw)
        XCTAssertTrue(pubKey.isValidSignature(rawSignature!, for: challenge))
    }

    func testSSHAgentSignRequestBiometricDenied() async throws {
        let keyPair = try SSHKeyGenerator.generateEd25519Key(comment: "denied@filaire")
        let keyId = UUID()
        let keyModel = SSHKeyModel(id: keyId, name: "Denied Key", publicKey: keyPair.publicKey, requiresBiometrics: true)
        let host = HostProfile(name: "Host", hostname: "server.com", username: "user")

        let parts = keyPair.publicKey.components(separatedBy: .whitespaces)
        let keyBlob = Data(base64Encoded: parts[1])!
        let challenge = "Test".data(using: .utf8)!

        var payload = Data([13])
        payload.append(UInt8((keyBlob.count >> 24) & 0xFF))
        payload.append(UInt8((keyBlob.count >> 16) & 0xFF))
        payload.append(UInt8((keyBlob.count >> 8) & 0xFF))
        payload.append(UInt8(keyBlob.count & 0xFF))
        payload.append(keyBlob)
        payload.append(UInt8((challenge.count >> 24) & 0xFF))
        payload.append(UInt8((challenge.count >> 16) & 0xFF))
        payload.append(UInt8((challenge.count >> 8) & 0xFF))
        payload.append(UInt8(challenge.count & 0xFF))
        payload.append(challenge)
        payload.append(contentsOf: [0, 0, 0, 0])

        var packet = Data()
        let pLen = payload.count
        packet.append(UInt8((pLen >> 24) & 0xFF))
        packet.append(UInt8((pLen >> 16) & 0xFF))
        packet.append(UInt8((pLen >> 8) & 0xFF))
        packet.append(UInt8(pLen & 0xFF))
        packet.append(payload)

        // Biometric authentication denied (returns false)
        let response = await SSHAgentServer.handlePacket(
            data: packet,
            keys: [keyModel],
            host: host,
            authenticateBiometrics: { _ in false }
        )

        var reader = SSHAgentDataReader(data: response)
        _ = reader.readUInt32()
        XCTAssertEqual(reader.readUInt8(), 5, "Must return SSH_AGENT_FAILURE (5) when biometric auth fails")
    }

    func testSSHAgentUnknownMessageFailure() async {
        let host = HostProfile(name: "Host", hostname: "server.com", username: "user")
        let unknownPacket = Data([0x00, 0x00, 0x00, 0x01, 99])
        let response = await SSHAgentServer.handlePacket(data: unknownPacket, keys: [], host: host)

        var reader = SSHAgentDataReader(data: response)
        _ = reader.readUInt32()
        XCTAssertEqual(reader.readUInt8(), 5, "Must return SSH_AGENT_FAILURE (5) for unknown message type")
    }

    func testAgentConfigWriteCommand() {
        let token = [UInt8](repeating: 0xab, count: 32)
        let cmd = SSHAgentServer.agentConfigWriteCommand(port: 40123, token: token)
        let expectedHex = String(repeating: "ab", count: 32)
        let expected = "sh -c 'umask 077 && mkdir -p ~/.filaire && chmod 700 ~/.filaire && printf \"%s\\n%s\\n\" 40123 \(expectedHex) > ~/.filaire/agent.tmp && mv -f ~/.filaire/agent.tmp ~/.filaire/agent'"
        XCTAssertEqual(cmd, expected)
    }

    func testForwardingTokenIsRandom() {
        let t1 = SSHAgentServer.makeForwardingToken()
        let t2 = SSHAgentServer.makeForwardingToken()
        XCTAssertEqual(t1.count, 32)
        XCTAssertEqual(t2.count, 32)
        XCTAssertNotEqual(t1, t2)
    }

    func testConstantTimeEquals() {
        let a: [UInt8] = [1, 2, 3, 4]
        let b: [UInt8] = [1, 2, 3, 4]
        let c: [UInt8] = [1, 2, 3, 5]
        let d: [UInt8] = [1, 2, 3]

        XCTAssertTrue(SSHAgentServer.constantTimeEquals(a, b))
        XCTAssertFalse(SSHAgentServer.constantTimeEquals(a, c))
        XCTAssertFalse(SSHAgentServer.constantTimeEquals(a, d))
    }

    func testKeysForForwarding() {
        let k1 = SSHKeyModel(name: "Key 1", keyType: "ssh-ed25519", publicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIK1")
        let k2 = SSHKeyModel(name: "Key 2", keyType: "ssh-ed25519", publicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIK2")
        let k3 = SSHKeyModel(name: "Key 3", keyType: "ssh-ed25519", publicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIK3")
        let allKeys = [k1, k2, k3]

        // Host with authMethod = .sshKey, selectedKeyId = k1.id, agentForwardingKeyIds = nil -> [k1]
        var h1 = HostProfile(name: "H1", hostname: "h1.com", authMethod: .sshKey, selectedKeyId: k1.id, agentForwardingKeyIds: nil)
        XCTAssertEqual(SSHAgentServer.keysForForwarding(host: h1, allKeys: allKeys).map(\.id), [k1.id])

        // Explicit [k2.id, k3.id] -> [k2, k3]
        h1.agentForwardingKeyIds = [k2.id, k3.id]
        XCTAssertEqual(SSHAgentServer.keysForForwarding(host: h1, allKeys: allKeys).map(\.id), [k2.id, k3.id])

        // Explicit [] -> []
        h1.agentForwardingKeyIds = []
        XCTAssertEqual(SSHAgentServer.keysForForwarding(host: h1, allKeys: allKeys).map(\.id), [])

        // Password host with nil -> []
        let h2 = HostProfile(name: "H2", hostname: "h2.com", authMethod: .password, selectedKeyId: nil, agentForwardingKeyIds: nil)
        XCTAssertEqual(SSHAgentServer.keysForForwarding(host: h2, allKeys: allKeys).map(\.id), [])
    }

    func testDescribeSignRequest() {
        // userauth blob -> contains log in as “deploy”
        var authBlob = Data()
        let sessionId: [UInt8] = [1, 2, 3, 4]
        authBlob.append(contentsOf: [0, 0, 0, UInt8(sessionId.count)])
        authBlob.append(contentsOf: sessionId)
        authBlob.append(50) // SSH_MSG_USERAUTH_REQUEST
        let userBytes = Array("deploy".utf8)
        authBlob.append(contentsOf: [0, 0, 0, UInt8(userBytes.count)])
        authBlob.append(contentsOf: userBytes)
        XCTAssertTrue(SSHAgentServer.describeSignRequest(authBlob).contains("log in as “deploy”"))

        // "SSHSIG" + SSH string "git" -> contains namespace “git”
        var sshsigBlob = Data("SSHSIG".utf8)
        let gitBytes = Array("git".utf8)
        sshsigBlob.append(contentsOf: [0, 0, 0, UInt8(gitBytes.count)])
        sshsigBlob.append(contentsOf: gitBytes)
        XCTAssertTrue(SSHAgentServer.describeSignRequest(sshsigBlob).contains("namespace “git”"))

        // random bytes -> "sign an unrecognized request"
        let randomBlob = Data([0xDE, 0xAD, 0xBE, 0xEF])
        XCTAssertEqual(SSHAgentServer.describeSignRequest(randomBlob), "sign an unrecognized request")
    }


    // MARK: - Fix 4 Forwarded-Agent Concurrency & Ordering Regression Tests

    private func makeTestKeyAndBlob() throws -> (SSHKeyModel, Data) {
        let keyPair = try SSHKeyGenerator.generateEd25519Key(comment: "test@filaire")
        let keyModel = SSHKeyModel(name: "Test Key", publicKey: keyPair.publicKey)
        let parts = keyPair.publicKey.components(separatedBy: .whitespaces)
        guard parts.count >= 2, let blob = Data(base64Encoded: parts[1]) else {
            throw SSHError.keyNotFound
        }
        return (keyModel, blob)
    }

    private func appendUInt32(to data: inout Data, _ value: UInt32) {
        var be = value.bigEndian
        Swift.withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }

    private func makeSignPacket(keyBlob: Data, challenge: Data = Data("test challenge".utf8)) -> Data {
        var payload = Data([13])
        appendUInt32(to: &payload, UInt32(keyBlob.count))
        payload.append(keyBlob)
        appendUInt32(to: &payload, UInt32(challenge.count))
        payload.append(challenge)
        appendUInt32(to: &payload, 0) // flags

        var packet = Data()
        appendUInt32(to: &packet, UInt32(payload.count))
        packet.append(payload)
        return packet
    }

    private func makeIdentitiesPacket() -> Data {
        Data([0x00, 0x00, 0x00, 0x01, 0x0B])
    }

    @MainActor
    func testSSHAgentPipelinedRequestsStayInFIFOOrder() async throws {
        let (keyModel, keyBlob) = try makeTestKeyAndBlob()
        let host = HostProfile(name: "Host", hostname: "server.com", username: "user")
        let signPacket = makeSignPacket(keyBlob: keyBlob)
        let idPacket = makeIdentitiesPacket()

        let signGate = ReadinessGate()
        let handler = SSHAgentChannelHandler(
            keys: [keyModel],
            host: host,
            token: [],
            packetProcessor: { data in
                if data.count >= 5 && data[4] == 13 {
                    // Delayed sign request
                    try? await signGate.wait()
                    return SSHAgentServer.makeEd25519SignResponse(signature: Data(repeating: 0x42, count: 64))
                } else {
                    // Fast identities request
                    return SSHAgentServer.makeIdentitiesAnswer(keys: [keyModel])
                }
            }
        )
        let channel = EmbeddedChannel(handler: handler)

        var buf1 = channel.allocator.buffer(capacity: signPacket.count)
        buf1.writeBytes(signPacket)
        try channel.writeInbound(buf1)

        var buf2 = channel.allocator.buffer(capacity: idPacket.count)
        buf2.writeBytes(idPacket)
        try channel.writeInbound(buf2)

        XCTAssertNil(try channel.readOutbound(as: ByteBuffer.self), "No response yet because sign is waiting on gate")

        // Unblock sign request
        signGate.succeed()

        // Wait a short moment for sign task to complete
        for _ in 0..<50 {
            handler.runPendingEmbeddedTasks()
            channel.embeddedEventLoop.run()
            if handler.hasActiveRequestForTesting || handler.queuedRequestsCountForTesting > 0 {
                try await Task.sleep(nanoseconds: 20_000_000)
            } else {
                break
            }
        }
        handler.runPendingEmbeddedTasks()
        channel.embeddedEventLoop.run()

        // Verify response 1 is signResponse (14)
        guard var resp1Buf = try channel.readOutbound(as: ByteBuffer.self),
              let resp1Bytes = resp1Buf.readBytes(length: resp1Buf.readableBytes) else {
            XCTFail("Expected first response")
            return
        }
        var reader1 = SSHAgentDataReader(data: Data(resp1Bytes))
        _ = reader1.readUInt32()
        XCTAssertEqual(reader1.readUInt8(), 14, "First response must be signResponse (14)")

        // Verify response 2 is identitiesAnswer (12)
        guard var resp2Buf = try channel.readOutbound(as: ByteBuffer.self),
              let resp2Bytes = resp2Buf.readBytes(length: resp2Buf.readableBytes) else {
            XCTFail("Expected second response")
            return
        }
        var reader2 = SSHAgentDataReader(data: Data(resp2Bytes))
        _ = reader2.readUInt32()
        XCTAssertEqual(reader2.readUInt8(), 12, "Second response must be identitiesAnswer (12)")

        _ = try channel.finish()
    }

    @MainActor
    func testSSHAgentMultipleSignRequestsBoundedConcurrencyAcrossChannels() async throws {
        let (keyModel, keyBlob) = try makeTestKeyAndBlob()
        let host = HostProfile(name: "Host", hostname: "server.com", username: "user")
        let signPacket = makeSignPacket(keyBlob: keyBlob)

        let coordinator = AgentSigningCoordinator(maxWaiters: 16)
        final class ConcurrencyTracker: @unchecked Sendable {
            private let lock = NSLock()
            private var current: Int = 0
            private(set) var maxConcurrency: Int = 0
            private(set) var totalCompleted: Int = 0

            func enter() {
                lock.lock()
                current += 1
                if current > maxConcurrency {
                    maxConcurrency = current
                }
                lock.unlock()
            }

            func exit() {
                lock.lock()
                current -= 1
                totalCompleted += 1
                lock.unlock()
            }
        }

        let tracker = ConcurrencyTracker()

        let processor: SSHAgentPacketProcessor = { _ in
            guard await coordinator.acquire() else {
                return SSHAgentServer.makeFailurePacket()
            }
            tracker.enter()
            try? await Task.sleep(nanoseconds: 30_000_000)
            tracker.exit()
            coordinator.release()
            return SSHAgentServer.makeEd25519SignResponse(signature: Data(repeating: 0x01, count: 64))
        }

        let handler1 = SSHAgentChannelHandler(
            keys: [keyModel], host: host, token: [], signingCoordinator: coordinator, packetProcessor: processor
        )
        let handler2 = SSHAgentChannelHandler(
            keys: [keyModel], host: host, token: [], signingCoordinator: coordinator, packetProcessor: processor
        )
        let channel1 = EmbeddedChannel(handler: handler1)
        let channel2 = EmbeddedChannel(handler: handler2)

        // Send 2 sign requests to channel 1, and 2 to channel 2
        for _ in 0..<2 {
            var buf1 = channel1.allocator.buffer(capacity: signPacket.count)
            buf1.writeBytes(signPacket)
            try channel1.writeInbound(buf1)

            var buf2 = channel2.allocator.buffer(capacity: signPacket.count)
            buf2.writeBytes(signPacket)
            try channel2.writeInbound(buf2)
        }

        // Wait for all 4 to complete
        for _ in 0..<100 {
            handler1.runPendingEmbeddedTasks()
            channel1.embeddedEventLoop.run()
            handler2.runPendingEmbeddedTasks()
            channel2.embeddedEventLoop.run()
            if tracker.totalCompleted < 4 {
                try await Task.sleep(nanoseconds: 20_000_000)
            } else {
                break
            }
        }
        handler1.runPendingEmbeddedTasks()
        channel1.embeddedEventLoop.run()
        handler2.runPendingEmbeddedTasks()
        channel2.embeddedEventLoop.run()

        XCTAssertEqual(tracker.totalCompleted, 4)
        XCTAssertEqual(tracker.maxConcurrency, 1, "Concurrency must never exceed 1 prompt/signature at any time across all channels")

        _ = try channel1.finish()
        _ = try channel2.finish()
    }

    @MainActor
    func testSSHAgentHighWatermarkPausesAndLowWatermarkResumes() async throws {
        let (keyModel, keyBlob) = try makeTestKeyAndBlob()
        let host = HostProfile(name: "Host", hostname: "server.com", username: "user")
        let signPacket = makeSignPacket(keyBlob: keyBlob) // size is 82 bytes

        let holdGate = ReadinessGate()
        final class CompletedCounter: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            func increment() {
                lock.lock()
                count += 1
                lock.unlock()
            }
            var value: Int {
                lock.lock()
                defer { lock.unlock() }
                return count
            }
        }
        let counter = CompletedCounter()

        let handler = SSHAgentChannelHandler(
            keys: [keyModel],
            host: host,
            token: [],
            packetProcessor: { _ in
                if counter.value == 0 {
                    try? await holdGate.wait()
                }
                counter.increment()
                return SSHAgentServer.makeEd25519SignResponse(signature: Data(repeating: 0x02, count: 64))
            },
            highWatermarkBytes: 150,
            lowWatermarkBytes: 100,
            maxQueuedRequests: 5
        )
        let channel = EmbeddedChannel(handler: handler)

        // Write packet 1 (~113 bytes)
        var buf1 = channel.allocator.buffer(capacity: signPacket.count)
        buf1.writeBytes(signPacket)
        try channel.writeInbound(buf1)

        channel.embeddedEventLoop.run()
        XCTAssertTrue(handler.hasActiveRequestForTesting)
        XCTAssertEqual(handler.queuedRequestsCountForTesting, 0)
        XCTAssertFalse(handler.isReadPausedForTesting)

        // Write packet 2 (~82 bytes) -> totalTrackedBytes is 164 bytes >= 150 high watermark!
        var buf2 = channel.allocator.buffer(capacity: signPacket.count)
        buf2.writeBytes(signPacket)
        try channel.writeInbound(buf2)

        channel.embeddedEventLoop.run()
        XCTAssertTrue(handler.hasActiveRequestForTesting)
        XCTAssertEqual(handler.queuedRequestsCountForTesting, 1)
        XCTAssertTrue(handler.isReadPausedForTesting, "Read should be paused after crossing high watermark")

        // Unblock packet 1
        holdGate.succeed()

        // Run until packet 1 completes
        for _ in 0..<50 {
            handler.runPendingEmbeddedTasks()
            channel.embeddedEventLoop.run()
            if counter.value >= 1 && !handler.hasActiveRequestForTesting {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        handler.runPendingEmbeddedTasks()
        channel.embeddedEventLoop.run()

        // Wait until packet 2 completes and queue empties
        for _ in 0..<50 {
            handler.runPendingEmbeddedTasks()
            channel.embeddedEventLoop.run()
            if counter.value >= 2 && handler.queuedRequestsCountForTesting == 0 && !handler.hasActiveRequestForTesting {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        handler.runPendingEmbeddedTasks()
        channel.embeddedEventLoop.run()

        // Now queue is empty (0 bytes <= 100 low watermark)
        XCTAssertFalse(handler.isReadPausedForTesting, "Read should resume below low watermark")

        _ = try channel.finish()
    }

    @MainActor
    func testSSHAgentChannelClosureDuringAuthDiscardsWorkAndReleasesReservation() async throws {
        let (keyModel, keyBlob) = try makeTestKeyAndBlob()
        let host = HostProfile(name: "Host", hostname: "server.com", username: "user")
        let signPacket = makeSignPacket(keyBlob: keyBlob)
        let coordinator = AgentSigningCoordinator(maxWaiters: 16)

        let authGate = ReadinessGate()

        let handler = SSHAgentChannelHandler(
            keys: [keyModel],
            host: host,
            token: [],
            signingCoordinator: coordinator,
            packetProcessor: { _ in
                guard await coordinator.acquire() else {
                    return SSHAgentServer.makeFailurePacket()
                }
                defer { coordinator.release() }
                try? await authGate.wait()
                return SSHAgentServer.makeEd25519SignResponse(signature: Data(repeating: 0x99, count: 64))
            }
        )
        let channel = EmbeddedChannel(handler: handler)

        // Write 2 packets into channel
        var buf1 = channel.allocator.buffer(capacity: signPacket.count)
        buf1.writeBytes(signPacket)
        try channel.writeInbound(buf1)

        var buf2 = channel.allocator.buffer(capacity: signPacket.count)
        buf2.writeBytes(signPacket)
        try channel.writeInbound(buf2)

        handler.runPendingEmbeddedTasks()
        channel.embeddedEventLoop.run()
        // Wait a moment for packet 1 to enter processor and acquire coordinator
        for _ in 0..<50 {
            if coordinator.isBusyForTesting { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(coordinator.isBusyForTesting, "Coordinator must be busy while auth is pending")
        XCTAssertEqual(handler.queuedRequestsCountForTesting, 1)

        // Close channel while auth is held
        _ = try channel.finish()

        XCTAssertEqual(handler.queuedRequestsCountForTesting, 0, "Queued requests must be discarded on channel close")

        // Release the auth gate with fake late success
        authGate.succeed()

        // Wait for task defer to execute
        for _ in 0..<50 {
            handler.runPendingEmbeddedTasks()
            channel.embeddedEventLoop.run()
            if !coordinator.isBusyForTesting { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        handler.runPendingEmbeddedTasks()
        channel.embeddedEventLoop.run()

        // Verify coordinator permit is released
        XCTAssertFalse(coordinator.isBusyForTesting, "Coordinator permit must be released after close")
        XCTAssertNil(try channel.readOutbound(as: ByteBuffer.self), "No response must be produced to closed channel")

        // A new request on another channel should be able to acquire immediately
        let acquired = await coordinator.acquire()
        XCTAssertTrue(acquired, "Subsequent acquire must succeed now that permit is released")
        coordinator.release()
    }

    @MainActor
    func testSSHAgentFramingSplitFramesMultipleFramesZeroOversizedInvalidPreamble() async throws {
        let (keyModel, _) = try makeTestKeyAndBlob()
        let host = HostProfile(name: "Host", hostname: "server.com", username: "user")
        let token: [UInt8] = Array(repeating: 0xAA, count: 32)
        let expectedPreamble = SSHAgentServer.forwardingPreambleMagic + token
        let idPacket = makeIdentitiesPacket()

        // 1. Split frames: preamble in 2 chunks, packet in 2 chunks
        do {
            let handler = SSHAgentChannelHandler(keys: [keyModel], host: host, token: token)
            let channel = EmbeddedChannel(handler: handler)

            // Preamble first half
            var p1 = channel.allocator.buffer(capacity: 20)
            p1.writeBytes(expectedPreamble.prefix(20))
            try channel.writeInbound(p1)

            // Preamble second half + packet length
            var p2 = channel.allocator.buffer(capacity: 24)
            p2.writeBytes(expectedPreamble.dropFirst(20))
            p2.writeBytes(idPacket.prefix(4))
            try channel.writeInbound(p2)

            // Packet payload (type 11)
            var p3 = channel.allocator.buffer(capacity: 1)
            p3.writeBytes(idPacket.dropFirst(4))
            try channel.writeInbound(p3)

            for _ in 0..<50 {
                handler.runPendingEmbeddedTasks()
                channel.embeddedEventLoop.run()
                if let _ = try channel.readOutbound(as: ByteBuffer.self) {
                    break
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            _ = try channel.finish()
        }

        // 2. Several frames in one read
        do {
            let handler = SSHAgentChannelHandler(keys: [keyModel], host: host, token: token)
            let channel = EmbeddedChannel(handler: handler)

            var multiBuf = channel.allocator.buffer(capacity: expectedPreamble.count + idPacket.count * 2)
            multiBuf.writeBytes(expectedPreamble)
            multiBuf.writeBytes(idPacket)
            multiBuf.writeBytes(idPacket)
            try channel.writeInbound(multiBuf)

            var responses = 0
            for _ in 0..<50 {
                handler.runPendingEmbeddedTasks()
                channel.embeddedEventLoop.run()
                while let _ = try channel.readOutbound(as: ByteBuffer.self) {
                    responses += 1
                }
                if responses == 2 { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertEqual(responses, 2, "Both frames in single read should be processed in order")
            _ = try channel.finish()
        }

        // 3. Zero length packet -> deterministic channel close
        do {
            let handler = SSHAgentChannelHandler(keys: [keyModel], host: host, token: token)
            let channel = EmbeddedChannel(handler: handler)

            var zeroBuf = channel.allocator.buffer(capacity: expectedPreamble.count + 4)
            zeroBuf.writeBytes(expectedPreamble)
            zeroBuf.writeBytes([0, 0, 0, 0]) // length 0
            try channel.writeInbound(zeroBuf)

            channel.embeddedEventLoop.run()
            XCTAssertTrue(handler.isClosedForTesting, "Channel handler must be closed on zero length packet")
            XCTAssertEqual(handler.totalTrackedBytesForTesting, 0, "Buffer must be cleared")
        }

        // 4. Oversized packet (> 256 KiB) -> deterministic channel close
        do {
            let handler = SSHAgentChannelHandler(keys: [keyModel], host: host, token: token)
            let channel = EmbeddedChannel(handler: handler)

            var overBuf = channel.allocator.buffer(capacity: expectedPreamble.count + 4)
            overBuf.writeBytes(expectedPreamble)
            // 256 KiB + 1 = 262145 = 0x00040001
            overBuf.writeBytes([0x00, 0x04, 0x00, 0x01])
            try channel.writeInbound(overBuf)

            channel.embeddedEventLoop.run()
            XCTAssertTrue(handler.isClosedForTesting, "Channel handler must be closed on oversized packet")
            XCTAssertEqual(handler.totalTrackedBytesForTesting, 0, "Buffer must be cleared")
        }

        // 5. Invalid forwarding preamble -> deterministic channel close
        do {
            let handler = SSHAgentChannelHandler(keys: [keyModel], host: host, token: token)
            let channel = EmbeddedChannel(handler: handler)

            var badPreamble = channel.allocator.buffer(capacity: 40)
            badPreamble.writeBytes(Array(repeating: UInt8(0xFF), count: 40))
            try channel.writeInbound(badPreamble)

            channel.embeddedEventLoop.run()
            XCTAssertTrue(handler.isClosedForTesting, "Channel handler must be closed on invalid preamble")
            XCTAssertEqual(handler.totalTrackedBytesForTesting, 0, "Buffer must be cleared")
        }
    }

    @MainActor
    func testSSHAgentDeniedOrCancelledAuthProducesFailureWithoutSigning() async throws {
        let (keyModel, keyBlob) = try makeTestKeyAndBlob()
        let host = HostProfile(name: "Host", hostname: "server.com", username: "user")
        let signPacket = makeSignPacket(keyBlob: keyBlob)

        // Case A: Denied auth (returns false)
        do {
            let response = await SSHAgentServer.handlePacket(
                data: signPacket,
                keys: [keyModel],
                host: host,
                authenticateBiometrics: { _ in false }
            )
            var reader = SSHAgentDataReader(data: response)
            let len = reader.readUInt32()
            XCTAssertEqual(len, 1)
            XCTAssertEqual(reader.readUInt8(), 5, "Must return SSH_AGENT_FAILURE (5)")
        }

        // Case B: Cancelled auth (cancelled during prompt)
        do {
            let authStarted = ReadinessGate()
            let task = Task {
                await SSHAgentServer.handlePacket(
                    data: signPacket,
                    keys: [keyModel],
                    host: host,
                    authenticateBiometrics: { _ in
                        authStarted.succeed()
                        while !Task.isCancelled {
                            try? await Task.sleep(nanoseconds: 10_000_000)
                        }
                        return true
                    }
                )
            }
            try await authStarted.wait()
            task.cancel()
            let response = await task.value
            var reader = SSHAgentDataReader(data: response)
            let len = reader.readUInt32()
            XCTAssertEqual(len, 1)
            XCTAssertEqual(reader.readUInt8(), 5, "Must return SSH_AGENT_FAILURE (5) on cancellation")
        }

        // Case C: Real channel handler with denied auth returns failure to client while channel stays active
        do {
            let handler = SSHAgentChannelHandler(
                keys: [keyModel],
                host: host,
                token: [],
                packetProcessor: { data in
                    await SSHAgentServer.handlePacket(
                        data: data,
                        keys: [keyModel],
                        host: host,
                        authenticateBiometrics: { _ in false }
                    )
                }
            )
            let channel = EmbeddedChannel(handler: handler)

            var buf = channel.allocator.buffer(capacity: signPacket.count)
            buf.writeBytes(signPacket)
            try channel.writeInbound(buf)

            for _ in 0..<50 {
                handler.runPendingEmbeddedTasks()
                channel.embeddedEventLoop.run()
                if let respBuf = try channel.readOutbound(as: ByteBuffer.self) {
                    var reader = SSHAgentDataReader(data: Data(respBuf.readableBytesView))
                    _ = reader.readUInt32()
                    XCTAssertEqual(reader.readUInt8(), 5, "Channel must receive SSH_AGENT_FAILURE (5)")
                    break
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertFalse(handler.isClosedForTesting, "Channel should remain active to serve subsequent requests")
            _ = try channel.finish()
        }
    }

    @MainActor
    func testSSHAgentClosingWaitingChannelDoesNotCancelActiveChannel() async throws {
        let (keyModel, keyBlob) = try makeTestKeyAndBlob()
        let host = HostProfile(name: "Host", hostname: "server.com", username: "user")
        let signPacket = makeSignPacket(keyBlob: keyBlob)
        let coordinator = AgentSigningCoordinator(maxWaiters: 16)

        let ch1Gate = ReadinessGate()
        final class BoolHolder: @unchecked Sendable {
            private let lock = NSLock()
            private var _val = false
            var value: Bool {
                get { lock.lock(); defer { lock.unlock() }; return _val }
                set { lock.lock(); _val = newValue; lock.unlock() }
            }
        }
        let ch1Completed = BoolHolder()
        let ch2Completed = BoolHolder()

        let ch1Handler = SSHAgentChannelHandler(
            keys: [keyModel],
            host: host,
            token: [],
            signingCoordinator: coordinator,
            packetProcessor: { _ in
                guard await coordinator.acquire() else {
                    return SSHAgentServer.makeFailurePacket()
                }
                defer { coordinator.release() }
                try? await ch1Gate.wait()
                ch1Completed.value = true
                return SSHAgentServer.makeEd25519SignResponse(signature: Data(repeating: 0x11, count: 64))
            }
        )

        let ch2Handler = SSHAgentChannelHandler(
            keys: [keyModel],
            host: host,
            token: [],
            signingCoordinator: coordinator,
            packetProcessor: { _ in
                guard await coordinator.acquire() else {
                    return SSHAgentServer.makeFailurePacket()
                }
                defer { coordinator.release() }
                ch2Completed.value = true
                return SSHAgentServer.makeEd25519SignResponse(signature: Data(repeating: 0x22, count: 64))
            }
        )

        let channel1 = EmbeddedChannel(handler: ch1Handler)
        let channel2 = EmbeddedChannel(handler: ch2Handler)

        // Start Channel 1 request
        var buf1 = channel1.allocator.buffer(capacity: signPacket.count)
        buf1.writeBytes(signPacket)
        try channel1.writeInbound(buf1)

        // Wait until Channel 1 holds coordinator
        for _ in 0..<50 {
            if coordinator.isBusyForTesting { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(coordinator.isBusyForTesting, "Channel 1 should hold coordinator permit")

        // Start Channel 2 request -> will wait in coordinator queue
        var buf2 = channel2.allocator.buffer(capacity: signPacket.count)
        buf2.writeBytes(signPacket)
        try channel2.writeInbound(buf2)

        // Wait until Channel 2 is registered as waiter
        for _ in 0..<50 {
            if coordinator.waiterCountForTesting == 1 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(coordinator.waiterCountForTesting, 1, "Channel 2 should be waiting in coordinator")

        // Now CLOSE Channel 2 while it waits
        _ = try channel2.finish()

        // Verify Channel 2 was removed from coordinator waiters
        for _ in 0..<50 {
            if coordinator.waiterCountForTesting == 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(coordinator.waiterCountForTesting, 0, "Channel 2 should be cancelled and removed from coordinator")
        XCTAssertFalse(ch2Completed.value, "Channel 2 must not complete")

        // Verify Channel 1 is STILL running and NOT cancelled!
        XCTAssertTrue(coordinator.isBusyForTesting, "Channel 1 must still hold coordinator")
        XCTAssertFalse(ch1Completed.value, "Channel 1 should still be waiting on ch1Gate")

        // Now release Channel 1 gate
        ch1Gate.succeed()

        // Wait for Channel 1 to complete and write response
        for _ in 0..<50 {
            ch1Handler.runPendingEmbeddedTasks()
            channel1.embeddedEventLoop.run()
            if ch1Completed.value { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        ch1Handler.runPendingEmbeddedTasks()
        channel1.embeddedEventLoop.run()

        XCTAssertTrue(ch1Completed.value, "Channel 1 must succeed without being affected by Channel 2 closure")
        guard var resp1 = try channel1.readOutbound(as: ByteBuffer.self) else {
            XCTFail("Channel 1 should have produced a response")
            return
        }
        var reader = SSHAgentDataReader(data: Data(resp1.readBytes(length: resp1.readableBytes)!))
        _ = reader.readUInt32()
        XCTAssertEqual(reader.readUInt8(), 14, "Channel 1 should return signResponse (14)")

        _ = try channel1.finish()
    }


    // MARK: - Finding 3 Regressions: Atomic Agent Forwarded-Signing Admission

    func testAgentSigningCoordinatorDeterministicAdmissionAndHandoff() async {
        let coordinator = AgentSigningCoordinator(maxWaiters: 4)

        // 1. Uncontended acquisition
        let first = await coordinator.acquire()
        XCTAssertTrue(first, "Uncontended acquisition must succeed")
        XCTAssertTrue(coordinator.isBusyForTesting)
        XCTAssertEqual(coordinator.waiterCountForTesting, 0)

        // 2. Queue waiters (FIFO order)
        final class ResultCollector: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var order: [Int] = []
            func record(_ val: Int) {
                lock.lock()
                order.append(val)
                lock.unlock()
            }
        }
        let collector = ResultCollector()

        let task1 = Task {
            let acquired = await coordinator.acquire()
            if acquired {
                collector.record(1)
                coordinator.release()
            }
        }
        for _ in 0..<50 where coordinator.waiterCountForTesting < 1 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        let task2 = Task {
            let acquired = await coordinator.acquire()
            if acquired {
                collector.record(2)
                coordinator.release()
            }
        }
        for _ in 0..<50 where coordinator.waiterCountForTesting < 2 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        let task3 = Task {
            let acquired = await coordinator.acquire()
            if acquired {
                collector.record(3)
                coordinator.release()
            }
        }
        for _ in 0..<50 where coordinator.waiterCountForTesting < 3 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(coordinator.waiterCountForTesting, 3)

        // 3. Queue-full rejection: capacity is 4
        let task4 = Task {
            let acquired = await coordinator.acquire()
            if acquired {
                collector.record(4)
                coordinator.release()
            }
            return acquired
        }
        for _ in 0..<50 {
            if coordinator.waiterCountForTesting == 4 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(coordinator.waiterCountForTesting, 4)

        // 5th waiter exceeds maxWaiters of 4
        let rejected = await coordinator.acquire()
        XCTAssertFalse(rejected, "Acquisition when waiter queue is at limit must immediately fail")

        // Release first owner -> triggers FIFO handoff
        coordinator.release()
        _ = await task1.value
        _ = await task2.value
        _ = await task3.value
        _ = await task4.value

        // Wait for all handoffs to complete
        for _ in 0..<50 {
            if !coordinator.isBusyForTesting && coordinator.waiterCountForTesting == 0 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertFalse(coordinator.isBusyForTesting, "Coordinator must return to idle")
        XCTAssertEqual(coordinator.waiterCountForTesting, 0)
        XCTAssertEqual(collector.order, [1, 2, 3, 4], "Handoff must be strictly FIFO")
    }

    func testDeterministicReleaseWhileEnteringAdmissionAndQueuedBeforeRelease() async {
        let coordinator = AgentSigningCoordinator(maxWaiters: 4)

        // Case 1: Release occurs right before arriving caller executes admission
        let acquired1 = await coordinator.acquire()
        XCTAssertTrue(acquired1)
        XCTAssertTrue(coordinator.isBusyForTesting)

        let gateBeforeAcquire = ReadinessGate()
        let callerTask = Task {
            try? await gateBeforeAcquire.wait()
            return await coordinator.acquire()
        }

        // Release owner 1, then release the gate for callerTask to enter admission
        coordinator.release()
        gateBeforeAcquire.succeed()

        let callerResult = await callerTask.value
        XCTAssertTrue(callerResult, "Arriving caller must observe free permit and succeed immediately")
        XCTAssertTrue(coordinator.isBusyForTesting)
        coordinator.release()
        XCTAssertFalse(coordinator.isBusyForTesting)

        // Case 2: Queued before release (waiter in queue when release occurs)
        let acquired2 = await coordinator.acquire()
        XCTAssertTrue(acquired2)

        let queuedGate = ReadinessGate()
        let queuedTask = Task {
            let res = await coordinator.acquire()
            if res {
                queuedGate.succeed()
                coordinator.release()
            }
            return res
        }

        for _ in 0..<50 {
            if coordinator.waiterCountForTesting == 1 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(coordinator.waiterCountForTesting, 1)

        coordinator.release()
        try? await queuedGate.wait()
        let queuedResult = await queuedTask.value
        XCTAssertTrue(queuedResult, "Queued waiter must be granted permit on release")
        XCTAssertFalse(coordinator.isBusyForTesting)
        XCTAssertEqual(coordinator.waiterCountForTesting, 0)
    }

    func testAgentSigningCoordinatorCancellationCases() async {
        let coordinator = AgentSigningCoordinator(maxWaiters: 4)

        // 1. Cancelled before entry
        let preCancelledTask = Task {
            return await coordinator.acquire()
        }
        preCancelledTask.cancel()
        let preCancelledResult = await preCancelledTask.value
        XCTAssertFalse(preCancelledResult, "Pre-cancelled task must return false immediately")
        XCTAssertFalse(coordinator.isBusyForTesting)

        // 2. Cancelled while queued
        let acquiredFirst = await coordinator.acquire()
        XCTAssertTrue(acquiredFirst)
        XCTAssertTrue(coordinator.isBusyForTesting)

        let queuedTask = Task {
            return await coordinator.acquire()
        }

        for _ in 0..<50 {
            if coordinator.waiterCountForTesting == 1 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(coordinator.waiterCountForTesting, 1)

        queuedTask.cancel()
        let queuedResult = await queuedTask.value
        XCTAssertFalse(queuedResult, "Cancelled queued waiter must return false")
        XCTAssertEqual(coordinator.waiterCountForTesting, 0, "Cancelled waiter must be removed from queue")

        // Release the owner
        coordinator.release()
        XCTAssertFalse(coordinator.isBusyForTesting)
    }

    func testAgentSigningCoordinatorStress80000Operations() async {
        let coordinator = AgentSigningCoordinator(maxWaiters: 64)
        let totalWorkers = 8
        let iterationsPerWorker = 10_000
        let totalExpectedOps = totalWorkers * iterationsPerWorker

        final class AtomicCounter: @unchecked Sendable {
            private let lock = NSLock()
            private var currentActive: Int = 0
            private(set) var maxConcurrent: Int = 0
            private(set) var completedCount: Int = 0

            func enter() -> Bool {
                lock.lock()
                currentActive += 1
                if currentActive > maxConcurrent {
                    maxConcurrent = currentActive
                }
                let ok = (currentActive == 1)
                lock.unlock()
                return ok
            }

            func exit() {
                lock.lock()
                currentActive -= 1
                completedCount += 1
                lock.unlock()
            }
        }

        let tracker = AtomicCounter()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<totalWorkers {
                group.addTask {
                    for _ in 0..<iterationsPerWorker {
                        let acquired = await coordinator.acquire()
                        if acquired {
                            let singleOwner = tracker.enter()
                            XCTAssertTrue(singleOwner, "At most one signing operation may own admission simultaneously")
                            tracker.exit()
                            coordinator.release()
                        }
                    }
                }
            }
        }

        XCTAssertEqual(tracker.completedCount, totalExpectedOps, "All 80,000 operations must complete")
        XCTAssertEqual(tracker.maxConcurrent, 1, "Maximum simultaneous ownership must be exactly 1")
        XCTAssertFalse(coordinator.isBusyForTesting, "Coordinator must be idle after stress")
        XCTAssertEqual(coordinator.waiterCountForTesting, 0, "No waiters left in queue")
    }

    func testHostProfileAgentForwardingKeyIdsDecoding() throws {
        let keyIds = [UUID(), UUID()]
        let host = HostProfile(name: "H", hostname: "h.com", agentForwardingKeyIds: keyIds)
        let data = try JSONEncoder().encode(host)
        let decoded = try JSONDecoder().decode(HostProfile.self, from: data)
        XCTAssertEqual(decoded.agentForwardingKeyIds, keyIds)

        // JSON without key -> decodes to nil
        let minimalJSON = """
        {
            "id": "\(UUID().uuidString)",
            "name": "Server",
            "hostname": "example.com",
            "port": 22,
            "username": "root",
            "authMethod": "SSH Key"
        }
        """.data(using: .utf8)!
        let decodedMinimal = try JSONDecoder().decode(HostProfile.self, from: minimalJSON)
        XCTAssertNil(decodedMinimal.agentForwardingKeyIds)
    }



}
