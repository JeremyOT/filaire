import Foundation
import NIO
import NIOCore
import NIOSSH
import Crypto
import Citadel

public struct KnownHostEntry: Codable, Identifiable, Equatable {
    public var id: String { "\(hostname.lowercased()):\(port)" }
    public let hostname: String
    public let port: Int
    public let keyType: String
    public let fingerprintSHA256: String
    public let openSSHPublicKey: String
    public let firstSeen: Date

    public init(
        hostname: String,
        port: Int,
        keyType: String,
        fingerprintSHA256: String,
        openSSHPublicKey: String,
        firstSeen: Date = Date()
    ) {
        self.hostname = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        self.port = port
        self.keyType = keyType
        self.fingerprintSHA256 = fingerprintSHA256
        self.openSSHPublicKey = openSSHPublicKey
        self.firstSeen = firstSeen
    }
}

public enum HostKeyMismatchError: LocalizedError, Equatable {
    case hostKeyChanged(hostname: String, port: Int, expectedFingerprint: String, actualFingerprint: String)
    case hostKeyNotTrusted(hostname: String, port: Int, fingerprint: String)

    public var errorDescription: String? {
        switch self {
        case .hostKeyChanged(let host, let port, let expected, let actual):
            return "WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED for \(host):\(port)!\nExpected: \(expected)\nReceived: \(actual)\nSomeone could be intercepting your connection."
        case .hostKeyNotTrusted(let host, let port, let fingerprint):
            return "Connection cancelled: the host key for \(host):\(port) (\(fingerprint)) was not trusted."
        }
    }
}

public final class KnownHostsStore: @unchecked Sendable {
    public static let shared = KnownHostsStore()

    private let storageKey = "io.o-t.filaire.known_hosts_list"
    private let lock = NSLock()

    public init() {}

    public func getAllEntries() -> [KnownHostEntry] {
        lock.lock()
        defer { lock.unlock() }
        let storedData = UserDefaults.standard.data(forKey: storageKey)
        guard let data = storedData,
              let entries = try? JSONDecoder().decode([KnownHostEntry].self, from: data) else {
            return []
        }
        return entries
    }

    public func getEntry(hostname: String, port: Int) -> KnownHostEntry? {
        let entries = getAllEntries()
        return entries.first { $0.hostname.lowercased() == hostname.lowercased() && $0.port == port }
    }

    public func saveEntry(_ entry: KnownHostEntry) {
        lock.lock()
        defer { lock.unlock() }
        var entries = getAllEntriesNoLock()
        entries.removeAll { $0.hostname.lowercased() == entry.hostname.lowercased() && $0.port == entry.port }
        entries.append(entry)
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    public func removeEntry(hostname: String, port: Int) {
        lock.lock()
        defer { lock.unlock() }
        var entries = getAllEntriesNoLock()
        entries.removeAll { $0.hostname.lowercased() == hostname.lowercased() && $0.port == port }
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    public var entryCount: Int {
        getAllEntries().count
    }

    public func hasEntry(hostname: String, port: Int) -> Bool {
        getEntry(hostname: hostname, port: port) != nil
    }

    public func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    private func getAllEntriesNoLock() -> [KnownHostEntry] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let entries = try? JSONDecoder().decode([KnownHostEntry].self, from: data) else {
            return []
        }
        return entries
    }

    /// Computes SHA256 fingerprint in standard OpenSSH format: "SHA256:<base64>"
    public static func computeFingerprint(for hostKey: NIOSSHPublicKey) -> String {
        let openSSH = String(openSSHPublicKey: hostKey)
        let parts = openSSH.components(separatedBy: " ")
        if parts.count >= 2, let rawData = Data(base64Encoded: parts[1]) {
            let digest = SHA256.hash(data: rawData)
            let base64 = Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
            return "SHA256:\(base64)"
        }
        let fallbackDigest = SHA256.hash(data: Data(openSSH.utf8))
        return "SHA256:\(Data(fallbackDigest).base64EncodedString().replacingOccurrences(of: "=", with: ""))"
    }
}

public typealias UnknownHostKeyHandler = @Sendable (KnownHostEntry) async -> Bool

/// NIOSSH host key validator implementing Trust-On-First-Use with explicit user confirmation
public struct TOFUHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, Sendable {
    public let hostname: String
    public let port: Int
    public let onUnknownHostKey: UnknownHostKeyHandler?
    public let attempt: SSHConnectionAttempt?

    public init(hostname: String, port: Int, onUnknownHostKey: UnknownHostKeyHandler? = nil, attempt: SSHConnectionAttempt? = nil) {
        self.hostname = hostname
        self.port = port
        self.onUnknownHostKey = onUnknownHostKey
        self.attempt = attempt
    }

    public func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let fingerprint = KnownHostsStore.computeFingerprint(for: hostKey)
        let keyString = String(openSSHPublicKey: hostKey)
        let keyType = keyString.components(separatedBy: " ").first ?? "ssh"

        if let existing = KnownHostsStore.shared.getEntry(hostname: hostname, port: port) {
            if existing.fingerprintSHA256 == fingerprint {
                // Key matches previously accepted host key
                validationCompletePromise.succeed(())
            } else {
                // Potential MITM or key rotation
                let mismatch = HostKeyMismatchError.hostKeyChanged(
                    hostname: hostname,
                    port: port,
                    expectedFingerprint: existing.fingerprintSHA256,
                    actualFingerprint: fingerprint
                )
                validationCompletePromise.fail(mismatch)
            }
        } else {
            // Unknown host: only trust after explicit user confirmation
            let newEntry = KnownHostEntry(
                hostname: hostname,
                port: port,
                keyType: keyType,
                fingerprintSHA256: fingerprint,
                openSSHPublicKey: keyString
            )
            let rejection = HostKeyMismatchError.hostKeyNotTrusted(hostname: hostname, port: port, fingerprint: fingerprint)
            guard let handler = onUnknownHostKey else {
                validationCompletePromise.fail(rejection)
                return
            }

            let eventLoop = validationCompletePromise.futureResult.eventLoop

            if let attempt = attempt {
                guard attempt.isActive else {
                    validationCompletePromise.fail(rejection)
                    return
                }
                // Pause authentication deadline during local fingerprint verification
                attempt.pauseHandshakeTimeout()
            }

            Task { @MainActor in
                let userAccepted = await handler(newEntry)
                if userAccepted {
                    // Atomically check if the attempt is still valid for this decision before saving
                    if let attempt = attempt {
                        if attempt.approveHostKey() {
                            KnownHostsStore.shared.saveEntry(newEntry)
                            eventLoop.execute {
                                attempt.resumeHandshakeTimeout(budget: .seconds(10))
                                validationCompletePromise.succeed(())
                            }
                        } else {
                            eventLoop.execute {
                                attempt.fail(error: rejection)
                                validationCompletePromise.fail(rejection)
                            }
                        }
                    } else {
                        KnownHostsStore.shared.saveEntry(newEntry)
                        eventLoop.execute {
                            validationCompletePromise.succeed(())
                        }
                    }
                } else {
                    eventLoop.execute {
                        attempt?.fail(error: rejection)
                        validationCompletePromise.fail(rejection)
                    }
                }
            }
        }
    }
}
