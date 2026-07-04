# Nehir #112 — Focus-follows-mouse blocked by a fixed Dock (occlusion-exemption regression)

**Status:** planned
**GitHub issue:** #112 ("[Bug] Focus Follows Mouse not working with Fixed Dock")
**Regressed:** between `v0.5.0` and `v0.6.0-rc.13`
**Regressing commit:** `56573ba2` — "Fix focus-follows-mouse blocked by
click-through overlays (#64)" (2026-06-19), which is inside the reported range.

All file/line references verified against the main Nehir source tree on
2026-07-05. Re-verify before editing; line numbers drift.

## TL;DR

FFM's occlusion check treats a **fixed Dock** as an interactive window that
covers the pointer, so it suppresses focus-follows-mouse. In `v0.5.0` the same
check **exempted** the Dock; `#64` rewrote the snapshot-fallback occlusion
predicate and, as a side effect, dropped that exemption.

- `v0.5.0` exempted an occluder whose owner app was **not** `.regular`
  (`activationPolicy != .regular → continue`). The Dock is a non-`.regular`
  process, so it never occluded FFM.
- `v0.6.0-rc.13` replaced that with a predicate that only exempts a **faceless
  owner whose name is a known decorative-border utility** (`borders` /
  JankyBorders). The Dock has a bundle id (`com.apple.dock`) and a non-border
  owner name, so it is now treated as an interactive occluder → FFM is skipped.

Fix: re-exempt the Dock (and other system chrome) from the FFM occlusion
predicate, without re-exempting genuinely interactive overlays (Ghostty Quick
terminal), which `#64` correctly wanted to keep occluding.

## Symptom (from the issue)

- After updating `0.5.0 → 0.6.0-rc.13`, focus-follows-mouse stopped working.
- The reporter isolated it to **Dock set to fixed** (not auto-hide). Switching
  the Dock to auto-hide restored FFM.
- FFM still worked on the **secondary monitor**; it failed on the **primary**
  (the monitor carrying the Dock).

## Why the Dock now occludes FFM

FFM resolves a hover target in
`Sources/Nehir/Core/Controller/MouseEventHandler.swift`
`resolveFocusFollowsMouse(at:windowUnderPointer:)` (~`:1347`). Before hit-testing
a tile it bails to `.occlusion` if any of three predicates hold (~`:1357`):

```
if isFloatingWindowCoveringPointer(...)
    || hasVisibleFloatingWindowOverNiriLayout(...)
    || controller.unmanagedInteractiveWindowServerWindowCovers(
           point: location, windowUnderPointer: windowUnderPointer, ...)
{ return .occlusion }
```

The third predicate is the one that changed. Its snapshot fallback,
`WMController.visibleUnmanagedInteractiveWindowServerWindowCovers`
(`Sources/Nehir/Core/Controller/WMController.swift:2596`), walks the on-screen
`CGWindowList` and returns `true` for the first unmanaged window that:

- has `layer >= 0` (`:2615`) — the Dock sits at `kCGDockWindowLevel` (≈ 20), so
  it **passes** this filter,
- is on-screen and `width >= 80 && height >= 80` (`:2625`),
- geometrically contains the pointer (`:2632`),
- is not owned/tracked by Nehir, and
- is **not exempted** by the owner check (`:2644`):

```
if pid > 0,
   !ownerAppIsInteractiveApplication(pid),
   isDecorativeBorderOverlayOwner(ownerName)   // "borders" / "jankyborders" only
{ continue }
return true
```

`ownerAppIsInteractiveApplicationProvider` (`WMController.swift:2243`) returns
`true` when the owner has a bundle identifier:

```
guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
return app.bundleIdentifier != nil
```

The Dock owner (`com.apple.dock`) **has** a bundle id → `ownerAppIsInteractive`
is `true` → `!ownerAppIsInteractive` is `false` → the `if` is false → control
falls through to `return true`. The fixed Dock is reported as an occluder.

### Contrast with `v0.5.0` (why it used to work)

`v0.5.0`'s FFM path called `unmanagedWindowServerWindowCovers`, whose snapshot
fallback `visibleUnmanagedOverlayWindowServerWindowCovers` used an
**activation-policy** exemption instead:

```
let pid = ...
if pid > 0,
   let activationPolicy = ownerActivationPolicyProvider(pid),   // NSRunningApplication.activationPolicy
   activationPolicy != .regular
{ continue }                                                    // exempt every non-.regular owner
```

Every non-`.regular` process (the Dock, and other system agents) was exempted,
so the Dock never suppressed FFM. That original predicate **still exists** on
`main` as `visibleUnmanagedOverlayWindowServerWindowCovers`
(`WMController.swift:2684`, `activationPolicy != .regular` at `:2727`) — it is
simply no longer the one FFM calls.

The bug report is itself the empirical anchor: `0.5.0` demonstrably let FFM fire
with a fixed Dock, and `0.5.0`'s only owner-based exemption was
`activationPolicy != .regular`; therefore the Dock is a non-`.regular` owner in
practice, and the `#64` rewrite is exactly what removed its exemption.

### Why fixed vs. auto-hide matters

The occluder must be **on-screen** (`:2617`) and contain the pointer (`:2632`).
A **fixed** Dock is a persistent on-screen window occupying its reserved band.
An **auto-hidden** Dock parks its window off the screen edge (not on-screen /
out of the pointer's path), so the predicate never matches it — which is why
switching to auto-hide "fixes" FFM.

### Why the secondary monitor still works

The Dock (and its reserved band) exists on only one monitor. On the
Dock-less monitor no unmanaged system window covers the pointer, so FFM
resolves a tile normally.

## Open verification — scope on the primary monitor

The predicate only returns `.occlusion` when the pointer is **geometrically
inside the Dock window** (`frame.contains(point)` at `:2632`). That strictly
predicts FFM breaking **in the Dock band**, whereas the reporter described the
whole primary monitor as unresponsive. Before implementing, confirm the actual
scope with a trace from the reporter (fixed Dock, primary monitor), looking for:

- `ffm.skip reason=noTarget sub=occlusion` lines emitted by
  `handleFocusFollowsMouse` (`MouseEventHandler.swift:1304`) — the `sub=occlusion`
  discriminator was added by `#64` precisely to distinguish this case from
  `noHitTest`, and
- which owner/window is being caught (Dock vs. some other full-monitor system
  window such as a wallpaper/agent window).

Two plausible reasons the user perceives "whole monitor," to check against the
trace:

1. **Continuous motion uses the snapshot fallback.** On coalesced/continuous
   mouse-moved events the CGEvent carries no `windowUnderPointer`, so FFM takes
   the snapshot branch every move; each sweep that crosses the Dock band drops
   focus updates, so focus feels stuck across the monitor.
2. **A different non-`.regular` full-monitor window** (also newly un-exempted by
   the same change) may be the real occluder on the primary display. If so, the
   fix below (owner allowlist) must cover it too, or fall back to the
   activation-policy exemption.

The fix is the same mechanism regardless of scope; this item only decides how
wide the owner exemption must be.

## Fix

Re-introduce a system-chrome exemption in the FFM occlusion predicate, keeping
`#64`'s intent (faceless interactive overlays like the Ghostty Quick terminal
must still occlude; JankyBorders must not).

**Primary approach — explicit system-owner exemption** in
`visibleUnmanagedInteractiveWindowServerWindowCovers`
(`WMController.swift:2644`). Alongside `isDecorativeBorderOverlayOwner`, add an
`isSystemChromeOwner(ownerName:pid:)` carve-out that exempts the Dock and
comparable non-interactive system surfaces, e.g. owner bundle id
`com.apple.dock` (and, pending the trace above, the menu-bar / WindowServer
owner and Control Center). Apply the exemption as an additional `continue`
branch before `return true`.

Apply the **same** exemption on the fast path. The `windowUnderPointer` branch
`isUnmanagedWindowServerWindow(windowId:trackedWindowIds:)`
(`WMController.swift:2663`) currently applies **no** owner exemption at all — it
returns `true` for any window that is not tracked and not Nehir-owned. If the
CGEvent reports the Dock window as the window under the pointer, this path also
mis-flags it. Route both paths through the same owner-exemption helper.

**Alternative approaches (record, don't default to):**

- *Restore the activation-policy exemption.* Reinstate `activationPolicy !=
  .regular → continue` in the interactive predicate. Simple and matches `0.5.0`
  exactly. Risk: it re-exempts any non-`.regular` interactive overlay. The
  Ghostty Quick terminal is a `.regular` app, so it would still occlude — but
  the code comment at `WMController.swift:2642` claims the Quick terminal can
  appear **faceless** on the snapshot path, which is the case `#64` was guarding.
  Confirm Ghostty's snapshot owner before choosing this. A hybrid ("exempt
  non-`.regular` **with** a bundle id"; keep faceless non-border windows
  occluding) captures the Dock while preserving faceless-Ghostty occlusion.
- *Level cap.* Exempt windows at/above `kCGDockWindowLevel`. Risky: interactive
  overlays can float above normal level and would be wrongly exempted.

Recommended: **explicit system-owner exemption on both paths**, widened per the
trace. It is the most targeted and least likely to re-open `#64`.

## Tests

`Tests/NehirTests/MouseEventHandlerTests.swift` and the WMController occlusion
tests already stub the window providers
(`unmanagedOverlayWindowInfoProvider`, `ownerAppIsInteractiveApplicationProvider`)
and drive `visibleUnmanagedInteractiveWindowServerWindowCovers` with synthetic
window dictionaries. Add cases:

1. A synthetic Dock window (owner `com.apple.dock`, `layer = kCGDockWindowLevel`,
   ≥ 80×80, on-screen) covering the pointer ⇒ predicate returns `false`
   (exempted) ⇒ FFM resolves the tile beneath instead of `.occlusion`.
2. Regression guard: a faceless interactive overlay (Ghostty-Quick-like, no
   bundle id, non-border owner name) covering the pointer ⇒ still `true`
   (occludes). Preserves `#64`.
3. Regression guard: a decorative border overlay (`borders`) ⇒ still exempted.
4. Fast-path parity: `windowUnderPointer` = the Dock window id ⇒ not treated as
   an occluder.

## Non-goals

- **The Dock Edge Shield is unrelated.** `DockEdgeShieldManager` is opt-in and
  off by default (`isEnabled = false`,
  `Sources/Nehir/UI/DockEdgeShield/DockEdgeShieldManager.swift:201`); the shield
  is a Nehir-owned, click-through panel and is excluded from the occlusion scan
  via the owned-window registry. It appears in investigation traces only because
  it was enabled while capturing them. Do not change shield behavior here.
- Do not remove or alter the existing `visibleUnmanagedOverlayWindowServerWindowCovers`
  (`.regular`-based) predicate; it is used elsewhere and is a reference for the
  fix, not a target.
- Fixed-Dock **window parking** quirks (a separate, acknowledged limitation) are
  out of scope; this task only restores focus-follows-mouse.
