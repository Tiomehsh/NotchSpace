import AppKit
import SwiftUI

/// Wraps NSHostingView with an `.activeAlways` NSTrackingArea so continuous 120Hz hover physics
/// and handle grab cursors work seamlessly even while NotchSpace is a non-activating background panel.
@MainActor
public final class HoverTrackingContainerView: NSView {
    public var onHoverPointChanged: ((CGPoint?) -> Void)?
    private var trackingAreaRef: NSTrackingArea?

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    private func reportMouseLocation(for event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        let topLeft = CGPoint(x: local.x, y: bounds.height - local.y)
        onHoverPointChanged?(topLeft)
    }

    public override func mouseEntered(with event: NSEvent) {
        reportMouseLocation(for: event)
        super.mouseEntered(with: event)
    }

    public override func mouseMoved(with event: NSEvent) {
        reportMouseLocation(for: event)
        super.mouseMoved(with: event)
    }

    public override func mouseExited(with event: NSEvent) {
        onHoverPointChanged?(nil)
        NSCursor.arrow.set()
        super.mouseExited(with: event)
    }
}

@MainActor
public final class FloatingGlassPanel: NSPanel {
    private enum PointerSession {
        case idle
        case pendingWindowDrag
        case draggingWindow
        case pendingSpaceOrApp(
            spaceNumber: Int?,
            dragCandidate: WindowIconTarget?,
            clickedDirectIcon: Bool
        )
        case draggingApp(WindowIconTarget)
    }

    public let bridge = PanelInteractionBridge()

    public var onSpaceAction: ((SpaceAction) -> Void)?
    public var onContextMenuRequest: ((NSEvent, NSView) -> Void)?
    public var onDragPreviewPlacement: ((NSScreen, DisplayPlacement) -> Void)?
    public var onDragCommitPlacement: ((NSScreen, DisplayPlacement) -> Void)?

    public var isPositionLocked: Bool = false
    public var enableScrollSwitch: Bool = false
    public var dockedShape: DockedCapsuleShape = .floatingCapsule
    public var snapThreshold: CGFloat = 8.0

    private var pointerSession: PointerSession = .idle
    private var mouseDownScreenPoint: NSPoint?
    private var mouseDownPanelOrigin: NSPoint?
    private var rightMouseDownSpaceNumber: Int?
    private var lastSnapKind: DragSnapKind = .none
    private var lastHoveredDropSpace: Int?
    private var lastScrollTriggerTime: TimeInterval = 0

    public init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 74),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.level = .statusBar
        self.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .fullScreenAuxiliary,
            .ignoresCycle
        ]
        self.hidesOnDeactivate = false
        self.isMovable = false
        self.isMovableByWindowBackground = false
        self.acceptsMouseMovedEvents = true
    }

    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }

    public func updateHoverLocation(_ pt: CGPoint?) {
        if bridge.isDraggingWindow || bridge.activeAppDrag != nil {
            return
        }
        let canvasW = contentView?.bounds.width ?? frame.width
        bridge.updateHover(point: pt, canvasWidth: canvasW)
        if let pt, !isPositionLocked, bridge.hitTestDragHandle(at: pt) {
            NSCursor.openHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    private func rootTopLeftPoint(for event: NSEvent) -> CGPoint {
        let winPt = event.locationInWindow
        let h = contentView?.bounds.height ?? frame.height
        return CGPoint(x: winPt.x, y: h - winPt.y)
    }

    public override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            handleLeftMouseDown(event)
            super.sendEvent(event)

        case .leftMouseDragged:
            handleLeftMouseDragged(event)
            super.sendEvent(event)

        case .leftMouseUp:
            super.sendEvent(event)
            handleLeftMouseUp(event)

        case .rightMouseDown:
            handleRightMouseDown(event)

        case .rightMouseUp:
            handleRightMouseUp(event)

        case .otherMouseUp:
            handleOtherMouseUp(event)

        case .scrollWheel:
            handleScrollWheel(event)
            super.sendEvent(event)

        default:
            super.sendEvent(event)
        }
    }

    private func handleLeftMouseDown(_ event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            handleRightMouseDown(event)
            return
        }

        let pt = rootTopLeftPoint(for: event)
        mouseDownScreenPoint = NSEvent.mouseLocation
        mouseDownPanelOrigin = frame.origin
        bridge.isDraggingWindow = false
        bridge.activeAppDrag = nil
        lastSnapKind = .none
        lastHoveredDropSpace = nil

        // 1. Holding Option anywhere OR pressing the left/right dynamic drag handle initiates window repositioning
        if event.modifierFlags.contains(.option) || (!isPositionLocked && bridge.hitTestDragHandle(at: pt)) {
            if event.modifierFlags.contains(.option) {
                let canvasW = contentView?.bounds.width ?? frame.width
                bridge.activeHandleSide = pt.x < (canvasW / 2.0) ? .leading : .trailing
            }
            pointerSession = .pendingWindowDrag
            bridge.pressedSpaceNumber = nil
            NSCursor.closedHand.set()
            return
        }

        // 2. Otherwise inside the Space capsule: click switches Space / focuses App, drag moves App across Spaces!
        let hitSpace = bridge.hitTestSpace(at: pt)
        let resolvedCandidate = bridge.resolveDragCandidate(at: pt)
        bridge.pressedSpaceNumber = hitSpace
        pointerSession = .pendingSpaceOrApp(
            spaceNumber: hitSpace,
            dragCandidate: resolvedCandidate?.target,
            clickedDirectIcon: resolvedCandidate?.isDirectIcon ?? false
        )
    }

    private func handleLeftMouseDragged(_ event: NSEvent) {
        guard let startScreen = mouseDownScreenPoint,
              let startOrigin = mouseDownPanelOrigin else { return }

        let currentScreen = NSEvent.mouseLocation
        let dx = currentScreen.x - startScreen.x
        let dy = currentScreen.y - startScreen.y
        let distance = hypot(dx, dy)

        switch pointerSession {
        case .idle:
            return

        case .pendingWindowDrag:
            guard distance >= 2.5 else { return }
            pointerSession = .draggingWindow
            bridge.isDraggingWindow = true
            bridge.pressedSpaceNumber = nil
            bridge.hoverLocationInRoot = nil
            NSCursor.closedHand.set()
            performWindowDragStep(startOrigin: startOrigin, dx: dx, dy: dy)

        case .draggingWindow:
            performWindowDragStep(startOrigin: startOrigin, dx: dx, dy: dy)

        case .pendingSpaceOrApp(_, let candidate, _):
            guard distance >= 4.0, let sourceTarget = candidate else { return }
            pointerSession = .draggingApp(sourceTarget)
            bridge.pressedSpaceNumber = nil
            bridge.hoverLocationInRoot = nil
            NSCursor.closedHand.set()
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            updateAppDragStep(sourceTarget: sourceTarget, event: event)

        case .draggingApp(let sourceTarget):
            updateAppDragStep(sourceTarget: sourceTarget, event: event)
        }
    }

    private func performWindowDragStep(startOrigin: NSPoint, dx: CGFloat, dy: CGFloat) {
        let proposedOrigin = NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy)
        let evaluation = NotchGeometryResolver.evaluateDragPlacement(
            proposedPanelOrigin: proposedOrigin,
            capsuleSize: bridge.restingCapsuleSize,
            dockedShape: dockedShape,
            snapThreshold: snapThreshold
        )

        if evaluation.snapKind != .none && evaluation.snapKind != lastSnapKind {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        lastSnapKind = evaluation.snapKind

        setFrameOrigin(evaluation.snappedPanelOrigin)
        onDragPreviewPlacement?(evaluation.screen, evaluation.placement)
    }

    private func updateAppDragStep(sourceTarget: WindowIconTarget, event: NSEvent) {
        let currentPt = rootTopLeftPoint(for: event)
        let dropHit = bridge.hitTestDropDestination(at: currentPt, excludingSpace: sourceTarget.spaceNumber)

        if dropHit?.spaceNumber != lastHoveredDropSpace {
            if dropHit != nil {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
            lastHoveredDropSpace = dropHit?.spaceNumber
        }

        bridge.activeAppDrag = ActiveAppDrag(
            source: sourceTarget,
            currentPointInRoot: currentPt,
            targetSpaceNumber: dropHit?.spaceNumber,
            isCreatingNewSpace: dropHit?.isNewSpace ?? false,
            followWithShift: event.modifierFlags.contains(.shift)
        )
    }

    private func handleLeftMouseUp(_ event: NSEvent) {
        let completedSession = pointerSession
        pointerSession = .idle
        mouseDownScreenPoint = nil
        mouseDownPanelOrigin = nil
        bridge.pressedSpaceNumber = nil
        lastHoveredDropSpace = nil

        let upPt = rootTopLeftPoint(for: event)
        let isInsideBounds = contentView?.bounds.contains(event.locationInWindow) ?? false

        switch completedSession {
        case .idle, .pendingWindowDrag:
            restoreHoverCursor(at: isInsideBounds ? upPt : nil)

        case .draggingWindow:
            bridge.isDraggingWindow = false
            let evaluation = NotchGeometryResolver.evaluateDragPlacement(
                proposedPanelOrigin: frame.origin,
                capsuleSize: bridge.restingCapsuleSize,
                dockedShape: dockedShape,
                snapThreshold: snapThreshold
            )
            setFrameOrigin(evaluation.snappedPanelOrigin)
            onDragCommitPlacement?(evaluation.screen, evaluation.placement)
            let postSnapPt = rootTopLeftPoint(for: event)
            let insidePostSnap = contentView?.bounds.contains(event.locationInWindow) ?? false
            restoreHoverCursor(at: insidePostSnap ? postSnapPt : nil)

        case .draggingApp(let sourceTarget):
            let finalDrop = bridge.hitTestDropDestination(at: upPt, excludingSpace: sourceTarget.spaceNumber)
            bridge.activeAppDrag = nil
            restoreHoverCursor(at: isInsideBounds ? upPt : nil)

            if let dst = finalDrop {
                let shouldFollow = event.modifierFlags.contains(.shift)
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                onSpaceAction?(
                    .moveSpecificWindow(
                        windowID: sourceTarget.windowID,
                        fromSpace: sourceTarget.spaceNumber,
                        toSpace: dst.spaceNumber,
                        follow: shouldFollow
                    )
                )
            }

        case .pendingSpaceOrApp(let downSpace, let candidate, let clickedDirectIcon):
            restoreHoverCursor(at: isInsideBounds ? upPt : nil)
            guard let hitSpace = bridge.hitTestSpace(at: upPt),
                  hitSpace == downSpace else {
                return
            }

            if event.modifierFlags.contains(.shift) {
                onSpaceAction?(.moveAndFollowWindow(hitSpace))
            } else if clickedDirectIcon,
                      let icon = candidate,
                      icon.isSpaceActive,
                      !icon.isFocused {
                onSpaceAction?(.focusWindow(icon.windowID))
            } else {
                onSpaceAction?(.focusWorkspace(hitSpace))
            }
        }
    }

    private func restoreHoverCursor(at pt: CGPoint?) {
        let canvasW = contentView?.bounds.width ?? frame.width
        bridge.updateHover(point: pt, canvasWidth: canvasW)
        if let pt, !isPositionLocked, bridge.hitTestDragHandle(at: pt) {
            NSCursor.openHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    private func handleRightMouseDown(_ event: NSEvent) {
        let pt = rootTopLeftPoint(for: event)

        if event.modifierFlags.contains(.option) || bridge.hitTestDragHandle(at: pt) {
            if let view = contentView {
                onContextMenuRequest?(event, view)
            }
            return
        }

        rightMouseDownSpaceNumber = bridge.hitTestSpace(at: pt)
        if rightMouseDownSpaceNumber == nil, bridge.capsuleRectInRoot.contains(pt), let view = contentView {
            onContextMenuRequest?(event, view)
        } else {
            bridge.pressedSpaceNumber = rightMouseDownSpaceNumber
        }
    }

    private func handleRightMouseUp(_ event: NSEvent) {
        defer {
            rightMouseDownSpaceNumber = nil
            bridge.pressedSpaceNumber = nil
        }
        guard !event.modifierFlags.contains(.option) else { return }

        let pt = rootTopLeftPoint(for: event)
        if let hitSpace = bridge.hitTestSpace(at: pt), hitSpace == rightMouseDownSpaceNumber {
            onSpaceAction?(.sendFocusedWindow(hitSpace))
        }
    }

    private func handleOtherMouseUp(_ event: NSEvent) {
        let pt = rootTopLeftPoint(for: event)
        if let hitSpace = bridge.hitTestSpace(at: pt) {
            onSpaceAction?(.moveAndFollowWindow(hitSpace))
        }
    }

    private func handleScrollWheel(_ event: NSEvent) {
        guard enableScrollSwitch else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastScrollTriggerTime > 0.22 else { return }

        let delta = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX)
            ? event.scrollingDeltaY
            : event.scrollingDeltaX
        guard abs(delta) > 3.0 else { return }

        lastScrollTriggerTime = now
        onSpaceAction?(.stepRelative(north: delta > 0))
    }
}
