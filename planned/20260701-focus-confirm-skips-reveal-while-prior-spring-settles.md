# Focus-confirm skips reveal while a prior spring is settling; relayout snaps instead — Plan

## Verdict on the "D. Relayout viewport stability" catalogue

Checked against the three candidate items from the catalogue:

- **Item 7** ("Settled relayout recenters an already fully-visible unchanged
  selection") — **does not match**. In this repro the selection's column
  genuinely changes (the clicked window is not in the previously active
  column), so this is not a no-op/unchanged-selection case. Item 7's fix
  (`discovery/20260628-relayout-path-recenters-fully-visible-unchanged-selection.md`)
  explicitly preserves "genuine selection change" as a legitimate recenter
  trigger, so shipping it would **not** fix this repro.
- **Item 8** ("Stale relayout patch overwrites a live gesture / newer state")
  — **does not match**. There is no stale async session patch race here; the
  whole sequence below happens synchronously within one focus-confirmation
  call plus the relayout it requests. (Item 8 is `discovery/20260618-stale-session-selection-revision-guard.md`,
  already fixed on an unmerged branch — unrelated code path: `WorkspaceManager.applySessionPatch`.)
- **Item 9** ("Settings/config relayout reinterprets a parked/edge-snapped
  selection") — **does not match**. The trigger is a mouse click and its
  focus confirmation, not an app-rule/workspace-config/monitor-settings/gap
  change.

This is a **fourth, previously undocumented** mechanism. It shares the same
downstream "mover" code as item 7 (`ensureSelectionVisible` →
`scrollToReveal` → `animateToOffset`) and the same unrecorded-intermediate-
mutation pattern as the "Residual attribution gap" noted in
`planned/20260625-unrecorded-viewport-offset-mutation-attribution.md`, but
the *trigger* — a click confirming focus while an unrelated prior spring is
in its settle tail — is new.

---

## TL;DR

- **Symptom.** Clicking a window in a column outside the currently active
  column, while a previous relayout's viewport spring is still technically
  "animating" (even though it has already visually reached its target),
  produces no movement at focus-confirmation time, then a visible viewport
  snap moments later when the requested relayout runs.
- **Root cause.** `AXEventHandler`'s `preserveActiveViewport` gate treats
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

## Evidence — one repro, full causal chain

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

Two gates that should agree don't:

1. `AXEventHandler`'s `preserveActiveViewport` skips `revealForFocusActivation`
   whenever `state.viewOffsetPixels.isAnimating`, which stays true through a
   spring's cosmetic settle tail (`current == target`, not yet flipped to
   `.static`).
2. The relayout the focus-confirm step itself requests runs moments later,
   by which point the same spring has settled and `isGestureOrAnimation` is
   false — so `resolveSelection` always proceeds to `ensureSelectionVisible`,
   which has no fully-visible/`revealPartial` awareness and instead does an
   instant rebase followed by a hard centering spring.

The combination means: any click on a window outside the active column,
landing during another spring's settle tail, **always** gets routed through
the generic relayout reveal path instead of the focus-activation-specific
one — guaranteeing the jarring rebase-then-recenter motion instead of the
smooth, visibility-aware reveal `revealForFocusActivation` exists to
provide. This is not a rare race; it reproduces whenever a transient
relayout (Helium's address-bar/preview popups, or anything else that
briefly nudges the viewport — see
`discovery/20260628-relayout-path-recenters-fully-visible-unchanged-selection.md`
for triggers) is still settling when the user clicks a window in a
different column.

---

## Fix direction

### Phase 1 — Stop treating a converged spring as "in flight"

Narrow the animation half of `preserveActiveViewport`
(`AXEventHandler.swift:2438-2440`) so it only protects a *genuinely moving*
spring, not one whose `current` has already converged to `target`. The
viewport already has the building blocks for an "is this settled" check
(`scrollToReveal` and friends compare offsets against a `pixel` tolerance
derived from `displayScale`); reuse that pattern rather than introducing a
new threshold. Concretely: compute `isAnimating` for the gate as
`state.viewOffsetPixels.isAnimating && abs(current - target) > pixel`,
or equivalently treat a spring within tolerance of its target as `.static`
for this purpose only.

### Phase 2 — Keep `activeColumnIndex` synced at focus-confirm time

Independent of Phase 1 (defense in depth): when `activateNode` updates
`state.selectedNodeId` (`AXEventHandler.swift:2457-2466`), also resolve and
store the node's real column index immediately, even on the
`preserveActiveViewport == true` branch — i.e. update
`state.activeColumnIndex` without moving the viewport offset. This removes
the staleness that forces `ensureSelectionVisible`'s rebase branch to fire
on the next relayout; if `activeColumnIndex` is already correct,
`ensureSelectionVisible`'s `offsetDelta` rebase becomes a no-op (`targetIdx
== state.activeColumnIndex`), and only `scrollToReveal` proper runs — and
only if the column truly isn't visible yet from the *new* (still-unmoved)
viewport.

### Phase 3 — Regression tests

- `AXEventHandlerTests` (or equivalent focus-confirmation test target):
  drive a focus confirmation while `viewOffsetPixels` is a `.spring` whose
  `current == target` (settled-but-not-yet-`.static`), targeting a node in a
  **different, clipped** column than `state.activeColumnIndex`. Assert
  `revealForFocusActivation` runs (i.e. `ax_focus_confirm_reveal_candidate`
  is recorded / the equivalent return value path is taken) and that the
  resulting viewport motion is a single `scrollToReveal`-policy move, not an
  instant rebase followed by a second spring.
- Regression test mirroring the existing `dad2e63a` fully-visible no-op
  test, but for a **clipped** target column under a converged-but-still-
  `.spring` `viewOffsetPixels`, asserting `revealPartial` policy is honored
  exactly as it would be from `.static`.
- `NiriNavigationTests` (or equivalent): `ensureSelectionVisible` called
  with `state.activeColumnIndex` already equal to the selected node's real
  column must not perform the `moveSelectionToContainer.rebaseActiveColumn`
  mutation (i.e. it's a true no-op rebase when already in sync).

**Exit criteria:** the repro above — click a clipped window in a non-active
column while a prior spring is in its settle tail — produces a single,
visibility-policy-respecting reveal motion (or no motion, if `revealPartial
== .off`), not an instant rebase followed by a separate centering spring.

---

## Acceptance criteria

- Clicking a window in a different, clipped column while a prior relayout's
  viewport spring has visually converged (but not yet formally stopped)
  triggers `revealForFocusActivation`/`scrollToReveal` directly from the
  focus-confirmation step, honoring `revealPartial`.
- `state.activeColumnIndex` reflects the newly confirmed selection's real
  column immediately after `activateNode`, regardless of
  `preserveActiveViewport`.
- The subsequent relayout's `ensureSelectionVisible` no longer needs to
  perform a column rebase for this case (it was already in sync), so only
  one viewport motion is observed end to end, not two.

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
- If Phase 1's tolerance-based "settled spring" check turns out to be used
  elsewhere and has subtle interactions with the gesture-interrupt path
  (`settleAtCurrentOffset`, `ViewportState+Animation.swift`), keep the
  check local to the `preserveActiveViewport` computation rather than
  changing `ViewportOffset.isAnimating`'s general definition.

## References

- Skip site: `Sources/Nehir/Core/Controller/AXEventHandler.swift:2438-2540`
  (`preserveActiveViewport`, reveal block, `ax_focus_confirm_reveal_skipped`).
- Animation predicate: `Sources/Nehir/Core/Layout/Niri/ViewportState.swift:111-120`
  (`ViewportOffset.isAnimating`).
- Focus-activation reveal (added by `dad2e63a`/`0602387d`, currently
  unreachable for this repro): `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+ViewportCommands.swift:160-211`
  (`revealForFocusActivation`).
- Generic relayout reveal mover: `Sources/Nehir/Core/Layout/Niri/NiriNavigation.swift:173-246`
  (`ensureSelectionVisible`, instant rebase at `:220-223`),
  `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+ViewportCommands.swift:70-150`
  (`scrollToReveal`).
- Relayout entry point: `Sources/Nehir/Core/Controller/NiriLayoutHandler.swift:570-654`
  (`resolveSelection`, `isGestureOrAnimation` gate at `:597`).
- Related, not overlapping: `discovery/20260628-relayout-path-recenters-fully-visible-unchanged-selection.md`
  (item 7 — unchanged-selection no-op recenter, same mover, different
  trigger), `discovery/20260618-stale-session-selection-revision-guard.md`
  (item 8 — unrelated async-patch staleness), `planned/20260625-unrecorded-viewport-offset-mutation-attribution.md`
  (single-slot audit collapse referenced above).
