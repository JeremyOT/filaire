import Foundation
import Observation

/// Local-editor state owned by one `TerminalSessionContext`: which editor is presented, the live draft, and
/// the per-host draft cache. Holds no connection state and sends nothing; submission goes through
/// `TerminalInputSubmission` and `SessionManager.admit`.
@MainActor
@Observable
public final class TerminalInteractionState {

    public enum ComposerOrigin: Equatable, Sendable {
        case shortcut
        case accessoryBar
        case statusActions
        case snippet
    }

    /// How to merge incoming prefill text with a draft that already has content.
    public enum PrefillResolution: Equatable, Sendable {
        case replace
        case append
    }

    public struct PendingPrefill: Equatable, Sendable {
        public let text: String
        public let containsSecretValues: Bool
    }

    /// Closed drafts retained per terminal context before the least recently used one is evicted.
    public static let maxRetainedDrafts = 8

    public private(set) var isComposerPresented = false
    public private(set) var composerOrigin: ComposerOrigin?
    public private(set) var composerHostID: UUID?

    /// One in-progress use of a snippet. Values live only here and in the form; they are never persisted,
    /// never logged, and never searched.
    public struct SnippetInvocation: Equatable, Sendable {
        public let snippet: CommandSnippet
        /// The host the form was opened for. A later host change disables transfer until the user picks again.
        public let hostID: UUID
        public var values: [String: String]
        public var revealSecrets: Bool

        public func value(for parameterName: String) -> String {
            values[parameterName] ?? ""
        }
    }

    public private(set) var isSnippetLibraryPresented = false
    public private(set) var snippetInvocation: SnippetInvocation?
    /// A snippet being authored or edited. Separate from invocation so template text and values never mix.
    public private(set) var snippetEditorDraft: CommandSnippet?

    /// Live editor text for the presented draft.
    public var draftText: String = ""
    public var draftSelection: NSRange?

    /// True while the draft holds expanded secret values: it is discarded instead of cached.
    public private(set) var isDraftEphemeral = false
    public private(set) var inlineError: String?
    public private(set) var pendingPrefill: PendingPrefill?
    /// Set when an older draft was dropped to stay within the retention bound, so the user is told.
    public private(set) var evictionNotice: String?

    private var drafts: [UUID: CommandDraft] = [:]
    private var recency: [UUID] = []

    public init() {}

    public var isDraftWithinSizeLimit: Bool {
        draftText.utf8.count <= TerminalInputSubmission.maxDraftBytes
    }

    // MARK: - Presentation

    public func openComposer(forHost hostID: UUID, origin: ComposerOrigin) {
        if composerHostID != hostID {
            persistCurrentDraft()
            composerHostID = hostID
            loadDraft(for: hostID)
        }
        composerOrigin = origin
        inlineError = nil
        isComposerPresented = true
    }

    /// Fills the editor from a snippet. Never sends, and never silently replaces existing text.
    public func openComposer(
        with text: String,
        containsSecretValues: Bool,
        forHost hostID: UUID,
        origin: ComposerOrigin = .snippet
    ) {
        openComposer(forHost: hostID, origin: origin)
        if draftText.isEmpty {
            adoptPrefill(text: text, containsSecretValues: containsSecretValues)
        } else {
            pendingPrefill = PendingPrefill(text: text, containsSecretValues: containsSecretValues)
        }
    }

    public func resolvePendingPrefill(_ resolution: PrefillResolution) {
        guard let prefill = pendingPrefill else { return }
        pendingPrefill = nil
        switch resolution {
        case .replace:
            adoptPrefill(text: prefill.text, containsSecretValues: prefill.containsSecretValues)
        case .append:
            // Appending keeps a visible newline boundary and leaves the combined text editable.
            let separator = draftText.hasSuffix("\n") ? "" : "\n"
            adoptPrefill(
                text: draftText + separator + prefill.text,
                containsSecretValues: prefill.containsSecretValues || isDraftEphemeral
            )
        }
    }

    public func cancelPendingPrefill() {
        pendingPrefill = nil
    }

    private func adoptPrefill(text: String, containsSecretValues: Bool) {
        draftText = text
        draftSelection = NSRange(location: (text as NSString).length, length: 0)
        isDraftEphemeral = containsSecretValues
        inlineError = nil
    }

    // MARK: - Snippets

    public func openSnippetLibrary() {
        isSnippetLibraryPresented = true
    }

    public func closeSnippetLibrary() {
        isSnippetLibraryPresented = false
    }

    public func beginInvocation(of snippet: CommandSnippet, forHost hostID: UUID) {
        var values: [String: String] = [:]
        for parameter in snippet.parameters {
            // A secret never carries a stored default, so its field always starts empty.
            if let defaultValue = parameter.defaultValue, !parameter.isSecret {
                values[parameter.name] = defaultValue
            }
        }
        snippetInvocation = SnippetInvocation(
            snippet: snippet,
            hostID: hostID,
            values: values,
            revealSecrets: false
        )
    }

    public func updateInvocationValue(_ value: String, for parameterName: String) {
        guard var invocation = snippetInvocation else { return }
        invocation.values[parameterName] = value
        snippetInvocation = invocation
    }

    public func setRevealSecrets(_ reveal: Bool) {
        guard var invocation = snippetInvocation else { return }
        invocation.revealSecrets = reveal
        snippetInvocation = invocation
    }

    /// Dismissing the form discards every entered value, including secrets.
    public func cancelInvocation() {
        snippetInvocation = nil
    }

    public func beginSnippetEditor(_ snippet: CommandSnippet) {
        snippetEditorDraft = snippet
    }

    public func updateSnippetEditorDraft(_ snippet: CommandSnippet) {
        snippetEditorDraft = snippet
    }

    public func closeSnippetEditor() {
        snippetEditorDraft = nil
    }

    /// Drops secret values while keeping the rest of the form, for use when the destination host changes.
    private func clearSecretInvocationValues() {
        guard var invocation = snippetInvocation else { return }
        for parameter in invocation.snippet.parameters where parameter.isSecret {
            invocation.values.removeValue(forKey: parameter.name)
        }
        invocation.revealSecrets = false
        snippetInvocation = invocation
    }

    /// Closes the editor, preserving the draft unless it holds expanded secret values.
    public func closeComposer() {
        persistCurrentDraft()
        isComposerPresented = false
        composerOrigin = nil
        pendingPrefill = nil
        inlineError = nil
    }

    /// Clears the editor's text as a user action; participates in the caller's undo handling.
    public func clearDraft() {
        draftText = ""
        draftSelection = NSRange(location: 0, length: 0)
        inlineError = nil
    }

    /// Drops the draft that was just admitted to the outbound queue. Only called after acceptance.
    public func clearSubmittedDraft() {
        if let hostID = composerHostID {
            drafts.removeValue(forKey: hostID)
            recency.removeAll { $0 == hostID }
        }
        draftText = ""
        draftSelection = nil
        isDraftEphemeral = false
        inlineError = nil
        isComposerPresented = false
        composerOrigin = nil
        pendingPrefill = nil
    }

    // MARK: - Lifecycle

    /// A host switch closes the editor and never carries text to the newly selected host.
    public func hostDidChange(to hostID: UUID?) {
        guard hostID != composerHostID else { return }
        persistCurrentDraft()
        isComposerPresented = false
        composerOrigin = nil
        pendingPrefill = nil
        inlineError = nil
        // Keep only nonsecret form state across a host change; transfer stays disabled until the user
        // picks a valid destination.
        clearSecretInvocationValues()
        isSnippetLibraryPresented = false
        composerHostID = hostID
        if let hostID {
            loadDraft(for: hostID)
        } else {
            draftText = ""
            draftSelection = nil
            isDraftEphemeral = false
        }
    }

    public func removeDrafts(for hostIDs: Set<UUID>) {
        for hostID in hostIDs {
            drafts.removeValue(forKey: hostID)
            recency.removeAll { $0 == hostID }
            if composerHostID == hostID {
                draftText = ""
                draftSelection = nil
                isDraftEphemeral = false
                isComposerPresented = false
                composerOrigin = nil
                composerHostID = nil
            }
        }
    }

    public func teardown() {
        snippetInvocation = nil
        snippetEditorDraft = nil
        isSnippetLibraryPresented = false
        drafts.removeAll()
        recency.removeAll()
        draftText = ""
        draftSelection = nil
        isDraftEphemeral = false
        isComposerPresented = false
        composerOrigin = nil
        composerHostID = nil
        pendingPrefill = nil
        inlineError = nil
    }

    // MARK: - Errors and notices

    public func setInlineError(_ message: String) {
        inlineError = message
    }

    public func clearInlineError() {
        inlineError = nil
    }

    public func acknowledgeEvictionNotice() {
        evictionNotice = nil
    }

    // MARK: - Draft cache

    public func retainedDraftCount() -> Int {
        drafts.count
    }

    public func retainedDraftText(forHost hostID: UUID) -> String? {
        drafts[hostID]?.text
    }

    private func persistCurrentDraft() {
        guard let hostID = composerHostID else { return }

        // Expanded secret values are never cached, so closing the editor discards them.
        if isDraftEphemeral {
            drafts.removeValue(forKey: hostID)
            recency.removeAll { $0 == hostID }
            isDraftEphemeral = false
            draftText = ""
            draftSelection = nil
            return
        }

        guard !draftText.isEmpty else {
            drafts.removeValue(forKey: hostID)
            recency.removeAll { $0 == hostID }
            return
        }

        var draft = drafts[hostID] ?? CommandDraft(hostID: hostID)
        draft.update(text: draftText, selectedRange: draftSelection)
        drafts[hostID] = draft
        touch(hostID)
        evictIfNeeded()
    }

    private func loadDraft(for hostID: UUID) {
        let draft = drafts[hostID]
        draftText = draft?.text ?? ""
        draftSelection = draft?.selectedRange
        isDraftEphemeral = false
        if draft != nil {
            touch(hostID)
        }
    }

    private func touch(_ hostID: UUID) {
        recency.removeAll { $0 == hostID }
        recency.append(hostID)
    }

    private func evictIfNeeded() {
        while recency.count > Self.maxRetainedDrafts {
            let victim = recency.removeFirst()
            guard victim != composerHostID else {
                // Never evict the draft that is currently open.
                recency.append(victim)
                return
            }
            drafts.removeValue(forKey: victim)
            evictionNotice = "An older command draft was discarded to stay within the draft limit."
        }
    }
}
