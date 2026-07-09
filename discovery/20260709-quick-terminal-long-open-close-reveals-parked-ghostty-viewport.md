# Quick Terminal close disturbs viewport / switches workspace (same-app focus redirect acted on instead of ignored)

**Status:** discovery / source-backed root cause. Verified against `main`
(`Sources/Nehir/Core/Controller/AXEventHandler.swift` as of this branch's
checkout; re-verify line numbers before implementing — they drift).

**Symptom:** closing Ghostty's Quick Terminal *occasionally* disturbs the
viewport/focus even though the user only dismissed the overlay and never
navigated. Two observed surface symptoms, one underlying cause:

- **Variant A (viewport scroll):** on the *active* origin workspace, the viewport
  scrolls to reveal the regular managed Ghostty window's parked column.
- **Variant B (workspace switch):** when the user has navigated to a *different*
  workspace, the QT close drags the active workspace back to the origin (Ghostty)
  workspace.

Both violate "closing the quick terminal must not move the viewport or switch
workspaces."

## Unifying root cause

On QT close, macOS emits a same-app `AXFocusedWindowChanged` for the Ghostty pid
that resolves to **one specific managed Ghostty window — whichever macOS treats as
the app's main/frontmost window (the most-recently-focused Ghostty window)**. This
target window is *not* necessarily on the workspace the user is currently viewing:
if the user has Ghostty windows on several workspaces, macOS refocuses the
last-focused one wherever it lives. Nehir then *acts* on that redirect instead of
ignoring it. **Which Ghostty window macOS picks, and whether its workspace is
active, is the primary lever**; the disturbance you then see depends on that plus
timing:

| Origin workspace | Overlay evidence armed | Race outcome | Symptom | Path |
|---|---|---|---|---|
| active | — | reveal wins | **viewport scroll** to parked column | reveal via `scrollToReveal` |
| active | — | destroy wins | correct | `closeRecoveryStableRedirect` |
| inactive | no | — | correct (suppressed) | `close_recovery_inactive_successor_suppressed` |
| inactive | **yes** | — | **workspace switch** to origin | `redirectToStableSameAppRecoveryFocusIfNeeded` (`AXEventHandler.swift:2669`) |

Open duration / any "recent overlay" TTL is **not** the discriminator: Variant A
reproduces with the memory *absent* and Variant B reproduces with the memory
*present* (`recentNonManaged=true`).

This refines and partially supersedes
[`20260702-quick-terminal-close-reveals-managed-ghostty-column.md`](20260702-quick-terminal-close-reveals-managed-ghostty-column.md):
same symptom, but that note predates the close-recovery machinery that has since
landed. The determinant is **not** how long the overlay was open, and **not** a
TTL/"recent overlay" memory — it is an **event-ordering race** between the
overlay's destroy (which arms close-recovery) and the same-app
`AXFocusedWindowChanged` redirect that reveals the parked window.

All runtime evidence below is inlined; this document does not depend on any
captured trace file surviving.

---

## Two captures, same shape, opposite outcome

Both captures are the *same structural event*: a different app is the confirmed
managed focus, Ghostty's Quick Terminal overlay (`pid 82494`, overlay window
`5915`, classified `unmanaged source=builtInRule(ghosttyQuickTerminalOverlay)`)
is open, and on close macOS emits an `AXFocusedWindowChanged` for the Ghostty pid
that resolves to a **regular managed Ghostty window parked offscreen to the
left**. Ghostty owns two managed windows here: `27176` (`source=userRule`) and
`29687` (`source=heuristic`).

The knobs that are **identical** in both closes (so none of them is the
determinant):

- Overlay open duration is long in both (bad ≈16 s: opened `07:40:25`, closed
  `07:40:41`; good ≈42 s: opened `08:01:43`, closed `08:02:25`).
- At the close-time activation gate both show
  `recentSameAppClose=false recentNonManagedFocus=false focusedWindowLossPrecursor=nil`
  and `decision=allow reason=no_recent_same_app_close`.
- In both, the previously confirmed managed focus is a **different app**
  on-screen (bad: Microsoft Teams `53999:30982`; good: `1876:31050`), and the
  redirect target is a **parked-left** Ghostty window (bad: `27176` at column 0,
  `hidden:left`; good: `29687` at column 0, `hidden:left`).

### GOOD close — viewport stays put (workspace `3E053A2E…`, 3 columns)

Close-recovery is already armed when the parked-redirect activation arrives, so
`redirectToStableRecoveryFocusIfNeeded` fires and sends focus back to the
**pre-close on-screen window**:

```text
reason=close_recovery_activation_gate token=WindowToken(pid: 82494, windowId: 29687)
  source=focusedWindowChanged decision=allow reason=no_recent_same_app_close
  columns=3 activeColumnIndex=2 currentViewStart=1519.5
  confirmedFocus=WindowToken(pid: 1876, windowId: 31050)   // on-screen, column 2

event: pending_focus_started token=WindowToken(pid: 1876, windowId: 31050)
  reason=closeRecoveryStableRedirect          ← focus restored to the pre-close window
event: follow_focus_to_parked_window token=…29687 decision=skip reason=dedup
```

No `ax_focus_confirm_before_activate`, no reveal candidate, no
`viewportOffsetChanged`, no `scroll_animation_start` — the viewport never moves.

### BAD close — viewport scrolls to the parked column (workspace `4DF8AC09…`, 7 columns)

Close-recovery is **not yet armed** when the same parked-redirect activation
arrives, so the reveal path runs to completion first:

```text
reason=close_recovery_activation_gate token=WindowToken(pid: 82494, windowId: 27176)
  source=focusedWindowChanged decision=allow reason=no_recent_same_app_close
  columns=7 activeColumnIndex=3 currentViewStart=4367.1
  confirmedFocus=WindowToken(pid: 53999, windowId: 30982)   // Teams, on-screen, column 3

reason=ax_focus_confirm_before_activate token=…27176
  preserveActiveViewport=false closeRecoveryPin=false recentSameAppClosePin=false
  overlayRecoveryPin=false recentNonManaged=false overlayVisible=false
  wasAlreadyConfirmedFocus=false

reason=ax_focus_confirm_reveal_candidate token=…27176 columnIndex=0
  visibility=parked(AxisHideEdge.minimum) viewStart=4367.1 center=-56.9:center
reason=ax_focus_confirm_reveal_result token=…27176 didReveal=true

reason=relayout.viewportOffsetChanged activeColumnIndex=0
  currentViewStart=4335.2 → targetViewStart=-56.9        ← THE UNWANTED SCROLL
reason=scroll_animation_start targetViewStart=-56.9
```

Only *after* the reveal is already animating does the overlay destroy arm
close-recovery — and by then it cannot capture the pre-close focus:

```text
reason=close_recovery_begin caller=auxiliary_destroy suppressedPid=82494 preservedToken=nil
  currentViewStart=4127.1 targetViewStart=-56.9          ← reveal already in flight
reason=close_recovery_stable_target targetToken=WindowToken(pid: 82494, windowId: 27176) reason=nearest
```

`preservedToken=nil` and the stable target resolves to the **parked Ghostty
`27176` itself** (`reason=nearest`), because focus had already been confirmed
there. There is **no** `closeRecoveryStableRedirect` in this capture. The
viewport is already committed to `targetViewStart=-56.9`; the later suppression
of subsequent activations cannot undo it.

---

## Root cause

The defense that keeps the viewport stable on a Quick Terminal close is
`redirectToStableRecoveryFocusIfNeeded` (`AXEventHandler.swift:2417-2452`): when
an activation arrives during close-recovery, it redirects focus to the
pre-close "stable" target and emits `.closeRecoveryStableRedirect`
(`AXEventHandler.swift:2450`). Its very first guard is:

```swift
guard let context = activeWindowCloseFocusRecoveryContext(),
      context.workspaceId == workspaceId
else { return false }
```

i.e. **close-recovery must already be armed** when the redirect activation is
processed. Close-recovery is armed only by the overlay's `AXUIElementDestroyed`
handler: `prepareDestroyCandidate` returns nil for the untracked overlay element,
and the fallback calls `armWindowCloseFocusRecoveryForFocusedAppEvent`
(`AXEventHandler.swift:5085-5098`, arming at `:2301-2309`).

On close, macOS delivers two independent AX events in a burst:

1. `AXFocusedWindowChanged` (pid 82494) → resolves to a **parked managed Ghostty
   window** → `handleManagedAppActivation` → `scrollToReveal` on the parked
   column.
2. `AXUIElementDestroyed` (overlay `5915`) → arms close-recovery.

**Their processing order is not guaranteed.**

- When **(2) is processed first** (GOOD): close-recovery is armed, so activation
  (1) hits `redirectToStableRecoveryFocusIfNeeded`, focus is redirected back to
  the pre-close on-screen window, and the parked reveal never runs. No scroll.
- When **(1) is processed first** (BAD): close-recovery is not yet armed
  (`activeWindowCloseFocusRecoveryContext() == nil`), the guard returns false, the
  reveal runs and confirms focus on the parked window, and close-recovery arms
  too late — with `preservedToken=nil` and a `nearest` stable target that is now
  the parked window itself, so it cannot correct anything. Viewport scrolls.

This is exactly the distinction the design is meant to make and the user
describes: **window close (restore the pre-close focus/viewport) vs. legitimate
same-app window focus switch (may reveal).** The QT close is the former, but when
the focus-redirect event wins the race it is handled as the latter.

The `recentNonManagedFocus` / `overlayRecoveryPin` / `recentSameAppClose` memories
are all false in **both** captures and are not the discriminator; overlay open
duration is irrelevant.

### Secondary fragility worth noting for the fix

`armWindowCloseFocusRecoveryForFocusedAppEvent` (`AXEventHandler.swift:2301-2309`)
only arms when the *currently confirmed* focus is already the destroyed overlay's
pid (`focusedToken.pid == pid`). In the bad capture this is satisfied only
*because* the erroneous reveal already confirmed focus on Ghostty `27176` — so
the arming that does happen is a consequence of the bug, not a defense against
it, and it lands with `preservedToken=nil`. Any fix should capture the correct
pre-close stable target independent of whether the racing redirect already
mutated confirmed focus.

---

## Variant B — workspace switch on close (inactive origin workspace)

Capture: workspace `3E053A2E…` ("workspace 1") hosts the managed Ghostty window
`29687` **partially visible** (column 0, `cur=-494 … hidden:nil` — clipped at the
left edge, not fully parked) and the pre-close focus `51532:24203` selected at
column 1. The user opened QT, then navigated away to workspace 7 via the
workspace bar, then closed QT at `08:11:30` — so workspace 1 was **inactive**.

```text
reason=close_recovery_activation_gate token=WindowToken(pid: 82494, windowId: 29687)
  isWorkspaceActive=false source=focusedWindowChanged      // origin ws inactive

reason=close_recovery_overlay_stable_target
  observedToken=WindowToken(pid: 82494, windowId: 29687)
  targetToken=WindowToken(pid: 51532, windowId: 24203)     // a window ON workspace 1
  recentSameAppClose=false recentNonManaged=true overlayVisible=false

reason=ax_focus_confirm_reveal_result token=…51532:24203 didReveal=false   // no scroll

reason=close_recovery_activation_gate token=WindowToken(pid: 51532, windowId: 24203)
  isWorkspaceActive=true source=focusedWindowChanged origin=probe   // ws 1 now ACTIVE ⇒ switch
```

The viewport did not scroll (`didReveal=false`, target fully visible), but
focusing `51532:24203` — a window on the inactive origin workspace — flipped
workspace 1 back to active, switching the user away from workspace 7.

### Source locus

`redirectToStableSameAppRecoveryFocusIfNeeded` (`AXEventHandler.swift:2669-2748`)
emits `close_recovery_overlay_stable_target` and, for the `.overlay` phase, fires
whenever `hasOverlayRecoveryEvidence` (`recentNonManaged || overlayVisible`) is
true (`:2685-2694`). It then computes a stable focus target **on the origin
`workspaceId`** and focuses it unconditionally:

```swift
let target = stableViewportFocusTarget(workspaceId: workspaceId, excluding: observedEntry.token)
…
controller?.focusWindow(target, reason: phase.focusReason)   // :2746
```

There is **no guard that `workspaceId` is still the active workspace**. The
runtime reveal path has an inactive-workspace guard
(`close_recovery_inactive_successor_suppressed`, exercised in a sibling capture),
but this focus-redirect path does not — so on an inactive origin workspace it
reaches back and refocuses there, forcing the switch. `recentNonManaged=true`
here confirms the overlay memory being *armed* is what routes the close into this
path; it is not a TTL/duration effect.

## Prerequisites for reproduction

Durable topology (all required):
1. Ghostty's **regular window is managed** by Nehir (the built-in
   `ghosttyQuickTerminalOverlay` rule keeps the QT overlay unmanaged; a user rule
   or the heuristic manages the regular window). One pid owns both.
2. The managed Ghostty regular window is on the **currently active** workspace,
   in a column that is **parked offscreen** and **not visible** in the current
   viewport (≥3 columns; Ghostty's column clipped/parked). If it were already
   visible the reveal is a no-op and nothing can scroll. **The workspace must be
   active at close time** (`isWorkspaceActive=true` at the gate): when the
   Ghostty workspace is inactive, the redirect is instead caught by the
   inactive-workspace successor guard (`close_recovery_inactive_successor_suppressed
   … reason=unmanaged_current_target`) and no reveal runs — so toggling QT while
   navigating across workspaces is safe.
3. The confirmed managed focus is a **different app** in a different, on-screen
   column on that active workspace.

Action sequence:
4. Stay on the workspace that hosts the parked managed Ghostty window; focus the
   non-Ghostty on-screen window there (Ghostty's managed column stays parked
   offscreen).
5. Open Ghostty's Quick Terminal (over that app), keeping the same workspace
   active.
6. Close the Quick Terminal **without switching workspaces first**.

**Primary gating condition (why it is hard to reproduce):** the QT-close redirect
targets whichever Ghostty window macOS makes frontmost — the *most-recently-focused
Ghostty window* — not the Ghostty window on the workspace you are viewing. Variant
A can only fire when that target window is on the **currently active** workspace
*and* parked there. In a capture where the user viewed workspace 4 (Ghostty window
`27176` parked there) but the last-focused Ghostty window was `29687` on the
inactive workspace 1, **every** close redirect targeted `29687` on workspace 1 →
`close_recovery_inactive_successor_suppressed` → no scroll, no matter how many
times QT was toggled. The workspace-4 window was never the redirect target.

To pin condition (1), make the active workspace's Ghostty window the only (or
most-recently-focused) Ghostty window: close/move Ghostty windows on other
workspaces so macOS is forced to refocus the active-workspace one on close.

Once that is pinned, occurrence is still **intermittent by nature (condition 2)**:
Variant A fires only when the close-time redirect is processed *before* the overlay
`AXUIElementDestroyed` arms close-recovery. Open duration does **not** matter
(reproduced with the overlay open for tens of seconds; a long-open close that
processed the destroy first stayed stable). Repeat open/close; a fraction of
closes will jump the viewport to the parked Ghostty column. Toggling faster or
slower does not change the race, only the luck of event ordering.

### Variant B (workspace switch) prerequisites

Same topology (managed Ghostty window clipped/parked on its workspace, a
different app focused there), but:
1. Overlay recovery evidence must be **armed** (`recentNonManaged=true`) — i.e.
   the overlay was seen recently enough that `hasSameAppOverlayRecoverySignal`
   returns true at close.
2. **Navigate to a different workspace after opening QT**, so the Ghostty
   workspace is inactive at close.
3. Close QT.

The close then reaches `redirectToStableSameAppRecoveryFocusIfNeeded(.overlay)`,
which refocuses a window on the (inactive) Ghostty workspace and switches the
active workspace back to it — deterministically when (1) and (2) hold, not a race.

---

## Candidate fix directions (for the plan stage — not prescribed here)

The goal is to make close-recovery arming win the race, or to make the
parked-window reveal wait for it — so the QT close is always handled as a
window-close, never as a same-app focus switch:

1. **Defer the same-app parked reveal briefly when a same-pid overlay just
   disappeared / is disappearing.** Hold confirmation+reveal of a
   `focusedWindowChanged` redirect to a *parked* managed window whose pid owns a
   known unmanaged overlay for a very short window, giving the overlay
   `AXUIElementDestroyed` a chance to arm close-recovery so
   `redirectToStableRecoveryFocusIfNeeded` can catch it.

2. **Arm close-recovery from the overlay's disappearance independent of confirmed
   focus.** Loosen `armWindowCloseFocusRecoveryForFocusedAppEvent`'s
   `focusedToken.pid == destroyedPid` guard for the overlay-close case and capture
   the *pre-close* stable target (the on-screen window that was focused before the
   overlay), so arming does not depend on the racing redirect having already
   mutated focus, and `preservedToken` is non-nil.

3. **Ensure ordering: process the auxiliary overlay destroy ahead of the same-burst
   same-app focus redirect** (e.g. recognize the destroy synchronously within the
   activation path when a same-pid overlay is known-present), so
   `activeWindowCloseFocusRecoveryContext()` is non-nil at the redirect.

4. **(Variant B) Gate the overlay stable-recovery redirect on the origin
   workspace still being active.** `redirectToStableSameAppRecoveryFocusIfNeeded`
   (`AXEventHandler.swift:2669`) refocuses a window on `workspaceId` with no check
   that `workspaceId` is the active workspace; add the same inactive-workspace
   suppression the reveal path already has
   (`close_recovery_inactive_successor_suppressed`) so a QT close cannot pull the
   active workspace back to the origin once the user has navigated away.

Ideally a single fix treats the QT-close same-app focus redirect as a *window
close to ignore* (no reveal, no cross-workspace refocus) rather than patching
each surface (scroll vs workspace switch) independently.

Any fix must preserve the Evidence-B startup guard from the 2026-07-02 discovery:
ordinary level-0 Ghostty windows visible before services start must not be
treated as overlay churn.

---

## Cluster membership

Belongs to **CR-1 (close-recovery / same-app overlay focus churn)** in
[`20260708-cross-discovery-relevance-clusters.md`](20260708-cross-discovery-relevance-clusters.md);
Variant A also touches **VR-1 (automatic viewport movement)**. This reopens CR-1
under its own stated criterion — "new evidence again shows same-app close/overlay
recovery redirects choosing opposite stable targets": here the overlay
stable-recovery redirect (`close_recovery_overlay_stable_target`) fires against an
**inactive** origin workspace with no active-workspace guard (Variant B), and the
active-workspace reveal loses the destroy-vs-redirect arming race (Variant A).

Related documents:

- [`../completed/20260708-focus-dance-stuck-same-app-recovery.md`](../completed/20260708-focus-dance-stuck-same-app-recovery.md)
  — the reverse-redirect latch (`9ac0b91c`) for the A→B→A oscillation on this same
  `close_recovery_overlay_stable_target` path; Variant B here is a *different*
  failure of that path (cross-workspace refocus), not the oscillation.
- [`../completed/20260706-stable-viewport-on-window-close-recovery.md`](../completed/20260706-stable-viewport-on-window-close-recovery.md)
  — parent that introduced the viewport pins, stable-target redirects,
  preconfirm/overlay phases, and the recent-non-managed-overlay TTL this document
  analyzes.
- [`../completed/20260707-close-last-app-window-stay-on-current-workspace.md`](../completed/20260707-close-last-app-window-stay-on-current-workspace.md)
  and [`../completed/20260706-same-app-focus-switch-reveals-inactive-workspace-window.md`](../completed/20260706-same-app-focus-switch-reveals-inactive-workspace-window.md)
  — compatibility boundaries any fix must not regress: close stays local, and
  *genuine* same-app focus switches must still reveal/follow their target.
- [`20260702-quick-terminal-close-reveals-managed-ghostty-column.md`](20260702-quick-terminal-close-reveals-managed-ghostty-column.md),
  [`../completed/20260615-quick-terminal-close-switches-workspace.md`](../completed/20260615-quick-terminal-close-switches-workspace.md),
  and [`20260615-viewport-reveal-from-unmanaged-overlay-activation.md`](20260615-viewport-reveal-from-unmanaged-overlay-activation.md)
  — earlier quick-terminal / app-owned-overlay roots; Variant A refines the first,
  Variant B is a recurrence of the second's workspace-switch symptom via the newer
  close-recovery machinery.
