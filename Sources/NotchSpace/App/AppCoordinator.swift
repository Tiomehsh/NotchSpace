import AppKit
import SwiftUI

@MainActor
public final class AppCoordinator: NSObject, NSMenuDelegate {
    public let configStore = ConfigStore()
    public let wmClient = WorkspaceManagerClient()
    public let panel = FloatingGlassPanel()

    private var hostingView: NSHostingView<SpaceBarView>?
    private var statusItem: NSStatusItem?
    private var menuBarAppearanceProbe: NSStatusItem?
    private var appAppearanceObservation: NSKeyValueObservation?
    private var menuBarAppearanceObservation: NSKeyValueObservation?
    private var settingsController: SettingsWindowController?
    private var currentScreen: NSScreen?
    private var previewPlacementOverride: DisplayPlacement?

    public override init() {
        super.init()
    }

    public func start() {
        wmClient.setMode(configStore.config.interaction.backend)
        wmClient.setHideEmptyWorkspaces(configStore.config.appearance.hideEmptyWorkspaces)
        wmClient.start()

        setupAppearanceProbe()
        setupPanel()
        updateMenuBarStatusItem()
        setupSystemObservers()
        observeCapsuleSizeChanges()

        configStore.onChange = { [weak self] cfg in
            guard let self else { return }
            self.wmClient.setMode(cfg.interaction.backend)
            self.wmClient.setHideEmptyWorkspaces(cfg.appearance.hideEmptyWorkspaces)
            self.syncPanelFlags()
            self.refreshRootViewAndLayout()
            self.updateMenuBarStatusItem()
            self.updateFullscreenVisibility()
        }
    }

    private func resolveTargetScreen() -> NSScreen {
        if let activeDisplayID = wmClient.activeDisplayID,
           let matched = NSScreen.screens.first(where: { NotchGeometryResolver.displayID(for: $0) == activeDisplayID }) {
            return matched
        }
        if let existing = currentScreen, NSScreen.screens.contains(existing) {
            return existing
        }
        return NSScreen.main ?? NSScreen.screens[0]
    }

    private func setupPanel() {
        let screen = resolveTargetScreen()
        currentScreen = screen

        syncPanelFlags()

        panel.onSpaceAction = { [weak self] action in
            self?.wmClient.perform(action)
        }

        panel.onContextMenuRequest = { [weak self] event, view in
            guard let self else { return }
            let menu = self.buildQuickMenu()
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        }

        panel.onDragPreviewPlacement = { [weak self] dragScreen, placement in
            guard let self else { return }
            self.currentScreen = dragScreen
            self.previewPlacementOverride = placement
            self.updateHostingRootView(for: dragScreen, placementOverride: placement)
        }

        panel.onDragCommitPlacement = { [weak self] dragScreen, placement in
            guard let self else { return }
            self.currentScreen = dragScreen
            self.previewPlacementOverride = nil
            let uuid = NotchGeometryResolver.displayUUID(for: dragScreen)
            self.configStore.setPlacement(placement, for: uuid)
            self.refreshRootViewAndLayout()
        }

        let root = makeSpaceBarView(for: screen, placementOverride: nil)
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = false

        let container = HoverTrackingContainerView(frame: .zero)
        container.onHoverPointChanged = { [weak self] pt in
            self?.panel.updateHoverLocation(pt)
        }
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        panel.contentView = container
        self.hostingView = hosting

        repositionPanel(on: screen)
        panel.orderFrontRegardless()
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

    private func resolveColorScheme(for screen: NSScreen, placement: DisplayPlacement) -> ColorScheme {
        switch configStore.config.appearance.colorTheme {
        case .dark:
            return .dark
        case .light:
            return .light
        case .system:
            return isSystemDark() ? .dark : .light
        case .auto:
            let capSize = panel.bridge.restingCapsuleSize
            let anchorPt = NotchGeometryResolver.resolveCapsuleAnchorPoint(
                placement: placement,
                capsuleSize: capSize,
                on: screen
            )
            let capsuleMidY = anchorPt.topY - capSize.height / 2.0
            let topBarBoundaryY = screen.frame.maxY - max(NotchGeometryResolver.menuBarHeight(for: screen), 36.0) - 2.0
            let inTopBarZone = capsuleMidY >= topBarBoundaryY
            let dark = inTopBarZone ? isMenuBarDark() : isSystemDark()
            return dark ? .dark : .light
        }
    }

    private func makeSpaceBarView(for screen: NSScreen, placementOverride: DisplayPlacement?) -> SpaceBarView {
        let uuid = NotchGeometryResolver.displayUUID(for: screen)
        let hasNotch = NotchGeometryResolver.hasHardwareNotch(screen)
        let placement = placementOverride ?? configStore.placement(for: uuid, hasNotch: hasNotch)
        let isChin = NotchGeometryResolver.isDockedFlushToTopBar(
            placement: placement,
            dockedShape: configStore.config.appearance.dockedShape
        )
        let scheme = resolveColorScheme(for: screen, placement: placement)
        panel.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        return SpaceBarView(
            wmClient: wmClient,
            configStore: configStore,
            bridge: panel.bridge,
            isDockedChinMode: isChin,
            resolvedColorScheme: scheme
        )
    }

    private func updateHostingRootView(for screen: NSScreen, placementOverride: DisplayPlacement?) {
        hostingView?.rootView = makeSpaceBarView(for: screen, placementOverride: placementOverride)
    }

    private func syncPanelFlags() {
        let cfg = configStore.config
        panel.isPositionLocked = cfg.interaction.lockPosition
        panel.enableScrollSwitch = cfg.interaction.enableScrollSwitch
        panel.dockedShape = cfg.appearance.dockedShape
        panel.snapThreshold = CGFloat(cfg.interaction.snapThreshold)
    }

    private func refreshRootViewAndLayout() {
        guard !NSScreen.screens.isEmpty else { return }
        let screen = resolveTargetScreen()
        currentScreen = screen
        updateHostingRootView(for: screen, placementOverride: previewPlacementOverride)
        if !panel.bridge.isDraggingWindow && panel.bridge.activeAppDrag == nil {
            repositionPanel(on: screen)
        }
    }

    private func currentCapsuleSize() -> NSSize {
        let cfg = configStore.config.appearance
        let scale = CGFloat(min(max(cfg.scale, 0.80), 1.40))
        let metrics = SpaceBarView.computeRestingMetrics(
            spaces: wmClient.spaces,
            iconStyle: cfg.iconStyle,
            scale: scale
        )
        panel.bridge.restingCapsuleSize = metrics.totalSize
        return metrics.totalSize
    }

    private func repositionPanel(on screen: NSScreen) {
        let uuid = NotchGeometryResolver.displayUUID(for: screen)
        let hasNotch = NotchGeometryResolver.hasHardwareNotch(screen)
        let placement = configStore.placement(for: uuid, hasNotch: hasNotch)

        let capsuleSize = currentCapsuleSize()
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

        if panel.frame != targetFrame {
            panel.setFrame(targetFrame, display: true)
        }
    }

    private func observeCapsuleSizeChanges() {
        withObservationTracking {
            _ = wmClient.spaces
            _ = configStore.config.appearance
            _ = wmClient.activeDisplayID
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: .milliseconds(16))
                if !self.panel.bridge.isDraggingWindow,
                   self.panel.bridge.activeAppDrag == nil,
                   !NSScreen.screens.isEmpty {
                    let screen = self.resolveTargetScreen()
                    self.currentScreen = screen
                    self.updateHostingRootView(for: screen, placementOverride: self.previewPlacementOverride)
                    self.repositionPanel(on: screen)
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
                self?.refreshRootViewAndLayout()
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
        guard configStore.config.interaction.hideInFullscreen else {
            if !panel.isVisible {
                panel.orderFrontRegardless()
            }
            return
        }

        let screen = resolveTargetScreen()
        let inNativeFullscreen = abs(screen.visibleFrame.height - screen.frame.height) < 1.0
            && !NotchGeometryResolver.hasHardwareNotch(screen)

        if inNativeFullscreen {
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
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
    }

    @objc private func snapInsideMenuBarCenter() {
        let screen = resolveTargetScreen()
        let uuid = NotchGeometryResolver.displayUUID(for: screen)
        configStore.setPlacement(
            DisplayPlacement(anchor: .menuBarInsideCenter, offsetX: 0, offsetY: 0),
            for: uuid
        )
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
