import Foundation

@MainActor
public enum LaunchAgentManager {
    public static let label = "dev.4hhuang.NotchSpace"

    public static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    public static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    public static func setEnabled(_ enabled: Bool) {
        if enabled {
            install()
        } else {
            uninstall()
        }
    }

    private static func install() {
        let executablePath = Bundle.main.executablePath
            ?? ProcessInfo.processInfo.arguments.first
            ?? ""
        guard !executablePath.isEmpty else { return }

        let dir = plistURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executablePath],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Interactive"
        ]

        if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
            try? data.write(to: plistURL, options: .atomic)
        }
    }

    private static func uninstall() {
        try? FileManager.default.removeItem(at: plistURL)
    }
}
