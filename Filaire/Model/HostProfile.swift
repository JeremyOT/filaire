import Foundation

public enum AuthMethodType: String, Codable, CaseIterable, Identifiable {
    case sshKey = "SSH Key"
    case password = "Password"

    public var id: String { rawValue }
}

public enum PortForwardType: String, Codable, CaseIterable {
    case local
    case dynamic
}

public enum RemoteUrlOpeningPolicy: String, Codable, CaseIterable, Identifiable {
    case denyUnusualSchemes
    case promptAlways
    case promptUnusualSchemes

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .denyUnusualSchemes:
            return "Deny Unusual Schemes"
        case .promptAlways:
            return "Prompt Always"
        case .promptUnusualSchemes:
            return "Prompt Unusual Schemes"
        }
    }

    public var description: String {
        switch self {
        case .denyUnusualSchemes:
            return "Prompts for http/https URLs. Blocks all other schemes."
        case .promptAlways:
            return "Prompts before opening any remote URL."
        case .promptUnusualSchemes:
            return "Automatically allows http/https URLs. Prompts for other schemes."
        }
    }
}

public enum RemoteUrlAction: Equatable {
    case openImmediately
    case promptUser
    case deny
}

public extension RemoteUrlOpeningPolicy {
    func action(for url: URL) -> RemoteUrlAction {
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else {
            return .deny
        }
        let isStandardWebScheme = (scheme == "http" || scheme == "https")
        switch self {
        case .denyUnusualSchemes:
            return isStandardWebScheme ? .promptUser : .deny
        case .promptAlways:
            return .promptUser
        case .promptUnusualSchemes:
            return isStandardWebScheme ? .openImmediately : .promptUser
        }
    }
}

public struct PortForwardRule: Identifiable, Codable, Equatable {
    public static let validPortRange = 1...65535
    public static let defaultPort = 8080

    public var id: UUID
    public var name: String
    public var localPort: Int
    public var remoteHost: String
    public var remotePort: Int
    public var isEnabled: Bool
    public var ruleType: PortForwardType

    public init(
        id: UUID = UUID(),
        name: String = "",
        localPort: Int = 8080,
        remoteHost: String = "localhost",
        remotePort: Int = 8080,
        isEnabled: Bool = true,
        ruleType: PortForwardType = .local
    ) {
        self.id = id
        self.localPort = Self.validPortRange.contains(localPort) ? localPort : Self.defaultPort
        self.remoteHost = remoteHost
        self.remotePort = (ruleType == .dynamic && remotePort == 0) ? 0 : (Self.validPortRange.contains(remotePort) ? remotePort : Self.defaultPort)
        self.isEnabled = isEnabled
        self.ruleType = ruleType
        if !name.isEmpty {
            self.name = name
        } else if ruleType == .dynamic {
            self.name = "127.0.0.1:\(self.localPort) (SOCKS5 Proxy)"
        } else {
            self.name = "\(self.localPort) → \(remoteHost):\(self.remotePort)"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, name, localPort, remoteHost, remotePort, isEnabled, ruleType
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        let rawLocal = try container.decode(Int.self, forKey: .localPort)
        self.localPort = Self.validPortRange.contains(rawLocal) ? rawLocal : Self.defaultPort
        self.remoteHost = try container.decodeIfPresent(String.self, forKey: .remoteHost) ?? "localhost"
        let decodedRuleType = try container.decodeIfPresent(PortForwardType.self, forKey: .ruleType) ?? .local
        self.ruleType = decodedRuleType
        let rawRemote = try container.decodeIfPresent(Int.self, forKey: .remotePort) ?? Self.defaultPort
        self.remotePort = (decodedRuleType == .dynamic && rawRemote == 0) ? 0 : (Self.validPortRange.contains(rawRemote) ? rawRemote : Self.defaultPort)
        self.isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
    }
}

public struct HostProfile: Identifiable, Codable, Equatable {
    public static let validPortRange = 1...65535
    public static let defaultPort = 22

    public var id: UUID
    public var name: String
    public var hostname: String
    public var port: Int
    public var username: String
    public var authMethod: AuthMethodType
    public var selectedKeyId: UUID?
    public var customTmuxSession: String?
    public var autoConnect: Bool
    public var autoConnectTmux: Bool
    public var tmuxPrefix: String
    public var detachExistingTmux: Bool
    public var enableTmuxSetClipboard: Bool
    public var connectionCommand: String?
    public var requireBiometrics: Bool
    public var keepAliveInterval: TimeInterval
    public var jumpHostId: UUID?
    public var portForwards: [PortForwardRule]
    public var lastConnected: Date?
    public var enableAgentForwarding: Bool
    public var agentForwardingKeyIds: [UUID]?
    public var allowClipboardRead: Bool
    public var allowClipboardWrite: Bool
    public var allowLegacyAlgorithms: Bool
    public var urlOpeningPolicy: RemoteUrlOpeningPolicy
    public var allowFilePreview: Bool
    public var allowRemoteNotifications: Bool

    public init(
        id: UUID = UUID(),
        name: String = "",
        hostname: String = "",
        port: Int = 22,
        username: String = "",
        authMethod: AuthMethodType = .sshKey,
        selectedKeyId: UUID? = nil,
        customTmuxSession: String? = nil,
        autoConnect: Bool = true,
        autoConnectTmux: Bool = true,
        tmuxPrefix: String = "ctrl-b",
        detachExistingTmux: Bool = false,
        connectionCommand: String? = nil,
        requireBiometrics: Bool = true,
        keepAliveInterval: TimeInterval = 15,
        jumpHostId: UUID? = nil,
        portForwards: [PortForwardRule] = [],
        lastConnected: Date? = nil,
        enableAgentForwarding: Bool = false,
        agentForwardingKeyIds: [UUID]? = nil,
        allowClipboardRead: Bool = false,
        allowClipboardWrite: Bool = true,
        allowLegacyAlgorithms: Bool = false,
        urlOpeningPolicy: RemoteUrlOpeningPolicy = .denyUnusualSchemes,
        enableTmuxSetClipboard: Bool = false,
        allowFilePreview: Bool = true,
        allowRemoteNotifications: Bool = true
    ) {
        self.id = id
        self.name = name.isEmpty ? (hostname.isEmpty ? "New Server" : hostname) : name
        self.hostname = hostname
        self.port = Self.validPortRange.contains(port) ? port : Self.defaultPort
        self.username = username
        self.authMethod = authMethod
        self.selectedKeyId = selectedKeyId
        self.customTmuxSession = customTmuxSession
        self.autoConnect = autoConnect
        self.autoConnectTmux = autoConnectTmux
        self.tmuxPrefix = tmuxPrefix
        self.detachExistingTmux = detachExistingTmux
        self.enableTmuxSetClipboard = enableTmuxSetClipboard
        self.connectionCommand = connectionCommand
        self.requireBiometrics = requireBiometrics
        self.keepAliveInterval = keepAliveInterval
        self.jumpHostId = jumpHostId
        self.portForwards = portForwards
        self.lastConnected = lastConnected
        self.enableAgentForwarding = enableAgentForwarding
        self.agentForwardingKeyIds = agentForwardingKeyIds
        self.allowClipboardRead = allowClipboardRead
        self.allowClipboardWrite = allowClipboardWrite
        self.allowLegacyAlgorithms = allowLegacyAlgorithms
        self.urlOpeningPolicy = urlOpeningPolicy
        self.allowFilePreview = allowFilePreview
        self.allowRemoteNotifications = allowRemoteNotifications
    }

    enum CodingKeys: String, CodingKey {
        case id, name, hostname, port, username, authMethod, selectedKeyId, customTmuxSession, autoConnect, autoConnectTmux, tmuxPrefix, detachExistingTmux, connectionCommand, requireBiometrics, keepAliveInterval, jumpHostId, portForwards, lastConnected, enableAgentForwarding, agentForwardingKeyIds, allowClipboardRead, allowClipboardWrite, allowLegacyAlgorithms, urlOpeningPolicy, enableTmuxSetClipboard, allowFilePreview, allowRemoteNotifications
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.hostname = try container.decode(String.self, forKey: .hostname)
        let rawPort = try container.decode(Int.self, forKey: .port)
        self.port = Self.validPortRange.contains(rawPort) ? rawPort : Self.defaultPort
        self.username = try container.decode(String.self, forKey: .username)
        self.authMethod = try container.decode(AuthMethodType.self, forKey: .authMethod)
        self.selectedKeyId = try container.decodeIfPresent(UUID.self, forKey: .selectedKeyId)
        self.customTmuxSession = try container.decodeIfPresent(String.self, forKey: .customTmuxSession)
        self.autoConnect = try container.decodeIfPresent(Bool.self, forKey: .autoConnect) ?? true
        self.autoConnectTmux = try container.decodeIfPresent(Bool.self, forKey: .autoConnectTmux) ?? true
        self.tmuxPrefix = try container.decodeIfPresent(String.self, forKey: .tmuxPrefix) ?? "ctrl-b"
        self.detachExistingTmux = try container.decodeIfPresent(Bool.self, forKey: .detachExistingTmux) ?? false
        self.connectionCommand = try container.decodeIfPresent(String.self, forKey: .connectionCommand)
        self.requireBiometrics = try container.decodeIfPresent(Bool.self, forKey: .requireBiometrics) ?? true
        self.keepAliveInterval = try container.decodeIfPresent(TimeInterval.self, forKey: .keepAliveInterval) ?? 15
        self.jumpHostId = try container.decodeIfPresent(UUID.self, forKey: .jumpHostId)
        self.portForwards = try container.decodeIfPresent([PortForwardRule].self, forKey: .portForwards) ?? []
        self.lastConnected = try container.decodeIfPresent(Date.self, forKey: .lastConnected)
        self.enableAgentForwarding = try container.decodeIfPresent(Bool.self, forKey: .enableAgentForwarding) ?? false
        self.agentForwardingKeyIds = try container.decodeIfPresent([UUID].self, forKey: .agentForwardingKeyIds)
        self.allowClipboardRead = try container.decodeIfPresent(Bool.self, forKey: .allowClipboardRead) ?? false
        self.allowClipboardWrite = try container.decodeIfPresent(Bool.self, forKey: .allowClipboardWrite) ?? true
        self.allowLegacyAlgorithms = try container.decodeIfPresent(Bool.self, forKey: .allowLegacyAlgorithms) ?? false
        self.urlOpeningPolicy = try container.decodeIfPresent(RemoteUrlOpeningPolicy.self, forKey: .urlOpeningPolicy) ?? .denyUnusualSchemes
        self.enableTmuxSetClipboard = try container.decodeIfPresent(Bool.self, forKey: .enableTmuxSetClipboard) ?? false
        self.allowFilePreview = try container.decodeIfPresent(Bool.self, forKey: .allowFilePreview) ?? true
        self.allowRemoteNotifications = try container.decodeIfPresent(Bool.self, forKey: .allowRemoteNotifications) ?? true
    }

    /// Returns the single ASCII control byte for the configured tmux prefix (e.g. 0x02 for Ctrl-B, 0x1A for Ctrl-Z).
    /// Defaults to Ctrl-B (0x02).
    public var tmuxPrefixByte: UInt8 {
        let cleaned = tmuxPrefix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let letter: Character?
        if cleaned.hasPrefix("ctrl-") || cleaned.hasPrefix("ctrl+") {
            letter = cleaned.dropFirst(5).first
        } else if cleaned.hasPrefix("c-") || cleaned.hasPrefix("c+") {
            letter = cleaned.dropFirst(2).first
        } else if cleaned.hasPrefix("^") {
            letter = cleaned.dropFirst(1).first
        } else if cleaned.count == 1 {
            letter = cleaned.first
        } else {
            letter = cleaned.last
        }

        if let letter = letter, let ascii = letter.asciiValue {
            if ascii >= 97 && ascii <= 122 { // 'a'...'z'
                return ascii - 96
            } else if ascii >= 65 && ascii <= 90 { // 'A'...'Z'
                return ascii - 64
            }
        }
        return 0x02 // Default to Ctrl-B
    }

    /// Formatted display string for the tmux prefix (e.g. "Ctrl-B", "Ctrl-Z")
    public var tmuxPrefixDisplay: String {
        let byte = tmuxPrefixByte
        if byte >= 1 && byte <= 26 {
            let char = Character(UnicodeScalar(64 + byte))
            return "Ctrl-\(char)"
        }
        return "Ctrl-B"
    }

    /// Returns the tmux session name to attach to or create.
    /// Defaults to the username as requested ("always use the username as the session name").
    public var effectiveTmuxSession: String {
        if let custom = customTmuxSession, !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return custom.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedUser.isEmpty ? "filaire" : trimmedUser
    }

    /// Quotes a string for safe POSIX shell execution if it contains spaces or metacharacters
    public static func shellQuoteIfNeeded(_ string: String) -> String {
        let safeChars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
        if string.unicodeScalars.allSatisfy({ safeChars.contains($0) }) && !string.isEmpty {
            return string
        }
        return "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Shell startup command to attach or create the tmux session
    public var tmuxStartupCommand: String {
        let quotedSession = Self.shellQuoteIfNeeded(effectiveTmuxSession)
        // set-clipboard lets any program inside tmux write the iOS clipboard, so it is opt-in
        let setClipboard = enableTmuxSetClipboard ? "tmux set -s set-clipboard on 2>/dev/null; " : ""
        // Binds the escape sequences sent for Cmd+D / Cmd+Shift+D to splits in the current pane's directory,
        // and Cmd+J / Cmd+Shift+J to join the marked pane vertically or horizontally.
        // Chained after new-session so a tmux that rejects them still attaches.
        let splitBindings = " \\; set -s 'user-keys[900]' \"$(printf '\\033[9990~')\" \\; set -s 'user-keys[901]' \"$(printf '\\033[9991~')\" \\; set -s 'user-keys[902]' \"$(printf '\\033[9992~')\" \\; set -s 'user-keys[903]' \"$(printf '\\033[9993~')\" \\; bind -n User900 split-window -h -c '#{pane_current_path}' \\; bind -n User901 split-window -v -c '#{pane_current_path}' \\; bind -n User902 join-pane -h \\; bind -n User903 join-pane -v"
        if detachExistingTmux {
            return "\(setClipboard)exec tmux new-session -A -D -s \(quotedSession)\(splitBindings)\n"
        } else {
            return "\(setClipboard)exec tmux new-session -A -s \(quotedSession)\(splitBindings)\n"
        }
    }

    /// Startup command to send upon SSH channel establishment.
    /// When autoConnectTmux is true: attaches to or creates the tmux session.
    /// When false: executes the optional custom command if specified.
    public var startupCommand: String? {
        if autoConnectTmux {
            return tmuxStartupCommand
        }
        if let custom = connectionCommand?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            return custom.hasSuffix("\n") ? custom : "\(custom)\n"
        }
        return nil
    }

    public var displayName: String {
        if !name.isEmpty && name != "New Server" {
            return name
        }
        if !hostname.isEmpty {
            return username.isEmpty ? hostname : "\(username)@\(hostname)"
        }
        return "Unnamed Host"
    }

    /// Creates an independent clone of the host profile with a unique UUID,
    /// refreshed port forwarding rule IDs, cleared lastConnected state, and an appended name suffix.
    public func duplicated(nameSuffix: String = " (Copy)") -> HostProfile {
        var copy = self
        copy.id = UUID()
        copy.name = "\(self.displayName)\(nameSuffix)"
        copy.lastConnected = nil
        copy.portForwards = self.portForwards.map { rule in
            var r = rule
            r.id = UUID()
            return r
        }
        return copy
    }
}
