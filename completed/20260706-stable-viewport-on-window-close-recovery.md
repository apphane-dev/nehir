# Stable Viewport on Window-Close Focus Recovery

**Status: LANDED (2026-07-06).** Shipped on `main` in commit
`Keep viewport stable after same-app window close`
(changeset: `nehir` patch — "Prevent close recovery from scrolling to offscreen
same-app windows"). Verified in the real app across multiple close repros; the
viewport no longer jumps when a same-app window (canonically Ghostty's Quick
Terminal) closes.

## What actually landed (vs. the plan below)

The plan's two mechanisms shipped, but real-app trace testing surfaced a second
race that required more than the original design. The landed version, all in
`Sources/Nehir/Core/Controller/AXEventHandler.swift` unless noted:

1. **Viewport pin during recovery** — an active close-recovery lease forces
   `preserveActiveViewport = true` in the focus-confirm path so the recovery's
   opening confirm never reveals/scrolls (`closeRecoveryPin`).
2. **Stable-target focus redirect** — during recovery, focus is redirected to the
   preserved anchor, else the tile nearest the current viewport
   (`stableRecoveryFocusTarget` / `redirectToStableRecoveryFocusIfNeeded`;
   nearest-tile lookup added to `NiriLayoutEngine+ViewportCommands.swift`).
3. **Pre-arm leading-activation handling** — macOS often reports focus on a
   parked same-app successor *before* the close signal arrives, so the lease has
   not armed yet. Covered by: a same-app pre-confirm stale-focus suppression and
   redirect (`shouldSuppressSameAppParkedFocusBeforeConfirm`,
   `redirectToStableSameAppRecoveryFocusIfNeeded` with preconfirm/overlay
   phases), a 120ms defer-and-retry of the ambiguous pre-close activation
   (`shouldDeferSameAppActiveNativeActivationBeforeCloseRecovery`, restricted to
   `.unrelatedNoRequest`), and pre-lease viewport pins keyed on a recency window.
4. **Recency signals** — a per-pid "recent non-managed (overlay) focus" TTL map
   primed at every `enterNonManagedFocus` site, plus the existing "recent
   same-app window close" map, unified behind
   `isWithinSameAppCloseRecoveryWindow(pid:)`. Parked follow-focus is suppressed
   during this window so it doesn't fight the recovery.
5. **Focus-request reason tracing** — a `FocusWindowReason` enum threaded through
   `WMController.focusWindow(...)` and the deferred-focus path (touches several
   controller files) so runtime traces attribute which path initiated a focus
   request.

A post-landing consolidation pass (code review follow-up) removed the accreted
redundancy: the defer was restricted to `.unrelatedNoRequest` (was also
swallowing `.conflictsWithPendingRequest`); the parked-follow suppression was
extracted to the documented `isWithinSameAppCloseRecoveryWindow` predicate; the
two redirect helpers were unified behind
`redirectToStableSameAppRecoveryFocusIfNeeded(phase:)`; and the overlapping
viewport pins were factored onto a shared `leaseInactive` precondition. All
runtime-trace `reason=` records were kept observable.

The landed commit also updated `Tests/NehirTests/RefreshRoutingTests.swift` to
keep the native-fullscreen same-window-id refresh test deterministic under
WindowServer lookup (a signature/adjustment from the enum threading), and carried
unrelated dev-task tooling changes committed alongside.

Follow-up worth tracking as its own discovery: the landed logic is broad — many
overlapping recency-keyed signals gate the pins/redirects. If a legitimate reveal
is ever wrongly suppressed shortly after a same-app close, revisit the union of
triggers.

Follow-ups completed:

- [`completed/20260707-close-last-app-window-stay-on-current-workspace.md`](20260707-close-last-app-window-stay-on-current-workspace.md)
  addresses an ordering hole left by this work: an inactive-workspace same-app
  successor can be reported before the tracked close/removal marker, so the
  close-recovery window is not yet reliably active. The shipped policy extends
  the same "close is local" rule to the case where the current workspace has no
  same-app survivor, and even to an empty workspace.
- [`completed/20260708-focus-dance-stuck-same-app-recovery.md`](20260708-focus-dance-stuck-same-app-recovery.md)
  addresses a later oscillation hole in this work: overlay-phase stable-target
  redirects could bounce A → B → A while `recentNonManaged=true` remained active.
  Commit `9ac0b91c` added a short reverse-redirect latch and the
  `close_recovery_reverse_redirect_skipped` trace marker.

---

## Overview

When a same-app window closes on the active workspace (canonical case: closing
Ghostty's Quick Terminal), macOS moves native focus to another window of the
same app — often one sitting far away on the layout strip. Nehir's
`windowCloseFocusRecovery` honors that macOS-chosen successor and, on its first
focus-confirm, runs `scrollToReveal`, panning the niri viewport a large distance
to bring the far window on-screen.

The user expectation is **no viewport movement at all** when a window closes and
focus recovers to another window already on the active workspace. This matches
original niri, which is purely spatial and app-agnostic: on removing a column it
either preserves the current view position (a non-active column was removed) or
activates the spatially **adjacent** column — it never scrolls across the strip
to reach a same-app window.

This plan makes close-recovery honor a **maximum-stable-viewport** policy:

1. **Viewport layer** — while a close-recovery lease is active on the active
   workspace, pin the viewport (force `preserveActiveViewport = true`) so the
   recovery's opening focus-confirm never reveals/scrolls.
2. **Focus-target layer** — instead of following macOS's same-app successor,
   retarget Nehir's managed focus/selection to the spatially **stable** column
   (the preserved anchor, else the column nearest the current viewport), and
   re-issue a managed focus request so native macOS focus follows Nehir's choice
   rather than the reverse.

End state: border indicator, Nehir selection, viewport offset, and macOS native
focus all agree, and the viewport does not move on close.

## Root-cause evidence (self-contained)

**Reproduction topology.** Two displays. Display 1 active workspace holds several
Ghostty windows tiled in a niri strip (6+ columns). A Ghostty Quick Terminal
overlay is open over that workspace. The user closes the Quick Terminal.

**Observed close sequence** (Ghostty pid `82494`, active workspace on display 1):

- The Quick Terminal surface (`window 5915`) is destroyed; the app's AX window
  set drops from `[5915, 6872, 6599]` to `[6872, 6599]`.
- Nehir arms `windowCloseFocusRecovery` and takes a focus lease
  (`owner=window_close_focus_recovery`).
- macOS re-focuses another Ghostty window, `window 6872`, which sits at
  **column index 3** — far from where the overlay was and clipped off the right
  edge of the viewport (`visibility=clipped(maximum)`, `viewStart≈1977`,
  nearest snap `≈2943:rightEdge`).
- The recovery's **first** focus-confirm computes `preserveActiveViewport=false`,
  so `scrollToReveal` fires (`didReveal=true`) and animates the viewport
  `currentViewStart 1977 → targetViewStart 3452` — a ~1475px jump.
- Subsequent focus-confirms on the same window have `wasAlreadyConfirmedFocus=true`
  → `preserveActiveViewport=true` → reveal skipped. So the unwanted scroll is
  produced solely by the recovery's opening confirm.

**Why the existing inactive-workspace guard does not catch it.**
`shouldSuppressSameAppInactiveWorkspaceActivationBeforeCloseRecovery`
(`Sources/Nehir/Core/Controller/AXEventHandler.swift`) only suppresses
activations whose target is on an **inactive** workspace: it bails out via
`guard !isWorkspaceActive else { return false }`. Here the successor window 6872
is on the **active** workspace, so `isWorkspaceActive=true` and the guard
correctly returns false. The damage is a within-workspace viewport pan, not a
workspace switch, so that guard is structurally the wrong layer.

**niri reference behavior.** In niri's `remove_column_by_idx`
(`src/layout/scrolling.rs` in the upstream niri source tree), removal branches
only on the removed column index relative to the active column:
`column_idx < active_column_idx` → `active_column_idx -= 1` and preserve the
current position; active column removed → activate the previous column with its
stored offset, else `activate_column(min(active_column_idx, len-1))`. It always
selects the spatially adjacent column and never scrolls across the strip, and it
has no concept of "app", so it never seeks a same-app window elsewhere.

## Context (source-backed)

- **Scroll decision point** —
  `Sources/Nehir/Core/Controller/AXEventHandler.swift`, focus-confirm path:
  ```swift
  let preserveActiveViewport = state.viewOffsetPixels.isGesture
      || isSpringInFlight
      || (wasAlreadyConfirmedFocus && source == .focusedWindowChanged)
  ```
  followed by the `scrollToReveal` block (the `ax_focus_confirm_reveal_candidate`
  / `_result` / `_skipped` trace records). On the recovery's first confirm all
  three disjuncts are false → reveal fires.
- **Recovery machinery** (`AXEventHandler.swift`):
  - `WindowCloseFocusRecoveryContext` carries `workspaceId`,
    `suppressedActivationPid`, and `preservedToken` — the window the user was on
    before the close/overlay. `preservedToken` is the natural stable anchor.
  - `activeWindowCloseFocusRecoveryContext()` — live lease accessor (already used
    by `shouldSuppressObservedActivationDuringWindowCloseRecovery`).
  - `beginWindowCloseFocusRecovery(in:suppressingPid:preservedToken:)`,
    `armWindowCloseFocusRecoveryForFocusedWindowLossIfNeeded(...)`,
    `armWindowCloseFocusRecoveryForFocusedAppEvent(...)`,
    `endWindowCloseFocusRecovery(matching:)`.
  - Lease duration constant `windowCloseFocusRecoveryDuration = 0.6s`.
  - Accepted-activation site: after the suppression guards, the switch on
    `requestDisposition` calls `endWindowCloseFocusRecovery(matching: wsId)` then
    `handleManagedAppActivation(entry:...)`.
- **Layout/selection helpers** —
  `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+ViewportCommands.swift`:
  `scrollToReveal`, `syncViewportSelectionToActiveColumn`,
  `nearestVisibleColumnIndex(to:viewportOffset:context:)`.

## Development Approach

- **Testing approach**: deferred by design (matches the repo AGENTS.md rule
  "wait for user-confirmed fix before editing tests"). Implement first; validate
  against the real app repro and runtime trace. **Do not add or modify tests
  until the user confirms the behavior in their real repro.** Tests become a
  dedicated final task, gated on that confirmation.
- Small, focused changes; each task independently verifiable via runtime trace.
- Preserve the existing inactive-workspace suppression behavior; this plan only
  addresses the active-workspace successor-focus path that guard does not cover.
- Backward compatibility: outside an active close-recovery lease,
  `preserveActiveViewport` and focus-selection behavior are unchanged.
- **Fast gate between steps**: project build (`swift build` or the repo's build
  task). **Full suite once at the end** (see final task), gated on user sign-off
  for any test edits.

## Do-not-touch fences

- Do **not** modify `shouldSuppressSameAppInactiveWorkspaceActivationBeforeCloseRecovery`
  or the other inactive-workspace suppression guards — they own the
  cross-workspace successor case and are out of scope.
- Do **not** widen `windowCloseFocusRecoveryDuration` or the lease lifecycle.
- Do **not** edit tests until the user confirms the fix (AGENTS.md).

## Solution Overview

Two coordinated changes, both scoped to an **active close-recovery lease** on the
**active workspace**:

1. **Pin the viewport** in the focus-confirm path: when
   `activeWindowCloseFocusRecoveryContext()?.workspaceId == wsId`, treat
   `preserveActiveViewport = true`. This alone guarantees the viewport never
   scrolls during recovery (the reveal takes the `_skipped` branch).
2. **Redirect the recovery focus** to a spatially stable column: rather than
   confirming macOS's successor window, compute the stable target
   (`preservedToken` if still managed and on the active workspace, else the
   column nearest `currentViewStart`) and issue a managed focus request to it, so
   native focus follows Nehir instead of the reverse.

Change #1 is the safety net (viewport can never move). Change #2 restores
niri-like coherence so the border/selection matches the pinned view.

## Technical Details

- **Lease scoping**: reuse `activeWindowCloseFocusRecoveryContext()` and its
  `workspaceId` / `preservedToken`. Do not extend the lease lifetime.
- **Stable target selection** (new private helper): return the token to focus
  during recovery, in priority order:
  1. `context.preservedToken` if non-nil, still managed, and on the lease
     workspace;
  2. else the active-tile token of the column nearest `currentViewStart`
     (via a `nearestVisibleColumnIndex`-style lookup);
  3. else nil → fall back to current behavior (never worse than today).
- **Re-focus mechanism**: issue the stable focus through the same managed focus
  request path `handleManagedAppActivation` already uses, so the follow-up reveal
  is a no-op (target already the anchored, on-screen column) and native focus
  converges.
- **Ordering**: the redirect must run *after*
  `shouldSuppressObservedActivationDuringWindowCloseRecovery` so suppressed churn
  is still dropped; only the accepted confirm is retargeted.

## Implementation Steps

### Task 1: Pin viewport during active close-recovery lease

**Files:**
- Modify: `Sources/Nehir/Core/Controller/AXEventHandler.swift`

- [ ] in the focus-confirm path, extend the `preserveActiveViewport` computation:
  when `activeWindowCloseFocusRecoveryContext()?.workspaceId == wsId`, force it
  true.
- [ ] add a runtime-trace detail (e.g. `closeRecoveryPin=true`) in the
  `ax_focus_confirm_before_activate` record so the pin is observable.
- [ ] confirm the `ax_focus_confirm_reveal_skipped` branch is taken during
  recovery instead of `scrollToReveal`.
- [ ] fast gate: build must succeed.
- [ ] validate in real app: close Quick Terminal with a far same-app window on
  the strip; capture a runtime trace; confirm no `scroll_animation_start` and
  `currentViewStart` unchanged across the recovery confirms. (tests deferred.)

### Task 2: Compute the spatially-stable recovery focus target

**Files:**
- Modify: `Sources/Nehir/Core/Controller/AXEventHandler.swift`
- Modify (if needed): `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+ViewportCommands.swift`

- [ ] add a private helper `stableRecoveryFocusToken(...)` returning: preserved
  token (if still managed + on the lease workspace), else nearest-to-`viewStart`
  column's active-tile token, else nil.
- [ ] if the engine lacks a reusable "column nearest a viewport offset"
  accessor, expose a thin one alongside `nearestVisibleColumnIndex`.
- [ ] add a runtime-trace record (`close_recovery_stable_target`) logging chosen
  token + reason (preserved / nearest / fallback).
- [ ] fast gate: build must succeed. (tests deferred.)

### Task 3: Redirect recovery confirm to the stable target

**Files:**
- Modify: `Sources/Nehir/Core/Controller/AXEventHandler.swift`

- [ ] at the accepted-activation site during recovery (after the suppression
  guard, before/within `handleManagedAppActivation`), when a stable target exists
  and differs from the observed successor token, issue a managed focus request to
  the stable target instead of confirming the successor.
- [ ] end the lease appropriately (`endWindowCloseFocusRecovery(matching: wsId)`)
  once the stable target is confirmed, so it doesn't linger.
- [ ] guard against ping-pong: if the stable target equals the observed token,
  take the normal path; only redirect on a genuine mismatch.
- [ ] fast gate: build must succeed.
- [ ] validate in real app: after close, border/selection sit on the stable
  column, native focus converges there, viewport unchanged; trace shows
  `close_recovery_stable_target` and no scroll.

### Task 4: Regression pass on adjacent scenarios (trace-based)

- [ ] closing a non-focused managed window on the active workspace → no scroll,
  focus unchanged.
- [ ] closing the focused managed window (not an overlay) → focus moves to the
  spatially adjacent column, minimal/no scroll, not a far jump.
- [ ] closing a window whose recovery target is on an inactive workspace →
  existing inactive-workspace suppression preserved (no workspace switch).
- [ ] genuine user Cmd-Tab / Dock switch (no lease active) → still reveals
  normally, unchanged behavior.

### Task 5: Verify acceptance criteria

- [ ] closing the Quick Terminal produces zero viewport movement.
- [ ] border, selection, viewport, and macOS native focus all agree post-close.
- [ ] no new focus ping-pong or lease leaks in traces.
- [ ] full build clean; run the full test suite once (no test edits yet).

### Task 6: [Deferred — only after user confirms] Tests, changeset, housekeep

**Files:**
- Create/Modify: unit tests alongside `Tests/NehirTests/...` for the touched code
- Changeset via `mise run changeset patch "..."`

- [ ] (gated on user sign-off) unit test: `preserveActiveViewport` forced true
  under an active close-recovery lease.
- [ ] unit test: `stableRecoveryFocusToken` prefers preserved, else nearest,
  else fallback; never the far successor.
- [ ] run full suite — must pass.
- [ ] add a Changesets fragment (`patch`) summarizing the user-visible fix;
  reference the nehir issue number if one is opened.
- [ ] move this plan to `completed/`.

## Post-Completion

**Manual verification (required before Task 6):** user confirms the Quick
Terminal close now feels stable (no scroll, focus lands sensibly). Tests are
intentionally deferred until this confirmation.

**Note on fighting macOS:** we cannot prevent macOS from emitting its app-scoped
successor focus; Change #2 wins by re-issuing our own managed focus so native
focus converges to Nehir's spatial choice. Watch traces for residual macOS
re-focus churn within the 0.6s lease window.
