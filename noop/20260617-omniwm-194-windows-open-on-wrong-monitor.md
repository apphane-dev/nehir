# OmniWM issue #194 — "Windows open on wrong monitor" — Discovery

Source issue: <https://github.com/BarutSRB/OmniWM/issues/194>
Scope of this doc: determine whether the symptom (new apps/windows opening on
the "wrong" — i.e. not the focused — monitor) reproduces in nehir, and whether
forcing new windows onto the focused monitor is a fix nehir should adopt.

All file/line references were verified against worktree `worktree-calm-meadow-6229`
at `904df02` ("Add bunch of discoveries mapped to issues from OmniWM"). Re-verify
before implementing; line numbers drift.

> **Filed under `discovery/noop/`** — nehir does not reproduce a "wrong monitor"
> bug: window placement is resolved by a deliberate **multi-signal priority
> resolver** (`resolveWorkspacePlacementTarget`) that honors the active focus
> request, the window's actual frame monitor, the interaction monitor, the native
> macOS Space monitor, and the focused workspace — not a single "focused monitor"
> heuristic. The upstream issue was closed `not_planned` with no fix, and the
> behavior the reporter wants (force new windows onto the focused monitor) is a
> declined design direction that would *regress* nehir's principled
> native-placement honoring. nehir already gives the user explicit per-app /
> per-workspace monitor pinning (`assignToWorkspace`, `monitorAssignment`), which
> is the reporter's own stated workaround. No new repo action is owned here.

---

## TL;DR

- **nehir places new windows using a tiered priority resolver that intentionally
  prefers where the window natively appeared and where the user is interacting,
  over the keyboard-focused monitor.** This is the opposite of the reporter's
  requested behavior, and it is by design.
- **Verdict:** ⚪ **Won't port / Not applicable.** OmniWM declined to fix this
  (`not_planned`); nehir already behaves more correctly and offers explicit
  pinning for users who want deterministic placement. There is no fix to port,
  and adopting "force focused monitor" would conflict with nehir's native-space
  / frame honoring.

## Issue context

- **State:** closed `not_planned`; no merged fix, no diff to port.
- **Symptom (verbatim):** "I have noticed a few scenarios where when opening an
  application it doesn't open on the focused monitor but instead the unfocused
  one."
- **Setup:** two monitors, each with its own workspace; external monitor is
  primary, built-in is secondary. The reporter's own config pins many apps with
  `assignToWorkspace: "2"` and uses `workspaceConfigurations` with
  `monitorAssignment` `{type:"main"}` / `{type:"secondary"}`.
- **Expected:** apps open on the focused monitor.

## Provenance: is this nehir's code?

Yes. Window-create placement is fully present and substantially more developed
than a single heuristic:

- `WMController.resolveWorkspacePlacementTarget(...)` — the priority resolver
  (`Sources/Nehir/Core/Controller/WMController.swift:1206`), consulted from the
  create path (`WMController.swift:3066`, `LayoutRefreshController.swift:1336`).
- `WindowCreatePlacementContext` — the captured-at-create-time signal bundle
  (`Sources/Nehir/Core/Controller/AXEventHandler.swift:87`), carrying
  `nativeSpaceMonitorId`, `focusedMonitorId`, `interactionMonitorId`,
  `activeFocusRequestWorkspaceId/MonitorId`, `focusedWorkspaceId`, `source`.
- `managedFocusPlacementTarget(_:_)` — the focused-workspace / focused-monitor
  resolver helper (`WMController.swift:1345`).
- Explicit pinning: `assignToWorkspace` app rules and per-workspace
  `monitorAssignment` (the reporter's own mechanism) are first-class in nehir's
  settings model.

## The code in question

**The priority resolver (abbreviated; tiers in order):**

```swift
// Sources/Nehir/Core/Controller/WMController.swift:1206  (resolveWorkspacePlacementTarget)
if preferManagedFocusPlacement {
    // 1. active focus request (a pending keyboard/programmatic focus target wins)
    if let target = managedFocusPlacementTarget(ctx?.activeFocusRequestWorkspaceId,
                                                ctx?.activeFocusRequestMonitorId) { return target }

    // 2. FRAME-monitor override: if the window actually appeared on a monitor that
    //    is NOT the focused one, and there's no conflicting interaction monitor,
    //    honor the frame (where macOS put it).
    if let focusedMonitorId = ctx?.focusedMonitorId,
       let frameMonitor, frameMonitor.id != focusedMonitorId,
       (ctx?.interactionMonitorId == nil || ctx?.interactionMonitorId == frameMonitor.id),
       let workspace = workspaceManager.activeWorkspaceOrFirst(on: frameMonitor.id) {
        return WorkspacePlacementTarget(workspaceId: workspace.id, monitorId: frameMonitor.id, isAuthoritative: true)
    }

    // 3. INTERACTION-monitor override: the monitor the user last interacted with.
    if let interactionMonitorId = ctx?.interactionMonitorId,
       interactionMonitorId != focusedMonitorId,
       let workspace = workspaceManager.activeWorkspaceOrFirst(on: interactionMonitorId) { ... return }

    // 4. interaction monitor's active workspace when it differs from focused …
    // 5. focused workspace / focused monitor fallback.
}

// 6. NATIVE-SPACE monitor: the monitor of the macOS Space the window belongs to.
if let monitorId = ctx?.nativeSpaceMonitorId, let workspace = ... { return ... }

// 7. window frame monitor, then AX-frame monitor.
// 8. interaction monitor, then fallback workspace.
```

**What the signals mean:**

- `interactionMonitorId` / `interactionWorkspace()` — the monitor/workspace of
  the user's last mouse/keyboard interaction
  (`Sources/Nehir/Core/Workspace/WorkspaceManager.swift:3983`,
  `WMController.swift:970`). This is "where the user is."
- `nativeSpaceMonitorId` — the monitor of the native macOS Space the window
  actually opened on.
- `frameMonitorId` — derived from the window's on-screen frame center
  (`WMController.swift:1365` `monitorForPlacementFrame`).

## Why the bug does not apply (and the requested "fix" would regress)

1. **nehir does not use a naive "focused monitor" heuristic.** The resolver's top
   tiers deliberately prefer the *frame* monitor (where macOS placed the window)
   and the *interaction* monitor (where the user is) over the keyboard-focused
   monitor (`WMController.swift:1226-1258`). On macOS the window server often
   decides initial placement; nehir honors that and *then* manages the window,
   rather than fighting it onto an unrelated monitor.

2. **The reporter's actual need is already covered by explicit pinning.** Their
   own config uses `assignToWorkspace: "2"` for the apps in question and
   `monitorAssignment {type:"secondary"}` for workspace 2. nehir treats these as
   authoritative app-rule / workspace-assignment inputs upstream of this resolver,
   so pinned apps go where the user asked — independent of which monitor happens
   to be "focused" at launch.

3. **OmniWM declined to "fix" this; there is nothing to port.** The issue is
   `not_planned`. Forcing every new window onto the keyboard-focused monitor
   would conflict with nehir's frame/native-space honoring (tiers 2 and 6) and
   would mis-manage windows whose native Space or on-screen frame is on a
   different monitor — a regression for the multi-monitor workflows nehir
   already handles correctly.

4. **The one genuinely surprising combination is intentional, not a bug.** If the
   user keyboard-focuses monitor 1 (`focusMonitorNext`) but the mouse (and thus
   `interactionMonitorId`) is on monitor 2, a launched app lands on monitor 2.
   That is "interaction = where the user is," a defensible and documented design
   choice, not a placement error.

## Recommendation

**Do nothing / do not port.** Keep nehir's multi-signal resolver as the owner for
window-create placement. If a user reports a specific app landing on a clearly
wrong monitor *despite* an `assignToWorkspace`/`monitorAssignment` pin or despite
their mouse being on that monitor, investigate it as a new resolver-tier bug with
the captured `WindowCreatePlacementContext` (`create_placement_resolved` trace
line, `AXEventHandler.swift:132`) — do not add a global "force focused monitor"
switch, which is the declined upstream direction.
