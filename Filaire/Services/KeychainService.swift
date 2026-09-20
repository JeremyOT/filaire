import Foundation
import Security
import LocalAuthentication

public protocol KeychainBackend: Sendable {
    func copyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    func add(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    func update(_ query: CFDictionary, _ attributesToUpdate: CFDictionary) -> OSStatus
    func delete(_ query: CFDictionary) -> OSStatus
    func createAccessControl(
        _ allocator: CFAllocator?,
        _ protection: CFTypeRef,
        _ flags: SecAccessControlCreateFlags,
        _ error: UnsafeMutablePointer<Unmanaged<CFError>?>?
    ) -> SecAccessControl?
}

public struct DefaultKeychainBackend: KeychainBackend {
    public init() {}

    public func copyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        SecItemCopyMatching(query, result)
    }

    public func add(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        SecItemAdd(query, result)
    }

    public func update(_ query: CFDictionary, _ attributesToUpdate: CFDictionary) -> OSStatus {
        SecItemUpdate(query, attributesToUpdate)
    }

    public func delete(_ query: CFDictionary) -> OSStatus {
        SecItemDelete(query)
    }

    public func createAccessControl(
        _ allocator: CFAllocator?,
        _ protection: CFTypeRef,
        _ flags: SecAccessControlCreateFlags,
        _ error: UnsafeMutablePointer<Unmanaged<CFError>?>?
    ) -> SecAccessControl? {
        SecAccessControlCreateWithFlags(allocator, protection, flags, error)
    }
}

public enum KeychainService {
    private static let servicePrefix = "io.o-t.filaire"

    private static let backendLock = NSLock()
    private static var _backend: any KeychainBackend = DefaultKeychainBackend()

    public static var backend: any KeychainBackend {
        get {
            backendLock.lock()
            defer { backendLock.unlock() }
            return _backend
        }
        set {
            backendLock.lock()
            defer { backendLock.unlock() }
            _backend = newValue
        }
    }

    public static func resetBackend() {
        backendLock.lock()
        defer { backendLock.unlock() }
        _backend = DefaultKeychainBackend()
    }

    struct RefRecord: Codable, Equatable {
        let version: String
        let requireBiometrics: Bool
    }

    // MARK: - Password Management

    public static func savePassword(_ password: String, forHostId hostId: UUID, requireBiometrics: Bool = true) throws {
        guard let data = password.data(using: .utf8) else { throw KeychainError.invalidData }
        let key = "\(servicePrefix).host.\(hostId.uuidString).password"
        try save(key: key, data: data, requireBiometrics: requireBiometrics)
    }

    public static func getPassword(forHostId hostId: UUID, context: LAContext? = nil) -> String? {
        let key = "\(servicePrefix).host.\(hostId.uuidString).password"
        guard let data = get(key: key, context: context) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func deletePassword(forHostId hostId: UUID) {
        let key = "\(servicePrefix).host.\(hostId.uuidString).password"
        delete(key: key)
    }

    public static func hasPassword(forHostId hostId: UUID) -> Bool {
        let key = "\(servicePrefix).host.\(hostId.uuidString).password"
        return exists(key: key)
    }

    // MARK: - SSH Private Key Management

    public static func savePrivateKey(_ privateKeyString: String, forKeyId keyId: UUID, requireBiometrics: Bool = true) throws {
        guard let data = privateKeyString.data(using: .utf8) else { throw KeychainError.invalidData }
        let key = "\(servicePrefix).key.\(keyId.uuidString).private"
        try save(key: key, data: data, requireBiometrics: requireBiometrics)
    }

    public static func getPrivateKey(forKeyId keyId: UUID, context: LAContext? = nil) -> String? {
        let key = "\(servicePrefix).key.\(keyId.uuidString).private"
        guard let data = get(key: key, context: context) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func deletePrivateKey(forKeyId keyId: UUID) {
        let key = "\(servicePrefix).key.\(keyId.uuidString).private"
        delete(key: key)
    }

    public static func hasPrivateKey(forKeyId keyId: UUID) -> Bool {
        let key = "\(servicePrefix).key.\(keyId.uuidString).private"
        return exists(key: key)
    }

    // MARK: - SSH Key Passphrase Management

    public static func saveKeyPassphrase(_ passphrase: String, forKeyId keyId: UUID, requireBiometrics: Bool = true) throws {
        guard let data = passphrase.data(using: .utf8) else { throw KeychainError.invalidData }
        let key = "\(servicePrefix).key.\(keyId.uuidString).passphrase"
        try save(key: key, data: data, requireBiometrics: requireBiometrics)
    }

    public static func getKeyPassphrase(forKeyId keyId: UUID, context: LAContext? = nil) -> String? {
        let key = "\(servicePrefix).key.\(keyId.uuidString).passphrase"
        guard let data = get(key: key, context: context) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func deleteKeyPassphrase(forKeyId keyId: UUID) {
        let key = "\(servicePrefix).key.\(keyId.uuidString).passphrase"
        delete(key: key)
    }

    public static func hasKeyPassphrase(forKeyId keyId: UUID) -> Bool {
        let key = "\(servicePrefix).key.\(keyId.uuidString).passphrase"
        return exists(key: key)
    }

    // MARK: - Low-level Secure Enclave & Keychain Primitives

    private static func save(key: String, data: Data, requireBiometrics: Bool = true) throws {
        let currentBackend = backend

        // Step 1: Pre-validate & construct access control if needed
        var accessControl: SecAccessControl? = nil
        if requireBiometrics {
            var error: Unmanaged<CFError>?
            accessControl = currentBackend.createAccessControl(
                kCFAllocatorDefault,
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                [.biometryAny],
                &error
            )
            if accessControl == nil {
                accessControl = currentBackend.createAccessControl(
                    kCFAllocatorDefault,
                    kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                    [.userPresence],
                    &error
                )
            }
            #if !targetEnvironment(simulator)
            if accessControl == nil {
                throw KeychainError.protectionUnavailable(errSecParam)
            }
            #endif
        }

        // Step 2: Check existing ref
        let refKey = key + ".ref"
        let currentRefData = getInternal(service: servicePrefix, key: refKey, context: nil, backend: currentBackend)
        let currentRef = currentRefData.flatMap { try? JSONDecoder().decode(RefRecord.self, from: $0) }

        // Path A: Existing item with unchanged protection policy -> in-place SecItemUpdate
        if let currentRef = currentRef, currentRef.requireBiometrics == requireBiometrics {
            let currentVersionKey = "\(key).v.\(currentRef.version)"
            let updateQuery: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: servicePrefix,
                kSecAttrAccount: currentVersionKey
            ]
            let updateAttrs: [CFString: Any] = [
                kSecValueData: data
            ]
            let updateStatus = currentBackend.update(updateQuery as CFDictionary, updateAttrs as CFDictionary)
            if updateStatus == errSecSuccess {
                return
            } else if updateStatus != errSecItemNotFound {
                // If update failed with an error, propagate without deleting original!
                throw KeychainError.secError(updateStatus)
            }
            // If item was not found, fall through to staged creation
        }

        // Path B: New item, unversioned item, or protection policy change -> Staged replacement
        let newVersion = UUID().uuidString
        let newVersionKey = "\(key).v.\(newVersion)"

        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: servicePrefix,
            kSecAttrAccount: newVersionKey,
            kSecValueData: data
        ]

        if requireBiometrics {
            if let ac = accessControl {
                query[kSecAttrAccessControl] = ac
            } else {
                #if targetEnvironment(simulator)
                query[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                #else
                throw KeychainError.protectionUnavailable(errSecParam)
                #endif
            }
        } else {
            query[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }

        var addStatus = currentBackend.add(query as CFDictionary, nil)
        if (addStatus == errSecAuthFailed || addStatus == errSecParam) && requireBiometrics {
            var error: Unmanaged<CFError>?
            if let userPresence = currentBackend.createAccessControl(
                kCFAllocatorDefault,
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                [.userPresence],
                &error
            ) {
                query[kSecAttrAccessControl] = userPresence
                addStatus = currentBackend.add(query as CFDictionary, nil)
            }
        }
        #if targetEnvironment(simulator)
        if (addStatus == errSecAuthFailed || addStatus == errSecParam) && requireBiometrics {
            query.removeValue(forKey: kSecAttrAccessControl)
            query[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            addStatus = currentBackend.add(query as CFDictionary, nil)
        }
        #endif

        if requireBiometrics && (addStatus == errSecAuthFailed || addStatus == errSecParam) {
            throw KeychainError.protectionUnavailable(addStatus)
        }

        guard addStatus == errSecSuccess else {
            throw KeychainError.secError(addStatus)
        }

        // Step 4: Staging succeeded. Now switch durable reference pointer.
        let newRef = RefRecord(version: newVersion, requireBiometrics: requireBiometrics)
        guard let newRefData = try? JSONEncoder().encode(newRef) else {
            deleteInternal(service: servicePrefix, key: newVersionKey, backend: currentBackend)
            throw KeychainError.secError(errSecParam)
        }

        var refQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: servicePrefix,
            kSecAttrAccount: refKey
        ]
        let refUpdateAttrs: [CFString: Any] = [
            kSecValueData: newRefData
        ]
        let refUpdateStatus = currentBackend.update(refQuery as CFDictionary, refUpdateAttrs as CFDictionary)
        if refUpdateStatus == errSecItemNotFound {
            refQuery[kSecValueData] = newRefData
            refQuery[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let refAddStatus = currentBackend.add(refQuery as CFDictionary, nil)
            if refAddStatus == errSecDuplicateItem {
                let retryStatus = currentBackend.update([
                    kSecClass: kSecClassGenericPassword,
                    kSecAttrService: servicePrefix,
                    kSecAttrAccount: refKey
                ] as CFDictionary, [kSecValueData: newRefData] as CFDictionary)
                if retryStatus != errSecSuccess {
                    deleteInternal(service: servicePrefix, key: newVersionKey, backend: currentBackend)
                    throw KeychainError.secError(retryStatus)
                }
            } else if refAddStatus != errSecSuccess {
                deleteInternal(service: servicePrefix, key: newVersionKey, backend: currentBackend)
                throw KeychainError.secError(refAddStatus)
            }
        } else if refUpdateStatus != errSecSuccess {
            deleteInternal(service: servicePrefix, key: newVersionKey, backend: currentBackend)
            throw KeychainError.secError(refUpdateStatus)
        }

        // Step 5: Switch succeeded! New version is authoritative. Clean up old version & unversioned item.
        if let oldVersion = currentRef?.version {
            deleteInternal(service: servicePrefix, key: "\(key).v.\(oldVersion)", backend: currentBackend)
        }
        deleteInternal(service: servicePrefix, key: key, backend: currentBackend)
    }

    private static func get(key: String, context: LAContext? = nil) -> Data? {
        let currentBackend = backend
        let refKey = key + ".ref"
        if let refData = getInternal(service: servicePrefix, key: refKey, context: nil, backend: currentBackend),
           let ref = try? JSONDecoder().decode(RefRecord.self, from: refData) {
            let versionedKey = "\(key).v.\(ref.version)"
            if let data = getInternal(service: servicePrefix, key: versionedKey, context: context, backend: currentBackend) {
                return data
            }
        }

        // Direct key fallback (unversioned items)
        return getInternal(service: servicePrefix, key: key, context: context, backend: currentBackend)
    }

    private static func exists(key: String) -> Bool {
        let currentBackend = backend
        let refKey = key + ".ref"
        let refExists = itemExistsInternal(service: servicePrefix, key: refKey, backend: currentBackend)

        if refExists {
            if let refData = getInternal(service: servicePrefix, key: refKey, context: nil, backend: currentBackend),
               let ref = try? JSONDecoder().decode(RefRecord.self, from: refData) {
                let versionedKey = "\(key).v.\(ref.version)"
                if itemExistsInternal(service: servicePrefix, key: versionedKey, backend: currentBackend) {
                    return true
                }
            } else {
                // ref item exists in Keychain but couldn't be decrypted/read (e.g. before first unlock).
                // Do NOT consider it missing!
                return true
            }
        }

        // Direct key fallback (unversioned items)
        return itemExistsInternal(service: servicePrefix, key: key, backend: currentBackend)
    }

    private static func delete(key: String) {
        let currentBackend = backend
        let refKey = key + ".ref"
        if let refData = getInternal(service: servicePrefix, key: refKey, context: nil, backend: currentBackend),
           let ref = try? JSONDecoder().decode(RefRecord.self, from: refData) {
            deleteInternal(service: servicePrefix, key: "\(key).v.\(ref.version)", backend: currentBackend)
        }
        deleteInternal(service: servicePrefix, key: refKey, backend: currentBackend)
        deleteInternal(service: servicePrefix, key: key, backend: currentBackend)
    }

    private static func getInternal(service: String, key: String, context: LAContext? = nil, backend: any KeychainBackend) -> Data? {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            kSecReturnData: kCFBooleanTrue as Any,
            kSecMatchLimit: kSecMatchLimitOne
        ]

        if let context = context {
            query[kSecUseAuthenticationContext] = context
        }

        var item: CFTypeRef?
        var status = backend.copyMatching(query as CFDictionary, &item)
        if status != errSecSuccess && context != nil {
            // Fallback in case item in Keychain does not require authentication context
            query.removeValue(forKey: kSecUseAuthenticationContext)
            status = backend.copyMatching(query as CFDictionary, &item)
        }

        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return data
    }

    private static func itemExistsInternal(service: String, key: String, backend: any KeychainBackend) -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            kSecUseAuthenticationUI: kSecUseAuthenticationUISkip,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        let status = backend.copyMatching(query as CFDictionary, nil)
        return status != errSecItemNotFound
    }

    private static func deleteInternal(service: String, key: String, backend: any KeychainBackend) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key
        ]
        _ = backend.delete(query as CFDictionary)
    }
}

public enum KeychainError: Error, LocalizedError, Equatable {
    case secError(OSStatus)
    case protectionUnavailable(OSStatus)
    case invalidData

    public var errorDescription: String? {
        switch self {
        case .secError(let status):
            if let msg = SecCopyErrorMessageString(status, nil) as String? {
                return "Keychain error (\(status)): \(msg)"
            }
            return "Keychain error (\(status))"
        case .protectionUnavailable(let status):
            return "Couldn’t protect this secret with \(BiometricAuthService.biometryName) or your device passcode (\(status)). Set a device passcode, or turn off “Require \(BiometricAuthService.biometryName)” for this item."
        case .invalidData:
            return "Failed to encode secret data"
        }
    }
}
