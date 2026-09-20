import SwiftUI

/// What each control does, for the icons that are not self-explanatory. Data-driven so the list and the
/// controls it documents can be checked against each other in tests.
public struct ControlHelpEntry: Identifiable, Equatable, Sendable {
    public var id: String { title }
    public let symbol: String
    public let title: String
    public let detail: String
    /// The keyboard shortcut, where one exists.
    public let shortcut: String?

    public init(symbol: String, title: String, detail: String, shortcut: String? = nil) {
        self.symbol = symbol
        self.title = title
        self.detail = detail
        self.shortcut = shortcut
    }
}

public struct ControlHelpSection: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public let name: String
    public let footer: String?
    public let entries: [ControlHelpEntry]
}

public enum ControlHelp {
    public static let sections: [ControlHelpSection] = [
        ControlHelpSection(
            name: "Composing",
            footer: "Nothing is sent to the host until you choose Insert or Run.",
            entries: [
                ControlHelpEntry(symbol: "text.badge.plus", title: "Snippets", detail: "Saved command templates. Fill in the parameters, check the exact command, then open it in the composer.", shortcut: "Cmd + Shift + S"),
                ControlHelpEntry(symbol: "square.and.pencil", title: "Compose", detail: "Write a command in a normal editor with selection and undo, then insert or run it.", shortcut: "Cmd + Shift + E")
            ]
        ),
        ControlHelpSection(
            name: "tmux panes",
            footer: "Panes divide one window. Breaking a pane out gives it a window of its own, which is easier to read on a phone.",
            entries: [
                ControlHelpEntry(symbol: "arrow.up.left.and.arrow.down.right", title: "Zoom pane", detail: "Expand this pane to fill the window, or restore it."),
                ControlHelpEntry(symbol: "rectangle.split.2x1", title: "Split side by side", detail: "New pane to the right, in the same directory.", shortcut: "Cmd + D"),
                ControlHelpEntry(symbol: "rectangle.split.1x2", title: "Split top and bottom", detail: "New pane below, in the same directory.", shortcut: "Cmd + Shift + D"),
                ControlHelpEntry(symbol: "arrow.right.and.line.vertical.and.arrow.left", title: "Join side by side", detail: "Join the marked pane to the right of this one.", shortcut: "Cmd + J"),
                ControlHelpEntry(symbol: "arrow.down.and.line.horizontal.and.arrow.up", title: "Join top and bottom", detail: "Join the marked pane below this one.", shortcut: "Cmd + Shift + J"),
                ControlHelpEntry(symbol: "pin", title: "Mark pane", detail: "Mark this pane to be joined into another window.", shortcut: "Cmd + M"),
                ControlHelpEntry(symbol: "arrow.2.squarepath", title: "Next pane", detail: "Move to the next pane in this window.", shortcut: "Cmd + Opt + ]"),
                ControlHelpEntry(symbol: "arrow.left.arrow.right", title: "Last pane", detail: "Jump back to the pane you came from."),
                ControlHelpEntry(symbol: "rectangle.portrait.and.arrow.right", title: "Break pane out", detail: "Move this pane into a window of its own.", shortcut: "Cmd + Shift + B"),
                ControlHelpEntry(symbol: "xmark", title: "Close pane", detail: "Close this pane. Closing the last pane closes the window.", shortcut: "Cmd + W")
            ]
        ),
        ControlHelpSection(
            name: "tmux windows",
            footer: "A window is a full screen of its own. Numbers jump straight to a window.",
            entries: [
                ControlHelpEntry(symbol: "number", title: "0 – 9", detail: "Switch to that tmux window.", shortcut: "Cmd + 1…9"),
                ControlHelpEntry(symbol: "chevron.left", title: "Previous window", detail: "Move to the window before this one.", shortcut: "Cmd + P"),
                ControlHelpEntry(symbol: "chevron.right", title: "Next window", detail: "Move to the window after this one.", shortcut: "Cmd + N"),
                ControlHelpEntry(symbol: "plus", title: "New window", detail: "Create a window and switch to it.", shortcut: "Cmd + T"),
                ControlHelpEntry(symbol: "pencil.line", title: "Rename window", detail: "Opens tmux's rename prompt for this window.", shortcut: "Cmd + Shift + R")
            ]
        ),
        ControlHelpSection(
            name: "Keyboard bar",
            footer: "The bar above the keyboard. Ctrl and Alt stay held for the next key you press.",
            entries: [
                ControlHelpEntry(symbol: "keyboard", title: "Ctrl-B", detail: "Sends the tmux prefix on its own, for any tmux command without a button here."),
                ControlHelpEntry(symbol: "doc.on.clipboard", title: "Copy", detail: "Enters tmux's own copy mode for scrolling and selecting with the keyboard.", shortcut: "Cmd + Opt + C"),
                ControlHelpEntry(symbol: "doc.on.doc", title: "Paste", detail: "Pastes the clipboard into the terminal.", shortcut: "Cmd + V"),
                ControlHelpEntry(symbol: "keyboard.chevron.compact.down", title: "Dismiss keyboard", detail: "Puts the keyboard away. Pinned to the right so it never scrolls out of reach.")
            ]
        )
    ]
}

public struct ControlHelpView: View {
    @Environment(\.dismiss) private var dismiss

    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                ForEach(ControlHelp.sections) { section in
                    Section {
                        ForEach(section.entries) { entry in
                            row(entry)
                        }
                    } header: {
                        Text(section.name)
                    } footer: {
                        if let footer = section.footer {
                            Text(footer)
                        }
                    }
                }
            }
            .navigationTitle("Controls")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func row(_ entry: ControlHelpEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: entry.symbol)
                .font(.system(size: 14))
                .frame(width: 26, height: 26)
                .foregroundStyle(Color(uiColor: SolarizedDarkTheme.cyan))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(entry.title)
                        .font(.system(size: 15, weight: .semibold))
                    if let shortcut = entry.shortcut {
                        Text(shortcut)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(entry.detail)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
