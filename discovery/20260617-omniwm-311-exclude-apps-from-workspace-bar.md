# OmniWM issue #311 — "Option to exclude specific apps from the workspace bar" — Discovery

Groom 2026-07-07: in flight — a plan exists (planned/20260621-omniwm-311-exclude-apps-from-workspace-bar.md); no per-app hide-from-workspace-bar rule yet (verified against main 7a025b78).

Source issue: https://github.com/BarutSRB/OmniWM/issues/311
Scope of this doc: determine whether/how nehir should let users exclude specific
apps (by bundle id) from the workspace bar, and where the filter plugs in.

All file/line references were verified against the Nehir source tree at
`904df02` ("Add bunch of discoveries mapped to issues from OmniWM"). Line numbers drift —
re-verify before implementing.

---

## TL;DR

- **nehir has no per-app workspace-bar exclusion today; the only bar filters are global toggles (`showFloatingWindows`, `deduplicateAppIcons`, `hideEmptyWorkspaces`) and the scratchpad filter. The whole app-rule subsystem already keys on bundle id and has matching + persistence + a UI editor, so the feature is a small additive change.**
- **Verdict:** 🔴 **Open / Applies.** This is an unimplemented, well-specified feature request. It owns a new repo action (implement per-app bar exclusion); recommended shape is a `hideFromWorkspaceBar` field on `AppRule` reusing the existing bundle-id matcher, with a filter inserted in `WorkspaceBarDataSource`.

## The request

The reporter (Samefisk) wants to keep apps running but remove them from the workspace bar —
specifically Übersicht (`tracesOf.Uebersicht`), plus the general class of helper widgets,
overlays, and background UI apps that create windows but are not useful in the bar. They
propose two shapes:

- (a) an app-rule option such as `hideFromWorkspaceBar = true`, or
- (b) a dedicated list of excluded bundle ids for the workspace bar.

The issue is open upstream with **no comments and no labels** as of the verification date
(comments feed returned zero entries). It is a feature request, not a bug.

### Cross-links in the triage notes

- **Closed #281 ("hide the application icons from the bar")** is **not** the same request.
  #281 asks to hide *all* app icons and show bare workspace numbers (`| 1 | 2 | 3 |`); it was
  closed upstream as `not_planned`. #311 is per-app exclusion by identity. They are distinct
  actions and do not collide.
- Discussion #83 ("Non-Sticky floating windows") is thematically related (background/overlay
  windows) but is about floating-window stickiness, not bar presence.

## Provenance: is this nehir's code?

Yes. The entire workspace-bar and app-rule pipeline lives in nehir and is verified below. The feature
is simply absent — `ffgrep` for `hideFromWorkspaceBar|excludedApps|excludeFromBar|barExcluded`
across `Sources` returns **no matches**.

## How the workspace bar enumerates app entries today

The projection flows through `WorkspaceBarDataSource.workspaceItems`, which pulls entries from
`WorkspaceManager.barVisibleEntries`, then groups them into `WorkspaceBarWindowItem`s keyed by
**app name** (resolved from pid via `AppInfoCache`):

```swift
// Sources/Nehir/UI/WorkspaceBar/WorkspaceBarDataSource.swift:67
private static func workspaceItems(
    for monitor: Monitor,
    options: WorkspaceBarProjectionOptions,
    workspaceManager: WorkspaceManager,
    appInfoCache: AppInfoCache,
    niriEngine: NiriLayoutEngine?,
    focusedToken: WindowToken?,
    settings: SettingsStore
) -> [WorkspaceBarItem] {
    var workspaces = workspaceManager.workspaces(on: monitor.id).map { workspace in
        let projectedEntries = workspaceManager.barVisibleEntries(
            in: workspace.id,
            showFloatingWindows: options.showFloatingWindows
        )
        return WorkspaceSnapshot(
            workspace: workspace,
            tiledEntries: projectedEntries.filter { $0.mode == .tiling },
            floatingEntries: projectedEntries.filter { $0.mode == .floating },
            hasBarOccupancy: workspaceManager.hasBarVisibleOccupancy(
                in: workspace.id,
                showFloatingWindows: options.showFloatingWindows
            )
        )
    }
    ...
```

`barVisibleEntries` returns tiled entries plus (optionally) floating entries; the only
floating-side filter is the scratchpad filter:

```swift
// Sources/Nehir/Core/Workspace/WorkspaceManager.swift:2548
func barVisibleEntries(
    in workspace: WorkspaceDescriptor.ID,
    showFloatingWindows: Bool = false
) -> [WindowModel.Entry] {
    var entries = tiledEntries(in: workspace)
    if showFloatingWindows {
        entries.append(contentsOf: barVisibleFloatingEntries(in: workspace))
    }
    return entries
}

// Sources/Nehir/Core/Workspace/WorkspaceManager.swift:2574
private func barVisibleFloatingEntries(in workspace: WorkspaceDescriptor.ID) -> [WindowModel.Entry] {
    floatingEntries(in: workspace).filter {
        !isScratchpadToken($0.token) && hiddenState(for: $0.token)?.isScratchpad != true
    }
}
```

Entries are turned into bar window items by grouping on app name; `bundleId` is never
consulted for filtering:

```swift
// Sources/Nehir/UI/WorkspaceBar/WorkspaceBarDataSource.swift (createDedupedWindowItems)
let appName = appInfoCache.name(for: entry.handle.pid) ?? "Unknown"
```

So **there is no per-bundle-id, per-app, or per-pid exclusion anywhere in the bar pipeline.**
The only inputs are the three global booleans in `WorkspaceBarProjectionOptions`
(`Sources/Nehir/UI/WorkspaceBar/WorkspaceBarProjectionOptions.swift:3`-`6`), the scratchpad
filter, and `hideEmptyWorkspaces`.

## The bundle-id primitive to reuse

nehir already has everything needed; nothing has to be invented:

- **Per-pid bundle-id resolution:** `AppInfoCache.bundleId(for:)`, backed by
  `NSRunningApplication.bundleIdentifier`:

  ```swift
  // Sources/Nehir/Core/AppInfoCache.swift:50
  func bundleId(for pid: pid_t) -> String? {
      info(for: pid)?.bundleId
  }
  ```

  The same pid→bundle-id pattern (cache, then `NSRunningApplication` fallback) is already used
  for rule evaluation at `Sources/Nehir/Core/Controller/LayoutRefreshController.swift:1144`-`1145`:

  ```swift
  let bundleId = controller.appInfoCache.bundleId(for: pid)
      ?? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
  ```

- **App-rule schema keyed on bundle id:** `AppRule.bundleId` is a required `String`
  (`Sources/Nehir/Core/Config/AppRule.swift`), with optional advanced matchers
  (`appNameSubstring`, `titleSubstring`, `titleRegex`, `axRole`, `axSubrole`) and actions
  (`manage`, `layout`, `assignToWorkspace`, `minWidth`, `minHeight`). Rules are stored in
  `SettingsStore.appRules` (`Sources/Nehir/Core/Config/SettingsStore.swift:230`) and looked up
  by bundle id at `Sources/Nehir/Core/Config/SettingsStore.swift:731`:

  ```swift
  func appRule(for bundleId: String) -> AppRule? {
      appRules.first { $0.bundleId == bundleId }
  }
  ```

- **Case-insensitive bundle-id matcher (the convention to follow):**

  ```swift
  // Sources/Nehir/Core/Rules/WindowRuleEngine.swift:228
  func matches(_ facts: WindowRuleFacts) -> Bool {
      if rule.bundleId.caseInsensitiveCompare(facts.ax.bundleId ?? "") != .orderedSame {
          return false
      }
      ...
  ```

- **App-rule editor UI:** `AppRuleDraft` (`Sources/Nehir/UI/AppRuleDraft.swift`) maps every
  `AppRule` field to an editable form via `makeRule()` / `init(rule:)`; a new optional field
  is a mechanical addition there (the editor already exposes per-rule toggles like
  `minWidthEnabled`).

- **Bar settings surface:** global bar toggles live on `SettingsStore`
  (`workspaceBarDeduplicateAppIcons`, etc., wired into `GlobalBarSettingsSection` at
  `Sources/Nehir/UI/WorkspaceBarSettingsTab.swift:81`-`86`), with per-monitor overrides in
  `MonitorBarSettings` and a resolved view in `ResolvedBarSettings`
  (`Sources/Nehir/Core/Config/MonitorBarSettings.swift`). The projection options already flow
  into `WorkspaceBarDataSource` via `settings: SettingsStore`, so an exclusion set derived
  from `settings.appRules` needs **no new call-site plumbing**.

## Why this applies

This is a genuine gap with an unambiguous, low-risk fix path. Specifically:

1. **The filter insertion point is clean.** `WorkspaceBarDataSource.workspaceItems`
   (`Sources/Nehir/UI/WorkspaceBar/WorkspaceBarDataSource.swift:67`-`79`) already receives
   both `settings` (so `settings.appRules` is reachable) and `appInfoCache` (so
   `bundleId(for:)` is reachable). Computing an excluded-set once and filtering
   `projectedEntries` requires no signature change to the existing entry points
   `workspaceBarItems` / `workspaceBarProjection` (both already pass `settings` and
   `appInfoCache`, `Sources/Nehir/UI/WorkspaceBar/WorkspaceBarDataSource.swift:13`-`44`).

2. **`hideEmptyWorkspaces` consistency must be preserved.** That toggle keys off
   `hasBarVisibleOccupancy` (`Sources/Nehir/Core/Workspace/WorkspaceManager.swift:2565`),
   which is computed independently of `projectedEntries`. If only `projectedEntries` is
   filtered but occupancy is not, a workspace containing *only* an excluded app (the exact
   Übersicht case) would still register as occupied and would not be hidden. The filter must
   therefore be applied to the occupancy decision as well — either by recomputing occupancy
   in the DataSource from the filtered set, or by threading the excluded-set into
   `barVisibleEntries`/`hasBarVisibleOccupancy`. The DataSource-local recomputation keeps
   `WorkspaceManager` free of a settings dependency (it currently only takes the scalar
   `showFloatingWindows` presentation param), so it is the lower-coupling choice.

3. **No existing mechanism covers it.** nehir's only "hide a window from the bar" path is the
   scratchpad (an intentional, transient hide-everything state), which is not a per-app,
   persistent identity filter. Assigning an app to a workspace (`assignToWorkspace`) relocates
   it but does not hide it.

## Recommendation

Implement the feature. Prefer the **app-rule field** shape (issue option a) over a standalone
bundle-id list, because nehir already has the app-rule subsystem (schema, case-insensitive
matcher, TOML persistence via `AppRuleFileStore`, and the `AppRuleDraft` editor) keyed on
bundle id — a new field is additive and gives users the advanced matchers (appName/title
substring, regex, role) for free, which is useful for widget families that share a bundle-id
prefix but not an exact id.

Concretely:

1. **Schema:** add `var hideFromWorkspaceBar: Bool? = nil` to `AppRule`
   (`Sources/Nehir/Core/Config/AppRule.swift`): add the `CodingKeys` entry, the memberwise
   `init` parameter, and the `init(from:)` / default. Keep it optional + opt-in so existing
   rules round-trip unchanged (cf. the unknown-key round-trip concerns in the sibling
   `20260616-omniwm-410-settings-toml-unknown-keys-roundtrip-loss.md`).
2. **Exclusion set:** in `WorkspaceBarDataSource.workspaceItems`, build the set once:

   ```swift
   let excludedBundleIds = Set(settings.appRules
       .filter { $0.hideFromWorkspaceBar == true }
       .map { $0.bundleId.lowercased() })
   ```
3. **Per-entry resolve + filter:** resolve each entry's bundle id via
   `appInfoCache.bundleId(for: entry.handle.pid)` (with the `NSRunningApplication` fallback
   used at `LayoutRefreshController.swift:1144`), compare lowercased against the set, and drop
   matches — applying the same filter to the `hasBarOccupancy` recompute so
   `hideEmptyWorkspaces` stays correct for Übersicht-only workspaces.
4. **UI:** add a "Hide from Workspace Bar" toggle to `AppRuleDraft`/`AppRulesView`, mirroring
   the existing per-rule toggles (`Sources/Nehir/UI/AppRuleDraft.swift`).
5. **(Optional, alternative) global list:** if a lighter-weight entry point is desired for the
   single-app case, a `workspaceBarExcludedBundleIds: [String]` on `SettingsStore` /
   `ResolvedBarSettings` (and `MonitorBarSettings` for per-monitor overrides, following the
   scalar-toggle pattern at `Sources/Nehir/UI/WorkspaceBarSettingsTab.swift:304`-`318`) is a
   viable secondary surface. It is redundant with (1) for the same bundle id, so pick one
   primary; recommend the app-rule field as primary.

Do **not** gate this on PR #323's separate bar filter (`layoutReason == .standard`,
documented in `20260616-omniwm-323-floating-panel-bar-filter.md`) — that is a different
concern (excluding non-standard floating entries) and is orthogonal to per-app identity
exclusion.

## Suggested tests

- `WorkspaceBarDataSource` / `WorkspaceBarDataSourceTests`: a window whose bundle id matches an
  `AppRule { hideFromWorkspaceBar: true }` is absent from `workspaceBarItems` for every
  workspace it appears in, while other apps remain.
- With `hideEmptyWorkspaces == true`, a workspace that contains **only** an excluded app is
  hidden (occupancy recomputed from the filtered set), and a workspace with one excluded +
  one normal app shows and lists only the normal app.
- Case-insensitive match: an `AppRule.bundleId` of `"tracesof.uebersicht"` excludes a window
  reporting `"tracesOf.Uebersicht"` (mirrors the `WindowRuleEngine.swift:229` convention).
- Round-trip: a rule with `hideFromWorkspaceBar: true` survives TOML write + reload via
  `AppRuleFileStore` without losing the field (guard against the regression class in
  `20260616-omniwm-410`).
- Excluded app is still tiled/floated and focused normally — exclusion affects **only** bar
  presence, not window management (regression guard: the app must still appear in
  `tiledEntries`/`floatingEntries`).
