# Upstream post-roadmap candidates — 0.5.4 / 0.5.5 / 0.5.6 sweep (2026-07-07 → 2026-07-14)

Fifth post-roadmap triage of `BarutSRB/OmniWM` against Nehir `main`. It continues
the running backport-tracking loop established by the canonical roadmap
([`20260618-upstream-port-roadmap.md`](20260618-upstream-port-roadmap.md)) and the
previous sweep ([`20260707-upstream-post-roadmap-candidates.md`](20260707-upstream-post-roadmap-candidates.md)).

**Sweep range:** every upstream commit after the previous sweep's cutoff `38987c81`
("Keep Quake Terminal centered after display changes") through current upstream
`main` HEAD `be68cfbf` ("Release 0.5.6"). 28 commits total across releases
**0.5.4**, **0.5.5**, **0.5.6**; 22 are behavioural, the rest are
release/docs/merge noise (`0864ddd1`, `36e823a9`, `be68cfbf`, `420da776`,
`22cf3e0a`).

Nehir-side evidence was verified against the main Nehir source tree at `3056bee8`
on 2026-07-14. Upstream commits were read directly from `BarutSRB/OmniWM` via the
`upstream` remote. No Nehir source was modified; this is planning only.

**Method note.** Unlike prior single-agent sweeps, this loop was run as four
parallel, non-overlapping triage lanes (focus/FFM/directional; layout/Niri/Overview;
trackpad/gestures/bar; runtime/Hidden-Bar/admission), then synthesised and
re-verified here. The two headline findings below (`6808e44c` observer reinstall;
`e1ec597c` directional eligibility) were independently re-checked against source
during synthesis.

**State change since last sweep — Nehir now ships an Overview.** The prior sweeps
recorded Nehir as having no exposé/Overview feature. That is now stale: `main` has
a keyboard-opened, multi-monitor Overview with drag/drop move and close
(`Sources/Nehir/Core/Overview/OverviewController.swift`, `OverviewInputHandler.swift`,
bound to Option-Command-O in `Sources/Nehir/Core/Input/ActionCatalog.swift:787-793`).
This flips several upstream Overview commits/issues from "feature port" to
"already-have" — see the Overview rows below.

**Verdict legend:** 🔴 worth porting · 🟡 conditional-investigate / verify / fold-in · 🟢 already-have / skip / N/A.

---

## Commit triage table

| Upstream commit | One-line change | Nehir-equivalent already present? (file:line) | Verdict | Effort | Nehir files |
| --- | --- | --- | --- | --- | --- |
| `6808e44c` Stabilize event intake and service restarts — **observer reinstall subset** | Make launch/termination observer install idempotent and reinstall after a service restart. | **Confirmed latent bug.** `AXManager.init()` is the only caller of `setupTerminationObserver()`/`setupLaunchObserver()` (`Sources/Nehir/Core/Ax/AXManager.swift:88-89`); `cleanup()` removes and nils both observers (`AXManager.swift:418-427`); `ServiceLifecycleManager.startServices()` re-wires the `onAppLaunched`/`onAppTerminated` closures but never reinstalls the NSWorkspace observers (`Sources/Nehir/Core/Controller/ServiceLifecycleManager.swift:77-95`). After a disable→enable or AX-permission-toggle cycle, app launch/termination detection is silently lost until full relaunch. | **🔴** (real bug, top priority) | S | `Sources/Nehir/Core/Ax/AXManager.swift`, `Sources/Nehir/Core/Controller/ServiceLifecycleManager.swift` |
| `e1ec597c` Fix directional focus jumping across vertically stacked monitors at workspace edges | Treat a monitor as directional only when the requested-axis delta dominates the perpendicular delta. | **No.** `adjacentMonitor` accepts any monitor with merely signed `dx`/`dy` (`Sources/Nehir/Core/Workspace/WorkspaceManager.swift:3715-3722`), so a vertically-stacked-but-horizontally-offset display is wrongly eligible for left/right. | **🔴** | XS | `Sources/Nehir/Core/Workspace/WorkspaceManager.swift` |
| `17f4872d` Cover offset stacked monitors in directional routing | Regression coverage that horizontal commands ignore vertically stacked but horizontally offset displays. | **No** — same signed-delta gap as `e1ec597c`; ranking only orders candidates after eligibility (`WorkspaceManager.swift:3807-3832`). | **🔴** (fold into `e1ec597c`) | XS | `Sources/Nehir/Core/Workspace/WorkspaceManager.swift`; new behaviour test under `Tests/NehirTests/` |
| `b243d36f` Keep the pointer where users click | Do not warp to a focused window's center when the pointer is already inside it. | **Partial.** `moveMouseToWindow` unconditionally computes `frame.center` and warps after only off-screen/button checks; its current-location read is diagnostics-only (`Sources/Nehir/Core/Controller/WMController.swift:3983-4025`). Complements the already-🔴 BarutSRB/OmniWM#446. | **🔴** | XS | `Sources/Nehir/Core/Controller/WMController.swift` |
| `eae140a9` Fix focus-follows-mouse focus steal beneath floating windows | Resolve hover from the authoritative WindowServer ID and focus the hovered floating window rather than the tile beneath it. | **Partial safety only.** Nehir detects a floating cover and returns `.occlusion`, preserving old focus rather than focusing the float; FFM target enum supports only Niri tiles (`Sources/Nehir/Core/Controller/MouseEventHandler.swift:1365-1391`, `:50-52`, `:1461-1500`). | **🔴** (behaviour upgrade: focus the float) | M | `Sources/Nehir/Core/Controller/MouseEventHandler.swift`, possibly `WMController.swift` |
| `f4903f89` Enforce app minimum sizes under the no-bleed invariant | Make application minimum sizes hard, including infeasible Niri columns and hidden windows. | **Partial.** Rule/inferred minimums merge into snapshots and clamp column width (`Sources/Nehir/Core/Controller/LayoutRefreshController.swift:561-573`, `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+Windows.swift:89-119`), but Nehir still relaxes hidden/oversized minimums for feasibility (`LayoutRefreshController.swift:601-629`) and the axis solver scales fixed tiles below their minima (`Sources/Nehir/Core/Layout/Niri/NiriConstraintSolver.swift:71-85`). Same gap as BarutSRB/OmniWM#268. | **🔴** | L | `LayoutRefreshController.swift`, `NiriConstraintSolver.swift`, `NiriLayout.swift`, `NiriLayoutEngine+ColumnOps.swift`, `NiriLayoutEngine+Windows.swift` |
| `4d0d45b0` Make trackpad scrolling stop when fingers stop | Drop projected-end deceleration; only a real flick glides (history window 0.150→0.080). | **Diverged (old model).** Nehir still uses `SwipeTracker.projectedEndPosition()` + `decelerationRate 0.997` + `historyLimit 0.150` (`Sources/Nehir/Core/Animation/SwipeTracker.swift:15-16,42-46`), consumed at `Core/Layout/Niri/ViewportState+Gestures.swift:132` and `MouseEventHandler.swift:2066`. No `AnimationDriver` exists to cherry-pick; port the *intent*. Already flagged BarutSRB/OmniWM#451 in the prior sweep. | **🟡** (verify/tune; port intent, not diff) | M | `SwipeTracker.swift`, `ViewportState+Gestures.swift`, `MouseEventHandler.swift` |
| `d25e8a36` Add trackpad workspace swipe with configurable fingers and axis | One-shot workspace-switch swipe with configurable finger count + axis, alongside column scroll. | **Absent as a mode.** Nehir's trackpad gesture is column-scroll only; no workspace-switch seam and no `workspaceSwipe*` config (`Sources/Nehir/Core/Controller/MouseEventHandler.swift`, `GestureFingerCount.swift`). Overlaps Nehir #53 but does not resolve it (that is the existing column-scroll matcher). | **🟡** (net-new config surface; product-gated) | L | `Sources/Nehir/Core/Multitouch/MultitouchGestureSource.swift`, `MouseEventHandler.swift`, `SettingsStore.swift`, `CanonicalTOMLConfig.swift`, `BehaviorSettingsTab.swift` |
| `b431b9b8` Show workspace bar only while holding keys | Reveal the workspace bar only while a chosen modifier combo is held, after a delay. | **Absent.** Bar visibility is a plain on/off `enabled` (`Sources/Nehir/Core/Config/MonitorBarSettings.swift:16`, `:160`); Nehir's `reveal*` symbols are viewport reveal, not bar visibility. No plan covers it. | **🟡** (net-new feature) | M–L | `MonitorBarSettings.swift`, `SettingsStore.swift`, `CanonicalTOMLConfig.swift`, new input monitor + `WorkspaceBarSettingsTab.swift`/`WorkspaceBarManager.swift` |
| `27f19d8a` Add keyboard-revealed configurable Overview | Keyboard-revealed Overview + configurable zoom/appearance. | **Core already shipped;** only configurable zoom is missing. Option-Command-O → `toggleOverview` (`Sources/Nehir/Core/Input/ActionCatalog.swift:787-793`), keyboard selection (`Sources/Nehir/Core/Overview/OverviewController.swift:620-635`); zoom hard-coded 0.5…1.5 on Option-Shift scroll (`OverviewController.swift:665-686`). | **🟡** (settings enhancement only) | M | `OverviewController.swift`, `SettingsStore.swift`, `CanonicalTOMLConfig.swift`, settings UI |
| `ea5d70e5` Add Niri-style Overview window management (BarutSRB/OmniWM#461) | Overview window move / column insertion / close. | **Already have.** Overview drag targets do workspace move / Niri insertion / column insertion (`Sources/Nehir/Core/Overview/OverviewController.swift:993-1035`); close-click dispatch (`Sources/Nehir/Core/Overview/OverviewInputHandler.swift:142-158`). | **🟢** | — | none |
| `b68bee7a` Preserve Niri widths across workspace moves | Preserve canonical Niri column width when moving a window to another workspace. | **Already planned.** `planned/20260621-omniwm-295-niri-window-width-preservation.md` owns it; the current move path still resets via `initializeNewColumnWidth` (`Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+WorkspaceOps.swift:40-50`); reusable state-copy helper exists (`NiriLayoutEngine+ColumnOps.swift:37-47`). `b68bee7a` is the upstream reference impl. | **🟡** (finish the planned work) | S | `NiriLayoutEngine+WorkspaceOps.swift`, `NiriLayoutEngine+ColumnOps.swift` |
| `bdde067c` Add initial Niri column width rules | Per-app initial Niri column-width rules. | **Already planned.** `planned/20260621-omniwm-283-per-app-initial-column-width.md` owns it; new columns currently receive only workspace default width (`Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine.swift:231-255`). `bdde067c` is the upstream reference impl. | **🟡** (finish the planned work) | M | `AppRule.swift`, `WindowRuleEngine.swift`, `NiriLayoutHandler.swift`, `NiriLayoutEngine.swift`, `NiriLayoutEngine+Windows.swift`, app-rule UI/IPC |
| `02251503` Scope layout ownership and focus per workspace | Scope layout roots, selection, focus, interaction state by workspace. | **Already present.** Roots keyed by workspace (`Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine.swift:152-157`); viewport/selection in `WorkspaceSession` (`Sources/Nehir/Core/Workspace/WorkspaceManager.swift:153-160`); stale patches rejected per workspace (`WorkspaceManager.swift:1778-1795`). | **🟢** | — | none |
| `5d33310c` Add tabbed window groups to Dwindle | Tabbed window groups for the Dwindle layout. | **N/A.** Nehir is Niri-only; its tabbed mode is Niri-column based (`Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+TabbedMode.swift:38-57`). No Dwindle source. | **🟢** | — | none |
| `c044f652` Rebuild Hidden Bar with safe activation and IPC v7 | New Hidden Bar subsystem; IPC wire protocol bumped to v7. | **N/A.** No Hidden Bar feature (grep `HiddenBar` empty); Nehir IPC has its own envelope + version query (`Sources/Nehir/IPC/IPCConnection.swift:169`, `IPCApplicationBridge.swift:47,75`). | **🟢** | — | none |
| `161b3f76` Fix Hidden Bar concealment fallback behavior | Hidden Bar fallback-icon tweak. | **N/A.** No Hidden Bar. | **🟢** | — | none |
| `50448dd4` Harden Quake surface callbacks and clipboard prompts | Ghostty surface callback ownership, OSC-52 clipboard, Cmd-1..9 keymap. | **N/A.** No embedded Quake/Ghostty terminal; Ghostty grep hits are external-app frame-refusal handling only. | **🟢** | — | none |
| `7dbe8f30` Remove dead runtime state and refresh architecture docs | Delete `AppBootstrapPlanner`, `WindowCapabilityProfile`, WorldStore fields dead after the upstream WorldStore rewrite. | **N/A.** Nehir still uses these files and never adopted WorldStore (🔵 strategic divergence, per the roadmap). | **🟢** | — | none |
| `08b3f7bc` Make previous window return across workspaces | Resolve Focus Previous against global MRU and switch workspace. | **Already have.** `findMostRecentlyFocusedWindow(..., in: nil)` then activates the target workspace/window (`Sources/Nehir/Core/Controller/NiriLayoutHandler.swift:1543-1576`), tested in `Tests/NehirTests/FocusPreviousCrossWorkspaceTests.swift`. | **🟢** | — | none |
| `e8f3ae45` Suppress cursor warping when focusing windows via mouse click | Carry click intent so click focus cannot trigger a focused-window cursor warp. | **Already have (token suppression).** Mouse-down marks the pointer target (`Sources/Nehir/Core/Controller/MouseEventHandler.swift:957-968`), settlement checks it (`NiriLayoutHandler.swift:254-264`), floating clicks covered (`MouseEventHandler.swift:1439-1459`). `b243d36f` remains the complementary geometric backstop. | **🟢** (mechanism differs; behaviour present) | — | none |
| `49846ac9` Keep the cursor on the chosen screen path | Optional custom-routing containment blocking crossings that violate a configured screen graph. | **Related, not equivalent.** Nehir has axis-specific ordered warp (`Sources/Nehir/Core/Config/SettingsStore.swift:691-713`, `Sources/Nehir/Core/Controller/MouseWarpHandler.swift:487-520`) but no routing-graph/containment setting. Net-new product/design decision. | **🟡** (design decision first) | M | `SettingsStore.swift`, `SettingsExport.swift`, `CanonicalTOMLConfig.swift`, `MouseWarpHandler.swift` |

### Runtime sub-findings from `6808e44c` (beyond the 🔴 observer reinstall)

- **AppAXContext stale-callback fencing — 🟡, M.** Nehir runs old resume-based context creation with async teardown and no callback-generation admission (`Sources/Nehir/Core/Ax/AppAXContext.swift:85`, `:136`, `:200`); cleanup destroys contexts via a detached `Task { @MainActor }` (`AXManager.swift:428`), leaving a window for stale callbacks. Nehir's existing generation registry (`AppAXContext.swift:36-62`) fences *frame writes*, a different concern. Confirm the window is hit before porting.
- **RunLoopJob serialization — 🟡, S.** Nehir carries the identical pre-fix atomic-flag / `weak var action` code the commit hardened (`Sources/Nehir/Core/Ax/RunLoopJob.swift:10-34`). Low-risk to port alongside the observer fix; confirm the cancel/execute race manifests first.
- Event-intake coalescing order, live-AX-ref stripping from trace, stopped-service work rejection: **🟢 N/A** — Nehir's intake path diverges, its `WMEvent` carries `WindowAdmissionContext` (no live `AXWindowRef`, `Sources/Nehir/Core/Reconcile/WMEvent.swift:51-66`), and services are already gated on `hasStartedServices`.

### Verdict tally (22 behavioural commits)

- 🔴 **worth porting / planning now:** 6 — `6808e44c` observer reinstall (real bug), `e1ec597c` + `17f4872d` directional eligibility, `b243d36f` cursor-inside no-warp guard, `eae140a9` FFM focus-the-float, `f4903f89` hard min-size semantics.
- 🟡 **verify / selective / feature-gated / already-planned:** 8 — `4d0d45b0` stop-on-fingers-stop scroll, `d25e8a36` workspace-swipe gesture, `b431b9b8` hold-to-show bar, `27f19d8a` configurable Overview zoom, `b68bee7a`/`bdde067c` already-planned width work, `49846ac9` screen-path containment, plus the two 🟡 `6808e44c` sub-findings.
- 🟢 **already-have / N/A:** the remaining commits (Overview move/close, per-workspace layout scoping, Dwindle tabs, both Hidden Bar commits, Quake, dead-state removal, focus-previous, click-warp suppression).

---

## Upstream issue / PR sweep (updated since 2026-07-06)

`gh issue list -R BarutSRB/OmniWM --state all --search "updated:>=2026-07-06"` (30 issues) and the open PRs. Rows already owned by existing Nehir docs are marked as such.

| Upstream issue / PR | Status | Coverage / Nehir applicability (file:line) | Verdict | Nehir files |
| --- | --- | --- | --- | --- |
| BarutSRB/OmniWM#474 directional hotkeys inverted on vertical monitors | open | Nehir derives portrait orientation from dimensions (`Sources/Nehir/Core/Monitor/Monitor.swift:65-73`) and remaps axes for `.vertical` (`Sources/Nehir/Core/Controller/Direction.swift:21-56`), but focus calls default horizontal (`NiriLayoutHandler.swift:1520-1528`, `Sources/Nehir/Core/Layout/Niri/NiriNavigation.swift:252-260`). Needs a rotated-display repro and a direction-contract decision. | **🟡** | `Direction.swift`, `NiriLayoutHandler.swift`, `NiriNavigation.swift` |
| BarutSRB/OmniWM#468 FFM no longer traverses to off-screen columns (since 0.5.5) | open | Nehir's FFM geometric hit-test requires the pointer inside a rendered frame (`Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+InteractiveResize.swift:65-92`); keyboard focus reveals off-screen targets, FFM cannot. Verify desired interaction before building. | **🟡** | `MouseEventHandler.swift`, `NiriLayoutEngine+InteractiveResize.swift`, `NiriNavigation.swift` |
| BarutSRB/OmniWM#457 stacked-monitor focus across edge | closed | Same signed-delta gap as `e1ec597c` (`WorkspaceManager.swift:3715-3722`). | **🔴** (fold into `e1ec597c`) | `WorkspaceManager.swift` |
| BarutSRB/OmniWM#456 FFM steals focus to tile beneath a floating window | closed | Nehir's floating-cover branch emits `.occlusion` and tests assert focus stays on the tile (`MouseEventHandler.swift:1375-1384`, `Tests/NehirTests/MouseEventHandlerTests.swift:2553-2558`). Upstream `eae140a9` now focuses the float. | **🔴** (with `eae140a9`) | `MouseEventHandler.swift` |
| BarutSRB/OmniWM#446 click focus warps cursor to center | closed | Already-🔴 from the prior sweep; `b243d36f` is the clean complementary backstop (`WMController.swift:3997-4025`). | **🔴** | `WMController.swift` |
| BarutSRB/OmniWM#447 Focus Previous across workspaces | closed | Already have (`NiriLayoutHandler.swift:1554-1576`); `08b3f7bc` does not change the verdict. | **🟢** | none |
| BarutSRB/OmniWM#472 / BarutSRB/OmniWM#471 singleWindowAspectRatio custom / column_width no effect | open / closed | Non-equivalent config model: Nehir uses `LoneWindowPolicy` with fill/centered UI (`Sources/Nehir/Core/Config/SettingsStore.swift:123-126`), applied single-window path centers the rect (`Sources/Nehir/Core/Layout/Niri/NiriLayout.swift:723-742`). | **🟢** | none |
| BarutSRB/OmniWM#469 move window up/down in Overview | closed | Overview drag/drop supports moves (`OverviewController.swift:993-1035`), but the command handler ignores non-toggle commands while Overview is open (`Sources/Nehir/Core/Controller/CommandHandler.swift:248-255`). Keyboard structural moves would be net-new. | **🟡** | `CommandHandler.swift`, `OverviewController.swift`, `HotkeyCommand.swift`, `ActionCatalog.swift` |
| BarutSRB/OmniWM#467 certain windows not being picked up | open | Nehir has admission recovery + omission diagnostics (`Sources/Nehir/Core/Ax/AXManager.swift:578-629`, `Sources/Nehir/Core/Controller/AXEventHandler.swift:4278-4357`). No landed upstream fix to port; no Nehir repro. | **🟡** (monitor) | none actionable yet |
| BarutSRB/OmniWM#461 move/close windows in Overview | closed | Already have (`OverviewInputHandler.swift:142-158`, `OverviewController.swift:993-1035`). | **🟢** | none |
| BarutSRB/OmniWM#460 stack indicators | open | Already present: tab-indicator width + tabbed-column overlays (`NiriLayoutEngine.swift:138-141`, `NiriLayoutHandler.swift:1291-1317`). | **🟢** | none |
| BarutSRB/OmniWM#459 keyboard Overview scroll + zoom settings | closed | Keyboard nav present; persisted/configurable zoom absent (`OverviewController.swift:73-79`, `:665-686`). | **🟡** (settings) | `OverviewController.swift`, `SettingsStore.swift`, `CanonicalTOMLConfig.swift` |
| BarutSRB/OmniWM#451 scrolling has too much momentum | closed | Applies; same as commit `4d0d45b0`. Nehir keeps the old projected-end model (`SwipeTracker.swift:15-16,42-46`). | **🟡** | `SwipeTracker.swift`, `ViewportState+Gestures.swift` |
| BarutSRB/OmniWM#275 workspace bar only when holding modifier | closed | Same as commit `b431b9b8`; absent in Nehir (`MonitorBarSettings.swift:16`). | **🟡** | bar settings + input monitor |
| BarutSRB/OmniWM#311 exclude apps from workspace bar | closed | **Already planned**, deliberately different design: `planned/20260621-omniwm-311-exclude-apps-from-workspace-bar.md` uses an app-rule `hideFromWorkspaceBar` field (`Sources/Nehir/UI/WorkspaceBar/WorkspaceBarDataSource.swift:71`) and explicitly rejects the global-bundle-ID list that upstream `97110817` implements. Plan stands unchanged. | **🟢** | covering doc only |
| BarutSRB/OmniWM#268 minimum window size has no effect | closed | Same hard-constraint gap as `f4903f89` (`LayoutRefreshController.swift:601-629`). | **🔴** (with `f4903f89`) | `LayoutRefreshController.swift`, `NiriConstraintSolver.swift` |
| BarutSRB/OmniWM#464 Guake cmd+w closes window | closed | No Quake terminal. | **🟢** | none |
| BarutSRB/OmniWM#454 won't launch on v0.5.3.2 | open | No FoundationModels dependency; Nehir macOS floor independent. | **🟢** | none |
| BarutSRB/OmniWM#436 window moved to ws8 reconciled back to ws7 | closed | Same class as existing `planned/20260619-nehir-62-move-workspace-to-monitor.md` / stale-command-target discoveries; already Nehir-tracked. | **🟢** (already-tracked class) | existing docs |
| BarutSRB/OmniWM#358 / BarutSRB/OmniWM#390 / BarutSRB/OmniWM#315 / BarutSRB/OmniWM#283 / BarutSRB/OmniWM#295 / BarutSRB/OmniWM#254 | closed | All already own Nehir docs (`noop/20260616-omniwm-358-*`, `discovery/20260615-omniwm-390-*`, `discovery/20260617-omniwm-315-*`, `planned/20260621-omniwm-283-*`, `planned/20260621-omniwm-295-*` + impl worktree, `noop/20260617-omniwm-254-*`). Recently closed upstream; no re-scope. | **🟢** | covering docs only |
| PR#478 fix bar click on emoji-named workspaces | open | Nehir routes bar names through `displayName(for:)` and keys identity on `rawWorkspaceName` (`WorkspaceBarDataSource.swift:299-305`, `WorkspaceBarView.swift:114-115`), so the upstream glyph hit-test bug likely does not apply. Not confirmed. | **🟡** (low-priority verify) | `WorkspaceBarView.swift`, `WorkspaceBarDataSource.swift` |
| PR#477 per-display inner gap overrides | open | Already have (`Sources/Nehir/Core/Config/MonitorGapSettings.swift:29-33`, per-display via `MonitorOverrideFileStore.swift:39-40`). | **🟢** | none |
| PR#427 hold-to-show workspace bar | closed | Same as BarutSRB/OmniWM#275 / `b431b9b8`. | **🟡** | bar settings |
| PR#350 Niri scroll snap toggle | closed | Equivalent, modifier-gated by design (`MouseEventHandler.swift:2054`, `noop/20260617-omniwm-336-modifier-gated-no-snap-gesture-scroll.md`). 🟡 only if a persistent global off-toggle is wanted. | **🟢** | none |

---

## Recommendation — what to plan next

Ranked by confidence/leverage:

1. **🔴 `6808e44c` observer reinstall — the one real bug this sweep found.** Add an idempotent `installWorkspaceObservers()` to `AXManager` (init calls it; each `setup*Observer` guarded on `== nil`) and call it from `ServiceLifecycleManager.startServices()`, so a disable→enable / AX-permission-toggle cycle does not permanently lose app launch/termination detection. Small, self-contained, testable. Confirm the `stop()`→`cleanup()` wiring in the plan.
2. **🔴 `e1ec597c` + `17f4872d` + BarutSRB/OmniWM#457 — directional-monitor eligibility.** XS, isolated: require the requested-axis delta to dominate the perpendicular delta in `adjacentMonitor`. Fold the offset-stacked-monitor regression scenario into the same work.
3. **🔴 `b243d36f` + BarutSRB/OmniWM#446 — cursor-inside no-warp guard.** XS backstop to Nehir's existing click-token suppression; add a "pointer already inside target frame" short-circuit in `moveMouseToWindow`.
4. **🔴 `eae140a9` + BarutSRB/OmniWM#456 — FFM should focus the hovered floating window.** M; changes Nehir's `.occlusion` "avoid stealing beneath a float" into "focus the authoritative hovered float". Needs FFM target-enum support for floating/managed-displayable windows.
5. **🔴 `f4903f89` + BarutSRB/OmniWM#268 — hard app-minimum-size semantics.** L; remove the feasibility-relaxation path so infeasible Niri allocation is deterministic while preserving no-bleed. Highest-effort; scope as a Nehir-native constraint change, not a diff apply.
6. **🟡 Finish already-planned width work — BarutSRB/OmniWM#295 (`b68bee7a`) and BarutSRB/OmniWM#283 (`bdde067c`).** Both have `planned/` docs and a live impl worktree for #295; upstream now has the reference impls to compare against.
7. **🟡 Trackpad momentum (BarutSRB/OmniWM#451 / `4d0d45b0`).** Real UX complaint already on the roadmap; port the intent (drop projected-end glide) into Nehir's own `SwipeTracker`, coordinating with existing fling-overshoot discoveries. Needs a repro first.
8. **🟡 Runtime hardening sub-findings (`6808e44c`):** AppAXContext stale-callback fencing and RunLoopJob serialization — pair the low-risk RunLoopJob port with rec. 1; open a discovery to confirm the AppAXContext teardown window is actually hit before committing.

Feature-gated / product-decision items (plan only if desired, not bug backports): configurable Overview zoom (BarutSRB/OmniWM#459), hold-to-show bar (BarutSRB/OmniWM#275), configurable workspace-swipe gesture (`d25e8a36`), screen-path containment (`49846ac9`), keyboard structural moves in Overview (BarutSRB/OmniWM#469).

Explicitly **not** ported in this loop: Hidden Bar (both commits), Quake/Ghostty surface work, dead-state removal (coupled to the un-adopted WorldStore rewrite), the global-bundle-ID bar exclusion list (Nehir deliberately chose the app-rule field), and release/floor metadata.

## Scope of this sweep vs. the loop

This doc accounts for upstream commits `38987c81..be68cfbf` (releases **0.5.4**, **0.5.5**,
**0.5.6**) and upstream issues/PRs updated on or after 2026-07-06. The running loop's
next observation should resume from `be68cfbf`. Nothing here supersedes the canonical
roadmap's deferred lanes; it adds one confirmed runtime bug (`6808e44c` observer
reinstall), a small focus/directional hardening set, a layout min-size constraint
item, and issue/PR-driven verify/feature candidates. The prior sweep's open items
(transient-subrole floating seed guard `25f4a459`, no-op readmission guard `6520c461`,
scroll-animation frame-echo guard `679f0ba3`, durable title cache `9abda3d2`,
overlay-tool exclusion BarutSRB/OmniWM#440) remain open and are not re-triaged here.
