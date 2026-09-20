import Foundation

/// Builds the remote command that appends a public key to the current user's `authorized_keys`, the way
/// `ssh-copy-id` does. Pure: it opens no connection, holds no credentials, and runs nothing locally.
public enum KeyInstaller {

    public enum ValidationError: Error, Equatable {
        case emptyKey
        /// An `authorized_keys` entry is one line; anything else would append a partial or extra entry.
        case multipleLines
        case notAPublicKey
        /// Install connects directly, so a host reached through a bastion is refused rather than
        /// silently connected some other way.
        case jumpHostNotSupported
    }

    /// Recognized OpenSSH public key prefixes, including security-key variants.
    private static let keyPrefixes = ["ssh-", "ecdsa-", "sk-"]

    /// Accepts a single-line OpenSSH public key: an algorithm name, base64 material, and an optional comment.
    public static func validate(publicKey: String) -> ValidationError? {
        let trimmed = publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .emptyKey }

        if trimmed.contains("\n") || trimmed.contains("\r") {
            return .multipleLines
        }
        // Any other control character would be meaningless in an authorized_keys line.
        if trimmed.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            return .notAPublicKey
        }

        let fields = trimmed.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 2 else { return .notAPublicKey }
        guard keyPrefixes.contains(where: { fields[0].hasPrefix($0) }) else { return .notAPublicKey }
        return nil
    }

    public static func validate(host: HostProfile) -> ValidationError? {
        host.jumpHostId == nil ? nil : .jumpHostNotSupported
    }

    /// The remote command. It is idempotent (an exact duplicate line is never appended), creates `~/.ssh`
    /// as 700 and `authorized_keys` as 600, and is silent on success — so any stderr output or non-zero
    /// exit from the server is a real failure worth showing the user.
    ///
    /// The key is quoted with the same POSIX encoder used for snippets, which is verified against sh, bash
    /// and zsh, so a comment containing quotes or spaces cannot break out of the argument.
    public static func installCommand(for publicKey: String) -> String {
        let key = SnippetTemplateRenderer.posixQuoted(
            publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        return [
            "set -e",
            "key=\(key)",
            "dir=\"$HOME/.ssh\"",
            "file=\"$dir/authorized_keys\"",
            "mkdir -p \"$dir\"",
            "chmod 700 \"$dir\"",
            "touch \"$file\"",
            "chmod 600 \"$file\"",
            // An existing file whose last line has no newline would otherwise be welded to the new key,
            // corrupting the entry already there and the one being added.
            "if grep -qxF \"$key\" \"$file\"; then :; else if [ -s \"$file\" ] && [ -n \"$(tail -c1 \"$file\")\" ]; then printf '\\n' >> \"$file\"; fi; printf '%s\\n' \"$key\" >> \"$file\"; fi"
        ].joined(separator: "; ")
    }

    public static func message(for error: ValidationError) -> String {
        switch error {
        case .emptyKey:
            return "This key has no public key text to install."
        case .multipleLines:
            return "A public key must be a single line."
        case .notAPublicKey:
            return "That does not look like an OpenSSH public key."
        case .jumpHostNotSupported:
            return "Install connects directly and cannot use this host's jump host. Install the key on the jump host's target yourself, or remove the jump host temporarily."
        }
    }
}
