import AppKit
import CoreGraphics
import Foundation

public enum NotchGeometryResolver {
    /// Generous transparent canvas margins around the resting capsule so Dock-style fluid hover magnification
    /// and Liquid Glass shadows animate at 120fps purely inside SwiftUI without resizing the NSPanel.
    public static let panelHorizontalMargin: CGFloat = 38.0
    public static let panelVerticalMargin: CGFloat = 16.0

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
            let verticalCenterTop = frame.maxY - max(1, (mbHeight - capsuleSize.height) / 2.0)
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
        snapThreshold: CGFloat
    ) -> (screen: NSScreen, placement: DisplayPlacement, snappedPanelOrigin: NSPoint, didSnap: Bool) {
        let mx = panelHorizontalMargin
        let my = panelVerticalMargin
        let capsuleCenterX = proposedPanelOrigin.x + mx + capsuleSize.width / 2.0
        let capsuleTopY = proposedPanelOrigin.y + my + capsuleSize.height

        let centerPoint = NSPoint(x: capsuleCenterX, y: capsuleTopY - capsuleSize.height / 2.0)
        let screen = NSScreen.screens.first(where: { NSMouseInRect(centerPoint, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens[0]

        let hasNotch = hasHardwareNotch(screen)
        let mbHeight = menuBarHeight(for: screen)
        let defaultBottomGap: Double = (dockedShape == .notchChin && hasNotch) ? 0.0 : 4.0

        let bottomTargetX = notchRect(for: screen)?.midX ?? screen.frame.midX
        let bottomTargetTopY = (notchRect(for: screen)?.minY ?? (screen.frame.maxY - mbHeight)) - CGFloat(defaultBottomGap)

        if abs(capsuleCenterX - bottomTargetX) <= snapThreshold,
           abs(capsuleTopY - bottomTargetTopY) <= snapThreshold {
            let placement = DisplayPlacement(
                anchor: .notchOrMenuBarBottomCenter,
                offsetX: 0.0,
                offsetY: defaultBottomGap
            )
            let frame = panelFrame(
                capsuleCenterX: bottomTargetX,
                capsuleTopY: bottomTargetTopY,
                capsuleSize: capsuleSize
            )
            return (screen, placement, frame.origin, true)
        }

        if !hasNotch {
            let insideTopY = screen.frame.maxY - max(1, (mbHeight - capsuleSize.height) / 2.0)
            if abs(capsuleCenterX - screen.frame.midX) <= snapThreshold,
               abs(capsuleTopY - insideTopY) <= snapThreshold {
                let placement = DisplayPlacement(anchor: .menuBarInsideCenter, offsetX: 0.0, offsetY: 0.0)
                let frame = panelFrame(
                    capsuleCenterX: screen.frame.midX,
                    capsuleTopY: insideTopY,
                    capsuleSize: capsuleSize
                )
                return (screen, placement, frame.origin, true)
            }
        }

        var finalCenterX = capsuleCenterX
        var snappedHorizontally = false
        if abs(capsuleCenterX - screen.frame.midX) <= snapThreshold {
            finalCenterX = screen.frame.midX
            snappedHorizontally = true
        }

        let clampedCenterX = min(
            max(finalCenterX, screen.frame.minX + capsuleSize.width / 2.0 + 4.0),
            screen.frame.maxX - capsuleSize.width / 2.0 - 4.0
        )
        let clampedTopY = min(
            max(capsuleTopY, screen.frame.minY + capsuleSize.height + 4.0),
            screen.frame.maxY
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
        return (screen, placement, frame.origin, snappedHorizontally)
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
            return placement.offsetY <= 38.0
        default:
            return false
        }
    }
}
