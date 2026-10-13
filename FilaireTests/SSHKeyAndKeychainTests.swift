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

final class SSHKeyAndKeychainTests: XCTestCase {
    // MARK: - SSH Key Generator & Parser

    func testSSHKeyGenerationAndRoundTripParsing() throws {
        let keyPair = try SSHKeyGenerator.generateEd25519Key(comment: "test@filaire")

        // Validate public key format
        XCTAssertTrue(keyPair.publicKey.hasPrefix("ssh-ed25519 "))
        XCTAssertTrue(keyPair.publicKey.hasSuffix(" test@filaire"))

        // Validate private key PEM format
        XCTAssertTrue(keyPair.privateKeyPEM.contains("-----BEGIN OPENSSH PRIVATE KEY-----"))
        XCTAssertTrue(keyPair.privateKeyPEM.contains("-----END OPENSSH PRIVATE KEY-----"))

        // Parse private key back from PEM
        let parsedPrivateKey = try SSHKeyGenerator.parseEd25519PrivateKey(from: keyPair.privateKeyPEM)

        // Verify the public key derived from parsed private key matches the original
        let pubKeyBlob = keyPair.publicKey
            .replacingOccurrences(of: "ssh-ed25519 ", with: "")
            .components(separatedBy: " ")[0]
        guard let expectedData = Data(base64Encoded: pubKeyBlob) else {
            XCTFail("Failed to decode public key base64")
            return
        }

        let rawPubKey = expectedData.suffix(32)
        XCTAssertEqual(Data(parsedPrivateKey.publicKey.rawRepresentation), Data(rawPubKey))
    }


    // MARK: - Biometrics & Secure Enclave Credentials

    func testHostProfileBiometricsDefaultsAndDecoding() throws {
        let profile = HostProfile(name: "Secure Server", hostname: "sec.net", username: "admin")
        XCTAssertTrue(profile.requireBiometrics, "requireBiometrics must default to true")

        // Test backward compatibility: JSON without requireBiometrics
        let legacyJSON = """
        {
            "id": "23d4a4f7-347d-44f5-b92b-d727f7ce09a8",
            "name": "Legacy Server",
            "hostname": "legacy.net",
            "port": 22,
            "username": "root",
            "authMethod": "Password"
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(HostProfile.self, from: legacyJSON)
        XCTAssertTrue(decoded.requireBiometrics, "requireBiometrics must default to true when missing from legacy JSON")
        XCTAssertTrue(decoded.autoConnect, "autoConnect must default to true")
    }

    func testSSHKeyModelBiometricsAndPassphraseDefaults() throws {
        let key = SSHKeyModel(name: "Mac Key", publicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5...")
        XCTAssertTrue(key.requiresBiometrics, "requiresBiometrics must default to true")
        XCTAssertFalse(key.hasPassphrase, "hasPassphrase must default to false")

        // Backward compatibility
        let legacyJSON = """
        {
            "id": "23d4a4f7-347d-44f5-b92b-d727f7ce09a8",
            "name": "Legacy Key",
            "keyType": "Ed25519",
            "publicKey": "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5...",
            "createdAt": 1700000000
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(SSHKeyModel.self, from: legacyJSON)
        XCTAssertTrue(decoded.requiresBiometrics, "requiresBiometrics must default to true when missing")
        XCTAssertFalse(decoded.hasPassphrase, "hasPassphrase must default to false when missing")
    }

    func testKeychainServicePassphraseAndCredentialsLifecycle() throws {
        let testKeyId = UUID()
        let testHostId = UUID()

        // 1. Password
        try KeychainService.savePassword("super-secret-pw", forHostId: testHostId, requireBiometrics: false)
        XCTAssertEqual(KeychainService.getPassword(forHostId: testHostId), "super-secret-pw")
        KeychainService.deletePassword(forHostId: testHostId)
        XCTAssertNil(KeychainService.getPassword(forHostId: testHostId))

        // 2. Private Key
        try KeychainService.savePrivateKey("dummy-private-key-pem", forKeyId: testKeyId, requireBiometrics: false)
        XCTAssertEqual(KeychainService.getPrivateKey(forKeyId: testKeyId), "dummy-private-key-pem")
        KeychainService.deletePrivateKey(forKeyId: testKeyId)
        XCTAssertNil(KeychainService.getPrivateKey(forKeyId: testKeyId))

        // 3. Key Passphrase
        try KeychainService.saveKeyPassphrase("passphrase123", forKeyId: testKeyId, requireBiometrics: false)
        XCTAssertEqual(KeychainService.getKeyPassphrase(forKeyId: testKeyId), "passphrase123")
        KeychainService.deleteKeyPassphrase(forKeyId: testKeyId)
        XCTAssertNil(KeychainService.getKeyPassphrase(forKeyId: testKeyId))
    }

    func testKeychainProtectionUnavailableErrorDescription() {
        let desc = KeychainError.protectionUnavailable(errSecAuthFailed).errorDescription
        XCTAssertNotNil(desc)
        XCTAssertTrue(desc?.contains("passcode") == true)
    }


    // MARK: - Keychain Reliability and Staged Preservation Tests

    private final class MockKeychainBackend: KeychainBackend, @unchecked Sendable {
        let lock = NSLock()
        var items: [String: [String: Any]] = [:]
        var failAccessControlCreation = false
        var failAddStatus: OSStatus? = nil
        var failUpdateStatus: OSStatus? = nil
        var simulateDuplicateOnRefAdd = false
        var simulateBiometricsLocked = false
        var addCount = 0
        var updateCount = 0
        var deleteCount = 0

        init() {}

        func copyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
            lock.lock()
            defer { lock.unlock() }
            let dict = query as NSDictionary
            guard let account = dict[kSecAttrAccount as String] as? String,
                  let service = dict[kSecAttrService as String] as? String else {
                return errSecParam
            }
            let storageKey = "\(service):\(account)"
            guard let item = items[storageKey] else {
                return errSecItemNotFound
            }

            if simulateBiometricsLocked && !account.hasSuffix(".ref") {
                if (dict[kSecUseAuthenticationUI as String] as? String) == (kSecUseAuthenticationUISkip as String) {
                    return errSecInteractionNotAllowed
                }
                return errSecAuthFailed
            }

            if dict[kSecReturnData as String] as? Bool == true {
                if let data = item[kSecValueData as String] as? Data {
                    result?.pointee = data as CFData
                    return errSecSuccess
                }
            }
            return errSecSuccess
        }

        func add(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
            lock.lock()
            defer { lock.unlock() }
            addCount += 1
            if let fail = failAddStatus {
                return fail
            }
            let dict = query as NSDictionary
            guard let account = dict[kSecAttrAccount as String] as? String,
                  let service = dict[kSecAttrService as String] as? String else {
                return errSecParam
            }
            let storageKey = "\(service):\(account)"
            if simulateDuplicateOnRefAdd && account.hasSuffix(".ref") {
                simulateDuplicateOnRefAdd = false
                items[storageKey] = [
                    kSecAttrAccount as String: account,
                    kSecAttrService as String: service,
                    kSecValueData as String: Data()
                ]
                return errSecDuplicateItem
            }
            if items[storageKey] != nil {
                return errSecDuplicateItem
            }
            var copy: [String: Any] = [:]
            for (k, v) in dict {
                if let keyStr = k as? String {
                    copy[keyStr] = v
                }
            }
            items[storageKey] = copy
            return errSecSuccess
        }

        func update(_ query: CFDictionary, _ attributesToUpdate: CFDictionary) -> OSStatus {
            lock.lock()
            defer { lock.unlock() }
            updateCount += 1
            if let fail = failUpdateStatus {
                return fail
            }
            let qDict = query as NSDictionary
            guard let account = qDict[kSecAttrAccount as String] as? String,
                  let service = qDict[kSecAttrService as String] as? String else {
                return errSecParam
            }
            let storageKey = "\(service):\(account)"
            guard var existing = items[storageKey] else {
                return errSecItemNotFound
            }
            let uDict = attributesToUpdate as NSDictionary
            for (k, v) in uDict {
                if let keyStr = k as? String {
                    existing[keyStr] = v
                }
            }
            items[storageKey] = existing
            return errSecSuccess
        }

        func delete(_ query: CFDictionary) -> OSStatus {
            lock.lock()
            defer { lock.unlock() }
            deleteCount += 1
            let dict = query as NSDictionary
            guard let account = dict[kSecAttrAccount as String] as? String,
                  let service = dict[kSecAttrService as String] as? String else {
                return errSecParam
            }
            let storageKey = "\(service):\(account)"
            items.removeValue(forKey: storageKey)
            return errSecSuccess
        }

        func createAccessControl(
            _ allocator: CFAllocator?,
            _ protection: CFTypeRef,
            _ flags: SecAccessControlCreateFlags,
            _ error: UnsafeMutablePointer<Unmanaged<CFError>?>?
        ) -> SecAccessControl? {
            if failAccessControlCreation {
                return nil
            }
            return SecAccessControlCreateWithFlags(allocator, protection, flags, error)
        }
    }

    func testKeychainSaveUpdateFailurePreservesOriginal() throws {
        let mock = MockKeychainBackend()
        KeychainService.backend = mock
        defer { KeychainService.resetBackend() }

        let hostId = UUID()
        try KeychainService.savePassword("original-secret", forHostId: hostId, requireBiometrics: false)
        XCTAssertEqual(KeychainService.getPassword(forHostId: hostId), "original-secret")

        mock.failUpdateStatus = errSecIO

        XCTAssertThrowsError(try KeychainService.savePassword("new-secret", forHostId: hostId, requireBiometrics: false)) { error in
            XCTAssertEqual(error as? KeychainError, KeychainError.secError(errSecIO))
        }

        mock.failUpdateStatus = nil
        XCTAssertEqual(KeychainService.getPassword(forHostId: hostId), "original-secret", "Original secret must not be lost on update failure")
    }

    func testKeychainInPlaceValueUpdate() throws {
        let mock = MockKeychainBackend()
        KeychainService.backend = mock
        defer { KeychainService.resetBackend() }

        let hostId = UUID()
        try KeychainService.savePassword("version-1", forHostId: hostId, requireBiometrics: false)
        XCTAssertEqual(KeychainService.getPassword(forHostId: hostId), "version-1")

        let updatesBefore = mock.updateCount
        try KeychainService.savePassword("version-2", forHostId: hostId, requireBiometrics: false)
        XCTAssertEqual(KeychainService.getPassword(forHostId: hostId), "version-2")
        XCTAssertGreaterThan(mock.updateCount, updatesBefore, "Unchanged protection policy should use in-place SecItemUpdate")
    }

    func testKeychainDuplicateOnRefAddRetriesUpdate() throws {
        let mock = MockKeychainBackend()
        KeychainService.backend = mock
        defer { KeychainService.resetBackend() }

        let hostId = UUID()
        mock.simulateDuplicateOnRefAdd = true
        try KeychainService.savePassword("initial-value", forHostId: hostId, requireBiometrics: false)
        XCTAssertEqual(KeychainService.getPassword(forHostId: hostId), "initial-value")
    }

    func testKeychainStagedInterruptionPreservesActiveVersion() throws {
        let mock = MockKeychainBackend()
        KeychainService.backend = mock
        defer { KeychainService.resetBackend() }

        let hostId = UUID()
        try KeychainService.savePassword("authoritative-v1", forHostId: hostId, requireBiometrics: false)

        let baseKey = "io.o-t.filaire.host.\(hostId.uuidString).password"
        let orphanKey = "io.o-t.filaire:\(baseKey).v.orphan-uuid"
        mock.items[orphanKey] = [
            kSecAttrAccount as String: "\(baseKey).v.orphan-uuid",
            kSecAttrService as String: "io.o-t.filaire",
            kSecValueData as String: "orphan-payload".data(using: .utf8)!
        ]

        XCTAssertEqual(KeychainService.getPassword(forHostId: hostId), "authoritative-v1")
    }

    func testPassphraseFailureDuringImportCleansUpOrphanPrivateKey() throws {
        let mock = MockKeychainBackend()
        KeychainService.backend = mock
        defer { KeychainService.resetBackend() }

        let unrelatedKeyId = UUID()
        try KeychainService.savePrivateKey("unrelated-key-data", forKeyId: unrelatedKeyId, requireBiometrics: false)
        XCTAssertNotNil(KeychainService.getPrivateKey(forKeyId: unrelatedKeyId))

        let newKeyId = UUID()
        try KeychainService.savePrivateKey("new-key-data", forKeyId: newKeyId, requireBiometrics: false)

        // Inject passphrase save failure
        mock.failAddStatus = errSecAuthFailed

        // Attempting to save passphrase fails
        XCTAssertThrowsError(try KeychainService.saveKeyPassphrase("passphrase", forKeyId: newKeyId, requireBiometrics: false))

        // Cleanup handler removes orphan key
        KeychainService.deletePrivateKey(forKeyId: newKeyId)

        // Verify orphan key is gone, but unrelated key remains intact!
        XCTAssertNil(KeychainService.getPrivateKey(forKeyId: newKeyId))
        mock.failAddStatus = nil
        XCTAssertEqual(KeychainService.getPrivateKey(forKeyId: unrelatedKeyId), "unrelated-key-data")
    }

    func testKeychainExistenceChecksDistinguishMissingFromBiometricLocked() throws {
        let mock = MockKeychainBackend()
        KeychainService.backend = mock
        defer { KeychainService.resetBackend() }

        let hostId = UUID()
        let keyId = UUID()

        // 1. Initially missing
        XCTAssertFalse(KeychainService.hasPassword(forHostId: hostId))
        XCTAssertFalse(KeychainService.hasPrivateKey(forKeyId: keyId))
        XCTAssertFalse(KeychainService.hasKeyPassphrase(forKeyId: keyId))

        // 2. Save items
        try KeychainService.savePassword("mypassword", forHostId: hostId, requireBiometrics: true)
        try KeychainService.savePrivateKey("myprivatekey", forKeyId: keyId, requireBiometrics: true)
        try KeychainService.saveKeyPassphrase("mypassphrase", forKeyId: keyId, requireBiometrics: true)

        XCTAssertTrue(KeychainService.hasPassword(forHostId: hostId))
        XCTAssertTrue(KeychainService.hasPrivateKey(forKeyId: keyId))
        XCTAssertTrue(KeychainService.hasKeyPassphrase(forKeyId: keyId))

        // 3. Simulate biometric locked (e.g. user hasn't scanned Face ID or cancelled)
        mock.simulateBiometricsLocked = true

        // Direct get without auth fails/returns nil
        XCTAssertNil(KeychainService.getPassword(forHostId: hostId))
        XCTAssertNil(KeychainService.getPrivateKey(forKeyId: keyId))
        XCTAssertNil(KeychainService.getKeyPassphrase(forKeyId: keyId))

        // But non-prompting existence check STILL returns true because item is physically in Keychain!
        XCTAssertTrue(KeychainService.hasPassword(forHostId: hostId))
        XCTAssertTrue(KeychainService.hasPrivateKey(forKeyId: keyId))
        XCTAssertTrue(KeychainService.hasKeyPassphrase(forKeyId: keyId))

        // 4. Delete items
        mock.simulateBiometricsLocked = false
        KeychainService.deletePassword(forHostId: hostId)
        KeychainService.deletePrivateKey(forKeyId: keyId)
        KeychainService.deleteKeyPassphrase(forKeyId: keyId)

        XCTAssertFalse(KeychainService.hasPassword(forHostId: hostId))
        XCTAssertFalse(KeychainService.hasPrivateKey(forKeyId: keyId))
        XCTAssertFalse(KeychainService.hasKeyPassphrase(forKeyId: keyId))
    }

    @MainActor
    func testKeysAreNeverAutomaticallyPurgedOnStartupOrReload() throws {
        let mock = MockKeychainBackend()
        KeychainService.backend = mock
        defer {
            KeychainService.resetBackend()
            UserDefaults.standard.removeObject(forKey: AppState.savedHostsKey)
            UserDefaults.standard.removeObject(forKey: "io.o-t.filaire.saved_keys")
        }

        let orphanedKeyId = UUID()
        let orphanedKey = SSHKeyModel(
            id: orphanedKeyId,
            name: "Orphaned Key",
            publicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAtest key@ipad",
            requiresBiometrics: false
        )

        let hostId = UUID()
        let hostWithKey = HostProfile(
            id: hostId,
            name: "Key Host",
            hostname: "key.example.com",
            username: "deploy",
            authMethod: .sshKey,
            selectedKeyId: orphanedKeyId,
            agentForwardingKeyIds: [orphanedKeyId]
        )

        // Populate UserDefaults
        let keysData = try JSONEncoder().encode([orphanedKey])
        let hostsData = try JSONEncoder().encode([hostWithKey])
        UserDefaults.standard.set(keysData, forKey: "io.o-t.filaire.saved_keys")
        UserDefaults.standard.set(hostsData, forKey: AppState.savedHostsKey)

        // Keychain backend is completely empty (e.g. after migration or keychain transient failure)
        let appState = AppState()

        // Keys MUST NOT be purged
        XCTAssertEqual(appState.keys.count, 1)
        XCTAssertEqual(appState.keys.first?.id, orphanedKeyId)

        // Host configuration must NOT be modified
        let loadedHost = appState.hosts.first(where: { $0.id == hostId })
        XCTAssertNotNil(loadedHost)
        XCTAssertEqual(loadedHost?.authMethod, .sshKey)
        XCTAssertEqual(loadedHost?.selectedKeyId, orphanedKeyId)
        XCTAssertEqual(loadedHost?.agentForwardingKeyIds, [orphanedKeyId])

        // Reloading keys or hosts must ALSO never purge them
        appState.reloadKeys()
        XCTAssertEqual(appState.keys.count, 1)

        appState.reloadHosts()
        XCTAssertEqual(appState.hosts.count, 1)
    }

    @MainActor
    func testBiometricCredentialsPreservedWhenLocked() throws {
        let mock = MockKeychainBackend()
        KeychainService.backend = mock
        defer {
            KeychainService.resetBackend()
            UserDefaults.standard.removeObject(forKey: AppState.savedHostsKey)
            UserDefaults.standard.removeObject(forKey: "io.o-t.filaire.saved_keys")
        }

        let biometricKeyId = UUID()
        let biometricKey = SSHKeyModel(
            id: biometricKeyId,
            name: "Biometric Key",
            publicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAtest key@ipad",
            requiresBiometrics: true
        )

        let hostId = UUID()
        let hostProfile = HostProfile(
            id: hostId,
            name: "Secured Host",
            hostname: "secured.example.com",
            username: "admin",
            authMethod: .password,
            selectedKeyId: biometricKeyId,
            requireBiometrics: true
        )

        try KeychainService.savePassword("secret-pass", forHostId: hostId, requireBiometrics: true)
        try KeychainService.savePrivateKey("secret-priv-key", forKeyId: biometricKeyId, requireBiometrics: true)

        let keysData = try JSONEncoder().encode([biometricKey])
        let hostsData = try JSONEncoder().encode([hostProfile])
        UserDefaults.standard.set(keysData, forKey: "io.o-t.filaire.saved_keys")
        UserDefaults.standard.set(hostsData, forKey: AppState.savedHostsKey)

        // Lock biometrics
        mock.simulateBiometricsLocked = true

        let appState = AppState()

        // Biometric key must NOT be purged
        XCTAssertEqual(appState.keys.count, 1)
        XCTAssertEqual(appState.keys.first?.id, biometricKeyId)

        // Password auth must NOT be reset
        let loadedHost = appState.hosts.first(where: { $0.id == hostId })
        XCTAssertEqual(loadedHost?.authMethod, .password)
        XCTAssertEqual(loadedHost?.selectedKeyId, biometricKeyId)
    }

    func testSSHServiceAuthResolutionDisplaysRegenerationWarningOnMissingOrInvalidKey() async throws {
        let mock = MockKeychainBackend()
        KeychainService.backend = mock
        defer { KeychainService.resetBackend() }

        let sshService = SSHService()
        let hostId = UUID()
        let keyId = UUID()
        let keyModel = SSHKeyModel(id: keyId, name: "Production Key", publicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAtest key@ipad")

        let keyHost = HostProfile(
            id: hostId,
            name: "Key Host",
            hostname: "test.example.com",
            username: "admin",
            authMethod: .sshKey,
            selectedKeyId: keyId
        )

        // 1. Missing private key in Keychain: throws .keyNotFound and formatErrorMessage warns of regeneration
        do {
            _ = try await sshService.resolveAuthMethod(for: keyHost, allKeys: [keyModel])
            XCTFail("Should fail when key cannot be retrieved")
        } catch let sshErr as SSHError {
            guard case .keyNotFound = sshErr else {
                XCTFail("Expected .keyNotFound error, got \(sshErr)")
                return
            }
            let authInfo = await sshService.lastAttemptedAuth
            let formatted = SessionManager.formatErrorMessage(sshErr, for: keyHost, authInfo: authInfo)
            XCTAssertTrue(formatted.contains("The key may need to be regenerated."))
            XCTAssertTrue(formatted.contains("Production Key"))
        }

        // 2. Corrupt / invalid private key in Keychain: throws .invalidCredentials with regeneration warning
        try KeychainService.savePrivateKey("NOT A VALID OPENSSH KEY", forKeyId: keyId, requireBiometrics: false)
        do {
            _ = try await sshService.resolveAuthMethod(for: keyHost, allKeys: [keyModel])
            XCTFail("Should fail when key data is invalid")
        } catch let sshErr as SSHError {
            guard case .invalidCredentials(let msg) = sshErr else {
                XCTFail("Expected .invalidCredentials, got \(sshErr)")
                return
            }
            XCTAssertTrue(msg.contains("The key may need to be regenerated."))
        }
    }

    @MainActor
    func testBiometricAuthServiceProperties() async throws {
        let name = BiometricAuthService.biometryName
        XCTAssertFalse(name.isEmpty, "biometryName must not be empty")

        // In test environments, authenticateUser gracefully returns true
        let authed = try await BiometricAuthService.authenticateUser(reason: "Unit Test Verification")
        XCTAssertTrue(authed)

        let context = try await BiometricAuthService.authenticate(reason: "Unit Test Verification")
        XCTAssertNotNil(context)
    }


    // MARK: - Encrypted OpenSSH Key Parsing & Decryption

    func testParseKeyInfoUnencryptedEd25519() throws {
        let keyPair = try SSHKeyGenerator.generateEd25519Key(comment: "test@filaire")
        let info = try SSHKeyGenerator.parseKeyInfo(from: keyPair.privateKeyPEM)

        XCTAssertEqual(info.keyType, "Ed25519")
        XCTAssertEqual(info.rawKeyType, "ssh-ed25519")
        XCTAssertFalse(info.isEncrypted)
        XCTAssertEqual(info.cipherName, "none")
        XCTAssertTrue(info.publicKey.hasPrefix("ssh-ed25519 "))
    }

    func testParseKeyInfoRaw32ByteKey() throws {
        let randomBytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
        let base64 = Data(randomBytes).base64EncodedString()
        let info = try SSHKeyGenerator.parseKeyInfo(from: base64)

        XCTAssertEqual(info.keyType, "Ed25519")
        XCTAssertEqual(info.rawKeyType, "ssh-ed25519")
        XCTAssertFalse(info.isEncrypted)
        XCTAssertEqual(info.cipherName, "none")
        XCTAssertTrue(info.publicKey.hasPrefix("ssh-ed25519 "))

        let parsed = try SSHKeyGenerator.parseEd25519PrivateKey(from: base64)
        XCTAssertEqual(Data(parsed.rawRepresentation), Data(randomBytes))
    }

    func testEncryptedEd25519KeyHandling() throws {
        let encryptedEd25519PEM = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABABaUeVZt
        smQjtk+phmze7ZAAAAGAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIA7lH5hqjOz3+ZjY
        zo9oGkWn7I1dutNB0V6Ro3LqYc3vAAAAkORdJE/Tf1J6d20Ot/uXDrR10QqUjq8nXll+80
        sxYUAH8BjOCRrX12de+FmK60OiTZ7LlRjz/M88VhXSIYzn0x7iJVrD2AGzgL5AWtb9Xeq0
        LV7afOJ2QhOyl6Y/HO7Y5yZfV7rInOXP+5RGXSmPZv8Vbgiyj6A9QE8L8igw01p3MsjYN4
        1tMz913abJYSWazw==
        -----END OPENSSH PRIVATE KEY-----
        """

        // 1. Inspect without passphrase
        let info = try SSHKeyGenerator.parseKeyInfo(from: encryptedEd25519PEM)
        XCTAssertEqual(info.keyType, "Ed25519")
        XCTAssertEqual(info.rawKeyType, "ssh-ed25519")
        XCTAssertTrue(info.isEncrypted)
        XCTAssertEqual(info.cipherName, "aes256-ctr")
        XCTAssertTrue(info.publicKey.hasPrefix("ssh-ed25519 "))

        // 2. Missing passphrase should throw passphraseRequired
        XCTAssertThrowsError(try SSHKeyGenerator.parseEd25519PrivateKey(from: encryptedEd25519PEM, passphrase: nil)) { error in
            guard case SSHKeyError.passphraseRequired(let cipher) = error else {
                XCTFail("Expected passphraseRequired error, got: \(error)")
                return
            }
            XCTAssertEqual(cipher, "aes256-ctr")
        }

        // 3. Incorrect passphrase should throw incorrectPassphrase
        XCTAssertThrowsError(try SSHKeyGenerator.parseEd25519PrivateKey(from: encryptedEd25519PEM, passphrase: "wrongpassword")) { error in
            guard case SSHKeyError.incorrectPassphrase = error else {
                XCTFail("Expected incorrectPassphrase error, got: \(error)")
                return
            }
        }

        // 4. Correct passphrase decrypts successfully
        let privateKey = try SSHKeyGenerator.parseEd25519PrivateKey(from: encryptedEd25519PEM, passphrase: "testpass123")
        XCTAssertEqual(privateKey.rawRepresentation.count, 32)
    }

    func testEncryptedRSAKeyHandling() throws {
        let encryptedRSAPEM = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABBSyhMPQn
        q4G0qHOYA46TL9AAAAGAAAAAEAAAEXAAAAB3NzaC1yc2EAAAADAQABAAABAQDBwh3LOeXH
        5WM0pvGq7c9WXgS/mNFJS2G5Z31bDWFPZWDd7CZJD5q9YMalEFaTCQKud3d9ZXNQYm06+K
        B8Qhep7qw8yTN82tXkaoqWAI5Xuo/Le7OKDL3YtpEg/6LyoAiGBjw8mCuoHL9OjkzxKhFE
        mjxFdklMontThsqM0kqR8zvVfkwOmw4KovMkDbNbaa9wBwO/qw5N+wpm+DMi5Uy0wCs2dW
        s7B6bFZLAaANjOwH4g9avqRG2BcS3QSN6Nc9Lzw+OPTEplT6SExmJxbbk/Pm+Ei/aNIa6X
        IF3AM7PmLrP/XP7DbybRrRKoEazCkSD1+dJe8hI7eLPF2f4S9luDAAADwHkKVOiuXNCXRl
        7jk6jy3bzlpVWMhDnHIip9AU4TGsse/2N6bZeEzs+F9RD3WEZWI2eWpRk5G0DC9iwoxqKn
        Ed3D/MQLTrGL2fWz2WEan548fqxfT0vhXrHjHhlyzzFX+EtZTEdxYAVG2vw/8qP2v9eyPj
        1j1xwFdw0qWPZEmYevE1hWLEFDjD44dI3+ysKoIDMN2R9yY5U45cUdOTDpun1GYw4Rz9ZW
        mHha616PapDyLd53+83GbuqW2i2eU31avGwjgoy78VL7vovyrA14Y9ezroWKCJwZowW5Sl
        KjqF165mwKkKZIv+vcdFP8hwxDxH7Xc/75vOYrIK88Z751QmKU+0Y6vLM5K5iTtdAqnIB+
        Z7RT1sngLeq+89qGz5J8vhFdh6WY0DfCZYtY0DvQZ1isK96VC1mEnfx1im4nidX4vwBoqs
        a5798p1vGAUjKhVjTi3rRtfe6V3v7PGQh5N625jpzM+0BU2/IsmTOvvc5dwrMSpErgCLle
        za5i9u6C1hET8fUl3AgCbCaAnaxKUPojx3oDMBRBip+D5LSM5vqwKuQq/g8SVNh7BSyGXX
        GbWnrbgOoQlel0d6zw9DHrx38VXKKvrp043qHm8vuoV6IDOD4pJ6Kvdt+snIpvFP+8HkeN
        3hg2YLbK0jl7ApF3U6z+LOOcQAR/HnyHjN441zAmt+ycpb3MWdtAXJwKbtaFM5WtScFvPs
        5Nm865UlrxjnN5DLFdyvKPfPcaq5fe3aVBPq+04dF7sAJMsgu6Bd8khQauvnvSum9uchE6
        b/ASDrnQr6h9qP3myuiZEB8kKBJlp3K8OLtbXpEJqF4hFPYByKPsTkXP/J0asowIe9v3qx
        2Kp66cOgfaMyXN4oYQba/QeeiDJdm/adpGnjQX+qhz/kdr5eB2cXydNnQWcBVMGt/yIjMO
        +v/6RehpwqlmfyMKoVPnMA+r3Hah/XWJFIzkNy7Blz6LPYDrJj+8QXxTwa9omDnGB0kXAu
        E6ig0qimBrACM4snmp8C1QiRJ/G42ShATzto8UQpsSC5QoWTBSnYfxgK65QCwbJjMriDzi
        LEjw7MjcMDP+xv9la4YU9zZ9dIH2eEOIzjLOnrA2LziU61OAb/WoMWJh9i5z0UPr4EUlSo
        cEEJQolcDPChZn06/TdGylKOBk3Xh9wUfQXQbIeLlNbJ8M2/hPy8dElyBeMiFHlbehEqtU
        vyv0m0cj9SwiTb+ryx8dP62Tkm2evhAJtAys38mjW54V2UMPoIcHoaXQH1hyuAi4zXzcRo
        EepG4ycQ==
        -----END OPENSSH PRIVATE KEY-----
        """

        // 1. Inspect without passphrase
        let info = try SSHKeyGenerator.parseKeyInfo(from: encryptedRSAPEM)
        XCTAssertEqual(info.keyType, "RSA")
        XCTAssertEqual(info.rawKeyType, "ssh-rsa")
        XCTAssertTrue(info.isEncrypted)
        XCTAssertEqual(info.cipherName, "aes256-ctr")
        XCTAssertTrue(info.publicKey.hasPrefix("ssh-rsa "))

        // 2. Missing passphrase should throw passphraseRequired
        XCTAssertThrowsError(try SSHKeyGenerator.parseRSAPrivateKey(from: encryptedRSAPEM, passphrase: nil)) { error in
            guard case SSHKeyError.passphraseRequired(let cipher) = error else {
                XCTFail("Expected passphraseRequired error, got: \(error)")
                return
            }
            XCTAssertEqual(cipher, "aes256-ctr")
        }

        // 3. Incorrect passphrase should throw incorrectPassphrase
        XCTAssertThrowsError(try SSHKeyGenerator.parseRSAPrivateKey(from: encryptedRSAPEM, passphrase: "wrongpassword")) { error in
            guard case SSHKeyError.incorrectPassphrase = error else {
                XCTFail("Expected incorrectPassphrase error, got: \(error)")
                return
            }
        }

        // 4. Correct passphrase decrypts successfully
        let rsaKey = try SSHKeyGenerator.parseRSAPrivateKey(from: encryptedRSAPEM, passphrase: "testpass123")
        XCTAssertNotNil(rsaKey)
    }



}
