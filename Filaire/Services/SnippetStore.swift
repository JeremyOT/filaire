import Foundation
import Observation

/// Serializes every write to the snippet document and drops a save that is older than one already written,
/// so a slow asynchronous save can never clobber newer content.
internal actor SnippetFileWriter {
    private var lastWrittenRevision = 0

    /// Returns false when the save was stale and therefore skipped.
    @discardableResult
    func write(data: Data, revision: Int, fileURL: URL, backupURL: URL) throws -> Bool {
        guard revision > lastWrittenRevision else { return false }

        let manager = FileManager.default
        try manager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // Keep the previous good document as the single backup before replacing it.
        if manager.fileExists(atPath: fileURL.path) {
            try? manager.removeItem(at: backupURL)
            try? manager.copyItem(at: fileURL, to: backupURL)
        }

        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        lastWrittenRevision = revision
        return true
    }
}

/// One process-wide library of command templates, shared by every scene. Holds no invocation values and never
/// sends anything: snippets only ever reach a host through the composer's explicit Insert or Run.
@MainActor
@Observable
public final class SnippetStore {
    public static let shared = SnippetStore()

    public enum LoadState: Equatable, Sendable {
        case notLoaded
        case loaded
        /// The document could not be used and was left on disk for recovery. Saving stays blocked so the
        /// unreadable file is never overwritten.
        case unreadable(String)
    }

    public enum SaveOutcome: Equatable, Sendable {
        case saved(CommandSnippet)
        /// Another window saved this snippet first; the caller chooses Reload latest or Save as copy.
        case conflict(latest: CommandSnippet)
        /// The snippet violates a documented limit or the template is invalid.
        case rejected(String)
        /// Writing failed. The caller keeps its draft.
        case failed(String)
    }

    public private(set) var snippets: [CommandSnippet] = []
    public private(set) var loadState: LoadState = .notLoaded
    public private(set) var documentRevision: Int = 0
    /// Set when a damaged document was moved aside or a backup was used, so the app can say so once.
    public private(set) var recoveryNotice: String?

    private let baseDirectory: URL
    private let writer = SnippetFileWriter()

    private var fileURL: URL { baseDirectory.appendingPathComponent("snippets.json") }
    private var backupURL: URL { baseDirectory.appendingPathComponent("snippets.backup.json") }

    public init(baseDirectory: URL? = nil) {
        if let baseDirectory {
            self.baseDirectory = baseDirectory
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            self.baseDirectory = (support ?? FileManager.default.temporaryDirectory)
                .appendingPathComponent("Filaire", isDirectory: true)
        }
    }

    public var canSave: Bool {
        if case .unreadable = loadState { return false }
        return true
    }

    // MARK: - Loading

    public func load() {
        let manager = FileManager.default
        guard manager.fileExists(atPath: fileURL.path) else {
            snippets = []
            loadState = .loaded
            return
        }

        guard let data = try? Data(contentsOf: fileURL) else {
            loadState = .unreadable("The snippet library could not be read. It was left untouched.")
            return
        }

        switch decode(data) {
        case .success(let document):
            adopt(document)

        case .failure(.futureSchema(let version)):
            // A newer app version wrote this. Refuse to touch it rather than downgrade the user's library.
            loadState = .unreadable(
                "This snippet library was written by a newer version of Filaire (schema \(version)). It was left untouched."
            )

        case .failure(.corrupt):
            // Preserve the damaged bytes under a new name, then fall back to the backup if it is usable.
            let stamp = Int(Date().timeIntervalSince1970)
            let quarantine = baseDirectory.appendingPathComponent("snippets.corrupt-\(stamp).json")
            try? manager.moveItem(at: fileURL, to: quarantine)

            if let backupData = try? Data(contentsOf: backupURL),
               case .success(let document) = decode(backupData) {
                adopt(document)
                recoveryNotice = "The snippet library was damaged and has been restored from the last good backup. The damaged file was kept as \(quarantine.lastPathComponent)."
            } else {
                snippets = []
                loadState = .loaded
                recoveryNotice = "The snippet library was damaged and could not be restored. The damaged file was kept as \(quarantine.lastPathComponent)."
            }
        }
    }

    public func acknowledgeRecoveryNotice() {
        recoveryNotice = nil
    }

    private enum DecodeFailure: Error {
        case corrupt
        case futureSchema(Int)
    }

    private func decode(_ data: Data) -> Result<SnippetDocument, DecodeFailure> {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let document = try? decoder.decode(SnippetDocument.self, from: data) else {
            return .failure(.corrupt)
        }
        guard document.schemaVersion <= SnippetDocument.currentSchemaVersion else {
            return .failure(.futureSchema(document.schemaVersion))
        }
        return .success(document)
    }

    private func adopt(_ document: SnippetDocument) {
        // A hand-edited document could carry a stored secret default, which is never allowed to persist.
        snippets = document.snippets.map { snippet in
            var copy = snippet
            copy.parameters = snippet.parameters.map { parameter in
                guard parameter.isSecret, parameter.defaultValue != nil else { return parameter }
                var sanitized = parameter
                sanitized.defaultValue = nil
                return sanitized
            }
            return copy
        }
        documentRevision = document.revision
        loadState = .loaded
    }

    // MARK: - Queries

    public func available(forHost hostID: UUID?) -> [CommandSnippet] {
        snippets.filter { $0.isAvailable(forHost: hostID) }
    }

    public func favorites(forHost hostID: UUID?) -> [CommandSnippet] {
        available(forHost: hostID).filter(\.isFavorite)
    }

    /// Snippets whose host scope no longer matches a configured host. They stay host-scoped: a deleted host
    /// never silently promotes its snippets to global.
    public func orphaned(configuredHostIDs: Set<UUID>) -> [CommandSnippet] {
        snippets.filter { snippet in
            guard let owner = snippet.scope.hostID else { return false }
            return !configuredHostIDs.contains(owner)
        }
    }

    /// Searches name, description, and parameter labels. Never searches values of any kind.
    public func search(_ query: String, forHost hostID: UUID?) -> [CommandSnippet] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return available(forHost: hostID) }
        return available(forHost: hostID).filter { snippet in
            if snippet.name.lowercased().contains(trimmed) { return true }
            if snippet.description.lowercased().contains(trimmed) { return true }
            return snippet.parameters.contains { $0.label.lowercased().contains(trimmed) }
        }
    }

    // MARK: - Validation

    public func validationMessage(for snippet: CommandSnippet) -> String? {
        if snippet.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Give the snippet a name."
        }
        if snippet.name.utf8.count > SnippetLimits.maxNameBytes {
            return "The name is too long."
        }
        if snippet.description.utf8.count > SnippetLimits.maxDescriptionBytes {
            return "The description is too long."
        }
        if snippet.template.utf8.count > SnippetLimits.maxTemplateBytes {
            return "The template is larger than \(SnippetLimits.maxTemplateBytes) bytes."
        }
        if snippet.parameters.count > SnippetLimits.maxParametersPerSnippet {
            return "A snippet may define at most \(SnippetLimits.maxParametersPerSnippet) parameters."
        }
        if let duplicate = snippet.duplicateParameterNames.first {
            return "The parameter '\(duplicate)' is defined more than once."
        }
        for parameter in snippet.parameters {
            if !SnippetParameter.isValidName(parameter.name) {
                return "'\(parameter.name)' is not a valid parameter name."
            }
            if !parameter.hasPermittedDefault {
                return "A secret parameter cannot store a default value."
            }
            if parameter.kind == .choice && (parameter.choices?.isEmpty ?? true) {
                return "The parameter '\(parameter.name)' needs at least one choice."
            }
        }

        let validation = SnippetTemplateRenderer.validate(
            template: snippet.template,
            parameters: snippet.parameters
        )
        if let error = validation.errors.first {
            return Self.describe(error)
        }
        return nil
    }

    static func describe(_ error: SnippetTemplateError) -> String {
        switch error.kind {
        case .unmatchedOpenDelimiter: return "A placeholder is missing its closing '}}'."
        case .unmatchedCloseDelimiter: return "There is a '}}' without a matching '{{'."
        case .emptyPlaceholderName: return "A placeholder has no parameter name."
        case .invalidPlaceholderName(let name): return "'\(name)' is not a valid parameter name."
        case .unknownModifier(let modifier): return "'\(modifier)' is not a supported placeholder modifier."
        case .whitespaceInPlaceholder: return "A placeholder cannot contain spaces."
        case .placeholderInQuotedText: return "A parameter cannot be placed inside quoted text."
        case .placeholderInCommandSubstitution: return "A parameter cannot be placed inside a command substitution."
        case .placeholderInBackticks: return "A parameter cannot be placed inside backticks."
        case .placeholderInHereDoc: return "A parameter cannot be placed in a here-document."
        case .placeholderJoinedToAdjacentText: return "A parameter must stand alone as a complete word."
        case .undefinedParameter(let name): return "The template uses '\(name)', which is not defined."
        case .templateTooLarge(_, let limit): return "The template is larger than \(limit) bytes."
        }
    }

    // MARK: - Mutations

    public func save(_ snippet: CommandSnippet) async -> SaveOutcome {
        guard canSave else {
            return .failed("The snippet library is unreadable, so changes cannot be saved.")
        }
        if let message = validationMessage(for: snippet) {
            return .rejected(message)
        }

        let previous = snippets
        var updated = snippet
        if let index = snippets.firstIndex(where: { $0.id == snippet.id }) {
            let existing = snippets[index]
            guard existing.revision == snippet.revision else {
                return .conflict(latest: existing)
            }
            updated.revision = existing.revision + 1
            updated.updatedAt = Date()
            snippets[index] = updated
        } else {
            guard snippets.count < SnippetLimits.maxSnippets else {
                return .rejected("The library already holds \(SnippetLimits.maxSnippets) snippets.")
            }
            updated.updatedAt = Date()
            snippets.append(updated)
        }

        return await persist(successValue: updated, rollback: previous)
    }

    public func delete(id: UUID) async -> SaveOutcome {
        guard canSave else {
            return .failed("The snippet library is unreadable, so changes cannot be saved.")
        }
        guard let index = snippets.firstIndex(where: { $0.id == id }) else {
            return .rejected("That snippet no longer exists.")
        }
        let previous = snippets
        let removed = snippets.remove(at: index)
        return await persist(successValue: removed, rollback: previous)
    }

    /// A duplicate gets a new identity and independent parameter definitions.
    public func duplicate(id: UUID) async -> SaveOutcome {
        guard let original = snippets.first(where: { $0.id == id }) else {
            return .rejected("That snippet no longer exists.")
        }
        let copy = CommandSnippet(
            id: UUID(),
            revision: 0,
            name: original.name + " copy",
            description: original.description,
            template: original.template,
            shellDialect: original.shellDialect,
            scope: original.scope,
            parameters: original.parameters,
            isFavorite: false
        )
        return await save(copy)
    }

    public func setFavorite(_ isFavorite: Bool, id: UUID) async -> SaveOutcome {
        guard var snippet = snippets.first(where: { $0.id == id }) else {
            return .rejected("That snippet no longer exists.")
        }
        snippet.isFavorite = isFavorite
        return await save(snippet)
    }

    /// Moves orphaned snippets to a valid destination once the user chooses one.
    public func reassign(ids: Set<UUID>, to scope: SnippetScope) async -> SaveOutcome {
        guard canSave else {
            return .failed("The snippet library is unreadable, so changes cannot be saved.")
        }
        let previous = snippets
        var lastTouched: CommandSnippet?
        for index in snippets.indices where ids.contains(snippets[index].id) {
            snippets[index].scope = scope
            snippets[index].revision += 1
            snippets[index].updatedAt = Date()
            lastTouched = snippets[index]
        }
        guard let lastTouched else { return .rejected("No matching snippets.") }
        return await persist(successValue: lastTouched, rollback: previous)
    }

    /// `rollback` is the library as it was before the caller mutated it, so a failed write leaves memory and
    /// disk agreeing and the editor can retry from its draft.
    private func persist(successValue: CommandSnippet, rollback: [CommandSnippet]) async -> SaveOutcome {
        documentRevision += 1
        let document = SnippetDocument(
            schemaVersion: SnippetDocument.currentSchemaVersion,
            revision: documentRevision,
            snippets: snippets
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(document) else {
            snippets = rollback
            return .failed("The snippet library could not be encoded.")
        }
        guard data.count <= SnippetLimits.maxDocumentBytes else {
            snippets = rollback
            return .rejected("The snippet library would exceed \(SnippetLimits.maxDocumentBytes) bytes.")
        }

        do {
            try await writer.write(
                data: data,
                revision: documentRevision,
                fileURL: fileURL,
                backupURL: backupURL
            )
            return .saved(successValue)
        } catch {
            // The in-memory library stays as it was, so an editor can keep its draft and retry.
            snippets = rollback
            return .failed("The snippet library could not be saved: \(error.localizedDescription)")
        }
    }
}
