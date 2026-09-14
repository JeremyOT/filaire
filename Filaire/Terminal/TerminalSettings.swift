import Foundation
import UIKit

public extension Notification.Name {
    static let terminalSettingsChanged = Notification.Name("io.o-t.filaire.terminalSettingsChanged")
    static let openSettingsRequested = Notification.Name("io.o-t.filaire.openSettingsRequested")
    static let connectHostRequested = Notification.Name("io.o-t.filaire.connectHostRequested")
    static let hostsDidChange = Notification.Name("io.o-t.filaire.hostsDidChange")
    static let keysDidChange = Notification.Name("io.o-t.filaire.keysDidChange")
    static let openNewWindowRequested = Notification.Name("io.o-t.filaire.openNewWindowRequested")
    static let closeCurrentWindowRequested = Notification.Name("io.o-t.filaire.closeCurrentWindowRequested")
}

public enum ScrollbackLimit: Int, CaseIterable, Identifiable, Codable {
    case small = 2500
    case standard = 10000
    case large = 25000
    case maximum = 50000

    public var id: Int { rawValue }

    public var displayName: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let formatted = formatter.string(from: NSNumber(value: rawValue)) ?? "\(rawValue)"
        return "\(formatted) lines"
    }
}

public enum BellStyle: String, CaseIterable, Identifiable, Codable {
    case visualAndHaptic = "Visual Flash & Haptic"
    case visualOnly = "Visual Flash Only"
    case hapticOnly = "Haptic Only"
    case disabled = "Disabled"

    public var id: String { rawValue }
}

public final class TerminalSettings {
    public static let shared = TerminalSettings()
    private let scrollbackKey = "io.o-t.filaire.scrollback_limit"
    private let showAccessoryBarKey = "io.o-t.filaire.show_keyboard_accessory_bar"
    private let bellStyleKey = "io.o-t.filaire.bell_style"

    public var bellStyle: BellStyle {
        get {
            guard let raw = UserDefaults.standard.string(forKey: bellStyleKey),
                  let style = BellStyle(rawValue: raw) else {
                return .visualAndHaptic
            }
            return style
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: bellStyleKey)
            NotificationCenter.default.post(name: .terminalSettingsChanged, object: nil)
        }
    }

    public var scrollbackLimit: ScrollbackLimit {
        get {
            let saved = UserDefaults.standard.integer(forKey: scrollbackKey)
            return ScrollbackLimit(rawValue: saved) ?? .standard
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: scrollbackKey)
            NotificationCenter.default.post(name: .terminalSettingsChanged, object: nil)
        }
    }

    /// Whether to display the bottom helper toolbar above the keyboard.
    /// Defaults to true on iPhone (where thumb modifiers are essential)
    /// and false on iPad (where hardware/Magic Keyboards are commonly attached).
    public var showKeyboardAccessoryBar: Bool {
        get {
            if let saved = UserDefaults.standard.object(forKey: showAccessoryBarKey) as? Bool {
                return saved
            }
            return UIDevice.current.userInterfaceIdiom == .phone
        }
        set {
            UserDefaults.standard.set(newValue, forKey: showAccessoryBarKey)
            NotificationCenter.default.post(name: .terminalSettingsChanged, object: nil)
        }
    }

    private let aggressiveBackgroundTrimmingKey = "io.o-t.filaire.aggressive_background_trimming"

    /// When enabled, backgrounded sessions aggressively shed scrollback lines beyond 1,000 lines.
    /// Disabled by default to preserve terminal history during ordinary background transitions.
    public var aggressiveBackgroundTrimmingEnabled: Bool {
        get {
            UserDefaults.standard.bool(forKey: aggressiveBackgroundTrimmingKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: aggressiveBackgroundTrimmingKey)
            NotificationCenter.default.post(name: .terminalSettingsChanged, object: nil)
        }
    }

    public init() {}
}
