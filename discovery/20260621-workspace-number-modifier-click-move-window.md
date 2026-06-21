# Modifier + click on workspace number to move the active window/column — Discovery

Source: backlog brainstorm item **#2**, captured in
[`planned/20260621-backlog-brainstorm.md`](../planned/20260621-backlog-brainstorm.md)
under *Workspaces / window management*:

> **#2** Modifier + click on a workspace number to move the active window/column

There is no upstream OmniWM or nehir tracker issue for this — it is a raw
handwritten idea from a screenshot, not a port. This doc investigates whether and
how nehir could implement it, grounded in the current source.

Scope: a discovery / feasibility study. No source is changed here.

All file/line references were verified against `main` at `56573ba2`
("Fix focus-follows-mouse blocked by click-through overlays (#64)") on
2026-06-21. **Re-verify before implementing; line numbers drift.** Verdict is by
code inspection (no runtime trace).

---

## TL;DR

- **The feature is almost entirely reuse.** Nehir already has, end-to-end,
  both "move focused **window** to workspace N" and "move focused **column** to
  workspace N" commands (keyboard + IPC + command handler + navigation handler +
  niri engine). The only thing missing is *invoking them from a click on the
  workspace bar pill instead of from a key press*.
- **The click seam already exists.** Every workspace pill already calls a
  controller callback, `onFocusWorkspace: (WorkspaceBarItem) -> Void`, that
  receives the clicked workspace. Today it unconditionally focuses the workspace.
  Branching it on the held modifier (move vs. focus) is a ~10-line change in the
  callback wiring plus two thin delegating methods — no new layout/transfer logic.
- **The modifier convention is already established.** Nehir's default digit
  bindings are `Opt+Cmd+N` → focus workspace N, and `Opt+Shift+N` → move the
  focused window to workspace N. So **Shift is already Nehir's "move"
  differentiator**, and `Shift+click` on a pill is the exact mouse analogue of
  `Opt+Shift+N`.
- **Verdict:** 🟢 **Pursue.** Small, surgical, fully reuses existing move
  plumbing (including the target-viewport reveal landed in
  `completed/20260619-moved-window-inactive-target-viewport.md`). The one design
  decision to settle before coding is *window vs. column* semantics (see Open
  decision B). Recommend **v1 = Shift+click moves the focused window** (mirrors
  the only numbered move binding that ships enabled today), with column-move as
  an optional second modifier.

## Prior work (do not duplicate)

- [`planned/20260621-backlog-brainstorm.md`](../planned/20260621-backlog-brainstorm.md)
  — origin of this idea (#2). Related items in the same list: **#18** "Right-click
  actions in the action bar" (a sibling mouse-interaction idea — a right-click
  context menu on the pill would be an alternative surface for "move window
  here"); **#16** "Move workspace between displays"; **#24** "Learn niri's Design
  Principles and check for mismatches".
- [`discovery/20260621-nehir-93-vertical-workspace-bar.md`](../discovery/20260621-nehir-93-vertical-workspace-bar.md)
  — maps the workspace bar architecture (`Sources/Nehir/UI/WorkspaceBar/`):
  `WorkspaceBarManager` owns panel lifecycle and wires the click callbacks;
  `WorkspaceBarView` is the SwiftUI body; `WorkspaceBarDataSource` builds the
  items. This doc builds on that map and does not re-derive it.
- [`completed/20260619-moved-window-inactive-target-viewport.md`](../completed/20260619-moved-window-inactive-target-viewport.md)
  — centralized "prepare target viewport for a moved window" in
  `WorkspaceNavigationHandler.prepareMovedWindowTargetViewport(...)` so a moved
  window is revealed in the *target* workspace's stored viewport even when focus
  does not follow. **A click-to-move path inherits this for free**, because it
  reuses the same navigation-handler entry points.
- [`discovery/20260619-nehir-62-move-workspace-to-next-monitor.md`](../discovery/20260619-nehir-62-move-workspace-to-next-monitor.md)
  — documents that Nehir already uses Shift as the "column/window move" modifier
  and traces the same `WorkspaceNavigationHandler` move entry points; relevant
  for keeping the click modifier consistent with the keyboard convention.
- [`discovery/20260616-omniwm-295-niri-window-width-preservation.md`](../discovery/20260616-omniwm-295-niri-window-width-preservation.md)
  — same `moveWindowToWorkspace` engine path; any change to the move pipeline
  must keep width-preservation behavior intact. No conflict here (we only add a
  caller).

No prior discovery covers click-on-pill-to-move; this is net-new UI plumbing over
existing logic.

## What the idea means for Nehir

Today, clicking a workspace pill (the number/label, or the pill background)
**focuses** that workspace — it is the mouse equivalent of `Opt+Cmd+N`. The idea
asks for a modifier-held click to instead **move** the currently focused
window/column *to* the clicked workspace — i.e. the mouse equivalent of
`Opt+Shift+N` ("move focused window to workspace N") and/or a numbered
"move column to workspace N".

In niri/OmniWM terms this is purely an *input affordance*: the transfer semantics
already exist and are well-tested. The work is bridging a mouse event to the
right command, choosing the modifier, and making the affordance discoverable.

## Current behavior (with source)

### 1. Clicking a pill focuses the workspace via a single callback

The SwiftUI bar is built from `WorkspaceBarItem` rows. Each pill renders a
`WorkspaceLabelButton` plus window icons inside a `WorkspaceItemView`. Both the
label button and the pill background route to the same callback:

```swift
// Sources/Nehir/UI/WorkspaceBar/WorkspaceBarView.swift:371-389
private struct WorkspaceLabelButton: View {
    let item: WorkspaceBarItem
    ...
    let onFocusWorkspace: () -> Void
    ...
    var body: some View {
        Button(action: onFocusWorkspace) {       // <- label click
            Text(item.name) ...
        }
        ...
        .help("Focus workspace \(item.name)")
    }
}
```

and the whole pill adds an `.onTapGesture`:

```swift
// Sources/Nehir/UI/WorkspaceBar/WorkspaceBarView.swift:358-362 (inside WorkspaceItemView)
        .contentShape(Rectangle())
        .onTapGesture {
            onFocusWorkspace()                   // <- pill background click
        }
```

These `onFocusWorkspace` closures originate as a single typed callback on the
view (`Sources/Nehir/UI/WorkspaceBar/WorkspaceBarView.swift:100`,
`:144`, `:280`) and are wired in the manager:

```swift
// Sources/Nehir/UI/WorkspaceBar/WorkspaceBarManager.swift:222-224 (inside createBarForMonitor)
                onFocusWorkspace: { [weak controller] item in
                    controller?.focusWorkspaceFromBar(id: item.id)
                },
```

`WMController.focusWorkspaceFromBar(id:)`
(`Sources/Nehir/Core/Controller/WMController.swift:725`) delegates to
`WindowActionHandler.focusWorkspaceFromBar(id:)`
(`Sources/Nehir/Core/Controller/WindowActionHandler.swift:534`), which calls
`workspaceManager.focusWorkspace(id:)` and commits the workspace transition.

**Key fact:** the callback already receives the whole `WorkspaceBarItem`, which
carries everything needed to target a move — including the raw workspace
name/number:

```swift
// Sources/Nehir/UI/WorkspaceBar/WorkspaceBarDataSource.swift:125-128
            return WorkspaceBarItem(
                id: snapshot.workspace.id,
                name: settings.displayName(for: snapshot.workspace.name),
                rawName: snapshot.workspace.name,        // <- "1", "2", or a custom name
```

`item.id` is the `WorkspaceDescriptor.ID`; `item.rawName` is the raw workspace
name string (e.g. `"3"`). Both the window- and column-move functions accept a raw
workspace ID string (below), so no new resolution is required.

### 2. Both move commands already exist, full stack, and take a raw workspace ID

The keyboard command enum already has both numbered move cases:

```swift
// Sources/Nehir/Core/Input/HotkeyCommand.swift:9-18
    case moveToWorkspace(Int)            // move focused WINDOW to workspace N
    case moveWindowToWorkspaceUp
    case moveWindowToWorkspaceDown
    case moveColumnToWorkspace(Int)      // move focused COLUMN to workspace N
    case moveColumnToWorkspaceUp
    case moveColumnToWorkspaceDown
```

`CommandHandler.performCommand` dispatches them to the navigation handler:

```swift
// Sources/Nehir/Core/Controller/CommandHandler.swift:77-85
        case let .moveToWorkspace(index):
            controller.workspaceNavigationHandler.moveFocusedWindow(toWorkspaceIndex: index)
        case .moveWindowToWorkspaceUp:
            controller.workspaceNavigationHandler.moveWindowToAdjacentWorkspace(direction: .up)
        case .moveWindowToWorkspaceDown:
            controller.workspaceNavigationHandler.moveWindowToAdjacentWorkspace(direction: .down)
        case let .moveColumnToWorkspace(index):
            controller.workspaceNavigationHandler.moveColumnToWorkspaceByIndex(index: index)
```

Both navigation-handler entry points are public and accept either an index or a
**raw workspace ID string** (the form a click would use directly):

```swift
// Sources/Nehir/Core/Controller/WorkspaceNavigationHandler.swift:740-742
    func moveColumnToWorkspaceByIndex(index: Int) {
        guard let rawWorkspaceID = WorkspaceIDPolicy.rawID(from: max(0, index) + 1) else { return }
        moveColumnToWorkspace(rawWorkspaceID: rawWorkspaceID)
    }

// Sources/Nehir/Core/Controller/WorkspaceNavigationHandler.swift:745
    func moveColumnToWorkspace(rawWorkspaceID: String) { ... }

// Sources/Nehir/Core/Controller/WorkspaceNavigationHandler.swift:809-814
    func moveFocusedWindow(toWorkspaceIndex index: Int) {
        guard let rawWorkspaceID = WorkspaceIDPolicy.rawID(from: max(0, index) + 1) else { return }
        moveFocusedWindow(toRawWorkspaceID: rawWorkspaceID)
    }

    func moveFocusedWindow(toRawWorkspaceID rawWorkspaceID: String) { ... }
```

"Active window/column" is resolved exactly as for the keyboard commands:
`moveFocusedWindow` uses `controller.managedCommandTargetToken()`
(the focused managed window — `Sources/Nehir/Core/Controller/WMController.swift:1792`),
and `moveColumnToWorkspace` uses `controller.managedLayoutCommandTargetToken()`
(layout selection or focused window — `Sources/Nehir/Core/Controller/WMController.swift:1796`),
then resolves the containing column. **So "the active window/column" is already
defined consistently** — a click-to-move path would target the exact same object
the corresponding hotkey would.

Both entry points already call `prepareMovedWindowTargetViewport(token:workspaceId:)`
(`WorkspaceNavigationHandler.swift:844` and `:869`), so the moved window is
revealed in the target workspace's viewport per
`completed/20260619-moved-window-inactive-target-viewport.md`. They also honor
`settings.focusFollowsWindowToMonitor` (whether focus follows the window). A
click-to-move path inherits both behaviors for free.

### 3. The keyboard convention: Shift = "move"

The default digit bindings make the convention explicit:

```swift
// Sources/Nehir/Core/Input/ActionCatalog.swift:145-161
        for (idx, code) in digitCodes.enumerated() {
            specs.append(action(
                id: "switchWorkspace.\(idx)",
                command: .switchWorkspace(idx),
                ...
                binding: KeyBinding(keyCode: code, modifiers: UInt32(optionKey | cmdKey))   // Opt+Cmd+N = FOCUS
            ))
            specs.append(action(
                id: "moveToWorkspace.\(idx)",
                command: .moveToWorkspace(idx),
                ...
                binding: KeyBinding(keyCode: code, modifiers: UInt32(optionKey | shiftKey)) // Opt+Shift+N = MOVE WINDOW
            ))
        }
```

So plain digit = focus, Shift+digit = move window. The column equivalent
**has no default binding**:

```swift
// Sources/Nehir/Core/Input/ActionCatalog.swift:324-331
        for idx in 0 ..< 9 {
            specs.append(action(
                id: "moveColumnToWorkspace.\(idx)",
                command: .moveColumnToWorkspace(idx),
                ...
                binding: .unassigned            // <- no default for "move COLUMN to workspace N"
            ))
        }
```

Implication: of the two numbered "move to workspace N" actions, only the
**window** move ships with a default key binding. That makes `Shift+click → move
window` the most convention-consistent v1 mapping (it is the precise mouse
analogue of `Opt+Shift+N`). See Open decision B for the column case.

### 4. The bar panel is non-activating but clicks already work

```swift
// Sources/Nehir/UI/WorkspaceBar/WorkspaceBarManager.swift (defaultPanel(), inside the same file)
        styleMask: [.borderless, .nonactivatingPanel], ...
        panel.becomesKeyOnlyIfNeeded = true
```

The panel never becomes the key window, yet the existing focus-on-click already
works because SwiftUI `Button`/`.onTapGesture` dispatch on mouse-up regardless of
key status. Modifier flags are global state, so detecting them does not depend on
panel key-ness either.

## Where / how it would be implemented

Ranked from the smallest change to the most extensible.

### Step 1 — Branch the existing click callback on the held modifier (the whole feature)

The most surgical implementation changes only the callback wiring in
`WorkspaceBarManager` and adds two thin delegating methods. The SwiftUI views do
not change at all:

```swift
// Sources/Nehir/UI/WorkspaceBar/WorkspaceBarManager.swift:222-224 — replace the closure body
                onFocusWorkspace: { [weak controller] item in
                    guard let controller else { return }
                    let flags = NSEvent.modifierFlags
                    if flags.contains(.shift) {
                        controller.moveFocusedWindowFromBar(toWorkspaceId: item.id)   // new, ~3 lines
                    } else if flags.contains(.option) {
                        controller.moveFocusedColumnFromBar(toWorkspaceId: item.id)   // new, ~3 lines (optional, dec. B)
                    } else {
                        controller.focusWorkspaceFromBar(id: item.id)                 // unchanged
                    }
                },
```

The two new controller methods just delegate to the existing navigation-handler
entry points. They mirror `focusWorkspaceFromBar(id:)`
(`Sources/Nehir/Core/Controller/WMController.swift:725`). A minimal sketch:

```swift
// Sources/Nehir/Core/Controller/WMController.swift — add next to focusWorkspaceFromBar(id:)
func moveFocusedWindowFromBar(toWorkspaceId id: WorkspaceDescriptor.ID) {
    guard let rawID = workspaceManager.descriptor(for: id)?.name else { return }
    workspaceNavigationHandler.moveFocusedWindow(toRawWorkspaceID: rawID)
}
func moveFocusedColumnFromBar(toWorkspaceId id: WorkspaceDescriptor.ID) {
    guard let rawID = workspaceManager.descriptor(for: id)?.name else { return }
    workspaceNavigationHandler.moveColumnToWorkspace(rawWorkspaceID: rawID)
}
```

(Resolving `rawID` from the descriptor's `name` — the same field
`WorkspaceBarDataSource` uses for `rawName` — keeps numbered *and* custom-named
workspaces working. Alternatively pass `item.rawName` straight through the
callback instead of `item.id`; the `WorkspaceBarItem` already carries it.)

### Step 2 — Detecting the modifier: three options

SwiftUI's `Button(action:)` and `.onTapGesture` do **not** expose the triggering
`NSEvent`. Three ways to recover the held modifier, in increasing order of
explicitness:

- **A. Read `NSEvent.modifierFlags` inside the action (recommended for v1).**
  The action fires synchronously on the main thread during the click's mouse-up
  event dispatch, so `NSEvent.modifierFlags` reflects the held modifiers. Nehir
  already uses this exact pattern in `Sources/Nehir/UI/KeyRecorderView.swift` and
  `Sources/Nehir/UI/Onboarding/InteractiveMoveDemo.swift`. Smallest change;
  acceptable race profile for human input. This is what Step 1 assumes.
- **B. Track flags via a local `.flagsChanged` monitor.** Add
  `NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged])` (the pattern at
  `Sources/Nehir/Core/Overview/OverviewController.swift:739`) and store the
  current flags on the `WorkspaceBarModel` so the callback reads a model field
  instead of polling. More testable (tests can set the field directly) but adds a
  long-lived monitor. Prefer this only if Step 1's global-poll proves awkward in
  tests.
- **C. `NSViewRepresentable` overriding `mouseDown(with:)`.** Receives the real
  `NSEvent` and can branch on `event.modifierFlags`, and also gives
  `rightMouseDown(...)` for free — useful if backlog **#18** (right-click actions)
  lands on the same surface. Heavier SwiftUI/AppKit bridging; defer unless
  right-click menus are wanted here too.

### Step 3 — Discoverability (required, not optional)

Modifier+click has no visible affordance. Minimum:

- Update the tooltip on `WorkspaceLabelButton`
  (`Sources/Nehir/UI/WorkspaceBar/WorkspaceBarView.swift:388`) from
  `"Focus workspace \(item.name)"` to e.g.
  `"Focus workspace \(item.name) — Shift-click to move the focused window here"`.
- Consider a one-line onboarding hint. The bar's onboarding path is
  `Sources/Nehir/UI/Onboarding/Animations/WorkspaceBarAnimation.swift` (cosmetic
  only; a real hint likely belongs in the settings tab
  `Sources/Nehir/UI/WorkspaceBarSettingsTab.swift` next to the bar toggles, or in
  the onboarding flow that introduces workspaces).

## Risks and unknowns

- **"Active window/column" may be empty.** If nothing managed is focused,
  `managedCommandTargetToken()` / `managedLayoutCommandTargetToken()` return nil
  and both move functions early-return silently. A Shift+click that does nothing
  is confusing. Decide whether to (a) no-op silently (matches hotkey behavior
  today), (b) flash the pill, or (c) fall back to focusing the workspace. (a) is
  the consistent choice.
- **Column move moves *all* windows in the column**, including tabbed windows
  (`engine.moveColumnToWorkspace(...)` moves the whole `NiriContainer`; see
  `discovery/20260616-omniwm-295-...:240`). Users may expect a single-window
  move. This is the core of Open decision B.
- **Width preservation.** `moveWindowToWorkspace` resets/claims target column
  width (the subject of `discovery/20260616-omniwm-295-...`). Reusing the
  existing entry point means the click path inherits whatever that behavior is
  today — no new risk, but worth a regression check that Shift+click into an
  empty/lonely workspace preserves expected width.
- **Modifier collisions.** Shift is benign everywhere. Option/Command on a
  custom non-activating panel are ours (no system alternate-click semantics
  apply to a borderless panel's content), but Option+click and Cmd+click have
  meanings in other apps users may muscle-memory; keep the v1 binding to Shift
  only to minimize surprise.
- **Scratchpad pill / window icons.** The bar also renders a scratchpad pill and
  per-window icons with their own click handlers (`onFocusWindow`,
  `onActivateScratchpad`). This idea should be scoped to the **workspace
  label/pill** only. Applying modifiers to the window-icon sub-buttons is a
  separate question (and overlaps with backlog #8 "Fix target window for
  commands like toggle floating / scratchpad").
- **Tests.** There is no current test that drives `onFocusWorkspace` from the
  SwiftUI view (clicks are exercised through the controller methods). A
  modifier-aware callback is best tested at the controller seam
  (`moveFocusedWindowFromBar` / `moveFocusedColumnFromBar`) plus a small test
  that the wiring closure dispatches correctly given a flag — which favors
  Option B (model-injected flags) for testability if Step 1's global poll is hard
  to assert.

## Open decisions for the maintainer

- **A. Which modifier?** Recommend **Shift** for move-window (exact analogue of
  `Opt+Shift+N`). If a second modifier is wanted for move-column, pick one that
  does not collide with the digit bindings' `Opt`/`Cmd`/`Shift` set in a
  confusing way — e.g. `Shift+Cmd` (move column) vs `Shift` alone (move window).
- **B. Window vs. column semantics (the main decision).** Three options:
  1. **One modifier, always window** (`Shift+click` = `moveFocusedWindow`). Most
     discoverable, mirrors the only numbered move binding that ships enabled.
     Column move stays keyboard/IPC-only.
  2. **Two modifiers** (`Shift+click` = window, `Shift+Cmd+click` = column).
     Most expressive, slightly less discoverable.
  3. **One modifier, context-dependent** (`Shift+click` moves the column if the
     focused column has >1 window, else the single window). Matches "move the
     active container" intuition but is the least predictable.
  Recommend **(1)** for v1; revisit (2) if users ask for column moves.
- **C. Scope of clickable targets.** Workspace label + pill background only
  (recommended), or also the per-window icons? Recommend label/pill only.
- **D. Discoverability surface.** Tooltip (minimal) vs. onboarding hint vs.
  settings-tab description. Recommend tooltip + a one-liner in
  `WorkspaceBarSettingsTab`.
- **E. Kill switch.** Whether to gate the behavior behind a setting. Probably
  unnecessary for Shift-only (it is additive and never changes plain click), but
  a toggle would let users who remapped Shift to something else opt out.

## Suggested tests

- **Controller seam (the real logic).** With a focused managed window on
  workspace 1 and a target workspace 2, assert
  `moveFocusedWindowFromBar(toWorkspaceId: ws2.id)` moves the window (target
  workspace gains the window, source loses it) and reveals it in the target
  viewport (reuse the assertion shape from
  `WorkspaceNavigationHandlerTests.moveFocusedWindowWithoutFollowRevealsInactiveTargetViewport`).
  Mirror for `moveFocusedColumnFromBar` with a multi-window column.
- **Wiring dispatch.** A test that the `onFocusWorkspace` closure in
  `WorkspaceBarManager.createBarForMonitor` calls
  `moveFocusedWindowFromBar` when the flag is set and `focusWorkspaceFromBar`
  otherwise. (If using Step 1's `NSEvent.modifierFlags` poll, inject the flag via
  Option B's model field to keep the test hermetic.)
- **Empty-selection no-op.** With no managed window focused, both move-from-bar
  methods return without mutating workspace membership and without crashing.
- **Custom-named workspace target.** `item.rawName` / descriptor `name` for a
  non-numeric workspace resolves correctly through `moveFocusedWindow(toRawWorkspaceID:)`.

## Reproduction / verification commands

Re-verify the architecture before implementing:

```bash
# Click seam — single callback, currently unconditional focus
rg -n 'onFocusWorkspace|controller\?\.focusWorkspaceFromBar\(id: item\.id\)' \
   Sources/Nehir/UI/WorkspaceBar/WorkspaceBarView.swift Sources/Nehir/UI/WorkspaceBar/WorkspaceBarManager.swift

# Item carries the raw workspace name (no extra resolution needed)
rg -n 'rawName:|name: settings\.displayName' Sources/Nehir/UI/WorkspaceBar/WorkspaceBarDataSource.swift

# Both numbered move entry points exist and take a raw workspace ID
rg -n 'func moveFocusedWindow\(toRawWorkspaceID|func moveColumnToWorkspace\(rawWorkspaceID' \
   Sources/Nehir/Core/Controller/WorkspaceNavigationHandler.swift

# Convention: Opt+Cmd = focus, Opt+Shift = move window; column-move digit binding is unassigned
rg -n 'switchWorkspace\.\\\(idx\)|moveToWorkspace\.\\\(idx\)|moveColumnToWorkspace\.\\\(idx\)|optionKey \| cmdKey|optionKey \| shiftKey|\.unassigned' \
   Sources/Nehir/Core/Input/ActionCatalog.swift

# Existing modifier-flag patterns in-tree (for Step 2)
rg -n 'NSEvent\.modifierFlags|addLocalMonitorForEvents\(.*flagsChanged' \
   Sources/Nehir/UI/KeyRecorderView.swift Sources/Nehir/UI/Onboarding/InteractiveMoveDemo.swift \
   Sources/Nehir/Core/Overview/OverviewController.swift
```

The defining evidence: a single `onFocusWorkspace: (WorkspaceBarItem) -> Void`
callback already receives the clicked workspace
(`WorkspaceBarView.swift:100`, wired at `WorkspaceBarManager.swift:222-224`);
both `moveFocusedWindow(toRawWorkspaceID:)` and
`moveColumnToWorkspace(rawWorkspaceID:)` already exist
(`WorkspaceNavigationHandler.swift:745`/`:814`); and the default digit bindings
establish Shift as the "move" modifier (`ActionCatalog.swift:145-161`). The
feature is the bridge between them, not new logic.

## Recommendation

🟢 **Pursue.** It is a small, surgical, additive change that reuses 100% of the
existing move pipeline (entry points, target-viewport reveal, focus-follows
policy). Settle Open decision B first; recommend **v1 = Shift+click moves the
focused window** (the exact mouse analogue of the only numbered move binding that
ships enabled today, `Opt+Shift+N`), with column-move and a second modifier
deferred until asked for. Do not implement until the modifier choice is confirmed
so the tooltip/onboarding wording can be written once.
