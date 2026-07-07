# Right-click actions in the action bar

Groom 2026-07-07: resolved — landed on main `d0cf6368` ("Implement right-click context menus on the workspace bar"); see `completed/20260621-right-click-actions-action-bar.md`. (Left in `discovery/` — referenced by sibling discovery docs and the `completed/` companion already occupies the name.)

Source: handwritten backlog list captured 2026-06-21, idea **#18** — *"Right-click
actions in the action bar."* Triage doc for that idea. See
`planned/20260621-backlog-brainstorm.md` for the full raw list.

All source/line references were verified against the main Nehir source tree at
`e7b246b6` ("Surface global-hotkey conflicts in Diagnostics (Nehir #48)") on
2026-06-21. Re-verify before implementing; line numbers drift.

This is a discovery document. No source was modified.

---

## TL;DR

- **"Action bar" = the workspace bar** (`Sources/Nehir/UI/WorkspaceBar/`), the
  per-monitor floating pill bar that renders workspace labels, per-window app
  icons, the scratchpad pill, and the three trailing action buttons (trace
  capture, display-diagnostics warning, command palette). The menu-bar *status
  bar* (`Sources/Nehir/UI/StatusBar/`) is a separate surface and already handles
  right-click — it just shows the same `NSMenu` as a left-click
  (`StatusBarController.swift:88,97-117`). The idea is about the workspace bar.
- **Today the workspace bar is left-click only.** Every pill is a SwiftUI
  `Button(action:)` or `.onTapGesture` (`WorkspaceBarView.swift:360` etc.);
  right-click does nothing. There is no `.contextMenu(...)` modifier anywhere in
  `Sources/Nehir/UI/`, and no `rightMouseDown` on the bar's panel or views.
- **The cheap part is the menu UI.** SwiftUI `.contextMenu` (or an `NSMenu`
  `popUp(positioning:at:in:)`, already proven on the status bar) can attach to
  each pill in `WorkspaceBarView`. The wiring seam already exists: six click
  callbacks are plumbed from the SwiftUI view through
  `WorkspaceBarManager.createBarForMonitor` (`:222-237`) to controller entry
  points.
- **The real work is *token-parameterized actions.*** The per-window actions a
  right-click menu would surface — toggle floating, assign to scratchpad, toggle
  fullscreen, close, move-to-workspace — resolve their target internally from
  the *focused* window (`focusedManagedTokenForCommand()`), not from an explicit
  token. Right-clicking a window icon targets a **specific** window token that
  may not be focused. Nehir already solved this once for the Overview surface
  (`OverviewController.closeWindow(_:)`, `selectAndActivateWindow(_:)`,
  `WorkspaceNavigationHandler.moveWindow(handle:toWorkspaceId:)`); the right-click
  menu needs the same handle-targeted treatment for the remaining actions.
- **Recommendation: pursue, scoped.** Land right-click menus on the **window
  icons, scratchpad pill, and workspace labels** first; leave the three trailing
  action buttons (trace/diagnostics/palette) single-purpose with no menu. Build
  the token-parameterized action family in `WMController` so this idea, backlog
  **#2** (modifier+click move), and backlog **#8** (fix target window) share one
  refactor. Defer the full menu breadth; ship a minimal, consistent item set.

---

## Prior work (do not duplicate)

Checked `discovery/`, `planned/`, `completed/`, `noop/`. Related, but **not**
this idea:

- `planned/20260621-backlog-brainstorm.md` **#18** — this idea (canonical
  source). Siblings named there: **#2** *"Modifier + click on a workspace number
  to move the active window/column"*, **#8** *"Fix target window for commands
  like toggle floating / scratchpad, etc."*, **#24** *"Learn niri's Design
  Principles and check for mismatches."* All three overlap with #18 (see below).
- `discovery/20260621-workspace-number-modifier-click-move-window.md` — the #2
  triage. It maps the workspace-bar architecture (`WorkspaceBarManager` owns
  panel lifecycle and wires click callbacks; `WorkspaceBarView` is the SwiftUI
  body; `WorkspaceBarDataSource` builds items) that this doc builds on without
  re-deriving. It also names the three ways to recover an `NSEvent` / capture a
  right-click on the bar (read `NSEvent.modifierFlags`; a `.flagsChanged`
  monitor; an `NSViewRepresentable` overriding `mouseDown`/`rightMouseDown`) and
  explicitly defers window-icon interactions to backlog #8 — i.e. to the same
  token-target seam this idea depends on.
- `discovery/20260621-fix-target-window-toggle-floating-scratchpad.md` — the #8
  triage. Documents that Nehir has **three independent target notions**
  (`layoutSelection`, `confirmedManagedFocus`, `frontmostManagedFallback` —
  `WMCommandTarget.swift:9-13`) and that `toggleFocusedWindowFloating()`
  (`WMController.swift:3562`) and `assignFocusedWindowToScratchpad()`
  (`WMController.swift:3582`) resolve their target via the
  `focusedManagedTokenForCommand()` cascade. **This is exactly why a right-click
  menu cannot just call those methods** — they would act on the focused window,
  not the right-clicked one. Any token-parameterized action family introduced
  for #18 is shared with #8 and should be co-designed.
- `discovery/20260621-nehir-93-vertical-workspace-bar.md` — the full file/line
  map of `Sources/Nehir/UI/WorkspaceBar/` (manager, geometry, view, panel,
  projection options, data source) plus the settings/config files. Cited for
  architecture, not duplicated.
- `discovery/20260621-assign-hotkey-from-command-palette.md` — explicitly notes
  that #18 is *"a different surface (action bar, not palette)"* and that a
  right-click context menu on a palette row is one *possible* entry point for
  that separate idea. No overlap in implementation; cited to prevent conflating
  the two "right-click" surfaces.
- `completed/20260610-settings-and-onboarding-redesign.md` — documents the
  existing "Mouse Resize Modifier" setting ("Hold this modifier + right-click
  drag to resize tiled windows"). Relevant only as precedent that right-click is
  already part of Nehir's input vocabulary for *window manipulation*; it is not
  a menu.

Nothing in the repo implements a right-click context menu on the workspace bar
today. The status bar is the only bar surface with right-click handling, and it
shows the same menu as left-click.

---

## What the idea means for Nehir

The workspace bar is Nehir's always-visible, mouse-reachable summary of "what is
where" — which workspaces exist, which windows live on the focused workspace,
what is in the scratchpad. Today every pill is a one-shot left-click: focus
workspace / focus window / activate scratchpad / open palette / toggle trace /
open diagnostics. The idea adds a **secondary, contextual action surface** via
right-click, so a user can act on a specific window or workspace *without first
focusing it and without remembering a hotkey*.

Concretely, a right-click menu turns each pill into:

- **Window icon** — a per-window menu: toggle floating, assign to / unassign
  from scratchpad, toggle fullscreen, move to workspace ▸, close. This is the
  highest-value target: it is the only bar pill that identifies a *specific*
  window, and it is where the focused-window/target-window seam (#8) bites
  hardest.
- **Scratchpad pill** — a scratchpad menu: toggle visible/hidden, unassign from
  scratchpad (return to tiling), focus. Reuses the existing
  `activateScratchpadFromBar` path plus a token-targeted unassign.
- **Workspace label** — a per-workspace menu: focus (same as left-click), move
  workspace to monitor ▸ (backlog **#16**), and possibly "close all windows on
  this workspace." Lower priority than the window menu but cheap once the
  plumbing exists.

The three trailing **action buttons** (trace capture, display-diagnostics
warning, command palette) are deliberately excluded — they are single-purpose
and a right-click menu would just duplicate the left-click.

Scope boundary: this idea is a **mouse affordance over existing actions**, not
new window-management behavior. Every menu item must map to an action Nehir can
already perform (via hotkey, IPC, or the Overview). The work is (a) attaching
menus to pills, (b) wiring per-token action entry points, and (c) discoverability
(tooltips/onboarding). It is explicitly **not** "invent new close/move/float
semantics" — those belong to #8 and the existing action catalog.

---

## Current behavior (with source citations)

### The workspace bar is left-click only

`WorkspaceBarView` (`Sources/Nehir/UI/WorkspaceBar/WorkspaceBarView.swift:98`)
declares six click callbacks, all left-click:

```swift
// WorkspaceBarView.swift:100-105 (mirrored at :144-149 on WorkspaceBarContentView)
let onFocusWorkspace: (WorkspaceBarItem) -> Void
let onFocusWindow: (WindowToken) -> Void
let onActivateScratchpad: () -> Void
let onOpenCommandPalette: () -> Void
let onToggleTraceCapture: () -> Void
let onOpenDiagnostics: () -> Void
```

Each pill renders as a SwiftUI `Button(action:)` (e.g. `WorkspaceLabelButton`
`:371`, `ScratchpadPillView` `:452`, `WindowIconView` `:548`,
`CommandPaletteBarButton` `:792`, `TraceCaptureBarButton` `:699`,
`DisplayDiagnosticsBarButton` `:760`) or uses `.onTapGesture` (the workspace
pill background, `WorkspaceItemView` `:360`). There is no `.contextMenu(...)` on
any of them, and a repo-wide search confirms `.contextMenu(` appears **nowhere**
in `Sources/Nehir/UI/`. Right-click on any bar pill is a no-op.

The callbacks are wired to the controller in
`WorkspaceBarManager.createBarForMonitor`
(`Sources/Nehir/UI/WorkspaceBar/WorkspaceBarManager.swift:222-237`):

```swift
onFocusWorkspace: { [weak controller] item in controller?.focusWorkspaceFromBar(id: item.id) },
onFocusWindow:    { [weak controller] token in controller?.focusWindowFromBar(token: token) },
onActivateScratchpad: { [weak controller] in controller?.activateScratchpadFromBar(on: monitor.id) },
onOpenCommandPalette: { [weak controller] in controller?.openCommandPalette() },
onToggleTraceCapture:  { [weak controller] in controller?.toggleRuntimeTraceCapture() },
onOpenDiagnostics:     { ... SettingsWindowController.shared.show(... section: .diagnostics) }
```

This closure-to-controller seam is exactly where right-click callbacks would be
added.

### The panel is a non-activating, floating, key-only-if-needed panel

`WorkspaceBarManager.defaultPanel()`
(`Sources/Nehir/UI/WorkspaceBar/WorkspaceBarManager.swift:467-485`):

```swift
let panel = WorkspaceBarPanel(
    contentRect: .zero,
    styleMask: [.borderless, .nonactivatingPanel],   // :471
    backing: .buffered, defer: false)
panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary] // :476
panel.ignoresMouseEvents = false                     // :480
panel.isFloatingPanel = true                          // :481
panel.becomesKeyOnlyIfNeeded = true                   // :483
```

It is registered with the `SurfaceCoordinator` under a `.workspaceBar` kind with
`hitTestPolicy: .interactive` (`:280-287`). Two consequences for a context menu:

1. The panel accepts mouse events, so right-clicks *reach* the SwiftUI content —
   the only question is whether the view handles them.
2. Because the panel is `nonactivatingPanel` + `becomesKeyOnlyIfNeeded`, a menu
   shown from it must not steal app activation from the user's frontmost app.
   SwiftUI `.contextMenu` and `NSMenu.popUp(...)` both behave correctly here in
   principle, but only `NSMenu.popUp(positioning:at:in:)` is *proven* in-tree on
   a Nehir bar surface (the status bar, below).

### The status bar is the only bar with right-click — and it reuses the left menu

`Sources/Nehir/UI/StatusBar/StatusBarController.swift:87-117`:

```swift
button.action = #selector(handleClick(_:))
button.sendAction(on: [.leftMouseUp, .rightMouseUp])     // :88
...
@objc private func handleClick(_: NSStatusBarButton) {
    guard let event = NSApp.currentEvent else { return }
    if event.type == .rightMouseUp { handleRightClick() } // :100-101
    else { showMenu() }
}
...
private func showMenu() {
    rebuildMenu()
    guard let button = statusItem?.button, let menu else { return }
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button) // :114
}
private func handleRightClick() { showMenu() }            // :117 — same menu
```

So the status bar already (a) distinguishes left vs. right via `sendAction(on:)`
+ `NSApp.currentEvent`, and (b) pops an `NSMenu` anchored at the button. Both
techniques transfer directly to a workspace-bar pill if `NSMenu` is chosen over
SwiftUI `.contextMenu`. The menu itself is built by `StatusBarMenuBuilder`
(`Sources/Nehir/UI/StatusBar/StatusBarMenu.swift:44`) using custom `NSMenuItem`
views (`MenuToggleRowView`, `MenuSectionLabelView`, etc.) — a reusable pattern
if a styled `NSMenu` is wanted.

### Per-window actions resolve the target internally — no explicit token

The actions a window-icon right-click menu would surface are defined in the
`HotkeyCommand` catalog (`Sources/Nehir/Core/Input/HotkeyCommand.swift`) and
titled by `ActionCatalog` (`Sources/Nehir/Core/Input/ActionCatalog.swift`). The
relevant ones:

- `toggleFocusedWindowFloating` → *"Toggle Focused Window Floating"*
  (`WMController.swift:3562`)
- `assignFocusedWindowToScratchpad` → *"Assign Focused Window to Scratchpad"*
  (`WMController.swift:3582`)
- `toggleScratchpadWindow` → *"Toggle Scratchpad Window"*
  (`WMController.swift:3668`) — resolves via `workspaceManager.scratchpadToken()`,
  i.e. the *stored* scratchpad, not focus at all
- `toggleFullscreen` / `toggleNativeFullscreen` — layout path, resolved from the
  Niri viewport selection (`NiriLayoutHandler`)

**None of these accept an explicit window token.** `toggleFocusedWindowFloating`
and `assignFocusedWindowToScratchpad` both call `focusedManagedTokenForCommand()`
internally (see `discovery/20260621-fix-target-window-toggle-floating-scratchpad.md`
for the full cascade). Calling them from a window-icon right-click would act on
the *focused* window, not the right-clicked one — exactly the #8 defect.

### The Overview is the in-tree precedent for token-targeted actions

Nehir already has a surface that acts on an **explicit** window handle, not on
focus: the Overview. `Sources/Nehir/Core/Overview/OverviewController.swift`
exposes handle-parameterized entry points:

- `selectAndActivateWindow(_ handle: WindowHandle)` (`:578`)
- `closeWindow(_ handle: WindowHandle)` (`:589`) →
  `WindowActionHandler.closeWindowFromOverview(handle:)` (`:141`, private), which
  presses the window's AX close button.
- `closeWindows()` (`:418`) — bulk close.

And `Sources/Nehir/Core/Controller/WorkspaceNavigationHandler.swift` already has
the handle-parameterized move:

```swift
func moveWindow(handle: WindowHandle, toWorkspaceId targetWsId: WorkspaceDescriptor.ID) -> Bool // :885
```

`OverviewInputHandler` drives these (`controller.closeWindow(window.handle)`
`:147`, `controller.selectAndActivateWindow(...)` `:153`). So **close and
move-to-workspace already exist as token-targeted actions** — a right-click
window-icon menu can reuse them directly. The missing pieces are
token-targeted **toggle-floating**, **scratchpad assign/unassign**, and
**fullscreen**; the low-level primitive they share,
`applyManagedWindowOverride(_:for:entry:)` (`WMController.swift:3631`), exists
but is `private`.

---

## Where / how it would be implemented

Primary site: **`Sources/Nehir/UI/WorkspaceBar/WorkspaceBarView.swift`** — attach
a right-click menu to each in-scope pill. Secondary sites: the callback wiring in
`WorkspaceBarManager.createBarForMonitor` (`:222-237`), new token-parameterized
controller entry points, and tooltip/onboarding copy.

### Step 1 — Attach the menu (two viable mechanisms)

- **A. SwiftUI `.contextMenu(menuItems:)`.** Lightest. Attach per pill, e.g. on
  `WindowIconView` (`:548`) and `ScratchpadPillView` (`:452`). Menu items are
  SwiftUI `Button`s backed by new callbacks. Consistent with the rest of the
  view (already SwiftUI). *Unknown:* whether `.contextMenu` renders/dismisses
  correctly on a `nonactivatingPanel` with `becomesKeyOnlyIfNeeded` — needs a
  short spike. If it steals activation or fails to track, fall back to B.
- **B. `NSMenu.popUp(positioning:at:in:)` via an `NSViewRepresentable`.** Already
  proven on the status bar (`StatusBarController.swift:114`). Heavier bridging
  but guaranteed behavior; also yields the real `NSEvent` (useful if the same
  `NSViewRepresentable` also wants `rightMouseDown` for #2's modifier-click). This
  is "Option C" in `discovery/20260621-workspace-number-modifier-click-move-window.md`'s
  Step 2 — the two ideas can share one bridging view.

Recommend **A first, B as fallback**; the choice does not block the controller
work in Step 2.

### Step 2 — Token-parameterized action entry points (the real work)

Add handle/token-parameterized variants in `WMController` (or a small
`WindowActionHandler` extension) next to the existing bar entry points
(`focusWindowFromBar` `WMController.swift:729`). Reuse the Overview's precedent:

- `toggleWindowFloating(token:)` — refactor `toggleFocusedWindowFloating()`
  (`:3562`) so the focus-resolving wrapper calls a new
  `toggleWindowFloating(token:)` that runs the same
  `applyManagedWindowOverride(_:for:entry:)` body (`:3631`) directly. The
  right-click path passes the clicked token; the hotkey path keeps resolving via
  `focusedManagedTokenForCommand()`.
- `assignWindowToScratchpad(token:)` / `unassignWindowFromScratchpad(token:)` —
  same split of `assignFocusedWindowToScratchpad()` (`:3582`). Note the
  scratchpad has its own target quirks (stored `scratchpadToken()`, single-slot
  today — see backlog **#7**); a right-click *unassign* should call the cleanup
  path the focused variant already uses.
- `closeWindow(token:)` — expose the Overview's private
  `closeWindowFromOverview(handle:)` (`WindowActionHandler.swift:141`) as a
  controller entry point. Already token-targeted; just needs lifting.
- `moveWindow(token:toWorkspace:)` — already exists as
  `WorkspaceNavigationHandler.moveWindow(handle:toWorkspaceId:)` (`:885`); add a
  thin `WMController` wrapper.
- `toggleFullscreen(token:)` — hardest: the layout path resolves from the Niri
  viewport selection (`NiriLayoutHandler`), which cannot point at a floating
  window and which is *selection*-driven, not *token*-driven. **Defer** the
  fullscreen item unless the token-targeted layout work from #8 lands first;
  ship the menu without it.

This refactor is shared with backlog **#8** (which wants the focused path fixed)
and **#2** (which wants modifier-click move). Land it once; all three ideas
consume it.

### Step 3 — Callback wiring + new closures

Add right-click closures to `WorkspaceBarView` / `WorkspaceBarContentView`
alongside the six left-click ones (`:100-105`, `:144-149`), thread them through
the per-pill subviews (`WindowIconView` `:548`, `ScratchpadPillView` `:452`,
`WorkspaceLabelButton` `:371`), and wire them in
`WorkspaceBarManager.createBarForMonitor` (`:222-237`) to the new controller
entry points from Step 2. The `WorkspaceBarItem` already carries everything a
menu needs (`id`, `name`, `tiledWindows`, `floatingWindows`); the per-window
`WorkspaceBarWindowItem` carries `id: WindowToken` (`:31`) — that is the handle
the token-parameterized actions take.

### Step 4 — Discoverability (required, not optional)

Right-click has no visible affordance — the same problem #2 flags. Minimum:

- Update the per-pill `.help(...)` tooltips (`WorkspaceBarView.swift:396,510,610`)
  to mention right-click, e.g. window icon: *"Focus <app>. Right-click for more
  actions."*
- Optionally a one-line hint in `Sources/Nehir/UI/WorkspaceBarSettingsTab.swift`
  next to the bar toggles, mirroring the discoverability recommendation in the
  #2 triage.

### Step 5 — Tests

The controller seam is the testable boundary (as in #2). Add
`WMController`/`WindowActionHandler` tests asserting the token-parameterized
variants act on the passed token, not on focus — mirroring the existing
`toggleFocusedWindowFloatingTargetsFocusedFloatingWindowOverNiriSelection`
assertion style (cited in the #8 triage). The SwiftUI menu attachment itself is
best verified by a small view test that the right-click closure fires (favoring
mechanism B's testability if A proves hard to drive).

---

## Risks and unknowns

- **Target-window seam (the central risk).** Right-click targets a specific
  token; the existing per-window actions target focus. This is the same seam as
  #8 and #2, and the fix (token-parameterized actions) is shared. If #8 is not
  landed or co-designed, this idea must invent the token-targeted family on its
  own and risks diverging from the Overview's existing handle-targeted
  (`closeWindow`, `moveWindow(handle:toWorkspaceId:)`) precedent. **Mitigation:
  land the token-parameterized refactor as a shared prerequisite with #8/#2.**
- **`.contextMenu` on a non-activating panel (unproven).** Nehir has no
  `.contextMenu` in `Sources/Nehir/UI/` today. The panel is `nonactivatingPanel`
  + `becomesKeyOnlyIfNeeded` (`:471,483`). SwiftUI `.contextMenu` *may* require
  activation to track/dismiss correctly, or may render at the wrong level
  relative to the `isFloatingPanel` panel. **Mitigation:** short spike; fall back
  to `NSMenu.popUp(...)` (proven on the status bar, `:114`).
- **Layout actions cannot target an arbitrary token.** `toggleFullscreen`,
  `moveColumn`, `consumeOrExpelWindow`, sizing — these operate on the Niri
  viewport *selection* (`NiriLayoutHandler.withNiriOperationContext`,
  `state.selectedNodeId`), which is selection-driven and cannot point at a
  floating window. A right-click window menu must **not** offer these for a
  floating target, and offering them for a tiled target means first making that
  window the viewport selection (a focus side-effect that surprises users who
  right-clicked *without* focusing). **Mitigation:** ship a minimal item set
  (float/scratchpad/close/move) and defer fullscreen/column ops until #8 decides
  the layout-command-vs-focus policy.
- **Scope creep across pills.** It is tempting to add menus to the three
  trailing action buttons (trace/diagnostics/palette). They are single-purpose;
  a menu there adds clutter without value. **Mitigation:** explicitly scope to
  window icons + scratchpad pill + workspace labels.
- **Close semantics.** `closeWindowFromOverview` presses the AX close button
  (`WindowActionHandler.swift:141`). Some apps intercept/defeat close (unsaved
  changes, close-to-tray). A right-click "Close" inherits whatever the app does,
  which is the same behavior as the Overview close — acceptable, but the menu
  item should not promise "force close."
- **Scratchpad single-slot constraint.** `assignWindowToScratchpad(token:)`
  returns `.notFound` if a scratchpad slot is already occupied
  (`WMController.swift:3582-3666`, and see backlog **#7** for multi-slot). The
  menu item should be disabled or relabel ("Replace scratchpad") when a slot is
  taken, rather than silently no-op.
- **Design-philosophy fit.** Nehir is keyboard-first; right-click is a mouse
  power-user affordance. Whether it belongs is backlog **#24**'s question ("learn
  niri's Design Principles"). Not a blocker — the status bar already exposes a
  mouse menu — but worth a maintainer gut-check before investing.
- **Discoverability.** No visible affordance (same as #2). Without tooltips /
  onboarding, users will never find the menus.

---

## Open questions for the maintainer

1. **Which pills get a menu?** Recommend window icons + scratchpad pill +
   workspace labels; exclude the three trailing action buttons. Confirm.
2. **SwiftUI `.contextMenu` or `NSMenu.popUp`?** Recommend spike `.contextMenu`
   first; fall back to `NSMenu` (proven on the status bar) if the
   non-activating-panel behavior is wrong. Decide before Step 1.
3. **Token-parameterized action family — where?** Recommend a `WMController`
   extension (or `WindowActionHandler` methods) that the focused-window wrappers
   *and* the right-click path *and* the Overview all call. Co-design with #8/#2.
   Confirm the split: `toggleWindowFloating(token:)`,
   `assignWindowToScratchpad(token:)`, `closeWindow(token:)` (lift from
   Overview), `moveWindow(token:toWorkspace:)` (already exists).
4. **Menu item set v1?** Recommend, for a **window icon**: *Toggle Floating,
   Assign to Scratchpad / Unassign, Move to Workspace ▸, Close*. Defer
   *Toggle Fullscreen* (blocked by layout-vs-focus). For the **scratchpad pill**:
   *Toggle Visible, Unassign, Focus*. For a **workspace label**: *Focus,
   Move Workspace to Monitor ▸* (backlog #16). Confirm or trim.
5. **Should right-click also focus the target window first?** Some WMs focus the
   right-clicked window so subsequent keyboard input targets it. Recommend
   **no** for v1 (act on the token, leave focus alone) to avoid surprise; revisit
   if users expect menu-as-focus.
6. **Multi-window app pills.** A window icon with `windowCount > 1` opens a
   `WindowListSheet` on left-click (`WindowIconView` `:548-610`). Should
   right-click open the per-window menu for the *group* (acting on the focused
   window of that app), or also surface the window list? Recommend: right-click
   on a multi-window pill acts on that app's focused window and offers a
   "Windows…" item that opens the existing sheet.
7. **Settings gating.** Should right-click menus be behind a setting
   (e.g. `workspaceBarRightClickActions`), or always on? Recommend always on for
   v1 (low risk, discoverable via tooltip); add a toggle only if it interferes
   with app-level right-click passthrough (it should not — the panel is Nehir's
   own surface).

---

## Recommendation

**Pursue, scoped to three pill types, with the token-parameterized action
refactor landed as a shared prerequisite with #8 and #2.** This is a real
mouse-affordance gap (the only bar with right-click today is the status bar, and
it just duplicates left-click), the plumbing seam already exists, and the
Overview proves token-targeted actions are feasible in-tree.

Concrete plan, in order:

1. **Land token-parameterized actions** in `WMController`/`WindowActionHandler`:
   `toggleWindowFloating(token:)`, `assignWindowToScratchpad(token:)`,
   `closeWindow(token:)` (lifted from the Overview's private
   `closeWindowFromOverview`), and reuse the existing
   `moveWindow(handle:toWorkspaceId:)`. Refactor the focused-window wrappers to
   call these. **Do this jointly with #8** (which needs the same split to fix
   the target-window defect) and expose the same family to **#2**'s
   modifier-click move. One refactor, three ideas.
2. **Spike the menu mechanism** (Step 1) on a single pill (window icon). Confirm
   `.contextMenu` behaves on the non-activating panel; fall back to
   `NSMenu.popUp` if not.
3. **Wire right-click closures** through `WorkspaceBarView` →
   `WorkspaceBarManager.createBarForMonitor` (`:222-237`) → the new controller
   entry points. Ship the v1 item set (Open question 4) on **window icons,
   scratchpad pill, and workspace labels**.
4. **Discoverability**: update the per-pill `.help(...)` tooltips (`:396,510,610`)
   to mention right-click; add a one-line hint in `WorkspaceBarSettingsTab`.
5. **Defer**: fullscreen / column / sizing items (blocked by the layout-vs-focus
   decision in #8); menus on the three trailing action buttons; any new
   window-management behavior.

**Do not** pursue: inventing new close/move/float semantics (belong to #8 and
the existing catalog), making the menu the primary interaction (Nehir is
keyboard-first; this is a secondary affordance), or silently focusing the
right-clicked window.

**Effort / risk:** medium. The menu UI is small; the cost is the
token-parameterized action family (shared, so amortized across #8/#2) and the
`.contextMenu`-on-non-activating-panel spike. The highest-value, lowest-risk
slice is the **window-icon menu with float/scratchpad/close/move** — it directly
addresses the "act on a specific window without a hotkey" need and exercises the
entire pipeline end to end.
