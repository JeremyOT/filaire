import XCTest
@testable import Filaire

/// The install flow with the SSH work stubbed: no network, no credentials, no remote command.
@MainActor
final class KeyInstallCoordinatorTests: XCTestCase {

    private let publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGX8vKqX82jNmHQE3v9y0k filaire@ipad"

    private func makeHost() -> HostProfile {
        HostProfile(name: "Dev", hostname: "dev.internal", port: 22, username: "deploy")
    }

    private func entry() -> KnownHostEntry {
        KnownHostEntry(
            hostname: "dev.internal",
            port: 22,
            keyType: "ssh-ed25519",
            fingerprintSHA256: "SHA256:abc123",
            openSSHPublicKey: "ssh-ed25519 AAAA"
        )
    }

    func testSuccessReportsTheAccountItInstalledFor() async {
        let coordinator = KeyInstallCoordinator { _, _, _, _ in }

        await coordinator.run(publicKey: publicKey, host: makeHost(), password: "hunter2")

        XCTAssertEqual(coordinator.phase, .succeeded("Installed on deploy@dev.internal."))
    }

    func testTheKeyAndPasswordReachTheInstaller() async {
        var seenKey: String?
        var seenPassword: String?
        let coordinator = KeyInstallCoordinator { key, _, password, _ in
            seenKey = key
            seenPassword = password
        }

        await coordinator.run(publicKey: publicKey, host: makeHost(), password: "hunter2")

        XCTAssertEqual(seenKey, publicKey)
        XCTAssertEqual(seenPassword, "hunter2")
    }

    func testValidationFailureIsReportedInPlainLanguage() async {
        let coordinator = KeyInstallCoordinator { _, _, _, _ in
            throw KeyInstaller.ValidationError.jumpHostNotSupported
        }

        await coordinator.run(publicKey: publicKey, host: makeHost(), password: "hunter2")

        XCTAssertEqual(
            coordinator.phase,
            .failed(KeyInstaller.message(for: .jumpHostNotSupported))
        )
    }

    func testServerFailureSurfacesTheUnderlyingError() async {
        struct RemoteFailure: LocalizedError {
            var errorDescription: String? { "Permission denied (publickey,password)." }
        }
        let coordinator = KeyInstallCoordinator { _, _, _, _ in throw RemoteFailure() }

        await coordinator.run(publicKey: publicKey, host: makeHost(), password: "wrong")

        XCTAssertEqual(coordinator.phase, .failed("Permission denied (publickey,password)."))
    }

    func testUntrustedHostKeyWaitsForTheUserAndCanBeRefused() async {
        let sample = entry()
        let coordinator = KeyInstallCoordinator { _, _, _, onUnknownHostKey in
            let trusted = await onUnknownHostKey?(sample) ?? false
            if !trusted { throw SSHError.invalidCredentials("Host key was not trusted.") }
        }

        let run = Task { await coordinator.run(publicKey: publicKey, host: makeHost(), password: "hunter2") }

        // Wait for the prompt to appear, then refuse it.
        while coordinator.pendingHostKey == nil {
            await Task.yield()
        }
        XCTAssertEqual(coordinator.pendingHostKey?.fingerprintSHA256, "SHA256:abc123")
        coordinator.resolveHostKey(trusted: false)
        await run.value

        guard case .failed = coordinator.phase else {
            return XCTFail("expected refusing the host key to fail the install")
        }
        XCTAssertNil(coordinator.pendingHostKey)
    }

    func testTrustingTheHostKeyLetsTheInstallProceed() async {
        let sample = entry()
        let coordinator = KeyInstallCoordinator { _, _, _, onUnknownHostKey in
            let trusted = await onUnknownHostKey?(sample) ?? false
            if !trusted { throw SSHError.invalidCredentials("Host key was not trusted.") }
        }

        let run = Task { await coordinator.run(publicKey: publicKey, host: makeHost(), password: "hunter2") }

        while coordinator.pendingHostKey == nil {
            await Task.yield()
        }
        coordinator.resolveHostKey(trusted: true)
        await run.value

        XCTAssertEqual(coordinator.phase, .succeeded("Installed on deploy@dev.internal."))
        XCTAssertNil(coordinator.pendingHostKey)
    }

    func testResetClearsAPreviousResult() async {
        let coordinator = KeyInstallCoordinator { _, _, _, _ in }
        await coordinator.run(publicKey: publicKey, host: makeHost(), password: "hunter2")

        coordinator.reset()

        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertNil(coordinator.pendingHostKey)
    }
}
