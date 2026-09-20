import Foundation

public enum SnippetPlaceholderModifier: String, Equatable, Sendable {
    /// One POSIX shell-quoted argument.
    case argument
    /// Deliberate shell source, inserted without quoting.
    case raw
}

/// The shell quoting a placeholder sits inside. It decides how a value is escaped: an unquoted position gets
/// a fully quoted argument, while inside quotes the surrounding quotes already apply and only the characters
/// that would end or subvert them are escaped.
public enum PlaceholderQuoting: Equatable, Sendable {
    case unquoted
    case singleQuoted
    case doubleQuoted
}

public struct SnippetTemplateToken: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case literal(String)
        case placeholder(name: String, modifier: SnippetPlaceholderModifier, quoting: PlaceholderQuoting)
    }

    public let kind: Kind
    /// UTF-16 range in the template, so an editor can highlight exactly what it complains about.
    public let range: NSRange
}

public struct SnippetTemplateError: Error, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case unmatchedOpenDelimiter
        case unmatchedCloseDelimiter
        case emptyPlaceholderName
        case invalidPlaceholderName(String)
        case unknownModifier(String)
        case whitespaceInPlaceholder
        case placeholderInQuotedText
        case placeholderInCommandSubstitution
        case placeholderInBackticks
        case placeholderInHereDoc
        case placeholderJoinedToAdjacentText
        case undefinedParameter(String)
        case templateTooLarge(byteCount: Int, limit: Int)
    }

    public let kind: Kind
    public let range: NSRange

    public init(kind: Kind, range: NSRange) {
        self.kind = kind
        self.range = range
    }
}

public struct SnippetTemplateValidation: Equatable, Sendable {
    public let errors: [SnippetTemplateError]
    public let referencedParameterNames: [String]
    /// Defined but never referenced. Surfaced in the editor; never removed automatically.
    public let unusedParameterNames: [String]

    public var isValid: Bool { errors.isEmpty }
}

public enum SnippetRenderError: Error, Equatable, Sendable {
    case template(SnippetTemplateError)
    case missingRequiredValue(parameter: String)
    case valueTooLarge(parameter: String, byteCount: Int, limit: Int)
    case invalidInteger(parameter: String, value: String)
    case invalidChoice(parameter: String, value: String)
    case expandedTooLarge(byteCount: Int, limit: Int)
}

/// One piece of a rendered command. Keeping the expansion structured means masking a secret changes only the
/// presentation, never the command text or what is handed to the composer.
public struct RenderedSegment: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case literal
        case argument
        case raw
    }

    public let text: String
    public let kind: Kind
    public let parameterName: String?
    public let isSecret: Bool
}

public struct RenderedTemplate: Equatable, Sendable {
    public let segments: [RenderedSegment]

    /// The exact command text. This is what the composer receives.
    public var text: String {
        segments.map(\.text).joined()
    }

    public var containsSecretValues: Bool {
        segments.contains { $0.isSecret }
    }

    /// Presentation only. Never used as the command text, and never as an accessibility value for a secret.
    public func maskedText(revealSecrets: Bool = false) -> String {
        segments.map { segment in
            (segment.isSecret && !revealSecrets) ? "••••••" : segment.text
        }.joined()
    }
}

/// Pure template parsing, shell-context validation, POSIX argument encoding, and rendering. The same renderer
/// produces previews and final text, so a preview can never disagree with what gets submitted.
public enum SnippetTemplateRenderer {

    // MARK: - POSIX argument encoding

    /// Always single-quotes, including `''` for an empty string, and encodes an embedded single quote by
    /// closing the quote, writing an escaped quote, and reopening. Quoting stops shell expansion of the value;
    /// it does not stop a program from reading a leading `-` as an option, and it does not expand `~`,
    /// variables, or globs.
    public static func posixQuoted(_ value: String) -> String {
        "'" + escapedForSingleQuotes(value) + "'"
    }

    /// For a value dropped inside an existing `'...'` region: the only character that matters is the quote
    /// itself, which closes, escapes, and reopens.
    public static func escapedForSingleQuotes(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "'\\''")
    }

    /// For a value dropped inside an existing `"..."` region: the shell still interprets `$`, backticks and
    /// backslashes there, and the closing quote must not be reachable.
    public static func escapedForDoubleQuotes(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count)
        for character in value {
            if character == "\\" || character == "\"" || character == "$" || character == "`" {
                out.append("\\")
            }
            out.append(character)
        }
        return out
    }

    // MARK: - Parsing

    private enum ASCII {
        static let openBrace: UInt16 = 0x7B
        static let closeBrace: UInt16 = 0x7D
        static let singleQuote: UInt16 = 0x27
        static let doubleQuote: UInt16 = 0x22
        static let backtick: UInt16 = 0x60
        static let dollar: UInt16 = 0x24
        static let openParen: UInt16 = 0x28
        static let closeParen: UInt16 = 0x29
        static let lessThan: UInt16 = 0x3C
        static let colon: UInt16 = 0x3A
        static let backslash: UInt16 = 0x5C
        static let space: UInt16 = 0x20
        static let tab: UInt16 = 0x09
        static let newline: UInt16 = 0x0A
        static let carriageReturn: UInt16 = 0x0D
    }

    private static func isWhitespace(_ unit: UInt16) -> Bool {
        unit == ASCII.space || unit == ASCII.tab || unit == ASCII.newline || unit == ASCII.carriageReturn
    }

    /// Conservative shell context. Anything it cannot classify safely is reported as unsupported rather than
    /// treated as an ordinary unquoted position.
    private struct ShellContext {
        var inSingleQuote = false
        var inDoubleQuote = false
        var commandSubstitutionDepth = 0
        var inBacktick = false
        var sawHereDocOperator = false

        /// Quoted regions are supported: the value is escaped for the enclosing quote. Command substitution,
        /// backticks and here-documents remain unsupported, because a value there would be shell source
        /// rather than data.
        func unsupportedPlaceholderKind() -> SnippetTemplateError.Kind? {
            if sawHereDocOperator { return .placeholderInHereDoc }
            if commandSubstitutionDepth > 0 { return .placeholderInCommandSubstitution }
            if inBacktick { return .placeholderInBackticks }
            return nil
        }

        var quoting: PlaceholderQuoting {
            if inSingleQuote { return .singleQuoted }
            if inDoubleQuote { return .doubleQuoted }
            return .unquoted
        }
    }

    public static func parse(_ template: String) -> Result<[SnippetTemplateToken], SnippetTemplateError> {
        let byteCount = template.utf8.count
        guard byteCount <= SnippetLimits.maxTemplateBytes else {
            return .failure(SnippetTemplateError(
                kind: .templateTooLarge(byteCount: byteCount, limit: SnippetLimits.maxTemplateBytes),
                range: NSRange(location: 0, length: 0)
            ))
        }

        let units = Array(template.utf16)
        var tokens: [SnippetTemplateToken] = []
        var literalUnits: [UInt16] = []
        var literalStart = 0
        var context = ShellContext()
        var escaped = false
        var index = 0

        func flushLiteral(endingAt end: Int) {
            guard !literalUnits.isEmpty else { return }
            tokens.append(SnippetTemplateToken(
                kind: .literal(String(decoding: literalUnits, as: UTF16.self)),
                range: NSRange(location: literalStart, length: end - literalStart)
            ))
            literalUnits.removeAll(keepingCapacity: true)
        }

        while index < units.count {
            let unit = units[index]

            // `{{{{` and `}}}}` are the literal forms of the delimiters.
            if unit == ASCII.openBrace, index + 3 < units.count,
               units[index + 1] == ASCII.openBrace,
               units[index + 2] == ASCII.openBrace,
               units[index + 3] == ASCII.openBrace {
                literalUnits.append(ASCII.openBrace)
                literalUnits.append(ASCII.openBrace)
                index += 4
                escaped = false
                continue
            }
            if unit == ASCII.closeBrace, index + 3 < units.count,
               units[index + 1] == ASCII.closeBrace,
               units[index + 2] == ASCII.closeBrace,
               units[index + 3] == ASCII.closeBrace {
                literalUnits.append(ASCII.closeBrace)
                literalUnits.append(ASCII.closeBrace)
                index += 4
                escaped = false
                continue
            }

            if unit == ASCII.openBrace, index + 1 < units.count, units[index + 1] == ASCII.openBrace {
                let placeholderStart = index
                guard let closeIndex = findClosingDelimiter(units, from: index + 2) else {
                    return .failure(SnippetTemplateError(
                        kind: .unmatchedOpenDelimiter,
                        range: NSRange(location: placeholderStart, length: units.count - placeholderStart)
                    ))
                }
                let range = NSRange(location: placeholderStart, length: closeIndex + 2 - placeholderStart)

                if let unsupported = context.unsupportedPlaceholderKind() {
                    return .failure(SnippetTemplateError(kind: unsupported, range: range))
                }

                let quoting = context.quoting
                let followingIndex = closeIndex + 2

                // Unquoted, a placeholder stands alone as one shell word so the one-placeholder/one-argument
                // contract stays unambiguous. Inside quotes the whole quoted region is already one word, so
                // neighbouring text is fine.
                if quoting == .unquoted {
                    let precedingIsBoundary = placeholderStart == 0 || isWhitespace(units[placeholderStart - 1])
                    let followingIsBoundary = followingIndex >= units.count || isWhitespace(units[followingIndex])
                    guard precedingIsBoundary && followingIsBoundary else {
                        return .failure(SnippetTemplateError(kind: .placeholderJoinedToAdjacentText, range: range))
                    }
                }

                let inner = Array(units[(index + 2)..<closeIndex])
                switch parsePlaceholderBody(inner, range: range) {
                case .failure(let error):
                    return .failure(error)
                case .success(let placeholder):
                    flushLiteral(endingAt: placeholderStart)
                    tokens.append(SnippetTemplateToken(
                        kind: .placeholder(
                            name: placeholder.name,
                            modifier: placeholder.modifier,
                            quoting: quoting
                        ),
                        range: range
                    ))
                    literalStart = followingIndex
                    index = followingIndex
                    escaped = false
                    continue
                }
            }

            if unit == ASCII.closeBrace, index + 1 < units.count, units[index + 1] == ASCII.closeBrace {
                return .failure(SnippetTemplateError(
                    kind: .unmatchedCloseDelimiter,
                    range: NSRange(location: index, length: 2)
                ))
            }

            // Ordinary literal character: track shell context so placeholder positions can be classified.
            if escaped {
                escaped = false
            } else if context.inSingleQuote {
                if unit == ASCII.singleQuote { context.inSingleQuote = false }
            } else {
                switch unit {
                case ASCII.backslash:
                    escaped = true
                case ASCII.singleQuote:
                    if !context.inDoubleQuote { context.inSingleQuote = true }
                case ASCII.doubleQuote:
                    context.inDoubleQuote.toggle()
                case ASCII.backtick:
                    context.inBacktick.toggle()
                case ASCII.dollar:
                    if index + 1 < units.count, units[index + 1] == ASCII.openParen {
                        context.commandSubstitutionDepth += 1
                        literalUnits.append(unit)
                        literalUnits.append(units[index + 1])
                        index += 2
                        continue
                    }
                case ASCII.closeParen:
                    if context.commandSubstitutionDepth > 0 { context.commandSubstitutionDepth -= 1 }
                case ASCII.lessThan:
                    if index + 1 < units.count, units[index + 1] == ASCII.lessThan {
                        context.sawHereDocOperator = true
                    }
                default:
                    break
                }
            }

            if literalUnits.isEmpty { literalStart = index }
            literalUnits.append(unit)
            index += 1
        }

        flushLiteral(endingAt: units.count)
        return .success(tokens)
    }

    private static func findClosingDelimiter(_ units: [UInt16], from start: Int) -> Int? {
        var index = start
        while index + 1 < units.count {
            if units[index] == ASCII.closeBrace && units[index + 1] == ASCII.closeBrace {
                return index
            }
            index += 1
        }
        return nil
    }

    private struct ParsedPlaceholder {
        let name: String
        let modifier: SnippetPlaceholderModifier
    }

    private static func parsePlaceholderBody(
        _ inner: [UInt16],
        range: NSRange
    ) -> Result<ParsedPlaceholder, SnippetTemplateError> {
        guard !inner.isEmpty else {
            return .failure(SnippetTemplateError(kind: .emptyPlaceholderName, range: range))
        }
        if inner.contains(where: isWhitespace) {
            return .failure(SnippetTemplateError(kind: .whitespaceInPlaceholder, range: range))
        }

        let parts = inner.split(separator: ASCII.colon, omittingEmptySubsequences: false)
        let nameUnits = Array(parts[0])
        let name = String(decoding: nameUnits, as: UTF16.self)

        guard !name.isEmpty else {
            return .failure(SnippetTemplateError(kind: .emptyPlaceholderName, range: range))
        }
        guard SnippetParameter.isValidName(name) else {
            return .failure(SnippetTemplateError(kind: .invalidPlaceholderName(name), range: range))
        }

        guard parts.count > 1 else {
            return .success(ParsedPlaceholder(name: name, modifier: .argument))
        }
        guard parts.count == 2 else {
            let modifier = String(decoding: Array(parts[1]), as: UTF16.self)
            return .failure(SnippetTemplateError(kind: .unknownModifier(modifier), range: range))
        }

        let modifierText = String(decoding: Array(parts[1]), as: UTF16.self)
        guard let modifier = SnippetPlaceholderModifier(rawValue: modifierText), modifier == .raw else {
            return .failure(SnippetTemplateError(kind: .unknownModifier(modifierText), range: range))
        }
        return .success(ParsedPlaceholder(name: name, modifier: .raw))
    }

    // MARK: - Validation

    public static func validate(template: String, parameters: [SnippetParameter]) -> SnippetTemplateValidation {
        switch parse(template) {
        case .failure(let error):
            return SnippetTemplateValidation(
                errors: [error],
                referencedParameterNames: [],
                unusedParameterNames: parameters.map(\.name)
            )

        case .success(let tokens):
            var referenced: [String] = []
            var errors: [SnippetTemplateError] = []
            let defined = Set(parameters.map(\.name))

            for token in tokens {
                guard case .placeholder(let name, _, _) = token.kind else { continue }
                if !referenced.contains(name) { referenced.append(name) }
                if !defined.contains(name) {
                    errors.append(SnippetTemplateError(kind: .undefinedParameter(name), range: token.range))
                }
            }

            let unused = parameters.map(\.name).filter { !referenced.contains($0) }
            return SnippetTemplateValidation(
                errors: errors,
                referencedParameterNames: referenced,
                unusedParameterNames: unused
            )
        }
    }

    // MARK: - Rendering

    /// Substitutes in one pass: a value containing `{{other}}` stays data and is never expanded again.
    public static func render(
        template: String,
        parameters: [SnippetParameter],
        values: [String: String]
    ) -> Result<RenderedTemplate, SnippetRenderError> {
        let tokens: [SnippetTemplateToken]
        switch parse(template) {
        case .failure(let error): return .failure(.template(error))
        case .success(let parsed): tokens = parsed
        }

        let definitions = Dictionary(parameters.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var segments: [RenderedSegment] = []
        var byteCount = 0

        for token in tokens {
            switch token.kind {
            case .literal(let text):
                byteCount += text.utf8.count
                guard byteCount <= SnippetLimits.maxExpandedBytes else {
                    return .failure(.expandedTooLarge(byteCount: byteCount, limit: SnippetLimits.maxExpandedBytes))
                }
                segments.append(RenderedSegment(text: text, kind: .literal, parameterName: nil, isSecret: false))

            case .placeholder(let name, let modifier, let quoting):
                guard let parameter = definitions[name] else {
                    return .failure(.template(SnippetTemplateError(
                        kind: .undefinedParameter(name),
                        range: token.range
                    )))
                }

                let provided = values[name]
                let resolved = provided ?? parameter.defaultValue ?? ""
                if resolved.isEmpty && parameter.required {
                    return .failure(.missingRequiredValue(parameter: name))
                }

                let valueBytes = resolved.utf8.count
                guard valueBytes <= SnippetLimits.maxParameterValueBytes else {
                    return .failure(.valueTooLarge(
                        parameter: name,
                        byteCount: valueBytes,
                        limit: SnippetLimits.maxParameterValueBytes
                    ))
                }

                switch parameter.kind {
                case .integer:
                    guard isValidInteger(resolved) else {
                        return .failure(.invalidInteger(parameter: name, value: resolved))
                    }
                case .choice:
                    let allowed = parameter.choices?.map(\.value) ?? []
                    guard allowed.contains(resolved) else {
                        return .failure(.invalidChoice(parameter: name, value: resolved))
                    }
                case .text:
                    break
                }

                // An empty optional argument still occupies its position as '' when unquoted. Inside quotes
                // the enclosing quotes already delimit it, so only escaping is applied.
                let rendered: String
                if modifier == .raw {
                    rendered = resolved
                } else {
                    switch quoting {
                    case .unquoted: rendered = posixQuoted(resolved)
                    case .singleQuoted: rendered = escapedForSingleQuotes(resolved)
                    case .doubleQuoted: rendered = escapedForDoubleQuotes(resolved)
                    }
                }
                byteCount += rendered.utf8.count
                guard byteCount <= SnippetLimits.maxExpandedBytes else {
                    return .failure(.expandedTooLarge(byteCount: byteCount, limit: SnippetLimits.maxExpandedBytes))
                }
                segments.append(RenderedSegment(
                    text: rendered,
                    kind: modifier == .raw ? .raw : .argument,
                    parameterName: name,
                    isSecret: parameter.isSecret
                ))
            }
        }

        return .success(RenderedTemplate(segments: segments))
    }

    /// Signed decimal without locale grouping, so the rendered argument is what the user typed.
    public static func isValidInteger(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        var digits = Substring(value)
        if digits.first == "-" || digits.first == "+" {
            digits = digits.dropFirst()
        }
        guard !digits.isEmpty else { return false }
        return digits.allSatisfy { $0.isASCII && $0.isNumber }
    }
}
