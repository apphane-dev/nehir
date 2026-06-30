# Focus-confirm's reveal is superseded by the relayout it triggers — Plan

**Status:** in progress — Phase 1 ("Keep `activeColumnIndex` synced at
focus-confirm time") landed on `main` on 2026-07-01 in commit `26b4f8a3` ("Sync
activeColumnIndex during focus confirmation"). The fix resolves and stores the
newly-activated node's real column right after `activateNode`, unconditionally
on both `preserveActiveViewport` branches, in
`Sources/Nehir/Core/Controller/AXEventHandler.swift` (the block immediately
after the `ax_focus_confirm_after_activate` trace record, ahead of the existing
`if !isFFM, !preserveActiveViewport, ...` reveal branch). This covers both
repros' shared root cause. The pre-existing
`focusConfirmationPreservesActiveViewportSpring` test in
`Tests/NehirTests/AXEventHandlerTests.swift` was updated — its old assertion
that `activeColumnIndex` stayed put under `preserveActiveViewport == true`
encoded the bug itself — and a new regression test,
`focusConfirmationSyncsActiveColumnIndexForClippedTarget`, was added covering
the repro-2 shape (see Phase 3 status below). **Phase 2** (narrowing
`preserveActiveViewport`'s settle-tail false positive, which is repro 1's
specific triggering bug) and the **remaining three** Phase-3 regression tests
are not yet implemented; this doc stays in `planned/` until those land.

## Verdict on the "D. Relayout viewport stability" catalogue

Checked against the three candidate items from the catalogue:

- **Item 7** ("Settled relayout recenters an already fully-visible unchanged
  selection") — **does not match**. In both repros below the selection's
  column genuinely changes (the newly focused window is not in the
  previously active column), so this is not a no-op/unchanged-selection
  case. Item 7's fix (`discovery/20260628-relayout-path-recenters-fully-visible-unchanged-selection.md`)
  explicitly preserves "genuine selection change" as a legitimate recenter
  trigger, so shipping it would **not** fix either repro here.
- **Item 8** ("Stale relayout patch overwrites a live gesture / newer state")
  — **does not match**, but is closely related and **already shipped**:
  verified against the current main source tree, `WorkspaceManager.applySessionPatch`
  (`Sources/Nehir/Core/Workspace/WorkspaceManager.swift:1753-1794`) already
  carries both the gesture-only guard (`:1764-1767`) and the
  `plannedSelectionRevision` stale-patch guard (`:1769-1783`) described in
  `discovery/20260618-stale-session-selection-revision-guard.md` — landed as
  commit `42ac731f` ("Prevent stale async session patches from overwriting
  newer selection (M6)"), which **is** an ancestor of current `main` (the
  identically-named branch tip `da25d160` is a stale, separately-rebased
  copy and is *not* the landed commit — checking branch ancestry against
  `da25d160` alone is misleading; `42ac731f` is the one that matters).
  Neither guard touches `viewportState.viewOffsetPixels` outside the
  gesture case, so it does not protect the offset/spring staleness seen
  below.
- **Item 9** ("Settings/config relayout reinterprets a parked/edge-snapped
  selection") — **does not match**. Neither repro involves an app-rule/
  workspace-config/monitor-settings/gap change.

This is a **fourth, previously undocumented** mechanism. It shares the same
downstream "mover" code as item 7 (`ensureSelectionVisible` →
`scrollToReveal` → `animateToOffset`) and the same unrecorded-intermediate-
mutation pattern as the "Residual attribution gap" noted in
`planned/20260625-unrecorded-viewport-offset-mutation-attribution.md`. Two
independent repros pin it down:

1. A click confirming focus while an unrelated prior spring is in its
   settle tail (`isAnimating == true` but already converged) — the
   focus-confirm's own reveal is skipped outright.
2. **A focus change with zero user input** (an app self-activation,
   `workspaceDidActivateApplication`) — the focus-confirm's own reveal
   *does* run and reports success, and the viewport **still** jumps via the
   relayout it triggers, landing at a different value than what the
   focus-confirm reveal computed.

Repro 2 shows the bug is broader than "the `isAnimating` gate skips reveal":
even a successful, policy-respecting `revealForFocusActivation` call gets
superseded by the unconditional follow-up relayout, because that relayout's
`ensureSelectionVisible` only knows `state.activeColumnIndex` — which
`revealForFocusActivation`/`scrollToReveal` never update — so it always
treats the new selection as needing its own (re)reveal, redundantly or
divergently.

---

## TL;DR

- **Symptom (repro 1, click).** Clicking a window in a column outside the
  currently active column, while a previous relayout's viewport spring is
  still technically "animating" (even though it has already visually
  reached its target), produces no movement at focus-confirmation time,
  then a visible viewport snap moments later when the requested relayout
  runs.
- **Symptom (repro 2, no user input).** A window in another app process
  self-activates (e.g. raising a previously backgrounded window — observed
  as `event=focus_lease_changed owner=native_app_switch
  reason=workspaceDidActivateApplication`, with **no preceding mouse or
  keyboard trace record at all**). The newly OS-focused window is in a
  clipped, non-active column. Focus-confirmation runs its reveal
  computation cleanly this time (no skip), reports success — and the
  viewport still visibly jumps moments later via the relayout the
  focus-confirm step unconditionally requests, landing at a value the
  reveal computation itself never produced.
- **Root cause (shared).** `state.activeColumnIndex` is never updated by
  the focus-activation reveal path (`revealForFocusActivation`/
  `scrollToReveal` only move the offset, never `activeColumnIndex`).
  `ax_focus_confirm_request_relayout` *always* triggers a follow-up
  relayout regardless of whether the focus-confirm reveal ran or what it
  did. That relayout's `resolveSelection` → `ensureSelectionVisible` always
  re-derives the real column for the (now up to date) `selectedNodeId`,
  finds the stale `activeColumnIndex` disagrees, and performs its own
  instant rebase + recenter — independent of, and potentially divergent
  from, whatever the focus-confirm reveal already did. Repro 1 additionally
  has a *more specific* triggering bug (below) that causes the
  focus-confirm reveal to be skipped outright rather than merely
  superseded.
- **Root cause (repro 1's specific trigger).** `AXEventHandler`'s `preserveActiveViewport` gate treats
  `ViewportOffset.isAnimating` (true for the entire lifetime of a `.spring`
  representation, including the cosmetic tail after `current == target`) the
  same as an actual in-flight gesture. When it's true, the focus-confirmation
  path skips computing the click target's real column and never calls
  `revealForFocusActivation` — the function added specifically to make
  focus-activation reveals fully-visible-aware and `revealPartial`-aware.
  `state.activeColumnIndex` is left stale. The relayout requested right
  after then resolves the real column via `ensureSelectionVisible`, which
  does an **instant, unanimated rebase** of `activeColumnIndex`/offset to the
  real column, immediately followed by a **spring recenter** via
  `scrollToReveal`'s default (closest-filling-or-center) snap — a visibly
  different, two-stage "snap" instead of the smooth, immediate,
  visibility-aware reveal the click should have produced.
- **Fix direction.** Narrow `preserveActiveViewport`'s animation check to
  exclude the settle tail, and/or keep `state.activeColumnIndex` synced to
  the activated node's real column at focus-confirm time so the relayout
  path has nothing stale left to rebase.

---

## Evidence — repro 1: click during a settling spring, full causal chain

Captured 2026-06-30 on a ten-column Niri workspace (`columns=10`) with
several `net.imput.helium` (Helium browser) windows tiled, after a trackpad
fling had just settled the active column at index 1
(`w6892`, column `c1`, `x=1004.0` width `670.8`, spanning `1004.0–1674.8`)
with `currentOffset=-684.6`, `currentViewStart=319.4`. The clicked window,
`WindowToken(pid: 22641, windowId: 3416)`, sits in column `c2`
(`x=1706.8` width `972.0`, spanning `1706.8–2678.8`) — only partially inside
the visible range at that viewport position (the display's visible width is
`2056.0`, so the visible span is roughly `319.4–2375.4`; `c2` is clipped
past `2375.4`).

### 1 — A prior relayout's spring is still "animating" when the click lands

Just before the click, an unrelated relayout (admitting/re-admitting Helium
tab windows) had set:

```text
reason=relayout.viewportOffsetChanged activeColumnIndex=1
currentOffset=-52.7 targetOffset=-684.6 gesture=false animating=true
```

A `gesture.skip reason=underCount activeTouches=1` record at the same
on-screen location confirms the interaction was a single-finger click, not a
trackpad gesture.

### 2 — Focus confirms the click, but `wasAnimating=true` so the viewport is "preserved"

```text
reason=ax_focus_confirm_before_activate token=WindowToken(pid: 22641, windowId: 3416)
isGesture=false wasAnimating=true preserveActiveViewport=true
activeColumnIndex=1 currentOffset=-684.6 targetOffset=-684.6
selectedNode=NodeId(uuid: DA42CCD3-…)
```

`currentOffset` already equals `targetOffset` (`-684.6`) — the spring has
visually finished — but it is still represented as `.spring`, so
`isAnimating` reads `true`. `activateNode` then runs and updates the
selection:

```text
reason=ax_focus_confirm_after_activate token=WindowToken(pid: 22641, windowId: 3416)
preserveActiveViewport=true activeColumnIndex=1 currentOffset=-684.6 targetOffset=-684.6
selectedNode=NodeId(uuid: 97A67311-…)
```

The layout snapshot embedded in this same record shows the new selection is
already in column `c2`, not `c1`:

```text
c1[x=1004.0,...]{w6892{...}}
c2[x=1706.8,...]{w3416:selected{...}}
```

i.e. `state.selectedNodeId` now points at `w3416` in `c2`, but
`state.activeColumnIndex` is still `1` (pointing at `c1`/`w6892`).

Because `preserveActiveViewport=true`, the reveal computation is skipped
outright:

```text
reason=ax_focus_confirm_reveal_skipped token=WindowToken(pid: 22641, windowId: 3416)
preserveActiveViewport=true activeColumnIndex=1 currentOffset=-684.6 targetOffset=-684.6
```

No `ax_focus_confirm_reveal_candidate` record exists for this click — that
record is only emitted on the branch that actually computes a `columnIndex`
and calls `revealForFocusActivation` (see source below), which never ran.

### 3 — The relayout the click requested rebases and recenters

```text
reason=ax_focus_confirm_request_relayout … activeColumnIndex=1 currentOffset=-684.6
reason=scroll_animation_start displayId=1 registered=true … activeColumnIndex=1 currentOffset=-684.6 targetOffset=-684.6
reason=scroll_animation_stop  displayId=1 … activeColumnIndex=1 currentOffset=-684.6 targetOffset=-684.6
```

The prior spring formally completes here (converts to `.static`). The
requested relayout then runs and produces:

```text
reason=relayout.viewportOffsetChanged activeColumnIndex=2
currentOffset=-1382.4 targetOffset=-534.0 currentViewStart=319.5 targetViewStart=1172.8
gesture=false animating=true selectedNode=NodeId(uuid: 97A67311-…)
lastViewportMutationCaller=Nehir/ViewportState+Animation.swift:98 animateToOffset(_:motion:config:scale:)
lastViewportMutationBeforeCurrentOffset=-1387.4 lastViewportMutationBeforeTargetOffset=-1387.4
lastViewportMutationBeforeKind=static lastViewportMutationBeforeActiveColumnIndex=2
```

`activeColumnIndex` is already `2` and the offset already `-1387.4` (as
`.static`) in the **"before"** snapshot of this single record — i.e. an
instant, unanimated rebase to the real column already happened, with no
record of its own surviving in the trace (single-slot audit collapse,
matching the "Residual attribution gap" already noted in
`planned/20260625-unrecorded-viewport-offset-mutation-attribution.md`).
Immediately after, `animateToOffset` springs from `-1387.4` to `-534.0`
(`scroll_animation_start` → `scroll_animation_stop`, settling at
`currentViewStart=1172.8`, which does fully contain `c2`'s `1706.8–2678.8`
span). The end state is correct; the motion that gets there — instant
rebase, then a large spring — is the "snap" reported.

---

## Evidence — repro 2: zero user input, app self-activation

Captured the same session, on the same ten-column workspace, several
minutes later. The viewport had been fully settled for ~5 seconds
(`reason=scroll_animation_stop … activeColumnIndex=1 currentOffset=-1337.2
targetOffset=-1337.2 currentViewStart=570.4 targetViewStart=570.4
gesture=false animating=false`, with `lastViewportMutation=tickAnimation.complete`
— i.e. the prior spring had finished on its own, not via any new input).

**No mouse or keyboard activity is recorded in this window.** The mouse
focus trace's first record after the settle is four seconds *after* the
jump (`tap.mouseMoved … loc=(1460.7,1214.4)` at the next timestamp second);
the AX notification trace only shows `AXFocusedWindowChanged pid=22641
window=nil` (the same Helium process posting its own internal focus
notifications). The only events in this window are:

```text
event=focus_lease_changed owner=native_app_switch reason=workspaceDidActivateApplication …
event=non_managed_focus_changed active=true …
event=focus_lease_changed owner=nil reason= … focus_lease=cleared
event=focus_lease_changed owner=native_app_switch reason=workspaceDidActivateApplication …
event=managed_focus_confirmed token=WindowToken(pid: 22641, windowId: 6537) …
```

i.e. macOS/the app itself (pid 22641, `net.imput.helium`) reactivated and
brought window `6537` to native focus — an app self-activation, not a
click, key press, or trackpad gesture.

`6537` lives in column `c0` (`x=0.0`, `cached=1875.6`, `preset=3`,
`manual=true` — a wide/maximized-style column), while the active column at
settle time was `c1` (`x=1907.6`, the previously selected `w6892`). The
focus-confirmation sequence:

```text
reason=ax_focus_confirm_before_activate token=WindowToken(pid: 22641, windowId: 6537)
  isGesture=false wasAnimating=false preserveActiveViewport=false
  activeColumnIndex=1 currentOffset=-1337.2 targetOffset=-1337.2
  selectedNode=NodeId(uuid: DA42CCD3-…)
reason=ax_focus_confirm_after_activate token=WindowToken(pid: 22641, windowId: 6537)
  preserveActiveViewport=false activeColumnIndex=1 currentOffset=-1337.2 targetOffset=-1337.2
  selectedNode=NodeId(uuid: FD06C1F1-…)   # now c0's w6537:selected
```

This time `preserveActiveViewport=false` (nothing was gesturing or
animating), so the reveal computation runs — unlike repro 1, it is **not**
skipped:

```text
reason=ax_focus_confirm_reveal_candidate token=WindowToken(pid: 22641, windowId: 6537)
  columnIndex=0 revealPartial=default visibility=clipped(Nehir.AxisHideEdge.minimum)
  viewStart=570.4 closest=-32.0:leftEdge closestFills=false
  center=-82.2:center centerFills=false snapCount=3
reason=ax_focus_confirm_reveal_result token=WindowToken(pid: 22641, windowId: 6537)
  columnIndex=0 isFFM=false didReveal=true
```

`didReveal=true` — `revealForFocusActivation`'s `.clipped` branch found
neither candidate "fills" the viewport, fell back to the center snap, and
called `state.animateToOffset(...)`. (The `currentOffset`/`targetOffset`
fields printed on this same trace line still show `-1337.2`/`-1337.2`
because `recordRuntimeViewportTrace` reads the **live, already-committed**
`workspaceManager` state, not the function's local `inout state` parameter
that `revealForFocusActivation` just mutated — that local state is only
written back via `applySessionPatch`, called a few lines later. This is a
trace-display artifact, not evidence the reveal had no effect.)

Immediately after, `ax_focus_confirm_request_relayout` fires and schedules
`LayoutRefreshController.requestRefresh(reason: .layoutCommand)`. The
resulting relayout record:

```text
reason=relayout.viewportOffsetChanged
  activeColumnIndex=1 currentOffset=-1346.5 targetOffset=-1989.8
  currentViewStart=567.7 targetViewStart=-82.2 gesture=false animating=true
  selectedNode=NodeId(uuid: FD06C1F1-…)
  lastViewportMutationCaller=Nehir/ViewportState+Animation.swift:98 animateToOffset(_:motion:config:scale:)
  lastViewportMutationBeforeCurrentOffset=-1337.2 lastViewportMutationBeforeTargetOffset=-1337.2
  lastViewportMutationBeforeKind=static lastViewportMutationBeforeActiveColumnIndex=1
```

Two things stand out:

- The **"before" snapshot is `activeColumnIndex=1`, `.static`,
  `-1337.2`/`-1337.2`** — i.e. from this relayout pass's point of view,
  nothing had moved yet and `activeColumnIndex` was still the stale,
  pre-focus-confirm value. Whatever `revealForFocusActivation` had set up
  moments earlier is not what this pass animates from.
- The actual jump (`-1337.2 → -1989.8`, `currentViewStart 570.4 → -82.2`,
  a 652.6pt move) is what the user sees. `targetViewStart=-82.2`
  numerically matches the **center** snap candidate's printed offset
  (`-82.2`) from the reveal-candidate computation above — so the
  *destination* coincides with what `revealForFocusActivation` had already
  computed for column `0`, but it is the **relayout's own**
  `ensureSelectionVisible`/`scrollToReveal` pass that performs the move,
  starting from the stale `activeColumnIndex=1` anchor rather than from
  wherever the focus-confirm reveal had already gotten to.

This confirms the mechanism is not specific to the `isAnimating`-skip case
in repro 1: even when `revealForFocusActivation` runs cleanly and reports
success, the unconditional follow-up relayout's `ensureSelectionVisible`
still re-derives and re-applies the reveal from a stale `activeColumnIndex`,
because nothing in the focus-confirm path ever updates it. The user-visible
result is a 652pt viewport jump, attributable only to an app's own internal
window-activation, with literally no trackpad, mouse, or keyboard event
anywhere in the capture window that could explain it.

---

## Source attribution

### Skip site: `preserveActiveViewport` conflates "mid-gesture" with "spring settle tail"

`Sources/Nehir/Core/Controller/AXEventHandler.swift:2438-2440`:

```swift
let preserveActiveViewport = state.viewOffsetPixels.isGesture
    || state.viewOffsetPixels.isAnimating
    || (wasAlreadyConfirmedFocus && source == .focusedWindowChanged)
```

`isAnimating` (`Sources/Nehir/Core/Layout/Niri/ViewportState.swift:111-120`)
is `true` for the entire lifetime of a `.spring` case, independent of
whether `current` has already converged to `target`:

```swift
var isAnimating: Bool {
    switch self {
    case .spring: return true
    case let .gesture(g): return g.animation != nil
    case .static: return false
    }
}
```

The `isAnimating` half of this check predates the partial-reveal feature
(present since the initial Nehir import); it was never revisited when
`revealForFocusActivation` was added.

When `preserveActiveViewport` is true, the entire reveal block —
`AXEventHandler.swift:2476-2530` — is skipped in favor of the bare
`ax_focus_confirm_reveal_skipped` branch (`:2531-2540`). That skipped block
is the only call site of:

`Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+ViewportCommands.swift:160`
— `revealForFocusActivation`, added by `dad2e63a` / `0602387d` ("Do not
recenter viewport on activation of fully visible windows") specifically so
that: a fully-visible target never moves the viewport; a parked target gets
the fixed default snap; and a **clipped** target — exactly this repro's
case — delegates to `scrollToReveal` where `revealPartial` policy applies.
None of that runs here.

### Catch-up site: `ensureSelectionVisible`'s instant rebase, then a hard recenter

`Sources/Nehir/Core/Layout/Niri/NiriNavigation.swift:173-246` —
`ensureSelectionVisible`. It looks up the *actual* container of the
selected node (`:188-192`) and, if it differs from
`state.activeColumnIndex`, performs an instant, non-animated rebase:

```swift
// NiriNavigation.swift:220-223
state.withRecordedViewportMutation(reason: "moveSelectionToContainer.rebaseActiveColumn") { state in
    state.viewOffsetPixels.offset(delta: Double(offsetDelta))
    state.activeColumnIndex = targetIdx
}
```

then calls `scrollToReveal` (`NiriLayoutEngine+ViewportCommands.swift:70-150`),
whose `.clipped` branch with `revealPartial == .default` (the common case)
picks `defaultSnap()` — closest snap that fills the viewport, else the
center snap (`:90-98`) — and animates to it with a spring
(`state.animateToOffset(...)`, `:148`). This is the generic,
layout-driven reveal policy meant for relayout-triggered visibility
correction (window arrival/removal, column count change); it has no
"already handled at focus-confirm time" awareness and no fully-visible
no-op, because that responsibility belongs to `revealForFocusActivation`,
which was bypassed in step 2.

This `ensureSelectionVisible` call is reached via
`Sources/Nehir/Core/Controller/NiriLayoutHandler.swift:570` (`resolveSelection`),
`:642` — gated on `!isGestureOrAnimation` (`:597`), which is false by the
time the requested relayout actually runs (the prior spring has settled),
so the gate that blocked `revealForFocusActivation` moments earlier no
longer blocks `ensureSelectionVisible` here. The same underlying state
(`isAnimating`) that caused the skip in step 2 has, by construction, always
cleared by the time the deferred relayout runs — so the fallback path always
fires, never the intended one.

---

## Root cause

There are two layers, one general (explains both repros) and one specific
(explains why repro 1's focus-confirm reveal is skipped outright rather
than merely superseded):

**General (both repros).** Nothing in the focus-confirmation path updates
`state.activeColumnIndex` — `revealForFocusActivation` and `scrollToReveal`
only ever move the viewport offset, never the active-column pointer. But
`ax_focus_confirm_request_relayout` *unconditionally* requests a follow-up
relayout after every focus confirmation, success or skip
(`AXEventHandler.swift:2549-2558`). That relayout's `resolveSelection` →
`ensureSelectionVisible` (gated only on `!isGestureOrAnimation`, which is
essentially always true again by the time the relayout actually executes)
compares the *real* column of `state.selectedNodeId` against the *stale*
`state.activeColumnIndex` and, finding them different, performs its own
instant rebase + recenter — regardless of whether the focus-confirm step's
own reveal already ran, was skipped, or already landed on the right
answer. Repro 2 shows this firing even when the focus-confirm reveal
succeeded (`didReveal=true`): the relayout's "before" snapshot still shows
the pre-focus-confirm `activeColumnIndex`, so it treats the selection as
unrevealed and redoes the work itself.

**Specific to repro 1 (why the focus-confirm reveal is skipped, not just
superseded).** `AXEventHandler`'s `preserveActiveViewport` skips
`revealForFocusActivation` whenever `state.viewOffsetPixels.isAnimating`,
which stays true through a spring's cosmetic settle tail (`current ==
target`, not yet flipped to `.static`). This is what makes repro 1 produce
*zero* visible motion at focus-confirm time (rather than repro 2's
"correct-but-then-redone" pattern) — the relayout ends up being the *only*
mover, working from a `state.selectedNodeId` whose column was never even
looked up by the focus-confirm step.

Both repros converge on the same downstream "mover":
`Sources/Nehir/Core/Layout/Niri/NiriNavigation.swift:173` →
`Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+ViewportCommands.swift:70`
(`ensureSelectionVisible` → `scrollToReveal`), reached via
`Sources/Nehir/Core/Controller/NiriLayoutHandler.swift:570`
(`resolveSelection`). This is not a rare race; it reproduces whenever a
window in a different, clipped column receives focus — by click, by
keyboard, or, per repro 2, by an unrelated app simply self-activating one
of its own background windows.

---

## Fix direction

### Phase 1 — Keep `activeColumnIndex` synced at focus-confirm time (primary fix, covers both repros)

When `activateNode` updates `state.selectedNodeId`
(`AXEventHandler.swift:2457-2466`), also resolve and store the node's real
column index immediately — unconditionally, on both the
`preserveActiveViewport == true` and `== false` branches — i.e. update
`state.activeColumnIndex` without necessarily moving the viewport offset
itself (offset movement stays gated by the existing
`revealForFocusActivation`/`preserveActiveViewport` logic). This removes
the staleness that forces `ensureSelectionVisible`'s rebase branch to fire
on the next relayout: if `activeColumnIndex` is already correct,
`ensureSelectionVisible`'s `offsetDelta` rebase becomes a no-op (`targetIdx
== state.activeColumnIndex`), and the relayout either does nothing further
(repro 2: the focus-confirm reveal already got there) or performs a single,
policy-respecting `scrollToReveal` call from the *actual* current offset
(repro 1: the focus-confirm reveal was skipped, so this becomes the one and
only mover, instead of an instant-rebase-then-recenter pair).

**Implementation status (2026-07-01): landed**, commit `26b4f8a3` ("Sync
activeColumnIndex during focus confirmation") on `main`. Verified against the
current source tree: the `activateNode` call is still at
`AXEventHandler.swift:2457-2466` (line numbers had not drifted), and the new
column-sync block sits at `AXEventHandler.swift:2476-2483`, immediately after
the `ax_focus_confirm_after_activate` trace record and before the existing
`if !isFFM, !preserveActiveViewport, ...` reveal branch — guarded by `if let
activatedColumn = engine.column(of: node), let activatedColumnIndex =
engine.columnIndex(of: activatedColumn, in: wsId)` so a floating/non-tiled
node leaves `activeColumnIndex` untouched, exactly as scoped. Viewport offset
movement was not touched.

### Phase 2 — Stop treating a converged spring as "in flight" (repro 1's specific trigger)

Narrow the animation half of `preserveActiveViewport`
(`AXEventHandler.swift:2438-2440`) so it only protects a *genuinely moving*
spring, not one whose `current` has already converged to `target`. The
viewport already has the building blocks for an "is this settled" check
(`scrollToReveal` and friends compare offsets against a `pixel` tolerance
derived from `displayScale`); reuse that pattern rather than introducing a
new threshold. Concretely: compute `isAnimating` for the gate as
`state.viewOffsetPixels.isAnimating && abs(current - target) > pixel`,
or equivalently treat a spring within tolerance of its target as `.static`
for this purpose only. This lets the focus-confirm step's own
`revealForFocusActivation` run (and honor `revealPartial`) instead of
leaving the relayout as the sole, policy-blind mover.

### Phase 3 — Regression tests

- `AXEventHandlerTests` (or equivalent focus-confirmation test target):
  drive a focus confirmation while `viewOffsetPixels` is a `.spring` whose
  `current == target` (settled-but-not-yet-`.static`), targeting a node in a
  **different, clipped** column than `state.activeColumnIndex`. Assert
  `revealForFocusActivation` runs (i.e. `ax_focus_confirm_reveal_candidate`
  is recorded / the equivalent return value path is taken) and that the
  resulting viewport motion is a single `scrollToReveal`-policy move, not an
  instant rebase followed by a second spring.
  **Implementation status (2026-07-01): not yet implemented** — this needs
  Phase 2 (the settle-tail fix) to be meaningful, since today a converged
  spring still reports `preserveActiveViewport == true` and skips
  `revealForFocusActivation` outright.
- Regression test mirroring the existing `dad2e63a` fully-visible no-op
  test, but for a **clipped** target column under a converged-but-still-
  `.spring` `viewOffsetPixels`, asserting `revealPartial` policy is honored
  exactly as it would be from `.static`.
  **Implementation status (2026-07-01): not yet implemented** — same Phase 2
  dependency as above.
- `NiriNavigationTests` (or equivalent): `ensureSelectionVisible` called
  with `state.activeColumnIndex` already equal to the selected node's real
  column must not perform the `moveSelectionToContainer.rebaseActiveColumn`
  mutation (i.e. it's a true no-op rebase when already in sync).
  **Implementation status (2026-07-01): covered, not as a standalone
  suite** — there is no `NiriNavigationTests` target; `ensureSelectionVisible`
  is otherwise exercised in `NiriLayoutEngineTests.swift`. This specific
  already-in-sync no-op assertion was instead folded into the
  `AXEventHandlerTests` test below, which drives `engine.ensureSelectionVisible`
  directly on the post-focus-confirm state and asserts
  `lastViewportMutationReason != "moveSelectionToContainer.rebaseActiveColumn"`
  with `state.isViewportMutationAuditEnabled` turned on for the check.
- `AXEventHandlerTests`: repro-2 shape — focus-confirm a node in a
  different, clipped column with `preserveActiveViewport == false` (no
  gesture, no animation), let `revealForFocusActivation` succeed
  (`didReveal == true`), then drive the follow-up relayout
  (`resolveSelection`/`ensureSelectionVisible`) and assert it performs **no
  further offset mutation** — `state.activeColumnIndex` was already synced
  by Phase 1, so the relayout's rebase is a no-op and the only viewport
  motion observed end to end is the one `revealForFocusActivation` already
  produced.
  **Implementation status (2026-07-01): landed** as
  `focusConfirmationSyncsActiveColumnIndexForClippedTarget` in
  `Tests/NehirTests/AXEventHandlerTests.swift`, alongside an update to the
  pre-existing `focusConfirmationPreservesActiveViewportSpring` test (its old
  `activeColumnIndex == 0` assertion under `preserveActiveViewport == true`
  encoded the bug; it now asserts `activeColumnIndex` matches the activated
  node's real column, derived via `engine.column(of:)`/`columnIndex(of:in:)`
  rather than hardcoded). Confirmed the new test catches the regression: with
  the Phase 1 source change reverted, it fails with `activeColumnIndex → 0 ==
  targetColumnIndex → 1`. Full validation run clean: `swift build`,
  `AXEventHandlerTests` (167/167), `NiriLayoutEngineTests` (142/142, the
  closest existing target to "NiriNavigationTests"), `WorkspaceManagerTests`
  (62/62), and the full `swift test` suite (1379/1379 across 113 suites).

**Exit criteria:** both repros — a click landing during a settling spring,
and a zero-input app self-activation focusing a clipped, non-active-column
window — produce a single, visibility-policy-respecting reveal motion (or
no motion, if `revealPartial == .off`), not an instant rebase followed by a
separate centering spring, and not two independent reveal computations
landing on the same destination by coincidence.

---

## Acceptance criteria

- `state.activeColumnIndex` reflects the newly confirmed selection's real
  column immediately after `activateNode`, regardless of
  `preserveActiveViewport` — fixed unconditionally, not just for the click
  case.
- The relayout requested by every focus confirmation no longer needs to
  perform a column rebase when the focus-confirm step already resolved
  `activeColumnIndex` (repro 2: a successful `revealForFocusActivation` is
  not redundantly redone by the relayout).
- Clicking a window in a different, clipped column while a prior relayout's
  viewport spring has visually converged (but not yet formally stopped)
  triggers `revealForFocusActivation`/`scrollToReveal` directly from the
  focus-confirmation step, honoring `revealPartial` (repro 1).
- A window in another process self-activating (no click, no gesture, no
  keyboard input) and landing in a clipped, non-active column produces at
  most one viewport motion, sourced from a single, identifiable reveal
  computation — not an opaque jump whose destination only coincidentally
  matches what the focus-confirm step already computed.

## Out of scope / risks

- Do not change `scrollToReveal`'s `.clipped`/`revealPartial` policy itself
  — that's working as designed; the bug is that the click never reaches it
  via the focus-activation-specific path.
- Do not weaken `preserveActiveViewport`'s gesture (`isGesture`) or
  already-confirmed-focus (`wasAlreadyConfirmedFocus && source ==
  .focusedWindowChanged`) clauses — only the settle-tail false positive in
  the `isAnimating` clause is in scope.
- This is adjacent to, but does not block or get blocked by, Phase 3 of
  `planned/20260625-unrecorded-viewport-offset-mutation-attribution.md`
  (item 7's fix). That phase targets `resolveSelection`/
  `ensureSelectionVisible` recentering an **unchanged** selection; this plan
  targets a **changed** selection whose reveal got routed to the wrong code
  path. Land in either order; re-validate this repro after item 7 ships in
  case its `resolveSelection` gating changes shift the `isGestureOrAnimation`
  timing assumed above.
- If Phase 2's tolerance-based "settled spring" check turns out to be used
  elsewhere and has subtle interactions with the gesture-interrupt path
  (`settleAtCurrentOffset`, `ViewportState+Animation.swift`), keep the
  check local to the `preserveActiveViewport` computation rather than
  changing `ViewportOffset.isAnimating`'s general definition.
- Repro 2 confirms `recordRuntimeViewportTrace`'s `currentOffset`/
  `targetOffset` fields reflect the **committed** `workspaceManager` state,
  not a function's in-flight local `inout ViewportState` — anyone reading
  future traces of this code path should not interpret unchanged
  offset/target fields on `ax_focus_confirm_reveal_result` as proof the
  reveal had no effect; cross-check `didReveal` and the *next* mutation's
  `lastViewportMutationBefore*` fields instead.

## References

- Skip site: `Sources/Nehir/Core/Controller/AXEventHandler.swift:2438-2570`
  (`preserveActiveViewport`, reveal block, `ax_focus_confirm_reveal_skipped`,
  unconditional relayout request at `:2549-2558`).
- Animation predicate: `Sources/Nehir/Core/Layout/Niri/ViewportState.swift:111-120`
  (`ViewportOffset.isAnimating`).
- Focus-activation reveal (added by `dad2e63a`/`0602387d`): `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+ViewportCommands.swift:160-211`
  (`revealForFocusActivation`) — reachable in repro 2, unreachable in repro 1.
- Generic relayout reveal mover: `Sources/Nehir/Core/Layout/Niri/NiriNavigation.swift:173-246`
  (`ensureSelectionVisible`, instant rebase at `:220-223`),
  `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+ViewportCommands.swift:70-150`
  (`scrollToReveal`).
- Relayout entry point: `Sources/Nehir/Core/Controller/NiriLayoutHandler.swift:570-654`
  (`resolveSelection`, `isGestureOrAnimation` gate at `:597`).
- Stale-patch guard already shipped (item 8, verified present): `Sources/Nehir/Core/Workspace/WorkspaceManager.swift:1753-1794`
  (`applySessionPatch`, gesture guard `:1764-1767`, `plannedSelectionRevision`
  guard `:1769-1783`) — landed as `42ac731f`; does not cover the
  `activeColumnIndex`/offset desync this plan addresses.
- Related, not overlapping: `discovery/20260628-relayout-path-recenters-fully-visible-unchanged-selection.md`
  (item 7 — unchanged-selection no-op recenter, same mover, different
  trigger), `discovery/20260618-stale-session-selection-revision-guard.md`
  (item 8 — unrelated async-patch staleness), `planned/20260625-unrecorded-viewport-offset-mutation-attribution.md`
  (single-slot audit collapse referenced above).
