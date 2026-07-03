# Quick-terminal close can still reveal the managed Ghostty column

Status: discovery + implementation plan. Verified against `main` commit `61a67ba4`
(`nehir v61a67b*` in the captures) on 2026-07-02.

A rare regression remains in the quick-terminal coexistence fixes: when Ghostty's
Quick Terminal is dismissed, Nehir can still interpret Ghostty's post-close AX
focus churn as focus on the regular managed Ghostty window, then reveal that
managed window's parked column. The visible symptom is a same-workspace viewport
scroll to Ghostty even though the user only closed the overlay.

All runtime evidence below is inlined. This document does not depend on any
machine-local trace file surviving.

---

## Evidence A — quick-terminal close reveals parked Ghostty

Capture metadata: Nehir build `v61a67b*`, capture window
`2026-07-02T12:58:34Z` to `2026-07-02T12:58:37Z`.

Topology and start state:

```text
focusFollowsMouse=false moveMouseToFocusedWindow=false mouseWarpEnabled=false
interactionWorkspace=EA1BE709-8127-4235-A4D0-8DBC31C9D89F
interactionMonitor=ID(displayId: 1)
confirmed/observed managed focus=WindowToken(pid: 42984, windowId: 19419)  // Teams
workspace 1 visible=true columns=7 activeColumnIndex=0
currentOffset=-6.0 targetOffset=-6.0 currentViewStart=-6.0 targetViewStart=-6.0
```

Relevant managed windows on workspace 1 at capture start:

```text
WindowToken(pid: 42984, windowId: 19419) bundleId=com.microsoft.teams2
  phase=tiled hidden=nil liveAXFrame={{14.0, 7.0}, {847.0, 1045.0}}

WindowToken(pid: 92251, windowId: 20978) bundleId=com.mitchellh.ghostty
  phase=offscreen hidden=layoutTransient(right)
  liveAXFrame={{1727.0, 7.0}, {847.0, 1045.0}}
```

The quick-terminal overlay is detected and intentionally ignored as unmanaged:

```text
window_decision token=WindowToken(pid: 92251, windowId: 11936)
  context=full_refresh disposition=unmanaged
  source=builtInRule(ghosttyQuickTerminalOverlay) outcome=ignored
  bundleId=com.mitchellh.ghostty axSubrole=AXFloatingWindow wsLevel=3
  wsFrame=(0.0,33.0,1728.0,891.0)

window_decision token=WindowToken(pid: 92251, windowId: 11936)
  context=create disposition=unmanaged
  source=builtInRule(ghosttyQuickTerminalOverlay) outcome=ignored
  bundleId=com.mitchellh.ghostty axSubrole=AXFloatingWindow wsLevel=101
  wsFrame=(0.0,-589.0,1728.0,891.0)
prepare_create_rejected window=11936 reason=untracked_decision
```

The actual bad transition is a `focusedWindowChanged` activation for Ghostty
that resolves to the regular managed window, not the overlay:

```text
AX notification: ax=AXFocusedWindowChanged pid=92251 window=nil
activation_source_observed pid=92251 source=focusedWindowChanged
window_decision token=WindowToken(pid: 92251, windowId: 20978)
  context=activation_existing disposition=managed source=heuristic
  bundleId=com.mitchellh.ghostty axSubrole=AXStandardWindow wsLevel=0
  wsFrame=(1727.0,65.0,847.0,1045.0)
focus_confirmed token=WindowToken(pid: 92251, windowId: 20978)
  workspace=EA1BE709-8127-4235-A4D0-8DBC31C9D89F source=focusedWindowChanged
```

Niri then reveals the parked Ghostty column:

```text
ax_focus_confirm_before_activate token=WindowToken(pid: 92251, windowId: 20978)
  isFFM=false preserveActiveViewport=false wasAlreadyConfirmedFocus=false
  columns=7 activeColumnIndex=0 currentViewStart=-6.0 targetViewStart=-6.0
  preferredFocus=WindowToken(pid: 42984, windowId: 19419)
  confirmedFocus=WindowToken(pid: 92251, windowId: 20978)

ax_focus_confirm_reveal_candidate token=WindowToken(pid: 92251, windowId: 20978)
  columnIndex=4 revealStyle=auto locked=false
  visibility=parked(Nehir.AxisHideEdge.maximum) viewStart=-6.0
  closest=2553.0:rightEdge closestFills=true center=2979.5:center

ax_focus_confirm_reveal_result token=WindowToken(pid: 92251, windowId: 20978)
  columnIndex=4 isFFM=false didReveal=true

relayout.viewportOffsetChanged
  activeColumnIndex=4 currentOffset=-3411.0 targetOffset=-859.0
  currentViewStart=-3.8 targetViewStart=2553.0
  lastViewportMutation=animateToOffset.spring
  lastViewportMutationBeforeTargetOffset=-3418.0
  lastViewportMutationAfterTargetOffset=-859.0

scroll_animation_start displayId=1
  activeColumnIndex=4 currentViewStart=28.0 targetViewStart=2553.0
```

End state confirms the viewport finished on Ghostty:

```text
observedManagedFocus=WindowToken(pid: 92251, windowId: 20978)
layoutSelection=WindowToken(pid: 92251, windowId: 20978)
workspace=1 visible=true activeColumnIndex=4
currentOffset=-859.0 targetOffset=-859.0
currentViewStart=2553.0 targetViewStart=2553.0
WindowToken(pid: 92251, windowId: 20978) phase=tiled hidden=nil
  liveAXFrame={{867.0, 7.0}, {847.0, 1045.0}}
```

This is exactly the unwanted movement: before the close, Teams on column 0 was
the managed focus and the viewport start was `-6.0`; after Ghostty overlay churn,
Nehir selected the regular Ghostty window at column 4 and animated to
`targetViewStart=2553.0`.

---

## Evidence B — clean startup shape to preserve

A second capture starts with clean Nehir state: `startedServices=false`, no
managed windows, no Niri viewport, and seven ordinary WindowServer windows
visible. Ghostty's regular window is already present before Nehir begins
tracking:

```text
startedServices=false
windows total=0 tiled=0 floating=0 hidden=0
-- Visible Unmanaged WindowServer Windows --
windowId=20978 pid=92251 owner=Ghostty bundleId=com.mitchellh.ghostty
  frame={{1727.0, 65.0}, {847.0, 1045.0}}
windowId=19419 pid=42984 owner=Microsoft Teams bundleId=com.microsoft.teams2
  frame={{1727.0, 65.0}, {847.0, 1045.0}}
...
-- Niri Viewports --
niri disabled
```

On startup full rescan, Nehir admits the same seven windows and chooses Teams as
the managed focus; Ghostty is placed as a visible neighboring tile, not as an
unmanaged overlay:

```text
#1 window_admitted token=WindowToken(pid: 42984, windowId: 19419)
   context=startup_full_rescan
#7 window_admitted token=WindowToken(pid: 92251, windowId: 20978)
   context=startup_full_rescan
#13 managed_focus_requested token=WindowToken(pid: 42984, windowId: 19419)
#14 managed_focus_confirmed token=WindowToken(pid: 42984, windowId: 19419)
```

End state:

```text
observedManagedFocus=WindowToken(pid: 42984, windowId: 19419)
layoutSelection=WindowToken(pid: 42984, windowId: 19419)
WindowToken(pid: 92251, windowId: 20978) bundleId=com.mitchellh.ghostty
  phase=tiled hidden=nil liveAXFrame={{867.0, 7.0}, {847.0, 1045.0}}
```

This is not the same focus-confirm-to-Ghostty failure as Evidence A, but it is a
useful startup guard: any fix must not classify every ordinary Ghostty window as
overlay churn merely because it was visible before services started.

---

## Existing source behavior

### Ghostty Quick Terminal is correctly recognized as unmanaged

`Sources/Nehir/Core/Rules/WindowRuleEngine.swift:705-721` classifies Ghostty
non-level-0 windows as unmanaged via the built-in
`ghosttyQuickTerminalOverlay` rule:

```swift
private func ghosttyQuickTerminalOverlayDecision(for facts: WindowRuleFacts) -> WindowDecision? {
    guard facts.ax.bundleId?.lowercased() == Self.ghosttyBundleId,
          let windowServer = facts.windowServer,
          windowServer.level != 0
    else { return nil }

    return WindowDecision(
        disposition: .unmanaged,
        source: .builtInRule(Self.ghosttyQuickTerminalRuleName),
        layoutDecisionKind: .explicitLayout,
        workspaceName: nil,
        ruleEffects: .none,
        heuristicReasons: [],
        deferredReason: nil
    )
}
```

The capture proves this rule fired for `92251:11936`.

### Managed activation suppression already has an overlay guard, but it is live-snapshot-only

`Sources/Nehir/Core/Controller/AXEventHandler.swift:1650-1674` suppresses a
managed activation while a non-managed overlay owns focus:

```swift
let overlayFocusIsActive = controller.workspaceManager.isNonManagedFocusActive
    || hasVisibleSamePidOverlayWindow(for: observedEntry)
guard overlayFocusIsActive else { return false }
return true
```

`hasVisibleSamePidOverlayWindow` then consults the current SkyLight visible-window
snapshot (`AXEventHandler.swift:1677-1697`) and only returns true when the
overlay is still visible and non-level-0 in that instant:

```swift
return SkyLight.shared.queryAllVisibleWindows().contains { info in
    guard info.pid == entry.pid,
          info.id != windowId,
          info.level != 0,
          !info.frame.isNull,
          !info.frame.isEmpty
    else { return false }
    ...
    return isKnownSamePidOverlayWindow(info, pid: entry.pid)
}
```

The failure is therefore plausibly a race: the trace already has durable
evidence that Ghostty overlay `92251:11936` existed and was ignored as
`ghosttyQuickTerminalOverlay`, but by the time the regular-window activation is
handled the live snapshot no longer satisfies `hasVisibleSamePidOverlayWindow`.

### The inactive-workspace quick-terminal guard does not apply on the active workspace

`shouldSuppressSameAppInactiveWorkspaceActivationBeforeCloseRecovery` only
continues past line 1817 when the target workspace is inactive. In this repro the
regular Ghostty window is on the currently active workspace, so the guard returns
false before its `focusedWindowChanged` suppression branch:

```swift
// AXEventHandler.swift:1817
 guard !isWorkspaceActive else { return false }
...
// AXEventHandler.swift:1839-1840
if source == .focusedWindowChanged { return true }
```

That is correct for many ordinary same-workspace activations, but it leaves this
same-workspace overlay-close shape uncovered.

### The reveal path is behaving as written

`handleManagedAppActivation` confirms managed focus first
(`AXEventHandler.swift:2364-2401`), computes `preserveActiveViewport` from
in-flight gesture/spring state or already-confirmed duplicate focus
(`:2453-2458`), then calls `scrollToReveal` when `!isFFM &&
!preserveActiveViewport` (`:2502-2547`). The capture has
`preserveActiveViewport=false` because the previous confirmed token was Teams,
not Ghostty, and there was no gesture/in-flight spring.

`scrollToReveal` intentionally animates parked or clipped targets
(`Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+ViewportCommands.swift:70-142`).
So the reveal itself is not the bug; the bug is admitting this overlay-close
activation as ordinary managed focus.

---

## Root cause

The previous fix protects two shapes but misses this one:

1. **Inactive-workspace activation churn** is suppressed/deferred, but this
   capture resolves to a managed Ghostty window on the active workspace.
2. **Same-pid unmanaged overlay focus** is suppressed only while
   `workspaceManager.isNonManagedFocusActive` is set or a live SkyLight snapshot
   still contains a visible same-pid overlay. The capture shows durable overlay
   evidence in the create/focus trace, but the later activation still reaches
   `handleManagedAppActivation`, meaning the live-overlay predicate was false at
   the decisive moment.

The missing primitive is a short-lived, source-backed "recent unmanaged overlay
for pid" memory. The system already knows that `92251:11936` was an ignored
Ghostty Quick Terminal overlay; it should preserve that fact briefly across the
close/hide ordering race and use it to suppress the immediately following
`focusedWindowChanged` activation of `92251:20978`.

---

## Implementation plan

### 1. Add recent app-owned overlay evidence keyed by pid

In `AXEventHandler`, add a small in-memory map, for example:

```swift
struct RecentUnmanagedOverlayEvidence {
    let pid: pid_t
    let token: WindowToken
    let ruleName: String
    let observedAt: Date
    let windowLevel: Int?
    let frame: CGRect?
}
```

Record evidence when a window decision is `.unmanaged` from one of the known
app-owned overlay rules, starting with `ghosttyQuickTerminalOverlay`. The capture
shows the useful event is emitted from the decision path that currently records
`window_decision ... source=builtInRule(ghosttyQuickTerminalOverlay)` and from
the rejected create path.

Keep the TTL short (candidate: 500-1000 ms) and prune by pid/window id. This is
long enough for the close/hide ordering race, but short enough not to suppress a
real later click/Cmd-Tab to the app.

Do not seed this map during startup full rescan until `hasStartedServices` is
true and an activation/AX-create path indicates overlay churn. Evidence B shows
ordinary app windows are all visible before startup; startup must not inherit a
blanket Ghostty suppression.

### 2. Use recent overlay evidence before confirming managed activation

In `handleAppActivation`, after resolving an existing managed `entry` but before
calling `handleManagedAppActivation`, add a predicate next to
`shouldSuppressManagedActivationWhileNonManagedFocusAnchored`:

- `requestDisposition == .unrelatedNoRequest`
- `source == .focusedWindowChanged` (consider `workspaceDidActivateApplication`
  only if the TTL is very short and overlay evidence is fresh)
- `entry.pid` has fresh recent overlay evidence for a different window id
- there is no active managed request for `entry.token`
- the current confirmed managed focus is a different token on the active
  workspace

When it matches, return without confirming focus or revealing. This preserves
the pre-overlay managed focus/viewport just like the live-overlay guard intended.
For observability, record a create-focus trace event such as
`activation_suppressed_recent_overlay(pid, observedToken, overlayToken, ruleName,
source)` and a runtime viewport trace reason like
`ax_focus_confirm_suppressed_recent_overlay`.

### 3. Keep the existing reveal semantics unchanged

Do not special-case `scrollToReveal` for Ghostty. The reveal machinery is correct
for genuine managed focus. The fix should prevent false managed focus admission,
not weaken parked-column reveal for real user navigation.

### 4. Tests

Add focused tests in `Tests/NehirTests/AXEventHandlerTests.swift`:

1. **Recent Ghostty overlay suppresses same-workspace managed refocus.** Active
   workspace has Teams focused at column 0 and managed Ghostty parked at column
   4. Seed recent `ghosttyQuickTerminalOverlay` evidence for the same pid but a
   different window id. Make `focusedWindowRefProvider` return the managed
   Ghostty token and call `handleAppActivation(pid: ghosttyPid, source:
   .focusedWindowChanged)`. Assert confirmed focus remains Teams, viewport
   offset/target remain unchanged, and no `didReveal=true` trace is emitted.
2. **No evidence still allows deliberate managed focus.** Same layout, no recent
   overlay evidence, same `focusedWindowChanged`; assert the existing behavior
   still reveals Ghostty. This prevents over-suppression of ordinary focus.
3. **Expired evidence does not suppress.** Seed evidence older than the TTL;
   assert managed focus/reveal proceeds.
4. **Startup full rescan is unaffected.** Model the clean-start shape: services
   initially not started, regular Ghostty visible as an ordinary standard
   window, startup full rescan admits it as managed and still selects the intended
   startup focus. Assert no recent-overlay suppression is seeded by ordinary
   level-0 Ghostty windows.

If adding a test hook is needed, expose a narrow `seedRecentOverlayEvidenceForTests`
method rather than mocking global SkyLight. Longer term, consider replacing the
hard-coded `SkyLight.shared.queryAllVisibleWindows()` call in
`hasVisibleSamePidOverlayWindow` with an injectable provider so the existing
live-overlay guard can be regression-tested too.

### 5. Validation

Manual validation should capture three cases with evidence inlined into the
implementation PR notes:

- Quick Terminal close from a stable workspace with Ghostty parked offscreen: no
  managed focus change to Ghostty, no `didReveal=true`, viewport remains at the
  previous column.
- Repeated open/close attempts after the first reproduction: no delayed reveal
  once overlay evidence expires.
- Clean Nehir startup: ordinary Ghostty standard windows are admitted/laid out as
  before; no false suppression during startup full rescan.
