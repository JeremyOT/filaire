import XCTest
@testable import Filaire

/// Pure preparation and encoding tests: no connection, no queue, no UI.
final class TerminalInputSubmissionTests: XCTestCase {

    private let target = TerminalSubmissionTarget(hostID: UUID(), connectionID: UUID())

    private func prepared(
        _ text: String,
        action: TerminalSubmissionAction = .insert,
        bracketedPaste: Bool = false
    ) -> PreparedTerminalSubmission? {
        switch TerminalInputSubmission.prepare(
            text: text,
            action: action,
            target: target,
            bracketedPasteEnabled: bracketedPaste
        ) {
        case .success(let submission): return submission
        case .failure: return nil
        }
    }

    private func failure(
        _ text: String,
        action: TerminalSubmissionAction = .insert,
        bracketedPaste: Bool = false
    ) -> TerminalSubmissionPreparationError? {
        switch TerminalInputSubmission.prepare(
            text: text,
            action: action,
            target: target,
            bracketedPasteEnabled: bracketedPaste
        ) {
        case .success: return nil
        case .failure(let error): return error
        }
    }

    // MARK: - Encoding

    func testInsertSingleLineSendsTextWithoutSubmitKey() {
        let submission = prepared("ls -la")
        XCTAssertEqual(submission?.payload, Array("ls -la".utf8))
    }

    func testRunAppendsExactlyOneCarriageReturn() {
        let submission = prepared("ls -la", action: .run)
        XCTAssertEqual(submission?.payload, Array("ls -la".utf8) + [0x0D])
        XCTAssertEqual(submission?.payload.filter { $0 == 0x0D }.count, 1)
        XCTAssertEqual(submission?.payload.filter { $0 == 0x0A }.count, 0, "Run must not add an LF alongside the CR")
    }

    func testBracketedPasteWrapsTextAndRunCarriageReturnFollowsEndMarker() {
        guard let submission = prepared("echo hi", action: .run, bracketedPaste: true) else {
            return XCTFail("expected a prepared submission")
        }
        let start: [UInt8] = [0x1b, 0x5b, 0x32, 0x30, 0x30, 0x7e]
        let end: [UInt8] = [0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e]
        XCTAssertEqual(submission.payload, start + Array("echo hi".utf8) + end + [0x0D])
    }

    func testInsertWithBracketedPasteAddsNoCarriageReturn() {
        let submission = prepared("echo hi", bracketedPaste: true)
        XCTAssertEqual(submission?.payload.last, 0x7e, "Insert must end with the bracketed-paste end marker")
    }

    func testMultilineRequiresBracketedPaste() {
        XCTAssertEqual(failure("one\ntwo"), .multilineRequiresBracketedPaste)
        XCTAssertNotNil(prepared("one\ntwo", bracketedPaste: true))
    }

    // MARK: - Normalization

    func testCrlfAndLoneCrNormalizeToLf() {
        let submission = prepared("one\r\ntwo\rthree", bracketedPaste: true)
        XCTAssertEqual(submission?.normalizedText, "one\ntwo\nthree")
        XCTAssertEqual(submission?.didNormalizeLineEndings, true)
    }

    func testUnchangedTextReportsNoNormalization() {
        XCTAssertEqual(prepared("plain")?.didNormalizeLineEndings, false)
    }

    func testTrailingNewlineAndSpacesArePreserved() {
        let submission = prepared("echo hi  \n", bracketedPaste: true)
        XCTAssertEqual(submission?.normalizedText, "echo hi  \n")
    }

    // MARK: - Validation

    func testTabAndUnicodeAreAllowed() {
        let text = "echo\t'héllo 🌍 世界'"
        XCTAssertEqual(prepared(text)?.payload, Array(text.utf8))
    }

    func testEmptyTextIsRejected() {
        XCTAssertEqual(failure(""), .empty)
    }

    func testEscapeIsRejectedWithPosition() {
        guard case .forbiddenControlCharacter(let scalar, let offset)? = failure("ab\u{1B}[0m") else {
            return XCTFail("expected a forbidden control character")
        }
        XCTAssertEqual(scalar.value, 0x1B)
        XCTAssertEqual(offset, 2)
    }

    func testNulDelAndC1AreRejected() {
        for scalar: Unicode.Scalar in ["\u{00}", "\u{7F}", "\u{85}"] {
            guard case .forbiddenControlCharacter? = failure("ok\(scalar)") else {
                return XCTFail("expected \(scalar.value) to be rejected")
            }
        }
    }

    func testPositionIsUtf16OffsetIntoNormalizedText() {
        // The emoji is a surrogate pair, so the ESC after it sits at UTF-16 offset 2.
        guard case .forbiddenControlCharacter(_, let offset)? = failure("🌍\u{1B}") else {
            return XCTFail("expected a forbidden control character")
        }
        XCTAssertEqual(offset, 2)
    }

    // MARK: - Bounds

    func testDraftAtTheByteLimitIsAccepted() {
        let text = String(repeating: "a", count: TerminalInputSubmission.maxDraftBytes)
        XCTAssertNotNil(prepared(text))
    }

    func testDraftOverTheByteLimitIsRejected() {
        let limit = TerminalInputSubmission.maxDraftBytes
        guard case .tooLarge(let byteCount, let reported)? = failure(String(repeating: "a", count: limit + 1)) else {
            return XCTFail("expected an oversized draft to be rejected")
        }
        XCTAssertEqual(byteCount, limit + 1)
        XCTAssertEqual(reported, limit)
    }

    func testLimitCountsUtf8BytesNotCharacters() {
        // Four bytes per emoji: a quarter of the limit in characters already reaches it.
        let text = String(repeating: "🌍", count: TerminalInputSubmission.maxDraftBytes / 4 + 1)
        guard case .tooLarge? = failure(text) else {
            return XCTFail("expected multibyte text to be measured in UTF-8 bytes")
        }
    }
}
