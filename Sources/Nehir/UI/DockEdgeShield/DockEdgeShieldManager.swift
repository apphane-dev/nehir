// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import CoreGraphics

@MainActor
final class DockEdgeShieldManager {
    private enum Edge {
        case left
        case right
    }

    private struct ShieldGeometry: Equatable {
        let frame: CGRect
        let monitorId: Monitor.ID
        let edge: Edge
        /// Where the decorative logo is drawn, in global coordinates (top of the shield).
        let logoGlobal: CGRect?
        /// The button, centered in the shield, in global coordinates.
        let buttonGlobal: CGRect?
    }

    private final class ShieldPanel: NSPanel {
        override var canBecomeKey: Bool {
            false
        }

        override var canBecomeMain: Bool {
            false
        }
    }

    private final class ShieldView: NSView {
        private static let logoImage: NSImage? = {
            guard let url = Bundle.module.url(forResource: "Logo", withExtension: "png") else { return nil }
            return NSImage(contentsOf: url)
        }()

        var edge: Edge = .right {
            didSet { needsDisplay = true }
        }

        /// User-configurable fill (color + opacity baked into alpha).
        var fillColor: NSColor = .init(calibratedWhite: 0.12, alpha: 1.0) {
            didSet { needsDisplay = true }
        }

        /// Where to draw the decorative logo, in VIEW-LOCAL coordinates. Anchored just
        /// above the Dock bar's top edge so it rides the Dock as it grows/shrinks.
        var logoRect: NSRect? {
            didSet { needsDisplay = true }
        }

        /// Experimental button hit-area, in VIEW-LOCAL coordinates. Placed behind the
        /// Dock bar, so it's covered while the Dock is up and reachable when it hides.
        /// Only this rect captures clicks; the rest of the shield stays click-through.
        var buttonRect: NSRect? {
            didSet { needsDisplay = true }
        }

        var onButtonTap: (() -> Void)?
        var onLogoTap: (() -> Void)?
        private var buttonPressed = false {
            didSet { needsDisplay = true }
        }

        override var isFlipped: Bool {
            true
        }

        // Deliver the click even when the app/panel isn't active (non-activating panel).
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        // Re-resolve a theme-following fill color when light/dark switches.
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsDisplay = true
        }

        // Capture clicks ONLY inside the interactive rects (button, logo); return nil
        // elsewhere so the event passes through to whatever is behind the shield.
        override func hitTest(_ point: NSPoint) -> NSView? {
            let local = convert(point, from: superview)
            let inButton = buttonRect?.contains(local) ?? false
            let inLogo = logoRect?.contains(local) ?? false
            return (inButton || inLogo) ? self : nil
        }

        override func mouseDown(with event: NSEvent) {
            let local = convert(event.locationInWindow, from: nil)
            buttonPressed = (buttonRect?.contains(local) ?? false)
        }

        override func mouseUp(with event: NSEvent) {
            let local = convert(event.locationInWindow, from: nil)
            if buttonRect?.contains(local) == true {
                onButtonTap?()
            } else if logoRect?.contains(local) == true {
                onLogoTap?()
            }
            buttonPressed = false
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard bounds.width > 0, bounds.height > 0 else { return }

            // Opaque rounded panel (no translucency, per design): masks any window
            // parked in the band. Fill the FULL bounds — the straight edges stay flush
            // (no gap that would leak the parked window's 1px sliver); only the corners
            // curve inward, and those sit in the Dock area.
            let cornerRadius = min(min(bounds.width, bounds.height) * 0.5, 12)
            let path = NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius)
            fillColor.setFill()
            path.fill()
            path.addClip()

            // Decorative Nehir wordmark, drawn as-is at 85% opacity, sitting on top of
            // the Dock. If it doesn't read on the dark band, tint it via a template.
            if let logoRect, logoRect.height > 0, let logo = Self.logoImage {
                logo.draw(
                    in: logoRect,
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 0.85,
                    respectFlipped: true,
                    hints: nil
                )
            }

            // Experimental button, drawn behind the Dock (only visible when the Dock is
            // hidden). A simple circle with a centered glyph; placeholder action.
            if let buttonRect, buttonRect.width > 4 {
                let circle = NSBezierPath(ovalIn: buttonRect)
                NSColor(calibratedWhite: buttonPressed ? 0.45 : 0.32, alpha: 1.0).setFill()
                circle.fill()
                NSColor(calibratedWhite: 1.0, alpha: 0.25).setStroke()
                circle.lineWidth = 1
                circle.stroke()

                // Chevron pointing toward the screen edge (the Dock side).
                let symbolName = edge == .right ? "chevron.right" : "chevron.left"
                let pointSize = min(buttonRect.width, buttonRect.height) * 0.42
                let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
                if let chevron = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                    .withSymbolConfiguration(config)
                {
                    let tinted = NSImage(size: chevron.size, flipped: false) { rect in
                        chevron.draw(in: rect)
                        NSColor(calibratedWhite: 0.95, alpha: 0.9).set()
                        rect.fill(using: .sourceAtop)
                        return true
                    }
                    tinted.draw(
                        in: NSRect(
                            x: buttonRect.midX - chevron.size.width / 2,
                            y: buttonRect.midY - chevron.size.height / 2,
                            width: chevron.size.width,
                            height: chevron.size.height
                        ),
                        from: .zero,
                        operation: .sourceOver,
                        fraction: 1.0,
                        respectFlipped: true,
                        hints: nil
                    )
                }
            }
        }
    }

    var screenProvider: @MainActor (CGDirectDisplayID) -> NSScreen? = { displayId in
        NSScreen.screens.first(where: { $0.displayId == displayId })
    }

    /// Sink for runtime-trace lines. Wired to `AXManager.recordFrameApplyTrace` so
    /// shield activity lands in the same trace as parking. Without this the shield
    /// is invisible to diagnostics — you cannot tell from a trace whether a panel
    /// exists or why `shieldGeometry` returned nil.
    var trace: ((String) -> Void)?

    /// Invoked when the shield button is clicked. The owner wires this to re-evaluate the
    /// Dock environment (as at app start), so the shield hides itself when the Dock is
    /// genuinely gone but couldn't be detected automatically.
    var onButtonTap: (() -> Void)?

    /// Invoked when the shield logo is clicked. Wired to open the About page.
    var onLogoTap: (() -> Void)?

    /// Supplies the resolved outer layout margins for a monitor, so the shield's
    /// vertical extent matches the tiled columns (which are inset by the outer gaps)
    /// instead of spanning the full working area.
    var outerGapsProvider: (@MainActor (Monitor) -> LayoutGaps.OuterGaps)?

    /// Experimental feature gate — the shield only appears when the user opts in.
    var isEnabled = false
    /// User-configurable fill color (hex) and opacity, applied to every shield. When
    /// `fillColorDarkHex` is non-empty the fill follows the system theme: light hex in
    /// light appearance, dark hex in dark appearance.
    var fillColorHex = "#1F1F1F"
    var fillColorDarkHex = ""
    var fillOpacity: Double = 1.0

    private var fillColor: NSColor {
        let alpha = CGFloat(max(0, min(1, fillOpacity)))
        let light = (NSColor(hexString: fillColorHex) ?? NSColor(calibratedWhite: 0.12, alpha: 1.0))
            .withAlphaComponent(alpha)
        guard !fillColorDarkHex.isEmpty, let darkBase = NSColor(hexString: fillColorDarkHex) else {
            return light
        }
        let dark = darkBase.withAlphaComponent(alpha)
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    private var panelsByMonitor: [Monitor.ID: ShieldPanel] = [:]
    private var geometriesByMonitor: [Monitor.ID: ShieldGeometry] = [:]
    private let surfaceCoordinator = SurfaceCoordinator.shared

    func update(monitors: [Monitor]) {
        // Experimental opt-in: with the feature off, keep no shields at all.
        guard isEnabled else {
            if !panelsByMonitor.isEmpty { cleanup() }
            return
        }

        var liveMonitorIds = Set<Monitor.ID>()

        for monitor in monitors {
            guard let geometry = shieldGeometry(for: monitor) else {
                if panelsByMonitor[monitor.id] != nil {
                    trace?("dockShield.remove reason=noGeometry monitor=\(monitor.id.displayId)")
                }
                removeShield(for: monitor.id)
                continue
            }
            liveMonitorIds.insert(monitor.id)
            let existing = panelsByMonitor[monitor.id]
            // Idempotent: this runs on every layout refresh so it can self-heal after
            // the Dock reservation settles, but skip the AppKit work when unchanged.
            if existing != nil, geometriesByMonitor[monitor.id] == geometry {
                continue
            }
            let panel = existing ?? createShield(for: monitor)
            panelsByMonitor[monitor.id] = panel
            geometriesByMonitor[monitor.id] = geometry
            _ = screenProvider(monitor.displayId)
            let view = panel.contentView as? ShieldView
            view?.edge = geometry.edge
            view?.fillColor = fillColor
            panel.setFrame(geometry.frame, display: true)
            // Convert the global logo rect into the flipped view's local space.
            view?.logoRect = geometry.logoGlobal.map { logo in
                NSRect(
                    x: logo.minX - geometry.frame.minX,
                    y: geometry.frame.maxY - logo.maxY,
                    width: logo.width,
                    height: logo.height
                )
            }
            view?.buttonRect = geometry.buttonGlobal.map { button in
                NSRect(
                    x: button.minX - geometry.frame.minX,
                    y: geometry.frame.maxY - button.maxY,
                    width: button.width,
                    height: button.height
                )
            }
            view?.onButtonTap = { [weak self] in
                self?.trace?("dockShield.button tapped monitor=\(monitor.id.displayId)")
                self?.onButtonTap?()
            }
            view?.onLogoTap = { [weak self] in
                self?.trace?("dockShield.logo tapped monitor=\(monitor.id.displayId)")
                self?.onLogoTap?()
            }
            panel.orderFrontRegardless()
            trace?(
                "dockShield.\(existing == nil ? "create" : "update") monitor=\(monitor.id.displayId) "
                    + "edge=\(geometry.edge) frame=\(LayoutTrace.rect(geometry.frame)) level=\(panel.level.rawValue) "
                    + "logo=\(LayoutTrace.rect(geometry.logoGlobal)) button=\(LayoutTrace.rect(geometry.buttonGlobal)) "
                    + "visibleFrame=\(LayoutTrace.rect(monitor.visibleFrame)) monitorFrame=\(LayoutTrace.rect(monitor.frame))"
            )
        }

        for monitorId in Set(panelsByMonitor.keys).subtracting(liveMonitorIds) {
            trace?("dockShield.remove reason=monitorGone monitor=\(monitorId.displayId)")
            removeShield(for: monitorId)
        }
    }

    /// Live snapshot for the runtime-state dump (written fresh at capture time, so
    /// unlike the frame-apply ring buffer it is never evicted).
    func debugStateDump() -> String {
        guard !panelsByMonitor.isEmpty else { return "no-shields" }
        return panelsByMonitor.map { monitorId, panel in
            let geometry = geometriesByMonitor[monitorId]
            let edge = geometry.map { "\($0.edge)" } ?? "?"
            return "monitor=\(monitorId.displayId) edge=\(edge) frame=\(LayoutTrace.rect(panel.frame)) "
                + "wantFrame=\(LayoutTrace.rect(geometry?.frame)) "
                + "logo=\(LayoutTrace.rect(geometry?.logoGlobal)) button=\(LayoutTrace.rect(geometry?.buttonGlobal)) visible=\(panel.isVisible) level=\(panel.level.rawValue)"
        }.joined(separator: "\n")
    }

    /// Push the current fill color/opacity to all live shields (call after the user
    /// changes the shield color or opacity so it applies without waiting for a relayout).
    func applyAppearance() {
        let color = fillColor
        for panel in panelsByMonitor.values {
            (panel.contentView as? ShieldView)?.fillColor = color
        }
    }

    func cleanup() {
        for monitorId in Array(panelsByMonitor.keys) {
            removeShield(for: monitorId)
        }
    }

    private func createShield(for monitor: Monitor) -> ShieldPanel {
        let panel = ShieldPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.hasShadow = false
        panel.canHide = false
        // Accept mouse events so the button can be clicked; the content view's hitTest
        // returns nil outside the button rect, so everywhere else stays click-through.
        panel.ignoresMouseEvents = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) - 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = ShieldView(frame: .zero)

        surfaceCoordinator.register(
            window: panel,
            id: surfaceId(for: monitor.id),
            policy: SurfacePolicy(
                kind: .utility,
                hitTestPolicy: .passthrough,
                capturePolicy: .excluded,
                suppressesManagedFocusRecovery: false
            )
        )
        return panel
    }

    private func removeShield(for monitorId: Monitor.ID) {
        guard let panel = panelsByMonitor.removeValue(forKey: monitorId) else { return }
        geometriesByMonitor.removeValue(forKey: monitorId)
        surfaceCoordinator.unregister(id: surfaceId(for: monitorId))
        panel.orderOut(nil)
    }

    private func shieldGeometry(for monitor: Monitor) -> ShieldGeometry? {
        // Fill the ENTIRE Dock band (from the workspace edge to the physical screen
        // edge), not a thin rail. A window parked at `visibleFrame.max` rests inside
        // this band; the shield sits below the Dock (level dockWindow-1) and masks the
        // parked window so the band reads as a consistent backdrop behind the
        // translucent Dock instead of leaking window/desktop content.
        // Only refuse to shield when the Dock is genuinely on ANOTHER connected display
        // (prevents a spurious shield on a secondary display). A hidden Dock reporting
        // offscreen AX coords intersects no display and must NOT block this display's
        // shield — otherwise the shield never restores after the Dock reappears.
        if DockReservation.dockIsOnAnotherDisplay(than: monitor.frame) {
            if panelsByMonitor[monitor.id] != nil {
                trace?("dockShield.skip monitor=\(monitor.id.displayId) reason=dockOnOtherDisplay")
            }
            return nil
        }

        let leftInset = monitor.visibleFrame.minX - monitor.frame.minX
        let rightInset = monitor.frame.maxX - monitor.visibleFrame.maxX
        // Windows park 1px inside the working edge (visibleFrame.max-1 / min+1). Extend
        // the shield 1px past the workspace edge so it covers that revealed sliver.
        let parkCover: CGFloat = 1

        // Match the tiled layout: inset the shield's vertical extent by the top/bottom
        // outer gaps so it aligns with the parked columns (which sit inside the working
        // area), instead of spanning the full visibleFrame height into the margins.
        let gaps = outerGapsProvider?(monitor) ?? .zero
        let bandY = monitor.visibleFrame.minY + gaps.bottom
        let bandHeight = max(0, monitor.visibleFrame.height - gaps.top - gaps.bottom)

        if rightInset > 0.5 {
            let column = CGRect(
                x: monitor.visibleFrame.maxX - parkCover,
                y: bandY,
                width: rightInset + parkCover,
                height: bandHeight
            )
            return ShieldGeometry(
                frame: column,
                monitorId: monitor.id,
                edge: .right,
                logoGlobal: logoRect(column: column),
                buttonGlobal: buttonRect(column: column)
            )
        }

        if leftInset > 0.5 {
            let column = CGRect(
                x: monitor.frame.minX,
                y: bandY,
                width: leftInset + parkCover,
                height: bandHeight
            )
            return ShieldGeometry(
                frame: column,
                monitorId: monitor.id,
                edge: .left,
                logoGlobal: logoRect(column: column),
                buttonGlobal: buttonRect(column: column)
            )
        }

        trace?(
            "dockShield.skip monitor=\(monitor.id.displayId) reason=noReservedEdge "
                + "leftInset=\(String(format: "%.1f", leftInset)) rightInset=\(String(format: "%.1f", rightInset)) "
                + "visibleFrame=\(LayoutTrace.rect(monitor.visibleFrame)) monitorFrame=\(LayoutTrace.rect(monitor.frame))"
        )
        return nil
    }

    /// A small wordmark centered horizontally and anchored near the TOP of the shield.
    /// Fixed position — no Dock measurement.
    private func logoRect(column: CGRect) -> CGRect? {
        let sidePadding: CGFloat = 8
        let topPadding: CGFloat = 12
        let aspect: CGFloat = 313.0 / 1024.0 // Logo.png height / width

        let width = max(0, column.width - 2 * sidePadding)
        guard width > 4 else { return nil }
        let height = width * aspect
        // column.maxY is the top edge (AppKit bottom-left). Place the logo just below it.
        return CGRect(
            x: column.midX - width / 2,
            y: column.maxY - topPadding - height,
            width: width,
            height: height
        )
    }

    /// A round button at the exact center of the shield. It sits behind the Dock (which
    /// is vertically centered on the same edge), so it's covered while the Dock is up and
    /// exposed when the Dock hides — no Dock measurement needed.
    private func buttonRect(column: CGRect) -> CGRect? {
        let diameter = min(column.width - 12, 44)
        guard diameter > 8 else { return nil }
        return CGRect(
            x: column.midX - diameter / 2,
            y: column.midY - diameter / 2,
            width: diameter,
            height: diameter
        )
    }

    private func surfaceId(for monitorId: Monitor.ID) -> String {
        "dock-edge-shield-\(monitorId.displayId)"
    }
}

private extension NSColor {
    /// Parses "#RRGGBB" / "RRGGBB" (and "#RGB") into an sRGB color. Returns nil on a
    /// malformed string so the caller can fall back to a default.
    convenience init?(hexString: String) {
        var hex = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255.0,
            green: CGFloat((value >> 8) & 0xFF) / 255.0,
            blue: CGFloat(value & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}
