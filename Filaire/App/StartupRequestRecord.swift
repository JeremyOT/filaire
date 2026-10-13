import Foundation

public enum StartupRequestOrigin: String, Sendable {
    case quickAction
    case userAction
    case newWindow
    case userActivity
    case notification
    case shortcut
    case system
}

public enum StartupRequestDisposition: Equatable, Sendable {
    case pending
    case consumed
    case canceled
}

public struct StartupRequestRecord: Identifiable, Sendable {
    public let id: UUID
    public let hostId: UUID
    public let origin: StartupRequestOrigin
    public var intendedSessionId: String?
    public var disposition: StartupRequestDisposition
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        hostId: UUID,
        origin: StartupRequestOrigin = .userAction,
        intendedSessionId: String? = nil,
        disposition: StartupRequestDisposition = .pending,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.hostId = hostId
        self.origin = origin
        self.intendedSessionId = intendedSessionId
        self.disposition = disposition
        self.createdAt = createdAt
    }
}

public enum WindowRoutingIntent: Equatable, Sendable {
    case focusExisting
    case openDedicated
    case switchCurrent(sessionPersistentIdentifier: String)
}

public enum RoutingFailureReason: Equatable, Sendable {
    case hostNotFound(UUID)
    case sceneActivationFailed(String)
    case noAvailableWindow
    case requestObsolete
}

public enum WindowRoutingResult: Equatable, Sendable {
    case activatedExisting(sessionPersistentIdentifier: String)
    case switchedCurrent(sessionPersistentIdentifier: String)
    case requestedNewWindow(requestId: UUID)
    case failed(reason: RoutingFailureReason)
}

public struct RoutingFeedback: Equatable, Sendable {
    public let hostId: UUID
    public let reason: RoutingFailureReason
    public let timestamp: Date

    public init(hostId: UUID, reason: RoutingFailureReason, timestamp: Date = Date()) {
        self.hostId = hostId
        self.reason = reason
        self.timestamp = timestamp
    }
}
