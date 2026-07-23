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

    static func visibleOverlapArea(of frame: CGRect, across monitors: [Monitor]) -> CGFloat {
        monitors.reduce(CGFloat.zero) { total, monitor in
            let overlap = monitor.visibleFrame.intersection(frame)
            return overlap.isNull ? total : total + overlap.width * overlap.height
        }
    }

    static func isFrameOnScreen(
        _ frame: CGRect,
        across monitors: [Monitor],
        minimumVisibleFraction: CGFloat = 0.5
    ) -> Bool {
        let frameArea = frame.width * frame.height
        guard frameArea > 0 else { return false }
        return visibleOverlapArea(of: frame, across: monitors) >= frameArea * minimumVisibleFraction
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

/// Keeps a fixed Dock's working area stable against transient loss of its reserved
/// space, and reclaims the band for an auto-hide Dock.
///
/// `NSScreen.visibleFrame` reflects the *current* Dock reservation, which vanishes
/// globally whenever the active application suppresses the Dock via
/// `NSApplication.presentationOptions` (drop-down terminals commonly set
/// `.autoHideDock`). With a fixed Dock that makes the reported working area flap
/// between Dock-inset and full width as focus moves, retiling the workspace and
/// re-parking hidden windows each time. This helper remembers the last non-zero
/// Dock inset per display + Dock orientation + screen frame and keeps applying it,
/// so Nehir's working area stays Dock-inset even when the instantaneous reservation
/// is suppressed.
///
/// This stabilization is only correct for a fixed Dock. An auto-hide Dock reserves
/// no permanent band — its AX bar only animates on-screen during a reveal — so when
/// the persistent `com.apple.dock autohide` preference is authoritatively enabled,
/// the learned inset is dropped and the Dock-orientation axis reclaimed (#163). A
/// nil/unreadable preference is treated conservatively as fixed.
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
    // Last physical frame seen per display. A sticky inset is a fixed pixel count keyed
    // to a specific physical edge, so a value learned under one resolution/mode is
    // meaningless under another (e.g. a 328px right inset learned at 2056-wide produces
    // a giant phantom shield at 1728-wide). When a display's frame changes we drop its
    // sticky and skip re-learning for that one pass, so a frame/bar read straddling the
    // transition cannot immediately re-learn the mode-width delta.
    private nonisolated(unsafe) static var lastFrame: [CGDirectDisplayID: CGRect] = [:]
    // Global (not per-display) memo of the persistent Dock autohide preference:
    // (monotonic uptime of the last authoritative read, that value). Only successful
    // reads are stored; a transient-nil read leaves the last authoritative value in
    // place so reconnect churn cannot momentarily re-arm the fixed-Dock learn (#163).
    private nonisolated(unsafe) static var lastAutohideProbe: (uptime: TimeInterval, value: Bool)?

    /// Drop every learned Dock inset and the cached AX probe so the next
    /// `stableVisibleFrame` re-derives the working area purely from the current live
    /// environment — the manual "re-evaluate like on app start" the shield button uses
    /// to reclaim the band when the Dock is genuinely gone.
    static func forgetStickyInsets() {
        lock.lock()
        defer { lock.unlock() }
        stickyInset.removeAll()
        lastAXProbe = nil
        lastAutohideProbe = nil // #163: re-read live autohide on manual re-evaluate.
    }

    /// Pure memo policy for `dockAutohideEnabled`, extracted so the TTL/fallback rules
    /// are unit-testable without touching CFPreferences or the clock. Given the current
    /// uptime, the TTL, the cached probe, and a freshly-read value (`nil` when the read
    /// was unreadable), returns the value to report and the memo to store next:
    /// - within TTL: report the cached value with the memo unchanged (no re-probe);
    /// - TTL expired with a readable `fresh`: report it and re-time the memo;
    /// - TTL expired but unreadable: fall back to the cached value and leave the memo
    ///   untouched, so a transient-nil read cannot overwrite the last authoritative one.
    static func resolveAutohideMemo(
        now: TimeInterval,
        ttl: TimeInterval,
        cached: (uptime: TimeInterval, value: Bool)?,
        fresh: Bool?
    ) -> (value: Bool?, memo: (uptime: TimeInterval, value: Bool)?) {
        if let cached, now - cached.uptime < ttl {
            return (cached.value, cached)
        }
        if let fresh {
            return (fresh, (now, fresh))
        }
        return (cached?.value, cached)
    }

    /// The persistent `com.apple.dock autohide` preference, or nil when it has never
    /// been readable. Returns true only when auto-hide is authoritatively enabled;
    /// callers treat nil (and false) conservatively as a fixed Dock.
    ///
    /// Memoized for `ttl` seconds against a monotonic clock so a burst of
    /// `Monitor.current()` rebuilds triggers at most one `CFPreferencesAppSynchronize`.
    /// After a first authoritative read, a transient unreadable read returns the last
    /// known value rather than nil, so reconnect churn cannot momentarily re-arm the
    /// fixed-Dock learn. Never holds `DockReservation.lock` across the CFPreferences
    /// calls (those can block); the lock only guards the tiny memo read and write.
    private static func dockAutohideEnabled() -> Bool? {
        let ttl: TimeInterval = 1.0
        let now = ProcessInfo.processInfo.systemUptime

        // 1. Fast path: return a fresh memoized value without syncing. Read the memo
        //    under the lock, then release it before any CFPreferences call.
        lock.lock()
        let cached = lastAutohideProbe
        lock.unlock()
        if let cached, now - cached.uptime < ttl {
            return cached.value
        }

        // 2. TTL expired (or nothing cached yet): synchronize + read OUTSIDE the lock.
        let dockDomain = "com.apple.dock" as CFString
        CFPreferencesAppSynchronize(dockDomain)
        let raw = CFPreferencesCopyAppValue("autohide" as CFString, dockDomain)
        let fresh: Bool? =
            if let flag = raw as? Bool { flag }
            else if let number = raw as? NSNumber { number.boolValue }
            else { nil }

        // 3. Apply the fresh read (or fall back) under the lock via the pure policy, no
        //    CFPreferences call held. Re-read the memo so a concurrent refresh is honored.
        lock.lock()
        defer { lock.unlock() }
        let (value, memo) = resolveAutohideMemo(now: now, ttl: ttl, cached: lastAutohideProbe, fresh: fresh)
        lastAutohideProbe = memo
        return value
    }

    static func stableVisibleFrame(
        frame: CGRect,
        visibleFrame: CGRect,
        displayId: CGDirectDisplayID
    ) -> CGRect {
        let dockDomain = "com.apple.dock" as CFString
        // A fixed Dock's inset is treated as a stable property: once learned it is applied
        // permanently, regardless of the live reservation flapping (a quick-terminal that
        // suppresses the Dock via presentationOptions hides/reveals it constantly). This
        // keeps the shield and the working area rock-stable — no re-tile when the Dock
        // hides. An auto-hide Dock is different: it reserves no permanent band, so it is
        // detected via the persistent com.apple.dock autohide preference (see the gate
        // above) and has its band reclaimed rather than learned (#163).

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
        // A display mode/resolution change invalidates any inset learned under the old
        // frame. Drop the stale sticky and skip re-learning this pass (see the learn
        // block below), so a frame/bar read straddling the transition cannot re-learn
        // the mode-width delta as a phantom side inset. First sighting (nil → value) is
        // not a change; a Dock hide/show does not alter the physical frame, so the
        // sticky still survives transient suppression.
        let frameChanged = (lastFrame[displayId].map { $0 != frame }) ?? false
        lastFrame[displayId] = frame
        if frameChanged {
            stickyInset[displayId] = nil
        }
        let sticky = stickyInset[displayId] ?? 0
        lock.unlock()

        let liveLeftInset = visibleFrame.minX - frame.minX
        let liveRightInset = frame.maxX - visibleFrame.maxX
        let dockBar = dockBarAppKitRect()
        let dockBarIntersectsThisDisplay = dockBar?.intersects(frame) ?? false
        let axSideOrientationOnThisDisplay: String? = if let dockBar, dockBarIntersectsThisDisplay {
            if dockBar.maxX <= frame.midX {
                "left"
            } else if dockBar.minX >= frame.midX {
                "right"
            } else {
                nil
            }
        } else {
            nil
        }
        // CFPreferences can lag or read nil while the AX bar already exposes the real
        // side Dock geometry. In that case trust the singleton Dock bar's edge on this
        // display; otherwise a real left/right Dock can be mistaken for the bottom
        // fallback and have its legitimate side reservation reclaimed.
        let effectiveOrientation = axSideOrientationOnThisDisplay ?? orientation
        func reclaimUnconfirmedSideReservation(from rect: CGRect) -> CGRect {
            var corrected = rect
            if liveLeftInset > 0.5 {
                corrected.size.width = corrected.maxX - frame.minX
                corrected.origin.x = frame.minX
            }
            if liveRightInset > 0.5 {
                corrected.size.width = frame.maxX - corrected.origin.x
            }
            return corrected
        }
        // Reclaim the Dock-orientation axis back to the physical frame edge, preserving
        // the orthogonal (menu-bar/notch) edge carried by `rect`. Shared by the
        // dock-on-another-display reclaim and the #163 auto-hide reclaim. Delegates to
        // the pure, unit-testable `reclaimedDockAxis`.
        func reclaimDockAxis(from rect: CGRect, orientation: String) -> CGRect {
            reclaimedDockAxis(from: rect, frame: frame, orientation: orientation)
        }

        // The Dock lives on ONE display. If its bar is genuinely on ANOTHER connected
        // display, macOS can still report a phantom side reservation on this display
        // (seen on a DELL offset next to a built-in: a bogus 200px right inset with
        // nothing there). Reclaim that space on the Dock's orientation axis, keeping the
        // orthogonal menu-bar reservation from visibleFrame.
        //
        // For side reservations, use the singleton Dock host as the invariant: only the
        // display whose physical frame intersects the real AX Dock bar may keep a left or
        // right inset. Every other display must treat a live side reservation as phantom.
        // If the bar is unreadable, do not trust a side reservation either; a genuine side
        // Dock will be restored once AX resolves during the startup settle refreshes.
        //
        // Require the bar to actually land on some OTHER screen: a Dock hidden by a
        // quick-terminal can report offscreen AX coords that intersect NO display, and
        // treating that as "Dock on another display" would wrongly clear a single
        // display's learned inset (working area jumps to full width, shield disappears).
        // #163: An auto-hide Dock reserves no permanent band. Its AXList bar top-edge only
        // animates on-screen during a reveal, and a display reconfiguration animates it in
        // exactly as Monitor.current() rebuilds — sampling it mid-reveal otherwise learns a
        // sticky 64/78-pt inset that outlives the reveal forever. When the persistent Dock
        // preference is authoritatively auto-hide, drop any learned inset for this display
        // and reclaim the Dock-orientation axis from the live frame, keeping the orthogonal
        // menu-bar edge. A nil/unreadable preference is treated conservatively as fixed, so
        // fixed Docks and quick-terminal suppression keep the existing stabilization.
        if dockAutohideEnabled() == true {
            lock.lock()
            stickyInset[displayId] = nil
            lock.unlock()
            let corrected = reclaimDockAxis(from: visibleFrame, orientation: effectiveOrientation)
            return reclaimUnconfirmedSideReservation(from: corrected)
        }

        if dockIsOnAnotherDisplay(than: frame) {
            lock.lock()
            stickyInset[displayId] = nil
            lock.unlock()
            let corrected = reclaimDockAxis(from: visibleFrame, orientation: orientation)
            return reclaimUnconfirmedSideReservation(from: corrected)
        }

        // visibleFrame is AppKit bottom-left based: a right Dock shrinks width, a left
        // Dock raises minX, a bottom Dock raises minY.
        let currentInset: CGFloat = switch effectiveOrientation {
        case "left": liveLeftInset
        case "right": liveRightInset
        default: visibleFrame.minY - frame.minY
        }

        let derivedInset = axDerivedInset(frame: frame, orientation: effectiveOrientation)

        if (liveLeftInset > 0.5 || liveRightInset > 0.5), dockBar != nil, !dockBarIntersectsThisDisplay {
            lock.lock()
            stickyInset[displayId] = nil
            lock.unlock()
            return reclaimUnconfirmedSideReservation(from: visibleFrame)
        }

        lock.lock()
        defer { lock.unlock() }
        // The Dock inset is a STABLE property of a fixed Dock. It must NOT follow the
        // live reservation, which a quick-terminal (or any app that hides the Dock via
        // presentationOptions) suppresses transiently — following it would re-tile every
        // toggle. Update the sticky inset only from an authoritative positive reading:
        // the Dock's AX bar geometry when available, else the live reservation to
        // bootstrap before the bar is readable. For side Docks, however, macOS can
        // report a phantom live reservation on displays that do not host the Dock, so
        // left/right insets are learned only from AX-confirmed bar geometry on this
        // display. This deliberately leaves a genuine side Dock full-width for a short
        // cold-start beat until the Dock's AX bar becomes readable, instead of briefly
        // shielding the wrong display. A transient suppression (both zero) leaves the
        // sticky value untouched. A real Dock resize updates the AX bar and thus the
        // sticky value; an orientation change already cleared it above.
        // A real Dock never reserves more than a fraction of the display. Reject an
        // implausibly large inset — during display (re)configuration the frame/visibleFrame
        // can be momentarily inconsistent and yield a huge bogus inset that would otherwise
        // get learned and produce a giant shield / squished tiling on a display.
        let isSideOrientation = effectiveOrientation == "left" || effectiveOrientation == "right"
        let dockAxisSize = isSideOrientation ? frame.width : frame.height
        let maxPlausibleInset = dockAxisSize * 0.33
        // TODO: consider a tighter side-inset ceiling than the loose cross-orientation
        // 0.33 cap once we have a safe upper bound for legitimately large side Docks.

        if !frameChanged, let derivedInset, derivedInset > 0.5, derivedInset <= maxPlausibleInset {
            // Hysteresis: the AX Dock-bar measurement jitters a few px as it settles, so
            // adopting every reading makes the working area and shield flap (e.g. 71↔76px)
            // and desyncs the park target from the shield. Keep the learned inset unless
            // the new reading differs meaningfully (a real Dock resize/tilesize change).
            let insetJitterTolerance: CGFloat = 8
            if let current = stickyInset[displayId], abs(derivedInset - current) <= insetJitterTolerance {
                // within jitter — keep the stable value
            } else {
                stickyInset[displayId] = derivedInset
                LayoutTrace.log(
                    "dockInset.learn displayId=\(displayId) orientation=\(effectiveOrientation) "
                        + "derived=\(String(format: "%.1f", derivedInset)) "
                        + "frame=\(LayoutTrace.rect(frame)) rawVisible=\(LayoutTrace.rect(visibleFrame))"
                )
            }
        } else if !frameChanged,
                  !isSideOrientation,
                  stickyInset[displayId] == nil,
                  currentInset > 0.5,
                  currentInset <= maxPlausibleInset
        {
            stickyInset[displayId] = currentInset
        }
        var inset = stickyInset[displayId] ?? sticky
        if inset > maxPlausibleInset {
            stickyInset[displayId] = nil
            inset = 0
        }
        guard inset > 0.5 else {
            // No AX-confirmed side inset: do NOT pass the raw reservation through.
            // On an offset secondary display macOS bakes a phantom side inset into
            // visibleFrame (clamped to the adjacent display's edge), and while the
            // Dock's AX bar is unreadable (cold start, quick terminal up) the
            // dockIsOnAnotherDisplay reclaim above cannot fire — so the phantom
            // would leak into the working area and the Dock Shield. Reclaim the
            // side axis to the physical frame; a genuine side Dock re-insets as
            // soon as its AX bar becomes readable (the accepted cold-start beat). Do
            // the same when the Dock orientation read fell back to bottom/nil: a raw
            // side reservation is still not authoritative unless AX confirms it.
            if liveLeftInset > 0.5 || liveRightInset > 0.5 {
                return reclaimUnconfirmedSideReservation(from: visibleFrame)
            }
            return visibleFrame
        }

        // Apply the inset against the STABLE physical frame edge (not the flapping
        // visibleFrame), so the working width stays constant whether or not the Dock is
        // currently reserving. Preserve visibleFrame's orthogonal edges — they carry the
        // menu-bar reservation, which is unrelated to the Dock.
        var corrected = visibleFrame
        switch effectiveOrientation {
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
        return isSideOrientation ? corrected : reclaimUnconfirmedSideReservation(from: corrected)
    }

    /// Pure geometry for the Dock-axis reclaim: returns `rect` with the Dock-orientation
    /// axis pushed back to the physical `frame` edge, preserving the orthogonal
    /// (menu-bar/notch) edge carried by `rect`. For a bottom Dock this restores
    /// `origin.y = frame.minY` and extends the height to the previous top edge. Extracted
    /// as a pure seam so the #163 auto-hide reclaim geometry is unit-testable.
    static func reclaimedDockAxis(from rect: CGRect, frame: CGRect, orientation: String) -> CGRect {
        var corrected = rect
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

    /// Reads the Dock's bar rect (its `AXList` child) and converts it to an edge
    /// inset for `frame`. AX coordinates are global top-left based; x values match
    /// AppKit globals directly, y must be flipped against the primary screen height.
    /// Memoized for a few seconds — `Monitor.current()` can be called in bursts.
    /// The Dock bar's raw AX (top-left) rect, memoized ~5s. Only serves a cached probe
    /// when it actually found the bar: a nil probe (Dock AX not queryable yet, e.g. right
    /// after launch, or hidden) must NOT be cached, otherwise the inset stays unknown and
    /// the viewport stays full-width until a manual restart. Keep re-probing until the
    /// Dock answers, then cache. Shared by `axDerivedInset` and `dockBarAppKitRect`.
    private static func cachedDockBarRect() -> CGRect? {
        let now = ProcessInfo.processInfo.systemUptime
        if let probe = lastAXProbe, now - probe.uptime < 5.0, probe.barRect != nil {
            return probe.barRect
        }
        let fresh = dockBarRect()
        if fresh != nil {
            lastAXProbe = (now, fresh)
        }
        return fresh
    }

    private static func axDerivedInset(frame: CGRect, orientation: String) -> CGFloat? {
        guard let rawBar = cachedDockBarRect(), let appKitBar = appKitDockBarRect(from: rawBar) else { return nil }

        // A genuine side Dock bar sits flush against the screen edge it insets. A bar
        // rect cached under a different (smaller) display mode — the ~5s memo surviving a
        // scaled-resolution switch — has its OUTER edge short of the current frame edge by
        // exactly the mode-width delta. Reject that stale/straddled read: otherwise the
        // delta is learned as a phantom side inset (e.g. 2056 - 1728 = 328) that clears
        // the 0.33x ratio ceiling and sticks as a giant shield. (A bar from a *larger*
        // mode is already rejected by the maxX<=frame.maxX / minX>=frame.minX guards.)
        let edgeFlushTolerance: CGFloat = 24
        switch orientation {
        case "left":
            guard appKitBar.minY < frame.maxY, appKitBar.maxY > frame.minY else { return nil }
            guard appKitBar.minX >= frame.minX, appKitBar.maxX <= frame.midX else { return nil }
            guard appKitBar.minX - frame.minX <= edgeFlushTolerance else { return nil }
            return appKitBar.maxX - frame.minX
        case "right":
            guard appKitBar.minY < frame.maxY, appKitBar.maxY > frame.minY else { return nil }
            guard appKitBar.maxX <= frame.maxX, appKitBar.minX >= frame.midX else { return nil }
            guard frame.maxX - appKitBar.maxX <= edgeFlushTolerance else { return nil }
            return frame.maxX - appKitBar.minX
        default:
            return appKitBar.maxY - frame.minY
        }
    }

    /// The Dock bar's rect in AppKit global coordinates (bottom-left origin), or nil if
    /// the Dock is not readable. The Dock lives on ONE display at a time, so the shield
    /// uses this to avoid drawing on a display that has no Dock. Memoized ~5s.
    static func dockBarAppKitRect() -> CGRect? {
        guard let bar = cachedDockBarRect() else { return nil }
        return appKitDockBarRect(from: bar)
    }

    private static func appKitDockBarRect(from rawBar: CGRect) -> CGRect? {
        let primaryHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height
        guard let primaryHeight else { return nil }
        // AX is global top-left; flip y to AppKit bottom-left.
        return CGRect(x: rawBar.minX, y: primaryHeight - rawBar.maxY, width: rawBar.width, height: rawBar.height)
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
                  let posValue = posRef, let sizeValue = sizeRef,
                  // Safe cast: the Dock could return an unexpected type; a force-cast to
                  // AXValue would trap. Treat any cast failure as the guard/continue fallback.
                  CFGetTypeID(posValue) == AXValueGetTypeID(),
                  CFGetTypeID(sizeValue) == AXValueGetTypeID()
            else { continue }
            let posAXValue = posValue as! AXValue
            let sizeAXValue = sizeValue as! AXValue
            var position = CGPoint.zero
            var size = CGSize.zero
            guard AXValueGetValue(posAXValue, .cgPoint, &position),
                  AXValueGetValue(sizeAXValue, .cgSize, &size),
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

    func monitorContaining(in monitors: [Monitor]) -> Monitor? {
        monitors.first(where: { $0.frame.contains(self) })
    }
}
