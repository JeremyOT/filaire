import SwiftUI
import UIKit

/// The command composer: a local editor whose only way to reach the host is an explicit Insert or Run.
/// Admission into the outbound queue is not remote execution, so nothing here reports success.
public struct CommandComposerView: View {
    public let context: TerminalSessionContext
    @Bindable public var interaction: TerminalInteractionState
    @Environment(\.terminalTheme) private var theme

    public init(context: TerminalSessionContext, interaction: TerminalInteractionState) {
        self.context = context
        self.interaction = interaction
    }

    private var hostName: String {
        context.sessionManager.activeHost?.displayName ?? "No Host"
    }

    private var connectionSummary: String {
        switch context.sessionManager.state {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .reconnecting(let attempt): return "Reconnecting (attempt \(attempt))…"
        case .disconnected: return "Disconnected"
        case .failed: return "Connection failed"
        }
    }

    private var isBlockedByPrompt: Bool {
        context.sessionManager.pendingSecurityPrompt != nil
    }

    private var canSubmit: Bool {
        context.sessionManager.state.isConnected
            && !isBlockedByPrompt
            && !interaction.draftText.isEmpty
            && interaction.isDraftWithinSizeLimit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            CommandEditorView(
                text: $interaction.draftText,
                selection: $interaction.draftSelection,
                onRun: { submit(.run) },
                onDismiss: { context.closeComposer() }
            )
            .frame(minHeight: 96, maxHeight: 220)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            if interaction.isDraftEphemeral {
                label("This draft contains expanded secret values and is discarded when you close it.", color: theme.warning)
            }

            if let error = interaction.inlineError {
                label(error, color: theme.error)
            }

            if let notice = interaction.evictionNotice {
                label(notice, color: theme.tertiaryText)
                    .onTapGesture { interaction.acknowledgeEvictionNotice() }
            }

            actions
        }
        .padding(12)
        .background(Color(uiColor: theme.secondarySurface))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .alert("Snippet text", isPresented: Binding(
            get: { interaction.pendingPrefill != nil },
            set: { if !$0 { interaction.cancelPendingPrefill() } }
        )) {
            Button("Replace draft") { interaction.resolvePendingPrefill(.replace) }
            Button("Append to draft") { interaction.resolvePendingPrefill(.append) }
            Button("Cancel", role: .cancel) { interaction.cancelPendingPrefill() }
        } message: {
            Text("This editor already contains a draft.")
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(hostName)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color(uiColor: theme.primaryText))
                .lineLimit(1)

            Text("• \(connectionSummary)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color(uiColor: theme.tertiaryText))
                .lineLimit(1)

            Spacer()

            Button("Close") { context.closeComposer() }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(uiColor: theme.secondaryText))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Composing for \(hostName), \(connectionSummary)")
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button("Snippets") { context.openSnippetLibrary() }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(uiColor: theme.secondaryText))

            Button("Save") { context.saveDraftAsSnippet() }
                .disabled(interaction.draftText.isEmpty || interaction.isDraftEphemeral)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(uiColor: theme.secondaryText))

            Button("Clear") { interaction.clearDraft() }
                .disabled(interaction.draftText.isEmpty)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(uiColor: theme.secondaryText))

            Spacer()

            Button("Insert") { submit(.insert) }
                .disabled(!canSubmit)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(uiColor: canSubmit ? theme.primaryText : theme.mutedText))

            Button("Run") { submit(.run) }
                .disabled(!canSubmit)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color(uiColor: canSubmit ? theme.success : theme.mutedText))
        }
    }

    private func label(_ text: String, color: UIColor) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Color(uiColor: color))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func submit(_ action: TerminalSubmissionAction) {
        guard canSubmit else { return }
        context.submitComposerDraft(action: action)
    }
}
