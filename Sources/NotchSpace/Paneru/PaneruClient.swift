import AppKit
import Foundation

public enum SpaceAction: Sendable {
    case focusWorkspace(Int)
    case sendFocusedWindow(Int)
    case moveAndFollowWindow(Int)
    case stepRelative(north: Bool)
}

@MainActor
@Observable
public final class PaneruClient {
    public private(set) var spaces: [SpaceItemModel] = [
        SpaceItemModel(number: 1, isActive: true, windows: [])
    ]
    public private(set) var isConnected: Bool = false
    public private(set) var lastRawDocument: PaneruStateDocument?

    private let paneruExecutablePath: String
    private var hideEmptyWorkspaces: Bool = false

    @ObservationIgnored
    private var streamTask: Task<Void, Never>?
    @ObservationIgnored
    private var debounceTask: Task<Void, Never>?
    @ObservationIgnored
    private var activeProcess: Process?

    public init() {
        let candidates = [
            "/opt/homebrew/bin/paneru",
            "/usr/local/bin/paneru",
            "/run/current-system/sw/bin/paneru"
        ]
        self.paneruExecutablePath = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            ?? "/opt/homebrew/bin/paneru"
    }

    public func setHideEmptyWorkspaces(_ hide: Bool) {
        guard hideEmptyWorkspaces != hide else { return }
        hideEmptyWorkspaces = hide
        if let doc = lastRawDocument {
            spaces = PaneruStateProjector.project(document: doc, hideEmptyWorkspaces: hide)
        }
    }

    public func start() {
        stop()
        Task { await refreshNow() }
        streamTask = Task { [weak self] in
            guard let self else { return }
            await self.subscribeLoop()
        }
    }

    public func stop() {
        debounceTask?.cancel()
        debounceTask = nil
        streamTask?.cancel()
        streamTask = nil
        if let proc = activeProcess, proc.isRunning {
            proc.terminate()
        }
        activeProcess = nil
    }

    public func perform(_ action: SpaceAction) {
        let args: [String]
        switch action {
        case .focusWorkspace(let num):
            optimisticallyHighlight(workspaceNumber: num)
            args = ["send-cmd", "window", "virtualnum", String(num)]
        case .sendFocusedWindow(let num):
            args = ["send-cmd", "window", "virtualsendnum", String(num)]
        case .moveAndFollowWindow(let num):
            optimisticallyHighlight(workspaceNumber: num)
            args = ["send-cmd", "window", "virtualmovenum", String(num)]
        case .stepRelative(let north):
            args = ["send-cmd", "window", "virtualfocus", north ? "north" : "south"]
        }

        let execPath = paneruExecutablePath
        Task.detached(priority: .userInitiated) { [weak self] in
            _ = Self.runCommandSync(executable: execPath, arguments: args)
            await self?.scheduleDebouncedRefresh(delayMs: 35)
        }
    }

    public func refreshNow() async {
        let execPath = paneruExecutablePath
        let rawData = await Task.detached(priority: .userInitiated) {
            Self.runCommandSync(executable: execPath, arguments: ["query", "state", "--json"])
        }.value

        guard let rawData,
              let doc = try? JSONDecoder().decode(PaneruStateDocument.self, from: rawData) else {
            isConnected = false
            return
        }

        isConnected = true
        lastRawDocument = doc
        spaces = PaneruStateProjector.project(document: doc, hideEmptyWorkspaces: hideEmptyWorkspaces)
    }

    public func scheduleDebouncedRefresh(delayMs: Int = 60) {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(delayMs))
            guard !Task.isCancelled else { return }
            await self?.refreshNow()
        }
    }

    private func optimisticallyHighlight(workspaceNumber: Int) {
        guard spaces.contains(where: { $0.number == workspaceNumber }) else { return }
        for idx in spaces.indices {
            spaces[idx].isActive = (spaces[idx].number == workspaceNumber)
        }
    }

    private func handleEventLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(PaneruSubscribeEvent.self, from: data) else {
            return
        }

        // Ignore high-frequency title mutations since Space pills only render numbers & column icons.
        if envelope.event == "window_title_changed" {
            return
        }

        // Zero-latency optimistic active pill slide when virtual workspace changes within same native space.
        if envelope.event == "virtual_workspace_changed",
           let active = envelope.active,
           let targetNum = active.virtual_workspace_number,
           active.native_workspace_id == lastRawDocument?.active.native_workspace_id {
            optimisticallyHighlight(workspaceNumber: targetNum)
        }

        scheduleDebouncedRefresh(delayMs: 55)
    }

    private func subscribeLoop() async {
        let execPath = paneruExecutablePath
        while !Task.isCancelled {
            guard FileManager.default.isExecutableFile(atPath: execPath) else {
                isConnected = false
                try? await Task.sleep(for: .seconds(3))
                continue
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: execPath)
            process.arguments = ["subscribe", "--json"]
            let stdoutPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                activeProcess = process
                isConnected = true
                await refreshNow()

                for try await line in stdoutPipe.fileHandleForReading.bytes.lines {
                    if Task.isCancelled { break }
                    handleEventLine(line)
                }
            } catch {
                isConnected = false
            }

            if process.isRunning {
                process.terminate()
            }
            if activeProcess === process {
                activeProcess = nil
            }

            if !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1200))
            }
        }
    }

    nonisolated private static func runCommandSync(executable: String, arguments: [String]) -> Data? {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            return proc.terminationStatus == 0 ? data : nil
        } catch {
            return nil
        }
    }
}
