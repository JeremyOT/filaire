import UIKit
import SwiftTerm

public enum SolarizedDarkTheme {
    // Core Colors
    public static let base03 = UIColor(red: 0x00/255.0, green: 0x2b/255.0, blue: 0x36/255.0, alpha: 1.0) // #002b36 - background
    public static let base02 = UIColor(red: 0x07/255.0, green: 0x36/255.0, blue: 0x42/255.0, alpha: 1.0) // #073642 - background highlights
    public static let base01 = UIColor(red: 0x58/255.0, green: 0x6e/255.0, blue: 0x75/255.0, alpha: 1.0) // #586e75 - comments / secondary
    public static let base00 = UIColor(red: 0x65/255.0, green: 0x7b/255.0, blue: 0x83/255.0, alpha: 1.0) // #657b83
    public static let base0  = UIColor(red: 0x83/255.0, green: 0x94/255.0, blue: 0x96/255.0, alpha: 1.0) // #839496 - foreground
    public static let base1  = UIColor(red: 0x93/255.0, green: 0xa1/255.0, blue: 0xa1/255.0, alpha: 1.0) // #93a1a1 - emphasized text
    public static let base2  = UIColor(red: 0xee/255.0, green: 0xe8/255.0, blue: 0xd5/255.0, alpha: 1.0) // #eee8d5
    public static let base3  = UIColor(red: 0xfd/255.0, green: 0xf6/255.0, blue: 0xe3/255.0, alpha: 1.0) // #fdf6e3

    // Accent Colors
    public static let yellow  = UIColor(red: 0xb5/255.0, green: 0x89/255.0, blue: 0x00/255.0, alpha: 1.0) // #b58900
    public static let orange  = UIColor(red: 0xcb/255.0, green: 0x4b/255.0, blue: 0x16/255.0, alpha: 1.0) // #cb4b16
    public static let red     = UIColor(red: 0xdc/255.0, green: 0x32/255.0, blue: 0x2f/255.0, alpha: 1.0) // #dc322f
    public static let magenta = UIColor(red: 0xd3/255.0, green: 0x36/255.0, blue: 0x82/255.0, alpha: 1.0) // #d33682
    public static let violet  = UIColor(red: 0x6c/255.0, green: 0x71/255.0, blue: 0xc4/255.0, alpha: 1.0) // #6c71c4
    public static let blue    = UIColor(red: 0x26/255.0, green: 0x8b/255.0, blue: 0xd2/255.0, alpha: 1.0) // #268bd2
    public static let cyan    = UIColor(red: 0x2a/255.0, green: 0xa1/255.0, blue: 0x98/255.0, alpha: 1.0) // #2aa198
    public static let green   = UIColor(red: 0x85/255.0, green: 0x99/255.0, blue: 0x00/255.0, alpha: 1.0) // #859900

    public static var terminalBackground: UIColor { base03 }
    public static var terminalForeground: UIColor { base0 }
    public static var terminalCursor: UIColor { base1 }
    public static var terminalSelection: UIColor { base02 }

    /// SwiftTerm ANSI 16-color palette
    public static var ansiPalette: [SwiftTerm.Color] {
        [
            // Normal 0-7
            SwiftTerm.Color(red8: 0x07, green8: 0x36, blue8: 0x42), // 0: Black (base02)
            SwiftTerm.Color(red8: 0xdc, green8: 0x32, blue8: 0x2f), // 1: Red
            SwiftTerm.Color(red8: 0x85, green8: 0x99, blue8: 0x00), // 2: Green
            SwiftTerm.Color(red8: 0xb5, green8: 0x89, blue8: 0x00), // 3: Yellow
            SwiftTerm.Color(red8: 0x26, green8: 0x8b, blue8: 0xd2), // 4: Blue
            SwiftTerm.Color(red8: 0xd3, green8: 0x36, blue8: 0x82), // 5: Magenta
            SwiftTerm.Color(red8: 0x2a, green8: 0xa1, blue8: 0x98), // 6: Cyan
            SwiftTerm.Color(red8: 0xee, green8: 0xe8, blue8: 0xd5), // 7: White (base2)

            // Bright 8-15
            SwiftTerm.Color(red8: 0x00, green8: 0x2b, blue8: 0x36), // 8: Bright Black (base03)
            SwiftTerm.Color(red8: 0xcb, green8: 0x4b, blue8: 0x16), // 9: Bright Red / Orange
            SwiftTerm.Color(red8: 0x58, green8: 0x6e, blue8: 0x75), // 10: Bright Green (base01)
            SwiftTerm.Color(red8: 0x65, green8: 0x7b, blue8: 0x83), // 11: Bright Yellow (base00)
            SwiftTerm.Color(red8: 0x83, green8: 0x94, blue8: 0x96), // 12: Bright Blue (base0)
            SwiftTerm.Color(red8: 0x6c, green8: 0x71, blue8: 0xc4), // 13: Bright Magenta / Violet
            SwiftTerm.Color(red8: 0x93, green8: 0xa1, blue8: 0xa1), // 14: Bright Cyan (base1)
            SwiftTerm.Color(red8: 0xfd, green8: 0xf6, blue8: 0xe3)  // 15: Bright White (base3)
        ]
    }

    /// Applies Solarized Dark styling to a SwiftTerm.TerminalView
    public static func apply(to terminalView: SwiftTerm.TerminalView) {
        terminalView.installColors(ansiPalette)
        terminalView.nativeBackgroundColor = terminalBackground
        terminalView.nativeForegroundColor = terminalForeground
        terminalView.caretColor = terminalCursor
        terminalView.selectedTextBackgroundColor = terminalSelection
        terminalView.layer.backgroundColor = terminalBackground.cgColor
    }
}
