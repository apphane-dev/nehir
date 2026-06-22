# Roadmap for Nehir fullscreen / maximize behaviours

**Status:** planned
**Related plans:** `planned/20260621-niri-fullscreen-expectations-and-fix.md`,
`planned/20260622-native-fullscreen-toggle-exit-target.md`
**Related discovery:** `discovery/20260617-nehir-69-fullscreen-restore-on-focus.md`,
`discovery/20260621-niri-fullscreen-expectations-and-fix.md`

This is the coordination roadmap for the different "make it big" behaviours in
Nehir. It answers how many workstreams are needed, which traces are still needed,
and the recommended order.

## Executive answer

Implementation needs **two active fix plans**:

1. **Tiling/layout fullscreen → sticky maximize fix**
   (`planned/20260621-niri-fullscreen-expectations-and-fix.md`). This handles the
   #69 `toggleFullscreen` path, adopts the user-confirmed niri-style sticky model,
   relabels the action toward "Maximize", removes dead `.maximized` code, and
   makes the toggle unmaximize the existing fullscreen node after focus moves.
2. **Native macOS fullscreen → exit-target fix**
   (`planned/20260622-native-fullscreen-toggle-exit-target.md`). This handles the
   green-button / own-Space path where toggling while already in native fullscreen
   can enter native fullscreen on another managed window instead of exiting the
   current native-fullscreen record.

No separate fix plan is needed for **column full-width** right now. It is the
control/healthy behaviour: a column property, not a window fullscreen state. Keep
it covered by regression tests and do not mix it with #69.

A future optional third project can add **true niri fullscreen** (whole screen,
bar covered, black backdrop / app-aware state) if product wants it later. It is
not required to fix #69.

## User follow-up decision

The #69 follow-up resolved the tiling semantics question:

- Alan selected option 2: **stay fullscreen/maximized and navigate around it**.
- dagrlx also selected option 2: **niri style**.

Therefore the implementation should **not** auto-restore on focus change. The bug
is not that focus moves away; the bug is that sticky navigation/toggle behaviour
is unreliable once focus has moved away from the maximized node.

## Behaviour map

| Behaviour | Action | State owner | Intended fix status | Plan |
|---|---|---|---|---|
| Column full-width | `toggleColumnFullWidth` | Column (`isFullWidth`) | No fix needed; keep as control | none |
| Tiling window maximize | `toggleFullscreen` | Window node (`sizingMode == .fullscreen`) | Fix sticky toggle target + trace; relabel toward maximize | `planned/20260621-niri-fullscreen-expectations-and-fix.md` |
| Native macOS fullscreen | `toggleNativeFullscreen` | macOS AX fullscreen + `nativeFullscreenRecord` | Fix command target so active native fullscreen exits first | `planned/20260622-native-fullscreen-toggle-exit-target.md` |
| True niri fullscreen | not currently exposed | future layout/window-aware mode | Optional future product work | future plan only if requested |

## Trace needs

### Before implementation

No additional traces are blocking.

- **Tiling/layout path:** current traces are not enough by design because the
  tiling `sizingMode` transition is not emitted. The plan should add a new sizing
  trace event, then validate with tests and one post-fix/manual trace if desired.
- **Native path:** the new repro evidence is sufficient and is inlined in
  `planned/20260622-native-fullscreen-toggle-exit-target.md`. It already shows
  multiple native enters and final `nativeFullscreen records=3` after a sequence
  that should have exited the current fullscreen window.
- **Column full-width:** the control trace confirms expected `toggleFullWidth`
  command records; no further trace needed.

### Optional post-fix acceptance traces

Two small traces are useful after implementation, but not required to start work:

1. **Tiling sticky maximize:** maximize middle column/window, focus neighbour,
   press toggle again. Expected evidence: one `sizingModeChanged` enter, one
   matching exit, final selected neighbour normal and maximized node restored to
   normal.
2. **Native enter/exit:** enter native fullscreen, press native fullscreen toggle
   again without changing focus. Expected evidence: one `native_fullscreen
   active=true`, one matching `active=false`, final `nativeFullscreen records=0`.

Any evidence copied into durable docs or issue comments must inline the concrete
state/events. Do not cite local trace filenames.

## Roadmap / sequencing

### Phase 0 — documentation alignment (this branch)

- Record the user decision: niri-style sticky behaviour for tiling fullscreen.
- Split the native-fullscreen workstream from the tiling maximize workstream.
- Make clear that column full-width is not broken and is not in scope.
- Record trace needs: zero blocking traces, two optional post-fix acceptance
  traces.

### Phase 1 — tiling/layout sticky maximize fix

Implement `planned/20260621-niri-fullscreen-expectations-and-fix.md` first:

1. Delete dead `.maximized` mode branches if still present.
2. Relabel user-facing `toggleFullscreen` copy toward "Toggle Maximize" while
   keeping IDs, TOML keys, IPC symbols, and defaults stable.
3. Fix `NiriLayoutHandler.toggleFullscreen()` target resolution so a toggle on a
   neighbour unmaximizes the existing workspace fullscreen node.
4. Add a tiling sizing trace event.
5. Add focused tests for "maximize middle → focus neighbour → toggle restores
   middle".

Why first: it directly addresses the reporter's layout path and is mostly pure
layout/controller logic.

### Phase 2 — native fullscreen exit-target fix

Implement `planned/20260622-native-fullscreen-toggle-exit-target.md` second:

1. In `CommandHandler.toggleNativeFullscreenForFocused()`, resolve native exit
   targets before managed enter targets whenever app fullscreen is active or a
   native transition is pending.
2. Broaden `WorkspaceManager.nativeFullscreenCommandTarget(frontmostToken:)` so
   the active native fullscreen record can be selected for exit, not only
   suspended / exit-requested records.
3. Prevent entering native fullscreen on a second managed window while a native
   record is active.
4. Add command-decision trace and tests for frontmost native record, single record
   fallback, ambiguous records, and normal enter behaviour.

Why second: it is state-machine / AX / Space-transition work and has more edge
cases than the tiling fix.

### Phase 3 — regression guard column full-width

No behavioural change. Add or keep tests that confirm:

- `toggleColumnFullWidth` flips `column.isFullWidth` and keeps window
  `sizingMode == .normal`.
- Focus can move away and back without changing the column property.
- It remains distinct from `toggleFullscreen` / `toggleNativeFullscreen` in docs
  and action labels.

### Phase 4 — optional future true fullscreen

Only if product asks for real niri `fullscreen-window` semantics:

- Define a separate action or resurrect a separate sizing mode.
- Decide whether it should cover menu/workspace bars and hide gaps/borders.
- Decide whether to drive app/window awareness via AX or keep it layout-only.
- Add visual/backdrop policy and tests.

This should not block #69.

## Acceptance criteria across the roadmap

- Tiling maximize is sticky by design and toggles off reliably even after focus
  moves to a neighbour.
- Native fullscreen toggle exits the current native-fullscreen record before any
  managed command-target enter path is considered.
- Column full-width remains a column-only width operation.
- Trace output distinguishes tiling sizing transitions from native fullscreen
  transitions.
- Durable docs and issue updates inline evidence and never depend on local trace
  filenames.
