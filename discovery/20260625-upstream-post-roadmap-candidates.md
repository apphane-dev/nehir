# Upstream post-roadmap candidates — landed-status correction + post-cutoff triage

Two-part sweep of `BarutSRB/OmniWM` against Nehir `main`:

1. **Part 1** corrects the now-stale Status column of
   [`20260618-upstream-port-roadmap.md`](20260618-upstream-port-roadmap.md) for the
   three rows the roadmap still marks "not started" — **M4-S2, M6, A1**. All three
   have landed.
2. **Part 2** triages every *behavioural* upstream commit newer than the roadmap's
   2026-06-18 observation cutoff (plus the same-day 2026-06-17 commits the cutoff
   missed), with the two multi-monitor commits deep-dived.

Nehir-side evidence was verified against the main Nehir source tree at `54d5dd7e`
on 2026-06-25. Upstream commits are cited by hash + title and were read directly
from `BarutSRB/OmniWM`. No Nehir source was modified; this is planning only.

---

## Part 1 — Landed-status correction (roadmap is stale for M4-S2 / M6 / A1)

All three rows the roadmap marks `not started` are in fact `landed`. Evidence is
grepped symbol-for-symbol against `main` at `54d5dd7e`.

### Correction table

| ID | Roadmap status (stale) | Real status | Commit | Date | Residual scope vs. the planned doc |
| --- | --- | --- | --- | --- | --- |
| **M4-S2** | not started | **landed** | `4ae5fc96` "Exempt managed windows on inactive native Spaces from full-rescan eviction" | 2026-06-22 | (a) **no** stale-retention safety cap (intentional; still no `exemptCount`/max-exemption counter); (b) **scope expansion** — a second integration site `isWindowOnAllKnownSpaces` for workspace-switch parking, beyond the plan's full-rescan-only scope; (c) follow-ups (event-driven `SpaceTracker`, native-fullscreen reconciliation, mouse-warp/topology integration) still out of scope |
| **M6** | not started | **landed** | `42ac731f` "Prevent stale async session patches from overwriting newer selection (M6)" | 2026-06-22 | (a) **`ManagedFocusOrigin` still not added** (deferred to A4 per roadmap decision #4 and M6 OQ-3); (b) cross-workspace clear resolved as **cancel + reissue**, not rekey (OQ-1 closed); (c) `selectionRevision` placed in per-workspace session state (OQ-2 closed as recommended) |
| **A1** | not started | **landed** | `b1844dd8` "Extract pure layout reducer and drive move demo through it" (+ runtime-bridge follow-ups `98d00e4c`, `c2915f44`, `0022936f`, `0547046a`) | 2026-06-19 → 2026-06-20 | **Scope expansion beyond the plan**: the live runtime `NiriLayoutEngine` now routes focus/move *decisions* through `PureLayoutReducer` — which the planned A1 doc listed four times as an explicit non-goal. A2–A5 otherwise remain deferred |

### M4-S2 — landed detail

Verified symbols at `54d5dd7e`:

- `Sources/Nehir/Core/SkyLight/SpaceTopology.swift` exists. Predicate landed as
  `func isWindowOnKnownInactiveNativeSpace(windowId:preferredSpaceId:)` (renamed
  from the plan's `isWindowOnKnownInactiveSpace`, and it now takes a
  `preferredSpaceId`).
- `Sources/Nehir/Core/Controller/LayoutRefreshController.swift:184` keeps the
  test seam `var spaceTopologyProviderForTests: (([Monitor], [UInt32]) -> SpaceTopology)?`
  and the exemption block (`var inactiveSpaceExemptions = 0` at `:1522`,
  `spaceTopology.exempt ... mode=` trace event, `lastSpaceTopologyDebugSummary`).
- `Sources/Nehir/Core/SkyLight/SkyLight.swift` resolves
  `SLSCopySpacesForWindows`/`CGSCopySpacesForWindows` and exposes
  `spacesForWindow(_:)`, `managedDisplaySpaces(monitors:)`,
  `ManagedDisplaySpacesSnapshot` — exactly the SkyLight surface the plan called for.
- Tests: `Tests/NehirTests/SpaceTopologyTests.swift` + `RefreshRoutingTests` coverage.

**Scope expansion vs. plan (worth flagging):** a *second* `SpaceTopology` consumer
beyond full-rescan eviction — `func isWindowOnAllKnownSpaces(windowId:)`
(`SpaceTopology.swift:79`, doc-commented "workspace-switch parking — unlike
`isWindowOnKnownInactiveSpace`…"), consulted at `LayoutRefreshController.swift:713`.
The planned M4-S2 doc scoped only the full-rescan eviction path; the landed code
also exempts windows present on all known Spaces during workspace-switch parking.

**Residual (unchanged from plan):** the stale-retention safety cap the plan listed
as an out-of-scope follow-up did **not** land — grep for
`exemptCount|maxExempt|exemptionCap|consecutiveExempt` in
`LayoutRefreshController.swift` / `SpaceTopology.swift` returns nothing. Field
testing on a real Separate-Spaces host is still the trigger for adding it.

### M6 — landed detail

The full M6 design from `20260618-stale-session-selection-revision-guard.md`
landed. Verified at `54d5dd7e`:

- `var selectionRevision: UInt64 = 0` on `WorkspaceSession`
  (`Sources/Nehir/Core/Workspace/WorkspaceManager.swift:160`).
- `var plannedSelectionRevision: UInt64? = nil` on `WorkspaceSessionPatch`
  (`Sources/Nehir/Core/Layout/LayoutBoundary.swift:107`).
- Accessors `selectionRevision(for:)` / `bumpSelectionRevision(for:)` and the
  live-mutation wrapper `mutateSelection(for:_:)`
  (`WorkspaceManager.swift` ~`:3352`, `:3506`).
- Guard at apply (`WorkspaceManager.applySessionPatch`, `:1756`):
  `if let plannedRevision = patch.plannedSelectionRevision, plannedRevision < selectionRevision(for: …)` → drop only selection fields + `rememberedFocusToken`, preserving `viewOffsetPixels` (narrower than the gesture guard, as designed).
- Stamp at capture in `NiriLayoutHandler.swift:920`:
  `plannedSelectionRevision: controller?.workspaceManager.selectionRevision(for: pass.wsId)`.
- Cross-workspace stale-pending-focus clear: `WMController.reassignManagedWindow`
  (`WMController.swift:4188`) calls `focusBridge.discardPendingFocus(token)`
  (`:4203`); the move/reassign path additionally cancels the matching managed
  request — `focusBridge.cancelManagedRequest(matching: token, workspaceId: …)`
  + `discardPendingFocus(token)` (`WMController.swift:4459-4460`).

**Residual / deferred (unchanged):** `ManagedFocusOrigin` (the M3 decision #4 /
M6 OQ-3 deferral) is still **not** introduced; it remains queued for A4, which
enriches `ManagedFocusRequest`. M6 task 6 therefore took the cancel-and-reissue
shape (callers already reissue) rather than an origin-aware rekey.

### A1 — landed detail (with a scope expansion the planned doc did not authorise)

Phases 1–5 of `20260619-pure-niri-engine-extraction-a1.md` landed at `b1844dd8`:

- Pure core: `Sources/Nehir/Core/PureLayout/PureDirection.swift`,
  `PureLayoutModels.swift`, `PureLayoutReducer.swift`, `PureLayoutInvariants.swift`
  (all `Provenance=nehir-original`).
- `PureLayoutReducerTests` / `PureLayoutAgreementTests` / `PureLayoutBoundaryTests`
  (phases 1, 2, 5).
- Onboarding delegation (phase 3): `MoveDemoModel` stores
  `@Published private var world: CoreWorld<Int, Int>` and every
  focus/move/switchWorkspace call goes through `PureLayoutReducer.focus/.moveFocusedWindow/.switchWorkspace`.
- Phase 4 model regression tests: `Tests/NehirTests/InteractiveMoveDemoModelTests.swift`.

**Scope expansion (the important deviation).** The planned A1 doc states four
times: *"Do not refactor the live runtime command path in A1"* / *"No live
runtime command-path refactor"*. The landed code does exactly that, via a new
Nehir-original bridge:

- `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+PureLayoutBridge.swift`
  (`nehir-original`) maps the live Niri tree to/from `CoreWorld<…, WindowToken>`
  and exposes `pureLayoutFocusTarget(direction:…)` and
  `pureLayoutMoveDecision(_:direction:…)` → `PureLayoutMovePlan`
  (`.noChange`/`.verticalSwap`/`.horizontalExpel`/`.horizontalConsume`/`.unsupported`).
- It is wired into the **production** runtime:
  - focus: `Sources/Nehir/Core/Layout/Niri/NiriNavigation.swift:257`
    `switch pureLayoutFocusTarget(…)`.
  - move: `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+WindowOps.swift:36`
    and `NiriLayoutEngine+ColumnOps.swift:492` both call `pureLayoutMoveDecision(…)`.
- The bridge carries a snapshot-divergence assertion (`assertPureLayoutSnapshotMatches`,
  `pureLayoutBridgeLogger`) so the real engine and the pure reducer stay in lockstep —
  i.e. the pure reducer is now the *decision engine*, not merely an onboarding/demo oracle.

This pulls A2's "runtime consumes the core" territory into A1. It is not a defect,
but it invalidates the planned A1 doc's "non-goal" framing. A2 (effect-plan
interpreter / `LayoutPlan` boundary) is still not done; A3–A5 remain deferred; no
`WorldStore`/`EventIntake`/`IntentLedger` port (as the roadmap insists).

---

## Part 2 — Post-cutoff upstream candidate triage

Cutoff = the roadmap's 2026-06-18 observation. Newer behavioural commits only;
pure branding/UX-redesign ("Omni Sponsors", status-bar Control-Center grid),
release bumps (`078b57d` 0.5.0, `bc69e97` 0.5.1), "Docs: New Stuff", "Script: Fix",
"Cleanup: Small cleanup", and the README "related forks" note are excluded. Merge
commit `1b6421a` is folded into its PR `b8afccb`.

**Verdict legend:** 🔴 worth porting · 🟡 conditional-investigate / product-gated · 🟢 already-have / skip / N/A.

### Triage table

| Upstream commit | One-line change | Nehir-equivalent already present? | Overlap / conflict | Verdict | Effort | Nehir files |
| --- | --- | --- | --- | --- | --- | --- |
| `b8a545f` Cross directional focus to adjacent monitor at workspace edge | Directional focus (↑↓←→) dead-ending at a workspace boundary now falls through to the physically-adjacent monitor; picks the window nearest the crossing edge via pure `spatialNeighborToken`; gated by `focusCrossesMonitorAtEdge` (default off). `LayoutFocusable.focusNeighbor` now returns `Bool` and `CommandHandler` crosses only when it did **not** move. | **No.** Nehir's cross-workspace+cross-monitor focus is **history-based** (`30faf8f3` "Focus Previous Window crosses workspaces and monitors" → `focusPrevious()`), not directional. `.focus(direction)` (`CommandHandler.swift:55-56`) calls `focusNeighbor(direction:)` (returns `Void`) and dead-ends. There is no `focusCrossesMonitorAtEdge` setting and no directional `focusMonitor(direction:)` (grep empty). Nehir **does** have every building block: `adjacentMonitor(from:direction:wrapAround:)` (`WorkspaceManager.swift:3409`), `insetWorkingFrame(for:)` (`WMController.swift:879`), `preferredKeyboardFocusFrame(for:)` (`WMController.swift:4554`), `tiledEntries(in:)`, `rememberFocus(_:in:)`, and `switchToMonitor`. | **Compatible, complementary.** Reuses Nehir's existing adjacency + monitor-switch seams; does not touch M3/M6. Complements (not duplicates) `30faf8f3` history-based focus. | **🔴** | S–M | `Sources/Nehir/Core/Controller/WorkspaceNavigationHandler.swift` (new `focusMonitor(direction:)` + `spatialNeighborToken`), `Sources/Nehir/Core/Controller/LayoutCoordinator.swift` + `NiriLayoutHandler.swift` (`focusNeighbor` → `Bool`), `Sources/Nehir/Core/Controller/CommandHandler.swift` (escalation), `Sources/Nehir/Core/Config/SettingsStore.swift` + a settings tab (`focusCrossesMonitorAtEdge`) |
| `be443f1` Monitor routing + mouse-warp unification (+ repo-wide GPL headers) | Three behaviours squashed into one commit: (1) cross-monitor **window move** at the workspace edge; (2) a configurable **grid routing** model (`MonitorRouting.gridAdjacent`) + macOS arrangement-canvas editor, replacing physical-only adjacency; (3) **mouse-warp unified** onto that routing model (`MouseWarpHandler` rewritten +27/-420, `MouseWarpAxis` retired, pure `MouseWarpGeometry` extracted). | **Partial / divergent.** Nehir has **physical** `adjacentMonitor(from:direction:)` and the CAT-4 `MonitorGapSettings.swift` (from this same upstream's `dacccb8`). Nehir **lacks**: grid routing + arrangement canvas (grep for `MonitorRouting`/`gridAdjacent`/`MonitorArrangementCanvas` empty); cross-monitor **window-move-at-edge** (`moveWindowToMonitor` grep empty — Nehir only swaps/moves *workspaces* to a monitor); and it **still ships `Sources/Nehir/Core/Config/MouseWarpAxis.swift`** with an axis-based `MouseWarpHandler` that M3 diverged (FFM suppression). | **Mouse-warp half CONFLICTS with M3.** Unification retires the axis model Nehir still uses and re-derives warps through edge geometry — a concept-port, not a line-port, and M3's `isFFM` gate must be re-built on top. Grid routing is a different product direction (user-configurable logical grid vs Nehir's physical-arrangement-first diagnostics). | **🟡** (split — see deep-dive) | see deep-dive below |
| `e42751b` Harden rapid focus navigation (+ `b8afccb` Fix rapid Niri focus desync) | Makes command-selected focus **synchronous** before relayout (call `focusWindow` before `requestLayoutCommandRelayout`, not as a post-layout completion) so rapid keypresses can't stale-drop the final focus intent. `b8afccb` is the predecessor PR; `e42751b` renames to `focusSelectedWindowAndRequestRelayout` and extends to Dwindle. | **Covered by M6 (different mechanism).** Nehir already solves the same root cause — stale selection overwriting a newer one — with the M6 `plannedSelectionRevision` guard, and `focusNeighbor` routes focus through `applySessionPatch` (revision-stamped), not a stale post-layout closure. | Same bug class as M6; Nehir's revision-guard approach is the stronger fix. Only residual: audit Nehir's remaining *direct* `controller?.focusWindow(token)` post-layout closures (`NiriLayoutHandler.swift:1758`, `:1981`) for the same stale-token shape. | **🟢** | XS (audit only) | none required; optional `NiriLayoutHandler.swift` audit |
| `e399415` Runtime diagnostics, tracing, and issue-report subsystem | Dev-Mode diagnostics report, ring-buffered runtime trace (AX/frame-apply/mouse/Niri/input), crash capture, window-classification fixtures, `AXWindowDump`, Report-Issue GitHub flow w/ optional FoundationModels rewrite; replaces IPC debug queries (IPC protocol 5→6). | **Yes — Nehir's own.** `Sources/Nehir/Core/Diagnostics/BackgroundTraceBuffer.swift` (ring buffer), `DebugBarManager`, `DisplayDiagnosticsSettingsTab`, `runtimeStateDebugDump` throughout, and a planned Report-Issue flow (`planned/20260621-send-reports.md`), plus trace-clip work (`completed/20260624-recent-trace-clip-buffer.md`). | Parallel implementations of the same subsystem. Nehir's is Nehir-original and already shipping. | **🟢** | — | none (possible minor idea-borrow of `AXWindowDump` only, not a port) |
| `fe29d2a` App rules for bundleless apps | Match windows by app name / title / axRole / axSubrole when the runtime bundle id is unavailable; bundle id stays the strongest anchor; reject unanchored rules; fetch titles only for bundleless windows. | **Mostly already present.** Nehir's `WindowRuleEngine` already matches `appNameSubstring` / `titleSubstring` / `titleRegex` / `axRole` / `axSubrole` when bundle id is absent (`WindowRuleEngine.swift:242-270`, via `nonEmpty(_:)` fall-through). | Overlap is near-total on the matching side. Marginal adds only: `hasBundleId`/`hasIdentifyingMatcher`/`displayLabel` helpers, reject-unanchored-rules hardening, bundle-anchored specificity (`score += 2`). | **🟢** | XS | (optional) `Sources/Nehir/Core/Config/AppRule.swift`, `Sources/Nehir/Core/Rules/WindowRuleEngine.swift` |
| `569cbde` Side-specific hotkey modifiers | Left-vs-right modifier-specific bindings (distinguish physical Left Cmd from Right Cmd via `NX_DEVICEL{CTL,ALT,SHIFT,CMD}KEYMASK`); side-pinned bindings dispatch through an event tap, either-side stays on Carbon. New `CommandHotkeyTapMatcher` + `ModifierFlagMask`. | **No** (grep for `sideSpecific`/`leftModifier`/`CommandHotkeyTapMatcher` empty). | Genuine gap, but niche; Nehir's hotkey stack has its own shape (choru chord work is planned, not upstream's Hyper). | **🟡** | M | only on user request — `Sources/Nehir/Core/Input/` (new matcher) + `HotkeyBinding.swift` |
| `1aadf76` Redesign Hyper as a literal chord + optional System Hyper Trigger | Rebuilds the Hyper key as a literal chord, adds `CapsLockToggler`, rewrites `Hotkeys.swift` (-929) and `KeyRecorderView`. | **N/A — Nehir has no Hyper.** Grep for `hyperKey`/`systemHyper`/`hyperTrigger` in Nehir returns nothing; Hyper is one of the upstream product assumptions Nehir intentionally removed (roadmap "Why not wholesale WorldStore"). | None. | **🟢** | — | none |
| `1715013` Use shared fullscreen layout frame | OmniWM-fullscreen and single-window "Fill Screen" share one gapless, UI-safe layout frame; normal tiling stays gap-respecting. Fixes #373. | **Tracked separately (Nehir-native).** Nehir has no `fullscreenFrame`/`fillScreen` vocabulary, but it owns the adjacent problem: `discovery/20260617-omniwm-373-smart-gaps-single-window.md` is 🔴 Open (drop outer gaps for a lone window), and the fullscreen roadmap (`planned/20260622-fullscreen-behaviour-roadmap.md`, `planned/20260621-niri-fullscreen-expectations-and-fix.md`) is Nehir's own native-fullscreen + Nehir-fullscreen model. | Overlaps Nehir's tracked #373 + fullscreen roadmap; Nehir should solve in its own vocabulary, not port. | **🟡** | — | fold into Nehir's fullscreen/smart-gaps roadmap, do **not** port |
| `042a67d` Unify single-window sizing into Full Screen / Custom / Column Width | Replaces two near-duplicate single-window ratio enums (Dwindle + Niri) with one `SingleWindowFit` model; fixes a Dwindle `0/0 = NaN` lone-window mis-size stuck after cross-workspace move. | **N/A on the Dwindle half.** Nehir removed Dwindle; its Niri lone-window sizing is already one model — `LoneWindowPolicy` (`MonitorNiriSettings.swift:17`) + `loneWindowLayoutWidthOverride` / `fullWidthToggle` (`NiriLayoutEngine+Sizing.swift`). | The NaN bug class is Dwindle-specific and does not apply. Nehir's lone-window semantics are tracked in `planned/20260621-window-width-vs-column-width-semantics.md`. | **🟢** | — | none |
| `a1ca576` Allow uncapped workspace bar offsets | Removes the ±500 px cap from global + per-monitor workspace-bar offset steppers. | **Nehir still caps.** `Sources/Nehir/UI/WorkspaceBarSettingsTab.swift` still has `range: -500 ... 500` at four sites (`:131`, `:143`, `:380`, `:392`). | Trivial gap, low value. | **🟢** (trivial follow-up) | XS | `Sources/Nehir/UI/WorkspaceBarSettingsTab.swift` (drop 4 ranges) |
| `dacccb8` Fix multi-monitor gap resolution | Multi-monitor gap resolution. | **Already caught** — CAT-4 `Sources/Nehir/Core/Config/MonitorGapSettings.swift` (provenance `02-borrowed-later.md`). | — | **🟢** | — | none |

### Deep-dive — the two multi-monitor commits

The maintainer has a strong interest in multi-monitor behaviour, so these two are
read in full.

#### `b8a545f` "Cross directional focus to the adjacent monitor at a workspace edge" — 🔴 worth porting

**What it changes (read from the diff):**

- `LayoutFocusable.focusNeighbor(direction:)` becomes `-> Bool` (did focus move?).
  `Sources/OmniWM/Core/Controller/LayoutCapabilities.swift`.
- `CommandHandler` `.focus(direction)`: if `focusNeighbor(…) != true` **and**
  `settings.focusCrossesMonitorAtEdge`, call
  `workspaceNavigationHandler.focusMonitor(direction:)`.
- `WorkspaceNavigationHandler.focusMonitor(direction:)`: resolve the target via
  `adjacentMonitor(from:direction:)`, pick the landing window with the pure
  `spatialNeighborToken(from:candidates:direction:targetFrame:)` (cross-axis
  overlap → edge distance → cross-axis center proximity; AeroSpace-style), then
  `rememberFocus` + `switchToMonitor`.
- New opt-in setting `focusCrossesMonitorAtEdge` (default **off**), persisted under
  `[focus]`, surfaced in the status-bar focus toggles. No-op on a single monitor
  or at an outer edge.

**Nehir-equivalence (the decisive field):** Nehir does **not** have directional
cross-monitor focus. Its cross-workspace+cross-monitor capability is the
history-based `focusPrevious` (`30faf8f3`, 2026-06-22). Directional
`.focus(direction)` dead-ends (`CommandHandler.swift:55-56` →
`layoutCoordinator.focusNeighbor(direction:)`, returns `Void`). There is no
`focusCrossesMonitorAtEdge` setting and no `spatialNeighborToken` (greps empty).

But Nehir already owns **every primitive** this port needs: `adjacentMonitor(from:direction:)`,
`insetWorkingFrame(for:)`, `preferredKeyboardFocusFrame(for:)`, `tiledEntries(in:)`,
`rememberFocus(_:in:)`, `activeWorkspaceOrFirst(on:)`, and `switchToMonitor`. The
`focusNeighbor → Bool` change is a small protocol edit
(`Sources/Nehir/Core/Controller/LayoutCoordinator.swift:21`).

**Compatibility:** divergent from upstream's *file layout* (Nehir routes through
`LayoutCoordinator`, upstream through `LayoutFocusable`), but **semantically
compatible and non-conflicting** with M3 (FFM warp) and M6 (revision guard). It
complements `30faf8f3` rather than duplicating it (directional vs history).

**Verdict: 🔴.** High multi-monitor value, opt-in/default-off (low regression risk),
reuses Nehir primitives. This is the single best backport candidate in this sweep.

#### `be443f1` "Add monitor routing and mouse-warp unification" — 🟡, split into three

The commit is squashed from ten; the +3-line noise is repo-wide GPL-2.0 headers
(provenance-relevant: it formalises upstream's `Copyright (C) 2026 BarutSRB`
header). The behavioural payload is three distinct things, each with a different
Nehir verdict:

1. **Cross-monitor window move at the workspace edge** — 🟡 (leaning 🔴).
   Nehir has *workspace*-to-monitor move/swap
   (`swapCurrentWorkspaceWithMonitor(direction:)`, `planned/20260619-nehir-62-move-workspace-to-monitor.md`)
   but **no** move-the-focused-*window*-to-the-adjacent-monitor (grep empty).
   Genuine gap; same edge-crossing theme as `b8a545f`, so the two pair naturally.

2. **Grid routing model + arrangement canvas** — 🟡 (product decision).
   `MonitorRouting.gridAdjacent(from:direction:layout:monitors:wrapAround:)`
   resolves adjacency off a user-editable grid (`gridColumn`/`gridRow` per monitor,
   `seedLayout` from physical centres), exposed via a `MonitorArrangementCanvas` +
   `MonitorArrangementGeometry` editor. Nehir's multi-monitor model is
   **physical-arrangement-first** (arrangement diagnostics recommend matching
   physical layout; `discovery/20260618-separate-spaces-and-monitor-arrangement.md`).
   A user-configurable logical-grid *override* is a different product direction
   worth a maintainer decision before any port. Touches a lot of UI + config.

3. **Mouse-warp unification** — 🟡 (conflicts with M3).
   `MouseWarpHandler` is rewritten (+27/-420) onto `MonitorRouting.gridAdjacent` +
   a pure `MouseWarpGeometry` (edge-crossing `Crossing` detection +
   `destinationPoint(on:entryEdge:ratio:)`). `MouseWarpAxis` (`.horizontal`/
   `.vertical`) is **retired**. Nehir still ships `Sources/Nehir/Core/Config/MouseWarpAxis.swift`
   and an axis-based `MouseWarpHandler` that M3 (`51f86e84`) diverged with FFM
   suppression. A direct port would **regress M3**; it must be a concept-port that
   re-derives the `isFFM` gate on top of edge-geometry. The pure
   `MouseWarpGeometry` helper is the one cleanly portable piece.

**Net:** not a single port. Treat (1) as a 🔴-leaning 🟡 that pairs with `b8a545f`,
(2) as a product-gated 🟡, (3) as a 🟡 that needs an M3-compatibility spike. Do not
attempt the squashed commit wholesale.

---

## Part 3 — Provenance notes (worth-porting set)

For each candidate judged 🔴 or 🟡-worth-investigating, upstream provenance and the
foreseeable Nehir destination category (per `provenance/README.md` cat 1–5; most
are cat-2 edits or cat-4 borrowed-later if a new file is introduced). These feed
`.provenance.json` and the SPDX headers on `main` once landed.

| Candidate | Upstream commit + title | Upstream path(s) | Nehir destination category |
| --- | --- | --- | --- |
| `b8a545f` directional cross-monitor focus | `b8a545f` "Cross directional focus to the adjacent monitor at a workspace edge" | `Sources/OmniWM/Core/Controller/WorkspaceNavigationHandler.swift` (`focusMonitor` + `spatialNeighborToken`), `CommandHandler.swift`, `LayoutCapabilities.swift` | `focusMonitor(direction:)` escalation + `focusNeighbor→Bool` + `focusCrossesMonitorAtEdge` setting = **cat-2** edits to existing Nehir files. The pure `spatialNeighborToken` helper, if vendored near-verbatim into a new Nehir location, = **cat-4** (borrowed-later); if Nehir re-expresses it inline = **cat-5** (nehir-original). Recommend vendoring the tested pure helper and classifying it **cat-4**. |
| `be443f1` (1) cross-monitor window move | `be443f1` "Add monitor routing and mouse-warp unification …" (squashed sub-commit "Add cross-monitor window move at the workspace edge") | `Sources/OmniWM/Core/Controller/WorkspaceNavigationHandler.swift`, `NiriLayoutHandler.swift`, `WMController.swift` | **cat-2** edits to Nehir's `WorkspaceNavigationHandler.swift` / `NiriLayoutHandler.swift` (the move-at-edge escalation). |
| `be443f1` (2) grid routing + canvas | `be443f1` (sub-commit "Add monitor routing settings, grid resolver, and macOS arrangement canvas" / "Add custom monitor routing arrangement editor and wire resolver") | `Sources/OmniWM/Core/Monitor/MonitorRouting.swift`, `Sources/OmniWM/Core/Config/MonitorRoutingSettings.swift`, `Sources/OmniWM/UI/MonitorArrangementCanvas.swift`, `Sources/OmniWM/UI/MonitorArrangementGeometry.swift`, `Sources/OmniWM/UI/MonitorSettingsTab.swift` | New Nehir files from a later upstream commit → **cat-4** if vendored near-verbatim; the resolver is pure enough to also be a **cat-5** re-expression. Product-gated; decide before classifying. |
| `be443f1` (3) mouse-warp unification | `be443f1` (sub-commit "Unify mouse warp onto monitor routing and retire warp order/axis") | `Sources/OmniWM/Core/Controller/MouseWarpHandler.swift`, `Sources/OmniWM/Core/Controller/MouseWarpGeometry.swift` (new); deletes `Sources/OmniWM/Core/Config/MouseWarpAxis.swift` | `MouseWarpHandler.swift` rewrite = **cat-2/3** (Nehir file, significantly modified, M3 divergence must be preserved); `MouseWarpGeometry.swift` if vendored = **cat-4**. This is a concept-port, not a line-port. |
| `569cbde` side-specific modifiers | `569cbde` "Add side-specific hotkey modifiers" | `Sources/OmniWM/Core/Input/CommandHotkeyTapMatcher.swift` (new), `HotkeyBinding.swift`, `Hotkeys.swift`, `KeySymbolMapper.swift`, `UI/HotkeySettingsView.swift` | `CommandHotkeyTapMatcher` if vendored = **cat-4**; the binding/setting plumbing = **cat-2**. Low priority. |
| `1715013` shared fullscreen frame | `1715013` "Use shared fullscreen layout frame" | `Sources/OmniWM/Core/Layout/Niri/NiriLayout.swift`, `NiriLayoutEngine.swift`, `LayoutBoundary.swift`, `WMController.swift` | Not a port — fold into Nehir's native fullscreen/#373 roadmap. If any snippet is borrowed, **cat-2** into Nehir's fullscreen path. |

`a1ca576` (uncapped offsets) and `e42751b`/`b8afccb` (rapid focus) carry no
upstream provenance obligation if acted on: the former is a trivial Nehir-local
cap removal, the latter is already covered by M6 (Nehir-original revision guard).

---

## Part 4 — Recommendation: what to backport next, sequenced

1. **`b8a545f` — directional focus crosses to the adjacent monitor (🔴, first).**
   Cleanest, highest multi-monitor value, opt-in/default-off, reuses Nehir
   primitives (`adjacentMonitor`, `insetWorkingFrame`, `preferredKeyboardFocusFrame`,
   `tiledEntries`, `rememberFocus`, `switchToMonitor`). One protocol change
   (`focusNeighbor → Bool`) + one new handler + one setting. Stands alone; no M3/M6
   interaction.

2. **`be443f1` sub-part (1) — cross-monitor window move at edge (🟡→🔴, pair with #1).**
   Same edge-crossing theme; Nehir has workspace-to-monitor but not window-to-monitor.
   Land alongside #1 so the edge-crossing UX is consistent for both focus and move.

3. **`be443f1` sub-part (3) — `MouseWarpGeometry` helper only (🟡, spike).**
   Port the pure edge-crossing helper as a cat-4 file, then spike whether Nehir's
   axis-based `MouseWarpHandler` (M3-diverged) can adopt edge-geometry **without**
   regressing the `isFFM` warp gate. Do **not** retire `MouseWarpAxis` until that
   spike confirms M3 survives. Defer the full unification.

4. **`be443f1` sub-part (2) — grid routing + arrangement canvas (🟡, product-gated).**
   Needs a maintainer decision: user-configurable logical-grid routing vs Nehir's
   physical-arrangement-first model. Do not start before that decision; it is the
   largest surface in this sweep (UI + config + resolver).

5. **`569cbde` side-specific modifiers (🟡) / `a1ca576` uncapped offsets (🟢 trivial).**
   Both low priority; pick up only on a user request (modifiers) or if someone
   actually hits the ±500 cap (offsets — a 4-line removal).

**Explicitly do NOT port:** `1aadf76` (Nehir has no Hyper), `042a67d` (Dwindle half
N/A, Nehir lone-window model already unified), `e399415` (Nehir has its own
Diagnostics subsystem), and `1715013` (solve in Nehir's own fullscreen/#373 roadmap).
WorldStore / EventIntake / IntentLedger remain off-limits per the roadmap.

**Recommended next planning artifact:** a per-cluster discovery doc for **#1 + #2**
(directional cross-monitor focus + window-move-at-edge) modelled on the roadmap's
existing focus-lane docs, since they share the `adjacentMonitor` + edge-crossing
seam and are the clear next multi-monitor increment.
