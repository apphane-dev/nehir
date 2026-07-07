# Define expectations and fix niri fullscreen — Discovery

Groom 2026-07-07: in flight (partially resolved) — native-fullscreen column drift was fixed (`56095965`); the broader expectations/tiling-fullscreen restore-on-focus semantics remain open; see `planned/20260621-niri-fullscreen-expectations-and-fix.md` and `planned/20260622-fullscreen-behaviour-roadmap.md` (verified against main 7a025b78).

Source: backlog brainstorm idea **#20**, *"Define expectations and fix niri
fullscreen"* (`planned/20260621-backlog-brainstorm.md`), which itself points at
`discovery/20260617-nehir-69-fullscreen-restore-on-focus.md`. This doc is the
**companion** to the #69 investigation: #69 scoped the *bug* (focus-restore +
intermittent toggle) and **explicitly declined** to (a) decide the intended
semantics or (b) propose a fix — *"Scope: collect context for investigation.
Does not propose a fix."* Idea #20 is precisely those two deferred pieces:
**define the target expectations, then fix toward them.**

Verified against the main Nehir source tree at HEAD `e7b246b6` on 2026-06-21.
Line numbers drift — re-verify before implementing. The sibling #69 doc was last
verified at `7b731a51`; the deltas since then are called out inline (notably,
`.maximized` now has its own render/geometry branch it did not have before, and
it is still never produced).

> Scope: product-level expectations definition + a concrete fix
> recommendation. Source is read-only on this branch; no code changes.

---

## TL;DR / recommendation

- **Pursue, in two phases.** Phase A is "define": reconcile Nehir's *three*
  "make it big" surfaces with niri's *four* and pick a target model. Phase B is
  "fix": repair the #69 toggle/focus bugs against the chosen model. The two are
  coupled — the correct #69 fix depends on the Phase-A decision.
- **The expectation problem is a naming + coverage muddle, not just a bug.**
  Nehir's `toggleFullscreen` action does **not** do what niri calls fullscreen.
  It renders to the gap- and strut-inset *working frame* (`canonicalFullscreenRect
  = workingFrame`, `NiriLayout.swift:162,179`), so it keeps outer gaps **and**
  respects the menu bar / workspace bar. That is niri's *maximize-to-edges*
  territory (minus border hiding), not niri's *fullscreen*. There is no action
  that covers the whole screen like niri's `fullscreen-window`.
- **Nehir already has a second sizing mode that would map to a different niri
  mode, but it is dead code.** `SizingMode.maximized` (`NiriNode.swift:16-24`)
  is rendered (`NiriLayout.swift:1026`, `ViewportState+Geometry.swift:284-286`)
  and defensively cleared (`NiriLayoutEngine+Sizing.swift:901,963`), but it is
  **never assigned** anywhere except restore-of-state
  (`NiriLayoutEngine+Restore.swift:139`) — and nothing produces it. It is
  unreachable today.
- **No Nehir "make it big" action is window-aware on the tiling path.** The
  `AXFullScreen` attribute plumbing (`AXWindow.swift:497-566`) is used **only**
  by `toggleNativeFullscreen` (real macOS fullscreen, own Space). Tiling
  `.fullscreen`/`.maximized` are pure layout-rect changes; the app is never told
  it is maximized/fullscreen, so it will not square corners, hide toolbars, etc.
  — a real behavioral gap versus niri (whose maximize/fullscreen set XDG state).
- **The #69 "focus doesn't restore" symptom is half a product decision, half a
  bug.** niri keeps `fullscreen-window` *sticky* (scrolling away reveals
  neighbours; the window stays fullscreen). So "auto-restore on focus" is a
  product fork, not a port. The actual bug is that Nehir's toggle then becomes a
  no-op once selection moves off the fullscreen node, and the fullscreen window
  occludes its column siblings (`focusHitTestPrefersFullscreenWindowOverCoveredTile`,
  `NiriLayoutEngineTests.swift:4557`) — so the user is stuck.

---

## Prior work on this branch (reconciliation)

- **`discovery/20260617-nehir-69-fullscreen-restore-on-focus.md`** — owns the
  **#69 bug investigation**. Confirmed the three-mechanism map, the
  `.normal↔.fullscreen`-only toggle (`NiriLayoutEngine+Sizing.swift:407`), the
  focus path that never writes `sizingMode` (`focusColumnByIndex`,
  `NiriNavigation.swift:382`), and inlined the native-path trace evidence
  (focus-lease misattribution to `window_close_focus_recovery`, seven
  `window_admitted` in ~1 s, post-exit A↔B↔C focus storm). Its open question #1
  — *"Decide the intended semantics first"* — is exactly what this doc answers.
- **`noop/20260617-omniwm-244-native-fullscreen-counted-and-leak.md`** — owns the
  native-fullscreen **suspension + transition-guard** design. Verdict 🟢 for the
  *counting*/*content-leak* symptoms; #69's native-path symptoms are a disjoint
  failure mode not covered there. Relevant here only because any Phase-B fix on
  the native path must respect that guard set
  (`WorkspaceManager.hasPendingNativeFullscreenTransition`).
- **`discovery/20260617-omniwm-326-niri-column-over-100-percent-width.md`** — owns
  the **column-width cap**; confirms `toggleColumnFullWidth` = exactly
  `proportion(1.0)` (clamped at `min(1.0,…)` in `SettingsStore`). This is the
  source of truth that `toggleColumnFullWidth` is a faithful `maximize-column`.
- **`discovery/20260617-omniwm-373-smart-gaps-single-window.md`** — owns **smart
  gaps** (absent). Confirms a lone window fills the gap-inset working frame, and
  that `singleWindowLayoutContext` gates on `sizingMode == .normal`
  (`NiriLayoutEngine.swift:287`) — so a fullscreen/maximized lone window is
  excluded from the lone-window policy. Reinforces that Nehir "fullscreen" keeps
  gaps.
- **`discovery/20260616-omniwm-295-niri-window-width-preservation.md`** — owns
  width-state preservation on cross-workspace move; confirms `isFullWidth` is a
  **column** property carried on moves (`NiriLayoutEngine+ColumnOps.swift:40`),
  unlike the window-node `sizingMode`. This contrast (column-property = robust
  under focus/move; window-node property = fragile) is central to the #69 fix.

This doc **adds**: the authoritative niri 4-mode model, the Nehir→niri
faithfulness table at current HEAD, the discovery that `.maximized` is dead
state, the window-awareness gap, and the phased recommendation. It does not
re-derive the trace evidence (see #69).

---

## What "niri fullscreen" means upstream (authoritative)

From the niri wiki *Fullscreen and Maximize* (current `main`,
`docs/wiki/Fullscreen-and-Maximize.md`). niri has **four** "make it big" actions
today (one more than when #69 was written — `maximize-window-to-edges` shipped in
niri 25.11):

| niri action | Default | Since | Protocol state | Covers | Bar / struts | Gaps | Borders | Window-aware? | Multi-window? |
|---|---|---|---|---|---|---|---|---|---|
| `maximize-column` | `Mod+F` | stable | none (layout) | **width only** | respected | kept | kept | no | yes (column) |
| `maximize-window-to-edges` | `Mod+M` | **25.11** | `XDG_MAXIMIZED` | available area edges | bar **visible** | **hidden** | **hidden** | **yes** | no (or tabbed) |
| `fullscreen-window` | `Mod+Shift+F` | stable | `XDG_FULLSCREEN` | **entire screen** | **covered** + black backdrop | hidden | hidden | **yes** | no |
| `toggle-windowed-fullscreen` | — | 25.05 | `XDG_FULLSCREEN` (told, not shown) | normal rect | normal | normal | normal | yes | n/a |

Two wiki passages fix the semantics precisely:

- maximize-to-edges: *"it expands a window to the edges of the available screen
  area. You will still see your bar, but not struts, gaps, or borders."*
- fullscreen-window: *"Fullscreen windows cover the entire screen. … Niri
  renders a solid black backdrop behind fullscreen windows."*

And the cross-cutting rule that governs the #69 "sticky" question: *"Thanks to
scrollable tiling, fullscreen and maximized windows remain a normal participant
of the layout: you can scroll left and right from them and see other windows."*
→ In niri, focusing/scrolling away does **not** unfullscreen. Fullscreen is
sticky. This is the upstream answer to #69's open question #1.

---

## Current Nehir behavior (HEAD `e7b246b6`)

Nehir exposes **three** "make it big" actions plus a dead fourth mode:

### 1. `toggleColumnFullWidth` — column maximize (default `Opt+Shift+F`)

- Spec: `ActionCatalog.swift:602-607`. Engine `toggleFullWidth`
  (`NiriLayoutEngine+Sizing.swift:625`); flips `column.isFullWidth`
  (`NiriNode.swift:393`) and sets width to `proportion(1.0)`. Column property,
  carried on moves (`NiriLayoutEngine+ColumnOps.swift:40`).
- **Faithful to niri `maximize-column`.** ✅ Width-only, keeps gaps/struts/
  borders, multi-window. This one is correct; not in scope.

### 2. `toggleFullscreen` — window-node "fullscreen" (default `Opt+Return`)

- Spec: `ActionCatalog.swift:470-475`. Handler `CommandHandler.swift:101-102` →
  `LayoutCoordinator.toggleFullscreen()` → engine `toggleFullscreen`
  (`NiriLayoutEngine+Sizing.swift:407-413`), which **only** flips
  `.normal ↔ .fullscreen`:
  `let newMode = window.sizingMode == .fullscreen ? .normal : .fullscreen`.
- `setWindowSizingMode` (`+Sizing.swift:375-405`) saves/restores
  `window.savedHeight` and a viewport offset, then writes
  `window.sizingMode = mode` (`:404`). It handles **only** `.normal↔.fullscreen`.
- **Rendered rect = the working frame.** `canonicalFullscreenRect = workingFrame`
  (`NiriLayout.swift:179`), and `workingFrame = workingArea?.workingFrame ??
  monitorFrame` (`:162`). The working frame is the gap- and strut-inset area.
  This is codified in a test: `expectedFullscreenFrame =
  monitor.visibleFrame.roundedToPhysicalPixels(scale: area.scale)`
  (`NiriLayoutEngineTests.swift:4538`) — i.e. **visible frame, menu bar / Dock
  respected, outer gaps kept**.
- State lives on the **window node** (`NiriNode.swift:702`), read via
  `state.selectedNodeId` — the selection-dependent, focus-fragile path.

### 3. `toggleNativeFullscreen` — macOS-native AX fullscreen (default `Opt+Shift+Cmd+Return`)

- Spec: `ActionCatalog.swift:476-481`. Handler
  `CommandHandler.toggleNativeFullscreenForFocused()` (`CommandHandler.swift:242`),
  calls `AXWindowService.setNativeFullscreen(axRef, fullscreen:)`
  (`AXWindow.swift:538`) — the real macOS `AXFullScreen` attribute, own Space.
  Tracked via `WorkspaceManager.nativeFullscreenRecord` + suspension (see #244).
- **No niri analog** (niri is Wayland). This is genuine macOS fullscreen and is
  the only window-aware path. The #69 native-path symptoms live here.

### 4. `SizingMode.maximized` — DEAD mode (no action)

- Defined: `NiriNode.swift:16-24` (three cases: `.normal`, `.maximized`,
  `.fullscreen`). Rendered: `NiriLayout.swift:1026` and `:1069` render
  `.maximized` identically to `.fullscreen` (both → `fullscreenRect`). Geometry:
  `ViewportFittingAreas.area(for:)` returns `parent` for `.maximized` vs
  `working` for `.fullscreen` (`ViewportState+Geometry.swift:284-286`), consumed
  only by viewport offset math (`computeModeAwareFitOffset` / `…CenteredOffset`,
  `:562,595`).
- **Never produced.** A repo-wide search for `sizingMode` writes shows the only
  non-`.normal` writers are `setWindowSizingMode` (`:404`, which only ever
  receives `.normal`/`.fullscreen` from `toggleFullscreen`) and restore
  (`NiriLayoutEngine+Restore.swift:139`, `window.sizingMode = state.sizingMode`).
  Nothing assigns `.maximized`. The defensive `if window.sizingMode == .maximized
  { window.sizingMode = .normal }` at `+Sizing.swift:901,963` can therefore never
  fire. `effectiveSizingMode` (`ViewportState+Geometry.swift:298-321`) aggregates
  a `.maximized` branch that is unreachable.
- This is the "hidden 4th mode" #69 flagged as plumbing-only — now confirmed dead
  at current HEAD.

### Nehir → niri faithfulness (current HEAD)

| Nehir action | Closest niri action | Faithfulness |
|---|---|---|
| `toggleColumnFullWidth` | `maximize-column` | ✅ Faithful. |
| `toggleFullscreen` (`.fullscreen`) | between `maximize-window-to-edges` and `fullscreen-window` | ⚠️ **Mislabeled middle.** Window-level like niri's window modes, but the rect is the *working frame* (keeps gaps **and** the bar). niri's maximize-to-edges keeps the bar but hides gaps/borders; niri's fullscreen hides the bar too. Nehir's does neither hide — it is "maximize-to-edges but keep gaps." Not window-aware. |
| `toggleNativeFullscreen` | none (macOS-native) | n/a |
| `.maximized` (dead) | would-be `fullscreen-window` or `maximize-to-edges` | ❌ **Unreachable.** The `area(for:)` `parent`-rect branch suggests an intent to cover the full view frame (screen), i.e. true niri fullscreen — but it is never set. |

---

## The core expectation problem (what "fix" must fix first)

Three independent gaps, each independently fixable:

**G1 — Naming/coverage.** Users invoking "Toggle Fullscreen" do not get niri
fullscreen (whole screen, black backdrop). They get "fill the working area while
keeping gaps and the bar." There is no action for either niri window mode
(`maximize-window-to-edges` or `fullscreen-window`). `.maximized` exists to host
one of them but is dead. So the surface is both *mislabeled* and *incomplete*.

**G2 — Window-awareness.** On the tiling path the app is never told it is
maximized/fullscreen. macOS exposes `AXFullScreen` (already plumbed at
`AXWindow.swift:538`) and the zoom-button / `AXFullScreen` subrole
(`AXWindow.swift:497,566`); none of it is driven by `toggleFullscreen`. So apps
keep rounded corners and full chrome. niri's two window modes set XDG state for
exactly this reason.

**G3 — The #69 interaction bug** (focus/toggle). See next section.

These are separable: G1 is product/semantics, G2 is an AX-integration task, G3
is a focus/selection bug. Phase A decides G1; G2 and G3 follow.

---

## #69 bugs, re-read through the expectations lens

Reproduces on the **tiling** path (the reporter's rebound `Opt+Shift+F` =
`toggleFullscreen`). Topology: 3+ columns; fullscreen the middle one; focus a
neighbour.

- **Symptom — "focus to neighbour doesn't restore."** `focusColumnByIndex`
  (`NiriNavigation.swift:382-411`) only updates `activatePrevColumnOnRemoval`
  and calls `ensureSelectionVisible`; it **never writes `sizingMode`**. So the
  fullscreen window stays fullscreen. **By niri semantics this is correct**
  (fullscreen is sticky; you scroll to see neighbours). The mismatch is
  *expectation*: the reporter wants restore. → **Product decision, not a bug.**
- **Symptom — "toggle sometimes won't un-fullscreen."** `toggleFullscreen` reads
  `window.sizingMode` of the node it is handed. Once selection moves to a
  neighbour, the resolved target is the *current* node, not the fullscreened one,
  so the press toggles the wrong window or no-ops. This is the real defect. (See
  #69 hypothesis 2.) Compounded by occlusion: a fullscreen window covers its
  column siblings and wins hit-testing
  (`focusHitTestPrefersFullscreenWindowOverCoveredTile`,
  `NiriLayoutEngineTests.swift:4557`), so the user cannot easily get back to it.
- **Symptom — "focus switching breaks" (native path).** Owned by #69's trace.
  Self-contained recap of the inlined evidence: entering native fullscreen for
  window `A = WindowToken(pid: 12328, windowId: 374)` misattributes the focus
  lease to `window_close_focus_recovery` with no window closing, admits `A`
  seven times in ~1 s (`window_admitted … mode=tiling phase=tiled`), and on exit
  produces a multi-second A↔B↔C `managed_focus_requested`/`managed_focus_confirmed`
  storm with floods of `managed_replacement_metadata_changed`. These are not
  addressed by #244's suspension guard (disjoint failure mode). Out of scope for
  the *tiling* expectations work; tracked separately under #69.

The crux: **the correct G3 fix cannot be chosen until G1 is decided.** If Nehir
keeps fullscreen sticky (niri model), the fix is "make the toggle reliably
target the fullscreen node" + add a trace emit. If Nehir adopts auto-restore
(reporter model), the fix is "restore on focus move." Pick the model first.

---

## Risks and unknowns

- **Backward compatibility.** The reporter (and presumably others) rebound
  `Opt+Shift+F` from `toggleColumnFullWidth` to `toggleFullscreen`. Any rename or
  re-default of these actions must carry a settings migration (precedent:
  `completed/20260616-unified-config-diagnostics-and-migration-policy.md`).
  Renaming `toggleFullscreen`'s *behavior* would silently change what an existing
  binding does.
- **`.maximized` removal vs revival.** If Phase A picks a target model that needs
  a true screen-covering mode, reviving `.maximized` (and wiring it to an action)
  is cheap and removes dead code as a side effect. If the model does not need it,
  deleting `.maximized`, its render/geometry branches, and the defensive clears
  is the cleaner move. Either is low-risk; leaving it half-implemented is the
  worst option.
- **Workspace-bar interaction.** `workingFrame` already insets the reserved
  workspace-bar top area (`WMController.insetWorkingFrame`, see #69). A true
  fullscreen that covers the bar would have to bypass that inset — touch surface
  shared with `completed/…workspace-bar-over-autohidden-menu-bar` work.
- **Window-awareness cost (G2).** Driving `AXFullScreen` from the tiling path
  risks the app entering *native* macOS fullscreen (own Space) unintentionally —
  the attribute is overloaded. Needs an AX-spike to confirm whether a
  layout-only "maximized" signal is even expressible on macOS without going
  native. May not be worth it; niri's square-corners payoff is small on macOS
  where most apps already adapt to window size.
- **Native path is a separate workstream.** The lease/admission/focus-storm
  symptoms are real but orthogonal to "define expectations." Do not bundle.

---

## Open questions

1. **Target model.** Adopt niri's full 4-action set (column-max / maximize-to-
   edges / fullscreen / windowed-fullscreen), or keep Nehir's 3 and just fix the
   label? Minimum viable = decide what `toggleFullscreen` *should* do.
2. **Sticky vs auto-restore.** For the tiling window mode, follow niri (sticky;
   scroll to see neighbours) or the reporter (restore on focus)? niri-loyal is
   less code and more predictable.
3. **`.maximized` fate.** Revive (host a new mode) or delete (remove dead
   branches)? Gated on #1.
4. **G2 worth doing at all?** Is window-awareness on the tiling path worth the AX
   risk, given `toggleNativeFullscreen` already exists for real fullscreen?
5. **Scroll-vs-focus.** Nehir's viewport already supports scrolling past a
   fullscreen window (the layout participant rule). Is the #69 frustration purely
   the toggle-no-op + occlusion, i.e. fixable without changing stickiness?

---

## Recommendation

**Pursue. Phase A (define) before Phase B (fix).** Both are small.

**Phase A — define the model (product decision, ~0 code):**
- Decide #1/#2: recommend the **niri-loyal minimum** — keep `toggleFullscreen`
  *sticky* (matches upstream; no auto-restore), and **rename the *rect*** so the
  label matches behavior. Concretely: either (a) keep the working-frame rect and
  document/relabel it as "Maximize" (niri `maximize-to-edges`-ish), or (b) make
  it true screen-covering (revive `.maximized`→full view frame, hide gaps/bar)
  and keep the "Fullscreen" name. Option (a) is the smaller change and matches
  the *existing* test (`monitor.visibleFrame`).
- Decide #3: recommend **reviving `.maximized`** only if option (b) is chosen;
  otherwise **delete it** (and `effectiveSizingMode`'s dead branch, the render
  `case .maximized` fallthrough, and the two defensive clears). Removing dead
  code is a net win and is independently correct regardless of #69.

**Phase B — fix #69 against the chosen model (small, tiling path only):**
- **Make the toggle reliable.** When `toggleFullscreen` fires and the focused
  node is not the workspace's fullscreen node, resolve to the fullscreen node
  (or no-op cleanly) rather than toggling the wrong window. Site:
  `NiriLayoutEngine+Sizing.swift:407` + the handler at
  `NiriLayoutHandler.swift` toggle entry (see #69 for the `:1288-1291` guard).
- **Add a trace emit to the tiling toggle.** Today it is silent (no event),
  which is why #69's trace could not speak to this path. A `sizingMode`
  transition event makes future repros observable.
- **Occlusion UX.** If sticky is kept, ensure focusing a neighbour visibly
  scrolls it into view (it should, via `ensureSelectionVisible`) so the user is
  not stranded behind the fullscreen window. Verify; this may already work.
- **Defer G2 (window-awareness)** unless a follow-up specifically wants it.
- **Defer the native-path storm** to #69's native workstream; do not bundle.

**Sequencing rationale.** Phase A is a decision + (optionally) dead-code
removal; Phase B is a ~2-site fix + a trace event. Neither blocks on the other
mechanically, but the *correct* Phase-B toggle behavior depends on the Phase-A
stickiness decision, so decide A first.

---

## Implementation map (files / types / symbols)

Phase A:
- `Sources/Nehir/Core/Layout/Niri/NiriNode.swift:16` — `SizingMode` enum (delete
  `.maximized` or wire it).
- `Sources/Nehir/Core/Layout/Niri/NiriLayout.swift:162,179` — `workingFrame` →
  `canonicalFullscreenRect` (the rect decision).
- `Sources/Nehir/Core/Layout/Niri/NiriLayout.swift:1026,1069` and
  `ViewportState+Geometry.swift:284-286,298-321` — `.maximized` render/geometry
  branches (remove if deleting).
- `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+Sizing.swift:901,963` —
  defensive `.maximized` clears (remove if deleting).
- `Sources/Nehir/Core/Input/ActionCatalog.swift:470-475` — `toggleFullscreen`
  spec/label/default.

Phase B:
- `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+Sizing.swift:407-413` —
  `toggleFullscreen` (target resolution).
- `Sources/Nehir/Core/Layout/Niri/NiriNavigation.swift:382-411` —
  `focusColumnByIndex` (verify `ensureSelectionVisible` reveals neighbours).
- `Sources/Nehir/Core/Controller/NiriLayoutHandler.swift` — toggle entry / guard
  (see #69 `:1288-1291` region; re-verify line).
- New trace event site near `WMEvent.swift` (tiling `sizingMode` transition;
  native already emits `.nativeFullscreenTransition`).

Tests to add/update:
- `Tests/NehirTests/NiriLayoutEngineTests.swift:4538` (`expectedFullscreenFrame`)
  and `:4557` (`focusHitTestPrefersFullscreenWindowOverCoveredTile`) — update if
  the rect model changes; add a "toggle targets the fullscreen node after focus
  moves" case.
- `Tests/NehirTests/ViewportGeometryTests.swift:37,65,83` — `.fullscreen` mode
  fixtures; add `.maximized` coverage only if reviving.

---

## Reproduction / verification (self-contained)

Tiling path (the one this idea owns). Needs no captured log:

1. Three columns in one workspace. Note the middle column's window token.
2. Focus the middle column, press `toggleFullscreen` (default `Opt+Return`;
   reporter's rebound `Opt+Shift+F`). Observe it fills the working area — outer
   gaps and the menu/workspace bar remain visible (rect = `workingFrame`, not the
   screen). The app keeps rounded corners / full chrome (not window-aware).
3. Press focus-left / focus-right to a neighbour. Observe: the fullscreen window
   stays fullscreen (`focusColumnByIndex` does not write `sizingMode`); the
   neighbour is revealed only if the viewport scrolls it into view.
4. Press `toggleFullscreen` again. Observe the reported defect: because selection
   is now on the neighbour, the press no-ops or toggles the wrong window (root
   cause: `toggleFullscreen` reads the *focused* node's `sizingMode`).
5. Expected after Phase B: step 4 reliably un-fullscreens the workspace's
   fullscreen node; step 2's rect/label match the Phase-A decision.

Sanity check for dead code: grep the repo for any `sizingMode = .maximized` write
— there is none at HEAD `e7b246b6`, confirming `.maximized` is unreachable.
