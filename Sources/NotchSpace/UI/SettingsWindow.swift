import AppKit
import SwiftUI

@MainActor
public final class SettingsWindowController: NSWindowController {
    private let configStore: ConfigStore
    private let activeScreenProvider: () -> NSScreen

    public init(configStore: ConfigStore, activeScreenProvider: @escaping () -> NSScreen) {
        self.configStore = configStore
        self.activeScreenProvider = activeScreenProvider

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 590),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "NotchSpace 偏好设置"
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)

        let rootView = SettingsContentView(
            configStore: configStore,
            activeScreenProvider: activeScreenProvider
        )
        window.contentView = NSHostingView(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func present() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}

private struct SettingsContentView: View {
    let configStore: ConfigStore
    let activeScreenProvider: () -> NSScreen

    @State private var launchAtLogin: Bool = LaunchAgentManager.isEnabled
    @State private var selectedDisplayUUID: String?

    private var availableScreens: [NSScreen] {
        NSScreen.screens
    }

    private var currentScreen: NSScreen {
        if let selectedDisplayUUID,
           let matched = availableScreens.first(where: { NotchGeometryResolver.displayUUID(for: $0) == selectedDisplayUUID }) {
            return matched
        }
        return activeScreenProvider()
    }

    private var displayUUID: String {
        NotchGeometryResolver.displayUUID(for: currentScreen)
    }

    private var hasNotch: Bool {
        NotchGeometryResolver.hasHardwareNotch(currentScreen)
    }

    private var currentPlacement: DisplayPlacement {
        configStore.placement(for: displayUUID, hasNotch: hasNotch)
    }

    var body: some View {
        Form {
            Section("位置与拖拽自定义（各显示器独立记忆）") {
                if availableScreens.count > 1 {
                    Picker(
                        "目标显示器",
                        selection: Binding(
                            get: { displayUUID },
                            set: { newUUID in selectedDisplayUUID = newUUID }
                        )
                    ) {
                        ForEach(availableScreens, id: \.self) { scr in
                            let uuid = NotchGeometryResolver.displayUUID(for: scr)
                            let notchTag = NotchGeometryResolver.hasHardwareNotch(scr) ? "（刘海屏）" : ""
                            Text("\(scr.localizedName)\(notchTag)").tag(uuid)
                        }
                    }
                }
                Picker(
                    "对齐基准点",
                    selection: Binding(
                        get: { currentPlacement.anchor },
                        set: { newAnchor in
                            var p = currentPlacement
                            p.anchor = newAnchor
                            if newAnchor != .custom {
                                p.offsetX = 0
                                p.offsetY = newAnchor == .menuBarInsideCenter ? 0 : 4
                            }
                            configStore.setPlacement(p, for: displayUUID)
                        }
                    )
                ) {
                    ForEach(DisplayAnchorPreset.allCases, id: \.self) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }

                HStack {
                    Text("水平偏移 X")
                    Spacer()
                    Stepper(
                        value: Binding(
                            get: { currentPlacement.offsetX },
                            set: { val in
                                var p = currentPlacement
                                p.offsetX = val
                                configStore.setPlacement(p, for: displayUUID)
                            }
                        ),
                        in: -2000...2000,
                        step: 2
                    ) {
                        Text("\(Int(currentPlacement.offsetX)) pt")
                            .monospacedDigit()
                            .frame(width: 68, alignment: .trailing)
                    }
                }

                HStack {
                    Text("垂直偏移 Y")
                    Spacer()
                    Stepper(
                        value: Binding(
                            get: { currentPlacement.offsetY },
                            set: { val in
                                var p = currentPlacement
                                p.offsetY = val
                                configStore.setPlacement(p, for: displayUUID)
                            }
                        ),
                        in: -60...2000,
                        step: 2
                    ) {
                        Text("\(Int(currentPlacement.offsetY)) pt")
                            .monospacedDigit()
                            .frame(width: 68, alignment: .trailing)
                    }
                }

                Toggle(
                    "锁定悬浮窗位置（锁定后按住 ⌥ Option 仍可拖动）",
                    isOn: Binding(
                        get: { configStore.config.interaction.lockPosition },
                        set: { val in configStore.update { $0.interaction.lockPosition = val } }
                    )
                )

                HStack {
                    Button("一键归位至刘海 / 菜单栏正下方") {
                        configStore.resetPlacement(for: displayUUID, hasNotch: hasNotch)
                    }
                    Spacer()
                    Text(hasNotch ? "已识别硬件刘海屏" : "当前为无刘海外接屏")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("液态玻璃与图标外观") {
                Picker(
                    "深浅色外观",
                    selection: Binding(
                        get: { configStore.config.appearance.colorTheme },
                        set: { val in configStore.update { $0.appearance.colorTheme = val } }
                    )
                ) {
                    ForEach(ColorThemeMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                Picker(
                    "玻璃材质",
                    selection: Binding(
                        get: { configStore.config.appearance.glassStyle },
                        set: { val in configStore.update { $0.appearance.glassStyle = val } }
                    )
                ) {
                    ForEach(GlassMaterialStyle.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }

                Picker(
                    "顶部贴合造型",
                    selection: Binding(
                        get: { configStore.config.appearance.dockedShape },
                        set: { val in configStore.update { $0.appearance.dockedShape = val } }
                    )
                ) {
                    ForEach(DockedCapsuleShape.allCases, id: \.self) { shape in
                        Text(shape.displayName).tag(shape)
                    }
                }

                Picker(
                    "工作区图标风格",
                    selection: Binding(
                        get: { configStore.config.appearance.iconStyle },
                        set: { val in configStore.update { $0.appearance.iconStyle = val } }
                    )
                ) {
                    ForEach(SpaceIconStyle.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }

                HStack {
                    Text("整体缩放比例")
                    Slider(
                        value: Binding(
                            get: { configStore.config.appearance.scale },
                            set: { val in
                                let rounded = (val * 20.0).rounded() / 20.0
                                configStore.update { $0.appearance.scale = rounded }
                            }
                        ),
                        in: 0.85...1.35,
                        step: 0.05
                    )
                    Text("\(Int(round(configStore.config.appearance.scale * 100)))%")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }

                ColorPicker(
                    "激活工作区胶囊高亮色",
                    selection: Binding(
                        get: { Color(hex: configStore.config.appearance.activeTintHex) },
                        set: { newColor in
                            let hex = newColor.toHexString()
                            configStore.update { $0.appearance.activeTintHex = hex }
                        }
                    ),
                    supportsOpacity: false
                )

                Toggle(
                    "隐藏没有窗口的空工作区",
                    isOn: Binding(
                        get: { configStore.config.appearance.hideEmptyWorkspaces },
                        set: { val in configStore.update { $0.appearance.hideEmptyWorkspaces = val } }
                    )
                )
            }

            Section("交互与系统集成") {
                Picker(
                    "窗口管理器后端",
                    selection: Binding(
                        get: { configStore.config.interaction.backend },
                        set: { val in configStore.update { $0.interaction.backend = val } }
                    )
                ) {
                    ForEach(WMBackendMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                Toggle(
                    "支持在胶囊上滚动鼠标滚轮切换上下工作区",
                    isOn: Binding(
                        get: { configStore.config.interaction.enableScrollSwitch },
                        set: { val in configStore.update { $0.interaction.enableScrollSwitch = val } }
                    )
                )

                Toggle(
                    "原生全屏应用下自动隐藏悬浮窗",
                    isOn: Binding(
                        get: { configStore.config.interaction.hideInFullscreen },
                        set: { val in configStore.update { $0.interaction.hideInFullscreen = val } }
                    )
                )

                Toggle(
                    "在右上角菜单栏显示托盘图标（关闭后可用 ⌥+右键 点击胶囊呼出菜单）",
                    isOn: Binding(
                        get: { configStore.config.interaction.showMenuBarIcon },
                        set: { val in configStore.update { $0.interaction.showMenuBarIcon = val } }
                    )
                )

                Toggle(
                    "登录 macOS 时自动启动 NotchSpace",
                    isOn: Binding(
                        get: { launchAtLogin },
                        set: { enabled in
                            LaunchAgentManager.setEnabled(enabled)
                            launchAtLogin = LaunchAgentManager.isEnabled
                        }
                    )
                )

                HStack {
                    Button("打开配置文件目录 (~/.config/notchspace)") {
                        NSWorkspace.shared.activateFileViewerSelecting([configStore.configFileURL])
                    }
                    Spacer()
                    Text("左右就近把手移窗 · 拖图标跨工作区 · ⇧ 拖放携窗跟随")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 590)
    }
}
