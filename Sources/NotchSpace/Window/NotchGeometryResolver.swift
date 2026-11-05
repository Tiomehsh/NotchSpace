import AppKit
import CoreGraphics
import Foundation

public enum DragSnapKind: Equatable, Sendable {
    case none
    case notchBottomCenter
    case statusBarInsideVertical
    case statusBarBelowVertical
}

public enum NotchGeometryResolver {
    /// Generous transparent canvas margins around the resting capsule so Dock-style fluid hover magnification,
    /// the right-side dynamic drag handle, New Space (`+`) drop target, and dragged App glass badges animate
    /// at 120fps purely inside SwiftUI without resizing the NSPanel.
    public static let panelHorizontalMargin: CGFloat = 76.0
    public static let panelVerticalMargin: CGFloat = 28.0

    public static func displayID(for screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID)
            ?? CGMainDisplayID()
    }

    public static func displayUUID(for screen: NSScreen) -> String {
        let id = displayID(for: screen)
        if let uuidRef = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
           let str = CFUUIDCreateString(nil, uuidRef) as String? {
            return str
        }
        return "display-\(id)"
    }

    public static func hasHardwareNotch(_ screen: NSScreen) -> Bool {
        screen.safeAreaInsets.top > 0
            && screen.auxiliaryTopLeftArea != nil
            && screen.auxiliaryTopRightArea != nil
    }

    public static func notchRect(for screen: NSScreen) -> NSRect? {
        guard hasHardwareNotch(screen),
              let leftArea = screen.auxiliaryTopLeftArea,
              let rightArea = screen.auxiliaryTopRightArea else {
            return nil
        }
        let notchMinX = leftArea.maxX
        let notchMaxX = rightArea.minX
        let width = max(120, notchMaxX - notchMinX)
        let height = screen.safeAreaInsets.top
        return NSRect(
            x: notchMinX,
            y: screen.frame.maxY - height,
            width: width,
            height: height
        )
    }

    public static func menuBarHeight(for screen: NSScreen) -> CGFloat {
        let diff = screen.frame.maxY - screen.visibleFrame.maxY
        if diff > 1 {
            return diff
        }
        return NSStatusBar.system.thickness
    }

    /// Returns the visual height of the top bar corridor (from `screen.frame.maxY` down to the top edge
    /// of tiled windows just below the menu bar, or `menuBarHeight + 3pt` when no window sits near the bar),
    /// so snapping inside the status bar centers the capsule with equal top & bottom breathing room.
    public static func statusBarVisualCorridorHeight(for screen: NSScreen) -> CGFloat {
        let mbHeight = menuBarHeight(for: screen)
        guard let primaryScreenHeight = NSScreen.screens.first?.frame.height else {
            return mbHeight + 3.0
        }
        // Convert `screen.frame.maxY` (AppKit bottom-left origin) into CoreGraphics global Y (primary top-left origin)
        let screenTopCGY = primaryScreenHeight - screen.frame.maxY

        let opts = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .excludeDesktopElements)
        if let infoList = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] {
            var nearestWindowOffset: CGFloat?
            for info in infoList {
                guard (info[kCGWindowLayer as String] as? Int) == 0,
                      let boundsDict = info[kCGWindowBounds as String] as? NSDictionary else {
                    continue
                }
                var cgRect = CGRect.zero
                guard CGRectMakeWithDictionaryRepresentation(boundsDict, &cgRect),
                      cgRect.width >= 200,
                      cgRect.height >= 120 else {
                    continue
                }
                // Check horizontal overlap with this screen
                let overlapX = min(cgRect.maxX, screen.frame.maxX) - max(cgRect.minX, screen.frame.minX)
                guard overlapX > 80 else { continue }

                let offsetFromScreenTop = cgRect.minY - screenTopCGY
                if offsetFromScreenTop >= mbHeight - 1.0 && offsetFromScreenTop <= mbHeight + 16.0 {
                    if let cur = nearestWindowOffset {
                        nearestWindowOffset = min(cur, offsetFromScreenTop)
                    } else {
                        nearestWindowOffset = offsetFromScreenTop
                    }
                }
            }
            if let nearestWindowOffset {
                return nearestWindowOffset
            }
        }
        return mbHeight + 3.0
    }

    /// Top Y (in AppKit screen coordinates) that vertically centers `capsuleSize` inside the status bar corridor.
    public static func statusBarInsideCenteredTopY(capsuleSize: NSSize, on screen: NSScreen) -> CGFloat {
        let corridorHeight = statusBarVisualCorridorHeight(for: screen)
        let topMargin = max(2.0, round((corridorHeight - capsuleSize.height) / 2.0 * 2.0) / 2.0)
        return screen.frame.maxY - topMargin
    }

    /// Computes `(centerX, topY)` of the resting visible capsule in global AppKit coordinates.
    public static func resolveCapsuleAnchorPoint(
        placement: DisplayPlacement,
        capsuleSize: NSSize,
        on screen: NSScreen
    ) -> (centerX: CGFloat, topY: CGFloat) {
        let frame = screen.frame
        let mbHeight = menuBarHeight(for: screen)

        let rawCenterX: CGFloat
        let rawTopY: CGFloat

        switch placement.anchor {
        case .notchOrMenuBarBottomCenter:
            if let notch = notchRect(for: screen) {
                rawCenterX = notch.midX + CGFloat(placement.offsetX)
                rawTopY = notch.minY - CGFloat(placement.offsetY)
            } else {
                rawCenterX = frame.midX + CGFloat(placement.offsetX)
                rawTopY = (frame.maxY - mbHeight) - CGFloat(placement.offsetY)
            }

        case .menuBarInsideCenter:
            let verticalCenterTop = statusBarInsideCenteredTopY(capsuleSize: capsuleSize, on: screen)
            rawCenterX = frame.midX + CGFloat(placement.offsetX)
            rawTopY = verticalCenterTop - CGFloat(placement.offsetY)

        case .topLeading:
            rawCenterX = frame.minX + 16.0 + capsuleSize.width / 2.0 + CGFloat(placement.offsetX)
            rawTopY = (frame.maxY - mbHeight) - 6.0 - CGFloat(placement.offsetY)

        case .topTrailing:
            rawCenterX = frame.maxX - 16.0 - capsuleSize.width / 2.0 + CGFloat(placement.offsetX)
            rawTopY = (frame.maxY - mbHeight) - 6.0 - CGFloat(placement.offsetY)

        case .custom:
            rawCenterX = frame.midX + CGFloat(placement.offsetX)
            rawTopY = frame.maxY - CGFloat(placement.offsetY)
        }

        let halfW = capsuleSize.width / 2.0
        let minCenterX = frame.minX + halfW + 4.0
        let maxCenterX = frame.maxX - halfW - 4.0
        let clampedCenterX = min(max(rawCenterX, minCenterX), max(minCenterX, maxCenterX))

        let minTopY = frame.minY + capsuleSize.height + 4.0
        let maxTopY = frame.maxY
        let clampedTopY = min(max(rawTopY, minTopY), maxTopY)

        return (clampedCenterX, clampedTopY)
    }

    public static func panelFrame(
        capsuleCenterX: CGFloat,
        capsuleTopY: CGFloat,
        capsuleSize: NSSize
    ) -> NSRect {
        let mx = panelHorizontalMargin
        let my = panelVerticalMargin
        let panelWidth = capsuleSize.width + mx * 2
        let panelHeight = capsuleSize.height + my * 2
        let originX = round(capsuleCenterX - panelWidth / 2.0)
        let originY = round((capsuleTopY - capsuleSize.height) - my)
        return NSRect(x: originX, y: originY, width: panelWidth, height: panelHeight)
    }

    public static func evaluateDragPlacement(
        proposedPanelOrigin: NSPoint,
        capsuleSize: NSSize,
        dockedShape: DockedCapsuleShape,
        snapThreshold: CGFloat,
        preferredScreen: NSScreen? = nil
    ) -> (screen: NSScreen, placement: DisplayPlacement, snappedPanelOrigin: NSPoint, snapKind: DragSnapKind) {
        let mx = panelHorizontalMargin
        let my = panelVerticalMargin
        let capsuleCenterX = proposedPanelOrigin.x + mx + capsuleSize.width / 2.0
        let capsuleTopY = proposedPanelOrigin.y + my + capsuleSize.height

        let centerPoint = NSPoint(x: capsuleCenterX, y: capsuleTopY - capsuleSize.height / 2.0)
        let screen: NSScreen = {
            if let preferredScreen, NSScreen.screens.contains(preferredScreen) {
                return preferredScreen
            }
            return NSScreen.screens.first(where: { NSMouseInRect(centerPoint, $0.frame, false) })
                ?? NSScreen.main
                ?? NSScreen.screens[0]
        }()

        let notch = notchRect(for: screen)
        let hasNotch = notch != nil
        let mbHeight = menuBarHeight(for: screen)
        let statusBarBottomY = notch?.minY ?? (screen.frame.maxY - mbHeight)
        let defaultBottomGap: Double = (dockedShape == .notchChin && hasNotch) ? 0.0 : 4.0

        let clampedCenterX = min(
            max(capsuleCenterX, screen.frame.minX + capsuleSize.width / 2.0 + 4.0),
            screen.frame.maxX - capsuleSize.width / 2.0 - 4.0
        )

        let belowStatusBarTopY = statusBarBottomY - CGFloat(defaultBottomGap)
        let insideStatusBarTopY = statusBarInsideCenteredTopY(capsuleSize: capsuleSize, on: screen)

        // 1. Hardware Notch (or primary home) bottom-center pocket: snaps both X and Y right under the Notch.
        if let notch {
            if abs(clampedCenterX - notch.midX) <= snapThreshold,
               abs(capsuleTopY - belowStatusBarTopY) <= snapThreshold {
                let placement = DisplayPlacement(
                    anchor: .notchOrMenuBarBottomCenter,
                    offsetX: 0.0,
                    offsetY: defaultBottomGap
                )
                let frame = panelFrame(
                    capsuleCenterX: notch.midX,
                    capsuleTopY: belowStatusBarTopY,
                    capsuleSize: capsuleSize
                )
                return (screen, placement, frame.origin, .notchBottomCenter)
            }
        }

        // 2. Status bar INSIDE vertical snap rail (Y snaps to vertical center of status bar; X moves freely!).
        // On Notch displays, active on both the left and right status bar wings outside the camera cutout.
        let overlapsHardwareNotch: Bool = {
            guard let notch else { return false }
            let halfW = capsuleSize.width / 2.0
            return (clampedCenterX + halfW) > (notch.minX + 2.0)
                && (clampedCenterX - halfW) < (notch.maxX - 2.0)
        }()

        if !overlapsHardwareNotch,
           (abs(capsuleTopY - insideStatusBarTopY) <= snapThreshold || capsuleTopY >= insideStatusBarTopY) {
            let placement = DisplayPlacement(
                anchor: .menuBarInsideCenter,
                offsetX: Double(round((clampedCenterX - screen.frame.midX) * 2.0) / 2.0),
                offsetY: 0.0
            )
            let frame = panelFrame(
                capsuleCenterX: clampedCenterX,
                capsuleTopY: insideStatusBarTopY,
                capsuleSize: capsuleSize
            )
            return (screen, placement, frame.origin, .statusBarInsideVertical)
        }

        // 3. Status bar BELOW vertical snap rail (Y snaps cleanly right below the status bar; X moves freely!).
        if abs(capsuleTopY - belowStatusBarTopY) <= snapThreshold {
            let placement = DisplayPlacement(
                anchor: .custom,
                offsetX: Double(round((clampedCenterX - screen.frame.midX) * 2.0) / 2.0),
                offsetY: Double(round((screen.frame.maxY - belowStatusBarTopY) * 2.0) / 2.0)
            )
            let frame = panelFrame(
                capsuleCenterX: clampedCenterX,
                capsuleTopY: belowStatusBarTopY,
                capsuleSize: capsuleSize
            )
            return (screen, placement, frame.origin, .statusBarBelowVertical)
        }

        // 4. Free positioning everywhere else (no horizontal X detents).
        let maxAllowedTopY = overlapsHardwareNotch ? statusBarBottomY : screen.frame.maxY
        let clampedTopY = min(
            max(capsuleTopY, screen.frame.minY + capsuleSize.height + 4.0),
            maxAllowedTopY
        )

        let placement = DisplayPlacement(
            anchor: .custom,
            offsetX: Double(round((clampedCenterX - screen.frame.midX) * 2.0) / 2.0),
            offsetY: Double(round((screen.frame.maxY - clampedTopY) * 2.0) / 2.0)
        )
        let frame = panelFrame(
            capsuleCenterX: clampedCenterX,
            capsuleTopY: clampedTopY,
            capsuleSize: capsuleSize
        )
        return (screen, placement, frame.origin, .none)
    }

    public static func isDockedFlushToTopBar(
        placement: DisplayPlacement,
        dockedShape: DockedCapsuleShape
    ) -> Bool {
        guard dockedShape == .notchChin else { return false }
        switch placement.anchor {
        case .notchOrMenuBarBottomCenter:
            return placement.offsetY <= 2.0
        case .custom:
            return placement.offsetY >= 20.0 && placement.offsetY <= 36.0
        default:
            return false
        }
    }
}
