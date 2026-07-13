# Finder opens on the internal display: focused-admission placement trusts a mis-snapped frame monitor over the interaction monitor

**Status:** ✅ RESOLVED — landed on `main` in **`3056bee8`** ("Open new windows
on the display you're using and keep focus on them"), 2026-07-13. All three
failure modes below are fixed; see the "Resolution" section immediately after
this line for what actually shipped. Original source-backed root cause was
verified against `main` (`WMController.swift`, `AXEventHandler.swift`,
`Monitor.swift`).

Companion plan: [`20260713-finder-focused-admission-frame-monitor-snaps-to-internal-display-plan.md`](20260713-finder-focused-admission-frame-monitor-snaps-to-internal-display-plan.md).

## Resolution (landed `3056bee8`)

The fix addresses the reported repro (**failure mode B**) plus the two related
defects surfaced during investigation:

- **B — stale interaction monitor (primary, the reported bug).** A new
  `cursorMonitorId` signal is derived from `NSEvent.mouseLocation` via strict
  `NSScreen` containment and carried on `WindowCreatePlacementContext` (populated
  in `makeCreatePlacementContext`, faked at the OS boundary in tests via
  `cursorDisplayIdProvider`). In the focused-admission tail of
  `createPlacementTarget`, when no native space is claimed and the WindowServer
  frame is off-screen, placement prefers the cursor monitor — the only signal
  that points at the display the user is actually on. Ordered after
  pending/native/confirmed-focus so those still win; an on-screen WindowServer
  frame still honors the frame monitor. It deliberately does **not** also require
  the live AX frame to be off-screen (a fresh window's AX frame is macOS default
  placement — noise, not intent). The cursor monitor now also appears in the
  `create_placement_resolved` trace line.
- **A — off-screen frame mis-snap (secondary hardening).** The interaction-monitor
  fallback from the original plan also landed: when *both* the WindowServer frame
  and the live AX frame are off-screen, prefer the interaction monitor over the
  `monitorApproximation`-snapped frame monitor. Backed by the new
  `Monitor.monitorContaining(in:)` strict-containment helper and
  `monitorContainingPlacementFrame(_:)`.
- **C — focus bounce after correct placement (found during implementation).**
  Opening the window is a non-managed app activation that records
  `recentNonManagedFocus` for its own pid, which satisfied the same-app
  overlay-recovery redirect and bounced focus to the nearest other tile. Fix:
  exempt a window that was itself just admitted as a managed window into the
  workspace (genuine focus-stealing overlays are non-managed and never appear in
  the recent managed-admission map).

Shipped files: `Monitor.swift`, `WMController.swift`, `AXEventHandler.swift`, new
test `Tests/NehirTests/PlacementCursorInteractionMonitorFallbackTests.swift`,
seam additions in `AXEventHandlerTests.swift` / `LayoutPlanTestSupport.swift`, and
two changeset fragments (placement + focus). No follow-up work outstanding.

The original investigation follows unchanged for provenance.

---

**Symptom:** the user activates Finder expecting its window on the **external
display** (they were interacting there), but the new Finder window is admitted
to the **internal (built-in) display's** active workspace instead.

Reported: "Finder that I expected to run [on the] 2nd display moved to internal
display instead." Canonical action: **click the external (display-2) desktop,
then ⌘N in Finder → the new window opens on the internal display.**

All evidence is inlined below; nothing depends on a trace file.

> **This document records two distinct failure modes.** Read the Correction
> section immediately below first: a fresh capture of the *canonical* user
> action reproduces the symptom via **failure mode B — a stale interaction
> monitor** (the interaction monitor is display 1, not display 2). Failure mode
> A (the D1/D2 frame mis-snap, analysed in the bulk of this document) is a real
> but **secondary** defect that does **not** explain or fix the reported repro.
> The first plan derived from this discovery targeted only A and is therefore
> inert against the canonical repro.

---

## Correction (verified against `main`, 2026-07-13): the reported repro is failure mode B — a stale interaction monitor, not a mis-snapped frame

A fresh capture of the canonical user action — *click the display-2 (external)
desktop, then ⌘N in Finder* — reproduces the symptom while `interaction_monitor`
is **display 1**, not display 2. This is exactly the case originally filed under
"Related but distinct: the second reproduction" (near the end of this document)
and deferred as an open question. It is in fact **the reproducible bug**, and the
D1/D2 analysis in the body below does **not** explain or fix it.

Fresh evidence (values inlined; topology identical to the Topology section
below — display 1 built-in `(0,0,2056,1329)`, display 2 DELL
`(-312,1329,2560,1440)`):

```text
window_decision token=WindowToken(pid: 60520, windowId: 52142)
  context=focused_admission disposition=managed bundleId=com.apple.finder
  wsFrame=(210.0, -1369.0, 1011.0, 1251.0)            # negative-y, off-screen

create_placement_resolved token=WindowToken(pid: 60520, windowId: 52142)
  workspace=3CD59A4A-…                                 # a DISPLAY-1 workspace
  focused_workspace=nil focused_monitor=nil native_monitor=nil
  frame_monitor=Optional(ID(displayId: 1))
  interaction_monitor=Optional(ID(displayId: 1))       # <-- STALE: user is on display 2
  context_source=ax_focused_admission_synthesized
```

The interaction monitor is display 1 **from session start and is never
written**: every event carries `interaction=ID(displayId: 1)/prev=nil`, the
status snapshot shows `interactionMonitor=ID(displayId: 1)` /
`previous-interaction-monitor=nil` / `interaction current=ID(displayId: 1)
previous=nil`, and there is not a single interaction-monitor write in the whole
capture. `focusFollowsMouse=false` and `mouseWarpEnabled=false`.

Because `interaction_monitor` is already display 1, a fix that merely prefers the
interaction monitor over an off-screen frame monitor (failure mode A) is a
**no-op** here: interaction monitor == frame monitor == display 1. Placement
lands on display 1 whichever of the two it trusts. **This was confirmed at
runtime**: the capture above was taken with the failure-mode-A fix applied, and
Finder still opened on the internal display.

### Root cause (failure mode B): the interaction monitor is never updated by a non-managed desktop activation on a display without managed windows

`interactionMonitorId` in the create-placement context is read verbatim from the
WorkspaceManager's stored value (`AXEventHandler.swift:6978`,
`interactionMonitorId: controller.workspaceManager.interactionMonitorId`). That
stored value is written **only** by Nehir-managed actions:

- `MouseWarpHandler.swift:517` — mouse warp (disabled: `mouseWarpEnabled=false`).
- `WindowActionHandler.swift:482` — navigate-to-window across workspaces.
- `WMController.swift:863` — scratchpad-from-bar.
- `WorkspaceNavigationHandler.swift:242` — workspace navigation.
- `WorkspaceManager.setActiveWorkspace(…, updateInteractionMonitor: true)`
  (`WorkspaceManager.swift:3459`, applied at `:4351`) — workspace activation.

Clicking the display-2 desktop and hitting ⌘N in Finder triggers **none** of
these. It is a non-managed app activation (`workspaceDidActivateApplication` for
Finder — the trace shows it firing repeatedly for pid 60520), and no activation
handler updates the interaction monitor. Display 2 has **no managed window** to
focus, `focusFollowsMouse` is off, and mouse warp is off — so the cursor's actual
display (display 2) is never consulted. The interaction monitor therefore stays
at its startup value (display 1), and the focused-admission carries **no signal
at all** pointing at the display the user actually clicked.

The window's own frame is no help: WindowServer reports it in an off-screen park
zone `(210,-1369,1011,1251)` (center `(715.5,-743.5)`, inside neither monitor),
which `monitorApproximation` snaps to the nearest display — display 1 (`dy=743.5`
vs display 2 `dy=2072.5`). Every available signal points at display 1; the
display-2 intent exists only as the cursor location, which placement never reads.

### Fix direction for failure mode B (non-prescriptive)

The missing signal is *where the user is actually interacting*. For the
"click desktop on display N → ⌘N" flow the reliable source is the **cursor
location** at admission time (`NSEvent.mouseLocation` → a strict-containment
monitor lookup; the cursor is already used for UI placement at
`CommandPaletteController.swift:336`). Two candidate seams:

- **Broad / root cause:** update the interaction monitor from the cursor's
  monitor on non-managed app activation. Fixes it globally, but wide blast radius
  — border, reveal, and focus heuristics all read the interaction monitor.
- **Targeted:** add a cursor-derived monitor field to the create-placement
  context (populated in `makeCreatePlacementContext`) and prefer it in the
  no-focused/native-context focused-admission tail of `createPlacementTarget`.

Either way the cursor-monitor lookup must be **strict containment** (a cursor on
no monitor should yield no signal), not nearest-snap.

*(Landed as the targeted approach — see the Resolution section at the top.)*

---

## Topology

Two monitors, in the global CoreGraphics coordinate space Nehir uses
(y grows downward from the main display's top-left):

```text
ID(displayId: 1)  isMain=true  frame=(0.0,    0.0,    2056.0, 1329.0)  Built-in Retina Display   (INTERNAL)
ID(displayId: 2)               frame=(-312.0, 1329.0, 2560.0, 1440.0)  DELL P2423D               (EXTERNAL, below display 1)
```

Display 2 occupies **positive** y (1329 → 2769). Nehir parks display-2's
inactive-workspace windows in a **negative-y** off-screen zone (observed
sibling parked frames on display 2 sit at `y ≈ -1378`).

## Evidence — the clean reproduction (failure mode A)

A new Finder window is created via the focused-admission path while the user's
interaction monitor is the **external display 2**:

```text
window_decision token=WindowToken(pid: 60520, windowId: 51308)
  context=focused_admission disposition=managed source=heuristic
  outcome=trackedTiling bundleId=com.apple.finder
  wsFrame=(719.0, -1369.0, 1011.0, 1251.0)          # WindowServer frame: NEGATIVE-y

create_placement_resolved token=WindowToken(pid: 60520, windowId: 51308)
  workspace=0301EC1A-…                                 # a DISPLAY-1 workspace
  pending_workspace=nil  pending_monitor=nil
  focused_workspace=nil  focused_monitor=nil  native_monitor=nil
  frame_monitor=Optional(ID(displayId: 1))          # <-- snapped to INTERNAL
  interaction_monitor=Optional(ID(displayId: 2))    # <-- user is on EXTERNAL
  context_source=ax_focused_admission_synthesized
  focused_workspace_source=nil  recent_pid_workspace=nil

track_prepared_create ... workspace=0301EC1A... monitor=Optional(ID(displayId: 1))
  admissionContext=focusedAdmission mode=tiling structuralWorkspaceMatch=false
window_admitted ... workspace=0301EC1A... monitor=Optional(ID(displayId: 1))
```

Workspace `0301EC1A-…` is a display-1 workspace (its other members — a Helium
window and a Slack window — carry display-1 replacement frames around
`x∈[14,2055], y∈[7,71]`). The Finder window then settles on-screen on the
internal display: final `liveAXFrame={{523.0, 19.0}, {1011.0, 1251.0}}`
(inside display 1's `0…2056 × 0…1329`).

So: **interaction monitor is display 2, but the window is placed on display 1**,
tracking `frame_monitor=display 1`.

### Why `frame_monitor` resolved to display 1

`placementFrame = evaluation.facts.windowServer?.frame ?? matchingWindowInfo?.frame`
(`AXEventHandler.swift:5359`) — here the WindowServer frame is
`(719, -1369, 1011, 1251)`. Its center is:

```text
center = (719 + 1011/2,  -1369 + 1251/2) = (1224.5, -743.5)
```

`monitorForPlacementFrame` (`WMController.swift:1721-1724`) resolves the monitor
via `frame.center.monitorApproximation(in:)`. `monitorApproximation`
(`Monitor.swift:486-491`) returns the **containing** monitor if any contains the
point, else the **nearest by squared distance**:

```swift
func monitorApproximation(in monitors: [Monitor]) -> Monitor? {
    if let containing = monitors.first(where: { $0.frame.contains(self) }) {
        return containing
    }
    return monitors.min(by: { $0.frame.distanceSquared(to: self) < $1.frame.distanceSquared(to: self) })
}
```

The center `(1224.5, -743.5)` is inside **neither** monitor (both start at
`y ≥ 0` for display 1, `y ≥ 1329` for display 2). Nearest wins:

```text
dist² to display 1 (y edge 0):     dy = 743.5   → 743.5²   ≈ 552,000
dist² to display 2 (y edge 1329):  dy = 2072.5  → 2072.5²  ≈ 4,295,000
```

Display 1 is ~7.8× closer, so a frame that actually lives in **display 2's
negative-y park zone** gets snapped to the **internal display**. The frame
monitor is therefore wrong: it points at display 1 for a window whose real home
is display 2.

## Failure mode A — placement discards a correct interaction monitor and trusts the (wrong) frame monitor

> Failure mode A is **secondary**: it only manifests when the interaction monitor
> is *correctly* on display 2 while the frame mis-snaps to display 1. The
> reported/canonical repro is failure mode B (stale interaction monitor = display
> 1) — see the Correction section above. Everything below remains a valid,
> separate hardening opportunity but does not fix the reported symptom.

`createPlacementTarget` (`WMController.swift:1465-1594`) runs with
`preferManagedFocusPlacement == true` (new window: `existingEntry == nil`, and
`restrictWorkspaceRuleToPlacementMonitor == true` because the tracked mode is
tiling, not floating — `AXEventHandler.swift:5371`).

The placement context for this synthesized focused-admission was built by
`makeCreatePlacementContext` (`AXEventHandler.swift:7074-7104`). Because Finder
had **no confirmed managed focus token** and **no recent managed workspace**
(`recentManagedWorkspaceId(for: 60520) == nil`), the derived fields collapse:

- `focusedWorkspaceId = confirmedFocusedWorkspaceId ?? fallbackFocusedWorkspaceId = nil`
  (both nil) → matches `focused_workspace=nil`, `focused_workspace_source=nil`.
- `focusedMonitorId = focusedWorkspaceId.flatMap { … } = nil` → `focused_monitor=nil`.
- `nativeSpaceMonitorId = nil` (synthesized path passes `nil` at
  `AXEventHandler.swift:7064`) → `native_monitor=nil`.
- `interactionMonitorId = workspaceManager.interactionMonitorId = display 2` —
  **the only correct signal present** (in this failure-mode-A capture).

Now walk `createPlacementTarget` with `focusedMonitorId == nil`,
`focusedWorkspaceId == nil`, `interactionMonitorId == display 2`,
`frameMonitor == display 1`:

1. **`preferManagedFocusPlacement` block (`1477-1545`):**
   - `managedFocusPlacementTarget(pending…)` → nil (pending both nil).
   - native-space branch → skipped (`nativeSpaceMonitorId == nil`).
   - `if let focusedMonitorId = …focusedMonitorId` (`1499`) — **skipped, nil.**
     This is the only branch that arbitrates frame-monitor vs interaction-monitor
     (its interaction fallback lives at `1513-1522`), so the interaction monitor
     never gets a look here.
   - interaction branch at `1525-1537` requires
     `let focusedWorkspaceId = …focusedWorkspaceId` — **skipped, nil.**
   - `managedFocusPlacementTarget(focusedWorkspaceId, focusedMonitorId)` → nil.
   - → block returns nothing; fall through.

2. **Fallback tail (`1547-1594`):**
   - `1553`: interaction branch requires `frameMonitor.id == interactionMonitorId`
     — display 1 ≠ display 2 → **skipped.**
   - `1566`: `nativeSpaceMonitorId` branch → skipped (nil).
   - `1576`: **`fallbackFrameMonitor` (display 1) wins** →
     `activeWorkspaceOrFirst(on: display 1)` → workspace `0301EC1A`. **BUG.**

Net: when the focused context is entirely absent (a plain app activation of an
app with no tracked/recent window — Finder here), **every branch that would
honor `interactionMonitorId` is gated behind a non-nil focused workspace or
focused monitor**, so the authoritative interaction monitor (display 2) is
silently dropped, and placement falls back to a frame monitor (display 1) that
`monitorApproximation` mis-snapped from a negative-y park-zone frame.

Two independent defects compound:

- **D1 (gating):** the interaction-monitor placement branches
  (`WMController.swift:1499-1523` and `1525-1537`) are unreachable when focused
  context is nil, even though `interactionMonitorId` is populated and correct.
  There is no "interaction monitor, no focused context" branch before the frame
  fallback at `1576`.
- **D2 (snap):** `monitorForPlacementFrame` → `monitorApproximation`
  (`Monitor.swift:486`) resolves an off-screen negative-y frame to the nearest
  monitor with no containment/plausibility gate, turning a display-2 park-zone
  frame into a display-1 answer. Placement then trusts it (`1576`).

D1 alone would land the window correctly (interaction monitor = display 2) if a
branch consumed it; D2 alone would be harmless if the frame monitor were only
used as a tie-breaker under confirmed focus. Together they invert the result.

## The second reproduction — now identified as failure mode B (the reported bug)

> **Update:** this section originally flagged the case below as a separate open
> question. The Correction section at the top of this document resolves it: it is
> **failure mode B**, the reproducible bug, root-caused as a stale interaction
> monitor that no non-managed cross-display activation updates. Retained here for
> the original evidence.

A separate activation of the same Finder pid produced:

```text
create_placement_resolved token=WindowToken(pid: 60520, windowId: 51320)
  workspace=0301EC1A-…  frame_monitor=nil
  interaction_monitor=Optional(ID(displayId: 1))     # already INTERNAL
  focused_workspace=nil focused_monitor=nil native_monitor=nil
  context_source=ax_focused_admission_synthesized recent_pid_workspace=nil
# track_prepared_create … frame=(0,0 0x0)            # empty WindowServer frame
```

Here `interaction_monitor` was **already display 1** at admission time (and the
WindowServer frame was empty, `frame_monitor=nil`), so placing on display 1
merely *followed* the interaction monitor. This is a **different** failure mode
— the interaction monitor never pointed at the external display for this
activation — and it is **not** explained by D1/D2. It is the canonical reported
repro, root-caused in the Correction section above.

## Fix direction (for the plan stage, not prescriptive)

*(Failure-mode-A hardening. The reported bug is failure mode B — see above.)*

- Add an interaction-monitor placement branch that fires under
  `preferManagedFocusPlacement` **without** requiring focused workspace/monitor
  context: when `interactionMonitorId` is present and resolves to an active
  workspace, and no stronger authoritative signal (pending/native/confirmed
  focus) exists, prefer it over the frame monitor. Closes D1.
- Make `monitorForPlacementFrame` (or its use at `WMController.swift:1576`)
  reject an off-screen frame whose center is contained by **no** monitor,
  rather than silently snapping to the nearest one — or only use the snapped
  frame monitor as a tie-breaker, never ahead of a known interaction monitor.
  Closes D2.
- Guard against regressing the legitimate frame-monitor case: a window the user
  dragged onto a specific monitor before Nehir admits it should still land
  there. The distinguishing fact is **containment** — an on-screen frame is
  contained by exactly one monitor; the buggy frame here is contained by none.

## Key source anchors (verified during investigation)

- `Sources/Nehir/Core/Controller/WMController.swift:1465` — `createPlacementTarget`
  (whole method `1465-1594`).
- `Sources/Nehir/Core/Controller/WMController.swift:1499` / `:1513` / `:1525` —
  interaction-monitor branches gated behind focused context (D1).
- `Sources/Nehir/Core/Controller/WMController.swift:1576` — frame-monitor
  fallback that wins.
- `Sources/Nehir/Core/Controller/WMController.swift:1721` —
  `monitorForPlacementFrame`.
- `Sources/Nehir/Core/Monitor/Monitor.swift:486` — `monitorApproximation`
  (nearest-monitor snap, D2).
- `Sources/Nehir/Core/Controller/AXEventHandler.swift:5359` — `placementFrame`
  source (`windowServer.frame ?? matchingWindowInfo.frame`).
- `Sources/Nehir/Core/Controller/AXEventHandler.swift:7074` —
  `makeCreatePlacementContext` (how the nil focused fields / interaction monitor
  are derived); synthesized-path entry at `AXEventHandler.swift:7052`.
