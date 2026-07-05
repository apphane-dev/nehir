# Switching an app profile from its menu bar does not reveal the target profile's workspace — the transient-menu close arms focus recovery that reverts the reveal — Discovery

Discovery (2026-07-05). Switching the active browser profile from a menu-bar
control (Helium / any Chromium-family app) raises that profile's existing
window, which lives on a **different Nehir workspace**. Nehir briefly follows
the raise and reveals the target workspace, but the profile-picker **menu
popup closing** arms `window_close_focus_recovery`, anchored to the
*pre-switch* window on the *original* workspace. Recovery then wins the race:
focus and the visible workspace snap back to where the user started, so the
target profile's windows are never shown.

All code citations verified against the main Nehir source tree at
`83c2234b` on 2026-07-05 (`git log -1 --format='%h %s'` → `83c2234b Remove
broken chart`), which is the exact build that produced the capture
(`nehir v83c223` in the trace). Line numbers will drift.

This is the cross-workspace **revert** sibling of the same-workspace
suppression documented in
`discovery/20260622-dock-click-focus-does-not-reveal-column.md` (that one never
reveals because non-managed focus is latched; this one *does* reveal, then
undoes it). It shares its root actor family — the transient-churn defenses in
`handleAppActivation` — with the recent FFM menu-steal work
(`completed/20260705-ffm-steals-focus-at-app-menu-edge.md`,
`completed/20260705-nehir-112-ffm-fixed-dock-occlusion-regression.md`) and the
quick-terminal reveal cases
(`discovery/20260702-quick-terminal-close-reveals-managed-ghostty-column.md`).

---

## TL;DR

- **Symptom.** One display, seven Nehir workspaces sharing one native Space.
  Workspace 2 is visible with Helium window `w1287` focused. The user switches
  the Helium profile from the menu bar; the target profile's windows
  (`w215`, `w1945`) live on workspace 1. Expected: workspace 1 is revealed.
  Actual: the view stays on workspace 2 and focus lands back on `w1287`.
- **Not** the dock-click bug: `nonManaged=false` / `non-managed-focus=false`
  for the whole capture, so the non-managed-focus latch is not involved. And it
  is **not** a plain suppression — the target workspace *is* revealed mid-burst
  (multiple `focus_confirmed` for `w215`/`w1945` on workspace 1 prove
  `handleManagedAppActivation` ran with `activateWorkspaceOnMonitor`). The bug
  is that the reveal is **reverted**.
- **Mechanism.** A profile switch is not a clean single activation. Helium opens
  transient profile-picker **menu popups** (window level 101, e.g. `w1943`
  `parent=215`, plus `w1944`/`w1947`/`w1951`/`w1953`) and raises the target
  profile window on the inactive workspace. Those popups are never tracked
  (`prepare_create_rejected … reason=missing_ax_ref`). When each popup is
  destroyed, `handleWindowDestroyed` takes its untracked-auxiliary fallback and
  calls `armWindowCloseFocusRecoveryForFocusedAppEvent(pid:)`
  (`AXEventHandler.swift:3564`); the menu also reports focused-window=nil for
  the app (`AXFocusedWindowChanged pid=28651 window=nil`), which arms recovery
  again via `armWindowCloseFocusRecoveryForFocusedWindowLossIfNeeded`
  (`AXEventHandler.swift:4635`). Both anchor recovery to
  `confirmedManagedFocusToken` — `w1287` on workspace 2 — and its whole purpose
  is, per the code comment, "so the native successor activation does not pull us
  to another workspace" (`AXEventHandler.swift:4631-4633`). Then
  `shouldSuppressObservedActivationDuringWindowCloseRecovery`
  (`AXEventHandler.swift:1659`) suppresses the app's remaining workspace-1
  activations because `recoveryWorkspaceId != observedEntry.workspaceId`
  (`:1680-1682`), and focus is restored to `w1287` on workspace 2.
- **Root false assumption (shared across the guard family).** These defenses
  assume a *genuine* cross-workspace user switch arrives as a clean
  `workspaceDidActivateApplication` that **makes the target workspace active
  first**, so anything that re-points the same app's focus at an *inactive*
  workspace must be app-internal churn to be undone. That is true for native
  macOS Spaces. It is **false for Nehir's virtual workspaces**: all seven live
  on one native Space (`displaySpacesMode=enabled`, `activeSpaces=1
  knownSpaces=1`), so the OS never pre-activates a Nehir workspace, and a
  legitimate app-driven raise of a window on another Nehir workspace is
  indistinguishable, by the current signals, from a transient popup flap.

---

## Topology and initial state (inlined from the capture)

Single display, seven Nehir workspaces on one native Space:

```
-- Monitor Topology --
ID(displayId: 1) isMain=true hasNotch=true frame=(0.0, 0.0, 2056.0, 1329.0) visibleFrame=(0.0, 0.0, 2056.0, 1290.0) name=Built-in Retina Display
-- SpaceTopology --
mode=enabled activeSpaces=1 knownSpaces=1 windowRecords=7 globalSticky=0 sticky=0 nativeInactive=0
-- WorkspaceManager --
monitors=1 workspaces=7 visibleWorkspaces=1
```

Focus / non-managed state at capture start (and end):

```
-- Focus Targets --
interactionWorkspace=49D9E7F4-BC46-429B-9031-753E87254A94 observedManagedFocus=WindowToken(pid: 28651, windowId: 1287) focusRequest=nil interactionMonitor=ID(displayId: 1) nonManaged=false
-- Reconcile Snapshot --
focused=WindowToken(pid: 28651, windowId: 1287)
non-managed-focus=false
```

`nonManaged=false` throughout — the dock-click / non-managed-latch mechanism is
excluded. `displaySpacesMode=enabled` with `activeSpaces=1 knownSpaces=1`
confirms the seven workspaces are virtual on one native Space.

Helium (`pid 28651`, `bundleId net.imput.helium`) owns three managed windows,
split across two workspaces:

| window | workspace                              | role       | state at start |
|--------|----------------------------------------|------------|----------------|
| w1287  | 49D9E7F4… (**workspace 2, visible**)   | AXWindow   | focused, tiled |
| w215   | D14B2E79… (**workspace 1, inactive**)  | AXWindow   | hidden (workspaceInactive) |
| w1945  | D14B2E79… (workspace 1, inactive)      | AXWindow   | hidden (layoutTransient) |

Workspace 1 (`D14B2E79…`) also holds ChatGPT (`w1815`), Telegram (`w351`), and
two VS Code Insiders windows (`w1573`, `w1582`); workspace 2 (`49D9E7F4…`) holds
only `w1287`. The user starts on workspace 2 looking at profile-A window
`w1287`, and switches to a profile whose windows (`w215`/`w1945`) are on
workspace 1.

---

## What the trace shows (inlined)

### The reveal genuinely happened

Every `focus_confirmed` in the create-focus trace is emitted by exactly one
call site — `handleManagedAppActivation` at `AXEventHandler.swift:2447-2455`,
which reaches it *after* calling `confirmManagedFocus(…,
activateWorkspaceOnMonitor: shouldActivateWorkspace)` with `shouldActivateWorkspace
= !isWorkspaceActive` (`:2408`, `:2420-2426`). So a `focus_confirmed` for a
window on an inactive workspace proves the workspace-activation path ran for it.
The burst is full of them for workspace 1 (`D14B2E79…`):

```
focus_confirmed token=WindowToken(pid: 28651, windowId: 215)  workspace=D14B2E79… source=workspaceDidActivateApplication
…
create_seen window=1945
create_placement_resolved token=…windowId: 1945… workspace=D14B2E79… context_source=cgs_created focused_workspace_source=confirmed_focus
candidate_tracked token=…windowId: 1945… workspace=D14B2E79…
relayout_activated_window token=…windowId: 1945… workspace=D14B2E79…
pending_focus_started request=9 token=…windowId: 1945… workspace=D14B2E79…
focus_confirmed token=…windowId: 1945… workspace=D14B2E79… source=focusedWindowChanged
```

followed by requests 10–20 confirming focus across workspace-1 windows
(`w1287`, `w1582`, `w1573`, `w1815`, `w351`) — i.e. workspace 1 was being
activated/laid out.

### The transient profile-picker menu

Interleaved with the raise, Helium spawns level-101 popup windows that are never
admitted:

```
create_seen window=1943
prepare_create_rejected window=1943 … reason=missing_ax_ref … window_info_level=0  window_info_parent=215 ws_float=true  ws_frame=(524,1277 322x43) … create_context_source=cgs_created
create_seen window=1944
prepare_create_rejected window=1944 … reason=missing_ax_ref … window_info_level=101 window_info_parent=0   ws_float=false ws_frame=(432,40 117x158) …
create_seen window=1947  → prepare_create_rejected … window_info_level=101 …
create_seen window=1951  → prepare_create_rejected … window_info_level=101 …
create_seen window=1953  → prepare_create_rejected … window_info_level=101 …
```

`w1943` is explicitly a child of `w215` (`window_info_parent=215`), a 322×43
strip (the menu-bar affordance); `w1944`/`w1947`/`w1951`/`w1953` are 117×158
level-101 popups (the profile menu). None is tracked. The full-runtime section
records `windowRemoval=6` and `RefreshReason.windowDestroyed: 6` — these popups
being created and destroyed.

### Recovery arms and wins

At `12:44:15Z` the reconcile "Tracing logs" show recovery taking over:

```
#19 event=focus_lease_changed owner=window_close_focus_recovery reason=window_close_focus_recovery … plan=focus=focused=WindowToken(pid: 28651, windowId: 1287),pending=nil,lease=window_close_focus_recovery focus_lease=window_close_focus_recovery window_close_focus_recovery
```

Recovery's preserved focus is **`w1287`** (workspace 2), not the raised
`w215`/`w1945` (workspace 1). The AX notification trace confirms the trigger:

```
-- AX notification trace --
2026-07-05T12:44:15Z ax=AXFocusedWindowChanged pid=28651 window=nil
```

Helium reported *no* focused standard window when the menu dismissed. The
create-focus tail then flips back to workspace 2 and stays:

```
pending_focus_started request=21 token=WindowToken(pid: 28651, windowId: 1287) workspace=49D9E7F4…
activation_source_observed pid=28651 source=workspaceDidActivateApplication
focus_confirmed token=WindowToken(pid: 28651, windowId: 1287) workspace=49D9E7F4… source=workspaceDidActivateApplication
activation_source_observed pid=28651 source=focusedWindowChanged
focus_confirmed token=WindowToken(pid: 28651, windowId: 1287) workspace=49D9E7F4… source=focusedWindowChanged
```

End state: `focused=WindowToken(pid: 28651, windowId: 1287)`, workspace 2
(`49D9E7F4…`) `visible=true`, workspace 1 (`D14B2E79…`) `visible=false` with its
selected node now `w1582` (VS Code), never revealed to the user.

---

## Root cause (with citations)

### 1. Untracked popup destruction arms recovery anchored to the pre-switch window

`handleWindowDestroyed` (`AXEventHandler.swift:3546`). When the destroyed window
has no prepared destroy candidate — true for the untracked level-101 profile
popups (`prepareDestroyCandidate` returns nil) — it takes the fallback branch:

```swift
// AXEventHandler.swift:3559-3565
guard let candidate = prepareDestroyCandidate(windowId: windowId, pidHint: pidHint) else {
    if let destroyedPid = pidHint ?? resolvedToken?.pid {
        // Quick-terminal hide/close can destroy an auxiliary AX element
        // instead of the tracked managed window. Preserve the current
        // workspace before macOS activates a successor app/window.
        armWindowCloseFocusRecoveryForFocusedAppEvent(pid: destroyedPid)
    }
    …
```

`armWindowCloseFocusRecoveryForFocusedAppEvent` (`:1624`) anchors recovery to
whatever `confirmedManagedFocusToken` is for that pid, in that token's
workspace:

```swift
// AXEventHandler.swift:1624-1633
private func armWindowCloseFocusRecoveryForFocusedAppEvent(pid: pid_t) {
    guard let controller,
          let focusedToken = controller.workspaceManager.confirmedManagedFocusToken,
          focusedToken.pid == pid,
          let workspaceId = controller.workspaceManager.workspace(for: focusedToken)
    else { return }
    beginWindowCloseFocusRecovery(in: workspaceId)
}
```

The menu-close also drives `handleMissingFocusedWindow` (the `window=nil`
report), which arms recovery a second time with the same intent — its comment is
the clearest statement of the mechanism:

```swift
// AXEventHandler.swift:4631-4639
// Dropdown/quick-terminal close paths can report focused-window=nil
// without destroying the managed window. Reuse close recovery so the
// native successor activation does not pull us to another workspace.
let focusedTokenBeforeFallback = controller.workspaceManager.confirmedManagedFocusToken
armWindowCloseFocusRecoveryForFocusedWindowLossIfNeeded(
    pid: pid, source: source, preservedToken: focusedTokenBeforeFallback)
```

Because the profile switch's transient churn had (by this point) re-confirmed
`w1287` as the same-pid managed focus, recovery anchors to `w1287` on workspace
2 — the exact window the user was trying to switch *away* from.

### 2. Recovery suppresses the app's other-workspace activations

Once recovery is armed on workspace 2,
`shouldSuppressObservedActivationDuringWindowCloseRecovery`
(`AXEventHandler.swift:1659`) rejects the remaining raises of `w215`/`w1945` on
workspace 1:

```swift
// AXEventHandler.swift:1680-1682
if recoveryWorkspaceId != observedEntry.workspaceId {
    return true
}
```

and, for a same-pid successor that reports `workspaceDidActivateApplication`, the
`:1673-1678` branch (`suppressedActivationPid == observedEntry.pid`,
`observedEntry.token != preservedToken`) also suppresses. The net effect is that
the target-workspace raise cannot re-take the interaction anchor; workspace 2 is
restored.

### 3. Why the reveal was fragile enough to lose the race

Even before recovery, the same-app cross-workspace raise is treated as suspect.
`shouldSuppressSameAppInactiveWorkspaceActivationBeforeCloseRecovery`
(`AXEventHandler.swift:1844`) suppresses a `.unrelatedNoRequest` activation of a
same-pid window on an inactive workspace whenever the active workspace already
holds same-pid confirmed managed focus:

```swift
// AXEventHandler.swift:1867-1875
// Same-pid confirmed focus on the active workspace anchors suppression:
// the user is actively working with another window of the same app.
if let focusedToken = controller.workspaceManager.confirmedManagedFocusToken,
   focusedToken != observedEntry.token,
   focusedToken.pid == observedEntry.pid,
   let focusedEntry = controller.workspaceManager.entry(for: focusedToken),
   let focusedMonitorId = controller.workspaceManager.monitorId(for: focusedEntry.workspaceId),
   controller.workspaceManager.activeWorkspace(on: focusedMonitorId)?.id == focusedEntry.workspaceId
{
    return true
}
```

and its comment (`:1877-1887`) states the false assumption in full: "A genuine
user switch arrives as `workspaceDidActivateApplication` (which makes the
workspace active first)…". For Nehir's virtual workspaces the OS never makes the
target workspace active first, so this is precisely the case the comment thinks
cannot happen. This guard did not fire on every event in the capture (the raise
did reveal for a moment), but it is why the reveal has no protection of its own
and can be cleanly reverted by recovery.

`shouldSuppressManagedActivationWhileNonManagedFocusAnchored`
(`:1696`) is **not** implicated here: `isNonManagedFocusActive` is false, and
`hasVisibleSamePidOverlayWindow` (`:1723`) only recognizes overlays whose
window-rule decision is `ghosttyQuickTerminalOverlay`, `cleanShotRecordingOverlay`,
or `systemTextInputPanel` (`isKnownSamePidOverlayWindow`) — a Helium profile
popup is none of these, so that predicate returns false. Ruling it out isolates
the cause to the recovery arming + the inactive-workspace suppression above.

---

## The conflation, stated plainly

`window_close_focus_recovery` exists to defend a real invariant: when a
*transient overlay* of an app (Ghostty quick-terminal, a dropdown, a system
input panel) closes and macOS momentarily re-points focus at the app's other
window or a successor app, the user's workspace should not be dragged around.

A browser **profile switch** looks identical at the AX layer — an untracked
same-pid popup is created and destroyed, and focused-window briefly goes nil —
but the *intent* is the opposite: the user deliberately asked to bring the other
profile forward, and its window legitimately lives on another Nehir workspace.
Recovery, anchored to the pre-switch window, cannot tell these apart and undoes
the switch. The single missing distinction is: **did the same-pid activity, in
the same burst, raise a real standard window (not a popup) on another Nehir
workspace as a result of user action?** If so, that raise is the intent and
recovery should yield to it, not overwrite it.

---

## Reproduction

1. One display, Nehir virtual workspaces enabled (`displaySpacesMode=enabled`),
   at least two workspaces.
2. A Chromium-family browser with menu-bar / in-app profile switching (Helium
   here; Chrome/Brave/Edge "switch person" behave the same). Open two profiles
   whose windows Nehir has tiled onto **different** workspaces.
3. Focus the profile-A window on the visible workspace.
4. Use the app's own control (menu bar item, or the profile avatar menu) to
   switch to profile B, whose window is on the other workspace.
5. Expected: the workspace holding profile B's window is revealed. Actual: a
   brief flicker toward it, then the view returns to profile A's workspace;
   profile B stays hidden.

Trace signature (create-focus + reconcile): `focus_confirmed` for the target
window on the inactive workspace, several level-101
`prepare_create_rejected … reason=missing_ax_ref` popup records, an
`AXFocusedWindowChanged … window=nil` for the app, a `focus_lease_changed
owner=window_close_focus_recovery` whose `focused=` is the *pre-switch* window,
and a final `focus_confirmed` back on the original workspace.

---

## Fix options

### A. Let a completed same-burst cross-workspace raise win over recovery (recommended)

Track, per pid, the most recent user-driven raise of a **standard** managed
window on a workspace *other* than the current interaction workspace (recorded
where `handleManagedAppActivation` confirms focus with
`activateWorkspaceOnMonitor == true`). When
`armWindowCloseFocusRecoveryForFocusedAppEvent` / `…ForFocusedWindowLossIfNeeded`
is about to anchor recovery to a same-pid token, if such a raise happened within
a short window (a few hundred ms) and targeted a different workspace, either skip
arming or anchor recovery to the **raised** window's workspace instead of the
pre-switch one. This keeps overlay-close protection intact (no such raise for a
quick-terminal toggle) while letting a genuine profile switch stand.

### B. Distinguish popup-close from managed-window-close at the arming site

`armWindowCloseFocusRecoveryForFocusedAppEvent` fires on the destruction of *any*
untracked same-pid auxiliary window. Narrow it: only arm when the destroyed
window plausibly *was* the app's key surface (e.g. a level-0 standard window, or
one whose frame overlapped the confirmed managed window), not for level ≠ 0 menu
popups (`window_info_level=101` in the capture). A menu popup closing is normal
and should not, by itself, trigger workspace-preserving recovery.

### C. Widen the "genuine user switch" signal for virtual workspaces

`shouldSuppressSameAppInactiveWorkspaceActivationBeforeCloseRecovery`'s comment
assumes the OS pre-activates the target workspace. Under
`displaySpacesMode=enabled` that never happens, so the same-pid-active-workspace
anchor (`:1867-1875`) should additionally consult the recent-app-activation
signal already recorded by `recordRecentAppActivation`
(`AXEventHandler.swift:1917`, added for the Slack admission fix —
`completed/20260703-fix-unrequested-admission-guard-user-activation-exemption.md`):
a `workspaceDidActivateApplication` for this pid moments earlier means the user
just invoked the app, so a resulting raise on another virtual workspace is
intent, not churn.

**Recommendation:** A is the most targeted (it defends the exact invariant —
"a real cross-workspace raise the user just caused") without weakening
overlay-close recovery, which is the property most likely to regress. B is a
cheap complementary narrowing. C generalizes the fix to the suppression guard
but touches a hotter predicate.

---

## Regressions to guard against if we change this

The recovery + inactive-workspace suppression machinery is load-bearing for
several already-fixed bugs. Any loosening must be verified against them:

1. **Quick-terminal close must not reveal/steal a workspace.**
   `discovery/20260702-quick-terminal-close-reveals-managed-ghostty-column.md`
   and `discovery/20260617-move-mouse-to-focused-warps-across-monitors-on-quick-terminal-close.md`.
   The `window=nil` → recovery path (`:4631-4639`) exists precisely so a
   quick-terminal dismissal does not pull the view to the managed sibling's
   column/workspace. Fix A survives this because a quick-terminal toggle
   performs **no** cross-workspace standard-window raise; fix B must keep arming
   for the quick-terminal case (its destroyed element is not a level-101 menu).
   Add a regression test: quick-terminal open→close with the managed window on
   another workspace must **not** reveal it.

2. **App context-menu / menu-bar edge must not steal focus (FFM).**
   `completed/20260705-ffm-steals-focus-at-app-menu-edge.md` and
   `completed/20260705-nehir-112-ffm-fixed-dock-occlusion-regression.md`. Those
   fixes classify AX-less transient menu popups as unmanaged so they never
   become focus/activation targets. Fix B's "popup vs key window" test must use
   the *same* classification, or the two can disagree (a popup treated as a key
   window here, but unmanaged there).

3. **PiP / sticky cross-monitor bounce.**
   `discovery/20260705-nehir-108-pip-cross-monitor-bounce-sticky-not-globalsticky.md`
   and `shouldSuppressHiddenInactiveStickyActivation` (`:1817`). A PiP surface
   re-reporting activation after Nehir parks it must still be suppressed;
   widening the "raise on another workspace is intent" rule (fix A/C) must
   exclude sticky-sourced windows so an auto-sticky PiP does not yank the view
   to its workspace. Gate fix A on `!hasStickyWindowSource`.

4. **Dock/Cmd-Tab to a managed window must still reveal — and not double-reveal.**
   `discovery/20260622-dock-click-focus-does-not-reveal-column.md`. That is the
   *wanted* reveal on the same axis; a fix here must not suppress it, and must
   not cause a second, competing reveal (the "successor activation" recovery was
   meant to prevent). Fix A's short time-window and standard-window requirement
   keep it from firing on ordinary dock switches that don't spawn a popup burst.

5. **Rapid focus-revert races / lease timing.**
   `discovery/20260616-omniwm-317-rapid-focus-revert-race.md` and
   `discovery/20260616-omniwm-379-focus-revert-grace-period.md`. Introducing a
   "recent cross-workspace raise" TTL (fix A) adds another timing window that can
   interact with the `native_app_switch` lease (0.4s, `:1947-1952`) and the
   revert grace period. Pick the TTL to be shorter than, and checked against,
   those windows.

6. **Multi-window apps where the user is deliberately working across workspaces.**
   The same-pid anchor at `:1867-1875` deliberately keeps you put when you have
   two windows of one app on two workspaces and the app re-focuses the other
   one. Fix A/C must only override that anchor for a raise that is *both*
   user-initiated (recent `workspaceDidActivateApplication`) *and* accompanied
   by the app's own transient-popup burst — not for passive same-app focus
   churn, or the anchor's original purpose regresses.

---

## Files implicated

- `Sources/Nehir/Core/Controller/AXEventHandler.swift` —
  `handleWindowDestroyed` untracked-auxiliary fallback (`:3559-3565`),
  `armWindowCloseFocusRecoveryForFocusedAppEvent` (`:1624`),
  `armWindowCloseFocusRecoveryForFocusedWindowLossIfNeeded` (`:1586`) and the
  `window=nil` arm site (`:4631-4639`),
  `shouldSuppressObservedActivationDuringWindowCloseRecovery` (`:1659`),
  `shouldSuppressSameAppInactiveWorkspaceActivationBeforeCloseRecovery`
  (`:1844`), `recordRecentAppActivation` (`:1917`),
  `handleManagedAppActivation` reveal confirm (`:2408-2455`).
- `Sources/Nehir/Core/Workspace/WorkspaceManager.swift` — `confirmManagedFocus`
  (`:1294`) and its `activateWorkspaceOnMonitor` reveal.
- `Tests/NehirTests/` — cross-workspace profile-switch reveal survives menu
  close (new); plus the six regression cases above.
- `.changeset/<timestamp>-profile-switch-reveals-target-workspace.md` — `patch`
  (e.g. "Switching a browser profile now reveals the workspace holding the
  target profile's window").
