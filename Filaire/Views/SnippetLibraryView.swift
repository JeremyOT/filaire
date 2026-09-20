import SwiftUI

/// The snippet library: favorites, this host, all hosts, and any snippets orphaned by a deleted host.
/// Selecting a snippet opens its parameter form; nothing here ever sends bytes.
public struct SnippetLibraryView: View {
    public let context: TerminalSessionContext
    @Bindable public var interaction: TerminalInteractionState
    @State private var query: String = ""
    @State private var storeMessage: String?

    private var store: SnippetStore { SnippetStore.shared }

    public init(context: TerminalSessionContext, interaction: TerminalInteractionState) {
        self.context = context
        self.interaction = interaction
    }

    private var hostID: UUID? { context.sessionManager.activeHost?.id }

    private var configuredHostIDs: Set<UUID> {
        Set(context.sessionManager.allHosts.map(\.id))
    }

    private var matches: [CommandSnippet] {
        store.search(query, forHost: hostID)
    }

    private var favorites: [CommandSnippet] { matches.filter(\.isFavorite) }
    private var thisHost: [CommandSnippet] { matches.filter { $0.scope.hostID != nil } }
    private var allHosts: [CommandSnippet] { matches.filter { $0.scope.hostID == nil } }
    private var orphans: [CommandSnippet] { store.orphaned(configuredHostIDs: configuredHostIDs) }

    public var body: some View {
        NavigationStack {
            List {
                if let notice = store.recoveryNotice {
                    Section {
                        Text(notice)
                            .font(.footnote)
                            .foregroundStyle(Color(uiColor: SolarizedDarkTheme.yellow))
                        Button("Dismiss") { store.acknowledgeRecoveryNotice() }
                    }
                }

                if let storeMessage {
                    Section {
                        Text(storeMessage)
                            .font(.footnote)
                            .foregroundStyle(Color(uiColor: SolarizedDarkTheme.red))
                    }
                }

                if case .unreadable(let reason) = store.loadState {
                    Section {
                        Text(reason)
                            .font(.footnote)
                            .foregroundStyle(Color(uiColor: SolarizedDarkTheme.red))
                    }
                }

                section("Favorites", favorites)
                section("This host", thisHost)
                section("All hosts", allHosts)

                if !orphans.isEmpty {
                    Section("Unassigned") {
                        ForEach(orphans) { snippet in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(snippet.name).font(.body)
                                Text("The host this snippet belonged to no longer exists.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .swipeActions {
                                Button("Make global") { perform { await store.reassign(ids: [snippet.id], to: .global) } }
                                Button("Delete", role: .destructive) { perform { await store.delete(id: snippet.id) } }
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Search names, descriptions, labels")
            .navigationTitle("Snippets")
            // Presented from inside the library: a sheet cannot be raised by a view that is already
            // presenting one, which is why tapping a snippet appeared to do nothing.
            .sheet(item: Binding(
                get: { interaction.snippetInvocation.map { SnippetInvocationBox(invocation: $0) } },
                set: { if $0 == nil { interaction.cancelInvocation() } }
            )) { _ in
                SnippetParameterView(context: context, interaction: interaction)
            }
            .sheet(item: Binding(
                get: { interaction.snippetEditorDraft.map { SnippetDraftBox(snippet: $0) } },
                set: { if $0 == nil { interaction.closeSnippetEditor() } }
            )) { box in
                SnippetEditorView(context: context, interaction: interaction, draft: box.snippet)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { context.closeSnippetLibrary() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("New") {
                        interaction.beginSnippetEditor(CommandSnippet(name: "", template: ""))
                    }
                    .disabled(!store.canSave)
                }
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ snippets: [CommandSnippet]) -> some View {
        if !snippets.isEmpty {
            Section(title) {
                ForEach(snippets) { snippet in
                    Button {
                        guard let hostID else { return }
                        interaction.beginInvocation(of: snippet, forHost: hostID)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(snippet.name)
                                .font(.body)
                                .foregroundStyle(Color(uiColor: SolarizedDarkTheme.base1))
                            if !snippet.description.isEmpty {
                                Text(snippet.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(snippet.template)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .disabled(hostID == nil)
                    .swipeActions(edge: .leading) {
                        Button(snippet.isFavorite ? "Unfavorite" : "Favorite") {
                            perform { await store.setFavorite(!snippet.isFavorite, id: snippet.id) }
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Edit") { interaction.beginSnippetEditor(snippet) }
                        Button("Duplicate") { perform { await store.duplicate(id: snippet.id) } }
                        Button("Delete", role: .destructive) { perform { await store.delete(id: snippet.id) } }
                    }
                }
            }
        }
    }

    /// Surfaces a store failure instead of silently dropping it.
    private func perform(_ action: @escaping @MainActor () async -> SnippetStore.SaveOutcome) {
        Task { @MainActor in
            switch await action() {
            case .saved:
                storeMessage = nil
            case .conflict:
                storeMessage = "Another window changed that snippet. Reopen it to see the latest version."
            case .rejected(let message), .failed(let message):
                storeMessage = message
            }
        }
    }
}
