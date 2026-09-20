import SwiftUI
import UserNotifications
import QuickLook

@MainActor
final class NotificationDelegate: NSObject, @preconcurrency UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()

    func presentationOptions(for userInfo: [AnyHashable: Any], targetContentIdentifier: String? = nil) -> UNNotificationPresentationOptions {
        let hostIdString = (userInfo[QuickActionManager.hostIdUserInfoKey] as? String)
            ?? targetContentIdentifier?.replacingOccurrences(of: "io.o-t.filaire.host.", with: "")
        let hostId = hostIdString.flatMap { UUID(uuidString: $0) }
        let decision = NotificationPresentationPolicy.shared.decision(for: hostId)
        if decision == .inWindowToast {
            return []
        }
        return [.banner, .sound, .badge, .list]
    }

    func handleNotificationResponse(
        userInfo: [AnyHashable: Any],
        targetContentIdentifier: String? = nil,
        intendedSessionId: String? = nil
    ) {
        let hostIdString = (userInfo[QuickActionManager.hostIdUserInfoKey] as? String)
            ?? targetContentIdentifier?.replacingOccurrences(of: "io.o-t.filaire.host.", with: "")
        if let hostIdString = hostIdString,
           let hostId = UUID(uuidString: hostIdString) {
            guard QuickActionManager.shared.isHostConfigured(hostId) else {
                QuickActionManager.shared.showDeletedHostFeedback(hostId: hostId)
                return
            }
            _ = QuickActionManager.shared.enqueueRequest(
                for: hostId,
                origin: .notification,
                intendedSessionId: intendedSessionId
            )
            QuickActionManager.shared.openHostInWindow(hostId: hostId)
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let options = presentationOptions(
            for: notification.request.content.userInfo,
            targetContentIdentifier: notification.request.content.targetContentIdentifier
        )
        completionHandler(options)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        handleNotificationResponse(
            userInfo: response.notification.request.content.userInfo,
            targetContentIdentifier: response.notification.request.content.targetContentIdentifier
        )
        completionHandler()
    }
}

@MainActor
public final class FilaireSceneDelegate: UIResponder, UIWindowSceneDelegate {
    public var window: UIWindow?

    public func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let _ = scene as? UIWindowScene else { return }
        let pid = session.persistentIdentifier

        if let shortcutItem = connectionOptions.shortcutItem {
            QuickActionManager.shared.handleConnectingShortcutItem(shortcutItem, for: pid)
        }

        for activity in connectionOptions.userActivities {
            QuickActionManager.shared.handleConnectingUserActivity(activity, for: pid)
        }

        if let notificationResponse = connectionOptions.notificationResponse {
            NotificationDelegate.shared.handleNotificationResponse(
                userInfo: notificationResponse.notification.request.content.userInfo,
                targetContentIdentifier: notificationResponse.notification.request.content.targetContentIdentifier,
                intendedSessionId: pid
            )
        }

        MultiWindowManager.shared.reconcileWithOpenSessions()
    }

    public func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let accepted = QuickActionManager.shared.handleWarmShortcutItem(
            shortcutItem,
            for: windowScene.session.persistentIdentifier
        )
        completionHandler(accepted)
    }

    public func sceneDidDisconnect(_ scene: UIScene) {
        if let windowScene = scene as? UIWindowScene {
            MultiWindowManager.shared.detach(scene: windowScene)
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        #if DEBUG
        if NSClassFromString("XCTestCase") != nil ||
           ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
           ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil {
            return true
        }
        #endif
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
        if !CommandLine.arguments.contains("--demo") {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        }
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: "Default Configuration",
            sessionRole: connectingSceneSession.role
        )
        configuration.delegateClass = FilaireSceneDelegate.self
        return configuration
    }

    func application(
        _ application: UIApplication,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let accepted = QuickActionManager.shared.handleWarmShortcutItem(shortcutItem, for: "")
        completionHandler(accepted)
    }

    func application(
        _ application: UIApplication,
        didDiscardSceneSessions sceneSessions: Set<UISceneSession>
    ) {
        MultiWindowManager.shared.discardSessions(sceneSessions)
    }
}

@MainActor
public struct WindowBootstrapResolver {
    public static func resolveTargetHostId(
        scenePid: String,
        activity: NSUserActivity?,
        restorationActivity: NSUserActivity?,
        sessionUserInfo: [AnyHashable: Any]?,
        hosts: [HostProfile],
        excludingSession: SessionManager? = nil
    ) -> UUID? {
        let primaryActivity = activity ?? restorationActivity
        let requestIdStr = primaryActivity?.userInfo?[QuickActionManager.requestIdUserInfoKey] as? String
        if let reqIdStr = requestIdStr, let reqId = UUID(uuidString: reqIdStr),
           let consumed = QuickActionManager.shared.consumeRequest(id: reqId) {
            if hosts.contains(where: { $0.id == consumed.hostId }) && !QuickActionManager.shared.isHostDeleted(consumed.hostId) {
                return consumed.hostId
            }
        }

        if let consumed = QuickActionManager.shared.consumeRequest(forScenePid: scenePid) {
            if hosts.contains(where: { $0.id == consumed.hostId }) && !QuickActionManager.shared.isHostDeleted(consumed.hostId) {
                return consumed.hostId
            }
        }

        // 2. Resolve valid scene restoration metadata
        if let sceneHostIdString = sessionUserInfo?[QuickActionManager.hostIdUserInfoKey] as? String,
           let sceneHostId = UUID(uuidString: sceneHostIdString),
           hosts.contains(where: { $0.id == sceneHostId }),
           !QuickActionManager.shared.isHostDeleted(sceneHostId) {
            return sceneHostId
        }
        if let actHostId = primaryActivity?.userInfo?[QuickActionManager.hostIdUserInfoKey] as? String,
           let id = UUID(uuidString: actHostId),
           hosts.contains(where: { $0.id == id }),
           !QuickActionManager.shared.isHostDeleted(id) {
            return id
        }
        if let targetId = primaryActivity?.targetContentIdentifier,
           targetId.hasPrefix("io.o-t.filaire.host."),
           let id = UUID(uuidString: targetId.replacingOccurrences(of: "io.o-t.filaire.host.", with: "")),
           hosts.contains(where: { $0.id == id }),
           !QuickActionManager.shared.isHostDeleted(id) {
            return id
        }

        // Fallback for untargeted window:
        // 1. If there is a remembered focus host that is already open in an active window,
        // resolve to that host so performBootstrap can activate the focus window and dismiss the duplicate.
        if let focusHostId = MultiWindowManager.shared.rememberedFocusHostId,
           hosts.contains(where: { $0.id == focusHostId }),
           !QuickActionManager.shared.isHostDeleted(focusHostId),
           MultiWindowManager.shared.isHostOpenAnywhere(focusHostId, excluding: excludingSession) {
            return focusHostId
        }

        // 2. If the remembered focus host is configured for auto-connect (e.g. cold launch after termination),
        // prioritize it over other auto-connect hosts.
        if let focusHostId = MultiWindowManager.shared.rememberedFocusHostId,
           let focusHost = hosts.first(where: { $0.id == focusHostId }),
           focusHost.autoConnect,
           !QuickActionManager.shared.isHostDeleted(focusHostId) {
            return focusHostId
        }

        // 3. Fallback for untargeted window: check auto-connect
        let unclaimedHost = hosts.first { host in
            host.autoConnect && !QuickActionManager.shared.isHostDeleted(host.id) && !MultiWindowManager.shared.isHostOpenAnywhere(host.id, excluding: excludingSession)
        }
        return unclaimedHost?.id
    }
}

public enum WindowBootstrapState: Equatable, Sendable {
    case waitingForScene
    case resolvingIntent
    case ready
    case closing
}

@main
struct FilaireApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            WindowRootView()
        }
        .handlesExternalEvents(matching: Set([QuickActionManager.connectHostActionType, "*"]))
    }
}

struct WindowRootView: View {
    @State private var appState = AppState()
    @Environment(\.scenePhase) private var scenePhase
    @State private var window: UIWindow?
    @State private var bootstrapState: WindowBootstrapState = .waitingForScene
    @State private var bootstrapGeneration: Int = 0

    private var targetIdentifiers: Set<String> {
        guard let id = appState.selectedHostId else {
            return Set([QuickActionManager.connectHostActionType, "*"])
        }
        return Set([QuickActionManager.targetContentIdentifier(for: id)])
    }

    var body: some View {
        MainContentView(appState: appState, window: window)
            .preferredColorScheme(.dark)
            .windowSceneTitle(appState.windowTitle) { win in
                guard self.window !== win else {
                    if let scene = win?.windowScene {
                        MultiWindowManager.shared.register(
                            sessionManager: appState.sessionManager,
                            scene: scene,
                            hostId: appState.selectedHostId
                        )
                    }
                    return
                }
                self.window = win
                appState.sessionManager.onIntentionalDisconnect = { [weak win, weak sm = appState.sessionManager] in
                    if let scene = win?.windowScene {
                        MultiWindowManager.shared.closeSceneIfMultiple(scene)
                    } else if let sm = sm {
                        MultiWindowManager.shared.closeWindowIfMultiple(for: sm)
                    }
                }
                if let scene = win?.windowScene {
                    let record = MultiWindowManager.shared.attach(
                        scene: scene,
                        sessionManager: appState.sessionManager,
                        hostId: appState.selectedHostId
                    )
                    if record.sessionManager !== appState.sessionManager {
                        appState.bindSessionManager(record.sessionManager)
                    }
                    if bootstrapState == .waitingForScene {
                        performBootstrap(for: scene)
                    }
                }
            }
            .onDisappear {
                if let scene = window?.windowScene {
                    MultiWindowManager.shared.detach(scene: scene)
                }
            }
            .task {
                #if DEBUG
                if NSClassFromString("XCTestCase") != nil ||
                   ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
                   ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil {
                    return
                }
                if CommandLine.arguments.contains("--demo") {
                    setupDemoState()
                    return
                }
                #endif
                if let scene = window?.windowScene, bootstrapState == .waitingForScene {
                    performBootstrap(for: scene)
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    if let record = MultiWindowManager.shared.records.values.first(where: { $0.sessionManager === appState.sessionManager }) {
                        record.terminalContext?.handleVisibilityChanged(isVisible: true)
                    } else {
                        appState.sessionManager.restoreMemory()
                    }
                    // Auto-reconnect if the session dropped while this window was inactive
                    let sm = appState.sessionManager
                    if sm.activeHost != nil, !sm.isIntentionalDisconnect, sm.state == .disconnected {
                        sm.reconnect()
                    }
                } else if newPhase == .background {
                    if let record = MultiWindowManager.shared.records.values.first(where: { $0.sessionManager === appState.sessionManager }) {
                        record.terminalContext?.handleVisibilityChanged(isVisible: false)
                    }
                    if TerminalSettings.shared.aggressiveBackgroundTrimmingEnabled {
                        appState.sessionManager.scheduleBackgroundMemoryShed(after: 120)
                    }
                }
                MultiWindowManager.shared.handleScenePhaseChange(
                    scenePhase: newPhase,
                    sessionManager: appState.sessionManager,
                    hosts: appState.hosts
                )
            }
            .onChange(of: appState.hosts) { _, newHosts in
                QuickActionManager.updateQuickActions(for: newHosts)
            }
            .onChange(of: appState.selectedHostId) { _, newHostId in
                MultiWindowManager.shared.updateHostId(newHostId, for: appState.sessionManager)
                if let scene = window?.windowScene {
                    QuickActionManager.shared.tagScene(scene, withHostId: newHostId)
                }
            }
            .onChange(of: appState.sessionManager.state) { _, newState in
                if newState == .connected, let hostId = appState.selectedHostId, let scene = window?.windowScene {
                    QuickActionManager.shared.tagScene(scene, withHostId: hostId)
                    MultiWindowManager.shared.updateHostId(hostId, for: appState.sessionManager)
                }
            }
            .handlesExternalEvents(
                preferring: targetIdentifiers,
                allowing: targetIdentifiers
            )
            .onContinueUserActivity(QuickActionManager.connectHostActionType) { userActivity in
                let hostIdString = (userActivity.userInfo?[QuickActionManager.hostIdUserInfoKey] as? String)
                    ?? userActivity.targetContentIdentifier?.replacingOccurrences(of: "io.o-t.filaire.host.", with: "")
                if let idStr = hostIdString, let hostId = UUID(uuidString: idStr), appState.hosts.contains(where: { $0.id == hostId }) {
                    if let existingScene = MultiWindowManager.shared.findScene(for: hostId),
                       let myScene = window?.windowScene,
                       existingScene !== myScene {
                        QuickActionManager.shared.activateScene(existingScene, hostId: hostId)
                        return
                    }
                    if appState.selectedHostId != hostId || appState.sessionManager.state == .disconnected {
                        appState.connect(toHostId: hostId)
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .connectHostRequested)) { notification in
                if let targetPid = notification.userInfo?["targetSessionPersistentIdentifier"] as? String {
                    guard let myPid = window?.windowScene?.session.persistentIdentifier, myPid == targetPid else { return }
                } else if let targetScene = notification.object as? UIWindowScene {
                    guard let myScene = window?.windowScene, targetScene === myScene else { return }
                } else if UIApplication.shared.supportsMultipleScenes {
                    // Eliminate nil-target broadcasts that multiple foreground scenes can consume
                    return
                }
                if let hostId = notification.userInfo?[QuickActionManager.hostIdUserInfoKey] as? UUID {
                    if appState.hosts.contains(where: { $0.id == hostId }) {
                        appState.connect(toHostId: hostId)
                    }
                }
            }
    }

    private func performBootstrap(for scene: UIWindowScene) {
        #if DEBUG
        if NSClassFromString("XCTestCase") != nil ||
           ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
           ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil {
            bootstrapState = .ready
            return
        }
        if CommandLine.arguments.contains("--demo") {
            setupDemoState()
            bootstrapState = .ready
            return
        }
        #endif

        bootstrapGeneration += 1
        let currentGen = bootstrapGeneration
        bootstrapState = .resolvingIntent

        let pid = scene.session.persistentIdentifier
        let targetHostId = WindowBootstrapResolver.resolveTargetHostId(
            scenePid: pid,
            activity: scene.userActivity,
            restorationActivity: scene.session.stateRestorationActivity,
            sessionUserInfo: scene.session.userInfo,
            hosts: appState.hosts,
            excludingSession: appState.sessionManager
        )

        guard currentGen == bootstrapGeneration else { return }

        if let hostId = targetHostId, let host = appState.hosts.first(where: { $0.id == hostId }) {
            let claim = MultiWindowManager.shared.claimHost(
                hostId,
                for: appState.sessionManager,
                scene: scene
            )
            switch claim {
            case .claimed:
                appState.connect(to: host)
                QuickActionManager.shared.tagScene(scene, withHostId: hostId)
                bootstrapState = .ready
            case .alreadyClaimed(let existingScene):
                let activeOtherScene = existingScene ?? MultiWindowManager.shared.findScene(for: hostId)
                if let existing = activeOtherScene, existing !== scene, existing.activationState != .unattached {
                    QuickActionManager.shared.activateScene(existing, hostId: hostId)
                    if MultiWindowManager.shared.hasMultipleOpenWindows {
                        bootstrapState = .closing
                        MultiWindowManager.shared.closeSceneIfMultiple(scene)
                        return
                    }
                }
                // No other active attached scene holds the host; this window connects to host
                appState.connect(to: host)
                QuickActionManager.shared.tagScene(scene, withHostId: hostId)
                bootstrapState = .ready
            }
        } else {
            // Untargeted system-created window with no auto-connect:
            // R3 Instruction 8: "On an untargeted system-created window, show a host picker when auto-connect does not resolve a host. Retain the user's new window long enough to select or configure a host."
            QuickActionManager.shared.tagScene(scene, withHostId: nil)
            bootstrapState = .ready
        }

        MultiWindowManager.shared.deduplicateWindows()
    }
}

private struct PreviewOverlayModifier: ViewModifier {
    @ObservedObject var previewManager: FilePreviewManager

    func body(content: Content) -> some View {
        content
            .quickLookPreview($previewManager.previewURL)
            .alert("Quick Look Error", isPresented: $previewManager.showErrorAlert) {
                Button("Copy Error") {
                    if let msg = previewManager.errorMessage {
                        UIPasteboard.general.string = msg
                    }
                }
                Button("OK", role: .cancel) {}
            } message: {
                if let msg = previewManager.errorMessage {
                    Text(msg)
                }
            }
    }
}

struct MainContentView: View {
    @Bindable var appState: AppState
    var window: UIWindow? = nil
    @State private var showingHostManagement = false
    #if DEBUG
    @State private var showingHostEditor = false
    @State private var showingKeyManagementDemo = false
    #endif

    private var isCoveredByPresentation: Bool {
        if showingHostManagement { return true }
        if appState.sessionManager.pendingSecurityPrompt != nil { return true }
        if appState.sessionManager.filePreviewManager.previewURL != nil { return true }
        if MultiWindowManager.shared.terminalContext(for: appState.sessionManager).interaction.isComposerPresented { return true }
        #if DEBUG
        if showingHostEditor || showingKeyManagementDemo { return true }
        #endif
        return false
    }

    public static func handleOpenNewWindow(appState: AppState) {
        let unopenedHost = appState.hosts.first {
            $0.id != appState.selectedHostId && !MultiWindowManager.shared.isHostOpenAnywhere($0.id, excluding: appState.sessionManager)
        }
        if let hostId = unopenedHost?.id {
            QuickActionManager.shared.openHostInNewWindow(hostId: hostId)
        } else {
            if appState.hosts.count <= 1 {
                appState.sessionManager.showToast(
                    title: "New Window",
                    message: "Add another host in Settings to open multiple windows."
                )
            } else {
                appState.sessionManager.showToast(
                    title: "New Window",
                    message: "All configured hosts are already open in dedicated windows."
                )
            }
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let topInset = max(geometry.safeAreaInsets.top, UIDevice.current.userInterfaceIdiom == .phone ? 54 : 24)

            ZStack(alignment: .top) {
                // Background matching active terminal theme
                Color(uiColor: ThemeManager.shared.currentTheme.background)
                    .ignoresSafeArea()

                if appState.hosts.isEmpty {
                    // Empty state: prompt user to configure first host
                    emptyStateView
                } else {
                    // Low-latency Native Terminal: starts below iPad status bar
                    TerminalContainerView(
                        sessionManager: appState.sessionManager,
                        isStatusExpanded: appState.isStatusExpanded,
                        isCoveredByPresentation: isCoveredByPresentation,
                        onUserInput: {
                            if appState.isStatusExpanded {
                                withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                                    appState.isStatusExpanded = false
                                }
                            }
                        }
                    )
                    .padding(.top, topInset + (UIDevice.current.userInterfaceIdiom == .phone ? 40 : 0))
                    // .container only: the terminal still extends under the home indicator, but the
                    // keyboard region is respected so the software keyboard never covers output.
                    .ignoresSafeArea(.container, edges: .bottom)

                    // Tap outside expanded status bar dismisses it immediately
                    if appState.isStatusExpanded {
                        Color.black.opacity(0.02)
                            .contentShape(Rectangle())
                            .padding(.top, topInset + 44)
                            .onTapGesture {
                                withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                                    appState.isStatusExpanded = false
                                }
                            }
                            .zIndex(90)
                    }

                    // Top Status Bar: in-line with iPad status bar when minimized,
                    // expands to full overlay when tapped
                    StatusOverlayView(
                        sessionManager: appState.sessionManager,
                        availableKeys: appState.keys,
                        allHosts: appState.hosts,
                        topInset: topInset,
                        isExpanded: $appState.isStatusExpanded,
                        onConnectToHost: { host in
                            appState.connect(to: host, force: true)
                        },
                        onOpenSettings: {
                            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                                appState.isStatusExpanded = false
                            }
                            showingHostManagement = true
                        }
                    )
                    .zIndex(100)
                }

                // In-App Toast Banner for fil notify and window actions (visible across both empty and non-empty states)
                if let toast = appState.sessionManager.activeToast {
                    HStack(spacing: 10) {
                        Image(systemName: toast.title.contains("Window") ? "macwindow.badge.plus" : "bell.badge.fill")
                            .foregroundStyle(Color(uiColor: SolarizedDarkTheme.yellow))
                            .font(.system(size: 15))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(toast.title)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(Color(uiColor: SolarizedDarkTheme.base1))
                            if !toast.message.isEmpty {
                                Text(toast.message)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color(uiColor: SolarizedDarkTheme.base0))
                            }
                        }

                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        Capsule()
                            .fill(Color(uiColor: SolarizedDarkTheme.base02).opacity(0.95))
                            .overlay(
                                Capsule()
                                    .stroke(Color(uiColor: SolarizedDarkTheme.base01).opacity(0.4), lineWidth: 0.5)
                            )
                            .shadow(color: Color.black.opacity(0.35), radius: 8, x: 0, y: 3)
                    )
                    .padding(.horizontal, 20)
                    .padding(.top, topInset + 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(100)
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            appState.sessionManager.activeToast = nil
                        }
                    }
                }
            }
        }
        // .container so the root still fills the display but yields to the keyboard; the background Color
        // keeps its own blanket ignoresSafeArea, so nothing stops covering the screen edge to edge.
        .ignoresSafeArea(.container)
        .sheet(isPresented: $showingHostManagement) {
            HostListView(
                hosts: $appState.hosts,
                selectedHostId: $appState.selectedHostId,
                availableKeys: $appState.keys,
                currentWindowScene: window?.windowScene,
                sessionManager: appState.sessionManager,
                onDisconnect: {
                    showingHostManagement = false
                    appState.sessionManager.disconnect()
                    if let scene = window?.windowScene {
                        MultiWindowManager.shared.closeSceneIfMultiple(scene)
                    } else {
                        MultiWindowManager.shared.closeWindowIfMultiple(for: appState.sessionManager)
                    }
                },
                onDeleteHosts: { ids in
                    appState.deleteHosts(ids: ids)
                }
            ) { host in
                showingHostManagement = false
                appState.scheduleDelayedConnect(to: host, delay: 0.3)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSettingsRequested)) { notification in
            if let targetWindow = notification.object as? UIWindow {
                if targetWindow === window {
                    showingHostManagement = true
                }
            } else {
                showingHostManagement = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openNewWindowRequested)) { notification in
            if let targetWindow = notification.object as? UIWindow {
                guard targetWindow === window else { return }
            } else {
                if UIApplication.shared.supportsMultipleScenes {
                    guard window?.windowScene?.activationState == .foregroundActive else { return }
                }
            }
            MainContentView.handleOpenNewWindow(appState: appState)
        }
        .onReceive(NotificationCenter.default.publisher(for: .closeCurrentWindowRequested)) { notification in
            if let targetWindow = notification.object as? UIWindow {
                guard targetWindow === window else { return }
            } else {
                if UIApplication.shared.supportsMultipleScenes {
                    guard window?.windowScene?.activationState == .foregroundActive else { return }
                }
            }
            if MultiWindowManager.shared.hasMultipleOpenWindows {
                appState.sessionManager.disconnect()
                if let scene = window?.windowScene {
                    MultiWindowManager.shared.closeSceneIfMultiple(scene)
                } else {
                    MultiWindowManager.shared.closeWindowIfMultiple(for: appState.sessionManager)
                }
            } else {
                appState.sessionManager.showToast(
                    title: "Close Window",
                    message: "Cannot close the only open window."
                )
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .connectHostRequested)) { notification in
            if let targetPid = notification.userInfo?["targetSessionPersistentIdentifier"] as? String {
                guard let myPid = window?.windowScene?.session.persistentIdentifier, myPid == targetPid else { return }
            } else if let targetScene = notification.object as? UIWindowScene {
                guard let myScene = window?.windowScene, targetScene === myScene else { return }
            } else if UIApplication.shared.supportsMultipleScenes {
                return
            }
            showingHostManagement = false
            appState.isStatusExpanded = false
        }
        .modifier(PreviewOverlayModifier(previewManager: appState.sessionManager.filePreviewManager))
        #if DEBUG
        .sheet(isPresented: $showingHostEditor) {
            if let firstHost = appState.hosts.first {
                HostEditorView(
                    host: Binding(
                        get: { firstHost },
                        set: { _ in }
                    ),
                    availableKeys: $appState.keys,
                    availableHosts: appState.hosts
                ) { _ in }
            }
        }
        .sheet(isPresented: $showingKeyManagementDemo) {
            NavigationStack {
                KeyManagementView(keys: $appState.keys)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showingKeyManagementDemo = false }
                        }
                    }
            }
        }
        .onAppear {
            if CommandLine.arguments.contains("--demo") {
                let screen = CommandLine.arguments.first(where: { $0.hasPrefix("--demo-screen=") })?
                    .replacingOccurrences(of: "--demo-screen=", with: "") ?? "terminal"
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    if screen == "hosts" {
                        showingHostManagement = true
                    } else if screen == "editor" {
                        showingHostEditor = true
                    } else if screen == "keys" {
                        showingKeyManagementDemo = true
                    }
                }
            }
        }
        #endif
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "terminal.fill")
                .font(.system(size: 64))
                .foregroundStyle(Color(uiColor: SolarizedDarkTheme.cyan))

            Text("Welcome to Filaire")
                .font(.title2.bold())
                .foregroundStyle(Color(uiColor: SolarizedDarkTheme.base1))

            Text("A native SSH terminal client built for tmux workflows.")
                .font(.subheadline)
                .foregroundStyle(Color(uiColor: SolarizedDarkTheme.base0))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button(action: { showingHostManagement = true }) {
                Label("Configure Remote Host", systemImage: "plus.circle.fill")
                    .font(.headline)
                    .foregroundStyle(Color(uiColor: SolarizedDarkTheme.base03))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color(uiColor: SolarizedDarkTheme.cyan))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .padding(.top, 12)

            Spacer()
        }
    }
}

#if DEBUG
extension WindowRootView {
    func setupDemoState() {
        let sampleProdId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let sampleJumpId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let sampleDevId  = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let sampleDbId   = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!

        let sampleKeyId = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        let sampleRsaId = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!

        let prodHost = HostProfile(
            id: sampleProdId,
            name: "Production API",
            hostname: "api.filaire.internal",
            port: 22,
            username: "deploy",
            authMethod: .sshKey,
            selectedKeyId: sampleKeyId,
            customTmuxSession: "k8s-prod",
            autoConnect: true,
            autoConnectTmux: true,
            tmuxPrefix: "ctrl-b",
            requireBiometrics: true,
            jumpHostId: sampleJumpId,
            portForwards: [
                PortForwardRule(name: "8080 → 127.0.0.1:8080", localPort: 8080, remoteHost: "127.0.0.1", remotePort: 8080, isEnabled: true, ruleType: .local)
            ]
        )

        let stgHost = HostProfile(
            id: sampleJumpId,
            name: "Staging Bastion",
            hostname: "bastion.filaire.internal",
            port: 2222,
            username: "ops",
            authMethod: .sshKey,
            selectedKeyId: sampleKeyId,
            requireBiometrics: true
        )

        let devHost = HostProfile(
            id: sampleDevId,
            name: "Dev Workstation",
            hostname: "devbox.local",
            port: 22,
            username: "dev",
            authMethod: .sshKey,
            selectedKeyId: sampleKeyId,
            customTmuxSession: "workspace",
            autoConnectTmux: true,
            portForwards: [
                PortForwardRule(name: "3000 → localhost:3000", localPort: 3000, remoteHost: "localhost", remotePort: 3000, isEnabled: true, ruleType: .local)
            ]
        )

        let dbHost = HostProfile(
            id: sampleDbId,
            name: "Database Primary",
            hostname: "postgres.internal",
            port: 5432,
            username: "postgres",
            authMethod: .sshKey,
            selectedKeyId: sampleRsaId,
            portForwards: [
                PortForwardRule(name: "1080 (SOCKS5 Proxy)", localPort: 1080, remoteHost: "localhost", remotePort: 0, isEnabled: true, ruleType: .dynamic)
            ]
        )

        let key1 = SSHKeyModel(
            id: sampleKeyId,
            name: "Secure Enclave (Ed25519)",
            keyType: "Ed25519",
            publicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGX8vKqX82jNmHQE3v9y0kfilaire filaire@ipad",
            requiresBiometrics: true
        )
        let key2 = SSHKeyModel(
            id: sampleRsaId,
            name: "Production Bastion (RSA)",
            keyType: "RSA 4096",
            publicKey: "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDQ9wEf8k2... filaire@ipad",
            requiresBiometrics: false
        )

        appState.hosts = [prodHost, stgHost, devHost, dbHost]
        appState.keys = [key1, key2]
        appState.selectedHostId = prodHost.id
        appState.sessionManager.activeHost = prodHost
        appState.sessionManager.state = .connected

        let screen = CommandLine.arguments.first(where: { $0.hasPrefix("--demo-screen=") })?
            .replacingOccurrences(of: "--demo-screen=", with: "") ?? "terminal"

        if screen == "status" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                    appState.isStatusExpanded = true
                }
            }
        }
    }
}
#endif
