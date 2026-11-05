import Foundation

// MARK: - OmniWM IPC Envelope & Models

public struct OmniWMStreamEnvelope: Decodable, Sendable {
    public let ok: Bool?
    public let kind: String?
    public let channel: String?
    public let status: String?
    public let result: OmniWMResultBody?
}

public struct OmniWMResultBody: Decodable, Sendable {
    public let kind: String
    public let windowsPayload: OmniWMWindowsPayload?
    public let workspacesPayload: OmniWMWorkspacesPayload?
    public let displaysPayload: OmniWMDisplaysPayload?
    public let activeWorkspacePayload: OmniWMActiveWorkspacePayload?
    public let focusedMonitorPayload: OmniWMFocusedMonitorPayload?
    public let focusedWindowPayload: OmniWMFocusedWindowPayload?

    private enum CodingKeys: String, CodingKey {
        case kind
        case payload
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        self.kind = kind

        var wp: OmniWMWindowsPayload?
        var wsp: OmniWMWorkspacesPayload?
        var dp: OmniWMDisplaysPayload?
        var awp: OmniWMActiveWorkspacePayload?
        var fmp: OmniWMFocusedMonitorPayload?
        var fwp: OmniWMFocusedWindowPayload?

        switch kind {
        case "windows":
            wp = try? c.decodeIfPresent(OmniWMWindowsPayload.self, forKey: .payload)
        case "workspaces":
            wsp = try? c.decodeIfPresent(OmniWMWorkspacesPayload.self, forKey: .payload)
        case "displays":
            dp = try? c.decodeIfPresent(OmniWMDisplaysPayload.self, forKey: .payload)
        case "active-workspace":
            awp = try? c.decodeIfPresent(OmniWMActiveWorkspacePayload.self, forKey: .payload)
        case "focused-monitor":
            fmp = try? c.decodeIfPresent(OmniWMFocusedMonitorPayload.self, forKey: .payload)
        case "focused-window":
            fwp = try? c.decodeIfPresent(OmniWMFocusedWindowPayload.self, forKey: .payload)
        default:
            break
        }

        self.windowsPayload = wp
        self.workspacesPayload = wsp
        self.displaysPayload = dp
        self.activeWorkspacePayload = awp
        self.focusedMonitorPayload = fmp
        self.focusedWindowPayload = fwp
    }
}

public struct OmniWMAppRef: Codable, Equatable, Sendable {
    public let bundleId: String?
    public let name: String?
}

public struct OmniWMDisplayRef: Codable, Equatable, Sendable {
    public let id: String?
    public let isMain: Bool?
    public let name: String?

    public var cgDisplayID: UInt32? {
        guard let id else { return nil }
        if id.hasPrefix("display:"),
           let parsed = UInt32(id.dropFirst("display:".count)) {
            return parsed
        }
        return UInt32(id)
    }
}

public struct OmniWMWorkspaceRef: Codable, Equatable, Sendable {
    public let id: String?
    public let number: Int?
    public let rawName: String?
    public let displayName: String?

    public var resolvedNumber: Int? {
        if let number { return number }
        if let rawName, let n = Int(rawName) { return n }
        return nil
    }
}

public struct OmniWMWindowFrame: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
}

public struct OmniWMWindow: Codable, Equatable, Sendable {
    public let id: String
    public let windowId: Int?
    public let pid: Int?
    public let app: OmniWMAppRef?
    public let title: String?
    public let columnIndex: Int?
    public let frame: OmniWMWindowFrame?
    public let mode: String?
    public var isFocused: Bool?
    public let isFullscreen: Bool?
    public let isScratchpad: Bool?
    public let isAppHidden: Bool?
    public let isVisible: Bool?
    public let display: OmniWMDisplayRef?
    public let workspace: OmniWMWorkspaceRef?

    /// Resolves a stable integer Window ID for NotchSpace UI tracking.
    /// Prefers `windowId` (CGWindowID); falls back to parsing the trailing `:windowId` in OmniWM's base64url token or hash.
    public var resolvedWindowID: Int {
        if let windowId { return windowId }
        if let decoded = Self.extractWindowIDFromOpaqueToken(id) {
            return decoded
        }
        return abs(id.hashValue)
    }

    private static func extractWindowIDFromOpaqueToken(_ opaqueID: String) -> Int? {
        guard opaqueID.hasPrefix("ow_") else { return nil }
        var b64 = String(opaqueID.dropFirst(3))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let rem = b64.count % 4
        if rem > 0 {
            b64 += String(repeating: "=", count: 4 - rem)
        }
        guard let data = Data(base64Encoded: b64),
              let str = String(data: data, encoding: .utf8),
              let lastColon = str.lastIndex(of: ":"),
              let parsed = Int(str[str.index(after: lastColon)...]) else {
            return nil
        }
        return parsed
    }
}

public struct OmniWMWorkspaceCounts: Codable, Equatable, Sendable {
    public let tiled: Int?
    public let floating: Int?
    public let scratchpad: Int?
    public let total: Int?
}

public struct OmniWMWorkspace: Codable, Equatable, Sendable {
    public let id: String
    public let number: Int?
    public let rawName: String?
    public let displayName: String?
    public let layout: String?
    public let isCurrent: Bool?
    public let isFocused: Bool?
    public let isVisible: Bool?
    public let focusedWindowId: String?
    public let display: OmniWMDisplayRef?
    public let counts: OmniWMWorkspaceCounts?

    public var resolvedNumber: Int? {
        if let number { return number }
        if let rawName, let n = Int(rawName) { return n }
        return nil
    }
}

public struct OmniWMDisplaySnapshot: Codable, Equatable, Sendable {
    public let id: String
    public let name: String?
    public let isMain: Bool?
    public let isCurrent: Bool?
    public let hasNotch: Bool?
    public let activeWorkspace: OmniWMWorkspaceRef?

    public var cgDisplayID: UInt32? {
        if id.hasPrefix("display:"),
           let parsed = UInt32(id.dropFirst("display:".count)) {
            return parsed
        }
        return UInt32(id)
    }
}

public struct OmniWMWindowsPayload: Decodable, Sendable {
    public let windows: [OmniWMWindow]
}

public struct OmniWMWorkspacesPayload: Decodable, Sendable {
    public let workspaces: [OmniWMWorkspace]
}

public struct OmniWMDisplaysPayload: Decodable, Sendable {
    public let displays: [OmniWMDisplaySnapshot]
}

public struct OmniWMActiveWorkspacePayload: Decodable, Sendable {
    public let display: OmniWMDisplayRef?
    public let focusedApp: OmniWMAppRef?
    public let workspace: OmniWMWorkspaceRef?
}

public struct OmniWMFocusedMonitorPayload: Decodable, Sendable {
    public let display: OmniWMDisplayRef?
    public let activeWorkspace: OmniWMWorkspaceRef?
}

public struct OmniWMFocusedWindowPayload: Decodable, Sendable {
    public let window: OmniWMWindow?
}

// MARK: - OmniWM State Projector

public enum OmniWMStateProjector {
    /// Projects OmniWM workspaces and windows into ordered `SpaceItemModel` items.
    /// Because OmniWM statically defines workspaces 1..9 in `settings.toml`, trailing unused empty workspaces
    /// beyond `max(activeSpace, highestOccupiedSpace)` are trimmed when `hideEmptyWorkspaces == false` so the
    /// capsule stays compact and dragging an app reveals the `+` new-workspace drop target naturally.
    public static func project(
        workspaces: [OmniWMWorkspace],
        windows: [OmniWMWindow],
        activeDisplayRefID: String?,
        activeWorkspaceNumber: Int?,
        hideEmptyWorkspaces: Bool
    ) -> [SpaceItemModel] {
        let displayWorkspaces = workspaces
            .filter { ws in
                guard ws.resolvedNumber != nil else { return false }
                guard let activeDisplayRefID, let wsDisplayID = ws.display?.id else { return true }
                return wsDisplayID == activeDisplayRefID
            }
            .sorted { ($0.resolvedNumber ?? 0) < ($1.resolvedNumber ?? 0) }

        var windowsBySpace: [Int: [OmniWMWindow]] = [:]
        for win in windows {
            guard !(win.isScratchpad ?? false) else { continue }
            guard (win.mode ?? "tiling") == "tiling" else { continue }
            if let activeDisplayRefID,
               let winDisplayID = win.display?.id,
               winDisplayID != activeDisplayRefID {
                continue
            }
            guard let spaceNum = win.workspace?.resolvedNumber else { continue }
            windowsBySpace[spaceNum, default: []].append(win)
        }

        let resolvedActiveNum: Int = activeWorkspaceNumber
            ?? displayWorkspaces.first(where: { $0.isFocused == true })?.resolvedNumber
            ?? displayWorkspaces.first(where: { $0.isCurrent == true })?.resolvedNumber
            ?? 1

        let highestOccupied = windowsBySpace
            .filter { !$0.value.isEmpty }
            .keys
            .max() ?? 1
        let maxVisibleWhenNotHidingEmpty = max(resolvedActiveNum, highestOccupied)

        var candidateNumbers: [Int] = displayWorkspaces.compactMap(\.resolvedNumber)
        for occupiedKey in windowsBySpace.keys where !candidateNumbers.contains(occupiedKey) {
            candidateNumbers.append(occupiedKey)
        }
        if !candidateNumbers.contains(resolvedActiveNum) {
            candidateNumbers.append(resolvedActiveNum)
        }
        candidateNumbers.sort()

        var result: [SpaceItemModel] = []
        result.reserveCapacity(candidateNumbers.count)

        for num in candidateNumbers {
            let isActive = (num == resolvedActiveNum)
            let rawWins = windowsBySpace[num] ?? []
            let items = orderedWindows(in: rawWins)

            if hideEmptyWorkspaces {
                if items.isEmpty && !isActive {
                    continue
                }
            } else {
                if items.isEmpty && !isActive && num > maxVisibleWhenNotHidingEmpty {
                    continue
                }
            }

            result.append(
                SpaceItemModel(
                    number: num,
                    isActive: isActive,
                    windows: items
                )
            )
        }

        if result.isEmpty {
            result.append(SpaceItemModel(number: resolvedActiveNum, isActive: true, windows: []))
        }

        return result
    }

    private static func orderedWindows(in rawWindows: [OmniWMWindow]) -> [SpaceWindowIconItem] {
        guard !rawWindows.isEmpty else { return [] }

        // Swift's `.sorted(by:)` is guaranteed stable, preserving OmniWM's top-to-bottom column row order
        // when two stacked windows share the same 1-based `columnIndex`.
        let ordered = rawWindows.sorted { lhs, rhs in
            let lc = lhs.columnIndex ?? Int.max
            let rc = rhs.columnIndex ?? Int.max
            if lc != rc { return lc < rc }
            return false
        }

        return ordered.map { win in
            SpaceWindowIconItem(
                windowID: win.resolvedWindowID,
                bundleID: win.app?.bundleId ?? "",
                appName: win.app?.name ?? "",
                isFocused: win.isFocused ?? false
            )
        }
    }
}
