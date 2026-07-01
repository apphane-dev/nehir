# Nehir #68 — Workspace bar overlaps an auto-hidden menu bar

**Status:** completed — shipped in commit `156dad98` on `main` (2026-06-21, "Anchor workspace bar below menu bar under auto-hide #68"). Moved from `planned/` to `completed/`.
**Source discovery:** `discovery/20260619-nehir-68-workspace-bar-over-autohidden-menu-bar.md`
**GitHub issue:** #68

All file/line references re-verified against
the main Nehir source tree on 2026-06-19. Re-verify
before editing; line numbers drift.

## TL;DR

With `position = "belowMenuBar"` and macOS **"Automatically hide and show the
menu bar: Always"**, the workspace bar lands in the top ~24 pt strip the menu
bar slides into. Root cause: `WorkspaceBarGeometry.frame()` anchors to
`monitor.visibleFrame.maxY`, but under auto-hide AppKit no longer reserves the
menu-bar inset there, so `visibleFrame.maxY ≈ frame.maxY`. The bar's own
`menuBarHeight(for:)` is computed but **never read by `frame()`** (dead code).

Fix: anchor `.belowMenuBar` to `monitor.frame.maxY - standardMenuBarHeight`
using an explicit, always-≥24 reservation (immune to auto-hide). Idempotent for
the visible-menu-bar majority.

## Scope

- `Sources/Nehir/UI/WorkspaceBar/WorkspaceBarGeometry.swift` — `frame()` + a new
  `standardMenuBarHeight(for:)` (repurpose the dead `menuBarHeight`).
- `Sources/Nehir/Core/Controller/WMController.swift` — `insetWorkingFrame(for:)`
  gains the same explicit top strut so managed windows stay clear of the reveal
  region (Change 2 — companion).
- Tests under `Tests/NehirTests/`.

### Non-goals

- Do **not** add a menu-bar-auto-hide detector (no first-class API exists; the
  explicit-constant approach avoids needing one).
- Do **not** change window-level policy (Change 3 in discovery = product
  decision; the offset fix makes level irrelevant). Keep `popup`/`.popUpMenu`.
- Do **not** touch `monitor.visibleFrame` capture (keep raw) — it's the
  unreliable input we move *away* from for `belowMenuBar`.
- Do **not** change `.overlappingMenuBar` (intentional overlap mode).

## Exact edits

### Change 1 — `WorkspaceBarGeometry.frame()` (core fix)

Verified current (`:33-41`):
```swift
var y = effectivePosition == .belowMenuBar ? monitor.visibleFrame.maxY - barHeight : monitor.visibleFrame.maxY
```
and `menuBarHeight(for:)` (`:56-59`, currently dead for positioning):
```swift
static func menuBarHeight(for monitor: Monitor) -> CGFloat {
    let height = monitor.frame.maxY - monitor.visibleFrame.maxY
    return height > 0 ? height : 28
}
```

Post-fix: anchor `.belowMenuBar` to `frame.maxY` minus an explicit always-≥24
menu-bar reservation:
```swift
static func standardMenuBarHeight(for monitor: Monitor) -> CGFloat {
    // Always reserve the conventional macOS menu-bar height for "below menu bar".
    // Visible menu bar: frame.maxY - visibleFrame.maxY == 24, so unchanged.
    // Auto-hidden menu bar: visibleFrame no longer carries the inset, so add it.
    let inferred = monitor.frame.maxY - monitor.visibleFrame.maxY
    return max(inferred, 24)
}
// in frame():
let topInset: CGFloat = effectivePosition == .belowMenuBar
    ? Self.standardMenuBarHeight(for: monitor)
    : 0
var y = monitor.frame.maxY - topInset - barHeight
```
Remove the now-dead `menuBarHeight(for:)` (or rename to
`standardMenuBarHeight`) and its unused-callers (a debug log string in
`WorkspaceBarManager.swift:625` — update or drop).

**Idempotency check (must hold):** visible menu bar ⇒
`frame.maxY - visibleFrame.maxY == 24` ⇒ `standardMenuBarHeight == 24` ⇒
`frame.maxY - 24 - barHeight == visibleFrame.maxY - barHeight` (old value). ✓

### Change 2 — `WMController.insetWorkingFrame(for:)` (`:754-777`)

Today it parents the tile working area on `monitor.visibleFrame` and adds only
`reservedTopInset = barHeight`. Under auto-hide that parent starts at the very
top, so managed windows underlap the menu-bar reveal region. Add the explicit
`standardMenuBarHeight` as an additional top strut when the workspace bar is in
`.belowMenuBar` mode. (Read the resolved bar position; if awkward to thread,
apply unconditionally — safe because the constant matches the visible-menu-bar
case.)

## Tests

`Tests/NehirTests/` — pure geometry, no live `NSScreen`:

1. `WorkspaceBarGeometryTests.belowMenuBarAnchoredBelowExplicitMenuBarInset` —
   fabricate a `Monitor` whose `frame.maxY - visibleFrame.maxY == 0` (simulating
   auto-hide) and assert the `.belowMenuBar` bar top sits at
   `frame.maxY - 24 - barHeight` (NOT `frame.maxY - barHeight`).
2. `WorkspaceBarGeometryTests.belowMenuBarUnchangedForVisibleMenuBar` — fabricate
   a monitor with a 24 pt top inset; assert the resulting `y` equals the
   pre-fix `visibleFrame.maxY - barHeight` (idempotency / no regression).
3. `WorkspaceBarGeometryTests.overlappingMenuBarUnchanged` — `.overlappingMenuBar`
   still anchors to `frame.maxY` (topInset 0).
4. (Change 2) extend or add `WMController.insetWorkingFrame...` coverage so the
   working frame's top strut includes the menu-bar reservation under auto-hide.

Re-verify a `WorkspaceBarGeometry`-targeted test file exists; if not, create
`Tests/NehirTests/WorkspaceBarGeometryTests.swift` with synthetic `Monitor`
fixtures (the existing `WorkspaceBarManagerTests` likely has monitor-fixture
helpers to reuse).

## Validation

```bash
swift build
swift test --filter WorkspaceBar
swift test --filter WorkspaceBarGeometry
swift test --filter WorkspaceBarManager
# Manual: toggle "Automatically hide and show the menu bar: Always" in System
# Settings, relaunch Nehir, confirm the bar sits below the revealed menu bar.
```

Changeset (patch): "Keep the workspace bar below an auto-hidden menu bar by
anchoring it to an explicit menu-bar inset instead of the auto-hide-sensitive
visible frame."

## Risks

- **Dock bottom inset** — anchoring to `frame.maxY` (not `visibleFrame.maxY`)
  avoids the Dock's bottom inset leaking into the top placement; verify with a
  bottom-Dock fixture.
- **`menuBarHeight` callers** — grep for other readers before removing/renaming;
  update the debug-log caller in `WorkspaceBarManager`.
- Change 2 must not double-count on a visible menu bar (the constant makes it a
  no-op there, but confirm with the idempotency test).
