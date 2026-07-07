# Command palette: fallback to all sources if no results, or use all sources by default

Groom 2026-07-07: resolved (partial) — Variant A (fallback on empty) landed on main `1aa518bc`; Variant B (unified `.all` tab) remains deferred; see `completed/20260621-command-palette-fallback-all-sources.md`.

Source: handwritten backlog list captured 2026-06-21, idea **#4** — *"Command
palette: fallback to all sources if no results, or use all sources by default."*
Triage doc for that idea. See `planned/20260621-backlog-brainstorm.md` for the
full raw list.

All source/line references were verified against the main Nehir source tree at
`56573ba2` ("Fix focus-follows-mouse blocked by click-through overlays (#64)")
on 2026-06-21. Re-verify before implementing; line numbers drift.

This is a discovery document. No source was modified.

**Outcome (2026-06-22):** the recommended **Variant A (fallback on empty)**
shipped in main source commit `1aa518bc`; see
`completed/20260621-command-palette-fallback-all-sources.md`. **Variant B**
(unified `.all` tab / unified-by-default) remains a deferred opt-in follow-up
contingent on A feedback; the Recommendation and Open Questions below are
otherwise resolved as written.

---

## TL;DR

- The Nehir command palette is **mode-segmented**: it has three sources —
  **Windows** (`⌘1`), **Menu** (`⌘2`, frontmost-app menus), and **Commands**
  (`⌘3`) — and at any moment the search field filters **only the currently
  selected mode**. The two other sources are not consulted.
- The consequence is a real dead-end: type a query that matches nothing in the
  active mode and you get a flat "No windows found / No menu items found / No
  commands found" empty state. The match you wanted may exist one tab over, but
  nothing tells you so and nothing searches across tabs for you.
- The idea has two flavors, both implementable on top of the existing types:
  - **Variant A — fallback on empty:** when the active mode yields zero hits for
    a non-empty query, also surface matches from the other available sources
    (grouped, secondary). Preserves the per-mode mental model; cheap for the
    window↔command pair; the only real cost is the already-lazy, async menu
    source.
  - **Variant B — all sources by default:** a unified list that searches every
    source at once (either as a new opt-in 4th tab, or by replacing the default
    mode). More invasive; changes the core interaction and the persisted
  `commandPaletteLastMode`.
- **Recommendation: pursue Variant A (fallback) now; treat Variant B only as an
  opt-in `.all`/`.unified` mode if the fallback lands and users still want a
  true unified view.** Do not make unified-by-default the new default — the
  existing segmented model is deliberate and users have `⌘1`/`⌘2`/`⌘3`
  muscle memory for it. The two ideas compound with backlog **#11 (fuzzy
  search)** and should be designed together, but ship independently.

---

## Prior work (do not duplicate)

Checked `discovery/`, `planned/`, `completed/`, `noop/`. Related, but **not**
this idea:

- `discovery/20260619-nehir-48-command-palette-hotkey-conflict.md` — the
  palette's *global hotkey* (`Option+Command+Space`, `openCommandPalette`) and a
  diagnostics ask for registration conflicts. Touches the same controller but is
  about hotkey registration, not about *which sources the search consults*.
- `discovery/20260619-choru-leader-palette.md` — a *fourth* palette mode
  (`.leader`, a mnemonic single-key command tree) on the `choru-k` fork. Relevant
  only as precedent that `CommandPaletteMode` can grow a new case and that the
  mode picker / shortcuts extend cleanly (`⌘4` there). It is a *different
  source*, not a cross-source search.
- `planned/20260621-backlog-brainstorm.md` **#11** — *"Fuzzy search in the
  command palette."* Complementary, not overlapping: #11 is *how* each source
  matches (today it is plain substring `contains`); this idea is *which* sources
  are searched. A unified/all-sources view (this idea) is the place fuzzy ranking
  pays off most, so the two should be co-designed but can ship independently.
- `planned/20260621-backlog-brainstorm.md` **#9** — *"Assign hotkey for an action
  from the command palette."* Operates on the Commands source; unrelated to
  cross-source search.

Nothing in the repo implements an "all"/"unified"/"fallback" search today — a
grep of `Sources/Nehir/UI/CommandPalette/` and `Sources/Nehir/Core/CommandPaletteMode.swift`
for `.all`, `allSources`, `unified`, `allResults`, `fallback` returns nothing.

---

## What the idea means for Nehir

The palette is Nehir's keyboard launcher: one field that today searches exactly
one of three sources at a time. The idea is to stop making the user guess which
tab their target lives in. Concretely, it is about removing two failure modes:

1. **Silent empty state across known-good sources.** You are in Windows mode and
   type the name of a command ("float", "scratchpad", "zoom") — you see "No
   windows found" and may conclude the palette can't do it, when it is in fact a
   `⌘3` away. The same happens in reverse (a window title typed while in
   Commands mode).
2. **No way to answer "where does X live?"** There is no view that shows, for a
   single query, all matches across windows + menus + commands.

Variant A fixes (1) without adding a tab. Variant B fixes (2) by adding a tab
(or by changing the default). Both are scope-limited to the palette controller
and its view; neither touches the WM engine, hotkey registration, or config
files.

---

## Current behavior (with source citations)

All citations are `Sources/Nehir/UI/CommandPalette/CommandPaletteController.swift`
unless noted.

### Three sources, one active at a time

`Sources/Nehir/Core/CommandPaletteMode.swift:9-19` defines exactly three cases —
`windows`, `menu`, `commands` — each with a display name and a `⌘N` shortcut.
The controller holds one active mode:

```swift
// CommandPaletteController.swift:164
@Published var selectedMode: CommandPaletteMode = .windows {
    didSet { handleModeChange(from: oldValue) }
}
```

The active mode is persisted across launches as a raw-value string in
runtime state and re-read on show:

```swift
// CommandPaletteController.swift:284-285
let preferredMode = wmController.settings.commandPaletteLastMode
selectedMode = resolvedInitialMode(preferredMode)
```

`resolvedInitialMode` (`:387`) falls back to `.windows` when the preferred mode
is unavailable (menu needs a live frontmost-app target). Persistence lives in
`Sources/Nehir/Core/Config/RuntimeStateStore.swift:13` (`commandPaletteLastMode:
String?`), decoded at `:86-89` via `CommandPaletteMode.init(rawValue:) ?? default`,
so an **unknown** raw value (e.g. a future `"all"`) already degrades gracefully
to `.windows` on older builds — adding a case is forward/backward-compatible.

### The search field filters the active mode only

There is a single shared query:

```swift
// CommandPaletteController.swift:160
@Published var searchText = "" {
    didSet { updateSelectionAfterFilterChange() }
}
```

…and three computed, mode-specific filtered lists, each calling its own matcher
against that same `searchText`:

```swift
// CommandPaletteController.swift:221-231
var filteredWindowItems: [CommandPaletteWindowItem] {
    filterWindowItems(windows, query: searchText)
}
var filteredMenuItems: [MenuItemModel] {
    filterMenuItems(menuItems, query: searchText)
}
var filteredCommandItems: [CommandPaletteCommandItem] {
    filterCommandItems(commandItems, query: searchText)
}
```

The view renders **only** the active mode's list:

```swift
// CommandPaletteController.swift:1113-1148 (inside CommandPaletteView.body)
switch controller.selectedMode {
case .windows:  ForEach(controller.filteredWindowItems)  { ... }
case .menu:     ForEach(controller.filteredMenuItems)     { ... }
case .commands: ForEach(controller.filteredCommandItems)  { ... }
}
```

There is no code path that consults a second source from within a mode.

### Empty matches produce a flat dead-end, not a hint

When the active mode's filtered list is empty, the view swaps in an empty state:

```swift
// CommandPaletteController.swift:1193-1203
private var isEmptyStateVisible: Bool {
    switch controller.selectedMode {
    case .windows:
        controller.filteredWindowItems.isEmpty
    case .menu:
        !controller.isMenuLoading &&
            (!controller.isMenuModeAvailable || controller.filteredMenuItems.isEmpty)
    case .commands:
        controller.filteredCommandItems.isEmpty
    }
}

// CommandPaletteController.swift:1216-1228
private var emptyStateText: String {
    switch controller.selectedMode {
    case .windows:
        return controller.searchText.isEmpty ? "No windows available" : "No windows found"
    case .menu:
        if !controller.isMenuModeAvailable { return controller.menuStatusText }
        return controller.searchText.isEmpty ? "No menu items available" : "No menu items found"
    case .commands:
        return controller.searchText.isEmpty ? "No commands available" : "No commands found"
    }
}
```

So a non-empty query that matches nothing in the active mode renders "No windows
found" (etc.) and stops. This is exactly the dead-end Variant A targets.

### The three matchers are independent and score-incompatibly

Each source has its own scorer, and the score scales are not comparable across
sources:

- `filterWindowItems` (`:402`) — substring in `title` scores `pos`, substring in
  `appName` scores `1000 + pos`. Plain `lowercased()` only.
- `filterMenuItems` (`:438`) — substring in `title` scores `pos`, substring in
  `fullPath` scores `1000 + pos`. Plain `lowercased()` only.
- `filterCommandItems` (`:471`) — substring in each of `item.searchTerms` scores
  `termIndex * 10000 + pos`, **and** the term is normalized via
  `ActionCatalog.normalizedSearchTerm`
  (`Sources/Nehir/Core/Input/ActionCatalog.swift:133-139`: lowercase, `. - _ →
  space`, trim). The query is normalized the same way before matching.

Implication for a unified/all list: you cannot just merge the three scored
arrays and sort by score — a `1000+pos` window hit and a `termIndex*10000+pos`
command hit are not on the same scale. The clean answer is **group-by-source**
(keep each source's internal ordering, show sections), which avoids needing a
cross-source relevance function entirely. (Cross-source ranking is also where
backlog #11 fuzzy search would naturally live.)

### Mode switching is keyboard- and picker-driven

`⌘1`/`⌘2`/`⌘3` switch modes via `handleModeShortcut`:

```swift
// CommandPaletteController.swift:803-815
private func handleModeShortcut(_ characters: String) -> Bool {
    switch characters {
    case "1": selectedMode = .windows; return true
    case "2":
        guard isMenuModeAvailable else { return false }
        selectedMode = .menu; return true
    case "3": selectedMode = .commands; return true
    default:  return false
    }
}
```

The `CommandPaletteModePicker` segmented control
(`CommandPaletteController.swift:1231-1300`) mirrors this, disabling the Menu
button when `!isMenuModeAvailable`. Any new mode (e.g. an opt-in `.all`) needs
both a `⌘N` slot and a picker button.

### Selection and dispatch are already source-tagged (good news)

Navigation and dispatch key off a flat per-mode list today:

```swift
// CommandPaletteController.swift:922-930
private func currentSelectionList() -> [CommandPaletteSelectionID] {
    switch selectedMode {
    case .windows: return filteredWindowItems.map { .window($0.id) }
    case .menu:    return filteredMenuItems.map    { .menu($0.id) }
    case .commands:return filteredCommandItems.map { .command($0.id) }
    }
}
```

…but the selection ID itself is **already a tagged union by source**
(`CommandPaletteController.swift:57-60`):

```swift
enum CommandPaletteSelectionID: Hashable {
    case window(WindowToken)
    case menu(UUID)
    case command(String)
}
```

…and `resolvedSelectionAction(for:)` (`:858-894`) switches on `selectedMode` to
build the action. This means a cross-source list is structurally easy to
**select** (the IDs are source-tagged), but `resolvedSelectionAction` would need
to switch on **the selection's source** rather than `selectedMode` so an item
from a non-active source can still dispatch. That is the single most important
refactor for either variant.

### Menu is the only lazy / async / costly source

Window and command items are built synchronously in `show()`:

```swift
// CommandPaletteController.swift:268-271
windows = buildWindowItems(from: wmController)      // reads workspaceManager + cached appInfo
commandItems = buildCommandItems(from: wmController) // ActionCatalog.allSpecs()
menuItems = []
hasLoadedMenuItems = false
```

Both are cheap. Menu items are fetched lazily, only when Menu is selected, and
asynchronously (AX menu enumeration can block), with a generation guard:

```swift
// CommandPaletteController.swift:649-688
private func loadMenuItemsIfNeeded() {
    guard isVisible, selectedMode == .menu else { return }   // :650
    guard isMenuModeAvailable else { menuItems = []; isMenuLoading = false; return } // :651-654
    ...
    isMenuLoading = true                                      // :668
    DispatchQueue.main.async { ... self.menuItems = items; self.isMenuLoading = false } // :678-686
}
```

So: **window↔command fallback is essentially free; involving menu is the only
costly path**, because menu items are not even loaded unless the user is in Menu
mode. Any cross-source feature that wants to show menu hits from another mode
must either eagerly kick off the menu fetch in `show()` (extra AX cost on every
open) or accept "menu results pending" until the async load lands.

---

## Where / how it would be implemented

All in `Sources/Nehir/UI/CommandPalette/CommandPaletteController.swift` plus
`Sources/Nehir/Core/CommandPaletteMode.swift`. No engine, config-file, or
hotkey-registration changes required.

### Variant A — fallback on empty (recommended)

1. **Detection.** Add a computed property on the controller, e.g.
   `fallbackSections: [(source: CommandPaletteMode, items: …)]`, built only when
   the active mode's filtered list is empty **and** `searchText` is non-empty.
   It runs each available source's existing matcher
   (`filterWindowItems`/`filterMenuItems`/`filterCommandItems`) and keeps any
   non-empty section. Reuse the existing scorers verbatim — do not invent a
   cross-source score (see "score-incompatibly" above); section ordering is fixed
   (e.g. windows → commands → menu) so there is nothing to sort across.
2. **Menu handling.** Because `loadMenuItemsIfNeeded()` (`:649`) guards on
   `selectedMode == .menu`, menu items are normally absent outside Menu mode.
   Two options: (a) drop the `selectedMode == .menu` guard when called from the
   fallback path so menu is fetched on demand for a fallback search, or (b)
   include menu in the fallback **only when already loaded** and show a
   "Searching menus…" inline affordance otherwise. Option (b) is cheaper and
   safer; option (a) is more complete at the cost of AX latency on empty queries.
3. **Dispatch.** Generalize `resolvedSelectionAction(for:)` (`:858`) so it
   resolves from the **selection's source tag** (`CommandPaletteSelectionID`),
   not from `selectedMode`. The ID union already carries the source, so a
   fallback item from Commands resolves to `.executeCommand` even when the user
   is in Windows mode.
4. **Navigation.** `currentSelectionList()` (`:922`) and `moveSelection(by:)`
   (`:720`) currently build a single flat list per mode. For the fallback, build
   the list as `activeList + fallbackSections.flattened` (or, when the active
   list is empty, just the flattened fallback). `updateSelectionAfterFilterChange`
   (`:933`) already clamps/advances the selection within whatever list it is
   given, so it needs no change beyond pointing at the combined list.
5. **View.** In `CommandPaletteView.body`, the empty-state branch
   (`isEmptyStateVisible`, `:1193`) is where the fallback UI goes: when the
   active list is empty but `searchText` is non-empty **and** at least one
   fallback section is non-empty, render a sectioned list (small source header +
   the existing `CommandPaletteWindowRow`/`CommandPaletteMenuRow`/
   `CommandPaletteCommandRow`) instead of `CommandPaletteEmptyStateView`. Only
   when all sources are empty do we show the true "No results anywhere" empty
   state.
6. **Tests.** `Tests/NehirTests/CommandPaletteControllerTests.swift` already
   exercises per-mode filtering, `filteredWindowItems`, mode switching, and
   availability fallback (`persistedMenuModeFallsBackToWindowsWhenUnavailable`,
   `:517`). Add: (a) a non-empty query with zero window hits but ≥1 command hit
   yields a fallback section containing the command and `selectCurrent` dispatches
   `.executeCommand` from Windows mode; (b) when **all** sources are empty, the
   fallback is empty and the empty state still shows; (c) menu is omitted from
   the fallback when `isMenuModeAvailable == false`.

### Variant B — all sources by default (opt-in mode, if pursued)

1. **New mode.** Add `case all` (or `unified`) to
   `Sources/Nehir/Core/CommandPaletteMode.swift` with a display name and a
   `⌘4` shortcut (precedent: the `choru` leader palette used `⌘4` — see
   `discovery/20260619-choru-leader-palette.md`). The picker
   (`CommandPaletteController.swift:1231`) iterates `CommandPaletteMode.allCases`
   so it picks the new tab up automatically; add `⌘4` in `handleModeShortcut`
   (`:803`).
2. **Eager menu load.** `.all` needs menu items even though the user is not in
   Menu mode, so `loadMenuItemsIfNeeded()` (`:649`) must drop its
   `selectedMode == .menu` guard for this mode (or always). Show a
   `CommandPaletteLoadingView`-style section while `isMenuLoading`.
3. **Unified list.** Provide `var filteredAllItems: [(CommandPaletteMode, …)]`
   (or a small `struct CommandPaletteAnyItem` wrapping a source + the underlying
   item) that concatenates the three existing filtered lists, **grouped by
   source** (no cross-source sort — see the score-incompatibility note). Update
   `currentSelectionList()` (`:922`), `updateSelectionAfterFilterChange` (`:933`),
   `moveSelection(by:)` (`:720`), `resolvedSelectionAction(for:)` (`:858`), and
   the view's `switch controller.selectedMode` (`:1113`) to handle `.all`.
4. **Dispatch.** Same generalized `resolvedSelectionAction` as Variant A step 3
   — resolve from the source-tagged `CommandPaletteSelectionID`, not from
   `selectedMode`.
5. **Default vs. opt-in.** Recommend **opt-in**: do **not** change
   `RuntimeStateStore.defaultCommandPaletteLastMode` (currently `.windows`,
   `Sources/Nehir/Core/Config/RuntimeStateStore.swift:20`). Let users who want
   unified set it once (`commandPaletteLastMode` persists). A setting toggle is
   optional; the mode picker is enough. Making `.all` the default would silently
   change every existing user's palette and add AX menu-fetch cost on every open.

---

## Risks and unknowns

1. **Menu-source latency / cost.** Menu items are fetched async precisely
   because AX menu enumeration can block
   (`loadMenuItemsIfNeeded`, `:649-688`). Any cross-source feature that pulls
   menu in eagerly (Variant B, or Variant A option (a)) adds that cost to every
   palette open even for window/command-only queries. Variant A option (b)
   (include menu only when already loaded) avoids this at the cost of
   completeness. **Unknown:** how slow is `MenuAnywhereFetcher().fetchMenuItemsSync`
   in practice for large apps — needs a measurement before picking (a) vs (b).
2. **Score comparability.** The three matchers use incompatible score scales
   (`pos`/`1000+pos` for windows & menus; `termIndex*10000+pos` for commands,
   plus normalization). A merged-and-sorted unified list would require a new
   cross-source relevance function. **Mitigation:** group by source; never sort
   across sources. This sidesteps the problem and is also the conventional UX
   for multi-source launchers.
3. **Empty-state semantics change.** Today `isEmptyStateVisible` (`:1193`) means
   "active mode empty." With fallback, the true empty state should mean "all
   sources empty." Getting this right matters for the `No X found` copy and for
   not flashing the empty state while menu is still loading.
4. **Dispatch decoupling.** `resolvedSelectionAction(for:)` (`:858`) currently
   switches on `selectedMode`. Both variants require it to switch on the
   selection's source instead. Low risk (the ID is already a tagged union), but
   it is the one behavioral change that touches the dispatch path and must be
   covered by tests for each source-while-not-in-that-mode.
5. **Mode-picker / shortcut crowding.** Adding `.all` as a 4th tab pushes the
   picker to four buttons in a 620pt-wide panel (`createPanel`,
   `CommandPaletteController.swift:986`) and consumes `⌘4`. Acceptable, but worth
   a visual check; the choru leader palette already used `⌘4` so there is
   precedent and no hard conflict on main.
6. **Persistence forward-compat is fine.** `commandPaletteLastMode` is a
   `String?` decoded with `?? default` (`RuntimeStateStore.swift:86-89`), so an
   unknown raw value on an older build falls back to `.windows`. No migration
   needed for a new case.
7. **Interaction with backlog #11 (fuzzy search).** If fuzzy ranking lands, the
   "group by source, don't cross-sort" mitigation in (2) should be revisited — a
   good fuzzy score is exactly the cross-source relevance signal a unified list
   wants. Design the two together; ship independently.

---

## Open questions

1. **Fallback UX shape.** When the active mode is empty, should the palette
   (a) keep the active tab selected and show a secondary "Also in other sources"
   section, or (b) auto-jump the selected tab to the first source with hits?
   (a) is less surprising and preserves `⌘1/⌘2/⌘3` context; (b) is faster but
   moves the user's cursor unexpectedly. Recommendation: (a).
2. **Menu in fallback when unavailable.** Confirm menu is excluded from fallback
   whenever `isMenuModeAvailable == false` (no frontmost-app target). It must be
   — there can be no menu results then.
3. **Does Variant B ship at all?** Or does Variant A make the unified tab
   unnecessary for most users? Decide after A lands and gets feedback.
4. **Unified default?** If B ships, is `.all` the new default for new installs
   only (keep existing users on their persisted mode), or for everyone? Strong
   lean: never override a persisted mode; at most default new installs to `.all`
   if telemetry/feedback supports it.
5. **Section caps.** In a grouped fallback/unified list, should each source
   section be capped (e.g. top 5) to keep the 430pt panel usable? Today each mode
   shows all hits in a scroll view; grouping three full lists may need per-section
   truncation.

---

## Recommendation

**Pursue Variant A (fallback on empty). Defer Variant B (unified-by-default) to
an opt-in `.all` mode, contingent on A shipping and user feedback.**

Why:

- Variant A fixes the concrete, reported-feeling dead-end ("No windows found"
  while the answer is a `⌘3` away) with **no change to the default UX**, no new
  tab, no new shortcut, and no eager menu fetch. The window↔command path is
  free; menu can be included lazily. It is low-risk, localized to the palette
  controller and its view, and testable with the existing test harness.
- Variant B is the more powerful but more invasive option. It should exist as an
  **opt-in** mode (new `case all` + `⌘4` + picker button), **not** as the new
  default — the segmented model is deliberate, users have `⌘1/⌘2/⌘3` muscle
  memory, and making `.all` default would silently change every user's palette
  and add AX cost on every open. Let users who want unified turn it on once.
- The two ideas are best **co-designed** with backlog **#11 (fuzzy search)**:
   a cross-source list is where fuzzy ranking earns its keep, and the
   "don't cross-sort, group by source" mitigation in this doc is exactly what
   fuzzy scores would later replace. They remain independently shippable.
- Net: A is a clear `planned/` candidate (small, scoped, owner-friendly). B is a
  `planned/` candidate only as an opt-in mode, sized medium, and ideally sequenced
  after A and alongside #11.

Sizing hint: Variant A is roughly one controller property + one generalized
dispatch switch + one view branch + 2-3 tests. Variant B adds one enum case,
`⌘4`, eager-menu policy, and a unified-list view section.
