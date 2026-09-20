import SwiftUI
import UIKit

/// A `UITextView` wrapper for composing commands: native selection, undo, dictation, and IME composition.
/// Autocorrection and the smart-substitution features are off, so a composed command is exactly what was typed.
public struct CommandEditorView: UIViewRepresentable {
    @Binding public var text: String
    @Binding public var selection: NSRange?
    public var onRun: () -> Void
    public var onDismiss: () -> Void

    public init(
        text: Binding<String>,
        selection: Binding<NSRange?>,
        onRun: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self._text = text
        self._selection = selection
        self.onRun = onRun
        self.onDismiss = onDismiss
    }

    /// Return inserts a newline; Cmd+Return runs. Escape dismisses, except while an input method owns the
    /// keystroke for marked-text composition.
    public final class EditorTextView: UITextView {
        var onRun: (() -> Void)?
        var onDismiss: (() -> Void)?

        public override var keyCommands: [UIKeyCommand]? {
            let run = UIKeyCommand(input: "\r", modifierFlags: .command, action: #selector(handleRun(_:)))
            run.title = "Run"
            run.discoverabilityTitle = "Run"
            run.wantsPriorityOverSystemBehavior = true

            let dismiss = UIKeyCommand(
                input: UIKeyCommand.inputEscape,
                modifierFlags: [],
                action: #selector(handleDismiss(_:))
            )
            return [run, dismiss]
        }

        @objc private func handleRun(_ sender: Any?) {
            guard markedTextRange == nil else { return }
            onRun?()
        }

        @objc private func handleDismiss(_ sender: Any?) {
            guard markedTextRange == nil else { return }
            onDismiss?()
        }
    }

    public func makeUIView(context: Context) -> EditorTextView {
        let view = EditorTextView()
        view.delegate = context.coordinator
        view.onRun = onRun
        view.onDismiss = onDismiss

        view.font = UIFont.monospacedSystemFont(ofSize: 15, weight: .regular)
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.spellCheckingType = .no
        view.dataDetectorTypes = []
        view.backgroundColor = SolarizedDarkTheme.base03
        view.textColor = SolarizedDarkTheme.base1
        view.tintColor = SolarizedDarkTheme.cyan
        view.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        view.alwaysBounceVertical = true
        view.text = text
        return view
    }

    public func updateUIView(_ uiView: EditorTextView, context: Context) {
        uiView.onRun = onRun
        uiView.onDismiss = onDismiss

        // Adopt external text changes (snippet prefill, Clear, visible line-ending normalization) without
        // disturbing an in-progress IME composition.
        if uiView.text != text && uiView.markedTextRange == nil {
            uiView.text = text
        }

        if let selection, uiView.markedTextRange == nil {
            let length = (uiView.text as NSString).length
            let location = min(max(0, selection.location), length)
            let span = min(selection.length, length - location)
            let target = NSRange(location: location, length: span)
            if uiView.selectedRange != target {
                uiView.selectedRange = target
            }
            DispatchQueue.main.async {
                context.coordinator.consumeSelection()
            }
        }
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public final class Coordinator: NSObject, UITextViewDelegate {
        private let parent: CommandEditorView

        init(_ parent: CommandEditorView) {
            self.parent = parent
        }

        /// Clears the one-shot selection request so the user can move the caret freely afterwards.
        func consumeSelection() {
            if parent.selection != nil {
                parent.selection = nil
            }
        }

        public func textViewDidChange(_ textView: UITextView) {
            // Marked text is provisional IME content; adopting it would fight the input method.
            guard textView.markedTextRange == nil else { return }
            if parent.text != textView.text {
                parent.text = textView.text
            }
        }

        /// Rejects an edit that would exceed the draft bound outright, so no grapheme is cut and no paste
        /// lands partially.
        public func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText text: String
        ) -> Bool {
            let current = textView.text as NSString
            let prospective = current.replacingCharacters(in: range, with: text)
            return prospective.utf8.count <= TerminalInputSubmission.maxDraftBytes
        }
    }
}
