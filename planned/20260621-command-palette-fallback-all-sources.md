# Command palette: fallback to all sources if no results

**Status:** planned (Variant A — fallback on empty; Variant B deferred, see Follow-ups)
**Source discovery:** `discovery/20260621-command-palette-fallback-all-sources.md`
**Related:** `planned/20260621-backlog-brainstorm.md` (idea **#4**; co-design with **#11**
fuzzy search and coordinate chord choice with **#9** assign-hotkey-from-palette),
`planned/20260621-assign-hotkey-from-command-palette.md` (shares the palette
controller + its `Tab`/`⌘N` chord budget), `discovery/20260619-choru-leader-palette.md`
(precedent that `CommandPaletteMode` + picker extend cleanly).

All source references were re-verified against the main Nehir source tree at
`42ac731f` ("Prevent stale async session patches from overwriting newer selection
(M6)") on 2026-06-22. The tree has advanced past the discovery's `56573ba2`;
several line numbers drifted and are corrected below. Re-verify before editing;
line numbers drift.

## TL;DR

The command palette is mode-segmented: `⌘1` Windows, `⌘2` Menu, `⌘3` Commands,
and at any moment the search field filters **only** the active mode
(`CommandPaletteController.swift:1113` switches the view on `selectedMode`;
`resolvedSelectionAction` at `:820` resolves only within the active mode). Type a
non-empty query that matches nothing in the active mode and you hit a flat dead-end
— "No windows found" / "No menu items found" / "No commands found"
(`emptyStateText`, `:1216`) — even when the match exists one tab over.

This plan delivers the discovery's **Variant A — fallback on empty**: when the
active mode's filtered list is empty **and** `searchText` is non-empty, surface
the other available sources' matches as a sectioned "Also in other sources" list
under the same query, and let the user select/dispatch across sources without
switching tabs. Window↔Command fallback is free (both sources are built
synchronously in `show()` at `:266-271`); Menu is included only when already
loaded (lazy/async, `loadMenuItemsIfNeeded` `:649`), so the fallback adds **no
eager AX cost**. No new tab, no new shortcut, no default-UX change, no
persistence change.

The single behavioral refactor that enables both cross-source selection and
cross-source dispatch: generalize `resolvedSelectionAction(for:)` (`:820`) to
resolve from the **selection's source tag** (`CommandPaletteSelectionID`,
`:57`) instead of from `selectedMode`. The ID union is already source-tagged, and
`performSelectionAction(_:)` (`:894`) already dispatches source-agnostically off
the `SelectionAction` enum, so only `resolvedSelectionAction` changes.

Variant B (a true unified `.all` tab) is explicitly **out of scope** and deferred
to a follow-up contingent on A shipping and user feedback (see Follow-ups).

## Discovery corrections / decisions

The discovery recommendation is right at the product level (do A now, defer B as
opt-in). Corrections made while porting to the current tree (`42ac731f`):

1. **`⌘N` shortcut labels are NOT in `CommandPaletteMode.swift`.** The discovery
   says `CommandPaletteMode.swift:9-19` defines each case "with a display name
   and a `⌘N` shortcut." Verified: `CommandPaletteMode.swift` carries only the
   three cases (`:9-12`) and `displayName` (`:14-20`) — **no shortcut**. The
   `⌘1`/`⌘2`/`⌘3` *labels* come from `CommandPaletteController.modeHint(for:)`
   (`:310-318`), and the *bindings* come from `handleModeShortcut` (`:803`).
   This matters for the deferred Variant B: adding a `.all` case requires edits
   in three places (enum + `modeHint` + `handleModeShortcut` + view branches),
   not one. It does not affect Variant A.
2. **`resolvedSelectionAction` line drift.** Discovery cites `:858-894`;
   verified signature is `:820`, body `:820-857`. The actual dispatch executor
   `performSelectionAction(_:)` is at `:894` and switches on the `SelectionAction`
   enum — it is **already source-agnostic and needs no change**. Only
   `resolvedSelectionAction` is generalized.
3. **`moveSelection(by:)` line drift.** Discovery cites `:720`; verified `:751`.
   `selectCurrent(trigger:)` (which calls `resolvedSelectionAction` then
   `performSelectionAction`) is at `:767`.
4. **`createPanel` / panel-size line drift.** Discovery cites `createPanel`
   `:986` for the "620pt-wide panel"; verified `createPanel` is at `:947`, and
   the `.frame(width: 620, height: 430)` lives in the SwiftUI body at `:1163`.
   The 620×430 numbers themselves are correct.
5. **Menu async completion re-checks the mode.** `loadMenuItemsIfNeeded` (`:649`)
   guards entry on `selectedMode == .menu` (`:650`) **and** its async completion
   re-checks `self.selectedMode == .menu` (`:677`) before committing results.
   Decision: Variant A uses the discovery's **option (b)** — include Menu in the
   fallback **only when already loaded**. This avoids touching either guard and
   avoids any eager AX cost. Option (a) (relax the guard to fetch menu on demand
   for a fallback search) would require editing **both** `:650` and `:677` and
   adds menu-enumeration latency to empty queries; it is a follow-up, not v1.
6. **No `setCommandItemsForTests` harness exists today.** Verified: the test
   seam block (`:1010-1058`) exposes `setWindowSelectionStateForTests`,
   `setMenuAvailabilityForTests`, `setMenuLoadingStateForTests`,
   `loadMenuItemsForTests`, `handleModeShortcutForTests`,
   `selectionTriggerForTests`, `panelForTests` — but **no** command-item or
   fallback injector. Because `commandItems` is private and populated only via
   `show()` → `buildCommandItems` (`:498`), the plan adds a small
   `setCommandItemsForTests`/`setFallbackStateForTests` helper (Scope step 4).
7. **Score-incompatibility stands; group, do not cross-sort.** Re-verified the
   three scorer scales are not comparable: windows/menus use `pos` and
   `1000+pos` (`:402`, `:438`); commands use `i * 10000 + pos` on
   `ActionCatalog.normalizedSearchTerm`-normalized terms (`:471`, normalization
   at `ActionCatalog.swift:133-139`). The fallback keeps each source's internal
   ordering and renders fixed-order sections (windows → commands → menu); there
   is no cross-source relevance function in v1.
8. **Persistence forward-compat is fine, unchanged.** `commandPaletteLastMode`
   is a `String?` decoded with `?? defaultCommandPaletteLastMode`
   (`RuntimeStateStore.swift:13`, `:20`, `:86-89`). Variant A adds no new mode,
   so there is nothing to migrate and `defaultCommandPaletteLastMode` stays
   `.windows`.

## Scope

### Files to add/change

1. `Sources/Nehir/UI/CommandPalette/CommandPaletteController.swift` (all
   controller + view work; the bulk).
   - **Fallback model.** Add a small value type describing one fallback section,
     e.g. (inside the file, near `CommandPaletteSelectionID` at `:57`):
     ```swift
     struct CommandPaletteFallbackSection: Identifiable, Equatable {
         let source: CommandPaletteMode
         let windowItems: [CommandPaletteWindowItem]
         let menuItems: [MenuItemModel]
         let commandItems: [CommandPaletteCommandItem]
         var id: CommandPaletteMode { source }
         var isEmpty: Bool { windowItems.isEmpty && menuItems.isEmpty && commandItems.isEmpty }
     }
     ```
     Only one of the three item arrays is non-empty per section (the section's
     source decides which); the others stay `[]`. This avoids a sum-type wrapper
     and lets each section reuse the existing row views unchanged.
   - **Fallback builder.** Add a computed property, e.g.
     `var fallbackSections: [CommandPaletteFallbackSection]`, built **only when**
     `searchText.trimmingCharacters(in: .whitespacesAndNewlines)` is non-empty
     **and** the active mode's filtered list is empty. For each available source
     (`windows`, `commands`, always; `menu` only when `isMenuModeAvailable &&
     hasLoadedMenuItems`), run that source's **existing** matcher
     (`filterWindowItems`/`filterMenuItems`/`filterCommandItems`) against the
     same `searchText` and keep the section if non-empty. Fixed section order:
     windows → commands → menu. Reuse the scorers verbatim — do not invent a
     cross-source score (Correction 7).
   - **Active-mode-emptiness helper.** Add `private var activeModeFilteredIsEmpty: Bool`
     factoring the per-mode emptiness check already inlined in
     `isEmptyStateVisible` (`:1193`), so the view, the fallback builder, and the
     empty-state all agree on "active mode is empty".
   - **Generalized dispatch.** Rewrite `resolvedSelectionAction(for:)` (`:820`)
     to resolve from the **selection's source tag**, not from `selectedMode`.
     Concretely, switch on `selectedItemID` (`.window`/`.menu`/`.command`) and,
     within each branch, look the item up in the matching source's filtered list
     — where "matching filtered list" is the **fallback-aware** list: when the
     fallback is active (`fallbackActive`), use the item's source section from
     `fallbackSections`; otherwise use the existing per-mode filtered list
     (`filteredWindowItems`/`filteredMenuItems`/`filteredCommandItems`). This
     keeps the today-path identical when no fallback is active and makes a
     fallback item from e.g. Commands dispatch to `.executeCommand`
     (`performSelectionAction`, `:894`) even while the user is in Windows mode.
     `performSelectionAction` is unchanged.
   - **Selection list.** Update `currentSelectionList()` (`:922`) so that when
     `fallbackActive` is true it returns the flattened fallback IDs
     (`fallbackSections` in order, each section's items mapped to their
     `.window`/`.menu`/`.command` `CommandPaletteSelectionID`); otherwise the
     existing per-mode list. `updateSelectionAfterFilterChange()` (`:933`) and
     `moveSelection(by:)` (`:751`) then need **no change** — they already
     operate on whatever `currentSelectionList()` returns. Initial selection in
     fallback mode: first item of the first non-empty section (mirrors the
     "advance to first" behavior `updateSelectionAfterFilterChange` already
     implements when the current selection vanishes).
   - **`fallbackActive` predicate.** `private var fallbackActive: Bool` —
     `!fallbackSections.isEmpty`. Computed from the builder above; the view and
     dispatch branch on it.
   - **View: replace the dead-end with the fallback list.** In `CommandPaletteView.body`,
     the empty-state branch is at `:1102-1108`
     (`if menu && isMenuLoading { Loading } else if isEmptyStateVisible { EmptyStateView } else { results }`).
     Insert a fallback branch: when `isEmptyStateVisible && controller.fallbackActive`,
     render a sectioned `ScrollView` (reuse `ScrollViewReader` + `LazyVStack`)
     where each `CommandPaletteFallbackSection` is a small header (source
     `displayName`, e.g. "Commands") followed by the section's items rendered
     with the **existing** `CommandPaletteWindowRow`/`CommandPaletteMenuRow`/
     `CommandPaletteCommandRow` (same `.id(...)`/`.onTapGesture { selectCurrent }`
     wiring as the per-mode branches at `:1115`/`:1128`/`:1140`). When
     `isEmptyStateVisible && !controller.fallbackActive`, render the true
     "No results anywhere" empty state (see next bullet). The `.frame(width: 620, height: 430)`
     (`:1163`) is unchanged.
   - **Empty-state copy when fallback exists.** Branch `emptyStateText`
     (`:1216`) and `isEmptyStateVisible` (`:1193`) on `fallbackActive`: the true
     empty state now means "all sources empty for this query." When the active
     mode is empty but `fallbackActive`, do **not** show `CommandPaletteEmptyStateView`
     at all — the fallback list replaces it. When the active mode is empty and
     `!fallbackActive`, keep today's per-mode "No X found" copy (it now correctly
     implies "…in any source").
   - **Footer status text.** In `statusText` (`:1180`), when `controller.fallbackActive`,
     return a hint such as `"No \(activeMode) matches — showing other sources."`
     so the user understands why non-Windows rows appeared in Windows mode.
   - **Test seam.** Add `setCommandItemsForTests(_:wmController:)` and
     `setFallbackStateForTests(wmController:windows:menuItems:commands:selectedMode:selectedItemID:)`
     to the `ForTests` block (`:1010-1058`), mirroring
     `setWindowSelectionStateForTests`. These let tests inject command items
     (otherwise private, built only in `show()` → `buildCommandItems`, `:498`)
     and drive the fallback path without a live AX/menu environment.
2. `Sources/Nehir/Core/CommandPaletteMode.swift` — **no change** in Variant A.
   The three cases, `displayName`, `allCases`, and `Codable` raw-value behavior
   are all reused as-is.
3. `Sources/Nehir/Core/Config/RuntimeStateStore.swift` — **no change**. Variant A
   adds no mode, so `commandPaletteLastMode` (`:13`, `:86-89`) and
   `defaultCommandPaletteLastMode` (`:20`) are untouched.
4. Tests under `Tests/NehirTests/CommandPaletteControllerTests.swift` (see Tests).

### Non-goals

- Do **not** implement Variant B (unified `.all` tab, `⌘4`, eager menu fetch,
  or changing the default mode). That is a follow-up contingent on A shipping.
- Do **not** change the default palette UX, the segmented mental model, or
  users' `⌘1`/`⌘2`/`⌘3` muscle memory. The active tab stays selected; fallback
  is a secondary, below-the-empty-state section, never an auto-jump to another
  tab (discovery Open Question 1 — decision: keep active tab selected).
- Do **not** eagerly fetch menu items on palette open or on empty queries
  (Correction 5). Menu appears in the fallback only when `hasLoadedMenuItems` is
  already true (i.e. the user previously visited Menu mode this session, or the
  `sessionMenuCache` hit path at `:662-666` populated it).
- Do **not** invent a cross-source relevance score or sort across sources
  (Correction 7). Sections keep each source's internal ordering and appear in
  fixed order windows → commands → menu.
- Do **not** change `CommandPaletteMode`, `RuntimeStateStore`, the WM engine,
  hotkey registration, IPC, or any config file/TOML schema.
- Do **not** change per-section caps in v1 (discovery Open Question 5). Each
  section shows all of its (already matcher-filtered) hits in the existing
  scroll view; per-section truncation is a follow-up if grouping three lists
  proves visually heavy.
- Do **not** couple to backlog **#11** (fuzzy search). The fallback reuses
  today's substring scorers verbatim; fuzzy ranking is independently shippable
  and is where a future cross-source score would naturally live.

## Exact implementation plan

### Phase 1 — Fallback model + builder (no UX change yet)

1. Add `CommandPaletteFallbackSection` (Scope step 1) near
   `CommandPaletteSelectionID` (`:57`).
2. Add `private var activeModeFilteredIsEmpty: Bool` factoring the per-mode
   emptiness switch currently inlined in `isEmptyStateVisible` (`:1193`).
3. Add `var fallbackSections: [CommandPaletteFallbackSection]` and
   `var fallbackActive: Bool { !fallbackSections.isEmpty }`. Gate the builder on
   `!searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
   activeModeFilteredIsEmpty`. For windows/commands: always consult
   `filterWindowItems(windows, query: searchText)` /
   `filterCommandItems(commandItems, query: searchText)`. For menu: consult
   `filterMenuItems(menuItems, query: searchText)` **only when**
   `isMenuModeAvailable && hasLoadedMenuItems`. Drop empty sections. Order:
   windows → commands → menu.

### Phase 2 — Generalized dispatch (the load-bearing refactor)

4. Rewrite `resolvedSelectionAction(for:)` (`:820`) to switch on
   `selectedItemID`'s source tag. Within each branch, choose the lookup list:
   - `.window(token)` → `fallbackActive ? section(in: .windows).windowItems : filteredWindowItems`,
     then `first { $0.id == token }`; map to `.navigateWindow` / `.summonWindowRight`
     exactly as today.
   - `.menu(id)` → `fallbackActive ? section(in: .menu).menuItems : filteredMenuItems`;
     map to `.pressMenu` as today (still requires `menuFocusTarget`).
   - `.command(id)` → `fallbackActive ? section(in: .commands).commandItems : filteredCommandItems`;
     map to `.executeCommand` as today.
   Add a small `private func section(in source:) -> CommandPaletteFallbackSection?`
   helper. When `!fallbackActive`, behavior is byte-for-byte today's. Confirm
   `performSelectionAction` (`:894`) needs no edit.
5. Update `currentSelectionList()` (`:922`): when `fallbackActive`, return
   `fallbackSections.flatMap { section in sectionItems(section).map { id($0) } }`
   (where `sectionItems`/`id` pick the right array and tag per `section.source`);
   otherwise the existing per-mode switch unchanged.

### Phase 3 — View: replace the dead-end

6. In `CommandPaletteView.body`, change the empty-state branch (`:1102-1108`)
   to three states: (a) menu loading (unchanged), (b) **fallback list** — when
   `isEmptyStateVisible && controller.fallbackActive`, render the sectioned
   `ScrollViewReader { ScrollView { LazyVStack { ForEach(controller.fallbackSections) { section in ... } } } }`
   with a per-section header (`Text(section.source.displayName)`) + the existing
   row views and `.onTapGesture { controller.selectedItemID = ...; controller.selectCurrent() }`
   wiring; (c) true empty state — when `isEmptyStateVisible && !controller.fallbackActive`,
   today's `CommandPaletteEmptyStateView`.
7. Branch `emptyStateText` (`:1216`) and `isEmptyStateVisible` (`:1193`) so the
   per-mode "No X found" copy only renders in state (c). In state (b) the
   fallback list replaces the empty state entirely (no "No windows found" text).
8. Branch `statusText` (`:1180`) on `controller.fallbackActive` to surface the
   "no active-mode matches — showing other sources" hint.

### Phase 4 — Test seam

9. Add `setCommandItemsForTests(_ items: [CommandPaletteCommandItem], wmController:)`
   and `setFallbackStateForTests(wmController:windows:menuItems:commands:selectedMode:selectedItemID:)`
   to the `ForTests` block (`:1010-1058`). They set the private `commandItems`/
   `windows`/`menuItems`/`hasLoadedMenuItems`/`selectedMode`/`selectedItemID`
   exactly the way `setWindowSelectionStateForTests` does, so tests can drive
   the fallback without a live `show()`.

### Phase 5 — Tests + validation (see below)

## Tests

All tests are added to `Tests/NehirTests/CommandPaletteControllerTests.swift`.
The harness already builds a real `WMController` via
`makeCommandPaletteTestWMController()` (`:19`) and drives the controller with a
synthetic `CommandPaletteEnvironment`. Existing tests to keep green:
`selectCurrentNavigatesSelectedWindowAfterDismiss` (`:242`),
`selectCurrentSummonsSelectedWindowAfterDismiss` (`:289`),
the `handleModeShortcutForTests("2")` availability tests (`:448`, `:459`, `:474`),
and `persistedMenuModeFallsBackToWindowsWhenUnavailable` (`:517`).

New cases (use the Phase-4 seam to inject items):

- **`fallbackShowsCommandHitsWhenWindowsModeIsEmpty`** — `.windows` mode, inject
  windows that do not match `"float"`, inject a command whose `searchTerms`
  contain `"float"`; set `searchText = "float"`. Assert `controller.fallbackActive`,
  `fallbackSections` contains exactly one section (`.commands`) with that
  command, `filteredWindowItems.isEmpty`, and the active tab stays `.windows`.
- **`fallbackDispatchesCommandFromWindowsMode`** — same setup; set
  `selectedItemID = .command(thatCommand.id)` and call `selectCurrent()`.
  Assert the command was dispatched (capture via
  `environment.executeCommand`/the same `WMController.commandHandler` path the
  existing `.executeCommand` tests would use; if no direct command-capture
  env hook exists, assert via `resolvedSelectionAction(for:)` returning
  `.executeCommand` for that id while `selectedMode == .windows`). This is the
  test for Correction 2 / the generalized dispatch.
- **`fallbackOmitsMenuWhenNotLoaded`** — `.windows` mode, empty windows,
  `isMenuModeAvailable == true` but `hasLoadedMenuItems == false`, a matching
  command exists. Assert `fallbackSections` has the `.commands` section and
  **no** `.menu` section (Correction 5).
- **`fallbackOmitsMenuWhenMenuModeUnavailable`** — `setMenuAvailabilityForTests(nil)`
  (no frontmost app). Assert no `.menu` section even if `hasLoadedMenuItems`
  were set; matches `isMenuModeAvailable == false` semantics
  (`isEmptyStateVisible` menu branch, `:1198`).
- **`fallbackIncludesMenuWhenAlreadyLoaded`** — drive `setMenuLoadingStateForTests`
  then `loadMenuItemsForTests()` with an `environment.fetchMenuItems` that
  returns a matching `MenuItemModel`; switch to `.windows`, set a query that
  misses windows but hits the cached menu item. Assert the `.menu` section
  appears in `fallbackSections`.
- **`noFallbackWhenActiveModeHasMatches`** — `.windows` mode, a window matches
  the query. Assert `!controller.fallbackActive` and `currentSelectionList()`
  is the per-mode window list (today-path unchanged).
- **`noFallbackWhenQueryIsEmpty`** — `searchText == ""`. Assert
  `!controller.fallbackActive` even if all lists are empty (empty-query is the
  "No X available" state, not a fallback trigger).
- **`trueEmptyStateWhenAllSourcesEmpty`** — non-empty query, no matches in any
  source. Assert `!controller.fallbackActive`, `isEmptyStateVisible`, and the
  view renders `CommandPaletteEmptyStateView` (state (c)), not the fallback list.
- **`fallbackSelectionAdvancesToFirstHit`** — trigger fallback; assert
  `selectedItemID` resolves to the first item of the first non-empty section
  after `updateSelectionAfterFilterChange()` (no change to that method expected —
  confirm by test).
- **`resolvedSelectionActionUnchangedWhenFallbackInactive`** — golden-path
  regression: with matches in the active mode, `resolvedSelectionAction` returns
  the same `.navigateWindow`/`.pressMenu`/`.executeCommand` it does today for
  each `selectedMode`/`selectedItemID` pair.

If the SwiftUI sectioned view needs a snapshot/preview test, add it alongside
the existing view tests; otherwise cover behavior via the controller assertions
above (the view branches purely on `fallbackActive`/`fallbackSections`).

## Validation

```bash
swift build
swift test --filter CommandPaletteControllerTests
# Manual:
#   1. Open the palette (Option+Command+Space) in Windows mode (⌘1).
#   2. Type a query that matches no open window but matches a command name
#      (e.g. "float", "scratchpad", "zoom"). Confirm the "No windows found" dead-
#      end is gone; instead a "Commands" section lists the matching command(s),
#      the active tab is still Windows, and the footer hints "showing other
#      sources".
#   3. Arrow to the command hit and press Enter. Confirm the command executes
#      (dispatch from Windows mode), i.e. the generalized dispatch works.
#   4. Repeat in Commands mode (⌘3) with a query that matches a window title but
#      no command. Confirm a "Windows" section appears and Enter navigates to it.
#   5. Switch to Menu mode (⌘2) once to load menus, then go back to Windows and
#      search a menu-item title. Confirm a "Menu" section appears (menu included
#      only when already loaded). Repeat without having visited Menu: confirm no
#      "Menu" section appears (no eager AX fetch).
#   6. Type a query matching nothing anywhere. Confirm the true "No results"
#      empty state (no fallback list).
#   7. With an app that has no frontmost menu target (e.g. a fresh launch state
#      where isMenuModeAvailable is false), confirm the Menu section never
#      appears in the fallback.
```

Changeset (minor or patch; confirm release policy): "Command palette: when the
active source has no matches, fall back to matches from the other sources."

## Risks and mitigations

1. **Dispatch-decoupling correctness.** `resolvedSelectionAction` (`:820`)
   switching on the selection's source instead of `selectedMode` is the one
   behavioral change on the dispatch path. **Mitigation:** the
   `resolvedSelectionActionUnchangedWhenFallbackInactive` regression test pins
   today's behavior when no fallback is active, and
   `fallbackDispatchesCommandFromWindowsMode` covers each source-while-not-in-
   that-mode. The ID union is already source-tagged (`:57`) and
   `performSelectionAction` (`:894`) is unchanged, so the blast radius is one
   function.
2. **Empty-state semantics change.** `isEmptyStateVisible` (`:1193`) today means
   "active mode empty"; with fallback it must mean "all sources empty" for the
   true empty state, and the fallback list must not flash the "No X found" copy
   while menu is still loading. **Mitigation:** the three-state view branch
   (Phase 3 step 6) and the `fallbackActive` gate on `emptyStateText` (step 7)
   keep the states disjoint; `fallbackOmitsMenuWhenNotLoaded` plus
   `trueEmptyStateWhenAllSourcesEmpty` pin the boundaries.
3. **Menu latency / AX cost.** Any path that pulls menu in eagerly adds
   menu-enumeration cost to every palette open. **Mitigation:** Variant A
   includes Menu only when `hasLoadedMenuItems` (Correction 5 / option (b)); the
   entry guard (`:650`) and the async completion guard (`:677`) are untouched.
   The cost of option (a) is documented as a follow-up, not v1.
4. **Score comparability across sources.** Merging the three scored arrays and
   sorting would need a new cross-source relevance function
   (windows/menus `pos`+`1000+pos`; commands `i*10000+pos` on normalized terms).
   **Mitigation:** group by source, fixed order, no cross-sort (Correction 7).
   This is also the conventional UX for multi-source launchers and is exactly
   what backlog #11 (fuzzy) would later replace with a comparable score.
5. **Visual weight of grouped lists.** Three full per-source lists in a 430pt
   panel (`:1163`) could feel heavy. **Mitigation:** the fallback only appears
   when the active mode is empty, so at most two secondary sections show;
   per-section caps are an explicit follow-up (Open Question 5), not v1.
6. **Selection identity across re-renders.** `selectedItemID` is a tagged union
   (`:57`); moving from a per-mode list to a flattened fallback list must keep
   the existing `ScrollViewReader` `.id(...)` scrolling stable
   (`:1153`-region). **Mitigation:** fallback rows reuse the same
   `CommandPaletteSelectionID`-typed `.id` as the per-mode branches, so scroll
   anchoring and `updateSelectionAfterFilterChange` clamping are unchanged.
7. **Footer/status churn.** Swapping `statusText` (`:1180`) between per-mode and
   fallback copy on each keystroke could flicker. **Mitigation:** the fallback
   hint is only shown when `fallbackActive`, which itself is gated on a
   non-empty query and an empty active list, so the transition is intentional
   and matches the list swap.

## Follow-ups (out of scope)

- **Variant B — unified `.all` mode (opt-in tab).** Add `case all` to
  `CommandPaletteMode` (`:9-12`) + `displayName` (`:14-20`) **+
  `modeHint(for:)` entry** (`:310-318`, Correction 1) + `handleModeShortcut`
  `⌘4` (`:803`) + view branches (`:1113`, `:1193`, `:1216`). Requires eager
  menu policy (relax `loadMenuItemsIfNeeded` guards `:650`/`:677`). Ship **only
  as opt-in** — do **not** change `defaultCommandPaletteLastMode`
  (`RuntimeStateStore.swift:20`); let users who want unified set it once.
  Sequence after A lands and gets feedback (discovery Open Questions 3 & 4).
- **Variant A option (a) — on-demand menu fetch for fallback.** If field
  feedback says "I want menu hits without first visiting the Menu tab," relax
  the entry (`:650`) and completion (`:677`) guards for the fallback path and
  show a "Searching menus…" inline affordance while `isMenuLoading`. Measure
  `fetchMenuItems` latency for large apps first (discovery Risk 1).
- **Per-section caps** in the grouped fallback/unified list (e.g. top 5 per
  source) to keep the 430pt panel usable with many hits (Open Question 5).
- **Co-design with backlog #11 (fuzzy search).** A comparable fuzzy score is the
  natural cross-source relevance signal; revisit the "group, do not cross-sort"
  mitigation (Correction 7) once #11 lands. The two remain independently
  shippable.
- **Coordinate the chord budget with `planned/20260621-assign-hotkey-from-command-palette.md`**
  (backlog #9). A and #9 are orthogonal (A is *which sources* are searched; #9
  is *rebinding* the selected match) but both touch the palette controller; if
  #9 claims `Tab` and A later wants an "expand all sources" toggle, pick a
  non-conflicting chord up front.
