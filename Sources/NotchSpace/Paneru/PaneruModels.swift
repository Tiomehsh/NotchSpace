import Foundation

public struct PaneruStateDocument: Codable, Sendable {
    public let version: Int?
    public let timestamp: Int?
    public let active: PaneruActiveState
    public let virtual_workspaces: [PaneruVirtualWorkspace]
}

public struct PaneruActiveState: Codable, Equatable, Sendable {
    public let display_id: UInt32?
    public let native_workspace_id: Int?
    public let virtual_workspace_number: Int?
    public let focused_window_id: Int?
    public let focused_bundle_id: String?
    public let focused_app_name: String?
    public let focused_window_title: String?
}

public struct PaneruVirtualWorkspace: Codable, Sendable {
    public let number: Int
    public let native_workspace_id: Int?
    public let active: Bool?
    public let windows: [PaneruWindow]
}

public struct PaneruWindowFrame: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
}

public struct PaneruWindow: Codable, Sendable {
    public let window_id: Int
    public let display_id: UInt32?
    public let bundle_id: String?
    public let app_name: String?
    public let title: String?
    public let focused: Bool?
    public let floating: Bool?
    public let column: Int?
    public let row: Int?
    public let frame: PaneruWindowFrame?
}

public struct PaneruSubscribeEvent: Codable, Sendable {
    public let event: String
    public let virtual_workspace_number: Int?
    public let active: PaneruActiveState?
}

// MARK: - View Presentation Models

public struct SpaceWindowIconItem: Identifiable, Equatable, Sendable {
    public var id: Int { windowID }
    public let windowID: Int
    public let bundleID: String
    public let appName: String
    public var isFocused: Bool
    public var isInFocusedColumn: Bool
    public let columnIndex: Int?

    public init(
        windowID: Int,
        bundleID: String,
        appName: String,
        isFocused: Bool,
        isInFocusedColumn: Bool? = nil,
        columnIndex: Int? = nil
    ) {
        self.windowID = windowID
        self.bundleID = bundleID
        self.appName = appName
        self.isFocused = isFocused
        self.isInFocusedColumn = isInFocusedColumn ?? isFocused
        self.columnIndex = columnIndex
    }
}

public struct SpaceItemModel: Identifiable, Equatable, Sendable {
    public var id: Int { number }
    public let number: Int
    public var isActive: Bool
    public var windows: [SpaceWindowIconItem]

    public var isEmpty: Bool { windows.isEmpty }
}

public enum PaneruStateProjector {
    /// Projects raw Paneru JSON state into ordered workspace items preserving all managed windows.
    /// Active workspace displays windows expanded left-to-right; inactive workspaces stack them compactly.
    public static func project(
        document: PaneruStateDocument,
        targetNativeWorkspaceID: Int? = nil,
        activeVirtualOverride: Int? = nil,
        hideEmptyWorkspaces: Bool
    ) -> [SpaceItemModel] {
        let activeNative = targetNativeWorkspaceID ?? document.active.native_workspace_id
        let isTargetingActiveNative = (activeNative == document.active.native_workspace_id)
        let activeVirtual = activeVirtualOverride
            ?? (isTargetingActiveNative ? document.active.virtual_workspace_number : nil)

        let filteredWorkspaces = document.virtual_workspaces
            .filter { ws in
                guard let activeNative, let wsNative = ws.native_workspace_id else { return true }
                return wsNative == activeNative
            }
            .sorted { $0.number < $1.number }

        var result: [SpaceItemModel] = []
        result.reserveCapacity(filteredWorkspaces.count)

        for ws in filteredWorkspaces {
            let isActive = (ws.number == activeVirtual) || (ws.active == true && activeVirtual == nil)
            let items = orderedWindows(
                in: ws.windows,
                isWorkspaceActive: isActive,
                activeFocusedWindowID: (isActive && isTargetingActiveNative) ? document.active.focused_window_id : nil
            )

            if hideEmptyWorkspaces && items.isEmpty && !isActive {
                continue
            }

            result.append(
                SpaceItemModel(
                    number: ws.number,
                    isActive: isActive,
                    windows: items
                )
            )
        }

        if result.isEmpty {
            result.append(SpaceItemModel(number: activeVirtual ?? 1, isActive: true, windows: []))
        }

        return result
    }

    private static func orderedWindows(
        in rawWindows: [PaneruWindow],
        isWorkspaceActive: Bool,
        activeFocusedWindowID: Int?
    ) -> [SpaceWindowIconItem] {
        let tiled = rawWindows.filter { !($0.floating ?? false) }
        guard !tiled.isEmpty else { return [] }

        let ordered: [PaneruWindow]
        if tiled.allSatisfy({ $0.column != nil }) {
            ordered = tiled.sorted { lhs, rhs in
                let lc = lhs.column ?? 0
                let rc = rhs.column ?? 0
                if lc != rc { return lc < rc }
                return (lhs.row ?? 0) < (rhs.row ?? 0)
            }
        } else if isWorkspaceActive {
            // On the active workspace, window frames reflect true on-screen column coordinates.
            ordered = tiled.sorted { lhs, rhs in
                let lx = lhs.frame?.x ?? 0
                let rx = rhs.frame?.x ?? 0
                if abs(lx - rx) > 8.0 { return lx < rx }
                return (lhs.frame?.y ?? 0) < (rhs.frame?.y ?? 0)
            }
        } else {
            // On inactive workspaces, Paneru parks all windows in a sliver at the screen corner
            // (so frame.x values are nearly identical). Preserve Paneru's strip order directly
            // so every window in the workspace is retained for stacked rendering.
            ordered = tiled
        }

        // Resolve column indices (explicit `column` if provided by Paneru, or grouped by `frame.x` on active space)
        var resolvedColumns: [Int] = []
        resolvedColumns.reserveCapacity(ordered.count)
        var currentSyntheticCol = 1
        var lastX: Double?

        for (idx, win) in ordered.enumerated() {
            if let explicitCol = win.column {
                resolvedColumns.append(explicitCol)
            } else if isWorkspaceActive, let wx = win.frame?.x {
                if let prevX = lastX, abs(wx - prevX) > 8.0 {
                    currentSyntheticCol += 1
                }
                lastX = wx
                resolvedColumns.append(currentSyntheticCol)
            } else {
                resolvedColumns.append(idx + 1)
            }
        }

        let focusedIdx = ordered.firstIndex { win in
            (win.focused == true) || (activeFocusedWindowID != nil && win.window_id == activeFocusedWindowID)
        }
        let focusedCol: Int? = focusedIdx.map { resolvedColumns[$0] }

        return ordered.enumerated().map { idx, win in
            let colIdx = resolvedColumns[idx]
            let isWinFocused = (idx == focusedIdx) || (focusedIdx == nil && (win.focused ?? false))
            let inFocusedCol = isWinFocused || (focusedCol != nil && colIdx == focusedCol)
            return SpaceWindowIconItem(
                windowID: win.window_id,
                bundleID: win.bundle_id ?? "",
                appName: win.app_name ?? "",
                isFocused: isWinFocused,
                isInFocusedColumn: inFocusedCol,
                columnIndex: colIdx
            )
        }
    }
}
