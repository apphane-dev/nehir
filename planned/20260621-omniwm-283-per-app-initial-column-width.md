# BarutSRB/OmniWM#283 — Per-app initial column width

Re-verified against main 7a025b78 on 2026-07-07.

**Status:** planned
**Source discovery:** `discovery/20260617-omniwm-283-per-app-initial-column-width.md`
**Upstream reference:** <https://github.com/BarutSRB/OmniWM/issues/283>
**Coordinate with:** `planned/20260621-omniwm-295-niri-window-width-preservation.md` (move path) and `noop/20260616-omniwm-384-respect-window-min-size-in-niri-column-width.md` (min-size floor, already satisfied).

Source references were refreshed against main `7a025b78` on 2026-07-07. `AppRule` still has no `initialColumnWidth` field (current effect fields are `minWidth`, `minHeight`, and `sticky` around `Sources/Nehir/Core/Config/AppRule.swift:42-68`).

## TL;DR

Nehir has no per-app *initial* column-width support: the symbols
`initialWidth` / `initialColumnWidth` / `initialProportion` / `startupWidth` /
`openingWidth` do not exist anywhere in the tree, and column width at admission
is computed entirely from workspace/monitor settings — the matched app's
`bundleId` never reaches the column-width resolver. The reporter wants per-app
startup width via App Rules (Kitty opens at 50%, Safari at 100%), distinct from
the per-app `minWidth` floor.

Add a new `AppRule` effect `initialColumnWidth: Double?` (a proportion,
`0.0...1.0`), thread it through the existing rule pipeline
(`ManagedWindowRuleEffects` → `WindowModel.Entry.ruleEffects` → engine
admission), and consume it **once, at column creation**, in
`initializeNewColumnWidth`. When non-nil, set `column.width = .proportion(...)`
and `column.hasManualSingleWindowWidthOverride = true` so the lone-window `.fill`
policy honors it (otherwise a 50%-rule window on an empty workspace still
renders at 100%). The app's `minWidth` floor keeps winning via the existing
`resolveSpan`/`widthBounds` clamp (`NiriNode.swift:551`), so a rule below the
floor is clamped up automatically. The effect is strictly additive: an app with
no rule behaves exactly as before.

## Discovery corrections / decisions

The discovery's recommendation is correct; correct the following before
implementing (re-verified against main `7a025b78`):

1. **Line-number drift (cosmetic):**
   - `AppRule` struct fields live at `AppRule.swift:41-68` (`var minWidth` at
     `:67`, `var minHeight` at `:68`); `CodingKeys` at `:42-55` (`case minWidth`
     `:53`); memberwise init at `:70-94`; `hasAnyRule` at `:128-132`;
     `init(from decoder:)` at `:135-150`. Discovery said `:57-78` / `:120-141`.
   - `ManagedWindowRuleEffects` is at `WindowRuleEngine.swift:46-51`
     (discovery said `:40-47`). The effects construction inside
     `decision(for:)` is at `:353-357` (discovery said `:335-340`); `decision(for:)`
     itself starts at `:326`.
   - `addWindow(token:to:afterSelection:focusedToken:)` is at
     `NiriLayoutEngine+Windows.swift:122`; the two `initializeNewColumnWidth`
     calls are at `:131` (claimed empty column) and `:159` (new column);
     `root.allWindows.count == 1` reset loop is at `:152-155`.
     `syncWindows(_:in:selectedNodeId:focusedToken:)` is at `:608`; its
     `addWindow` call is at `:630`.
   - `initializeNewColumnWidth(_:in:)` is at `NiriLayoutEngine.swift:235-246`
     (discovery said `:210-233`/`:223-233`); `matchingPresetIndex(for:)` at
     `:248` (private, same file — usable from `initializeNewColumnWidth`).
   - `resolvedSingleWindowWidth(for:in:gaps:)` is at `NiriLayout.swift:707-720`
     (discovery said `:700-707`). The `hasManualSingleWindowWidthOverride` guard
     is at `:716-718`; the `cachedWidth`-returning branch is at `:720`.
   - `effectiveDefaultColumnWidth(in:)` is at
     `NiriLayoutEngine+Monitors.swift:87-89` (discovery said `:81-83`).
   - `moveWindowToWorkspace` is at `NiriLayoutEngine+WorkspaceOps.swift:19-67`;
     its two `initializeNewColumnWidth` calls are at `:42` and `:46`; the
     post-append `clearLoneWindowLayoutWidthOverride` loop is at `:52-56`.

2. **The admission entry now carries the whole `ruleEffects` struct, not
   individual `minWidth`/`minHeight` fields (load-bearing — simplifies the
   plan).** The discovery assumed per-field plumbing at `WMController.swift` and
   the entry build. The current source stores
   `WindowModel.Entry.ruleEffects: ManagedWindowRuleEffects` wholesale
   (`WindowModel.swift:187`); it is populated from `decision.ruleEffects` in
   `LayoutRefreshController.swift:1380-1388`
   (`controller.workspaceManager.addWindow(..., ruleEffects: ruleEffects, ...)`,
   where `ruleEffects` is `decision.ruleEffects` or the existing entry's) and in
   `WMController.swift:1597` (`ruleEffects: decision.ruleEffects`). Consequently
   **adding `initialColumnWidth` to `ManagedWindowRuleEffects` automatically
   flows it onto the admission entry** — no `WMController`/`LayoutRefreshController`
   entry-build edits are required for the effect to reach the engine boundary.
   The only consumer-side edit is the engine admission path (see Scope).

3. **Engine consumption design — plumb a per-token provider through `syncWindows`
   → `addWindow`, not a `bundleId` lookup inside the engine.** The engine has no
   access to `ManagedWindowRuleEffects`; that lives in the controller layer. The
   clean boundary is: `NiriLayoutHandler.syncAndInsert` already has `controller`
   (`NiriLayoutHandler.swift:29`, a `weak var controller: WMController?`) and
   already iterates new tokens after `syncWindows` (`:494`). It builds an
   `initialColumnWidth: (WindowToken) -> CGFloat?` provider that reads
   `controller?.workspaceManager.entry(for: token)?.ruleEffects.initialColumnWidth`
   and passes it into `syncWindows`, which resolves it per-token and forwards a
   plain `CGFloat?` into `addWindow` → `initializeNewColumnWidth`. This keeps the
   rule system out of the layout engine (the engine sees only an optional
   proportion) and matches the discovery's "plumb the token's effect through"
   recommendation.

4. **Reusing `hasManualSingleWindowWidthOverride` for a rule-set width is a
   deliberate semantic decision (the discovery flagged this as a gotcha).** The
   lone-window `.fill` policy ignores `column.width` unless that flag is true
   (`NiriLayout.swift:716-718`), so the flag *must* be set for the rule to take
   effect on an empty workspace. Treat a rule-set initial width as a non-default
   (i.e. "manual") width. This composes correctly with:
   - the `addingSecondWindow` reset loop (`NiriLayoutEngine+Windows.swift:152-155`),
     which skips manual columns — a rule-set column is not stripped when a second
     window joins;
   - the workspace-assignment transient-override split — a manual column never
     receives a `loneWindowLayoutWidthOverride` (only the `else` branch at
     `NiriLayout.swift:831-835` sets it), so nothing stale is left behind;
   - the planned BarutSRB/OmniWM#295 preserve-on-move, which copies source width state only when
     `hasManualSingleWindowWidthOverride == true` — so a rule-set width is carried
     across a workspace move once BarutSRB/OmniWM#295 lands.

5. **`moveWindowToWorkspace` is left unchanged in this plan (defer to BarutSRB/OmniWM#295).**
   The discovery's precedence ("a moved window with a rule uses the rule width")
   is satisfied compositionally: the rule sets the proportion + the manual flag
   at fresh admission, and BarutSRB/OmniWM#295's `applySourceColumnWidthOrReset` preserves that
   state across a move. Until BarutSRB/OmniWM#295 lands, a moved rule-set window resets to the
   target workspace default — a known transient gap, called out under Risks and
   in the BarutSRB/OmniWM#295 coordination test.

6. **Optional validator addition.** `IPCRuleValidator`
   (`Sources/NehirIPC/IPCRuleValidator.swift`) currently validates only
   `bundleId` and `titleRegex`; it does not validate `minWidth`/`minHeight`.
   Add a `0.0...1.0` range check for `initialColumnWidth` (return a descriptive
   error outside the range) so bad CLI/IPC input is rejected at the same gate as
   a malformed bundle id. This is additive and low-risk.

## Scope

### Files to add/change

**Config / model**

1. `Sources/Nehir/Core/Config/AppRule.swift`
   - Add `case initialColumnWidth` to `CodingKeys` (after `minHeight`, `:54`).
   - Add `var initialColumnWidth: Double?` to the stored fields (after `minHeight`, `:68`).
   - Add `initialColumnWidth: Double? = nil` to the memberwise init (`:70-94`) and
     its body.
   - Add `initialColumnWidth = try container.decodeIfPresent(Double.self, forKey: .initialColumnWidth)`
     to `init(from decoder:)` (after `minHeight`, `:149`).
   - Add `|| initialColumnWidth != nil` to `hasAnyRule` (`:128-132`) so a rule
     carrying only an initial width counts as a real rule.
   - `AppRule` is `Codable` via the explicit `CodingKeys` + custom `init(from:)`,
     so both must be updated (auto-synthesis is not used here).

2. `Sources/Nehir/Core/Rules/WindowRuleEngine.swift`
   - Add `var initialColumnWidth: Double?` to `ManagedWindowRuleEffects` (`:46-51`,
     after `minHeight`).
   - In `decision(for:)`'s effects construction (`:353-357`), add
     `initialColumnWidth: userRule?.rule.initialColumnWidth`.
   - The static `WindowRuleDebugSnapshot` carrier (`:154-156`, `:195`) is a
     debug-only mirror; extend it with `initialColumnWidth` for trace completeness
     (optional but consistent).

**Effect flows onto the entry automatically** — `WindowModel.Entry.ruleEffects`
(`WindowModel.swift:187`) carries the whole `ManagedWindowRuleEffects`, and the
admission build sites
(`LayoutRefreshController.swift:1380-1388`, `WMController.swift:1597`,
`AXEventHandler.swift:1170`/`:3150`) forward `decision.ruleEffects` wholesale.
**No edits there.**

**File store / TOML**

3. `Sources/Nehir/Core/Config/AppRuleFileStore.swift`
   - Encode: add
     `if let w = rule.initialColumnWidth { effectLines.append("initialColumnWidth = \(formatNumber(w))") }`
     in the `[effect]` block (after `minHeight`, `:63`).
   - Decode: add
     `initialColumnWidth: extractDouble(effectFields["initialColumnWidth"])`
     to the `AppRule(...)` construction (`:153-154`).
   - Optionally add a fourth inactive sample under `writeInactiveSamples`
     (`:167+`) demonstrating the field; not required for correctness.

**IPC / CLI plumbing**

4. `Sources/NehirIPC/IPCModels.swift`
   - Add `public let initialColumnWidth: Double?` + init param to
     `IPCRuleDefinition` (`:1546-1583`).
   - Add the same to `IPCRuleSnapshot` (`:2364-2421`).
   - (Both types use auto-synthesized `Codable` — no `CodingKeys` edits needed.)
   - Optional: add to `IPCFocusedWindowDecisionSnapshot` (`:2484-2543`) for
     debug-snapshot parity with `minWidth`/`minHeight`/`matchedRuleId`.

5. `Sources/Nehir/IPC/IPCRuleProjection.swift`
   - Four minWidth/minHeight pairs to mirror with `initialColumnWidth`:
     `:47-48` (snapshot from definition), `:66-67` (definition from rule),
     `:84-85` (appRule from definition), `:99-100` (normalized).

6. `Sources/NehirIPC/IPCAutomationManifest.swift`
   - Add a `--initial-column-width` option descriptor to
     `ruleDefinitionOptionDescriptors` (`:835-887`), after `--min-height` (`:882`).
     Suggested summary: "Set the initial tiled column width as a 0.0–1.0
     fraction of the working area, applied once when a matching window creates a
     column."; placeholder `<fraction>`.

7. `Sources/NehirCtl/CLIParser.swift`
   - Add `var initialColumnWidth: Double?` to the local parsing vars (`:362-363`).
   - Add a `case "--initial-column-width":` arm (`:398-401`) parsing the value
     (use a bounded 0.0–1.0 parse helper, or `parsePositiveDouble` plus a range
     check that throws `CLIParseError.usage`).
   - Pass `initialColumnWidth: initialColumnWidth` into the `IPCRuleDefinition`
     construction (`:414-424`).
   - `ruleDefinitionOptionFlags` (`:45`) and `CLICompletionGenerator`
     (`CLICompletionGenerator.swift:325`) derive from the manifest, so they pick
     up the new flag automatically — no edit.

8. `Sources/NehirIPC/IPCRuleValidator.swift` (optional, recommended)
   - Add `initialColumnWidthError(for:) -> String?` returning a descriptive
     error when the value is outside `0.0...1.0`, and surface it in
     `IPCRuleValidationReport` + `validate(_:)` (`:46-52`).

**Engine consumption**

9. `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine.swift`
   - Extend `initializeNewColumnWidth(_:in:)` (`:235-246`) with a trailing
     `initialProportion: CGFloat? = nil`:

     ```swift
     func initializeNewColumnWidth(
         _ column: NiriContainer,
         in workspaceId: WorkspaceDescriptor.ID,
         initialProportion: CGFloat? = nil
     ) {
         if let initialProportion {
             let clamped = initialProportion.clamped(to: 0...1)
             column.width = .proportion(clamped)
             column.presetWidthIdx = matchingPresetIndex(for: clamped)
         } else {
             let resolvedWidth = resolvedColumnResetWidth(in: workspaceId)
             column.width = .proportion(resolvedWidth.proportion)
             column.presetWidthIdx = resolvedWidth.presetWidthIdx
         }
         column.cachedWidth = 0
         column.isFullWidth = false
         column.savedWidth = nil
         column.hasManualSingleWindowWidthOverride = (initialProportion != nil)
         column.widthAnimation = nil
         column.targetWidth = nil
     }
     ```

   - Existing callers that omit the parameter (notably both branches of
     `moveWindowToWorkspace` at `NiriLayoutEngine+WorkspaceOps.swift:42`/`:46`,
     and BarutSRB/OmniWM#295's planned `applySourceColumnWidthOrReset`) keep current behavior.

10. `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+Windows.swift`
    - Add `initialColumnWidth: CGFloat? = nil` to `addWindow`
      (`:122-126`), and pass it into both `initializeNewColumnWidth` calls
      (`:131`, `:159`):
      `initializeNewColumnWidth(existingColumn, in: workspaceId, initialProportion: initialColumnWidth)`
      and the same for `newColumn`.
    - Add `initialColumnWidth: ((WindowToken) -> CGFloat?)? = nil` provider to
      `syncWindows` (`:608-613`); at the `addWindow` call site (`:630`), resolve
      it per token:
      `initialColumnWidth: initialColumnWidth?(token)`.

11. `Sources/Nehir/Core/Controller/NiriLayoutHandler.swift`
    - In `syncAndInsert`, build the provider and pass it into `syncWindows`
      (`:494-501`):

      ```swift
      let initialColumnWidthProvider: (WindowToken) -> CGFloat? = { token in
          guard let value = controller?.workspaceManager.entry(for: token)?.ruleEffects.initialColumnWidth
          else { return nil }
          return CGFloat(value)
      }
      _ = pass.engine.syncWindows(
          windowTokens,
          in: pass.wsId,
          selectedNodeId: currentSelection,
          focusedToken: preferredWorkspaceFocusToken,
          initialColumnWidth: initialColumnWidthProvider
      )
      ```

    - The provider is consulted only inside `addWindow`, which `syncWindows`
      calls solely for tokens not already in the engine, so the rule fires once
      per fresh admission and never re-applies on subsequent passes.

12. `Tests/NehirTests/TokenCompatibilityTestSupport.swift`
    - Extend the test-only `addWindow(handle:to:afterSelection:focusedHandle:)`
      wrapper (`:111-124`) with `initialColumnWidth: CGFloat? = nil`, forwarding
      it to the token-based `addWindow`. Also extend the test-only
      `syncWindows(_ handles:...)` wrapper (`:126-138`) analogously if any test
      drives admission through it.

**UI surface (so the field is reachable from Settings, not just TOML/CLI)**

13. `Sources/Nehir/UI/AppRuleDraft.swift`
    - Add `var initialColumnWidthEnabled: Bool` and `var initialColumnWidth: Double`
      (default `false` / `0.5`) to the stored fields (`:34-37`), the default init
      (`:54-57`), `init(rule:)` (`:75-78`: `initialColumnWidthEnabled =
      rule.initialColumnWidth != nil; initialColumnWidth = rule.initialColumnWidth ?? 0.5`),
      and `makeRule()` (`:134-135`: `initialColumnWidth: initialColumnWidthEnabled ?
      initialColumnWidth : nil`).

14. `Sources/Nehir/UI/AppRulesView.swift`
    - Add a `Toggle("Initial Column Width", isOn: $draft.initialColumnWidthEnabled)`
      plus a guarded `TextField`/`Stepper` (0.0–1.0) in **both** form locations
      that render the `minWidth`/`minHeight` toggles (`:342-358` add-draft form
      and `:520-534` edit-draft form), mirroring their layout exactly.

**Docs**

15. `docs/CONFIGURATION.md`
    - Extend the app-rules `[effect]` example (`:208-219`) to mention
      `initialColumnWidth`, e.g. add a commented line:
      `# initialColumnWidth = 0.5   # 0.0–1.0 of working-area width; applied once at column creation`
      and a one-sentence note that it is applied once at column creation and is
      orthogonal to `minWidth`.

### Non-goals

- Do **not** make `initialColumnWidth` a continuous constraint (it is not a
  floor). It is consumed **once, at column creation**, never re-merged into the
  relayout floor. The existing `minWidth` floor stays the only continuous
  per-app width effect.
- Do **not** change `moveWindowToWorkspace` in this plan. Move-path rule
  preservation is delegated to BarutSRB/OmniWM#295 (see "Discovery corrections / decisions" #5
  and Risks).
- Do **not** retroactively apply the rule to windows that are already admitted
  when a rule is added/edited. The effect is "initial" — it fires on the next
  fresh admission of a matching window, mirroring how `minWidth` (continuous) is
  the only effect that touches already-admitted windows.
- Do **not** change the lone-window `.fill`/`.centered` policy, preset-width
  cycling, the `addingSecondWindow` reset loop, or the workspace-assignment
  transient-override split.
- Do **not** add a setting/toggle to disable the feature; it is strictly
  additive and inert when no rule sets the field.
- Do **not** port BarutSRB/OmniWM#384 (it is already satisfied in Nehir; see the noop
  doc). The min-size floor interaction is handled by existing
  `resolveSpan`/`widthBounds` clamping.
- Do **not** model fixed-pixel initial widths; the field is a proportion only,
  matching the issue's "50% relative to current screen" ask.

## Exact implementation plan

### Phase 1 — Config model + rule-engine effect

1. Edit `AppRule.swift` per Scope #1 (field, CodingKey, memberwise init,
   `init(from:)`, `hasAnyRule`).
2. Edit `WindowRuleEngine.swift` per Scope #2 (`ManagedWindowRuleEffects` field +
   `decision(for:)` effects construction).
3. `swift build` — confirm the model compiles. Existing
   `ManagedWindowRuleEffects` call sites continue to compile because the new
   field is optional with no required init change (memberwise init gets the new
   `nil` default).

### Phase 2 — TOML + IPC + CLI plumbing

4. Edit `AppRuleFileStore.swift` (Scope #3), `IPCModels.swift` (#4),
   `IPCRuleProjection.swift` (#5), `IPCAutomationManifest.swift` (#6),
   `CLIParser.swift` (#7), and optionally `IPCRuleValidator.swift` (#8).
5. `swift build` — confirm both `Nehir` and `NehirCtl`/`NehirIPC` compile and
   the projection round-trips (`AppRule` ↔ `IPCRuleDefinition` ↔ `AppRule`).

### Phase 3 — Engine consumption

6. Extend `initializeNewColumnWidth` (Scope #9).
7. Extend `addWindow` + `syncWindows` (Scope #10).
8. Wire the provider in `NiriLayoutHandler.syncAndInsert` (Scope #11).
9. Extend the test-support wrapper (Scope #12).
10. `swift build`.

### Phase 4 — UI surface

11. Edit `AppRuleDraft.swift` (Scope #13) and `AppRulesView.swift` (Scope #14).
12. `swift build`.

### Phase 5 — Tests + docs

13. Add/extend tests per `## Tests`.
14. Update `docs/CONFIGURATION.md` (Scope #15).
15. Run the full validation block.

## Tests

### `Tests/NehirTests/NiriLayoutEngineTests.swift` (admission consumption)

Add near the existing `addingSecondWindowReturnsToNormalColumnSizingAfterSingleWindowOverride`
test (`:1543`). Use `NiriLayoutEngine(balancedColumnCount: 3)`, `makeTestHandle()`,
a `UUID` workspace id, and the same `makeLayoutPlanTestMonitor()` /
`calculateCombinedLayoutWithVisibility(in:monitor:gaps:state:)` harness as that
test.

1. **`initialColumnWidthEffectSetsProportionAndManualFlagOnAdmission`**
   - `engine.addWindow(handle:to:afterSelection:initialColumnWidth: 0.5)`.
   - Grab the column via `engine.column(of: window)`; assert
     `column.width == .proportion(0.5)`, `column.hasManualSingleWindowWidthOverride == true`,
     and `column.presetWidthIdx == matchingPresetIndex(for: 0.5)` (or `nil` if
     0.5 is not a preset).
   - Locks in: the rule is consumed at column creation and sets the manual flag.

2. **`initialColumnWidthRendersAtRuleFractionForLoneWindow`**
   - Admit one window with `initialColumnWidth: 0.5` on a fixture monitor with
     `visibleFrame.width = 2000`, `gap = 8`.
   - Run `calculateCombinedLayoutWithVisibility`; assert the rendered frame width
     is ~`1000 - 2*8` (≈ 984), i.e. ~50% — **not** ~2000 (which would be `.fill`).
   - Locks in: the lone-window `.fill` policy is bypassed because the manual flag
     is set (the §4 gotcha in the discovery).

3. **`initialColumnWidthBelowMinSizeFloorIsClampedUp`**
   - Admit one window with `initialColumnWidth: 0.3` (→ ~600px on a 2000px
     monitor) and call `engine.updateWindowConstraints(for: handle,
     constraints: WindowSizeConstraints(minSize: CGSize(width: 900, height: 1)))`
     to model an enforced app min (BarutSRB/OmniWM#384 floor).
   - Assert the rendered frame width is `>= 900` — the floor wins over the rule,
     never sub-minimum.
   - Locks in: the BarutSRB/OmniWM#384 floor interaction is handled by existing clamp machinery
     (`resolveSpan`/`widthBounds` + `clampColumnWidthToBounds`).

4. **`initialColumnWidthAppliedOnceNotOnEveryAppend`**
   - Admit window A with `initialColumnWidth: 0.5`. Admit window B (same or
     different handle, no rule) into the same workspace via the same
     `initialColumnWidth: 0.5` provider (or `nil`).
   - Assert window A's column width is unchanged by B's admission; the rule fired
     at A's creation only.
   - Locks in: one-shot consumption, not continuous.

5. **`initialColumnWidthNilFallsBackToWorkspaceDefault`**
   - Admit a window with `initialColumnWidth: nil` on an engine whose
     `defaultColumnWidth` resolves to a known fraction (e.g. `0.7`).
   - Assert `column.width == .proportion(0.7)` and
     `column.hasManualSingleWindowWidthOverride == false`.
   - Locks in: the feature is strictly additive — no-rule behavior is unchanged.

6. **Existing regression stays green.**
   `addingSecondWindowReturnsToNormalColumnSizingAfterSingleWindowOverride`
   (`:1543`) and `defaultColumnWidthMatchingPresetKeepsCenteredLoneWindowUntilManualResize`
   (`:1500`) do not pass an `initialColumnWidth`, so they take the `nil` branch
   and keep their current assertions. No edit required; rerun to confirm.

### `Tests/NehirTests/WindowRuleEngineTests.swift` (effect flows into decision)

Add next to the existing `minWidth` effect assertion
(`moreSpecificTitleRuleBeatsGenericBundleRule`, `:118-149`):

7. **`initialColumnWidthEffectFlowsIntoRuleEffects`**
   - Register a rule with `bundleId` + `initialColumnWidth: 0.5`.
   - Evaluate a matching window; assert `decision.ruleEffects.initialColumnWidth == 0.5`
     and `decision.ruleEffects.matchedRuleId == rule.id`.
   - Locks in: the new effect rides the existing `ManagedWindowRuleEffects`
     pipeline.

### `Tests/NehirTests/TokenCompatibilityTestSupport.swift`-driven / new TOML round-trip

8. **`appRuleFileStoreRoundTripsInitialColumnWidth`** (add to a new
   `AppRuleFileStoreTests.swift` or to `ConfigMismatchDetectorTests.swift`):
   - `AppRuleFileStore.encode` a rule with `initialColumnWidth: 0.5` plus
     `minWidth`/`minHeight`; decode the result; assert all three survive.
   - Locks in: TOML `[effect]` encode/decode parity.

### `Tests/NehirTests/CLIParserTests.swift` + `IPCModelsTests.swift`

9. **`cliParsesInitialColumnWidthFlag`** — `rule add --bundle-id … --initial-column-width 0.5`
   yields an `IPCRuleDefinition` with `initialColumnWidth == 0.5`; out-of-range
   values (`1.5`, `-0.1`) are rejected with `CLIParseError.usage` (if the
   validator/parse helper is added).
10. **`ipcRuleDefinitionCodableRoundTripsInitialColumnWidth`** — encode/decode an
    `IPCRuleDefinition` and `IPCRuleSnapshot` carrying the field.

### `Tests/NehirTests/AppRuleDraftTests.swift`

11. **`appRuleDraftRoundTripsInitialColumnWidth`** — `AppRuleDraft(rule:)` reads
    the field; `makeRule()` writes it back; the disabled toggle yields `nil`.

### Cross-workspace move precedence (BarutSRB/OmniWM#295 coordination — gated)

12. **`movedRuleSetWindowKeepsRuleWidthAfterMove`** — add to
    `NiriLayoutEngineTests.swift` **only after BarutSRB/OmniWM#295 lands**. Admit a window with
    `initialColumnWidth: 0.5`, then `moveWindowToWorkspace` it to a fresh
    workspace; assert the target column still carries `.proportion(0.5)` and the
    manual flag (delivered by BarutSRB/OmniWM#295's `applySourceColumnWidthOrReset`, not by this
    plan). Until BarutSRB/OmniWM#295 lands, document this test as expected-to-fail-on-move and
    keep it behind the BarutSRB/OmniWM#295 coordination note.

## Validation

```bash
swift build

# Engine admission consumption + floor interaction
swift test --filter NiriLayoutEngineTests/initialColumnWidthEffectSetsProportionAndManualFlagOnAdmission
swift test --filter NiriLayoutEngineTests/initialColumnWidthRendersAtRuleFractionForLoneWindow
swift test --filter NiriLayoutEngineTests/initialColumnWidthBelowMinSizeFloorIsClampedUp
swift test --filter NiriLayoutEngineTests/initialColumnWidthAppliedOnceNotOnEveryAppend
swift test --filter NiriLayoutEngineTests/initialColumnWidthNilFallsBackToWorkspaceDefault

# Whole-engine Niri suite (catches accidental regressions in column/sizing paths)
swift test --filter NiriLayoutEngineTests

# Rule pipeline
swift test --filter WindowRuleEngineTests

# Config / TOML / IPC / CLI
swift test --filter AppRuleFileStore
swift test --filter CLIParserTests
swift test --filter IPCModelsTests
swift test --filter IPCRuleRouterTests
swift test --filter AppRuleDraftTests

# Whole-program check (format + lint + build + test)
mise run check
```

Manual validation on a host with the default lone-window `.fill` policy:

1. Add `apprules.d/net.kovidgoyal.kitty.toml` with `[match] bundleId =
   "net.kovidgoyal.kitty"` and `[effect] initialColumnWidth = 0.5`.
2. Open Kitty on an empty workspace; confirm it renders at ~50% of the working
   width (not 100%).
3. Open a second, non-matching app into the same workspace; confirm Kitty's
   column keeps its ~50% width (the manual flag is preserved by the
   `addingSecondWindow` loop).
4. Add a `minWidth = 1200` effect to the same rule, set the rule fraction to
   `0.3`, and reopen Kitty on a ~3000px-wide monitor; confirm the column clamps
   up to ~1200 (the floor wins) rather than rendering at ~900.
5. Remove the rule file; confirm Kitty admits at the workspace default again.

Changeset (minor): "Add per-app initial column width as an App Rule effect
(BarutSRB/OmniWM#283)."

## Risks and mitigations

- **`hasManualSingleWindowWidthOverride` semantic overload (MED).** Reusing the
  "manual" flag for a rule-set width is deliberate (see "Discovery corrections /
  decisions" #4) but means the flag no longer exclusively means "user resized."
  Mitigation: the only behavioral consequence is that the lone-window policy
  honors the width and BarutSRB/OmniWM#295 preserves it on move — both desirable for an initial
  width. Document the overload at the `initializeNewColumnWidth` call site. If a
  future feature needs to distinguish rule-set from user-resized, introduce a
  separate flag then; do not preemptively split now.
- **Move-path gap until BarutSRB/OmniWM#295 lands (MED).** A moved rule-set window resets to
  the target workspace default until BarutSRB/OmniWM#295's preserve-on-move is implemented.
  Mitigation: the rule re-applies on the *next fresh admission* of a matching
  window; for the common "open app, it goes to the right workspace" flow the
  width is correct. Track the gap via the gated coordination test #12 and the
  BarutSRB/OmniWM#295 plan's "Follow-ups" cross-reference.
- **Provider closure built every layout pass (LOW).** `syncAndInsert` constructs
  the `(WindowToken) -> CGFloat?` closure on every pass even when no new tokens
  are admitted. Mitigation: the closure is cheap and only consulted inside
  `addWindow` (which is skipped when all tokens exist). If profiling ever shows
  cost, gate the provider behind a `newTokens.isEmpty == false` check before
  passing it in.
- **Out-of-range proportion from hand-edited TOML (LOW).** A user could write
  `initialColumnWidth = 1.5`. Mitigation: `initializeNewColumnWidth` clamps with
  `.clamped(to: 0...1)`, and the optional `IPCRuleValidator` range check rejects
  it at the CLI/IPC gate. The TOML path is best-effort (TOML has no schema); the
  engine clamp is the safety net.
- **`presetWidthIdx` drift across engines (LOW).** `matchingPresetIndex` returns
  a preset index only when the rule fraction lands on a preset; otherwise `nil`.
  Presets are engine-global, so the index is valid on any workspace. No
  mitigation needed.
- **Existing admission-flow tests (LOW).** Tests that drive admission through
  `engine.addWindow(handle:...)` omit the new optional parameter and take the
  `nil` branch, so `addingSecondWindow…` and `defaultColumnWidthMatchingPreset…`
  stay green. Rerun the full `NiriLayoutEngineTests` suite to confirm.

## Follow-ups (out of scope)

- **Move-path rule preservation (BarutSRB/OmniWM#295).** Land BarutSRB/OmniWM#295's
  `applySourceColumnWidthOrReset` so a moved rule-set window keeps its width.
  This plan sets the flag BarutSRB/OmniWM#295 keys off; the two compose without further
  BarutSRB/OmniWM#283-side work. See `planned/20260621-omniwm-295-niri-window-width-preservation.md`.
- **Re-apply on rule edit.** Today, editing/adding a rule does not retroactively
  resize already-admitted windows (the effect is "initial"). If user feedback
  wants "apply now," add a one-shot controller command that, for each matching
  tracked window whose column is a fresh single, reapplies the proportion. Out
  of scope here.
- **Per-app `>100%` initial width (BarutSRB/OmniWM#326).** Independent; the clamp to
  `0...1` would need widening if BarutSRB/OmniWM#326 lands. The proportion storage
  (`.proportion(...)`) already supports values `>1.0` structurally.
- **Fixed-pixel initial width.** The issue asks only for a proportion. A future
  `.fixed` variant would reuse `ProportionalSize.fixed` but needs cross-monitor
  DPI policy; deferred.
- **Debug-snapshot surface.** `IPCFocusedWindowDecisionSnapshot` and the
  `WindowDecisionDebugSnapshot` mirror can optionally carry `initialColumnWidth`
  for diagnostic parity; not required for the feature.
