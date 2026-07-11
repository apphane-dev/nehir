# BarutSRB/OmniWM#311 — Exclude apps from the workspace bar

Re-verified against main 7a025b78 on 2026-07-07.

**Status:** planned
**Source discovery:** `discovery/20260617-omniwm-311-exclude-apps-from-workspace-bar.md`
**Upstream reference:** https://github.com/BarutSRB/OmniWM/issues/311 (open, no comments/labels;
feature request, not a bug). Distinct from closed `not_planned` #281 (hide *all* app icons) —
BarutSRB/OmniWM#311 is per-app exclusion by identity.

Source references were refreshed against main `7a025b78` on 2026-07-07. `AppRule` still has no `hideFromWorkspaceBar` field and `WorkspaceBarDataSource` has no exclusion helper.

## TL;DR

Add an opt-in **`hideFromWorkspaceBar`** field to `AppRule` (issue option a), then
filter excluded apps out of the workspace-bar projection in
`WorkspaceBarDataSource.workspaceItems`. The app-rule subsystem already keys on
bundle id with a case-insensitive matcher, TOML persistence, and a form editor, so
this is a small additive change: one schema field, two codec touch-ups, one filter
site, one UI toggle, and tests. `ffgrep hideFromWorkspaceBar|excludedApps|excludeFromBar|barExcluded`
across `Sources` returns no matches — the feature is genuinely absent.

The filter is applied **DataSource-local**: `workspaceItems` already receives both
`settings` (so `settings.appRules` is reachable) and `appInfoCache` (so
`bundleId(for:)` is reachable), so no call-site plumbing changes. The same filtered
set is used to recompute `hasBarOccupancy` so `hideEmptyWorkspaces` stays correct
for the exact Übersicht case (a workspace containing *only* an excluded app must
hide, not linger as an empty-seeming workspace). `WorkspaceManager` is left
untouched — it keeps taking only the scalar `showFloatingWindows` presentation
param and gains no settings dependency.

## Discovery corrections / decisions

The discovery's recommendation is right at the product level. Two corrections when
porting it into source:

1. **`AppRuleFileStore` is a hand-rolled TOML codec, not `AppRule.Codable` — and the
   discovery's step 1 only touched the `Codable` path.** On-disk rule persistence is
   `Sources/Nehir/Core/Config/AppRuleFileStore.swift`, which manually writes a
   `[match]`/`[effect]` TOML layout in `encode(_:order:)` (`:44`) and parses it back
   field-by-field in `decodeWithOrder` (`:110`). It does **not** round-trip unknown
   keys and has no `extractBool` helper (only `extractString`/`extractDouble`/`extractInt`,
   `:270`/`:280`/`:285`). So adding `hideFromWorkspaceBar` requires:
   - emitting it in `encode`'s `[effect]` block, and
   - reading it back in `decodeWithOrder`'s `AppRule(...)` initializer call (`:148-155`),
     backed by a new `extractBool` helper.
   Without both, the discovery's proposed round-trip test ("a rule with
   `hideFromWorkspaceBar: true` survives TOML write + reload via `AppRuleFileStore`")
   would fail. This is the same lossy-manual-codec class the sibling BarutSRB/OmniWM#410 work
   (`completed/20260621-omniwm-410-settings-toml-unknown-keys-roundtrip-loss.md`) flagged
   for `HotkeysTOMLCodec`/`WorkspacesTOMLCodec`; `AppRuleFileStore` is the app-rule
   member of that class. The `AppRule.Codable` path (`CodingKeys`/`init(from:)`) still
   needs the field too, because it is exercised by `SettingsMigrationStateStore` and
   `RuntimeStateStore`.
2. **Line-number drift across the discovery's citations** (verified against
   `7a025b78`). The discovery's locations are all correct as *symbols*; only line
   numbers moved. Corrected map used below: `WorkspaceManager.barVisibleEntries`
   `:2548→:2550`, `hasBarVisibleOccupancy` `:2565→:2562`, `barVisibleFloatingEntries`
   `:2574→:2573`; `AppInfoCache.bundleId(for:)` `:50→:54`; `SettingsStore.appRules`
   `:230→:239`, `appRule(for:)` `:731→:854`; `WindowRuleEngine` matcher `:228→:237`;
   `LayoutRefreshController` NSRunningApplication fallback `:1144-1145→:1175-1176`;
   `WorkspaceBarProjectionOptions` fields `:3-6→:6-9`; `WorkspaceBarDataSource.workspaceItems`
   `:67→:71`.

Decisions adopted from the discovery (no change): primary surface is the **app-rule
field**, not a standalone `workspaceBarExcludedBundleIds` list — the app-rule shape
reuses the existing matcher/persistence/editor and gives users the advanced matchers
(appName/title substring, regex, role) for free. Exclusion affects **only** bar
presence; tiling/floating/focus are untouched.

## Scope

### Files to add/change

1. `Sources/Nehir/Core/Config/AppRule.swift` — schema:
   - add `case hideFromWorkspaceBar` to the `CodingKeys` enum (`:39-53`);
   - add `var hideFromWorkspaceBar: Bool? = nil` stored property (next to `minHeight`,
     `:64`);
   - add `hideFromWorkspaceBar: Bool? = nil` to the memberwise `init` (`:55-86`);
   - add `hideFromWorkspaceBar = try container.decodeIfPresent(Bool.self, forKey: .hideFromWorkspaceBar)`
     to `init(from:)` (`:135-150`).
   - No `encode(to:)` exists on `AppRule` (synthesized from `CodingKeys`), so the
     Codable encode path is covered by the `CodingKeys` entry alone.
   - Keep the field optional + opt-in so existing rules round-trip unchanged
     (cf. `planned/20260621-omniwm-410-...`).

2. `Sources/Nehir/Core/Config/AppRuleFileStore.swift` — hand-rolled TOML persistence
   (the load-bearing on-disk path; see correction #1):
   - in `encode(_:order:)` (`:44`), inside the `effectLines` block (`:71-75`), emit
     `if rule.hideFromWorkspaceBar == true { effectLines.append("hideFromWorkspaceBar = true") }`
     (only write when `true` — opt-in, matches the `if let v = …` style used for
     `layout`/`minWidth`/etc.);
   - in `decodeWithOrder`'s `AppRule(...)` initializer (`:148-155`), pass
     `hideFromWorkspaceBar: extractBool(effectFields["hideFromWorkspaceBar"])`;
   - add a private `extractBool(_ raw: String?) -> Bool?` helper next to
     `extractInt` (`:285`) that trims whitespace and returns `"true"` → `true`,
     `"false"` → `false`, anything else → `nil`.

3. `Sources/Nehir/UI/WorkspaceBar/WorkspaceBarDataSource.swift` — the filter, applied
   in the private `workspaceItems(...)` (`:71`):
   - build the excluded set once before the `workspaceManager.workspaces(on:).map`:
     ```swift
     let excludedBundleIds = Set(settings.appRules
         .filter { $0.hideFromWorkspaceBar == true }
         .map { $0.bundleId.lowercased() })
     ```
   - filter `projectedEntries` (currently `:82-86`) through a new private helper
     `isExcludedFromBar(_:appInfoCache:excludedBundleIds:)` that resolves the entry's
     bundle id via `appInfoCache.bundleId(for: entry.handle.pid)` with the
     `NSRunningApplication(processIdentifier:)` fallback used at
     `LayoutRefreshController.swift:1175-1176`, and returns `true` if the lowercased
     id is in the set (early-return `false` when the set is empty or the bundle id is
     unknown);
   - recompute `hasBarOccupancy` from the **filtered** `projectedEntries`
     (`!projectedEntries.isEmpty`) instead of calling
     `workspaceManager.hasBarVisibleOccupancy(...)` (`:88`), so a workspace
     containing only excluded apps hides under `hideEmptyWorkspaces` (`:93`).
   - The public entry points `workspaceBarItems(...)` (`:14`) and
     `workspaceBarProjection(...)` (`:32`) are unchanged — they already thread
     `settings` and `appInfoCache`.

4. `Sources/Nehir/UI/AppRuleDraft.swift` — editor mapping:
   - add `var hideFromWorkspaceBar: Bool = false` to the struct (`:28-46`; a plain
     `Bool` — `false` maps to `nil`, no separate "enabled" gate needed unlike the
     `minWidthEnabled`/`minWidth` pairs);
   - in `init(rule:)` (`:69`): `hideFromWorkspaceBar = rule.hideFromWorkspaceBar ?? false`;
   - in `makeRule(id:)` (`:123`): pass `hideFromWorkspaceBar: hideFromWorkspaceBar ? true : nil`.

5. `Sources/Nehir/UI/AppRulesView.swift` — surface the control: add
   `Toggle("Hide from Workspace Bar", isOn: $draft.hideFromWorkspaceBar)` in the rule
   editor's effect/action section (alongside the `layout`/`assignToWorkspace` controls
   used at `:388`/`:565`), so it is reachable from both the add-draft and edit-draft
   paths.

### Non-goals

- Do **not** add a parallel `workspaceBarExcludedBundleIds: [String]` global list. The
  app-rule field is the single primary surface (discovery decision). A global list is
  redundant for the same bundle id.
- Do **not** thread the excluded-set into `WorkspaceManager.barVisibleEntries` /
  `hasBarVisibleOccupancy`. Keep `WorkspaceManager` free of a `SettingsStore`
  dependency; recompute occupancy DataSource-local.
- Do **not** change tiling, floating, focus, scratchpad, or `assignToWorkspace`
  behavior — exclusion is bar-presence only.
- Do **not** gate this on PR BarutSRB/OmniWM#323's separate `layoutReason == .standard` bar filter
  (`discovery/20260616-omniwm-323-floating-panel-bar-filter.md`) — that is orthogonal
  (excluding non-standard floating entries by layout reason, not by app identity).
- Do **not** change #281 (hide all app icons, closed `not_planned`) — distinct request.
- Do **not** touch `HotkeysTOMLCodec`/`WorkspacesTOMLCodec` — that lossy-codec gap is
  owned by the BarutSRB/OmniWM#410 follow-up, not this ticket.

## Exact implementation plan

### Phase 1 — Schema (`AppRule`)

1. Add `case hideFromWorkspaceBar` to `CodingKeys` (`AppRule.swift:39-53`).
2. Add the stored property `var hideFromWorkspaceBar: Bool? = nil`.
3. Add the matching `hideFromWorkspaceBar: Bool? = nil` parameter to the memberwise
   `init` and assign it.
4. In `init(from:)` (`:135-150`), decode with
   `decodeIfPresent(Bool.self, forKey: .hideFromWorkspaceBar)`.
5. Confirm there is no custom `encode(to:)` to update (there is not — synthesized).

### Phase 2 — Persistence (`AppRuleFileStore`)

1. Add `extractBool(_ raw: String?) -> Bool?` next to `extractInt` (`:285`): trim
   whitespace; `"true"` → `true`, `"false"` → `false`, else `nil`.
2. In `encode(_:order:)` (`:44`), within the `effectLines` assembly (`:71-75`), add
   `if rule.hideFromWorkspaceBar == true { effectLines.append("hideFromWorkspaceBar = true") }`.
   (Write only when true; absent key decodes as `nil`, which is the default.)
3. In `decodeWithOrder` (`:110`), pass
   `hideFromWorkspaceBar: extractBool(effectFields["hideFromWorkspaceBar"])` to the
   `AppRule(...)` initializer (`:148-155`).
4. Update the inactive sample TOML in `writeInactiveSamples` (`:184`) only if a worker
   wants a teaching example; not required for correctness.

### Phase 3 — Bar filter (`WorkspaceBarDataSource`)

1. In `workspaceItems(...)` (`:71`), compute `excludedBundleIds` once before the
   `.map` (snippet in Scope §3).
2. Add the private helper `isExcludedFromBar(_:appInfoCache:excludedBundleIds:)`:
   ```swift
   private static func isExcludedFromBar(
       _ entry: WindowModel.Entry,
       appInfoCache: AppInfoCache,
       excludedBundleIds: Set<String>
   ) -> Bool {
       guard !excludedBundleIds.isEmpty else { return false }
       let bundleId = appInfoCache.bundleId(for: entry.handle.pid)
           ?? NSRunningApplication(processIdentifier: entry.handle.pid)?.bundleIdentifier
       guard let bundleId else { return false }
       return excludedBundleIds.contains(bundleId.lowercased())
   }
   ```
3. Filter `projectedEntries` (`:82`) with `.filter { !isExcludedFromBar($0, appInfoCache: appInfoCache, excludedBundleIds: excludedBundleIds) }`
   before splitting into `tiledEntries`/`floatingEntries` and before the occupancy
   decision.
4. Set `hasBarOccupancy: !projectedEntries.isEmpty` (filtered set) instead of the
   current `workspaceManager.hasBarVisibleOccupancy(...)` call (`:88`).
5. Leave `scratchpadItem(...)` (`:138`) unchanged — the scratchpad is an intentional
   transient hide and is out of scope.

### Phase 4 — UI (`AppRuleDraft`, `AppRulesView`)

1. Add `var hideFromWorkspaceBar: Bool = false` to `AppRuleDraft` (`:28-46`) and set it
   to `false` in the default `init` (`:47`).
2. Map it in `init(rule:)` (`:69`) and `makeRule(id:)` (`:123`) per Scope §4.
3. Add `Toggle("Hide from Workspace Bar", isOn: $draft.hideFromWorkspaceBar)` in the
   editor form in `AppRulesView.swift` (effect/action section), reachable from both
   add and edit flows.

## Tests

All bar tests use the existing Swift Testing harness and fixtures in
`Tests/NehirTests/WorkspaceBarDataSourceTests.swift` (`makeLayoutPlanTestController()`,
`makeLayoutPlanTestWindow(windowId:)`, `controller.appInfoCache.storeInfoForTests(pid:name:bundleId:)`,
`controller.workspaceManager.addWindow(_:pid:windowId:to:mode:)`,
`WorkspaceBarDataSource.workspaceBarItems(for:options:workspaceManager:appInfoCache:niriEngine:focusedToken:settings:)`).
Rules are seeded via `controller.settings.appRules.append(...)`.

`Tests/NehirTests/WorkspaceBarDataSourceTests.swift` (add cases):

1. `excludedAppIsAbsentFromWorkspaceBar` — two apps in one workspace; an `AppRule`
   with `hideFromWorkspaceBar: true` on app A's bundle id. Assert A is absent from the
   returned `WorkspaceBarItem.tiledWindows`/`floatingWindows` and B remains.
2. `workspaceWithOnlyExcludedAppIsHiddenWhenHideEmptyWorkspacesEnabled` — workspace
   contains only the excluded app; `options.hideEmptyWorkspaces == true`. Assert the
   workspace id is **not** in `items.map(\.id)` (occupancy recomputed from the filtered
   set). This is the literal Übersicht case.
3. `workspaceWithExcludedAndNormalAppShowsAndListsOnlyNormalApp` — mixed workspace.
   Assert the workspace is present and only the normal app is listed.
4. `excludedBundleIdMatchIsCaseInsensitive` — `AppRule.bundleId ==
   "tracesof.uebersicht"`, window reports `"tracesOf.Uebersicht"` via
   `storeInfoForTests`. Assert exclusion (mirrors the
   `WindowRuleEngine.swift:237` `caseInsensitiveCompare` convention).
5. `excludedAppStillTiledAndPresentInManagerEntries` — regression guard: after the bar
   filter, `controller.workspaceManager.tiledEntries(in:)` /
   `floatingEntries(in:)` still contain the excluded entry (exclusion is bar-only).

`Tests/NehirTests/AppRuleFileStoreTests.swift` (new — there is no direct
`AppRuleFileStore` coverage today):

6. `hideFromWorkspaceBarRoundTripsThroughFileStore` — build an `AppRule` with
   `hideFromWorkspaceBar: true` plus a couple of existing fields; `AppRuleFileStore.encode`
   then `decode` into a temp dir; assert the decoded rule has
   `hideFromWorkspaceBar == true` and the other fields survive. This locks correction #1.
7. `hideFromWorkspaceBarAbsentKeyDecodesAsNil` — a hand-written TOML body with no
   `hideFromWorkspaceBar` line decodes to `nil` (old rules round-trip unchanged).

`Tests/NehirTests/AppRuleDraftTests.swift` (add cases):

8. `hideFromWorkspaceBarRoundTripsThroughDraft` — `AppRuleDraft(rule:)` then
   `.makeRule(id:)` preserves `hideFromWorkspaceBar: true`; default draft produces
   `nil`.

## Validation

```bash
swift build
swift test --filter WorkspaceBarDataSourceTests
swift test --filter AppRuleFileStoreTests
swift test --filter AppRuleDraftTests
swift test --filter AppRule                # any AppRule Codable coverage
mise run test                              # full suite, if the project uses mise
```

Manual validation:

1. Add an app rule for Übersicht (`tracesOf.Uebersicht`) with "Hide from Workspace
   Bar" enabled.
2. Confirm Übersicht disappears from the bar while remaining tiled/focusable.
3. On a workspace containing *only* Übersicht, with "Hide Empty Workspaces" on,
   confirm that workspace hides.
4. Quit/relaunch nehir; confirm the rule and its `hideFromWorkspaceBar` flag survive
   the `apprules.d/*.toml` reload.

Changeset (minor): "Add a per-app Hide from Workspace Bar rule (BarutSRB/OmniWM#311)."

## Risks and mitigations

- **Occupancy/filter skew (HIGH).** Filtering `projectedEntries` but not recomputing
  occupancy leaves an Übersicht-only workspace visible-but-empty. Mitigation: recompute
  `hasBarOccupancy` from the filtered set in the same edit; covered by test #2.
- **Lossy manual codec (MED).** Forgetting the `AppRuleFileStore` encode/decode pair
  silently drops the flag on disk (the BarutSRB/OmniWM#410 regression class). Mitigation: the
  file-store round-trip test #6 is load-bearing; do not skip it.
- **Bundle-id resolution miss (MED).** `appInfoCache.bundleId(for:)` may return `nil`
  for a not-yet-cached pid during early enumeration. Mitigation: keep the
  `NSRunningApplication(processIdentifier:)` fallback (mirrors
  `LayoutRefreshController.swift:1175-1176`); treat unknown bundle id as "not
  excluded" so we never accidentally hide a window we cannot identify.
- **Case sensitivity (LOW).** Bundle ids are case-insensitive in practice
  (`tracesOf.Uebersicht` vs `tracesof.uebersicht`). Mitigation: lower-case both sides
  (rule id at set-build time, window id at lookup time); covered by test #4.
- **Performance (LOW).** The excluded set is built once per `workspaceItems` call and
  lookup is `O(1)`. No measurable cost expected.
- **Scope creep into BarutSRB/OmniWM#323 (LOW).** A worker might conflate this with the
  `layoutReason == .standard` filter. Mitigation: the Non-goals section calls it out;
  these are independent tickets.

## Follow-ups (out of scope)

- PR BarutSRB/OmniWM#323's `layoutReason == .standard` floating-bar filter
  (`discovery/20260616-omniwm-323-floating-panel-bar-filter.md`) — separate concern.
- A global `workspaceBarExcludedBundleIds` list / per-monitor override in
  `MonitorBarSettings` — only if user research shows the app-rule editor is too heavy
  for the single-app case. Redundant with this field for the same bundle id.
- Extending `HotkeysTOMLCodec`/`WorkspacesTOMLCodec` unknown-key round-trip — owned by
  the BarutSRB/OmniWM#410 follow-up, not this ticket.
- "Hide all app icons / bare workspace numbers" (#281) — closed `not_planned` upstream;
  not this feature.
