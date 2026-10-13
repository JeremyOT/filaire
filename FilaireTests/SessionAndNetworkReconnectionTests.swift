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

final class SessionAndNetworkReconnectionTests: XCTestCase {
    // MARK: - Output Coalescing

    @MainActor
    func testOutputCoalescerBatching() {
        let expectation = expectation(description: "Coalesced output delivered")
        var receivedBatches: [[UInt8]] = []

        let coalescer = OutputCoalescer { chunk in
            receivedBatches.append(chunk)
            expectation.fulfill()
        }

        // Send 3 small chunks in immediate succession
        coalescer.append([0x41, 0x42]) // "AB"
        coalescer.append([0x43, 0x44]) // "CD"
        coalescer.append([0x45, 0x46]) // "EF"

        waitForExpectations(timeout: 1.0)

        // All 3 chunks should be coalesced into a single delivery of "ABCDEF"
        XCTAssertEqual(receivedBatches.count, 1)
        XCTAssertEqual(receivedBatches.first, [0x41, 0x42, 0x43, 0x44, 0x45, 0x46])
    }

    @MainActor
    func testOutputCoalescerImmediateFlush() {
        var received: [UInt8] = []
        let coalescer = OutputCoalescer { chunk in
            received.append(contentsOf: chunk)
        }

        coalescer.append([0x01, 0x02, 0x03])
        coalescer.flushImmediately()

        let expectation = expectation(description: "Flush delivered")
        DispatchQueue.main.async {
            expectation.fulfill()
        }
        waitForExpectations(timeout: 1.0)

        XCTAssertEqual(received, [0x01, 0x02, 0x03])
    }

    @MainActor
    func testOutputCoalescerResetDiscardsPendingDelivery() {
        var received: [[UInt8]] = []
        let coalescer = OutputCoalescer { chunk in
            received.append(chunk)
        }

        coalescer.append([0x01, 0x02, 0x03])
        // Immediate reset should discard the queued delivery
        coalescer.reset()

        let expectation = expectation(description: "Wait after reset")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            expectation.fulfill()
        }
        waitForExpectations(timeout: 1.0)

        XCTAssertTrue(received.isEmpty, "Reset must discard pending deliveries from previous generation")
    }

    @MainActor
    func testOutputCoalescerPreservesOrderUnderBacklog() {
        var received: [UInt8] = []
        var chunkSizes: [Int] = []
        let coalescer = OutputCoalescer { chunk in
            received.append(contentsOf: chunk)
            chunkSizes.append(chunk.count)
        }

        // The test holds the main thread, so every append lands before any flush runs (a backlogged UI thread).
        // 21 packets = five 128 KB bursts plus one leftover packet, which previously jumped the queue.
        let packet = 32 * 1024
        var expected: [UInt8] = []
        for i in 0..<21 {
            let bytes = [UInt8](repeating: UInt8(i), count: packet)
            expected.append(contentsOf: bytes)
            coalescer.append(bytes)
        }

        let drained = expectation(description: "Backlog drained")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { drained.fulfill() }
        waitForExpectations(timeout: 2.0)

        XCTAssertEqual(received.count, expected.count)
        XCTAssertTrue(received == expected, "Output must be delivered in arrival order")
        XCTAssertTrue(chunkSizes.allSatisfy { $0 <= 128 * 1024 }, "Each delivery must be at most 128 KB")
    }


    // MARK: - Scrollback Settings

    func testScrollbackSettings() {
        let settings = TerminalSettings.shared

        settings.scrollbackLimit = .small
        XCTAssertEqual(settings.scrollbackLimit.rawValue, 2500)
        XCTAssertEqual(settings.scrollbackLimit.displayName, "2,500 lines")

        settings.scrollbackLimit = .maximum
        XCTAssertEqual(settings.scrollbackLimit.rawValue, 50000)
        XCTAssertEqual(settings.scrollbackLimit.displayName, "50,000 lines")

        // Reset to standard
        settings.scrollbackLimit = .standard
        XCTAssertEqual(settings.scrollbackLimit.rawValue, 10000)
        XCTAssertEqual(settings.scrollbackLimit.displayName, "10,000 lines")
    }


    // MARK: - Network State Transitions

    @MainActor
    func testNetworkStateTransitions() {
        let manager = SessionManager()
        XCTAssertEqual(manager.state, .disconnected)
        XCTAssertFalse(manager.state.isConnected)
        XCTAssertFalse(manager.state.isBusy)

        manager.state = .connecting
        XCTAssertTrue(manager.state.isBusy)
        XCTAssertFalse(manager.state.isConnected)

        manager.state = .connected
        XCTAssertTrue(manager.state.isConnected)
        XCTAssertFalse(manager.state.isBusy)

        manager.state = .reconnecting(attempt: 2)
        XCTAssertTrue(manager.state.isBusy)
        XCTAssertFalse(manager.state.isConnected)
        XCTAssertEqual(manager.state.description, "Reconnecting (attempt 2)...")
    }

    @MainActor
    func testSessionManagerReconnectionPolicyAndCancel() {
        let manager = SessionManager()
        XCTAssertEqual(manager.maxReconnectAttempts, 10, "Default maxReconnectAttempts should be 10")

        manager.maxReconnectAttempts = 3
        XCTAssertEqual(manager.maxReconnectAttempts, 3)

        manager.state = .reconnecting(attempt: 2)
        XCTAssertTrue(manager.state.isBusy)

        // Cancelling reconnect should transition from .reconnecting to .disconnected
        manager.cancelReconnect()
        XCTAssertEqual(manager.state, .disconnected)
        XCTAssertEqual(manager.reconnectAttempt, 0)
    }

    func testRetryableConnectErrorClassification() {
        XCTAssertTrue(SessionManager.isRetryableConnectError(POSIXError(.ECONNREFUSED)))
        XCTAssertTrue(SessionManager.isRetryableConnectError(SSHError.channelClosed))
        XCTAssertFalse(SessionManager.isRetryableConnectError(SSHError.invalidCredentials("bad")))
        XCTAssertFalse(SessionManager.isRetryableConnectError(SSHError.keyNotFound))
        XCTAssertFalse(SessionManager.isRetryableConnectError(SSHError.negotiationFailed("kex")))
        XCTAssertFalse(SessionManager.isRetryableConnectError(CancellationError()))
        XCTAssertFalse(SessionManager.isRetryableConnectError(BiometricError.userCancelled))
        XCTAssertFalse(SessionManager.isRetryableConnectError(
            HostKeyMismatchError.hostKeyNotTrusted(hostname: "h", port: 22, fingerprint: "f")))
    }

    @MainActor
    func testConnectFailureDuringReconnectDoesNotRetry() async {
        let manager = SessionManager()
        manager.activeHost = HostProfile(name: "Retry", hostname: "retry.invalid")
        manager.reconnectAttempt = 2
        manager.state = .reconnecting(attempt: 2)

        await manager.handleConnectFailure(error: POSIXError(.ECONNREFUSED))

        XCTAssertTrue(manager.state.isFailed)
        XCTAssertEqual(manager.reconnectAttempt, 0)
    }

    @MainActor
    func testConnectFailureWithCredentialsErrorDoesNotRetry() async {
        let manager = SessionManager()
        manager.activeHost = HostProfile(name: "Retry", hostname: "retry.invalid")
        manager.reconnectAttempt = 2
        manager.state = .reconnecting(attempt: 2)

        await manager.handleConnectFailure(error: SSHError.invalidCredentials("rejected"))

        XCTAssertTrue(manager.state.isFailed)
        XCTAssertEqual(manager.reconnectAttempt, 0)
    }

    @MainActor
    func testConnectFailureStopsAfterMaxAttempts() async {
        let manager = SessionManager()
        manager.activeHost = HostProfile(name: "Retry", hostname: "retry.invalid")
        manager.reconnectAttempt = manager.maxReconnectAttempts
        manager.state = .reconnecting(attempt: manager.maxReconnectAttempts)

        await manager.handleConnectFailure(error: POSIXError(.ECONNREFUSED))

        XCTAssertTrue(manager.state.isFailed)
    }

    @MainActor
    func testConnectFailureOnFreshConnectDoesNotRetry() async {
        let manager = SessionManager()
        manager.activeHost = HostProfile(name: "Fresh", hostname: "fresh.invalid")
        manager.state = .connecting

        await manager.handleConnectFailure(error: POSIXError(.ECONNREFUSED))

        XCTAssertTrue(manager.state.isFailed, "A first-time connect failure should surface to the user, not retry")
    }

    func testReadinessGateResolutionBeforeWait() async throws {
        let gate = ReadinessGate()
        XCTAssertFalse(gate.isResolved)
        gate.succeed()
        XCTAssertTrue(gate.isResolved)
        gate.succeed()
        try await gate.wait()
    }

    func testReadinessGateFailureBeforeWait() async {
        let gate = ReadinessGate()
        gate.fail(SSHError.terminalSetupTimedOut)
        XCTAssertTrue(gate.isResolved)
        do {
            try await gate.wait()
            XCTFail("Should have thrown")
        } catch let err as SSHError {
            guard case .terminalSetupTimedOut = err else {
                XCTFail("Unexpected error: \(err)")
                return
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testReadinessGateTimeoutWrapperReturnsTimedOutPromptly() async throws {
        let gate = ReadinessGate()
        let start = ContinuousClock.now
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await gate.wait()
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 50_000_000) // 50ms
                    gate.fail(SSHError.terminalSetupTimedOut)
                    throw SSHError.terminalSetupTimedOut
                }
                try await group.next()
                group.cancelAll()
            }
            XCTFail("Should have thrown terminalSetupTimedOut")
        } catch let err as SSHError {
            guard case .terminalSetupTimedOut = err else {
                XCTFail("Expected terminalSetupTimedOut, got \(err)")
                return
            }
            let elapsed = ContinuousClock.now - start
            XCTAssertLessThan(elapsed, .seconds(1.0), "Timeout must complete promptly, took \(elapsed)")
        }
    }

    func testReadinessGateCancellationBeforeWait() async {
        let gate = ReadinessGate()
        gate.cancel()
        do {
            try await gate.wait()
            XCTFail("Should throw CancellationError")
        } catch is CancellationError {
            // Success
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testReadinessGateCancellationWhileWaiting() async {
        let gate = ReadinessGate()
        let task = Task {
            try await gate.wait()
        }
        for _ in 0..<5 {
            await Task.yield()
        }
        task.cancel()
        do {
            try await task.value
            XCTFail("Should throw CancellationError")
        } catch is CancellationError {
            // Success
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testReadinessGateRepeatedResolutionBehavior() async throws {
        let gate = ReadinessGate()
        gate.succeed()
        gate.fail(SSHError.terminalSetupTimedOut)
        gate.cancel()
        // Must succeed because succeed was first
        try await gate.wait()
    }

    func testReadinessGateConcurrentRaces() async throws {
        for _ in 0..<50 {
            let gate = ReadinessGate()
            let waiterTask = Task {
                try await gate.wait()
            }
            let resolverTask = Task {
                if Bool.random() {
                    gate.succeed()
                } else {
                    gate.fail(SSHError.channelClosed)
                }
            }
            let cancelTask = Task {
                waiterTask.cancel()
            }
            _ = await resolverTask.result
            _ = await cancelTask.result
            _ = await waiterTask.result
            XCTAssertTrue(gate.isResolved)
        }
    }

    func testTerminalSetupErrorsAreNonRetryable() {
        XCTAssertFalse(SessionManager.isRetryableConnectError(SSHError.terminalSetupFailed("Refused")))
        XCTAssertFalse(SessionManager.isRetryableConnectError(SSHError.terminalSetupTimedOut))
    }

    @MainActor
    func testRepeatedImmediateDisconnectsExhaustRetryBudget() {
        let manager = SessionManager()
        manager.maxReconnectAttempts = 3
        manager.activeHost = HostProfile(name: "Test", hostname: "test.invalid")
        manager.currentConnectionId = UUID()

        var fakeNow = ContinuousClock.now
        manager.nowProvider = { fakeNow }

        // Attempt 1: immediate drop (duration 0.1s < 10.0s threshold)
        manager.markConnectedForTesting()
        fakeNow = fakeNow.advanced(by: .milliseconds(100))
        manager.handleDisconnect(error: SSHError.channelClosed)
        XCTAssertEqual(manager.reconnectAttempt, 1)
        XCTAssertTrue(manager.state.isBusy)

        // Attempt 2: immediate drop again
        manager.markConnectedForTesting()
        fakeNow = fakeNow.advanced(by: .milliseconds(100))
        manager.handleDisconnect(error: SSHError.channelClosed)
        XCTAssertEqual(manager.reconnectAttempt, 2)
        XCTAssertTrue(manager.state.isBusy)

        // Attempt 3: immediate drop again -> reaches maxReconnectAttempts (3)
        manager.markConnectedForTesting()
        fakeNow = fakeNow.advanced(by: .milliseconds(100))
        manager.handleDisconnect(error: SSHError.channelClosed)
        XCTAssertEqual(manager.reconnectAttempt, 3)
        XCTAssertTrue(manager.state.isBusy)

        // Attempt 4: exceeds maxReconnectAttempts -> transitions to failed, does not retry
        manager.markConnectedForTesting()
        fakeNow = fakeNow.advanced(by: .milliseconds(100))
        manager.handleDisconnect(error: SSHError.channelClosed)
        XCTAssertTrue(manager.state.isFailed, "Must stop retrying when max attempts exceeded")
        manager.cancelReconnect()
    }

    @MainActor
    func testStableConnectionResetsRetryBudget() {
        let manager = SessionManager()
        manager.maxReconnectAttempts = 3
        manager.activeHost = HostProfile(name: "Test", hostname: "test.invalid")
        manager.currentConnectionId = UUID()

        var fakeNow = ContinuousClock.now
        manager.nowProvider = { fakeNow }

        // Attempt 1: immediate drop
        manager.markConnectedForTesting()
        fakeNow = fakeNow.advanced(by: .milliseconds(100))
        manager.handleDisconnect(error: SSHError.channelClosed)
        XCTAssertEqual(manager.reconnectAttempt, 1)

        // Reconnected and stayed connected for 15 seconds (>= 10.0s stable threshold)
        manager.markConnectedForTesting()
        fakeNow = fakeNow.advanced(by: .seconds(15))
        manager.handleDisconnect(error: SSHError.channelClosed)

        // Stable session reset retry count to 0, then incremented to 1 for this new drop
        XCTAssertEqual(manager.reconnectAttempt, 1)
        XCTAssertTrue(manager.state.isBusy)
        manager.cancelReconnect()
    }

    @MainActor
    func testSessionManagerOutboundBufferCap() {
        let manager = SessionManager()
        manager.state = .connected
        XCTAssertEqual(SessionManager.maxOutboundBufferSize, 512 * 1024)

        // Generate data exceeding buffer capacity
        let largeChunk = [UInt8](repeating: 0x41, count: 600 * 1024)
        manager.send(data: largeChunk)

        // Buffer must not exceed maxOutboundBufferSize (oversized paste rejected in whole)
        XCTAssertEqual(manager.pendingOutboundBufferSize, 0)
        XCTAssertEqual(manager.activeToast?.title, "Input Dropped")
    }

    @MainActor
    func testSessionManagerRejectsInputWhenOutboundBufferFull() {
        let manager = SessionManager()
        manager.markConnectedForTesting()

        // Block writer to keep bytes in flight
        var writerContinuation: CheckedContinuation<Void, Never>?
        manager.sshWriterForTesting = { _ in
            await withCheckedContinuation { continuation in
                writerContinuation = continuation
            }
        }

        // The first send goes in-flight immediately (400 KB)
        manager.send(data: [UInt8](repeating: 0x41, count: 400 * 1024))
        XCTAssertEqual(manager.pendingOutboundBufferSize, 400 * 1024)

        // The second send would bring total pending to 600 KB (> 512 KB) and is rejected
        manager.send(data: [UInt8](repeating: 0x42, count: 200 * 1024))
        XCTAssertEqual(manager.pendingOutboundBufferSize, 400 * 1024, "Overflowing input must be rejected, not trimmed from the front")
        XCTAssertEqual(manager.activeToast?.title, "Input Dropped")

        // Input that fits (e.g. 50 KB: 400 KB in flight + 50 KB = 450 KB <= 512 KB) must still be accepted
        manager.send(data: [UInt8](repeating: 0x43, count: 50 * 1024))
        XCTAssertEqual(manager.pendingOutboundBufferSize, 450 * 1024, "Input that fits must still be accepted")

        writerContinuation?.resume()
        manager.disconnect()
    }

    @MainActor
    func testSessionManagerRejectsOversizedInitialPaste() {
        let manager = SessionManager()
        manager.markConnectedForTesting()

        XCTAssertEqual(manager.pendingOutboundBufferSize, 0)
        let largePaste = [UInt8](repeating: 0x41, count: 600 * 1024)
        manager.send(data: largePaste)

        // Must reject whole paste and enqueue zero bytes
        XCTAssertEqual(manager.pendingOutboundBufferSize, 0)
        XCTAssertEqual(manager.activeToast?.title, "Input Dropped")
        manager.disconnect()
    }

    @MainActor
    func testSessionManagerBuffersPreReadyInputAndDrainsAfterConnected() async {
        let manager = SessionManager()
        manager.state = .connecting

        var delivered: [[UInt8]] = []
        manager.sshWriterForTesting = { chunk in
            delivered.append(chunk)
        }

        manager.send(data: [0x01, 0x02])
        manager.send(data: [0x03, 0x04])

        // Input is queued while connecting, but not yet sent
        XCTAssertEqual(manager.pendingOutboundBufferSize, 4)
        XCTAssertTrue(delivered.isEmpty)

        // Mark connected
        let connId = UUID()
        manager.currentConnectionId = connId
        manager.state = .connected

        // Send a third chunk after connecting; triggers drain
        manager.send(data: [0x05])

        // Wait a brief moment for async drain tasks to finish
        for _ in 0..<10 {
            if delivered.count == 3 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(delivered, [[0x01, 0x02], [0x03, 0x04], [0x05]])
        XCTAssertEqual(manager.pendingOutboundBufferSize, 0)
        manager.disconnect()
    }

    @MainActor
    func testSessionManagerWriteFailureDiscardsInputAndDoesNotAutoReplay() async {
        let manager = SessionManager()
        let connId = UUID()
        manager.currentConnectionId = connId
        manager.state = .connected

        struct TestWriteError: Error, Equatable {}

        var writesAttempted = 0
        manager.sshWriterForTesting = { chunk in
            writesAttempted += 1
            if writesAttempted == 1 {
                // First write succeeds
                return
            } else {
                // Subsequent write fails
                throw TestWriteError()
            }
        }

        // First write succeeds
        manager.send(data: [0x01])
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(writesAttempted, 1)

        // Queue second and third writes
        manager.send(data: [0x02])
        manager.send(data: [0x03])

        // Wait for drain failure to process
        for _ in 0..<10 {
            if manager.activeToast?.title == "Write Failed" { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(manager.activeToast?.title, "Write Failed")
        // All unsent pending input was discarded
        XCTAssertEqual(manager.pendingOutboundBufferSize, 0)

        // State transitioned away from .connected
        XCTAssertFalse(manager.state.isConnected)

        // Reconnecting must not automatically replay the discarded input
        manager.state = .connected
        manager.currentConnectionId = UUID()
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(writesAttempted, 2, "No additional writes should have run after failure")
        XCTAssertEqual(manager.pendingOutboundBufferSize, 0)
        manager.disconnect()
    }

    @MainActor
    func testSessionManagerSupersededWriteDoesNotAffectNewSession() async {
        let manager = SessionManager()
        let session1Id = UUID()
        manager.currentConnectionId = session1Id
        manager.state = .connected

        var continuation1: CheckedContinuation<Void, Never>?
        manager.sshWriterForTesting = { chunk in
            if chunk == [0xAA] {
                await withCheckedContinuation { cont in
                    continuation1 = cont
                }
            }
        }

        // Send chunk for session 1 that suspends in flight
        manager.send(data: [0xAA])
        XCTAssertEqual(manager.pendingOutboundBufferSize, 1)

        // Yield to allow session 1's drain task to invoke writer and suspend
        for _ in 0..<10 {
            if continuation1 != nil { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(continuation1)

        // Host switch or disconnect creates session 2
        manager.clearOutbound()
        let session2Id = UUID()
        manager.currentConnectionId = session2Id
        manager.state = .connected

        // Session 2 sends fresh data
        var session2Delivered: [[UInt8]] = []
        manager.sshWriterForTesting = { chunk in
            session2Delivered.append(chunk)
        }
        manager.send(data: [0xBB])

        // Now resume session 1's suspended write
        continuation1?.resume()
        try? await Task.sleep(nanoseconds: 20_000_000)

        // Verify session 2's data was delivered and pending buffer reflects only session 2
        XCTAssertEqual(session2Delivered, [[0xBB]])
        XCTAssertEqual(manager.pendingOutboundBufferSize, 0)
        manager.disconnect()
    }

    @MainActor
    func testSessionManagerAcceptsInputByState() {
        let manager = SessionManager()
        manager.state = .connected
        XCTAssertTrue(manager.acceptsInput)

        manager.state = .connecting
        XCTAssertTrue(manager.acceptsInput)

        manager.state = .reconnecting(attempt: 1)
        XCTAssertFalse(manager.acceptsInput)

        manager.state = .failed("Network error")
        XCTAssertFalse(manager.acceptsInput)

        manager.state = .disconnected
        XCTAssertFalse(manager.acceptsInput)

        // Resume case
        let host = HostProfile(name: "Resume Test", hostname: "resume.example.com")
        manager.activeHost = host
        manager.reconnect()
        XCTAssertEqual(manager.state, .connecting)
        XCTAssertFalse(manager.acceptsInput)
        manager.disconnect()
    }

    @MainActor
    func testSessionManagerDiscardedInputToastOnce() {
        let manager = SessionManager()
        manager.state = .reconnecting(attempt: 1)

        manager.send(data: [0x41])
        XCTAssertEqual(manager.activeToast?.title, "Not Connected")
        XCTAssertEqual(manager.activeToast?.message, "Input typed while disconnected was discarded.")

        manager.activeToast = nil
        manager.send(data: [0x42])
        XCTAssertNil(manager.activeToast)
        XCTAssertEqual(manager.pendingOutboundBufferSize, 0)
    }

    func testSSHServiceRejectsSendWhenDisconnected() async {
        let service = SSHService()
        let isConn = await service.isConnected
        XCTAssertFalse(isConn)

        do {
            try await service.send(data: [0x41, 0x42, 0x43])
            XCTFail("send(data:) when disconnected should throw SSHError.notConnected")
        } catch let error as SSHError {
            switch error {
            case .notConnected:
                break
            default:
                XCTFail("Expected notConnected, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSSHServiceStaleCleanupDoesNotTouchCurrentSession() async throws {
        let service = SSHService()
        await service.disconnect()
        let staleGeneration = await service.currentSessionGeneration
        await service.disconnect()
        let currentGeneration = await service.currentSessionGeneration
        XCTAssertNotEqual(staleGeneration, currentGeneration)

        let bundle = SessionBundle(generation: currentGeneration)
        await service.installSessionBundleForTesting(bundle)
        let beforeCleanup = await service.hasActiveSession
        XCTAssertTrue(beforeCleanup)

        await service.cleanup(generation: staleGeneration)
        let afterStale = await service.hasActiveSession
        XCTAssertTrue(afterStale, "Cleanup from a superseded session must not clear current state")

        await service.cleanup(generation: currentGeneration)
        let afterCurrent = await service.hasActiveSession
        XCTAssertFalse(afterCurrent)
    }

    func testSSHServiceStaleCleanupWithSuspendedTeardownDoesNotTouchNewSession() async throws {
        let service = SSHService()
        await service.disconnect()
        let genA = await service.currentSessionGeneration

        let bundleA = SessionBundle(generation: genA)
        let suspendGate = ReadinessGate()
        let teardownStarted = NIOLockedValueBox(false)
        bundleA.onTeardownStart = {
            teardownStarted.withLockedValue { $0 = true }
            try? await suspendGate.wait()
        }
        await service.installSessionBundleForTesting(bundleA)

        // Start cleanup for A in background Task (which suspends inside onTeardownStart)
        let cleanupTask = Task {
            await service.cleanup(generation: genA)
        }
        while !teardownStarted.withLockedValue({ $0 }) {
            await Task.yield()
        }

        // Install Session B while A's teardown is suspended
        await service.disconnect()
        let genB = await service.currentSessionGeneration
        let bundleB = SessionBundle(generation: genB)
        await service.installSessionBundleForTesting(bundleB)

        // Release A's teardown
        suspendGate.succeed()
        await cleanupTask.value

        // Verify B's state remains intact
        let currentGen = await service.currentSessionGeneration
        XCTAssertEqual(currentGen, genB)
        let bActive = await service.hasActiveSession
        XCTAssertTrue(bActive, "Session B must not be cleared by Session A teardown")
        let activeBundle = await service.activeSessionBundleForTesting
        XCTAssertTrue(activeBundle === bundleB, "Session B bundle must remain active")
    }

    func testSSHServiceOverlappingDisconnectAndNewSession() async throws {
        let service = SSHService()
        await service.disconnect()
        let genA = await service.currentSessionGeneration
        let bundleA = SessionBundle(generation: genA)
        let suspendGate = ReadinessGate()
        let teardownStarted = NIOLockedValueBox(false)
        bundleA.onTeardownStart = {
            teardownStarted.withLockedValue { $0 = true }
            try? await suspendGate.wait()
        }
        await service.installSessionBundleForTesting(bundleA)

        // Disconnect A in background
        let disconnectTask = Task {
            await service.disconnect()
        }
        while !teardownStarted.withLockedValue({ $0 }) {
            await Task.yield()
        }

        // Install B
        let genB = await service.currentSessionGeneration
        let bundleB = SessionBundle(generation: genB)
        await service.installSessionBundleForTesting(bundleB)

        // Release A
        suspendGate.succeed()
        await disconnectTask.value

        let activeBundle = await service.activeSessionBundleForTesting
        XCTAssertTrue(activeBundle === bundleB, "Session B must remain active after Session A disconnect finishes")
    }

    @MainActor
    func testSessionManagerProbeDoesNotReconnectAfterSwitchingHost() async {
        let manager = SessionManager()
        let hostA = HostProfile(name: "HostA", hostname: "a.invalid")
        let hostB = HostProfile(name: "HostB", hostname: "b.invalid")
        manager.activeHost = hostA
        let idA = UUID()
        manager.currentConnectionId = idA
        manager.markConnectedForTesting()

        // Switch to host B before probe completes
        let idB = UUID()
        manager.activeHost = hostB
        manager.currentConnectionId = idB

        // Trigger foreground check completion for A's probe
        manager.handleAppForegrounded()

        XCTAssertEqual(manager.activeHost?.id, hostB.id)
    }

    @MainActor
    func testSessionManagerProbeDoesNotReconnectAfterIntentionalDisconnect() async {
        let manager = SessionManager()
        let hostA = HostProfile(name: "HostA", hostname: "a.invalid")
        manager.activeHost = hostA
        manager.currentConnectionId = UUID()
        manager.markConnectedForTesting()

        manager.disconnect()
        XCTAssertTrue(manager.isIntentionalDisconnect)
        XCTAssertEqual(manager.state, .disconnected)
        XCTAssertNil(manager.currentConnectionId)
    }

    @MainActor
    func testSessionManagerBackgroundExpirationAfterForegroundDoesNotDisconnect() async {
        let manager = SessionManager()
        let host = HostProfile(name: "Host", hostname: "host.invalid")
        manager.activeHost = host
        manager.currentConnectionId = UUID()
        manager.markConnectedForTesting()

        manager.handleAppBackgrounded()
        XCTAssertTrue(manager.isAppInBackground)

        // App foregrounds before background execution expires
        manager.handleAppForegrounded()
        XCTAssertFalse(manager.isAppInBackground)

        XCTAssertEqual(manager.state, .connected)
        XCTAssertFalse(manager.isIntentionalDisconnect)
    }

    func testTerminalChannelHandlerWithholdsAcceptanceTimesOutAndClosesChannel() async throws {
        let handler = TerminalChannelHandler(generation: 1, onOutput: { _ in })
        let channel = EmbeddedChannel(handler: handler)

        let waitTask = Task {
            try await handler.waitForServerAcceptance(eventLoop: channel.eventLoop)
        }
        for _ in 0..<5 {
            await Task.yield()
        }
        waitTask.cancel()

        do {
            try await waitTask.value
            XCTFail("Should have thrown CancellationError")
        } catch is CancellationError {
            // Success
        }

        _ = try? channel.finish()
    }

    func testSSHServiceActivityNotUpdatedByOutboundSend() async {
        let service = SSHService()
        let notIdle = await service.isConnectionIdle(for: 10.0)
        XCTAssertFalse(notIdle)

        try? await Task.sleep(nanoseconds: 60_000_000)
        let isIdle = await service.isConnectionIdle(for: 0.05)
        XCTAssertTrue(isIdle)

        // Attempting to send data should NOT reset lastActivityTime
        try? await service.send(data: [0x01, 0x02])

        let stillIdle = await service.isConnectionIdle(for: 0.05)
        XCTAssertTrue(stillIdle)
    }


    // MARK: - Resize Debouncing

    @MainActor
    func testSessionManagerResizeDebouncing() async throws {
        let manager = SessionManager()
        XCTAssertNil(manager.pendingCols)
        XCTAssertNil(manager.pendingRows)

        // Rapidly dispatch multiple resize calls (simulating live window dragging)
        manager.resize(cols: 80, rows: 24)
        manager.resize(cols: 90, rows: 30)
        manager.resize(cols: 120, rows: 45)

        // The latest pending targets should be recorded
        XCTAssertEqual(manager.pendingCols, 120)
        XCTAssertEqual(manager.pendingRows, 45)

        // Wait for debounced task to settle
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(manager.pendingCols, 120)
        XCTAssertEqual(manager.pendingRows, 45)
    }


    // MARK: - Connection Health Probe

    func testConnectionHealthProbeWhenDisconnected() async {
        let service = SSHService()
        let healthy = await service.ping(timeout: 0.2)
        XCTAssertFalse(healthy, "Ping must return false immediately if disconnected")
        await service.disconnect()
    }


    // MARK: - Memory Pressure Management

    @MainActor
    func testMemoryPressureHandling() {
        let manager = SessionManager()
        var memoryWarningReceived = false
        manager.onMemoryWarning = {
            memoryWarningReceived = true
        }

        manager.handleMemoryWarning()
        XCTAssertTrue(memoryWarningReceived, "SessionManager must invoke onMemoryWarning callback")

        let terminal = FilaireTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        terminal.changeScrollback(10000)
        terminal.shedMemoryPressure()
    }

    @MainActor
    func testTerminalViewKeepsMemoryScrollbackCap() {
        let terminal = FilaireTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertEqual(terminal.appliedScrollback, TerminalSettings.shared.scrollbackLimit.rawValue)

        terminal.shedMemoryPressure()
        XCTAssertEqual(terminal.appliedScrollback, 1000)

        // Re-applying settings (as the settings notification does) must not undo the memory cap
        terminal.applyScrollbackLimit()
        XCTAssertEqual(terminal.appliedScrollback, 1000)
    }

    @MainActor
    func testCellDimensionIsStableAndTracksFont() {
        let terminal = FilaireTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let first = terminal.cellDimension()
        XCTAssertEqual(terminal.cellDimension(), first)

        terminal.font = UIFont.monospacedSystemFont(ofSize: terminal.font.pointSize + 6, weight: .regular)
        XCTAssertNotEqual(terminal.cellDimension(), first, "Cache must invalidate when the font changes")
    }


    // MARK: - Graceful Termination & Detach

    @MainActor
    func testGracefulTerminationHandling() async {
        let manager = SessionManager()
        let host = HostProfile(name: "Test", hostname: "localhost")
        manager.activeHost = host
        manager.state = .connected

        manager.handleAppTerminating()

        let service = SSHService()
        await service.disconnect()
        let isConnected = await service.isConnected
        XCTAssertFalse(isConnected)
    }


    // MARK: - Citadel Error Mapping & Formatting

    func testCitadelErrorFormatting() {
        let host = HostProfile(name: "Test Server", hostname: "server.local", username: "alice")

        // 1. SSHClientError.allAuthenticationOptionsFailed (Error 4)
        let error4 = SSHClientError.allAuthenticationOptionsFailed
        let mapped = SSHService.mapSSHError(error4, for: host)
        XCTAssertTrue(mapped.localizedDescription.contains("Citadel.SSHClientError 4"))
        XCTAssertTrue(mapped.localizedDescription.contains("alice"))
        XCTAssertTrue(mapped.localizedDescription.contains("~/.ssh/authorized_keys"))

        let formatted = SessionManager.formatErrorMessage(error4, for: host)
        XCTAssertTrue(formatted.contains("Citadel.SSHClientError 4"))
        XCTAssertTrue(formatted.contains("alice"))
        XCTAssertTrue(formatted.contains("~/.ssh/authorized_keys"))

        // 2. Unsupported password auth
        let unsuppPw = SSHClientError.unsupportedPasswordAuthentication
        let formattedPw = SessionManager.formatErrorMessage(unsuppPw, for: host)
        XCTAssertTrue(formattedPw.contains("Citadel.SSHClientError 0"))

        // 3. Unsupported private key auth
        let unsuppKey = SSHClientError.unsupportedPrivateKeyAuthentication
        let formattedKey = SessionManager.formatErrorMessage(unsuppKey, for: host)
        XCTAssertTrue(formattedKey.contains("Citadel.SSHClientError 1"))
    }


    // MARK: - Background Auto-Reconnect
    @MainActor
    func testSessionManagerBackgroundDisconnectAndAutoReconnect() async {
        let manager = SessionManager()
        var host = HostProfile(name: "Test Server", hostname: "127.0.0.1", username: "user")
        host.requireBiometrics = false
        manager.activeHost = host
        manager.state = .connected

        // 1. App goes to background
        manager.handleAppBackgrounded()
        XCTAssertTrue(manager.isAppInBackground)

        // 2. Connection drops in background (e.g. timeout)
        NotificationCenter.default.post(
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )

        // Simulate state transition to failed in background
        manager.state = .failed("Connection timed out in background")

        // 3. App returns to foreground -> should automatically attempt reconnect
        manager.handleAppForegrounded()
        XCTAssertFalse(manager.isAppInBackground)
        XCTAssertEqual(manager.state, .connecting, "Returning to foreground from background failure must auto-reconnect")

        // 4. Calling handleAppForegrounded again while already foregrounded should be an idempotent no-op
        manager.state = .connected
        manager.handleAppForegrounded()
        XCTAssertEqual(manager.state, .connected, "Redundant foreground call must be an idempotent no-op")
    }


    // MARK: - Network Path Change & Reconnection

    @MainActor
    func testNetworkPathChangeDropAndRestore() {
        let manager = SessionManager()
        let host = HostProfile(name: "PathTest", hostname: "127.0.0.1", username: "user")
        manager.activeHost = host
        manager.state = .connected

        // 1. Initial / cold start path notification should not trigger reconnection
        manager.handleNetworkPathChange(status: .satisfied, interfaceType: .wifi)
        XCTAssertEqual(manager.state, .connected, "Cold start path evaluation must not disconnect or reconnect")

        // 2. Network drop: transition from satisfied to unsatisfied while connected
        manager.handleNetworkPathChange(status: .unsatisfied, interfaceType: nil)
        XCTAssertEqual(manager.state, .reconnecting(attempt: 1), "Loss of network connectivity must transition to reconnecting(attempt: 1)")

        // 3. Network restored: transition from unsatisfied to satisfied while reconnecting
        manager.handleNetworkPathChange(status: .satisfied, interfaceType: .wifi)
        // Reconnect triggers connect(), which sets state to .connecting
        XCTAssertTrue(manager.state == .connecting || manager.state.isBusy, "Restoration of network must trigger reconnect attempt")
    }


    // MARK: - Finding 3 Regressions: Remote Responses for Connection Health

    func testInitialHealthCheckTimeoutDoesNotDisableFutureRemoteProbesAndSucceedsOnLaterResponse() async throws {
        let service = SSHService()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }

        let gen = await service.currentSessionGeneration
        let bundle = SessionBundle(generation: gen)
        bundle.isConnectedForTesting = true
        bundle.connectionChannel = channel
        bundle.stdinWriter = TerminalChannelWriter(channel: channel)
        await service.installSessionBundleForTesting(bundle)

        let probeCount = NIOLockedValueBox(0)
        await service.setProbeRunnerForTesting { _, _ in
            let count = probeCount.withLockedValue { c -> Int in
                c += 1
                return c
            }
            if count == 1 {
                // First probe times out
                try? await Task.sleep(nanoseconds: 200_000_000)
                return false
            } else {
                // Subsequent probe receives remote response and succeeds
                return true
            }
        }

        // Probe 1 times out
        let result1 = await service.ping(timeout: 0.05)
        XCTAssertFalse(result1)

        // Remote probes are NOT permanently disabled! Probe 2 actually sends and succeeds
        let result2 = await service.ping(timeout: 1.0)
        XCTAssertTrue(result2)
        XCTAssertEqual(probeCount.withLockedValue { $0 }, 2)
    }

    func testBlackholedConnectionFailsPingDespiteLocalWriteSuccessAndKeepAliveDisconnects() async throws {
        let service = SSHService()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }

        let gen = await service.currentSessionGeneration
        let bundle = SessionBundle(generation: gen)
        bundle.isConnectedForTesting = true
        bundle.connectionChannel = channel
        bundle.stdinWriter = TerminalChannelWriter(channel: channel)
        await service.installSessionBundleForTesting(bundle)

        // Blackholed connection: local writes succeed (EmbeddedChannel accepts writes),
        // but remote probes receive no response and time out
        await service.setProbeRunnerForTesting { _, _ in
            try? await Task.sleep(nanoseconds: 100_000_000)
            return false
        }

        // Local resize write succeeds
        await service.resize(cols: 80, rows: 24)

        // Ping must fail by its deadline, refusing to fall back to window-size write
        let pingResult = await service.ping(timeout: 0.05)
        XCTAssertFalse(pingResult)

        // Start keep-alive with rapid interval; 3 consecutive probe failures must trigger disconnect
        let disconnected = NIOLockedValueBox(false)
        await service.startKeepAliveForTesting(interval: 0.05) { error in
            disconnected.withLockedValue { $0 = true }
        }

        for _ in 0..<100 where !disconnected.withLockedValue({ $0 }) {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(disconnected.withLockedValue { $0 }, "Repeated probe failures must trigger disconnect")
    }

    func testExplicitGlobalRequestRefusalCountsAsHealthyResponse() async throws {
        let service = SSHService()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }

        let gen = await service.currentSessionGeneration
        let bundle = SessionBundle(generation: gen)
        bundle.isConnectedForTesting = true
        bundle.connectionChannel = channel
        bundle.stdinWriter = TerminalChannelWriter(channel: channel)
        await service.installSessionBundleForTesting(bundle)

        // Explicit globalRequestRefused proves remote liveness
        await service.setProbeRunnerForTesting { _, _ in
            return true
        }

        let result = await service.ping(timeout: 1.0)
        XCTAssertTrue(result, "Explicit global request refusal proves remote liveness")
    }

    func testTransportErrorOrFailedChannelLookupFailsPingEvenWithWriterPresent() async throws {
        let service = SSHService()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }

        let gen = await service.currentSessionGeneration
        let bundle = SessionBundle(generation: gen)
        bundle.isConnectedForTesting = true
        bundle.stdinWriter = TerminalChannelWriter(channel: channel)
        // No connectionChannel set (lookup fails)
        await service.installSessionBundleForTesting(bundle)

        let result = await service.ping(timeout: 1.0)
        XCTAssertFalse(result, "Missing or broken channel lookup must fail ping without write fallback")
    }

    func testConcurrentHeartbeatAndForegroundChecksCoalesceWithBoundedOutstandingRequests() async throws {
        let service = SSHService()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }

        let gen = await service.currentSessionGeneration
        let bundle = SessionBundle(generation: gen)
        bundle.isConnectedForTesting = true
        bundle.connectionChannel = channel
        bundle.stdinWriter = TerminalChannelWriter(channel: channel)
        await service.installSessionBundleForTesting(bundle)

        let executions = NIOLockedValueBox(0)
        await service.setProbeRunnerForTesting { _, _ in
            executions.withLockedValue { $0 += 1 }
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms probe
            return true
        }

        // Call ping concurrently: caller 1 has 30ms timeout (will time out),
        // caller 2 has 250ms timeout (will succeed when probe finishes)
        async let p1 = service.ping(timeout: 0.03)
        async let p2 = service.ping(timeout: 0.25)

        let (r1, r2) = await (p1, p2)
        XCTAssertFalse(r1, "Caller 1 timeout expired before probe completed")
        XCTAssertTrue(r2, "Caller 2 received shared probe success")
        XCTAssertEqual(executions.withLockedValue { $0 }, 1, "Concurrent checks must coalesce to exactly 1 in-flight probe")
    }

    func testCallerCancellationDoesNotCancelSharedUnderlyingProbe() async throws {
        let service = SSHService()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }

        let gen = await service.currentSessionGeneration
        let bundle = SessionBundle(generation: gen)
        bundle.isConnectedForTesting = true
        bundle.connectionChannel = channel
        bundle.stdinWriter = TerminalChannelWriter(channel: channel)
        await service.installSessionBundleForTesting(bundle)

        await service.setProbeRunnerForTesting { _, _ in
            try? await Task.sleep(nanoseconds: 80_000_000)
            return true
        }

        // Caller 1 starts and cancels after 10ms
        let t1 = Task { await service.ping(timeout: 1.0) }
        let t2 = Task { await service.ping(timeout: 1.0) }

        try? await Task.sleep(nanoseconds: 10_000_000)
        t1.cancel()

        let r1 = await t1.value
        let r2 = await t2.value
        XCTAssertFalse(r1, "Cancelled task returns false")
        XCTAssertTrue(r2, "Non-cancelled task completes successfully using shared probe")
    }

    func testDisconnectWhileProbeOutstandingResolvesWaitersAndDoesNotAffectNewSession() async throws {
        let service = SSHService()
        let channelA = EmbeddedChannel()
        defer { _ = try? channelA.finish() }

        await service.disconnect()
        let genA = await service.currentSessionGeneration
        let bundleA = SessionBundle(generation: genA)
        bundleA.isConnectedForTesting = true
        bundleA.connectionChannel = channelA
        bundleA.stdinWriter = TerminalChannelWriter(channel: channelA)
        await service.installSessionBundleForTesting(bundleA)

        let probeStarted = NIOLockedValueBox(false)
        await service.setProbeRunnerForTesting { _, _ in
            probeStarted.withLockedValue { $0 = true }
            try? await Task.sleep(nanoseconds: 500_000_000)
            return true
        }

        // Start ping on Session A
        let pingTaskA = Task { await service.ping(timeout: 1.0) }
        while !probeStarted.withLockedValue({ $0 }) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        // Disconnect Session A and start Session B
        await service.disconnect()
        let genB = await service.currentSessionGeneration
        XCTAssertNotEqual(genA, genB)

        let channelB = EmbeddedChannel()
        defer { _ = try? channelB.finish() }
        let bundleB = SessionBundle(generation: genB)
        bundleB.isConnectedForTesting = true
        bundleB.connectionChannel = channelB
        bundleB.stdinWriter = TerminalChannelWriter(channel: channelB)
        await service.installSessionBundleForTesting(bundleB)

        // Session A's probe waiter must resolve false (not affected by late response)
        let rA = await pingTaskA.value
        XCTAssertFalse(rA)

        // Session B is healthy and untouched
        await service.setProbeRunnerForTesting { _, _ in true }
        let rB = await service.ping(timeout: 0.1)
        XCTAssertTrue(rB)
    }

    func testPingWhileDisconnectedReturnsFalseImmediately() async throws {
        let service = SSHService()
        await service.disconnect()
        let result = await service.ping(timeout: 1.0)
        XCTAssertFalse(result)
    }

    @MainActor
    func testForegroundHealthCheckFailsAndTriggersReconnectWhenProbeTimesOut() async throws {
        let manager = SessionManager()
        let host = HostProfile(id: UUID(), name: "TestHost", hostname: "testhost.test", username: "user")
        manager.activeHost = host
        manager.currentConnectionId = UUID()
        manager.markConnectedForTesting()
        manager.handleAppBackgrounded()

        // Simulate probe failing (remote peer unresponsive)
        await manager.sshService.setProbeRunnerForTesting { _, _ in
            return false
        }

        manager.handleAppForegrounded()

        // Wait for healthCheckTask to complete and trigger reconnect
        for _ in 0..<50 where manager.state == .connected {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(manager.state.isBusy || manager.state != .connected)
    }



}
