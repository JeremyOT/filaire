import SwiftUI

public struct HostEditorView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var draftHost: HostProfile
    @Binding public var availableKeys: [SSHKeyModel]
    public var availableHosts: [HostProfile] = []
    public let onSave: (HostProfile) -> Void

    @State private var password: String = ""
    @State private var showingKeyManagement = false
    @State private var showingAddPortForward = false
    @State private var newRuleType: PortForwardType = .local
    @State private var newLocalPort: Int = 8080
    @State private var newRemoteHost: String = "localhost"
    @State private var newRemotePort: Int = 8080
    @State private var copiedFeedback: String? = nil
    @State private var saveErrorMessage: String?

    public init(
        initialHost: HostProfile = HostProfile(),
        availableKeys: Binding<[SSHKeyModel]>,
        availableHosts: [HostProfile] = [],
        onSave: @escaping (HostProfile) -> Void
    ) {
        self._draftHost = State(initialValue: initialHost)
        self._availableKeys = availableKeys
        self.availableHosts = availableHosts
        self.onSave = onSave
    }

    public init(
        host: Binding<HostProfile>,
        availableKeys: Binding<[SSHKeyModel]>,
        availableHosts: [HostProfile] = [],
        onSave: @escaping (HostProfile) -> Void
    ) {
        self._draftHost = State(initialValue: host.wrappedValue)
        self._availableKeys = availableKeys
        self.availableHosts = availableHosts
        self.onSave = onSave
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Host Info")) {
                    TextField("Display Name (optional)", text: $draftHost.name)
                    TextField("Host / IP Address", text: $draftHost.hostname)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)

                    HStack {
                        Text("Port")
                        Spacer()
                        TextField("22", value: $draftHost.port, format: .number)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numberPad)
                    }

                    TextField("Username", text: $draftHost.username)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }

                Section(header: Text("Authentication")) {
                    Picker("Method", selection: $draftHost.authMethod) {
                        ForEach(AuthMethodType.allCases) { method in
                            Text(method.rawValue).tag(method)
                        }
                    }
                    .pickerStyle(.segmented)

                    if draftHost.authMethod == .sshKey {
                        if availableKeys.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("No SSH keys found.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Button("Create or Import an SSH Key") {
                                    showingKeyManagement = true
                                }
                                .font(.subheadline.bold())
                                .foregroundStyle(Color(uiColor: SolarizedDarkTheme.cyan))
                            }
                            .padding(.vertical, 4)
                        } else {
                            Picker("SSH Key", selection: $draftHost.selectedKeyId) {
                                Text("Select a Key").tag(nil as UUID?)
                                ForEach(availableKeys) { key in
                                    Text(key.name).tag(key.id as UUID?)
                                }
                            }

                            if let keyId = draftHost.selectedKeyId, let key = availableKeys.first(where: { $0.id == keyId }) {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(key.keyType)
                                            .font(.caption2.bold())
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color(uiColor: SolarizedDarkTheme.base02))
                                            .foregroundStyle(Color(uiColor: SolarizedDarkTheme.cyan))
                                            .clipShape(Capsule())

                                        if key.keyType == "RSA" {
                                            Text("⚠️ OpenSSH 8.8+ disables ssh-rsa")
                                                .font(.caption2.bold())
                                                .foregroundStyle(Color(uiColor: SolarizedDarkTheme.yellow))
                                        }
                                    }

                                    Text(key.publicKey)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .textSelection(.enabled)

                                    Button(action: {
                                        copyToClipboard(key.publicKey, feedback: "Public Key Copied")
                                    }) {
                                        Label(copiedFeedback == "Public Key Copied" ? "Copied!" : "Copy Public Key",
                                              systemImage: copiedFeedback == "Public Key Copied" ? "checkmark" : "doc.on.doc")
                                            .font(.caption.bold())
                                            .foregroundStyle(Color(uiColor: SolarizedDarkTheme.cyan))
                                    }
                                    .buttonStyle(.borderless)
                                }
                                .padding(.vertical, 4)
                            }

                            Button("Manage Keys...") {
                                showingKeyManagement = true
                            }
                            .font(.caption)
                            .foregroundStyle(Color(uiColor: SolarizedDarkTheme.cyan))
                        }
                    } else {
                        SecureField("Password (saved in Keychain)", text: $password)
                    }
                }

                Section(
                    header: Text("Session & Startup"),
                    footer: Text(draftHost.autoConnectTmux
                        ? "Automatically attaches to or creates the tmux session on connection. Prefix defaults to Ctrl-B. Use Cmd+Opt+C or the 'Copy' bar button to enter copy mode. Enabling set-clipboard lets any program running in tmux write to your clipboard."
                        : "Optional command to execute automatically upon connection. Leave blank for default login shell.")
                ) {
                    Toggle("Auto-connect to tmux session", isOn: $draftHost.autoConnectTmux)

                    if draftHost.autoConnectTmux {
                        TextField(
                            "Session Name (optional, defaults to '\(draftHost.username.isEmpty ? "username" : draftHost.username)')",
                            text: Binding(
                                get: { draftHost.customTmuxSession ?? "" },
                                set: { draftHost.customTmuxSession = $0.isEmpty ? nil : $0 }
                            )
                        )
                        .autocapitalization(.none)
                        .disableAutocorrection(true)

                        HStack {
                            Text("tmux Prefix")
                            Spacer()
                            TextField(
                                "ctrl-b",
                                text: $draftHost.tmuxPrefix
                            )
                            .multilineTextAlignment(.trailing)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .frame(maxWidth: 120)

                            Text(draftHost.tmuxPrefixDisplay)
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color(uiColor: SolarizedDarkTheme.cyan))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color(uiColor: SolarizedDarkTheme.cyan).opacity(0.15))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }

                        Toggle("Detach existing sessions (-D)", isOn: $draftHost.detachExistingTmux)
                        Toggle("Enable tmux set-clipboard on connect", isOn: $draftHost.enableTmuxSetClipboard)
                    } else {
                        TextField(
                            "Command (optional, e.g. htop or zsh)",
                            text: Binding(
                                get: { draftHost.connectionCommand ?? "" },
                                set: { draftHost.connectionCommand = $0.isEmpty ? nil : $0 }
                            )
                        )
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    }
                }

                Section(header: Text("Jump Host (ProxyJump)")) {
                    Picker("Bastion Host", selection: $draftHost.jumpHostId) {
                        Text("Direct Connection (None)").tag(nil as UUID?)
                        ForEach(availableHosts.filter { $0.id != draftHost.id }) { bastion in
                            Text(bastion.displayName).tag(bastion.id as UUID?)
                        }
                    }
                }

                Section(header: Text("Port Forwarding (ssh -L / -D)")) {
                    if draftHost.portForwards.isEmpty {
                        Text("No port forwards configured.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach($draftHost.portForwards) { $rule in
                            HStack {
                                Toggle(isOn: $rule.isEnabled) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(rule.ruleType == .dynamic ? "127.0.0.1:\(rule.localPort) (SOCKS5 Proxy)" : "127.0.0.1:\(rule.localPort) → \(rule.remoteHost):\(rule.remotePort)")
                                            .font(.system(.subheadline, design: .monospaced))
                                    }
                                }
                            }
                        }
                        .onDelete { indexSet in
                            draftHost.portForwards.remove(atOffsets: indexSet)
                        }
                    }

                    Button(action: { showingAddPortForward = true }) {
                        Label("Add Port Forward Rule", systemImage: "plus")
                            .foregroundStyle(Color(uiColor: SolarizedDarkTheme.cyan))
                    }
                }

                Section(
                    header: Text("Security"),
                    footer: Text(draftHost.urlOpeningPolicy.description)
                ) {
                    Toggle("Require \(BiometricAuthService.biometryName) on Connect", isOn: $draftHost.requireBiometrics)
                    Toggle("Enable SSH Agent Forwarding", isOn: $draftHost.enableAgentForwarding)
                    if draftHost.enableAgentForwarding {
                        ForEach(availableKeys.filter { $0.publicKey.hasPrefix("ssh-ed25519") }) { key in
                            Toggle("Forward “\(key.name)”", isOn: agentKeyBinding(for: key))
                                .padding(.leading)
                        }
                    }
                    Toggle("Allow Remote Clipboard Write (OSC 52)", isOn: $draftHost.allowClipboardWrite)
                    Toggle("Allow Remote Clipboard Read (OSC 52)", isOn: $draftHost.allowClipboardRead)
                    Toggle("Allow Remote File Previews (OSC 5101)", isOn: $draftHost.allowFilePreview)
                    Toggle("Allow Remote Notifications (OSC 777)", isOn: $draftHost.allowRemoteNotifications)

                    Picker("Remote URL Action", selection: $draftHost.urlOpeningPolicy) {
                        ForEach(RemoteUrlOpeningPolicy.allCases) { policy in
                            Text(policy.displayName).tag(policy)
                        }
                    }
                }

                Section(header: Text("Connection Options")) {
                    Toggle("Auto-connect on launch", isOn: $draftHost.autoConnect)
                    Toggle("Allow Legacy Algorithms (SHA-1)", isOn: $draftHost.allowLegacyAlgorithms)

                    Stepper(value: $draftHost.keepAliveInterval, in: 0...120, step: 5) {
                        HStack {
                            Text("Keep-Alive Interval")
                            Spacer()
                            Text(draftHost.keepAliveInterval == 0 ? "Disabled" : "\(Int(draftHost.keepAliveInterval))s")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle(draftHost.hostname.isEmpty ? "New Host" : "Edit Host")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveAndDismiss()
                    }
                    .disabled(
                        draftHost.hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        draftHost.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        !HostProfile.validPortRange.contains(draftHost.port)
                    )
                }
            }
            .sheet(isPresented: $showingAddPortForward) {
                NavigationStack {
                    Form {
                        Section {
                            Picker("Forwarding Type", selection: $newRuleType) {
                                Text("Local (ssh -L)").tag(PortForwardType.local)
                                Text("Dynamic SOCKS5 (ssh -D)").tag(PortForwardType.dynamic)
                            }
                            .pickerStyle(.segmented)
                        }

                        Section(header: Text("Local Port (on device)")) {
                            TextField("8080", value: $newLocalPort, format: .number)
                                .keyboardType(.numberPad)
                        }

                        if newRuleType == .local {
                            Section(header: Text("Remote Target (from server)")) {
                                TextField("Remote Host (e.g. localhost)", text: $newRemoteHost)
                                    .autocapitalization(.none)
                                    .disableAutocorrection(true)
                                TextField("Remote Port (e.g. 8080)", value: $newRemotePort, format: .number)
                                    .keyboardType(.numberPad)
                            }
                        } else {
                            Section(footer: Text("Dynamic SOCKS5 proxy listens on 127.0.0.1:\(newLocalPort) and dynamically routes client connections through the remote SSH host.")) {
                                EmptyView()
                            }
                        }
                    }
                    .navigationTitle("New Port Forward")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { showingAddPortForward = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Add") {
                                let rule = PortForwardRule(
                                    localPort: newLocalPort,
                                    remoteHost: newRuleType == .dynamic ? "" : (newRemoteHost.isEmpty ? "localhost" : newRemoteHost),
                                    remotePort: newRuleType == .dynamic ? 0 : newRemotePort,
                                    ruleType: newRuleType
                                )
                                draftHost.portForwards.append(rule)
                                showingAddPortForward = false
                            }
                            .disabled(
                                !PortForwardRule.validPortRange.contains(newLocalPort) ||
                                (newRuleType == .local && !PortForwardRule.validPortRange.contains(newRemotePort))
                            )
                        }
                    }
                }
                .presentationDetents([.medium])
            }
            .sheet(isPresented: $showingKeyManagement) {
                NavigationStack {
                    KeyManagementView(keys: $availableKeys) { selectedKey in
                        draftHost.selectedKeyId = selectedKey.id
                        showingKeyManagement = false
                    }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showingKeyManagement = false }
                        }
                    }
                }
            }
            .onAppear {
                if draftHost.authMethod == .password {
                    password = KeychainService.getPassword(forHostId: draftHost.id) ?? ""
                }
                if draftHost.selectedKeyId == nil, let firstKey = availableKeys.first {
                    draftHost.selectedKeyId = firstKey.id
                }
            }
            .alert("Couldn’t Save Password", isPresented: Binding(get: { saveErrorMessage != nil }, set: { if !$0 { saveErrorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(saveErrorMessage ?? "")
            }
        }
    }

    private func saveAndDismiss() {
        draftHost.name = draftHost.name.trimmingCharacters(in: .whitespacesAndNewlines)
        draftHost.hostname = draftHost.hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        draftHost.username = draftHost.username.trimmingCharacters(in: .whitespacesAndNewlines)
        draftHost.port = HostProfile.validPortRange.contains(draftHost.port) ? draftHost.port : HostProfile.defaultPort
        if let cmd = draftHost.connectionCommand {
            let trimmed = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
            draftHost.connectionCommand = trimmed.isEmpty ? nil : trimmed
        }
        if let session = draftHost.customTmuxSession {
            let trimmed = session.trimmingCharacters(in: .whitespacesAndNewlines)
            draftHost.customTmuxSession = trimmed.isEmpty ? nil : trimmed
        }
        draftHost.tmuxPrefix = draftHost.tmuxPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        if draftHost.authMethod == .password {
            if !password.isEmpty {
                do {
                    try KeychainService.savePassword(password, forHostId: draftHost.id, requireBiometrics: draftHost.requireBiometrics)
                } catch {
                    saveErrorMessage = error.localizedDescription
                    return
                }
            } else {
                KeychainService.deletePassword(forHostId: draftHost.id)
            }
        }
        onSave(draftHost)
        dismiss()
    }

    private func copyToClipboard(_ text: String, feedback: String) {
        UIPasteboard.general.string = text
        copiedFeedback = feedback
        let gen = UINotificationFeedbackGenerator()
        gen.notificationOccurred(.success)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if copiedFeedback == feedback {
                copiedFeedback = nil
            }
        }
    }

    private func agentKeyBinding(for key: SSHKeyModel) -> Binding<Bool> {
        Binding(
            get: { SSHAgentServer.keysForForwarding(host: draftHost, allKeys: availableKeys).contains { $0.id == key.id } },
            set: { isOn in
                var ids = Set(SSHAgentServer.keysForForwarding(host: draftHost, allKeys: availableKeys).map(\.id))
                if isOn { ids.insert(key.id) } else { ids.remove(key.id) }
                draftHost.agentForwardingKeyIds = availableKeys.map(\.id).filter { ids.contains($0) }
            }
        )
    }
}
