import Foundation
import SwiftTerm

/// Identifies the connection a composed submission was prepared against. Every connect and retry mints a
/// new connection id, so a token captured before a reconnect can never admit bytes into the new session.
public struct TerminalSubmissionTarget: Equatable, Sendable {
    public let hostID: UUID
    public let connectionID: UUID

    public init(hostID: UUID, connectionID: UUID) {
        self.hostID = hostID
        self.connectionID = connectionID
    }
}

/// Insert sends the text alone. Run sends the text followed by exactly one carriage return; it is ordinary
/// terminal input, not a separate SSH exec request, so it cannot promise the remote application ran anything.
public enum TerminalSubmissionAction: Equatable, Sendable {
    case insert
    case run
}

/// The outcome of offering a prepared submission to the outbound queue. Admission is all or nothing:
/// anything other than `.accepted` means zero bytes were enqueued and the draft should be preserved.
/// Invalid text cannot appear here because preparation rejects it before a payload exists.
public enum TerminalSubmissionAdmission: Equatable, Sendable {
    case accepted
    case notConnected
    /// The connection the submission was prepared against is gone, typically after a reconnect or host switch.
    case staleTarget
    case queueFull(available: Int, required: Int)
    /// This submission id was already admitted; a new deliberate action carries a new id.
    case duplicate
}

public enum TerminalSubmissionPreparationError: Error, Equatable, Sendable {
    case empty
    /// A control character that cannot be sent literally. `utf16Offset` indexes the normalized text, so the
    /// editor can select the offending character with an NSRange.
    case forbiddenControlCharacter(scalar: Unicode.Scalar, utf16Offset: Int)
    case multilineRequiresBracketedPaste
    case tooLarge(byteCount: Int, limit: Int)
}

/// A validated, fully encoded payload. Only `TerminalInputSubmission.prepare` produces one, so the payload
/// is guaranteed non-empty and free of forbidden control characters.
public struct PreparedTerminalSubmission: Equatable, Sendable {
    public let id: UUID
    public let target: TerminalSubmissionTarget
    public let action: TerminalSubmissionAction
    public let normalizedText: String
    /// True when normalization changed the text; the editor adopts the normalized form so the change is visible.
    public let didNormalizeLineEndings: Bool
    public let payload: [UInt8]
}

/// Pure preparation shared by the command composer and parameterized snippets. Contains no connection state:
/// capacity and connection identity are checked at admission time by `SessionManager`.
public enum TerminalInputSubmission {
    /// Editor bound per draft. This does not replace the outbound queue's aggregate capacity check.
    public static let maxDraftBytes: Int = 64 * 1024

    private static let carriageReturn: UInt8 = 0x0D

    /// Collapses CRLF and lone CR to LF. Spaces and trailing newlines are never trimmed.
    public static func normalizeLineEndings(_ text: String) -> String {
        guard text.contains("\r") else { return text }
        return text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    /// LF and TAB are the only control characters that may be sent literally. Everything else in C0, DEL, and
    /// C1 is rejected rather than stripped, so a composed command can never emit its own escape sequence.
    private static func isForbiddenControl(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if value == 0x0A || value == 0x09 { return false }
        if value <= 0x1F { return true }
        if value == 0x7F { return true }
        return (0x80...0x9F).contains(value)
    }

    public static func prepare(
        text: String,
        action: TerminalSubmissionAction,
        target: TerminalSubmissionTarget,
        bracketedPasteEnabled: Bool,
        id: UUID = UUID()
    ) -> Result<PreparedTerminalSubmission, TerminalSubmissionPreparationError> {
        let normalized = normalizeLineEndings(text)
        guard !normalized.isEmpty else { return .failure(.empty) }

        var utf16Offset = 0
        for scalar in normalized.unicodeScalars {
            if isForbiddenControl(scalar) {
                return .failure(.forbiddenControlCharacter(scalar: scalar, utf16Offset: utf16Offset))
            }
            utf16Offset += UTF16.width(scalar)
        }

        let textBytes = Array(normalized.utf8)
        guard textBytes.count <= maxDraftBytes else {
            return .failure(.tooLarge(byteCount: textBytes.count, limit: maxDraftBytes))
        }

        // Without bracketed paste the remote shell would execute each embedded newline as it arrives, so
        // multiline sending is refused rather than silently reshaped into something else.
        if normalized.contains("\n") && !bracketedPasteEnabled {
            return .failure(.multilineRequiresBracketedPaste)
        }

        var payload: [UInt8] = []
        payload.reserveCapacity(textBytes.count + 16)
        if bracketedPasteEnabled {
            payload.append(contentsOf: EscapeSequences.bracketedPasteStart)
            payload.append(contentsOf: textBytes)
            payload.append(contentsOf: EscapeSequences.bracketedPasteEnd)
        } else {
            payload.append(contentsOf: textBytes)
        }
        if action == .run {
            payload.append(carriageReturn)
        }

        return .success(
            PreparedTerminalSubmission(
                id: id,
                target: target,
                action: action,
                normalizedText: normalized,
                didNormalizeLineEndings: normalized != text,
                payload: payload
            )
        )
    }
}
