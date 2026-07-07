# Define expectations and fix niri fullscreen

Re-verified against main 7a025b78 on 2026-07-07.

**Status:** planned
**Source discovery:** `discovery/20260621-niri-fullscreen-expectations-and-fix.md`
**Related:** `discovery/20260617-nehir-69-fullscreen-restore-on-focus.md` (owns
the #69 bug body), `planned/20260621-backlog-brainstorm.md` idea #20,
`discovery/20260621-window-width-vs-column-width-semantics.md` (window-node vs
column-property robustness contrast),
`planned/20260622-native-fullscreen-toggle-exit-target.md` (separate native
macOS fullscreen fix), `planned/20260622-fullscreen-behaviour-roadmap.md`
(coordination roadmap)
**Prerequisite:** none blocking; coordinates with
`completed/20260616-unified-config-diagnostics-and-migration-policy.md` if any
default binding is renamed.

Source references were refreshed against main `7a025b78` on 2026-07-07. The `.maximized` sizing mode still exists (`Sources/Nehir/Core/Layout/Niri/NiriNode.swift:19`), and the command remains labeled `Toggle Fullscreen` (`Sources/Nehir/Core/Input/ActionCatalog.swift:902`).

## TL;DR

Nehir's `toggleFullscreen` does not do what niri calls fullscreen. It renders to
the gap- and strut-inset *working frame* (`canonicalFullscreenRect = workingFrame`,
`NiriLayout.swift:179`), so it keeps outer gaps **and** respects the menu /
workspace bar. That is niri's *maximize-to-edges* territory, not niri's
*fullscreen*. There is a second sizing mode, `SizingMode.maximized`
(`NiriNode.swift:16-22`), that would host a true screen-covering mode — but it is
**dead**: rendered (`NiriLayout.swift:1026-1027,1069-1070`) and defensively
cleared (`NiriLayoutEngine+Sizing.swift:900-901,962-963`) yet **never assigned**
(anywhere — verified: no `= .maximized` write site exists; only `.normal` /
`.fullscreen` are ever written, plus restore-of-state at
`NiriLayoutEngine+Restore.swift:139`).

This plan adopts the discovery's **niri-loyal minimum** recommendation in two
phases:

- **Phase A — define (product decision + dead-code removal):** keep
  `toggleFullscreen` *sticky* (matches upstream niri; no auto-restore on focus
  move) and **relabel** the action so the name matches what the rect actually
  does ("Maximize" / maximize-to-edges), keeping the existing working-frame rect.
  **Delete the dead `.maximized` mode** and its render/geometry/clear branches as
  independently-correct cleanup.
- **Phase B — fix #69 (tiling path only):** make `toggleFullscreen` reliably
  target the workspace's fullscreen node when selection has moved off it (today
  it reads the *focused* node's `sizingMode` and no-ops / toggles the wrong
  window), add a trace event to the tiling toggle (today it is silent), and
  verify that focusing a neighbour visibly reveals it.

Both phases are small. The correct Phase-B toggle behavior depends on the
Phase-A stickiness decision, so Phase A is decided first.

Follow-up comments on #69 have now resolved the open product question: both
reporters preferred **option 2, niri-style sticky fullscreen/maximize**. This
confirms the plan's no-auto-restore direction. The implementation should make
sticky navigation and toggling reliable; it should not restore a maximized window
just because focus moves to a neighbour.

This plan is one of **two active fullscreen fix plans**. It covers only the
layout/tiling `toggleFullscreen` path. The native macOS fullscreen path is tracked
separately in `planned/20260622-native-fullscreen-toggle-exit-target.md` because
new evidence shows a distinct command-target bug where toggling while already in
native fullscreen can enter native fullscreen on another managed window instead
of exiting the current native-fullscreen record.

## Discovery corrections / decisions

The discovery's product verdict and scope stand. Corrections made while
porting to current main `7a025b78`:

1. **Phase-B toggle-entry site is stale in the discovery.** It cites "#69's
   `:1288-1291` guard" for the handler. At current HEAD the toggle entry is
   `NiriLayoutHandler.toggleFullscreen()` at `NiriLayoutHandler.swift:1558`,
   whose resolution guard is `:1561-1564`
   (`guard let currentId = state.selectedNodeId, let currentNode =
   engine.findNode(by: currentId), let windowNode = currentNode as? NiriWindow`)
   and the engine call is `engine.toggleFullscreen(windowNode, …)` at `:1566`.
   This is the authoritative Phase-B edit site, not `:1288`.
2. **`effectiveSizingMode` line range.** Discovery said `:298-321`; the var
   actually starts at `ViewportState+Geometry.swift:300` (body `:300-321`).
   `area(for:)` is `:284-286` as stated.
3. **Defensive `.maximized` clear ranges.** Discovery cited `:901,963`; the
   `if … { … }` pairs are `NiriLayoutEngine+Sizing.swift:900-901` (in the
   height-reset path) and `:962-963` (in `resetWindowHeight`).
4. **`WorkspaceManager` location / field name.** It lives at
   `Sources/Nehir/Core/Workspace/WorkspaceManager.swift` (not `…/Controller/`).
   The native-fullscreen record store is `nativeFullscreenRecordsByOriginalToken`
   (`:215`); `nativeFullscreenRecord(for:)` is the accessor (`:1299`). The
   transition guard consumed by any native-path fix is
   `hasPendingNativeFullscreenTransition` (`:1119-1121`), already used by
   `WMController` (`:3918`) and `FocusBorderController` (`:291`).
5. **Trace-event location.** `WMEvent` is at `Sources/Nehir/Core/Reconcile/WMEvent.swift`.
   The native path emits `.nativeFullscreenTransition` (`:69`); `.windowModeChanged`
   (`:47`) carries a `TrackedWindowMode` (floating/tiling), **not** `SizingMode`,
   so a tiling sizing transition needs a **new** case. WMEvents are emitted from
   the controller layer (`WMController`/handlers), never from the pure niri
   engine — so the emit site is the handler, not `NiriLayoutEngine+Sizing.swift`
   (this also keeps the engine extraction-friendly; see
   `completed/20260619-pure-niri-engine-extraction-a1.md`).

Decisions encoded by this plan (resolving the discovery's open questions):

- **#1 Target model — Option (a) "relabel", not Option (b) "revive".** Keep the
  working-frame rect (matches the existing test
  `NiriLayoutEngineTests.swift:4538` `expectedFullscreenFrame =
  monitor.visibleFrame.roundedToPhysicalPixels(scale:)`) and rename the action
  surface to "Maximize". Option (b) (true screen-covering, revive `.maximized`,
  hide gaps/bar) is a larger, riskier change touching `WMController.insetWorkingFrame`
  (`WMController.swift:820`) and is recorded under Risks as the swap-out
  alternative, **not** chosen.
- **#2 Sticky (niri-loyal).** No auto-restore on focus move.
- **#3 Delete `.maximized`.** Revival is gated on Option (b), which is not
  chosen; deleting dead branches is a net win independent of #69.
- **#4 G2 (window-awareness) deferred.** `toggleNativeFullscreen` already covers
  real fullscreen; the AX risk of driving `AXFullScreen` from the tiling path is
  not worth the small macOS payoff.

## Scope

### Files to add/change

**Phase A — define / relabel / dead-code removal**

1. `Sources/Nehir/Core/Input/ActionCatalog.swift:471-475` — `toggleFullscreen`
   action spec. Update the user-facing title at `:881`
   (`case .toggleFullscreen: "Toggle Fullscreen"`) to a maximize-to-edges label
   (e.g. `"Toggle Maximize"`). Keep the `id: "toggleFullscreen"` and
   `.toggleFullscreen` command symbol **stable** so existing bindings /
   config (`HotkeyConfigMapping`) and IPC keep parsing; only the display label
   changes. (Default binding `Opt+Return` at `:474` is unchanged.)
2. `Sources/Nehir/Core/Layout/Niri/NiriNode.swift:16-22` — `SizingMode` enum.
   Delete `case maximized`, leaving `.normal` / `.fullscreen`.
3. `Sources/Nehir/Core/Layout/Niri/NiriLayout.swift:1026-1027` and `:1069-1070` —
   collapse the `case .fullscreen, .maximized:` fallthroughs to `case .fullscreen:`
   in both the frame-compute switch and the animated-frame switch.
4. `Sources/Nehir/Core/Layout/Niri/ViewportState+Geometry.swift:284-286` —
   `area(for mode:)` is currently `mode.isMaximized ? parent : working`, i.e. it
   returns `parent` **only** for `.maximized` and `working` for both `.normal`
   and `.fullscreen`. With `.maximized` gone it therefore always returns
   `working`; inline it to a constant `working` return at the call sites
   (`computeModeAwareFitOffset` / `…CenteredOffset`, `:562,595` — the only
   consumers) and delete `area(for:)` plus the `isMaximized` helper
   (`:289-291`). This is behavior-preserving: `.maximized` was never produced, so
   `parent` was never actually returned at runtime.
5. `Sources/Nehir/Core/Layout/Niri/ViewportState+Geometry.swift:300-321` —
   `effectiveSizingMode`: drop the `anyMaximized` accumulation and the
   `else if anyMaximized { return .maximized }` branch (`:315-317`), leaving
   fullscreen-or-normal.
6. `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+Sizing.swift:900-901` and
   `:962-963` — delete both `if window.sizingMode == .maximized {
   window.sizingMode = .normal }` defensive clears (unreachable).
7. `Resources/` / onboarding copy (if any user-visible string says "Fullscreen"
   for this action) — update to match the new label. Audit with a repo-wide
   search for the old display string before editing.

**Phase B — fix #69 against the sticky model (tiling path only)**

8. `Sources/Nehir/Core/Controller/NiriLayoutHandler.swift:1558-1568` —
   `toggleFullscreen()`. Today the guard at `:1561-1564` resolves the target from
   `state.selectedNodeId` only, so once focus moves to a neighbour the press
   toggles the wrong window. Change resolution: if the focused node is
   `.normal`, **search the current workspace's columns for a window whose
   `sizingMode == .fullscreen`**; if exactly one exists, target *that* node for
   un-fullscreen; if the focused node itself is `.fullscreen`, target it as
   today; if none, no-op cleanly. Keep the existing
   `requestRefresh(reason: .layoutCommand)` (`:1568`) and
   `startScrollAnimationIfNeeded` (`:1569`) calls.
9. `Sources/Nehir/Core/Reconcile/WMEvent.swift` — add a new case for the tiling
   sizing transition, mirroring `.nativeFullscreenTransition` (`:69`):
   `case sizingModeChanged(token: WindowToken, workspaceId: …, monitorId: …,
   sizingMode: SizingMode, source: WMEventSource)`. Wire it into the
   token/workspaceId/monitorId extractor (`:120-140`), the source extractor
   (`:148-160`), and the debugDescription switch (`:180-206`).
10. `Sources/Nehir/Core/Controller/NiriLayoutHandler.swift` (the `:1566`
    engine-call site) — after `engine.toggleFullscreen(…)`, emit the new
    `.sizingModeChanged` event with the resolved node's resulting `sizingMode`
    and `source` (reuse the `motion`/`source` already in the
    `withNiriWorkspaceContext` closure). This makes the tiling toggle observable
    in the event stream, which is the gap #69 hit (the tiling path was silent).
11. `Sources/Nehir/Core/Layout/Niri/NiriNavigation.swift:382-411` —
    `focusColumnByIndex` (verification only, no edit expected): confirm it does
    **not** write `sizingMode` (correct for the sticky model) and that
    `ensureSelectionVisible(...)` at `:405` reveals the newly-focused neighbour
    past a sticky fullscreen window. If reveal is unreliable, that is a separate
    follow-up (see Follow-ups), not a blocker.

### Non-goals

- Do **not** change `toggleColumnFullWidth` — it is a faithful niri
  `maximize-column` (`ActionCatalog.swift:603`, `NiriLayoutEngine+Sizing.swift:625`,
  `NiriNode.swift:393`). Correct and out of scope.
- Do **not** change `toggleNativeFullscreen` here — genuine macOS AX fullscreen
  (`AXWindow.swift:538`), the only window-aware path. It now has its own plan:
  `planned/20260622-native-fullscreen-toggle-exit-target.md`. Any native-path
  work must respect `WorkspaceManager.hasPendingNativeFullscreenTransition`
  (`WorkspaceManager.swift:1119`).
- Do **not** bundle native-path focus/record churn into this tiling plan. The
  native workstream includes the earlier focus storm evidence (lease
  misattribution to `window_close_focus_recovery`, repeated `window_admitted`,
  post-exit A↔B↔C `managed_focus_requested`/`managed_focus_confirmed`) plus new
  evidence where toggling while already native-fullscreen created multiple native
  fullscreen records instead of exiting the current one.
- Do **not** implement G2 (drive `AXFullScreen` from the tiling path). Deferred;
  `toggleNativeFullscreen` already serves real fullscreen.
- Do **not** add auto-restore-on-focus. Stickiness is the chosen model.
- Do **not** revive `.maximized` (Option (b) is not chosen; it is deleted).
- Do **not** rename the `toggleFullscreen` command symbol / `id` / TOML key —
  only the display label changes, to preserve binding / IPC / config round-trip.

## Exact implementation plan

Ordered; each phase is independently shippable but Phase A's stickiness decision
is what makes Phase B's resolution rule correct.

### Phase A — define the model (product decision + dead-code removal)

**A1. Delete `.maximized` (dead code).** Remove the enum case
(`NiriNode.swift:21`), the two render fallthroughs (`NiriLayout.swift:1027,1070`),
the `area(for:)` `parent` branch and `isMaximized` helper
(`ViewportState+Geometry.swift:284-291`), the `effectiveSizingMode` maximized
accumulation (`:300-321`), and the two defensive clears
(`NiriLayoutEngine+Sizing.swift:900-901,962-963`). The compiler will flag every
remaining `case .maximized` / `.maximized` reference; resolve each to the
`.fullscreen` or `.normal` arm. After this, `setWindowSizingMode`
(`:375-404`) is unchanged in behavior — it already only handles
`.normal ↔ .fullscreen`.

**A2. Relabel the action (Option a).** In `ActionCatalog.swift` change the
`:881` display string from `"Toggle Fullscreen"` to `"Toggle Maximize"` (or
product's chosen maximize-to-edges wording). Keep `id: "toggleFullscreen"`,
`command: .toggleFullscreen`, the `Opt+Return` default (`:474`), the TOML key,
and the IPC symbol unchanged. Audit `Resources/` and any onboarding/settings copy
for the old string and align. No settings migration is needed because no binding
or key changes — only a display label (confirm against
`completed/20260616-unified-config-diagnostics-and-migration-policy.md`'s policy:
label-only changes do not require a migration entry).

**A3. Verify the rect decision is documented.** The rect stays
`canonicalFullscreenRect = workingFrame` (`NiriLayout.swift:162,179`) — visible
frame, gaps and bar kept — now matched by the "Maximize" label. No code change
to the rect; this step is the product sign-off captured in this plan.

### Phase B — fix #69 against the sticky model (tiling path only)

**B1. Make the toggle target the fullscreen node.** In
`NiriLayoutHandler.toggleFullscreen()` (`:1558-1568`), after resolving the
focused node via the existing guard (`:1561-1564`), apply this resolution rule
*before* calling `engine.toggleFullscreen(...)`:

- If the focused window's `sizingMode == .fullscreen`, target it (current
  behavior).
- Else, enumerate the current workspace's columns and find windows with
  `sizingMode == .fullscreen`. If exactly one, target that node (un-fullscreen
  it). If more than one, target the most-recently-fullscreened (or first found)
  and emit the trace event; the one-fullscreen-per-workspace invariant should
  hold, so the multi case is defensive.
- Else (no fullscreen window in the workspace), no-op cleanly (do not toggle the
  focused normal window *on* unless it was already the intended target — keep
  today's "toggle on" semantics only when no fullscreen node exists and the user
  is explicitly maximizing the focused window; this preserves the maximize affordance).

The engine entry `NiriLayoutEngine.toggleFullscreen` (`NiriLayoutEngine+Sizing.swift:407-413`)
is unchanged; it already flips `.normal ↔ .fullscreen` for whatever `NiriWindow`
it is handed. The fix is entirely in target resolution at the handler.

**B2. Add the trace event.** Add `WMEvent.sizingModeChanged` (Scope item 9). Emit
it from the handler at `:1566` immediately after `engine.toggleFullscreen(...)`,
reading the resolved node's `sizingMode` and the closure's `source`. This closes
the observability gap that left #69's tiling path silent.

**B3. Verify sticky reveal.** Manually confirm (repro steps below) that with a
fullscreen window in column 2 and focus moved to column 1 or 3,
`ensureSelectionVisible` (`NiriNavigation.swift:405`) scrolls the neighbour into
view so the user is not stranded. If it does not reveal reliably, file the
viewport-scroll fix as a follow-up (out of scope here) — the B1 toggle fix alone
already un-strands the user because the press now un-fullscreens the right node.

## Tests

Named files and cases; map each to the behavior it pins.

- `Tests/NehirTests/NiriLayoutEngineTests.swift`
  - Existing `:4538` (`expectedFullscreenFrame =
    monitor.visibleFrame.roundedToPhysicalPixels(scale: area.scale)`) and `:4557`
    (`focusHitTestPrefersFullscreenWindowOverCoveredTile`) **stay green
    unchanged** after Phase A — the rect does not change (Option a) and the
    hit-test preference is still desired. Re-run, do not rewrite.
  - **Add** `toggleFullscreenUnfullscreensWorkspaceNodeAfterFocusMoves` — 3-column
    fixture; fullscreen column 2's window; move selection to column 1; invoke the
    handler's `toggleFullscreen()`; assert column 2's window returns to
    `.normal` and column 1's window stays `.normal` (Phase B / B1).
  - **Add** `toggleFullscreenNoOpsWhenNoFullscreenWindowInWorkspace` — no
    fullscreen window, focused window is `.normal`; invoking toggle maximizes the
    focused window (preserve on-affordance) OR no-ops per the chosen sub-rule;
    pin whichever B1 decides (Phase B / B1).
- `Tests/NehirTests/ViewportGeometryTests.swift`
  - Existing `.maximized` fixtures at `:36-37,57,65,82-83,125` **must be removed
    or rewritten** to drop `.maximized` inputs (Phase A / A1). Convert each to a
    `.fullscreen`-only or `.normal`-only assertion as appropriate. Add a case
    asserting `area(for: .fullscreen)` returns the working area and that
    `effectiveSizingMode` never reports a maximized value once the case is gone.
- `Tests/NehirTests/WMEventTests.swift` (or the existing event-encoding suite —
  locate via the `WMEvent` encoder tests)
  - **Add** `sizingModeChangedRoundTripsThroughEncoder` — encode/decode the new
    case and assert token/workspaceId/monitorId/sizingMode/source survive (Phase B / B2).
- No new test for the `ActionCatalog` label change unless a snapshot test pins
  display strings; if one exists, update the expected string.

## Validation

```bash
swift build
swift test --filter NiriLayoutEngineTests
swift test --filter ViewportGeometryTests
swift test --filter WMEvent            # encoder/decoder suite for the new case
# Plus the full suite once Phase A's enum deletion settles:
swift test
```

Manual validation (self-contained; no captured log needed):

1. Three columns in one workspace on one monitor. Note the middle column's window.
2. Focus the middle column, trigger `toggleFullscreen` (default `Opt+Return`;
   reporter's rebound `Opt+Shift+F`). Observe it fills the **working area** —
   outer gaps and the menu/workspace bar remain visible (rect = `workingFrame`,
   not the screen). The label now reads "Toggle Maximize" (Phase A).
3. Press focus-left / focus-right to a neighbour. Observe: the maximized window
   stays maximized (`focusColumnByIndex` does not write `sizingMode` — sticky,
   per the chosen model); the neighbour is revealed if the viewport scrolls it
   into view (Phase B / B3).
4. Press `toggleFullscreen` again. **Expected after Phase B:** the workspace's
   maximized node reliably returns to `.normal` even though selection is on the
   neighbour (B1), and a `sizingModeChanged` event appears in the event stream (B2).
5. Sanity (Phase A dead-code removal): `grep -rn ".maximized" Sources/Nehir`
   returns no enum-case references after the build is green.

Changeset (minor): "Define niri fullscreen expectations: relabel tiling
fullscreen as Maximize, delete the dead `.maximized` sizing mode, and make
`toggleFullscreen` reliably target the workspace's fullscreen node (#69)."

## Risks and mitigations

- **Product fork not fully settled.** This plan commits to Option (a) + sticky +
  delete `.maximized` per the discovery's recommendation. If product instead
  wants Option (b) (true screen-covering fullscreen), the swap is localized:
  revive `.maximized`, point `canonicalFullscreenRect` at the full view frame
  instead of `workingFrame` (`NiriLayout.swift:179`), bypass
  `WMController.insetWorkingFrame` (`WMController.swift:820`) for that mode, and
  keep the "Fullscreen" label. Record the decision before B1 is merged.
- **Multi-fullscreen-per-workspace edge case.** B1's "exactly one fullscreen
  node" assumption should hold (toggle is per-window and the rect covers the
  working frame), but if two windows are somehow `.fullscreen` in one workspace,
  pick one deterministically (e.g. the selected column's, else lowest-id) and
  emit the trace event. The defensive branch prevents a no-op.
- **Label-only rename regressions.** Changing `"Toggle Fullscreen"` to
  `"Toggle Maximize"` must not alter the command symbol, `id`, TOML key, or IPC
  representation. Add / update a round-trip test in `HotkeyConfigMapping` only if
  the display string is part of the serialized shape (it should not be).
- **Engine-extraction friendliness.** Emitting `.sizingModeChanged` from the
  handler (not from inside `NiriLayoutEngine+Sizing.swift`) keeps the niri engine
  free of `WMEvent` dependencies, consistent with
  `completed/20260619-pure-niri-engine-extraction-a1.md`. Do not push the emit into
  the engine.
- **Sticky-model UX surprise.** Users coming from Aerospace/i3 auto-restore may
  expect focus to un-maximize. Mitigation: the B1 toggle now *works* when they
  press it again (the actual #69 defect), and the relabel sets the expectation
  that this is a niri-style sticky maximize. Do not add auto-restore.
- **Native path is disjoint.** Any later native-fullscreen fix must respect
  `WorkspaceManager.hasPendingNativeFullscreenTransition`
  (`WorkspaceManager.swift:1119`); do not couple it to Phase B.

## Follow-ups (out of scope)

- **#69 native path** — the focus-lease misattribution, repeated `window_admitted`,
  and post-exit A↔B↔C focus storm. Owned by
  `discovery/20260617-nehir-69-fullscreen-restore-on-focus.md`; disjoint from this
  tiling work.
- **G2 window-awareness** — driving `AXFullScreen` / zoom-button state from the
  tiling maximize path so apps square corners / hide chrome. Needs an AX spike;
  low payoff on macOS. Defer unless requested.
- **Sticky reveal polish** — if `ensureSelectionVisible` does not reliably reveal
  a neighbour past a sticky maximize window, a viewport-scroll follow-up (not a
  toggle fix).
- **Option (b) true fullscreen** — if product later wants niri `fullscreen-window`
  semantics (whole screen, black backdrop, cover the bar), revive `.maximized`
  and swap the rect per the Risks note. Sequenced after this plan lands.
