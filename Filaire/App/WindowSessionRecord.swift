import UIKit
import Foundation

public enum WindowEntryStatus: Equatable, Sendable {
    case pending
    case owned
    case closing
}

public struct HostWindowState: Equatable, Sendable {
    public let hostId: UUID
    public let ownerSessionPersistentIdentifier: String?
    public let windowStatus: WindowEntryStatus
    public let connectionState: ConnectionState
    public let isDetached: Bool

    public init(
        hostId: UUID,
        ownerSessionPersistentIdentifier: String?,
        windowStatus: WindowEntryStatus,
        connectionState: ConnectionState,
        isDetached: Bool = false
    ) {
        self.hostId = hostId
        self.ownerSessionPersistentIdentifier = ownerSessionPersistentIdentifier
        self.windowStatus = windowStatus
        self.connectionState = connectionState
        self.isDetached = isDetached
    }
}

/// An authoritative runtime record of an application window session,
/// independent of SwiftUI view hierarchy existence or scene attachment.
@MainActor
public final class WindowSessionRecord {
    public let persistentIdentifier: String
    public var sessionManager: SessionManager
    public weak var scene: UIWindowScene?
    public var terminalContext: TerminalSessionContext?
    public var hostId: UUID?
    public var status: WindowEntryStatus
    public var ownershipGeneration: Int
    public var lastInteractionTime: Date
    public var isDetached: Bool { scene == nil }

    public init(
        persistentIdentifier: String,
        sessionManager: SessionManager,
        scene: UIWindowScene? = nil,
        hostId: UUID? = nil,
        status: WindowEntryStatus = .owned,
        ownershipGeneration: Int = 1,
        lastInteractionTime: Date = Date()
    ) {
        self.persistentIdentifier = persistentIdentifier
        self.sessionManager = sessionManager
        self.scene = scene
        self.hostId = hostId
        self.status = status
        self.ownershipGeneration = ownershipGeneration
        self.lastInteractionTime = lastInteractionTime
    }
}
