# Stale live AX frame persists on a stably-hidden scrolled-off column — Discovery

Discovery (2026-06-16). A tiled window belonging to a far-offscreen column of a
Niri horizontal-scrolling workspace keeps an **on-screen live AX frame** long after
the layout has marked it hidden and parked. The window is "wrong-parked": its layout
`target`/`cur` is the offscreen park slot, but its **`live` AX frame never advanced** off
the last on-screen coordinate, so the system believes it parked (`observedVisible=false`)
while the real window is still sitting at an on-screen x. The stale frame only gets
corrected when the user scrolls that window's workspace back until the column physically
re-enters the viewport "apply band" and transitions back to shown.

All evidence below is inlined from the runtime trace that exposed this. Trace logs are
machine-local and ephemeral; this document reproduces the concrete frames, viewStart
values, timestamps, tokens, and column geometry needed to follow the reasoning with no
access to any captured log. Code citations (`file:line`) were current as of commit
`8dd8f39` and will drift — re-verify before implementing.

This is a **sharper characterization of a failure mode already flagged** in
`docs/window-parking-and-offscreen-clamp.md` (§ "Iteration finding: live AX evidence suggests one
failure mode is stale cached / last-applied state … `hidePlan.staleCachedAlreadyHidden`
… re-applies the parking move when live AX disagrees"). That doc identified the
per-window drift reconciliation and wired it into the hide path. This discovery pins
**why it still misses**: the reconciliation runs only on a hide *transition*, so a
window that is already stably hidden when its live frame drifts is never re-checked.
See [Relationship to `window-parking-and-offscreen-clamp.md`](#relationship-to-window-parking-and-offscreen-clampmd).

---

## TL;DR

- **Symptom.** One Helium window — `WindowToken(pid: 33418, windowId: 7194)`,
  `bundleId=net.imput.helium`, in workspace `B0D042E7-…826` on the built-in display
  (display 1, frame `(0,0,2056,1329)`) — sat at column **c2** of a 12-column horizontal
  layout. After being scrolled offscreen it should have been parked at the left hide
  slot `x=-1006`, but its live AX frame stayed at **`live=986`** (fully on-screen:
  `x∈[986,1992]`, well inside the `0..2056` display) for the entire capture.
- **How long it stayed wrong.** At capture start (`08:08:02Z`) it was already
  `live=986` with `lastApplied=nil`. Through the whole recorded scroll it stayed pinned
  at `986` while the viewport slid from `currentViewStart=9496.9` (`08:08:08Z`) all the
  way down to `currentViewStart=3040.7` (`08:08:10Z`) — i.e. the viewport was hovering
  over columns 11→10→9→8 on the far right while c2 was visually still drawn at `x=986`.
- **The fix by scrolling its workspace.** The moment the user scrolled left enough that
  c2 re-entered the viewport apply band, the live frame refreshed. The boundary is
  exact: c2 spans workspace-x `[2028, 3034]`; with `preParkMargin=16`
  (`Sources/Nehir/Core/Layout/Niri/ViewportState+Geometry.swift:4`) it transitions
  shown/hidden at `viewStart = 3034 − 16 = 3018`. The last stale sample is
  `viewStart=3040.7` (`live=986`, still hidden); the first refreshed sample is
  `viewStart=2563.6` (`live=-523`, now shown). The data straddles `3018` on the nose.
- **Root cause.** Hidden columns emit a `.hide` visibility change **only on the
  transition** into being hidden (`NiriLayoutHandler.swift:910-916`), and the per-window
  drift reconciliation (`resolveHideOperation`, including the
  `hidePlan.staleCachedAlreadyHidden` re-apply guard at
  `LayoutRefreshController.swift:2258-2289`) is **only reached** for windows that appear
  in `diff.visibilityChanges` (`LayoutRefreshController.swift:3269-3273` → the loop at
  `:3339`). A window that is *already* hidden when its live frame drifts is stably
  hidden — it produces no `.hide` event on subsequent layout passes — so the
  reconciliation never runs for it again. Nothing rewrites its park slot until it
  transitions back to shown.
- **Not a systemic park failure.** Every sibling column was parked correctly throughout:
  `c0/c1/c3/c4/c5/c6/c7` all show `live=-1005` (the 1pt-reveal park value) the whole
  time, and the other Helium window `1692` at c3 was correctly parked `live=-1005` from
  start to end. Only `7194` had drifted. That asymmetry is the fingerprint of a missing
  *re-check* for stably-hidden windows, not a broken park computation.
- **Fix direction.** Reconcile stably-hidden windows' live AX frames against their park
  origins on a cadence (a low-frequency sweep, or folded into existing layout ticks),
  reusing the exact `hidePlan.staleCachedAlreadyHidden` re-apply logic that already
  exists for transitions. See [Recommendations](#recommendations).

---

## Topology and initial state

Workspace `B0D042E7-39C0-4D40-86F2-8CFDCFF1B826`, active on display 1 (Built-in Retina,
`frame=(0.0,0.0,2056.0,1329.0)`, `visibleFrame=(0.0,0.0,2056.0,1290.0)`). A second
monitor (display 2, DELL) holds a different, unrelated workspace. 12-column horizontal
Niri layout; columns are `1006pt` wide. Column origins (workspace-x): c0=0, c1=1014,
**c2=2028**, c3=3042, c4=4056, c5=5070, c6=6084, c7=7098, c8=8112, c9=9126, c10=10140,
c11=11154.

The two Helium windows of interest:

```
WindowToken(pid: 33418, windowId: 1692)  c3   bundleId=net.imput.helium
WindowToken(pid: 33418, windowId: 7194)  c2   bundleId=net.imput.helium   ← the stray one
```

### Runtime state at start (`08:08:02Z`) — the contradiction is already present

For `windowId=7194` the layout record is self-contradictory:

```
w7194{cur=-1006,0,1006,1280, target=-1006,0,1006,1280, live=986,0,1006,1280,
     last=nil, replacement=nil, observed=nil, hidden:left}
```

- `target` / `cur` (what the layout *thinks* the frame is) = **`(-1006, 0)`** — correctly
  parked offscreen-left.
- `live` (the actual AX frame the runtime last saw) = **`(986, 0)`** — physically
  on-screen. Display 1 spans `x=0..2056`; `986..1992` is fully visible.
- `observedVisible=false`, yet the coordinate is an on-screen one.
- AX state line confirms it with no apply ever recorded:
  `windowId=7194 lastApplied=nil pending=nil failure=nil … forceApply=false … inactiveWorkspace=false`.

The start-state managed-window dump agrees:
`windowId=7194 … liveAXFrame={{986.0, 0.0}, {1006.0, 1280.0}} … hidden=layoutTransient(left)`.

Where did `986` come from? It is the column's last *on-screen* x-origin from a prior
viewport position: `986 ≈ 2028 (c2 workspace-x) − viewStart`, i.e. from when `viewStart`
was ≈`1042` and c2 was visible at screen `x=986`. When the viewport later slid right and
c2 scrolled off-left, the park write to `-1006` either failed WindowServer verification
(offscreen clamp — see `window-parking-and-offscreen-clamp.md`) or was never issued, leaving `live`
frozen at that last-shown `986`.

The sibling Helium window and all other far-offscreen columns are parked correctly at
this same moment, proving the park computation itself is fine:

```
c0 w3270{…live=-1005,…hidden:left}   c1 w8240{…live=-1005,…hidden:left}
c3 w1692{…live=-1005,…hidden:left}   c4 w7820{…live=-1005,…hidden:left}
c5 w7656{…live=-1005,…hidden:left}   c6 w5165{…live=-1005,…hidden:left}
c7 w8044{…live=-1005,…hidden:left}
```

Only **c2 / w7194** has drifted to `live=986`. That single-window asymmetry is the key
evidence that this is a *re-check gap*, not a park bug.

---

## The drift is not corrected during the scroll

Across the recorded trackpad scroll, the viewport's `currentViewStart` moved monotonically
right→left through the far columns while c2 stayed far offscreen. At every sample, c2's
`live` is still `986`:

| time (Z) | reason | currentViewStart | w7194 `live` | c2 vs viewport |
|----------|--------|------------------|--------------|----------------|
| 08:08:08 | gesture_update | 9496.9 | **986** | c2 far off-left, hidden |
| 08:08:08 | gesture_update | 9476.5 | **986** | hidden |
| 08:08:09 | gesture_update | 8497.0 | **986** | hidden |
| 08:08:09 | gesture_update | 7474.7 | **986** | hidden |
| 08:08:09 | gesture_end → animating | 7373.8 → target 6583.0 | **986** | hidden |
| 08:08:10 | gesture_update | 6426.9 | **986** | hidden |
| 08:08:10 | gesture_end → animating | 6311.5 → target 5062.0 | **986** | hidden |
| 08:08:10 | gesture_update | 4870.7 | **986** | hidden |
| 08:08:10 | gesture_end → animating | 4548.4 → target 3541.0 | **986** | hidden |
| 08:08:10 | gesture_update | 3370.5 | **986** | hidden |
| 08:08:10 | ax_focus_confirm_request_relayout | **3040.7** | **986** | hidden (≥3018) |

c2 spans workspace-x `[2028, 3034]`. With `preParkMargin=16`
(`ViewportState+Geometry.swift:4`) the column is *intersecting* (shown) only while
`containerRect.maxX (3034) > viewStart + 16`, i.e. while **`viewStart < 3018`**. Every
row above has `viewStart ≥ 3018`, so c2 is stably hidden the entire time — and `live`
never moves off `986`.

---

## The fix — scrolling the workspace until c2 re-enters the apply band

The very next viewport sample after the table above is where the user's continued
leftward scroll drags c2 back across the `viewStart < 3018` boundary:

```
08:08:10  reason=touch_scroll_gesture_armed  currentViewStart=2563.6  w7194 live=-523   ← corrected
08:08:11  reason=touch_scroll_gesture_committed currentViewStart=2536.3 live=-499
…
08:08:11  reason=touch_scroll_gesture_update  currentViewStart=925.6   live=1112   (c2 now on-screen, tracking)
```

At `viewStart=2563.6`, c2 `[2028,3034]` ∩ viewport `[2563.6, 4619.6]` = `[2563.6, 3034]`
— a partial intersection, so c2 transitions `.show`. The layout now writes a real frame
for it, and `live` jumps from the stale `986` to `-523` (the genuine transitional
position, ≈ `2028 − 2563.6` in screen space) and thereafter tracks the scroll truthfully
(`-523 → -499 → 1112` as it crosses fully on-screen, then `2055` once it hides on the
far side).

By the **runtime state at end** (`08:08:17Z`) both Helium windows are settled correctly:

```
windowId=7194 … liveAXFrame={{-1005.0, 0.0}, {1006.0, 1280.0}} … hidden=layoutTransient(left)
windowId=1692 … liveAXFrame={{-1005.0, 0.0}, {1006.0, 1280.0}} … hidden=layoutTransient(left)
```

So the user's reported "fixed by scrolling the workspace it belongs" is exactly this:
scrolling until the column re-enters the apply band, which forces the one transition
(`.show`) that re-applies a real frame and clears the drift.

---

## Mechanism — why stably-hidden drift is never re-checked

### 1. Hidden windows emit `.hide` only on the transition

`NiriLayoutHandler.swift` (the layout-diff builder), around the visibility decision:

```swift
// NiriLayoutHandler.swift:910-916
let previousOffscreenSide = window.hiddenState?.offscreenSide
if let side = hiddenHandles[token] {
    if previousOffscreenSide != side {
        diff.visibilityChanges.append(.hide(token, side: side))   // transition only
    }
    continue                                                       // hidden → never a frameChange
}
```

A window already in `hiddenHandles` (offscreen) with the same side as last pass produces
**no** `.hide` event and, via `continue`, **no** entry in `diff.frameChanges`. Once c2
was stably `hidden:left`, subsequent scrolls generated neither a frame change nor a
re-hide for it.

### 2. The drift reconciliation is only reached for `.hide` (and `.show`) transitions

The applier consumes visibility changes into `hiddenEntries`:

```swift
// LayoutRefreshController.swift:3269-3273
case let .hide(token, side):
    hiddenTokens.insert(token)
    guard let entry = resolveEntry(for: token) else { continue }
    guard entry.layoutReason != .nativeFullscreen else { continue }
    hiddenEntries.append((entry, side))
```

…then runs each through the hide resolver:

```swift
// LayoutRefreshController.swift:3339-3341
for (entry, side) in hiddenEntries {
    switch refreshController.resolveHideOperation(
        for: entry, monitor: monitor, side: side, reason: .layoutTransient
    ) { … }
```

Because `hiddenEntries` is populated **exclusively** from `diff.visibilityChanges`
`.hide` events (the loop at `:3266-3274`), and those events are transition-only (§1), a
stably-hidden window never reaches `resolveHideOperation` on a later pass.

### 3. `resolveHideOperation` already contains the correct per-window fix — it just isn't called

```swift
// LayoutRefreshController.swift:2225-2289 (abridged)
fileprivate func resolveHideOperation(… ) -> HideOperationResolution {
    guard let frame = fastFrame(for: entry.token, axRef: entry.axRef)           // :2233
        ?? controller.axManager.lastAppliedFrame(for: entry.windowId)
        ?? (try? AXWindowService.frame(entry.axRef))
    else { return .unavailable }
    …
    guard let origin = liveFrameHideOrigin(for: frame, …) else { return .unavailable }
    let moveEpsilon: CGFloat = 0.01                                             // :2258
    if abs(frame.origin.x - origin.x) < moveEpsilon,
       abs(frame.origin.y - origin.y) < moveEpsilon
    {
        if reason == .layoutTransient,
           let liveFrame = try? AXWindowService.frame(entry.axRef)              // :2262 re-read live AX
        {
            let liveDx = abs(liveFrame.origin.x - origin.x)
            let liveDy = abs(liveFrame.origin.y - origin.y)
            if liveDx > moveEpsilon || liveDy > moveEpsilon {
                controller.axManager.recordFrameApplyTrace("hidePlan.staleCachedAlreadyHidden …")  // :2268
                return .movable( WindowPositionPlan(entry: entry, origin: origin, …), hiddenState: hiddenState) // re-apply
            }
        }
        return .alreadyHidden(hiddenState: hiddenState)
    }
    return .movable( WindowPositionPlan(entry: entry, origin: origin, …), …)
}
```

This is precisely the medicine: when the cached/last-applied frame already matches the
park origin, it re-reads the **live** AX frame and, if it has drifted, returns
`.movable` to re-issue the park move. Had this run for `7194`, it would have seen
`live=986` vs `origin=-1006` (`liveDx=1992 ≫ epsilon`) and re-applied immediately.

It did not run, because `7194` was stably hidden and therefore absent from
`hiddenEntries`. There is **no background/cadenced path** that re-invokes this check for
windows that are not transitioning. The only events that can lift a stably-hidden window
back into reconciliation are:

- a `.show` transition (column re-enters the apply band — what we observed at
  `viewStart≈2563`), or
- a side flip (`previousOffscreenSide != side`, e.g. scrolling past and out the other
  side), or
- an unrelated force-apply path (`forceApplyNextFrame`) reaching the window for another
  reason (workspace switch, restore, focus reveal, etc.).

Until one of those fires, the drifted `live` frame is permanent.

---

## Relationship to `window-parking-and-offscreen-clamp.md`

`docs/window-parking-and-offscreen-clamp.md` documents the broader, still-open problem that macOS clamps
offscreen positions so full-size external windows cannot be truly hidden, and records
(among its iteration findings) the exact drift failure mode this discovery is about:

> "live AX evidence suggests one failure mode is stale cached / last-applied state. Nehir
> can classify a window as already parked because its cached frame is near the 1pt target,
> while live AX has drifted/clamped to a larger visible strip … The experiment logs
> `hidePlan.staleCachedAlreadyHidden` and re-applies the parking move when live AX
> disagrees with the cached already-hidden decision."

That work added the `:2262` live-AX re-read inside `resolveHideOperation`. What it did
**not** add is a way to *reach* that re-read for a window that is already stably hidden
when the drift occurs. This discovery supplies the missing half: the reconciliation is
transition-gated (`NiriLayoutHandler.swift:910-916` + `LayoutRefreshController.swift:3269`),
so the very windows most likely to have drifted-and-stuck (long-offscreen far columns)
are the ones least likely to be re-checked.

Note also the clamp angle: the park target here was `(-1006, 0)` for a 1006-wide window,
i.e. the kind of fully-offscreen coordinate WindowServer is known to clamp
(`window-parking-and-offscreen-clamp.md` §1). A clamped/failed park write is a plausible *origin* of the
`live=986` drift; this discovery does not depend on which origin caused the drift, only
on the fact that once it exists, nothing corrects it for stably-hidden windows.

---

## Confidence and open questions before implementing

The mechanism above (transition-gated reconciliation misses stably-hidden drift) is
**proven** by the trace. Whether a fix built on it *resolves the user-visible bug* is
**not yet proven** — three questions separate "buildable" from "trustworthy".

### De-risked: the park target likely lands

The main worry for any re-apply fix — "re-writing the park slot `-1006` just clamps back
to nothing" — is largely answered by the trace itself. All **seven sibling columns** are
parked at `live=-1005` the entire capture, including the same-app Helium window `1692`
at c3. So the park target demonstrably resolves to the 1pt-reveal value on this setup,
and re-parking `7194` toward `-1006` would very likely settle at `-1005` like its
siblings rather than bounce. That makes the cadenced-reconciliation option below safe to
build and *probably* effective.

### Not yet proven

1. **The drift origin is unknown.** `7194` shows `lastApplied=nil` at capture start — no
   apply was ever recorded for it. "Clamp failure or write skipped" is asserted, not
   proven. This decides whether reconciliation treats *root cause* or *symptom*:
   - If the cause is **one-shot** (a restore race, a one-time clamp at the moment the
     column scrolled off), reconciliation re-applies once and the window stays parked —
     the fix is complete.
   - If the cause is **recurring** (the app self-moves, or a layout pass keeps
     re-deriving a frame the dedup then suppresses), reconciliation enters a fight /
     whack-a-mole loop and only patches the symptom — the real fix would then live in the
     dedup or the layout re-derivation, not in reconciliation.
   Reconciliation is defensive either way, but the origin determines which layer is the
   true fix.
2. **There is no on-demand reproduction.** The evidence is a single snapshot taken
   *mid-drift*. The `986` state cannot be reproduced at will, so a fix cannot be
   validated to prevent or predict correction except by waiting for the bug to recur in
   the wild. This is the single biggest blocker to "implementing the fix" vs
   "implementing a hypothesis."
3. **Off-cycle invocation safety is unverified.** `resolveHideOperation` reads
   `fastFrame` — a layout-pass cache — first (`:2233`). Calling it from a timer rather
   than a layout diff needs a check that the fallback chain (`lastAppliedFrame` → live
   AX) and the surrounding plumbing (`applyPositionPlans`, `cancelPendingFrameJobs`,
   `suppressFrameWrites`) behave correctly outside a diff. Feasible — `:2262` re-reads
   live AX directly anyway — but not yet confirmed.

### Recommended next step before fixing — capture the origin

One focused capture closes gaps (1) and (2) together: start a trace, scroll a *fresh*
interior column offscreen, and watch that window's apply trace from the moment it
transitions `.hide`. The three distinguishable outcomes each point at a different fix:

| Apply trace at the `.hide` transition | Implied origin | Correct fix layer |
|---|---|---|
| `enqueue → confirmed`, then drift later | app self-move / restore race | reconciliation (gap (1), this doc) |
| `enqueue → failed` / `verificationMismatch` (clamped) | WindowServer clamp rejects park | reconciliation re-applies, but park itself still the open `window-parking-and-offscreen-clamp.md` problem |
| **no `enqueue` at all** | dedup/skip suppresses the write | the dedup/`lastApplied` path, not reconciliation |

That single capture both names the root cause and yields the repro needed to validate
any fix against. The characterization in this doc is the brief for that capture.

---

## Recommendations

All options reuse the existing, correct per-window logic in `resolveHideOperation`
(`:2258-2289`); the gap is purely *reachability* for stably-hidden windows. Pick by cost
tolerance, not by re-deriving the reconciliation. Read in light of the open questions
above: option (1) is *defensive* (corrects drift regardless of origin) but should not be
claimed as the root-cause fix until the [origin capture](#recommended-next-step-before-fixing--capture-the-origin)
confirms the cause is one-shot rather than recurring.

1. **(Preferred) Cadenced background reconciliation of hidden windows.** On a low-frequency
   timer (or folded into an existing `LayoutRefreshController` tick, throttled), sweep the
   set of currently-hidden windows and call `resolveHideOperation` for each, re-applying
   when `hidePlan.staleCachedAlreadyHidden` fires. This directly closes the stably-hidden
   gap without touching the hot scroll path, and self-heals drift regardless of how it
   arose (clamp failure, app self-move, restore race). Cost: one `AXWindowService.frame`
   read per hidden window per cadence tick — cheap because hidden sets are small and the
   cadence can be coarse (sub-second is plenty vs. a bug that otherwise persists
   indefinitely).
2. **(Cheaper, partial) Reconcile on viewport settle.** When a scroll gesture commits /
   snaps (`touch_scroll_gesture_committed`, animation `animating=false`), run the same
   sweep for the columns that were just *left behind* offscreen in that gesture. Tighter
   scope than (1) but only catches drift introduced by a scroll; it would still miss drift
   that arose while idle (e.g. an app repositioning itself, or a clamp that only lands
   after the settle).
3. **(Breadth) Unconditional re-hide pass on every layout diff.** Include all currently-
   hidden windows in the `hiddenEntries` loop each pass, not only those with a `.hide`
   transition. Simplest to implement but adds a per-pass AX read for every hidden window
   on every layout tick — likely overkill vs. the cadenced (1).

Any fix must be validated against the `window-parking-and-offscreen-clamp.md` pitfalls: do **not** claim
the park itself is "fixed" from geometry or unit tests alone — WindowServer clamp behavior
must be confirmed in a real run. The reconciliation here only guarantees that the live
frame is *re-driven* toward the park slot; whether WindowServer finally accepts it is the
separate, still-open problem documented there. A unit test can cover the invariant "a
stably-hidden window whose live frame drifted gets re-scheduled for a park write"; it
cannot prove the external window renders hidden.

---

## Reproduction checklist (self-contained)

- Topology: display 1 `(0,0,2056,1329)` + display 2; active workspace `B0D042E7-…826` on
  display 1, 12-column horizontal Niri layout, 1006pt columns.
- Put a window in an interior column (here c2, workspace-x `[2028,3034]`) and scroll the
  viewport far to the right so the column is fully offscreen-left (`viewStart > 3034`).
- Induce drift on that column's live AX frame (e.g. a park write that WindowServer clamps,
  or the app repositioning). Concretely observed: `target=(-1006,0)` but `live=(986,0)`,
  `lastApplied=nil`, `hidden=layoutTransient(left)`, `observedVisible=false`.
- Hold the viewport far right and observe: `live` stays at the stale on-screen value
  across many seconds of further scrolling (observed `viewStart 9496.9 → 3040.7`, `live`
  pinned `986`).
- Scroll left until the column re-enters the apply band (`viewStart < 3034 − 16 = 3018`,
  `preParkMargin=16`). `live` refreshes to the real transitional frame (observed at
  `viewStart=2563.6`, `live=-523`) and thereafter tracks.
- Confirm: at next settle both the drifted window and its siblings report the same park
  `liveAXFrame` (observed end state both Helium windows `(-1005,0,1006,1280)`).
