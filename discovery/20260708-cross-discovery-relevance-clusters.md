# Cross-discovery relevance clusters — high-confidence links

Discovery index (2026-07-08). This file cross-links discoveries and plans that are highly likely to be relevant to each other because they share a source-backed mechanism, recovery path, or guard. Cluster IDs are planning labels only; they are not source identifiers.

Status update, 2026-07-08: `main` commit `f6078799` shipped the first OT-1/NF-1 observability slice. It added developer-mode background trace retention outside active capture sessions, viewport background participation, a lazy named runtime decision-event API, runtime decision trace export, background clip `eventNameCounts`, and `managedCommandTarget()` `command_target.resolve.*` accept/decline events. See [`../completed/20260708-internal-cluster-tracing-diagnostics.md`](../completed/20260708-internal-cluster-tracing-diagnostics.md). The cluster table below still tracks remaining behavior fixes and unshipped tracing slices.

Use this as a navigation aid before planning fixes. It intentionally omits weak thematic similarities.

## Triage dimensions

Scale used below:

- **User impact:** how visible / trust-breaking the cluster is for normal users.
- **Effort:** likely implementation size for a durable fix, not just a band-aid (`S`, `M`, `L`, `XL`).
- **Quick wins:** narrow fixes that can plausibly land before a full redesign.
- **Pain-in-arse factor:** how annoying the work is likely to be because of repro instability, AX/WindowServer weirdness, cross-cutting policy, or hard-to-test behavior (`Low`, `Med`, `High`, `Very high`).
- **Regression risk:** chance of breaking legitimate edge cases while fixing the cluster.
- **Observability need:** whether the first step should be more tracing before behavior changes.

| Cluster | User impact | Effort | Quick wins | Pain-in-arse | Regression risk | Observability need | Suggested priority |
| --- | --- | --- | --- | --- | --- | --- | --- |
| **NF-1** stale non-managed focus | **Very high** — commands silently no-op, windows refuse admission/reveal | **M/L** | Yes: explicit-token command paths; trace guard declines | **High** | **High** — overlay/quick-terminal protections are easy to weaken | **High** | **P0/P1** |
| **CR-1** close-recovery focus churn | **High** — focus can visibly oscillate or follow the wrong same-app successor | **S/M** | Landed: reverse-redirect latch in `9ac0b91c`; remaining work only if new churn appears | **High** | **High** — real same-app switches and close-local policy must survive | **Med/High** | **Completed for known bounce** |
| **LC-1** lifecycle/admission desync | **Very high** — windows disappear, merge, or are not admitted | **L/XL** | Partial: gate CGS destroy with liveness; improve burst tracing | **Very high** | **Very high** — destroy/admission is central | **Very high** | **P0 but sliced** |
| **VR-1** automatic viewport movement | **High** — viewport moves against user intent | **S/M** for current planned fixes; **L** for full policy cleanup | Partial: fully-visible focus reveal guard shipped in `c6eaafb9`; lone-column snap bound filter remains | **Med** | **Med** — explicit navigation must still move | **Med** | **P0 quick wins (partially shipped)** |
| **XD-1** cross-display move/reveal ordering | **High** for multi-display users | **M/L** | Some: make Summon Right reveal after target-frame materialization | **High** | **High** — monitor geometry and admission overlap | **High** | **P1 after LC/VR slices** |
| **TF-1** transient/floating/PiP classification | **Med/High** — app-specific, but ugly when hit | **M** | Yes: narrow built-ins + durable metadata for known offenders | **Med/High** | **Med/High** — over-broad floating rules are dangerous | **Med** | **P1/P2** |
| **OT-1** observability/test truthfulness | **Indirect but compounding** — reduces every future bug cost | **M/L** | Yes: trace silent guards; audit highest-risk test seams | **Med** | **Low/Med** if additive | **This is the observability work** | **Parallel enabler** |

## Cluster evaluations

### NF-1 evaluation — stale non-managed focus

- **Why it hurts:** it turns explicit user intent into silence: move-window commands, workspace-bar Shift-click, app activation, and reveal can all do nothing while the UI still shows a managed window selected.
- **Best quick wins:**
  - make workspace-bar Shift-click / context-derived moves pass an explicit token instead of re-resolving through `managedCommandTarget()`;
  - emit a trace event whenever a command target is dropped because non-managed focus is active (**generic `managedCommandTarget()` accept/decline tracing shipped in `f6078799`; non-managed-focus arming and explicit-token move traces remain open**);
  - add a narrow stale-non-managed-focus escape when the preserved managed token is hidden/offscreen and the selected viewport token is visible.
- **Hard part:** preserving the reason the guard exists: real unmanaged overlays, quick terminals, menus, and system UI must not cause focus bounce-back into tiled windows.
- **Recommended slice:** the first tracing part landed in `f6078799`; next, add explicit-token command-path traces and plan the focus/admission guard narrowing separately.
- **Update 2026-07-10:** the arming path was identified — quick-terminal summon arms the flag with the managed token preserved, and the CR-1 close-churn suppression swallows the only clearing confirmation. **Landed** in `31c8b851` ("Clear stale non-managed focus after quick terminal dismissal"): the churn-suppression point now clears stale non-managed focus while preserving the confirmed token and the viewport-stillness behavior. See [`../completed/20260710-ghostty-quick-terminal-arms-stale-nonmanaged-focus.md`](../completed/20260710-ghostty-quick-terminal-arms-stale-nonmanaged-focus.md) for what landed vs. what was proposed.

### CR-1 evaluation — close-recovery and same-app overlay focus churn

- **Why it hurts:** the close-recovery system can become its own focus source: macOS confirms one same-app window, Nehir redirects to the spatially stable target, then the same overlay/close evidence redirects the confirmation back again.
- **Best quick wins:** the known A → B → A oscillation is fixed by the `9ac0b91c` per-pid/workspace reverse-redirect latch. If related churn appears later, the next lever is requiring stronger evidence than `recentNonManaged=true` alone before the `.overlay` phase redirects between two managed same-workspace windows.
- **Hard part:** this is a protection added for real close/quick-terminal churn. Do not regress the landed local-close policy, and do not suppress legitimate same-app profile/window switches that should reveal their target.
- **Recommended slice:** completed for the exact A → B → A oscillation. The new trace marker is `close_recovery_reverse_redirect_skipped`, emitted when the latch suppresses a reverse redirect.

### LC-1 evaluation — lifecycle/admission desync

- **Why it hurts:** this is the scary class: managed windows are wiped, merged, hidden, or omitted even though AX/WindowServer still has them.
- **Best quick wins:**
  - treat CGS space-destroy events as space-membership changes unless a second oracle confirms window death;
  - add trace coverage for managed-replacement burst enqueue/schedule/flush and final admission;
  - keep/extend pid-window-list confirmation after suspicious partial enumeration.
- **Hard part:** every oracle lies sometimes. AX destroy, CGS destroy, first AX enumeration, and structural replacement are each valid in some cases and false in others.
- **Recommended slice:** do not attempt a single grand lifecycle rewrite. Land the CGS liveness/dual-oracle plan first, then separately instrument and fix replacement-burst admission.

### VR-1 evaluation — automatic viewport movement

- **Why it hurts:** it makes the viewport feel haunted: focus, relayout, or fling moves content when the user did not ask for movement.
- **Best quick wins:**
  - shipped in `c6eaafb9`: stop automatic focus-confirm reveal when the target is fully visible;
  - shipped in `c6eaafb9`: honor scroll lock before choosing a fully-visible automatic reveal target;
  - still open: filter offscreen bound snaps when the column strip is narrower than the viewport.
- **Hard part:** preserving explicit navigation behavior. User-initiated focus/move commands still need to reveal clipped or offscreen targets.
- **Recommended slice:** this is the cleanest near-term win cluster. The fully-visible focus-confirm slice shipped in `c6eaafb9`; land the lone-column snap-bound slice before broader viewport-policy work.

### XD-1 evaluation — cross-display move/reveal ordering

- **Why it hurts:** cross-display moves combine different monitor sizes, workspace identity, admission, replacement metadata, and reveal. Users see size dances, offscreen stranding, or a need to click before the column becomes real.
- **Best quick wins:**
  - for Summon Right, reveal only after the target display's frame/layout is materialized;
  - add transition diagnostics that tie model move → frame write → admission → reveal for a single token;
  - avoid relying on native focus as the only recovery path after external-display migration.
- **Hard part:** this overlaps both LC-1 and VR-1. Some symptoms are not fixable until lifecycle/admission and viewport snap/reveal rules are less leaky.
- **Recommended slice:** fix the isolated Summon Right size-dance first; defer the broader external-display admission issue until LC-1 replacement-burst tracing exists.

### TF-1 evaluation — transient/floating/PiP classification

- **Why it hurts:** helper windows become tiled columns, leak into the bar, or bounce between workspaces. It is app-specific but very visible for affected apps.
- **Best quick wins:**
  - keep using narrow built-ins for proven offenders such as Gecko dialogs;
  - persist transient/floating metadata across projection and lifecycle refresh;
  - add catalog-format work only for identity rules, not structural heuristics.
- **Hard part:** every tempting generic rule is dangerous. "Tagless standard window" or "zero frame" can describe real user windows as well as helpers.
- **Recommended slice:** continue narrow app-backed fixes plus durable metadata. Treat a generic shareable rule catalog as separate product work.

### OT-1 evaluation — observability and test truthfulness

- **Why it hurts:** it is not usually the user-facing bug, but it is why the first capture often cannot explain the bug and why tests can pass without exercising production behavior.
- **Best quick wins:**
  - trace every silent user-visible early return with a reason and target token/pid (`managedCommandTarget()` now emits `command_target.resolve.*` events in `f6078799`; other guard families remain open);
  - make the runtime trace buffer actually useful after-the-fact, not only during an armed capture (`f6078799` changed the background-buffer gate to developer mode and let viewport events participate; broader default-on policy remains open);
  - audit the top five test-only seams that skip production scheduling/reconciliation.
- **Hard part:** this is broad hygiene, so it is easy to postpone. It needs to be attached to concrete bug clusters rather than run as an abstract cleanup.
- **Recommended slice:** partially shipped by `f6078799` for NF-1 generic command-target decisions. Keep OT-1 as an acceptance requirement for NF-1, LC-1, VR-1, and XD-1 plans: each behavior change must add or preserve a traceable decision point and avoid test-only shortcut paths.

## NF-1 — stale non-managed focus blocks admission, confirmation, and command targets

**Common issue:** `isNonManagedFocusActive` can outlive the visible unmanaged surface or can be armed while a user-visible managed window is already selected. Once armed, it suppresses managed app activation/reveal and makes generic command-target resolution return `nil`, so explicit move/admission commands silently no-op.

**Arming path identified (2026-07-10):** the quick-terminal arming discovery below closes the "where does the staleness come from" gap. Summoning the Ghostty quick terminal enters non-managed focus with the managed token preserved (`AXEventHandler.swift:3922-3935`); on dismissal, the CR-1 overlay-close-churn suppression (`AXEventHandler.swift:3069-3126`, shipped in `d3ef41ee`) discards the only managed activation that would run `confirmManagedFocus` — the sole AX-driven reset of the flag — while the still-frontmost preserved window emits no AX event at all. The two guard families deadlock, and the stuck flag then suppresses scroll selection and FFM, locking out its own recovery.

**Primary links:**

- [`../completed/20260710-ghostty-quick-terminal-arms-stale-nonmanaged-focus.md`](../completed/20260710-ghostty-quick-terminal-arms-stale-nonmanaged-focus.md) — **arming mechanism + exact repro steps; landed as `31c8b851`.** Complete arm → stuck → re-arm → still-stuck capture: `command_target.resolve.decline reason=nonManagedFocus.frontmostTracked` fired while `frontmostToken == confirmedToken == layoutSelectionToken` (all the same tracked managed window), and the state persisted across a fresh quick-terminal summon and a full overlay destroy. The clearing fix at the churn-suppression point shipped; see the doc for what landed vs. the two unneeded alternative slices.
- [`20260708-assign-to-workspace-7-nonmanaged-command-target-decline.md`](20260708-assign-to-workspace-7-nonmanaged-command-target-decline.md) — direct post-instrumentation capture: assigning/moving Helium windows to workspace 7 no-ops while `command_target.resolve.decline reason=nonManagedFocus.frontmostTracked` returns no target; the same windows move once managed focus recovers and `reason=layoutSelection` accepts.
- [`20260708-stale-nonmanaged-focus-suppresses-managed-selection-and-window-move.md`](20260708-stale-nonmanaged-focus-suppresses-managed-selection-and-window-move.md) — broader current capture: viewport selection moves to visible managed windows, but stale non-managed focus keeps `confirmedManagedFocusToken` old and `wmCommandTarget=nil`.
- [`20260705-move-focused-window-to-workspace-noop-under-nonmanaged-focus.md`](20260705-move-focused-window-to-workspace-noop-under-nonmanaged-focus.md) — same generic move-command targetless failure after a third-party focus-suppressing overlay is destroyed.
- [`20260707-workspace-bar-shift-click-command-target-stale-nonmanaged.md`](20260707-workspace-bar-shift-click-command-target-stale-nonmanaged.md) — workspace-bar Shift-click variant: the UI promises a concrete move, but the handler re-resolves through the ambiguous generic command target.
- [`20260707-chatgpt-activation-admission-misses-recent-activation-ttl.md`](20260707-chatgpt-activation-admission-misses-recent-activation-ttl.md) — same guard family, but the recorded user activation expires before any admission attempt exists.
- [`20260703-user-activated-slack-suppressed-as-stale-under-nonmanaged-focus.md`](20260703-user-activated-slack-suppressed-as-stale-under-nonmanaged-focus.md) and [`20260703-unrequested-admission-guard-anatomy-and-hazards.md`](20260703-unrequested-admission-guard-anatomy-and-hazards.md) — original anatomy of the unrequested-admission guard and the shipped user-activation exemption.
- [`../planned/20260706-app-activation-nil-focused-window-skips-reveal.md`](../planned/20260706-app-activation-nil-focused-window-skips-reveal.md) — adjacent nil-focused-window activation gap. Keep separate unless implementation proves the nil window is the trigger for a stale non-managed focus loop.
- [`20260622-dock-click-focus-does-not-reveal-column.md`](20260622-dock-click-focus-does-not-reveal-column.md) and [`20260622-workspace-bar-freezes-on-gesture-with-non-managed-focus.md`](20260622-workspace-bar-freezes-on-gesture-with-non-managed-focus.md) — older reveal/bar-projection symptoms from the same suppressor branch.

**Do not merge blindly:** NF-1 contains two fix surfaces: clearing/narrowing stale non-managed focus, and command paths that should carry an explicit token instead of asking `managedCommandTarget()` again. They are related but may need separate plans.

## CR-1 — close-recovery and same-app overlay focus churn

**Common issue:** close/overlay recovery deliberately overrides macOS's same-app successor to preserve the user's viewport and local workspace. The guard family is timing-sensitive: if its recency evidence is too broad or lacks an oscillation latch, recovery can either follow the wrong successor or get stuck redirecting between two same-app managed windows.

**Primary links:**

- [`../completed/20260708-focus-dance-stuck-same-app-recovery.md`](../completed/20260708-focus-dance-stuck-same-app-recovery.md) — completed fix for the strongest capture: `close_recovery_overlay_stable_target` alternated observed/target tokens while `recentNonManaged=true` and disappeared-focus signals were false; `9ac0b91c` added the reverse-redirect latch.
- [`../completed/20260706-stable-viewport-on-window-close-recovery.md`](../completed/20260706-stable-viewport-on-window-close-recovery.md) — direct parent that added viewport pins, stable-target redirects, preconfirm/overlay phases, and recent non-managed overlay focus TTL.
- [`../completed/20260707-close-last-app-window-stay-on-current-workspace.md`](../completed/20260707-close-last-app-window-stay-on-current-workspace.md) — follow-up that keeps close local even when the current workspace loses its same-app survivor; preserve this policy while fixing oscillation.
- [`../completed/20260706-same-app-focus-switch-reveals-inactive-workspace-window.md`](../completed/20260706-same-app-focus-switch-reveals-inactive-workspace-window.md) — compatibility boundary: genuine same-app focus switches must still reveal/follow their target.
- [`../completed/20260615-quick-terminal-close-switches-workspace.md`](../completed/20260615-quick-terminal-close-switches-workspace.md) and [`20260615-viewport-reveal-from-unmanaged-overlay-activation.md`](20260615-viewport-reveal-from-unmanaged-overlay-activation.md) — older quick-terminal / app-owned overlay roots for this policy family.
- [`../completed/20260709-quick-terminal-long-open-close-reveals-parked-ghostty-viewport.md`](../completed/20260709-quick-terminal-long-open-close-reveals-parked-ghostty-viewport.md) — **reopened and re-closed CR-1 (2026-07-09).** Quick-terminal close acted on macOS's same-app focus redirect to a managed Ghostty window on the origin workspace. Variant A: on the active origin workspace the reveal lost the destroy-vs-redirect arming race and scrolled to the parked column (also VR-1). Variant B: on an *inactive* origin workspace `close_recovery_overlay_stable_target` refocused there and switched the active workspace back. **Landed** in `d3ef41ee` ("Keep active workspace when quick terminal close refocuses a window elsewhere"): a durable `overlayCapablePids` memory plus a broadened evidence gate on `shouldSuppressSameAppInactiveWorkspaceActivationBeforeCloseRecovery` fix both variants and the QT-open scroll. `mise run test` (1435 tests) green.
- [`../completed/20260710-quick-terminal-close-after-restart-lacks-overlay-evidence.md`](../completed/20260710-quick-terminal-close-after-restart-lacks-overlay-evidence.md) — **cold-start boundary condition (2026-07-10); landed as `efc64f1a`.** All overlay/close evidence (`overlayCapablePids`, recent non-managed focus, recent same-app close, live overlay scan) was in-memory and observation-driven; when Nehir restarted while the quick terminal was already open, the first QT close evaluated with every evidence field false and close recovery revealed the parked Ghostty column. Not a regression of `d3ef41ee` or `31c8b851` — the guards behaved as designed on empty inputs. Fix: `overlayCapablePids` is now armed unconditionally at `WMController.evaluateWindowDisposition`, using the rule engine's base decision so manual layout overrides don't drop the arming; regression-tested.
- [`20260709-window-close-successor-app-activation-reveals-far-parked-column.md`](20260709-window-close-successor-app-activation-reveals-far-parked-column.md) — **open, adjacent finding from the same session.** Closing a *different app's* window (not an overlay) can still let a cross-app successor activation reveal a far parked column, because focus-recovery falls back to `tiledEntries.first` rather than nearest-to-closed. Not covered by the `d3ef41ee` fix above; needs its own plan (touches `WMController.swift`/`WorkspaceManager.swift`, outside `AXEventHandler.swift`).

**Current state:** the known CR-1 bounce (A→B→A oscillation) is fixed. The 2026-07-09 reopen (quick-terminal close scroll/workspace-switch) is **landed and fixed** as of `d3ef41ee`. **NF-1 side effect (2026-07-10), landed:** the `d3ef41ee` overlay-close-churn suppression also discarded the managed activation that would clear stale non-managed focus after quick-terminal dismissal — see [`../completed/20260710-ghostty-quick-terminal-arms-stale-nonmanaged-focus.md`](../completed/20260710-ghostty-quick-terminal-arms-stale-nonmanaged-focus.md). Fixed in `31c8b851`, which clears the stale flag at the suppression point while preserving this cluster's viewport-stillness behavior. **Cold-start boundary condition (2026-07-10), landed:** `overlayCapablePids` and the other close/overlay evidence were populated only by observation, so the first quick-terminal close after Nehir restarted under an already-open quick terminal was unprotected — see [`../completed/20260710-quick-terminal-close-after-restart-lacks-overlay-evidence.md`](../completed/20260710-quick-terminal-close-after-restart-lacks-overlay-evidence.md). Fixed in `efc64f1a`, one commit after the NF-1 fix above. The adjacent cross-app successor-activation finding above remains **open** but is a distinct root cause (successor selection, not same-app overlay recovery) — track it separately rather than folding it into CR-1's reopen criterion. Otherwise, do not reopen this cluster for generic non-managed-focus command failures (NF-1) or generic viewport reveal movement (VR-1) unless new evidence again shows same-app close/overlay recovery redirects choosing opposite stable targets.

## LC-1 — lifecycle/admission desync: false removals, partial enumeration, and replacement bursts

**Common issue:** window lifecycle signals can temporarily diverge from real WindowServer/AX liveness. False destroy paths, partial first enumeration, structural replacement rekeys, or delayed replacement bursts remove/merge/delay managed entries; later focused admission or pid reevaluation often acts as the accidental recovery path.

**Primary links:**

- [`../completed/20260707-cold-start-spurious-ax-destroy-wipes-managed-windows.md`](../completed/20260707-cold-start-spurious-ax-destroy-wipes-managed-windows.md) — first cold-start wipe root-caused to spurious AX destroy notifications.
- [`20260707-cold-start-wipe-recurs-post-liveness-fix-only-focused-pid-readmitted.md`](20260707-cold-start-wipe-recurs-post-liveness-fix-only-focused-pid-readmitted.md) — recurrence after AX-destroy liveness verification; points at CGS space events and focus-only readmission.
- [`../completed/20260708-cold-start-destroy-only-replacement-bursts-click-readmit.md`](../completed/20260708-cold-start-destroy-only-replacement-bursts-click-readmit.md) — **fixed** (`a55b4e33`). CGS `spaceWindowDestroyed` now carries `spaceId`, runs liveness verification, and confirms AX membership before removing; nil-oracle branch no longer falls through to removal. Captures showed windows initially AX-enumerated and inserted, then destroy-only replacement bursts removed them; recovery was focus/pid-driven only.
- [`../completed/20260707-verify-liveness-before-honoring-ax-destroy.md`](../completed/20260707-verify-liveness-before-honoring-ax-destroy.md) and [`../planned/20260707-final-destroy-liveness-dual-oracle.md`](../planned/20260707-final-destroy-liveness-dual-oracle.md) — shipped first fix and planned finalization.
- [`../completed/20260707-cross-display-move-strands-window-offscreen-missing-niri-column.md`](../completed/20260707-cross-display-move-strands-window-offscreen-missing-niri-column.md) — downstream symptom of lifecycle desync: token removed from the niri column tree while WindowModel still has/then re-admits it.
- [`20260707-external-display-column-admission-click-required.md`](20260707-external-display-column-admission-click-required.md) — replacement metadata churn on a monitor/workspace migration delays clean column admission until a manual/native focus path re-enters admission.
- [`../completed/20260701-startup-full-rescan-under-enumerates-multi-window-app.md`](../completed/20260701-startup-full-rescan-under-enumerates-multi-window-app.md), [`../completed/20260701-structural-replacement-correlation-merges-distinct-startup-windows.md`](../completed/20260701-structural-replacement-correlation-merges-distinct-startup-windows.md), and [`../completed/20260701-confirm-pid-window-list-after-partial-ax-enumeration.md`](../completed/20260701-confirm-pid-window-list-after-partial-ax-enumeration.md) — same symptom class at startup: not all real windows survive first admission as distinct managed entries.

**Do not merge blindly:** LC-1 spans different event oracles (AX destroy, CGS space destroy, full-rescan AX enumeration, and replacement correlation). The common issue is missing cross-oracle verification and over-trusting one lifecycle signal, not a single call site.

## VR-1 — automatic reveal/recenter/snap movement bypasses user intent or visibility checks

**Common issue:** layout/reveal code often treats selection/focus changes as a mandate to re-center or snap even when the target is already fully visible, scroll lock is active, a spring is settling, or a lone-column snap target is an offscreen bound. These bugs feel like the viewport moves by itself.

**Primary links:**

- [`../completed/20260707-fully-visible-focus-reveal-recenters-viewport-ignoring-scroll-lock.md`](../completed/20260707-fully-visible-focus-reveal-recenters-viewport-ignoring-scroll-lock.md) and [`../completed/20260707-fully-visible-focus-reveal-scroll-lock-bypass.md`](../completed/20260707-fully-visible-focus-reveal-scroll-lock-bypass.md) — completed in `c6eaafb9`: automatic focus reveal no longer recenters a fully visible column and the fully-visible arm now honors scroll lock for automatic triggers. A 2026-07-08 two-window capture strengthened the policy boundary: with both windows fully visible and scroll lock disabled, automatic focus still chose the center snap, so the shipped fix stops fully-visible automatic movement even when unlocked.
- [`20260707-lone-column-fling-snaps-to-offscreen-overscroll-bound.md`](20260707-lone-column-fling-snaps-to-offscreen-overscroll-bound.md) and [`../planned/20260707-lone-column-fling-snaps-offscreen-overscroll-bound.md`](../planned/20260707-lone-column-fling-snaps-offscreen-overscroll-bound.md) — snap grid includes offscreen bound candidates for a lone/narrow column.
- [`20260628-relayout-path-recenters-fully-visible-unchanged-selection.md`](20260628-relayout-path-recenters-fully-visible-unchanged-selection.md), [`../completed/20260701-focus-confirm-skips-reveal-while-prior-spring-settles.md`](../completed/20260701-focus-confirm-skips-reveal-while-prior-spring-settles.md), and [`../completed/20260701-config-relayout-reinterprets-parked-edge-snapped-selection.md`](../completed/20260701-config-relayout-reinterprets-parked-edge-snapped-selection.md) — earlier variants where relayout or focus confirmation clobbers an already-useful viewport anchor.
- [`../completed/20260701-preserve-parked-edge-snapped-anchor-across-config-relayout.md`](../completed/20260701-preserve-parked-edge-snapped-anchor-across-config-relayout.md) and [`../completed/20260702-reveal-style-scroll-lock-redesign.md`](../completed/20260702-reveal-style-scroll-lock-redesign.md) — shipped policy/fix background for reveal style and scroll lock.
- [`20260627-trackpad-fling-snap-overshoot-to-neighbor-column.md`](20260627-trackpad-fling-snap-overshoot-to-neighbor-column.md) and [`20260625-precommitted-viewport-shifts-before-trackpad-gesture.md`](20260625-precommitted-viewport-shifts-before-trackpad-gesture.md) — adjacent gesture/release projection symptoms.

**Do not merge blindly:** VR-1 has at least three layers: snap target generation, reveal eligibility, and relayout selection reconciliation. Fixes should preserve explicit navigation while narrowing automatic movement.

## XD-1 — cross-display moves reveal at the wrong time, size, or workspace identity

**Common issue:** cross-display operations often combine a model move, monitor-size-dependent layout recomputation, native focus/admission, and reveal. If those are not atomic, a window can be revealed at the source display size, stranded offscreen, or admitted only after a click.

**Primary links:**

- [`20260706-summon-right-cross-display-size-dance.md`](20260706-summon-right-cross-display-size-dance.md) and [`../completed/20260706-summon-right-empty-active-workspace.md`](../completed/20260706-summon-right-empty-active-workspace.md) — Summon Right moves first, then relies on transition relayout, so the user sees a size/position dance across displays.
- [`20260707-external-display-column-admission-click-required.md`](20260707-external-display-column-admission-click-required.md) — external-display workspace migration leaves replacement/admission unsettled until focus.
- [`../completed/20260707-cross-display-move-strands-window-offscreen-missing-niri-column.md`](../completed/20260707-cross-display-move-strands-window-offscreen-missing-niri-column.md) — cross-display inactive workspace move can leave no niri column for the moved token.
- [`20260628-connecting-display-strands-window-via-layouttransient-hide-origin.md`](20260628-connecting-display-strands-window-via-layouttransient-hide-origin.md) and [`20260625-park-invisible-horizontal-second-monitor.md`](20260625-park-invisible-horizontal-second-monitor.md) — monitor arrangement/parking variants of offscreen stranding.
- [`../completed/20260707-dock-shield-phantom-right-inset-on-offset-secondary-display.md`](../completed/20260707-dock-shield-phantom-right-inset-on-offset-secondary-display.md) — display-edge geometry can leak between monitors and distort placement assumptions.

**Overlap:** XD-1 often overlaps LC-1 (admission/lifecycle) and VR-1 (reveal/snap), but the shared trigger is a display/workspace identity transition.

## TF-1 — transient/floating/PiP surfaces need durable classification across lifecycle and projection

**Common issue:** AppKit/AX metadata is often incomplete or misleading for helper surfaces. A surface may be zero-frame, tagless, unparented, or re-created with different metadata. If classification is only a one-time admission decision, projection or lifecycle refresh can tile it later or leak it into the workspace bar.

**Primary links:**

- [`../completed/20260706-thunderbird-gecko-dialog-tiled-untagged-unparented-standard-window.md`](../completed/20260706-thunderbird-gecko-dialog-tiled-untagged-unparented-standard-window.md), [`../completed/20260707-thunderbird-gecko-dialog-still-tiles-frame-isempty-guard-defeats-fix.md`](../completed/20260707-thunderbird-gecko-dialog-still-tiles-frame-isempty-guard-defeats-fix.md), [`../completed/20260707-thunderbird-gecko-dialog-floats-then-tiles-projection.md`](../completed/20260707-thunderbird-gecko-dialog-floats-then-tiles-projection.md), and [`../completed/20260707-thunderbird-gecko-dialog-durable-transient-metadata.md`](../completed/20260707-thunderbird-gecko-dialog-durable-transient-metadata.md) — compact Gecko dialog sequence; the final lesson is durable transient metadata plus classification that does not depend on non-empty frames.
- [`20260622-rescued-floating-auxiliary-windows-leak-into-workspace-bar.md`](20260622-rescued-floating-auxiliary-windows-leak-into-workspace-bar.md), [`20260628-stale-floating-entry-lingers-after-surface-destroyed.md`](20260628-stale-floating-entry-lingers-after-surface-destroyed.md), and [`../completed/20260624-user-addressable-floating-surfaces.md`](../completed/20260624-user-addressable-floating-surfaces.md) — bar/projection leakage from floating auxiliary surfaces.
- [`20260628-chromium-pip-opens-offscreen-never-create-seen.md`](20260628-chromium-pip-opens-offscreen-never-create-seen.md), [`20260705-nehir-108-pip-cross-monitor-bounce-sticky-not-globalsticky.md`](20260705-nehir-108-pip-cross-monitor-bounce-sticky-not-globalsticky.md), and [`../completed/20260624-nehir-108-pip-disappears-and-snaps-back-on-workspace-switch.md`](../completed/20260624-nehir-108-pip-disappears-and-snaps-back-on-workspace-switch.md) — PiP is a sibling class where special surfaces need consistent workspace/sticky semantics.

**Do not merge blindly:** TF-1 includes product policy (which surfaces are user-addressable) and engine mechanics (durable metadata). Keep app-specific built-ins narrow; avoid a broad "tagless standard window floats" rule.

## OT-1 — observability and tests can hide the real path

**Common issue:** recent bugs repeatedly involved silent guards, missing trace emissions, or tests that bypass the production seam. This makes root-cause notes depend on indirect evidence and makes regression tests pass without exercising the bug-triggering path.

**Primary links:**

- [`20260707-traceability-gaps-and-post-extraction-maintainability.md`](20260707-traceability-gaps-and-post-extraction-maintainability.md) — silent guards and free-form trace schema are a recurring investigation tax.
- [`20260708-test-only-seams-can-make-tests-untruthful.md`](20260708-test-only-seams-can-make-tests-untruthful.md) — inventory of test-only seams that can make tests miss production behavior.
- [`../completed/20260701-add-runtime-diagnostics-for-main-gesture-and-bar-issues.md`](../completed/20260701-add-runtime-diagnostics-for-main-gesture-and-bar-issues.md), [`20260621-better-record-trace-visual-feedback.md`](20260621-better-record-trace-visual-feedback.md), and [`../completed/20260624-recent-trace-clip-buffer.md`](../completed/20260624-recent-trace-clip-buffer.md) — prior observability work.
- [`../planned/20260625-unrecorded-viewport-offset-mutation-attribution.md`](../planned/20260625-unrecorded-viewport-offset-mutation-attribution.md) — concrete viewport mutation attribution gap related to VR-1.

**Actionable review heuristic:** before accepting a new plan for NF-1, LC-1, VR-1, or XD-1, require an explicit trace point for the guard/decision being changed and verify that any proposed test follows the same production path as the runtime bug. For NF-1 generic command-target work, reuse the `command_target.resolve.*` events shipped in `f6078799` instead of adding another parallel trace vocabulary.
