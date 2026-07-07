# Same-app focus switch to a window on an inactive workspace now reveals it — Completed

Shipped 2026-07-06. Switching focus within one application to **another of its
own windows** that Nehir had parked on an **inactive** Nehir workspace did
nothing visible: the target window stayed parked off-screen and the view stayed
on the origin window. The user had to bring the window forward by hand.

The canonical repro is a browser profile switch (Helium/Chromium "switch
profile" raises another of the app's windows that lives on a different
workspace), but the essence is app-agnostic: **any same-app focus switch to a
window on a non-visible workspace.**

Superseded the earlier profile-switch discovery/plan notes, which were removed
because they were written from runtime traces that recorded Nehir's *intended*
focus model rather than the observed macOS state (see "Diagnostics" below).
Verified against the main Nehir source tree; landed on `main` via branch
`fix/profile-switch-follow-front-window`.

Follow-up: [`planned/20260707-close-last-app-window-stay-on-current-workspace.md`](../planned/20260707-close-last-app-window-stay-on-current-workspace.md)
handles the remaining close-successor race where macOS reports another same-app
window on a different Nehir workspace before the tracked close/removal marker is
available. That follow-up preserves this document's deliberate same-app
focus-switch behavior: real same-app switches still reveal the target workspace;
window close must stay local, even if the current workspace becomes empty.

## Root cause — three layers, all fixed

Trustworthy traces (added first, see below) showed three independent obstacles,
each of which had to be removed before the switch worked.

### 1. A guard suppressed the reveal (the main cause)

`shouldSuppressSameAppInactiveWorkspaceActivationBeforeCloseRecovery`
(`Sources/Nehir/Core/Controller/AXEventHandler.swift`) — a guard Nehir added on
top of OmniWM, **which OmniWM does not have** (confirmed by comparing
`Sources/OmniWM/Core/Controller/AXEventHandler.swift` in the upstream checkout;
OmniWM reveals the target correctly) — suppressed the activation of a same-app
window on an inactive workspace whenever another same-app window held focus on
the active workspace. Its comment assumed "a genuine switch arrives as
`workspaceDidActivateApplication` which makes the target workspace active
first" — **false for Nehir's virtual workspaces**, where the OS never
pre-activates a Nehir workspace.

**Fix (close-only):** the guard exists only to absorb the successor-focus churn
macOS emits when one of the app's windows **closes** (it re-focuses another of
the app's windows, possibly on an inactive workspace). Gate it on a *recent
same-app window close* — `recentSameAppWindowCloseByPid`, recorded on window
destroy in `handleRemoved(token:)` and `handleWindowDestroyed(...)`. An ordinary
same-app focus switch with no close is no longer suppressed and reveals its
workspace. This deliberately **removes the previous broad behaviour** of
suppressing any same-app cross/inactive-workspace focus churn (see Regressions).

### 2. The normal reveal path is unreliable — follow the parked focus

Even past the guard, Nehir's *active* workspace pointer and the actually
*visible* workspace can diverge during the churn, so
`shouldActivateWorkspace = !isWorkspaceActive` (in `handleManagedAppActivation`)
stays `false` and no switch is issued (the model believes the workspace is
already active while the window is physically parked).

**Fix:** after a managed focus confirmation, if the confirmed window is a
non-sticky **tiling** window that is **physically off-screen** — judged by its
live AX frame vs the monitors' visible area (`isEntryOnScreen`), the trustworthy
signal, *not* the model's visibility flag — follow it:
`workspaceNavigationHandler.activateWorkspace(workspaceId, focusing: token)`,
which switches to the workspace **and** scrolls to the window. Deduplicated per
token for a short grace so the re-confirmation `activateWorkspace` triggers does
not loop before the window unparks (`recentParkedFocusFollowByToken`).

### 3. The follow could bounce back — a short hold

Immediately after the follow, a confirm of another of the app's windows (the
still-on-screen origin) could reveal *its* workspace and bounce the view back;
which window's confirm arrived last was non-deterministic.

**Fix:** a short per-pid hold on the just-revealed workspace
(`parkedFollowHoldByPid`, ~1.2 s). While it is active, `shouldActivateWorkspace`
is forced `false` for other windows of the same pid that would switch to a
different workspace (`bounceBlocked` in `handleManagedAppActivation`).

## Diagnostics (added, kept)

Runtime focus traces previously logged only `focus_confirmed` / `focused=` —
Nehir's *intent* — which read as success while nothing reached the screen. Added
records that expose the model↔reality boundary, and which were essential to
finding the real cause after several fixes aimed at phantoms:

- `focus_reality` (beside every `focus_confirmed`): `observed_focused` (did macOS
  make it key), `observed_visible`, `on_screen` (live frame overlaps a monitor),
  `ws_visible`, `app_frontmost`, `app_focused_window`.
- `reveal_decision` (at focus-confirm): `target_ws`, `is_ws_active`,
  `should_activate`, `target_ws_visible`, `source` — the model→screen decision.
- `follow_focus_to_parked_window` — the layer-2 decision.
- `reeval_workspace_changed` — tripwire for window-rule reevaluation moving an
  already-placed window between workspaces (a suspected churn source; measured at
  zero, kept as a regression tripwire).

## Tests

In `Tests/NehirTests/` (main Nehir repo):

- The close-only guard change flipped the intent of the existing same-app
  suppression tests, which previously asserted suppression **without** a close.
  Rewritten to simulate a same-app window close first (so they exercise the
  guard's real purpose): `focusedWindowChangedOnEmptyActiveWorkspaceSuppresses
  InactiveWorkspaceActivation`, `unmanagedSameAppFocusSuppressesInactiveWorkspace
  Activation`, `unmanagedSameAppFocusSuppressesCurrentWorkspaceActivation`, and
  `closingFocusedWindowSuppressesCrossWorkspaceSameAppActivation` (the last uses
  a stateful focused-window provider: the focused window before the close, the
  cross-workspace successor after).
- `isEntryOnScreen` resolves the frame through the injectable `observedFrame`
  chain, so follow-focus behaviour is mockable via the existing frame providers.

Live-verified in both shapes (target window was / was not the selected column of
its workspace) — uniform switch + scroll, no bounce; quick-terminal close does
not steal the view (close-successor suppression preserved).

## Regressions removed / to watch

- **Removed on purpose:** the guard no longer suppresses arbitrary same-app
  cross/inactive-workspace focus churn — only close-successor churn. An app that
  emits `focusedWindowChanged` to a window on another workspace (without a close)
  now follows to that workspace. Accepted trade-off; no visible regressions
  observed. If a background app is seen stealing the view, narrow layer 1
  further (e.g. also require the app to be frontmost).
- Quick-terminal close must not reveal/steal a workspace — still covered by the
  close-successor path (`discovery/20260702-quick-terminal-close-reveals-managed-ghostty-column.md`).
- Sticky/PiP windows are excluded from follow-focus (`hasStickyWindowSource`).
- Floating windows are excluded from follow-focus (no niri node to select).

## Follow-ups (not blocking)

- The active-vs-visible workspace pointer divergence (layer 2's root) is worked
  around, not fixed; worth a dedicated investigation if it surfaces elsewhere.
- The pre-existing `RefreshRoutingTests.nativeFullscreenSpaceChangeRetainsMulti
  ColumnNiriOrderWithSameWindowId` failure is unrelated and predates this work.
