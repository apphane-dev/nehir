# Phantom 328 px side-Dock inset: kill the straddled AX-probe learn on wake

Verified against `main` on 2026-07-21 (HEAD `0d409327`). **Re-verify line numbers
before editing; they drift.** Scopes **Finding 1 only** of
[`20260721-wake-scaled-resolution-phantom-dock-inset-shield-and-relayout-runaway.md`](./20260721-wake-scaled-resolution-phantom-dock-inset-shield-and-relayout-runaway.md)
(the user-visible shield). Findings 2 (dancing / topology-bounce debounce) and 3
(relayout re-execution runaway) are separate plans and are explicitly out of
scope here.

**Status:** LANDED 2026-07-21 as `3baf74d7` on `main`. **The implementation
deviated from the proposal below** — see "As landed" next. Finding 3 (relayout
runaway), scoped *out* here, was fixed in the same commit; Finding 2 remains
open (`discovery/20260721-wake-topology-bounce-repark-dancing.md`).

## As landed (`3baf74d7`) — deviation from the proposal

The shipped fix does **not** invalidate the memoized probe from
`ServiceLifecycleManager` (Steps 1–2 below). It instead makes
`DockReservation.stableVisibleFrame` self-correcting on any physical-frame change,
which catches the straddle intrinsically regardless of which reconfiguration path
fires — judged the better fix. `ServiceLifecycleManager.swift` was untouched.

Actual changes, all in `Sources/Nehir/Core/Monitor/Monitor.swift` (`DockReservation`):

- Added `lastFrame: [CGDirectDisplayID: CGRect]`. When a display's `frame`
  changes (a mode/resolution switch, not a Dock hide/show), drop its `stickyInset`
  and set a `frameChanged` flag.
- Gated **both** learn branches on `!frameChanged`, so a frame/bar read straddling
  the transition cannot re-learn the mode-width delta on the same pass.
- Added `edgeFlushTolerance = 24` guards in `axDerivedInset` (left and right):
  reject a Dock-bar rect whose outer edge is not flush against the current frame
  edge — i.e. a stale bar cached under a smaller mode. This is the direct guard
  against the `2056 − 1728 = 328` straddle.
- Added a `dockInset.learn` trace at the learn site.

The **root-cause analysis below is accurate** (straddled stale AX-bar memo across
the scaled-resolution switch); only the fix vector changed. The changeset and
commit that landed cover both this and Finding 3 (see the discovery's Resolution
section). The Step 3 regression tests were **not** written — the no-test-edits gate
still holds pending the user's real-repro confirmation.

The original proposal follows unchanged, for the record.

**Status (original):** planned.

**Symptom:** Opening the laptop lid from sleep leaves a large dark Dock Shield
down the **right edge** of the built-in display that does not clear. The working
area is reported ~328 px narrower than the physical frame on the right; the
shield has no size of its own and just fills that bogus reservation band.

## Root cause (confirmed in source, 2026-07-21)

`Monitor.current()` filters `NSScreen.visibleFrame` through
`DockReservation.stableVisibleFrame(frame:visibleFrame:displayId:)`
(`Sources/Nehir/Core/Monitor/Monitor.swift:36`, helper at `:170`), which learns a
per-display **sticky** side inset and applies it against the physical frame edge.

**The learn site is pinned.** A *right* (side) inset can only be written at
`Monitor.swift:313` — `stickyInset[displayId] = derivedInset` — the AX-derived
branch. The other learn site, `Monitor.swift:320` (`= currentInset`), is gated
`!isSideOrientation` (`:315`) and its non-side `currentInset` is the **vertical**
measure `visibleFrame.minY - frame.minY` (`:267`); it can never produce a
right-edge inset. So the 328 was adopted from
`axDerivedInset(frame:, orientation:"right")` (`:270`, `:385`), which returns
`frame.maxX - appKitBar.minX` (`:396`).

**The value is a straddle across the scaled-resolution switch.** `328 = 2056 −
1728`, the exact width delta between this session's two scaled built-in modes.
`axDerivedInset` read a Dock-bar `minX ≈ 1728` (a coordinate valid in the *new*
1728-wide mode) against a `frame.maxX = 2056` still read in the *old* mode:
`2056 − 1728 = 328`. The bar coordinate is stale because `cachedDockBarRect()`
**memoizes the Dock bar rect for ~5 s** (`Monitor.swift:373-383`); across a
resolution change the cached (new-mode) bar is paired with an as-yet-old-mode
frame. `328 ≤ maxPlausibleInset` (`0.33 × 1728 ≈ 570`, `:298-300`), so the guard
accepted it; hysteresis (`:310`) then kept it sticky, and it was re-subtracted
from whichever physical `frame.maxX` was live thereafter (producing `1728` under
the 2056 frame and `1400` under the 1728 frame). The shield faithfully mirrors
that bad working area (`DockEdgeShieldManager.shieldGeometry`,
`Sources/Nehir/UI/DockEdgeShield/DockEdgeShieldManager.swift:385` / `:401`:
`width = rightInset + parkCover`) — **Finding 1b: the shield is not at fault.**

**Why the frame guards do not already reject it.** `axDerivedInset`'s right-case
guards (`Monitor.swift:395`) require `appKitBar.maxX <= frame.maxX` and
`appKitBar.minX >= frame.midX`. A bar *lagging* at old-mode coordinates (minX
beyond the new frame) is correctly rejected → nil → no learn. But a bar cached in
the *narrower new* mode (minX = 1728) fits inside the *wider old* frame's guards,
so it is accepted. The stale-memo pairing is the one straddle that slips through.

This machine's Dock is on the **right edge** (derivable from source: for the
right shield to persist, `effectiveOrientation == "right"` at apply
(`Monitor.swift:354`); a bottom Dock yields `axSideOrientationOnThisDisplay ==
nil` (`:200-210`) and a `"bottom"` fallback, which cannot render a right shield).
So a *small* right inset is legitimate; only the oversized straddled 328 is the
bug. The fix must therefore keep learning genuine right insets and reject only the
straddle.

## Fix — invalidate the memoized Dock-bar probe on display reconfiguration

The straddle vector is the ~5 s AX-bar memo surviving a frame/mode change. Drop
that memo at the single coalescing choke point for every reconfiguration
notification, *before* the monitors are rebuilt, so the next
`stableVisibleFrame` samples a Dock bar in the same mode as the live frame. This
is minimal, targeted, and touches neither the learn heuristics nor the
sticky-survives-suppression design (so no auto-hide / quick-terminal regression).

### Step 1 — add a probe-only invalidator to `DockReservation`

File: `Sources/Nehir/Core/Monitor/Monitor.swift`.

Next to `forgetStickyInsets()` (`:163-168`), add a sibling that clears **only**
the memoized AX probe — never the learned sticky insets (dropping those on every
reconfig would re-tile/flap the working area, which the sticky design exists to
prevent):

```swift
/// Drop only the memoized Dock-bar AX probe, forcing the next
/// `stableVisibleFrame` to re-sample the bar. Called on display
/// reconfiguration so a bar rect cached under one resolution/mode cannot be
/// paired with a frame read under another (the scaled-mode "straddle" that
/// learns a phantom side inset, e.g. 2056 − 1728 = 328). Unlike
/// forgetStickyInsets(), this preserves every learned sticky inset, so a fixed
/// Dock's working area does not flap on reconfiguration.
static func invalidateDockBarProbe() {
    lock.lock()
    defer { lock.unlock() }
    lastAXProbe = nil
}
```

(`lastAXProbe` is the only bar memo — `Monitor.swift:157`. `cachedDockBarRect()`
re-probes whenever it is nil, `:375-382`.)

### Step 2 — invalidate before rebuilding monitors on every reconfiguration

File: `Sources/Nehir/Core/Controller/ServiceLifecycleManager.swift`, function
`handleMonitorConfigurationChanged()` (`:199-206`).

This is the coalesced entry point for **both** `DisplayConfigurationObserver`
events (`handleDisplayEvent` → `:182`) and `didChangeScreenParameters`
(`:167-170`). Inside the debounced Task, immediately **before** the
`Monitor.current()` call that feeds `applyMonitorConfigurationChanged`
(`:204`), invalidate the probe:

```swift
monitorConfigurationCoalesceTask = Task { @MainActor [weak self] in
    try? await Task.sleep(for: .milliseconds(50))
    guard !Task.isCancelled, let self, self.controller != nil else { return }
    DockReservation.invalidateDockBarProbe()          // <-- add
    self.applyMonitorConfigurationChanged(currentMonitors: Monitor.current())
}
```

`Monitor.current()` (called at `:204`) drives `stableVisibleFrame` →
`axDerivedInset` → `cachedDockBarRect`, so clearing the memo one line earlier
guarantees the rebuild samples a fresh bar in the current mode. The existing
50 ms coalescing debounce bounds the extra AX query to at most one per settled
reconfiguration burst.

### Step 3 — regression test (DO NOT WRITE YET)

**Gate:** per the repo `AGENTS.md` and `docs/TESTING.md`, do **not** add, modify,
or delete any test until the user has confirmed this fix in their real
lid-open-from-sleep repro. This step is the *intended* coverage, described so the
implementer knows the target — it is not authorization to write it first.

When cleared, add a new small per-behavior file (do **not** append to the frozen
monoliths) — e.g. `Tests/NehirTests/DockReservationStraddleLearnTests.swift` —
that fakes only the OS boundary (frame + AX Dock-bar rect), never the learn
algorithm:

1. **Straddle is not learned.** Feed a right-Dock bar at a new-mode `minX` while
   the frame is still old-mode (`frame.maxX` from the wider mode) with a fresh
   probe invalidated between the two reads; assert the learned right inset is the
   legitimate small value (or unlearned), **not** the `oldMaxX − barMinX`
   straddle delta.
2. **Legitimate small right inset still learns.** A coherent same-mode
   bar+frame learns the real inset (guards the fix does not over-suppress).
3. **Sticky survives suppression.** With a learned inset, a transient
   full-width reservation (Dock hidden) leaves the sticky untouched — invalidating
   the *probe* must not drop the *sticky* (guards Step 1's probe-only scope).

Prefer asserting through `stableVisibleFrame` / `Monitor.current()` output with a
faked bar rect over reaching into private state; add a read-only observability
accessor only if unavoidable, and document why (per
`discovery/20260708-test-only-seams-can-make-tests-untruthful.md`).

## Considered and not included

- **Tighten the side-inset ceiling** (`maxPlausibleInset`, `Monitor.swift:300`,
  and its `TODO` at `:301`). Rejected as the fix: 328 is only ≈19 % of 1728, well
  under any ratio ceiling that still admits legitimately large side Docks. It
  does not catch this artifact.
- **AX↔live coherence gate at the learn site** (refuse to learn when
  `derivedInset` disagrees with the live OS side reservation). Rejected: an
  **auto-hide** right Dock legitimately has a zero live reservation while its AX
  bar is momentarily revealed, so an AX-must-equal-live gate would break the very
  auto-hide learning the AX-derived branch exists for. Probe invalidation fixes
  the straddle without this risk.
- **Self-healing an already-stuck sticky 328.** With Step 2 the phantom is never
  learned, so no persisted-bad-value cleanup is needed for this bug. A general
  "reclaim a stale side sticky" path risks the sticky-survives-suppression design
  and is a separate decision if a future case needs it; the manual shield
  re-evaluate button (`forgetStickyInsets()`) already exists as an escape hatch.

## Do-not-touch fences

- Do **not** change the shield geometry
  (`DockEdgeShieldManager.shieldGeometry`) — it faithfully mirrors the working
  area (Finding 1b); the fix is upstream in the working-area computation.
- Do **not** alter the sticky-inset learn/apply heuristics, the
  `maxPlausibleInset` guard, hysteresis, or the apply block
  (`Monitor.swift:298-361`). This plan only drops the *memoized probe* on
  reconfiguration; the learn logic is unchanged.
- Do **not** make `invalidateDockBarProbe` clear `stickyInset` (that is
  `forgetStickyInsets`' job and would re-introduce working-area flapping).
- Do **not** touch `LayoutRefreshController` or the topology/rescan scheduling —
  those are Findings 2 and 3 (separate plans).
- Scope: two source files (`Monitor.swift`, `ServiceLifecycleManager.swift`) plus
  a changeset. The test file lands only after the user's real-repro confirmation.

## Gate

- **Between steps (fast):** `mise run build` (or `hk check` / `mise run check`
  for format + lint + build).
- **Once at the end (full):** `mise run test` (full suite) must stay green;
  existing `Monitor` / `DockReservation` / `ServiceLifecycleManager` /
  `DockEdgeShield` tests must not regress. Add the Step 3 test only after the
  user confirms the real repro, then re-run the full suite.

## Changeset (required — user-visible bug fix)

```bash
mise run changeset patch "Stop a phantom right-edge Dock shield from appearing after opening the lid from sleep on a scaled-resolution built-in display"
```

Mention the Nehir issue number in the summary if one is filed for this report;
otherwise omit. Do not cite upstream tickets in the changeset.

## Commit message shape

Plain-English subject, no Conventional-Commits prefix:

```
Drop the memoized Dock-bar probe on display reconfiguration

stableVisibleFrame learned a per-display side Dock inset from the AX Dock-bar
rect, which cachedDockBarRect memoizes for ~5s. Across a scaled-resolution
switch on wake, a bar rect cached in the new (narrower) mode was paired with a
frame still read in the old (wider) mode, so axDerivedInset returned the mode
width delta (2056 - 1728 = 328) as a right inset. It cleared the 0.33x
plausibility ceiling, was learned sticky, and drew a phantom right-edge Dock
shield that never cleared.

Add DockReservation.invalidateDockBarProbe() (clears only the memoized AX probe,
never the learned sticky insets) and call it in handleMonitorConfigurationChanged
before Monitor.current(), so every reconfiguration rebuild samples a Dock bar in
the same mode as the live frame. The straddle can no longer be learned; a
genuine side Dock still learns its real inset, and a fixed Dock's working area
does not flap.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
```

(No confirmed Nehir issue number at plan time; add `Fixes #nnn` only for a real
nehir-repo issue. Do not write a bare `#nnn` for an upstream ticket.)

## Completion token

On success, after the full gate is green, print exactly:

`PLAN_DONE_phantom_dock_side_inset_straddle_fixed`
