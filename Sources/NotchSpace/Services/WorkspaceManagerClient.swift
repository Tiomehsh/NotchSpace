import AppKit
import Foundation

public enum ActiveWMBackend: String, Equatable, Sendable {
    case omniwm
    case paneru

    public var displayName: String {
        switch self {
        case .omniwm: "OmniWM"
        case .paneru: "Paneru"
        }
    }
}

/// Unified `@Observable` workspace state & command façade supporting both **OmniWM** and **Paneru**
/// with automatic runtime detection or explicit user preference.
@MainActor
@Observable
public final class WorkspaceManagerClient {
    public let omniwmClient = OmniWMClient()
    public let paneruClient = PaneruClient()

    public private(set) var mode: WMBackendMode = .auto
    public private(set) var activeBackend: ActiveWMBackend = .omniwm

    @ObservationIgnored
    private var appLaunchObserver: NSObjectProtocol?
    @ObservationIgnored
    private var appTerminateObserver: NSObjectProtocol?
    @ObservationIgnored
    private var isStarted: Bool = false

    public init() {
        self.activeBackend = Self.detectPreferredBackend(for: .auto)
    }

    public var spaces: [SpaceItemModel] {
        switch activeBackend {
        case .omniwm:
            return omniwmClient.spaces
        case .paneru:
            return paneruClient.spaces
        }
    }

    public var isConnected: Bool {
        switch activeBackend {
        case .omniwm:
            return omniwmClient.isConnected
        case .paneru:
            return paneruClient.isConnected
        }
    }

    public var activeDisplayID: UInt32? {
        switch activeBackend {
        case .omniwm:
            return omniwmClient.activeDisplayID
        case .paneru:
            return paneruClient.lastRawDocument?.active.display_id
        }
    }

    public var activeBackendName: String {
        activeBackend.displayName
    }

    public func setMode(_ newMode: WMBackendMode) {
        let nextBackend = Self.detectPreferredBackend(for: newMode)
        let modeChanged = (mode != newMode)
        let backendChanged = (activeBackend != nextBackend)
        mode = newMode

        guard modeChanged || backendChanged else { return }
        switchActiveBackend(to: nextBackend)
    }

    public func setHideEmptyWorkspaces(_ hide: Bool) {
        omniwmClient.setHideEmptyWorkspaces(hide)
        paneruClient.setHideEmptyWorkspaces(hide)
    }

    public func start() {
        isStarted = true
        activeBackend = Self.detectPreferredBackend(for: mode)
        startCurrentBackendOnly()
        installWorkspaceAppObserversIfNeeded()
    }

    public func stop() {
        isStarted = false
        omniwmClient.stop()
        paneruClient.stop()
        removeWorkspaceAppObservers()
    }

    public func perform(_ action: SpaceAction) {
        switch activeBackend {
        case .omniwm:
            omniwmClient.perform(action)
        case .paneru:
            paneruClient.perform(action)
        }
    }

    public func refreshNow() async {
        if mode == .auto {
            let detected = Self.detectPreferredBackend(for: .auto)
            if detected != activeBackend {
                switchActiveBackend(to: detected)
                return
            }
        }
        switch activeBackend {
        case .omniwm:
            await omniwmClient.refreshNow()
        case .paneru:
            await paneruClient.refreshNow()
        }
    }

    public func scheduleDebouncedRefresh(delayMs: Int = 60) {
        switch activeBackend {
        case .omniwm:
            omniwmClient.scheduleDebouncedRefresh(delayMs: delayMs)
        case .paneru:
            paneruClient.scheduleDebouncedRefresh(delayMs: delayMs)
        }
    }

    // MARK: - Auto Detection & Switching

    public static func detectPreferredBackend(for mode: WMBackendMode) -> ActiveWMBackend {
        switch mode {
        case .omniwm:
            return .omniwm
        case .paneru:
            return .paneru
        case .auto:
            if OmniWMClient.isRuntimeDetected {
                return .omniwm
            }
            if isPaneruProcessRunning() {
                return .paneru
            }
            if FileManager.default.isExecutableFile(atPath: OmniWMClient.resolveExecutablePath())
                || FileManager.default.fileExists(atPath: "/Applications/OmniWM.app") {
                return .omniwm
            }
            return .paneru
        }
    }

    private static func isPaneruProcessRunning() -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        proc.arguments = ["-x", "paneru"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func switchActiveBackend(to nextBackend: ActiveWMBackend) {
        activeBackend = nextBackend
        guard isStarted else { return }
        startCurrentBackendOnly()
    }

    private func startCurrentBackendOnly() {
        switch activeBackend {
        case .omniwm:
            paneruClient.stop()
            omniwmClient.start()
        case .paneru:
            omniwmClient.stop()
            paneruClient.start()
        }
    }

    private func installWorkspaceAppObserversIfNeeded() {
        guard appLaunchObserver == nil else { return }
        let wsCenter = NSWorkspace.shared.notificationCenter

        appLaunchObserver = wsCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated {
                guard let self, self.mode == .auto else { return }
                if bundleID == "com.barut.OmniWM" {
                    self.switchActiveBackend(to: .omniwm)
                }
            }
        }

        appTerminateObserver = wsCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated {
                guard let self, self.mode == .auto else { return }
                if bundleID == "com.barut.OmniWM" {
                    let next = Self.detectPreferredBackend(for: .auto)
                    if next != self.activeBackend {
                        self.switchActiveBackend(to: next)
                    }
                }
            }
        }
    }

    private func removeWorkspaceAppObservers() {
        let wsCenter = NSWorkspace.shared.notificationCenter
        if let obs = appLaunchObserver {
            wsCenter.removeObserver(obs)
            appLaunchObserver = nil
        }
        if let obs = appTerminateObserver {
            wsCenter.removeObserver(obs)
            appTerminateObserver = nil
        }
    }
}
