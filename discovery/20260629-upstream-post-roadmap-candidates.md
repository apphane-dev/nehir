# Upstream post-roadmap candidates — 0.5.2 / 0.5.2.1 sweep (2026-06-25 → 2026-06-29)

Groom 2026-07-07: still applicable — triage sweep; the Focus Lock candidate (`79067d45`) has since shipped (`dc1f5fac`, "Add Manual Override focus lock from OmniWM"; see `completed/20260705-omniwm-425-overload-override-modifier-focus-lock.md`), but the remaining 🔴 candidates (column-width re-tile `3e26655c`, tabbed-column Space-left liveness reap `c836fbb0`, offscreen-tab hide `e82cd168`, `.layoutTransient` min-size floor `8a8ecbd8`) are still open (verified against main 7a025b78).

Third post-roadmap triage of `BarutSRB/OmniWM` against Nehir `main`. It continues
the running backport-tracking loop established by the canonical roadmap
([`20260618-upstream-port-roadmap.md`](20260618-upstream-port-roadmap.md)) and the
prior post-cutoff sweep ([`20260625-upstream-post-roadmap-candidates.md`](20260625-upstream-post-roadmap-candidates.md)).

**Sweep range:** every upstream commit newer than the previous sweep's observation
cutoff `36461fe1` ("Redesign Omni Sponsors window …", 2026-06-24 19:00 — the last
commit the 2026-06-25 doc explicitly accounted for as a branding exclusion) through
current upstream `main` HEAD `cf5e72b0` ("Release 0.5.2.1"). That span ships two new
upstream releases: **v0.5.2** (`9a1b28f6`) and **v0.5.2.1** (`cf5e72b0`). 28 commits
total; 16 are behavioural, the rest are release/build/branding noise handled in the
table's dismissal rows.

Nehir-side evidence was verified against the main Nehir source tree at `0602387d`
("Do not recenter viewport on activation of fully visible windows") on 2026-06-29.
Upstream commits are cited by hash + title and were read directly from
`BarutSRB/OmniWM` via the `upstream` remote. No Nehir source was modified; this is
planning only.

**Verdict legend:** 🔴 worth porting · 🟡 conditional-investigate / verify / fold-in · 🟢 already-have / skip / N/A.

---

## Triage table

| Upstream commit | One-line change | Nehir-equivalent already present? | Verdict | Effort | Nehir files |
| --- | --- | --- | --- | --- | --- |
| `79067d45` Focus Lock Modifier to suspend FFM while held | A configurable sided modifier (e.g. Left Option) holds focus-follows-mouse in abeyance while physically held; gate reads the mouse-move event's own modifier flags (self-healing — a missed key-up can never strand focus). New `FocusLockModifier` enum + `[focus] lockModifier` setting + picker; default off. Closes upstream #425. | **No** (grep `focusLock`/`FocusLock` empty). Nehir **has** FFM (`WMController.focusFollowsMouseEnabled`, gate at `Sources/Nehir/Core/Controller/MouseEventHandler.swift:876` `if controller.focusFollowsMouseEnabled, shouldHandleFocusFollowsMouse(at:)`), but no suspend-while-held gate. | **🔴** (concept-port — see deep-dive) | M | new `Sources/Nehir/Core/Config/FocusLockModifier.swift`, `MouseEventHandler.swift:876` (gate), settings plumbing (`SettingsStore`, `BehaviorSettingsTab`, TOML codec) |
| `3e26655c` Apply Niri column-width settings to existing windows | Visible Columns / Default Column Width previously sized only *new* columns; the GUI controls now re-tile already-open windows. `NiriLayoutEngine.balanceSizes` returns `Bool`; new `NiriLayoutHandler.balanceSizesAllWorkspaces` (Niri-only, skips Dwindle/empty) issues one batched relayout. | **No — Nehir has the exact gap.** `SettingsView.swift` onChange handlers call only `controller.updateNiriConfig(…)` with no re-tile (lines 380-381, 387-388, 395); grep for `balanceSizesAllWorkspaces` is empty. Nehir has every primitive: `balanceSizes()` (`NiriLayoutEngine+ColumnOps.swift:253`), `resolvedColumnResetWidth`, `updateNiriConfig`, `niriDefaultColumnWidth`, `niriBalancedColumnCount`, `niriColumnWidthPresets`. | **🔴** (near-direct engine port + Nehir-vocab UI wiring) | S–M | `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+ColumnOps.swift:253` (`balanceSizes → Bool`), `Sources/Nehir/Core/Controller/NiriLayoutHandler.swift` (new `balanceSizesAllWorkspaces`), `Sources/Nehir/Core/Controller/WMController.swift` (one-line forwarder), `Sources/Nehir/UI/SettingsView.swift` (3 onChange wirings) |
| `c836fbb0` Don't reap windows that left a Space (tabbed-column split fix) | `handleCGSWindowDestroyed` reaped any tracked window on `spaceWindowDestroyed`, but a tabbed column's inactive tabs briefly leave the Space (a window-server side effect of the active-tab raise), so OmniWM reaped still-alive tabs and re-admitted them as fresh single-window columns — the tabbed column split apart on toggle/scroll. Gate the destroy path on window-server liveness: if `resolveWindowInfo(windowId) != nil` the window merely left a Space, so skip the reap. | **No — Nehir lacks the gate.** `Sources/Nehir/Core/Controller/AXEventHandler.swift:1076` `handleCGSWindowDestroyed` goes straight to `invalidateCachedTitle` → `cancelCreatedWindowRetry` → `handleWindowDestroyed(…)` with no liveness check. Nehir has tabbed columns (`TabbedColumnOverlay.swift`, `isTabbed`, `isHiddenInTabbedMode`) and `resolveWindowInfo`, so the split-on-toggle bug class applies. | **🔴** (clean 3-line port, Nehir has `resolveWindowInfo`) | XS | `Sources/Nehir/Core/Controller/AXEventHandler.swift:1076` |
| `e82cd168` Hide inactive tabs offscreen so only the active tab animates | A visible tabbed column overlaid all windows at the same on-screen frame, so scrolling rewrote every tab's AX frame each tick (3 writes/tick when one is visible). Route `isHiddenInTabbedMode` windows into the existing offscreen hide pipeline (`hiddenHandles`) in the `.visible` case; the hide machinery parks them once and suppresses per-tick writes. Depends on `c836fbb0`'s liveness gate (keeps the offscreen move from reaping parked tabs). | **No.** `Sources/Nehir/Core/Layout/Niri/NiriLayout.swift:281` `case .visible:` only sets `renderedContainerRect = visibilityRect`; it does **not** route `isHiddenInTabbedMode` windows into `hiddenHandles`. Nehir sets `isHiddenInTabbedMode` (`:991`) and owns the hide pipeline (`hiddenHandles`, `hiddenEdge`, `encodedHideSide` at `:285`), so the per-tick churn applies. | **🔴** (concept-port; verify hide-pipeline integration) | S | `Sources/Nehir/Core/Layout/Niri/NiriLayout.swift:281` (`.visible` case) |
| `edd49d09` Tabbed-column tile offsets must overlay, not stack | `computeTileOffset`/`computeTileOffsets` summed each tile's height as if stacked, but a tabbed column overlays all windows at the column top; consuming/expelling into a tabbed column computed a bogus vertical displacement, throwing the window out of the tab's bounds. Return `gaps` for every tile of a tabbed column. | **Diverged — verify.** Nehir's `computeTileOffset` (`NiriLayoutEngine+Animation.swift:435`) is a *stacked* model (`offset += height + gaps`, comment "Stacks anchor at contentY with zero leading gap") and does **not** special-case `isTabbed`; Nehir instead applies the tab x-offset via a separate `tilesOrigin` (`isEffectivelyTabbed ? renderStyle.tabIndicatorWidth : 0`). The bug manifests only if Nehir's tabbed render path actually consults `computeTileOffset`'s y — confirm before porting. | **🟡** (verify render path) | XS–S | `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+Animation.swift:435` |
| `8a8ecbd8` Keep min-size floor for offscreen-scroll windows | `resolvedLayoutConstraints` relaxed a window's min-size floor to 1×1 whenever hidden, including the transient `.layoutTransient` state a column gets while parked offscreen during a scroll — so column heights flickered to an even split during left/right navigation. Treat `.layoutTransient` like a visible window (keep its real min unless the min genuinely overflows). | **No — Nehir has the same gap.** `Sources/Nehir/Core/Controller/LayoutRefreshController.swift:578` `private func resolvedLayoutConstraints(…)` gates on `hiddenState == nil` (line 592), identical to upstream's pre-fix. Nehir has `.layoutTransient` (`:2944`), `offscreenSide`, and `relaxedForOversizedMinimum`. | **🔴** (clean port; also make it `nonisolated static` for unit tests) | S | `Sources/Nehir/Core/Controller/LayoutRefreshController.swift:578-592` |
| `9a54fac8` Clamp animated window frames to the work area | A column changing height while moving (1↔2 windows, scroll/resize) let the displaced-low position plus final full height hang the window far below the work area until the offset settled (e.g. 1394-tall window briefly at y=2103 on a 1410-tall area). Clamp the animated frame's non-scroll axis to the container's rendered bounds (horizontal layouts clamp y; vertical clamp x). Size stays final-only on purpose. | **Verify — likely partial / interacts with Nehir's intentional overflow.** Nehir's `NiriLayout.swift` has clamp infrastructure (`clampRect`, `yClampedRect`) for lone windows and an explicit line-58 note ("A separate clamp here would desync render from gesture state"). Nehir also intentionally lets windows overflow into neighbouring monitors (`overflowEdgeIntersectingNeighboringMonitor`, `containerOverflowRegions`, the offscreen-parking feature). The upstream clamp targets the *animation-offset overshoot* in the multi-window `.normal` case and claims to leave scrolls/fullscreen untouched — confirm it does not fight Nehir's intentional offscreen overflow before porting. | **🟡** (verify; targeted animation polish) | XS | `Sources/Nehir/Core/Layout/Niri/NiriLayout.swift` (`.normal` animation case) |
| `20d7848b` Reduce managed-replacement churn: epsilon frame guard, match dedupe, early-flush | Kill the `managed_replacement_metadata_changed` reconcile flood: `updateManagedReplacementFrame` ignores ≤1px frame echoes via `FrameTolerance.frameWrite`; `structuralReplacementMatch` is computed once per create and threaded into the rekey decision (collapses the old `structuralReplacementWorkspaceIdForCreate` + `rekeyStructuralManagedReplacementIfNeeded` pair into `rekeyStructuralManagedReplacement(match:)`); early-flush an unambiguous 1-destroy/1-create burst as soon as it matches (~150ms sooner). | **Partial / diverged vocabulary.** Nehir has `managedReplacementMetadata` with a `frame` field and `updateManagedReplacementFrame` (`WMController.swift`, `WindowRuleEngine.swift:192`), plus a live managed-replacement rekey investigation (`planned/20260625-vscode-focused-admission-skips-managed-replacement-rekey.md`). But Nehir uses its own reconcile vocabulary (`ReconcileTxn`/`RuntimeStore`, not upstream `WorldStore`) and has already reworked the burst/rekey shape for the VS Code admission case. The epsilon-guard and early-flush *concepts* apply; the line-level restructure does not. | **🟡** (selective concept-adoption — see deep-dive) | M | `Sources/Nehir/Core/Controller/AXEventHandler.swift`, `Sources/Nehir/Core/Workspace/WorkspaceManager.swift` |
| `d22a3d88` Source managed-replacement match frame from the AX ledger, not per-frame reconcile | Delete the continuous `updateManagedReplacementFrame` path (which committed a reconcile txn per observed frame-change — 465 commits in 17s during resize/scroll) and source the matcher's old-window frame lazily from the existing AX frame ledger (`lastAppliedFrame`), falling back to `floatingState.lastFrame` for dragged floating windows. | **Partial / diverged vocabulary.** Same area as `20d7848b`. The lazy-ledger-sourcing idea is sound and portable in concept, but Nehir's matcher reads `managedReplacementMetadata?.frame` and its reconcile substrate differs. Verify whether Nehir's frame-echo path causes the same churn before adopting. | **🟡** (selective concept-adoption; pairs with `20d7848b`) | M | `Sources/Nehir/Core/Controller/AXEventHandler.swift`, `Sources/Nehir/Core/Workspace/WorkspaceManager.swift` |
| `18c30dd0` Niri: don't switch focus to an empty adjacent monitor | At a monitor's column-strip boundary, directional `focus.left/right` falls through to `focusMonitor` which switched the interaction monitor to the neighbour even when it had no focusable windows — stranding focus on an empty monitor. Skip the switch when the target workspace has no focusable windows (`guard !candidates.isEmpty else { return }`). | **N/A standalone; fold into the `b8a545f` port.** Nehir does not yet have directional `focusMonitor(direction:)` — the 2026-06-25 sweep's #1 🔴 recommendation (`b8a545f` "Cross directional focus to adjacent monitor") is still unstarted. When that port lands it must carry this empty-monitor guard (1 line at the `spatialNeighborToken` candidate site). Nehir's existing cyclic `focusMonitorCyclic(previous:)` is a separate path. | **🟡** (companion to `b8a545f`, not standalone) | XS | `Sources/Nehir/Core/Controller/WorkspaceNavigationHandler.swift` (when `focusMonitor(direction:)` is added) |
| `ecabdbac` Niri scroll: animate via AX, hide via SkyLight; scroll trace diagnostics | Split the column-scroll render path: animate via AX writes, hide offscreen windows via SkyLight; adds a large diagnostics surface (`ScrollTickRecorder`, `AnimationTickRecorder`, `BorderOpMetricsRecorder`, `AXWriteLatencyRecorder`, `LayoutBuildMetrics` enrichment). | **Diagnostics = Nehir-native track.** The four new recorders parallel Nehir's own diagnostics (`BackgroundTraceBuffer`, `DebugBarManager`, `runtimeStateDebugDump`) already triaged 🟢 in the 2026-06-25 doc (`e399415`). The behavioural payload — the AX-animate / SkyLight-hide split for scrolling windows — is worth a verify: Nehir's scroll path writes AX per tick and may benefit from routing offscreen hides through SkyLight. Mostly a study item, not a port. | **🟡** (verify AX/SkyLight scroll split; diagnostics = 🟢 Nehir-native) | M | `Sources/Nehir/Core/Controller/NiriLayoutHandler.swift`, `LayoutRefreshController.swift` |
| `809a1f3d` Harden focus-border surface creation + validate border settings | Defensive hardening of `BorderSurfaceApplier` / `BorderWindow` surface creation and validation of border settings on apply (+216-line `BorderSurfaceTests`). | **Mostly already-defensive in Nehir** but worth a targeted audit. Nehir has focus borders and has its own border-surface lifecycle; the validation-hardening idea is portable in concept. | **🟡** (audit / idea-borrow) | S | `Sources/Nehir/Core/Border/BorderSurfaceApplier.swift`, `BorderWindow.swift`, `Sources/Nehir/Core/Config/SettingsStore.swift` |
| `6bd0bf75` + `644d9115` Private-API capability diagnostic + fallback-firing instrumentation (+ tidy) | New `PrivateAPIHealthDiagnostics.swift` (477 lines) + `FallbackFiringRecorder` instrumenting where private-API (SkyLight) fallbacks fire; `644d9115` tidies the surface. | **Nehir-native diagnostics track.** Nehir already instruments its SkyLight surface (`SpaceTopology.swift`, the M4-S1/M4-S2 diagnostics). The *fallback-firing instrumentation* concept is borrowable; the subsystem is not. | **🟢** (idea-borrow only) | — | none required |
| `315787d4` Drop dead private-API fallbacks (macOS 27 baseline) | `SkyLight.swift` −242/+91: removes fallback codepaths, establishing macOS 27 as the deployment baseline. | **Baseline decision, not a port.** Nehir depends heavily on SkyLight. Whether Nehir wants to adopt the macOS 27 baseline (and drop the same dead fallbacks) is a maintainer decision; it is a large deletion with version-floor implications, not a backport candidate. Flag for a separate decision, do not port in this loop. | **🟡** (baseline decision — defer) | — | `Sources/Nehir/Core/SkyLight/SkyLight.swift` |
| `f540bb4a` Redesign App Rules UI with staged editor + validation hardening | Large UI rewrite (+1021/−706): new `AppRuleEditor.swift`, staged `AppRuleDraft`, `IPCRuleValidator` hardening. | **Nehir-native UI.** Nehir has its own App Rules UI. The `IPCRuleValidator` / `AppRule` validation hardening is the only marginally portable piece; the staged-editor UI is Nehir's own design problem. | **🟢** (validation-hardening idea-borrow only) | — | none required |
| `38b7c565` + `b6330508` + `a68a230d` + `bc9fc567` In-app issue bug-report form + structured triage fields + welcome workflow | Extends the issue-report subsystem (form, structured triage fields, first-issue welcome, review pass). | **Nehir-native track.** Nehir already owns this subsystem (`planned/20260621-send-reports.md`, `completed/20260624-recent-trace-clip-buffer.md`); the 2026-06-25 doc triaged the parent `e399415` 🟢 already-have. These commits extend the same Nehir-native track. | **🟢** | — | none |
| `a8dbbc8c` Left-side modifiers as System Hyper Trigger keys | Hyper-trigger expansion (left-sided). | **N/A — Nehir has no Hyper** (per the 2026-06-25 doc's `1aadf76` 🟢 finding). | **🟢** | — | none |
| `97b3b994` + `cb587a19` Dwindle Grow/Shrink + Option+right-drag resize | Dwindle-layout resize features. | **N/A — Nehir removed Dwindle** (per roadmap "Why not wholesale WorldStore"). | **🟢** | — | none |
| `d0c03fda` Boot animation "Omni" + Lofty Goals brand icon | Branding. | **N/A — branding.** | **🟢** | — | none |
| `cc795ff6` + `00d3b8f1` + `5ade4220` Ghostty arch preflight / release build path / Script: Fix | Build, packaging, release plumbing. | **N/A — build/release.** | **🟢** | — | none |
| `9a1b28f6` + `cf5e72b0` Release 0.5.2 / Release 0.5.2.1 | Release bumps. | **Release metadata only.** | **🟢** | — | none |

### Verdict tally (16 behavioural commits)

- 🔴 **worth porting (clean gap + substrate):** 4 — `79067d45` Focus Lock Modifier, `3e26655c` column-width to existing windows, `c836fbb0` don't reap windows that left a Space, `8a8ecbd8` min-size floor for offscreen-scroll windows.
- 🔴/🟡 **worth porting pending verify:** 1 — `e82cd168` hide inactive tabs offscreen (depends on `c836fbb0`).
- 🟡 **verify / selective / fold-in / baseline-decision:** 7 — `edd49d09` tabbed tile-offset overlay, `9a54fac8` clamp animated frames, `20d7848b`+`d22a3d88` managed-replacement churn, `18c30dd0` empty-adjacent-monitor (fold into `b8a545f`), `ecabdbac` AX/SkyLight scroll split, `809a1f3d` border-surface hardening, `315787d4` macOS 27 baseline (decision).
- 🟢 **already-have / N/A / Nehir-native:** 4 — issue-reporter cluster (Nehir-native), private-API diagnostics (idea-borrow), App Rules UI (Nehir-native), plus the Hyper/Dwindle/branding/build/release dismissals.

---

## Deep-dive — the four clean 🔴 ports + the tabbed cluster

### `79067d45` Focus Lock Modifier — 🔴 concept-port

**What it changes (read from the diff):** a new pure enum `FocusLockModifier` (`.off`/`.option`/`.leftOption`/…/`.rightShift`) with `isHeld(inRawFlags:)` that distinguishes side via `NX_DEVICEL{…}KEYMASK`-style masks. The gate is one line at the FFM decision point:

```swift
if controller.focusFollowsMouseEnabled,
   !controller.settings.focusLockModifier.isHeld(inRawFlags: modifiersRawValue),
   shouldHandleFocusFollowsMouse(at: location) {
    handleFocusFollowsMouse(at: location)
}
```

The modifier flags are threaded through the mouse-move intake so the gate is **self-healing** — it reads the event's own flags, so a missed key-up can never strand focus, and no extra event tap or lease is needed. Opt-in, default off.

**Nehir-equivalence:** Nehir has FFM but no suspend gate. The decision point is
`Sources/Nehir/Core/Controller/MouseEventHandler.swift:876`:

```swift
if controller.focusFollowsMouseEnabled, shouldHandleFocusFollowsMouse(at: location) {
    handleFocusFollowsMouse(at: location, windowUnderPointer: windowUnderPointer)
}
```

— structurally identical to upstream's, so the `!settings.focusLockModifier.isHeld(…)` clause slots in directly.

**Why this is a concept-port, not a line-port:** upstream threads `modifiersRawValue` through `EventIntake` (the WorldStore-family intake Nehir intentionally did **not** port — see roadmap "Why not wholesale WorldStore"). Nehir's mouse-move path does not carry modifier flags to that point today, so the port must re-thread raw modifier flags through Nehir's own `MouseEventHandler` mouse-moved entry (the event tap already has `modifiers.rawValue` available where it builds `.mouseMoved`). The pure `FocusLockModifier` enum is cleanly vendored as a new Nehir file; its side-detection helper depends on a `ModifierFlagMask` type that itself arrives with `569cbde` (side-specific modifiers, 🟡 low-priority from the prior sweep) — either bring that small helper along (cat-4) or re-express the side mask inline with `NX_DEVICEL{CTL,ALT,SHIFT,CMD}KEYMASK` (cat-5). Recommend the latter to avoid pulling in the side-specific-modifier surface Nehir hasn't asked for.

**Verdict: 🔴.** High FFM ergonomics value (read/scroll/inspect without losing focus), opt-in/default-off (zero regression risk), reuses Nehir's FFM seam. Pairs naturally with the existing M3 FFM-cursor-warp work (same `[focus]` settings neighbourhood).

### `3e26655c` column-width settings apply to existing windows — 🔴 near-direct port

**What it changes:** `NiriLayoutEngine.balanceSizes` becomes `@discardableResult … -> Bool`; a new `NiriLayoutHandler.balanceSizesAllWorkspaces` iterates Niri (non-Dwindle) workspaces, skips empty ones, calls `balanceSizes` and collects changed IDs into one batched `requestLayoutCommandRelayout(affectedWorkspaceIds:)`. The `SettingsView` handlers for Default Column Width (mode + percent) and Visible Columns now call a `controller.balanceNiriSizesAllWorkspaces()` forwarder after `updateNiriConfig`. Visible-Columns changes also flip `niriDefaultColumnWidth` to `nil` (Auto 1/N).

**Nehir-equivalence — the gap is confirmed verbatim.** Nehir's `SettingsView.swift`:

- `:380-381` default-column-width mode → `controller.updateNiriConfig(defaultColumnWidth: …)` only.
- `:387-388` percent → `controller.updateNiriConfig(defaultColumnWidth: …)` only.
- `:395` `niriBalancedColumnCount` → `controller.updateNiriConfig(balancedColumnCount: …)` only.

None re-tile existing windows, and `grep balanceSizesAllWorkspaces` is empty. Nehir has the engine substrate: `balanceSizes()` at `NiriLayoutEngine+ColumnOps.swift:253` (returns `Void` today), `resolvedColumnResetWidth` (`NiriLayoutEngine.swift:222`), and `requestLayoutCommandRelayout`.

**Verdict: 🔴.** Near-direct engine port (`balanceSizes → Bool` + the new handler are identical to upstream because the Niri engine is cat-1/2); the only Nehir-vocabulary adaptation is the `SettingsView` wiring (Nehir says `niriBalancedColumnCount`/`DefaultColumnWidthMode.balanced` where upstream says `maxVisibleColumns`). Low risk, high UX value (settings finally affect open windows), and the upstream `NiriVisibleColumnsTests` ports directly.

### `c836fbb0` + `e82cd168` (+ `edd49d09`) — the tabbed-column cluster

Nehir has tabbed columns (`Sources/Nehir/Core/Layout/Niri/TabbedColumnOverlay.swift`, `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+TabbedMode.swift`, `isTabbed`, `isHiddenInTabbedMode`, `tabOffset`), so this cluster is squarely on Nehir's surface.

**`c836fbb0` don't reap windows that left a Space — 🔴 clean port.** The fix is 3 lines at the top of `handleCGSWindowDestroyed`:

```swift
private func handleCGSWindowDestroyed(windowId: UInt32) {
    if resolveWindowInfo(windowId) != nil { return }   // alive — merely left a Space
    …
}
```

Nehir's `handleCGSWindowDestroyed` (`AXEventHandler.swift:1076`) lacks the gate and calls `handleWindowDestroyed(…)` unconditionally; Nehir has `resolveWindowInfo` (used at 11+ other sites). This is the root cause of tabbed columns splitting on toggle/scroll and ports cleanly.

**`e82cd168` hide inactive tabs offscreen — 🔴 concept-port (verify hide integration).** Upstream adds, inside `case .visible:` of the layout build, a block that routes each `isHiddenInTabbedMode` window into `hiddenHandles` with a parked hide-edge. Nehir's `case .visible:` (`NiriLayout.swift:281`) only sets `renderedContainerRect = visibilityRect` and does **not** touch `hiddenHandles` for inactive tabs, so Nehir rewrites every tab's AX frame each scroll tick. Nehir owns the same hide pipeline (`hiddenHandles`, `hiddenEdge(for:viewportFrame:fallback:orientation:)`, `encodedHideSide`), so the block ports in concept; verify the exact hide-edge helper signature matches Nehir's. **Hard-depends on `c836fbb0`** — without the liveness gate, parking inactive tabs offscreen would reap them.

**`edd49d09` tile offsets overlay vs stack — 🟡 verify.** Upstream returns `gaps` for every tile of a tabbed column inside `computeTileOffset`/`computeTileOffsets`. Nehir's `computeTileOffset` (`NiriLayoutEngine+Animation.swift:435`) is a *stacked* model that does not special-case `isTabbed`, and Nehir instead applies the tab x-offset through a separate `tilesOrigin`. Confirm whether Nehir's tabbed render path actually consults the stacked y-offset (in which case the displacement bug applies and the guard ports) before acting.

### `8a8ecbd8` min-size floor for offscreen-scroll windows — 🔴 clean port

**What it changes:** `resolvedLayoutConstraints` (made `nonisolated static` for unit testing) keeps the min-size floor for `.layoutTransient` (offscreen-parked-during-scroll) windows instead of relaxing them to 1×1. The gate flips from `hiddenState == nil` to `hiddenState == nil || hiddenState?.offscreenSide != nil`; the existing oversized-min overflow check still relaxes genuinely-overflowing mins.

**Nehir-equivalence — identical code shape.** Nehir's `Sources/Nehir/Core/Controller/LayoutRefreshController.swift:578` is `private func resolvedLayoutConstraints(…)` gating on `hiddenState == nil` (line 592); Nehir has `.layoutTransient` (`:2944`), `offscreenSide`, and `relaxedForOversizedMinimum()`. The fix is a one-line gate change plus the `nonisolated static` promotion (and the upstream `ResolvedLayoutConstraintsTests` ports directly). Fixes the column-height-flickers-to-even-split-during-navigation symptom.

**Verdict: 🔴.** Smallest, cleanest port in the sweep.

---

## Provenance notes (worth-porting set)

Per `provenance/README.md` cat 1–5. These feed `.provenance.json` and the SPDX headers on `main` once landed.

| Candidate | Upstream commit + title | Nehir destination category |
| --- | --- | --- |
| `79067d45` Focus Lock Modifier | `79067d45` "Add Focus Lock Modifier to suspend Focus Follows Mouse while held" | New `FocusLockModifier.swift` re-expressed with inline side masks (no `569cbde` `ModifierFlagMask` dependency) = **cat-5** (nehir-original); if the upstream enum is vendored near-verbatim = **cat-4**. The one-line gate + settings plumbing = **cat-2**. Recommend cat-5 + cat-2. |
| `3e26655c` column-width to existing windows | `3e26655c` "Apply Niri column-width settings to existing windows" | `balanceSizes → Bool` + `balanceSizesAllWorkspaces` into existing cat-1/2 Niri files = **cat-2**; `SettingsView` wiring = **cat-2**; `NiriVisibleColumnsTests` = **cat-2** (test borrowed alongside). |
| `c836fbb0` don't reap windows that left a Space | `c836fbb0` "Fix tabbed columns splitting: don't reap windows that left a space" | 3-line gate into Nehir's `AXEventHandler.swift` = **cat-2**. |
| `e82cd168` hide inactive tabs offscreen | `e82cd168` "Hide inactive tabs offscreen so only the active tab animates" | Block added to Nehir's `NiriLayout.swift` `.visible` case = **cat-2**. |
| `edd49d09` tile offsets overlay not stack | `edd49d09` "Fix tabbed columns: tile offsets must overlay, not stack" | Guard into Nehir's `NiriLayoutEngine+Animation.swift` = **cat-2** (if verified applicable). |
| `8a8ecbd8` min-size floor offscreen-scroll | `8a8ecbd8` "Keep min-size floor for offscreen-scroll windows" | Gate change + `nonisolated static` into `LayoutRefreshController.swift` = **cat-2**; `ResolvedLayoutConstraintsTests` = **cat-2**. |

`20d7848b`/`d22a3d88` (managed-replacement churn) and `9a54fac8` (frame clamp) carry
no upstream provenance obligation if acted on as concept-ports / Nehir re-expressions
(cat-5); any near-verbatim borrow is cat-2/4.

---

## Recommendation — what to backport next, sequenced

1. **`8a8ecbd8` — min-size floor for offscreen-scroll windows (🔴, first).** Smallest, cleanest port in the sweep; one-line gate change + `nonisolated static` + a ported unit test. Zero interaction with other work. Fixes visible column-height flicker during navigation.

2. **`c836fbb0` — don't reap windows that left a Space (🔴).** 3-line liveness gate, prerequisite for `e82cd168`, fixes tabbed-column splitting. Nehir has `resolveWindowInfo`.

3. **`e82cd168` — hide inactive tabs offscreen (🔴, after #2).** Concept-port of the `.visible`-case hide routing; cuts per-tick AX writes for inactive tabs to ~none. Pairs with `edd49d09` (🟡 verify) if Nehir's render path proves to share the displacement bug.

4. **`3e26655c` — column-width settings re-tile existing windows (🔴).** Near-direct engine port (`balanceSizes → Bool` + `balanceSizesAllWorkspaces`) + Nehir-vocab `SettingsView` wiring. High UX value (settings finally affect open windows); ports with its test.

5. **`79067d45` — Focus Lock Modifier (🔴 concept-port).** Self-contained, opt-in/default-off, slots into Nehir's FFM gate at `MouseEventHandler.swift:876`. Re-thread raw modifier flags through Nehir's own mouse-move entry; vendor the enum as cat-5 with inline side masks. Largest of the clean ports but lowest regression risk.

6. **Selective managed-replacement churn hardening (`20d7848b` + `d22a3d88`, 🟡).** Adopt the epsilon-frame-guard and lazy-ledger-sourcing *concepts* onto Nehir's `managedReplacementMetadata` path after the live `planned/20260625-vscode-focused-admission-skips-managed-replacement-rekey.md` rework settles — do not line-port the WorldStore-vocabulary restructure.

7. **Carry `18c30dd0` (🟡) into the `b8a545f` directional-cross-monitor-focus port** (the prior sweep's #1 🔴, still unstarted) — the empty-adjacent-monitor guard is one line at the `spatialNeighborToken` candidate site and belongs with that feature, not as a standalone port.

**Verify-only (no commitment):** `edd49d09` (tabbed tile-offset overlay — Nehir's render path diverged via `tilesOrigin`), `9a54fac8` (animated-frame clamp — confirm it does not fight Nehir's intentional offscreen overflow), `ecabdbac` (AX-animate/SkyLight-hide scroll split — behaviour payload only; diagnostics are Nehir-native), `809a1f3d` (border-surface hardening — audit/idea-borrow).

**Explicitly do NOT port in this loop:** `315787d4` (macOS 27 baseline — a maintainer baseline decision with version-floor implications, not a backport; flag separately), the issue-reporter cluster (Nehir-native track), the private-API diagnostics (idea-borrow only), the App Rules UI (Nehir-native), and the Hyper/Dwindle/branding/build/release dismissals. WorldStore/EventIntake/IntentLedger remain off-limits per the roadmap.

**Recommended next planning artifacts:**
- A per-cluster discovery doc for **#2 + #3 (+ #4 if shared)** — the tabbed-column cluster — modelled on the roadmap's existing lane docs, since `c836fbb0`/`e82cd168` share the tabbed-column + hide-pipeline seam and `c836fbb0` is a hard prereq for `e82cd168`.
- Update [`20260625-upstream-post-roadmap-candidates.md`](20260625-upstream-post-roadmap-candidates.md) Part 4 item 1: the directional-focus port (`b8a545f`) must now also carry this sweep's `18c30dd0` empty-monitor guard.

## Scope of this sweep vs. the loop

This doc accounts for upstream commits `36461fe1..cf5e72b0` (releases **0.5.2** and **0.5.2.1**). The running loop's next observation should resume from `cf5e72b0`. Nothing in this sweep supersedes the canonical roadmap's A2–A5 (deferred) or the prior sweep's open 🔴 recommendations (`b8a545f` directional focus, `be443f1` sub-parts 1/3) — those remain the standing multi-monitor backlog.
