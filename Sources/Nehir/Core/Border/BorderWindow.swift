// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import QuartzCore

enum BorderPlacement: Equatable {
    case outside
    case inside
}

@MainActor
final class BorderWindow {
    struct Operations {
        var createBorderWindow: @MainActor (CGRect) -> UInt32
        var releaseBorderWindow: @MainActor (UInt32) -> Void
        var configureWindow: @MainActor (UInt32, Float, Bool) -> Void
        var setWindowTags: @MainActor (UInt32, UInt64) -> Void
        var createWindowContext: @MainActor (UInt32) -> CGContext?
        var setWindowShape: @MainActor (UInt32, CGRect) -> Void
        var flushWindow: @MainActor (UInt32) -> Void
        var transactionMove: @MainActor (UInt32, CGPoint) -> Void
        var transactionMoveAndOrder: @MainActor (UInt32, CGPoint, Int32, UInt32, SkyLightWindowOrder) -> Void
        var transactionHide: @MainActor (UInt32) -> Void
        var backingScaleForFrame: @MainActor (CGRect) -> CGFloat

        static let live = Self(
            createBorderWindow: { SkyLight.shared.createBorderWindow(frame: $0) },
            releaseBorderWindow: { SkyLight.shared.releaseBorderWindow($0) },
            configureWindow: { SkyLight.shared.configureWindow($0, resolution: $1, opaque: $2) },
            setWindowTags: { SkyLight.shared.setWindowTags($0, tags: $1) },
            createWindowContext: { SkyLight.shared.createWindowContext(for: $0) },
            setWindowShape: { SkyLight.shared.setWindowShape($0, frame: $1) },
            flushWindow: { SkyLight.shared.flushWindow($0) },
            transactionMove: { SkyLight.shared.transactionMove($0, origin: $1) },
            transactionMoveAndOrder: {
                SkyLight.shared.transactionMoveAndOrder($0, origin: $1, level: $2, relativeTo: $3, order: $4)
            },
            transactionHide: { SkyLight.shared.transactionHide($0) },
            backingScaleForFrame: { targetFrame in
                let targetScreen = NSScreen.screens.first(where: {
                    $0.frame.contains(targetFrame.center)
                }) ?? NSScreen.main ?? NSScreen.screens.first
                return targetScreen?.backingScaleFactor ?? 2.0
            }
        )
    }

    private var wid: UInt32 = 0
    private var context: CGContext?
    private var config: BorderConfig
    private let operations: Operations

    private var currentFrame: CGRect = .zero
    private var currentTargetFrame: CGRect = .zero
    private var currentTargetWid: UInt32 = 0
    private var origin: CGPoint = .zero
    private var needsRedraw = true
    private var isVisible = false
    private var lastOrderedTargetWid: UInt32 = 0
    private var lastConfiguredScale: CGFloat = 0
    private var currentCornerRadius: CGFloat = 9.0
    private var currentPlacement: BorderPlacement = .outside

    private let padding: CGFloat = 8.0
    private let defaultCornerRadius: CGFloat = 9.0
    private let orderingLevel: Int32 = 3

    init(config: BorderConfig, operations: Operations = .live) {
        self.config = config
        self.operations = operations
    }

    func destroy() {
        context = nil
        if wid != 0 {
            operations.releaseBorderWindow(wid)
            wid = 0
        }
        isVisible = false
        lastOrderedTargetWid = 0
        currentTargetWid = 0
        currentCornerRadius = defaultCornerRadius
        currentPlacement = .outside
    }

    @discardableResult
    func update(
        frame targetFrame: CGRect,
        targetWid: UInt32,
        cornerRadius: CGFloat = 9.0,
        forceOrdering: Bool = false,
        order: SkyLightWindowOrder = .below,
        placement: BorderPlacement = .outside
    ) -> Bool {
        let borderWidth = config.width
        let scale = operations.backingScaleForFrame(targetFrame)
        let resolvedCornerRadius = max(cornerRadius, 0)

        let geometry = borderGeometry(
            for: targetFrame,
            borderWidth: borderWidth,
            placement: placement,
            scale: scale
        )
        var frame = geometry.frame

        origin = ScreenCoordinateSpace.toWindowServer(rect: frame).origin
        frame.origin = .zero

        let drawingBounds = geometry.drawingBounds

        let createdWindow: Bool
        if wid == 0 {
            createWindow(frame: frame, scale: scale)
            guard wid != 0 else { return false }
            createdWindow = true
        } else {
            createdWindow = false
        }

        if scale != lastConfiguredScale, wid != 0 {
            operations.configureWindow(wid, Float(scale), false)
            lastConfiguredScale = scale
            needsRedraw = true
        }

        if frame.size != currentFrame.size {
            reshapeWindow(frame: frame)
            needsRedraw = true
        }
        if currentCornerRadius != resolvedCornerRadius || currentPlacement != placement {
            needsRedraw = true
        }
        currentTargetFrame = targetFrame
        currentTargetWid = targetWid
        currentFrame = frame
        currentCornerRadius = resolvedCornerRadius
        currentPlacement = placement

        if needsRedraw {
            draw(frame: frame, drawingBounds: drawingBounds)
        }

        let needsOrdering = forceOrdering || createdWindow || !isVisible || lastOrderedTargetWid != targetWid
        move(relativeTo: targetWid, needsOrdering: needsOrdering, order: order)
        isVisible = true
        lastOrderedTargetWid = targetWid
        return true
    }

    private func borderGeometry(
        for targetFrame: CGRect,
        borderWidth: CGFloat,
        placement: BorderPlacement,
        scale: CGFloat
    ) -> (frame: CGRect, drawingBounds: CGRect) {
        switch placement {
        case .outside:
            let borderOffset = -borderWidth - padding
            let frame = targetFrame.insetBy(dx: borderOffset, dy: borderOffset)
                .roundedToPhysicalPixels(scale: scale)
            let drawingBounds = CGRect(
                x: -borderOffset,
                y: -borderOffset,
                width: targetFrame.width,
                height: targetFrame.height
            )
            return (frame, drawingBounds)
        case .inside:
            let frame = targetFrame.roundedToPhysicalPixels(scale: scale)
            let drawingBounds = CGRect(origin: .zero, size: frame.size)
            return (frame, drawingBounds)
        }
    }

    private func createWindow(frame: CGRect, scale: CGFloat) {
        wid = operations.createBorderWindow(frame)
        guard wid != 0 else { return }

        operations.configureWindow(wid, Float(scale), false)
        lastConfiguredScale = scale

        let tags: UInt64 = (1 << 1) | (1 << 9)
        operations.setWindowTags(wid, tags)

        context = operations.createWindowContext(wid)
        context?.interpolationQuality = .none
    }

    private func reshapeWindow(frame: CGRect) {
        operations.setWindowShape(wid, frame)
    }

    private func draw(frame: CGRect, drawingBounds: CGRect) {
        guard let context else { return }
        needsRedraw = false

        let borderWidth = config.width
        let cornerRadius = currentCornerRadius
        let outerRadius = cornerRadius + borderWidth

        context.saveGState()
        context.clear(frame)

        let innerRect = drawingBounds.insetBy(dx: borderWidth, dy: borderWidth)
        let innerPath = CGPath(
            roundedRect: innerRect,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )

        let clipPath = CGMutablePath()
        clipPath.addRect(frame)
        clipPath.addPath(innerPath)
        context.addPath(clipPath)
        context.clip(using: .evenOdd)

        context.setFillColor(config.color.cgColor)

        let outerPath = CGPath(
            roundedRect: drawingBounds,
            cornerWidth: outerRadius,
            cornerHeight: outerRadius,
            transform: nil
        )
        context.addPath(outerPath)
        context.fillPath()

        context.restoreGState()
        context.flush()
        operations.flushWindow(wid)
    }

    private func move(
        relativeTo targetWid: UInt32,
        needsOrdering: Bool,
        order: SkyLightWindowOrder
    ) {
        if needsOrdering {
            operations.transactionMoveAndOrder(wid, origin, orderingLevel, targetWid, order)
            return
        }

        operations.transactionMove(wid, origin)
    }

    func reorder(relativeTo targetWid: UInt32, order: SkyLightWindowOrder = .below) {
        guard wid != 0 else { return }
        move(relativeTo: targetWid, needsOrdering: true, order: order)
        isVisible = true
        currentTargetWid = targetWid
        lastOrderedTargetWid = targetWid
    }

    func hide() {
        guard wid != 0 else { return }
        operations.transactionHide(wid)
        isVisible = false
        currentTargetWid = 0
        currentTargetFrame = .zero
        lastOrderedTargetWid = 0
    }

    func updateConfig(_ newConfig: BorderConfig) {
        let needsRedrawForColor = config.color != newConfig.color
        let needsRedrawForWidth = config.width != newConfig.width
        config = newConfig
        if needsRedrawForColor || needsRedrawForWidth {
            if wid != 0, isVisible, currentTargetWid != 0 {
                needsRedraw = true
                update(
                    frame: currentTargetFrame,
                    targetWid: currentTargetWid,
                    cornerRadius: currentCornerRadius,
                    placement: currentPlacement
                )
            }
        }
    }

    var windowId: UInt32? {
        wid == 0 ? nil : wid
    }
}
