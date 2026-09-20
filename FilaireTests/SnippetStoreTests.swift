import XCTest
@testable import Filaire

/// Persistence, recovery, conflict, and limit behavior. Every test works in its own temporary directory, so
/// none of them touch the real Application Support library.
@MainActor
final class SnippetStoreTests: XCTestCase {

    /// One directory per test instance, created on demand, so no test touches the real library.
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("snippet-store-tests-" + UUID().uuidString, isDirectory: true)

    private func ensureDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { [directory] in
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func writeRawDocument(_ text: String) {
        ensureDirectory()
        try? Data(text.utf8).write(to: fileURL)
    }

    private func makeStore() -> SnippetStore {
        ensureDirectory()
        let store = SnippetStore(baseDirectory: directory)
        store.load()
        return store
    }

    private func sampleSnippet(
        name: String = "Tail log",
        template: String = "tail -n {{lines}} {{path}}",
        scope: SnippetScope = .global
    ) -> CommandSnippet {
        CommandSnippet(
            name: name,
            template: template,
            scope: scope,
            parameters: [
                SnippetParameter(name: "lines", label: "Lines", kind: .integer, defaultValue: "50"),
                SnippetParameter(name: "path", label: "Path")
            ]
        )
    }

    private var fileURL: URL { directory.appendingPathComponent("snippets.json") }
    private var backupURL: URL { directory.appendingPathComponent("snippets.backup.json") }

    // MARK: - Round trip

    func testSavedSnippetSurvivesAReload() async {
        let store = makeStore()
        guard case .saved = await store.save(sampleSnippet()) else { return XCTFail("expected a save") }

        let reopened = SnippetStore(baseDirectory: directory)
        reopened.load()

        XCTAssertEqual(reopened.loadState, .loaded)
        XCTAssertEqual(reopened.snippets.count, 1)
        XCTAssertEqual(reopened.snippets.first?.name, "Tail log")
        XCTAssertEqual(reopened.snippets.first?.parameters.count, 2)
    }

    func testFavoritesPersist() async {
        let store = makeStore()
        guard case .saved(let saved) = await store.save(sampleSnippet()) else { return XCTFail("expected a save") }
        guard case .saved = await store.setFavorite(true, id: saved.id) else { return XCTFail("expected a save") }

        let reopened = SnippetStore(baseDirectory: directory)
        reopened.load()
        XCTAssertEqual(reopened.snippets.first?.isFavorite, true)
    }

    func testEmptyDirectoryLoadsAsAnEmptyLibrary() {
        let store = makeStore()
        XCTAssertEqual(store.loadState, .loaded)
        XCTAssertTrue(store.snippets.isEmpty)
    }

    func testDeleteRemovesTheSnippet() async {
        let store = makeStore()
        guard case .saved(let saved) = await store.save(sampleSnippet()) else { return XCTFail("expected a save") }
        guard case .saved = await store.delete(id: saved.id) else { return XCTFail("expected a delete") }
        XCTAssertTrue(store.snippets.isEmpty)
    }

    func testDuplicateGetsANewIdentityAndIsNotFavorite() async {
        let store = makeStore()
        guard case .saved(let original) = await store.save(sampleSnippet()) else { return XCTFail("expected a save") }
        guard case .saved = await store.setFavorite(true, id: original.id) else { return XCTFail("expected a save") }

        guard case .saved(let copy) = await store.duplicate(id: original.id) else { return XCTFail("expected a copy") }

        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertFalse(copy.isFavorite)
        XCTAssertEqual(copy.parameters.count, original.parameters.count)
        XCTAssertEqual(store.snippets.count, 2)
    }

    // MARK: - Recovery

    func testCorruptDocumentIsPreservedAndRestoredFromBackup() async {
        let store = makeStore()
        guard case .saved = await store.save(sampleSnippet(name: "Good one")) else { return XCTFail("expected a save") }
        // A second save moves the first good document into the backup slot.
        guard case .saved = await store.save(sampleSnippet(name: "Second")) else { return XCTFail("expected a save") }

        writeRawDocument("{ not json")

        let reopened = SnippetStore(baseDirectory: directory)
        reopened.load()

        XCTAssertEqual(reopened.loadState, .loaded)
        XCTAssertFalse(reopened.snippets.isEmpty, "The backup should have been used")
        XCTAssertNotNil(reopened.recoveryNotice)

        let quarantined = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
            .filter { $0.hasPrefix("snippets.corrupt-") } ?? []
        XCTAssertEqual(quarantined.count, 1, "The damaged file must be kept for recovery")
    }

    func testCorruptDocumentWithNoBackupIsNeverReplacedWithAnEmptyFile() {
        writeRawDocument("{ not json")

        let store = makeStore()

        XCTAssertTrue(store.snippets.isEmpty)
        XCTAssertNotNil(store.recoveryNotice)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fileURL.path),
            "The damaged file is moved aside, not overwritten in place"
        )
        let quarantined = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
            .filter { $0.hasPrefix("snippets.corrupt-") } ?? []
        XCTAssertEqual(quarantined.count, 1)
    }

    func testFutureSchemaIsLeftUntouchedAndBlocksSaving() async {
        let future = """
        {"schemaVersion": 99, "revision": 3, "snippets": []}
        """
        writeRawDocument(future)

        let store = makeStore()

        guard case .unreadable = store.loadState else {
            return XCTFail("expected an unreadable document, got \(store.loadState)")
        }
        XCTAssertFalse(store.canSave)

        guard case .failed = await store.save(sampleSnippet()) else {
            return XCTFail("saving must not overwrite a newer schema")
        }
        let onDisk = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        XCTAssertTrue(onDisk.contains("99"), "The newer document must be left exactly as it was")
    }

    // MARK: - Stale writes and conflicts

    func testAnOlderSaveCannotOverwriteANewerOne() async throws {
        ensureDirectory()
        let writer = SnippetFileWriter()
        let newer = Data("newer".utf8)
        let older = Data("older".utf8)

        let wroteNewer = try await writer.write(data: newer, revision: 5, fileURL: fileURL, backupURL: backupURL)
        let wroteOlder = try await writer.write(data: older, revision: 4, fileURL: fileURL, backupURL: backupURL)

        XCTAssertTrue(wroteNewer)
        XCTAssertFalse(wroteOlder, "A stale save must be dropped")
        XCTAssertEqual(try Data(contentsOf: fileURL), newer)
    }

    func testConcurrentEditOfTheSameSnippetReportsAConflict() async {
        let store = makeStore()
        guard case .saved(let first) = await store.save(sampleSnippet()) else { return XCTFail("expected a save") }

        // A second window still holds the pre-edit revision.
        let staleCopy = first

        var edited = first
        edited.name = "Edited by window one"
        guard case .saved = await store.save(edited) else { return XCTFail("expected a save") }

        var conflicting = staleCopy
        conflicting.name = "Edited by window two"
        guard case .conflict(let latest) = await store.save(conflicting) else {
            return XCTFail("expected a conflict")
        }
        XCTAssertEqual(latest.name, "Edited by window one")
        XCTAssertEqual(store.snippets.first?.name, "Edited by window one", "The other window's edit must survive")
    }

    // MARK: - Scope and host deletion

    func testDeletedHostLeavesSnippetsOrphanedRatherThanGlobal() async {
        let hostID = UUID()
        let store = makeStore()
        guard case .saved = await store.save(sampleSnippet(name: "Host only", scope: .host(hostID))) else {
            return XCTFail("expected a save")
        }

        let orphans = store.orphaned(configuredHostIDs: [])

        XCTAssertEqual(orphans.count, 1)
        XCTAssertEqual(orphans.first?.scope, .host(hostID))
        XCTAssertFalse(store.available(forHost: nil).contains { $0.name == "Host only" })
    }

    func testReassigningAnOrphanMovesItToTheChosenScope() async {
        let hostID = UUID()
        let store = makeStore()
        guard case .saved(let saved) = await store.save(sampleSnippet(name: "Host only", scope: .host(hostID))) else {
            return XCTFail("expected a save")
        }

        guard case .saved = await store.reassign(ids: [saved.id], to: .global) else {
            return XCTFail("expected a reassignment")
        }
        XCTAssertEqual(store.snippets.first?.scope, .global)
        XCTAssertTrue(store.orphaned(configuredHostIDs: []).isEmpty)
    }

    func testAvailabilityFiltersByHostScope() async {
        let hostA = UUID()
        let hostB = UUID()
        let store = makeStore()
        _ = await store.save(sampleSnippet(name: "Global", scope: .global))
        _ = await store.save(sampleSnippet(name: "Only A", scope: .host(hostA)))

        XCTAssertEqual(store.available(forHost: hostA).map(\.name).sorted(), ["Global", "Only A"])
        XCTAssertEqual(store.available(forHost: hostB).map(\.name), ["Global"])
    }

    // MARK: - Search

    func testSearchCoversNameDescriptionAndParameterLabelsOnly() async {
        let store = makeStore()
        var snippet = sampleSnippet(name: "Restart service")
        snippet.description = "Bounce a systemd unit"
        _ = await store.save(snippet)

        XCTAssertEqual(store.search("restart", forHost: nil).count, 1)
        XCTAssertEqual(store.search("systemd", forHost: nil).count, 1)
        XCTAssertEqual(store.search("Lines", forHost: nil).count, 1, "Parameter labels are searchable")
        XCTAssertEqual(store.search("50", forHost: nil).count, 0, "Values are never searched")
    }

    // MARK: - Validation

    func testInvalidTemplateIsRejectedWithAReadableMessage() async {
        let store = makeStore()
        let snippet = CommandSnippet(
            name: "Broken",
            template: "echo $( {{name}} )",
            parameters: [SnippetParameter(name: "name", label: "Name")]
        )
        guard case .rejected(let message) = await store.save(snippet) else {
            return XCTFail("expected a rejection")
        }
        XCTAssertTrue(
            message.contains("command substitution"),
            "Message should explain the unsupported position: \(message)"
        )
    }

    func testQuotedPlaceholderTemplateIsAccepted() async {
        // Placeholders inside quotes are supported; the value is escaped for the quote it sits in rather
        // than quoted a second time.
        let store = makeStore()
        let snippet = CommandSnippet(
            name: "Quoted",
            template: "psql --dbname='{{db}}_prod'",
            parameters: [SnippetParameter(name: "db", label: "Database")]
        )
        guard case .saved = await store.save(snippet) else {
            return XCTFail("expected a quoted placeholder to be accepted")
        }
    }

    func testUndefinedParameterIsRejected() async {
        let store = makeStore()
        let snippet = CommandSnippet(name: "Missing", template: "echo {{ghost}}", parameters: [])
        guard case .rejected = await store.save(snippet) else { return XCTFail("expected a rejection") }
    }

    func testDuplicateParameterNamesAreRejected() async {
        let store = makeStore()
        let snippet = CommandSnippet(
            name: "Dupes",
            template: "echo {{a}}",
            parameters: [SnippetParameter(name: "a", label: "A"), SnippetParameter(name: "a", label: "Again")]
        )
        guard case .rejected(let message) = await store.save(snippet) else {
            return XCTFail("expected a rejection")
        }
        XCTAssertTrue(message.contains("more than once"))
    }

    func testUnnamedSnippetIsRejected() async {
        let store = makeStore()
        let snippet = CommandSnippet(name: "   ", template: "uptime")
        guard case .rejected = await store.save(snippet) else { return XCTFail("expected a rejection") }
    }

    func testSecretDefaultIsStrippedRatherThanPersisted() async {
        let store = makeStore()
        let snippet = CommandSnippet(
            name: "Token",
            template: "curl -H {{token}} url",
            parameters: [SnippetParameter(name: "token", label: "Token", defaultValue: "leaked", isSecret: true)]
        )
        guard case .saved = await store.save(snippet) else { return XCTFail("expected a save") }

        let onDisk = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        XCTAssertFalse(onDisk.contains("leaked"), "A secret default must never reach the library file")
    }

    func testHandEditedSecretDefaultIsSanitizedOnLoad() {
        let document = """
        {"schemaVersion": 1, "revision": 1, "snippets": [
          {"id": "\(UUID().uuidString)", "revision": 0, "name": "Token", "description": "",
           "template": "curl -H {{token}} url", "shellDialect": "posix", "scope": {"global": {}},
           "parameters": [{"name": "token", "label": "Token", "kind": "text", "required": true,
                           "defaultValue": "leaked", "isSecret": true}],
           "isFavorite": false, "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z"}
        ]}
        """
        writeRawDocument(document)

        let store = makeStore()

        guard store.loadState == .loaded, let parameter = store.snippets.first?.parameters.first else {
            return XCTFail("expected the document to load, got \(store.loadState)")
        }
        XCTAssertNil(parameter.defaultValue, "A stored secret default must be dropped on load")
    }
}
