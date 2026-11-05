import AppKit
import Foundation

@MainActor
@Observable
public final class OmniWMClient {
    public private(set) var spaces: [SpaceItemModel] = [
        SpaceItemModel(number: 1, isActive: true, windows: [])
    ]
    public private(set) var spacesByDisplayID: [UInt32: [SpaceItemModel]] = [:]
    public private(set) var nextNewSpaceByDisplayID: [UInt32: Int] = [:]
    public private(set) var isConnected: Bool = false
    public private(set) var activeDisplayID: UInt32?

    private let omniwmctlPath: String
    private var hideEmptyWorkspaces: Bool = false

    @ObservationIgnored
    private var cachedDisplays: [OmniWMDisplaySnapshot] = []
    @ObservationIgnored
    private var cachedWorkspaces: [OmniWMWorkspace] = []
    @ObservationIgnored
    private var cachedWindows: [OmniWMWindow] = []
    @ObservationIgnored
    private var activeDisplayRefID: String?
    @ObservationIgnored
    private var activeWorkspaceNumber: Int?
    @ObservationIgnored
    private var activeWorkspaceByDisplayID: [UInt32: Int] = [:]
    @ObservationIgnored
    private var focusedOpaqueWindowID: String?
    @ObservationIgnored
    private var opaqueIDByWindowID: [Int: String] = [:]

    @ObservationIgnored
    private var streamTask: Task<Void, Never>?
    @ObservationIgnored
    private var debounceTask: Task<Void, Never>?
    @ObservationIgnored
    private var activeProcess: Process?

    public init() {
        self.omniwmctlPath = Self.resolveExecutablePath()
    }

    public static func resolveExecutablePath() -> String {
        let candidates = [
            "/opt/homebrew/bin/omniwmctl",
            "/usr/local/bin/omniwmctl",
            "/Applications/OmniWM.app/Contents/MacOS/omniwmctl",
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/OmniWM.app/Contents/MacOS/omniwmctl").path
        ]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            ?? "/opt/homebrew/bin/omniwmctl"
    }

    public static var socketPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.barut.OmniWM/ipc.sock")
            .path
    }

    public static var isRuntimeDetected: Bool {
        if !NSRunningApplication.runningApplications(withBundleIdentifier: "com.barut.OmniWM").isEmpty {
            return true
        }
        return FileManager.default.fileExists(atPath: socketPath)
    }

    public func spaces(for displayID: UInt32?) -> [SpaceItemModel] {
        if let displayID, let matched = spacesByDisplayID[displayID], !matched.isEmpty {
            return matched
        }
        return spaces
    }

    public func nextNewSpaceNumber(for displayID: UInt32?) -> Int? {
        if let displayID {
            return nextNewSpaceByDisplayID[displayID]
        }
        if let activeDisplayID {
            return nextNewSpaceByDisplayID[activeDisplayID]
        }
        let maxNum = spaces.map(\.number).max() ?? 1
        return maxNum < 9 ? (maxNum + 1) : nil
    }

    public func setHideEmptyWorkspaces(_ hide: Bool) {
        guard hideEmptyWorkspaces != hide else { return }
        hideEmptyWorkspaces = hide
        reprojectSpaces()
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
        let execPath = omniwmctlPath

        switch action {
        case .focusWindow(let winID):
            optimisticallyFocusWindow(windowID: winID)
            let knownOpaque = opaqueIDByWindowID[winID]
            Task.detached(priority: .userInitiated) { [weak self] in
                if let opaque = knownOpaque ?? Self.lookupOpaqueIDSync(executable: execPath, windowID: winID) {
                    _ = Self.runCommandSync(executable: execPath, arguments: ["window", "focus", opaque])
                }
                await self?.scheduleDebouncedRefresh(delayMs: 45)
            }

        case .moveSpecificWindow(let winID, let fromSpace, let toSpace, let follow):
            guard fromSpace != toSpace else { return }
            let priorActiveSpace = activeWorkspaceNumber ?? spaces.first(where: \.isActive)?.number ?? fromSpace
            let knownOpaque = opaqueIDByWindowID[winID]
            optimisticallyMoveWindow(windowID: winID, fromSpace: fromSpace, toSpace: toSpace, follow: follow)

            Task.detached(priority: .userInitiated) { [weak self] in
                let opaque = knownOpaque ?? Self.lookupOpaqueIDSync(executable: execPath, windowID: winID)
                if let opaque {
                    _ = Self.runCommandSync(
                        executable: execPath,
                        arguments: ["window", "move-to-workspace", opaque, String(toSpace)]
                    )
                    if follow {
                        _ = Self.runCommandSync(executable: execPath, arguments: ["window", "focus", opaque])
                    } else {
                        _ = Self.runCommandSync(
                            executable: execPath,
                            arguments: ["command", "switch-workspace", String(priorActiveSpace)]
                        )
                    }
                } else {
                    _ = Self.runCommandSync(
                        executable: execPath,
                        arguments: ["command", "move-to-workspace", String(toSpace)]
                    )
                    let targetFocusSpace = follow ? toSpace : priorActiveSpace
                    _ = Self.runCommandSync(
                        executable: execPath,
                        arguments: ["command", "switch-workspace", String(targetFocusSpace)]
                    )
                }
                await self?.scheduleDebouncedRefresh(delayMs: 50)
            }

        case .focusWorkspace(let num):
            optimisticallyHighlight(workspaceNumber: num)
            Task.detached(priority: .userInitiated) { [weak self] in
                _ = Self.runCommandSync(
                    executable: execPath,
                    arguments: ["command", "switch-workspace", String(num)]
                )
                await self?.scheduleDebouncedRefresh(delayMs: 40)
            }

        case .sendFocusedWindow(let num):
            let priorActiveSpace = activeWorkspaceNumber ?? spaces.first(where: \.isActive)?.number ?? 1
            guard num != priorActiveSpace else { return }
            let focusedOpaque = focusedOpaqueWindowID
            Task.detached(priority: .userInitiated) { [weak self] in
                if let focusedOpaque {
                    _ = Self.runCommandSync(
                        executable: execPath,
                        arguments: ["window", "move-to-workspace", focusedOpaque, String(num)]
                    )
                } else {
                    _ = Self.runCommandSync(
                        executable: execPath,
                        arguments: ["command", "move-to-workspace", String(num)]
                    )
                }
                // Keep viewport on the current workspace ("人留原地") even when `followsWindowToMonitor = true`.
                _ = Self.runCommandSync(
                    executable: execPath,
                    arguments: ["command", "switch-workspace", String(priorActiveSpace)]
                )
                await self?.scheduleDebouncedRefresh(delayMs: 45)
            }

        case .moveAndFollowWindow(let num):
            optimisticallyHighlight(workspaceNumber: num)
            let focusedOpaque = focusedOpaqueWindowID
            Task.detached(priority: .userInitiated) { [weak self] in
                if let focusedOpaque {
                    _ = Self.runCommandSync(
                        executable: execPath,
                        arguments: ["window", "move-to-workspace", focusedOpaque, String(num)]
                    )
                    _ = Self.runCommandSync(
                        executable: execPath,
                        arguments: ["window", "focus", focusedOpaque]
                    )
                } else {
                    _ = Self.runCommandSync(
                        executable: execPath,
                        arguments: ["command", "move-to-workspace", String(num)]
                    )
                    _ = Self.runCommandSync(
                        executable: execPath,
                        arguments: ["command", "switch-workspace", String(num)]
                    )
                }
                await self?.scheduleDebouncedRefresh(delayMs: 45)
            }

        case .stepRelative(let north, let targetDisplayID):
            if let targetDisplayID,
               let dispSpaces = spacesByDisplayID[targetDisplayID],
               dispSpaces.count > 1,
               let activeIdx = dispSpaces.firstIndex(where: \.isActive) {
                let nextIdx = north
                    ? max(0, activeIdx - 1)
                    : min(dispSpaces.count - 1, activeIdx + 1)
                if nextIdx != activeIdx {
                    perform(.focusWorkspace(dispSpaces[nextIdx].number))
                    return
                }
            }
            let dir = north ? "prev" : "next"
            Task.detached(priority: .userInitiated) { [weak self] in
                _ = Self.runCommandSync(
                    executable: execPath,
                    arguments: ["command", "switch-workspace", dir]
                )
                await self?.scheduleDebouncedRefresh(delayMs: 40)
            }
        }
    }

    public func refreshNow() async {
        let execPath = omniwmctlPath
        let snapshot = await Task.detached(priority: .userInitiated) {
            let dispRaw = Self.runCommandSync(executable: execPath, arguments: ["query", "displays", "--json"])
            let activeRaw = Self.runCommandSync(executable: execPath, arguments: ["query", "active-workspace", "--json"])
            let wsRaw = Self.runCommandSync(executable: execPath, arguments: ["query", "workspaces", "--json"])
            let winRaw = Self.runCommandSync(executable: execPath, arguments: ["query", "windows", "--json"])
            return (dispRaw, activeRaw, wsRaw, winRaw)
        }.value

        let decoder = JSONDecoder()
        var gotAny = false

        for raw in [snapshot.0, snapshot.1, snapshot.2, snapshot.3] {
            if let data = raw,
               let env = try? decoder.decode(OmniWMStreamEnvelope.self, from: data),
               env.ok == true,
               let body = env.result {
                applyResultBody(body, reproject: false)
                gotAny = true
            }
        }

        isConnected = gotAny
        if gotAny {
            reprojectSpaces()
        }
    }

    public func scheduleDebouncedRefresh(delayMs: Int = 60) {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(delayMs))
            guard !Task.isCancelled else { return }
            await self?.refreshNow()
        }
    }

    // MARK: - Stream & In-Memory State Projection

    private func handleEventLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(OmniWMStreamEnvelope.self, from: data),
              envelope.ok == true,
              let body = envelope.result else {
            return
        }
        isConnected = true
        applyResultBody(body, reproject: true)
    }

    private func applyResultBody(_ body: OmniWMResultBody, reproject: Bool) {
        switch body.kind {
        case "active-workspace":
            if let payload = body.activeWorkspacePayload {
                if let disp = payload.display {
                    if let refID = disp.id { activeDisplayRefID = refID }
                    if let cgID = disp.cgDisplayID {
                        activeDisplayID = cgID
                        if let num = payload.workspace?.resolvedNumber {
                            activeWorkspaceByDisplayID[cgID] = num
                        }
                    }
                }
                if let num = payload.workspace?.resolvedNumber {
                    activeWorkspaceNumber = num
                }
            }

        case "focused-monitor":
            if let payload = body.focusedMonitorPayload {
                if let disp = payload.display {
                    if let refID = disp.id { activeDisplayRefID = refID }
                    if let cgID = disp.cgDisplayID {
                        activeDisplayID = cgID
                        if let num = payload.activeWorkspace?.resolvedNumber {
                            activeWorkspaceByDisplayID[cgID] = num
                        }
                    }
                }
                if let num = payload.activeWorkspace?.resolvedNumber {
                    activeWorkspaceNumber = num
                }
            }

        case "focused-window":
            if let payload = body.focusedWindowPayload {
                let newFocusedOpaque = payload.window?.id
                focusedOpaqueWindowID = newFocusedOpaque
                if let win = payload.window {
                    opaqueIDByWindowID[win.resolvedWindowID] = win.id
                    if let disp = win.display {
                        if let refID = disp.id { activeDisplayRefID = refID }
                        if let cgID = disp.cgDisplayID {
                            activeDisplayID = cgID
                            if let wsNum = win.workspace?.resolvedNumber {
                                activeWorkspaceByDisplayID[cgID] = wsNum
                            }
                        }
                    }
                    if let wsNum = win.workspace?.resolvedNumber {
                        activeWorkspaceNumber = wsNum
                    }
                }
                for idx in cachedWindows.indices {
                    cachedWindows[idx].isFocused = (cachedWindows[idx].id == newFocusedOpaque)
                }
            }

        case "windows":
            if let payload = body.windowsPayload {
                cachedWindows = payload.windows
                var map: [Int: String] = [:]
                map.reserveCapacity(payload.windows.count)
                for win in payload.windows {
                    map[win.resolvedWindowID] = win.id
                    if win.isFocused == true {
                        focusedOpaqueWindowID = win.id
                    }
                }
                opaqueIDByWindowID = map
            }

        case "workspaces":
            if let payload = body.workspacesPayload {
                cachedWorkspaces = payload.workspaces
                for ws in payload.workspaces {
                    if (ws.isVisible == true || ws.isCurrent == true || ws.isFocused == true),
                       let cgID = ws.display?.cgDisplayID,
                       let wsNum = ws.resolvedNumber {
                        activeWorkspaceByDisplayID[cgID] = wsNum
                    }
                }
                if let focusedWS = payload.workspaces.first(where: { $0.isFocused == true })
                    ?? payload.workspaces.first(where: {
                        if let activeDisplayRefID, let dispID = $0.display?.id {
                            return dispID == activeDisplayRefID && ($0.isCurrent == true)
                        }
                        return $0.isCurrent == true
                    }) {
                    if let num = focusedWS.resolvedNumber {
                        activeWorkspaceNumber = num
                    }
                    if let disp = focusedWS.display {
                        if let refID = disp.id { activeDisplayRefID = refID }
                        if let cgID = disp.cgDisplayID {
                            activeDisplayID = cgID
                            if let num = focusedWS.resolvedNumber {
                                activeWorkspaceByDisplayID[cgID] = num
                            }
                        }
                    }
                    if let fw = focusedWS.focusedWindowId {
                        focusedOpaqueWindowID = fw
                        for idx in cachedWindows.indices {
                            cachedWindows[idx].isFocused = (cachedWindows[idx].id == fw)
                        }
                    }
                }
            }

        case "displays":
            if let payload = body.displaysPayload {
                cachedDisplays = payload.displays
                for disp in payload.displays {
                    if let cgID = disp.cgDisplayID,
                       let num = disp.activeWorkspace?.resolvedNumber {
                        activeWorkspaceByDisplayID[cgID] = num
                    }
                }
                if let currentDisp = payload.displays.first(where: { $0.isCurrent == true })
                    ?? payload.displays.first(where: { $0.isMain == true })
                    ?? payload.displays.first {
                    activeDisplayRefID = currentDisp.id
                    if let cgID = currentDisp.cgDisplayID {
                        activeDisplayID = cgID
                    }
                    if let num = currentDisp.activeWorkspace?.resolvedNumber {
                        activeWorkspaceNumber = num
                    }
                }
            }

        default:
            return
        }

        if reproject {
            reprojectSpaces()
        }
    }

    private func reprojectSpaces() {
        spaces = OmniWMStateProjector.project(
            workspaces: cachedWorkspaces,
            windows: cachedWindows,
            activeDisplayRefID: activeDisplayRefID,
            activeWorkspaceNumber: activeWorkspaceNumber,
            focusedOpaqueWindowID: focusedOpaqueWindowID,
            hideEmptyWorkspaces: hideEmptyWorkspaces
        )

        var knownDisplayIDs = Set<UInt32>()
        for screen in NSScreen.screens {
            knownDisplayIDs.insert(NotchGeometryResolver.displayID(for: screen))
        }
        for disp in cachedDisplays {
            if let cgID = disp.cgDisplayID { knownDisplayIDs.insert(cgID) }
        }
        for ws in cachedWorkspaces {
            if let cgID = ws.display?.cgDisplayID { knownDisplayIDs.insert(cgID) }
        }
        for win in cachedWindows {
            if let cgID = win.display?.cgDisplayID { knownDisplayIDs.insert(cgID) }
        }

        var byDisplay: [UInt32: [SpaceItemModel]] = [:]
        var nextNewByDisplay: [UInt32: Int] = [:]

        for cgID in knownDisplayIDs {
            let refID = "display:\(cgID)"
            let activeWSForDisp: Int? = {
                if activeDisplayRefID == refID, let activeWorkspaceNumber {
                    return activeWorkspaceNumber
                }
                if let known = activeWorkspaceByDisplayID[cgID] {
                    return known
                }
                if let fromDisp = cachedDisplays.first(where: { $0.cgDisplayID == cgID })?.activeWorkspace?.resolvedNumber {
                    return fromDisp
                }
                return cachedWorkspaces.first(where: {
                    $0.display?.id == refID && ($0.isFocused == true || $0.isCurrent == true || $0.isVisible == true)
                })?.resolvedNumber
            }()

            let projected = OmniWMStateProjector.project(
                workspaces: cachedWorkspaces,
                windows: cachedWindows,
                activeDisplayRefID: refID,
                activeWorkspaceNumber: activeWSForDisp,
                focusedOpaqueWindowID: focusedOpaqueWindowID,
                hideEmptyWorkspaces: hideEmptyWorkspaces
            )
            byDisplay[cgID] = projected

            let assignedNums = cachedWorkspaces
                .filter { $0.display?.id == refID }
                .compactMap(\.resolvedNumber)
                .sorted()
            let shownNums = Set(projected.map(\.number))
            let maxShown = shownNums.max() ?? 1
            if let nextAbove = assignedNums.first(where: { $0 > maxShown }) {
                nextNewByDisplay[cgID] = nextAbove
            } else if let firstUnused = assignedNums.first(where: { !shownNums.contains($0) }) {
                nextNewByDisplay[cgID] = firstUnused
            }
        }

        spacesByDisplayID = byDisplay
        nextNewSpaceByDisplayID = nextNewByDisplay
    }

    private func optimisticallyFocusWindow(windowID: Int) {
        if let opaque = opaqueIDByWindowID[windowID] {
            focusedOpaqueWindowID = opaque
            for idx in cachedWindows.indices {
                cachedWindows[idx].isFocused = (cachedWindows[idx].id == opaque)
            }
        }
        Self.applyOptimisticWindowFocus(windowID: windowID, in: &spaces)
        for key in spacesByDisplayID.keys {
            if var list = spacesByDisplayID[key] {
                Self.applyOptimisticWindowFocus(windowID: windowID, in: &list)
                spacesByDisplayID[key] = list
            }
        }
    }

    private static func applyOptimisticWindowFocus(windowID: Int, in spaceList: inout [SpaceItemModel]) {
        for sIdx in spaceList.indices {
            guard let targetWin = spaceList[sIdx].windows.first(where: { $0.windowID == windowID }) else { continue }
            let targetCol = targetWin.columnIndex
            for wIdx in spaceList[sIdx].windows.indices {
                let isThisWin = spaceList[sIdx].windows[wIdx].windowID == windowID
                let inCol = isThisWin || (targetCol != nil && spaceList[sIdx].windows[wIdx].columnIndex == targetCol)
                spaceList[sIdx].windows[wIdx].isFocused = isThisWin
                spaceList[sIdx].windows[wIdx].isInFocusedColumn = inCol
            }
        }
    }

    private func optimisticallyHighlight(workspaceNumber: Int) {
        activeWorkspaceNumber = workspaceNumber
        let targetDisplayID: UInt32? = cachedWorkspaces
            .first(where: { $0.resolvedNumber == workspaceNumber })?
            .display?.cgDisplayID
            ?? spacesByDisplayID.first(where: { $0.value.contains(where: { $0.number == workspaceNumber }) })?.key
            ?? activeDisplayID

        if let targetDisplayID {
            activeWorkspaceByDisplayID[targetDisplayID] = workspaceNumber
            if var dispSpaces = spacesByDisplayID[targetDisplayID] {
                if dispSpaces.contains(where: { $0.number == workspaceNumber }) {
                    for idx in dispSpaces.indices {
                        dispSpaces[idx].isActive = (dispSpaces[idx].number == workspaceNumber)
                    }
                } else {
                    for idx in dispSpaces.indices {
                        dispSpaces[idx].isActive = false
                    }
                    dispSpaces.append(SpaceItemModel(number: workspaceNumber, isActive: true, windows: []))
                    dispSpaces.sort { $0.number < $1.number }
                }
                spacesByDisplayID[targetDisplayID] = dispSpaces
            }
        }

        if spaces.contains(where: { $0.number == workspaceNumber }) {
            for idx in spaces.indices {
                spaces[idx].isActive = (spaces[idx].number == workspaceNumber)
            }
        } else if targetDisplayID == nil || targetDisplayID == activeDisplayID {
            for idx in spaces.indices {
                spaces[idx].isActive = false
            }
            spaces.append(SpaceItemModel(number: workspaceNumber, isActive: true, windows: []))
            spaces.sort { $0.number < $1.number }
        }
    }

    private func optimisticallyMoveWindow(
        windowID: Int,
        fromSpace: Int,
        toSpace: Int,
        follow: Bool
    ) {
        var movedItem: SpaceWindowIconItem?

        for (dispID, var dispSpaces) in spacesByDisplayID {
            if let srcIdx = dispSpaces.firstIndex(where: { $0.number == fromSpace }),
               let winPos = dispSpaces[srcIdx].windows.firstIndex(where: { $0.windowID == windowID }) {
                movedItem = dispSpaces[srcIdx].windows.remove(at: winPos)
                spacesByDisplayID[dispID] = dispSpaces
                break
            }
        }

        if let srcIdx = spaces.firstIndex(where: { $0.number == fromSpace }),
           let winPos = spaces[srcIdx].windows.firstIndex(where: { $0.windowID == windowID }) {
            let item = spaces[srcIdx].windows.remove(at: winPos)
            if movedItem == nil { movedItem = item }
        }

        guard let item = movedItem else { return }

        let targetDisplayID: UInt32? = cachedWorkspaces
            .first(where: { $0.resolvedNumber == toSpace })?
            .display?.cgDisplayID
            ?? spacesByDisplayID.first(where: { $0.value.contains(where: { $0.number == toSpace }) })?.key
            ?? activeDisplayID

        if let targetDisplayID, var dstSpaces = spacesByDisplayID[targetDisplayID] {
            if let dstIdx = dstSpaces.firstIndex(where: { $0.number == toSpace }) {
                dstSpaces[dstIdx].windows.append(item)
            } else {
                dstSpaces.append(SpaceItemModel(number: toSpace, isActive: follow, windows: [item]))
                dstSpaces.sort { $0.number < $1.number }
            }
            spacesByDisplayID[targetDisplayID] = dstSpaces
        }

        if let dstIdx = spaces.firstIndex(where: { $0.number == toSpace }) {
            spaces[dstIdx].windows.append(item)
        } else if targetDisplayID == activeDisplayID {
            spaces.append(SpaceItemModel(number: toSpace, isActive: follow, windows: [item]))
            spaces.sort { $0.number < $1.number }
        }

        if follow {
            optimisticallyHighlight(workspaceNumber: toSpace)
        }
    }

    private func subscribeLoop() async {
        let execPath = omniwmctlPath
        let channels = "focus,active-workspace,focused-monitor,windows-changed,display-changed,layout-changed"

        while !Task.isCancelled {
            guard FileManager.default.isExecutableFile(atPath: execPath) else {
                isConnected = false
                try? await Task.sleep(for: .seconds(3))
                continue
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: execPath)
            process.arguments = ["subscribe", channels, "--reconnect", "--format", "ndjson"]
            let stdoutPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                activeProcess = process

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
                isConnected = false
                try? await Task.sleep(for: .milliseconds(1200))
            }
        }
    }

    nonisolated private static func lookupOpaqueIDSync(executable: String, windowID: Int) -> String? {
        guard let data = runCommandSync(executable: executable, arguments: ["query", "windows", "--json"]),
              let env = try? JSONDecoder().decode(OmniWMStreamEnvelope.self, from: data),
              let wins = env.result?.windowsPayload?.windows else {
            return nil
        }
        return wins.first(where: { $0.resolvedWindowID == windowID })?.id
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
