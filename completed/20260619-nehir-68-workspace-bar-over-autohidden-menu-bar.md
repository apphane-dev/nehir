# Workspace bar renders OVER an auto-hidden menu bar even with `position = "belowMenuBar"` — Discovery

GitHub issue: **Guria/nehir #68** — *Workspace bar renders over the menu bar
when macOS menu-bar auto-hide is on, even with `position = "belowMenuBar"`* (no
labels). Maintainer (@Guria, OWNER) has acknowledged but not investigated:
"This is something we haven't considered yet. I'll try to investigate it
further and see what's going on."

All code references are against the main Nehir worktree
(the main Nehir source tree, branch `main`). Re-verify
line numbers before implementing; they drift.

---

## TL;DR

- **`belowMenuBar` is a misnomer.** It does not measure or offset by the menu
  bar. The bar's vertical position is computed as
  `monitor.visibleFrame.maxY - barHeight`
  (`Sources/Nehir/UI/WorkspaceBar/WorkspaceBarGeometry.swift:35`), where
  `monitor.visibleFrame` is the raw `NSScreen.visibleFrame` captured verbatim
  (`Sources/Nehir/Core/Monitor/Monitor.swift:30`).
- With macOS **"Automatically hide and show the menu bar: Always"**, AppKit does
  not reserve the menu bar's top inset in `NSScreen.visibleFrame` (the top gap
  `screen.frame.maxY - screen.visibleFrame.maxY` collapses toward 0). So
  `visibleFrame.maxY ≈ frame.maxY`, and `belowMenuBar` places the bar in the
  top ~24 pt strip that the auto-hidden menu bar later slides into.
- The one field that *does* quantify the menu bar —
  `WorkspaceBarGeometry.menuBarHeight(for:)`
  (`Sources/Nehir/UI/WorkspaceBar/WorkspaceBarGeometry.swift:56-59`, defined as
  `frame.maxY - visibleFrame.maxY`, default `28`) — is computed and stored but
  **never used by `frame()`**. Its only other consumer is a debug log string
  (`Sources/Nehir/UI/WorkspaceBar/WorkspaceBarManager.swift:625`). Under
  auto-hide it would infer `≤0` and fall back to `28`, but because `frame()`
  ignores it, the bar still lands on top.
- `reserveLayoutSpace = true` is orthogonal: it only adds `barHeight` to the
  *window-layout* top strut (`Sources/Nehir/Core/Controller/WMController.swift:754-777`)
  so managed windows avoid the bar. It does not move the bar and does not consult
  the menu bar.
- `windowLevel = "popup"` → `NSWindow.Level.popUpMenu` (≈ 101)
  (`Sources/Nehir/UI/WorkspaceBar/WorkspaceBarManager.swift:31`, applied at
  `:590`), which is *above* the system menu-bar level. So wherever the bar and
  the revealed menu bar share vertical space, the bar paints on top — matching
  the reporter's screenshot of the bar over the menu bar.

**Verdict:** Real bug, root-caused in geometry, with a self-contained fix in
`WorkspaceBarGeometry`. Filed under `discovery/` because it owns a concrete plan
and needs no further investigation; it can be promoted to `planned/` on
approval.

---

## The reporter's configuration (issue #68 body + comment)

From `~/.config/nehir/settings.toml` (relevant keys):

```toml
[workspaceBar]
position = "belowMenuBar"
reserveLayoutSpace = true
notchAware = true
windowLevel = "popup"
height = 24.0
```

Environment: Nehir 0.5.0 (Homebrew cask), macOS 26 Tahoe (Darwin 25.2.0),
Apple Silicon. macOS menu bar set to *Automatically hide and show the menu bar →
Always*. Symptom: when the pointer is moved to the top, the macOS menu bar
appears but the Nehir workspace bar sits on top of it instead of below it.

---

## How the bar position is computed (evidence)

### 1. The bar anchors at `visibleFrame.maxY`, not at a menu-bar offset

```swift
// Sources/Nehir/UI/WorkspaceBar/WorkspaceBarGeometry.swift:28-41
func frame(
    fittingWidth: CGFloat,
    monitor: Monitor,
    resolved: ResolvedBarSettings
) -> CGRect {
    let width = max(fittingWidth, 300)
    var x = monitor.frame.midX - width / 2
    var y = effectivePosition == .belowMenuBar ? monitor.visibleFrame.maxY - barHeight : monitor.visibleFrame.maxY

    x += CGFloat(resolved.xOffset)
    y += CGFloat(resolved.yOffset)

    return CGRect(x: x, y: y, width: width, height: barHeight)
}
```

Note what this does **not** do: it never reads `menuBarHeight`, never subtracts
a menu-bar height, never consults the notch/safe-area. For `belowMenuBar` the
only adjustment relative to the top is `- barHeight`. The bar is therefore
"anchored at the top of the visible frame, shifted down by its own height" —
which is only *below the menu bar* when `visibleFrame.maxY` already excludes the
menu bar.

### 2. `visibleFrame` is the raw `NSScreen.visibleFrame`

```swift
// Sources/Nehir/Core/Monitor/Monitor.swift:13-32
let frame: CGRect
let visibleFrame: CGRect
let hasNotch: Bool
…
return Monitor(
    id: ID(displayId: displayId),
    displayId: displayId,
    frame: screen.frame,
    visibleFrame: screen.visibleFrame,
    hasNotch: hasNotch,
    …
)
```

`NSScreen.visibleFrame` is the screen area excluding the menu bar **and** Dock
that the system *currently* considers reserved. When the menu bar is set to
auto-hide and is not being revealed, AppKit does not reserve the menu bar in
`visibleFrame` — so `visibleFrame.maxY` rises to (effectively) `screen.frame.maxY`.
That single fact is the whole bug: the anchor point moves up into the menu bar's
reveal region.

### 3. The menu-bar height is inferred — and then ignored

```swift
// Sources/Nehir/UI/WorkspaceBar/WorkspaceBarGeometry.swift:56-59
static func menuBarHeight(for monitor: Monitor) -> CGFloat {
    let height = monitor.frame.maxY - monitor.visibleFrame.maxY
    return height > 0 ? height : 28
}
```

This is the only place Nehir tries to "know" the menu bar, and it is exactly the
gap that auto-hide collapses. It returns `28` by default once the gap is `≤0`.
But the field is dead weight for positioning: a repo-wide search shows its only
read sites are the `resolve(...)` constructor (`:15`) and a debug trace string
(`WorkspaceBarManager.swift:625`). `frame()` never references it. So even the
fallback constant does not save the layout.

### 4. `reserveLayoutSpace` affects the layout region, not the bar

```swift
// Sources/Nehir/UI/WorkspaceBar/WorkspaceBarGeometry.swift:18
let reservedTopInset = isVisible && resolved.reserveLayoutSpace ? barHeight : 0
```

```swift
// Sources/Nehir/Core/Controller/WMController.swift:754-777  (insetWorkingFrame(for:))
let reservedTopInset = WorkspaceBarGeometry.resolve(
    monitor: monitor,
    resolved: resolved,
    isVisible: isWorkspaceBarVisible(on: monitor, resolved: resolved)
).reservedTopInset
return insetWorkingFrame(
    from: monitor.visibleFrame,
    scale: scale,
    reservedTopInset: reservedTopInset,
    outerGaps: outerGaps(for: monitor)
)
…
let struts = Struts(
    left: outer.left,
    right: outer.right,
    top: outer.top + reservedTopInset,   // pushes managed windows DOWN below the bar
    bottom: outer.bottom
)
```

`reservedTopInset` is `barHeight` (24 here). It is added to the *top gap of the
tile working area* so windows don't slide under the bar. It has no effect on the
bar's own `y`, and it is computed from `monitor.visibleFrame` — so under
auto-hide the working area itself also starts at the very top (a related, lesser
issue: managed windows would underlap the auto-hidden menu bar too).

### 5. The panel level can sit above the system menu bar

```swift
// Sources/Nehir/UI/WorkspaceBar/WorkspaceBarManager.swift:22-31
var nsWindowLevel: NSWindow.Level {
    switch self {
    case .normal: .normal
    case .floating: .floating
    case .status: .statusBar
    case .popup: .popUpMenu
    case .screensaver: .screenSaver
    }
}
```

```swift
// Sources/Nehir/UI/WorkspaceBar/WorkspaceBarManager.swift:31  (case .popup: .popUpMenu)
// Sources/Nehir/UI/WorkspaceBar/WorkspaceBarManager.swift:589-591
private func applySettingsToPanel(_ panel: NSPanel, resolved: ResolvedBarSettings) {
    panel.level = resolved.windowLevel.nsWindowLevel
}
```

The reporter uses `windowLevel = "popup"`, i.e. `.popUpMenu` (level 101). The
system menu bar renders around `.menuBar`/`.statusBar` (≈ 24–25), so the
workspace bar is well above it. Thus wherever the two overlap vertically, the
bar wins the paint — exactly the "renders over the menu bar" symptom.

---

## Root-cause hypothesis (complete)

For `position = "belowMenuBar"`, the bar's top edge is
`monitor.visibleFrame.maxY` (`WorkspaceBarGeometry.swift:35`). On macOS Tahoe
with "Automatically hide and show the menu bar: Always", AppKit does not reserve
the menu bar in `NSScreen.visibleFrame`, so `visibleFrame.maxY ≈ frame.maxY` and
the bar lands at the very top of the screen — the ~24 pt strip the auto-hidden
menu bar occupies when revealed. Because the bar runs at
`NSWindow.Level.popUpMenu` (reporter's `windowLevel = "popup"`), which is above
the system menu-bar level, it then paints over the revealed menu bar.

Internal consistency check that supports the hypothesis: Nehir's own
`menuBarHeight(for:)` is defined as `frame.maxY - visibleFrame.maxY`. In the
auto-hide case that gap is `≤0`, which is precisely the condition under which
the geometry would be wrong — and the function even returns its `28` fallback in
that exact case. The bug and the inferred-height collapse are the same
phenomenon; the geometry just never consults that height when placing the bar.

---

## macOS constraints: there is no first-class "menu bar is auto-hidden" API

Any fix that tries to *detect* auto-hide is fighting the platform. Documented
and commonly-tried approaches, with caveats:

- **No public API.** `NSScreen` exposes `frame`, `visibleFrame`, and (macOS 12+)
  `safeAreaInsets` / `auxiliaryTopLeftArea` / `auxiliaryTopRightArea`.
  `safeAreaInsets.top` is the *notch* inset on notched MacBooks and is `0` on
  non-notched external displays; it does **not** reflect the menu bar or its
  auto-hide state. `auxiliaryTopLeftArea/Right` describe the camera housing /
  notch, not menu-bar hide.
- **Private `NSUserDefaults` keys.** The "Automatically hide and show the menu
  bar" preference historically lives in a host-level user defaults domain
  (undocumented key names that have changed across macOS versions). A sandboxed
  Nehir may not reliably read the host domain, and relying on undocumented keys
  is fragile and version-dependent (notably across Tahoe releases). Not
  recommended as a sole signal.
- **Notifications.** `NSApplication.didChangeScreenParametersNotification` /
  `NSScreen.didChangeParametersNotification` fire on display configuration
  changes but **not** when the user merely toggles menu-bar auto-hide at runtime,
  and they carry no "auto-hide" flag.

**Implication for the fix:** Do not try to detect auto-hide. Make `belowMenuBar`
correct *regardless* of auto-hide by reserving a standard menu-bar inset
explicitly, instead of inheriting it (or not) from `visibleFrame`.

---

## Proposed plan: anchor `belowMenuBar` to an explicit menu-bar inset

Goal: with `position = "belowMenuBar"`, the bar sits below the menu bar whether
the menu bar is always-visible or auto-hidden, without trying to detect the
state.

### Change 1 — position relative to `frame.maxY`, not `visibleFrame.maxY`

In `Sources/Nehir/UI/WorkspaceBar/WorkspaceBarGeometry.swift`, for
`.belowMenuBar` compute the top of the bar as
`monitor.frame.maxY - menuBarReservedHeight - barHeight` using an **explicit**
menu-bar reservation rather than the auto-hide-sensitive `visibleFrame.maxY`.

Concretely, introduce a resolved top inset used only for `.belowMenuBar`:

```swift
// Sketch — WorkspaceBarGeometry.swift
static func standardMenuBarHeight(for monitor: Monitor) -> CGFloat {
    // Always reserve the conventional macOS menu-bar height for "below menu bar".
    // On a normally-visible menu bar this equals frame.maxY - visibleFrame.maxY;
    // on an auto-hidden menu bar visibleFrame no longer carries it, so we add it.
    let inferred = monitor.frame.maxY - monitor.visibleFrame.maxY
    return max(inferred, 24)            // 24 pt is the standard macOS menu-bar height
}

// In frame():
let topInset: CGFloat
switch effectivePosition {
case .belowMenuBar:
    topInset = Self.standardMenuBarHeight(for: monitor)
case .overlappingMenuBar:
    topInset = 0                        // intentional overlap mode unchanged
}
var y = monitor.frame.maxY - topInset - barHeight
```

Why this is safe and idempotent for the *normal* (visible menu bar) case: when
the menu bar is visible, `frame.maxY - visibleFrame.maxY == 24`, so
`standardMenuBarHeight` returns `24` and `frame.maxY - 24 - barHeight` equals
the previous `visibleFrame.maxY - barHeight`. Behaviour is unchanged for the
non-auto-hide majority; only the auto-hide case gains the missing inset.

Why `frame.maxY` instead of `visibleFrame.maxY`: `visibleFrame` conflates the
menu bar **and** the Dock; anchoring `belowMenuBar` to the physical top edge
minus an explicit menu-bar constant avoids the Dock's bottom inset leaking into
the top placement and, crucially, is immune to auto-hide dropping the top inset.

### Change 2 — keep the tile working area out of the menu-bar region too

`insetWorkingFrame(for:)` (`Sources/Nehir/Core/Controller/WMController.swift:754-777`)
currently parents the tile working area on `monitor.visibleFrame` and adds only
`reservedTopInset = barHeight`. Under auto-hide that parent already starts at
the very top, so managed windows would also underlap the menu-bar reveal region.
Apply the same explicit `standardMenuBarHeight` as an additional top strut for
the working area when the workspace bar is in `.belowMenuBar` mode (or
unconditionally), so windows stay below the bar — and the bar stays below the
menu bar.

### Change 3 — decide the level interaction

The vertical-offset fix (Changes 1–2) is the primary fix and makes level
irrelevant in the normal case. Separately, document/decide the window-level
policy:

- Option A (recommended): keep `popup`/`.popUpMenu` as a user choice, rely on
  the offset fix so the bar and menu bar never share vertical space. No
  behaviour change beyond Change 1.
- Option B: add a setting (or auto-lower) to `.statusBar` level so that if the
  bar ever overlaps the menu bar, the *system* menu bar wins. This is a
  product/policy decision (the bar is intentionally high so it is never covered
  by fullscreen menus); not required to fix #68.

### Change 4 — reposition on runtime config changes

Because toggling auto-hide (or changing screen layout) at runtime is not
reliably notified (see "macOS constraints"), Nehir already re-resolves bar
geometry on each `updateBarFrameAndPosition`
(`Sources/Nehir/UI/WorkspaceBar/WorkspaceBarManager.swift:388-401`) pass and on
screen-parameter changes. No new observer is strictly required; ensure the bar
is re-laid-out on `NSApplication.didChangeScreenParametersNotification` and on
settings changes (already wired through `updateWorkspaceBarSettings()`), and
verify a manual "Toggle Workspace Bar" re-applies the new geometry.

### Seam points (file:line)

- `Sources/Nehir/UI/WorkspaceBar/WorkspaceBarGeometry.swift:28-41` — `frame()`:
  switch `.belowMenuBar` to `frame.maxY - menuBarReservedHeight - barHeight`.
- `Sources/Nehir/UI/WorkspaceBar/WorkspaceBarGeometry.swift:56-59` —
  `menuBarHeight(for:)`: repurpose into `standardMenuBarHeight(for:)`
  (`max(inferred, 24)`); wire it into `frame()`. (Today this is dead for
  positioning — make it live.)
- `Sources/Nehir/UI/WorkspaceBar/WorkspaceBarManager.swift:388-401` —
  `updateBarFrameAndPosition`: already re-applies `geometry.frame(...)`; no
  change needed, but re-verify it runs after the geometry edit.
- `Sources/Nehir/UI/WorkspaceBar/WorkspaceBarManager.swift:589-591` —
  `applySettingsToPanel`: window-level policy (Change 3, optional).
- `Sources/Nehir/Core/Controller/WMController.swift:754-777` —
  `insetWorkingFrame(for:)`: add the explicit menu-bar top strut so windows stay
  clear of the reveal region (Change 2).
- `Sources/Nehir/Core/Monitor/Monitor.swift:13-32` — `visibleFrame` capture: no
  change needed (keep raw), but it is the unreliable input we are moving away
  from for `belowMenuBar`.

---

## Interaction with `notchAware` and the existing notch handling

The reporter sets `notchAware = true`. Today
`effectivePosition` (`Sources/Nehir/UI/WorkspaceBar/WorkspaceBarGeometry.swift:43-54`)
only promotes `overlappingMenuBar → belowMenuBar` when `monitor.hasNotch &&
notchAware`. Here the user already set `position = "belowMenuBar"` explicitly,
so `notchAware` is a no-op for routing. The fix does not change
`effectivePosition`; it only corrects what `.belowMenuBar` *means*
geometrically. Two follow-on notes:

- On a **notched MacBook**, `NSScreen.safeAreaInsets.top` (~32 pt) already
  includes the notch+menu-bar region, and `visibleFrame.maxY` is reduced
  accordingly — so today the bar already clears the notch. The explicit-constant
  approach (`max(inferred, 24)`) must not *reduce* that clearance; use
  `max(inferred, 24)` rather than a fixed `24` so notched displays keep their
  larger inset. (On notched hardware `inferred ≈ 32`, so the `max` preserves it.)
- On **non-notched external displays** (the reporter's Elgato / ARZOPA), there
  is no notch inset; `safeAreaInsets.top == 0`. The fix's constant-24 reservation
  is exactly what is missing under auto-hide. This is the case the issue
  reproduces on.

---

## Verification / regression notes (no source edits made in this pass)

Manual checks to confirm the fix:

1. Non-notched external display, macOS menu bar **visible** (default):
   `belowMenuBar` bar y should be unchanged (`frame.maxY - 24 - barHeight` ≈
   previous `visibleFrame.maxY - barHeight`).
2. Same display, menu bar **auto-hide Always**: bar should now sit 24 pt below
   `frame.maxY`; moving the pointer to the top reveals the menu bar **above**
   the workspace bar instead of under it.
3. Notched MacBook, menu bar auto-hide: bar still clears the notch/menu region
   (inferred inset ≈ 32 dominates the `max(..., 24)`).
4. `overlappingMenuBar` mode: behaviour unchanged (bar intentionally overlaps —
   this is the documented "overlapping" behaviour).
5. `reserveLayoutSpace = true`: managed windows start below the bar and below
   the menu-bar reveal region.

Recommended unit additions (geometry is pure and already unit-testable):

- `WorkspaceBarGeometry.frame(...)` for `.belowMenuBar` with a mock `Monitor`
  whose `visibleFrame.maxY == frame.maxY` (auto-hide shape): assert bar
  `frame.maxY == monitor.frame.maxY - 24 - barHeight` (not
  `monitor.frame.maxY - barHeight`).
- Same with `visibleFrame.maxY == frame.maxY - 24` (visible menu bar): assert
  identical y to today (no regression).
- Notched monitor (`inferred ≈ 32`): assert `max(inferred, 24)` preserves 32.

---

## Open questions / risks

- **Exact Tahoe `visibleFrame` semantics under auto-hide.** The hypothesis is
  grounded in the reported symptom and in Nehir's own inferred-height collapse,
  but `NSScreen.visibleFrame` menu-bar behaviour has historically been
  version-dependent. If a future build finds `visibleFrame.maxY` *does* still
  subtract the menu bar under auto-hide on some hardware, Change 1 with
  `max(inferred, 24)` remains correct (idempotent) — it only adds inset when
  none is reserved.
- **Whether to expose the menu-bar reservation as a per-monitor override.** A
  Tahoe "island"/camera cutout that is larger than 24 pt on a non-notched
  display would need a larger value. Optional: add a
  `workspaceBarTopInsetOverride` to `MonitorBarSettings`
  (`Sources/Nehir/Core/Config/MonitorBarSettings.swift`) and let the explicit
  reservation be `max(inferred, override ?? 24)`. Out of scope for the minimal
  fix but a clean extension point.
- **Window-level policy (Change 3).** Whether the bar should ever yield to the
  system menu bar is a product decision; the minimal fix does not require it.

---

## Related planning docs (deduplication)

- `discovery/20260615-workspace-bar-focus-projection-routing.md` — workspace
  bar *refresh* routing on focus changes; unrelated to geometry/positioning.
- `noop/20260617-omniwm-95-workspace-bar-notch.md` — documents that the default
  notch-aware path promotes `overlappingMenuBar → belowMenuBar` and that
  `belowMenuBar` anchors at `visibleFrame.maxY - barHeight`. That doc treats the
  notched case as "fixed" and does not address the auto-hide menu bar; this
  issue is the orthogonal, non-notched (or any-display) gap that #68 exposes.
