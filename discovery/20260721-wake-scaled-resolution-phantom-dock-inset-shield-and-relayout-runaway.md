# After open-from-sleep: phantom 328 px Dock shield, dancing windows, relayout runaway — Discovery

> Scope: root-cause a repeat of the reported post-wake glitch on a laptop
> (built-in display + one external HP), captured on a fresh session. Refines and
> **corrects** the earlier note
> `20260714-wake-transient-dock-reservation-giant-shield-and-relayout-storm.md`.
> Source-backed; **does not propose a fix** — leads with confirmed mechanism and
> lists what a plan must still verify. Symbol/line references verified against
> main-repo HEAD `0d409327`; re-verify before implementing (they drift) and cite
> by symbol name.

## Symptom (as reported)

Laptop lid opened from sleep. For several seconds the windows "danced" (jumped /
re-parked / re-revealed), and a **large dark Dock shield** appeared down the
right edge of the built-in display and stayed there.

## TL;DR

Three independent effects, one wake event — matching the earlier note, but this
capture pins the shield's origin arithmetically and corrects the relayout-storm
mechanism.

1. **Phantom 328 px shield (primary complaint).** After wake, the built-in
   display's working area was reported **328 px narrower** than its physical
   frame on the right edge — an inset that was **not present** at session start
   (full-width working area, no shield). The Dock Shield has no size of its own;
   it fills exactly the reserved band, so a bogus 328 px reservation yields a
   329 px-wide shield. Crucially, **328 = 2056 − 1728**, the exact width
   difference between the two scaled built-in-display modes seen in this session.
   The inset behaves as a single learned "sticky" value re-subtracted from
   whatever physical `frame.maxX` is live: it produced `2056 − 328 = 1728` under
   the old mode and `1728 − 328 = 1400` under the settled mode. 328 clears the
   plausibility guard (`0.33 × frame.width ≈ 570` px at 1728 wide), so it was
   accepted and — being sticky — it persisted instead of self-healing.
2. **Dancing windows.** Display topology bounced **2 → 1 → 2 → 1 → 2** over a
   ~2.5-minute wake settle, and the built-in frame was read as **both** 2056×1329
   and 1728×1117 within the same settle window. Every topology transition forces
   a full rescan + re-park, so windows visibly shuffled (repeated
   `offscreen → tiled → offscreen` flips on the same windows inside a single
   second).
3. **Relayout runaway (invisible, but severe).** **13** `monitorConfigurationChanged`
   refresh *requests* produced **4,450,441** *executions*; **170** `axWindowCreated`
   requests produced **1,011,812** executions. This is a self-perpetuating
   re-execution loop, not genuine request volume. Peak RSS ~205 MB.

Findings 1–3 are distinct bugs that co-fire on wake. The shield is the
user-visible one; #2 explains the dancing; #3 is a latent perf/stability hazard.

---

## Evidence (inlined; self-contained)

Session ran on a single machine over ~5.8 h; the wake churn is the last ~2.5 min.

**Topology at start** (healthy): one display only.
`display 1 isMain hasNotch frame=(0,0,2056,1329) visibleFrame=(0,0,2056,1290)`
— working width == full width (**no** right inset), `-- Dock Edge Shield -- no-shields`.

**Topology at end** (anomalous): external reconnected, built-in mode settled.
```
display 1 isMain hasNotch frame=(0,0,1728,1117) visibleFrame=(0,0,1400,1084)
display 3          HP Z27k G3 frame=(-104,1117,1920,1080) visibleFrame=(-104,1117,1920,1050)
-- Dock Edge Shield --
monitor=1 edge=right frame=(1399,7 329x1045) visible=true level=19
```

Six managed windows, all tiling on built-in workspaces (Ghostty `853:4883`/`853:7233`,
Slack `13432:6095`, Telegram `23324:2421`, Helium `34788:188`, VS Code `89703:8368`).

### The working area shrank *after* wake; start had none

`visibleFrame.width` at start = **2056** (full frame width, no reservation);
at end = **1400** on a 1728-wide frame → a **328 px** right inset that
materialised across the wake. So 328 px is **not** this machine's steady state.

### One sticky value, re-applied against two different physical frames

A single 328 px right inset is subtracted from whatever physical `frame.maxX`
is live at read time. Two frame readings coexisted during the settle, both
carrying the same 328 (corrected `Monitor.visibleFrame` values, sticky already
applied):

```
11×  monitorFrame=(0,0 2056x1329)  visibleFrame=(0,0 1728x1290)   # 2056 − 328 = 1728
 6×  monitorFrame=(0,0 1728x1117)  visibleFrame=(0,0 1400x1084)   # 1728 − 328 = 1400
```

The shield update reconciles exactly with the 1728-frame reading:
```
dockShield.update monitor=1 edge=right frame=(1399,7 329x1045)
                  visibleFrame=(0,0 1400x1084) monitorFrame=(0,0 1728x1117)
```
- `rightInset = frame.maxX − visibleFrame.maxX = 1728 − 1400 = 328`
- shield width `= rightInset + parkCover = 328 + 1 = 329` ✓
- shield x `= visibleFrame.maxX − parkCover = 1400 − 1 = 1399` ✓

The external display draws no shield (`dockShield.skip monitor=3
reason=noReservedEdge leftInset=0.0 rightInset=0.0`).

**Origin arithmetic (the new lead):** `2056 − 1728 = 328`. The two values are
the widths of the two scaled built-in modes observed this session. The phantom
inset equals a `frame.maxX` from the **old** mode paired with a
`visibleFrame.maxX` from the **new** mode — a frame/visibleFrame pair that
straddled the resolution transition. This is exactly the "momentarily
inconsistent frame/visibleFrame … huge bogus inset … giant shield" case the code
comment warns about (`DockReservation.stableVisibleFrame`, the comment block
above `maxPlausibleInset`).

### Topology / resolution churn (the "dancing")

```
06:54:41  topology_changed displays=1  plan=topology=2->1   interaction 1→3
06:56:58  topology_changed displays=2  plan=topology=1->2
06:56:58  topology_changed displays=2  plan=topology=2->2
06:57:00  topology_changed displays=1  plan=topology=2->1   disconnected_cache=1
06:57:00  topology_changed displays=1  plan=topology=1->1   disconnected_cache=1
06:57:04  topology_changed displays=2  plan=topology=1->2
06:57:04  topology_changed displays=2  plan=topology=2->2
```

During the 06:54:41 transition, the same windows flip
`hidden(offscreen) → tiled → hidden(offscreen)` several times within one second
as repeated `window_admitted context=startup_full_rescan` batches re-run. That
repeated park/reveal is the visible dance. Interaction-monitor writes corroborate
the bounce: `applyTopologyTransition` fires at 06:54:41, 06:56:58 (twice),
06:57:00, and 06:57:04.

### Relayout runaway

```
fullRescan=4450683  relayout=1011839  immediateRelayout=1199  windowRemoval=502
requestedByReason=[ monitorConfigurationChanged: 13,  axWindowCreated: 170,  … ]
executedByReason =[ monitorConfigurationChanged: 4450441,  axWindowCreated: 1011812,  … ]
```

13 requests → 4,450,441 executions for `monitorConfigurationChanged`; 170 → 1,011,812
for `axWindowCreated`. `fullRescan` (4,450,683) tracks the `monitorConfigurationChanged`
execution count; `relayout` (1,011,839) tracks `axWindowCreated`. Peak RSS ~205 MB.

---

## Root cause — source-backed

### Finding 1 — a single sticky inset is re-applied against the live physical edge; the guard is too loose to reject the 328 px wake artifact

`Monitor.current()` does not pass `NSScreen.visibleFrame` through untouched — it
routes it through `DockReservation.stableVisibleFrame(frame:visibleFrame:displayId:)`
(`Sources/Nehir/Core/Monitor/Monitor.swift`, the `stableVisibleFrame` call inside
`Monitor.current()`). That helper deliberately treats a Dock inset as a **sticky,
learned property** keyed by `displayId` (`stickyInset: [CGDirectDisplayID: CGFloat]`,
declared near the top of `enum DockReservation`) so a fixed Dock's reservation
survives transient suppression (drop-down terminals, auto-hide).

Once learned, the inset is applied **against the stable physical frame edge, not
the live `visibleFrame`** (see the `switch effectiveOrientation` block, `right`
case: `corrected.size.width = (frame.maxX - inset) - corrected.origin.x`). This
is why the *same* 328 produced `1728` under a 2056 frame and `1400` under a 1728
frame — the sticky is a fixed number re-subtracted from whatever `frame.maxX` is
live. It is exactly the sticky design; the trace confirms it operating.

The plausibility guard that is supposed to reject reconfiguration artifacts:
```
let isSideOrientation = effectiveOrientation == "left" || effectiveOrientation == "right"
let dockAxisSize = isSideOrientation ? frame.width : frame.height
let maxPlausibleInset = dockAxisSize * 0.33
```
For the built-in the axis is `frame.width`, so the ceiling is `0.33 × 1728 ≈ 570`
px (or `0.33 × 2056 ≈ 678` if evaluated under the old mode). The artifact was
**328 px**, under both ceilings — so it passed, was applied, and (being sticky)
stuck. The in-code comment above `maxPlausibleInset` names this failure mode
verbatim, and the adjacent `TODO` already flags that the side-inset ceiling wants
to be tighter than the cross-orientation `0.33` cap.

**What the trace adds over the earlier note:** the artifact size equals the
scaled-mode width delta (`2056 − 1728 = 328`), pointing the origin squarely at a
frame/visibleFrame read that straddled the scaled-resolution transition, rather
than at a generic "inconsistent read". A tighter *ratio* ceiling alone would not
have caught 328 (it is only ≈19 % of 1728); the fix likely has to refuse to
**learn** a new sticky inset while the display mode/topology is unsettled.

### Finding 1b — the shield faithfully mirrors the (bad) working area; it is not itself at fault

`DockEdgeShieldManager.shieldGeometry(for:)`
(`Sources/Nehir/UI/DockEdgeShield/DockEdgeShieldManager.swift`) derives the band
purely from the monitor geometry it is handed:
```
let rightInset = monitor.frame.maxX - monitor.visibleFrame.maxX
…
if rightInset > 0.5 {
    // x = monitor.visibleFrame.maxX - parkCover ; width = rightInset + parkCover
```
`parkCover = 1`, so the shield is `rightInset + 1` wide by construction. Any fix
belongs upstream in the working-area computation (Finding 1), not in the shield.

### Finding 2 — every topology bounce forces a full rescan; the wake bounced five times

`monitorConfigurationChanged` is inherently a full-rescan trigger; the pathology
is the **number of transitions** — five `topology_changed` edges (`2→1→2→1→2`)
across the ~2.5-min settle, plus a built-in frame that read as both 2056×1329 and
1728×1117 during it. Each rescan re-parks/re-reveals windows (the visible
dancing). This is a churn-debouncing gap, not a logic error in any single rescan.

### Finding 3 — CORRECTION: follow-up re-enqueues *are* counted; the runaway is elsewhere

The earlier note attributed the request/execution divergence to
`finishRefresh(_:didComplete:)` re-enqueuing follow-ups "directly via
`enqueueRefresh(...)` … outside `recordRefreshRequest`". **That is not what the
source does** — at both the earlier note's HEAD (`3056bee8`) and current HEAD
(`0d409327`), `enqueueRefresh` records a request on its **first line**:

```
private func enqueueRefresh(_ refresh: ScheduledRefresh) {
    recordRefreshRequest(refresh.reason, affectedWorkspaceIds: refresh.affectedWorkspaceIds)
    …
```
(`LayoutRefreshController.swift`, `enqueueRefresh`.) And `finishRefresh`
re-enqueues its follow-up **through** `enqueueRefresh`:
```
if let followUpRefresh = completedRefresh.followUpRefresh {
    enqueueRefresh(.init(kind:…, reason: followUpRefresh.reason, affectedWorkspaceIds:…))
}
```
So a follow-up loop would drive `requestedByReason` upward in lockstep with
`executedByReason`. The trace shows the **opposite**: 13 requests, 4.45 M
executions. Therefore the amplification is **not** the follow-up path.

Executions are counted once per `recordRefreshExecution(_:reason:)` call, invoked
from the execution routes (`executeRelayout` calls it before building the plan;
likewise `executeVisibilityRefresh`, `executeWindowRemoval`). The scheduler
(`startNextRefreshIfNeeded`) pulls a single `pendingRefresh` slot, runs
`execute(_:)`, then `finishRefresh`. For 13 requests to yield 4.45 M executions,
the same refresh must be re-driven into `pendingRefresh` **without** passing
`enqueueRefresh` — a re-execution path that bypasses the request counter. The
earlier note identified the right *symptom* (self-perpetuating re-execution under
wake churn) but the wrong *mechanism*. **The exact producer that re-arms the
pending slot 4.45 M times is unconfirmed and is the key open question below.**

---

## Confirmed vs. to-confirm

**Confirmed from source + inlined evidence:**
- The shield width == `rightInset + 1`; it mirrors `Monitor.visibleFrame` and has
  no independent size (`DockEdgeShieldManager.shieldGeometry`).
- `visibleFrame` is filtered through `DockReservation.stableVisibleFrame`, which
  learns a per-display sticky inset and applies it against the **physical** frame
  edge, rejecting only insets above `0.33 × axis`
  (`Monitor.swift`, `stableVisibleFrame` / `maxPlausibleInset`). 328 < 570 ⇒
  accepted; one sticky value reproduced both `1728` and `1400` working widths.
- The 328 px reservation is a post-wake development (full-width `visibleFrame` at
  session start) and equals `2056 − 1728`, the scaled-mode width delta.
- `enqueueRefresh` records a request on every call, and `finishRefresh` routes
  follow-ups through it (`LayoutRefreshController.swift`, both HEADs) — so the
  earlier note's follow-up-bypass explanation for the runaway is **incorrect**.

**Still to confirm before a plan:**
- **The exact learn moment for the 328 px inset.** A *right* inset is learned
  only from `axDerivedInset` (AX Dock-bar geometry) — the `currentInset`
  bootstrap branch is bottom-orientation-only (`!isSideOrientation`). So either
  the AX Dock bar reported a phantom rect during the mode switch, or
  `effectiveOrientation`/`frame` were mis-paired. Needs a targeted trace at the
  `stableVisibleFrame` learn site logging `frame`, raw `visibleFrame`,
  `effectiveOrientation`, `derivedInset`, and the resulting `stickyInset` write.
- **Whether refusing to learn while topology/mode is unsettled is sufficient**,
  vs. also tightening the side-inset ceiling. A ratio ceiling alone misses 328
  (≈19 % of 1728).
- **The real re-execution loop behind the 13→4.45 M divergence** — which producer
  re-arms `pendingRefresh` without going through `enqueueRefresh`. Needs a
  targeted trace of `recordRefreshExecution` / `startNextRefreshIfNeeded` call
  origins under topology churn. (Supersedes the earlier note's follow-up-counter
  hypothesis.)

## Where a fix would live (for the plan stage — not prescribed here)

- Working-area stability: `DockReservation.stableVisibleFrame` / `maxPlausibleInset`
  (`Monitor.swift`) — gate the **learn** of a new sticky inset on a settled
  display mode/topology, and/or tighten the side-inset ceiling.
- Wake churn debounce: the topology / `monitorConfigurationChanged` rescan
  scheduling in `LayoutRefreshController`.
- Relayout runaway: the re-execution path that re-arms `pendingRefresh` (identify
  first via trace; do **not** target `finishRefresh`'s follow-up enqueue, which
  is correctly counted).

## Relationship to prior discovery

Refines and partially corrects
`20260714-wake-transient-dock-reservation-giant-shield-and-relayout-storm.md`:
- Confirms Findings 1 / 1b / 2 with a second independent capture and adds the
  `328 = 2056 − 1728` origin arithmetic (answers that note's open question about
  which frame reading produced the inset: neither in isolation — a straddling
  pair).
- **Overturns** that note's Finding 3 mechanism: `enqueueRefresh` records
  requests, so follow-up re-enqueues cannot explain the divergence; the runaway
  source is still open.
