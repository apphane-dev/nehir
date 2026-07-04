// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import CoreGraphics

struct Monitor: Identifiable, Hashable {
    struct ID: Hashable {
        let displayId: CGDirectDisplayID

        static let fallback = ID(displayId: CGMainDisplayID())
    }

    let id: ID
    let displayId: CGDirectDisplayID
    let frame: CGRect
    let visibleFrame: CGRect
    let hasNotch: Bool

    let name: String

    static func current() -> [Monitor] {
        NSScreen.screens.compactMap { screen -> Monitor? in
            guard let displayId = screen.displayId else { return nil }
            var hasNotch = false
            if #available(macOS 12.0, *) {
                hasNotch = screen.safeAreaInsets.top > 0
            }
            return Monitor(
                id: ID(displayId: displayId),
                displayId: displayId,
                frame: screen.frame,
                visibleFrame: DockReservation.stableVisibleFrame(
                    frame: screen.frame,
                    visibleFrame: screen.visibleFrame,
                    displayId: displayId
                ),
                hasNotch: hasNotch,
                name: screen.localizedName
            )
        }
    }

    static func fallback() -> Monitor {
        let frame = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let displayId = NSScreen.main?.displayId ?? CGMainDisplayID()
        var hasNotch = false
        if #available(macOS 12.0, *) {
            hasNotch = NSScreen.main?.safeAreaInsets.top ?? 0 > 0
        }
        return Monitor(
            id: .fallback,
            displayId: displayId,
            frame: frame,
            visibleFrame: frame,
            hasNotch: hasNotch,
            name: "Fallback"
        )
    }
}

extension Monitor {
    enum Orientation: String, Codable, Equatable {
        case horizontal
        case vertical
    }

    var autoOrientation: Orientation {
        frame.width >= frame.height ? .horizontal : .vertical
    }

    var isMain: Bool {
        let mainDisplayId = CGMainDisplayID()
        if mainDisplayId != 0 {
            return displayId == mainDisplayId
        }
        if let screen = NSScreen.screens.first(where: { $0.frame.origin == .zero }),
           let displayId = screen.displayId
        {
            return self.displayId == displayId
        }
        return frame.minX == 0 && frame.minY == 0
    }

    var workspaceAnchorPoint: CGPoint {
        frame.topLeftCorner
    }

    func relation(to monitor: Monitor) -> Orientation {
        let otherYRange = monitor.frame.minY ..< monitor.frame.maxY
        let myYRange = frame.minY ..< frame.maxY
        return myYRange.overlaps(otherYRange) ? .horizontal : .vertical
    }

    static func sortedByPosition(_ monitors: [Monitor]) -> [Monitor] {
        monitors.sorted {
            if $0.frame.minX != $1.frame.minX {
                return $0.frame.minX < $1.frame.minX
            }
            return $0.frame.maxY > $1.frame.maxY
        }
    }
}

extension NSScreen {
    var displayId: CGDirectDisplayID? {
        guard let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(screenNumber.uint32Value)
    }
}

/// Keeps the working area stable against transient loss of the Dock's reserved space.
///
/// `NSScreen.visibleFrame` reflects the *current* Dock reservation, which vanishes
/// globally whenever the active application suppresses the Dock via
/// `NSApplication.presentationOptions` (drop-down terminals commonly set
/// `.autoHideDock`). With a fixed Dock that makes the reported working area flap
/// between Dock-inset and full width as focus moves, retiling the workspace and
/// re-parking hidden windows each time. This helper remembers the last non-zero
/// Dock inset per display + Dock orientation + screen frame and keeps applying it
/// while the Dock is configured as fixed (`autohide == false`), so Nehir's working
/// area stays Dock-inset even when the instantaneous reservation is suppressed.
///
/// Known limitation: if a fixed Dock is relocated to another display without an
/// orientation or screen-frame change (bottom Dock dragged across displays with
/// separate Spaces), the previous display keeps its cached inset until the Dock
/// settings or display configuration change.
enum DockReservation {
    private static let lock = NSLock()
    // Sticky Dock inset per display. Keyed by displayId ONLY: keying by orientation or
    // frame breaks stickiness because CFPreferences("orientation") reads nil
    // intermittently (→ wrong key + wrong axis) and the reservation flaps.
    private nonisolated(unsafe) static var stickyInset: [CGDirectDisplayID: CGFloat] = [:]
    private nonisolated(unsafe) static var lastOrientation: [CGDirectDisplayID: String] = [:]
    private nonisolated(unsafe) static var lastAXProbe: (uptime: TimeInterval, barRect: CGRect?)?

    /// Drop every learned Dock inset and the cached AX probe so the next
    /// `stableVisibleFrame` re-derives the working area purely from the current live
    /// environment — the manual "re-evaluate like on app start" the shield button uses
    /// to reclaim the band when the Dock is genuinely gone.
    static func forgetStickyInsets() {
        lock.lock()
        defer { lock.unlock() }
        stickyInset.removeAll()
        lastAXProbe = nil
    }

    static func stableVisibleFrame(
        frame: CGRect,
        visibleFrame: CGRect,
        displayId: CGDirectDisplayID
    ) -> CGRect {
        let dockDomain = "com.apple.dock" as CFString
        // The Dock inset is treated as a stable property: once learned it is applied
        // permanently, regardless of the live reservation flapping (a quick-terminal or
        // an auto-hide Dock hides/reveals it constantly). This keeps the shield and the
        // working area rock-stable — no re-tile when the Dock hides. We intentionally do
        // NOT try to detect auto-hide and reclaim the band.

        // CFPreferences("orientation") reads nil intermittently; falling back to
        // "bottom" would pick the wrong axis and drop the reservation. Reuse the last
        // known orientation for this display when the live read is missing.
        let rawOrientation = CFPreferencesCopyAppValue("orientation" as CFString, dockDomain) as? String
        lock.lock()
        let orientation = rawOrientation ?? lastOrientation[displayId] ?? "bottom"
        // A genuine orientation change invalidates the sticky inset for this display.
        if let rawOrientation, lastOrientation[displayId] != nil, lastOrientation[displayId] != rawOrientation {
            stickyInset[displayId] = nil
        }
        if let rawOrientation { lastOrientation[displayId] = rawOrientation }
        let sticky = stickyInset[displayId] ?? 0
        lock.unlock()

        // The Dock lives on ONE display. If its bar is genuinely on ANOTHER connected
        // display, macOS can still report a phantom side reservation on this display
        // (seen on a DELL offset next to a built-in: a bogus 200px right inset with
        // nothing there). Reclaim that space on the Dock's orientation axis, keeping the
        // orthogonal menu-bar reservation from visibleFrame.
        //
        // Require the bar to actually land on some OTHER screen: a Dock hidden by a
        // quick-terminal can report offscreen AX coords that intersect NO display, and
        // treating that as "Dock on another display" would wrongly clear a single
        // display's learned inset (working area jumps to full width, shield disappears).
        if dockIsOnAnotherDisplay(than: frame) {
            lock.lock()
            stickyInset[displayId] = nil
            lock.unlock()
            var corrected = visibleFrame
            switch orientation {
            case "left":
                corrected.size.width = corrected.maxX - frame.minX
                corrected.origin.x = frame.minX
            case "right":
                corrected.size.width = frame.maxX - corrected.origin.x
            default:
                corrected.size.height = corrected.maxY - frame.minY
                corrected.origin.y = frame.minY
            }
            return corrected
        }

        // visibleFrame is AppKit bottom-left based: a right Dock shrinks width, a left
        // Dock raises minX, a bottom Dock raises minY.
        let currentInset: CGFloat = switch orientation {
        case "left": visibleFrame.minX - frame.minX
        case "right": frame.maxX - visibleFrame.maxX
        default: visibleFrame.minY - frame.minY
        }

        let derivedInset = axDerivedInset(frame: frame, orientation: orientation)

        lock.lock()
        defer { lock.unlock() }
        // The Dock inset is a STABLE property of a fixed Dock. It must NOT follow the
        // live reservation, which a quick-terminal (or any app that hides the Dock via
        // presentationOptions) suppresses transiently — following it would re-tile every
        // toggle. Update the sticky inset only from an authoritative positive reading:
        // the Dock's AX bar geometry when available, else the live reservation to
        // bootstrap before the bar is readable. A transient suppression (both zero)
        // leaves the sticky value untouched. A real Dock resize updates the AX bar and
        // thus the sticky value; an orientation change already cleared it above.
        // A real Dock never reserves more than a fraction of the display. Reject an
        // implausibly large inset — during display (re)configuration the frame/visibleFrame
        // can be momentarily inconsistent and yield a huge bogus inset that would otherwise
        // get learned and produce a giant shield / squished tiling on a display.
        let dockAxisSize = (orientation == "left" || orientation == "right") ? frame.width : frame.height
        let maxPlausibleInset = dockAxisSize * 0.33

        if let derivedInset, derivedInset > 0.5, derivedInset <= maxPlausibleInset {
            stickyInset[displayId] = derivedInset
        } else if stickyInset[displayId] == nil, currentInset > 0.5, currentInset <= maxPlausibleInset {
            stickyInset[displayId] = currentInset
        }
        var inset = stickyInset[displayId] ?? sticky
        if inset > maxPlausibleInset {
            stickyInset[displayId] = nil
            inset = 0
        }
        guard inset > 0.5 else { return visibleFrame }

        // Apply the inset against the STABLE physical frame edge (not the flapping
        // visibleFrame), so the working width stays constant whether or not the Dock is
        // currently reserving. Preserve visibleFrame's orthogonal edges — they carry the
        // menu-bar reservation, which is unrelated to the Dock.
        var corrected = visibleFrame
        switch orientation {
        case "left":
            let newMinX = frame.minX + inset
            corrected.size.width = corrected.maxX - newMinX
            corrected.origin.x = newMinX
        case "right":
            corrected.size.width = (frame.maxX - inset) - corrected.origin.x
        default:
            let newMinY = frame.minY + inset
            corrected.size.height = corrected.maxY - newMinY
            corrected.origin.y = newMinY
        }
        return corrected
    }

    /// Reads the Dock's bar rect (its `AXList` child) and converts it to an edge
    /// inset for `frame`. AX coordinates are global top-left based; x values match
    /// AppKit globals directly, y must be flipped against the primary screen height.
    /// Memoized for a few seconds — `Monitor.current()` can be called in bursts.
    private static func axDerivedInset(frame: CGRect, orientation: String) -> CGFloat? {
        let now = ProcessInfo.processInfo.systemUptime
        let barRect: CGRect?
        // Only serve a cached probe when it actually found the bar. A nil probe (Dock
        // AX not queryable yet, e.g. right after launch) must NOT be cached for 5s —
        // otherwise the inset stays unknown and the viewport stays full-width until a
        // manual restart. Keep re-probing until the Dock answers, then cache 5s.
        if let probe = lastAXProbe, now - probe.uptime < 5.0, probe.barRect != nil {
            barRect = probe.barRect
        } else {
            let fresh = dockBarRect()
            if fresh != nil {
                lastAXProbe = (now, fresh)
            }
            barRect = fresh
        }
        guard let barRect else { return nil }

        switch orientation {
        case "left":
            guard barRect.minX >= frame.minX, barRect.maxX <= frame.midX else { return nil }
            return barRect.maxX - frame.minX
        case "right":
            guard barRect.maxX <= frame.maxX, barRect.minX >= frame.midX else { return nil }
            return frame.maxX - barRect.minX
        default:
            // Bottom Dock: convert the bar's AX top-left y to an AppKit bottom inset.
            let primaryHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
                ?? NSScreen.main?.frame.height
            guard let primaryHeight else { return nil }
            let barTopAppKit = primaryHeight - barRect.minY
            return barTopAppKit - frame.minY
        }
    }

    /// The Dock bar's rect in AppKit global coordinates (bottom-left origin), or nil if
    /// the Dock is not readable. The Dock lives on ONE display at a time, so the shield
    /// uses this to avoid drawing on a display that has no Dock. Memoized ~5s.
    static func dockBarAppKitRect() -> CGRect? {
        let now = ProcessInfo.processInfo.systemUptime
        let bar: CGRect?
        if let probe = lastAXProbe, now - probe.uptime < 5.0, probe.barRect != nil {
            bar = probe.barRect
        } else {
            let fresh = dockBarRect()
            if fresh != nil { lastAXProbe = (now, fresh) }
            bar = fresh
        }
        guard let bar else { return nil }
        let primaryHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height
        guard let primaryHeight else { return nil }
        // AX is global top-left; flip y to AppKit bottom-left.
        return CGRect(x: bar.minX, y: primaryHeight - bar.maxY, width: bar.width, height: bar.height)
    }

    /// True only when the Dock bar is genuinely on a connected display OTHER than
    /// `frame`. A hidden Dock (e.g. a quick terminal is up) can report offscreen AX
    /// coordinates that intersect no display at all — this returns false for that case,
    /// so a single display's learned inset and its shield are never wrongly dropped.
    static func dockIsOnAnotherDisplay(than frame: CGRect) -> Bool {
        guard let bar = dockBarAppKitRect() else { return false }
        return !bar.intersects(frame)
            && NSScreen.screens.contains { $0.frame != frame && $0.frame.intersects(bar) }
    }

    private static func dockBarRect() -> CGRect? {
        guard let dock = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return nil }
        let axDock = AXUIElementCreateApplication(dock.processIdentifier)
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axDock, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement]
        else { return nil }
        for child in children {
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef)
            guard (roleRef as? String) == kAXListRole as String else { continue }
            var posRef: CFTypeRef?
            var sizeRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString, &posRef) == .success,
                  AXUIElementCopyAttributeValue(child, kAXSizeAttribute as CFString, &sizeRef) == .success,
                  let posValue = posRef, let sizeValue = sizeRef
            else { continue }
            var position = CGPoint.zero
            var size = CGSize.zero
            guard AXValueGetValue(posValue as! AXValue, .cgPoint, &position),
                  AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
                  size.width > 0, size.height > 0
            else { continue }
            return CGRect(origin: position, size: size)
        }
        return nil
    }
}

extension CGRect {
    var topLeftCorner: CGPoint {
        CGPoint(x: minX, y: maxY)
    }
}

extension CGRect {
    func distanceSquared(to point: CGPoint) -> CGFloat {
        // Keep fallback distance calculations aligned with CGRect.contains(_:),
        // which treats maxX/maxY as exclusive bounds.
        let maxInclusiveX = maxX > minX ? maxX.nextDown : minX
        let maxInclusiveY = maxY > minY ? maxY.nextDown : minY
        let clampedX = min(max(point.x, minX), maxInclusiveX)
        let clampedY = min(max(point.y, minY), maxInclusiveY)
        let dx = point.x - clampedX
        let dy = point.y - clampedY
        return dx * dx + dy * dy
    }
}

extension CGPoint {
    func monitorApproximation(in monitors: [Monitor]) -> Monitor? {
        if let containing = monitors.first(where: { $0.frame.contains(self) }) {
            return containing
        }
        return monitors.min(by: { $0.frame.distanceSquared(to: self) < $1.frame.distanceSquared(to: self) })
    }
}
