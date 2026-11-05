import AppKit
import SwiftUI

public enum DragHandleSide: String, Equatable, Sendable {
    case leading
    case trailing
}

public struct WindowIconTarget: Equatable, Sendable {
    public let windowID: Int
    public let spaceNumber: Int
    public let isSpaceActive: Bool
    public let isFocused: Bool
    public let bundleID: String
    public let appName: String
    public let stackOrder: Int
    public var rectInRoot: CGRect
}

public struct ActiveAppDrag: Equatable, Sendable {
    public let source: WindowIconTarget
    public var currentPointInRoot: CGPoint
    public var targetSpaceNumber: Int?
    public var isCreatingNewSpace: Bool
    public var followWithShift: Bool
}

@MainActor
@Observable
public final class PanelInteractionBridge {
    @ObservationIgnored public var capsuleRectInRoot: CGRect = .zero
    @ObservationIgnored public var restingCapsuleSize: CGSize = CGSize(width: 140, height: 30)
    @ObservationIgnored public var itemRectsInRoot: [Int: CGRect] = [:]
    @ObservationIgnored public var dragHandleRectInRoot: CGRect = .zero
    @ObservationIgnored public var isDragHandleVisible: Bool = false
    @ObservationIgnored public var newSpaceDropRectInRoot: CGRect = .zero
    @ObservationIgnored public var nextNewSpaceNumber: Int?

    @ObservationIgnored public var windowIconTargets: [Int: WindowIconTarget] = [:]
    @ObservationIgnored public var primaryWindowBySpace: [Int: WindowIconTarget] = [:]

    public var hoverLocationInRoot: CGPoint?
    public var activeHandleSide: DragHandleSide = .trailing
    public var isDraggingWindow: Bool = false
    public var activeAppDrag: ActiveAppDrag?
    public var pressedSpaceNumber: Int?

    public init() {}

    public func updateHover(point pt: CGPoint?, canvasWidth: CGFloat) {
        if isDraggingWindow || activeAppDrag != nil {
            return
        }
        let wasHovering = hoverLocationInRoot != nil
        hoverLocationInRoot = pt

        guard let pt, canvasWidth > 1 else { return }
        let centerX = canvasWidth / 2.0
        if !wasHovering {
            activeHandleSide = pt.x < centerX ? .leading : .trailing
        } else if pt.x < centerX - 6.0 {
            if activeHandleSide != .leading {
                dragHandleRectInRoot = .zero
                activeHandleSide = .leading
            }
        } else if pt.x > centerX + 6.0 {
            if activeHandleSide != .trailing {
                dragHandleRectInRoot = .zero
                activeHandleSide = .trailing
            }
        }
    }

    public func hitTestDragHandle(at rootTopLeftPoint: CGPoint) -> Bool {
        guard isDragHandleVisible, dragHandleRectInRoot.width > 4 else { return false }
        let hitRect: CGRect
        if activeHandleSide == .leading {
            let minX = dragHandleRectInRoot.minX - 12.0
            let maxX = dragHandleRectInRoot.maxX
            hitRect = CGRect(
                x: minX,
                y: dragHandleRectInRoot.minY - 8.0,
                width: max(8.0, maxX - minX),
                height: dragHandleRectInRoot.height + 16.0
            )
        } else {
            let minX = dragHandleRectInRoot.minX
            let maxX = dragHandleRectInRoot.maxX + 12.0
            hitRect = CGRect(
                x: minX,
                y: dragHandleRectInRoot.minY - 8.0,
                width: max(8.0, maxX - minX),
                height: dragHandleRectInRoot.height + 16.0
            )
        }
        return hitRect.contains(rootTopLeftPoint)
    }

    public func hitTestSpace(at rootTopLeftPoint: CGPoint) -> Int? {
        for (number, rect) in itemRectsInRoot {
            if rect.insetBy(dx: -2.5, dy: -4.5).contains(rootTopLeftPoint) {
                return number
            }
        }
        return nil
    }

    public func hitTestDirectWindowIcon(at rootTopLeftPoint: CGPoint) -> WindowIconTarget? {
        let hits = windowIconTargets.values.filter { target in
            target.rectInRoot.width > 1
                && target.rectInRoot.insetBy(dx: -4.0, dy: -5.0).contains(rootTopLeftPoint)
        }
        guard !hits.isEmpty else { return nil }

        return hits.min { lhs, rhs in
            let lDist = hypot(rootTopLeftPoint.x - lhs.rectInRoot.midX, rootTopLeftPoint.y - lhs.rectInRoot.midY)
                + CGFloat(lhs.stackOrder) * 1.2
            let rDist = hypot(rootTopLeftPoint.x - rhs.rectInRoot.midX, rootTopLeftPoint.y - rhs.rectInRoot.midY)
                + CGFloat(rhs.stackOrder) * 1.2
            return lDist < rDist
        }
    }

    public func resolveDragCandidate(at rootTopLeftPoint: CGPoint) -> (target: WindowIconTarget, isDirectIcon: Bool)? {
        if let direct = hitTestDirectWindowIcon(at: rootTopLeftPoint) {
            return (direct, true)
        }
        if let spaceNum = hitTestSpace(at: rootTopLeftPoint),
           let fallback = primaryWindowBySpace[spaceNum] {
            return (fallback, false)
        }
        return nil
    }

    public func hitTestDropDestination(
        at rootTopLeftPoint: CGPoint,
        excludingSpace sourceSpace: Int
    ) -> (spaceNumber: Int, isNewSpace: Bool)? {
        if let nextSpace = nextNewSpaceNumber,
           newSpaceDropRectInRoot.width > 1,
           newSpaceDropRectInRoot.insetBy(dx: -5.0, dy: -7.0).contains(rootTopLeftPoint) {
            return (nextSpace, true)
        }

        for (number, rect) in itemRectsInRoot {
            if number != sourceSpace,
               rect.insetBy(dx: -3.0, dy: -6.0).contains(rootTopLeftPoint) {
                return (number, false)
            }
        }
        return nil
    }
}

public struct SpaceBarView: View {
    public let wmClient: WorkspaceManagerClient
    public let configStore: ConfigStore
    public let bridge: PanelInteractionBridge
    public let displayID: UInt32?
    public let isDockedChinMode: Bool
    public let resolvedColorScheme: ColorScheme

    @Namespace private var activePillNamespace

    public init(
        wmClient: WorkspaceManagerClient,
        configStore: ConfigStore,
        bridge: PanelInteractionBridge,
        displayID: UInt32? = nil,
        isDockedChinMode: Bool,
        resolvedColorScheme: ColorScheme
    ) {
        self.wmClient = wmClient
        self.configStore = configStore
        self.bridge = bridge
        self.displayID = displayID
        self.isDockedChinMode = isDockedChinMode
        self.resolvedColorScheme = resolvedColorScheme
    }

    private var scale: CGFloat {
        CGFloat(min(max(configStore.config.appearance.scale, 0.80), 1.40))
    }

    private var baseOuterHeight: CGFloat {
        round(30.0 * scale)
    }

    private var baseItemHeight: CGFloat {
        round(22.5 * scale)
    }

    private var glassStyleVariant: Glass {
        switch configStore.config.appearance.glassStyle {
        case .regular:
            return .regular.interactive()
        case .clear:
            return .clear.interactive()
        }
    }

    private var activeAccentColor: Color {
        Color(hex: configStore.config.appearance.activeTintHex, fallback: Color(red: 0.184, green: 0.506, blue: 0.969))
    }

    /// Computes deterministic unmagnified width and center offsets for each space item so
    /// Dock-like cosine magnification is 100% oscillation-free and panel sizing never jitters.
    public static func computeRestingMetrics(
        spaces: [SpaceItemModel],
        iconStyle: SpaceIconStyle,
        scale: CGFloat
    ) -> (totalSize: CGSize, itemCenterOffsets: [Int: CGFloat]) {
        let s = min(max(scale, 0.80), 1.40)
        let outerH = round(30.0 * s)
        let itemH = round(22.5 * s)
        let iconSize = round(17.0 * s)
        let itemSpacing = round(3.0 * s)
        let outerHPad = round(5.5 * s)

        var widths: [(Int, CGFloat)] = []
        widths.reserveCapacity(spaces.count)

        for sp in spaces {
            let digitsWidth: CGFloat = sp.number >= 10 ? round(15.0 * s) : round(8.5 * s)
            let winCount = iconStyle == .numbersOnly ? 0 : sp.windows.count
            let iconsWidth: CGFloat
            if winCount == 0 {
                iconsWidth = 0
            } else if sp.isActive {
                iconsWidth = CGFloat(winCount) * iconSize + CGFloat(max(0, winCount - 1)) * round(3.5 * s)
            } else {
                let shown = min(winCount, 3)
                let stackStep = iconSize - round(7.0 * s)
                let extraBadge: CGFloat = winCount > 3 ? round(13.0 * s) : 0
                iconsWidth = iconSize + CGFloat(max(0, shown - 1)) * stackStep + extraBadge
            }

            let innerGap: CGFloat = winCount > 0 ? round(4.5 * s) : 0
            let hPad = round(16.0 * s)
            let w = max(itemH, digitsWidth + innerGap + iconsWidth + hPad)
            widths.append((sp.number, w))
        }

        let contentWidth = widths.reduce(0) { $0 + $1.1 }
            + CGFloat(max(0, widths.count - 1)) * itemSpacing
        let totalWidth = ceil(contentWidth + outerHPad * 2.0)

        var offsets: [Int: CGFloat] = [:]
        var cursorX = -contentWidth / 2.0
        for (idx, entry) in widths.enumerated() {
            let center = cursorX + entry.1 / 2.0
            offsets[entry.0] = center
            cursorX += entry.1 + (idx < widths.count - 1 ? itemSpacing : 0)
        }

        return (CGSize(width: max(48, totalWidth), height: outerH), offsets)
    }

    private func deterministicRestingRect(metricsSize: CGSize, canvasWidth: CGFloat, canvasHeight: CGFloat) -> CGRect {
        CGRect(
            x: (canvasWidth - metricsSize.width) / 2.0,
            y: (canvasHeight - metricsSize.height) / 2.0,
            width: metricsSize.width,
            height: metricsSize.height
        )
    }

    private func isHoveringBarOrHandleZone(
        metricsSize: CGSize,
        canvasWidth: CGFloat,
        canvasHeight: CGFloat
    ) -> Bool {
        guard let hoverPt = bridge.hoverLocationInRoot else { return false }
        let capRect = deterministicRestingRect(metricsSize: metricsSize, canvasWidth: canvasWidth, canvasHeight: canvasHeight)
        let sideReach: CGFloat = configStore.config.interaction.lockPosition ? 14.0 : round(42.0 * scale)
        let unifiedZone = CGRect(
            x: capRect.minX - sideReach,
            y: capRect.minY - 15.0,
            width: capRect.width + sideReach * 2.0,
            height: capRect.height + 30.0
        )
        return unifiedZone.contains(hoverPt)
    }

    private func handleHoverProximity(
        side: DragHandleSide,
        metricsSize: CGSize,
        canvasWidth: CGFloat,
        canvasHeight: CGFloat
    ) -> CGFloat {
        if bridge.isDraggingWindow { return 1.0 }
        guard !configStore.config.interaction.lockPosition,
              bridge.activeAppDrag == nil,
              let hoverPt = bridge.hoverLocationInRoot else {
            return 0.0
        }
        let capRect = deterministicRestingRect(metricsSize: metricsSize, canvasWidth: canvasWidth, canvasHeight: canvasHeight)
        let bandMinX: CGFloat
        let bandMaxX: CGFloat
        if side == .leading {
            bandMinX = capRect.minX - round(25.0 * scale)
            bandMaxX = capRect.minX - round(2.0 * scale)
        } else {
            bandMinX = capRect.maxX + round(2.0 * scale)
            bandMaxX = capRect.maxX + round(25.0 * scale)
        }
        let dx: CGFloat
        if hoverPt.x < bandMinX {
            dx = bandMinX - hoverPt.x
        } else if hoverPt.x > bandMaxX {
            dx = hoverPt.x - bandMaxX
        } else {
            dx = 0.0
        }
        let dy = abs(hoverPt.y - capRect.midY) * 1.15
        let dist = hypot(dx, dy)
        let radius: CGFloat = 38.0 * scale
        guard dist < radius else { return 0.0 }
        return 0.5 * (1.0 + cos(.pi * dist / radius))
    }

    private func hoverProximity(
        for spaceNumber: Int,
        restingOffsets: [Int: CGFloat],
        metricsSize: CGSize,
        canvasWidth: CGFloat,
        canvasHeight: CGFloat
    ) -> CGFloat {
        guard !bridge.isDraggingWindow,
              bridge.activeAppDrag == nil,
              let hoverPt = bridge.hoverLocationInRoot else {
            return 0.0
        }
        let capRect = deterministicRestingRect(metricsSize: metricsSize, canvasWidth: canvasWidth, canvasHeight: canvasHeight)
        let spaceZone = CGRect(
            x: capRect.minX - 10.0,
            y: capRect.minY - 14.0,
            width: capRect.width + 20.0,
            height: capRect.height + 28.0
        )
        guard spaceZone.contains(hoverPt),
              let itemOffset = restingOffsets[spaceNumber] else {
            return 0.0
        }

        let cursorOffset = hoverPt.x - (canvasWidth / 2.0)
        let dist = abs(cursorOffset - itemOffset)
        let radius: CGFloat = 68.0 * scale
        guard dist < radius else { return 0.0 }
        return 0.5 * (1.0 + cos(.pi * dist / radius))
    }

    private static func buildPrimaryWindowMap(spaces: [SpaceItemModel]) -> [Int: WindowIconTarget] {
        var map: [Int: WindowIconTarget] = [:]
        for sp in spaces {
            guard let primary = sp.windows.first(where: \.isFocused) ?? sp.windows.first else { continue }
            map[sp.number] = WindowIconTarget(
                windowID: primary.windowID,
                spaceNumber: sp.number,
                isSpaceActive: sp.isActive,
                isFocused: primary.isFocused,
                bundleID: primary.bundleID,
                appName: primary.appName,
                stackOrder: 0,
                rectInRoot: .zero
            )
        }
        return map
    }

    public var body: some View {
        let spaces = wmClient.spaces(for: displayID)
        let validSpaceIDs = Set(spaces.map(\.number))
        let validWindowIDs = Set(spaces.flatMap { $0.windows.map(\.windowID) })
        let iconStyle = configStore.config.appearance.iconStyle
        let metrics = Self.computeRestingMetrics(spaces: spaces, iconStyle: iconStyle, scale: scale)
        let canvasWidth = metrics.totalSize.width + NotchGeometryResolver.panelHorizontalMargin * 2.0
        let canvasHeight = metrics.totalSize.height + NotchGeometryResolver.panelVerticalMargin * 2.0

        let appDrag = bridge.activeAppDrag
        let isDraggingApp = appDrag != nil
        let computedNextSpace: Int? = isDraggingApp ? wmClient.nextNewSpaceNumber(for: displayID) : nil

        let inHoverOrHandleZone = isHoveringBarOrHandleZone(
            metricsSize: metrics.totalSize,
            canvasWidth: canvasWidth,
            canvasHeight: canvasHeight
        )
        let handleSide = bridge.activeHandleSide
        let showDragHandle = bridge.isDraggingWindow
            || (!isDraggingApp && !configStore.config.interaction.lockPosition && inHoverOrHandleZone)
        let handleProximity = showDragHandle
            ? handleHoverProximity(side: handleSide, metricsSize: metrics.totalSize, canvasWidth: canvasWidth, canvasHeight: canvasHeight)
            : 0.0
        let isHoveringHandleDirectly: Bool = {
            guard showDragHandle, !bridge.isDraggingWindow, let pt = bridge.hoverLocationInRoot else { return false }
            return bridge.hitTestDragHandle(at: pt)
        }()
        let hoveredWindowID: Int? = {
            guard !bridge.isDraggingWindow, !isDraggingApp, !isHoveringHandleDirectly,
                  let pt = bridge.hoverLocationInRoot else { return nil }
            return bridge.hitTestDirectWindowIcon(at: pt)?.windowID
        }()

        let proximities: [Int: CGFloat] = Dictionary(
            uniqueKeysWithValues: spaces.map { sp in
                (
                    sp.number,
                    hoverProximity(
                        for: sp.number,
                        restingOffsets: metrics.itemCenterOffsets,
                        metricsSize: metrics.totalSize,
                        canvasWidth: canvasWidth,
                        canvasHeight: canvasHeight
                    )
                )
            }
        )
        let maxProximity = proximities.values.max() ?? 0.0
        let handleEmphasis = bridge.isDraggingWindow
            ? 1.0
            : (showDragHandle ? max(handleProximity, isHoveringHandleDirectly ? 1.0 : 0.0) : 0.0)
        let overallSwell = max(maxProximity, handleEmphasis * 0.95)
        let dynamicOuterHeight = baseOuterHeight + round(9.5 * overallSwell * scale)
        let handleSlotHeight = baseItemHeight + round(7.0 * overallSwell * scale)
        let bottomRadius = dynamicOuterHeight / 2.0
        let topRadius = isDockedChinMode ? round(4.5 * scale) : bottomRadius
        let outerShape = UnevenRoundedRectangle(
            topLeadingRadius: topRadius,
            bottomLeadingRadius: bottomRadius,
            bottomTrailingRadius: bottomRadius,
            topTrailingRadius: topRadius,
            style: .continuous
        )
        let trailingGap = round(6.5 * scale)
        let activeHandleExtension = round((14.5 + 10.5 * handleEmphasis) * scale)
        let leadingExtension: CGFloat = (showDragHandle && handleSide == .leading) ? activeHandleExtension : 0.0
        let trailingExtension: CGFloat = (showDragHandle && handleSide == .trailing) ? activeHandleExtension : 0.0
        let directionalCenterCompensation = (trailingExtension - leadingExtension) / 2.0

        ZStack {
            GlassEffectContainer(spacing: round(12.0 * scale)) {
                HStack(spacing: 0) {
                    // Left integrated vertical-bar handle slot: extends out from right-to-left inside the unified capsule
                    IntegratedDragHandleSlotView(
                        side: .leading,
                        isVisible: showDragHandle && handleSide == .leading,
                        slotWidth: leadingExtension,
                        slotHeight: handleSlotHeight,
                        emphasis: (showDragHandle && handleSide == .leading) ? handleEmphasis : 0.0,
                        colorScheme: resolvedColorScheme,
                        scale: scale,
                        isDraggingWindow: bridge.isDraggingWindow,
                        accentColor: activeAccentColor
                    )
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .named("panelRoot"))
                    } action: { rect in
                        if bridge.activeHandleSide == .leading {
                            bridge.dragHandleRectInRoot = rect
                        }
                    }

                    HStack(spacing: round((3.0 + 2.2 * maxProximity) * scale)) {
                        ForEach(spaces) { space in
                            let prox = proximities[space.number] ?? 0.0
                            let isDropTarget = (appDrag?.targetSpaceNumber == space.number)
                                && (appDrag?.isCreatingNewSpace == false)
                            let draggedWinIDInThisSpace: Int? = (appDrag?.source.spaceNumber == space.number)
                                ? appDrag?.source.windowID
                                : nil

                            SpacePillItemView(
                                space: space,
                                iconStyle: iconStyle,
                                glassStyle: configStore.config.appearance.glassStyle,
                                colorScheme: resolvedColorScheme,
                                scale: scale,
                                baseItemHeight: baseItemHeight,
                                proximity: prox,
                                activeAccentColor: activeAccentColor,
                                isPressed: bridge.pressedSpaceNumber == space.number && !bridge.isDraggingWindow && !isDraggingApp,
                                isDropTarget: isDropTarget,
                                draggedWindowID: draggedWinIDInThisSpace,
                                hoveredWindowID: hoveredWindowID,
                                bridge: bridge,
                                activeNamespace: activePillNamespace
                            )
                            .onGeometryChange(for: CGRect.self) { proxy in
                                proxy.frame(in: .named("panelRoot"))
                            } action: { newRect in
                                bridge.itemRectsInRoot[space.number] = newRect
                            }
                            .transition(.blurReplace)
                        }
                    }

                    // Right integrated vertical-bar handle slot: extends out from left-to-right inside the unified capsule
                    IntegratedDragHandleSlotView(
                        side: .trailing,
                        isVisible: showDragHandle && handleSide == .trailing,
                        slotWidth: trailingExtension,
                        slotHeight: handleSlotHeight,
                        emphasis: (showDragHandle && handleSide == .trailing) ? handleEmphasis : 0.0,
                        colorScheme: resolvedColorScheme,
                        scale: scale,
                        isDraggingWindow: bridge.isDraggingWindow,
                        accentColor: activeAccentColor
                    )
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .named("panelRoot"))
                    } action: { rect in
                        if bridge.activeHandleSide == .trailing {
                            bridge.dragHandleRectInRoot = rect
                        }
                    }
                }
                .padding(.horizontal, round((5.5 + 4.0 * overallSwell) * scale))
                .padding(.vertical, round(4.0 * scale))
                .frame(height: dynamicOuterHeight)
                .fixedSize(horizontal: true, vertical: true)
                .glassEffect(glassStyleVariant, in: outerShape)
                .overlay {
                    ZStack {
                        // Subtle cursor-following liquid specular sheen across both spaces & integrated handle
                        if let hoverPt = bridge.hoverLocationInRoot, overallSwell > 0.02 {
                            let localX = hoverPt.x - bridge.capsuleRectInRoot.minX
                            RadialGradient(
                                colors: [
                                    .white.opacity(0.24 * Double(overallSwell)),
                                    .clear
                                ],
                                center: UnitPoint(
                                    x: max(0, min(1, localX / max(1, bridge.capsuleRectInRoot.width))),
                                    y: 0.15
                                ),
                                startRadius: 2,
                                endRadius: 58 * scale
                            )
                            .clipShape(outerShape)
                            .allowsHitTesting(false)
                        }

                        outerShape
                            .strokeBorder(
                                LinearGradient(
                                    colors: resolvedColorScheme == .dark
                                        ? [
                                            .white.opacity(bridge.isDraggingWindow ? 0.62 : (0.26 + 0.18 * Double(overallSwell))),
                                            .white.opacity(bridge.isDraggingWindow ? 0.24 : 0.07)
                                        ]
                                        : [
                                            .white.opacity(bridge.isDraggingWindow ? 0.85 : 0.68),
                                            .black.opacity(bridge.isDraggingWindow ? 0.22 : 0.11)
                                        ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: bridge.isDraggingWindow ? 1.05 : 0.7
                            )
                            .allowsHitTesting(false)
                    }
                }
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .named("panelRoot"))
                } action: { rect in
                    bridge.capsuleRectInRoot = rect
                }
                .overlay(alignment: .trailing) {
                    // Right-side `+` New Space pill during App-to-Space drag
                    ZStack(alignment: .leading) {
                        if let nextNum = computedNextSpace {
                            NewSpaceDropPillView(
                                nextSpaceNumber: nextNum,
                                glassVariant: glassStyleVariant,
                                colorScheme: resolvedColorScheme,
                                scale: scale,
                                isTargeted: appDrag?.isCreatingNewSpace == true,
                                accentColor: activeAccentColor
                            )
                            .padding(.leading, trailingGap)
                            .onGeometryChange(for: CGRect.self) { proxy in
                                proxy.frame(in: .named("panelRoot"))
                            } action: { rect in
                                bridge.newSpaceDropRectInRoot = rect
                            }
                            .transition(.scale(scale: 0.5, anchor: .leading).combined(with: .opacity))
                        }
                    }
                    .alignmentGuide(.trailing) { d in
                        d[.leading]
                    }
                }
                .offset(x: directionalCenterCompensation)
                .scaleEffect(bridge.isDraggingWindow ? 1.03 : 1.0)
            }

            // Floating Liquid Glass Dragged-App Ghost Badge following pointer at 120Hz
            if let drag = appDrag {
                let clampedX = min(max(drag.currentPointInRoot.x, 18.0), canvasWidth - 18.0)
                let clampedY = min(max(drag.currentPointInRoot.y, 16.0), canvasHeight - 16.0)

                DraggedAppFloatingBadgeView(
                    drag: drag,
                    colorScheme: resolvedColorScheme,
                    scale: scale,
                    accentColor: activeAccentColor
                )
                .position(x: clampedX, y: clampedY)
                .allowsHitTesting(false)
                .zIndex(50)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .frame(width: canvasWidth, height: canvasHeight, alignment: .center)
        .coordinateSpace(name: "panelRoot")
        .environment(\.controlActiveState, .active)
        .environment(\.colorScheme, resolvedColorScheme)
        .animation(.interactiveSpring(response: 0.24, dampingFraction: 0.68, blendDuration: 0.06), value: maxProximity)
        .animation(.interactiveSpring(response: 0.22, dampingFraction: 0.70, blendDuration: 0.05), value: handleProximity)
        .animation(.interactiveSpring(response: 0.18, dampingFraction: 0.72), value: hoveredWindowID)
        .animation(.spring(response: 0.25, dampingFraction: 0.74), value: showDragHandle)
        .animation(.spring(response: 0.25, dampingFraction: 0.76), value: handleSide)
        .animation(.spring(response: 0.22, dampingFraction: 0.72), value: isHoveringHandleDirectly)
        .animation(.spring(response: 0.24, dampingFraction: 0.76), value: isDraggingApp)
        .animation(.snappy(duration: 0.24, extraBounce: 0.06), value: spaces)
        .animation(.spring(response: 0.26, dampingFraction: 0.76), value: isDockedChinMode)
        .animation(.spring(response: 0.20, dampingFraction: 0.80), value: bridge.isDraggingWindow)
        .onAppear {
            bridge.restingCapsuleSize = metrics.totalSize
            bridge.isDragHandleVisible = showDragHandle
            bridge.nextNewSpaceNumber = computedNextSpace
            bridge.primaryWindowBySpace = Self.buildPrimaryWindowMap(spaces: spaces)
        }
        .onChange(of: metrics.totalSize) { _, newSize in
            bridge.restingCapsuleSize = newSize
        }
        .onChange(of: showDragHandle) { _, visible in
            bridge.isDragHandleVisible = visible
            if !visible {
                bridge.dragHandleRectInRoot = .zero
            }
        }
        .onChange(of: computedNextSpace) { _, nextVal in
            bridge.nextNewSpaceNumber = nextVal
            if nextVal == nil {
                bridge.newSpaceDropRectInRoot = .zero
            }
        }
        .onChange(of: spaces) { _, updatedSpaces in
            bridge.primaryWindowBySpace = Self.buildPrimaryWindowMap(spaces: updatedSpaces)
        }
        .onChange(of: validSpaceIDs) { _, current in
            bridge.itemRectsInRoot = bridge.itemRectsInRoot.filter { current.contains($0.key) }
        }
        .onChange(of: validWindowIDs) { _, current in
            bridge.windowIconTargets = bridge.windowIconTargets.filter { current.contains($0.key) }
        }
    }
}

/// Integrated vertical-bar drag handle (`|`) living directly inside the main unified Space capsule.
/// Expands seamlessly from right-to-left (leading) or left-to-right (trailing) out of the capsule's end,
/// and liquidly magnifies when the pointer approaches.
private struct IntegratedDragHandleSlotView: View {
    let side: DragHandleSide
    let isVisible: Bool
    let slotWidth: CGFloat
    let slotHeight: CGFloat
    let emphasis: CGFloat
    let colorScheme: ColorScheme
    let scale: CGFloat
    let isDraggingWindow: Bool
    let accentColor: Color

    var body: some View {
        let targetInnerWidth = round((14.0 + 9.5 * emphasis) * scale)
        let barWidth = max(2.6, round((2.8 + 1.8 * emphasis) * scale))
        let barHeight = round((12.0 + 8.0 * emphasis) * scale)
        let slideOffset: CGFloat = isVisible
            ? 0.0
            : ((side == .leading ? 1.0 : -1.0) * round(9.0 * scale))

        let barColor: Color = {
            if isDraggingWindow {
                return colorScheme == .dark ? .white : accentColor
            }
            if colorScheme == .dark {
                return .white.opacity(0.56 + 0.42 * Double(emphasis))
            } else {
                return Color(red: 0.10, green: 0.12, blue: 0.16).opacity(0.50 + 0.42 * Double(emphasis))
            }
        }()

        ZStack {
            if emphasis > 0.05 {
                RadialGradient(
                    colors: [
                        (isDraggingWindow ? accentColor : Color.white)
                            .opacity((colorScheme == .dark ? 0.22 : 0.34) * Double(emphasis)),
                        .clear
                    ],
                    center: .center,
                    startRadius: 1.0,
                    endRadius: round(14.0 * scale)
                )
            }

            Capsule(style: .continuous)
                .fill(barColor)
                .frame(width: barWidth, height: barHeight)
                .shadow(
                    color: isDraggingWindow
                        ? accentColor.opacity(0.60)
                        : (colorScheme == .dark
                            ? Color.white.opacity(0.35 * Double(emphasis))
                            : Color.black.opacity(0.14 * Double(emphasis))),
                    radius: 1.5 + 3.0 * emphasis,
                    y: 0
                )
                .offset(x: (side == .leading ? -1.0 : 1.0) * round(0.5 * scale))
        }
        .frame(width: targetInnerWidth, height: slotHeight)
        .offset(x: slideOffset)
        .opacity(isVisible ? 1.0 : 0.0)
        .frame(width: slotWidth, height: slotHeight, alignment: side == .leading ? .trailing : .leading)
        .clipped()
        .allowsHitTesting(false)
    }
}

/// Appears on the right side while dragging an App icon so dropping onto `+` sends the window to a brand-new Space.
private struct NewSpaceDropPillView: View {
    let nextSpaceNumber: Int
    let glassVariant: Glass
    let colorScheme: ColorScheme
    let scale: CGFloat
    let isTargeted: Bool
    let accentColor: Color

    var body: some View {
        let size = round((isTargeted ? 31.0 : 26.0) * scale)

        Image(systemName: "plus")
            .font(.system(size: round((isTargeted ? 14.0 : 12.0) * scale), weight: .bold, design: .rounded))
            .foregroundStyle(
                isTargeted
                    ? Color.white
                    : (colorScheme == .dark ? Color.white.opacity(0.88) : Color(red: 0.12, green: 0.14, blue: 0.18))
            )
            .frame(width: size, height: size)
            .background {
                if isTargeted {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [accentColor.opacity(0.95), accentColor.opacity(0.75)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }
            }
            .glassEffect(glassVariant, in: Circle())
            .overlay {
                Circle()
                    .strokeBorder(
                        isTargeted ? Color.white.opacity(0.72) : accentColor.opacity(0.48),
                        lineWidth: isTargeted ? 1.4 : 0.9
                    )
            }
            .shadow(color: isTargeted ? accentColor.opacity(0.55) : .clear, radius: 6, y: 1)
            .scaleEffect(isTargeted ? 1.14 : 1.0)
            .animation(.interactiveSpring(response: 0.20, dampingFraction: 0.68), value: isTargeted)
            .allowsHitTesting(false)
    }
}

/// Floating miniature glass card carrying the dragged App icon + live target workspace badge.
private struct DraggedAppFloatingBadgeView: View {
    let drag: ActiveAppDrag
    let colorScheme: ColorScheme
    let scale: CGFloat
    let accentColor: Color

    var body: some View {
        let iconImg = AppIconCache.shared.icon(bundleID: drag.source.bundleID, appName: drag.source.appName)
        let cardSize = round(26.0 * scale)
        let iconSize = round(19.0 * scale)
        let hasValidTarget = drag.targetSpaceNumber != nil

        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: round(7.5 * scale), style: .continuous)
                .fill(.ultraThinMaterial)
                .frame(width: cardSize, height: cardSize)
                .overlay {
                    Image(nsImage: iconImg)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: iconSize, height: iconSize)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: round(7.5 * scale), style: .continuous)
                        .strokeBorder(
                            hasValidTarget
                                ? accentColor.opacity(0.90)
                                : (colorScheme == .dark ? Color.white.opacity(0.38) : Color.black.opacity(0.18)),
                            lineWidth: hasValidTarget ? 1.2 : 0.75
                        )
                }
                .shadow(color: .black.opacity(0.32), radius: 6, y: 3)

            if let targetNum = drag.targetSpaceNumber {
                let label = drag.isCreatingNewSpace ? "+\(targetNum)" : "→\(targetNum)"
                Text(label)
                    .font(.system(size: round(8.5 * scale), weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, round(3.8 * scale))
                    .padding(.vertical, round(1.2 * scale))
                    .background(
                        Capsule(style: .continuous)
                            .fill(accentColor)
                            .shadow(color: .black.opacity(0.28), radius: 2, y: 1)
                    )
                    .offset(x: round(6.0 * scale), y: round(4.5 * scale))
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .scaleEffect(hasValidTarget ? 1.08 : 1.0)
        .animation(.interactiveSpring(response: 0.18, dampingFraction: 0.72), value: drag.targetSpaceNumber)
    }
}

private struct SpacePillItemView: View {
    let space: SpaceItemModel
    let iconStyle: SpaceIconStyle
    let glassStyle: GlassMaterialStyle
    let colorScheme: ColorScheme
    let scale: CGFloat
    let baseItemHeight: CGFloat
    let proximity: CGFloat
    let activeAccentColor: Color
    let isPressed: Bool
    let isDropTarget: Bool
    let draggedWindowID: Int?
    let hoveredWindowID: Int?
    let bridge: PanelInteractionBridge
    let activeNamespace: Namespace.ID

    private var visibleWindows: [SpaceWindowIconItem] {
        iconStyle == .numbersOnly ? [] : space.windows
    }

    private var inactiveNumberColor: Color {
        if isDropTarget {
            return .white
        }
        if colorScheme == .dark {
            return .white.opacity(0.86 + 0.14 * Double(proximity))
        } else {
            return Color(red: 0.10, green: 0.12, blue: 0.16).opacity(0.80 + 0.20 * Double(proximity))
        }
    }

    private var inactiveTextShadowColor: Color {
        if space.isActive || isDropTarget {
            return .black.opacity(0.22)
        }
        if colorScheme == .dark {
            return .black.opacity(glassStyle == .clear ? 0.48 : 0.22)
        } else {
            return .white.opacity(glassStyle == .clear ? 0.65 : 0.25)
        }
    }

    var body: some View {
        let hasIcons = !visibleWindows.isEmpty
        let effectiveProximity = isDropTarget ? max(proximity, 0.85) : proximity
        let dynamicHeight = baseItemHeight + round(4.8 * effectiveProximity * scale)
        let innerCornerRadius = dynamicHeight / 2.0
        let itemMagnification = isDropTarget
            ? (1.0 + 0.22 * scale)
            : (1.0 + 0.25 * proximity)
        let extraFluidSidePad = round(5.5 * effectiveProximity * scale)

        HStack(spacing: round((4.5 + 1.5 * effectiveProximity) * scale)) {
            Text("\(space.number)")
                .font(.system(size: round((12.5 + 1.2 * effectiveProximity) * scale), weight: (space.isActive || isDropTarget) ? .bold : .semibold, design: .rounded))
                .monospacedDigit()
                .fixedSize()
                .foregroundStyle((space.isActive || isDropTarget) ? Color.white : inactiveNumberColor)
                .shadow(
                    color: inactiveTextShadowColor,
                    radius: (!space.isActive && glassStyle == .clear) ? 1.5 : 0.8,
                    y: colorScheme == .dark ? 0.5 : 0.0
                )

            if hasIcons {
                WorkspaceIconsClusterView(
                    windows: visibleWindows,
                    spaceNumber: space.number,
                    isActiveSpace: space.isActive,
                    iconStyle: iconStyle,
                    scale: scale,
                    hoverProximity: proximity,
                    draggedWindowID: draggedWindowID,
                    hoveredWindowID: hoveredWindowID,
                    bridge: bridge
                )
            }
        }
        .padding(.leading, round((hasIcons ? 8.5 : 8.0) * scale) + extraFluidSidePad)
        .padding(.trailing, round((hasIcons ? 7.5 : 8.0) * scale) + extraFluidSidePad)
        .frame(minWidth: dynamicHeight, minHeight: dynamicHeight, maxHeight: dynamicHeight)
        .fixedSize(horizontal: true, vertical: true)
        .background {
            if space.isActive {
                RoundedRectangle(cornerRadius: innerCornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                activeAccentColor.opacity(0.95),
                                activeAccentColor.opacity(0.78)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: innerCornerRadius, style: .continuous)
                            .strokeBorder(
                                isDropTarget ? Color.white.opacity(0.88) : Color.white.opacity(0.35),
                                lineWidth: isDropTarget ? 1.5 : 0.65
                            )
                    }
                    .shadow(
                        color: activeAccentColor.opacity(isDropTarget ? 0.65 : 0.42),
                        radius: isDropTarget ? 7 : (4 + 2 * proximity),
                        y: 1
                    )
                    .matchedGeometryEffect(id: "activeWorkspacePill", in: activeNamespace)
            } else if isDropTarget {
                RoundedRectangle(cornerRadius: innerCornerRadius, style: .continuous)
                    .fill(activeAccentColor.opacity(0.52))
                    .overlay {
                        RoundedRectangle(cornerRadius: innerCornerRadius, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.75), lineWidth: 1.35)
                    }
                    .shadow(color: activeAccentColor.opacity(0.48), radius: 6, y: 1)
            } else if proximity > 0.08 {
                RoundedRectangle(cornerRadius: innerCornerRadius, style: .continuous)
                    .fill(.primary.opacity(0.11 * Double(proximity)))
            }
        }
        .scaleEffect(isPressed ? (itemMagnification * 0.93) : itemMagnification)
        .offset(y: -0.35 * effectiveProximity * scale)
        .zIndex(isDropTarget ? 4.0 : (space.isActive ? 2.0 : Double(proximity)))
        .contentShape(RoundedRectangle(cornerRadius: innerCornerRadius, style: .continuous))
        .animation(.interactiveSpring(response: 0.22, dampingFraction: 0.68, blendDuration: 0.05), value: proximity)
        .animation(.interactiveSpring(response: 0.20, dampingFraction: 0.70), value: isDropTarget)
        .animation(.easeOut(duration: 0.11), value: isPressed)
    }
}

/// Renders expanded side-by-side icons for the active workspace, and a compact overlapping
/// stacked deck for inactive workspaces (which fans open on hover so individual icons can be dragged).
private struct WorkspaceIconsClusterView: View {
    let windows: [SpaceWindowIconItem]
    let spaceNumber: Int
    let isActiveSpace: Bool
    let iconStyle: SpaceIconStyle
    let scale: CGFloat
    let hoverProximity: CGFloat
    let draggedWindowID: Int?
    let hoveredWindowID: Int?
    let bridge: PanelInteractionBridge

    var body: some View {
        // Enlarges smoothly from 17pt at rest up to 21.5pt on hover (plus pill magnification & direct hover pop!)
        let iconSize = round((17.0 + 4.5 * hoverProximity) * scale)

        if isActiveSpace {
            let expandedSpacing = round((3.5 + 3.0 * hoverProximity) * scale)
            let hasFocusedColumn = windows.contains(where: \.isInFocusedColumn)
            HStack(spacing: expandedSpacing) {
                ForEach(Array(windows.enumerated()), id: \.element.id) { idx, win in
                    let isHighlightedColumn = !hasFocusedColumn || win.isInFocusedColumn
                    AppWindowIconView(
                        item: win,
                        style: iconStyle,
                        isActiveSpace: true,
                        isHighlightedColumn: isHighlightedColumn,
                        isStackedDeck: false,
                        isBeingDragged: draggedWindowID == win.windowID,
                        isDirectlyHovered: hoveredWindowID == win.windowID,
                        size: iconSize
                    )
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .named("panelRoot"))
                    } action: { rect in
                        bridge.windowIconTargets[win.windowID] = WindowIconTarget(
                            windowID: win.windowID,
                            spaceNumber: spaceNumber,
                            isSpaceActive: true,
                            isFocused: win.isFocused,
                            bundleID: win.bundleID,
                            appName: win.appName,
                            stackOrder: idx,
                            rectInRoot: rect
                        )
                    }
                    .transition(.blurReplace)
                }
            }
            .fixedSize()
        } else {
            let maxVisible = hoverProximity > 0.55 ? min(windows.count, 5) : 3
            let visibleSlice = Array(windows.prefix(maxVisible))
            let overflowCount = max(0, windows.count - maxVisible)
            // Fans out from -7pt overlap at rest up to +4.0pt full side-by-side separation on hover!
            let stackedSpacing = (-7.0 + 11.0 * hoverProximity) * scale

            HStack(spacing: round(3.0 * scale)) {
                HStack(spacing: stackedSpacing) {
                    ForEach(Array(visibleSlice.enumerated()), id: \.element.id) { idx, win in
                        AppWindowIconView(
                            item: win,
                            style: iconStyle,
                            isActiveSpace: false,
                            isHighlightedColumn: false,
                            isStackedDeck: visibleSlice.count > 1 && hoverProximity < 0.55,
                            isBeingDragged: draggedWindowID == win.windowID,
                            isDirectlyHovered: hoveredWindowID == win.windowID,
                            size: iconSize
                        )
                        .onGeometryChange(for: CGRect.self) { proxy in
                            proxy.frame(in: .named("panelRoot"))
                        } action: { rect in
                            bridge.windowIconTargets[win.windowID] = WindowIconTarget(
                                windowID: win.windowID,
                                spaceNumber: spaceNumber,
                                isSpaceActive: false,
                                isFocused: win.isFocused,
                                bundleID: win.bundleID,
                                appName: win.appName,
                                stackOrder: idx,
                                rectInRoot: rect
                            )
                        }
                        .zIndex(hoveredWindowID == win.windowID ? 10.0 : Double(visibleSlice.count - idx))
                        .transition(.blurReplace)
                    }
                }

                if overflowCount > 0 {
                    Text("+\(overflowCount)")
                        .font(.system(size: round(9.5 * scale), weight: .bold, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.75))
                        .padding(.horizontal, round(3.5 * scale))
                        .padding(.vertical, round(1.0 * scale))
                        .background(
                            Capsule(style: .continuous)
                                .fill(.primary.opacity(0.12))
                        )
                }
            }
            .fixedSize()
        }
    }
}

private struct AppWindowIconView: View {
    let item: SpaceWindowIconItem
    let style: SpaceIconStyle
    let isActiveSpace: Bool
    let isHighlightedColumn: Bool
    let isStackedDeck: Bool
    let isBeingDragged: Bool
    let isDirectlyHovered: Bool
    let size: CGFloat

    var body: some View {
        let image = AppIconCache.shared.icon(bundleID: item.bundleID, appName: item.appName)
        let isDimmedColumn = isActiveSpace && !isHighlightedColumn && !isDirectlyHovered

        let targetScale: CGFloat = {
            if isBeingDragged { return 0.80 }
            if isDirectlyHovered { return 1.16 }
            return 1.0
        }()

        Group {
            switch style {
            case .appIcon:
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .saturation(isDimmedColumn ? 0.92 : 1.0)
                    .brightness(isDimmedColumn ? -0.08 : 0.0)
                    .opacity(
                        isBeingDragged
                            ? 0.24
                            : (isDirectlyHovered
                                ? 1.0
                                : (isActiveSpace ? (isHighlightedColumn ? 1.0 : 0.85) : 0.92))
                    )
                    .shadow(
                        color: .black.opacity(
                            isDirectlyHovered
                                ? 0.48
                                : (isDimmedColumn ? 0.20 : (isStackedDeck ? 0.42 : 0.28))
                        ),
                        radius: isDirectlyHovered ? 3.2 : (isStackedDeck ? 1.6 : 1.3),
                        x: isStackedDeck ? -0.6 : 0.0,
                        y: isDirectlyHovered ? 1.2 : 0.5
                    )

            case .monochrome:
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .saturation(0.0)
                    .contrast(1.25)
                    .brightness(isDimmedColumn ? -0.06 : 0.0)
                    .opacity(
                        isBeingDragged
                            ? 0.22
                            : (isDirectlyHovered
                                ? 0.98
                                : (isActiveSpace ? (isHighlightedColumn ? 0.98 : 0.83) : 0.78))
                    )
                    .shadow(
                        color: .black.opacity(isDirectlyHovered ? 0.42 : (isStackedDeck ? 0.35 : 0.18)),
                        radius: isDirectlyHovered ? 2.8 : 1.2,
                        x: isStackedDeck ? -0.5 : 0.0,
                        y: isDirectlyHovered ? 1.0 : 0.4
                    )

            case .numbersOnly:
                EmptyView()
            }
        }
        .scaleEffect(targetScale)
        .offset(y: (!isBeingDragged && isDirectlyHovered) ? -1.4 : 0.0)
        .animation(.interactiveSpring(response: 0.20, dampingFraction: 0.72), value: isHighlightedColumn)
        .animation(.interactiveSpring(response: 0.18, dampingFraction: 0.68), value: isDirectlyHovered)
        .animation(.easeOut(duration: 0.14), value: isBeingDragged)
        .frame(width: size, height: size)
    }
}
