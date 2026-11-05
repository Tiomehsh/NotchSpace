import AppKit
import Foundation

public enum SpaceAction: Sendable {
    case focusWorkspace(Int)
    case focusWindow(Int)
    case sendFocusedWindow(Int)
    case moveAndFollowWindow(Int)
    case moveSpecificWindow(windowID: Int, fromSpace: Int, toSpace: Int, follow: Bool)
    case stepRelative(north: Bool, displayID: UInt32?)
}

@MainActor
@Observable
public final class PaneruClient {
    public private(set) var spaces: [SpaceItemModel] = [
        SpaceItemModel(number: 1, isActive: true, windows: [])
    ]
    public private(set) var spacesByDisplayID: [UInt32: [SpaceItemModel]] = [:]
    public private(set) var isConnected: Bool = false
    public private(set) var lastRawDocument: PaneruStateDocument?

    private let paneruExecutablePath: String
    private var hideEmptyWorkspaces: Bool = false

    @ObservationIgnored
    private var nativeWorkspaceByDisplayID: [UInt32: Int] = [:]
    @ObservationIgnored
    private var activeVirtualByNativeID: [Int: Int] = [:]

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

    public func spaces(for displayID: UInt32?) -> [SpaceItemModel] {
        if let displayID, let matched = spacesByDisplayID[displayID], !matched.isEmpty {
            return matched
        }
        return spaces
    }

    public func nextNewSpaceNumber(for displayID: UInt32?) -> Int? {
        let currentSpaces = spaces(for: displayID)
        let maxNum = currentSpaces.map(\.number).max() ?? 1
        return maxNum < 9 ? (maxNum + 1) : nil
    }

    public func setHideEmptyWorkspaces(_ hide: Bool) {
        guard hideEmptyWorkspaces != hide else { return }
        hideEmptyWorkspaces = hide
        if let doc = lastRawDocument {
            projectDocument(doc)
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
        let execPath = paneruExecutablePath

        switch action {
        case .focusWindow(let winID):
            optimisticallyFocusWindow(windowID: winID)
            Task.detached(priority: .userInitiated) { [weak self] in
                _ = PaneruMachIPC.focusWindow(windowID: winID)
                await self?.scheduleDebouncedRefresh(delayMs: 35)
            }
            return

        case .moveSpecificWindow(let winID, let fromSpace, let toSpace, let follow):
            guard fromSpace != toSpace else { return }
            optimisticallyMoveWindow(windowID: winID, fromSpace: fromSpace, toSpace: toSpace, follow: follow)
            Task.detached(priority: .userInitiated) { [weak self] in
                let ok = PaneruMachIPC.moveWindowToWorkspace(
                    windowID: winID,
                    workspaceNumber: toSpace,
                    follow: follow
                )
                if !ok {
                    let subcmd = follow ? "virtualmovenum" : "virtualsendnum"
                    _ = Self.runCommandSync(
                        executable: execPath,
                        arguments: ["send-cmd", "window", subcmd, String(toSpace)]
                    )
                }
                await self?.scheduleDebouncedRefresh(delayMs: 45)
            }
            return

        case .focusWorkspace(let num):
            optimisticallyHighlight(workspaceNumber: num)
            let args = ["send-cmd", "window", "virtualnum", String(num)]
            Task.detached(priority: .userInitiated) { [weak self] in
                _ = Self.runCommandSync(executable: execPath, arguments: args)
                await self?.scheduleDebouncedRefresh(delayMs: 35)
            }

        case .sendFocusedWindow(let num):
            let args = ["send-cmd", "window", "virtualsendnum", String(num)]
            Task.detached(priority: .userInitiated) { [weak self] in
                _ = Self.runCommandSync(executable: execPath, arguments: args)
                await self?.scheduleDebouncedRefresh(delayMs: 35)
            }

        case .moveAndFollowWindow(let num):
            optimisticallyHighlight(workspaceNumber: num)
            let args = ["send-cmd", "window", "virtualmovenum", String(num)]
            Task.detached(priority: .userInitiated) { [weak self] in
                _ = Self.runCommandSync(executable: execPath, arguments: args)
                await self?.scheduleDebouncedRefresh(delayMs: 35)
            }

        case .stepRelative(let north, _):
            let args = ["send-cmd", "window", "virtualfocus", north ? "north" : "south"]
            Task.detached(priority: .userInitiated) { [weak self] in
                _ = Self.runCommandSync(executable: execPath, arguments: args)
                await self?.scheduleDebouncedRefresh(delayMs: 35)
            }
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
        projectDocument(doc)
    }

    private func projectDocument(_ doc: PaneruStateDocument) {
        if let activeDisp = doc.active.display_id, let activeNative = doc.active.native_workspace_id {
            nativeWorkspaceByDisplayID[activeDisp] = activeNative
            if let vNum = doc.active.virtual_workspace_number {
                activeVirtualByNativeID[activeNative] = vNum
            }
        }

        for ws in doc.virtual_workspaces {
            guard let wsNative = ws.native_workspace_id else { continue }
            if ws.active == true {
                activeVirtualByNativeID[wsNative] = ws.number
            }
            if let winDisp = ws.windows.compactMap(\.display_id).first {
                nativeWorkspaceByDisplayID[winDisp] = wsNative
            }
        }

        spaces = PaneruStateProjector.project(document: doc, hideEmptyWorkspaces: hideEmptyWorkspaces)

        var byDisplay: [UInt32: [SpaceItemModel]] = [:]
        for (dispID, nativeID) in nativeWorkspaceByDisplayID {
            byDisplay[dispID] = PaneruStateProjector.project(
                document: doc,
                targetNativeWorkspaceID: nativeID,
                activeVirtualOverride: activeVirtualByNativeID[nativeID],
                hideEmptyWorkspaces: hideEmptyWorkspaces
            )
        }
        spacesByDisplayID = byDisplay
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

    private func optimisticallyFocusWindow(windowID: Int) {
        for sIdx in spaces.indices {
            guard let targetWin = spaces[sIdx].windows.first(where: { $0.windowID == windowID }) else { continue }
            let targetCol = targetWin.columnIndex
            for wIdx in spaces[sIdx].windows.indices {
                let isThisWin = spaces[sIdx].windows[wIdx].windowID == windowID
                let inCol = isThisWin || (targetCol != nil && spaces[sIdx].windows[wIdx].columnIndex == targetCol)
                spaces[sIdx].windows[wIdx].isFocused = isThisWin
                spaces[sIdx].windows[wIdx].isInFocusedColumn = inCol
            }
        }
    }

    private func optimisticallyMoveWindow(
        windowID: Int,
        fromSpace: Int,
        toSpace: Int,
        follow: Bool
    ) {
        guard let srcIdx = spaces.firstIndex(where: { $0.number == fromSpace }),
              let winPos = spaces[srcIdx].windows.firstIndex(where: { $0.windowID == windowID }) else {
            return
        }

        let movedItem = spaces[srcIdx].windows.remove(at: winPos)

        if let dstIdx = spaces.firstIndex(where: { $0.number == toSpace }) {
            spaces[dstIdx].windows.append(movedItem)
        } else {
            let newSpace = SpaceItemModel(
                number: toSpace,
                isActive: follow,
                windows: [movedItem]
            )
            spaces.append(newSpace)
            spaces.sort { $0.number < $1.number }
        }

        if follow {
            optimisticallyHighlight(workspaceNumber: toSpace)
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

        if let focusedWinID = envelope.active?.focused_window_id {
            optimisticallyFocusWindow(windowID: focusedWinID)
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
