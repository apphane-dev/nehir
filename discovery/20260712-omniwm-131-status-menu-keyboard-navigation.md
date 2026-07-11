# BarutSRB/OmniWM#131 — Status-bar menu cannot be navigated with the keyboard — Discovery

Source issue: <https://github.com/BarutSRB/OmniWM/issues/131> (closed
`not planned` in upstream's 2026-05-05 cleanup sweep; regroomed via
`20260712-omniwm-cleanup-sweep-20260505-regroom.md`).

**Status:** open — reproduces in Nehir; subject to fix.

All file/line references verified against the main Nehir source tree at
`0b9a1560` on 2026-07-12. Re-verify before implementing; line numbers drift.

## TL;DR

- **Nehir reproduces the upstream symptom in full: the status-bar menu has no
  keyboard interaction at all.** Most macOS apps' status menus support
  arrow-key navigation (standard `NSMenu` behavior); some support at least Tab
  traversal; Nehir's menu supports neither.
- The cause is structural: **every row in the menu is a custom-view
  `NSMenuItem`**, and AppKit's built-in menu keyboard loop (arrow keys,
  type-select, Return, Space) skips items that have a custom `view` — they are
  never highlighted and never receive key-driven activation.
- Interaction is implemented exclusively as mouse events on the custom views
  (`mouseDown` for toggles, `mouseUp` for action rows), so there is no
  keyboard-reachable code path and no accessibility action either.

## Evidence (code)

Every item in `buildMenu()` gets a custom view instead of a standard
title/action item (`Sources/Nehir/UI/StatusBar/StatusBarMenu.swift`):

- header `headerItem.view = createHeaderView()` (`:58`)
- dividers/section labels `item.view = MenuDividerView()` / `MenuSectionLabelView` (`:99`, `:105`)
- toggles `focusItem.view = focusToggle`, `bordersItem.view = bordersToggle`,
  `workspaceItem.view = workspaceBarToggle`, `debugBarItem.view = debugBarToggle`
  (`:120`, `:133`, `:146`, `:160`)
- info/diagnostics rows (`:180`, `:200`, `:211`)
- action rows: Settings (`:267`), What's New (`:278`), Reset (`:304`),
  Restart (`:323`), Quit (`:336`)

None of these `NSMenuItem`s carries a `target`/`action` or `keyEquivalent`;
activation lives only in the views' mouse handlers:

- `MenuToggleSwitchView.mouseDown` flips the switch (`StatusBarMenu.swift:529`
  → `onToggle` at `:455`, wired through `MenuToggleRowView` at `:612`).
- `MenuActionRowView.mouseUp` fires the row action (`:778`).

AppKit's `NSMenu` keyboard handling (Up/Down highlight, Return/Space to
activate, Escape to close, type-select) operates only on items it draws
itself. A custom-view item is rendered and hit-tested by the view, so the menu
never highlights it and never routes key events to it. With **all** items
custom-view, the menu is keyboard-dead: upstream's exact report ("Tab should
select Focus Follows Mouse", "up/down arrows should move between items",
"Space should toggle", "Enter should open Settings", "Escape should close" —
only Escape works, because that is window-level).

## Expected behavior (acceptance)

Match standard macOS menus, not just upstream's ask:

1. Up/Down arrows move a visible highlight across interactive rows (toggles,
   action rows), skipping headers, dividers, section labels, and info rows.
2. Return activates the highlighted row (open Settings / fire action);
   Space toggles a highlighted toggle row.
3. Escape closes the menu (already works; must keep working).
4. VoiceOver: rows expose proper accessibility roles/actions (a keyboard fix
   via accessibility actions gets much of this for free; a raw keyDown fix
   does not — prefer the former or do both).

## Fix directions (not prescriptive; pick at plan time)

- **A. Revert simple rows to standard `NSMenuItem`s.** Settings / What's New /
  Reset / Restart / Quit are plain label+icon rows; standard items (title,
  `image`, target/action) restore arrow navigation, Return, and type-select
  for free. Toggles could become standard items with `state = .on/.off`
  (checkmark) at some visual cost. Cheapest and most robust; loses the custom
  switch visuals unless mixed with B.
- **B. Keep custom views, add keyboard/highlight machinery.** Track a
  highlighted index in `StatusBarMenu`, render highlight state in the row
  views, and handle keyDown via the menu window / a local event monitor;
  expose `NSAccessibilityButton`/`NSAccessibilitySwitch` roles with `press`
  actions on the row views. More work, preserves current visuals.
- **C. Hybrid (likely right):** standard items for action rows (A), custom
  views only for the toggle rows with accessibility actions + highlight
  support (B-lite).

## Non-goals

- No change to menu contents or layout beyond what highlight rendering needs.
- The Escape behavior and mouse interaction must remain unchanged.
