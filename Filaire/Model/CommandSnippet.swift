import Foundation

/// Bounds applied before any expansion is materialized, so an exponential-looking template cannot allocate
/// its way through memory before being rejected.
public enum SnippetLimits {
    public static let maxSnippets = 500
    public static let maxTemplateBytes = 64 * 1024
    public static let maxParametersPerSnippet = 32
    public static let maxParameterValueBytes = 8 * 1024
    public static let maxExpandedBytes = 64 * 1024
    public static let maxDocumentBytes = 8 * 1024 * 1024
    public static let maxNameBytes = 200
    public static let maxDescriptionBytes = 2000
    public static let maxParameterNameLength = 64
}

/// Where a snippet is offered. A `host` scope whose UUID no longer matches a configured host is an orphaned
/// reference: it is presented as unassigned rather than silently promoted to global.
public enum SnippetScope: Codable, Equatable, Sendable {
    case global
    case host(UUID)

    public var hostID: UUID? {
        if case .host(let id) = self { return id }
        return nil
    }
}

/// v1 renders POSIX-style argument quoting used by sh, bash, and zsh. Other dialects need their own tested
/// encoder and context grammar before they can be claimed.
public enum SnippetShellDialect: String, Codable, Equatable, Sendable {
    case posix
}

public enum SnippetParameterKind: String, Codable, Equatable, Sendable {
    case text
    case integer
    case choice
}

public struct SnippetChoice: Codable, Equatable, Sendable, Identifiable {
    public var id: String { value }
    public let label: String
    /// The text substituted into the command. Choices render this, never the display label.
    public let value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

public struct SnippetParameter: Codable, Equatable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public var label: String
    public var help: String?
    public var kind: SnippetParameterKind
    public var required: Bool
    /// Secret parameters cannot carry a persisted default; see `hasPermittedDefault`.
    public var defaultValue: String?
    public var choices: [SnippetChoice]?
    public var isSecret: Bool

    public init(
        name: String,
        label: String,
        help: String? = nil,
        kind: SnippetParameterKind = .text,
        required: Bool = true,
        defaultValue: String? = nil,
        choices: [SnippetChoice]? = nil,
        isSecret: Bool = false
    ) {
        self.name = name
        self.label = label
        self.help = help
        self.kind = kind
        self.required = required
        self.defaultValue = isSecret ? nil : defaultValue
        self.choices = choices
        self.isSecret = isSecret
    }

    /// Parameter names are identifiers so they can be matched exactly in a template without quoting rules.
    public static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= SnippetLimits.maxParameterNameLength else { return false }
        guard name.allSatisfy({ $0.isASCII }) else { return false }
        var isFirst = true
        for character in name {
            let isLetterOrUnderscore = character.isLetter || character == "_"
            let isDigit = character.isNumber
            if isFirst {
                guard isLetterOrUnderscore else { return false }
                isFirst = false
            } else {
                guard isLetterOrUnderscore || isDigit else { return false }
            }
        }
        return true
    }

    /// A secret parameter never persists a default value, so a secret cannot be stored in the library.
    public var hasPermittedDefault: Bool {
        !(isSecret && defaultValue != nil)
    }
}

public struct CommandSnippet: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    /// Bumped on every saved edit; two windows editing the same snippet reconcile on this.
    public var revision: Int
    public var name: String
    public var description: String
    public var template: String
    public var shellDialect: SnippetShellDialect
    public var scope: SnippetScope
    public var parameters: [SnippetParameter]
    public var isFavorite: Bool
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        revision: Int = 0,
        name: String,
        description: String = "",
        template: String,
        shellDialect: SnippetShellDialect = .posix,
        scope: SnippetScope = .global,
        parameters: [SnippetParameter] = [],
        isFavorite: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.revision = revision
        self.name = name
        self.description = description
        self.template = template
        self.shellDialect = shellDialect
        self.scope = scope
        self.parameters = parameters
        self.isFavorite = isFavorite
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// True when this snippet may be offered for the given host. A snippet scoped to another host is never
    /// directly runnable here.
    public func isAvailable(forHost hostID: UUID?) -> Bool {
        switch scope {
        case .global: return true
        case .host(let owner): return owner == hostID
        }
    }

    public var duplicateParameterNames: [String] {
        var seen = Set<String>()
        var duplicates: [String] = []
        for parameter in parameters where !seen.insert(parameter.name).inserted {
            duplicates.append(parameter.name)
        }
        return duplicates
    }
}

/// A versioned document so a future schema can be recognized and preserved rather than overwritten.
public struct SnippetDocument: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    /// Monotonic across saves, so a slow write cannot clobber a newer one.
    public var revision: Int
    public var snippets: [CommandSnippet]

    public init(
        schemaVersion: Int = SnippetDocument.currentSchemaVersion,
        revision: Int = 0,
        snippets: [CommandSnippet] = []
    ) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.snippets = snippets
    }
}
