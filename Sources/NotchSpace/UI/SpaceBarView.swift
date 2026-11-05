import AppKit
import SwiftUI

@MainActor
@Observable
public final class PanelInteractionBridge {
    public var capsuleRectInRoot: CGRect = .zero
    public var restingCapsuleSize: CGSize = CGSize(width: 140, height: 30)
    public var itemRectsInRoot: [Int: CGRect] = [:]
    public var hoverLocationInRoot: CGPoint?
    public var isDraggingWindow: Bool = false
    public var pressedSpaceNumber: Int?

    public init() {}

    public func hitTestSpace(at rootTopLeftPoint: CGPoint) -> Int? {
        for (number, rect) in itemRectsInRoot {
            if rect.insetBy(dx: -2.0, dy: -3.0).contains(rootTopLeftPoint) {
                return number
            }
        }
        return nil
    }
}

public struct SpaceBarView: View {
    public let paneruClient: PaneruClient
    public let configStore: ConfigStore
    public let bridge: PanelInteractionBridge
    public let isDockedChinMode: Bool
    public let resolvedColorScheme: ColorScheme

    @Namespace private var activePillNamespace

    public init(
        paneruClient: PaneruClient,
        configStore: ConfigStore,
        bridge: PanelInteractionBridge,
        isDockedChinMode: Bool,
        resolvedColorScheme: ColorScheme
    ) {
        self.paneruClient = paneruClient
        self.configStore = configStore
        self.bridge = bridge
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
        round(22.0 * scale)
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
        let itemH = round(22.0 * s)
        let iconSize = round(15.0 * s)
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
            let hPad = round((winCount > 0 ? 16.0 : 16.0) * s)
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

    private func hoverProximity(
        for spaceNumber: Int,
        restingOffsets: [Int: CGFloat],
        canvasWidth: CGFloat
    ) -> CGFloat {
        guard !bridge.isDraggingWindow,
              let hoverPt = bridge.hoverLocationInRoot else {
            return 0.0
        }
        let activeZone = bridge.capsuleRectInRoot.insetBy(dx: -12.0, dy: -10.0)
        guard activeZone.contains(hoverPt),
              let itemOffset = restingOffsets[spaceNumber] else {
            return 0.0
        }

        let cursorOffset = hoverPt.x - (canvasWidth / 2.0)
        let dist = abs(cursorOffset - itemOffset)
        let radius: CGFloat = 62.0 * scale
        guard dist < radius else { return 0.0 }
        return 0.5 * (1.0 + cos(.pi * dist / radius))
    }

    public var body: some View {
        let spaces = paneruClient.spaces
        let validIDs = Set(spaces.map(\.number))
        let iconStyle = configStore.config.appearance.iconStyle
        let metrics = Self.computeRestingMetrics(spaces: spaces, iconStyle: iconStyle, scale: scale)
        let canvasWidth = metrics.totalSize.width + NotchGeometryResolver.panelHorizontalMargin * 2.0
        let canvasHeight = metrics.totalSize.height + NotchGeometryResolver.panelVerticalMargin * 2.0

        let proximities: [Int: CGFloat] = Dictionary(
            uniqueKeysWithValues: spaces.map { sp in
                (sp.number, hoverProximity(for: sp.number, restingOffsets: metrics.itemCenterOffsets, canvasWidth: canvasWidth))
            }
        )
        let maxProximity = proximities.values.max() ?? 0.0
        let dynamicOuterHeight = baseOuterHeight + round(5.5 * maxProximity * scale)
        let bottomRadius = dynamicOuterHeight / 2.0
        let topRadius = isDockedChinMode ? round(4.5 * scale) : bottomRadius
        let outerShape = UnevenRoundedRectangle(
            topLeadingRadius: topRadius,
            bottomLeadingRadius: bottomRadius,
            bottomTrailingRadius: bottomRadius,
            topTrailingRadius: topRadius,
            style: .continuous
        )

        ZStack {
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: round(3.0 * scale)) {
                    ForEach(spaces) { space in
                        let prox = proximities[space.number] ?? 0.0
                        SpacePillItemView(
                            space: space,
                            iconStyle: iconStyle,
                            glassStyle: configStore.config.appearance.glassStyle,
                            colorScheme: resolvedColorScheme,
                            scale: scale,
                            baseItemHeight: baseItemHeight,
                            proximity: prox,
                            activeAccentColor: activeAccentColor,
                            isPressed: bridge.pressedSpaceNumber == space.number && !bridge.isDraggingWindow,
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
                .padding(.horizontal, round((5.5 + 2.5 * maxProximity) * scale))
                .padding(.vertical, round(4.0 * scale))
                .frame(height: dynamicOuterHeight)
                .fixedSize(horizontal: true, vertical: true)
                .glassEffect(glassStyleVariant, in: outerShape)
                .overlay {
                    ZStack {
                        // Subtle cursor-following liquid specular sheen
                        if let hoverPt = bridge.hoverLocationInRoot, maxProximity > 0.02 {
                            let localX = hoverPt.x - bridge.capsuleRectInRoot.minX
                            RadialGradient(
                                colors: [
                                    .white.opacity(0.22 * Double(maxProximity)),
                                    .clear
                                ],
                                center: UnitPoint(
                                    x: max(0, min(1, localX / max(1, bridge.capsuleRectInRoot.width))),
                                    y: 0.15
                                ),
                                startRadius: 2,
                                endRadius: 56 * scale
                            )
                            .clipShape(outerShape)
                            .allowsHitTesting(false)
                        }

                        outerShape
                            .strokeBorder(
                                LinearGradient(
                                    colors: resolvedColorScheme == .dark
                                        ? [
                                            .white.opacity(bridge.isDraggingWindow ? 0.58 : (0.26 + 0.16 * Double(maxProximity))),
                                            .white.opacity(bridge.isDraggingWindow ? 0.22 : 0.07)
                                        ]
                                        : [
                                            .white.opacity(bridge.isDraggingWindow ? 0.85 : 0.68),
                                            .black.opacity(bridge.isDraggingWindow ? 0.22 : 0.11)
                                        ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: bridge.isDraggingWindow ? 1.0 : 0.7
                            )
                            .allowsHitTesting(false)
                    }
                }
                .scaleEffect(bridge.isDraggingWindow ? 1.04 : 1.0)
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .named("panelRoot"))
                } action: { rect in
                    bridge.capsuleRectInRoot = rect
                }
            }
        }
        .frame(width: canvasWidth, height: canvasHeight, alignment: .center)
        .coordinateSpace(name: "panelRoot")
        .environment(\.controlActiveState, .active)
        .environment(\.colorScheme, resolvedColorScheme)
        .animation(.interactiveSpring(response: 0.24, dampingFraction: 0.68, blendDuration: 0.06), value: maxProximity)
        .animation(.snappy(duration: 0.24, extraBounce: 0.06), value: spaces)
        .animation(.spring(response: 0.26, dampingFraction: 0.76), value: isDockedChinMode)
        .animation(.spring(response: 0.20, dampingFraction: 0.80), value: bridge.isDraggingWindow)
        .onAppear {
            bridge.restingCapsuleSize = metrics.totalSize
        }
        .onChange(of: metrics.totalSize) { _, newSize in
            bridge.restingCapsuleSize = newSize
        }
        .onChange(of: validIDs) { _, current in
            bridge.itemRectsInRoot = bridge.itemRectsInRoot.filter { current.contains($0.key) }
        }
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
    let activeNamespace: Namespace.ID

    private var visibleWindows: [SpaceWindowIconItem] {
        iconStyle == .numbersOnly ? [] : space.windows
    }

    private var inactiveNumberColor: Color {
        if colorScheme == .dark {
            return .white.opacity(0.86 + 0.14 * Double(proximity))
        } else {
            return Color(red: 0.10, green: 0.12, blue: 0.16).opacity(0.80 + 0.20 * Double(proximity))
        }
    }

    private var inactiveTextShadowColor: Color {
        if space.isActive {
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
        let dynamicHeight = baseItemHeight + round(2.5 * proximity * scale)
        let innerCornerRadius = dynamicHeight / 2.0
        let itemMagnification = 1.0 + 0.19 * proximity
        let extraFluidSidePad = round(4.2 * proximity * scale)

        HStack(spacing: round(4.5 * scale)) {
            Text("\(space.number)")
                .font(.system(size: round(12.5 * scale), weight: space.isActive ? .bold : .semibold, design: .rounded))
                .monospacedDigit()
                .fixedSize()
                .foregroundStyle(space.isActive ? Color.white : inactiveNumberColor)
                .shadow(
                    color: inactiveTextShadowColor,
                    radius: (!space.isActive && glassStyle == .clear) ? 1.5 : 0.8,
                    y: colorScheme == .dark ? 0.5 : 0.0
                )

            if hasIcons {
                WorkspaceIconsClusterView(
                    windows: visibleWindows,
                    isActiveSpace: space.isActive,
                    iconStyle: iconStyle,
                    scale: scale,
                    hoverProximity: proximity
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
                            .strokeBorder(.white.opacity(0.35), lineWidth: 0.65)
                    }
                    .shadow(color: activeAccentColor.opacity(0.42), radius: 4 + 2 * proximity, y: 1)
                    .matchedGeometryEffect(id: "activeWorkspacePill", in: activeNamespace)
            } else if proximity > 0.08 {
                RoundedRectangle(cornerRadius: innerCornerRadius, style: .continuous)
                    .fill(.primary.opacity(0.11 * Double(proximity)))
            }
        }
        .scaleEffect(isPressed ? (itemMagnification * 0.93) : itemMagnification)
        .offset(y: -0.35 * proximity * scale)
        .zIndex(space.isActive ? 2.0 : Double(proximity))
        .contentShape(RoundedRectangle(cornerRadius: innerCornerRadius, style: .continuous))
        .animation(.interactiveSpring(response: 0.22, dampingFraction: 0.68, blendDuration: 0.05), value: proximity)
        .animation(.easeOut(duration: 0.11), value: isPressed)
    }
}

/// Renders expanded side-by-side icons for the active workspace, and a compact overlapping
/// stacked deck for inactive workspaces (which gently fans open on hover).
private struct WorkspaceIconsClusterView: View {
    let windows: [SpaceWindowIconItem]
    let isActiveSpace: Bool
    let iconStyle: SpaceIconStyle
    let scale: CGFloat
    let hoverProximity: CGFloat

    var body: some View {
        let iconSize = round(15.0 * scale)

        if isActiveSpace {
            // Active space: fully expanded side-by-side app icons
            HStack(spacing: round(3.5 * scale)) {
                ForEach(windows) { win in
                    AppWindowIconView(
                        item: win,
                        style: iconStyle,
                        isActiveSpace: true,
                        isStackedDeck: false,
                        size: iconSize
                    )
                    .transition(.blurReplace)
                }
            }
            .fixedSize()
        } else {
            // Inactive space: overlapping stacked deck (up to 3 icons + "+N" overflow badge),
            // fluidly fanning out slightly when cursor hovers near this space!
            let maxVisible = 3
            let visibleSlice = Array(windows.prefix(maxVisible))
            let overflowCount = max(0, windows.count - maxVisible)
            let stackedSpacing = (-7.0 + 5.2 * hoverProximity) * scale

            HStack(spacing: round(3.0 * scale)) {
                HStack(spacing: stackedSpacing) {
                    ForEach(Array(visibleSlice.enumerated()), id: \.element.id) { idx, win in
                        AppWindowIconView(
                            item: win,
                            style: iconStyle,
                            isActiveSpace: false,
                            isStackedDeck: visibleSlice.count > 1,
                            size: iconSize
                        )
                        .zIndex(Double(visibleSlice.count - idx))
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
    let isStackedDeck: Bool
    let size: CGFloat

    var body: some View {
        let image = AppIconCache.shared.icon(bundleID: item.bundleID, appName: item.appName)

        Group {
            switch style {
            case .appIcon:
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .opacity(isActiveSpace ? 1.0 : 0.92)
                    .shadow(
                        color: .black.opacity(isStackedDeck ? 0.42 : 0.26),
                        radius: isStackedDeck ? 1.6 : 1.2,
                        x: isStackedDeck ? -0.6 : 0.0,
                        y: 0.5
                    )

            case .monochrome:
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .saturation(0.0)
                    .contrast(1.25)
                    .opacity(isActiveSpace ? 0.98 : 0.78)
                    .shadow(
                        color: .black.opacity(isStackedDeck ? 0.35 : 0.18),
                        radius: 1.2,
                        x: isStackedDeck ? -0.5 : 0.0,
                        y: 0.4
                    )

            case .numbersOnly:
                EmptyView()
            }
        }
        .frame(width: size, height: size)
    }
}
