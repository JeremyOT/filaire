import Foundation
import Observation

/// Drives one "install with password" attempt: collect the password, connect, get a decision if the host
/// key is not yet trusted, run the append, and report what actually happened.
///
/// The install work is injectable so the flow can be tested without a network.
@MainActor
@Observable
public final class KeyInstallCoordinator {

    public enum Phase: Equatable, Sendable {
        case idle
        case installing
        case succeeded(String)
        case failed(String)
    }

    public typealias InstallOperation =
        @Sendable (String, HostProfile, String, UnknownHostKeyHandler?) async throws -> Void

    public private(set) var phase: Phase = .idle
    /// Set while an untrusted host key is waiting on the user. The password is not sent until this resolves.
    public private(set) var pendingHostKey: KnownHostEntry?

    private let install: InstallOperation
    private var hostKeyContinuation: CheckedContinuation<Bool, Never>?

    public init(
        install: @escaping @Sendable (String, HostProfile, String, UnknownHostKeyHandler?) async throws -> Void = {
            key, host, password, onUnknownHostKey in
            try await SSHService.installPublicKey(
                key,
                on: host,
                password: password,
                onUnknownHostKey: onUnknownHostKey
            )
        }
    ) {
        self.install = install
    }

    public var isBusy: Bool { phase == .installing }

    public func reset() {
        resolveHostKey(trusted: false)
        phase = .idle
    }

    public func run(publicKey: String, host: HostProfile, password: String) async {
        guard phase != .installing else { return }
        phase = .installing

        do {
            try await install(publicKey, host, password, { [weak self] entry in
                await self?.confirmHostKey(entry) ?? false
            })
            phase = .succeeded("Installed on \(host.username)@\(host.hostname).")
        } catch let error as KeyInstaller.ValidationError {
            phase = .failed(KeyInstaller.message(for: error))
        } catch {
            phase = .failed(error.localizedDescription)
        }

        // A cancelled or failed attempt must never leave the prompt waiting.
        resolveHostKey(trusted: false)
    }

    /// Called from the SSH host-key validator, off the main actor.
    private func confirmHostKey(_ entry: KnownHostEntry) async -> Bool {
        // Only one decision can be outstanding; a second request refuses rather than dropping a continuation.
        guard hostKeyContinuation == nil else { return false }
        return await withCheckedContinuation { continuation in
            self.hostKeyContinuation = continuation
            self.pendingHostKey = entry
        }
    }

    /// Resolves a waiting fingerprint prompt. Trusting also remembers the key, the same as a normal connect.
    public func resolveHostKey(trusted: Bool) {
        guard let continuation = hostKeyContinuation else {
            pendingHostKey = nil
            return
        }
        hostKeyContinuation = nil
        pendingHostKey = nil
        continuation.resume(returning: trusted)
    }
}
