import SwiftUI

public struct StatusOverlayView: View {
    public let sessionManager: SessionManager
    public var availableKeys: [SSHKeyModel]
    public var allHosts: [HostProfile]
    public var topInset: CGFloat
    @Binding public var isExpanded: Bool
    public let onConnectToHost: ((HostProfile) -> Void)?
    public let onOpenSettings: () -> Void
    @ObservedObject public var windowManager: MultiWindowManager

    @State private var showingDiagnosticSheet: Bool = false
    @State private var showingControlHelp: Bool = false
    @State private var copiedFeedback: String? = nil
    @State private var inactivityTimerTask: Task<Void, Never>? = nil

    private var dynamicSpringAnimation: Animation {
        .spring(response: 0.38, dampingFraction: 0.82)
    }

    public init(
        sessionManager: SessionManager,
        availableKeys: [SSHKeyModel] = [],
        allHosts: [HostProfile] = [],
        topInset: CGFloat = 24,
        isExpanded: Binding<Bool>,
        windowManager: MultiWindowManager = .shared,
        onConnectToHost: ((HostProfile) -> Void)? = nil,
        onOpenSettings: @escaping () -> Void
    ) {
        self.sessionManager = sessionManager
        self.availableKeys = availableKeys
        self.allHosts = allHosts
        self.topInset = topInset
        self._isExpanded = isExpanded
        self.windowManager = windowManager
        self.onConnectToHost = onConnectToHost
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        Group {
            if isExpanded {
                expandedStatusView
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else {
                minimizedStatusView
                    .transition(.opacity)
            }
        }
        .sheet(isPresented: $showingDiagnosticSheet) {
            diagnosticSheet
        }
        .sheet(isPresented: Binding(
            get: { showingControlHelp },
            set: { isPresented in
                showingControlHelp = isPresented
                // Hold the bar open behind the sheet, and start the timer again once it closes.
                presentControlHelp(isPresented)
            }
        )) {
            ControlHelpView()
        }
        .onChange(of: isExpanded) { _, expanded in
            if expanded {
                resetInactivityTimer()
            } else {
                cancelInactivityTimer()
            }
        }
        .onChange(of: showingDiagnosticSheet) { _, isShowing in
            if !isShowing && isExpanded {
                resetInactivityTimer()
            } else if isShowing {
                cancelInactivityTimer()
            }
        }
        .onChange(of: sessionManager.state) { oldState, newState in
            if newState.isFailed && newState != oldState {
                expand()
            }
        }
        .onDisappear {
            cancelInactivityTimer()
        }
    }

    private var statusBarHeight: CGFloat {
        max(24, topInset)
    }

    // MARK: - Minimized Status Bar (In-line with iPad Status Bar, Centered)

    private var minimizedStatusView: some View {
        let hostName = sessionManager.activeHost?.displayName ?? sessionManager.activeHost?.hostname ?? "No Host"
        let userName = sessionManager.activeHost?.username ?? ""
        let height = statusBarHeight

        return VStack(spacing: 0) {
            if UIDevice.current.userInterfaceIdiom == .phone {
                Spacer().frame(height: statusBarHeight)
            }
            // Minimized pill in-line with iPad Status Bar (height = statusBarHeight)
            HStack(spacing: 0) {
                // Left margin tap area to expand
                Button {
                    expand()
                } label: {
                    Color(uiColor: SolarizedDarkTheme.base03).opacity(0.02)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // Minimized pill
                HStack(spacing: 6) {
                    // Tapping status info or hostname expands status bar
                    Button {
                        expand()
                    } label: {
                        HStack(spacing: 6) {
                            statusIndicator

                            Text(hostName)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color(uiColor: SolarizedDarkTheme.base1))
                                .lineLimit(1)
                                .fixedSize()

                            if !userName.isEmpty && UIDevice.current.userInterfaceIdiom != .phone {
                                Text(userName)
                                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                                    .foregroundStyle(Color(uiColor: SolarizedDarkTheme.base00))
                                    .lineLimit(1)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    // Direct settings button in pill
                    Button {
                        onOpenSettings()
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color(uiColor: SolarizedDarkTheme.base0))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Settings")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(Color(uiColor: SolarizedDarkTheme.base02).opacity(0.9))
                )

                // Right margin tap area to expand
                Button {
                    expand()
                } label: {
                    Color(uiColor: SolarizedDarkTheme.base03).opacity(0.02)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .frame(height: UIDevice.current.userInterfaceIdiom == .phone ? 36 : height)

            // Finger-width tap/click expansion bar across the top below the top bar (44pt standard)
            Button {
                expand()
            } label: {
                ZStack {
                    // Hit-testable backdrop (alpha >= 0.15 so UIKit hitTest never skips it)
                    Rectangle()
                        .fill(Color(uiColor: SolarizedDarkTheme.base03).opacity(0.15))

                    // Subtle visual grab handle indicating the interactive pull-down bar
                    Capsule()
                        .fill(Color(uiColor: SolarizedDarkTheme.base01).opacity(0.55))
                        .frame(width: 36, height: 4)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Tap to expand status bar")
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Expanded Status Bar

    private var expandedStatusView: some View {
        VStack(spacing: 0) {
            HStack(spacing: UIDevice.current.userInterfaceIdiom == .phone ? 6 : 12) {
                // Status Indicator Icon
                statusIndicator

                // Status Message & Host Details
                statusText

                Spacer()

                // Quick Disconnect Button if currently connected
                if sessionManager.state == .connected {
                    Button(action: {
                        cancelInactivityTimer()
                        sessionManager.disconnect()
                        collapse()
                        MultiWindowManager.shared.closeWindowIfMultiple(for: sessionManager)
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "power")
                                .font(.system(size: 11, weight: .semibold))
                            if UIDevice.current.userInterfaceIdiom != .phone {
                                Text("Disconnect")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                        }
                        .padding(.horizontal, UIDevice.current.userInterfaceIdiom == .phone ? 8 : 10)
                        .padding(.vertical, 5)
                        .background(Color(uiColor: SolarizedDarkTheme.red.withAlphaComponent(0.2)))
                        .foregroundStyle(Color(uiColor: SolarizedDarkTheme.red))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Disconnect from host")
                }

                // Quick Reconnect Button if failed/disconnected
                if sessionManager.state != .connected && !sessionManager.state.isBusy {
                    Button(action: {
                        resetInactivityTimer()
                        sessionManager.reconnect()
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11, weight: .semibold))
                            if UIDevice.current.userInterfaceIdiom != .phone {
                                Text("Reconnect")
                                    .font(.system(size: 12, weight: .medium))
                            }
                        }
                        .padding(.horizontal, UIDevice.current.userInterfaceIdiom == .phone ? 8 : 10)
                        .padding(.vertical, 5)
                        .background(Color(uiColor: SolarizedDarkTheme.cyan.withAlphaComponent(0.2)))
                        .foregroundStyle(Color(uiColor: SolarizedDarkTheme.cyan))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }

                // Switch Host Menu
                if !allHosts.isEmpty {
                    Menu {
                        Section("Switch Host") {
                            ForEach(allHosts) { host in
                                Button {
                                    cancelInactivityTimer()
                                    collapse()
                                    let myScene = MultiWindowManager.shared.findScene(for: sessionManager)
                                    let otherScene = MultiWindowManager.shared.findScene(for: host.id) ?? QuickActionManager.findScene(for: host.id)
                                    if let existingScene = otherScene, existingScene !== myScene, MultiWindowManager.shared.isHostConnected(host.id) {
                                        QuickActionManager.shared.activateScene(existingScene, hostId: host.id)
                                    } else {
                                        onConnectToHost?(host)
                                    }
                                } label: {
                                    if host.id == sessionManager.activeHost?.id {
                                        Label(host.displayName, systemImage: "checkmark")
                                    } else if windowManager.isHostOpenAnywhere(host.id, excluding: sessionManager) {
                                        Label(host.displayName, systemImage: "macwindow")
                                    } else {
                                        Text(host.displayName)
                                    }
                                }
                            }
                        }

                        let unopenedHosts = allHosts.filter {
                            $0.id != sessionManager.activeHost?.id && !windowManager.isHostOpenAnywhere($0.id, excluding: sessionManager)
                        }
                        if UIApplication.shared.supportsMultipleScenes && !unopenedHosts.isEmpty {
                            Section("Open in New Window") {
                                ForEach(unopenedHosts) { host in
                                    Button {
                                        cancelInactivityTimer()
                                        collapse()
                                        QuickActionManager.shared.openHostInNewWindow(hostId: host.id)
                                    } label: {
                                        Label(host.displayName, systemImage: "macwindow.badge.plus")
                                    }
                                }
                            }
                        }

                        Divider()

                        Button {
                            cancelInactivityTimer()
                            onOpenSettings()
                        } label: {
                            Label("Manage Hosts...", systemImage: "gearshape")
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.triangle.swap")
                                .font(.system(size: 12, weight: .semibold))
                            if UIDevice.current.userInterfaceIdiom != .phone {
                                Text("Switch Host")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                        }
                        .padding(.horizontal, UIDevice.current.userInterfaceIdiom == .phone ? 8 : 10)
                        .padding(.vertical, 5)
                        .background(Color(uiColor: SolarizedDarkTheme.base03))
                        .foregroundStyle(Color(uiColor: SolarizedDarkTheme.cyan))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Switch Host")
                }

                // Settings / Host Picker Button
                Button(action: {
                    cancelInactivityTimer()
                    onOpenSettings()
                }) {
                    HStack(spacing: 5) {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 12, weight: .semibold))
                        if UIDevice.current.userInterfaceIdiom != .phone {
                            Text("Settings")
                                .font(.system(size: 12, weight: .semibold))
                        }
                    }
                    .padding(.horizontal, UIDevice.current.userInterfaceIdiom == .phone ? 8 : 10)
                    .padding(.vertical, 5)
                    .background(Color(uiColor: SolarizedDarkTheme.base03))
                    .foregroundStyle(Color(uiColor: SolarizedDarkTheme.base1))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")

                // Dedicated Collapse Button
                Button {
                    collapse()
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(uiColor: SolarizedDarkTheme.base0))
                        .padding(6)
                        .background(Color(uiColor: SolarizedDarkTheme.base03))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Collapse status bar")
            }
            .padding(.horizontal, UIDevice.current.userInterfaceIdiom == .phone ? 10 : 16)
            .frame(minHeight: 44)
            .padding(.top, statusBarHeight)

            if sessionManager.state == .connected {
                terminalControlBar
                    .simultaneousGesture(keepOpenWhileDragging)
            }
        }
        .background(
            Color(uiColor: SolarizedDarkTheme.base02)
                .opacity(0.96)
        )
        .overlay(
            Rectangle()
                .frame(height: 0.5)
                .foregroundStyle(Color(uiColor: SolarizedDarkTheme.base01).opacity(0.3)),
            alignment: .bottom
        )
        .shadow(color: Color.black.opacity(0.35), radius: 6, x: 0, y: 3)
        .onHover { _ in
            resetInactivityTimer()
        }
    }

    /// Holds the bar open while a finger is down. Scrolling the bar is not a tap, so the inactivity timer
    /// used to expire mid-drag while the user was still hunting for a control.
    private var keepOpenWhileDragging: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in cancelInactivityTimer() }
            .onEnded { _ in resetInactivityTimer() }
    }

    private var composingTools: some View {
        HStack(spacing: 5) {
            Button(action: {
                resetInactivityTimer()
                triggerHapticFeedback()
                MultiWindowManager.shared.terminalContext(for: sessionManager).openSnippetLibrary()
            }) {
                Image(systemName: "text.badge.plus")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: controlButtonSize, height: controlButtonSize)
                    .background(Color(uiColor: SolarizedDarkTheme.base03))
                    .foregroundStyle(Color(uiColor: SolarizedDarkTheme.base0))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .accessibilityLabel("Snippets")

            Button(action: {
                resetInactivityTimer()
                triggerHapticFeedback()
                MultiWindowManager.shared.terminalContext(for: sessionManager).openComposer(origin: .statusActions)
            }) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: controlButtonSize, height: controlButtonSize)
                    .background(Color(uiColor: SolarizedDarkTheme.base03))
                    .foregroundStyle(Color(uiColor: SolarizedDarkTheme.base0))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .accessibilityLabel("Compose command")
        }
    }

    @ViewBuilder
    private var tmuxControls: some View {
        Divider()
            .frame(height: 16)
            .background(Color(uiColor: SolarizedDarkTheme.base01).opacity(0.4))

        HStack(spacing: 4) {
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: 11, weight: .bold))
            Text("tmux")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(Color(uiColor: SolarizedDarkTheme.violet).opacity(0.2))
        .foregroundStyle(Color(uiColor: SolarizedDarkTheme.violet))
        .clipShape(Capsule())

        Divider()
            .frame(height: 16)
            .background(Color(uiColor: SolarizedDarkTheme.base01).opacity(0.4))

        // Panes: Zoom, Split V, Split H, Join V, Join H, Mark, Next, Last, Break, Close
        HStack(spacing: 5) {
            Group {
                Button(action: {
                    resetInactivityTimer()
                    triggerHapticFeedback()
                    sessionManager.triggerTmuxZoomPane()
                }) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: controlButtonSize, height: controlButtonSize)
                        .background(Color(uiColor: SolarizedDarkTheme.base03))
                        .foregroundStyle(Color(uiColor: SolarizedDarkTheme.yellow))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityLabel("Toggle pane zoom")

                Button(action: {
                    resetInactivityTimer()
                    triggerHapticFeedback()
                    sessionManager.triggerTmuxSplitVertical()
                }) {
                    Image(systemName: "rectangle.split.2x1")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: controlButtonSize, height: controlButtonSize)
                        .background(Color(uiColor: SolarizedDarkTheme.base03))
                        .foregroundStyle(Color(uiColor: SolarizedDarkTheme.base0))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityLabel("Split pane vertically")

                Button(action: {
                    resetInactivityTimer()
                    triggerHapticFeedback()
                    sessionManager.triggerTmuxSplitHorizontal()
                }) {
                    Image(systemName: "rectangle.split.1x2")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: controlButtonSize, height: controlButtonSize)
                        .background(Color(uiColor: SolarizedDarkTheme.base03))
                        .foregroundStyle(Color(uiColor: SolarizedDarkTheme.base0))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityLabel("Split pane horizontally")

                Button(action: {
                    resetInactivityTimer()
                    triggerHapticFeedback()
                    sessionManager.triggerTmuxJoinVertical()
                }) {
                    Image(systemName: "arrow.right.and.line.vertical.and.arrow.left")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: controlButtonSize, height: controlButtonSize)
                        .background(Color(uiColor: SolarizedDarkTheme.base03))
                        .foregroundStyle(Color(uiColor: SolarizedDarkTheme.orange))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityLabel("Join pane vertically")

                Button(action: {
                    resetInactivityTimer()
                    triggerHapticFeedback()
                    sessionManager.triggerTmuxJoinHorizontal()
                }) {
                    Image(systemName: "arrow.down.and.line.horizontal.and.arrow.up")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: controlButtonSize, height: controlButtonSize)
                        .background(Color(uiColor: SolarizedDarkTheme.base03))
                        .foregroundStyle(Color(uiColor: SolarizedDarkTheme.orange))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityLabel("Join pane horizontally")
            }

            Group {
                Button(action: {
                    resetInactivityTimer()
                    triggerHapticFeedback()
                    sessionManager.triggerTmuxMarkPane()
                }) {
                    Image(systemName: "pin")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: controlButtonSize, height: controlButtonSize)
                        .background(Color(uiColor: SolarizedDarkTheme.base03))
                        .foregroundStyle(Color(uiColor: SolarizedDarkTheme.orange))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityLabel("Mark tmux pane")

                Button(action: {
                    resetInactivityTimer()
                    triggerHapticFeedback()
                    sessionManager.triggerTmuxNextPane()
                }) {
                    Image(systemName: "arrow.2.squarepath")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: controlButtonSize, height: controlButtonSize)
                        .background(Color(uiColor: SolarizedDarkTheme.base03))
                        .foregroundStyle(Color(uiColor: SolarizedDarkTheme.cyan))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityLabel("Next tmux pane")

                Button(action: {
                    resetInactivityTimer()
                    triggerHapticFeedback()
                    sessionManager.triggerTmuxLastPane()
                }) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: controlButtonSize, height: controlButtonSize)
                        .background(Color(uiColor: SolarizedDarkTheme.base03))
                        .foregroundStyle(Color(uiColor: SolarizedDarkTheme.cyan))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityLabel("Toggle last tmux pane")

                Button(action: {
                    resetInactivityTimer()
                    triggerHapticFeedback()
                    sessionManager.triggerTmuxBreakPane()
                }) {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: controlButtonSize, height: controlButtonSize)
                        .background(Color(uiColor: SolarizedDarkTheme.base03))
                        .foregroundStyle(Color(uiColor: SolarizedDarkTheme.violet))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityLabel("Break pane into a new window")

                Button(action: {
                    resetInactivityTimer()
                    triggerHapticFeedback()
                    sessionManager.triggerTmuxClosePane()
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: controlButtonSize, height: controlButtonSize)
                        .background(Color(uiColor: SolarizedDarkTheme.base03))
                        .foregroundStyle(Color(uiColor: SolarizedDarkTheme.red))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityLabel("Close tmux pane")
            }
        }

        Divider()
            .frame(height: 16)
            .background(Color(uiColor: SolarizedDarkTheme.base01).opacity(0.4))

        // Window numbers 0..9
        HStack(spacing: 5) {
            ForEach(0...9, id: \.self) { num in
                Button(action: {
                    resetInactivityTimer()
                    triggerHapticFeedback()
                    sessionManager.triggerTmuxWindowNumber(num)
                }) {
                    Text("\(num)")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .frame(width: controlButtonSize, height: controlButtonSize)
                        .background(Color(uiColor: SolarizedDarkTheme.base03))
                        .foregroundStyle(Color(uiColor: SolarizedDarkTheme.base1))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityLabel("Switch to tmux window \(num)")
            }
        }

        Divider()
            .frame(height: 16)
            .background(Color(uiColor: SolarizedDarkTheme.base01).opacity(0.4))

        // Navigation: Prev / Next / New / Rename
        HStack(spacing: 5) {
            Button(action: {
                resetInactivityTimer()
                triggerHapticFeedback()
                sessionManager.triggerTmuxPrevWindow()
            }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: controlButtonSize, height: controlButtonSize)
                    .background(Color(uiColor: SolarizedDarkTheme.base03))
                    .foregroundStyle(Color(uiColor: SolarizedDarkTheme.base0))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .accessibilityLabel("Previous tmux window")

            Button(action: {
                resetInactivityTimer()
                triggerHapticFeedback()
                sessionManager.triggerTmuxNextWindow()
            }) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: controlButtonSize, height: controlButtonSize)
                    .background(Color(uiColor: SolarizedDarkTheme.base03))
                    .foregroundStyle(Color(uiColor: SolarizedDarkTheme.base0))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .accessibilityLabel("Next tmux window")

            Button(action: {
                resetInactivityTimer()
                triggerHapticFeedback()
                sessionManager.triggerTmuxNewWindow()
            }) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: controlButtonSize, height: controlButtonSize)
                    .background(Color(uiColor: SolarizedDarkTheme.base03))
                    .foregroundStyle(Color(uiColor: SolarizedDarkTheme.green))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .accessibilityLabel("New tmux window")

            Button(action: {
                resetInactivityTimer()
                triggerHapticFeedback()
                sessionManager.triggerTmuxRenameWindow()
            }) {
                Image(systemName: "pencil.line")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: controlButtonSize, height: controlButtonSize)
                    .background(Color(uiColor: SolarizedDarkTheme.base03))
                    .foregroundStyle(Color(uiColor: SolarizedDarkTheme.cyan))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .accessibilityLabel("Rename tmux window")
        }
    }

    private var terminalControlBar: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    composingTools

                    if sessionManager.activeHost?.autoConnectTmux ?? false {
                        tmuxControls
                    }

                    if UIDevice.current.userInterfaceIdiom != .pad {
                        Group {
                            Divider()
                                .frame(height: 16)
                                .background(Color(uiColor: SolarizedDarkTheme.base01).opacity(0.4))

                            helpButton
                        }
                    }
                }
                .padding(.leading, 16)
                .padding(.trailing, UIDevice.current.userInterfaceIdiom == .pad ? 8 : 16)
                .padding(.vertical, 6)
            }

            if UIDevice.current.userInterfaceIdiom == .pad {
                HStack(spacing: 8) {
                    Divider()
                        .frame(height: 16)
                        .background(Color(uiColor: SolarizedDarkTheme.base01).opacity(0.4))

                    helpButton
                }
                .padding(.trailing, 16)
                .padding(.vertical, 6)
            }
        }
        .background(Color(uiColor: SolarizedDarkTheme.base03).opacity(0.6))
    }

    private var tmuxControlBar: some View {
        terminalControlBar
    }

    private var helpButton: some View {
        Button(action: {
            cancelInactivityTimer()
            triggerHapticFeedback()
            showingControlHelp = true
        }) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 11, weight: .medium))
                .frame(width: controlButtonSize, height: controlButtonSize)
                .background(Color(uiColor: SolarizedDarkTheme.base03))
                .foregroundStyle(Color(uiColor: SolarizedDarkTheme.base0))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel("What these controls do")
    }

    /// 44pt is the smallest comfortable touch target for finger tapping on both iPhone and iPad.
    private var controlButtonSize: CGFloat {
        44
    }

    private func triggerHapticFeedback() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred()
    }

    private func expand() {
        withAnimation(dynamicSpringAnimation) {
            isExpanded = true
        }
        resetInactivityTimer()
    }

    private func collapse() {
        cancelInactivityTimer()
        withAnimation(dynamicSpringAnimation) {
            isExpanded = false
        }
    }

    /// The help sheet keeps the bar open behind it; closing it restarts the timer.
    private func presentControlHelp(_ isPresented: Bool) {
        if isPresented {
            cancelInactivityTimer()
        } else {
            resetInactivityTimer()
        }
    }

    private func resetInactivityTimer() {
        inactivityTimerTask?.cancel()
        inactivityTimerTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            guard !showingDiagnosticSheet else { return }
            collapse()
        }
    }

    private func cancelInactivityTimer() {
        inactivityTimerTask?.cancel()
        inactivityTimerTask = nil
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch sessionManager.state {
        case .connected:
            Circle()
                .fill(Color(uiColor: SolarizedDarkTheme.green))
                .frame(width: 8, height: 8)
        case .connecting, .reconnecting:
            ProgressView()
                .scaleEffect(0.65)
                .tint(Color(uiColor: SolarizedDarkTheme.yellow))
                .frame(width: 8, height: 8)
        case .disconnected:
            Circle()
                .fill(Color(uiColor: SolarizedDarkTheme.base01))
                .frame(width: 8, height: 8)
        case .failed:
            Button(action: { showingDiagnosticSheet = true }) {
                Circle()
                    .fill(Color(uiColor: SolarizedDarkTheme.red))
                    .frame(width: 8, height: 8)
            }
            .buttonStyle(.borderless)
        }
    }

    @ViewBuilder
    private var statusText: some View {
        let hostName = sessionManager.activeHost?.displayName ?? "No Host"
        let tmuxSession = sessionManager.activeHost?.effectiveTmuxSession ?? ""

        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(hostName)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color(uiColor: SolarizedDarkTheme.base1))
                    .lineLimit(1)
                    .textSelection(.enabled)

                if (sessionManager.activeHost?.autoConnectTmux ?? false) && !tmuxSession.isEmpty && UIDevice.current.userInterfaceIdiom != .phone {
                    Text("• tmux: \(tmuxSession)")
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundStyle(Color(uiColor: SolarizedDarkTheme.base00))
                        .lineLimit(1)
                        .textSelection(.enabled)
                }
            }

            if sessionManager.state != .connected {
                HStack(spacing: 6) {
                    Text(sessionManager.state.description)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(statusColor)
                        .lineLimit(1)
                        .textSelection(.enabled)

                    // If connection failed, provide instant Copy button and Diagnostic info button
                    if case .failed = sessionManager.state {
                        Button(action: {
                            resetInactivityTimer()
                            let text = sessionManager.lastError ?? sessionManager.state.description
                            copyToClipboard(text, feedback: "Copied Error")
                        }) {
                            HStack(spacing: 3) {
                                Image(systemName: copiedFeedback != nil ? "checkmark" : "doc.on.doc")
                                Text(copiedFeedback ?? "Copy Error")
                            }
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(uiColor: SolarizedDarkTheme.base03))
                            .foregroundStyle(Color(uiColor: SolarizedDarkTheme.cyan))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.borderless)

                        Button(action: {
                            cancelInactivityTimer()
                            showingDiagnosticSheet = true
                        }) {
                            Image(systemName: "info.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(Color(uiColor: SolarizedDarkTheme.yellow))
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var diagnosticSheet: some View {
        NavigationStack {
            List {
                Section(header: Text("Error Details")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(sessionManager.lastError ?? sessionManager.state.description)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(Color(uiColor: SolarizedDarkTheme.red))
                            .textSelection(.enabled)

                        Button(action: {
                            let err = sessionManager.lastError ?? sessionManager.state.description
                            copyToClipboard(err, feedback: "Error Copied")
                        }) {
                            Label(copiedFeedback == "Error Copied" ? "Copied Error to Clipboard" : "Copy Error Message",
                                  systemImage: copiedFeedback == "Error Copied" ? "checkmark" : "doc.on.doc")
                                .font(.subheadline.bold())
                                .foregroundStyle(Color(uiColor: SolarizedDarkTheme.cyan))
                        }
                    }
                    .padding(.vertical, 4)
                }

                if let err = sessionManager.lastError, err.contains("regenerated") {
                    Section(header: Text("⚠️ Key Warning")) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("The configured SSH key could not be retrieved from secure storage or appears invalid.")
                                .font(.caption)
                                .foregroundStyle(Color(uiColor: SolarizedDarkTheme.yellow))
                            Text("This may happen if the key was not transferred during a device migration or was removed from Keychain.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("Recommended Fix:")
                                .font(.caption.bold())
                            Text("Open Settings → SSH Keys to generate or import a new key, and update your host to use it.")
                                .font(.caption)
                        }
                        .padding(.vertical, 4)
                    }
                }

                if let auth = sessionManager.lastAttemptedAuth, auth.rawKeyType == "ssh-rsa" || auth.keyType == "RSA" {
                    Section(header: Text("⚠️ RSA Incompatibility Notice")) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Modern OpenSSH servers (Debian 12+, Ubuntu 22.04+, Arch, macOS) disable 'ssh-rsa' (SHA-1) by default. Citadel signs RSA keys with 'ssh-rsa', so modern servers will reject it even when added to authorized_keys.")
                                .font(.caption)
                                .foregroundStyle(Color(uiColor: SolarizedDarkTheme.yellow))

                            Text("Recommended Fixes:")
                                .font(.caption.bold())
                            Text("1. In Settings → SSH Keys, generate a new Ed25519 key (recommended) and add it to your server.")
                                .font(.caption)
                            Text("2. Or to keep using RSA, on your server add this line to /etc/ssh/sshd_config:")
                                .font(.caption)
                            Text("   PubkeyAcceptedAlgorithms +ssh-rsa")
                                .font(.system(size: 11, design: .monospaced))
                                .padding(4)
                                .background(Color(uiColor: SolarizedDarkTheme.base03))
                                .cornerRadius(4)
                                .textSelection(.enabled)
                            Text("   then run: sudo systemctl restart ssh")
                                .font(.caption)
                        }
                        .padding(.vertical, 4)
                    }
                }

                if let host = sessionManager.activeHost {
                    Section(header: Text("Host Connection Info")) {
                        LabeledContent("Host", value: "\(host.username)@\(host.hostname):\(host.port)")
                            .textSelection(.enabled)

                        if host.autoConnectTmux {
                            LabeledContent("tmux Startup", value: host.effectiveTmuxSession)
                                .textSelection(.enabled)
                        }

                        LabeledContent("Authentication", value: host.authMethod.rawValue)

                        if let auth = sessionManager.lastAttemptedAuth {
                            if let name = auth.keyName {
                                LabeledContent("Attempted Key", value: name)
                            }
                            if let type = auth.keyType {
                                LabeledContent("Key Type", value: type)
                            }
                            if let pubKey = auth.publicKey {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Offered Public Key:")
                                        .font(.caption.bold())
                                    Text(pubKey)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)

                                    Button(action: {
                                        copyToClipboard(pubKey, feedback: "Public Key Copied")
                                    }) {
                                        Label(copiedFeedback == "Public Key Copied" ? "Copied!" : "Copy Public Key",
                                              systemImage: copiedFeedback == "Public Key Copied" ? "checkmark" : "doc.on.doc")
                                            .font(.caption.bold())
                                            .foregroundStyle(Color(uiColor: SolarizedDarkTheme.cyan))
                                    }
                                    .buttonStyle(.borderless)
                                }
                                .padding(.vertical, 4)
                            }
                        } else if host.authMethod == .sshKey,
                           let keyId = host.selectedKeyId,
                           let key = availableKeys.first(where: { $0.id == keyId }) {
                            LabeledContent("Selected Key", value: key.name)
                            LabeledContent("Key Type", value: key.keyType)

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Public Key:")
                                    .font(.caption.bold())
                                Text(key.publicKey)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)

                                Button(action: {
                                    copyToClipboard(key.publicKey, feedback: "Public Key Copied")
                                }) {
                                    Label(copiedFeedback == "Public Key Copied" ? "Copied!" : "Copy Public Key",
                                          systemImage: copiedFeedback == "Public Key Copied" ? "checkmark" : "doc.on.doc")
                                        .font(.caption.bold())
                                        .foregroundStyle(Color(uiColor: SolarizedDarkTheme.cyan))
                                }
                                .buttonStyle(.borderless)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                Section(header: Text("Troubleshooting 'Citadel.SSHClientError 4'")) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Error 4 means the remote server rejected the credentials. Check the following on your server:")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text("1. Confirm server username matches '\(sessionManager.activeHost?.username ?? "user")'. Run on server:")
                            .font(.caption)
                        Text("   whoami")
                            .font(.system(size: 11, design: .monospaced))
                            .padding(4)
                            .background(Color(uiColor: SolarizedDarkTheme.base03))
                            .cornerRadius(4)
                            .textSelection(.enabled)

                        Text("2. Verify SSH directory and authorized_keys permissions:")
                            .font(.caption)
                        Text("   chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys")
                            .font(.system(size: 11, design: .monospaced))
                            .padding(4)
                            .background(Color(uiColor: SolarizedDarkTheme.base03))
                            .cornerRadius(4)
                            .textSelection(.enabled)

                        Text("3. Check why sshd rejected the key in real-time server logs:")
                            .font(.caption)
                        Text("   sudo journalctl -u ssh -n 50 --no-pager")
                            .font(.system(size: 11, design: .monospaced))
                            .padding(4)
                            .background(Color(uiColor: SolarizedDarkTheme.base03))
                            .cornerRadius(4)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    Button(action: {
                        copyDiagnosticReport()
                    }) {
                        Label(copiedFeedback == "Diagnostic Report Copied" ? "Report Copied to Clipboard" : "Copy Complete Diagnostic Report",
                              systemImage: copiedFeedback == "Diagnostic Report Copied" ? "checkmark" : "doc.on.doc")
                            .font(.subheadline.bold())
                            .foregroundStyle(Color(uiColor: SolarizedDarkTheme.yellow))
                    }
                }
            }
            .navigationTitle("Connection Diagnostic")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { showingDiagnosticSheet = false }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Retry") {
                        showingDiagnosticSheet = false
                        sessionManager.reconnect()
                    }
                }
            }
        }
    }

    private func copyToClipboard(_ text: String, feedback: String = "Copied to Clipboard") {
        UIPasteboard.general.string = text
        copiedFeedback = feedback
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if copiedFeedback == feedback {
                copiedFeedback = nil
            }
        }
    }

    private func copyDiagnosticReport() {
        var report = """
        === Filaire Connection Diagnostic ===
        Error: \(sessionManager.lastError ?? sessionManager.state.description)
        """
        if let host = sessionManager.activeHost {
            report += """

            Host: \(host.username)@\(host.hostname):\(host.port)
            Auth Method: \(host.authMethod.rawValue)
            """
            if host.autoConnectTmux {
                report += "\n            tmux Session: \(host.effectiveTmuxSession)"
            }
            if let auth = sessionManager.lastAttemptedAuth {
                report += """

                Attempted Key Name: \(auth.keyName ?? "None")
                Attempted Key Type: \(auth.keyType ?? "None")
                Attempted Raw Key Type: \(auth.rawKeyType ?? "None")
                Offered Public Key: \(auth.publicKey ?? "None")
                """
            } else if let keyId = host.selectedKeyId, let key = availableKeys.first(where: { $0.id == keyId }) {
                report += """

                Key Name: \(key.name)
                Key Type: \(key.keyType)
                Public Key: \(key.publicKey)
                """
            }
        }
        copyToClipboard(report, feedback: "Diagnostic Report Copied")
    }

    private var statusColor: Color {
        switch sessionManager.state {
        case .connected:
            return Color(uiColor: SolarizedDarkTheme.green)
        case .connecting, .reconnecting:
            return Color(uiColor: SolarizedDarkTheme.yellow)
        case .failed:
            return Color(uiColor: SolarizedDarkTheme.red)
        case .disconnected:
            return Color(uiColor: SolarizedDarkTheme.base01)
        }
    }
}
