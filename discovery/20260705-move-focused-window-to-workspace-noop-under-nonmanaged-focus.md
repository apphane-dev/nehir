# Move-focused-window-to-workspace silently no-ops while non-managed focus is active

Groom 2026-07-07: still applicable — `isNonManagedFocusActive` can stay stuck `true` after a third-party focus-suppressing overlay (e.g. Ghostty quick-terminal) is destroyed, because the clear path (`handleOwnedFocusSuppressingWindowClosed`) fires only for Nehir-owned windows; no `completed/`/`planned/` match. Re-verify the third-party-overlay clear path against current source before acting (verified against main 7a025b78).

Follow-up 2026-07-08: [`20260708-stale-nonmanaged-focus-suppresses-managed-selection-and-window-move.md`](20260708-stale-nonmanaged-focus-suppresses-managed-selection-and-window-move.md) captures the same move-command targetless state on current main, but with a stronger viewport-selection angle: the visible selected managed window changes while `confirmedManagedFocusToken` stays on an offscreen older token and `wmCommandTarget=nil`.

Cross-link cluster: [`NF-1` in `20260708-cross-discovery-relevance-clusters.md`](20260708-cross-discovery-relevance-clusters.md#nf-1--stale-non-managed-focus-blocks-admission-confirmation-and-command-targets) groups the high-confidence stale non-managed-focus/admission/command-target discoveries.

Discovery (2026-07-05). Trying to move the focused window to another workspace —
both by **shift-clicking a workspace-bar pill** and by the **keyboard shortcut**
(`Opt+Shift+N` / move-window-to-adjacent-workspace) — does nothing. No window
moves, no error, no feedback. Retrying a moment later works, so the gesture
"happens and resolves" on its own without any visible cause.

There are two layered causes.

**Proximate cause — explicit move commands hard-drop under non-managed focus.**
Both entry points resolve their target through
`WMController.managedCommandTargetToken()`. When the focus layer is in
**non-managed focus** (`isNonManagedFocusActive == true`),
`managedCommandTarget()` returns `nil` unless it can probe the frontmost app and
resolve a managed token that is *different* from the last confirmed managed
focus. The last focused managed window resolves to exactly that preserved token,
so the branch falls through to `return nil`. Each command then hits its
`guard let token = ... else { return }` and silently aborts, with **no UI
feedback and no surfaced state**.

**Underlying cause — non-managed focus gets *stuck* after a third-party
focus-suppressing overlay is destroyed, leaving no visible surface.** In this
capture the surface that put the focus layer into non-managed focus was the
**Ghostty quick-terminal dropdown** (`com.mitchellh.ghostty`, matched by
`builtInRule(ghosttyQuickTerminalOverlay)`, `AXSubrole=AXFloatingWindow`,
`wsLevel=101`). When that dropdown is dismissed it is *destroyed*
(`AXUIElementDestroyed`), Ghostty drops to **zero** windows, and focus returns to
the tiled window underneath — but the `isNonManagedFocusActive` flag is never
cleared. The only code path that clears it on a window close,
`WMController.handleOwnedFocusSuppressingWindowClosed`
(`Sources/Nehir/Core/Controller/WMController.swift:3757`), fires **only for
Nehir-owned windows** (`ownedWindowRegistry`); a third-party overlay like
Ghostty's does not qualify. So the flag stays `true` with **nothing on screen**,
which is exactly why the user sees no surface yet the move silently fails — and
why it "self-resolves" the moment some later app-activation re-confirms managed
focus. A 1-second `recentlyLeftNonManagedFocus` grace timer extends the dead zone
even once the flag does clear.

Evidence is reproduced inline from two runtime captures on a single built-in
display (`nehir v83c223`, capture windows around 2026-07-05T12:50Z): one for the
shift-click attempt, one for the keyboard-shortcut attempt. Both logs are
machine-local and ephemeral; the values that matter are copied below. Code
citations reference the main Nehir working tree; re-verify against `main` before
implementing.

---

## TL;DR

- **Symptom.** Focused-window-to-workspace move does nothing on shift-click of a
  bar pill *and* on the keyboard shortcut. Later the same gesture works.
- **Trigger.** A third-party focus-suppressing overlay — here the **Ghostty
  quick-terminal dropdown** — takes focus (Nehir enters non-managed focus), then
  is *destroyed* on dismiss. Non-managed focus is never cleared, so
  `isNonManagedFocusActive` stays `true` with **no visible surface** while a
  tiled window sits underneath.
- **Mechanism.** `moveFocusedWindow(toRawWorkspaceID:)` (bar shift-click) and
  `moveWindowToAdjacentWorkspace(direction:)` (hotkey) both start with
  `guard let token = controller.managedCommandTargetToken() else { return }`.
  Under non-managed focus `managedCommandTarget()` returns `nil` when the only
  managed candidate is the *preserved* managed focus token — which is precisely
  the window the user means to move.
- **Why it "self-resolves."** Once the unmanaged surface loses focus and the
  1-second `recentlyLeftNonManagedFocus(within: 1.0)` grace expires,
  `managedCommandTarget()` resolves the confirmed managed / layout-selection
  token again and the command works. Nothing the user does explains the change.
- **Asymmetry that confirms the diagnosis.** The bar **right-click → "Move to
  Workspace"** path passes an *explicit token* (`moveWindowFromBar(token:)`) and
  is unaffected. Only the two *dynamically-resolved-target* paths break.

---

## What the captures show

Both captures share this focus state at the moment of the attempt:

- `nonManaged=true` in the Focus Targets block, and `non-managed-focus=true` in
  the Reconcile Snapshot. Both fields are printed directly from
  `workspaceManager.isNonManagedFocusActive`
  (`Sources/Nehir/Core/Controller/RuntimeDiagnosticsCoordinator.swift:613`,
  `Sources/Nehir/Core/Reconcile/DebugDump.swift:21`). So the focus layer is
  unambiguously in non-managed focus.
- `layoutSelection=WindowToken(pid: 28651, windowId: 1945)` and
  `observedManagedFocus=WindowToken(pid: 28651, windowId: 1945)` — the last
  managed window (a Helium window) is still the layout selection.
- That same window's managed record reports `observedFocused=false`: the managed
  window does **not** hold live focus. Something unmanaged does.
- `wmCommandTarget=nil wmCommandTargetSource=nil` — no command target was
  resolved during the capture.

The captured lifecycle of the offending surface (pid 1835, window 169) names the
actor and proves the stuck state:

```
window_decision token=WindowToken(pid: 1835, windowId: 169) disposition=unmanaged
    source=builtInRule(ghosttyQuickTerminalOverlay) outcome=ignored
    bundleId=com.mitchellh.ghostty axRole=AXWindow axSubrole=AXFloatingWindow wsLevel=101
    ws_frame=(37,-1040 1982x1079)            # dropdown sliding in from the top
non_managed_fallback_entered pid=1835 source=focusedWindowChanged
...
AXUIElementDestroyed pid=1835 window=169     # dropdown dismissed → destroyed
ax_windows_query pid=1835 count=0 windowIds=[]   # Ghostty now has zero windows
```

So the surface that entered non-managed focus was Ghostty's quick-terminal
dropdown (`ghosttyQuickTerminalOverlay`, `AXFloatingWindow`, `wsLevel=101`,
sliding in at `y=-1040`). After it is destroyed, `nonManaged=true` still holds in
both captures (the shift-click capture even still points
`borderTarget=WindowToken(pid: 1835, windowId: 169)` at the dead window; the
keyboard capture has `borderTarget=nil`). Nothing on screen belongs to pid 1835
anymore, yet the focus layer never left non-managed focus — the flag is **stuck**.

Decisive negative evidence — **the command never ran**. The
`LayoutRefreshController` reason histograms are byte-for-byte identical between
the "state at start" and "state at end" dumps of each capture:
`Nehir.RefreshReason.layoutCommand: 38` requested at both start and end, with
`workspaceTransition: 10` unchanged. A successful move calls
`commitWorkspaceTransition(reason: .workspaceTransition)`; the counter would have
advanced. It did not. `isTransferringWindow=false` throughout, and all seven
managed windows remain on the same workspace
(`D14B2E79-0FE7-4313-B39F-CAE8246FB17F`) in both the start and end dumps. The
gesture was received (the mouse-focus trace shows pointer activity at
`loc≈(1073, 1205..1227)`, just above the bar at `y=1258`) but produced no move.

---

## Code path

Both user entry points converge on the same guarded resolve:

- Bar shift-click. `WorkspaceBarManager.handleWorkspacePillClick` maps `.shift`
  to `.moveWindow` (`WorkspaceBarClickIntent.resolve`,
  `Sources/Nehir/UI/WorkspaceBar/WorkspaceBarManager.swift:765`) and calls
  `controller.moveFocusedWindowFromBar(toWorkspaceId:)`
  (`WorkspaceBarManager.swift:659`). That forwards to
  `WMController.moveFocusedWindowFromBar` →
  `WorkspaceNavigationHandler.moveFocusedWindow(toRawWorkspaceID:)`
  (`Sources/Nehir/Core/Controller/WMController.swift:768`,
  `Sources/Nehir/Core/Controller/WorkspaceNavigationHandler.swift:868`).
- Keyboard shortcut. `moveWindowToAdjacentWorkspace(direction:)`
  (`WorkspaceNavigationHandler.swift:693`).

Each begins:

```swift
guard let token = controller.managedCommandTargetToken() else { return }
```

`managedCommandTargetToken()` → `managedCommandTarget()`
(`Sources/Nehir/Core/Controller/WMController.swift:1871`). The relevant branch:

```swift
if workspaceManager.isNonManagedFocusActive {
    let preservedManagedFocus = workspaceManager.confirmedManagedFocusToken
    if let frontmostToken,
       workspaceManager.entry(for: frontmostToken) != nil {
        return nil                                   // frontmost is a managed window → drop
    }
    if let frontmostPid {
        axEventHandler.handleAppActivation(pid: frontmostPid, ...)   // probe
        let resolvedFrontmostToken = ...
        if let target = managedCommandTarget(forFrontmostToken: resolvedFrontmostToken),
           target.token != preservedManagedFocus
            || workspaceManager.hasStickyWindowSource(target.token) {
            return target                            // only a *different* managed token wins
        }
    }
    return nil                                       // otherwise: drop the command
}
```

When an unmanaged surface holds focus, the probe cannot resolve a managed token
that differs from `preservedManagedFocus` (the last managed window — here Helium
`w1945`, which is also the `layoutSelection`). Both the `target.token !=
preservedManagedFocus` test and the final fallthrough return `nil`. Neither
command's guard is satisfied → silent early return. The generous
`confirmedManagedFocus` / `layoutSelectionCommandTarget` fallbacks further down
`managedCommandTarget()` are never reached, because the
`isNonManagedFocusActive` block `return`s before them.

The self-resolving behavior has a second contributor: even after the unmanaged
surface is gone, `recentlyLeftNonManagedFocus(within: 1.0)`
(`Sources/Nehir/Core/Workspace/WorkspaceManager.swift:1165`) runs first and, if a
frontmost token exists and is not the Nehir process, also `return nil` for up to
one second. So there is a ~1 s tail after focus returns to managed during which
the move still no-ops.

---

## Why this is a bug, not intended suppression

The `isNonManagedFocusActive` guard exists to stop *focus-stealing* commands from
firing at the wrong window when a menu/Spotlight/system dialog transiently holds
focus — reasonable for implicit "focused window" commands. But:

1. The two broken paths are **explicit user intent at an explicit destination**:
   the user clicked a specific workspace pill (shift-click) or pressed a
   dedicated move hotkey. There is an obvious, correct target already tracked as
   `layoutSelection` / `confirmedManagedFocusToken` (Helium `w1945`).
2. The sibling right-click **"Move to Workspace"** path
   (`moveWindowFromBar(token:)`, `WMController.swift:795`) carries an explicit
   token and works fine under the identical focus state — proving the move
   machinery is healthy; only target *resolution* fails.
3. The failure is **silent and state-invisible**. Nothing tells the user the
   command was dropped, and the deciding inputs (an unmanaged surface's focus + a
   1 s timer) leave no visible trace — hence "resolves without me realizing what
   affects it."

---

## Suggested direction (not yet a plan)

**Primary — stop non-managed focus from getting stuck when a third-party
focus-suppressing overlay is destroyed.** This is the underlying defect and, if
fixed, resolves the symptom on its own (managed focus is re-confirmed the instant
the overlay dies, so `managedCommandTarget()` resolves normally). Today only
`handleOwnedFocusSuppressingWindowClosed` (`WMController.swift:3757`) clears the
flag, and only for `ownedWindowRegistry` (Nehir-owned) windows. Extend the
overlay-closed / `AXUIElementDestroyed` handling so that when the *unmanaged
window that entered non-managed focus* is destroyed (or its app drops to zero
windows) and focus returns to a managed window, the flag is cleared and managed
focus re-confirmed — regardless of whether the overlay was Nehir-owned. Guard
against the FFM/menu-steal regressions the owned-only check was protecting (see
cross-refs) — the fix must distinguish "overlay destroyed, focus genuinely
returned to a tile" from "overlay merely deactivated but still present."

**Defensive — don't let explicit move commands hard-drop under non-managed
focus.** Even with the primary fix, an *explicit-destination* move should not
silently no-op:

- For these explicit-destination moves, fall back to
  `layoutSelectionCommandTarget()` / `confirmedManagedFocusToken` (the last
  managed window on the interaction workspace) when the non-managed-focus branch
  would otherwise return `nil`. This mirrors what the right-click path achieves
  by carrying an explicit token.
- Alternatively, route the bar shift-click through the same explicit-token move
  the right-click menu uses (`moveWindowFromBar(token:)`), resolving the token
  from `layoutSelection` at click time rather than through
  `managedCommandTargetToken()`.
- Whichever path is chosen, add a **no-op signal** (e.g. a diagnostic log or a
  brief bar flash) when a move command resolves no target, so a genuinely
  empty/ineligible case is distinguishable from this silent drop.

Cross-references: same non-managed-focus / transient-unmanaged-surface actor as
`discovery/20260616-ffm-steals-focus-behind-overlay-on-stale-queued-mouse-moves.md`
and the FFM menu-steal work in `completed/` — different code path (command-target
resolution vs. focus-follows-mouse).

## Reproduction (for fix validation)

The single lever is: make `workspaceManager.isNonManagedFocusActive == true` while
a managed window is the layout selection, then invoke either move path. Non-managed
focus is entered whenever the focused window resolves to a token with no managed
entry (`AXEventHandler` fallback at `AXEventHandler.swift:2245` →
`WorkspaceManager.enterNonManagedFocus`), and stays active as long as that
unmanaged surface holds focus.

### A. Deterministic automated repro (recommended regression guard)

Model it on the existing positive test
`moveFocusedWindowFromBarMovesFocusedWindowToClickedWorkspace`
(`Tests/NehirTests/WorkspaceNavigationHandlerTests.swift:169`) and insert **one
line** — flip the focus layer into non-managed focus immediately before the move:

```swift
_ = controller.workspaceManager.setManagedFocus(movedHandle, in: sourceWorkspaceId, onMonitor: monitor.id)
// ... existing niri/viewport/active-workspace setup ...

// Repro: an unmanaged surface holds live focus at the moment of the gesture.
_ = controller.workspaceManager.enterNonManagedFocus(appFullscreen: false)

controller.moveFocusedWindowFromBar(toWorkspaceId: targetWorkspaceId)
await waitForLayoutPlanRefreshWork(on: controller)
```

- **Pre-fix assertion (documents the bug):**
  `#expect(controller.managedCommandTargetToken() == nil)` and
  `#expect(controller.workspaceManager.workspace(for: movedHandle.id) == sourceWorkspaceId)`
  — the window does **not** move.
- **Post-fix assertion (the guard):** the window moves —
  `#expect(controller.workspaceManager.workspace(for: movedHandle.id) == targetWorkspaceId)`
  — i.e. the same assertions as the positive test, now holding even with
  non-managed focus active.

Add the mirror case for the keyboard path by driving
`controller.workspaceNavigationHandler.moveWindowToAdjacentWorkspace(direction:)`
(or `moveFocusedWindow(toRawWorkspaceID:)`) after the same
`enterNonManagedFocus(appFullscreen: false)` line. This is the predictable
validation: it removes all GUI/timing nondeterminism and pins both entry points.

Why it reproduces: `setManagedFocus(movedHandle, …)` makes `movedHandle` the
`confirmedManagedFocusToken` (= `preservedManagedFocus`). Under
`isNonManagedFocusActive`, `managedCommandTarget()` (`WMController.swift:1891`)
can only return a token *different* from `preservedManagedFocus`; the sole
managed candidate **is** `movedHandle`, so it returns `nil` and the move guard
aborts.

This test pins the **defensive** fix. For the **primary** (stuck-state) fix, add
an `AXEventHandler`-level test that mirrors the capture: admit an unmanaged
focus-suppressing overlay for a fake pid (entering non-managed focus while a
managed tiled window is confirmed), then dispatch that overlay's
`AXUIElementDestroyed` with the app reporting zero windows, and assert
`workspaceManager.isNonManagedFocusActive == false` and
`managedCommandTargetToken() == movedHandle.id` afterward — i.e. focus is
re-confirmed on the tile with no further user action. See
`Tests/NehirTests/AXEventHandlerTests.swift` for the destroy/close-recovery
harness (it already exercises `enterNonManagedFocus` and window-close paths).

### B. Manual GUI repro (the real one — matches the capture)

The offending surface is a **focus-suppressing overlay that gets destroyed on
dismiss**, so it leaves *no visible surface* behind — do **not** use a normal app
(Calculator/System Settings would be float-managed and legitimately movable; they
do not reproduce this). Use Ghostty's quick-terminal dropdown, which the capture
identifies (`builtInRule(ghosttyQuickTerminalOverlay)`):

1. Install Ghostty and enable its **quick terminal** (the dropdown/Quake-style
   terminal) bound to a global hotkey. Confirm Nehir classifies it as the
   built-in `ghosttyQuickTerminalOverlay` (unmanaged/ignored).
2. On the current workspace, focus a normal **tiled** managed window (any tiled
   app — Helium in the capture). This is the layout selection / last managed
   focus.
3. Press the quick-terminal hotkey so the dropdown **slides down and takes
   focus**. A runtime-state dump now shows `nonManaged=true` /
   `non-managed-focus=true` and a `non_managed_fallback_entered pid=<ghostty>`
   record.
4. Press the hotkey again to **dismiss** the dropdown. It slides up and is
   destroyed (`AXUIElementDestroyed`), Ghostty drops to zero windows, and focus
   returns to the tiled window. **Crucially, do not click the tiled window or
   switch apps** — a state dump still shows `nonManaged=true` with nothing from
   Ghostty on screen (the flag is stuck).
5. Now, with no visible surface, **shift-click a different workspace pill** (the
   bar is a non-activating panel, so it does not restore managed focus) **or**
   press the move-window-to-workspace hotkey.
6. **Buggy result:** nothing moves; the reason histogram's `workspaceTransition`
   count does not advance. **Fixed result:** the tiled window moves to the chosen
   workspace.
7. Confirm the self-resolve: click the tiled window (or Cmd-Tab away and back) to
   re-confirm managed focus, then repeat step 5 — it now works. This is the
   "resolves without me realizing" behaviour.

Generalization: any third-party window Nehir treats as a focus-suppressing
overlay (`AXFloatingWindow` / elevated `wsLevel`, entered via
`enterNonManagedFocus`) that is **destroyed** rather than merely deactivated will
reproduce the stuck state, because only *Nehir-owned* window closes clear the
flag (`handleOwnedFocusSuppressingWindowClosed`, `WMController.swift:3757`).

Contrast check (should pass both before and after the fix): the bar
**right-click → "Move to Workspace"** submenu on that same tiled window still
works in step 4's state, because it carries an explicit token
(`moveWindowFromBar(token:)`) rather than resolving through
`managedCommandTargetToken()`. If the right-click move works but shift-click /
hotkey do not, you are looking at exactly this bug.

### Distinguishing the two failure sub-modes

- **Steady mode** (repro B, ignored-app frontmost): non-managed focus is
  continuously active — the move fails every time until focus returns to a
  managed window.
- **Grace-tail mode:** even after the unmanaged surface closes and focus returns
  to a managed window, `recentlyLeftNonManagedFocus(within: 1.0)`
  (`WorkspaceManager.swift:1165`) keeps dropping the command for up to one
  second. To observe it, close the ignored window and fire the hotkey within
  ~1 s; it no-ops, then succeeds on a retry a beat later. This is the "resolves
  without me realizing" tail and should also be covered by a fix (a unit test can
  pin it by asserting the command still resolves a target immediately after a
  non-managed→managed transition).

## Provenance

Verified against the main Nehir source tree on 2026-07-05. Symbol/line citations
(`WMController.managedCommandTarget()` at `WMController.swift:1871`,
`WorkspaceNavigationHandler.moveFocusedWindow(toRawWorkspaceID:)` at
`WorkspaceNavigationHandler.swift:868`,
`moveWindowToAdjacentWorkspace(direction:)` at `WorkspaceNavigationHandler.swift:693`,
`WorkspaceBarClickIntent.resolve` at `WorkspaceBarManager.swift:765`) should be
re-confirmed before implementation. Runtime values are inlined from two
machine-local captures and are not reproducible from any stored file.
