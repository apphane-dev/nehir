# Discovery: settings/config relayout reinterprets a parked/edge-snapped selection

Status: root cause found and source-attributed. A config/settings mutation (app
rules, workspace config, layout config, monitor settings, gaps) requests a refresh
that runs the full niri layout pass, whose `resolveSelection` step recenters the
viewport onto the canonical centered-filling snap. For a multi-column workspace whose
viewport was deliberately parked/edge-snapped, that recenter discards the user's
chosen anchor even though the selection, active column, and column set never changed.

This is the config-triggered sibling of
`discovery/20260628-relayout-path-recenters-fully-visible-unchanged-selection.md`
(same mover, `resolveSelection` reconciliation; that doc's triggers were typing and
display-connect). It adds two things that document does not fully cover: the trigger
class is **config/settings changes specifically**, and the anchor at risk is a
**deliberately parked/edge-snapped** viewport, which the `centeredViewportCorrection`
block clobbers even when the selection is already fully visible.

Verified against `main` at `ca7ac372` on 2026-07-01. Source paths are
repository-relative; line numbers will drift, so function names are included.

## Summary

Every config/settings change that alters layout routes through
`LayoutRefreshController.requestRefresh(reason:)` with a reason whose route is
`.relayout` or `.fullRescan`. Both routes execute the niri layout pass, which calls
`resolveSelection` unconditionally
(`Sources/Nehir/Core/Controller/NiriLayoutHandler.swift:383`). For a multi-column,
active workspace with a settled viewport, `resolveSelection` runs two recentering
blocks that have **no "did anything actually change?" gate**:

1. `ensureSelectionVisible` → `scrollToReveal`
   (`NiriLayoutHandler.swift:642`), which for a fully-visible-but-filling viewport
   animates to the centered-filling start.
2. `resolveSelection.centeredViewportCorrection`
   (`NiriLayoutHandler.swift:656`–`693`), which computes
   `centeredFillingViewportStart` and, if the current view start differs from it by
   more than a pixel, statically snaps the viewport back to centered.

A user who deliberately parked/edge-snapped the viewport (scrolled so an edge column
is flush against the working area, not centered) is sitting at a view start that is
*not* the centered-filling start. On the next config change, block 2 sees the
mismatch and yanks the viewport back to centered; block 1 does the same for the
fully-visible-filling case. The user's anchor is reinterpreted as "drift to correct"
even though nothing about the layout changed.

The **asymmetry** is the tell. Two adjacent paths already learned not to do this:

- The **lone-window** branch of the same `resolveSelection`
  (`NiriLayoutHandler.swift:600`–`622`) was explicitly taught to preserve deliberate
  side-snaps: it only recenters on initial setup, window removal, or a resolved-width
  change — otherwise "keep the current offset so deliberate side-snaps survive
  relayouts" (comment at `:612`–`:614`).
- The **focus-confirmation** path was taught the fully-visible no-op by `dad2e63a`
  (`revealForFocusActivation`,
  `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+ViewportCommands.swift:160`,
  returns `false` for `.fullyVisible`).

The **multi-column relayout** branch received neither fix. It still force-centers on
every config-driven relayout, which is exactly item 9's report.

## Trigger inventory — config/settings changes all route into the pass

Confirmed in `Sources/Nehir/Core/Controller/RefreshReason.swift` (route table):

| Reason | Route | Runs `resolveSelection`? |
| --- | --- | --- |
| `appRulesChanged` | `.fullRescan` | yes (full refresh relayouts) |
| `workspaceConfigChanged` | `.fullRescan` | yes |
| `layoutConfigChanged` | `.relayout` | yes |
| `monitorSettingsChanged` | `.relayout` | yes |
| `gapsChanged` | `.relayout` | yes |
| `workspaceLayoutToggled` | `.relayout` | yes |
| `windowRuleReevaluation` | `.relayout` | yes |

Raise sites (repository-relative):

- App rules: `WMController.swift:1004` (`reason: .appRulesChanged`).
- Workspace config: `WMController.swift:995` (`reason: .workspaceConfigChanged`).
- Layout config: `NiriLayoutHandler.swift:1867` and `:1922`
  (`updateNiriConfig` / `enableNiriLayout` → `reason: .layoutConfigChanged`).
- Monitor settings: `WMController.swift:551`, `:585`, `:724`, `:749`, `:755`
  (`reason: .monitorSettingsChanged`).
- Gaps: `WMController.swift:517` and `ServiceLifecycleManager.swift:214`
  (`reason: .gapsChanged`).
- Window rule re-evaluation: `AXEventHandler.swift:4506`, `WMController.swift:4113`,
  `:4351`, `:4364` (`reason: .windowRuleReevaluation`).

Both `.relayout` and `.fullRescan` reach the niri pass whose first reconciliation
step is `resolveSelection` (`NiriLayoutHandler.swift:383`), so every reason above can
move a settled viewport.

## Evidence — a real session where the config reasons fired

A runtime capture (11.4 s, two monitors — Built-in Retina `(0,0,1728,1117)` and HP
Z27k `( -104,1117,1920,1080)`) taken while the **Nehir Settings** window was open
(an unmanaged WindowServer window, `owner=Nehir title="Nehir Settings"`,
`frame={{414,126},{900,712}}`) shows the config/settings refresh reasons firing in
`LayoutRefreshController`'s `requestedByReason` counters, quoted verbatim:

```text
appRulesChanged: 1
workspaceConfigChanged: 1
layoutConfigChanged: 2
monitorSettingsChanged: 4
windowRuleReevaluation: 2
```

i.e. adjusting settings in the open Settings window drove app-rule, workspace-config,
layout-config, monitor-settings, and window-rule refreshes in a single short session
— the exact trigger class item 9 names.

The managed side of that capture was a **lone-window** workspace (`columns=1`, the
only managed tile being Slack `pid 8662 windowId 8983`, resolved width `1541` on the
`1728`-wide built-in display). During the session that window's frame animated across
a long spring sweep and re-settled centered (`{{93,32},{1541,1020}}`, view start
`-85.5`). Because it is the lone-window path, that recenter went through the
width/removal-gated branch (`NiriLayoutHandler.swift:600`–`622`), **not** the
ungated multi-column branch. So this capture corroborates the *trigger* (config
reasons firing while Settings is open, viewport moving) but is not itself a
multi-column parked/edge-snap repro. The multi-column clobber is established by
source below, and by the already-validated sibling discovery which proved the same
`resolveSelection` recenter fires on a settled multi-column viewport for a
non-config trigger.

To capture the multi-column parked/edge-snap case directly: on a workspace with 3+
columns whose combined width fills the viewport, scroll to park an edge column flush
against the working area (a view start that is not the centered-filling start), leave
the viewport settled (`gesture=false animating=false`), then change gaps or a monitor
setting. Expected buggy result: the viewport springs back to the centered-filling
start with `activeColumnIndex`, `selectedNode`, and `columns` unchanged.

## Source attribution

### The pass always reconciles selection

`Sources/Nehir/Core/Controller/NiriLayoutHandler.swift:383` — every niri layout pass
calls `resolveSelection(...)` before arrival/removal handling. There is no gate that
skips it for config-only relayouts.

### Block 1 — `ensureSelectionVisible` on the multi-column branch

`NiriLayoutHandler.swift:633`–`654`. Gate: `!usesCenteredLoneWindow`,
`!isGestureOrAnimation`, `!preservesUnsnappedGestureOffset`, `isActiveWorkspace`, a
resolvable selection, `!visibilityWasCorrected`, and no-removal-or-known-from-index.
Note what is **absent**: any check that the selection, active column, or column set
changed. On a settled config relayout the gate passes and it calls
`ensureSelectionVisible` (`Sources/Nehir/Core/Layout/Niri/NiriNavigation.swift:173`)
→ `scrollToReveal`
(`Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+ViewportCommands.swift:70`). In
`scrollToReveal`'s `.fullyVisible` case, when the viewport fills, it animates to
`centeredFillingViewportStart` if the current start differs
(`NiriLayoutEngine+ViewportCommands.swift:106`–`122`) — i.e. it recenters an
already-fully-visible, edge-parked viewport.

### Block 2 — `centeredViewportCorrection` (the edge-snap clobber)

`NiriLayoutHandler.swift:656`–`693`. Same gate minus the selection/visibility
clauses. It builds a snap context, reads `currentViewStart`, computes
`centeredFillingViewportStart`, and if `abs(centeredStart - viewStart) > pixel`
performs a **static** `setStaticViewOffsetPixels(..., reason:
"resolveSelection.centeredViewportCorrection")` to the centered start. This is the
block that most directly destroys a deliberate edge-snap: any parked viewport whose
columns fill the working area is, by definition, off the centered-filling start, so
this correction fires and re-centers it. There is no notion here that the offset was
*deliberately* placed.

### The asymmetry left behind

- Lone-window branch (`:600`–`622`) already preserves deliberate side-snaps
  (comment `:612`–`:614`), recentering only on initial setup, removal, or width
  change.
- Focus-confirmation path already no-ops on fully visible via
  `revealForFocusActivation` (`NiriLayoutEngine+ViewportCommands.swift:160`, added by
  `dad2e63a`).
- Multi-column relayout branch (`:633`–`693`) has neither guard, so a config-driven
  relayout force-centers it.

## Root cause

The multi-column selection-reconciliation path in `resolveSelection` treats "the
viewport is not at the canonical centered-filling start" as drift to correct, and
corrects it on **every** settled relayout — including relayouts triggered purely by a
config/settings change that altered nothing about the selection or column layout. A
deliberately parked/edge-snapped viewport is exactly "not at the centered-filling
start," so it is reinterpreted and re-centered. The lone-window path and the
focus-confirmation path were each taught to preserve a deliberate/settled anchor; the
multi-column relayout path was not.

## Fix direction

Extend the same preserve-the-deliberate-anchor principle into the multi-column
relayout branch. Two complementary gates:

1. **Change gate on Block 1.** Only run `ensureSelectionVisible` when something that
   justifies a reveal actually changed — selected node, active column, column set, or
   a removal that shifted visibility. When selection/active-column/columns are all
   unchanged and the selection is fully visible, skip (mirror
   `revealForFocusActivation`'s `.fullyVisible` early return).
2. **Preserve edge-snaps in Block 2.** The `centeredViewportCorrection` must not fire
   for a viewport the user deliberately parked. Gate it on the same
   "something-changed" condition, or restrict it to the cases it legitimately fixes
   (a column-count/width change that made the *previous* offset invalid), mirroring
   the lone-window branch's width/removal gate at `:616`–`:618`.

Because the mover is the same `resolveSelection` recenter identified in the sibling
discovery, this fix shares Phase 3 of
`planned/20260625-unrecorded-viewport-offset-mutation-attribution.md`. Item 9's extra
requirement over that plan is that the fix must also cover the **edge-snapped
(non-centered) fully-visible** case via Block 2, not only the centered-fully-visible
case Block 1 handles — and must be validated against a config/settings trigger, not
only typing/display-connect.

Preserve the legitimate recenters: genuine selection/active-column change, window
arrival/removal that changes visibility, lone-window centering
(`resetViewportForCenteredLoneWindow`), and a real width/column-count change that
invalidates the parked offset (e.g. a `layoutConfigChanged` that changes column
widths so the old view start is out of range). Those must still move the viewport.

## Out of scope

- The single-slot audit collapse of intermediate relayout mutations — see
  `discovery/20260628-relayout-commit-collapses-intermediate-viewport-mutations.md`.
- Lone-window centering behavior on config-driven width change: already correctly
  gated at `NiriLayoutHandler.swift:616`–`618`; recentering there on a real width
  change is intended.
- Snap targeting / fling momentum on gesture end — intentional snap behavior.

## References

- Pass entry: `Sources/Nehir/Core/Controller/NiriLayoutHandler.swift:383`
  (`resolveSelection` called every pass).
- Mover blocks: `NiriLayoutHandler.swift:642` (`ensureSelectionVisible`),
  `:656`–`:693` (`centeredViewportCorrection`).
- Underlying recenter: `Sources/Nehir/Core/Layout/Niri/NiriNavigation.swift:173`
  (`ensureSelectionVisible`),
  `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+ViewportCommands.swift:70`
  (`scrollToReveal`, `.fullyVisible` recenter at `:106`–`:122`).
- Already-correct siblings: lone-window preserve-side-snaps
  `NiriLayoutHandler.swift:600`–`622`; focus-confirm fully-visible no-op
  `NiriLayoutEngine+ViewportCommands.swift:160` (`revealForFocusActivation`,
  `dad2e63a`).
- Trigger routes: `Sources/Nehir/Core/Controller/RefreshReason.swift` (route table);
  raise sites `WMController.swift:517/551/585/724/749/755/995/1004`,
  `NiriLayoutHandler.swift:1867/1922`, `ServiceLifecycleManager.swift:214`,
  `AXEventHandler.swift:4506`.
- Sibling discovery (same mover, non-config trigger):
  `discovery/20260628-relayout-path-recenters-fully-visible-unchanged-selection.md`.
- Parent plan (shared Phase 3 fix site):
  `planned/20260625-unrecorded-viewport-offset-mutation-attribution.md`.
