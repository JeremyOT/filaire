import Foundation

/// Sanitizes text supplied by a remote host before it is shown in system UI (prompts, notifications).
public enum RemoteText {
    /// Bidirectional override/isolate characters that can visually reorder text to spoof content.
    private static let bidiControls: Set<UInt32> = [
        0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
        0x2066, 0x2067, 0x2068, 0x2069
    ]

    public static func sanitize(_ text: String, maxLength: Int) -> String {
        let scalars = text.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar) && !bidiControls.contains(scalar.value)
        }
        let cleaned = String(String.UnicodeScalarView(scalars))
        guard cleaned.count > maxLength else { return cleaned }
        return String(cleaned.prefix(maxLength)) + "…"
    }
}
