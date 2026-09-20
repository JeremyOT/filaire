import SwiftUI

/// Authors a snippet: name, scope, template, and one definition per referenced parameter. Parameterization is
/// explicit — a parameter exists because the template names it.
public struct SnippetEditorView: View {
    public let context: TerminalSessionContext
    @Bindable public var interaction: TerminalInteractionState
    @State private var draft: CommandSnippet
    @State private var message: String?
    @State private var conflict: CommandSnippet?

    private var store: SnippetStore { SnippetStore.shared }

    public init(
        context: TerminalSessionContext,
        interaction: TerminalInteractionState,
        draft: CommandSnippet
    ) {
        self.context = context
        self.interaction = interaction
        self._draft = State(initialValue: draft)
    }

    private var validation: SnippetTemplateValidation {
        SnippetTemplateRenderer.validate(template: draft.template, parameters: draft.parameters)
    }

    private var undefinedNames: [String] {
        validation.referencedParameterNames.filter { name in
            !draft.parameters.contains { $0.name == name }
        }
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Snippet") {
                    TextField("Name", text: $draft.name)
                        .autocorrectionDisabled()
                    TextField("Description", text: $draft.description, axis: .vertical)
                    Toggle("Only on this host", isOn: Binding(
                        get: { draft.scope.hostID != nil },
                        set: { hostOnly in
                            if hostOnly, let hostID = context.sessionManager.activeHost?.id {
                                draft.scope = .host(hostID)
                            } else {
                                draft.scope = .global
                            }
                        }
                    ))
                    .disabled(context.sessionManager.activeHost == nil && draft.scope.hostID == nil)
                }

                Section("Template") {
                    TextEditor(text: $draft.template)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 90)
                        .autocorrectionDisabled()
                    Text("Write {{name}} for one quoted argument. It must stand alone as a whole word, outside quotes. Use {{{{ for a literal {{.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !undefinedNames.isEmpty {
                    Section("Undefined parameters") {
                        ForEach(undefinedNames, id: \.self) { name in
                            HStack {
                                Text(name).font(.system(.body, design: .monospaced))
                                Spacer()
                                Button("Define") {
                                    draft.parameters.append(SnippetParameter(name: name, label: name))
                                }
                            }
                        }
                    }
                }

                if !draft.parameters.isEmpty {
                    Section("Parameter definitions") {
                        ForEach(Array(draft.parameters.enumerated()), id: \.element.name) { index, parameter in
                            definitionRow(index: index, parameter: parameter)
                        }
                    }
                }

                if !validation.unusedParameterNames.isEmpty {
                    Section {
                        Text("Defined but unused: \(validation.unusedParameterNames.joined(separator: ", "))")
                            .font(.caption)
                            .foregroundStyle(Color(uiColor: SolarizedDarkTheme.yellow))
                    }
                }

                if let problem = store.validationMessage(for: draft) {
                    Section {
                        Text(problem)
                            .font(.caption)
                            .foregroundStyle(Color(uiColor: SolarizedDarkTheme.red))
                    }
                }

                if let message {
                    Section {
                        Text(message).font(.caption).foregroundStyle(Color(uiColor: SolarizedDarkTheme.red))
                    }
                }
            }
            .navigationTitle(draft.name.isEmpty ? "New snippet" : draft.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { interaction.closeSnippetEditor() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Save") { save() }
                        .disabled(store.validationMessage(for: draft) != nil || !store.canSave)
                }
            }
            .alert("Another window saved this snippet", isPresented: Binding(
                get: { conflict != nil },
                set: { if !$0 { conflict = nil } }
            )) {
                Button("Reload latest") {
                    if let latest = conflict { draft = latest }
                    conflict = nil
                }
                Button("Save as copy") {
                    // A new identity, so both windows' work survives.
                    draft = CommandSnippet(
                        name: draft.name + " copy",
                        description: draft.description,
                        template: draft.template,
                        scope: draft.scope,
                        parameters: draft.parameters
                    )
                    conflict = nil
                    save()
                }
                Button("Keep editing", role: .cancel) { conflict = nil }
            } message: {
                Text("Your draft is kept either way.")
            }
        }
    }

    @ViewBuilder
    private func definitionRow(index: Int, parameter: SnippetParameter) -> some View {
        DisclosureGroup(parameter.name) {
            TextField("Label", text: binding(index, \.label))
            Picker("Kind", selection: binding(index, \.kind)) {
                Text("Text").tag(SnippetParameterKind.text)
                Text("Whole number").tag(SnippetParameterKind.integer)
                Text("Choice").tag(SnippetParameterKind.choice)
            }
            Toggle("Required", isOn: binding(index, \.required))
            Toggle("Secret", isOn: Binding(
                get: { draft.parameters[index].isSecret },
                set: { isSecret in
                    draft.parameters[index].isSecret = isSecret
                    // A secret can never carry a stored default.
                    if isSecret { draft.parameters[index].defaultValue = nil }
                }
            ))
            if !draft.parameters[index].isSecret {
                TextField("Default value", text: Binding(
                    get: { draft.parameters[index].defaultValue ?? "" },
                    set: { draft.parameters[index].defaultValue = $0.isEmpty ? nil : $0 }
                ))
            }
            if draft.parameters[index].kind == .choice {
                TextField("Choices, comma separated", text: Binding(
                    get: { (draft.parameters[index].choices ?? []).map(\.value).joined(separator: ", ") },
                    set: { text in
                        let values = text.split(separator: ",").map {
                            $0.trimmingCharacters(in: .whitespaces)
                        }.filter { !$0.isEmpty }
                        draft.parameters[index].choices = values.map { SnippetChoice(label: $0, value: $0) }
                    }
                ))
            }
            Button("Remove definition", role: .destructive) {
                draft.parameters.remove(at: index)
            }
        }
    }

    private func binding<Value>(
        _ index: Int,
        _ keyPath: WritableKeyPath<SnippetParameter, Value>
    ) -> Binding<Value> {
        Binding(
            get: { draft.parameters[index][keyPath: keyPath] },
            set: { draft.parameters[index][keyPath: keyPath] = $0 }
        )
    }

    private func save() {
        Task { @MainActor in
            switch await store.save(draft) {
            case .saved:
                interaction.closeSnippetEditor()
            case .conflict(let latest):
                conflict = latest
            case .rejected(let text), .failed(let text):
                message = text
            }
        }
    }
}
