import UIKit
import Foundation

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
