import Foundation
import SwiftTerm

/// Abstraction over terminal grid to facilitate thorough unit testing
public protocol TerminalCharacterGrid {
    var cols: Int { get }
    var rows: Int { get }
    func character(col: Int, row: Int) -> Character?
    func explicitLink(col: Int, row: Int) -> String?
}

// Conformance for SwiftTerm.Terminal
extension Terminal: TerminalCharacterGrid {
    public func character(col: Int, row: Int) -> Character? {
        getCharacter(col: col, row: row)
    }

    public func explicitLink(col: Int, row: Int) -> String? {
        guard let data = getCharData(col: col, row: row), data.hasPayload,
              let payload = data.getPayload() as? String else {
            return nil
        }
        let split = payload.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        guard split.count > 1 else { return nil }
        return String(split[1])
    }
}

public struct DetectedUrlMatch: Equatable {
    public let url: String
    public let segments: [(row: Int, colRange: Range<Int>)]

    public init(url: String, segments: [(row: Int, colRange: Range<Int>)]) {
        self.url = url
        self.segments = segments
    }

    public static func == (lhs: DetectedUrlMatch, rhs: DetectedUrlMatch) -> Bool {
        guard lhs.url == rhs.url && lhs.segments.count == rhs.segments.count else { return false }
        for i in 0..<lhs.segments.count {
            if lhs.segments[i].row != rhs.segments[i].row || lhs.segments[i].colRange != rhs.segments[i].colRange {
                return false
            }
        }
        return true
    }
}

public struct TerminalUrlDetector {

    /// Checks if a character represents a box-drawing vertical border character.
    public static func isVerticalBorderChar(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1 else { return false }
        let val = scalar.value
        // Unicode Box Drawing block (U+2500 - U+257F)
        if val >= 0x2500 && val <= 0x257F {
            // Exclude purely horizontal lines
            if val == 0x2500 || val == 0x2501 || val == 0x254C || val == 0x254D || val == 0x2550 {
                return false
            }
            return true
        }
        return false
    }

    /// Checks if the cell at (col, row) is a vertical pane border (box-drawing character or vertical pipe)
    public static func isBorder(col: Int, row: Int, in grid: TerminalCharacterGrid) -> Bool {
        guard col >= 0, col < grid.cols, row >= 0, row < grid.rows else { return false }
        guard let ch = grid.character(col: col, row: row) else { return false }
        if isVerticalBorderChar(ch) {
            return true
        }
        if ch == "|" {
            // Check if adjacent rows at same column also have '|' or box drawing
            if row > 0, let above = grid.character(col: col, row: row - 1), (isVerticalBorderChar(above) || above == "|") {
                return true
            }
            if row + 1 < grid.rows, let below = grid.character(col: col, row: row + 1), (isVerticalBorderChar(below) || below == "|") {
                return true
            }
        }
        return false
    }

    /// Finds the left and right column boundaries of the tmux pane enclosing (col, row)
    public static func findPaneBounds(col: Int, row: Int, in grid: TerminalCharacterGrid) -> (left: Int, right: Int) {
        var left = 0
        var right = max(0, grid.cols - 1)

        // Scan left from col - 1
        if col > 0 {
            for c in stride(from: col - 1, through: 0, by: -1) {
                if isBorder(col: c, row: row, in: grid) {
                    left = c + 1
                    break
                }
            }
        }

        // Scan right from col + 1
        if col < grid.cols - 1 {
            for c in (col + 1)..<grid.cols {
                if isBorder(col: c, row: row, in: grid) {
                    right = c - 1
                    break
                }
            }
        }

        return (left, right)
    }

    /// Determines if a character is valid inside a URL string.
    public static func isUrlChar(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1 else { return false }
        if scalar.isASCII {
            let v = scalar.value
            // 0-9 (48..57), A-Z (65..90), a-z (97..122)
            if (v >= 48 && v <= 57) || (v >= 65 && v <= 90) || (v >= 97 && v <= 122) {
                return true
            }
            switch ch {
            case "-", ".", "_", "~", ":", "/", "?", "#", "[", "]", "@", "!", "$", "&", "'", "(", ")", "*", "+", ",", ";", "=", "%":
                return true
            default:
                return false
            }
        }
        return false
    }

    /// Checks if a row starts with a shell prompt indicator rather than a URL continuation
    private static func isPromptRow(text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("$ ") || trimmed.hasPrefix("# ") || trimmed.hasPrefix("> ") ||
           trimmed.hasPrefix("➜ ") || trimmed.hasPrefix("❯ ") || trimmed.hasPrefix("bash-") {
            return true
        }
        return false
    }

    /// Detects a URL at the specified grid position, stitching across line wraps in tmux panes.
    public static func detectUrl(at col: Int, row: Int, in grid: TerminalCharacterGrid) -> String? {
        detectUrlMatch(at: col, row: row, in: grid)?.url
    }

    /// Detects a URL and its line segments across line wraps in tmux panes.
    public static func detectUrlMatch(at col: Int, row: Int, in grid: TerminalCharacterGrid) -> DetectedUrlMatch? {
        guard col >= 0, col < grid.cols, row >= 0, row < grid.rows else { return nil }

        // 1. Check for explicit OSC 8 hyperlink payload first
        if let explicit = grid.explicitLink(col: col, row: row), !explicit.isEmpty {
            var startCol = col
            while startCol > 0 && grid.explicitLink(col: startCol - 1, row: row) == explicit {
                startCol -= 1
            }
            var endCol = col
            while endCol + 1 < grid.cols && grid.explicitLink(col: endCol + 1, row: row) == explicit {
                endCol += 1
            }
            return DetectedUrlMatch(url: explicit, segments: [(row: row, colRange: startCol..<(endCol + 1))])
        }

        // 2. Reject if the tapped cell is on a pane border
        if isBorder(col: col, row: row, in: grid) {
            return nil
        }

        let (paneLeft, paneRight) = findPaneBounds(col: col, row: row, in: grid)
        guard col >= paneLeft && col <= paneRight else { return nil }

        let targetChars = extractPaneRow(row: row, left: paneLeft, right: paneRight, in: grid)
        let tapOffset = col - paneLeft
        guard tapOffset >= 0, tapOffset < targetChars.count else { return nil }
        guard isUrlChar(targetChars[tapOffset]) else { return nil }

        // Find the continuous URL character span on the tapped row
        var spanStart = tapOffset
        while spanStart > 0 && isUrlChar(targetChars[spanStart - 1]) {
            spanStart -= 1
        }
        var spanEnd = tapOffset
        while spanEnd + 1 < targetChars.count && isUrlChar(targetChars[spanEnd + 1]) {
            spanEnd += 1
        }

        // 3. Step backward to find the start of the URL (if this line was wrapped from above)
        var startRow = row
        var currentSpanStart = spanStart

        // A line is a continuation if the span starts at or near paneLeft and doesn't begin with a scheme
        var checkingRow = row
        while checkingRow > 0 {
            let (currLeft, currRight) = findPaneBounds(col: paneLeft, row: checkingRow, in: grid)
            let currChars = extractPaneRow(row: checkingRow, left: currLeft, right: currRight, in: grid)
            guard currentSpanStart < currChars.count, spanEnd < currChars.count, currentSpanStart <= spanEnd else { break }
            let localSpan = String(currChars[currentSpanStart...spanEnd])
            if hasScheme(localSpan) {
                startRow = checkingRow
                break
            }

            // Check previous row
            let prevRow = checkingRow - 1
            let (prevLeft, prevRight) = findPaneBounds(col: paneLeft, row: prevRow, in: grid)
            let prevChars = extractPaneRow(row: prevRow, left: prevLeft, right: prevRight, in: grid)
            guard !prevChars.isEmpty else { break }

            // Did currentSpanStart start at the beginning of the pane row?
            let isCurrentAtLeftEdge = currentSpanStart <= firstNonSpaceOffset(in: currChars) + 2
            guard isCurrentAtLeftEdge else { break }

            // Did previous line end with URL characters near its right edge?
            var prevEnd = prevChars.count - 1
            while prevEnd >= 0 && prevChars[prevEnd].isWhitespace {
                prevEnd -= 1
            }
            guard prevEnd >= prevChars.count - 2, prevEnd >= 0, isUrlChar(prevChars[prevEnd]) else {
                break
            }

            var prevStart = prevEnd
            while prevStart > 0 && isUrlChar(prevChars[prevStart - 1]) {
                prevStart -= 1
            }

            checkingRow = prevRow
            startRow = prevRow
            currentSpanStart = prevStart
            spanEnd = prevEnd
        }

        // Verify that startRow actually contains a scheme
        let (startLeft, startRight) = findPaneBounds(col: paneLeft, row: startRow, in: grid)
        let startRowChars = extractPaneRow(row: startRow, left: startLeft, right: startRight, in: grid)
        let startRowText = String(startRowChars)
        guard let schemeRange = findSchemeRange(in: startRowText) else {
            return nil
        }
        let schemeStartOffset = startRowText.distance(from: startRowText.startIndex, to: schemeRange.lowerBound)

        // 4. Step forward from startRow to find the end of the URL across wraps
        var endRow = startRow
        var endOffset = startRight - startLeft
        var currentRow = startRow

        while currentRow < grid.rows {
            let (cLeft, cRight) = findPaneBounds(col: paneLeft, row: currentRow, in: grid)
            let cChars = extractPaneRow(row: currentRow, left: cLeft, right: cRight, in: grid)
            let cWidth = cRight - cLeft + 1

            // Does this line end at or near the right edge with URL characters?
            let lineStart = (currentRow == startRow) ? schemeStartOffset : firstNonSpaceOffset(in: cChars)
            var lineEnd = lineStart
            while lineEnd + 1 < cChars.count && isUrlChar(cChars[lineEnd + 1]) {
                lineEnd += 1
            }

            endRow = currentRow
            endOffset = lineEnd

            // If this line does not reach the right pane edge, the URL ends here
            if lineEnd < cWidth - 2 {
                break
            }

            // Check next row for continuation
            let nextRow = currentRow + 1
            guard nextRow < grid.rows else { break }
            let (nLeft, nRight) = findPaneBounds(col: paneLeft, row: nextRow, in: grid)
            let nChars = extractPaneRow(row: nextRow, left: nLeft, right: nRight, in: grid)
            guard !nChars.isEmpty else { break }

            let nStart = firstNonSpaceOffset(in: nChars)
            guard nStart <= 8, nStart < nChars.count, isUrlChar(nChars[nStart]) else { break }

            let nText = String(nChars[nStart...])
            if hasScheme(nText) || isPromptRow(text: nText) {
                break
            }

            currentRow = nextRow
        }

        // 5. Build stitched URL string and collect segments
        var stitched = ""
        var rawSegments: [(row: Int, colRange: Range<Int>)] = []
        for r in startRow...endRow {
            let (pLeft, pRight) = findPaneBounds(col: paneLeft, row: r, in: grid)
            let chars = extractPaneRow(row: r, left: pLeft, right: pRight, in: grid)
            let from = (r == startRow) ? schemeStartOffset : firstNonSpaceOffset(in: chars)
            var to = from
            while to + 1 < chars.count && isUrlChar(chars[to + 1]) {
                to += 1
            }
            if r == endRow {
                to = min(to, endOffset)
            }
            if from <= to && from >= 0 && to < chars.count {
                stitched += String(chars[from...to])
                let startCol = pLeft + from
                let endCol = pLeft + to + 1
                rawSegments.append((row: r, colRange: startCol..<endCol))
            }
        }

        // 6. Clean trailing sentence punctuation & unmatched brackets
        let cleaned = cleanUrl(stitched)
        guard isValidUrl(cleaned) else { return nil }

        // Adjust segments if trailing punctuation was trimmed from the stitched URL
        let trimmedCount = stitched.count - cleaned.count
        var remainingTrim = trimmedCount
        var segments: [(row: Int, colRange: Range<Int>)] = []

        for seg in rawSegments.reversed() {
            let segLen = seg.colRange.count
            if remainingTrim >= segLen {
                remainingTrim -= segLen
                continue
            }
            let newEnd = seg.colRange.upperBound - remainingTrim
            remainingTrim = 0
            if seg.colRange.lowerBound < newEnd {
                segments.insert((row: seg.row, colRange: seg.colRange.lowerBound..<newEnd), at: 0)
            }
        }

        // 7. Ensure original coordinate (col, row) is within the detected URL bounding area
        let isInside = segments.contains { seg in
            seg.row == row && seg.colRange.contains(col)
        }
        guard isInside else { return nil }

        return DetectedUrlMatch(url: cleaned, segments: segments)
    }

    /// Expands a URL if it was truncated at the right edge of a tmux pane.
    public static func expandUrlIfWrapped(link: String, in grid: TerminalCharacterGrid) -> String {
        // Search visible terminal rows for link
        for r in 0..<grid.rows {
            let (left, right) = findPaneBounds(col: 0, row: r, in: grid)
            let chars = extractPaneRow(row: r, left: left, right: right, in: grid)
            let text = String(chars)
            if let range = text.range(of: link) {
                let startCol = left + text.distance(from: text.startIndex, to: range.lowerBound)
                if let expanded = detectUrl(at: startCol, row: r, in: grid), expanded.count > link.count {
                    return expanded
                }
            }
        }
        return link
    }

    // MARK: - Helpers

    private static func extractPaneRow(row: Int, left: Int, right: Int, in grid: TerminalCharacterGrid) -> [Character] {
        guard row >= 0, row < grid.rows, left <= right else { return [] }
        var result: [Character] = []
        result.reserveCapacity(right - left + 1)
        for c in left...right {
            result.append(grid.character(col: c, row: row) ?? " ")
        }
        return result
    }

    private static func firstNonSpaceOffset(in chars: [Character]) -> Int {
        for i in 0..<chars.count {
            if chars[i] != " " { return i }
        }
        return 0
    }

    private static let supportedSchemes = ["https://", "http://", "file://", "ssh://", "git://"]

    private static func hasScheme(_ text: String) -> Bool {
        let lower = text.lowercased()
        return supportedSchemes.contains { lower.contains($0) }
    }

    private static func findSchemeRange(in text: String) -> Range<String.Index>? {
        let lower = text.lowercased()
        var earliestRange: Range<String.Index>? = nil
        for scheme in supportedSchemes {
            if let r = lower.range(of: scheme) {
                if let currentEarliest = earliestRange {
                    if r.lowerBound < currentEarliest.lowerBound {
                        earliestRange = r
                    }
                } else {
                    earliestRange = r
                }
            }
        }
        return earliestRange
    }

    public static func cleanUrl(_ raw: String) -> String {
        var str = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip enclosing quotes/brackets if both ends match
        if (str.hasPrefix("\"") && str.hasSuffix("\"")) ||
           (str.hasPrefix("'") && str.hasSuffix("'")) ||
           (str.hasPrefix("<") && str.hasSuffix(">")) ||
           (str.hasPrefix("`") && str.hasSuffix("`")) {
            str.removeFirst()
            str.removeLast()
        }

        var changed = true
        while changed {
            changed = false
            // Trim trailing punctuation (.,;:!?) or unclosed quotes/angles
            while let last = str.last, [".", ",", ";", ":", "!", "?", ">", "\"", "'", "`"].contains(last) {
                if last == ">" && !str.contains("<") {
                    str.removeLast()
                    changed = true
                } else if last == "\"" && str.filter({ $0 == "\"" }).count % 2 != 0 {
                    str.removeLast()
                    changed = true
                } else if last == "`" && str.filter({ $0 == "`" }).count % 2 != 0 {
                    str.removeLast()
                    changed = true
                } else if [".", ",", ";", ":", "!", "?"].contains(last) {
                    str.removeLast()
                    changed = true
                } else {
                    break
                }
            }

            // Trim trailing unbalanced closing parenthesis
            let openParen = str.filter { $0 == "(" }.count
            let closeParen = str.filter { $0 == ")" }.count
            if closeParen > openParen && str.hasSuffix(")") {
                str.removeLast()
                changed = true
            }

            // Trim trailing unbalanced closing bracket
            let openBracket = str.filter { $0 == "[" }.count
            let closeBracket = str.filter { $0 == "]" }.count
            if closeBracket > openBracket && str.hasSuffix("]") {
                str.removeLast()
                changed = true
            }

            // Trim trailing unbalanced single quote
            let singleQuotes = str.filter { $0 == "'" }.count
            if singleQuotes % 2 != 0 && str.hasSuffix("'") {
                str.removeLast()
                changed = true
            }
        }

        return str
    }

    public static func isValidUrl(_ str: String) -> Bool {
        guard let url = URL(string: str),
              let scheme = url.scheme?.lowercased()
        else {
            return false
        }
        if scheme == "http" || scheme == "https" || scheme == "ssh" || scheme == "git" {
            guard let host = url.host, !host.isEmpty else { return false }
            return true
        } else if scheme == "file" {
            return !url.path.isEmpty
        }
        return false
    }
}
