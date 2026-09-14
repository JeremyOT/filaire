import SwiftUI
import UIKit
import Crypto
import Citadel
import LocalAuthentication

public struct KeyManagementView: View {
    @Binding public var keys: [SSHKeyModel]
    public let onSelectKey: ((SSHKeyModel) -> Void)?

    @State private var showingGenerateSheet = false
    @State private var showingImportSheet = false
    @State private var copiedKeyId: UUID? = nil

    @State private var newKeyName = "Filaire iPad Key"
    @State private var keyPassphrase = ""
    @State private var requireBiometrics = true

    @State private var importedKeyName = ""
    @State private var importedKeyPEM = ""
    @State private var importedKeyPassphrase = ""
    @State private var importRequireBiometrics = true
    @State private var errorMessage: String? = nil

    public init(keys: Binding<[SSHKeyModel]>, onSelectKey: ((SSHKeyModel) -> Void)? = nil) {
        self._keys = keys
        self.onSelectKey = onSelectKey
    }

    public var body: some View {
        List {
            Section(header: Text("Configured SSH Keys")) {
                if keys.isEmpty {
                    Text("No SSH keys yet. Generate a new Ed25519 key below.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(keys) { key in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(key.name)
                                    .font(.headline)
                                Spacer()

                                if key.requiresBiometrics {
                                    HStack(spacing: 3) {
                                        Image(systemName: "faceid")
                                        Text(BiometricAuthService.biometryName)
                                    }
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color(uiColor: SolarizedDarkTheme.green).opacity(0.2))
                                    .foregroundStyle(Color(uiColor: SolarizedDarkTheme.green))
                                    .clipShape(Capsule())
                                }

                                if key.hasPassphrase {
                                    HStack(spacing: 3) {
                                        Image(systemName: "key.fill")
                                        Text("Passphrase")
                                    }
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color(uiColor: SolarizedDarkTheme.yellow).opacity(0.2))
                                    .foregroundStyle(Color(uiColor: SolarizedDarkTheme.yellow))
                                    .clipShape(Capsule())
                                }

                                Text(key.keyType)
                                    .font(.caption)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color(uiColor: SolarizedDarkTheme.base02))
                                    .foregroundStyle(Color(uiColor: SolarizedDarkTheme.cyan))
                                    .clipShape(Capsule())
                            }

                            if key.keyType == "RSA" {
                                Text("⚠️ OpenSSH 8.8+ disables ssh-rsa by default. Ed25519 recommended.")
                                    .font(.caption2.bold())
                                    .foregroundStyle(Color(uiColor: SolarizedDarkTheme.yellow))
                            }

                            Text(key.publicKey)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .textSelection(.enabled)

                            if key.publicKey.hasPrefix("(") {
                                Button("Unlock to Reveal Public Key") {
                                    unlockAndRevealPublicKey(for: key)
                                }
                                .font(.caption.bold())
                                .foregroundStyle(Color(uiColor: SolarizedDarkTheme.yellow))
                                .buttonStyle(.borderless)
                            }

                            HStack(spacing: 8) {
                                Button(action: { copyPublicKey(key) }) {
                                    Label(
                                        copiedKeyId == key.id ? "Copied!" : "Copy Public Key",
                                        systemImage: copiedKeyId == key.id ? "checkmark" : "doc.on.doc"
                                    )
                                    .font(.caption.bold())
                                    .foregroundStyle(Color(uiColor: SolarizedDarkTheme.cyan))
                                }
                                .buttonStyle(.borderless)

                                Spacer()

                                if let onSelect = onSelectKey {
                                    Button("Select") {
                                        onSelect(key)
                                    }
                                    .font(.caption)
                                    .buttonStyle(.borderless)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onDelete(perform: deleteKeys)
                }
            }

            Section {
                Button(action: {
                    errorMessage = nil
                    showingGenerateSheet = true
                }) {
                    Label("Generate New Ed25519 Key", systemImage: "key.fill")
                        .foregroundStyle(Color(uiColor: SolarizedDarkTheme.cyan))
                }

                Button(action: {
                    errorMessage = nil
                    showingImportSheet = true
                }) {
                    Label("Import Existing Private Key", systemImage: "square.and.arrow.down")
                        .foregroundStyle(Color(uiColor: SolarizedDarkTheme.yellow))
                }
            }
        }
        .navigationTitle("SSH Keys")
        .sheet(isPresented: $showingGenerateSheet) {
            NavigationStack {
                Form {
                    Section(header: Text("Key Details")) {
                        TextField("Key Name", text: $newKeyName)
                        SecureField("Key Passphrase (optional)", text: $keyPassphrase)
                    }

                    Section(
                        header: Text("Hardware Protection"),
                        footer: Text("Ed25519 private keys and passphrases are stored in the hardware Secure Enclave and can require \(BiometricAuthService.biometryName) verification to unlock.")
                    ) {
                        Toggle("Protect with \(BiometricAuthService.biometryName)", isOn: $requireBiometrics)
                    }

                    if let error = errorMessage {
                        Section {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(error)
                                    .foregroundStyle(Color(uiColor: SolarizedDarkTheme.red))
                                    .font(.caption)
                                    .textSelection(.enabled)

                                Button(action: {
                                    UIPasteboard.general.string = error
                                    let gen = UINotificationFeedbackGenerator()
                                    gen.notificationOccurred(.success)
                                }) {
                                    Label("Copy Error", systemImage: "doc.on.doc")
                                        .font(.caption2.bold())
                                        .foregroundStyle(Color(uiColor: SolarizedDarkTheme.cyan))
                                }
                            }
                        }
                    }

                    Section {
                        Button("Generate Keypair") {
                            generateKey()
                        }
                        .disabled(newKeyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .navigationTitle("Generate Key")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            showingGenerateSheet = false
                            errorMessage = nil
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showingImportSheet) {
            NavigationStack {
                Form {
                    Section(header: Text("Key Info")) {
                        TextField("Key Name", text: $importedKeyName)
                        SecureField("Key Passphrase (optional)", text: $importedKeyPassphrase)
                    }

                    Section(header: Text("Private Key (OpenSSH PEM)"), footer: Text("Paste your -----BEGIN OPENSSH PRIVATE KEY----- block here.")) {
                        TextEditor(text: $importedKeyPEM)
                            .frame(height: 150)
                            .font(.system(size: 11, design: .monospaced))
                    }

                    Section(header: Text("Hardware Protection")) {
                        Toggle("Protect with \(BiometricAuthService.biometryName)", isOn: $importRequireBiometrics)
                    }

                    if let parsedInfo = try? SSHKeyGenerator.parseKeyInfo(from: importedKeyPEM), parsedInfo.rawKeyType == "ssh-rsa" {
                        Section {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("⚠️ RSA Key Detected")
                                    .font(.subheadline.bold())
                                    .foregroundStyle(Color(uiColor: SolarizedDarkTheme.yellow))
                                Text("Modern OpenSSH servers (v8.8+, Debian 12+, Ubuntu 22.04+, macOS) reject 'ssh-rsa' (SHA-1) by default. If your server rejects this key, generate an Ed25519 key or add 'PubkeyAcceptedAlgorithms +ssh-rsa' to /etc/ssh/sshd_config.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if let error = errorMessage {
                        Section {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(error)
                                    .foregroundStyle(Color(uiColor: SolarizedDarkTheme.red))
                                    .font(.caption)
                                    .textSelection(.enabled)

                                Button(action: {
                                    UIPasteboard.general.string = error
                                    let gen = UINotificationFeedbackGenerator()
                                    gen.notificationOccurred(.success)
                                }) {
                                    Label("Copy Error", systemImage: "doc.on.doc")
                                        .font(.caption2.bold())
                                        .foregroundStyle(Color(uiColor: SolarizedDarkTheme.cyan))
                                }
                            }
                        }
                    }

                    Section {
                        Button("Import Key") {
                            importKey()
                        }
                        .disabled(
                            importedKeyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                            importedKeyPEM.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                    }
                }
                .navigationTitle("Import Key")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            showingImportSheet = false
                            errorMessage = nil
                        }
                    }
                }
            }
        }
    }

    private func copyPublicKey(_ key: SSHKeyModel) {
        UIPasteboard.general.string = key.publicKey
        copiedKeyId = key.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if copiedKeyId == key.id {
                copiedKeyId = nil
            }
        }
    }

    private func unlockAndRevealPublicKey(for key: SSHKeyModel) {
        Task {
            var context: LAContext? = nil
            if key.requiresBiometrics {
                context = try? await BiometricAuthService.authenticate(reason: "Unlock to retrieve public key")
            }
            guard let priv = KeychainService.getPrivateKey(forKeyId: key.id, context: context),
                  let info = try? SSHKeyGenerator.parseKeyInfo(from: priv),
                  let idx = keys.firstIndex(where: { $0.id == key.id }) else {
                return
            }
            keys[idx].publicKey = info.publicKey
            keys[idx].keyType = info.keyType
            copyPublicKey(keys[idx])
        }
    }

    private func generateKey() {
        do {
            let keyPair = try SSHKeyGenerator.generateEd25519Key(comment: "filaire@\(newKeyName.replacingOccurrences(of: " ", with: "-"))")
            let keyId = UUID()
            try KeychainService.savePrivateKey(keyPair.privateKeyPEM, forKeyId: keyId, requireBiometrics: requireBiometrics)

            if !keyPassphrase.isEmpty {
                do {
                    try KeychainService.saveKeyPassphrase(keyPassphrase, forKeyId: keyId, requireBiometrics: requireBiometrics)
                } catch {
                    KeychainService.deletePrivateKey(forKeyId: keyId)
                    throw error
                }
            }

            let model = SSHKeyModel(
                id: keyId,
                name: newKeyName.trimmingCharacters(in: .whitespacesAndNewlines),
                keyType: keyPair.keyType,
                publicKey: keyPair.publicKey,
                hasPassphrase: !keyPassphrase.isEmpty,
                requiresBiometrics: requireBiometrics
            )
            keys.append(model)
            onSelectKey?(model)
            showingGenerateSheet = false
            newKeyName = "Filaire iPad Key"
            keyPassphrase = ""
            requireBiometrics = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func importKey() {
        let keyId = UUID()
        let trimmedPEM = importedKeyPEM.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = importedKeyName.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            let info = try SSHKeyGenerator.parseKeyInfo(from: trimmedPEM)

            if info.isEncrypted && importedKeyPassphrase.isEmpty {
                errorMessage = "This private key is encrypted with cipher '\(info.cipherName)'. Please enter the Key Passphrase."
                return
            }

            // Validate key and passphrase before saving
            if info.rawKeyType == "ssh-rsa" {
                _ = try SSHKeyGenerator.parseRSAPrivateKey(from: trimmedPEM, passphrase: importedKeyPassphrase)
            } else if info.rawKeyType == "ssh-ed25519" {
                _ = try SSHKeyGenerator.parseEd25519PrivateKey(from: trimmedPEM, passphrase: importedKeyPassphrase)
            }

            try KeychainService.savePrivateKey(trimmedPEM, forKeyId: keyId, requireBiometrics: importRequireBiometrics)

            if !importedKeyPassphrase.isEmpty {
                do {
                    try KeychainService.saveKeyPassphrase(importedKeyPassphrase, forKeyId: keyId, requireBiometrics: importRequireBiometrics)
                } catch {
                    KeychainService.deletePrivateKey(forKeyId: keyId)
                    throw error
                }
            }

            let model = SSHKeyModel(
                id: keyId,
                name: trimmedName,
                keyType: info.keyType,
                publicKey: info.publicKey,
                hasPassphrase: !importedKeyPassphrase.isEmpty,
                requiresBiometrics: importRequireBiometrics
            )
            keys.append(model)
            onSelectKey?(model)
            showingImportSheet = false
            importedKeyName = ""
            importedKeyPEM = ""
            importedKeyPassphrase = ""
            importRequireBiometrics = true
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteKeys(at offsets: IndexSet) {
        for index in offsets {
            let key = keys[index]
            KeychainService.deletePrivateKey(forKeyId: key.id)
            KeychainService.deleteKeyPassphrase(forKeyId: key.id)
        }
        keys.remove(atOffsets: offsets)
    }
}
