import Foundation
import Crypto
import Citadel

public enum SSHKeyError: LocalizedError {
    case invalidPEM
    case unsupportedCipher(String)
    case unsupportedKeyType(String)
    case invalidKeyFormat(String)
    case passphraseRequired(cipher: String)
    case incorrectPassphrase

    public var errorDescription: String? {
        switch self {
        case .invalidPEM:
            return "Invalid OpenSSH PEM format."
        case .unsupportedCipher(let cipher):
            return "Encrypted private keys with cipher '\(cipher)' are not supported."
        case .unsupportedKeyType(let msg):
            return msg
        case .invalidKeyFormat(let reason):
            return "Invalid key format: \(reason)"
        case .passphraseRequired(let cipher):
            return "This private key is encrypted with cipher '\(cipher)'. A passphrase is required to decrypt it."
        case .incorrectPassphrase:
            return "Incorrect passphrase for private key, or decryption failed."
        }
    }
}

public enum SSHKeyGenerator {
    public struct GeneratedKeyPair {
        public let publicKey: String
        public let privateKeyPEM: String
        public let keyType: String
    }

    public struct ParsedKeyInfo: Sendable {
        public let keyType: String       // "Ed25519", "RSA", etc.
        public let rawKeyType: String    // "ssh-ed25519", "ssh-rsa"
        public let isEncrypted: Bool
        public let cipherName: String
        public let publicKey: String     // OpenSSH authorized_keys format
    }

    /// Generates a new Ed25519 key pair and returns OpenSSH formatted public key and private key PEM
    public static func generateEd25519Key(comment: String = "filaire@ios") throws -> GeneratedKeyPair {
        let privateKey = Curve25519.Signing.PrivateKey()
        let pubKeyBytes = Array(privateKey.publicKey.rawRepresentation) // 32 bytes
        let privKeyBytes = Array(privateKey.rawRepresentation) // 32 bytes

        // 1. Build OpenSSH public key wire format
        let pubKeyBlob = makeEd25519PublicKeyBlob(pubKeyBytes: pubKeyBytes)
        let publicKeyOpenSSH = "ssh-ed25519 \(pubKeyBlob.base64EncodedString()) \(comment)"

        // 2. Build OpenSSH private key PEM
        let privateKeyPEM = makeEd25519PrivateKeyPEM(
            privKeyBytes: privKeyBytes,
            pubKeyBytes: pubKeyBytes,
            comment: comment
        )

        return GeneratedKeyPair(
            publicKey: publicKeyOpenSSH,
            privateKeyPEM: privateKeyPEM,
            keyType: "Ed25519"
        )
    }

    /// Inspects an OpenSSH key string or raw Ed25519 base64 and extracts metadata without requiring the passphrase
    public static func parseKeyInfo(from keyString: String) throws -> ParsedKeyInfo {
        let trimmed = keyString.trimmingCharacters(in: .whitespacesAndNewlines)

        // If it's a direct 32-byte raw representation in base64
        if let directData = Data(base64Encoded: trimmed), directData.count == 32 {
            let privKey = try Curve25519.Signing.PrivateKey(rawRepresentation: directData)
            let pubBytes = Array(privKey.publicKey.rawRepresentation)
            let pubBlob = makeEd25519PublicKeyBlob(pubKeyBytes: pubBytes)
            let pubKeyStr = "ssh-ed25519 \(pubBlob.base64EncodedString()) filaire@imported"
            return ParsedKeyInfo(
                keyType: "Ed25519",
                rawKeyType: "ssh-ed25519",
                isEncrypted: false,
                cipherName: "none",
                publicKey: pubKeyStr
            )
        }

        let base64Body = trimmed
            .replacingOccurrences(of: "-----BEGIN OPENSSH PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END OPENSSH PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = Data(base64Encoded: base64Body) else {
            throw SSHKeyError.invalidPEM
        }

        var reader = DataReader(data: data)

        // Verify magic header: "openssh-key-v1\0"
        guard let magic = reader.readBytes(count: 15),
              let magicStr = String(bytes: magic, encoding: .utf8),
              magicStr == "openssh-key-v1\0" else {
            throw SSHKeyError.invalidKeyFormat("Missing openssh-key-v1 header")
        }

        // ciphername
        guard let cipherName = reader.readSSHString() else {
            throw SSHKeyError.invalidKeyFormat("Missing ciphername")
        }

        // kdfname
        guard let _ = reader.readSSHString() else {
            throw SSHKeyError.invalidKeyFormat("Missing kdfname")
        }

        // kdfoptions
        guard let _ = reader.readSSHBuffer() else {
            throw SSHKeyError.invalidKeyFormat("Missing kdfoptions")
        }

        // number of keys
        guard let numKeys = reader.readUInt32(), numKeys == 1 else {
            throw SSHKeyError.invalidKeyFormat("Invalid number of keys")
        }

        // public key blob
        guard let pubKeyBlob = reader.readSSHBuffer() else {
            throw SSHKeyError.invalidKeyFormat("Missing public key blob")
        }

        // Read key type inside pubKeyBlob
        var pubReader = DataReader(data: pubKeyBlob)
        guard let rawKeyType = pubReader.readSSHString() else {
            throw SSHKeyError.invalidKeyFormat("Missing key type in public key blob")
        }

        let displayKeyType: String
        switch rawKeyType {
        case "ssh-ed25519":
            displayKeyType = "Ed25519"
        case "ssh-rsa":
            displayKeyType = "RSA"
        case "ecdsa-sha2-nistp256":
            displayKeyType = "ECDSA P-256"
        case "ecdsa-sha2-nistp384":
            displayKeyType = "ECDSA P-384"
        case "ecdsa-sha2-nistp521":
            displayKeyType = "ECDSA P-521"
        default:
            displayKeyType = rawKeyType
        }

        let pubKeyString = "\(rawKeyType) \(pubKeyBlob.base64EncodedString()) filaire@imported"
        let isEncrypted = cipherName != "none"

        return ParsedKeyInfo(
            keyType: displayKeyType,
            rawKeyType: rawKeyType,
            isEncrypted: isEncrypted,
            cipherName: cipherName,
            publicKey: pubKeyString
        )
    }

    /// Parses an Ed25519 private key from OpenSSH PEM block (encrypted with aes256-ctr/bcrypt or unencrypted) or raw 32-byte representation
    public static func parseEd25519PrivateKey(from keyString: String, passphrase: String? = nil) throws -> Curve25519.Signing.PrivateKey {
        let trimmed = keyString.trimmingCharacters(in: .whitespacesAndNewlines)

        // If it's a direct 32-byte raw representation in base64
        if let directData = Data(base64Encoded: trimmed), directData.count == 32 {
            return try Curve25519.Signing.PrivateKey(rawRepresentation: directData)
        }

        let keyInfo = try parseKeyInfo(from: trimmed)
        guard keyInfo.rawKeyType == "ssh-ed25519" else {
            throw SSHKeyError.unsupportedKeyType("Expected an Ed25519 key, but found \(keyInfo.keyType)")
        }

        let decryptionData = (passphrase?.isEmpty == false) ? passphrase?.data(using: .utf8) : nil

        if keyInfo.isEncrypted && decryptionData == nil {
            throw SSHKeyError.passphraseRequired(cipher: keyInfo.cipherName)
        }

        do {
            return try Curve25519.Signing.PrivateKey(sshEd25519: trimmed, decryptionKey: decryptionData)
        } catch {
            if keyInfo.isEncrypted {
                throw SSHKeyError.incorrectPassphrase
            }
            // Fallback to manual parser if Citadel couldn't parse directly
            return try parseUnencryptedEd25519(from: trimmed)
        }
    }

    /// Parses an RSA private key from OpenSSH PEM block (encrypted with aes256-ctr/bcrypt or unencrypted)
    public static func parseRSAPrivateKey(from keyString: String, passphrase: String? = nil) throws -> Insecure.RSA.PrivateKey {
        let trimmed = keyString.trimmingCharacters(in: .whitespacesAndNewlines)
        let keyInfo = try parseKeyInfo(from: trimmed)
        guard keyInfo.rawKeyType == "ssh-rsa" else {
            throw SSHKeyError.unsupportedKeyType("Expected an RSA key, but found \(keyInfo.keyType)")
        }

        let decryptionData = (passphrase?.isEmpty == false) ? passphrase?.data(using: .utf8) : nil

        if keyInfo.isEncrypted && decryptionData == nil {
            throw SSHKeyError.passphraseRequired(cipher: keyInfo.cipherName)
        }

        do {
            return try Insecure.RSA.PrivateKey(sshRsa: trimmed, decryptionKey: decryptionData)
        } catch {
            if keyInfo.isEncrypted {
                throw SSHKeyError.incorrectPassphrase
            }
            throw SSHKeyError.invalidPEM
        }
    }

    private static func parseUnencryptedEd25519(from trimmed: String) throws -> Curve25519.Signing.PrivateKey {
        let base64Body = trimmed
            .replacingOccurrences(of: "-----BEGIN OPENSSH PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END OPENSSH PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = Data(base64Encoded: base64Body) else {
            throw SSHKeyError.invalidPEM
        }

        var reader = DataReader(data: data)

        // Verify magic header
        guard let magic = reader.readBytes(count: 15),
              let magicStr = String(bytes: magic, encoding: .utf8),
              magicStr == "openssh-key-v1\0" else {
            throw SSHKeyError.invalidKeyFormat("Missing openssh-key-v1 header")
        }

        // ciphername
        guard let cipherName = reader.readSSHString() else {
            throw SSHKeyError.invalidKeyFormat("Missing ciphername")
        }
        guard cipherName == "none" else {
            throw SSHKeyError.unsupportedCipher(cipherName)
        }

        // kdfname
        _ = reader.readSSHString()
        // kdfoptions
        _ = reader.readSSHBuffer()
        // number of keys
        _ = reader.readUInt32()
        // public key blob
        _ = reader.readSSHBuffer()

        // private key section
        guard let privSectionData = reader.readSSHBuffer() else {
            throw SSHKeyError.invalidKeyFormat("Missing private key section")
        }

        var privReader = DataReader(data: privSectionData)
        // checkint1 & checkint2
        guard let check1 = privReader.readUInt32(),
              let check2 = privReader.readUInt32(),
              check1 == check2 else {
            throw SSHKeyError.invalidKeyFormat("Checkint mismatch")
        }

        // key type
        guard let keyType = privReader.readSSHString() else {
            throw SSHKeyError.invalidKeyFormat("Missing key type")
        }
        guard keyType == "ssh-ed25519" else {
            throw SSHKeyError.invalidKeyFormat("Unsupported key type: \(keyType)")
        }

        // pubkey buffer (skip)
        _ = privReader.readSSHBuffer()

        // privkey buffer (64 bytes: 32 bytes seed + 32 bytes pubkey)
        guard let privBuffer = privReader.readSSHBuffer(), privBuffer.count >= 32 else {
            throw SSHKeyError.invalidKeyFormat("Invalid private key buffer length")
        }

        let seed = privBuffer.prefix(32)
        return try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    }

    // MARK: - Binary Encoding Helpers

    public static func makeEd25519PublicKeyBlob(pubKeyBytes: [UInt8]) -> Data {
        var data = Data()
        let typeName = "ssh-ed25519".data(using: .utf8)!
        data.appendUInt32(UInt32(typeName.count))
        data.append(typeName)
        data.appendUInt32(UInt32(pubKeyBytes.count))
        data.append(contentsOf: pubKeyBytes)
        return data
    }

    private static func makeEd25519PrivateKeyPEM(
        privKeyBytes: [UInt8],
        pubKeyBytes: [UInt8],
        comment: String
    ) -> String {
        var data = Data()

        // Magic header: "openssh-key-v1\0"
        let magic = "openssh-key-v1\0".data(using: .utf8)!
        data.append(magic)

        // ciphername: "none"
        let noneStr = "none".data(using: .utf8)!
        data.appendUInt32(UInt32(noneStr.count))
        data.append(noneStr)

        // kdfname: "none"
        data.appendUInt32(UInt32(noneStr.count))
        data.append(noneStr)

        // kdfoptions: empty
        data.appendUInt32(0)

        // number of keys: 1
        data.appendUInt32(1)

        // Public key blob
        let pubKeyBlob = makeEd25519PublicKeyBlob(pubKeyBytes: pubKeyBytes)
        data.appendUInt32(UInt32(pubKeyBlob.count))
        data.append(pubKeyBlob)

        // Private key section
        var privSection = Data()
        let checkInt: UInt32 = UInt32.random(in: 1..<UInt32.max)
        privSection.appendUInt32(checkInt)
        privSection.appendUInt32(checkInt)

        let typeName = "ssh-ed25519".data(using: .utf8)!
        privSection.appendUInt32(UInt32(typeName.count))
        privSection.append(typeName)

        // Public key (32 bytes)
        privSection.appendUInt32(UInt32(pubKeyBytes.count))
        privSection.append(contentsOf: pubKeyBytes)

        // Private key (64 bytes in OpenSSH: 32 bytes seed/private + 32 bytes public)
        privSection.appendUInt32(UInt32(privKeyBytes.count + pubKeyBytes.count))
        privSection.append(contentsOf: privKeyBytes)
        privSection.append(contentsOf: pubKeyBytes)

        // Comment
        let commentData = comment.data(using: .utf8)!
        privSection.appendUInt32(UInt32(commentData.count))
        privSection.append(commentData)

        // Padding to multiple of cipher block size (8 bytes for 'none')
        let blockSize = 8
        let padLength = blockSize - (privSection.count % blockSize)
        if padLength < blockSize {
            for i in 1...padLength {
                privSection.append(UInt8(i))
            }
        }

        data.appendUInt32(UInt32(privSection.count))
        data.append(privSection)

        let base64 = data.base64EncodedString()
        var pem = "-----BEGIN OPENSSH PRIVATE KEY-----\n"
        var index = base64.startIndex
        while index < base64.endIndex {
            let nextIndex = base64.index(index, offsetBy: 70, limitedBy: base64.endIndex) ?? base64.endIndex
            pem += String(base64[index..<nextIndex]) + "\n"
            index = nextIndex
        }
        pem += "-----END OPENSSH PRIVATE KEY-----\n"
        return pem
    }
}

private struct DataReader {
    let data: Data
    var offset: Int = 0

    mutating func readBytes(count: Int) -> [UInt8]? {
        guard offset + count <= data.count else { return nil }
        let sub = data[offset..<(offset + count)]
        offset += count
        return Array(sub)
    }

    mutating func readUInt32() -> UInt32? {
        guard let bytes = readBytes(count: 4) else { return nil }
        return bytes.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
    }

    mutating func readSSHBuffer() -> Data? {
        guard let length = readUInt32() else { return nil }
        guard let bytes = readBytes(count: Int(length)) else { return nil }
        return Data(bytes)
    }

    mutating func readSSHString() -> String? {
        guard let buf = readSSHBuffer() else { return nil }
        return String(data: buf, encoding: .utf8)
    }
}

private extension Data {
    mutating func appendUInt32(_ value: UInt32) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { self.append(contentsOf: $0) }
    }
}
