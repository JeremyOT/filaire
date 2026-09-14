import UIKit
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
}

// MARK: - Solarized Dark Theme Implementation

public struct SolarizedDarkPalette: TerminalTheme {
    public let type: TerminalThemeType = .solarizedDark
    public let name = "Solarized Dark"

    public var background: UIColor { UIColor(red: 0x00/255.0, green: 0x2b/255.0, blue: 0x36/255.0, alpha: 1.0) }
    public var foreground: UIColor { UIColor(red: 0x83/255.0, green: 0x94/255.0, blue: 0x96/255.0, alpha: 1.0) }
    public var cursor: UIColor { UIColor(red: 0x93/255.0, green: 0xa1/255.0, blue: 0xa1/255.0, alpha: 1.0) }
    public var selection: UIColor { UIColor(red: 0x07/255.0, green: 0x36/255.0, blue: 0x42/255.0, alpha: 1.0) }

    public var ansiPalette: [SwiftTerm.Color] {
        [
            SwiftTerm.Color(red8: 0x07, green8: 0x36, blue8: 0x42), // 0: base02
            SwiftTerm.Color(red8: 0xdc, green8: 0x32, blue8: 0x2f), // 1: red
            SwiftTerm.Color(red8: 0x85, green8: 0x99, blue8: 0x00), // 2: green
            SwiftTerm.Color(red8: 0xb5, green8: 0x89, blue8: 0x00), // 3: yellow
            SwiftTerm.Color(red8: 0x26, green8: 0x8b, blue8: 0xd2), // 4: blue
            SwiftTerm.Color(red8: 0xd3, green8: 0x36, blue8: 0x82), // 5: magenta
            SwiftTerm.Color(red8: 0x2a, green8: 0xa1, blue8: 0x98), // 6: cyan
            SwiftTerm.Color(red8: 0xee, green8: 0xe8, blue8: 0xd5), // 7: base2
            SwiftTerm.Color(red8: 0x00, green8: 0x2b, blue8: 0x36), // 8: base03
            SwiftTerm.Color(red8: 0xcb, green8: 0x4b, blue8: 0x16), // 9: orange
            SwiftTerm.Color(red8: 0x58, green8: 0x6e, blue8: 0x75), // 10: base01
            SwiftTerm.Color(red8: 0x65, green8: 0x7b, blue8: 0x83), // 11: base00
            SwiftTerm.Color(red8: 0x83, green8: 0x94, blue8: 0x96), // 12: base0
            SwiftTerm.Color(red8: 0x6c, green8: 0x71, blue8: 0xc4), // 13: violet
            SwiftTerm.Color(red8: 0x93, green8: 0xa1, blue8: 0xa1), // 14: base1
            SwiftTerm.Color(red8: 0xfd, green8: 0xf6, blue8: 0xe3)  // 15: base3
        ]
    }
}

// MARK: - Solarized Light Theme Implementation

public struct SolarizedLightPalette: TerminalTheme {
    public let type: TerminalThemeType = .solarizedLight
    public let name = "Solarized Light"

    public var background: UIColor { UIColor(red: 0xfd/255.0, green: 0xf6/255.0, blue: 0xe3/255.0, alpha: 1.0) }
    public var foreground: UIColor { UIColor(red: 0x65/255.0, green: 0x7b/255.0, blue: 0x83/255.0, alpha: 1.0) }
    public var cursor: UIColor { UIColor(red: 0x58/255.0, green: 0x6e/255.0, blue: 0x75/255.0, alpha: 1.0) }
    public var selection: UIColor { UIColor(red: 0xee/255.0, green: 0xe8/255.0, blue: 0xd5/255.0, alpha: 1.0) }

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

    public var background: UIColor { UIColor(red: 0x27/255.0, green: 0x28/255.0, blue: 0x22/255.0, alpha: 1.0) }
    public var foreground: UIColor { UIColor(red: 0xf8/255.0, green: 0xf8/255.0, blue: 0xf2/255.0, alpha: 1.0) }
    public var cursor: UIColor { UIColor(red: 0xf8/255.0, green: 0xf8/255.0, blue: 0xf0/255.0, alpha: 1.0) }
    public var selection: UIColor { UIColor(red: 0x49/255.0, green: 0x48/255.0, blue: 0x3e/255.0, alpha: 1.0) }

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
            SwiftTerm.Color(red8: 0xa6, green8: 0xe2, blue8: 0x2e), // 10: Bright Green
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
