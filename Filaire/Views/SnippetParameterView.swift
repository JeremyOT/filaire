import SwiftUI

/// Fills a snippet's parameters and shows the exact command it expands to. The preview comes from the same
/// renderer that produces the final text, so it can never disagree with what the composer receives.
///
/// The live invocation is read from the interaction state rather than captured, so every keystroke is
/// reflected in both the fields and the preview.
public struct SnippetParameterView: View {
    public let context: TerminalSessionContext
    @Bindable public var interaction: TerminalInteractionState

    public init(context: TerminalSessionContext, interaction: TerminalInteractionState) {
        self.context = context
        self.interaction = interaction
    }

    public var body: some View {
        NavigationStack {
            Group {
                if let invocation = interaction.snippetInvocation {
                    form(for: invocation)
                        .navigationTitle(invocation.snippet.name)
                } else {
                    Color.clear
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { interaction.cancelInvocation() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Open in composer") { openInComposer() }
                        .disabled(!canTransfer)
                }
            }
        }
    }

    // MARK: - Derived state

    private var currentHostID: UUID? { context.sessionManager.activeHost?.id }

    /// The form was opened for one host; it must not transfer into a different session.
    private func destinationChanged(_ invocation: TerminalInteractionState.SnippetInvocation) -> Bool {
        currentHostID != invocation.hostID
    }

    private func renderResult(
        _ invocation: TerminalInteractionState.SnippetInvocation
    ) -> Result<RenderedTemplate, SnippetRenderError> {
        SnippetTemplateRenderer.render(
            template: invocation.snippet.template,
            parameters: invocation.snippet.parameters,
            values: invocation.values
        )
    }

    private func rendered(
        _ invocation: TerminalInteractionState.SnippetInvocation
    ) -> RenderedTemplate? {
        if case .success(let value) = renderResult(invocation) { return value }
        return nil
    }

    private var canTransfer: Bool {
        guard let invocation = interaction.snippetInvocation else { return false }
        return rendered(invocation) != nil && !destinationChanged(invocation)
    }

    private func problem(_ invocation: TerminalInteractionState.SnippetInvocation) -> String? {
        guard case .failure(let error) = renderResult(invocation) else { return nil }
        switch error {
        case .template(let templateError):
            return SnippetStore.describe(templateError)
        case .missingRequiredValue(let parameter):
            return "Fill in \(label(for: parameter, in: invocation))."
        case .valueTooLarge(let parameter, _, let limit):
            return "\(label(for: parameter, in: invocation)) is longer than \(limit) bytes."
        case .invalidInteger(let parameter, _):
            return "\(label(for: parameter, in: invocation)) must be a whole number."
        case .invalidChoice(let parameter, _):
            return "Choose a valid option for \(label(for: parameter, in: invocation))."
        case .expandedTooLarge(_, let limit):
            return "The expanded command is longer than \(limit) bytes."
        }
    }

    private func label(
        for parameterName: String,
        in invocation: TerminalInteractionState.SnippetInvocation
    ) -> String {
        invocation.snippet.parameters.first { $0.name == parameterName }?.label ?? parameterName
    }

    // MARK: - Form

    @ViewBuilder
    private func form(for invocation: TerminalInteractionState.SnippetInvocation) -> some View {
        Form {
            Section("Destination") {
                Text(context.sessionManager.activeHost?.displayName ?? "No host")
                    .font(.system(.body, design: .monospaced))
                if destinationChanged(invocation) {
                    Text("The selected host changed since you opened this snippet. Choose a valid destination before continuing.")
                        .font(.caption)
                        .foregroundStyle(Color(uiColor: SolarizedDarkTheme.yellow))
                }
                Text("POSIX shell quoting (sh, bash, zsh)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !invocation.snippet.parameters.isEmpty {
                Section("Parameters") {
                    ForEach(invocation.snippet.parameters) { parameter in
                        field(for: parameter, in: invocation)
                    }
                }
            }

            Section("Exact command") {
                if let rendered = rendered(invocation) {
                    let shown = rendered.maskedText(revealSecrets: invocation.revealSecrets)
                    Text(shown)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .accessibilityLabel(
                            rendered.containsSecretValues && !invocation.revealSecrets
                                ? "Command preview with secret values hidden"
                                : shown
                        )
                    if rendered.containsSecretValues {
                        Toggle("Reveal secret values", isOn: Binding(
                            get: { invocation.revealSecrets },
                            set: { interaction.setRevealSecrets($0) }
                        ))
                        .font(.caption)
                        Text("Once sent, a secret is part of the command text and may enter the remote shell history.")
                            .font(.caption)
                            .foregroundStyle(Color(uiColor: SolarizedDarkTheme.yellow))
                    }
                } else if let problem = problem(invocation) {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(Color(uiColor: SolarizedDarkTheme.red))
                }
            }
        }
    }

    @ViewBuilder
    private func field(
        for parameter: SnippetParameter,
        in invocation: TerminalInteractionState.SnippetInvocation
    ) -> some View {
        let binding = Binding(
            get: { interaction.snippetInvocation?.value(for: parameter.name) ?? "" },
            set: { interaction.updateInvocationValue($0, for: parameter.name) }
        )

        VStack(alignment: .leading, spacing: 4) {
            switch parameter.kind {
            case .text:
                if parameter.isSecret {
                    SecureField(parameter.label, text: binding)
                } else {
                    TextField(parameter.label, text: binding)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
            case .integer:
                TextField(parameter.label, text: binding)
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
            case .choice:
                Picker(parameter.label, selection: binding) {
                    Text("Choose…").tag("")
                    ForEach(parameter.choices ?? []) { choice in
                        Text(choice.label).tag(choice.value)
                    }
                }
            }

            if let help = parameter.help, !help.isEmpty {
                Text(help).font(.caption).foregroundStyle(.secondary)
            }
            if !parameter.required {
                Text("Optional. An empty value still occupies its place as ''.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Transfers the expanded text to this scene's composer. No bytes are sent here.
    private func openInComposer() {
        guard let invocation = interaction.snippetInvocation,
              let rendered = rendered(invocation),
              !destinationChanged(invocation) else { return }

        let text = rendered.text
        let hasSecrets = rendered.containsSecretValues
        interaction.cancelInvocation()
        context.closeSnippetLibrary()
        context.openComposer(with: text, containsSecretValues: hasSecrets, origin: .snippet)
    }
}
