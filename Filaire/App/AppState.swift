import SwiftUI
import Combine

@MainActor
@Observable
public final class AppState {
    public static let savedHostsKey = "io.o-t.filaire.saved_hosts"

    public static func loadSavedHosts() -> [HostProfile] {
        let hostsData = UserDefaults.standard.data(forKey: savedHostsKey)
        if let data = hostsData,
           let decoded = try? JSONDecoder().decode([HostProfile].self, from: data) {
            return decoded
        }
        return []
    }

    public static let activeHostKey = "io.o-t.filaire.active_host_id"

    private let hostsKey = AppState.savedHostsKey
    private let keysKey = "io.o-t.filaire.saved_keys"
    private let activeHostKey = AppState.activeHostKey

    private var isReloadingFromDisk = false

    public var hosts: [HostProfile] = [] {
        didSet {
            syncSessionHosts()
            guard !isReloadingFromDisk else { return }
            saveHosts()
            QuickActionManager.updateQuickActions(for: hosts)
            NotificationCenter.default.post(name: .hostsDidChange, object: self)
        }
    }

    public var keys: [SSHKeyModel] = [] {
        didSet {
            if sessionManager.availableKeys != keys {
                sessionManager.availableKeys = keys
            }
            guard !isReloadingFromDisk else { return }
            saveKeys()
            NotificationCenter.default.post(name: .keysDidChange, object: self)
        }
    }

    public var selectedHostId: UUID? = nil {
        didSet {
            dynamicTerminalTitle = nil
            if let id = selectedHostId {
                UserDefaults.standard.set(id.uuidString, forKey: activeHostKey)
            } else {
                UserDefaults.standard.removeObject(forKey: activeHostKey)
            }
        }
    }

    public private(set) var sessionManager = SessionManager()
    public var isStatusExpanded: Bool = false

    public var dynamicTerminalTitle: String? = nil
    private var delayedConnectTask: Task<Void, Never>? = nil

    public func scheduleDelayedConnect(to host: HostProfile, delay: TimeInterval = 0.3) {
        delayedConnectTask?.cancel()
        delayedConnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self = self else { return }
            self.connect(to: host, force: true)
        }
    }

    public func cancelPendingDelayedConnect() {
        delayedConnectTask?.cancel()
        delayedConnectTask = nil
    }

    public var selectedHost: HostProfile? {
        if let id = selectedHostId, let host = hosts.first(where: { $0.id == id }) {
            return host
        }
        return nil
    }

    /// Dynamic window title matching the active host, tmux session name, and terminal process/title.
    /// Used by UIWindowScene.title so open windows are clearly named in iPadOS
    /// "Show All Windows", Stage Manager, App Switcher, and Home Screen icon menus.
    public var windowTitle: String {
        let base: String = {
            guard let host = selectedHost else {
                return "Filaire"
            }
            let hostName = host.displayName
            if host.autoConnectTmux {
                let session = host.effectiveTmuxSession
                if !session.isEmpty {
                    return "\(hostName) (\(session))"
                }
            }
            return hostName
        }()

        if let termTitle = dynamicTerminalTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !termTitle.isEmpty {
            return "\(base): \(termTitle)"
        }
        return base
    }

    private nonisolated(unsafe) var hostsObserver: (any NSObjectProtocol)?
    private nonisolated(unsafe) var keysObserver: (any NSObjectProtocol)?

    deinit {
        if let hostsObserver = hostsObserver {
            NotificationCenter.default.removeObserver(hostsObserver)
        }
        if let keysObserver = keysObserver {
            NotificationCenter.default.removeObserver(keysObserver)
        }
    }

    public init(initialHostId: UUID? = nil) {
        isReloadingFromDisk = true
        loadData()
        isReloadingFromDisk = false
        if let initialHostId = initialHostId {
            self.selectedHostId = initialHostId
        }
        QuickActionManager.updateQuickActions(for: hosts)
        setupCrossWindowSync()
        SnippetStore.shared.load()

        sessionManager.onKeyMigrated = { [weak self] keyId, keyType, pubKey in
            guard let self = self else { return }
            if let index = self.keys.firstIndex(where: { $0.id == keyId }) {
                self.keys[index].keyType = keyType
                self.keys[index].publicKey = pubKey
                self.saveKeys()
            }
        }

        sessionManager.onTerminalTitleChanged = { [weak self] title in
            self?.dynamicTerminalTitle = title.isEmpty ? nil : title
        }

        sessionManager.onDisconnect = { [weak self] in
            self?.dynamicTerminalTitle = nil
        }
    }

    public func bindSessionManager(_ newManager: SessionManager) {
        guard self.sessionManager !== newManager else { return }
        self.sessionManager = newManager
        self.dynamicTerminalTitle = nil
        newManager.onKeyMigrated = { [weak self] keyId, keyType, pubKey in
            guard let self = self else { return }
            if let index = self.keys.firstIndex(where: { $0.id == keyId }) {
                self.keys[index].keyType = keyType
                self.keys[index].publicKey = pubKey
                self.saveKeys()
            }
        }
        newManager.onTerminalTitleChanged = { [weak self] title in
            self?.dynamicTerminalTitle = title.isEmpty ? nil : title
        }
        newManager.onDisconnect = { [weak self] in
            self?.dynamicTerminalTitle = nil
        }
    }

    private func setupCrossWindowSync() {
        hostsObserver = NotificationCenter.default.addObserver(
            forName: .hostsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self, (note.object as AnyObject?) !== self else { return }
            MainActor.assumeIsolated {
                self.reloadHosts()
            }
        }

        keysObserver = NotificationCenter.default.addObserver(
            forName: .keysDidChange,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self, (note.object as AnyObject?) !== self else { return }
            MainActor.assumeIsolated {
                self.reloadKeys()
            }
        }
    }

    public func reloadHosts() {
        isReloadingFromDisk = true
        defer { isReloadingFromDisk = false }
        let hostsData = UserDefaults.standard.data(forKey: hostsKey)
        if let data = hostsData,
           let decoded = try? JSONDecoder().decode([HostProfile].self, from: data) {
            let previousIds = Set(self.hosts.map(\.id))
            let newIds = Set(decoded.map(\.id))
            let deletedIds = previousIds.subtracting(newIds)

            self.hosts = decoded

            if !deletedIds.isEmpty {
                MultiWindowManager.shared.invalidateAndCleanup(deletedHostIds: deletedIds)
                reconcileHostRemoval(deletedHostIds: deletedIds)
            } else if let id = selectedHostId, !decoded.contains(where: { $0.id == id }) {
                reconcileHostRemoval(deletedHostIds: [id])
            }
        }
    }

    public func deleteHost(id: UUID) {
        deleteHosts(ids: [id])
    }

    public func deleteHosts(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }

        // Synchronously invalidate and cleanup across all window records
        MultiWindowManager.shared.invalidateAndCleanup(deletedHostIds: ids)

        for id in ids {
            KeychainService.deletePassword(forHostId: id)
        }

        cancelPendingDelayedConnect()

        // Reconcile local state synchronously
        reconcileHostRemoval(deletedHostIds: ids)

        // Remove from hosts array
        self.hosts.removeAll(where: { ids.contains($0.id) })
    }

    internal func reconcileHostRemoval(deletedHostIds: Set<UUID>) {
        cancelPendingDelayedConnect()

        if let selected = selectedHostId, deletedHostIds.contains(selected) {
            self.selectedHostId = nil
            self.dynamicTerminalTitle = nil
        }

        let localSm = self.sessionManager
        let isLocalSmAffected = (localSm.activeHost.map { deletedHostIds.contains($0.id) } ?? false)
            || (localSm.lastConnectedHostId.map { deletedHostIds.contains($0) } ?? false)
            || (selectedHostId == nil && localSm.activeHost != nil && deletedHostIds.contains(localSm.activeHost!.id))

        if isLocalSmAffected {
            localSm.cancelReconnect()
            localSm.connectTask?.cancel()
            localSm.connectTask = nil
            localSm.isConnecting = false
            localSm.cancelPendingSecurityPrompt()
            localSm.disconnect(clearActiveHost: true, isUserInitiated: false, reason: .hostDeleted)
            self.dynamicTerminalTitle = nil
        }
    }

    public func reloadKeys() {
        isReloadingFromDisk = true
        defer { isReloadingFromDisk = false }
        let keysData = UserDefaults.standard.data(forKey: keysKey)
        if let data = keysData,
           let decoded = try? JSONDecoder().decode([SSHKeyModel].self, from: data) {
            self.keys = decoded
        }
    }

    private func loadData() {
        let hostsData = UserDefaults.standard.data(forKey: hostsKey)
        if let data = hostsData,
           let decoded = try? JSONDecoder().decode([HostProfile].self, from: data) {
            self.hosts = decoded
        }

        let keysData = UserDefaults.standard.data(forKey: keysKey)
        if let data = keysData,
           let decoded = try? JSONDecoder().decode([SSHKeyModel].self, from: data) {
            self.keys = decoded
        }

        migrateLegacyKeysIfNeeded()

        if UIDevice.current.userInterfaceIdiom != .pad || !UIApplication.shared.supportsMultipleScenes {
            let activeHostString = UserDefaults.standard.string(forKey: activeHostKey)
            if let idString = activeHostString,
               let uuid = UUID(uuidString: idString),
               hosts.contains(where: { $0.id == uuid }) {
                self.selectedHostId = uuid
            } else {
                self.selectedHostId = hosts.first?.id
            }
        }
    }

    private func saveHosts() {
        if let data = try? JSONEncoder().encode(hosts) {
            UserDefaults.standard.set(data, forKey: hostsKey)
        }
    }

    private func saveKeys() {
        if let data = try? JSONEncoder().encode(keys) {
            UserDefaults.standard.set(data, forKey: keysKey)
        }
    }

    private func migrateLegacyKeysIfNeeded() {
        var modified = false
        for index in keys.indices {
            if keys[index].publicKey.hasPrefix("(") || keys[index].keyType == "Imported Key" {
                if !keys[index].requiresBiometrics, let privPEM = KeychainService.getPrivateKey(forKeyId: keys[index].id) {
                    if let info = try? SSHKeyGenerator.parseKeyInfo(from: privPEM) {
                        keys[index].publicKey = info.publicKey
                        keys[index].keyType = info.keyType
                        modified = true
                    }
                }
            }
        }
        if modified {
            saveKeys()
        }
    }

    public func autoConnectIfNeeded() {
        guard sessionManager.state == .disconnected else { return }

        var targetHost = selectedHost ?? hosts.first(where: { $0.autoConnect })

        // On platforms with multi-window support, prevent duplicate auto-connections to hosts
        // that already have an open dedicated window. Look for another autoConnect-enabled host.
        if UIApplication.shared.supportsMultipleScenes {
            let isHostOpen: (UUID) -> Bool = { [weak self] hostId in
                MultiWindowManager.shared.isHostOpenAnywhere(hostId, excluding: self?.sessionManager)
            }

            if let current = targetHost, isHostOpen(current.id) {
                // Currently selected host is already open in another window.
                // Choose the first configured host not currently open anywhere with autoConnect == true.
                if let alternative = hosts.first(where: { !isHostOpen($0.id) && $0.autoConnect }) {
                    targetHost = alternative
                } else {
                    // No alternative auto-connectable host. Avoid claiming the already-open host.
                    self.selectedHostId = hosts.first(where: { !isHostOpen($0.id) })?.id
                    return
                }
            } else if targetHost == nil {
                targetHost = hosts.first(where: { !isHostOpen($0.id) && $0.autoConnect })
            }
        }

        guard let host = targetHost, host.autoConnect else { return }
        connect(to: host)
    }

    public func connect(to host: HostProfile, force: Bool = false) {
        guard !QuickActionManager.shared.isHostDeleted(host.id) else { return }
        guard let index = hosts.firstIndex(where: { $0.id == host.id }) else {
            return
        }
        if !force && sessionManager.activeHost?.id == host.id && (sessionManager.state == .connected || sessionManager.state == .connecting) {
            return
        }
        let scene = MultiWindowManager.shared.findScene(for: sessionManager)
        let claim = MultiWindowManager.shared.claimHost(host.id, for: sessionManager, scene: scene)
        if case .alreadyClaimed(let existingScene) = claim {
            if let existingScene = existingScene {
                QuickActionManager.shared.activateScene(existingScene, hostId: host.id)
            }
            return
        }

        self.selectedHostId = host.id
        hosts[index].lastConnected = Date()
        let targetHost = hosts[index]
        sessionManager.connect(to: targetHost, allHosts: self.hosts, allKeys: self.keys)
    }

    public func connect(toHostId id: UUID, force: Bool = false) {
        guard !QuickActionManager.shared.isHostDeleted(id) else { return }
        if let host = hosts.first(where: { $0.id == id }) {
            connect(to: host, force: force)
        }
    }

    /// Keeps the session's copy of host settings current, so reconnects and per-host policies use the latest edits.
    private func syncSessionHosts() {
        if sessionManager.allHosts != hosts {
            sessionManager.allHosts = hosts
        }
        if let activeId = sessionManager.activeHost?.id {
            if let updated = hosts.first(where: { $0.id == activeId }) {
                if updated != sessionManager.activeHost {
                    sessionManager.activeHost = updated
                }
            } else {
                reconcileHostRemoval(deletedHostIds: [activeId])
            }
        }
    }
}
