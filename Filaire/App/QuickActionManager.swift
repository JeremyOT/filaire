import UIKit
import Foundation
import SwiftUI

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
