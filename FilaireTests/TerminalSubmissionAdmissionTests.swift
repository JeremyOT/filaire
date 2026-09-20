import XCTest
@testable import Filaire

/// Queue admission tests: every assertion is about bytes reaching (or never reaching) the outbound queue.
@MainActor
final class TerminalSubmissionAdmissionTests: XCTestCase {

    private func makeConnectedManager() -> SessionManager {
        let manager = SessionManager()
        manager.activeHost = HostProfile(name: "Test", hostname: "localhost", port: 22, username: "user")
        manager.markConnectedForTesting()
        return manager
    }

    private func makeSubmission(
        _ manager: SessionManager,
        text: String = "echo hi",
        action: TerminalSubmissionAction = .run,
        id: UUID = UUID()
    ) -> PreparedTerminalSubmission? {
        guard let target = manager.captureSubmissionTarget() else {
            XCTFail("expected a live submission target")
            return nil
        }
        switch TerminalInputSubmission.prepare(
            text: text,
            action: action,
            target: target,
            bracketedPasteEnabled: false,
            id: id
        ) {
        case .success(let submission): return submission
        case .failure(let error):
            XCTFail("unexpected preparation failure: \(error)")
            return nil
        }
    }

    func testAcceptedSubmissionEnqueuesExactlyItsPayload() {
        let manager = makeConnectedManager()
        guard let submission = makeSubmission(manager) else { return }

        XCTAssertEqual(manager.admit(submission), .accepted)
        XCTAssertEqual(manager.pendingOutboundBufferSize, submission.payload.count)
    }

    func testAdmittedPayloadIsDeliveredAsOneOrderedItemAfterEarlierInput() async throws {
        let manager = makeConnectedManager()
        var delivered: [[UInt8]] = []
        manager.sshWriterForTesting = { chunk in
            delivered.append(chunk)
        }
        guard let submission = makeSubmission(manager) else { return }

        manager.send(data: [0x61])
        XCTAssertEqual(manager.admit(submission), .accepted)

        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(delivered, [[0x61], submission.payload])
    }

    func testDuplicateActivationOfTheSameSubmissionSendsNothingTwice() {
        let manager = makeConnectedManager()
        guard let submission = makeSubmission(manager) else { return }

        XCTAssertEqual(manager.admit(submission), .accepted)
        let afterFirst = manager.pendingOutboundBufferSize

        XCTAssertEqual(manager.admit(submission), .duplicate)
        XCTAssertEqual(manager.pendingOutboundBufferSize, afterFirst)
    }

    func testANewDeliberateActionWithAFreshIdIsAdmitted() {
        let manager = makeConnectedManager()
        guard let first = makeSubmission(manager, id: UUID()),
              let second = makeSubmission(manager, id: UUID()) else { return }

        XCTAssertEqual(manager.admit(first), .accepted)
        XCTAssertEqual(manager.admit(second), .accepted)
        XCTAssertEqual(manager.pendingOutboundBufferSize, first.payload.count + second.payload.count)
    }

    func testReconnectInvalidatesAnEarlierTargetAndSendsNothing() {
        let manager = makeConnectedManager()
        guard let submission = makeSubmission(manager) else { return }

        // A reconnect mints a new connection id even though the host UUID is unchanged.
        manager.currentConnectionId = UUID()

        XCTAssertEqual(manager.admit(submission), .staleTarget)
        XCTAssertEqual(manager.pendingOutboundBufferSize, 0)
    }

    func testSwitchingHostsInvalidatesAnEarlierTarget() {
        let manager = makeConnectedManager()
        guard let submission = makeSubmission(manager) else { return }

        manager.activeHost = HostProfile(name: "Other", hostname: "other.internal", port: 22, username: "user")

        XCTAssertEqual(manager.admit(submission), .staleTarget)
        XCTAssertEqual(manager.pendingOutboundBufferSize, 0)
    }

    func testDisconnectedManagerRejectsAndSendsNothing() {
        let manager = makeConnectedManager()
        guard let submission = makeSubmission(manager) else { return }

        manager.state = .disconnected

        XCTAssertEqual(manager.admit(submission), .notConnected)
        XCTAssertEqual(manager.pendingOutboundBufferSize, 0)
    }

    func testCaptureSubmissionTargetRequiresAnEstablishedConnection() {
        let manager = SessionManager()
        manager.activeHost = HostProfile(name: "Test", hostname: "localhost", port: 22, username: "user")
        manager.state = .connecting

        XCTAssertNil(manager.captureSubmissionTarget(), "Composed input requires an established connection")
    }

    func testFullQueueRejectsWithoutSendingAnyBytes() {
        let manager = makeConnectedManager()
        manager.sshWriterForTesting = { _ in
            try? await Task.sleep(for: .seconds(5))
        }
        guard let submission = makeSubmission(manager) else { return }

        // Occupy the entire outbound bound; the chunk goes in flight synchronously.
        manager.send(data: [UInt8](repeating: 0x41, count: SessionManager.maxOutboundBufferSize))
        let pendingBeforeAdmit = manager.pendingOutboundBufferSize

        guard case .queueFull(let available, let required) = manager.admit(submission) else {
            return XCTFail("expected the admission to be rejected as full")
        }
        XCTAssertEqual(available, 0)
        XCTAssertEqual(required, submission.payload.count)
        XCTAssertEqual(manager.pendingOutboundBufferSize, pendingBeforeAdmit, "A rejected admission must send zero bytes")
    }

    func testRejectedSubmissionCanBeAdmittedAfterCapacityFrees() {
        let manager = makeConnectedManager()
        guard let submission = makeSubmission(manager) else { return }

        manager.send(data: [UInt8](repeating: 0x41, count: SessionManager.maxOutboundBufferSize))
        guard case .queueFull = manager.admit(submission) else {
            return XCTFail("expected the admission to be rejected as full")
        }

        // The draft survives rejection, so the same submission is still admissible once the queue drains.
        manager.clearOutbound()
        XCTAssertEqual(manager.admit(submission), .accepted)
    }
}
