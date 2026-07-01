# Preserve a parked/edge-snapped viewport anchor across config/settings relayouts — Plan

Promotes `discovery/20260701-config-relayout-reinterprets-parked-edge-snapped-selection.md`.
That discovery source-attributed item 9: changing app rules / workspace config /
layout config / monitor settings / gaps requests a refresh that runs the niri layout
pass, whose `resolveSelection` step re-centers a settled multi-column viewport onto
the canonical centered-filling snap — discarding a deliberately parked/edge-snapped
anchor even though the selection, active column, and column set never changed.

This is the config-triggered, edge-snap-specific extension of Phase 3 of
`planned/20260625-unrecorded-viewport-offset-mutation-attribution.md` (same mover:
`resolveSelection` → `ensureSelectionVisible` → `scrollToReveal`, plus the
`centeredViewportCorrection` block). It can be implemented together with that Phase 3.

Source references verified against `main` at `ca7ac372` on 2026-07-01. Line numbers
will drift; function names are included so the code stays findable.

## TL;DR

- **Symptom.** With a multi-column workspace whose viewport was deliberately parked
  or edge-snapped (an edge column flush to the working area, not centered), changing
  any config/settings value — app rules, workspace config, layout config, monitor
  settings, or gaps — springs the viewport back to the centered-filling position.
  Nothing about the selection or layout changed; only the offset moved.
- **Cause.** `resolveSelection`'s multi-column branch runs two recenter blocks with
  no "did selection/active-column/columns change?" gate: `ensureSelectionVisible` →
  `scrollToReveal` (recenter a fully-visible filling viewport) and
  `resolveSelection.centeredViewportCorrection` (static snap to centered-filling
  start). A parked/edge-snapped viewport is by definition off the centered start, so
  the correction fires on every settled relayout.
- **Fix.** Gate both blocks on an actual change that justifies a reveal/recenter,
  mirroring the lone-window branch (which already preserves deliberate side-snaps)
  and `revealForFocusActivation` (which already no-ops on fully visible).

## Status

- Root cause source-attributed (see discovery). No further capture required to
  implement; a config-triggered multi-column repro is described in the discovery for
  regression validation after the fix.
- Not yet implemented.

## Source map

- Pass always reconciles selection: `NiriLayoutHandler.swift:383`
  (`resolveSelection` called every niri pass).
- Block 1 — `ensureSelectionVisible` (multi-column): `NiriLayoutHandler.swift:633`–`654`.
  Gate lacks any selection/active-column/columns change check. Delegates to
  `NiriNavigation.swift:173` (`ensureSelectionVisible`) →
  `NiriLayoutEngine+ViewportCommands.swift:70` (`scrollToReveal`), whose
  `.fullyVisible` recenter is at `:106`–`:122`.
- Block 2 — `centeredViewportCorrection`: `NiriLayoutHandler.swift:656`–`693`.
  Static snap to `centeredFillingViewportStart`; this is the block that clobbers a
  deliberate edge-snap.
- Already-correct sibling (reference for the fix shape): lone-window preserve-side-snaps
  gate `NiriLayoutHandler.swift:600`–`622` (see comment `:612`–`:614`, width/removal
  gate `:616`–`:618`); focus-confirm fully-visible no-op
  `NiriLayoutEngine+ViewportCommands.swift:160` (`revealForFocusActivation`,
  `dad2e63a`).
- Config trigger routes: `RefreshReason.swift` route table
  (`layoutConfigChanged`/`monitorSettingsChanged`/`gapsChanged`/
  `workspaceLayoutToggled`/`windowRuleReevaluation` → `.relayout`;
  `appRulesChanged`/`workspaceConfigChanged` → `.fullRescan`; both reach the pass).

## Phases

### Phase 1 — Gate Block 1 (`ensureSelectionVisible`) on an actual change

In `resolveSelection` (`NiriLayoutHandler.swift:633`), compute a
`selectionReconciliationRequiresReveal` condition and only call
`ensureSelectionVisible` when it is true. It is true when any of:

- the selected node changed since the last pass (compare against the pre-pass
  `state.selectedNodeId` / a remembered previous selection),
- the active column index changed,
- the column set changed (count or identity),
- a removal shifted visibility (`removal.removalResult.fromIndexForVisibility != nil`
  or `visibilityWasCorrected`).

When none hold and the selection is already fully visible, skip — mirroring
`revealForFocusActivation`'s `.fullyVisible` early return. This makes a config-only
relayout with an unchanged selection a no-op for Block 1.

Alternative (broader) implementation: give `ensureSelectionVisible` itself a
fully-visible/unchanged-selection fast-path so every caller benefits, not just
`resolveSelection`. Prefer this if it does not disturb the removal/arrival callers.

### Phase 2 — Preserve edge-snaps in Block 2 (`centeredViewportCorrection`)

Block 2 (`NiriLayoutHandler.swift:656`–`693`) must stop treating "viewport not at
the centered-filling start" as drift for a deliberately parked viewport. Gate it on
the same "something-changed" condition as Phase 1, OR restrict it to the case it
legitimately fixes: the parked offset became *invalid* because a real width/column
change moved the valid snap range (analogous to the lone-window width gate at
`:616`–`:618`). Concretely: only apply the centered correction when the pre-pass view
start is no longer a reachable snap for the new column layout, or when
Phase 1's change condition holds. A parked view start that is still a valid snap for
an unchanged layout must survive.

### Phase 3 — Regression test

After the user confirms the fix in a real repro (per repo policy, do not add tests
before that), add coverage:

- Multi-column workspace, columns fill the viewport, view start parked at an edge
  (not centered), viewport settled. Issue a `layoutConfigChanged` / `gapsChanged` /
  `monitorSettingsChanged` relayout that does **not** change column widths → assert
  the view start is unchanged (no recenter).
- Control 1: same setup but the relayout genuinely changes column widths so the
  parked offset is out of range → assert it recenters (legitimate correction still
  fires).
- Control 2: selection/active-column actually changes → assert reveal still happens.
- Control 3: lone-window deliberate side-snap across a config relayout still survives
  (guards against regressing `NiriLayoutHandler.swift:600`–`622`).

Likely home: `Tests/NehirTests` alongside existing niri layout/viewport tests.

## Acceptance

- Parking/edge-snapping a multi-column viewport then changing app rules / workspace
  config / layout config / monitor settings / gaps leaves the view start unchanged.
- Genuine selection change, active-column change, window arrival/removal that changes
  visibility, lone-window centering, and a real width/column-count change that
  invalidates the parked offset all still recenter as before.
- No change to focus-confirmation behavior (already handled by `revealForFocusActivation`).

## Notes

- User-visible bug fix → add a Changesets fragment
  (`mise run changeset patch "..."`) referencing the nehir issue for item 9 when the
  fix lands.
- Coordinate with `planned/20260625-unrecorded-viewport-offset-mutation-attribution.md`
  Phase 3: if that lands first with a Block 1 change gate, this plan reduces to
  Phase 2 (edge-snap preservation in Block 2) plus the config-trigger regression
  tests.
