import XCTest
@testable import Filaire

/// The remote command is built and checked here; it is never executed locally.
final class KeyInstallerTests: XCTestCase {

    private let sampleKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGX8vKqX82jNmHQE3v9y0k filaire@ipad"

    // MARK: - Validation

    func testAcceptsOpenSSHPublicKeys() {
        XCTAssertNil(KeyInstaller.validate(publicKey: sampleKey))
        XCTAssertNil(KeyInstaller.validate(publicKey: "ssh-rsa AAAAB3NzaC1yc2E comment"))
        XCTAssertNil(KeyInstaller.validate(publicKey: "ecdsa-sha2-nistp256 AAAAE2VjZHNh"))
        XCTAssertNil(KeyInstaller.validate(publicKey: "sk-ssh-ed25519@openssh.com AAAAGn NFC"))
    }

    func testAcceptsAKeyWithNoComment() {
        XCTAssertNil(KeyInstaller.validate(publicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5"))
    }

    func testRejectsEmptyKey() {
        XCTAssertEqual(KeyInstaller.validate(publicKey: "   "), .emptyKey)
    }

    func testRejectsMultilineKey() {
        XCTAssertEqual(
            KeyInstaller.validate(publicKey: "ssh-ed25519 AAAA one\nssh-ed25519 BBBB two"),
            .multipleLines
        )
    }

    func testRejectsTextThatIsNotAPublicKey() {
        XCTAssertEqual(KeyInstaller.validate(publicKey: "hello world"), .notAPublicKey)
        XCTAssertEqual(KeyInstaller.validate(publicKey: "-----BEGIN OPENSSH PRIVATE KEY-----"), .notAPublicKey)
        XCTAssertEqual(KeyInstaller.validate(publicKey: "ssh-ed25519"), .notAPublicKey, "Needs key material")
    }

    func testRejectsEmbeddedControlCharacters() {
        XCTAssertEqual(KeyInstaller.validate(publicKey: "ssh-ed25519 AAAA\u{1B}[0m evil"), .notAPublicKey)
    }

    func testRefusesAHostBehindAJumpHost() {
        var host = HostProfile(name: "Behind bastion", hostname: "internal", port: 22, username: "dev")
        XCTAssertNil(KeyInstaller.validate(host: host))

        host.jumpHostId = UUID()
        XCTAssertEqual(KeyInstaller.validate(host: host), .jumpHostNotSupported)
    }

    // MARK: - Command

    func testCommandQuotesTheKeyAsOneArgument() {
        let command = KeyInstaller.installCommand(for: sampleKey)
        XCTAssertTrue(command.contains("key='\(sampleKey)'"))
    }

    func testCommandEscapesAQuoteInTheComment() {
        // A comment can hold an apostrophe; it must not break out of the shell argument.
        let key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5 jeremy's ipad"
        let command = KeyInstaller.installCommand(for: key)
        XCTAssertTrue(command.contains("'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5 jeremy'\\''s ipad'"))
        XCTAssertFalse(command.contains("jeremy's ipad"), "The raw apostrophe must not survive unquoted")
    }

    func testCommandIsIdempotent() {
        let command = KeyInstaller.installCommand(for: sampleKey)
        XCTAssertTrue(
            command.contains("grep -qxF \"$key\" \"$file\""),
            "An exact duplicate line must never be appended"
        )
        XCTAssertTrue(
            command.contains("then :; else"),
            "The append runs only in the branch where the key is absent"
        )
    }

    func testCommandCreatesDirectoryAndFileWithSafePermissions() {
        let command = KeyInstaller.installCommand(for: sampleKey)
        XCTAssertTrue(command.contains("dir=\"$HOME/.ssh\""))
        XCTAssertTrue(command.contains("file=\"$dir/authorized_keys\""))
        XCTAssertTrue(command.contains("mkdir -p \"$dir\""))
        XCTAssertTrue(command.contains("chmod 700 \"$dir\""))
        XCTAssertTrue(command.contains("chmod 600 \"$file\""))
    }

    func testCommandAddsAMissingNewlineBeforeAppending() {
        // Without this, an authorized_keys whose last line lacks a newline would have the new key welded
        // onto it, breaking both entries.
        let command = KeyInstaller.installCommand(for: sampleKey)
        XCTAssertTrue(command.contains("[ -n \"$(tail -c1 \"$file\")\" ]"))
        XCTAssertTrue(command.contains("printf '\\n' >> \"$file\""))
    }

    func testCommandStopsAtTheFirstFailure() {
        XCTAssertTrue(KeyInstaller.installCommand(for: sampleKey).hasPrefix("set -e"))
    }

    func testCommandAppendsWithATrailingNewline() {
        let command = KeyInstaller.installCommand(for: sampleKey)
        XCTAssertTrue(command.contains("printf '%s\\n' \"$key\""), "Appending without a newline would join two entries")
        XCTAssertTrue(command.contains(">> \"$file\""))
    }

    func testCommandTrimsSurroundingWhitespace() {
        let command = KeyInstaller.installCommand(for: "  \(sampleKey)\n")
        XCTAssertTrue(command.contains("key='\(sampleKey)'"))
    }
}
