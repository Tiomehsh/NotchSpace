import AppKit
import SwiftUI

@MainActor
private final class DisplayPanelContext {
    let displayUUID: String
    var displayID: CGDirectDisplayID
    var screen: NSScreen
    let panel: FloatingGlassPanel
    let hostingView: NSHostingView<SpaceBarView>
    var previewPlacementOverride: DisplayPlacement?

    init(
        displayUUID: String,
        displayID: CGDirectDisplayID,
        screen: NSScreen,
        panel: FloatingGlassPanel,
        hostingView: NSHostingView<SpaceBarView>
    ) {
        self.displayUUID = displayUUID
        self.displayID = displayID
        self.screen = screen
        self.panel = panel
        self.hostingView = hostingView
    }
}

@MainActor
public final class AppCoordinator: NSObject, NSMenuDelegate {
    public let configStore = ConfigStore()
    public let wmClient = WorkspaceManagerClient()

    private var displayContexts: [String: DisplayPanelContext] = [:]
    private var lastContextMenuDisplayUUID: String?
    private var statusItem: NSStatusItem?
    private var menuBarAppearanceProbe: NSStatusItem?
    private var appAppearanceObservation: NSKeyValueObservation?
    private var menuBarAppearanceObservation: NSKeyValueObservation?
    private var settingsController: SettingsWindowController?

    public override init() {
        super.init()
    }

    public func start() {
        wmClient.setMode(configStore.config.interaction.backend)
        wmClient.setHideEmptyWorkspaces(configStore.config.appearance.hideEmptyWorkspaces)
        wmClient.start()

        setupAppearanceProbe()
        syncDisplayPanels()
        refreshRootViewAndLayout()
        updateMenuBarStatusItem()
        setupSystemObservers()
        observeCapsuleSizeChanges()

        configStore.onChange = { [weak self] cfg in
            guard let self else { return }
            self.wmClient.setMode(cfg.interaction.backend)
            self.wmClient.setHideEmptyWorkspaces(cfg.appearance.hideEmptyWorkspaces)
            self.syncAllPanelFlags()
            self.refreshRootViewAndLayout()
            self.updateMenuBarStatusItem()
            self.updateFullscreenVisibility()
        }
    }

    private func resolveTargetScreen() -> NSScreen {
        if let uuid = lastContextMenuDisplayUUID,
           let matched = NSScreen.screens.first(where: { NotchGeometryResolver.displayUUID(for: $0) == uuid }) {
            return matched
        }
        let mouseLoc = NSEvent.mouseLocation
        if let mouseScreen = NSScreen.screens.first(where: { NSMouseInRect(mouseLoc, $0.frame, false) }) {
            return mouseScreen
        }
        if let activeDisplayID = wmClient.activeDisplayID,
           let matched = NSScreen.screens.first(where: { NotchGeometryResolver.displayID(for: $0) == activeDisplayID }) {
            return matched
        }
        return NSScreen.main ?? NSScreen.screens[0]
    }

    private func syncDisplayPanels() {
        let screens = NSScreen.screens
        var activeUUIDs = Set<String>()

        for screen in screens {
            let uuid = NotchGeometryResolver.displayUUID(for: screen)
            let displayID = NotchGeometryResolver.displayID(for: screen)
            activeUUIDs.insert(uuid)

            if let existing = displayContexts[uuid] {
                existing.screen = screen
                existing.displayID = displayID
                existing.panel.targetScreen = screen
                existing.panel.targetDisplayID = displayID
                syncPanelFlags(for: existing.panel)
            } else {
                let panel = FloatingGlassPanel()
                panel.targetScreen = screen
                panel.targetDisplayID = displayID
                syncPanelFlags(for: panel)

                let root = makeSpaceBarView(
                    for: screen,
                    displayID: displayID,
                    panel: panel,
                    placementOverride: nil
                )
                let hosting = NSHostingView(rootView: root)
                hosting.sizingOptions = []
                hosting.translatesAutoresizingMaskIntoConstraints = false

                let container = HoverTrackingContainerView(frame: .zero)
                container.onHoverPointChanged = { [weak panel] pt in
                    panel?.updateHoverLocation(pt)
                }
                container.addSubview(hosting)
                NSLayoutConstraint.activate([
                    hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                    hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                    hosting.topAnchor.constraint(equalTo: container.topAnchor),
                    hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor)
                ])
                panel.contentView = container

                let context = DisplayPanelContext(
                    displayUUID: uuid,
                    displayID: displayID,
                    screen: screen,
                    panel: panel,
                    hostingView: hosting
                )
                displayContexts[uuid] = context

                panel.onSpaceAction = { [weak self] action in
                    self?.wmClient.perform(action)
                }

                panel.onContextMenuRequest = { [weak self] event, view in
                    guard let self else { return }
                    self.lastContextMenuDisplayUUID = uuid
                    let menu = self.buildQuickMenu()
                    NSMenu.popUpContextMenu(menu, with: event, for: view)
                }

                panel.onDragPreviewPlacement = { [weak self, weak context] _, placement in
                    guard let self, let context else { return }
                    context.previewPlacementOverride = placement
                    self.updateHostingRootView(for: context)
                }

                panel.onDragCommitPlacement = { [weak self, weak context] _, placement in
                    guard let self, let context else { return }
                    context.previewPlacementOverride = nil
                    self.configStore.setPlacement(placement, for: context.displayUUID)
                    self.refreshRootViewAndLayout()
                }

                panel.onCrossDisplayAppDragUpdate = { [weak self] sourceTarget, screenPt, followWithShift in
                    guard let self else { return nil }
                    var matchedHit: (spaceNumber: Int, isNewSpace: Bool)?
                    for (otherUUID, otherCtx) in self.displayContexts where otherUUID != uuid {
                        let otherFrame = otherCtx.panel.frame
                        if otherFrame.insetBy(dx: -16.0, dy: -16.0).contains(screenPt) {
                            let localX = screenPt.x - otherFrame.minX
                            let localTopY = otherFrame.height - (screenPt.y - otherFrame.minY)
                            let topLeft = CGPoint(x: localX, y: localTopY)
                            let hit = otherCtx.panel.bridge.hitTestDropDestination(
                                at: topLeft,
                                excludingSpace: sourceTarget.spaceNumber
                            )
                            otherCtx.panel.bridge.activeAppDrag = ActiveAppDrag(
                                source: sourceTarget,
                                currentPointInRoot: topLeft,
                                targetSpaceNumber: hit?.spaceNumber,
                                isCreatingNewSpace: hit?.isNewSpace ?? false,
                                followWithShift: followWithShift
                            )
                            if let hit {
                                matchedHit = hit
                            }
                        } else if otherCtx.panel.bridge.activeAppDrag != nil {
                            otherCtx.panel.bridge.activeAppDrag = nil
                        }
                    }
                    return matchedHit
                }

                panel.onCrossDisplayAppDragEnd = { [weak self] in
                    guard let self else { return }
                    for (otherUUID, otherCtx) in self.displayContexts where otherUUID != uuid {
                        if otherCtx.panel.bridge.activeAppDrag != nil {
                            otherCtx.panel.bridge.activeAppDrag = nil
                        }
                    }
                }

                repositionPanel(for: context)
                panel.orderFrontRegardless()
            }
        }

        let staleUUIDs = Set(displayContexts.keys).subtracting(activeUUIDs)
        for staleUUID in staleUUIDs {
            if let removed = displayContexts.removeValue(forKey: staleUUID) {
                removed.panel.orderOut(nil)
                removed.panel.close()
            }
        }
    }

    private func setupAppearanceProbe() {
        appAppearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.refreshRootViewAndLayout()
            }
        }
    }

    private func bindMenuBarAppearanceObserver(to button: NSStatusBarButton?) {
        menuBarAppearanceObservation = button?.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.refreshRootViewAndLayout()
            }
        }
    }

    private func isSystemDark() -> Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private func isMenuBarDark() -> Bool {
        let appearance = statusItem?.button?.effectiveAppearance
            ?? menuBarAppearanceProbe?.button?.effectiveAppearance
            ?? NSApp.effectiveAppearance
        return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private func resolveColorScheme(
        for screen: NSScreen,
        placement: DisplayPlacement,
        capsuleSize: NSSize
    ) -> ColorScheme {
        switch configStore.config.appearance.colorTheme {
        case .dark:
            return .dark
        case .light:
            return .light
        case .system:
            return isSystemDark() ? .dark : .light
        case .auto:
            let anchorPt = NotchGeometryResolver.resolveCapsuleAnchorPoint(
                placement: placement,
                capsuleSize: capsuleSize,
                on: screen
            )
            let capsuleMidY = anchorPt.topY - capsuleSize.height / 2.0
            let topBarBoundaryY = screen.frame.maxY - max(NotchGeometryResolver.menuBarHeight(for: screen), 36.0) - 2.0
            let inTopBarZone = capsuleMidY >= topBarBoundaryY
            let dark = inTopBarZone ? isMenuBarDark() : isSystemDark()
            return dark ? .dark : .light
        }
    }

    private func makeSpaceBarView(
        for screen: NSScreen,
        displayID: CGDirectDisplayID,
        panel: FloatingGlassPanel,
        placementOverride: DisplayPlacement?
    ) -> SpaceBarView {
        let uuid = NotchGeometryResolver.displayUUID(for: screen)
        let hasNotch = NotchGeometryResolver.hasHardwareNotch(screen)
        let placement = placementOverride ?? configStore.placement(for: uuid, hasNotch: hasNotch)
        let isChin = NotchGeometryResolver.isDockedFlushToTopBar(
            placement: placement,
            dockedShape: configStore.config.appearance.dockedShape
        )
        let capSize = currentCapsuleSize(for: displayID, bridge: panel.bridge)
        let scheme = resolveColorScheme(for: screen, placement: placement, capsuleSize: capSize)
        panel.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        return SpaceBarView(
            wmClient: wmClient,
            configStore: configStore,
            bridge: panel.bridge,
            displayID: displayID,
            isDockedChinMode: isChin,
            resolvedColorScheme: scheme
        )
    }

    private func updateHostingRootView(for context: DisplayPanelContext) {
        context.hostingView.rootView = makeSpaceBarView(
            for: context.screen,
            displayID: context.displayID,
            panel: context.panel,
            placementOverride: context.previewPlacementOverride
        )
    }

    private func syncPanelFlags(for panel: FloatingGlassPanel) {
        let cfg = configStore.config
        panel.isPositionLocked = cfg.interaction.lockPosition
        panel.enableScrollSwitch = cfg.interaction.enableScrollSwitch
        panel.dockedShape = cfg.appearance.dockedShape
        panel.snapThreshold = CGFloat(cfg.interaction.snapThreshold)
    }

    private func syncAllPanelFlags() {
        for context in displayContexts.values {
            syncPanelFlags(for: context.panel)
        }
    }

    private func refreshRootViewAndLayout() {
        syncDisplayPanels()
        for context in displayContexts.values {
            updateHostingRootView(for: context)
            if !context.panel.bridge.isDraggingWindow && context.panel.bridge.activeAppDrag == nil {
                repositionPanel(for: context)
            }
        }
    }

    private func currentCapsuleSize(for displayID: CGDirectDisplayID, bridge: PanelInteractionBridge) -> NSSize {
        let cfg = configStore.config.appearance
        let scale = CGFloat(min(max(cfg.scale, 0.80), 1.40))
        let displaySpaces = wmClient.spaces(for: displayID)
        let metrics = SpaceBarView.computeRestingMetrics(
            spaces: displaySpaces,
            iconStyle: cfg.iconStyle,
            scale: scale
        )
        bridge.restingCapsuleSize = metrics.totalSize
        return metrics.totalSize
    }

    private func repositionPanel(for context: DisplayPanelContext) {
        let screen = context.screen
        let uuid = context.displayUUID
        let hasNotch = NotchGeometryResolver.hasHardwareNotch(screen)
        let placement = configStore.placement(for: uuid, hasNotch: hasNotch)

        let capsuleSize = currentCapsuleSize(for: context.displayID, bridge: context.panel.bridge)
        let anchorPt = NotchGeometryResolver.resolveCapsuleAnchorPoint(
            placement: placement,
            capsuleSize: capsuleSize,
            on: screen
        )
        let targetFrame = NotchGeometryResolver.panelFrame(
            capsuleCenterX: anchorPt.centerX,
            capsuleTopY: anchorPt.topY,
            capsuleSize: capsuleSize
        )

        if context.panel.frame != targetFrame {
            context.panel.setFrame(targetFrame, display: true)
        }
    }

    private func observeCapsuleSizeChanges() {
        withObservationTracking {
            _ = wmClient.spaces
            _ = wmClient.spacesByDisplayID
            _ = configStore.config.appearance
            _ = wmClient.activeDisplayID
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: .milliseconds(16))
                self.syncDisplayPanels()
                for context in self.displayContexts.values {
                    if !context.panel.bridge.isDraggingWindow,
                       context.panel.bridge.activeAppDrag == nil {
                        self.updateHostingRootView(for: context)
                        self.repositionPanel(for: context)
                    }
                }
                self.observeCapsuleSizeChanges()
            }
        }
    }

    private func setupSystemObservers() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshRootViewAndLayout()
                self.updateFullscreenVisibility()
                Task { await self.wmClient.refreshNow() }
            }
        }

        let wsCenter = NSWorkspace.shared.notificationCenter
        wsCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.wmClient.scheduleDebouncedRefresh(delayMs: 40)
                self.updateFullscreenVisibility()
            }
        }

        wsCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.wmClient.refreshNow() }
                self.refreshRootViewAndLayout()
            }
        }
    }

    private func updateFullscreenVisibility() {
        let hideInFullscreen = configStore.config.interaction.hideInFullscreen
        for context in displayContexts.values {
            guard hideInFullscreen else {
                if !context.panel.isVisible {
                    context.panel.orderFrontRegardless()
                }
                continue
            }
            let screen = context.screen
            let inNativeFullscreen = abs(screen.visibleFrame.height - screen.frame.height) < 1.0
                && !NotchGeometryResolver.hasHardwareNotch(screen)

            if inNativeFullscreen {
                context.panel.orderOut(nil)
            } else {
                context.panel.orderFrontRegardless()
            }
        }
    }

    // MARK: - Status Item & Context Menu

    private func updateMenuBarStatusItem() {
        if configStore.config.interaction.showMenuBarIcon {
            if let probe = menuBarAppearanceProbe {
                NSStatusBar.system.removeStatusItem(probe)
                menuBarAppearanceProbe = nil
            }
            if statusItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                if let button = item.button {
                    let img = NSImage(
                        systemSymbolName: "rectangle.split.3x1",
                        accessibilityDescription: "NotchSpace"
                    )
                    img?.isTemplate = true
                    button.image = img
                    button.toolTip = "NotchSpace"
                }
                item.menu = buildQuickMenu()
                statusItem = item
                bindMenuBarAppearanceObserver(to: item.button)
                refreshRootViewAndLayout()
            } else {
                statusItem?.menu = buildQuickMenu()
            }
        } else {
            if let existing = statusItem {
                NSStatusBar.system.removeStatusItem(existing)
                statusItem = nil
            }
            if menuBarAppearanceProbe == nil {
                let probe = NSStatusBar.system.statusItem(withLength: 0)
                menuBarAppearanceProbe = probe
                bindMenuBarAppearanceObserver(to: probe.button)
            }
        }
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        populateQuickMenu(menu)
    }

    private func buildQuickMenu() -> NSMenu {
        let menu = NSMenu(title: "NotchSpace")
        menu.delegate = self
        populateQuickMenu(menu)
        return menu
    }

    private func populateQuickMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let resetItem = NSMenuItem(
            title: "归位至刘海 / 菜单栏正下方",
            action: #selector(resetCurrentDisplayPosition),
            keyEquivalent: "r"
        )
        resetItem.target = self
        menu.addItem(resetItem)

        let insideMenuBarItem = NSMenuItem(
            title: "移至菜单栏内部居中",
            action: #selector(snapInsideMenuBarCenter),
            keyEquivalent: ""
        )
        insideMenuBarItem.target = self
        menu.addItem(insideMenuBarItem)

        if NSScreen.screens.count > 1 {
            let resetAllItem = NSMenuItem(
                title: "归位所有显示器位置",
                action: #selector(resetAllDisplaysPosition),
                keyEquivalent: ""
            )
            resetAllItem.target = self
            menu.addItem(resetAllItem)
        }

        let lockItem = NSMenuItem(
            title: "锁定位置（按住 ⌥ 仍可拖动）",
            action: #selector(toggleLockPosition),
            keyEquivalent: "l"
        )
        lockItem.target = self
        lockItem.state = configStore.config.interaction.lockPosition ? .on : .off
        menu.addItem(lockItem)

        menu.addItem(.separator())

        // Color Theme Submenu
        let themeSub = NSMenu()
        for mode in ColorThemeMode.allCases {
            let subItem = NSMenuItem(
                title: mode.displayName,
                action: #selector(selectColorTheme(_:)),
                keyEquivalent: ""
            )
            subItem.target = self
            subItem.representedObject = mode.rawValue
            subItem.state = configStore.config.appearance.colorTheme == mode ? .on : .off
            themeSub.addItem(subItem)
        }
        let themeMenuRoot = NSMenuItem(title: "深浅色外观", action: nil, keyEquivalent: "")
        themeMenuRoot.submenu = themeSub
        menu.addItem(themeMenuRoot)

        // Glass Style Submenu
        let glassSub = NSMenu()
        for style in GlassMaterialStyle.allCases {
            let subItem = NSMenuItem(
                title: style.displayName,
                action: #selector(selectGlassStyle(_:)),
                keyEquivalent: ""
            )
            subItem.target = self
            subItem.representedObject = style.rawValue
            subItem.state = configStore.config.appearance.glassStyle == style ? .on : .off
            glassSub.addItem(subItem)
        }
        let glassMenuRoot = NSMenuItem(title: "玻璃材质", action: nil, keyEquivalent: "")
        glassMenuRoot.submenu = glassSub
        menu.addItem(glassMenuRoot)

        // Docked Shape Submenu
        let shapeSub = NSMenu()
        for shape in DockedCapsuleShape.allCases {
            let subItem = NSMenuItem(
                title: shape.displayName,
                action: #selector(selectDockedShape(_:)),
                keyEquivalent: ""
            )
            subItem.target = self
            subItem.representedObject = shape.rawValue
            subItem.state = configStore.config.appearance.dockedShape == shape ? .on : .off
            shapeSub.addItem(subItem)
        }
        let shapeMenuRoot = NSMenuItem(title: "胶囊造型", action: nil, keyEquivalent: "")
        shapeMenuRoot.submenu = shapeSub
        menu.addItem(shapeMenuRoot)

        // Icon Style Submenu
        let iconSub = NSMenu()
        for style in SpaceIconStyle.allCases {
            let subItem = NSMenuItem(
                title: style.displayName,
                action: #selector(selectIconStyle(_:)),
                keyEquivalent: ""
            )
            subItem.target = self
            subItem.representedObject = style.rawValue
            subItem.state = configStore.config.appearance.iconStyle == style ? .on : .off
            iconSub.addItem(subItem)
        }
        let iconMenuRoot = NSMenuItem(title: "图标风格", action: nil, keyEquivalent: "")
        iconMenuRoot.submenu = iconSub
        menu.addItem(iconMenuRoot)

        let hideEmptyItem = NSMenuItem(
            title: "隐藏空工作区",
            action: #selector(toggleHideEmptySpaces),
            keyEquivalent: ""
        )
        hideEmptyItem.target = self
        hideEmptyItem.state = configStore.config.appearance.hideEmptyWorkspaces ? .on : .off
        menu.addItem(hideEmptyItem)

        menu.addItem(.separator())

        let prefsItem = NSMenuItem(
            title: "偏好设置…",
            action: #selector(openPreferences),
            keyEquivalent: ","
        )
        prefsItem.target = self
        menu.addItem(prefsItem)

        // WM Backend Submenu
        let wmSub = NSMenu()
        for mode in WMBackendMode.allCases {
            let subItem = NSMenuItem(
                title: mode.displayName,
                action: #selector(selectWMBackend(_:)),
                keyEquivalent: ""
            )
            subItem.target = self
            subItem.representedObject = mode.rawValue
            subItem.state = configStore.config.interaction.backend == mode ? .on : .off
            wmSub.addItem(subItem)
        }
        let statusSuffix = wmClient.isConnected ? "已连接" : "未连接"
        let wmRoot = NSMenuItem(
            title: "窗口后端：\(wmClient.activeBackendName)（\(statusSuffix)）",
            action: nil,
            keyEquivalent: ""
        )
        wmRoot.submenu = wmSub
        menu.addItem(wmRoot)

        let reloadItem = NSMenuItem(
            title: "刷新 \(wmClient.activeBackendName) 状态",
            action: #selector(forceRefreshWM),
            keyEquivalent: ""
        )
        reloadItem.target = self
        menu.addItem(reloadItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "退出 NotchSpace",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc private func resetCurrentDisplayPosition() {
        let screen = resolveTargetScreen()
        let uuid = NotchGeometryResolver.displayUUID(for: screen)
        let hasNotch = NotchGeometryResolver.hasHardwareNotch(screen)
        configStore.resetPlacement(for: uuid, hasNotch: hasNotch)
        lastContextMenuDisplayUUID = nil
    }

    @objc private func resetAllDisplaysPosition() {
        for screen in NSScreen.screens {
            let uuid = NotchGeometryResolver.displayUUID(for: screen)
            let hasNotch = NotchGeometryResolver.hasHardwareNotch(screen)
            configStore.resetPlacement(for: uuid, hasNotch: hasNotch)
        }
        lastContextMenuDisplayUUID = nil
    }

    @objc private func snapInsideMenuBarCenter() {
        let screen = resolveTargetScreen()
        let uuid = NotchGeometryResolver.displayUUID(for: screen)
        configStore.setPlacement(
            DisplayPlacement(anchor: .menuBarInsideCenter, offsetX: 0, offsetY: 0),
            for: uuid
        )
        lastContextMenuDisplayUUID = nil
    }

    @objc private func toggleLockPosition() {
        configStore.update { $0.interaction.lockPosition.toggle() }
    }

    @objc private func selectColorTheme(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = ColorThemeMode(rawValue: raw) else { return }
        configStore.update { $0.appearance.colorTheme = mode }
    }

    @objc private func selectGlassStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let style = GlassMaterialStyle(rawValue: raw) else { return }
        configStore.update { $0.appearance.glassStyle = style }
    }

    @objc private func selectDockedShape(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let shape = DockedCapsuleShape(rawValue: raw) else { return }
        configStore.update { $0.appearance.dockedShape = shape }
    }

    @objc private func selectIconStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let style = SpaceIconStyle(rawValue: raw) else { return }
        configStore.update { $0.appearance.iconStyle = style }
    }

    @objc private func toggleHideEmptySpaces() {
        configStore.update { $0.appearance.hideEmptyWorkspaces.toggle() }
    }

    @objc private func openPreferences() {
        if settingsController == nil {
            settingsController = SettingsWindowController(
                configStore: configStore,
                activeScreenProvider: { [weak self] in
                    self?.resolveTargetScreen() ?? NSScreen.main ?? NSScreen.screens[0]
                }
            )
        }
        settingsController?.present()
    }

    @objc private func selectWMBackend(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = WMBackendMode(rawValue: raw) else { return }
        configStore.update { $0.interaction.backend = mode }
    }

    @objc private func forceRefreshWM() {
        Task { await wmClient.refreshNow() }
    }

    @objc private func quitApp() {
        wmClient.stop()
        NSApp.terminate(nil)
    }
}
