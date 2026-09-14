import SwiftUI

public struct HostListView: View {
    @Binding public var hosts: [HostProfile]
    @Binding public var selectedHostId: UUID?
    @Binding public var availableKeys: [SSHKeyModel]
    public var currentWindowScene: UIWindowScene?
    public var sessionManager: SessionManager?
    @ObservedObject public var windowManager: MultiWindowManager
    public var onDisconnect: (() -> Void)?
    public var onDeleteHosts: ((Set<UUID>) -> Void)?
    public let onConnectToHost: (HostProfile) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var detectedWindowScene: UIWindowScene?

    private var effectiveWindowScene: UIWindowScene? {
        currentWindowScene ?? detectedWindowScene
    }

    @State private var showingAddHost = false
    @State private var editingHost: HostProfile? = nil
    @State private var showingKeyManagement = false
    @State private var showingKnownHosts = false
    @State private var searchText = ""

    private var filteredHosts: [HostProfile] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return hosts }
        return hosts.filter { host in
            host.name.lowercased().contains(query) ||
            host.hostname.lowercased().contains(query) ||
            host.username.lowercased().contains(query) ||
            "\(host.port)".contains(query) ||
            (host.customTmuxSession?.lowercased().contains(query) ?? false)
        }
    }

    @State private var selectedFontFamily = FontManager.shared.selectedFamily
    @State private var fontSize = FontManager.shared.fontSize
    @State private var selectedTheme = ThemeManager.shared.selectedThemeType
    @State private var selectedScrollback = TerminalSettings.shared.scrollbackLimit
    @State private var showKeyboardAccessoryBar = TerminalSettings.shared.showKeyboardAccessoryBar
    @State private var selectedBellStyle = TerminalSettings.shared.bellStyle
    @State private var aggressiveBackgroundTrimming = TerminalSettings.shared.aggressiveBackgroundTrimmingEnabled

    public init(
        hosts: Binding<[HostProfile]>,
        selectedHostId: Binding<UUID?>,
        availableKeys: Binding<[SSHKeyModel]>,
        currentWindowScene: UIWindowScene? = nil,
        sessionManager: SessionManager? = nil,
        windowManager: MultiWindowManager = .shared,
        onDisconnect: (() -> Void)? = nil,
        onDeleteHosts: ((Set<UUID>) -> Void)? = nil,
        onConnectToHost: @escaping (HostProfile) -> Void
    ) {
        self._hosts = hosts
        self._selectedHostId = selectedHostId
        self._availableKeys = availableKeys
        self.currentWindowScene = currentWindowScene
        self.sessionManager = sessionManager
        self.windowManager = windowManager
        self.onDisconnect = onDisconnect
        self.onDeleteHosts = onDeleteHosts
        self.onConnectToHost = onConnectToHost
    }

    public var body: some View {
        NavigationStack {
            List {
                Section(header: Text("Configured Hosts")) {
                    if hosts.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("No SSH hosts configured.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Button("Add your first host") {
                                showingAddHost = true
                            }
                            .font(.subheadline.bold())
                            .foregroundStyle(Color(uiColor: SolarizedDarkTheme.cyan))
                        }
                        .padding(.vertical, 4)
                    } else if filteredHosts.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No hosts match '\(searchText)'.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    } else {
                        ForEach(filteredHosts) { host in
                            let hostSubtitle: String = {
                                let hostPort = "\(host.username)@\(host.hostname):\(host.port)"
                                if host.autoConnectTmux {
                                    return "\(hostPort) (tmux: \(host.effectiveTmuxSession))"
                                } else if let cmd = host.connectionCommand?.trimmingCharacters(in: .whitespacesAndNewlines), !cmd.isEmpty {
                                    return "\(hostPort) (cmd: \(cmd))"
                                } else {
                                    return hostPort
                                }
                            }()

                            let isCurrentWindow: Bool = {
                                if host.id == selectedHostId { return true }
                                if let currentScene = effectiveWindowScene,
                                   let sceneHost = windowManager.findScene(for: host.id),
                                   sceneHost == currentScene {
                                    return true
                                }
                                return false
                            }()

                            let isOpenInOtherWindow: Bool = {
                                guard UIApplication.shared.supportsMultipleScenes else { return false }
                                if let scene = windowManager.findScene(for: host.id) {
                                    if let current = effectiveWindowScene {
                                        return scene != current
                                    }
                                    return true
                                }
                                if let snap = windowManager.snapshots[host.id],
                                   snap.windowStatus == .owned,
                                   let current = effectiveWindowScene,
                                   snap.ownerSessionPersistentIdentifier != current.session.persistentIdentifier {
                                    return true
                                }
                                return false
                            }()

                            let isHostAlreadyOpen = isCurrentWindow || isOpenInOtherWindow

                            let currentConnState: ConnectionState = {
                                if isCurrentWindow {
                                    return sessionManager?.state ?? windowManager.snapshots[host.id]?.connectionState ?? .disconnected
                                }
                                return windowManager.snapshots[host.id]?.connectionState ?? .disconnected
                            }()

                            let handleRowOrButtonTap: () -> Void = {
                                let action = HostListView.resolveRowTapAction(
                                    for: host,
                                    selectedHostId: selectedHostId,
                                    effectiveWindowScene: effectiveWindowScene,
                                    sessionManager: sessionManager,
                                    windowManager: windowManager
                                )
                                switch action {
                                case .switchToOtherWindow(let scene):
                                    QuickActionManager.shared.activateScene(scene, hostId: host.id)
                                    dismiss()
                                case .dismissAndFocusTerminal:
                                    dismiss()
                                case .ignoreBusy:
                                    dismiss()
                                case .connectInCurrentWindow(let target):
                                    handleConnectInCurrentWindow(to: target)
                                }
                            }

                            let buttonImageName: String = {
                                if isOpenInOtherWindow {
                                    return "macwindow"
                                }
                                if isCurrentWindow {
                                    switch currentConnState {
                                    case .connected:
                                        return "checkmark.circle.fill"
                                    case .connecting, .reconnecting:
                                        return "arrow.triangle.2.circlepath"
                                    case .failed:
                                        return "arrow.clockwise.circle.fill"
                                    case .disconnected:
                                        return "terminal.fill"
                                    }
                                }
                                return "terminal.fill"
                            }()

                            let buttonColor: Color = {
                                if isOpenInOtherWindow {
                                    return Color(uiColor: SolarizedDarkTheme.yellow)
                                }
                                if isCurrentWindow {
                                    switch currentConnState {
                                    case .connected:
                                        return Color(uiColor: SolarizedDarkTheme.green)
                                    case .connecting, .reconnecting:
                                        return Color(uiColor: SolarizedDarkTheme.yellow)
                                    case .failed:
                                        return Color(uiColor: SolarizedDarkTheme.red)
                                    case .disconnected:
                                        return Color(uiColor: SolarizedDarkTheme.cyan)
                                    }
                                }
                                return Color(uiColor: SolarizedDarkTheme.cyan)
                            }()

                            let buttonAccessibilityLabel: String = {
                                if isOpenInOtherWindow {
                                    return "Switch to \(host.displayName)"
                                }
                                if isCurrentWindow {
                                    switch currentConnState {
                                    case .connected:
                                        return "Focus terminal for \(host.displayName)"
                                    case .connecting, .reconnecting:
                                        return "Connecting to \(host.displayName)"
                                    case .failed:
                                        return "Retry connection to \(host.displayName)"
                                    case .disconnected:
                                        return "Connect to \(host.displayName)"
                                    }
                                }
                                return "Connect to \(host.displayName)"
                            }()

                            HStack(spacing: 8) {
                                // Tapping the main row connects in the current window (or switches to existing window if open)
                                Button {
                                    handleRowOrButtonTap()
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 4) {
                                            HStack {
                                                Text(host.displayName)
                                                    .font(.headline)
                                                    .foregroundStyle(Color(uiColor: SolarizedDarkTheme.base1))

                                                if isOpenInOtherWindow {
                                                    Text("Open in Window")
                                                        .font(.caption2.bold())
                                                        .padding(.horizontal, 6)
                                                        .padding(.vertical, 2)
                                                        .background(Color(uiColor: SolarizedDarkTheme.yellow).opacity(0.2))
                                                        .foregroundStyle(Color(uiColor: SolarizedDarkTheme.yellow))
                                                        .clipShape(Capsule())
                                                } else if isCurrentWindow {
                                                    switch currentConnState {
                                                    case .connected:
                                                        Text("Connected")
                                                            .font(.caption2.bold())
                                                            .padding(.horizontal, 6)
                                                            .padding(.vertical, 2)
                                                            .background(Color(uiColor: SolarizedDarkTheme.green).opacity(0.2))
                                                            .foregroundStyle(Color(uiColor: SolarizedDarkTheme.green))
                                                            .clipShape(Capsule())
                                                    case .connecting:
                                                        Text("Connecting")
                                                            .font(.caption2.bold())
                                                            .padding(.horizontal, 6)
                                                            .padding(.vertical, 2)
                                                            .background(Color(uiColor: SolarizedDarkTheme.yellow).opacity(0.2))
                                                            .foregroundStyle(Color(uiColor: SolarizedDarkTheme.yellow))
                                                            .clipShape(Capsule())
                                                    case .reconnecting:
                                                        Text("Reconnecting")
                                                            .font(.caption2.bold())
                                                            .padding(.horizontal, 6)
                                                            .padding(.vertical, 2)
                                                            .background(Color(uiColor: SolarizedDarkTheme.yellow).opacity(0.2))
                                                            .foregroundStyle(Color(uiColor: SolarizedDarkTheme.yellow))
                                                            .clipShape(Capsule())
                                                    case .disconnected, .failed:
                                                        Text("Disconnected")
                                                            .font(.caption2.bold())
                                                            .padding(.horizontal, 6)
                                                            .padding(.vertical, 2)
                                                            .background(Color(uiColor: SolarizedDarkTheme.base01).opacity(0.2))
                                                            .foregroundStyle(Color(uiColor: SolarizedDarkTheme.base01))
                                                            .clipShape(Capsule())
                                                    }
                                                }
                                            }

                                            Text(hostSubtitle)
                                                .font(.system(size: 12, design: .monospaced))
                                                .foregroundStyle(Color(uiColor: SolarizedDarkTheme.base00))
                                        }

                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                // Connect button
                                Button {
                                    handleRowOrButtonTap()
                                } label: {
                                    Image(systemName: buttonImageName)
                                        .font(.system(size: 16))
                                        .foregroundStyle(buttonColor)
                                        .padding(6)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(buttonAccessibilityLabel)

                                // Open in new window button (only for hosts not already open anywhere)
                                if UIApplication.shared.supportsMultipleScenes && !isHostAlreadyOpen {
                                    Button {
                                        QuickActionManager.shared.openHostInNewWindow(hostId: host.id)
                                        dismiss()
                                    } label: {
                                        Image(systemName: "macwindow.badge.plus")
                                            .font(.system(size: 15))
                                            .foregroundStyle(Color(uiColor: SolarizedDarkTheme.yellow))
                                            .padding(6)
                                    }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel("Open \(host.displayName) in new window")
                                }

                                // Edit host button
                                Button {
                                    editingHost = host
                                } label: {
                                    Image(systemName: "pencil")
                                        .font(.system(size: 15))
                                        .foregroundStyle(.secondary)
                                        .padding(6)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Edit \(host.displayName)")
                            }
                            .contentShape(Rectangle())
                            .conditionalDrag(for: host, isAlreadyOpen: isHostAlreadyOpen, selectedHostId: selectedHostId)
                            .contextMenu {
                                Button {
                                    handleRowOrButtonTap()
                                } label: {
                                    if isCurrentWindow {
                                        switch currentConnState {
                                        case .connected:
                                            Label("Focus Terminal", systemImage: "terminal")
                                        case .connecting, .reconnecting:
                                            Label("Connecting...", systemImage: "arrow.triangle.2.circlepath")
                                        case .failed:
                                            Label("Retry Connection", systemImage: "arrow.clockwise")
                                        case .disconnected:
                                            Label("Connect in Current Window", systemImage: "terminal")
                                        }
                                    } else {
                                        Label("Connect in Current Window", systemImage: "terminal")
                                    }
                                }

                                if isOpenInOtherWindow {
                                    Button {
                                        handleSwitchToExistingWindow(to: host)
                                    } label: {
                                        Label("Switch to Open Window", systemImage: "macwindow")
                                    }
                                }

                                if UIApplication.shared.supportsMultipleScenes && !isHostAlreadyOpen {
                                    Button {
                                        QuickActionManager.shared.openHostInNewWindow(hostId: host.id)
                                        dismiss()
                                    } label: {
                                        Label("Open in New Window", systemImage: "macwindow.badge.plus")
                                    }
                                }

                                if isCurrentWindow, (currentConnState == .connected || currentConnState.isBusy), let onDisconnect = onDisconnect {
                                    Button(role: .destructive) {
                                        onDisconnect()
                                        dismiss()
                                    } label: {
                                        Label("Disconnect", systemImage: "power")
                                    }
                                }

                                Button {
                                    editingHost = host
                                } label: {
                                    Label("Edit Host", systemImage: "pencil")
                                }

                                Button {
                                    duplicateHost(host)
                                } label: {
                                    Label("Duplicate Host", systemImage: "doc.on.doc")
                                }

                                Button(role: .destructive) {
                                    deleteHost(host)
                                } label: {
                                    Label("Delete Host", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                if UIApplication.shared.supportsMultipleScenes && !isHostAlreadyOpen {
                                    Button {
                                        QuickActionManager.shared.openHostInNewWindow(hostId: host.id)
                                        dismiss()
                                    } label: {
                                        Label("New Window", systemImage: "macwindow.badge.plus")
                                    }
                                    .tint(Color(uiColor: SolarizedDarkTheme.yellow))
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    deleteHost(host)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                Button {
                                    duplicateHost(host)
                                } label: {
                                    Label("Duplicate", systemImage: "doc.on.doc")
                                }
                                .tint(Color(uiColor: SolarizedDarkTheme.cyan))
                            }
                        }
                        .onDelete(perform: deleteFilteredHosts)
                    }

                    Button(action: { showingAddHost = true }) {
                        Label("Add Host", systemImage: "plus")
                            .foregroundStyle(Color(uiColor: SolarizedDarkTheme.cyan))
                    }
                }

                Section(header: Text("Terminal & Font")) {
                    Picker("Font Family", selection: $selectedFontFamily) {
                        ForEach(TerminalFontFamily.allCases) { family in
                            Text(family.rawValue).tag(family)
                        }
                    }
                    .onChange(of: selectedFontFamily) { _, newFamily in
                        FontManager.shared.selectedFamily = newFamily
                    }

                    HStack {
                        Stepper(value: $fontSize, in: 9...28, step: 1) {
                            HStack {
                                Text("Font Size")
                                Spacer()
                                Text("\(Int(fontSize)) pt")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .onChange(of: fontSize) { _, newSize in
                            FontManager.shared.fontSize = newSize
                        }

                        if fontSize != FontManager.shared.defaultFontSize {
                            Button("Reset") {
                                FontManager.shared.resetFontSize()
                                fontSize = FontManager.shared.fontSize
                            }
                            .font(.caption.bold())
                            .foregroundStyle(Color(uiColor: SolarizedDarkTheme.cyan))
                            .buttonStyle(.borderless)
                        }
                    }

                    Picker("Color Scheme", selection: $selectedTheme) {
                        ForEach(TerminalThemeType.allCases) { theme in
                            Text(theme.rawValue).tag(theme)
                        }
                    }
                    .onChange(of: selectedTheme) { _, newTheme in
                        ThemeManager.shared.selectedThemeType = newTheme
                    }

                    Picker("Scrollback Limit", selection: $selectedScrollback) {
                        ForEach(ScrollbackLimit.allCases) { limit in
                            Text(limit.displayName).tag(limit)
                        }
                    }
                    .onChange(of: selectedScrollback) { _, newLimit in
                        TerminalSettings.shared.scrollbackLimit = newLimit
                    }

                    Toggle("Keyboard Helper Bar", isOn: $showKeyboardAccessoryBar)
                        .onChange(of: showKeyboardAccessoryBar) { _, newValue in
                            TerminalSettings.shared.showKeyboardAccessoryBar = newValue
                        }

                    Toggle("Aggressive Background Trimming", isOn: $aggressiveBackgroundTrimming)
                        .onChange(of: aggressiveBackgroundTrimming) { _, newValue in
                            TerminalSettings.shared.aggressiveBackgroundTrimmingEnabled = newValue
                        }

                    Picker("Terminal Bell", selection: $selectedBellStyle) {
                        ForEach(BellStyle.allCases) { style in
                            Text(style.rawValue).tag(style)
                        }
                    }
                    .onChange(of: selectedBellStyle) { _, newStyle in
                        TerminalSettings.shared.bellStyle = newStyle
                    }
                }

                Section(header: Text("Security")) {
                    Button(action: { showingKeyManagement = true }) {
                        Label("Manage SSH Keys (\(availableKeys.count))", systemImage: "key.fill")
                            .foregroundStyle(Color(uiColor: SolarizedDarkTheme.yellow))
                    }

                    Button(action: { showingKnownHosts = true }) {
                        Label("Known Hosts & Fingerprints", systemImage: "lock.shield")
                            .foregroundStyle(Color(uiColor: SolarizedDarkTheme.cyan))
                    }
                }

                Section(
                    header: Text("Companion Tool (fil)"),
                    footer: Text("Install the fil CLI on remote servers to unlock Quick Look file previews, remote URL opening, clipboard sync, SSH agent forwarding, and notifications.")
                ) {
                    NavigationLink {
                        CompanionToolGuideView()
                    } label: {
                        Label("Installation & Commands Guide", systemImage: "terminal.fill")
                            .foregroundStyle(Color(uiColor: SolarizedDarkTheme.cyan))
                    }

                    Link(destination: URL(string: "https://github.com/JeremyOT/filaire")!) {
                        HStack {
                            Label("Instructions on GitHub", systemImage: "safari")
                                .foregroundStyle(Color(uiColor: SolarizedDarkTheme.cyan))
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section(
                    header: Text("About"),
                    footer: VStack(alignment: .center, spacing: 4) {
                        Text("Filaire \(Self.appVersion)\(Self.buildNumber.isEmpty ? "" : " (\(Self.buildNumber))")")
                        Text(Self.commitHash)
                            .font(.system(.caption2, design: .monospaced))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                    .textSelection(.enabled)
                    .contextMenu {
                        Button {
                            UIPasteboard.general.string = Self.commitHash
                        } label: {
                            Label("Copy Commit Hash", systemImage: "doc.on.doc")
                        }
                        Button {
                            let buildStr = Self.buildNumber.isEmpty ? "" : " (\(Self.buildNumber))"
                            UIPasteboard.general.string = "Filaire \(Self.appVersion)\(buildStr) \u{00B7} \(Self.commitHash)"
                        } label: {
                            Label("Copy Build Info", systemImage: "info.circle")
                        }
                    }
                ) {
                    Link(destination: URL(string: "https://github.com/JeremyOT/filaire")!) {
                        HStack {
                            Label("Source / Licenses", systemImage: "safari")
                                .foregroundStyle(Color(uiColor: SolarizedDarkTheme.cyan))
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search hosts")
            .navigationTitle("Filaire Hosts")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }

                ToolbarItemGroup(placement: .primaryAction) {
                    let unopenedHosts = hosts.filter {
                        $0.id != selectedHostId && !windowManager.isHostOpenAnywhere($0.id)
                    }
                    if UIApplication.shared.supportsMultipleScenes && !unopenedHosts.isEmpty {
                        Menu {
                            ForEach(unopenedHosts) { host in
                                Button {
                                    QuickActionManager.shared.openHostInNewWindow(hostId: host.id)
                                    dismiss()
                                } label: {
                                    Label(host.displayName, systemImage: "terminal")
                                }
                            }
                        } label: {
                            Label("New Window", systemImage: "macwindow.badge.plus")
                        }
                    }

                    Button {
                        showingAddHost = true
                    } label: {
                        Label("Add Host", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddHost) {
                HostEditorView(
                    initialHost: HostProfile(),
                    availableKeys: $availableKeys,
                    availableHosts: hosts
                ) { newHost in
                    let wasEmpty = hosts.isEmpty
                    hosts.append(newHost)
                    if wasEmpty {
                        selectedHostId = newHost.id
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            handleConnectInCurrentWindow(to: newHost)
                        }
                    }
                }
            }
            .sheet(item: $editingHost) { host in
                HostEditorView(
                    initialHost: host,
                    availableKeys: $availableKeys,
                    availableHosts: hosts
                ) { updated in
                    if let index = hosts.firstIndex(where: { $0.id == updated.id }) {
                        hosts[index] = updated
                    }
                }
            }
            .sheet(isPresented: $showingKeyManagement) {
                NavigationStack {
                    KeyManagementView(keys: $availableKeys)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { showingKeyManagement = false }
                            }
                        }
                }
            }
            .sheet(isPresented: $showingKnownHosts) {
                NavigationStack {
                    KnownHostsView()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { showingKnownHosts = false }
                            }
                        }
                }
            }
            .background(
                WindowSceneTitleAccessor(title: "") { win in
                    if let scene = win?.windowScene, detectedWindowScene == nil {
                        detectedWindowScene = scene
                    }
                }
                .allowsHitTesting(false)
            )
        }
    }

    private func handleConnectInCurrentWindow(to host: HostProfile) {
        selectedHostId = host.id
        onConnectToHost(host)
        dismiss()
    }

    private func handleSwitchToExistingWindow(to host: HostProfile) {
        if let existingScene = MultiWindowManager.shared.findScene(for: host.id) {
            QuickActionManager.shared.activateScene(existingScene, hostId: host.id)
            dismiss()
        }
    }

    private func deleteHosts(at offsets: IndexSet) {
        let targets = Set(offsets.map { hosts[$0].id })
        if let onDeleteHosts = onDeleteHosts {
            onDeleteHosts(targets)
        } else {
            for index in offsets {
                let host = hosts[index]
                KeychainService.deletePassword(forHostId: host.id)
                if selectedHostId == host.id {
                    selectedHostId = nil
                }
            }
            hosts.remove(atOffsets: offsets)
        }
    }

    private func deleteFilteredHosts(at offsets: IndexSet) {
        let targets = offsets.map { filteredHosts[$0] }
        if let onDeleteHosts = onDeleteHosts {
            onDeleteHosts(Set(targets.map(\.id)))
        } else {
            for target in targets {
                deleteHost(target)
            }
        }
    }

    private func deleteHost(_ host: HostProfile) {
        if let onDeleteHosts = onDeleteHosts {
            onDeleteHosts([host.id])
        } else if let idx = hosts.firstIndex(where: { $0.id == host.id }) {
            deleteHosts(at: IndexSet(integer: idx))
        }
    }

    private func duplicateHost(_ host: HostProfile) {
        let clone = host.duplicated()
        if let idx = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts.insert(clone, at: idx + 1)
        } else {
            hosts.append(clone)
        }
    }

    public enum RowTapAction: Equatable {
        case switchToOtherWindow(scene: UIWindowScene)
        case dismissAndFocusTerminal
        case ignoreBusy
        case connectInCurrentWindow(host: HostProfile)
    }

    public static func resolveRowTapAction(
        for host: HostProfile,
        selectedHostId: UUID?,
        effectiveWindowScene: UIWindowScene?,
        sessionManager: SessionManager?,
        windowManager: MultiWindowManager = .shared
    ) -> RowTapAction {
        let otherScene: UIWindowScene? = {
            guard UIApplication.shared.supportsMultipleScenes else { return nil }
            if let scene = windowManager.findScene(for: host.id) {
                if let current = effectiveWindowScene {
                    return scene != current ? scene : nil
                }
                return scene
            }
            return nil
        }()

        if let otherScene = otherScene {
            return .switchToOtherWindow(scene: otherScene)
        }

        let isCurrentWindow: Bool = {
            if host.id == selectedHostId { return true }
            if let currentScene = effectiveWindowScene,
               let sceneHost = windowManager.findScene(for: host.id),
               sceneHost == currentScene {
                return true
            }
            return false
        }()

        if isCurrentWindow {
            let currentConnState: ConnectionState = sessionManager?.state ?? windowManager.snapshots[host.id]?.connectionState ?? .disconnected
            switch currentConnState {
            case .connected:
                return .dismissAndFocusTerminal
            case .connecting, .reconnecting:
                return .ignoreBusy
            case .disconnected, .failed:
                return .connectInCurrentWindow(host: host)
            }
        }

        return .connectInCurrentWindow(host: host)
    }

    public static func makeHostItemProvider(for host: HostProfile, isAlreadyOpen: Bool) -> NSItemProvider {
        guard !isAlreadyOpen else {
            return NSItemProvider()
        }
        let activity = NSUserActivity(activityType: QuickActionManager.connectHostActionType)
        activity.targetContentIdentifier = QuickActionManager.targetContentIdentifier(for: host.id)
        activity.userInfo = [QuickActionManager.hostIdUserInfoKey: host.id.uuidString]
        activity.title = host.displayName
        return NSItemProvider(object: activity)
    }

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    static var buildNumber: String {
        formatBuildNumber(Bundle.main.infoDictionary?["CFBundleVersion"] as? String)
    }

    static func formatBuildNumber(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "" }
        var parts = raw.components(separatedBy: ".")
        guard parts.count >= 2 else { return raw }
        let middle = parts[1]
        if middle.count < 4, !middle.isEmpty, middle.allSatisfy(\.isNumber) {
            parts[1] = String(repeating: "0", count: 4 - middle.count) + middle
        }
        return parts.joined(separator: ".")
    }

    static var commitHash: String {
        resolveCommitHash(
            gitCommit: Bundle.main.infoDictionary?["GitCommit"] as? String,
            buildNumber: Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        )
    }

    static func resolveCommitHash(gitCommit: String?, buildNumber: String?) -> String {
        let raw = gitCommit ?? ""
        if !raw.isEmpty && !raw.contains("$") {
            return raw
        }
        if let segments = buildNumber?.split(separator: "."),
           segments.count >= 3,
           let dec = Int(segments[2]),
           dec >= 0 {
            return String(format: "%04x", dec)
        }
        return "local"
    }
}

public struct CompanionToolGuideView: View {
    @State private var copiedCommand: String? = nil

    public static let cargoCommand = "cargo install --git https://github.com/JeremyOT/filaire fil"
    public static let sourceCommand = "git clone https://github.com/JeremyOT/filaire.git\ncargo build --release --manifest-path filaire/tools/fil/Cargo.toml\nsudo cp filaire/tools/fil/target/release/fil /usr/local/bin/"

    public init() {}

    public var body: some View {
        List {
            Section(
                header: Text("About the fil Companion CLI"),
                footer: Text("The fil CLI runs on your remote servers inside or outside tmux. It communicates directly with Filaire via standard ANSI escape sequences without requiring open inbound ports or background daemons.")
            ) {
                Text("Provides native Apple Quick Look file previews, remote URL opening in Safari, bi-directional clipboard sync, forwarded biometric SSH Agent management, and push notifications.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section(header: Text("Quick Install (Cargo)")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(Self.cargoCommand)
                        .font(.system(size: 12, design: .monospaced))
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(uiColor: SolarizedDarkTheme.base02))
                        .foregroundStyle(Color(uiColor: SolarizedDarkTheme.base1))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .textSelection(.enabled)

                    Button {
                        UIPasteboard.general.string = Self.cargoCommand
                        copiedCommand = "cargo"
                        let generator = UINotificationFeedbackGenerator()
                        generator.notificationOccurred(.success)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            if copiedCommand == "cargo" { copiedCommand = nil }
                        }
                    } label: {
                        Label(copiedCommand == "cargo" ? "Copied to Clipboard!" : "Copy Cargo Install Command",
                              systemImage: copiedCommand == "cargo" ? "checkmark" : "doc.on.doc")
                            .font(.caption.bold())
                            .foregroundStyle(Color(uiColor: SolarizedDarkTheme.cyan))
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.vertical, 4)
            }

            Section(header: Text("Build from Source")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(Self.sourceCommand)
                        .font(.system(size: 11, design: .monospaced))
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(uiColor: SolarizedDarkTheme.base02))
                        .foregroundStyle(Color(uiColor: SolarizedDarkTheme.base1))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .textSelection(.enabled)

                    Button {
                        UIPasteboard.general.string = Self.sourceCommand
                        copiedCommand = "source"
                        let generator = UINotificationFeedbackGenerator()
                        generator.notificationOccurred(.success)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            if copiedCommand == "source" { copiedCommand = nil }
                        }
                    } label: {
                        Label(copiedCommand == "source" ? "Copied to Clipboard!" : "Copy Build Commands",
                              systemImage: copiedCommand == "source" ? "checkmark" : "doc.on.doc")
                            .font(.caption.bold())
                            .foregroundStyle(Color(uiColor: SolarizedDarkTheme.cyan))
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.vertical, 4)
            }

            Section(header: Text("Key Commands")) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("eval $(fil agent)")
                        .font(.system(.subheadline, design: .monospaced).bold())
                        .foregroundStyle(Color(uiColor: SolarizedDarkTheme.cyan))
                    Text("Bridge forwarded iOS biometric SSH Agent (Face ID / Touch ID on sign).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)

                VStack(alignment: .leading, spacing: 4) {
                    Text("fil copy <file or text>")
                        .font(.system(.subheadline, design: .monospaced).bold())
                        .foregroundStyle(Color(uiColor: SolarizedDarkTheme.cyan))
                    Text("Copy text or file contents directly to your iOS clipboard.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)

                VStack(alignment: .leading, spacing: 4) {
                    Text("fil open <url>")
                        .font(.system(.subheadline, design: .monospaced).bold())
                        .foregroundStyle(Color(uiColor: SolarizedDarkTheme.cyan))
                    Text("Open URLs immediately in Safari on your iPad/iPhone.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)

                VStack(alignment: .leading, spacing: 4) {
                    Text("fil preview <file>")
                        .font(.system(.subheadline, design: .monospaced).bold())
                        .foregroundStyle(Color(uiColor: SolarizedDarkTheme.cyan))
                    Text("Preview documents, images, PDFs, media, and archives with Apple Quick Look.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)

                VStack(alignment: .leading, spacing: 4) {
                    Text("fil notify <title> [body]")
                        .font(.system(.subheadline, design: .monospaced).bold())
                        .foregroundStyle(Color(uiColor: SolarizedDarkTheme.cyan))
                    Text("Send in-app HUD toast banners and iOS push notifications.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }

            Section(header: Text("Online Documentation")) {
                Link(destination: URL(string: "https://github.com/JeremyOT/filaire")!) {
                    HStack {
                        Label("Filaire Repository & Documentation", systemImage: "safari")
                            .foregroundStyle(Color(uiColor: SolarizedDarkTheme.cyan))
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("fil Companion Tool")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private extension View {
    @ViewBuilder
    func conditionalDrag(for host: HostProfile, isAlreadyOpen: Bool, selectedHostId: UUID?) -> some View {
        if isAlreadyOpen {
            self
        } else {
            self.onDrag {
                guard host.id != selectedHostId && !MultiWindowManager.shared.isHostOpenAnywhere(host.id) else {
                    return NSItemProvider()
                }
                return HostListView.makeHostItemProvider(for: host, isAlreadyOpen: false)
            }
        }
    }
}

