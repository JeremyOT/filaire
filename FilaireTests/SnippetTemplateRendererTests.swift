import XCTest
@testable import Filaire

/// Grammar, shell-context, encoder, and rendering fixtures. No UI and no store: this is the layer everything
/// else in snippets depends on.
final class SnippetTemplateRendererTests: XCTestCase {

    private func parseFailure(_ template: String) -> SnippetTemplateError.Kind? {
        switch SnippetTemplateRenderer.parse(template) {
        case .success: return nil
        case .failure(let error): return error.kind
        }
    }

    private func tokens(_ template: String) -> [SnippetTemplateToken]? {
        switch SnippetTemplateRenderer.parse(template) {
        case .success(let tokens): return tokens
        case .failure: return nil
        }
    }

    private func placeholderNames(_ template: String) -> [String] {
        (tokens(template) ?? []).compactMap {
            if case .placeholder(let name, _, _) = $0.kind { return name }
            return nil
        }
    }

    private func quoting(_ template: String) -> PlaceholderQuoting? {
        (tokens(template) ?? []).compactMap {
            if case .placeholder(_, _, let quoting) = $0.kind { return quoting }
            return nil
        }.first
    }

    // MARK: - POSIX encoder

    func testEncoderAlwaysQuotesIncludingEmptyString() {
        XCTAssertEqual(SnippetTemplateRenderer.posixQuoted(""), "''")
        XCTAssertEqual(SnippetTemplateRenderer.posixQuoted("plain"), "'plain'")
    }

    func testEncoderNeutralizesShellMetacharacters() {
        XCTAssertEqual(SnippetTemplateRenderer.posixQuoted("a b"), "'a b'")
        XCTAssertEqual(SnippetTemplateRenderer.posixQuoted("$(whoami)"), "'$(whoami)'")
        XCTAssertEqual(SnippetTemplateRenderer.posixQuoted("`id`"), "'`id`'")
        XCTAssertEqual(SnippetTemplateRenderer.posixQuoted("a;rm -rf /"), "'a;rm -rf /'")
        XCTAssertEqual(SnippetTemplateRenderer.posixQuoted("line\nbreak"), "'line\nbreak'")
        XCTAssertEqual(SnippetTemplateRenderer.posixQuoted("--flag"), "'--flag'")
        XCTAssertEqual(SnippetTemplateRenderer.posixQuoted("héllo 🌍"), "'héllo 🌍'")
    }

    func testEncoderClosesAndReopensAroundEmbeddedSingleQuotes() {
        XCTAssertEqual(
            SnippetTemplateRenderer.posixQuoted("O'Reilly $(whoami)"),
            "'O'\\''Reilly $(whoami)'"
        )
    }

    func testEncoderTreatsPlaceholderSyntaxInAValueAsData() {
        XCTAssertEqual(SnippetTemplateRenderer.posixQuoted("{{other}}"), "'{{other}}'")
    }

    // MARK: - Grammar

    func testRepeatedPlaceholdersReferenceTheSameParameter() {
        XCTAssertEqual(placeholderNames("cp {{path}} {{path}}"), ["path", "path"])
    }

    func testSuffixWeldedToAPlaceholderIsAdjacentConcatenation() {
        // `{{path}}.bak` would build one shell word from a quoted argument plus literal text.
        XCTAssertEqual(parseFailure("cp {{path}} {{path}}.bak"), .placeholderJoinedToAdjacentText)
    }

    func testLiteralBracesAreUnescaped() {
        guard let tokens = tokens("echo {{{{literal}}}}") else { return XCTFail("expected a parse") }
        let text = tokens.compactMap { token -> String? in
            if case .literal(let value) = token.kind { return value }
            return nil
        }.joined()
        XCTAssertEqual(text, "echo {{literal}}")
        XCTAssertTrue(placeholderNames("echo {{{{literal}}}}").isEmpty)
    }

    func testUnmatchedDelimitersAreErrors() {
        XCTAssertEqual(parseFailure("echo {{name"), .unmatchedOpenDelimiter)
        XCTAssertEqual(parseFailure("echo name}}"), .unmatchedCloseDelimiter)
    }

    func testWhitespaceAndUnknownModifiersAreRejected() {
        XCTAssertEqual(parseFailure("echo {{ name }}"), .whitespaceInPlaceholder)
        XCTAssertEqual(parseFailure("echo {{name:upper}}"), .unknownModifier("upper"))
        XCTAssertEqual(parseFailure("echo {{name:raw:extra}}"), .unknownModifier("raw"))
    }

    func testInvalidAndEmptyNamesAreRejected() {
        XCTAssertEqual(parseFailure("echo {{}}"), .emptyPlaceholderName)
        XCTAssertEqual(parseFailure("echo {{9lives}}"), .invalidPlaceholderName("9lives"))
        XCTAssertEqual(parseFailure("echo {{a-b}}"), .invalidPlaceholderName("a-b"))
    }

    func testRawModifierParses() {
        guard let tokens = tokens("run {{fragment:raw}}") else { return XCTFail("expected a parse") }
        guard case .placeholder(let name, let modifier, _)? = tokens.last?.kind else {
            return XCTFail("expected a placeholder")
        }
        XCTAssertEqual(name, "fragment")
        XCTAssertEqual(modifier, .raw)
    }

    func testErrorsCarrySourceRanges() {
        switch SnippetTemplateRenderer.parse("echo {{ bad }}") {
        case .success: XCTFail("expected a failure")
        case .failure(let error):
            XCTAssertEqual(error.range.location, 5)
            XCTAssertEqual(error.range.length, 9)
        }
    }

    // MARK: - Shell context

    func testPlaceholdersInsideQuotesAreRecognized() {
        XCTAssertEqual(placeholderNames("echo '{{name}}'"), ["name"])
        XCTAssertEqual(placeholderNames("echo \"{{name}}\""), ["name"])
        XCTAssertEqual(quoting("echo '{{name}}'"), .singleQuoted)
        XCTAssertEqual(quoting("echo \"{{name}}\""), .doubleQuoted)
        XCTAssertEqual(quoting("echo {{name}}"), .unquoted)
    }

    func testAdjacentTextIsAllowedInsideQuotes() {
        // The quoted region is already one shell word, so neighbouring text is unambiguous there.
        XCTAssertEqual(placeholderNames("curl \"https://{{host}}/api\""), ["host"])
        XCTAssertEqual(placeholderNames("psql --dbname='{{db}}_prod'"), ["db"])
    }

    func testPlaceholdersInCommandSubstitutionAndBackticksAreRejected() {
        XCTAssertEqual(parseFailure("echo $( {{name}} )"), .placeholderInCommandSubstitution)
        XCTAssertEqual(parseFailure("echo ` {{name}} `"), .placeholderInBackticks)
    }

    func testPlaceholdersAfterAHereDocOperatorAreRejected() {
        XCTAssertEqual(parseFailure("cat <<EOF\n{{name}}\nEOF"), .placeholderInHereDoc)
    }

    func testAdjacentWordConcatenationIsRejected() {
        XCTAssertEqual(parseFailure("echo prefix{{name}}"), .placeholderJoinedToAdjacentText)
        XCTAssertEqual(parseFailure("echo {{name}}suffix"), .placeholderJoinedToAdjacentText)
        XCTAssertEqual(parseFailure("kubectl --namespace={{ns}} get pods"), .placeholderJoinedToAdjacentText)
    }

    func testCompleteShellWordPlaceholderIsAccepted() {
        XCTAssertEqual(placeholderNames("kubectl --namespace {{ns}} get pods"), ["ns"])
    }

    func testLiteralTemplateMayKeepArbitraryShellSyntax() {
        // Restrictions apply to parameter placement, not to literal snippets.
        XCTAssertNotNil(tokens("grep -E 'a|b' \"$HOME\" `date` <<EOF\nbody\nEOF"))
    }

    // MARK: - Validation against definitions

    func testUndefinedParameterIsAnError() {
        let validation = SnippetTemplateRenderer.validate(template: "echo {{missing}}", parameters: [])
        XCTAssertFalse(validation.isValid)
        XCTAssertEqual(validation.errors.first?.kind, .undefinedParameter("missing"))
    }

    func testUnusedDefinitionIsFlaggedButNotAnError() {
        let parameters = [SnippetParameter(name: "used", label: "Used"), SnippetParameter(name: "spare", label: "Spare")]
        let validation = SnippetTemplateRenderer.validate(template: "echo {{used}}", parameters: parameters)
        XCTAssertTrue(validation.isValid)
        XCTAssertEqual(validation.unusedParameterNames, ["spare"])
        XCTAssertEqual(validation.referencedParameterNames, ["used"])
    }

    func testDuplicateDefinitionsAreDetectedOnTheSnippet() {
        let snippet = CommandSnippet(
            name: "dupes",
            template: "echo {{a}}",
            parameters: [SnippetParameter(name: "a", label: "A"), SnippetParameter(name: "a", label: "A again")]
        )
        XCTAssertEqual(snippet.duplicateParameterNames, ["a"])
    }

    // MARK: - Rendering

    private func render(
        _ template: String,
        _ parameters: [SnippetParameter],
        _ values: [String: String]
    ) -> Result<RenderedTemplate, SnippetRenderError> {
        SnippetTemplateRenderer.render(template: template, parameters: parameters, values: values)
    }

    func testRenderQuotesEachValueAsOneArgument() {
        let parameters = [
            SnippetParameter(name: "service", label: "Service"),
            SnippetParameter(name: "lines", label: "Lines", kind: .integer)
        ]
        let result = render(
            "journalctl -u {{service}} -n {{lines}} --no-pager",
            parameters,
            ["service": "nginx proxy", "lines": "50"]
        )
        guard case .success(let rendered) = result else { return XCTFail("expected a render") }
        XCTAssertEqual(rendered.text, "journalctl -u 'nginx proxy' -n '50' --no-pager")
    }

    func testRepeatedPlaceholderUsesTheSameValue() {
        let result = render(
            "cp {{path}} {{path}}",
            [SnippetParameter(name: "path", label: "Path")],
            ["path": "a b.txt"]
        )
        guard case .success(let rendered) = result else { return XCTFail("expected a render") }
        XCTAssertEqual(rendered.text, "cp 'a b.txt' 'a b.txt'")
    }

    func testSubstitutionIsOnePassAndNeverRecursive() {
        let result = render(
            "echo {{outer}}",
            [SnippetParameter(name: "outer", label: "Outer"), SnippetParameter(name: "inner", label: "Inner")],
            ["outer": "{{inner}}", "inner": "surprise"]
        )
        guard case .success(let rendered) = result else { return XCTFail("expected a render") }
        XCTAssertEqual(rendered.text, "echo '{{inner}}'")
    }

    func testValueInsideSingleQuotesIsEscapedForThatRegion() {
        let result = render(
            "echo '{{message}}'",
            [SnippetParameter(name: "message", label: "Message")],
            ["message": "it's fine"]
        )
        guard case .success(let rendered) = result else { return XCTFail("expected a render") }
        // The apostrophe closes, escapes, and reopens without ending the quoted region.
        XCTAssertEqual(rendered.text, "echo 'it'\\''s fine'")
    }

    func testValueInsideDoubleQuotesEscapesExpansionCharacters() {
        let result = render(
            "echo \"{{message}}\"",
            [SnippetParameter(name: "message", label: "Message")],
            ["message": "$HOME `id` \"quoted\" back\\slash"]
        )
        guard case .success(let rendered) = result else { return XCTFail("expected a render") }
        XCTAssertEqual(rendered.text, "echo \"\\$HOME \\`id\\` \\\"quoted\\\" back\\\\slash\"")
    }

    func testQuotedValueDoesNotGainASecondLayerOfQuotes() {
        let result = render(
            "echo '{{name}}'",
            [SnippetParameter(name: "name", label: "Name")],
            ["name": "plain"]
        )
        guard case .success(let rendered) = result else { return XCTFail("expected a render") }
        XCTAssertEqual(rendered.text, "echo 'plain'", "Nested quoting would send the quotes literally")
    }

    func testRawFragmentIsNotQuotedAndIsMarkedDistinctly() {
        let parameters = [SnippetParameter(name: "fragment", label: "Fragment")]
        let result = render("sh -c {{fragment:raw}}", parameters, ["fragment": "a | b"])
        guard case .success(let rendered) = result else { return XCTFail("expected a render") }
        XCTAssertEqual(rendered.text, "sh -c a | b")
        XCTAssertTrue(rendered.segments.contains { $0.kind == .raw && $0.parameterName == "fragment" })
    }

    func testEmptyOptionalArgumentBecomesEmptyQuotesNotARemovedToken() {
        let parameters = [SnippetParameter(name: "filter", label: "Filter", required: false)]
        let result = render("grep {{filter}} file", parameters, [:])
        guard case .success(let rendered) = result else { return XCTFail("expected a render") }
        XCTAssertEqual(rendered.text, "grep '' file")
    }

    func testMissingRequiredValueIsRejected() {
        let parameters = [SnippetParameter(name: "service", label: "Service", required: true)]
        guard case .failure(let error) = render("systemctl status {{service}}", parameters, [:]) else {
            return XCTFail("expected a failure")
        }
        XCTAssertEqual(error, .missingRequiredValue(parameter: "service"))
    }

    func testDefaultValueIsUsedWhenNoValueIsProvided() {
        let parameters = [SnippetParameter(name: "lines", label: "Lines", kind: .integer, defaultValue: "20")]
        let result = render("tail -n {{lines}} log", parameters, [:])
        guard case .success(let rendered) = result else { return XCTFail("expected a render") }
        XCTAssertEqual(rendered.text, "tail -n '20' log")
    }

    func testIntegerAndChoiceValuesAreValidated() {
        let integerParameters = [SnippetParameter(name: "n", label: "N", kind: .integer)]
        guard case .failure(let integerError) = render("head -n {{n}} f", integerParameters, ["n": "1,000"]) else {
            return XCTFail("expected a failure")
        }
        XCTAssertEqual(integerError, .invalidInteger(parameter: "n", value: "1,000"))

        let choiceParameters = [SnippetParameter(
            name: "env",
            label: "Env",
            kind: .choice,
            choices: [SnippetChoice(label: "Production", value: "prod")]
        )]
        guard case .failure(let choiceError) = render("deploy {{env}}", choiceParameters, ["env": "Production"]) else {
            return XCTFail("expected a failure")
        }
        XCTAssertEqual(choiceError, .invalidChoice(parameter: "env", value: "Production"))
    }

    func testChoiceRendersStoredValueNotDisplayLabel() {
        let parameters = [SnippetParameter(
            name: "env",
            label: "Env",
            kind: .choice,
            choices: [SnippetChoice(label: "Production", value: "prod")]
        )]
        let result = render("deploy {{env}}", parameters, ["env": "prod"])
        guard case .success(let rendered) = result else { return XCTFail("expected a render") }
        XCTAssertEqual(rendered.text, "deploy 'prod'")
    }

    func testSignedIntegersAreAccepted() {
        XCTAssertTrue(SnippetTemplateRenderer.isValidInteger("-5"))
        XCTAssertTrue(SnippetTemplateRenderer.isValidInteger("+5"))
        XCTAssertFalse(SnippetTemplateRenderer.isValidInteger(""))
        XCTAssertFalse(SnippetTemplateRenderer.isValidInteger("-"))
        XCTAssertFalse(SnippetTemplateRenderer.isValidInteger("1 000"))
    }

    // MARK: - Secrets

    func testSecretValueIsMaskedInPreviewButPresentInCommandText() {
        let parameters = [SnippetParameter(name: "token", label: "Token", isSecret: true)]
        let result = render("curl -H {{token}} url", parameters, ["token": "s3cret"])
        guard case .success(let rendered) = result else { return XCTFail("expected a render") }

        XCTAssertTrue(rendered.containsSecretValues)
        XCTAssertEqual(rendered.text, "curl -H 's3cret' url")
        XCTAssertFalse(rendered.maskedText().contains("s3cret"))
        XCTAssertTrue(rendered.maskedText(revealSecrets: true).contains("s3cret"))
    }

    func testSecretParameterNeverKeepsAPersistedDefault() {
        let parameter = SnippetParameter(name: "token", label: "Token", defaultValue: "leaked", isSecret: true)
        XCTAssertNil(parameter.defaultValue)
        XCTAssertTrue(parameter.hasPermittedDefault)
    }

    // MARK: - Bounds

    func testOversizedTemplateIsRejectedBeforeParsing() {
        let template = String(repeating: "a", count: SnippetLimits.maxTemplateBytes + 1)
        guard case .templateTooLarge(let byteCount, let limit)? = parseFailure(template) else {
            return XCTFail("expected an oversized template to be rejected")
        }
        XCTAssertEqual(byteCount, SnippetLimits.maxTemplateBytes + 1)
        XCTAssertEqual(limit, SnippetLimits.maxTemplateBytes)
    }

    func testOversizedParameterValueIsRejected() {
        let parameters = [SnippetParameter(name: "blob", label: "Blob")]
        let value = String(repeating: "x", count: SnippetLimits.maxParameterValueBytes + 1)
        guard case .failure(let error) = render("echo {{blob}}", parameters, ["blob": value]) else {
            return XCTFail("expected a failure")
        }
        XCTAssertEqual(
            error,
            .valueTooLarge(
                parameter: "blob",
                byteCount: SnippetLimits.maxParameterValueBytes + 1,
                limit: SnippetLimits.maxParameterValueBytes
            )
        )
    }

    func testRepeatedPlaceholdersCannotExpandPastTheOutputBound() {
        // Ten repeats of an 8 KiB value exceeds the 64 KiB expansion bound.
        let parameters = [SnippetParameter(name: "v", label: "V")]
        let template = Array(repeating: "{{v}}", count: 10).joined(separator: " ")
        let value = String(repeating: "y", count: SnippetLimits.maxParameterValueBytes)
        guard case .failure(let error) = render(template, parameters, ["v": value]) else {
            return XCTFail("expected the expansion to be rejected")
        }
        guard case .expandedTooLarge = error else {
            return XCTFail("expected an expansion bound failure, got \(error)")
        }
    }

    func testMultibyteValuesAreMeasuredInUtf8Bytes() {
        let parameters = [SnippetParameter(name: "v", label: "V")]
        let value = String(repeating: "🌍", count: SnippetLimits.maxParameterValueBytes / 4 + 1)
        guard case .failure(let error) = render("echo {{v}}", parameters, ["v": value]) else {
            return XCTFail("expected a failure")
        }
        guard case .valueTooLarge = error else {
            return XCTFail("expected a value bound failure, got \(error)")
        }
    }

    // MARK: - Scope

    func testHostScopedSnippetIsNotOfferedToAnotherHost() {
        let owner = UUID()
        let snippet = CommandSnippet(name: "restart", template: "echo hi", scope: .host(owner))
        XCTAssertTrue(snippet.isAvailable(forHost: owner))
        XCTAssertFalse(snippet.isAvailable(forHost: UUID()))
        XCTAssertFalse(snippet.isAvailable(forHost: nil))

        let global = CommandSnippet(name: "uptime", template: "uptime", scope: .global)
        XCTAssertTrue(global.isAvailable(forHost: UUID()))
    }
}
