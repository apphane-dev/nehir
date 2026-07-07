# @choru custom Zones anchor model — Discovery

Groom 2026-07-07: still applicable — external-fork (`choru-k/nehir`) evaluation; the Zones/app-group-anchor concept has not been ported to main (no `ZoneEngine`, `ZonesConfig`, `focus-zone`, or `move-window-to-zone` exists) (verified against main 7a025b78).

Source branch: the `choru-k/nehir` fork on branch `choru` at `b47f7399842211ca71151563778e679a1c4f16c9`.
Comparison baseline: upstream `guria/nehir` `main` at `7b731a517119e7ad20c4d3953b4e5bc872717f94`.
Primary feature doc: `custom/zones.md` in the `choru` branch.

Scope: inspect @choru's custom **Zones (anchor model)** feature, verify the implementation files named by `custom/zones.md`, check adjacent config/action/IPC/layout/tests, and assess whether the idea is useful beyond the author's dotfiles workflow. All source references below were verified on 2026-06-19 against the source and baseline revisions above; re-verify before porting because line numbers will drift.

---

## TL;DR

- **What it is:** an opt-in, six-zone grouping layer over Nehir's existing single horizontal Niri-style column strip. A zone is not a separate workspace or hidden view; it is an **anchor/grouping tag** used to sort columns and jump focus to the first column in that group.
- **Main behavior:** `focus-zone N` jumps to the first/remembered column tagged with zone N; `move-window-to-zone N` retags the focused column and moves it into zone order; background auto-ordering sorts visible columns by configured zone.
- **Evidence:** main has no `ZoneEngine`, `ZonesConfig`, `focus-zone`, `move-window-to-zone`, or `zonesEnabled` symbols. The choru branch adds the feature across config (`ZonesConfig`, `ZonesConfigStore`, `zonesEnabled`), runtime state (`WMController.zoneEngine`), layout reordering (`NiriLayoutEngine.applyZoneOrdering`), commands/actions/hotkeys, IPC models/router/manifest, Leader defaults, and pure `ZoneEngineTests`.
- **Quality:** the pure state machine is small and reasonably tested, and `swift test --filter ZoneEngineTests` passed (17 tests). The production integration is much thinner: no tests for `applyZoneOrdering`, command routing, IPC execution, settings reload/seed failure behavior, or multi-workspace semantics.
- **Usefulness / wide-audience fit:** the idea can click for keyboard-heavy users who keep many app categories in one long strip and want app-group jump targets without creating more workspaces. As currently shaped, however, it is strongly personalized: six hard-coded dotfile-flavored defaults (`meeting`, `note`, `cat`, `duck`, `web`, `ai`), SketchyBar integration notes, no first-class UI, and behavior tuned to a single global strip.
- **Verdict:** **do not merge as-is.** Treat it as an interesting prototype for an optional "app groups / anchors" feature, but require product generalization, integration tests, and multi-workspace-safe state before upstreaming.

## Feature behavior verified from docs and code

`custom/zones.md` defines the intended model:

- A zone is an **anchor** over one continuous strip, not a separate/hiding mode (`custom/zones.md:1-5`).
- `focus-zone N` jumps focus to a zone's anchor (`custom/zones.md:8`).
- `move-window-to-zone N` tags the focused window's column and slides it into that zone's region (`custom/zones.md:9`).
- Auto-sort keeps the strip in zone order and attempts to preserve focus (`custom/zones.md:10`).
- Bundle assignments apply only on first sight; manual zone moves are sticky for that live window/column, and tags are recomputed each session (`custom/zones.md:12-18`).
- Zone definitions and bundle assignments live in `~/.config/nehir/zones.json`; the on/off switch remains `[general] zonesEnabled` in `settings.toml` (`custom/zones.md:20-58`).

Implementation confirms the high-level behavior, with an important nuance: production layout code treats a **column's first window token** as the zone identity (`NiriLayoutEngine+ColumnOps.swift:862-868`, `CommandHandler.swift:431-437`), so the implementation is more accurately "column-anchor tags" than durable per-window tags.

## Implementation / evidence

### Baseline comparison

A baseline grep for `ZoneEngine`, `ZonesConfig`, `focus-zone`, `move-window-to-zone`, and `zonesEnabled` under `Sources`, `Tests`, and `custom` returned no matches. The feature is branch-local.

Zones-specific paths added/modified relative to main include:

- `custom/zones.md` — feature doc and usage contract.
- `Sources/Nehir/Core/Layout/Niri/ZonesConfig.swift` — JSON-facing zone definitions and default app assignments.
- `Sources/Nehir/Core/Config/ZonesConfigStore.swift` — load/seed `~/.config/nehir/zones.json`.
- `Sources/Nehir/Core/Layout/Niri/ZoneEngine.swift` — pure state machine for tagging, sorting, focus target resolution, and focus memory.
- `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+ColumnOps.swift` — `applyZoneOrdering` layout hook.
- `Sources/Nehir/Core/Controller/NiriLayoutHandler.swift` — calls `applyZoneOrdering` during layout refresh for the active workspace.
- `Sources/Nehir/Core/Controller/CommandHandler.swift` — `focusZoneInNiri` and `moveWindowToZoneInNiri`.
- `Sources/Nehir/Core/Controller/WMController.swift` — owns/configures a single `zoneEngine`.
- `Sources/Nehir/Core/Input/ActionCatalog.swift`, `HotkeyCommand.swift`, `HotkeyConfigMapping.swift` — actions and bindable hotkey names.
- `Sources/Nehir/IPC/IPCCommandRouter.swift`, `Sources/NehirIPC/IPCModels.swift`, `IPCAutomationManifest.swift` — CLI/IPC command surface.
- `Tests/NehirTests/ZoneEngineTests.swift` — pure state/config tests.

### Config and defaults

`ZonesConfig` is Codable but intentionally persists only `definitions` and `bundleAssignments`; `enabled` and `layoutMode` are omitted from `zones.json` (`ZonesConfig.swift:25-56`). Defaults are highly personal: `meeting`, `note`, `cat`, `duck`, `web`, `ai`, mapped to Zoom, Obsidian, Slack, WezTerm, Kagi, Claude, and ChatGPT (`ZonesConfig.swift:58-76`).

`ZonesConfigStore.loadOrSeed` reads `zones.json`, silently falls back to defaults on any decode/read error, and writes defaults when loading fails (`ZonesConfigStore.swift:7-24`). `WMController.applyPersistedSettings` reloads this JSON whenever settings are applied, then overlays `settings.zonesEnabled` before configuring the engine (`WMController.swift:280-287`).

`zonesEnabled` is threaded through canonical TOML and settings export/store (`CanonicalTOMLConfig.swift:35-43`, `SettingsExport.swift:14-17`, `SettingsStore.swift:267-270`). No dedicated settings UI for editing the zone map was found; usage is TOML plus JSON plus CLI/Leader/hotkeys.

### Runtime model

`ZoneEngine` owns:

- `currentZone`;
- `windowZoneTags: [String: Int]`;
- `positionInferredWindowIDs` for unassigned windows;
- `focusedWindowIDByZone` for restored focus (`ZoneEngine.swift:16-34`).

Key operations:

- `reconciledOrder` filters to live IDs, reconciles tags, assigns untagged windows by position, and returns sorted order (`ZoneEngine.swift:100-106`).
- `reconcile` prunes dead/invalid tags and applies bundle assignments only when a window ID is first seen (`ZoneEngine.swift:108-129`).
- `move(windowID:toZone:)` retags a live ID, updates `currentZone`, and returns sorted order (`ZoneEngine.swift:169-176`).
- `focusTarget` and `restoredFocusTarget` resolve anchor/remembered focus (`ZoneEngine.swift:203-219`).

The engine is pure and easy to reason about, but the integration uses a **single global engine** in `WMController` (`WMController.swift:102-104`). `NiriLayoutHandler` explicitly gates auto-ordering to the active workspace and comments that cross-workspace sticky tags are not preserved (`NiriLayoutHandler.swift:391-407`). That matches the author's one-strip setup but is a mergeability concern for normal multi-workspace Nehir usage.

### Layout integration

`NiriLayoutEngine.applyZoneOrdering` builds one zone ID per column using the first window token (`pid:windowId`) and bundle ID via `NSRunningApplication`, asks `ZoneEngine` for the target order, and repeatedly calls `moveColumnToIndex` until the active workspace columns match (`NiriLayoutEngine+ColumnOps.swift:860-927`). It repins `state.activeColumnIndex` to the pre-reorder focused anchor if possible (`NiriLayoutEngine+ColumnOps.swift:898-925`).

`NiriLayoutHandler` calls this after window removals/insertions and new-window handling but before computing the final layout plan (`NiriLayoutHandler.swift:382-410`). The comment says this catches new windows, float-to-tile, and manual moves, not just fresh insertions (`NiriLayoutHandler.swift:391-393`).

### Command/action/IPC surface

`CommandHandler.performCommand` dispatches `.focusZone` and `.moveWindowToZone` (`CommandHandler.swift:133-136`).

- `focusZoneInNiri` reconciles current columns, sets `currentZone`, resolves the remembered/first target, remembers focus, and calls `engine.focusColumn` (`CommandHandler.swift:452-475`).
- `moveWindowToZoneInNiri` reconciles current columns, finds the focused column, retags its anchor, moves the column to its sorted index, and returns current focus (`CommandHandler.swift:480-500`).

Action catalog entries `focusZone.1`...`focusZone.6` and `moveWindowToZone.1`...`moveWindowToZone.6` are added with unassigned default global bindings (`ActionCatalog.swift:549-566`). Hotkey TOML aliases are added as `focus.zone1`...`focus.zone6` and `move.toZone1`...`move.toZone6` (`HotkeyConfigMapping.swift:56-61`, `:87-92`). Leader defaults also hard-code move/switch zone menu items for the six custom names (`LeaderConfig.swift:73-88`).

IPC adds command names `focus-zone` and `move-window-to-zone` in `IPCModels` (`IPCModels.swift:222-223`, `:359-360`), decodes/encodes them using the existing column-index argument shape (`IPCModels.swift:685-688`, `:970-975`, `:1163-1166`), routes them through `IPCCommandRouter` with only `>= 1` validation (`IPCCommandRouter.swift:46-51`), and lists them in the automation manifest (`IPCAutomationManifest.swift:471-480`). Values greater than configured zone count reach the command handler and become no-ops through `ZoneEngine` validation rather than IPC-level invalid arguments.

## Tests / validation observed

Observed validation command:

```bash
swift test --filter ZoneEngineTests
```

Result: passed — 17 tests in `ZoneEngineTests` passed.

Test coverage found:

- auto-tagging from bundle assignments and positional inference (`ZoneEngineTests.swift:19-37`);
- nearest-anchor inference for unknown windows (`:40-58`);
- stable intra-zone sort and duplicate input handling (`:61-94`);
- manual move stickiness against later bundle reconciliation (`:96-128`);
- JSON decode/encode behavior for `ZonesConfig` (`:130-145`);
- pruning stale tags and disabled no-op behavior (`:147-179`);
- focus target/cycle/restore behavior (`:181-228`);
- invalid zone rejection and focus memory codability/pruning (`:230-257`).

Coverage gaps:

- no test found for `NiriLayoutEngine.applyZoneOrdering` moving real columns while preserving selected node/viewport;
- no test found for `CommandHandler.focusZoneInNiri` or `moveWindowToZoneInNiri`;
- no IPC router/model test specifically for `focus-zone` / `move-window-to-zone` execution;
- no `ZonesConfigStore` test for seeding, malformed JSON fallback, or accidental overwrite behavior;
- no multi-workspace test proving manual zone tags survive workspace switches (and the code/comment imply they do not);
- no test for tabbed/multi-window columns where the first window changes and therefore the anchor ID changes.

## Quality concerns

1. **Global state is single-workspace-shaped.** `ZoneEngine.reconciledOrder` prunes all tags not in the current `windows` set (`ZoneEngine.swift:100-113`), and `NiriLayoutHandler` only feeds the active workspace (`NiriLayoutHandler.swift:391-407`). Manual retags on another workspace are likely discarded when the engine reconciles a different workspace. This is acceptable for a one-strip dotfiles workflow but not for general Nehir semantics.
2. **Column identity is fragile.** The engine stores opaque "window" IDs, but layout/command integration uses the first window in a column as the anchor (`NiriLayoutEngine+ColumnOps.swift:862-872`, `CommandHandler.swift:431-447`). Closing/expelling/reordering the first child of a multi-window column can change the column's zone identity.
3. **Auto-sort can fight ordinary manual rearrangement.** The layout hook intentionally catches manual moves (`NiriLayoutHandler.swift:391-393`). That keeps zones grouped, but it means dragging/moving a column across group boundaries without retagging may snap back on the next refresh.
4. **Config fallback can overwrite bad user config.** `ZonesConfigStore.loadOrSeed` writes defaults whenever read/decode fails (`ZonesConfigStore.swift:14-24`). For a hand-edited JSON file, a syntax error could be silently replaced instead of reported/backed up.
5. **Personal defaults leak into product shape.** The names and assignments are not neutral examples; `cat`/`duck` and specific AI/browser choices are author-workflow artifacts (`ZonesConfig.swift:58-76`, `custom/zones.md:51-53`).
6. **Integration code duplicates helper logic.** `zoneAnchorID` / `zoneBundleID` appear in both `NiriLayoutEngine+ColumnOps` and `CommandHandler`; this is small, but it invites drift.
7. **IPC validation is loose.** The router rejects `< 1` but not `> max configured zone`; invalid high values become quiet no-ops. That may be fine for commands, but `nehirctl` users usually benefit from explicit invalid-argument feedback.

## Mergeability risks

- The choru branch is not a focused patch: `git diff --stat` against main shows 122 changed files, including unrelated F15/Leader/config/monitor/docs work. A zones port would need to be carved out carefully.
- Zones depend on adjacent custom infrastructure for a polished workflow: Leader defaults, F15 chord support, custom docs, and SketchyBar notes. The core can be ported alone, but the user-facing story is incomplete without broader product decisions.
- Main's current config policy has been moving toward careful TOML/diagnostics behavior; adding a second JSON config with silent fallback needs review against that policy.
- The runtime model assumes one global strip more than Nehir does. Nehir's normal multi-monitor/multi-workspace behavior needs per-workspace or per-column-node state, not a single global prune-on-reconcile map.
- Because `applyZoneOrdering` mutates column order inside the layout refresh path, it may interact with existing new-window placement, restore placement, focus preservation, and viewport animation logic. The branch has no integration tests for those interactions.

## Usefulness and wide-audience assessment

The underlying idea **does have some broader appeal**: many users think in app categories (chat, notes, terminal, browser) and want a quick "jump to that cluster" command without making each category a separate workspace. The anchor model is intentionally lighter than niri-style hidden zones, so it preserves Nehir's continuous-strip mental model and avoids a much larger viewport rewrite.

But the current implementation **does not yet click as a wide-audience feature**. It clicks most strongly for @choru's dotfiles workflow: fixed six categories, known bundle IDs, Leader/F15 navigation, and a SketchyBar plugin reading the same JSON. Users who already use workspaces for categories, who have multiple workspaces/monitors, who manually arrange columns, or who expect a visible UI for managing groups may find the behavior surprising.

For wide use, the feature would need to be reframed from "Zones with meeting/note/cat/duck/web/ai defaults" to something like **optional app group anchors**:

- neutral defaults or no defaults;
- visible management UI and import/export-safe config;
- per-workspace state semantics;
- explicit behavior for manual moves vs automatic grouping;
- status/query surface so bars/palettes can show group membership without private dotfile scripts.

## Recommendation / verdict

**Recommendation: do not merge this branch implementation as-is.**

**Verdict: promising prototype, not upstream-ready.** The concept is worth preserving as a discovery candidate because it offers a lightweight alternative to more workspaces and a faster jump target for app clusters. However, the implementation is too personalized and too single-workspace-shaped for mainline Nehir.

A reasonable upstream path is a staged redesign:

1. keep the pure `ZoneEngine` idea, but rename/reframe it around app-group anchors;
2. make state per workspace or attach tags to stable column/window model identities;
3. add integration tests before wiring auto-sort into layout refresh;
4. expose neutral UI/config/IPC semantics;
5. only then consider adding hotkey/Leader defaults.

## Concrete follow-up work

1. **Product decision:** decide whether Nehir wants "app group anchors" as a first-class concept, or whether this remains a user-script/dotfiles pattern.
2. **Terminology/defaults:** replace personal six-zone defaults with neutral empty config or examples; avoid shipping author-specific bundle assignments.
3. **State model:** make tags workspace-scoped and use stable column/window identities instead of first-window-token anchors.
4. **Manual move policy:** specify whether ordinary column moves retag, temporarily override auto-sort, or are snapped back; make the choice visible in docs/settings.
5. **Config behavior:** add `ZonesConfigStore` diagnostics/backups for malformed JSON instead of silent overwrite.
6. **Integration tests:** cover `applyZoneOrdering`, focus preservation after auto-sort, command handler paths, IPC model/router paths, settings reload, and multi-workspace switching.
7. **IPC/query surface:** add a query for zone definitions/current tags if external bars are expected to use the feature.
8. **Merge extraction:** if ported, extract only the zones-related files from the broad choru branch and avoid dragging unrelated F15/Leader/config changes unless separately approved.
