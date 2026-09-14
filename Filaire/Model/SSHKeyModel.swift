import Foundation

public struct SSHKeyModel: Identifiable, Codable, Equatable {
    public var id: UUID
    public var name: String
    public var keyType: String
    public var publicKey: String
    public var createdAt: Date
    public var hasPassphrase: Bool
    public var requiresBiometrics: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        keyType: String = "Ed25519",
        publicKey: String,
        createdAt: Date = Date(),
        hasPassphrase: Bool = false,
        requiresBiometrics: Bool = true
    ) {
        self.id = id
        self.name = name
        self.keyType = keyType
        self.publicKey = publicKey
        self.createdAt = createdAt
        self.hasPassphrase = hasPassphrase
        self.requiresBiometrics = requiresBiometrics
    }

    enum CodingKeys: String, CodingKey {
        case id, name, keyType, publicKey, createdAt, hasPassphrase, requiresBiometrics
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.keyType = try container.decode(String.self, forKey: .keyType)
        self.publicKey = try container.decode(String.self, forKey: .publicKey)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.hasPassphrase = try container.decodeIfPresent(Bool.self, forKey: .hasPassphrase) ?? false
        self.requiresBiometrics = try container.decodeIfPresent(Bool.self, forKey: .requiresBiometrics) ?? true
    }
}
