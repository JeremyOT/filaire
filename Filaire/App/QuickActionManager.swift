import UIKit
import Foundation
import SwiftUI

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

@MainActor
public final class QuickActionManager: NSObject {
    public static let shared = QuickActionManager()

    public nonisolated static let connectHostActionType = "io.o-t.filaire.connectHost"
    public nonisolated static let hostIdUserInfoKey = "hostId"
    public nonisolated static let requestIdUserInfoKey = "requestId"

    public private(set) var startupRequests: [UUID: StartupRequestRecord] = [:]
    public private(set) var pendingCreationsByHostId: [UUID: UUID] = [:]
    public private(set) var deletedHostIds: Set<UUID> = []
    public private(set) var lastRoutingFeedback: RoutingFeedback?
    public private(set) var currentRoutingGeneration: Int = 0
    public var lastDeletedHostFeedbackId: UUID?
    public var hostLookup: ((UUID) -> HostProfile?)?
    public var sceneActivationHandler: ((UISceneSession?, NSUserActivity?, UIScene.ActivationRequestOptions?, @escaping (Error?) -> Void) -> Void)?
    public var onOpenHostInNewWindowForTesting: ((UUID) -> Void)?

    public func markHostsDeleted(_ ids: Set<UUID>) {
        deletedHostIds.formUnion(ids)
    }

    public func markHostDeleted(_ hostId: UUID) {
        deletedHostIds.insert(hostId)
    }

    public func isHostDeleted(_ hostId: UUID) -> Bool {
        deletedHostIds.contains(hostId)
    }

    public func invalidateRouting(for hostIds: Set<UUID>) {
        currentRoutingGeneration += 1
        for (id, var req) in startupRequests where hostIds.contains(req.hostId) {
            req.disposition = .canceled
            startupRequests[id] = req
        }
        for hostId in hostIds {
            pendingCreationsByHostId.removeValue(forKey: hostId)
        }
    }

    public var pendingHostId: UUID? {
        get {
            startupRequests.values.first(where: { $0.disposition == .pending })?.hostId
        }
        set {
            for (id, var req) in startupRequests where req.disposition == .pending {
                req.disposition = .canceled
                startupRequests[id] = req
            }
            pendingCreationsByHostId.removeAll()
            if let hostId = newValue {
                _ = enqueueRequest(for: hostId, origin: .userAction)
            }
        }
    }

    public func consumeInitialHostId() -> UUID? {
        let pending = startupRequests.values
            .filter { $0.disposition == .pending }
            .sorted(by: { $0.createdAt < $1.createdAt })
        if let firstPending = pending.last {
            return consumeRequest(id: firstPending.id)?.hostId
        }
        return nil
    }

    @discardableResult
    public func enqueueRequest(
        for hostId: UUID,
        origin: StartupRequestOrigin,
        intendedSessionId: String? = nil
    ) -> StartupRequestRecord {
        if let existingRequestId = pendingCreationsByHostId[hostId],
           let existing = startupRequests[existingRequestId],
           existing.disposition == .pending {
            return existing
        }
        let record = StartupRequestRecord(
            hostId: hostId,
            origin: origin,
            intendedSessionId: intendedSessionId,
            disposition: .pending
        )
        startupRequests[record.id] = record
        pendingCreationsByHostId[hostId] = record.id
        return record
    }

    public func consumeRequest(id: UUID) -> StartupRequestRecord? {
        guard var record = startupRequests[id], record.disposition == .pending else { return nil }
        record.disposition = .consumed
        startupRequests[id] = record
        if pendingCreationsByHostId[record.hostId] == id {
            pendingCreationsByHostId.removeValue(forKey: record.hostId)
        }
        return record
    }

    public func consumeRequest(forScenePid pid: String) -> StartupRequestRecord? {
        if let match = startupRequests.values.first(where: { $0.intendedSessionId == pid && $0.disposition == .pending }) {
            return consumeRequest(id: match.id)
        }
        return nil
    }

    public func cancelRequest(id: UUID) {
        if var record = startupRequests[id] {
            record.disposition = .canceled
            startupRequests[id] = record
            if pendingCreationsByHostId[record.hostId] == id {
                pendingCreationsByHostId.removeValue(forKey: record.hostId)
            }
        }
    }

    public func resetForTesting() {
        startupRequests.removeAll()
        pendingCreationsByHostId.removeAll()
        deletedHostIds.removeAll()
        lastRoutingFeedback = nil
        lastDeletedHostFeedbackId = nil
        hostLookup = nil
        sceneActivationHandler = nil
        onOpenHostInNewWindowForTesting = nil
        currentRoutingGeneration = 0
    }

    public func hostProfile(for hostId: UUID) -> HostProfile? {
        if isHostDeleted(hostId) {
            return nil
        }
        if let custom = hostLookup?(hostId) {
            return custom
        }
        if hostLookup != nil {
            return nil
        }
        if let saved = AppState.loadSavedHosts().first(where: { $0.id == hostId }) {
            return saved
        }
        for record in MultiWindowManager.shared.records.values {
            if let h = record.sessionManager.allHosts.first(where: { $0.id == hostId }) {
                return h
            }
        }
        #if DEBUG
        if NSClassFromString("XCTestCase") != nil ||
           ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
           ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil {
            return HostProfile(id: hostId, name: "TestHost-\(hostId.uuidString.prefix(4))", hostname: "test.local")
        }
        #endif
        return nil
    }

    public func isHostConfigured(_ hostId: UUID) -> Bool {
        return hostProfile(for: hostId) != nil
    }

    public func showDeletedHostFeedback(hostId: UUID) {
        lastDeletedHostFeedbackId = hostId
        for record in MultiWindowManager.shared.records.values {
            if record.status == .owned || record.status == .pending {
                record.sessionManager.showToast(
                    title: "Host Not Found",
                    message: "This host is no longer configured."
                )
            }
        }
    }

    public func requestSceneActivation(
        session: UISceneSession?,
        userActivity: NSUserActivity?,
        options: UIScene.ActivationRequestOptions?,
        errorHandler: @escaping (Error?) -> Void
    ) {
        if let customHandler = sceneActivationHandler {
            customHandler(session, userActivity, options, errorHandler)
        } else {
            UIApplication.shared.requestSceneSessionActivation(
                session,
                userActivity: userActivity,
                options: options,
                errorHandler: errorHandler
            )
        }
    }

    @discardableResult
    public func handleConnectingShortcutItem(_ item: UIApplicationShortcutItem, for persistentIdentifier: String) -> Bool {
        guard item.type == QuickActionManager.connectHostActionType,
              let hostIdString = item.userInfo?[QuickActionManager.hostIdUserInfoKey] as? String,
              let hostId = UUID(uuidString: hostIdString) else {
            return false
        }
        enqueueRequest(for: hostId, origin: .shortcut, intendedSessionId: persistentIdentifier)
        return true
    }

    @discardableResult
    public func handleWarmShortcutItem(_ item: UIApplicationShortcutItem, for persistentIdentifier: String) -> Bool {
        guard item.type == QuickActionManager.connectHostActionType,
              let hostIdString = item.userInfo?[QuickActionManager.hostIdUserInfoKey] as? String,
              let hostId = UUID(uuidString: hostIdString) else {
            return false
        }
        enqueueRequest(for: hostId, origin: .shortcut, intendedSessionId: persistentIdentifier)
        openHostInWindow(hostId: hostId, preferNewWindow: false)
        return true
    }

    @discardableResult
    public func handleConnectingUserActivity(_ activity: NSUserActivity, for persistentIdentifier: String) -> Bool {
        guard activity.activityType == QuickActionManager.connectHostActionType else { return false }
        let hostIdString = (activity.userInfo?[QuickActionManager.hostIdUserInfoKey] as? String)
            ?? activity.targetContentIdentifier?.replacingOccurrences(of: "io.o-t.filaire.host.", with: "")
        guard let hostIdStr = hostIdString, let hostId = UUID(uuidString: hostIdStr) else { return false }

        let reqIdString = activity.userInfo?[QuickActionManager.requestIdUserInfoKey] as? String
        let reqId = reqIdString.flatMap(UUID.init)

        if let reqId = reqId, var record = startupRequests[reqId] {
            record.intendedSessionId = persistentIdentifier
            startupRequests[reqId] = record
        } else {
            enqueueRequest(for: hostId, origin: .userActivity, intendedSessionId: persistentIdentifier)
        }
        return true
    }

    public nonisolated static func targetContentIdentifier(for hostId: UUID) -> String {
        return "io.o-t.filaire.host.\(hostId.uuidString)"
    }

    /// Pure helper to generate up to 4 quick action items from saved hosts sorted by most recently connected (MRU)
    public static func makeShortcutItems(for hosts: [HostProfile]) -> [UIApplicationShortcutItem] {
        let sortedHosts = hosts.enumerated().sorted { a, b in
            switch (a.element.lastConnected, b.element.lastConnected) {
            case let (d1?, d2?):
                if d1 != d2 {
                    return d1 > d2
                }
                return a.offset < b.offset
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return a.offset < b.offset
            }
        }.map(\.element)

        return sortedHosts.prefix(min(4, sortedHosts.count)).map { host in
            var subtitle = host.hostname
            if !host.username.isEmpty {
                subtitle = "\(host.username)@\(host.hostname)"
            }
            if host.autoConnectTmux {
                let session = host.effectiveTmuxSession
                if !session.isEmpty {
                    subtitle += " (tmux: \(session))"
                }
            }

            let item = UIMutableApplicationShortcutItem(
                type: connectHostActionType,
                localizedTitle: host.displayName,
                localizedSubtitle: subtitle,
                icon: UIApplicationShortcutIcon(systemImageName: "terminal"),
                userInfo: [hostIdUserInfoKey: host.id.uuidString as NSString]
            )
            item.targetContentIdentifier = targetContentIdentifier(for: host.id)
            return item
        }
    }

    /// Updates dynamic home screen shortcuts for the application
    public static func updateQuickActions(for hosts: [HostProfile]) {
        UIApplication.shared.shortcutItems = makeShortcutItems(for: hosts)
    }

    /// Tags a window scene and its session with the active host ID
    public func tagScene(_ scene: UIWindowScene, withHostId hostId: UUID?) {
        if let hostId = hostId {
            var info = scene.session.userInfo ?? [:]
            info[QuickActionManager.hostIdUserInfoKey] = hostId.uuidString
            scene.session.userInfo = info

            let targetId = QuickActionManager.targetContentIdentifier(for: hostId)
            let activity = scene.userActivity ?? NSUserActivity(activityType: QuickActionManager.connectHostActionType)
            activity.targetContentIdentifier = targetId
            var actInfo = activity.userInfo ?? [:]
            actInfo[QuickActionManager.hostIdUserInfoKey] = hostId.uuidString
            activity.userInfo = actInfo
            scene.userActivity = activity

            let targetPredicate = NSPredicate(format: "self == %@", targetId)
            scene.activationConditions.canActivateForTargetContentIdentifierPredicate = targetPredicate
            scene.activationConditions.prefersToActivateForTargetContentIdentifierPredicate = targetPredicate
        } else {
            var info = scene.session.userInfo ?? [:]
            info.removeValue(forKey: QuickActionManager.hostIdUserInfoKey)
            scene.session.userInfo = info
            scene.userActivity = nil
            scene.activationConditions.canActivateForTargetContentIdentifierPredicate = NSPredicate(value: true)
            scene.activationConditions.prefersToActivateForTargetContentIdentifierPredicate = NSPredicate(value: false)
        }
    }

    /// Checks if a window scene is associated with a given host ID
    public static func isScene(_ scene: UIWindowScene, associatedWith hostId: UUID) -> Bool {
        let hostIdString = hostId.uuidString
        let expectedTargetId = targetContentIdentifier(for: hostId)

        if let sessionHostId = scene.session.userInfo?[hostIdUserInfoKey] as? String,
           sessionHostId == hostIdString {
            return true
        }

        if let activity = scene.userActivity {
            if let activityHostId = activity.userInfo?[hostIdUserInfoKey] as? String,
               activityHostId == hostIdString {
                return true
            }
            if activity.targetContentIdentifier == expectedTargetId {
                return true
            }
        }

        return false
    }

    /// Finds a connected window scene associated with the specified host ID
    @MainActor
    public static func findScene(
        for hostId: UUID,
        in scenes: [UIWindowScene]? = nil
    ) -> UIWindowScene? {
        let activeScenes = scenes ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return activeScenes.first { $0.activationState != .unattached && isScene($0, associatedWith: hostId) }
    }

    /// Finds an unallocated connected window scene (not dedicated to any active host)
    @MainActor
    public static func findUnallocatedScene(
        in scenes: [UIWindowScene]? = nil
    ) -> UIWindowScene? {
        let activeScenes = scenes ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return activeScenes.first { scene in
            #if DEBUG
            let isTest = NSClassFromString("XCTestCase") != nil ||
                         ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
                         ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
            if !isTest {
                guard scene.activationState != .unattached else { return false }
            }
            #else
            guard scene.activationState != .unattached else { return false }
            #endif

            let hostIdInSession = scene.session.userInfo?[hostIdUserInfoKey] as? String
            let hostIdInActivity = scene.userActivity?.userInfo?[hostIdUserInfoKey] as? String
            let hasHost = (hostIdInSession != nil && !hostIdInSession!.isEmpty) ||
                          (hostIdInActivity != nil && !hostIdInActivity!.isEmpty)
            if let record = MultiWindowManager.shared.records[scene.session.persistentIdentifier],
               record.hostId != nil || (record.sessionManager.state != .disconnected) {
                return false
            }
            return !hasHost
        }
    }

    /// Brings an existing window scene forward, optionally delivering userActivity to trigger connection
    public func activateScene(_ scene: UIWindowScene, hostId: UUID? = nil, errorHandler: ((any Error) -> Void)? = nil) {
        let activity: NSUserActivity?
        if let hostId = hostId {
            activity = NSUserActivity(activityType: QuickActionManager.connectHostActionType)
            activity?.targetContentIdentifier = QuickActionManager.targetContentIdentifier(for: hostId)
            activity?.userInfo = [QuickActionManager.hostIdUserInfoKey: hostId.uuidString]
        } else {
            activity = nil
        }

        UIApplication.shared.requestSceneSessionActivation(
            scene.session,
            userActivity: activity,
            options: nil,
            errorHandler: errorHandler
        )
    }

    /// Handles a tapped shortcut item by routing to the dedicated window for that host
    public func handleShortcutItem(_ item: UIApplicationShortcutItem) {
        guard item.type == QuickActionManager.connectHostActionType,
              let hostIdString = item.userInfo?[QuickActionManager.hostIdUserInfoKey] as? String,
              let hostId = UUID(uuidString: hostIdString) else {
            return
        }

        openHostInWindow(hostId: hostId, preferNewWindow: true)
    }

    @discardableResult
    public func routeHost(
        _ hostId: UUID,
        intent: WindowRoutingIntent = .openDedicated,
        originatingSessionId: String? = nil,
        completion: (@MainActor (WindowRoutingResult) -> Void)? = nil
    ) -> WindowRoutingResult {
        currentRoutingGeneration += 1
        let generation = currentRoutingGeneration

        // 1. Validate host against saved profiles
        guard isHostConfigured(hostId) else {
            if let reqId = pendingCreationsByHostId[hostId] {
                cancelRequest(id: reqId)
            }
            let failure = RoutingFailureReason.hostNotFound(hostId)
            self.lastRoutingFeedback = RoutingFeedback(hostId: hostId, reason: failure, timestamp: Date())
            completion?(.failed(reason: failure))
            return .failed(reason: failure)
        }

        // 2. If intent is switchCurrent, perform immediate switch in specified session
        if case .switchCurrent(let targetSessionPid) = intent {
            if let record = MultiWindowManager.shared.records[targetSessionPid],
               let host = hostProfile(for: hostId) {
                if let reqId = pendingCreationsByHostId[hostId],
                   startupRequests[reqId]?.intendedSessionId == nil {
                    _ = consumeRequest(id: reqId)
                }
                record.sessionManager.connect(to: host, allHosts: record.sessionManager.allHosts, allKeys: record.sessionManager.availableKeys)
                postConnectNotification(hostId: hostId, targetScene: record.scene)
                let result = WindowRoutingResult.switchedCurrent(sessionPersistentIdentifier: targetSessionPid)
                completion?(result)
                return result
            }
        }

        // 3. Check for existing session owning this host (R4)
        if let existingSession = MultiWindowManager.shared.findSceneSession(for: hostId) {
            if let reqId = pendingCreationsByHostId[hostId],
               startupRequests[reqId]?.intendedSessionId == nil {
                _ = consumeRequest(id: reqId)
            }
            let pid = existingSession.persistentIdentifier
            let activity = NSUserActivity(activityType: QuickActionManager.connectHostActionType)
            activity.targetContentIdentifier = QuickActionManager.targetContentIdentifier(for: hostId)
            activity.userInfo = [QuickActionManager.hostIdUserInfoKey: hostId.uuidString]

            requestSceneActivation(session: existingSession, userActivity: activity, options: nil) { [weak self] error in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    guard generation == self.currentRoutingGeneration else { return }
                    if let error = error {
                        let failure = RoutingFailureReason.sceneActivationFailed(error.localizedDescription)
                        self.lastRoutingFeedback = RoutingFeedback(hostId: hostId, reason: failure, timestamp: Date())
                        completion?(.failed(reason: failure))
                    } else {
                        completion?(.activatedExisting(sessionPersistentIdentifier: pid))
                    }
                }
            }
            let result = WindowRoutingResult.activatedExisting(sessionPersistentIdentifier: pid)
            completion?(result)
            return result
        }

        let connectedScenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let existingScene = MultiWindowManager.shared.findScene(for: hostId) ?? QuickActionManager.findScene(for: hostId, in: connectedScenes) {
            if let reqId = pendingCreationsByHostId[hostId],
               startupRequests[reqId]?.intendedSessionId == nil {
                _ = consumeRequest(id: reqId)
            }
            let pid = existingScene.session.persistentIdentifier
            activateScene(existingScene, hostId: hostId)
            let result = WindowRoutingResult.activatedExisting(sessionPersistentIdentifier: pid)
            completion?(result)
            return result
        }

        // 4. If iPhone / multi-window not supported:
        if !UIApplication.shared.supportsMultipleScenes {
            if let reqId = pendingCreationsByHostId[hostId],
               startupRequests[reqId]?.intendedSessionId == nil {
                _ = consumeRequest(id: reqId)
            }
            postConnectNotification(hostId: hostId)
            if let firstRecord = MultiWindowManager.shared.records.values.first,
               let host = hostProfile(for: hostId) {
                firstRecord.sessionManager.connect(to: host, allHosts: firstRecord.sessionManager.allHosts, allKeys: firstRecord.sessionManager.availableKeys)
                let result = WindowRoutingResult.switchedCurrent(sessionPersistentIdentifier: firstRecord.persistentIdentifier)
                completion?(result)
                return result
            }
            let result = WindowRoutingResult.switchedCurrent(sessionPersistentIdentifier: "")
            completion?(result)
            return result
        }

        // 5. Look for verified unallocated empty session (when not strictly dedicated or dedicated allows unallocated empty window)
        if intent != .openDedicated {
            if let host = hostProfile(for: hostId) {
                let records = MultiWindowManager.shared.records.values
                let emptyRecord = records.first { rec in
                    let hasNoHost = rec.hostId == nil
                    let isUsable = rec.status == .owned || rec.status == .pending
                    let isDisconnected = rec.sessionManager.state == .disconnected
                    return hasNoHost && isUsable && isDisconnected
                }
                if let record = emptyRecord {
                    if let reqId = pendingCreationsByHostId[hostId],
                       startupRequests[reqId]?.intendedSessionId == nil {
                        _ = consumeRequest(id: reqId)
                    }
                    record.sessionManager.connect(to: host, allHosts: record.sessionManager.allHosts, allKeys: record.sessionManager.availableKeys)
                    postConnectNotification(hostId: hostId, targetScene: record.scene)
                    let result = WindowRoutingResult.switchedCurrent(sessionPersistentIdentifier: record.persistentIdentifier)
                    completion?(result)
                    return result
                }
            }
            let unalloc = QuickActionManager.findUnallocatedScene(in: connectedScenes)
            if let unallocatedScene = unalloc {
                if let reqId = pendingCreationsByHostId[hostId],
                   startupRequests[reqId]?.intendedSessionId == nil {
                    _ = consumeRequest(id: reqId)
                }
                activateScene(unallocatedScene, hostId: hostId)
                postConnectNotification(hostId: hostId, targetScene: unallocatedScene)
                let result = WindowRoutingResult.switchedCurrent(sessionPersistentIdentifier: unallocatedScene.session.persistentIdentifier)
                completion?(result)
                return result
            }
            if connectedScenes.isEmpty {
                if let reqId = pendingCreationsByHostId[hostId],
                   startupRequests[reqId]?.intendedSessionId == nil {
                    _ = consumeRequest(id: reqId)
                }
                postConnectNotification(hostId: hostId)
                let result = WindowRoutingResult.switchedCurrent(sessionPersistentIdentifier: "")
                completion?(result)
                return result
            }
        }

        // 6. Request new dedicated window creation
        let req = enqueueRequest(for: hostId, origin: .userAction)
        let activity = NSUserActivity(activityType: QuickActionManager.connectHostActionType)
        activity.targetContentIdentifier = QuickActionManager.targetContentIdentifier(for: hostId)
        activity.userInfo = [
            QuickActionManager.hostIdUserInfoKey: hostId.uuidString,
            QuickActionManager.requestIdUserInfoKey: req.id.uuidString
        ]

        let options = UIScene.ActivationRequestOptions()
        requestSceneActivation(session: nil, userActivity: activity, options: options) { [weak self] error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard generation == self.currentRoutingGeneration else {
                    // Late failure for obsolete request: cannot clear or redirect newer request!
                    return
                }

                if let error = error {
                    self.cancelRequest(id: req.id)
                    let failure = RoutingFailureReason.sceneActivationFailed(error.localizedDescription)
                    self.lastRoutingFeedback = RoutingFeedback(hostId: hostId, reason: failure, timestamp: Date())

                    // R5: Preserve every existing connection. DO NOT fall back to an arbitrary connected window!
                    if let origPid = originatingSessionId, let origRecord = MultiWindowManager.shared.records[origPid] {
                        origRecord.sessionManager.showToast(
                            title: "Window Error",
                            message: "Could not open window for host. Tap to retry."
                        )
                    }
                    completion?(.failed(reason: failure))
                } else {
                    completion?(.requestedNewWindow(requestId: req.id))
                }
            }
        }
        return .requestedNewWindow(requestId: req.id)
    }

    /// Enforces multi-window routing:
    /// 1. Attempts to open a connection to an already-connected host opens that host's window.
    /// 2. If host is not connected anywhere:
    ///    - On iPadOS / macOS: opens a new dedicated window (when preferNewWindow is true).
    ///    - On iPhone / current window: routes to current window.
    public func openHostInWindow(hostId: UUID, preferNewWindow: Bool = false) {
        let intent: WindowRoutingIntent = preferNewWindow ? .openDedicated : .focusExisting
        routeHost(hostId, intent: intent)
    }

    /// Explicitly requests a new dedicated window for the host (activates existing if already open, or opens new)
    public func openHostInNewWindow(hostId: UUID) {
        if let hook = onOpenHostInNewWindowForTesting {
            hook(hostId)
            return
        }
        routeHost(hostId, intent: .openDedicated)
    }

    private func postConnectNotification(hostId: UUID, targetScene: UIWindowScene? = nil) {
        guard let targetScene = targetScene else {
            NotificationCenter.default.post(
                name: .connectHostRequested,
                object: nil,
                userInfo: [QuickActionManager.hostIdUserInfoKey: hostId]
            )
            return
        }
        let pid = targetScene.session.persistentIdentifier
        NotificationCenter.default.post(
            name: .connectHostRequested,
            object: targetScene,
            userInfo: [
                QuickActionManager.hostIdUserInfoKey: hostId,
                "targetSessionPersistentIdentifier": pid
            ]
        )
    }
}

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

/// Tracks window/scene session associations and foreground focus across multiple scenes
@MainActor
public final class MultiWindowManager: NSObject, ObservableObject {
    public static let shared = MultiWindowManager()

    @Published public private(set) var snapshots: [UUID: HostWindowState] = [:]

    public struct WindowEntry {
        public weak var sessionManager: SessionManager?
        public weak var scene: UIWindowScene?
        public var sessionPersistentIdentifier: String?
        public var hostId: UUID?
        public var status: WindowEntryStatus
        public var ownershipGeneration: Int
        public var lastInteractionTime: Date
        public var isDetached: Bool { scene == nil }

        public init(
            sessionManager: SessionManager? = nil,
            scene: UIWindowScene? = nil,
            sessionPersistentIdentifier: String? = nil,
            hostId: UUID? = nil,
            status: WindowEntryStatus = .owned,
            ownershipGeneration: Int = 0,
            lastInteractionTime: Date = Date()
        ) {
            self.sessionManager = sessionManager
            self.scene = scene
            self.sessionPersistentIdentifier = sessionPersistentIdentifier ?? scene?.session.persistentIdentifier
            self.hostId = hostId
            self.status = status
            self.ownershipGeneration = ownershipGeneration
            self.lastInteractionTime = lastInteractionTime
        }
    }

    internal private(set) var records: [String: WindowSessionRecord] = [:]
    internal private(set) var entries: [ObjectIdentifier: WindowEntry] = [:]
    private var terminalContexts: [ObjectIdentifier: TerminalSessionContext] = [:]
    internal var pendingTeardownHostIds: Set<UUID> = []
    internal var sessionsWithDestructionInFlight: Set<String> = []
    public static let focusSceneIdentifierKey = "io.o-t.filaire.focus_scene_identifier"

    public var rememberedFocusHostId: UUID? {
        get {
            if let str = UserDefaults.standard.string(forKey: AppState.activeHostKey) {
                return UUID(uuidString: str)
            }
            return nil
        }
        set {
            if let val = newValue {
                UserDefaults.standard.set(val.uuidString, forKey: AppState.activeHostKey)
            } else {
                UserDefaults.standard.removeObject(forKey: AppState.activeHostKey)
            }
        }
    }

    public var rememberedFocusSceneIdentifier: String? {
        get {
            UserDefaults.standard.string(forKey: Self.focusSceneIdentifierKey)
        }
        set {
            if let val = newValue {
                UserDefaults.standard.set(val, forKey: Self.focusSceneIdentifierKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.focusSceneIdentifierKey)
            }
        }
    }

    public internal(set) var mostRecentInteractionSceneIdentifier: String?

    public func currentSnapshot() -> [UUID: HostWindowState] {
        var result: [UUID: HostWindowState] = [:]
        for (pid, record) in records {
            guard let hostId = record.hostId, record.status != .closing else { continue }
            let state = record.sessionManager.state
            let isDetached = record.isDetached
            if let existing = result[hostId] {
                if existing.windowStatus != .owned && record.status == .owned {
                    result[hostId] = HostWindowState(
                        hostId: hostId,
                        ownerSessionPersistentIdentifier: pid,
                        windowStatus: record.status,
                        connectionState: state,
                        isDetached: isDetached
                    )
                }
            } else {
                result[hostId] = HostWindowState(
                    hostId: hostId,
                    ownerSessionPersistentIdentifier: pid,
                    windowStatus: record.status,
                    connectionState: state,
                    isDetached: isDetached
                )
            }
        }
        for (_, entry) in entries {
            guard let hostId = entry.hostId, entry.status != .closing else { continue }
            if result[hostId] == nil {
                let state = entry.sessionManager?.state ?? .disconnected
                result[hostId] = HostWindowState(
                    hostId: hostId,
                    ownerSessionPersistentIdentifier: entry.sessionPersistentIdentifier,
                    windowStatus: entry.status,
                    connectionState: state,
                    isDetached: entry.isDetached
                )
            }
        }
        return result
    }

    public func updateSnapshot() {
        cleanupStaleEntries()
        let newSnapshots = currentSnapshot()
        if newSnapshots != snapshots {
            snapshots = newSnapshots
        }
    }

    internal func wireSessionManagerCallbacks(_ sessionManager: SessionManager) {
        sessionManager.onStateChange = { [weak self] _ in
            self?.updateSnapshot()
        }
        sessionManager.onActiveHostChange = { [weak self] _ in
            self?.updateSnapshot()
        }
    }

    public func recordInteraction(sessionPersistentIdentifier: String?) {
        guard let pid = sessionPersistentIdentifier else { return }
        mostRecentInteractionSceneIdentifier = pid
        rememberedFocusSceneIdentifier = pid
        if let rec = records[pid] {
            rec.lastInteractionTime = Date()
            if let hostId = rec.hostId {
                rememberedFocusHostId = hostId
            }
            syncEntry(for: rec)
        } else if let entry = entries.values.first(where: { $0.sessionPersistentIdentifier == pid }) {
            if let hostId = entry.hostId {
                rememberedFocusHostId = hostId
            }
        }
    }

    internal func syncEntry(for record: WindowSessionRecord) {
        let entry = WindowEntry(
            sessionManager: record.sessionManager,
            scene: record.scene,
            sessionPersistentIdentifier: record.persistentIdentifier,
            hostId: record.hostId,
            status: record.status,
            ownershipGeneration: record.ownershipGeneration,
            lastInteractionTime: record.lastInteractionTime
        )
        entries[ObjectIdentifier(record.sessionManager)] = entry
        updateSnapshot()
    }

    internal func removeRecord(withPersistentIdentifier pid: String) {
        if let record = records.removeValue(forKey: pid) {
            let id = ObjectIdentifier(record.sessionManager)
            entries.removeValue(forKey: id)
            terminalContexts.removeValue(forKey: id)
            record.terminalContext?.teardown()
            record.sessionManager.isCoordinatedByWindowManager = false
            record.sessionManager.shutdown()
            updateSnapshot()
        }
    }

    public override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sceneDidDisconnect(_:)),
            name: UIScene.didDisconnectNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSystemMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
        reconcileWithOpenSessions()
    }

    @objc private func sceneDidDisconnect(_ notification: Notification) {
        if let scene = notification.object as? UIWindowScene {
            handleSceneDidDisconnect(scene)
        }
    }

    internal func handleSceneDidDisconnect(_ scene: UIWindowScene) {
        detach(scene: scene)
    }

    public func detach(scene: UIWindowScene) {
        let pid = scene.session.persistentIdentifier
        sessionsWithDestructionInFlight.remove(pid)
        if let record = records[pid] {
            record.scene = nil
            record.terminalContext?.detachView()
            syncEntry(for: record)
        }
        for (id, var entry) in entries where entry.scene === scene {
            entry.scene = nil
            entries[id] = entry
        }
    }

    @discardableResult
    public func attach(
        scene: UIWindowScene,
        sessionManager: SessionManager,
        hostId: UUID?
    ) -> WindowSessionRecord {
        let pid = scene.session.persistentIdentifier
        return register(
            sessionManager: sessionManager,
            scene: scene,
            hostId: hostId,
            sessionPersistentIdentifier: pid
        )
    }

    public func terminalContext(for sessionManager: SessionManager) -> TerminalSessionContext {
        let id = ObjectIdentifier(sessionManager)
        if let existing = terminalContexts[id] {
            return existing
        }
        if let record = records.values.first(where: { $0.sessionManager === sessionManager }),
           let existing = record.terminalContext {
            terminalContexts[id] = existing
            return existing
        }
        let ctx = TerminalSessionContext(sessionManager: sessionManager)
        terminalContexts[id] = ctx
        if let record = records.values.first(where: { $0.sessionManager === sessionManager }) {
            record.terminalContext = ctx
        }
        return ctx
    }

    public func findSessionRecord(for hostId: UUID) -> WindowSessionRecord? {
        cleanupStaleEntries()
        return records.values.first { $0.hostId == hostId && $0.status != .closing }
    }

    public func findSceneSession(for hostId: UUID) -> UISceneSession? {
        cleanupStaleEntries()
        if let scene = findScene(for: hostId) {
            return scene.session
        }
        if let record = records.values.first(where: { $0.hostId == hostId && $0.status != .closing && ($0.sessionManager.state.isConnected || $0.sessionManager.state.isBusy) }) {
            if let openSession = UIApplication.shared.openSessions.first(where: { $0.persistentIdentifier == record.persistentIdentifier }) {
                return openSession
            }
        }
        return nil
    }

    public enum HostClaimResult: Equatable {
        case claimed
        case alreadyClaimed(existingScene: UIWindowScene?)
    }

    public func entry(for sessionManager: SessionManager) -> WindowEntry? {
        entries[ObjectIdentifier(sessionManager)]
    }

    public func entry(forPersistentIdentifier pid: String) -> WindowEntry? {
        if let record = records[pid] {
            return WindowEntry(
                sessionManager: record.sessionManager,
                scene: record.scene,
                sessionPersistentIdentifier: record.persistentIdentifier,
                hostId: record.hostId,
                status: record.status,
                ownershipGeneration: record.ownershipGeneration,
                lastInteractionTime: record.lastInteractionTime
            )
        }
        return entries.values.first(where: { $0.sessionPersistentIdentifier == pid })
    }

    public func findScene(for sessionManager: SessionManager) -> UIWindowScene? {
        entries[ObjectIdentifier(sessionManager)]?.scene
    }

    public func isHostClaimed(by sessionManager: SessionManager, hostId: UUID) -> Bool {
        if let record = records.values.first(where: { $0.sessionManager === sessionManager }) {
            return record.hostId == hostId && record.status == .owned
        }
        guard let entry = entries[ObjectIdentifier(sessionManager)] else { return false }
        return entry.hostId == hostId && entry.status == .owned
    }

    /// Atomically claims a host for the specified session manager and scene.
    /// If another window has already claimed the host, returns .alreadyClaimed with the existing scene.
    public func claimHost(
        _ hostId: UUID,
        for sessionManager: SessionManager,
        scene: UIWindowScene?
    ) -> HostClaimResult {
        cleanupStaleEntries()
        let id = ObjectIdentifier(sessionManager)
        let pid = scene?.session.persistentIdentifier ?? entries[id]?.sessionPersistentIdentifier

        // If this session manager or record already has this host claimed, confirm .claimed
        if let existing = entries[id], existing.hostId == hostId && existing.status == .owned {
            return .claimed
        }
        if let pid = pid, let record = records[pid], record.hostId == hostId && record.status == .owned {
            return .claimed
        }

        // Check if host is deleted
        if QuickActionManager.shared.isHostDeleted(hostId) {
            return .alreadyClaimed(existingScene: nil)
        }

        // Check if host is currently undergoing teardown from an old connection
        if pendingTeardownHostIds.contains(hostId) {
            return .alreadyClaimed(existingScene: nil)
        }

        // Check if another record already holds this host
        for (otherPid, otherRecord) in records {
            guard otherPid != pid, otherRecord.hostId == hostId, otherRecord.status != .closing else { continue }
            return .alreadyClaimed(existingScene: otherRecord.scene)
        }

        // Check if another entry already holds this host
        for (otherId, otherEntry) in entries {
            guard otherId != id, otherEntry.hostId == hostId, otherEntry.status != .closing else { continue }
            return .alreadyClaimed(existingScene: otherEntry.scene)
        }

        // Check if another connected scene is already associated with this host
        let connectedScenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for otherScene in connectedScenes {
            if let currentScene = scene, otherScene === currentScene { continue }
            if otherScene.activationState != .unattached && QuickActionManager.isScene(otherScene, associatedWith: hostId) {
                return .alreadyClaimed(existingScene: otherScene)
            }
        }

        // If this session manager previously held another host, mark previous host for teardown
        let oldHostId = entries[id]?.hostId ?? pid.flatMap { records[$0]?.hostId }
        if let oldHostId = oldHostId, oldHostId != hostId {
            pendingTeardownHostIds.insert(oldHostId)
            sessionManager.onTeardownComplete = { [weak self] in
                self?.pendingTeardownHostIds.remove(oldHostId)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                self?.pendingTeardownHostIds.remove(oldHostId)
            }
        }

        // Claim host for this session manager
        let persistentId = pid ?? UUID().uuidString
        var gen = entries[id]?.ownershipGeneration ?? pid.flatMap { records[$0]?.ownershipGeneration } ?? 0
        gen += 1

        let record = records[persistentId] ?? WindowSessionRecord(
            persistentIdentifier: persistentId,
            sessionManager: sessionManager,
            scene: scene,
            hostId: hostId,
            status: .owned,
            ownershipGeneration: gen,
            lastInteractionTime: Date()
        )
        record.sessionManager = sessionManager
        record.scene = scene
        record.hostId = hostId
        record.status = .owned
        record.ownershipGeneration = gen
        record.lastInteractionTime = Date()
        if record.terminalContext == nil {
            record.terminalContext = TerminalSessionContext(sessionManager: sessionManager)
        }
        records[persistentId] = record
        syncEntry(for: record)

        if let scene = scene {
            QuickActionManager.shared.tagScene(scene, withHostId: hostId)
        }
        sessionManager.isCoordinatedByWindowManager = true
        wireSessionManagerCallbacks(sessionManager)
        updateSnapshot()

        return .claimed
    }

    /// Scans all registered window entries and connected scenes, deduplicating any multiple windows
    /// that are currently open for or associated with the same host.
    @discardableResult
    public func deduplicateWindows() -> [UUID] {
        cleanupStaleEntries()
        var hostToEntries: [UUID: [(ObjectIdentifier, WindowEntry)]] = [:]
        for (id, entry) in entries {
            if let hostId = entry.hostId, entry.status != .closing {
                hostToEntries[hostId, default: []].append((id, entry))
            }
        }

        var dedupedHostIds: [UUID] = []

        for (hostId, windowEntries) in hostToEntries where windowEntries.count > 1 {
            // First coalesce entries that share the exact same sessionPersistentIdentifier
            var uniqueBySession: [String: (ObjectIdentifier, WindowEntry)] = [:]
            var distinctEntries: [(ObjectIdentifier, WindowEntry)] = []

            for item in windowEntries {
                if let pid = item.1.sessionPersistentIdentifier {
                    if let existing = uniqueBySession[pid] {
                        let existingConnected = existing.1.sessionManager?.state == .connected
                        let itemConnected = item.1.sessionManager?.state == .connected
                        let winner: (ObjectIdentifier, WindowEntry)
                        let victim: (ObjectIdentifier, WindowEntry)
                        if itemConnected && !existingConnected {
                            winner = item
                            victim = existing
                            uniqueBySession[pid] = item
                        } else {
                            winner = existing
                            victim = item
                        }
                        entries.removeValue(forKey: victim.0)
                        if let rec = records[pid] {
                            if let winningSm = winner.1.sessionManager {
                                rec.sessionManager = winningSm
                            }
                            rec.hostId = hostId
                            rec.status = .owned
                            syncEntry(for: rec)
                        }
                        var updatedWinner = winner.1
                        updatedWinner.status = .owned
                        updatedWinner.hostId = hostId
                        entries[winner.0] = updatedWinner
                        uniqueBySession[pid] = (winner.0, updatedWinner)

                        victim.1.sessionManager?.activeHost = nil
                        victim.1.sessionManager?.disconnect(clearActiveHost: true, isUserInitiated: false)
                    } else {
                        uniqueBySession[pid] = item
                    }
                } else {
                    distinctEntries.append(item)
                }
            }
            distinctEntries.append(contentsOf: uniqueBySession.values)

            guard distinctEntries.count > 1 else { continue }
            dedupedHostIds.append(hostId)

            // Deterministic survivor comparison:
            // 1. Established connection (.connected)
            // 2. Connecting / busy state (.isBusy)
            // 3. Accepted reservation (.owned status)
            // 4. Interaction recency (lastInteractionTime)
            // 5. Final stable tie-breaker: sessionPersistentIdentifier
            let sortedEntries = distinctEntries.sorted { a, b in
                let aConnected = a.1.sessionManager?.state == .connected
                let bConnected = b.1.sessionManager?.state == .connected
                if aConnected != bConnected { return aConnected }

                let aBusy = a.1.sessionManager?.state.isBusy ?? false
                let bBusy = b.1.sessionManager?.state.isBusy ?? false
                if aBusy != bBusy { return aBusy }

                let aOwned = a.1.status == .owned
                let bOwned = b.1.status == .owned
                if aOwned != bOwned { return aOwned }

                if a.1.lastInteractionTime != b.1.lastInteractionTime {
                    return a.1.lastInteractionTime > b.1.lastInteractionTime
                }

                let aPid = a.1.sessionPersistentIdentifier ?? ""
                let bPid = b.1.sessionPersistentIdentifier ?? ""
                return aPid > bPid
            }

            guard let primary = sortedEntries.first else { continue }
            let duplicates = sortedEntries.dropFirst()

            for (dupId, dupEntry) in duplicates {
                var updatedDup = dupEntry
                updatedDup.status = .closing
                updatedDup.hostId = nil
                entries[dupId] = updatedDup

                if let pid = dupEntry.sessionPersistentIdentifier, let rec = records[pid] {
                    rec.status = .closing
                    rec.hostId = nil
                }

                dupEntry.sessionManager?.activeHost = nil
                dupEntry.sessionManager?.disconnect(clearActiveHost: true, isUserInitiated: false)

                if let dupScene = dupEntry.scene {
                    QuickActionManager.shared.tagScene(dupScene, withHostId: nil)
                    dupScene.session.userInfo?[QuickActionManager.hostIdUserInfoKey] = nil
                    closeSceneIfMultiple(dupScene)
                }
            }

            var updatedPrimary = primary.1
            updatedPrimary.status = .owned
            updatedPrimary.hostId = hostId
            entries[primary.0] = updatedPrimary

            if let primaryPid = primary.1.sessionPersistentIdentifier, let rec = records[primaryPid] {
                rec.hostId = hostId
                rec.status = .owned
                syncEntry(for: rec)
            }
            if let primaryScene = primary.1.scene {
                QuickActionManager.shared.tagScene(primaryScene, withHostId: hostId)
            }
        }

        let connectedScenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        var sceneHostMap: [UUID: [UIWindowScene]] = [:]
        for scene in connectedScenes where scene.activationState != .unattached {
            for hostId in hostToEntries.keys {
                if QuickActionManager.isScene(scene, associatedWith: hostId) {
                    sceneHostMap[hostId, default: []].append(scene)
                }
            }
        }
        for (hostId, scenes) in sceneHostMap where scenes.count > 1 {
            let primaryScene = findScene(for: hostId) ?? scenes.first
            for scene in scenes where scene !== primaryScene {
                QuickActionManager.shared.tagScene(scene, withHostId: nil)
                scene.session.userInfo?[QuickActionManager.hostIdUserInfoKey] = nil
                closeSceneIfMultiple(scene)
            }
        }

        return dedupedHostIds
    }

    @discardableResult
    public func register(
        sessionManager: SessionManager,
        scene: UIWindowScene?,
        hostId: UUID?,
        sessionPersistentIdentifier: String? = nil
    ) -> WindowSessionRecord {
        cleanupStaleEntries()
        let id = ObjectIdentifier(sessionManager)
        let persistentId = sessionPersistentIdentifier ?? scene?.session.persistentIdentifier ?? entries[id]?.sessionPersistentIdentifier ?? UUID().uuidString

        let record: WindowSessionRecord
        if let existing = records[persistentId] {
            record = existing
            if existing.sessionManager !== sessionManager {
                let existingConnected = existing.sessionManager.state == .connected
                let newConnected = sessionManager.state == .connected
                if newConnected || !existingConnected {
                    entries.removeValue(forKey: ObjectIdentifier(existing.sessionManager))
                    existing.sessionManager = sessionManager
                    existing.terminalContext = terminalContext(for: sessionManager)
                }
            }
            if let scene = scene {
                record.scene = scene
            }
            if record.status != .closing && record.hostId == nil && hostId != nil {
                let alreadyClaimed = records.values.contains { $0.hostId == hostId && $0.status == .owned && $0.persistentIdentifier != persistentId }
                    || entries.values.contains { $0.hostId == hostId && $0.status == .owned && $0.sessionManager !== sessionManager }
                record.hostId = hostId
                record.status = alreadyClaimed ? .pending : .owned
            } else if let hostId = hostId, record.hostId == nil {
                record.hostId = hostId
            }
        } else {
            let alreadyClaimed: Bool
            if let hostId = hostId {
                alreadyClaimed = records.values.contains { $0.hostId == hostId && $0.status == .owned }
                    || entries.values.contains { $0.hostId == hostId && $0.status == .owned && $0.sessionManager !== sessionManager }
            } else {
                alreadyClaimed = false
            }
            record = WindowSessionRecord(
                persistentIdentifier: persistentId,
                sessionManager: sessionManager,
                scene: scene,
                hostId: hostId,
                status: alreadyClaimed ? .pending : .owned,
                ownershipGeneration: 1,
                lastInteractionTime: Date()
            )
            records[persistentId] = record
        }

        if record.terminalContext == nil {
            record.terminalContext = terminalContext(for: record.sessionManager)
        }

        syncEntry(for: record)
        if record.sessionManager !== sessionManager {
            let entry = WindowEntry(
                sessionManager: sessionManager,
                scene: record.scene,
                sessionPersistentIdentifier: record.persistentIdentifier,
                hostId: record.hostId,
                status: record.status,
                ownershipGeneration: record.ownershipGeneration,
                lastInteractionTime: record.lastInteractionTime
            )
            entries[id] = entry
        }

        record.sessionManager.isCoordinatedByWindowManager = true
        wireSessionManagerCallbacks(record.sessionManager)
        if hostId != nil {
            deduplicateWindows()
        }
        updateSnapshot()

        return record
    }

    public func updateHostId(_ hostId: UUID?, for sessionManager: SessionManager) {
        let id = ObjectIdentifier(sessionManager)
        if let record = records.values.first(where: { $0.sessionManager === sessionManager }) {
            guard record.status != .closing else { return }
            record.hostId = hostId
            record.ownershipGeneration += 1
            record.lastInteractionTime = Date()
            syncEntry(for: record)
        } else if var entry = entries[id], entry.status != .closing {
            entry.hostId = hostId
            entry.ownershipGeneration += 1
            entry.lastInteractionTime = Date()
            entries[id] = entry
            updateSnapshot()
        }
        if hostId != nil {
            deduplicateWindows()
        }
    }

    public func unregister(sessionManager: SessionManager) {
        entries.removeValue(forKey: ObjectIdentifier(sessionManager))
        if let pid = records.first(where: { $0.value.sessionManager === sessionManager })?.key {
            removeRecord(withPersistentIdentifier: pid)
        }
    }

    public func unregister(scene: UIWindowScene) {
        let pid = scene.session.persistentIdentifier
        sessionsWithDestructionInFlight.remove(pid)
        entries = entries.filter { $0.value.scene !== scene }
        if let record = records[pid] {
            record.scene = nil
            record.terminalContext?.detachView()
            syncEntry(for: record)
        }
    }

    public func discardSessions(_ sessions: Set<UISceneSession>) {
        let persistentIdentifiers = Set(sessions.map(\.persistentIdentifier))
        discardSessions(matchingPersistentIdentifiers: persistentIdentifiers)
    }

    internal func discardSessions(matchingPersistentIdentifiers persistentIdentifiers: Set<String>) {
        guard !persistentIdentifiers.isEmpty else { return }
        for pid in persistentIdentifiers {
            sessionsWithDestructionInFlight.remove(pid)
            FilePreviewManager.shared.cancelSession(pid)
            if let record = records.removeValue(forKey: pid) {
                entries.removeValue(forKey: ObjectIdentifier(record.sessionManager))
                if let hostId = record.hostId {
                    pendingTeardownHostIds.remove(hostId)
                }
                record.terminalContext?.teardown()
                record.sessionManager.activeHost = nil
                record.sessionManager.disconnect(clearActiveHost: true, isUserInitiated: false)
            }
        }
        let toRemove = entries.filter { _, entry in
            if let pid = entry.sessionPersistentIdentifier ?? entry.scene?.session.persistentIdentifier {
                return persistentIdentifiers.contains(pid)
            }
            return false
        }
        for (id, entry) in toRemove {
            if let pid = entry.sessionPersistentIdentifier ?? entry.scene?.session.persistentIdentifier {
                FilePreviewManager.shared.cancelSession(pid)
            }
            if let hostId = entry.hostId {
                pendingTeardownHostIds.remove(hostId)
            }
            entry.sessionManager?.activeHost = nil
            entry.sessionManager?.disconnect(clearActiveHost: true, isUserInitiated: false)
            entries.removeValue(forKey: id)
        }
    }

    public func reconcileWithOpenSessions() {
        guard forceMultipleWindowsForTesting == nil else { return }
        let openSessions = UIApplication.shared.openSessions.filter { session in
            session.role == .windowApplication
        }
        let openPids = Set(openSessions.map(\.persistentIdentifier))

        if !openSessions.isEmpty {
            let stalePids = records.filter { (pid, record) in
                guard !openPids.contains(pid) else { return false }
                if let scene = record.scene {
                    return !openPids.contains(scene.session.persistentIdentifier)
                }
                return false
            }.map(\.key)
            for stalePid in stalePids {
                removeRecord(withPersistentIdentifier: stalePid)
            }
        }

        for session in openSessions {
            let pid = session.persistentIdentifier
            let scene = session.scene as? UIWindowScene
            let hostIdFromUserInfo: UUID? = (session.userInfo?[QuickActionManager.hostIdUserInfoKey] as? String).flatMap(UUID.init)

            if let existingRecord = records[pid] {
                if scene != nil {
                    existingRecord.scene = scene
                }
                if existingRecord.hostId == nil && hostIdFromUserInfo != nil {
                    existingRecord.hostId = hostIdFromUserInfo
                }
                syncEntry(for: existingRecord)
            }
        }
        deduplicateWindows()
    }

    public func isHostDeleted(_ hostId: UUID) -> Bool {
        QuickActionManager.shared.isHostDeleted(hostId)
    }

    public func invalidateAndCleanup(deletedHostIds: Set<UUID>) {
        guard !deletedHostIds.isEmpty else { return }
        QuickActionManager.shared.markHostsDeleted(deletedHostIds)
        QuickActionManager.shared.invalidateRouting(for: deletedHostIds)

        for deletedId in deletedHostIds {
            pendingTeardownHostIds.remove(deletedId)
        }

        // Clean up matching records
        for record in records.values {
            let matches = (record.hostId != nil && deletedHostIds.contains(record.hostId!)) ||
                          (record.sessionManager.activeHost != nil && deletedHostIds.contains(record.sessionManager.activeHost!.id))
            if matches {
                record.sessionManager.cancelReconnect()
                record.sessionManager.connectTask?.cancel()
                record.sessionManager.connectTask = nil
                record.sessionManager.isConnecting = false
                record.sessionManager.cancelPendingSecurityPrompt()
                FilePreviewManager.shared.cancelSession(record.persistentIdentifier)
                if let connId = record.sessionManager.currentConnectionId?.uuidString {
                    record.sessionManager.filePreviewManager.cancelSession(connId)
                }
                record.sessionManager.disconnect(clearActiveHost: true, isUserInitiated: false, reason: .hostDeleted)
                record.hostId = nil
                record.ownershipGeneration += 1
                syncEntry(for: record)

                if let scene = record.scene {
                    QuickActionManager.shared.tagScene(scene, withHostId: nil)
                    scene.session.userInfo?[QuickActionManager.hostIdUserInfoKey] = nil
                    closeSceneIfMultiple(scene)
                }
            }
        }

        // Clean up matching entries
        for (id, var entry) in entries {
            let matches = (entry.hostId != nil && deletedHostIds.contains(entry.hostId!)) ||
                          (entry.sessionManager?.activeHost != nil && deletedHostIds.contains(entry.sessionManager!.activeHost!.id))
            if matches {
                entry.sessionManager?.cancelReconnect()
                entry.sessionManager?.connectTask?.cancel()
                entry.sessionManager?.connectTask = nil
                entry.sessionManager?.isConnecting = false
                entry.sessionManager?.cancelPendingSecurityPrompt()
                entry.sessionManager?.disconnect(clearActiveHost: true, isUserInitiated: false, reason: .hostDeleted)
                entry.hostId = nil
                entry.ownershipGeneration += 1
                entries[id] = entry

                if let scene = entry.scene {
                    QuickActionManager.shared.tagScene(scene, withHostId: nil)
                    scene.session.userInfo?[QuickActionManager.hostIdUserInfoKey] = nil
                    closeSceneIfMultiple(scene)
                }
            }
        }

        // Untag and close connected scenes associated with deleted hosts
        let connectedScenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in connectedScenes {
            let matches = deletedHostIds.contains { QuickActionManager.isScene(scene, associatedWith: $0) }
            if matches {
                QuickActionManager.shared.tagScene(scene, withHostId: nil)
                scene.session.userInfo?[QuickActionManager.hostIdUserInfoKey] = nil
                closeSceneIfMultiple(scene)
            }
        }

        // Clean open session userInfos
        for session in UIApplication.shared.openSessions {
            if let hostIdStr = session.userInfo?[QuickActionManager.hostIdUserInfoKey] as? String,
               let uid = UUID(uuidString: hostIdStr),
               deletedHostIds.contains(uid) {
                session.userInfo?[QuickActionManager.hostIdUserInfoKey] = nil
            }
        }
    }

    public private(set) var isSystemMemoryWarningActive: Bool = false

    @objc public func handleSystemMemoryWarning() {
        isSystemMemoryWarningActive = true
        // 1. Release spare coalescer storage across all sessions
        var notifiedSessions = Set<ObjectIdentifier>()
        for record in records.values {
            let id = ObjectIdentifier(record.sessionManager)
            if notifiedSessions.insert(id).inserted {
                record.sessionManager.handleMemoryWarning()
            }
        }
        for entry in entries.values {
            if let sm = entry.sessionManager {
                let id = ObjectIdentifier(sm)
                if notifiedSessions.insert(id).inserted {
                    sm.handleMemoryWarning()
                }
            }
        }

        // 2. Trim background terminals first
        for record in records.values {
            let isForeground = (record.scene?.activationState == .foregroundActive)
            if !isForeground {
                record.terminalContext?.terminalView.shedMemoryPressure()
            }
        }

        // 3. Trim visible terminals next if memory pressure is critical
        for record in records.values {
            let isForeground = (record.scene?.activationState == .foregroundActive)
            if isForeground {
                record.terminalContext?.terminalView.shedMemoryPressure()
            }
        }
    }

    public func resetForTesting() {
        records.removeAll()
        entries.removeAll()
        terminalContexts.removeAll()
        snapshots.removeAll()
        pendingTeardownHostIds.removeAll()
        sessionsWithDestructionInFlight.removeAll()
        forceMultipleWindowsForTesting = nil
        onSceneSessionDestructionRequestedForTesting = nil
        isSystemMemoryWarningActive = false
        mostRecentInteractionSceneIdentifier = nil
        rememberedFocusHostId = nil
        rememberedFocusSceneIdentifier = nil
        UserDefaults.standard.removeObject(forKey: AppState.activeHostKey)
        UserDefaults.standard.removeObject(forKey: Self.focusSceneIdentifierKey)
        updateSnapshot()
    }

    public func installRecordForTesting(_ record: WindowSessionRecord) {
        records[record.persistentIdentifier] = record
        record.sessionManager.isCoordinatedByWindowManager = true
        wireSessionManagerCallbacks(record.sessionManager)
        syncEntry(for: record)
        updateSnapshot()
    }

    /// Checks if a host is currently open in any window scene or managed window entry, optionally excluding a specific session manager
    public func isHostOpenAnywhere(_ hostId: UUID, excluding sessionManager: SessionManager? = nil) -> Bool {
        if let snap = snapshots[hostId] {
            if let excluding = sessionManager {
                let excludingPid = entries[ObjectIdentifier(excluding)]?.sessionPersistentIdentifier ??
                    records.values.first(where: { $0.sessionManager === excluding })?.persistentIdentifier
                if let excludingPid = excludingPid, snap.ownerSessionPersistentIdentifier == excludingPid {
                    return false
                }
            }
            if snap.windowStatus == .owned {
                return true
            }
        }
        for (_, record) in records {
            if let sessionManager = sessionManager, record.sessionManager === sessionManager {
                continue
            }
            guard record.hostId == hostId, record.status != .closing else { continue }
            if let scene = record.scene {
                if scene.activationState != .unattached {
                    return true
                }
            } else {
                return true
            }
        }
        for (id, entry) in entries {
            if let sessionManager = sessionManager, id == ObjectIdentifier(sessionManager) {
                continue
            }
            guard entry.hostId == hostId, entry.status != .closing else { continue }
            if let scene = entry.scene {
                if scene.activationState != .unattached {
                    return true
                }
            } else {
                return true
            }
        }
        let excludingScene = sessionManager.flatMap { entries[ObjectIdentifier($0)]?.scene }
        if let excludingScene = excludingScene {
            let connectedScenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            return QuickActionManager.findScene(for: hostId, in: connectedScenes.filter { $0 !== excludingScene }) != nil
        }
        return QuickActionManager.findScene(for: hostId) != nil
    }

    internal func cleanupStaleEntries() {
        entries = entries.filter { $0.value.sessionManager != nil }
    }

    /// Returns true if any window scene belonging to the application is currently in the foreground.
    public var isAnySceneInForeground: Bool {
        UIApplication.shared.connectedScenes.contains { scene in
            guard scene.activationState != .unattached else { return false }
            return scene.activationState == .foregroundActive || scene.activationState == .foregroundInactive
        }
    }

    internal var forceMultipleWindowsForTesting: Bool? = nil
    internal var onSceneSessionDestructionRequestedForTesting: ((UISceneSession) -> Void)? = nil

    /// Returns the count of open windows/sessions that are not currently undergoing destruction.
    public var eligibleSessionCount: Int {
        if let forced = forceMultipleWindowsForTesting {
            return forced ? 2 : 1
        }
        cleanupStaleEntries()
        let openSessions = UIApplication.shared.openSessions
        let inFlight = sessionsWithDestructionInFlight
        let activeSessions = openSessions.filter { !inFlight.contains($0.persistentIdentifier) }
        if !activeSessions.isEmpty {
            return activeSessions.count
        }
        let validRecords = records.values.filter { !inFlight.contains($0.persistentIdentifier) && $0.status != .closing }
        if !validRecords.isEmpty {
            return validRecords.count
        }
        let connectedScenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let validScenes = connectedScenes.filter {
            $0.activationState != .unattached && !inFlight.contains($0.session.persistentIdentifier)
        }
        if !validScenes.isEmpty {
            return validScenes.count
        }
        let validEntries = entries.values.filter { entry in
            guard entry.sessionManager != nil else { return false }
            if let pid = entry.sessionPersistentIdentifier ?? entry.scene?.session.persistentIdentifier {
                return !inFlight.contains(pid)
            }
            return true
        }
        return validEntries.count
    }

    /// Returns true if there is more than one active/attached window scene currently open and not pending destruction.
    public var hasMultipleOpenWindows: Bool {
        eligibleSessionCount > 1
    }

    public struct WindowFocusCandidate: Equatable, Sendable {
        public let persistentIdentifier: String
        public let hostId: UUID?
        public let lastInteractionTime: Date
        public let isForeground: Bool
        public let isConnected: Bool

        public init(
            persistentIdentifier: String,
            hostId: UUID? = nil,
            lastInteractionTime: Date = Date(),
            isForeground: Bool = false,
            isConnected: Bool = false
        ) {
            self.persistentIdentifier = persistentIdentifier
            self.hostId = hostId
            self.lastInteractionTime = lastInteractionTime
            self.isForeground = isForeground
            self.isConnected = isConnected
        }
    }

    public func selectOtherActiveWindow(
        excludingPersistentIdentifier excludedPid: String?,
        excludingScene: UIWindowScene? = nil
    ) -> (candidate: WindowFocusCandidate, scene: UIWindowScene?)? {
        cleanupStaleEntries()
        var candidateMap: [String: (candidate: WindowFocusCandidate, scene: UIWindowScene?)] = [:]

        // 1. Check records
        for (pid, record) in records {
            if let excludedPid = excludedPid, pid == excludedPid { continue }
            if let scene = record.scene, let excludingScene = excludingScene, scene === excludingScene { continue }
            if sessionsWithDestructionInFlight.contains(pid) { continue }
            guard record.status != .closing else { continue }
            if let scene = record.scene, scene.activationState == .unattached { continue }

            let isForeground = (record.scene?.activationState == .foregroundActive || record.scene?.activationState == .foregroundInactive)
            let isConnected = (record.sessionManager.state == .connected || record.sessionManager.state.isBusy)
            let candidate = WindowFocusCandidate(
                persistentIdentifier: pid,
                hostId: record.hostId,
                lastInteractionTime: record.lastInteractionTime,
                isForeground: isForeground,
                isConnected: isConnected
            )
            candidateMap[pid] = (candidate, record.scene)
        }

        // 2. Check entries
        for (_, entry) in entries {
            guard let pid = entry.sessionPersistentIdentifier else { continue }
            if let excludedPid = excludedPid, pid == excludedPid { continue }
            if let scene = entry.scene, let excludingScene = excludingScene, scene === excludingScene { continue }
            if sessionsWithDestructionInFlight.contains(pid) { continue }
            guard entry.status != .closing else { continue }
            if let scene = entry.scene, scene.activationState == .unattached { continue }

            if candidateMap[pid] == nil {
                let isForeground = (entry.scene?.activationState == .foregroundActive || entry.scene?.activationState == .foregroundInactive)
                let isConnected = (entry.sessionManager?.state == .connected || entry.sessionManager?.state.isBusy == true)
                let candidate = WindowFocusCandidate(
                    persistentIdentifier: pid,
                    hostId: entry.hostId,
                    lastInteractionTime: entry.lastInteractionTime,
                    isForeground: isForeground,
                    isConnected: isConnected
                )
                candidateMap[pid] = (candidate, entry.scene)
            }
        }

        // 3. Check connected scenes (only those tracked by MultiWindowManager)
        let connectedScenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in connectedScenes {
            let pid = scene.session.persistentIdentifier
            if let excludedPid = excludedPid, pid == excludedPid { continue }
            if let excludingScene = excludingScene, scene === excludingScene { continue }
            if sessionsWithDestructionInFlight.contains(pid) { continue }
            guard scene.activationState != .unattached else { continue }
            guard records[pid] != nil || entries.values.contains(where: { $0.sessionPersistentIdentifier == pid || $0.scene === scene }) else { continue }

            if candidateMap[pid] == nil {
                let hostId = (scene.session.userInfo?[QuickActionManager.hostIdUserInfoKey] as? String).flatMap(UUID.init)
                let isForeground = (scene.activationState == .foregroundActive || scene.activationState == .foregroundInactive)
                let candidate = WindowFocusCandidate(
                    persistentIdentifier: pid,
                    hostId: hostId,
                    lastInteractionTime: Date.distantPast,
                    isForeground: isForeground,
                    isConnected: false
                )
                candidateMap[pid] = (candidate, scene)
            }
        }

        return candidateMap.values.sorted { a, b in
            if a.candidate.isForeground != b.candidate.isForeground {
                return a.candidate.isForeground
            }
            if a.candidate.isConnected != b.candidate.isConnected {
                return a.candidate.isConnected
            }
            if a.candidate.lastInteractionTime != b.candidate.lastInteractionTime {
                return a.candidate.lastInteractionTime > b.candidate.lastInteractionTime
            }
            return a.candidate.persistentIdentifier > b.candidate.persistentIdentifier
        }.first
    }

    public func rememberFocusWindow(candidate: WindowFocusCandidate) {
        let focusPid = candidate.persistentIdentifier
        rememberedFocusSceneIdentifier = focusPid
        mostRecentInteractionSceneIdentifier = focusPid

        if let hostId = candidate.hostId {
            rememberedFocusHostId = hostId
            var savedHosts = AppState.loadSavedHosts()
            if let idx = savedHosts.firstIndex(where: { $0.id == hostId }) {
                savedHosts[idx].lastConnected = Date()
                if let data = try? JSONEncoder().encode(savedHosts) {
                    UserDefaults.standard.set(data, forKey: AppState.savedHostsKey)
                }
                QuickActionManager.updateQuickActions(for: savedHosts)
            }
        }
    }

    /// Auto-reconnects the session associated with the given persistent identifier if it's
    /// disconnected or failed without an intentional disconnect. This ensures that when a
    /// window becomes the focus (e.g. after closing another window), it stays connected
    /// as part of the core UX.
    public func autoReconnectIfNeeded(persistentIdentifier pid: String) {
        guard let record = records[pid] else { return }
        let sm = record.sessionManager
        guard sm.activeHost != nil, !sm.isIntentionalDisconnect else { return }
        if sm.state == .disconnected || sm.state.isFailed {
            sm.reconnect()
        }
    }

    /// Closes the specified window scene if it isn't the last open session/window.
    /// Returns true if destruction was requested, false if this is the last open session/window.
    @discardableResult
    public func closeWindowIfMultiple(for sessionManager: SessionManager) -> Bool {
        cleanupStaleEntries()
        let id = ObjectIdentifier(sessionManager)
        let scene = records.values.first(where: { $0.sessionManager === sessionManager })?.scene ?? entries[id]?.scene
        if let validScene = scene {
            return closeSceneIfMultiple(validScene)
        }
        guard hasMultipleOpenWindows else {
            return false
        }
        let pid = records.values.first(where: { $0.sessionManager === sessionManager })?.persistentIdentifier
            ?? entries[id]?.sessionPersistentIdentifier
            ?? UUID().uuidString

        if let record = records[pid] {
            record.status = .closing
            record.hostId = nil
            record.sessionManager.activeHost = nil
            syncEntry(for: record)
        }
        if var entry = entries[id] {
            entry.status = .closing
            entry.hostId = nil
            entry.sessionManager?.activeHost = nil
            entries[id] = entry
        }
        updateSnapshot()

        if let match = selectOtherActiveWindow(excludingPersistentIdentifier: pid, excludingScene: nil) {
            if let targetScene = match.scene {
                QuickActionManager.shared.activateScene(targetScene)
            }
            recordInteraction(sessionPersistentIdentifier: match.candidate.persistentIdentifier)
            rememberFocusWindow(candidate: match.candidate)
            autoReconnectIfNeeded(persistentIdentifier: match.candidate.persistentIdentifier)
        }
        return true
    }

    /// Closes the specified window scene if it isn't the last open session/window.
    /// Returns true if destruction was requested, false if this is the last open session/window.
    @discardableResult
    public func closeSceneIfMultiple(_ scene: UIWindowScene) -> Bool {
        let session = scene.session
        let pid = session.persistentIdentifier
        if sessionsWithDestructionInFlight.contains(pid) {
            return true
        }
        guard hasMultipleOpenWindows else {
            return false
        }
        sessionsWithDestructionInFlight.insert(pid)

        // 1. Untag and clear the closing scene session so it cannot re-claim the host
        QuickActionManager.shared.tagScene(scene, withHostId: nil)
        scene.session.userInfo?[QuickActionManager.hostIdUserInfoKey] = nil
        scene.userActivity = nil
        scene.session.stateRestorationActivity = nil

        if let record = records[pid] {
            record.status = .closing
            record.hostId = nil
            record.sessionManager.activeHost = nil
            syncEntry(for: record)
        }
        for (id, var entry) in entries where entry.sessionPersistentIdentifier == pid || entry.scene === scene {
            entry.status = .closing
            entry.hostId = nil
            entry.sessionManager?.activeHost = nil
            entries[id] = entry
        }
        updateSnapshot()

        // 2. Focus one of the other active windows and remember it
        if let match = selectOtherActiveWindow(excludingPersistentIdentifier: pid, excludingScene: scene) {
            if let targetScene = match.scene {
                QuickActionManager.shared.activateScene(targetScene)
                targetScene.windows.first(where: { $0.isKeyWindow })?.makeKeyAndVisible()
            }
            recordInteraction(sessionPersistentIdentifier: match.candidate.persistentIdentifier)
            rememberFocusWindow(candidate: match.candidate)
            autoReconnectIfNeeded(persistentIdentifier: match.candidate.persistentIdentifier)
        }

        // 3. Request destruction
        if let hook = onSceneSessionDestructionRequestedForTesting {
            hook(session)
            return true
        }
        UIApplication.shared.requestSceneSessionDestruction(session, options: nil) { [weak self] error in
            #if DEBUG
            print("[MultiWindowManager] requestSceneSessionDestruction error: \(error)")
            #endif
            self?.sessionsWithDestructionInFlight.remove(pid)
        }
        return true
    }

    /// Checks if a window dedicated to the host is currently in the active foreground and has user focus.
    public func isHostFocused(_ hostId: UUID) -> Bool {
        return NotificationPresentationPolicy.shared.decision(for: hostId) == .inWindowToast
    }

    /// Finds an active window scene associated with the host.
    public func findScene(for hostId: UUID) -> UIWindowScene? {
        cleanupStaleEntries()
        if let record = records.values.first(where: { $0.hostId == hostId && $0.scene?.activationState != .unattached && $0.status != .closing }),
           let scene = record.scene {
            return scene
        }
        if let entry = entries.values.first(where: { $0.hostId == hostId && $0.scene?.activationState != .unattached && $0.status != .closing }),
           let scene = entry.scene {
            return scene
        }
        return QuickActionManager.findScene(for: hostId)
    }

    /// Checks if the host has an active or connecting session in any open window.
    public func isHostConnected(_ hostId: UUID) -> Bool {
        cleanupStaleEntries()
        for record in records.values {
            guard record.hostId == hostId, record.status != .closing else { continue }
            if let scene = record.scene, scene.activationState == .unattached {
                continue
            }
            if record.sessionManager.state.isConnected || record.sessionManager.state.isBusy {
                return true
            }
        }
        for entry in entries.values {
            guard entry.hostId == hostId, entry.status != .closing else { continue }
            if let scene = entry.scene, scene.activationState == .unattached {
                continue
            }
            if let sm = entry.sessionManager, (sm.state.isConnected || sm.state.isBusy) {
                return true
            }
        }
        return false
    }

    /// Coordinates scene phase changes across all open windows.
    /// Connections remain active in all windows when ANY window is open.
    public func handleScenePhaseChange(scenePhase: ScenePhase, sessionManager: SessionManager, hosts: [HostProfile]) {
        if scenePhase == .active {
            deduplicateWindows()
            reconcileWithOpenSessions()
            // Bring all sessions to foreground mode if they were backgrounded
            var notifiedSessions = Set<ObjectIdentifier>()
            for record in records.values {
                let id = ObjectIdentifier(record.sessionManager)
                if notifiedSessions.insert(id).inserted && record.sessionManager.isAppInBackground {
                    record.sessionManager.handleAppForegrounded()
                }
            }
            for entry in entries.values {
                if let sm = entry.sessionManager {
                    let id = ObjectIdentifier(sm)
                    if notifiedSessions.insert(id).inserted && sm.isAppInBackground {
                        sm.handleAppForegrounded()
                    }
                }
            }
            if notifiedSessions.insert(ObjectIdentifier(sessionManager)).inserted && sessionManager.isAppInBackground {
                sessionManager.handleAppForegrounded()
            }
            if let record = records.values.first(where: { $0.sessionManager === sessionManager }) {
                record.terminalContext?.handleVisibilityChanged(isVisible: true)
            }
        } else if scenePhase == .background {
            if let record = records.values.first(where: { $0.sessionManager === sessionManager }) {
                record.terminalContext?.handleVisibilityChanged(isVisible: false)
            }
            QuickActionManager.updateQuickActions(for: hosts)
            // Allow other scene transitions in this runloop cycle to complete before evaluating app foreground state
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if !self.isAnySceneInForeground {
                    // All windows are in the background: now transition sessions to background mode
                    var bgNotified = Set<ObjectIdentifier>()
                    for record in self.records.values {
                        let id = ObjectIdentifier(record.sessionManager)
                        if bgNotified.insert(id).inserted {
                            record.sessionManager.handleAppBackgrounded()
                        }
                    }
                    for entry in self.entries.values {
                        if let sm = entry.sessionManager {
                            let id = ObjectIdentifier(sm)
                            if bgNotified.insert(id).inserted {
                                sm.handleAppBackgrounded()
                            }
                        }
                    }
                }
            }
        }
    }

    @objc private func applicationDidEnterBackground() {
        var notifiedSessions = Set<ObjectIdentifier>()
        for record in records.values {
            let id = ObjectIdentifier(record.sessionManager)
            if notifiedSessions.insert(id).inserted {
                record.sessionManager.handleAppBackgrounded()
            }
        }
        for entry in entries.values {
            if let sm = entry.sessionManager {
                let id = ObjectIdentifier(sm)
                if notifiedSessions.insert(id).inserted {
                    sm.handleAppBackgrounded()
                }
            }
        }
    }

    @objc private func applicationWillEnterForeground() {
        deduplicateWindows()
        reconcileWithOpenSessions()
        var notifiedSessions = Set<ObjectIdentifier>()
        for record in records.values {
            let id = ObjectIdentifier(record.sessionManager)
            if notifiedSessions.insert(id).inserted {
                if record.sessionManager.isAppInBackground {
                    record.sessionManager.handleAppForegrounded()
                }
            }
        }
        for entry in entries.values {
            if let sm = entry.sessionManager {
                let id = ObjectIdentifier(sm)
                if notifiedSessions.insert(id).inserted {
                    if sm.isAppInBackground {
                        sm.handleAppForegrounded()
                    }
                }
            }
        }
    }
}

public enum NotificationPresentationDecision: Equatable, Sendable {
    case inWindowToast
    case systemAlert
}

@MainActor
public final class NotificationPresentationPolicy {
    public static let shared = NotificationPresentationPolicy()

    public func decision(for hostId: UUID?) -> NotificationPresentationDecision {
        guard let hostId = hostId else { return .systemAlert }
        MultiWindowManager.shared.cleanupStaleEntries()

        let record = MultiWindowManager.shared.records.values.first(where: {
            $0.hostId == hostId && $0.status != .closing
        })
        let entry = MultiWindowManager.shared.entries.values.first(where: {
            $0.hostId == hostId && $0.status != .closing
        })

        guard record != nil || entry != nil else {
            return .systemAlert
        }

        guard let scene = record?.scene ?? entry?.scene else {
            return .systemAlert
        }
        #if DEBUG
        let isTesting = NSClassFromString("XCTestCase") != nil
        if !isTesting {
            guard scene.activationState == .foregroundActive else {
                return .systemAlert
            }
            guard scene.windows.contains(where: { $0.isKeyWindow }) else {
                return .systemAlert
            }
        }
        #else
        guard scene.activationState == .foregroundActive else {
            return .systemAlert
        }

        guard scene.windows.contains(where: { $0.isKeyWindow }) else {
            return .systemAlert
        }
        #endif

        let pid = record?.persistentIdentifier ?? entry?.sessionPersistentIdentifier ?? scene.session.persistentIdentifier
        if let mostRecent = MultiWindowManager.shared.mostRecentInteractionSceneIdentifier,
           mostRecent != pid {
            return .systemAlert
        }

        if let context = record?.terminalContext {
            if context.isCoveredByPresentation || context.focusIntent != .terminal {
                return .systemAlert
            }
        }

        if let sm = record?.sessionManager ?? entry?.sessionManager {
            if sm.pendingSecurityPrompt != nil {
                return .systemAlert
            }
            if sm.filePreviewManager.previewURL != nil {
                return .systemAlert
            }
        }

        if FilePreviewManager.shared.previewURL != nil {
            return .systemAlert
        }

        if let win = scene.windows.first(where: { $0.isKeyWindow }),
           win.rootViewController?.presentedViewController != nil {
            return .systemAlert
        }

        return .inWindowToast
    }
}
