# Nehir issue #69 — "Fullscreen window will not restore when switching focus to neighbours; toggle-fullscreen hotkey intermittently stops working" — Discovery

Groom 2026-07-07: in flight — context-collection doc (no fix proposed); native-fullscreen column drift was fixed (56095965) and fullscreen follow-up plans exist (planned/20260622-fullscreen-behaviour-roadmap.md, planned/20260621-niri-fullscreen-expectations-and-fix.md); tiling-fullscreen restore-on-focus semantics still undecided (verified against main 7a025b78).

Source issue: https://github.com/Guria/nehir/issues/69 — OPEN, label `bug`
Reporter: `Alan-TheGentleman` (Alan Buscaglia). Confirmation + runtime trace from
`dagrlx`. Owner (`Guria`) acknowledged and will investigate.

Attached runtime trace (native-fullscreen path) — dagrlx's comment:
<https://github.com/user-attachments/files/29057633/runtime-trace-1781709157354-1781712380496.log>
(captured 2026-06-17T15:12:37Z→16:06:20Z, ~54 min). All relevant events from it are
inlined verbatim in "Trace evidence" below, so the doc is self-contained; the URL is
here for the full raw capture if needed.
Nehir version: 0.5.0 (Homebrew cask). macOS 26 Tahoe (Darwin 25.2.0), Apple Silicon.

This is the **consolidated** discovery for Nehir's three "make it big" actions and
issue #69. It merges the #69 investigation with the pre-existing fullscreen-adjacent
discoveries already on this branch — see "Related discoveries on this branch" for the
reconciliation. Line references were verified against main-repo HEAD `7b731a51`.
**Re-verify before implementing; line numbers drift.** (Note: the sibling discoveries
`20260617-omniwm-244-*` and `20260617-omniwm-326-*` were last verified at older SHAs
`904df02`/`b7ac7e5`; their *findings* still hold but their cited line numbers are stale.
Current numbers are used everywhere below; see "Sibling-doc line drift" at the end.)

> Scope: collect context for investigation. **Does not propose a fix.** Two related but
> distinct code paths are in play; the single most important thing an investigator must
> know is which one the report vs. the trace actually exercises (they differ).

---

## TL;DR

- **Nehir has THREE distinct "make it big" mechanisms, and the report's binding
  exercises the one that is least robust under focus changes.**
  1. `toggleFullscreen` (`Opt+Return` default; reporter rebound to `Opt+Shift+F`) —
     layout-level **window** fullscreen, flips `NiriWindow.sizingMode` to `.fullscreen`.
     Property of a single window node, read back via `state.selectedNodeId`.
  2. `toggleColumnFullWidth` (`Opt+Shift+F` default; reporter unassigned it) —
     layout-level **column** maximize, flips `NiriContainer.isFullWidth` to width =
     `proportion(1.0)`. Property of the column; survives focus changes.
  3. `toggleNativeFullscreen` (`Opt+Shift+Cmd+Return`) — macOS-native AX fullscreen
     (green-button, own Space). Tracked via `nativeFullscreenRecord` + suspension.
- **The report and the attached trace describe two *different* mechanisms.** Alan's
  report (steps + expected) is about **#1, tiling window fullscreen**. dagrlx's trace
  captures **#3, native macOS fullscreen** (every fullscreen event in it is
  `native_fullscreen`; there is no `sizingMode` transition recorded). Both share the
  reported *symptom* (focus doesn't cleanly restore; focus cycling breaks; the toggle
  sometimes won't un-fullscreen) but the suspect code lives in different places.
- **Tiling-window-fullscreen path (by inspection — lead).** Focusing a neighbouring
  column goes through `NiriNavigation.focusColumn` → `focusColumnByIndex`, which only
  changes `ViewportState.selectedNodeId`. It does **not** write `sizingMode`. The only
  `sizingMode = .normal` writes are in sizing ops (`NiriLayoutEngine+Sizing.swift:408,
  901, 963`). Nothing on the focus path restores a `.fullscreen` window — consistent
  with symptom 1 ("moving focus to a neighbouring column does not restore the fullscreen
  window"). Strong lead, **not yet confirmed** end-to-end.
- **Native-fullscreen path (from the trace).** Entry for window
  `WindowToken(pid: 12328, windowId: 374)` shows (a) a focus lease reattributed to
  `window_close_focus_recovery` with no window closing, (b) seven repeated
  `window_admitted` events for the same token within ~1 s (admission churn), and (c)
  after exit, a long burst of paired `managed_focus_requested`/`managed_focus_confirmed`
  cycling three windows with floods of `managed_replacement_metadata_changed` — the
  visible "focus cycling breaks" symptom.
- **Why the binding choice matters for #69.** By default `Opt+Shift+F` is
  `toggleColumnFullWidth` (a *column* property, robust under focus). The reporter
  rebound it to `toggleFullscreen` (a *window-node* property tied to `selectedNodeId`).
  This is exactly the selection-dependent path the inspection lead flags as fragile.
- **Workaround reported:** toggle the window floating and back (`toggleFocusedFloating`,
  `Ctrl+Opt+F`) restores normal behaviour.

---

## Bindings in play

### Defaults (from `ActionCatalog.buildSpecs()`, main-repo HEAD `7b731a51`)

| Action | Default hotkey | Source |
|---|---|---|
| `toggleFullscreen` | **`Opt+Return`** | `ActionCatalog.swift:466` |
| `toggleNativeFullscreen` | `Opt+Shift+Cmd+Return` | `ActionCatalog.swift:472` |
| `toggleColumnFullWidth` | **`Opt+Shift+F`** | `ActionCatalog.swift:598` |
| `expandColumnToAvailableWidth` | `Opt+Ctrl+F` | (nearby) |

### Reporter's rebind (from the issue's `hotkeys.toml`)

```toml
[layout]
toggleFullscreen        = "Option+Shift+F"               # ← rebound (default Opt+Return)
toggleNativeFullscreen  = "Option+Shift+Command+Return"  # default
toggleColumnFullWidth   = "Unassigned"                   # ← removed (default Opt+Shift+F)
toggleFocusedFloating   = "Control+Option+F"             # reported workaround
```

⚠️ The reporter's `Opt+Shift+F` is **not** the default for `toggleFullscreen`. They
swapped `toggleColumnFullWidth` ↔ `toggleFullscreen`. This is central to why the bug
manifests: they moved onto the window-node-state path.

### Relevant reporter config (`settings.toml`)

- `focus.followsMouse = false`, `focus.moveMouseToFocusedWindow = true`,
  `focus.followsWindowToMonitor = false`.
- `niri.balancedColumnCount = 2`, `columnWidthPresets = [0.35, 0.5, 0.65, 0.95]`,
  `revealPartial = "default"`, `infiniteLoop = false`.
- Three monitors: `main` (workspaces 1–5) + specific-display workspaces 6 (`Elgato`,
  `monitorDisplayId = 6`) and 7 (`ARZOPA`, `monitorDisplayId = 5`).
- `ipcEnabled = true`. Trace capture hotkey: `Control+Option+Command+T`.

---

## Fullscreen mechanisms in Nehir — consolidated semantics

### 1. `toggleFullscreen` — layout-level WINDOW fullscreen

- Dispatch: `CommandHandler.swift:95` (`case .toggleFullscreen`) →
  `CommandHandler.swift:487` (`toggleFullscreen()`) →
  `NiriLayoutHandler.swift:1284` (`toggleFullscreen()`).
- Engine toggle: `NiriLayoutEngine+Sizing.swift:411` —
  `let newMode = window.sizingMode == .fullscreen ? .normal : .fullscreen`, then
  `setWindowSizingMode(…)` at `NiriLayoutEngine+Sizing.swift:379`.
- `setWindowSizingMode` (`+Sizing.swift:379-408`) saves/restores `window.savedHeight`
  and a viewport offset (`saveViewOffsetForFullscreen` / `animateViewOffsetRestore`),
  then writes `window.sizingMode = mode` (`+Sizing.swift:408`).
- Rendered rect: `.fullscreen` maps to `fullscreenRect`, and
  `canonicalFullscreenRect = workingFrame` (`NiriLayout.swift:173`), applied at
  `NiriLayout.swift:1009-1011` (`case .fullscreen: frame = fullscreenRect…`).
  **`workingFrame` is the gap- and strut-inset area** (`WMController.insetWorkingFrame`
  at `WMController.swift:751` insets by outer gaps + workspace-bar reserved top inset).
  → Nehir's tiling fullscreen **keeps outer gaps and respects the workspace bar**.
- State lives on the **window node**: `NiriNode.swift:686`
  (`var sizingMode: SizingMode = .normal`), `:745` (`var isFullscreen`).
- **No dedicated trace event** — it is just a layout refresh. This is why the attached
  trace cannot speak to this path directly.

### 2. `toggleColumnFullWidth` — layout-level COLUMN maximize (full-width column)

- Dispatch: `NiriLayoutHandler.toggleColumnFullWidth()` at
  `NiriLayoutHandler.swift:1361` → `engine.toggleFullWidth(…)`.
- Engine: `NiriLayoutEngine+Sizing.swift:640-680` — flips `column.isFullWidth`,
  saves/restores `column.savedWidth`, sets width to `proportion(1.0)` (the resolve call
  at `+Sizing.swift:667`; the spec selection `column.isFullWidth ? proportion(1) :
  column.width` at `+Sizing.swift:66,494,567`).
- **Full-width means exactly 100%** — confirmed by `20260617-omniwm-326-*`: column
  widths are hard-capped at `min(1.0, …)` in `SettingsStore.validatedPresets`
  (`SettingsStore.swift:964`) and `validatedDefaultColumnWidth` (`:972`), and
  `isFullWidth` resolves to `proportion(1)`.
- Property of the **column** (`NiriContainer.isFullWidth`), preserved across windows in
  it and across column moves (see `20260616-omniwm-295-*` on width-state preservation);
  gaps and borders kept; can hold multiple windows.

### 3. `toggleNativeFullscreen` — macOS-native AX fullscreen

- Dispatch: `CommandHandler.toggleNativeFullscreenForFocused()` at
  `CommandHandler.swift:495-541`. Calls `AXWindowService.setNativeFullscreen(axRef,
  true/false)`; on failed exit calls `markNativeFullscreenSuspended(token)`.
- **Does not touch the Niri layout engine.** The app moves onto its own macOS Space.
- Tracked via `WorkspaceManager.nativeFullscreenRecord(for:)` (`WorkspaceManager.swift:
  1284`, backed by `nativeFullscreenRecordsByOriginalToken` at `:203`) +
  `WMController.nativeFullscreenPlaceholderManager` (`WMController.swift:120`).
- Trace event: `.nativeFullscreenTransition` renders as
  `native_fullscreen token=… workspace=… active=…` (`WMEvent.swift:180-181`).

---

## Nehir ↔ niri mapping

niri (the Wayland compositor Nehir's layout engine is modelled on) defines **three**
"make it big" modes ([niri wiki: Fullscreen and Maximize](https://github.com/niri-wm/niri/blob/main/docs/wiki/Fullscreen-and-Maximize.md)):

| niri action | Default | Protocol state | Covers | Gaps/borders | Struts (bars) | Window-aware? |
|---|---|---|---|---|---|---|
| `maximize-column` | `Mod+F` | none (layout) | **width only** | kept | respected | no |
| `maximize-window-to-edges` | (PR #2376) | `XDG_MAXIMIZED` | working area | hidden | respected | yes |
| `fullscreen-window` | `Mod+Shift+F` | `XDG_FULLSCREEN` | **entire** screen | hidden | **covered** | yes |

| Nehir action | Closest niri action | Faithfulness |
|---|---|---|
| `toggleColumnFullWidth` (`Opt+Shift+F`) | `maximize-column` (`Mod+F`) | ✅ **Faithful** — column property, width = `proportion(1.0)`, gaps/borders kept, multi-window. |
| `toggleFullscreen` (`Opt+Return`) | `fullscreen-window` (`Mod+Shift+F`) | ⚠️ **Partial.** Window mode like niri's, but the rect is `workingFrame` (gap- + strut-inset), so it **keeps outer gaps + respects the workspace bar** — niri's `fullscreen-window` covers the entire screen including bars. Behaves closer to a full-width-**and**-full-height `maximize-column` than to true niri fullscreen. Reinforced by `20260617-omniwm-373-*` (smart gaps absent): a lone window already fills the gap-inset working frame, not the screen edge-to-edge. |
| `toggleNativeFullscreen` (`Opt+Shift+Cmd+Return`) | **no niri analog** | n/a — macOS-native (own Space via AX). niri is a Wayland compositor with no equivalent. |

### Hidden 4th mode (plumbing only)

Nehir's layout engine already has a `.maximized` `SizingMode` (`NiriNode.swift:13`,
rendered identically to `.fullscreen` at `NiriLayout.swift:1009-1011`) — the natural
analog of niri's `maximize-window-to-edges` (true Wayland maximize). But **no toggle
action exposes it**: `toggleFullscreen` only flips `.normal ↔ .fullscreen`
(`+Sizing.swift:416`). So niri's three-way distinction is only partially surfaced in
Nehir's actions. Also note `singleWindowLayoutContext` gates on
`window.sizingMode == .normal` (`NiriLayoutEngine.swift:273`), so a fullscreen/maximized
window is excluded from the lone-window policy path.

---

## Trace evidence — native-fullscreen transition (inlined, self-contained)

Topology at capture: interaction monitor = `ID(displayId: 2)`, previous =
`ID(displayId: 1)` (constant below). Event workspace:
`15AC49E8-9E94-4555-BBA6-E6BF3943D649` (display 2). Three windows: `A =
WindowToken(pid: 12328, windowId: 374)`, `B = WindowToken(pid: 17675, windowId: 728)`,
`C = WindowToken(pid: 17675, windowId: 733)`. All timestamps `2026-06-17`.

Entry into native fullscreen (window **A**):

- `#326 16:05:22` `managed_focus_confirmed token=A … fullscreen=false`
- `#327 16:05:23` `focus_lease_changed owner=window_close_focus_recovery reason=window_close_focus_recovery` ← **no window closed here**; lease misattributed to close-recovery
- `#328 16:05:23` (same, duplicate)
- `#329 16:05:23` **`native_fullscreen token=A … active=true`** `plan=phase=nativeFullscreen`
- `#330 16:05:23` `non_managed_focus_changed active=false fullscreen=false preserve=true`
- `#331 16:05:23` `managed_focus_cancelled token=A`
- `#332 16:05:23` `window_admitted token=A mode=tiling phase=tiled`
- `#333 16:05:23` `active_space_changed … restore_refresh=active_space` (interaction Optional(displayId: 2)->Optional(displayId: 1))
- `#337 16:05:23` `non_managed_focus_changed active=true fullscreen=true … non_managed=true,app_fullscreen=true` ← A treated as non-managed app-fullscreen surface
- `#338–#344 16:05:23–24` **seven repeated** `window_admitted token=A mode=tiling phase=tiled` for the same token in ~1 s ← admission churn

Exit from native fullscreen (window **A**, ~14 s later):

- `#345 16:05:36` `non_managed_focus_changed active=false fullscreen=false`
- `#346 16:05:36` `managed_focus_cancelled token=A`
- `#349 16:05:37` `active_space_changed … restore_refresh=active_space`
- `#353 16:05:37` **`native_fullscreen token=A … active=false`** `plan=phase=tiled`
- `#357 16:05:37` `managed_focus_requested token=A … pending=A`
- `#359 16:05:37` `managed_focus_confirmed token=A … fullscreen=false`
- `#361 16:05:37` `focus_lease_changed owner=window_close_focus_recovery …` (still the close-recovery lease)

Post-exit focus storm (the "focus cycling breaks" symptom). Focus bounces A↔B↔C with
paired `managed_focus_requested`/`managed_focus_confirmed` and floods of
`managed_replacement_metadata_changed`:

- `#374 16:05:46` B admitted; `#376` confirmed
- `#385–#393 16:05:50` C admitted → `managed_focus_confirmed token=C`; `hidden_state_changed token=C hidden=true phase=offscreen`, then `token=A hidden=true phase=offscreen` (A pushed offscreen), then C un-hidden
- `#398–#400 16:05:59` `managed_focus_requested token=A … pending=A` (twice) → `confirmed token=A`; A un-hidden, C hidden
- `#403–#408 16:06:00` requested/confirmed for B, then C; C un-hidden; A hidden
- `#410–#421` ~12× `managed_replacement_metadata_changed token=C` in the same second
- `#422–#464 16:06:01–04` the A↔B↔C request/confirm cycle repeats several more times, each with another burst of `managed_replacement_metadata_changed token=C` (tens of events) and `hidden_state_changed` toggles (`phase=tiled` ↔ `phase=offscreen`)
- Pattern continues to end of capture.

Start-of-capture runtime state (for repro context):

- `enabled=true desiredEnabled=true hotkeysEnabled=true … overviewOpen=false`
- `focusFollowsMouse=false moveMouseToFocusedWindow=false mouseWarpPolicyEnabled=true`
- `runtimeTraceCaptureActive=true`
- `interactionWorkspace=7AC92130-…` (a different workspace than the event workspace
  `15AC49E8-…` — interaction workspace ≠ the workspace where fullscreen happens)
- `wmCommandTarget=WindowToken(pid: 15745, windowId: 467) wmCommandTargetSource=frontmostManagedFallback`
- `interactionMonitor=ID(displayId: 2)`

What the trace does **not** contain: any `native_fullscreen active=true` that fails to
later go `active=false` (A does exit at #353). The "toggle sometimes won't
un-fullscreen" half of the report is **not** demonstrated by this trace; on the native
path that symptom would correspond to a `native_fullscreen active=true` with no matching
`active=false`, or a `markNativeFullscreenSuspended` branch (`CommandHandler.swift:510,
540`) where `setFullscreen(…, false)` returns false.

---

## Related discoveries on this branch (reconciliation)

These pre-existing discoveries own adjacent surfaces. They are referenced, not
duplicated. Current line numbers shown.

- **`noop/20260617-omniwm-244-native-fullscreen-counted-and-leak.md`** — owns the
  native-fullscreen **suspension + transition-guard** design. Confirms: a window
  entering native fullscreen is marked `.suspended` and excluded from the tiling diff
  (`if window.isNativeFullscreenSuspended { … continue }` at `NiriLayoutHandler.swift:
  924`, suspended-token set at `:919`), and `hasPendingNativeFullscreenTransition`
  (`WorkspaceManager.swift:1104`) gates relayout/FFM/border refresh during the
  transition. Verdict there: 🟢 the *counting* and *content-leak* symptoms are already
  fixed. **#69's native-path symptoms are a different failure mode** (focus-lease
  misattribution + admission churn + post-exit focus storm) that those guards do not
  address — so #69 is not contradicted by #244's "fixed" verdict; they cover disjoint
  symptoms of the same subsystem. The trace evidence above is the delta.
- **`discovery/20260617-omniwm-326-niri-column-over-100-percent-width.md`** — owns the
  **column-width cap**. Confirms `toggleColumnFullWidth` = exactly 100%:
  `validatedPresets`/`validatedDefaultColumnWidth` clamp to `min(1.0, …)`
  (`SettingsStore.swift:964,972`); `isFullWidth` → `proportion(1)`. This is the source
  of truth for mechanism #2's semantics above.
- **`discovery/20260617-omniwm-373-smart-gaps-single-window.md`** — owns **smart gaps**
  (absent). Confirms a lone window fills the gap-inset working frame, not the screen
  edge-to-edge (`singleWindowLayoutContext` at `NiriLayoutEngine.swift:258`, which gates
  on `sizingMode == .normal` at `:273`). Reinforces that Nehir's `toggleFullscreen`
  keeps outer gaps — diverging from niri's `fullscreen-window`.
- **`discovery/20260616-omniwm-295-niri-window-width-preservation.md`** — owns
  **width-state preservation on cross-workspace move**. Confirms `isFullWidth` is a
  column property that is carried with the column on moves (`targetColumn.isFullWidth =
  sourceColumn.isFullWidth`), unlike the window-node `sizingMode` — supporting the
  "column property is robust under focus/move, window-node property is not" contrast at
  the heart of #69.

## Hypotheses / open questions (to confirm before fixing)

1. **Tiling path — missing restore on focus (lead).** Is Nehir intended to restore a
   `sizingMode == .fullscreen` window when selection moves to a neighbour? If yes, the
   restore must be added on the focus path (around `NiriNavigation.focusColumnByIndex`)
   or in the layout refresh that follows; nothing does it today. If no, the report's
   "Expected" needs re-scoping. **Decide the intended semantics first.** (niri itself
   does *not* auto-unfullscreen on focus move — `fullscreen-window` is sticky — so this
   is a product decision, not a port.)
2. **Tiling path — "won't un-fullscreen" intermittently.** `toggleFullscreen` reads
   `window.sizingMode` to decide the next mode (`+Sizing.swift:411-416`). If the focused
   node is not the fullscreen node (selection moved to a neighbour), the guard at
   `NiriLayoutHandler.swift:1288-1291` resolves the *current* node, which may not be the
   fullscreened one — so the press becomes a no-op or toggles the wrong window.
3. **Native path — close-recovery lease misattribution.** The
   `focus_lease_changed owner=window_close_focus_recovery` events (#327-328, #361) fire
   with no window close. Investigate whether the lease owner is set from stale state and
   whether it blocks/redirects focus confirmation post-fullscreen.
4. **Native path — admission churn.** Seven `window_admitted` for one token in ~1 s
   (#338-344) during the transition. Check the restore-on-admission helpers in
   `AXEventHandler.swift` and the `.nativeFullscreen` short-circuits in
   `LayoutRefreshController.swift`. Note: #244's suspension design should normally
   prevent re-admission — so this churn may indicate the suspension is being entered and
   exited repeatedly.
5. **Native path — `managed_replacement_metadata_changed` flood.** Tens of these per
   second for token C during the focus storm. Determine whether pure noise or driving
   re-layouts that keep disturbing focus.
6. **Interaction workspace ≠ event workspace.** Start state shows
   `interactionWorkspace=7AC92130-…` while events are on `15AC49E8-…`. Confirm benign
   (multi-monitor) vs a source of misrouted commands.

## Reproduction notes (from the report)

1. Open 3+ columns in a workspace.
2. Fullscreen the **middle** column with `toggleFullscreen` (`Opt+Shift+F`).
3. Focus a neighbouring column (focus left/right).
4. Observe: the fullscreen window does not return to a tiled window; focus switching
   between windows breaks.
5. Sometimes pressing `toggleFullscreen` again no longer un-fullscreens the window.

## Suggested first investigation moves

- Decide tiling-fullscreen-on-focus semantics (hypothesis 1). Gates everything on the
  reported (`Opt+Shift+F`) path. Reference: niri keeps `fullscreen-window` sticky.
- Add a trace/emit point to the **tiling** fullscreen toggle (currently silent) so a
  future repro can show `sizingMode` transitions alongside focus — without it the
  reported path is effectively unobservable in traces.
- For the native path, instrument the close-recovery lease attribution (hypothesis 3)
  and the repeated-admission path (hypothesis 4); both are visible in the inlined
  events and map to concrete source sites.

## Sibling-doc line drift (for future maintainers)

Re-verified at main HEAD `7b731a51`. The findings hold; the cited line numbers below
are stale in the sibling docs and should be updated when those docs are next touched:

- `20260617-omniwm-244-*` cited `WorkspaceManager.swift:1339/2973/1102`,
  `AXEventHandler.swift:2127/2148`, `NiriLayoutHandler.swift:884/891`. **Current:**
  `WorkspaceManager.swift:1341/2975/1104`, `AXEventHandler.swift:2390/2408`,
  `NiriLayoutHandler.swift:919/924`.
- `20260617-omniwm-326-*` cited `SettingsStore.swift:852/862`. **Current:** `:964/972`.
  (`+Sizing.swift:66/494` unchanged.)
- `20260617-omniwm-373-*` cited `NiriLayoutEngine.swift:258`. **Current: unchanged.**
