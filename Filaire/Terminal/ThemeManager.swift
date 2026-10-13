import UIKit
import SwiftUI
import SwiftTerm

public enum TerminalThemeType: String, CaseIterable, Identifiable, Codable {
    case solarizedDark = "Solarized Dark"
    case solarizedLight = "Solarized Light"
    case dracula = "Dracula"
    case nord = "Nord"
    case monokai = "Monokai"

    public var id: String { rawValue }
}

public protocol TerminalTheme {
    var type: TerminalThemeType { get }
    var name: String { get }
    var background: UIColor { get }
    var foreground: UIColor { get }
    var cursor: UIColor { get }
    var selection: UIColor { get }
    var ansiPalette: [SwiftTerm.Color] { get }

    // MARK: - Semantic UI Colors
    var surfaceBackground: UIColor { get }
    var secondarySurface: UIColor { get }
    var tertiarySurface: UIColor { get }
    var separator: UIColor { get }

    var primaryText: UIColor { get }
    var secondaryText: UIColor { get }
    var tertiaryText: UIColor { get }
    var mutedText: UIColor { get }

    var accent: UIColor { get }
    var success: UIColor { get }
    var warning: UIColor { get }
    var error: UIColor { get }
    var info: UIColor { get }
    var altAccent: UIColor { get }
    var badgeAccent: UIColor { get }

    var isLight: Bool { get }
}

public extension TerminalTheme {
    var surfaceBackground: UIColor { background }
    var secondarySurface: UIColor { selection }
    var tertiarySurface: UIColor { background }
    var separator: UIColor { mutedText }

    var primaryText: UIColor { foreground }
    var secondaryText: UIColor { foreground }
    var tertiaryText: UIColor { foreground.withAlphaComponent(0.7) }
    var mutedText: UIColor { foreground.withAlphaComponent(0.5) }

    var accent: UIColor {
        if ansiPalette.count > 6 {
            let c = ansiPalette[6]
            return UIColor(red: CGFloat(c.red) / 255.0, green: CGFloat(c.green) / 255.0, blue: CGFloat(c.blue) / 255.0, alpha: 1.0)
        }
        return foreground
    }

    var success: UIColor {
        if ansiPalette.count > 2 {
            let c = ansiPalette[2]
            return UIColor(red: CGFloat(c.red) / 255.0, green: CGFloat(c.green) / 255.0, blue: CGFloat(c.blue) / 255.0, alpha: 1.0)
        }
        return .systemGreen
    }

    var warning: UIColor {
        if ansiPalette.count > 3 {
            let c = ansiPalette[3]
            return UIColor(red: CGFloat(c.red) / 255.0, green: CGFloat(c.green) / 255.0, blue: CGFloat(c.blue) / 255.0, alpha: 1.0)
        }
        return .systemYellow
    }

    var error: UIColor {
        if ansiPalette.count > 1 {
            let c = ansiPalette[1]
            return UIColor(red: CGFloat(c.red) / 255.0, green: CGFloat(c.green) / 255.0, blue: CGFloat(c.blue) / 255.0, alpha: 1.0)
        }
        return .systemRed
    }

    var info: UIColor {
        if ansiPalette.count > 4 {
            let c = ansiPalette[4]
            return UIColor(red: CGFloat(c.red) / 255.0, green: CGFloat(c.green) / 255.0, blue: CGFloat(c.blue) / 255.0, alpha: 1.0)
        }
        return .systemBlue
    }

    var altAccent: UIColor {
        if ansiPalette.count > 9 {
            let c = ansiPalette[9]
            return UIColor(red: CGFloat(c.red) / 255.0, green: CGFloat(c.green) / 255.0, blue: CGFloat(c.blue) / 255.0, alpha: 1.0)
        }
        return warning
    }

    var badgeAccent: UIColor {
        if ansiPalette.count > 13 {
            let c = ansiPalette[13]
            return UIColor(red: CGFloat(c.red) / 255.0, green: CGFloat(c.green) / 255.0, blue: CGFloat(c.blue) / 255.0, alpha: 1.0)
        }
        return info
    }

    var isLight: Bool {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if background.getRed(&r, green: &g, blue: &b, alpha: &a) {
            let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
            return luminance > 0.5
        }
        return false
    }

    var surfaceBackgroundColor: SwiftUI.Color { SwiftUI.Color(uiColor: surfaceBackground) }
    var secondarySurfaceColor: SwiftUI.Color { SwiftUI.Color(uiColor: secondarySurface) }
    var tertiarySurfaceColor: SwiftUI.Color { SwiftUI.Color(uiColor: tertiarySurface) }
    var separatorColor: SwiftUI.Color { SwiftUI.Color(uiColor: separator) }

    var primaryTextColor: SwiftUI.Color { SwiftUI.Color(uiColor: primaryText) }
    var secondaryTextColor: SwiftUI.Color { SwiftUI.Color(uiColor: secondaryText) }
    var tertiaryTextColor: SwiftUI.Color { SwiftUI.Color(uiColor: tertiaryText) }
    var mutedTextColor: SwiftUI.Color { SwiftUI.Color(uiColor: mutedText) }

    var accentColor: SwiftUI.Color { SwiftUI.Color(uiColor: accent) }
    var successColor: SwiftUI.Color { SwiftUI.Color(uiColor: success) }
    var warningColor: SwiftUI.Color { SwiftUI.Color(uiColor: warning) }
    var errorColor: SwiftUI.Color { SwiftUI.Color(uiColor: error) }
    var infoColor: SwiftUI.Color { SwiftUI.Color(uiColor: info) }
    var altAccentColor: SwiftUI.Color { SwiftUI.Color(uiColor: altAccent) }
    var badgeAccentColor: SwiftUI.Color { SwiftUI.Color(uiColor: badgeAccent) }
}

private struct TerminalThemeEnvironmentKey: EnvironmentKey {
    static let defaultValue: any TerminalTheme = SolarizedDarkPalette()
}

public extension EnvironmentValues {
    var terminalTheme: any TerminalTheme {
        get { self[TerminalThemeEnvironmentKey.self] }
        set { self[TerminalThemeEnvironmentKey.self] = newValue }
    }
}

// MARK: - Solarized Dark Theme Implementation

public struct SolarizedDarkPalette: TerminalTheme {
    public let type: TerminalThemeType = .solarizedDark
    public let name = "Solarized Dark"

    public var background: UIColor { SolarizedDarkTheme.base03 }
    public var foreground: UIColor { SolarizedDarkTheme.base0 }
    public var cursor: UIColor { SolarizedDarkTheme.base1 }
    public var selection: UIColor { SolarizedDarkTheme.base02 }

    public var surfaceBackground: UIColor { SolarizedDarkTheme.base03 }
    public var secondarySurface: UIColor { SolarizedDarkTheme.base02 }
    public var tertiarySurface: UIColor { SolarizedDarkTheme.base03 }
    public var separator: UIColor { SolarizedDarkTheme.base01 }

    public var primaryText: UIColor { SolarizedDarkTheme.base1 }
    public var secondaryText: UIColor { SolarizedDarkTheme.base0 }
    public var tertiaryText: UIColor { SolarizedDarkTheme.base00 }
    public var mutedText: UIColor { SolarizedDarkTheme.base01 }

    public var accent: UIColor { SolarizedDarkTheme.cyan }
    public var success: UIColor { SolarizedDarkTheme.green }
    public var warning: UIColor { SolarizedDarkTheme.yellow }
    public var error: UIColor { SolarizedDarkTheme.red }
    public var info: UIColor { SolarizedDarkTheme.blue }
    public var altAccent: UIColor { SolarizedDarkTheme.orange }
    public var badgeAccent: UIColor { SolarizedDarkTheme.violet }
    public var isLight: Bool { false }

    public var ansiPalette: [SwiftTerm.Color] {
        SolarizedDarkTheme.ansiPalette
    }
}

// MARK: - Solarized Light Theme Implementation

public struct SolarizedLightPalette: TerminalTheme {
    public let type: TerminalThemeType = .solarizedLight
    public let name = "Solarized Light"

    public var background: UIColor { SolarizedDarkTheme.base3 }
    public var foreground: UIColor { SolarizedDarkTheme.base00 }
    public var cursor: UIColor { SolarizedDarkTheme.base01 }
    public var selection: UIColor { SolarizedDarkTheme.base2 }

    public var surfaceBackground: UIColor { SolarizedDarkTheme.base3 }
    public var secondarySurface: UIColor { SolarizedDarkTheme.base2 }
    public var tertiarySurface: UIColor { SolarizedDarkTheme.base3 }
    public var separator: UIColor { SolarizedDarkTheme.base1 }

    public var primaryText: UIColor { SolarizedDarkTheme.base02 }
    public var secondaryText: UIColor { SolarizedDarkTheme.base00 }
    public var tertiaryText: UIColor { SolarizedDarkTheme.base0 }
    public var mutedText: UIColor { SolarizedDarkTheme.base1 }

    public var accent: UIColor { SolarizedDarkTheme.cyan }
    public var success: UIColor { SolarizedDarkTheme.green }
    public var warning: UIColor { SolarizedDarkTheme.yellow }
    public var error: UIColor { SolarizedDarkTheme.red }
    public var info: UIColor { SolarizedDarkTheme.blue }
    public var altAccent: UIColor { SolarizedDarkTheme.orange }
    public var badgeAccent: UIColor { SolarizedDarkTheme.violet }
    public var isLight: Bool { true }

    public var ansiPalette: [SwiftTerm.Color] {
        SolarizedDarkPalette().ansiPalette
    }
}

// MARK: - Dracula Theme Implementation

public struct DraculaPalette: TerminalTheme {
    public let type: TerminalThemeType = .dracula
    public let name = "Dracula"

    public var background: UIColor { UIColor(red: 0x28/255.0, green: 0x2a/255.0, blue: 0x36/255.0, alpha: 1.0) }
    public var foreground: UIColor { UIColor(red: 0xf8/255.0, green: 0xf8/255.0, blue: 0xf2/255.0, alpha: 1.0) }
    public var cursor: UIColor { UIColor(red: 0xf8/255.0, green: 0xf8/255.0, blue: 0xf2/255.0, alpha: 1.0) }
    public var selection: UIColor { UIColor(red: 0x44/255.0, green: 0x47/255.0, blue: 0x5a/255.0, alpha: 1.0) }

    public var surfaceBackground: UIColor { background }
    public var secondarySurface: UIColor { UIColor(red: 0x21/255.0, green: 0x22/255.0, blue: 0x2c/255.0, alpha: 1.0) }
    public var tertiarySurface: UIColor { UIColor(red: 0x34/255.0, green: 0x37/255.0, blue: 0x46/255.0, alpha: 1.0) }
    public var separator: UIColor { UIColor(red: 0x62/255.0, green: 0x72/255.0, blue: 0xa4/255.0, alpha: 1.0) }

    public var primaryText: UIColor { foreground }
    public var secondaryText: UIColor { UIColor(red: 0xe2/255.0, green: 0xe2/255.0, blue: 0xdc/255.0, alpha: 1.0) }
    public var tertiaryText: UIColor { UIColor(red: 0xab/255.0, green: 0xb2/255.0, blue: 0xbf/255.0, alpha: 1.0) }
    public var mutedText: UIColor { UIColor(red: 0x62/255.0, green: 0x72/255.0, blue: 0xa4/255.0, alpha: 1.0) }

    public var accent: UIColor { UIColor(red: 0x8b/255.0, green: 0xe9/255.0, blue: 0xfd/255.0, alpha: 1.0) }
    public var success: UIColor { UIColor(red: 0x50/255.0, green: 0xfa/255.0, blue: 0x7b/255.0, alpha: 1.0) }
    public var warning: UIColor { UIColor(red: 0xf1/255.0, green: 0xfa/255.0, blue: 0x8c/255.0, alpha: 1.0) }
    public var error: UIColor { UIColor(red: 0xff/255.0, green: 0x55/255.0, blue: 0x55/255.0, alpha: 1.0) }
    public var info: UIColor { UIColor(red: 0xbd/255.0, green: 0x93/255.0, blue: 0xf9/255.0, alpha: 1.0) }
    public var altAccent: UIColor { UIColor(red: 0xff/255.0, green: 0xb8/255.0, blue: 0x6c/255.0, alpha: 1.0) }
    public var badgeAccent: UIColor { UIColor(red: 0xff/255.0, green: 0x79/255.0, blue: 0xc6/255.0, alpha: 1.0) }
    public var isLight: Bool { false }

    public var ansiPalette: [SwiftTerm.Color] {
        [
            SwiftTerm.Color(red8: 0x21, green8: 0x22, blue8: 0x2c), // 0: Black
            SwiftTerm.Color(red8: 0xff, green8: 0x55, blue8: 0x55), // 1: Red
            SwiftTerm.Color(red8: 0x50, green8: 0xfa, blue8: 0x7b), // 2: Green
            SwiftTerm.Color(red8: 0xf1, green8: 0xfa, blue8: 0x8c), // 3: Yellow
            SwiftTerm.Color(red8: 0xbd, green8: 0x93, blue8: 0xf9), // 4: Purple
            SwiftTerm.Color(red8: 0xff, green8: 0x79, blue8: 0xc6), // 5: Pink
            SwiftTerm.Color(red8: 0x8b, green8: 0xe9, blue8: 0xfd), // 6: Cyan
            SwiftTerm.Color(red8: 0xf8, green8: 0xf8, blue8: 0xf2), // 7: White
            SwiftTerm.Color(red8: 0x62, green8: 0x72, blue8: 0xa4), // 8: Bright Black
            SwiftTerm.Color(red8: 0xff, green8: 0x6e, blue8: 0x6e), // 9: Bright Red
            SwiftTerm.Color(red8: 0x69, green8: 0xff, blue8: 0x94), // 10: Bright Green
            SwiftTerm.Color(red8: 0xff, green8: 0xff, blue8: 0xa5), // 11: Bright Yellow
            SwiftTerm.Color(red8: 0xd6, green8: 0xac, blue8: 0xff), // 12: Bright Purple
            SwiftTerm.Color(red8: 0xff, green8: 0x92, blue8: 0xdf), // 13: Bright Pink
            SwiftTerm.Color(red8: 0xa4, green8: 0xff, blue8: 0xff), // 14: Bright Cyan
            SwiftTerm.Color(red8: 0xff, green8: 0xff, blue8: 0xff)  // 15: Bright White
        ]
    }
}

// MARK: - Nord Theme Implementation

public struct NordPalette: TerminalTheme {
    public let type: TerminalThemeType = .nord
    public let name = "Nord"

    public var background: UIColor { UIColor(red: 0x2e/255.0, green: 0x34/255.0, blue: 0x40/255.0, alpha: 1.0) }
    public var foreground: UIColor { UIColor(red: 0xd8/255.0, green: 0xde/255.0, blue: 0xe9/255.0, alpha: 1.0) }
    public var cursor: UIColor { UIColor(red: 0xd8/255.0, green: 0xde/255.0, blue: 0xe9/255.0, alpha: 1.0) }
    public var selection: UIColor { UIColor(red: 0x43/255.0, green: 0x4c/255.0, blue: 0x5e/255.0, alpha: 1.0) }

    public var surfaceBackground: UIColor { background }
    public var secondarySurface: UIColor { UIColor(red: 0x3b/255.0, green: 0x42/255.0, blue: 0x52/255.0, alpha: 1.0) }
    public var tertiarySurface: UIColor { background }
    public var separator: UIColor { UIColor(red: 0x4c/255.0, green: 0x56/255.0, blue: 0x6a/255.0, alpha: 1.0) }

    public var primaryText: UIColor { UIColor(red: 0xec/255.0, green: 0xef/255.0, blue: 0xf4/255.0, alpha: 1.0) }
    public var secondaryText: UIColor { foreground }
    public var tertiaryText: UIColor { UIColor(red: 0xe5/255.0, green: 0xe9/255.0, blue: 0xf0/255.0, alpha: 1.0) }
    public var mutedText: UIColor { UIColor(red: 0x4c/255.0, green: 0x56/255.0, blue: 0x6a/255.0, alpha: 1.0) }

    public var accent: UIColor { UIColor(red: 0x88/255.0, green: 0xc0/255.0, blue: 0xd0/255.0, alpha: 1.0) }
    public var success: UIColor { UIColor(red: 0xa3/255.0, green: 0xbe/255.0, blue: 0x8c/255.0, alpha: 1.0) }
    public var warning: UIColor { UIColor(red: 0xeb/255.0, green: 0xcb/255.0, blue: 0x8b/255.0, alpha: 1.0) }
    public var error: UIColor { UIColor(red: 0xbf/255.0, green: 0x61/255.0, blue: 0x6a/255.0, alpha: 1.0) }
    public var info: UIColor { UIColor(red: 0x81/255.0, green: 0xa1/255.0, blue: 0xc1/255.0, alpha: 1.0) }
    public var altAccent: UIColor { UIColor(red: 0xd0/255.0, green: 0x87/255.0, blue: 0x70/255.0, alpha: 1.0) }
    public var badgeAccent: UIColor { UIColor(red: 0xb4/255.0, green: 0x8e/255.0, blue: 0xad/255.0, alpha: 1.0) }
    public var isLight: Bool { false }

    public var ansiPalette: [SwiftTerm.Color] {
        [
            SwiftTerm.Color(red8: 0x3b, green8: 0x42, blue8: 0x52), // 0: nord1
            SwiftTerm.Color(red8: 0xbf, green8: 0x61, blue8: 0x6a), // 1: nord11
            SwiftTerm.Color(red8: 0xa3, green8: 0xbe, blue8: 0x8c), // 2: nord14
            SwiftTerm.Color(red8: 0xeb, green8: 0xcb, blue8: 0x8b), // 3: nord13
            SwiftTerm.Color(red8: 0x81, green8: 0xa1, blue8: 0xc1), // 4: nord9
            SwiftTerm.Color(red8: 0xb4, green8: 0x8e, blue8: 0xad), // 5: nord15
            SwiftTerm.Color(red8: 0x88, green8: 0xc0, blue8: 0xd0), // 6: nord8
            SwiftTerm.Color(red8: 0xe5, green8: 0xe9, blue8: 0xf0), // 7: nord5
            SwiftTerm.Color(red8: 0x4c, green8: 0x56, blue8: 0x6a), // 8: nord3
            SwiftTerm.Color(red8: 0xbf, green8: 0x61, blue8: 0x6a), // 9: nord11
            SwiftTerm.Color(red8: 0xa3, green8: 0xbe, blue8: 0x8c), // 10: nord14
            SwiftTerm.Color(red8: 0xeb, green8: 0xcb, blue8: 0x8b), // 11: nord13
            SwiftTerm.Color(red8: 0x81, green8: 0xa1, blue8: 0xc1), // 12: nord9
            SwiftTerm.Color(red8: 0xb4, green8: 0x8e, blue8: 0xad), // 13: nord15
            SwiftTerm.Color(red8: 0x8f, green8: 0xbc, blue8: 0xbb), // 14: nord7
            SwiftTerm.Color(red8: 0xec, green8: 0xef, blue8: 0xf4)  // 15: nord6
        ]
    }
}

// MARK: - Monokai Theme Implementation

public struct MonokaiPalette: TerminalTheme {
    public let type: TerminalThemeType = .monokai
    public let name = "Monokai"

    public var background: UIColor { UIColor(red: 0x27/255.0, green: 0x28/255.0, blue: 0x32/255.0, alpha: 1.0) }
    public var foreground: UIColor { UIColor(red: 0xf8/255.0, green: 0xf8/255.0, blue: 0xf2/255.0, alpha: 1.0) }
    public var cursor: UIColor { UIColor(red: 0xf8/255.0, green: 0xf8/255.0, blue: 0xf0/255.0, alpha: 1.0) }
    public var selection: UIColor { UIColor(red: 0x49/255.0, green: 0x48/255.0, blue: 0x3e/255.0, alpha: 1.0) }

    public var surfaceBackground: UIColor { background }
    public var secondarySurface: UIColor { UIColor(red: 0x3e/255.0, green: 0x3d/255.0, blue: 0x32/255.0, alpha: 1.0) }
    public var tertiarySurface: UIColor { background }
    public var separator: UIColor { UIColor(red: 0x75/255.0, green: 0x71/255.0, blue: 0x5e/255.0, alpha: 1.0) }

    public var primaryText: UIColor { foreground }
    public var secondaryText: UIColor { UIColor(red: 0xcf/255.0, green: 0xcf/255.0, blue: 0xc2/255.0, alpha: 1.0) }
    public var tertiaryText: UIColor { UIColor(red: 0xa8/255.0, green: 0xa8/255.0, blue: 0x9a/255.0, alpha: 1.0) }
    public var mutedText: UIColor { UIColor(red: 0x75/255.0, green: 0x71/255.0, blue: 0x5e/255.0, alpha: 1.0) }

    public var accent: UIColor { UIColor(red: 0x66/255.0, green: 0xd9/255.0, blue: 0xef/255.0, alpha: 1.0) }
    public var success: UIColor { UIColor(red: 0xa6/255.0, green: 0xe2/255.0, blue: 0x2e/255.0, alpha: 1.0) }
    public var warning: UIColor { UIColor(red: 0xe6/255.0, green: 0xdb/255.0, blue: 0x74/255.0, alpha: 1.0) }
    public var error: UIColor { UIColor(red: 0xf9/255.0, green: 0x26/255.0, blue: 0x72/255.0, alpha: 1.0) }
    public var info: UIColor { UIColor(red: 0x66/255.0, green: 0xd9/255.0, blue: 0xef/255.0, alpha: 1.0) }
    public var altAccent: UIColor { UIColor(red: 0xfd/255.0, green: 0x97/255.0, blue: 0x1f/255.0, alpha: 1.0) }
    public var badgeAccent: UIColor { UIColor(red: 0xae/255.0, green: 0x81/255.0, blue: 0xff/255.0, alpha: 1.0) }
    public var isLight: Bool { false }

    public var ansiPalette: [SwiftTerm.Color] {
        [
            SwiftTerm.Color(red8: 0x27, green8: 0x28, blue8: 0x22), // 0: Black
            SwiftTerm.Color(red8: 0xf9, green8: 0x26, blue8: 0x72), // 1: Red
            SwiftTerm.Color(red8: 0xa6, green8: 0xe2, blue8: 0x2e), // 2: Green
            SwiftTerm.Color(red8: 0xf4, green8: 0xbf, blue8: 0x75), // 3: Yellow
            SwiftTerm.Color(red8: 0x66, green8: 0xd9, blue8: 0xef), // 4: Blue
            SwiftTerm.Color(red8: 0xae, green8: 0x81, blue8: 0xff), // 5: Magenta
            SwiftTerm.Color(red8: 0xa1, green8: 0xef, blue8: 0xe4), // 6: Cyan
            SwiftTerm.Color(red8: 0xf8, green8: 0xf8, blue8: 0xf2), // 7: White
            SwiftTerm.Color(red8: 0x75, green8: 0x71, blue8: 0x5e), // 8: Bright Black
            SwiftTerm.Color(red8: 0xf9, green8: 0x26, blue8: 0x72), // 9: Bright Red
            SwiftTerm.Color(red8: 0xa6, green8: 0xe2, blue8: 0xe2), // 10: Bright Green
            SwiftTerm.Color(red8: 0xf4, green8: 0xbf, blue8: 0x75), // 11: Bright Yellow
            SwiftTerm.Color(red8: 0x66, green8: 0xd9, blue8: 0xef), // 12: Bright Blue
            SwiftTerm.Color(red8: 0xae, green8: 0x81, blue8: 0xff), // 13: Bright Magenta
            SwiftTerm.Color(red8: 0xa1, green8: 0xef, blue8: 0xe4), // 14: Bright Cyan
            SwiftTerm.Color(red8: 0xf9, green8: 0xf8, blue8: 0xf5)  // 15: Bright White
        ]
    }
}

// MARK: - Theme Manager

@MainActor
@Observable
public final class ThemeManager {
    public static let shared = ThemeManager()
    private let themeKey = "io.o-t.filaire.selected_theme"

    public var selectedThemeType: TerminalThemeType {
        didSet {
            UserDefaults.standard.set(selectedThemeType.rawValue, forKey: themeKey)
            NotificationCenter.default.post(name: .terminalSettingsChanged, object: nil)
        }
    }

    public var currentTheme: any TerminalTheme {
        Self.theme(for: selectedThemeType)
    }

    public var currentPalette: any TerminalTheme {
        currentTheme
    }

    public init() {
        let saved = UserDefaults.standard.string(forKey: themeKey)
        if let saved = saved,
           let type = TerminalThemeType(rawValue: saved) {
            self.selectedThemeType = type
        } else {
            self.selectedThemeType = .solarizedDark
        }
    }

    public static func theme(for type: TerminalThemeType) -> any TerminalTheme {
        switch type {
        case .solarizedDark:
            return SolarizedDarkPalette()
        case .solarizedLight:
            return SolarizedLightPalette()
        case .dracula:
            return DraculaPalette()
        case .nord:
            return NordPalette()
        case .monokai:
            return MonokaiPalette()
        }
    }

    public func applyTheme(to terminalView: SwiftTerm.TerminalView) {
        let theme = currentTheme
        terminalView.installColors(theme.ansiPalette)
        terminalView.nativeBackgroundColor = theme.background
        terminalView.nativeForegroundColor = theme.foreground
        terminalView.caretColor = theme.cursor
        terminalView.selectedTextBackgroundColor = theme.selection
        terminalView.layer.backgroundColor = theme.background.cgColor
    }
}
