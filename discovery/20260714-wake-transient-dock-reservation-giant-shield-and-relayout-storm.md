# After sleep/wake: giant Dock shield and dancing windows — Discovery

> Scope: root-cause a reported post-wake visual glitch on a laptop (built-in
> display + one external). Source-backed; **does not propose a fix** — leads
> with confirmed mechanism and lists what a plan must still verify. Symbol/line
> references verified against main-repo HEAD `3056bee8`; re-verify before
> implementing (they drift) and cite by symbol name.

## Symptom (as reported)

Laptop resumed from sleep. For a few seconds the windows "danced" (jumped /
re-parked / re-revealed), and a **large dark Dock shield** appeared down the
right edge of the built-in display and stayed there.

## TL;DR

Three distinct effects, one wake event:

1. **Giant shield (primary complaint).** After the wake, the built-in display's
   *working area* was reported 328 px narrower than its physical frame — a
   right-edge inset that was **not present earlier in the same session**. The
   Dock Shield does not choose its own size; it fills exactly the reserved band,
   so a bogus 328 px reservation produces a 329 px-wide shield. The reservation
   is large but **not large enough** to trip the existing plausibility guard
   (`maxPlausibleInset = frame.width * 0.33 ≈ 570` px on a 1728-wide display),
   so it was accepted and — because side insets are cached as a "sticky" Dock
   property — it stuck.
2. **Dancing windows.** Display topology oscillated **1 → 2 → 1 → 2 displays**
   inside a ~6-second window, and the built-in display's frame momentarily
   misreported as **2056×1329** instead of the settled **1728×1117**. Each
   topology change forces a full rescan + re-park, so the windows visibly
   shuffled while the configuration settled.
3. **Relayout storm (invisible, but expensive).** 11 real `axWindowCreated`
   refresh *requests* produced **536,670** refresh *executions*. The
   self-arming follow-up path re-enqueues without going through the request
   counter, so this is a runaway follow-up loop, not 536k genuine requests.
   Peak memory during the sequence was ~589 MB.

Findings 1–3 are independent bugs that happened to fire together on one wake.
The shield is the user-visible one; #2 explains the dancing; #3 is a latent
perf/stability hazard the wake churn exposed.

---

## Evidence (inlined; self-contained)

Topology: built-in **display 1**, `frame = (0,0,1728,1117)`, `isMain`, notched;
external **display 2** `HP Z27k G3`, `frame = (-134,1117,1920,1080)`. Four
managed windows, all on workspace `5680D00C-…` (display 1): Ghostty
(`82494:56045`), two Helium windows (`16913:42801`, `16913:50794`), Telegram
(`37872:47208`).

### The working area shrank *after* wake, and the shield tracked it exactly

Two runtime-state snapshots captured close together near the end of the session
show display 1's working area flipping, with the shield appearing only in the
second:

```
# healthy snapshot — full working width, no shield
displayId: 1  frame=(0,0,1728,1117)  visibleFrame=(0,0,1728,1084)
-- Dock Edge Shield --
no-shields

# anomalous snapshot — 328px right inset, shield present
displayId: 1  frame=(0,0,1728,1117)  visibleFrame=(0,0,1400,1084)
-- Dock Edge Shield --
monitor=1 edge=right frame=(1399,7 329x1045) visible=true level=19
```

The full-working-width reading (`visibleFrame.width = 1728`) also appears at the
start of the session — so a 328 px right reservation is **not** this machine's
steady state; it materialised across the wake.

The shield frame is fully reconciled with the reported working area:

- `rightInset = frame.maxX − visibleFrame.maxX = 1728 − 1400 = 328`
- shield width `= rightInset + parkCover = 328 + 1 = 329` ✓
- shield x `= visibleFrame.maxX − parkCover = 1400 − 1 = 1399` ✓
- shield y `7`, height `1045` — the working-area band inset by the top (notch)
  and bottom outer gaps.

The parked windows corroborate the same 1400 working edge: the two `hidden:right`
windows sit at `liveAXFrame = {{1399,7},{…}}` — i.e. parked at
`visibleFrame.maxX − 1`, exactly where the shield is drawn to mask them.

### Topology / resolution churn (the "dancing")

```
#391 06:49:02  topology_changed displays=2  plan=topology=1->2
#400 06:49:02  topology_changed displays=2  plan=topology=2->2
#463 06:49:04  topology_changed displays=1  plan=topology=2->1
#475 06:49:04  topology_changed displays=1  plan=topology=1->1
#512 06:49:08  topology_changed displays=2  plan=topology=1->2
#525 06:49:08  topology_changed displays=2  plan=topology=2->2
```

The built-in display's frame width was seen as **2056** (height **1329**) during
this window, versus the settled **1728×1117** — a transient scale/resolution
misreport while the configuration bounced.

### Relayout storm

```
fullRescan=6648  relayout=536672  immediateRelayout=102  windowRemoval=7
requestedByReason=[ …  axWindowCreated: 11,  monitorConfigurationChanged: 12,  … ]
executedByReason=[  …  axWindowCreated: 536670,  monitorConfigurationChanged: 6638,  … ]
```

11 requests → 536,670 executions for `axWindowCreated`; 12 → 6,638 for
`monitorConfigurationChanged`. Peak RSS ~589 MB.

### Observed side effect — workspace duplication (secondary; needs its own note)

In the final layout, window `16913:42801` is both a managed tiled/offscreen
window on workspace 4 (display 1) **and** still present as a stale column on
workspace 7 with external-display coordinates
(`cur=56,1124,1523,1045`, y in display 2's band, while `live=1399,7,740,1045` is
on display 1). This looks like a disconnected-cache re-association during the
`2 → 1` collapse. Flagged only; not root-caused here.

---

## Root cause — source-backed

### Finding 1 — the plausibility guard is too loose to reject a 328 px wake artifact

`Monitor.current()` does not pass `NSScreen.visibleFrame` through untouched — it
routes it through `DockReservation.stableVisibleFrame(frame:visibleFrame:displayId:)`
(`Sources/Nehir/Core/Monitor/Monitor.swift:36`). That helper deliberately treats
a side-Dock inset as a **sticky, learned property** of the display so a fixed
Dock's reservation survives transient suppression (drop-down terminals, etc.).

It already tries to reject bogus insets that appear during display
reconfiguration:

```
let isSideOrientation = effectiveOrientation == "left" || effectiveOrientation == "right"
let dockAxisSize = isSideOrientation ? frame.width : frame.height
let maxPlausibleInset = dockAxisSize * 0.33
```
(`Monitor.swift:298–300`, and the reject-if-exceeded at `:323–326`.)

For the built-in display the axis is `frame.width = 1728`, so the ceiling is
`0.33 × 1728 ≈ 570 px`. The wake artifact was **328 px** — comfortably under the
ceiling — so it passed the guard, was applied against the stable physical edge
(`:354–355`, right case), and (being a side inset that AX could confirm as
on-this-display) was learned into `stickyInset[displayId]` (`:304–314`). Once
learned, it is intentionally re-applied on every subsequent `Monitor.current()`
regardless of the live reservation (the whole point of the sticky design), which
is why the shield persisted instead of self-healing.

The in-code comment at `:294–297` names exactly this failure mode ("during
display (re)configuration the frame/visibleFrame can be momentarily inconsistent
and yield a huge bogus inset … would … produce a giant shield"). The guard is
correct in intent; the threshold is simply too permissive for the mid-wake case
here, where the inconsistency was 328 px (≈19% of 1728), not a >33% blow-up. The
`TODO` at `:301–302` already flags that the side-inset ceiling wants to be
tighter than the cross-orientation 0.33 cap.

### Finding 1b — the shield faithfully mirrors the (bad) working area; it is not itself at fault

`DockEdgeShieldManager.shieldGeometry(for:)`
(`Sources/Nehir/UI/DockEdgeShield/DockEdgeShieldManager.swift:367`) derives the
band purely from the monitor geometry it is handed:

```
let rightInset = monitor.frame.maxX - monitor.visibleFrame.maxX      // :385
…
if rightInset > 0.5 {
    let column = CGRect(x: monitor.visibleFrame.maxX - parkCover,     // :399
                        y: bandY, width: rightInset + parkCover, …)   // :401
```

So the shield has no independent size of its own — it is `rightInset + 1` wide by
construction. Any fix belongs upstream in the working-area computation (Finding
1), not in the shield. (The shield's `update(monitors:)` is idempotent and
self-heals once the geometry changes — `:245–249` — so correcting `visibleFrame`
is sufficient to make the shield shrink/disappear.)

### Finding 2 — every topology bounce forces a full rescan; the wake bounced repeatedly

`monitorConfigurationChanged` executed **6,638** full rescans (≈ one per
topology-changed event amplified across the settle). This is expected per-event
behaviour; the pathology is the **number of events** — six `topology_changed`
transitions in ~6 s plus a spurious 2056×1329 frame reading. During each rescan
windows are re-parked/re-revealed, which is the visible "dancing". This is a
churn-debouncing gap, not a logic error in any single rescan.

### Finding 3 — follow-up refreshes re-arm without incrementing the request counter

Refresh *requests* are counted only at the public entrypoints via
`recordRefreshRequest(_:affectedWorkspaceIds:)`
(`Sources/Nehir/Core/Controller/LayoutRefreshController.swift:2177`). Refresh
*executions* are counted once each in `recordRefreshExecution(_:reason:)`
(`:2163`, called from the relayout path at `:956`).

The follow-up path does **not** go through `recordRefreshRequest`: on completion,
`finishRefresh(_:didComplete:)` re-enqueues `completedRefresh.followUpRefresh`
directly via `enqueueRefresh(...)` (`:2149–2157`). So a refresh whose follow-up
resolves to another same-reason refresh spins `executedByReason` upward while
`requestedByReason` stays flat — precisely the 11-requests / 536,670-executions
signature observed for `axWindowCreated`. The runaway is a self-perpetuating
follow-up under the wake churn, and it accounts for the ~589 MB peak.

---

## Confirmed vs. to-confirm

**Confirmed from source + inlined evidence:**
- Shield width == `rightInset + 1`; the shield mirrors `visibleFrame`, it does
  not choose its size (`DockEdgeShieldManager.swift:385,399–402`).
- `visibleFrame` is filtered through `DockReservation.stableVisibleFrame`, which
  learns side insets as sticky and rejects only insets above `0.33 × axis`
  (`Monitor.swift:36,298–326`); 328 < 570 ⇒ accepted.
- The 328 px reservation is a post-wake development (full-width `visibleFrame`
  recorded earlier in the same session).
- `finishRefresh` re-enqueues follow-ups outside `recordRefreshRequest`
  (`LayoutRefreshController.swift:2149–2157` vs `:2177`), explaining the
  request/execution divergence.

**Still to confirm before a plan:**
- The exact moment the 328 px inset was learned: whether it was computed while
  the frame read 2056×1329 (cap then `≈678`) or 1728×1117 (cap `≈570`). Either
  way it clears the current cap, but this determines whether a tighter ceiling
  alone is enough or whether the learn step must also gate on topology-settling.
- What the machine's *real* Dock configuration is (orientation + genuine
  reservation), so a tighter side-inset ceiling doesn't clip a legitimate large
  side Dock. The `TODO` at `Monitor.swift:301–302` is the open design question.
- The self-arming condition of the `axWindowCreated` follow-up loop — which
  producer keeps setting `followUpRefresh` to another `axWindowCreated` refresh
  during topology churn. Needs a targeted trace of `enqueueRefresh` origins.
- Whether the workspace-7 duplication of `16913:42801` is caused by the same
  wake collapse or is a pre-existing disconnected-cache bug (separate discovery).

## Where a fix would live (for the plan stage — not prescribed here)

- Working-area stability: `DockReservation.stableVisibleFrame` /
  `maxPlausibleInset` (`Monitor.swift:298–326`) — tighten the side-inset ceiling
  and/or refuse to *learn* a new sticky inset while display topology is unsettled.
- Wake churn debounce: the topology/`monitorConfigurationChanged` rescan
  scheduling in `LayoutRefreshController`.
- Follow-up loop: `finishRefresh` follow-up re-enqueue
  (`LayoutRefreshController.swift:2149–2157`) — bound or de-duplicate self-arming
  follow-ups.
