import AppKit
import SwiftUI

/// Wraps NSHostingView with an `.activeAlways` NSTrackingArea so continuous 120Hz hover physics
/// work seamlessly even while NotchSpace is a non-activating background panel.
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
        super.mouseExited(with: event)
    }
}

@MainActor
public final class FloatingGlassPanel: NSPanel {
    public let bridge = PanelInteractionBridge()

    public var onSpaceAction: ((SpaceAction) -> Void)?
    public var onContextMenuRequest: ((NSEvent, NSView) -> Void)?
    public var onDragPreviewPlacement: ((NSScreen, DisplayPlacement) -> Void)?
    public var onDragCommitPlacement: ((NSScreen, DisplayPlacement) -> Void)?

    public var isPositionLocked: Bool = false
    public var enableScrollSwitch: Bool = false
    public var dockedShape: DockedCapsuleShape = .floatingCapsule
    public var snapThreshold: CGFloat = 8.0

    private var mouseDownScreenPoint: NSPoint?
    private var mouseDownPanelOrigin: NSPoint?
    private var mouseDownSpaceNumber: Int?
    private var lastSnappedState: Bool = false
    private var lastScrollTriggerTime: TimeInterval = 0

    public init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 64),
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
        mouseDownSpaceNumber = bridge.hitTestSpace(at: pt)
        bridge.pressedSpaceNumber = mouseDownSpaceNumber
        bridge.isDraggingWindow = false
        lastSnappedState = false
    }

    private func handleLeftMouseDragged(_ event: NSEvent) {
        guard let startScreen = mouseDownScreenPoint,
              let startOrigin = mouseDownPanelOrigin else { return }

        let currentScreen = NSEvent.mouseLocation
        let dx = currentScreen.x - startScreen.x
        let dy = currentScreen.y - startScreen.y
        let distance = hypot(dx, dy)

        let canDrag = !isPositionLocked || event.modifierFlags.contains(.option)

        if !bridge.isDraggingWindow {
            guard distance >= 4.5, canDrag else { return }
            bridge.isDraggingWindow = true
            bridge.pressedSpaceNumber = nil
            bridge.hoverLocationInRoot = nil
        }

        let proposedOrigin = NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy)
        let evaluation = NotchGeometryResolver.evaluateDragPlacement(
            proposedPanelOrigin: proposedOrigin,
            capsuleSize: bridge.restingCapsuleSize,
            dockedShape: dockedShape,
            snapThreshold: snapThreshold
        )

        if evaluation.didSnap && !lastSnappedState {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        lastSnappedState = evaluation.didSnap

        setFrameOrigin(evaluation.snappedPanelOrigin)
        onDragPreviewPlacement?(evaluation.screen, evaluation.placement)
    }

    private func handleLeftMouseUp(_ event: NSEvent) {
        defer {
            mouseDownScreenPoint = nil
            mouseDownPanelOrigin = nil
            mouseDownSpaceNumber = nil
            bridge.pressedSpaceNumber = nil
        }

        if bridge.isDraggingWindow {
            bridge.isDraggingWindow = false
            let evaluation = NotchGeometryResolver.evaluateDragPlacement(
                proposedPanelOrigin: frame.origin,
                capsuleSize: bridge.restingCapsuleSize,
                dockedShape: dockedShape,
                snapThreshold: snapThreshold
            )
            setFrameOrigin(evaluation.snappedPanelOrigin)
            onDragCommitPlacement?(evaluation.screen, evaluation.placement)
            return
        }

        let upPt = rootTopLeftPoint(for: event)
        guard let hitSpace = bridge.hitTestSpace(at: upPt),
              hitSpace == mouseDownSpaceNumber else {
            return
        }

        if event.modifierFlags.contains(.shift) {
            onSpaceAction?(.moveAndFollowWindow(hitSpace))
        } else {
            onSpaceAction?(.focusWorkspace(hitSpace))
        }
    }

    private func handleRightMouseDown(_ event: NSEvent) {
        let pt = rootTopLeftPoint(for: event)

        if event.modifierFlags.contains(.option) {
            if let view = contentView {
                onContextMenuRequest?(event, view)
            }
            return
        }

        mouseDownSpaceNumber = bridge.hitTestSpace(at: pt)
        if mouseDownSpaceNumber == nil, bridge.capsuleRectInRoot.contains(pt), let view = contentView {
            onContextMenuRequest?(event, view)
        } else {
            bridge.pressedSpaceNumber = mouseDownSpaceNumber
        }
    }

    private func handleRightMouseUp(_ event: NSEvent) {
        defer {
            mouseDownSpaceNumber = nil
            bridge.pressedSpaceNumber = nil
        }
        guard !event.modifierFlags.contains(.option) else { return }

        let pt = rootTopLeftPoint(for: event)
        if let hitSpace = bridge.hitTestSpace(at: pt), hitSpace == mouseDownSpaceNumber {
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
