import UIKit
import CoreText

public enum TerminalFontFamily: String, CaseIterable, Identifiable, Codable {
    case nerdFont = "MesloLGS Nerd Font"
    case systemMono = "System Monospace"
    case menlo = "Menlo"
    case courier = "Courier New"

    public var id: String { rawValue }

    public var fontName: String? {
        switch self {
        case .nerdFont:
            return "MesloLGSNF-Regular"
        case .systemMono:
            return nil
        case .menlo:
            return "Menlo-Regular"
        case .courier:
            return "CourierNewPSMT"
        }
    }
}

public final class FontManager {
    public static let shared = FontManager()

    private let familyKey = "io.o-t.filaire.font_family"
    private let sizeKey = "io.o-t.filaire.font_size"

    private var didRegisterBundledFonts = false

    public var selectedFamily: TerminalFontFamily {
        get {
            guard let raw = UserDefaults.standard.string(forKey: familyKey),
                  let family = TerminalFontFamily(rawValue: raw) else {
                return .nerdFont
            }
            return family
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: familyKey)
            NotificationCenter.default.post(name: .terminalSettingsChanged, object: nil)
        }
    }

    public var defaultFontSize: CGFloat {
        UIDevice.current.userInterfaceIdiom == .pad ? 15.0 : 13.0
    }

    public var fontSize: CGFloat {
        get {
            let saved = UserDefaults.standard.double(forKey: sizeKey)
            if saved > 0 {
                return CGFloat(saved)
            }
            return defaultFontSize
        }
        set {
            let clamped = max(9.0, min(newValue, 32.0))
            UserDefaults.standard.set(Double(clamped), forKey: sizeKey)
            NotificationCenter.default.post(name: .terminalSettingsChanged, object: nil)
        }
    }

    public func resetFontSize() {
        fontSize = defaultFontSize
    }

    public init() {
        registerBundledFontsIfNeeded()
    }

    /// Dynamically registers any TTF fonts in the bundle so they are immediately available
    public func registerBundledFontsIfNeeded() {
        guard !didRegisterBundledFonts else { return }
        didRegisterBundledFonts = true

        // Register font from main bundle or resource URL
        if let fontURL = Bundle.main.url(forResource: "MesloLGSNerdFont-Regular", withExtension: "ttf") {
            var error: Unmanaged<CFError>?
            CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, &error)
        }
    }

    /// Constructs the active terminal font
    public func currentFont() -> UIFont {
        makeFont(family: selectedFamily, size: fontSize)
    }

    public func makeFont(family: TerminalFontFamily, size: CGFloat) -> UIFont {
        registerBundledFontsIfNeeded()

        if let fontName = family.fontName, let font = UIFont(name: fontName, size: size) {
            return font
        }

        return UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}
