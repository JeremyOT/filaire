import Foundation
import QuickLook
import SwiftUI

/// Transfer key identifying an in-flight file preview transfer scoped to an originating session
internal struct TransferKey: Hashable, Sendable {
    let sessionId: String
    let transferId: String
}

/// Abstract file writer for file preview payloads, allowing deterministic mock injection in unit tests
public protocol PreviewFileWriter: AnyObject {
    func write(data: Data) throws
    func close() throws
}

public final class DefaultPreviewFileWriter: PreviewFileWriter {
    private let fileHandle: FileHandle
    public init(url: URL) throws {
        self.fileHandle = try FileHandle(forWritingTo: url)
    }
    public func write(data: Data) throws {
        try fileHandle.write(contentsOf: data)
    }
    public func close() throws {
        try fileHandle.close()
    }
}

/// In-flight file preview transfer metadata and chunks
private struct PendingTransfer {
    let key: TransferKey
    var filename: String
    var total: Int
    var parts: [Int: String] = [:]              // only parts that arrived ahead of nextPart
    var retainedPartsBytes: Int = 0             // bytes of parts held in memory
    var revision: Int = 0                       // incremented on each chunk to invalidate stale timeouts
    var timeoutWorkItem: DispatchWorkItem? = nil
    var receivedBase64Length: Int = 0
    var sessionDir: URL? = nil
    var fileWriter: (any PreviewFileWriter)? = nil
    var nextPart: Int = 1
    var carry: String = ""                      // trailing base64 characters that do not yet form a 4-character group
    var decodedByteCount: Int = 0
    var head = Data()                           // first 2048 decoded bytes, for extension detection
}

private struct MailboxItem: @unchecked Sendable {
    let key: TransferKey
    let filename: String
    let part: Int
    let total: Int
    let base64Payload: String
    let rawByteCount: Int
    let prompt: ((_ filename: String, _ byteCount: Int64, _ onConfirm: @escaping () -> Void) -> Void)?
    let promptWithCancel: ((_ filename: String, _ byteCount: Int64, _ onConfirm: @escaping () -> Void, _ onCancel: @escaping () -> Void) -> Void)?
}

private struct AwaitingConfirmation {
    let url: URL
    let sessionDir: URL
    let byteCount: Int
    let sessionId: String
}

/// Coordinates process-wide preview storage, directory lifecycle, and admission/disk budgets across all preview managers.
public final class FilePreviewStorageCoordinator: @unchecked Sendable {
    public static let shared = FilePreviewStorageCoordinator()

    public let runId: UUID
    public let baseDirectory: URL
    public let currentRunURL: URL
    public var maxAggregateDiskBytes: Int
    public var maxConcurrentTransfers: Int

    private let lock = NSLock()
    private var reservedDiskBytes: Int = 0
    private var activeTransferCount: Int = 0

    public var currentReservedDiskBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return reservedDiskBytes
    }

    public var currentActiveTransfers: Int {
        lock.lock()
        defer { lock.unlock() }
        return activeTransferCount
    }

    public init(
        baseDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("filaire_previews", isDirectory: true),
        runId: UUID = UUID(),
        maxAggregateDiskBytes: Int = 200 * 1024 * 1024,
        maxConcurrentTransfers: Int = 20
    ) {
        self.baseDirectory = baseDirectory
        self.runId = runId
        self.maxAggregateDiskBytes = maxAggregateDiskBytes
        self.maxConcurrentTransfers = maxConcurrentTransfers
        self.currentRunURL = baseDirectory.appendingPathComponent("run-\(runId.uuidString)", isDirectory: true)

        try? FileManager.default.createDirectory(at: currentRunURL, withIntermediateDirectories: true)
    }

    public func tryReserveTransfer() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard activeTransferCount < maxConcurrentTransfers else { return false }
        activeTransferCount += 1
        return true
    }

    public func releaseTransfer() {
        lock.lock()
        defer { lock.unlock() }
        activeTransferCount = max(0, activeTransferCount - 1)
    }

    public func tryReserveDiskBytes(_ bytes: Int) -> Bool {
        guard bytes > 0 else { return true }
        lock.lock()
        defer { lock.unlock() }
        let (newTotal, overflow) = reservedDiskBytes.addingReportingOverflow(bytes)
        if overflow || newTotal > maxAggregateDiskBytes {
            return false
        }
        reservedDiskBytes = newTotal
        return true
    }

    public func releaseDiskBytes(_ bytes: Int) {
        guard bytes > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        reservedDiskBytes = max(0, reservedDiskBytes - bytes)
    }

    public func cleanStaleRunsAsync() {
        let base = self.baseDirectory
        let currentRunName = "run-\(runId.uuidString)"
        DispatchQueue.global(qos: .utility).async {
            Self.cleanStaleRuns(in: base, excludingRunName: currentRunName)
        }
    }

    public func cleanStaleRunsSync() {
        Self.cleanStaleRuns(in: baseDirectory, excludingRunName: "run-\(runId.uuidString)")
    }

    private static func cleanStaleRuns(in baseDir: URL, excludingRunName: String) {
        guard let items = try? FileManager.default.contentsOfDirectory(at: baseDir, includingPropertiesForKeys: nil) else {
            return
        }
        for item in items {
            let name = item.lastPathComponent
            if name.hasPrefix("run-") && name != excludingRunName {
                try? FileManager.default.removeItem(at: item)
            }
        }
    }

    public func resetForTesting() {
        lock.lock()
        reservedDiskBytes = 0
        activeTransferCount = 0
        lock.unlock()
    }
}

/// Manages incoming OSC 5101 file preview requests and presents native Apple Quick Look.
public final class FilePreviewManager: ObservableObject, @unchecked Sendable {
    public static let shared = FilePreviewManager()

    public let managerId: UUID
    public let storageCoordinator: FilePreviewStorageCoordinator
    public let managerDirectory: URL
    private var isShutDown: Bool = false

    @Published public var previewURL: URL? = nil {
        didSet {
            if let old = oldValue, old != previewURL {
                let oldDir = old.deletingLastPathComponent()
                try? FileManager.default.removeItem(at: oldDir)
                stateLock.lock()
                if activePreviewSessionDir == oldDir {
                    let bytes = activePreviewByteCount
                    activePreviewSessionDir = nil
                    activePreviewByteCount = 0
                    aggregateDiskBytes = max(0, aggregateDiskBytes - bytes)
                    stateLock.unlock()
                    storageCoordinator.releaseDiskBytes(bytes)
                } else {
                    stateLock.unlock()
                }
            }
        }
    }
    @Published public var errorMessage: String? = nil
    @Published public var showErrorAlert: Bool = false

    /// Maximum file size in bytes (25 MB) that will be previewed without user confirmation prompt.
    public static var maxUnpromptedFileSize: Int = 25 * 1024 * 1024

    /// Hard upper bound in bytes for a preview transfer; larger transfers are rejected as soon as that is known.
    public static var maxPreviewFileSize: Int = 100 * 1024 * 1024

    /// Earliest admission ceiling for a single OSC payload burst (2 MB default)
    public static var maxSinglePayloadSize: Int = 2 * 1024 * 1024

    // Configurable watermarks and limits
    public var highWatermark: Int = 1024 * 1024             // 1 MiB high watermark
    public var lowWatermark: Int = 512 * 1024               // 512 KiB low watermark
    public var maxAdmissionBytes: Int = 4 * 1024 * 1024     // 4 MiB hard admission ceiling
    public var maxAggregateDiskBytes: Int = 200 * 1024 * 1024 // 200 MiB aggregate disk budget
    public var maxActiveTransfers: Int = 20                 // max concurrent active transfers
    public var maxOutOfOrderBytesPerTransfer: Int = 4 * 1024 * 1024 // 4 MiB out-of-order budget
    public var timeoutDuration: TimeInterval = 5.0

    /// Optional default handler to prompt before showing previews over maxUnpromptedFileSize
    public var promptLargePreview: ((_ filename: String, _ byteCount: Int64, _ onConfirm: @escaping () -> Void) -> Void)? = nil
    public var promptLargePreviewWithCancel: ((_ filename: String, _ byteCount: Int64, _ onConfirm: @escaping () -> Void, _ onCancel: @escaping () -> Void) -> Void)? = nil

    /// Injected payload writer factory for testing
    public var fileWriterFactory: ((_ url: URL) throws -> any PreviewFileWriter)? = nil

    private static let base64Alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
    private static let payloadFilename = ".filaire-payload"
    private static let maxTextFallbackSize = 10 * 1024 * 1024

    private let stateLock = NSLock()
    private let queue = DispatchQueue(label: "io.o-t.filaire.preview-manager")

    // State protected by stateLock
    private var mailbox: [MailboxItem] = []
    private var isDrainScheduled: Bool = false
    private var queuedMailboxBytes: Int = 0
    private var sessionQueuedBytes: [String: Int] = [:]
    private var sessionOutOfOrderBytes: [String: Int] = [:]
    private var retainedOutOfOrderBytes: Int = 0
    private var aggregateDiskBytes: Int = 0
    private var activeTransferKeys: Set<TransferKey> = []
    private var pendingTransfers: [TransferKey: PendingTransfer] = [:]
    private var rejectedTransfers: [TransferKey: Date] = [:]
    private var cancelledSessionIds: Set<String> = []
    private var sessionPressureHandlers: [String: @Sendable (Bool) -> Void] = [:]
    private var sessionPausedStates: [String: Bool] = [:]
    private var filesAwaitingConfirmation: [TransferKey: AwaitingConfirmation] = [:]
    private var activePreviewByteCount: Int = 0
    private var activePreviewSessionDir: URL? = nil

    // MARK: - Metrics and State Accessors

    public var queuedMailboxBytesCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return queuedMailboxBytes
    }

    public var retainedOutOfOrderBytesCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return retainedOutOfOrderBytes
    }

    public var aggregateDiskBytesCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return aggregateDiskBytes
    }

    public var activeTransferCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return activeTransferKeys.count
    }

    public func isSessionPaused(_ sessionId: String = "default") -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return sessionPausedStates[sessionId] ?? false
    }

    /// Creates the transfer's session directory and payload file on its first chunk
    private func prepareStorage(_ entry: inout PendingTransfer) throws {
        guard entry.fileWriter == nil else { return }
        let sessionDir = managerDirectory.appendingPathComponent("xfer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let payloadURL = sessionDir.appendingPathComponent(Self.payloadFilename)
        guard FileManager.default.createFile(atPath: payloadURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        entry.sessionDir = sessionDir
        if let factory = fileWriterFactory {
            entry.fileWriter = try factory(payloadURL)
        } else {
            entry.fileWriter = try DefaultPreviewFileWriter(url: payloadURL)
        }
    }

    private enum AppendResult {
        case success
        case invalidBase64
        case diskLimitExceeded
        case writeFailed(Error)
    }

    /// Decodes every complete 4-character group (carry + chunk) and appends it to the payload file.
    private func appendDecoded(_ chunk: String, to entry: inout PendingTransfer) -> AppendResult {
        let cleaned = entry.carry + chunk.filter { Self.base64Alphabet.contains($0) }
        let usableCount = cleaned.count - cleaned.count % 4
        entry.carry = String(cleaned.suffix(cleaned.count - usableCount))
        guard usableCount > 0 else { return .success }
        guard let decoded = Data(base64Encoded: String(cleaned.prefix(usableCount))) else {
            return .invalidBase64
        }

        stateLock.lock()
        let (newTotal, overflow) = aggregateDiskBytes.addingReportingOverflow(decoded.count)
        if overflow || newTotal > maxAggregateDiskBytes {
            stateLock.unlock()
            return .diskLimitExceeded
        }
        guard storageCoordinator.tryReserveDiskBytes(decoded.count) else {
            stateLock.unlock()
            return .diskLimitExceeded
        }
        aggregateDiskBytes = newTotal
        stateLock.unlock()

        do {
            try entry.fileWriter?.write(data: decoded)
            if entry.head.count < 2048 {
                entry.head.append(decoded.prefix(2048 - entry.head.count))
            }
            entry.decodedByteCount += decoded.count
            return .success
        } catch {
            stateLock.lock()
            aggregateDiskBytes = max(0, aggregateDiskBytes - decoded.count)
            stateLock.unlock()
            storageCoordinator.releaseDiskBytes(decoded.count)
            return .writeFailed(error)
        }
    }

    /// Closes and deletes a transfer's partial data
    private func discardStorage(_ entry: PendingTransfer) {
        try? entry.fileWriter?.close()
        if let dir = entry.sessionDir {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private func postError(_ message: String) {
        DispatchQueue.main.async {
            self.errorMessage = message
            self.showErrorAlert = true
        }
    }

    public init(
        managerId: UUID = UUID(),
        storageCoordinator: FilePreviewStorageCoordinator = .shared
    ) {
        self.managerId = managerId
        self.storageCoordinator = storageCoordinator
        self.managerDirectory = storageCoordinator.currentRunURL.appendingPathComponent("mgr-\(managerId.uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: managerDirectory, withIntermediateDirectories: true)
        storageCoordinator.cleanStaleRunsAsync()
    }

    /// Detects a suggested file extension from binary magic bytes or UTF-8 text
    public static func detectExtension(for data: Data) -> String {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return "png"
        } else if data.starts(with: [0xFF, 0xD8, 0xFF]) {
            return "jpg"
        } else if data.starts(with: [0x47, 0x49, 0x46, 0x38]) { // GIF8
            return "gif"
        } else if data.starts(with: [0x25, 0x50, 0x44, 0x46, 0x2D]) { // %PDF-
            return "pdf"
        } else if data.starts(with: [0x50, 0x4B, 0x03, 0x04]) { // PK..
            return "zip"
        } else if data.starts(with: [0x1F, 0x8B]) { // Gzip magic bytes
            return "gz"
        } else if data.starts(with: [0x42, 0x5A, 0x68]) { // BZh (bzip2)
            return "bz2"
        } else if data.count >= 12 && data[0..<4] == Data([0x52, 0x49, 0x46, 0x46]) && data[8..<12] == Data([0x57, 0x45, 0x42, 0x50]) {
            return "webp"
        } else if data.count >= 12 && data[0..<4] == Data([0x52, 0x49, 0x46, 0x46]) && data[8..<12] == Data("WAVE".utf8) {
            return "wav"
        } else if data.count >= 8 && (data[4..<8] == Data("ftyp".utf8) || data[4..<8] == Data("moov".utf8)) {
            return "mp4"
        } else if data.starts(with: [0x49, 0x44, 0x33]) {
            return "mp3"
        } else if data.count >= 2 && data[0] == 0xFF && (data[1] & 0xF6) == 0xF0 {
            return "aac"
        } else if let text = String(data: data.prefix(2048), encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = trimmed.lowercased()
            if lower.starts(with: "<!doctype html") || lower.starts(with: "<html") {
                return "html"
            } else if lower.starts(with: "<svg") || (lower.starts(with: "<?xml") && lower.contains("<svg")) {
                return "svg"
            } else if lower.starts(with: "<?xml") {
                return "xml"
            } else if trimmed.starts(with: "{") || trimmed.starts(with: "[") {
                return "json"
            } else if trimmed.starts(with: "---") || trimmed.starts(with: "%YAML") {
                return "yaml"
            } else if trimmed.starts(with: "# ") || trimmed.starts(with: "## ") || trimmed.starts(with: "### ") || trimmed.contains("```") {
                return "md"
            } else if trimmed.contains("\t") && trimmed.contains("\n") {
                return "tsv"
            } else if trimmed.contains(",") && trimmed.contains("\n") && !trimmed.contains("{") {
                let firstLine = trimmed.components(separatedBy: .newlines).first ?? ""
                if firstLine.contains(",") && firstLine.components(separatedBy: ",").count >= 2 {
                    return "csv"
                }
                return "txt"
            } else {
                return "txt"
            }
        } else {
            return "txt"
        }
    }

    /// Handles incoming OSC 5101 escape sequence payload
    /// Format: preview;id=<id>;name=<filename>;part=<part>;total=<total>;<base64Data>
    /// Legacy:  preview;name=<filename>;part=<part>;total=<total>;<base64Data>
    public func handleOscData(
        _ data: ArraySlice<UInt8>,
        sessionId: String = "default",
        onPressureChanged: ((Bool) -> Void)? = nil,
        promptLargePreview: ((_ filename: String, _ byteCount: Int64, _ onConfirm: @escaping () -> Void) -> Void)? = nil,
        promptLargePreviewWithCancel: ((_ filename: String, _ byteCount: Int64, _ onConfirm: @escaping () -> Void, _ onCancel: @escaping () -> Void) -> Void)? = nil
    ) {
        guard data.count <= Self.maxSinglePayloadSize else { return }
        guard let text = String(bytes: data, encoding: .utf8) else { return }
        let parts = text.components(separatedBy: ";")
        guard parts.count >= 4, parts[0] == "preview" else { return }

        var transferId: String? = nil
        var filename = "preview.txt"
        var part = 1
        var total = 1
        var dataStartIndex = 1

        for (index, segment) in parts.enumerated().dropFirst() {
            if segment.hasPrefix("id=") {
                transferId = String(segment.dropFirst(3))
                dataStartIndex = index + 1
            } else if segment.hasPrefix("name=") {
                filename = String(segment.dropFirst(5))
                dataStartIndex = index + 1
            } else if segment.hasPrefix("part=") {
                part = Int(segment.dropFirst(5)) ?? 1
                dataStartIndex = index + 1
            } else if segment.hasPrefix("total=") {
                total = Int(segment.dropFirst(6)) ?? 1
                dataStartIndex = index + 1
            } else {
                dataStartIndex = index
                break
            }
        }

        guard dataStartIndex < parts.count else { return }
        guard total >= 1, part >= 1, part <= total else { return }

        let effectiveId = transferId ?? filename
        let base64Data = parts[dataStartIndex...].joined(separator: ";").trimmingCharacters(in: .whitespacesAndNewlines)
        let rawByteCount = data.count
        let key = TransferKey(sessionId: sessionId, transferId: effectiveId)

        var pauseCallback: (@Sendable (Bool) -> Void)? = nil
        var shouldScheduleDrain = false

        stateLock.lock()
        if isShutDown || cancelledSessionIds.contains(sessionId) {
            stateLock.unlock()
            return
        }

        if let handler = onPressureChanged {
            sessionPressureHandlers[sessionId] = handler
        }

        // Clean expired rejected transfers
        if rejectedTransfers.count > 100 {
            let now = Date()
            rejectedTransfers = rejectedTransfers.filter { now.timeIntervalSince($0.value) < 60.0 }
        }

        if rejectedTransfers[key] != nil {
            if part == total {
                rejectedTransfers.removeValue(forKey: key)
            }
            stateLock.unlock()
            return
        }

        var didReserveCoordinatorTransfer = false
        let isExisting = activeTransferKeys.contains(key)
        if !isExisting {
            if activeTransferKeys.count >= maxActiveTransfers {
                rejectedTransfers[key] = Date()
                stateLock.unlock()
                postError("File preview transfer limit reached (maximum \(maxActiveTransfers) concurrent transfers). Transfer '\(filename)' was rejected.")
                return
            }
            if !storageCoordinator.tryReserveTransfer() {
                rejectedTransfers[key] = Date()
                stateLock.unlock()
                postError("File preview transfer limit reached (maximum \(storageCoordinator.maxConcurrentTransfers) concurrent transfers). Transfer '\(filename)' was rejected.")
                return
            }
            didReserveCoordinatorTransfer = true
        }

        // Check hard admission ceiling with overflow-safe arithmetic
        let currentQueued = sessionQueuedBytes[sessionId] ?? 0
        let currentOOO = sessionOutOfOrderBytes[sessionId] ?? 0
        let (pendingBytes, overflow1) = currentQueued.addingReportingOverflow(currentOOO)
        let (newTotalPending, overflow2) = pendingBytes.addingReportingOverflow(rawByteCount)
        if overflow1 || overflow2 || newTotalPending > maxAdmissionBytes {
            if didReserveCoordinatorTransfer {
                storageCoordinator.releaseTransfer()
            }
            stateLock.unlock()
            let limitStr = ByteCountFormatter.string(fromByteCount: Int64(maxAdmissionBytes), countStyle: .file)
            abortTransfer(key: key, reason: "File preview memory limit exceeded (limit \(limitStr)). Transfer '\(filename)' was aborted.")
            return
        }

        activeTransferKeys.insert(key)
        queuedMailboxBytes += rawByteCount
        sessionQueuedBytes[sessionId, default: 0] += rawByteCount

        let newSessionPending = (sessionQueuedBytes[sessionId] ?? 0) + (sessionOutOfOrderBytes[sessionId] ?? 0)
        if newSessionPending >= highWatermark && sessionPausedStates[sessionId] != true {
            sessionPausedStates[sessionId] = true
            pauseCallback = sessionPressureHandlers[sessionId]
        }

        mailbox.append(MailboxItem(
            key: key,
            filename: filename,
            part: part,
            total: total,
            base64Payload: base64Data,
            rawByteCount: rawByteCount,
            prompt: promptLargePreview,
            promptWithCancel: promptLargePreviewWithCancel
        ))

        if !isDrainScheduled {
            isDrainScheduled = true
            shouldScheduleDrain = true
        }
        stateLock.unlock()

        if let pause = pauseCallback {
            pause(true)
        }

        if shouldScheduleDrain {
            queue.async { [weak self] in
                self?.drainMailbox()
            }
        }
    }

    private func drainMailbox() {
        while true {
            stateLock.lock()
            if isShutDown || mailbox.isEmpty {
                isDrainScheduled = false
                stateLock.unlock()
                return
            }
            let item = mailbox.removeFirst()
            queuedMailboxBytes = max(0, queuedMailboxBytes - item.rawByteCount)
            let sQueued = (sessionQueuedBytes[item.key.sessionId] ?? 0) - item.rawByteCount
            sessionQueuedBytes[item.key.sessionId] = max(0, sQueued)

            let isCancelled = cancelledSessionIds.contains(item.key.sessionId)
            let isRejected = rejectedTransfers[item.key] != nil
            stateLock.unlock()

            if isCancelled || isRejected {
                checkLowWatermark(sessionId: item.key.sessionId)
                continue
            }

            processMailboxItem(item)
            checkLowWatermark(sessionId: item.key.sessionId)
        }
    }

    private func checkLowWatermark(sessionId: String) {
        var unpauseCallback: (@Sendable (Bool) -> Void)? = nil
        stateLock.lock()
        let pending = (sessionQueuedBytes[sessionId] ?? 0) + (sessionOutOfOrderBytes[sessionId] ?? 0)
        if pending <= lowWatermark && sessionPausedStates[sessionId] == true {
            sessionPausedStates[sessionId] = false
            unpauseCallback = sessionPressureHandlers[sessionId]
        }
        stateLock.unlock()
        if let unpause = unpauseCallback {
            unpause(false)
        }
    }

    private func processMailboxItem(_ item: MailboxItem) {
        stateLock.lock()
        if isShutDown || cancelledSessionIds.contains(item.key.sessionId) || rejectedTransfers[item.key] != nil {
            stateLock.unlock()
            return
        }
        var entry = pendingTransfers[item.key] ?? PendingTransfer(
            key: item.key,
            filename: item.filename,
            total: item.total
        )
        entry.revision += 1
        let currentRevision = entry.revision
        entry.timeoutWorkItem?.cancel()
        entry.timeoutWorkItem = nil
        entry.total = item.total
        entry.filename = item.filename
        stateLock.unlock()

        // Check projected file size
        let maxBase64Length = (Self.maxPreviewFileSize + 2) / 3 * 4
        let (projected, overflow) = item.base64Payload.count.multipliedReportingOverflow(by: item.total)
        let estimatedBase64Length = overflow ? Int.max : max(entry.receivedBase64Length + item.base64Payload.count, projected)
        if estimatedBase64Length > maxBase64Length {
            let limit = ByteCountFormatter.string(fromByteCount: Int64(Self.maxPreviewFileSize), countStyle: .file)
            abortTransfer(key: item.key, currentEntry: entry, reason: "File preview '\(item.filename)' is too large to preview (limit \(limit)).")
            return
        }

        // Duplicate part check
        if item.part < entry.nextPart || entry.parts[item.part] != nil {
            rescheduleTimeoutIfNeeded(key: item.key, revision: currentRevision)
            return
        }

        entry.receivedBase64Length += item.base64Payload.count

        if item.part > entry.nextPart {
            // Out-of-order part
            entry.parts[item.part] = item.base64Payload
            let payloadBytes = item.base64Payload.utf8.count
            entry.retainedPartsBytes += payloadBytes

            stateLock.lock()
            retainedOutOfOrderBytes += payloadBytes
            sessionOutOfOrderBytes[item.key.sessionId, default: 0] += payloadBytes

            if entry.retainedPartsBytes > maxOutOfOrderBytesPerTransfer {
                stateLock.unlock()
                abortTransfer(key: item.key, currentEntry: entry, reason: "Out-of-order preview memory limit exceeded for '\(item.filename)'.")
                return
            }

            pendingTransfers[item.key] = entry
            stateLock.unlock()

            rescheduleTimeoutIfNeeded(key: item.key, revision: currentRevision)
            return
        }

        // item.part == entry.nextPart
        entry.parts[item.part] = item.base64Payload

        do {
            try prepareStorage(&entry)
            while let nextPayload = entry.parts.removeValue(forKey: entry.nextPart) {
                if entry.nextPart > item.part {
                    let nextBytes = nextPayload.utf8.count
                    entry.retainedPartsBytes = max(0, entry.retainedPartsBytes - nextBytes)
                    stateLock.lock()
                    retainedOutOfOrderBytes = max(0, retainedOutOfOrderBytes - nextBytes)
                    let sOOO = (sessionOutOfOrderBytes[item.key.sessionId] ?? 0) - nextBytes
                    sessionOutOfOrderBytes[item.key.sessionId] = max(0, sOOO)

                    var unpauseCallback: (@Sendable (Bool) -> Void)? = nil
                    let pending = (sessionQueuedBytes[item.key.sessionId] ?? 0) + (sessionOutOfOrderBytes[item.key.sessionId] ?? 0)
                    if pending <= lowWatermark && sessionPausedStates[item.key.sessionId] == true {
                        sessionPausedStates[item.key.sessionId] = false
                        unpauseCallback = sessionPressureHandlers[item.key.sessionId]
                    }
                    stateLock.unlock()
                    if let unpause = unpauseCallback { unpause(false) }
                }

                switch appendDecoded(nextPayload, to: &entry) {
                case .success:
                    break
                case .invalidBase64:
                    abortTransfer(key: item.key, currentEntry: entry, reason: "Failed to decode base64 preview data for '\(item.filename)'.")
                    return
                case .diskLimitExceeded:
                    let limit = ByteCountFormatter.string(fromByteCount: Int64(min(maxAggregateDiskBytes, storageCoordinator.maxAggregateDiskBytes)), countStyle: .file)
                    abortTransfer(key: item.key, currentEntry: entry, reason: "File preview aggregate disk budget exceeded (limit \(limit)). Transfer '\(item.filename)' was aborted.")
                    return
                case .writeFailed(let error):
                    abortTransfer(key: item.key, currentEntry: entry, reason: "Failed to write preview file '\(item.filename)': \(error.localizedDescription)")
                    return
                }

                if entry.decodedByteCount > Self.maxPreviewFileSize {
                    let limit = ByteCountFormatter.string(fromByteCount: Int64(Self.maxPreviewFileSize), countStyle: .file)
                    abortTransfer(key: item.key, currentEntry: entry, reason: "File preview '\(item.filename)' is too large to preview (limit \(limit)).")
                    return
                }

                entry.nextPart += 1
            }
        } catch {
            abortTransfer(key: item.key, currentEntry: entry, reason: "Failed to write preview file '\(item.filename)': \(error.localizedDescription)")
            return
        }

        if entry.nextPart <= entry.total {
            stateLock.lock()
            pendingTransfers[item.key] = entry
            stateLock.unlock()
            rescheduleTimeoutIfNeeded(key: item.key, revision: currentRevision)
            return
        }

        finalizeCompletedTransfer(entry: entry, item: item)
    }

    private func finalizeCompletedTransfer(entry: PendingTransfer, item: MailboxItem) {
        stateLock.lock()
        pendingTransfers.removeValue(forKey: item.key)
        let wasActive = activeTransferKeys.remove(item.key) != nil
        let isCancelled = cancelledSessionIds.contains(item.key.sessionId)
        stateLock.unlock()

        if wasActive {
            storageCoordinator.releaseTransfer()
        }

        try? entry.fileWriter?.close()

        if isCancelled {
            discardStorage(entry)
            stateLock.lock()
            aggregateDiskBytes = max(0, aggregateDiskBytes - entry.decodedByteCount)
            stateLock.unlock()
            storageCoordinator.releaseDiskBytes(entry.decodedByteCount)
            return
        }

        guard entry.carry.isEmpty, let sessionDir = entry.sessionDir else {
            discardStorage(entry)
            stateLock.lock()
            aggregateDiskBytes = max(0, aggregateDiskBytes - entry.decodedByteCount)
            stateLock.unlock()
            storageCoordinator.releaseDiskBytes(entry.decodedByteCount)
            postError("Failed to decode base64 preview data for '\(entry.filename)'.")
            return
        }

        let safeFilename = (entry.filename as NSString).lastPathComponent
        var cleanFilename = safeFilename.isEmpty ? "preview.txt" : safeFilename

        if (cleanFilename as NSString).pathExtension.isEmpty {
            let detectedExt = Self.detectExtension(for: entry.head)
            cleanFilename = "\(cleanFilename).\(detectedExt)"
        }

        var targetURL = sessionDir.appendingPathComponent(cleanFilename)
        do {
            try FileManager.default.moveItem(at: sessionDir.appendingPathComponent(Self.payloadFilename), to: targetURL)
        } catch {
            discardStorage(entry)
            stateLock.lock()
            aggregateDiskBytes = max(0, aggregateDiskBytes - entry.decodedByteCount)
            stateLock.unlock()
            storageCoordinator.releaseDiskBytes(entry.decodedByteCount)
            postError("Failed to write preview file '\(cleanFilename)': \(error.localizedDescription)")
            return
        }

        var isPreviewable = QLPreviewController.canPreview(targetURL as NSURL)
        if !isPreviewable, entry.decodedByteCount <= Self.maxTextFallbackSize,
           let data = try? Data(contentsOf: targetURL, options: .alwaysMapped),
           String(data: data, encoding: .utf8) != nil {
            let textURL = sessionDir.appendingPathComponent("\(cleanFilename).txt")
            if (try? FileManager.default.copyItem(at: targetURL, to: textURL)) != nil,
               QLPreviewController.canPreview(textURL as NSURL) {
                targetURL = textURL
                isPreviewable = true
            }
        }

        guard isPreviewable else {
            try? FileManager.default.removeItem(at: sessionDir)
            stateLock.lock()
            aggregateDiskBytes = max(0, aggregateDiskBytes - entry.decodedByteCount)
            stateLock.unlock()
            storageCoordinator.releaseDiskBytes(entry.decodedByteCount)
            let ext = targetURL.pathExtension.isEmpty ? "none" : targetURL.pathExtension
            postError("Quick Look cannot preview '\(cleanFilename)' (\(entry.decodedByteCount) bytes, extension: '\(ext)'). The file format is not supported by iOS Quick Look.")
            return
        }

        stateLock.lock()
        if cancelledSessionIds.contains(item.key.sessionId) {
            stateLock.unlock()
            try? FileManager.default.removeItem(at: sessionDir)
            stateLock.lock()
            aggregateDiskBytes = max(0, aggregateDiskBytes - entry.decodedByteCount)
            stateLock.unlock()
            storageCoordinator.releaseDiskBytes(entry.decodedByteCount)
            return
        }
        stateLock.unlock()

        let showPreview: @Sendable () -> Void = { [weak self] in
            guard let self = self else { return }
            self.stateLock.lock()
            if self.cancelledSessionIds.contains(item.key.sessionId) || self.isShutDown {
                self.stateLock.unlock()
                try? FileManager.default.removeItem(at: sessionDir)
                self.stateLock.lock()
                self.aggregateDiskBytes = max(0, self.aggregateDiskBytes - entry.decodedByteCount)
                self.stateLock.unlock()
                self.storageCoordinator.releaseDiskBytes(entry.decodedByteCount)
                return
            }
            self.filesAwaitingConfirmation.removeValue(forKey: item.key)
            let oldDir = self.activePreviewSessionDir
            let oldBytes = self.activePreviewByteCount
            self.activePreviewSessionDir = sessionDir
            self.activePreviewByteCount = entry.decodedByteCount
            self.stateLock.unlock()

            if let oldDir = oldDir, oldDir != sessionDir {
                try? FileManager.default.removeItem(at: oldDir)
                self.stateLock.lock()
                self.aggregateDiskBytes = max(0, self.aggregateDiskBytes - oldBytes)
                self.stateLock.unlock()
                self.storageCoordinator.releaseDiskBytes(oldBytes)
            }

            DispatchQueue.main.async {
                if self.previewURL != nil {
                    self.previewURL = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.previewURL = targetURL
                    }
                } else {
                    self.previewURL = targetURL
                }
            }
        }

        let cancelPreview: @Sendable () -> Void = { [weak self] in
            guard let self = self else { return }
            self.stateLock.lock()
            self.filesAwaitingConfirmation.removeValue(forKey: item.key)
            self.aggregateDiskBytes = max(0, self.aggregateDiskBytes - entry.decodedByteCount)
            self.stateLock.unlock()
            self.storageCoordinator.releaseDiskBytes(entry.decodedByteCount)
            try? FileManager.default.removeItem(at: sessionDir)
        }

        if entry.decodedByteCount > Self.maxUnpromptedFileSize {
            stateLock.lock()
            filesAwaitingConfirmation[item.key] = AwaitingConfirmation(
                url: targetURL,
                sessionDir: sessionDir,
                byteCount: entry.decodedByteCount,
                sessionId: item.key.sessionId
            )
            stateLock.unlock()

            let effectivePromptWithCancel = item.promptWithCancel ?? self.promptLargePreviewWithCancel
            let effectivePrompt = item.prompt ?? self.promptLargePreview

            if let promptWithCancel = effectivePromptWithCancel {
                promptWithCancel(cleanFilename, Int64(entry.decodedByteCount), showPreview, cancelPreview)
            } else if let prompt = effectivePrompt {
                prompt(cleanFilename, Int64(entry.decodedByteCount), showPreview)
            } else {
                showPreview()
            }
        } else {
            showPreview()
        }
    }

    private func rescheduleTimeoutIfNeeded(key: TransferKey, revision: Int) {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.queue.async {
                self.stateLock.lock()
                guard let entry = self.pendingTransfers[key], entry.revision == revision else {
                    self.stateLock.unlock()
                    return
                }
                let hasMailboxItems = self.mailbox.contains(where: { $0.key == key })
                if hasMailboxItems {
                    self.stateLock.unlock()
                    return
                }
                self.stateLock.unlock()

                let receivedCount = entry.nextPart - 1 + entry.parts.count
                let reason = "File preview transfer timed out for '\(entry.filename)': received \(receivedCount) of \(entry.total) parts."
                self.abortTransfer(key: key, reason: reason)
            }
        }

        stateLock.lock()
        if var entry = pendingTransfers[key], entry.revision == revision {
            entry.timeoutWorkItem = workItem
            pendingTransfers[key] = entry
        }
        stateLock.unlock()

        queue.asyncAfter(deadline: .now() + timeoutDuration, execute: workItem)
    }

    private func abortTransfer(key: TransferKey, currentEntry: PendingTransfer? = nil, reason: String) {
        stateLock.lock()
        let storedEntry = pendingTransfers.removeValue(forKey: key)
        let entry = currentEntry ?? storedEntry
        let wasActive = activeTransferKeys.remove(key) != nil
        if wasActive {
            storageCoordinator.releaseTransfer()
        }
        rejectedTransfers[key] = Date()

        var removedMailboxBytes = 0
        mailbox.removeAll { item in
            if item.key == key {
                removedMailboxBytes += item.rawByteCount
                return true
            }
            return false
        }
        queuedMailboxBytes = max(0, queuedMailboxBytes - removedMailboxBytes)
        let sQueued = (sessionQueuedBytes[key.sessionId] ?? 0) - removedMailboxBytes
        sessionQueuedBytes[key.sessionId] = max(0, sQueued)

        if let entry = entry {
            entry.timeoutWorkItem?.cancel()
            retainedOutOfOrderBytes = max(0, retainedOutOfOrderBytes - entry.retainedPartsBytes)
            let sOOO = (sessionOutOfOrderBytes[key.sessionId] ?? 0) - entry.retainedPartsBytes
            sessionOutOfOrderBytes[key.sessionId] = max(0, sOOO)
            aggregateDiskBytes = max(0, aggregateDiskBytes - entry.decodedByteCount)
            storageCoordinator.releaseDiskBytes(entry.decodedByteCount)
            discardStorage(entry)
        }

        var unpauseCallback: (@Sendable (Bool) -> Void)? = nil
        let pending = (sessionQueuedBytes[key.sessionId] ?? 0) + (sessionOutOfOrderBytes[key.sessionId] ?? 0)
        if pending <= lowWatermark && sessionPausedStates[key.sessionId] == true {
            sessionPausedStates[key.sessionId] = false
            unpauseCallback = sessionPressureHandlers[key.sessionId]
        }
        stateLock.unlock()

        if let unpause = unpauseCallback {
            unpause(false)
        }

        postError(reason)
    }

    public func cancelSession(_ sessionId: String) {
        var unpauseCallback: (@Sendable (Bool) -> Void)? = nil
        stateLock.lock()
        cancelledSessionIds.insert(sessionId)
        let handler = sessionPressureHandlers.removeValue(forKey: sessionId)
        let wasPaused = sessionPausedStates.removeValue(forKey: sessionId) ?? false
        if wasPaused {
            unpauseCallback = handler
        }

        var removedMailboxBytes = 0
        mailbox.removeAll { item in
            if item.key.sessionId == sessionId {
                removedMailboxBytes += item.rawByteCount
                return true
            }
            return false
        }
        queuedMailboxBytes = max(0, queuedMailboxBytes - removedMailboxBytes)
        sessionQueuedBytes.removeValue(forKey: sessionId)

        let sessionTransfers = pendingTransfers.filter { $0.key.sessionId == sessionId }
        for (key, entry) in sessionTransfers {
            pendingTransfers.removeValue(forKey: key)
            if activeTransferKeys.remove(key) != nil {
                storageCoordinator.releaseTransfer()
            }
            retainedOutOfOrderBytes = max(0, retainedOutOfOrderBytes - entry.retainedPartsBytes)
            aggregateDiskBytes = max(0, aggregateDiskBytes - entry.decodedByteCount)
            storageCoordinator.releaseDiskBytes(entry.decodedByteCount)
            entry.timeoutWorkItem?.cancel()
            discardStorage(entry)
        }
        sessionOutOfOrderBytes.removeValue(forKey: sessionId)

        let sessionAwaiting = filesAwaitingConfirmation.filter { $0.value.sessionId == sessionId }
        for (key, awaiting) in sessionAwaiting {
            filesAwaitingConfirmation.removeValue(forKey: key)
            aggregateDiskBytes = max(0, aggregateDiskBytes - awaiting.byteCount)
            storageCoordinator.releaseDiskBytes(awaiting.byteCount)
            try? FileManager.default.removeItem(at: awaiting.sessionDir)
        }
        stateLock.unlock()

        if let unpause = unpauseCallback {
            unpause(false)
        }
    }

    /// Dismisses active preview and optionally removes temporary file
    public func dismissPreview() {
        stateLock.lock()
        let dir = activePreviewSessionDir
        let bytes = activePreviewByteCount
        activePreviewSessionDir = nil
        activePreviewByteCount = 0
        aggregateDiskBytes = max(0, aggregateDiskBytes - bytes)
        stateLock.unlock()

        storageCoordinator.releaseDiskBytes(bytes)

        if let dir = dir {
            try? FileManager.default.removeItem(at: dir)
        }
        let clear = {
            self.previewURL = nil
        }
        if Thread.isMainThread {
            clear()
        } else {
            DispatchQueue.main.sync(execute: clear)
        }
    }

    /// Explicit shutdown operation to close writers, cancel timeout work, release reservations, and delete the manager's directory.
    public func shutdown() {
        stateLock.lock()
        guard !isShutDown else {
            stateLock.unlock()
            return
        }
        isShutDown = true

        for (_, entry) in pendingTransfers {
            entry.timeoutWorkItem?.cancel()
            try? entry.fileWriter?.close()
            storageCoordinator.releaseDiskBytes(entry.decodedByteCount)
        }
        for _ in activeTransferKeys {
            storageCoordinator.releaseTransfer()
        }
        pendingTransfers.removeAll()
        activeTransferKeys.removeAll()
        mailbox.removeAll()
        queuedMailboxBytes = 0
        sessionQueuedBytes.removeAll()
        sessionOutOfOrderBytes.removeAll()
        retainedOutOfOrderBytes = 0

        for (_, awaiting) in filesAwaitingConfirmation {
            storageCoordinator.releaseDiskBytes(awaiting.byteCount)
            try? FileManager.default.removeItem(at: awaiting.sessionDir)
        }
        filesAwaitingConfirmation.removeAll()

        if activePreviewByteCount > 0 {
            storageCoordinator.releaseDiskBytes(activePreviewByteCount)
            activePreviewByteCount = 0
        }
        if let dir = activePreviewSessionDir {
            try? FileManager.default.removeItem(at: dir)
        }
        activePreviewSessionDir = nil
        aggregateDiskBytes = 0
        rejectedTransfers.removeAll()

        let dirToDelete = managerDirectory
        stateLock.unlock()

        queue.async {
            try? FileManager.default.removeItem(at: dirToDelete)
        }

        let clearUI = {
            self.previewURL = nil
            self.errorMessage = nil
            self.showErrorAlert = false
        }
        if Thread.isMainThread {
            clearUI()
        } else {
            DispatchQueue.main.sync(execute: clearUI)
        }
    }

    /// Resets state for unit testing
    public func resetForTesting() {
        Self.maxUnpromptedFileSize = 25 * 1024 * 1024
        Self.maxPreviewFileSize = 100 * 1024 * 1024
        self.highWatermark = 1024 * 1024
        self.lowWatermark = 512 * 1024
        self.maxAdmissionBytes = 4 * 1024 * 1024
        self.maxAggregateDiskBytes = 200 * 1024 * 1024
        self.maxActiveTransfers = 20
        self.maxOutOfOrderBytesPerTransfer = 4 * 1024 * 1024
        self.timeoutDuration = 5.0
        self.promptLargePreview = nil
        self.promptLargePreviewWithCancel = nil
        self.fileWriterFactory = nil

        var unpauseCallbacks: [@Sendable (Bool) -> Void] = []

        stateLock.lock()
        for (_, entry) in pendingTransfers {
            entry.timeoutWorkItem?.cancel()
            discardStorage(entry)
            storageCoordinator.releaseDiskBytes(entry.decodedByteCount)
        }
        for _ in activeTransferKeys {
            storageCoordinator.releaseTransfer()
        }
        pendingTransfers.removeAll()
        activeTransferKeys.removeAll()
        mailbox.removeAll()
        queuedMailboxBytes = 0
        sessionQueuedBytes.removeAll()
        sessionOutOfOrderBytes.removeAll()
        retainedOutOfOrderBytes = 0
        aggregateDiskBytes = 0
        rejectedTransfers.removeAll()
        cancelledSessionIds.removeAll()

        for (sessionId, isPaused) in sessionPausedStates {
            if isPaused, let handler = sessionPressureHandlers[sessionId] {
                unpauseCallbacks.append(handler)
            }
        }
        sessionPressureHandlers.removeAll()
        sessionPausedStates.removeAll()

        for (_, awaiting) in filesAwaitingConfirmation {
            try? FileManager.default.removeItem(at: awaiting.sessionDir)
            storageCoordinator.releaseDiskBytes(awaiting.byteCount)
        }
        filesAwaitingConfirmation.removeAll()

        if let activeDir = activePreviewSessionDir {
            try? FileManager.default.removeItem(at: activeDir)
            storageCoordinator.releaseDiskBytes(activePreviewByteCount)
        }
        activePreviewSessionDir = nil
        activePreviewByteCount = 0
        isShutDown = false
        stateLock.unlock()

        if self === FilePreviewManager.shared {
            storageCoordinator.resetForTesting()
        }

        for unpause in unpauseCallbacks {
            unpause(false)
        }

        let resetUI = {
            self.previewURL = nil
            self.errorMessage = nil
            self.showErrorAlert = false
        }
        if Thread.isMainThread {
            resetUI()
        } else {
            DispatchQueue.main.sync(execute: resetUI)
        }
    }
}
