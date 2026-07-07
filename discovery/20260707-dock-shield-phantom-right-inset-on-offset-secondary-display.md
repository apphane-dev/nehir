# Discovery: Dock Shield paints a full-height 283 px band on the offset secondary display (phantom right inset)

Status: discovery only — root-caused and source-confirmed. With the experimental
Dock Shield enabled and a **right**-oriented fixed Dock, a large opaque shield
(≈283 px wide, full working height) appears on the **secondary** display (an
offset `DELL P2423D` sitting next to the built-in Retina), even though the Dock
is not on that display. The shield is masking a **phantom** side reservation that
macOS reports on the non-Dock display — the exact "offset DELL next to a
built-in: a bogus right inset with nothing there" case the Dock code already
documents at `Monitor.swift:196-205` and `DisplayEnvironmentDiagnostics.swift:122-125`,
but which the current guard fails to suppress on this topology.

Verified against the main Nehir source tree (`nehir v7a025b`) on 2026-07-07.
Source line numbers below are durable code citations.

## Summary

The shield's only "don't draw here" guard is
`DockReservation.dockIsOnAnotherDisplay(than:)` (`DockEdgeShieldManager.swift:377`).
That predicate is gated on the Dock's Accessibility bar rect being **resolvable**
*and* provably landing on some other connected screen (`Monitor.swift:349-353`).
When the Dock's AX bar is not resolvable — which the code itself notes is common
"right after launch" and while the Dock is hidden (`Monitor.swift:298-300`) — the
predicate short-circuits to `false`, so:

1. `DockReservation.stableVisibleFrame` cannot take its phantom-reclamation branch
   (`Monitor.swift:206-222`) and instead **learns** the live phantom reservation
   as a sticky inset via the bootstrap path (`Monitor.swift:262-264`), because
   282 px is under the 33 %-of-width plausibility cap (`Monitor.swift:248-249`,
   `2560 × 0.33 = 844.8`).
2. The corrected `visibleFrame` for the secondary display keeps a 282 px right
   inset, so `DockEdgeShieldManager.shieldGeometry` computes `rightInset = 282`
   and builds a 283 px-wide right-edge shield (`DockEdgeShieldManager.swift:384-411`)
   — its guard at `:377` shares the same blind spot and does not veto it.

Once learned, the sticky inset is only cleared by an orientation change
(`Monitor.swift:189-191`), a firing of the reclamation branch
(`Monitor.swift:206-209`), or exceeding the plausibility cap
(`Monitor.swift:266-269`). None of these fires for a stable 282 px phantom on a
2560 px display, so the band persists until a manual re-evaluation (the shield
button's `forgetStickyInsets`, `Monitor.swift:163-168`) or a config/display
change.

## Topology / repro

Two displays, `displaySpacesMode=enabled` (Displays have Separate Spaces):

- **Display 1** — built-in Retina, main, notched.
  `frame=(0, 0, 2056, 1329)`, `visibleFrame=(0, 0, 2056, 1290)`.
  Menu-bar inset 39 px at top; **no side inset, no bottom inset**
  (`visibleFrame.maxX = frame.maxX = 2056`).
- **Display 2** — `DELL P2423D`, secondary, sits directly **above** display 1 and
  is horizontally offset. `frame=(-222, 1329, 2560, 1440)`,
  `visibleFrame=(-222, 1329, 2278, 1410)`. Menu-bar inset 30 px at top, plus a
  **282 px right inset**: `frame.maxX (2338) − visibleFrame.maxX (2056) = 282`.

Dock: orientation resolves to **right** (the shield is `edge=right` and the inset
is computed on the right axis, `Monitor.swift:228`). A right-oriented fixed Dock
reserves on exactly one display; display 1 shows **zero** right reservation, so
the only right reservation in the system is the 282 px on the secondary — the
phantom. Under the user's report ("huge shield, nothing there"), the Dock is not
physically on display 2.

Repro: Dock Shield enabled + right-fixed Dock + this two-display arrangement
(offset secondary above/beside the built-in), cold start. The shield materializes
on the secondary as services come up.

## Evidence (inlined from the capture)

### The materialized shield (settled runtime-state dump, `startedServices=true`)

```text
-- Dock Edge Shield --
monitor=2 edge=right frame=(2055,1336 283x1371) wantFrame=(2055,1336 283x1371) \
  logo=(2063,2613 267x82) button=(2174,2000 44x44) visible=true level=19
```

- Width `283 = rightInset(282) + parkCover(1)` (`DockEdgeShieldManager.swift:388,399,401`).
- `x = 2055 = visibleFrame.maxX(2056) − parkCover(1)` (`:399`).
- Height `1371` ≈ full working height of the secondary — a floor-to-ceiling band,
  not a thin Dock rail. The decorative wordmark (`267×82`) and the 44 px button
  are drawn inside it.
- `level=19` = `CGWindowLevelForKey(.dockWindow) − 1` (`DockEdgeShieldManager.swift:343`).

### Topology carries the phantom inset before services even start

At `startedServices=false` (capture start) the monitor topology **already** shows
the corrected secondary `visibleFrame=(-222, 1329, 2278, 1410)` — i.e.
`Monitor.current()` → `stableVisibleFrame` had already baked in the 282 px right
inset. The `-- Dock Edge Shield --` section reads `no-shields` at this point only
because `DockEdgeShieldManager.update(...)` has not run yet (services not up). By
the settled dump (`startedServices=true`, ~24 s later) the shield section shows
the 283 px panel above. So: the phantom inset was learned first; the shield simply
rendered whatever the corrected `visibleFrame` implied once it ran.

### The reservation is retained, not reclaimed

Across both the start-state and settled-state topology dumps the secondary's
right inset stays at 282 px. If `dockIsOnAnotherDisplay(than: display2.frame)` had
returned `true` at any topology recompute, `stableVisibleFrame` would have cleared
the sticky inset and widened `visibleFrame` back to `frame.maxX` (reclamation
branch, `Monitor.swift:206-222`), and the shield guard at
`DockEdgeShieldManager.swift:377` would have returned `nil`. Neither happened, so
the predicate evaluated `false` throughout the capture window — including after
the startup settle re-reads at 0.5 s / 1.5 s / 3.0 s
(`ServiceLifecycleManager.swift:302`).

## Root cause (source walk)

The phantom-vs-real disambiguation hinges entirely on **one** signal — the Dock's
AX bar rect (`DockReservation.dockBarRect` → `dockBarAppKitRect`,
`Monitor.swift:336-343,355-389`) — and every safeguard degrades unsafely when
that signal is absent.

1. **Guard degrades open.** `dockIsOnAnotherDisplay` returns `false` whenever the
   bar rect is `nil` (`Monitor.swift:350`). "Cannot prove the Dock is elsewhere"
   is treated identically to "the Dock is here," so the phantom is not reclaimed
   and the shield is not vetoed.

2. **Sticky inset bootstraps from the phantom.** With the bar unresolvable,
   `axDerivedInset` also returns `nil` (`Monitor.swift:314`), so
   `stableVisibleFrame` falls to the live-reservation bootstrap
   (`Monitor.swift:262-264`): `stickyInset[2] = currentInset = 282`. The only
   gate here is the plausibility cap `maxPlausibleInset = frame.width × 0.33`
   (`Monitor.swift:248-249`). On a 2560 px-wide display that cap is **844.8 px**,
   so a 282 px phantom sails through. The cap was sized to catch *huge*
   transient reconfiguration garbage (`Monitor.swift:244-247`), not a
   several-hundred-px phantom.

3. **No self-heal on this geometry.** After the Dock becomes AX-readable, the
   only positive correction path for the secondary is
   `axDerivedInset(frame: display2)`, whose guards require the bar to fall
   *within display 2's own bounds* (`Monitor.swift:316-322`). A bar physically on
   display 1 fails those guards → returns `nil` → never overwrites the learned
   282 px. So the phantom can only be removed by the reclamation branch, which
   needs `dockIsOnAnotherDisplay == true`. For this stacked/offset arrangement a
   right-edge Dock bar on display 1 (small x-overlap with display 2's x-range,
   but disjoint in y) does not intersect display 2 — yet the predicate still
   requires the bar to be *resolvable* in the first place; if it stays `nil`
   through the capture, the phantom is permanent for the session.

4. **The shield guard shares the blind spot.** `shieldGeometry` re-invokes the
   same `dockIsOnAnotherDisplay` (`DockEdgeShieldManager.swift:377`) and otherwise
   trusts `visibleFrame` unconditionally: any `rightInset > 0.5` becomes a shield
   (`Monitor.swift... DockEdgeShieldManager.swift:397-411`). It cannot
   independently detect a phantom that `stableVisibleFrame` has already folded
   into `visibleFrame`.

Net: the phantom 282 px right inset on the offset secondary is (a) learned as a
sticky inset because the Dock AX bar was unresolvable at learn time, and (b) never
reclaimed, so it drives a full-height 283 px shield on a display that has no Dock.

Note: `DisplayEnvironmentDiagnostics.fixedDockIssues` uses a 24 px threshold and
its comment (`:122-125`) assumes phantoms are "already removed upstream by
`stableVisibleFrame`." Since that upstream removal is exactly what failed here,
the same 282 px phantom would additionally surface as a spurious *fixed-Dock*
diagnostic on the secondary — a second symptom of the same root cause.

## What the trace cannot show (and how to confirm the exact branch)

The runtime-state dump records the shield geometry and corrected `visibleFrame`
but **not** the Dock AX bar rect, so the log alone cannot distinguish "bar was
`nil`" (branch 1, most consistent with the `no-shields → shield` progression and
the documented cold-start nil behavior) from "bar resolved but tested as
intersecting display 2." To pin it down, add a trace line in
`stableVisibleFrame` / `dockIsOnAnotherDisplay` that records
`dockBarAppKitRect()` (or `nil`) and the per-display intersection outcome at each
topology recompute, then reproduce.

## Candidate fix directions (not yet a plan)

- **Reject side insets that don't correspond to a resolvable, on-this-display Dock
  bar.** Only bootstrap `stickyInset` from the live reservation when the AX bar is
  readable and lands on this display; treat a side reservation with an
  unresolvable bar as unknown rather than learning it. This closes the
  learn-the-phantom path at `Monitor.swift:262-264`.
- **Tighten / add an absolute cap for side insets.** A right/left Dock band is
  typically ~100–150 px; the 33 %-of-width relative cap is far too loose on wide
  externals. An absolute side-inset ceiling (or a much smaller side-specific
  fraction) would reject a 282 px phantom while leaving bottom insets alone.
- **Cross-check the shield against a positive Dock signal.** Have
  `shieldGeometry` require an affirmative "Dock bar is on *this* display" reading
  (not merely "not provably elsewhere") before painting, so an unresolvable bar
  never yields a shield.
- **Re-probe / reclaim on settle even when width is unchanged.** The settle
  refreshes only re-apply when `visibleFrame` width changed
  (`ServiceLifecycleManager.swift:310-315`); a phantom learned before the first
  settle stays because the width never changes. Force a phantom-reclamation check
  once the Dock AX bar first becomes resolvable.

Whichever direction is chosen, the invariant to restore is: **a display that does
not host the Dock must not retain a side inset, and must never receive a shield.**
