import AppKit
import Foundation

public enum ColorThemeMode: String, Codable, CaseIterable, Sendable {
    case auto
    case system
    case dark
    case light

    public var displayName: String {
        switch self {
        case .auto: "智能自适应 (顶栏随壁纸 · 桌面随系统)"
        case .system: "跟随系统深浅色 (System)"
        case .dark: "固定深色 (Dark)"
        case .light: "固定浅色 (Light)"
        }
    }
}

public enum GlassMaterialStyle: String, Codable, CaseIterable, Sendable {
    case regular
    case clear

    public var displayName: String {
        switch self {
        case .regular: "标准液态玻璃 (Regular)"
        case .clear: "高透清澈玻璃 (Clear)"
        }
    }
}

public enum DockedCapsuleShape: String, Codable, CaseIterable, Sendable {
    case floatingCapsule
    case notchChin

    public var displayName: String {
        switch self {
        case .floatingCapsule: "独立圆角胶囊 (留 4pt 呼吸缝隙)"
        case .notchChin: "贴合刘海水滴延伸"
        }
    }
}

public enum SpaceIconStyle: String, Codable, CaseIterable, Sendable {
    case appIcon
    case monochrome
    case numbersOnly

    public var displayName: String {
        switch self {
        case .appIcon: "应用原生彩色图标"
        case .monochrome: "去色高对比单色图标"
        case .numbersOnly: "纯数字极简模式"
        }
    }
}

public enum DisplayAnchorPreset: String, Codable, CaseIterable, Sendable {
    case notchOrMenuBarBottomCenter
    case menuBarInsideCenter
    case topLeading
    case topTrailing
    case custom

    public var displayName: String {
        switch self {
        case .notchOrMenuBarBottomCenter: "刘海 / 菜单栏正下方居中"
        case .menuBarInsideCenter: "菜单栏内部水平居中"
        case .topLeading: "屏幕左上角"
        case .topTrailing: "屏幕右上角"
        case .custom: "自由拖拽自定义位置"
        }
    }
}

public struct AppearanceConfig: Codable, Equatable, Sendable {
    public var colorTheme: ColorThemeMode = .auto
    public var glassStyle: GlassMaterialStyle = .regular
    public var dockedShape: DockedCapsuleShape = .floatingCapsule
    public var iconStyle: SpaceIconStyle = .appIcon
    public var scale: Double = 1.0
    public var hideEmptyWorkspaces: Bool = false
    public var activeTintHex: String = "#2F81F7"

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.colorTheme = try c.decodeIfPresent(ColorThemeMode.self, forKey: .colorTheme) ?? .auto
        self.glassStyle = try c.decodeIfPresent(GlassMaterialStyle.self, forKey: .glassStyle) ?? .regular
        self.dockedShape = try c.decodeIfPresent(DockedCapsuleShape.self, forKey: .dockedShape) ?? .floatingCapsule
        self.iconStyle = try c.decodeIfPresent(SpaceIconStyle.self, forKey: .iconStyle) ?? .appIcon
        self.scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? 1.0
        self.hideEmptyWorkspaces = try c.decodeIfPresent(Bool.self, forKey: .hideEmptyWorkspaces) ?? false
        self.activeTintHex = try c.decodeIfPresent(String.self, forKey: .activeTintHex) ?? "#2F81F7"
    }
}

public struct InteractionConfig: Codable, Equatable, Sendable {
    public var lockPosition: Bool = false
    public var enableScrollSwitch: Bool = false
    public var hideInFullscreen: Bool = false
    public var showMenuBarIcon: Bool = true
    public var snapThreshold: Double = 8.0

    public init() {}
}

public struct DisplayPlacement: Codable, Equatable, Sendable {
    public var anchor: DisplayAnchorPreset = .notchOrMenuBarBottomCenter
    /// Horizontal offset from anchor (or from screen horizontal center in `.custom` mode), in points.
    public var offsetX: Double = 0.0
    /// Vertical offset downward from top reference (screen.maxY in `.custom` mode, or preset anchor), in points.
    public var offsetY: Double = 4.0

    public init(
        anchor: DisplayAnchorPreset = .notchOrMenuBarBottomCenter,
        offsetX: Double = 0.0,
        offsetY: Double = 4.0
    ) {
        self.anchor = anchor
        self.offsetX = offsetX
        self.offsetY = offsetY
    }
}

public struct NotchSpaceConfig: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var appearance: AppearanceConfig = .init()
    public var interaction: InteractionConfig = .init()
    public var displays: [String: DisplayPlacement] = [:]

    public init() {}
}

@MainActor
@Observable
public final class ConfigStore {
    public private(set) var config: NotchSpaceConfig
    public let configDirectoryURL: URL
    public let configFileURL: URL

    @ObservationIgnored
    private var fileMonitor: DispatchSourceFileSystemObject?
    @ObservationIgnored
    private var fileDescriptor: Int32 = -1
    @ObservationIgnored
    private var isWritingInternally = false

    public var onChange: ((NotchSpaceConfig) -> Void)?

    public init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".config/notchspace", isDirectory: true)
        let file = dir.appendingPathComponent("config.json")
        self.configDirectoryURL = dir
        self.configFileURL = file

        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        if let data = try? Data(contentsOf: file),
           let decoded = try? JSONDecoder().decode(NotchSpaceConfig.self, from: data) {
            self.config = decoded
        } else {
            let initial = NotchSpaceConfig()
            self.config = initial
            Self.writeAtomically(initial, to: file)
        }

        startWatchingFile()
    }

    public func update(_ mutate: (inout NotchSpaceConfig) -> Void) {
        var next = config
        mutate(&next)
        guard next != config else { return }
        config = next
        save()
        onChange?(next)
    }

    public func placement(for displayUUID: String, hasNotch: Bool) -> DisplayPlacement {
        if let existing = config.displays[displayUUID] {
            return existing
        }
        let defaultOffset: Double = (config.appearance.dockedShape == .notchChin && hasNotch) ? 0.0 : 4.0
        return DisplayPlacement(anchor: .notchOrMenuBarBottomCenter, offsetX: 0.0, offsetY: defaultOffset)
    }

    public func setPlacement(_ placement: DisplayPlacement, for displayUUID: String) {
        update { cfg in
            cfg.displays[displayUUID] = placement
        }
    }

    public func resetPlacement(for displayUUID: String, hasNotch: Bool) {
        let defaultOffset: Double = (config.appearance.dockedShape == .notchChin && hasNotch) ? 0.0 : 4.0
        setPlacement(
            DisplayPlacement(anchor: .notchOrMenuBarBottomCenter, offsetX: 0.0, offsetY: defaultOffset),
            for: displayUUID
        )
    }

    private func save() {
        isWritingInternally = true
        Self.writeAtomically(config, to: configFileURL)
        startWatchingFile()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            self.isWritingInternally = false
        }
    }

    private static func writeAtomically(_ value: NotchSpaceConfig, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func startWatchingFile() {
        stopWatchingFile()
        let fd = open(configFileURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        fileDescriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let flags = source.data
                if flags.contains(.rename) || flags.contains(.delete) {
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(80))
                        self.reloadFromDiskIfExternal()
                        self.startWatchingFile()
                    }
                } else {
                    self.reloadFromDiskIfExternal()
                }
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        fileMonitor = source
        source.resume()
    }

    private func reloadFromDiskIfExternal() {
        guard !isWritingInternally else { return }
        guard let data = try? Data(contentsOf: configFileURL),
              let decoded = try? JSONDecoder().decode(NotchSpaceConfig.self, from: data),
              decoded != config else { return }
        config = decoded
        onChange?(decoded)
    }

    private func stopWatchingFile() {
        fileMonitor?.cancel()
        fileMonitor = nil
        fileDescriptor = -1
    }
}
