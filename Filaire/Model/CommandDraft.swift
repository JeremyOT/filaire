import Foundation

/// An in-memory command draft for one host. Drafts are deliberately not persisted: process termination
/// discards them, and nothing about a draft is ever logged.
public struct CommandDraft: Equatable, Sendable {
    public let hostID: UUID
    public private(set) var text: String
    /// Increments on every accepted edit so a stale asynchronous update cannot overwrite newer text.
    public private(set) var revision: Int
    /// Editor selection in UTF-16 units, matching UITextView ranges.
    public var selectedRange: NSRange?
    /// True when the text came from expanding snippet parameters marked secret. Such drafts are discarded
    /// rather than cached, so an expanded secret never outlives the editor session that produced it.
    public let containsSecretValues: Bool

    public init(
        hostID: UUID,
        text: String = "",
        selectedRange: NSRange? = nil,
        containsSecretValues: Bool = false
    ) {
        self.hostID = hostID
        self.text = text
        self.revision = 0
        self.selectedRange = selectedRange
        self.containsSecretValues = containsSecretValues
    }

    public mutating func update(text newText: String, selectedRange newRange: NSRange? = nil) {
        text = newText
        selectedRange = newRange
        revision &+= 1
    }

    public var utf8ByteCount: Int { text.utf8.count }

    public var isWithinSizeLimit: Bool { utf8ByteCount <= TerminalInputSubmission.maxDraftBytes }
}
