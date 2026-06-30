# Sticky window effect, PiP defaulting, and advanced ignore action

**Status:** completed — implemented on branch `patch/pip-sticky-unmanaged` at `f141c120` (baseline `196dee9a`), 2026-06-26. Not yet merged to `main`. Full suite green (`mise run test` → 1346 tests in 111 suites). Changeset `.changeset/20260626014016-add-sticky-and-ignore-app-rule-plumbing.md`. Moved from `planned/` to `completed/` on 2026-06-26.
**Plan date:** 2026-06-26
**Related issue:** PiP behavior expectations / follow-up to #108
**Related docs:** `completed/20260624-nehir-108-pip-disappears-and-snaps-back-on-workspace-switch.md`, `completed/20260624-user-addressable-floating-surfaces.md`

All source references below were re-verified against the main Nehir source tree at
`196dee9a` (`Close inactive-workspace .show reveal and multi-monitor drift gaps`) on
2026-06-26. Line numbers drift — re-verify before editing.

The runtime evidence below is inlined from the 2026-06-25 PiP capture. No trace-log
filename is referenced; the document stands on the quoted evidence.

## Implementation outcome

Shipped on `patch/pip-sticky-unmanaged` at `f141c120` (baseline `196dee9a`). The
implementation follows the proposed design with the runtime-driven deviations and
limitations recorded below.

### What shipped

- **Sticky as an effect/source overlay, not a third mode.** `TrackedWindowMode`
  stays `.tiling` / `.floating`; sticky rides on rule effects
  (`ManagedWindowRuleEffects.sticky`) and source sets in `WorkspaceManager`
  (`globalStickyWindowTokens`, `manualStickyWindowTokens`,
  `manualUnstickyWindowTokens`, `stickyFloatingPromotionTokens`).
  `Sources/Nehir/Core/Workspace/WorkspaceManager.swift`,
  `Sources/Nehir/Core/Rules/WindowRuleEngine.swift`.
- **`manage = ignore` management action.** `WindowRuleManageAction` gained
  `.ignore`; `AppRuleFileStore`, `AppRuleDraft`, `AppRulesView`, IPC rule
  definition/snapshot, `CLIParser` / `CLIRenderer`, and the automation manifest
  all carry it. Ignore wins over `layout` and produces
  `WindowDecisionDisposition.unmanaged` / `admissionOutcome = .ignored`.
  `Sources/Nehir/Core/Config/AppRule.swift`, `Sources/NehirIPC/IPCModels.swift`,
  `Sources/Nehir/IPC/IPCRuleProjection.swift`.
  Ignore rules render an `Ignore` sidebar badge and suppress
  layout/sticky/workspace/size badges in the App Rules UI.
- **Sticky app-rule effect (`sticky = true|false`).** Same surfaces as above;
  `sticky = false` opts a match out of PiP default sticky.
- **PiP default sticky classifier.** `WindowRuleFacts.pipDefaultStickyCandidate`
  marks top-level (`parentId == 0`), above-normal, standard-AX PiP-like surfaces
  sticky by default, including `AXSystemDialogSubrole` media-like cases. A shared
  `isTopLevelResizableMediaLikeSurfaceFrame(...)` frame heuristic gates the
  resizable-media shape and is reused by the degraded WindowServer child path.
  `Sources/Nehir/Core/Rules/WindowRuleEngine.swift`.
- **Manual sticky / unsticky and command targeting.** New
  `toggleFocusedWindowSticky` / `toggleWindowSticky(token:)`, IPC command
  (`toggle-focused-window-sticky`), action-catalog entry, hotkey config mapping,
  and a separate workspace-bar sticky section (`WorkspaceBarProjection.sticky`,
  `WorkspaceBarStickyItem`, `StickyPillView`). Manual unsticky overrides
  automatic sources; `hasStickyWindowSource(_:)` (command eligibility) is kept
  separate from `isStickyWindow(_:)` (effective behavior).
  `Sources/Nehir/Core/Controller/WMController.swift`,
  `Sources/Nehir/Core/Input/HotkeyCommand.swift`,
  `Sources/Nehir/Core/Input/ActionCatalog.swift`,
  `Sources/Nehir/IPC/IPCCommandRouter.swift`,
  `Sources/Nehir/UI/WorkspaceBar/WorkspaceBarView.swift`.
- **Sticky lifecycle.** `LayoutRefreshController` re-anchors sticky windows to
  active workspaces and skips parking them on workspace switch; sticky floating
  frame does not snap back after cross-monitor drag.
  `Sources/Nehir/Core/Controller/LayoutRefreshController.swift`.
- **Window-query `is-sticky` field** for automation.
  `Sources/Nehir/IPC/IPCQueryRouter.swift`, `Sources/NehirIPC/IPCAutomationManifest.swift`.
- **Lone-window far-overscroll** for single-column Niri workspaces (matches
  multi-column far-boundary behavior).
  `Sources/Nehir/Core/Layout/Niri/ViewportState+Geometry.swift`.
- **Docs** updated: `docs/CONFIGURATION.md`, `docs/glossary.md`,
  `docs/ARCHITECTURE.md`, `docs/IPC-CLI.md`, `docs/index.md`,
  `docs/window-parking-and-offscreen-clamp.md`, `docs/viewport-navigation-spec.md`.

### Runtime-driven deviations

These were driven by real captures (not trace files) during implementation:

- **No parented high-level WindowServer-only PiP admission.** An initial attempt
  added a parented popup-level candidate path to admit Safari/Dia/Atlas-style
  PiP that exposes no AX reference by window id. It was reverted because the same
  evidence shape is also used by browser **context menus**, which then got pinned
  as sticky windows. PiP detection stays conservative.
- **Degraded WindowServer child evidence scoping.** The media-like frame
  exemption in `degradedWindowServerChildEvidence` now only applies to actual
  top-level surfaces (`parentId == 0`); parented degraded children keep child
  evidence. This fixed a structural-rekey regression caught by tests.
- **Command target fallback.** A `samePidFloatingFallback` target was added so a
  tracked floating `AXDialog` PiP (e.g. Atlas) can be targeted for sticky/float
  commands ahead of the tiled main window. It was later tightened to exclude
  non-user-addressable transient helpers, and the untracked-frontmost-app guard
  was relaxed so unrelated frontmost app noise does not suppress confirmed
  managed-focus commands (a test regression).
- **Bar projection keeps sticky-source non-standard surfaces visible.**
  `barProjectionDecision` accepts a non-standard floating surface as a normal
  floating item when it still has a sticky source (e.g. a manually-unstuck PiP),
  so it does not look "lost" after manual unsticky.
- **Hide-plan AX fallback runs on nil readback too.** When a parked window's
  SkyLight frame readback is nil, the hide-plan verification now also runs the
  `AXWindowService.axWindowRef` + `setFrame` fallback (not only on origin
  delta).

### Limitations (documented, by design)

- **Safari, Dia, Arc, Atlas/ChatGPT native/helper PiP** expose only parented
  popup-level WindowServer children or generic `AXDialog` surfaces whose
  AX/WindowServer facts are indistinguishable from context menus / ordinary
  dialogs. Nehir does **not** auto-manage them as sticky PiP; they remain
  unmanaged / native-sticky. Workaround: explicit app rule matching stable facts
  (e.g. bundle id + `axSubrole = "AXDialog"` or a title pattern) with
  `layout = "float"` and `sticky = true`.
- **Chromium / Helium-style PiP** may only become trackable after the PiP
  receives focus or a click, because reliable AX facts are not available at
  creation time.

See `docs/CONFIGURATION.md` and `docs/glossary.md` for the user-facing wording.

### Test status

Existing suites extended for the new rule surfaces:
- `Tests/NehirTests/CLIParserTests.swift` — sample values for `--manage` / `--sticky`.
- `Tests/NehirTests/IPCModelsTests.swift` — manifest option flags include
  `--manage` / `--sticky`.
- `Tests/NehirTests/WindowRuleEngineTests.swift` — existing PiP / floating / tile
  coverage stays green, including the degraded child rekey guard.

No new PiP-runtime regression tests were added for the Safari/Dia/Atlas caveats:
the runtime-debugging workflow treats real captures as the acceptance signal, the
user confirmed the current behavior is the "best shape", and the limitations are
documented rather than enforced.

### Deferred

- A generic focused-window / workspace-bar **Ignore** command is intentionally
  still deferred (ignore is terminal and better reversed via rule surfaces).
- Scratchpad-vs-sticky unification (pin across workspaces and/or hide/summon) is
  left for a future slice.

---


The main source already answers the shape of the feature.

- Nehir has only **two tracked window modes**: `.tiling` and `.floating`
  (`Sources/Nehir/Core/Workspace/WindowModel.swift:10-13`).
- Nehir already has an internal **global-sticky** mechanism, but it is **not** a
  user-facing mode. It is derived from macOS Space membership
  (`Sources/Nehir/Core/SkyLight/SpaceTopology.swift:62-84`), collected in
  `Sources/Nehir/Core/Controller/LayoutRefreshController.swift:704-718`, stored as
  `globalStickyWindowTokens`
  (`Sources/Nehir/Core/Workspace/WorkspaceManager.swift:2971-2981`), and used to
  skip parking / preserve floating geometry
  (`Sources/Nehir/Core/Controller/LayoutRefreshController.swift:2360-2449`, `Sources/Nehir/Core/Workspace/WorkspaceManager.swift:3008-3075`).
- App rules, App Rules UI, IPC rule definitions, CLI rule parsing, and rule
  rendering currently expose only **`auto|tile|float`** plus workspace/size effects:
  `Sources/Nehir/Core/Config/AppRule.swift:23-39`, `Sources/Nehir/Core/Config/AppRuleFileStore.swift:60-64,151-154`,
  `Sources/Nehir/UI/AppRuleDraft.swift:28-46,69-94,123-134`, `Sources/Nehir/UI/AppRulesView.swift:214-239,314-359`,
  `Sources/NehirIPC/IPCModels.swift:130-133,1557-1591`,
  `Sources/Nehir/IPC/IPCRuleProjection.swift:36-52,55-100`,
  `Sources/NehirCtl/CLIParser.swift:353-424`,
  `Sources/NehirCtl/CLIRenderer.swift:350-365`,
  `Sources/NehirIPC/IPCAutomationManifest.swift:840-900`.
- `unmanaged` exists today only as an **internal decision disposition** and debug /
  query value (`Sources/Nehir/Core/Rules/WindowRuleEngine.swift:10-15`,
  `Sources/NehirIPC/IPCModels.swift:141-145`). User rules cannot request it as a
  layout: `WindowRuleLayoutAction` is only `auto|tile|float`
  (`Sources/Nehir/Core/Config/AppRule.swift:23-39`), and `explicitDecision` maps only
  `.float -> .floating`, `.tile -> .managed`, `.auto -> nil`
  (`Sources/Nehir/Core/Rules/WindowRuleEngine.swift:611-640`).
- However, current source already contains the right seam for exposing it cleanly:
  `AppRule` has a dormant `manage` field, but `WindowRuleManageAction` currently has
  only `.auto` (`Sources/Nehir/Core/Config/AppRule.swift:9-21,41-68`).

Therefore the correct product/implementation model is:

1. add a **first-class user-visible sticky effect** that users can apply to normal
   managed windows;
2. make **PiP default into that same sticky effect**;
3. expose **Ignore / Unmanaged** as a separate **management action**, **not** as a
   layout;
4. keep the internal tracked-mode model as **tiling/floating**, and layer sticky on
   top of it rather than inventing a PiP-only state.

## Source-backed answer on `unmanaged`

Yes — but **not as a layout**.

What the source says:

- `WindowDecisionDisposition` has `.managed`, `.floating`, `.unmanaged`, `.undecided`
  (`Sources/Nehir/Core/Rules/WindowRuleEngine.swift:10-15`).
- For `.unmanaged`, `trackedMode == nil` and `admissionOutcome == .ignored`
  (`Sources/Nehir/Core/Rules/WindowRuleEngine.swift:67-88`). That means
  `unmanaged` is fundamentally a **management decision**, not a tracked placement
  mode.
- `WindowRuleLayoutAction` only has `.auto`, `.tile`, `.float`
  (`Sources/Nehir/Core/Config/AppRule.swift:23-39`), and `IPCRuleLayout` also only
  has `.auto`, `.tile`, `.float` (`Sources/NehirIPC/IPCModels.swift:130-133`).
- `explicitDecision` therefore only returns `.floating` or `.managed`
  (`Sources/Nehir/Core/Rules/WindowRuleEngine.swift:611-640`).
- The only explicit `.unmanaged` paths in current source are built-ins such as:
  - system text input panels (`Sources/Nehir/Core/Rules/WindowRuleEngine.swift:348-359`),
  - transient system dialogs (`Sources/Nehir/Core/Rules/WindowRuleEngine.swift:549-566`),
  - Ghostty Quick Terminal overlay (`Sources/Nehir/Core/Rules/WindowRuleEngine.swift:592-608`).
- `AppRule` already has a `manage` field, but its enum currently has only one case,
  `.auto`, and current TOML/UI/IPC/CLI rule surfaces do not expose anything else
  (`Sources/Nehir/Core/Config/AppRule.swift:9-21,41-68`).

So if `unmanaged` is exposed, it should be exposed as a separate **manage** action
(e.g. UI label **Ignore**, internal mapping to `.unmanaged`), not as
`layout = "unmanaged"`.

## What the 2026-06-25 runtime capture proves

### 1. This capture does **not** answer the “other workspace / other monitor” question

At capture start:

```text
-- Monitor Topology --
ID(displayId: 1) isMain=true ... name=Built-in Retina Display
-- SpaceTopology --
mode=enabled activeSpaces=1 knownSpaces=1 windowRecords=11 globalSticky=0 nativeInactive=0
-- WorkspaceManager --
monitors=1 workspaces=7 visibleWorkspaces=1
```

So this is a **single-display** capture with `knownSpaces=1` and no observed global
sticky windows at capture start. It cannot prove whether a PiP was shown on another
monitor, and it cannot distinguish “ordinary current-Space window” from
“all-Spaces PiP” by Space membership alone.

That matches the source comment already present in
`Sources/Nehir/Core/SkyLight/SpaceTopology.swift:74-78`:

> On a single display `knownSpaceIds.count == 1` ... the case is left for a future
> user-declared `sticky` rule.

So the user-visible sticky effect is not just nice-to-have; current source already
names it as the missing single-display discriminator.

### 2. PiP shape is not stable across browsers

#### Vivaldi PiP: floated by heuristic, not by transient-surface rule

```text
window_decision token=WindowToken(pid: 1618, windowId: 24677)
  context=focused_admission disposition=floating source=heuristic
  bundleId=com.vivaldi.Vivaldi
  axRole=AXWindow axSubrole=AXStandardWindow
  hasCloseButton=true hasFullscreenButton=false hasZoomButton=true hasMinimizeButton=true
  axAttributeDiagnostics=... fetchFailure=invalid_fullscreen_button_type_treated_as_missing
  wsLevel=3 wsTags=0x100082c01 wsAttributes=0x3 wsParent=0
```

This PiP is:

- top-level (`wsParent=0`),
- above-normal (`wsLevel=3`),
- standard AX window-like,
- but **not** the transient non-document WindowServer shape.

#### Zen PiP: floated by `transientWindowServerSurface`

```text
window_decision token=WindowToken(pid: 87556, windowId: 28312)
  context=create disposition=floating source=builtInRule(transientWindowServerSurface)
  bundleId=app.zen-browser.zen titleLength=18
  axRole=AXWindow axSubrole=AXStandardWindow
  hasCloseButton=true hasFullscreenButton=true fullscreenButtonEnabled=true
  hasZoomButton=true hasMinimizeButton=true
  wsLevel=3 wsTags=0x3000001004c2802 wsAttributes=0x3 wsParent=0
```

#### Firefox PiP: same transient pattern as Zen

```text
window_decision token=WindowToken(pid: 87672, windowId: 28331)
  context=focused_admission disposition=floating source=builtInRule(transientWindowServerSurface)
  bundleId=org.mozilla.firefox titleLength=18
  axRole=AXWindow axSubrole=AXStandardWindow
  hasCloseButton=true hasFullscreenButton=true fullscreenButtonEnabled=true
  hasZoomButton=true hasMinimizeButton=true
  wsLevel=3 wsTags=0x3000001004c2802 wsAttributes=0x3 wsParent=0
```

### 3. Chromium-family PiP is not stable even within one browser family

The same Zen browser produced two materially different create paths.

#### First Zen PiP: normal create admission

```text
create_seen window=28312
window_decision ... context=create ... source=builtInRule(transientWindowServerSurface)
create_placement_resolved ... context_source=cgs_created native_monitor=Optional(...displayId: 1)
candidate_tracked token=WindowToken(pid: 87556, windowId: 28312)
```

#### Second Zen PiP: repeated create failure, later focused admission

```text
create_seen window=28322
prepare_create_rejected ... reason=missing_ax_ref ... attempt=1
prepare_create_rejected ... reason=missing_ax_ref ... attempt=2
prepare_create_rejected ... reason=missing_ax_ref ... attempt=3
prepare_create_rejected ... reason=missing_ax_ref ... attempt=4
prepare_create_rejected ... reason=missing_ax_ref ... attempt=5
```

followed later by:

```text
window_decision token=WindowToken(pid: 87556, windowId: 28322)
  context=focused_admission disposition=floating source=builtInRule(transientWindowServerSurface)
create_placement_resolved ... context_source=ax_focused_admission_synthesized native_monitor=nil
candidate_tracked token=WindowToken(pid: 87556, windowId: 28322)
```

So “first PiP open” and “second PiP open” can take different admission paths while
still deserving the same user-facing default.

### 4. Not every above-normal surface should inherit PiP defaults

The same capture also contains counterexamples:

```text
WindowToken(pid: 12808, windowId: 28284) ...
  mode=floating ... bundleId=com.openai.atlas role=AXWindow subrole=AXDialog windowLevel=3
  barFloating=rejected(nonStandardAXSurface)
```

and:

```text
WindowToken(pid: 94880, windowId: 28276) ...
  mode=floating ... bundleId=company.thebrowser.Browser role=AXHelpTag windowLevel=103
  transientWindowServerEvidence=true degradedWindowServerChildEvidence=true
```

So the denominator cannot be “everything above normal level” and cannot be
“everything transient”. The existing source already points in the same direction:
`WorkspaceManager.barProjectionDecision` only accepts global-sticky or
user-addressable standard AX surfaces, and rejects non-standard / child /
non-user-addressable transient helpers
(`Sources/Nehir/Core/Workspace/WorkspaceManager.swift:2691-2733`).

## Product decision

### External product language

User-facing behavior should be:

- **Sticky** is a window effect the user can apply to normal managed windows.
- **PiP is not special after admission.** It simply defaults into Sticky + Floating.
- **Ignore / Unmanaged** is an advanced rule action that tells Nehir to leave a
  matched window out of its managed model.

### Internal source model

Internally, this should **not** become `TrackedWindowMode.sticky`.

Reason:

- current source and IPC models only understand tracked window mode as
  `.tiling` or `.floating` (`Sources/Nehir/Core/Workspace/WindowModel.swift:10-13`,
  `Sources/NehirIPC/IPCModels.swift:103-106,2215-2261`),
- the current no-snap-back geometry preservation already lives on the floating path
  (`Sources/Nehir/Core/Workspace/WorkspaceManager.swift:3008-3075`),
- the current special-window precedents (`scratchpad`, `globalSticky`) are layered
  **on top of** the tracked-mode model rather than replacing it.

So the least-invasive and most source-aligned design is:

- keep tracked mode as **tiling/floating**,
- add a separate **sticky visibility effect / intent** for managed windows,
- add a separate **ignore/unmanaged management action** that yields
  `WindowDecisionDisposition.unmanaged`,
- compute **effective sticky** from user intent + PiP defaulting + native global
  evidence.

In other words: **product-level features, implementation-level orthogonal effects.**

## Proposed design

### 1. Add a user-facing sticky effect

Add a new explicit sticky field to the user-rule / automation model and a matching
manual command path.

The effect should be available across all supported surfaces:

- TOML app rules,
- App Rules UI,
- IPC rule definitions / snapshots,
- CLI rule add/replace/list,
- focused-window command path,
- workspace-bar window context menu,
- automation window queries.

### 2. Expose Ignore / Unmanaged as a separate management action

Use the dormant `manage` field as the primary seam.

Implementation shape:

- extend `WindowRuleManageAction` beyond `.auto`,
- expose a user-facing **Ignore** action in UI / docs,
- map it internally to `.unmanaged`,
- keep it separate from `layout`.

The important semantics are:

- **manage = ignore** → window is not tracked (`trackedMode == nil`) and its
  admission outcome is ignored;
- **layout** is irrelevant once ignore wins;
- PiP defaulting must never use ignore.

This avoids fighting the current architecture by pretending `unmanaged` is a third
layout mode.

### 3. PiP defaulting should set sticky, not ignore

PiP-like windows should default into sticky when they satisfy the current durable
shared denominator visible in both source and capture:

- top-level (`wsParent == 0`),
- floating / above-normal WindowServer level,
- standard AX window semantics,
- user-addressable rather than tiny helper / tag / child surface,
- normal persistent size.

This captures:

- Vivaldi heuristic PiP,
- Zen transient-surface PiP,
- Firefox transient-surface PiP,

without sweeping in Atlas dialogs or tiny AXHelpTag overlays.

### 4. Sticky should imply floating in the current implementation

If the user makes a tiled window sticky, Nehir should first move it to floating.

Why:

- there is no tracked sticky-tiling mode in current source,
- current cross-monitor sticky frame logic already assumes floating geometry,
- scratchpad already uses the same “promote out of tiling into a special
  floating-like behavior” pattern (`Sources/Nehir/Core/Controller/WMController.swift:3950-4040`).

So the contract should be:

- **sticky on a tiled window** → convert to floating, then mark sticky;
- **sticky off** → clear sticky effect; if no remaining rule/manual float intent
  exists, allow reevaluation back to tiling.

### 5. `globalSticky` stays as native/system evidence, not the whole feature

Current `globalStickyWindowTokens` should remain, but only as one source of
**effective sticky**.

The combined predicate should be something like:

- `nativeGlobalSticky` — derived from `SpaceTopology.isWindowOnAllKnownSpaces`
- `userRuleSticky`
- `manualSticky`
- `pipDefaultSticky`
- `effectiveSticky = nativeGlobalSticky || userRuleSticky || manualSticky || pipDefaultSticky`

Then the existing consumers should switch from “global sticky only” to “effective
sticky”, while still keeping the native-global subreason available for diagnostics.

### 6. Ignore / unmanaged remains terminal and ineligible for managed behaviors

Built-in unmanaged surfaces must remain unmanaged:

- system text input panels,
- transient system dialogs,
- Ghostty Quick Terminal overlay.

User-declared ignore should follow the same semantic family: once a rule says
ignore, the window should stay out of the managed-window state machine rather than
partially participating in sticky, scratchpad, workspace-bar, or floating-restore
behavior.

That is consistent with current source, where unmanaged windows are not tracked at
all (`Sources/Nehir/Core/Rules/WindowRuleEngine.swift:67-88,351-359,558-566,600-608`).

### 7. Non-user-addressable transient helpers should stay ineligible for ad hoc sticky toggles

Current source already blocks float toggling for non-user-addressable transient,
non-global surfaces (`Sources/Nehir/Core/Controller/WMController.swift:1351-1357,3922-3929`)
and hides them from the workspace bar unless they are standard,
user-addressable, or global-sticky
(`Sources/Nehir/Core/Workspace/WorkspaceManager.swift:2691-2733`).

Sticky should reuse the same gate for direct window actions. We should not add a
workspace-bar / hotkey / IPC toggle that starts pinning ephemeral Teams/Zoom helper
chips just because they happened to be tracked for lifecycle bookkeeping.

## Exact scope

### A. Rule schema / config / UI

1. `Sources/Nehir/Core/Config/AppRule.swift`
   - extend `WindowRuleManageAction` with an ignore/unmanaged case;
   - add `sticky: Bool?` to `AppRule` and `CodingKeys`.
2. `Sources/Nehir/Core/Config/AppRuleFileStore.swift`
   - write/read `manage = "ignore"` (or chosen raw spelling) and `sticky = true`
     in `[effect]` alongside `layout`, `minWidth`, `minHeight`,
     `assignToWorkspace`.
3. `Sources/Nehir/UI/AppRuleDraft.swift`
   - add draft state for manage action and sticky.
4. `Sources/Nehir/UI/AppRulesView.swift`
   - add management control in both edit and add panes;
   - add Sticky control;
   - add sidebar badges for Ignore and Sticky;
   - disable or clearly subordinate layout/sticky/workspace/size controls when
     Ignore is selected.

### B. IPC / CLI / automation rule surfaces

5. `Sources/NehirIPC/IPCModels.swift`
   - add a rule-manage enum/type;
   - add `manage` and `sticky` to `IPCRuleDefinition` and `IPCRuleSnapshot`.
6. `Sources/Nehir/IPC/IPCRuleProjection.swift`
   - project `manage` and `sticky` both directions.
7. `Sources/NehirCtl/CLIParser.swift`
   - parse manage rule option and sticky rule option.
8. `Sources/NehirCtl/CLIRenderer.swift`
   - render manage and sticky in rule list output.
9. `Sources/NehirIPC/IPCAutomationManifest.swift`
   - add manage/sticky rule option descriptors;
   - document any added window-query field such as `is-sticky`.
10. `Sources/NehirIPC/IPCRuleValidator.swift`
   - keep validation consistent if manage/sticky get normalization rules.

### C. Runtime model / rule engine

11. `Sources/Nehir/Core/Rules/WindowRuleEngine.swift`
   - extend rule effects to carry sticky intent;
   - honor user-declared ignore before layout classification;
   - add PiP/default sticky classification without relying on browser hardcodes;
   - keep built-in unmanaged paths unmanaged.
12. `Sources/Nehir/Core/Workspace/WindowModel.swift`
   - add stored sticky intent / override state on entries.
13. `Sources/Nehir/Core/Workspace/WorkspaceManager.swift`
   - add `isStickyWindow(_:)` / sticky-source helpers;
   - update bar projection and floating resolution to use effective sticky;
   - add query/debug helpers.
14. `Sources/Nehir/Core/Controller/LayoutRefreshController.swift`
   - re-anchor sticky windows to active workspaces the same way current source
     re-anchors global windows;
   - skip parking sticky windows in `hideWorkspace`;
   - exempt sticky windows from inactive-workspace drift accusations.

### D. Commands / hotkeys / workspace bar / IPC commands

15. `Sources/Nehir/Core/Input/HotkeyCommand.swift`
   - add focused sticky command.
16. `Sources/Nehir/Core/Input/ActionCatalog.swift`
   - add command-palette / default action entry for sticky.
17. `Sources/Nehir/Core/Config/HotkeyConfigMapping.swift`
   - add config mapping key for sticky.
18. `Sources/Nehir/Core/Controller/CommandHandler.swift`
   - route sticky command.
19. `Sources/Nehir/Core/Controller/WMController.swift`
   - add token-aware sticky toggle / assign path, parallel to floating/scratchpad.
20. `Sources/Nehir/IPC/IPCCommandRouter.swift`
   - expose sticky command over IPC.
21. `Sources/Nehir/UI/WorkspaceBar/WorkspaceBarView.swift`
   - add `Toggle Sticky` to the window icon context menu and action bundle.

### E. Automation window queries

22. `Sources/NehirIPC/IPCModels.swift`
   - extend `IPCWindowQuerySnapshot` with sticky state if automation should inspect
     it directly.
23. `Sources/NehirIPC/IPCAutomationManifest.swift`
   - add `is-sticky` to `windowFieldCatalog`.
24. `Sources/Nehir/IPC/IPCQueryRouter.swift`
   - populate the field.

### F. Explicitly deferred from this slice

25. Do **not** add a generic focused-window or workspace-bar **Ignore** command in the
    first slice.
    - Unlike Sticky, Ignore is terminal: the window disappears from managed queries /
      bar / command targeting as soon as it is applied.
    - Reversal is better handled through the rule surfaces first.

## Non-goals

- Do **not** expose `unmanaged` as an app-rule layout.
- Do **not** add a PiP-only runtime state.
- Do **not** rely only on `isWindowOnAllKnownSpaces`; current source already says
  single-display needs a user-declared sticky rule.
- Do **not** let sticky commands target built-in unmanaged windows or clearly
  non-user-addressable helper surfaces.
- Do **not** make PiP default to Ignore / Unmanaged.
- Do **not** invent tiled-all-workspaces semantics in this slice; current source is
  already structured around sticky + floating, not sticky + tiled.

## Acceptance / tests

At minimum, add source-backed tests for:

1. **Rule schema round-trip**
   - `AppRule` / TOML / IPC definition / IPC snapshot / CLI parser / CLI renderer all
     preserve `manage` and `sticky`.
2. **App rules surfaces**
   - App Rules add/edit forms persist Ignore and Sticky;
   - sidebar badges reflect them;
   - Ignore disables or suppresses contradictory controls.
3. **Ignore semantics**
   - user rule `manage = ignore` produces `.unmanaged`, `trackedMode == nil`, and
     `admissionOutcome == .ignored`;
   - ignore wins over `layout = tile|float` when both are present;
   - built-in unmanaged windows still resolve to `.unmanaged`.
4. **PiP defaulting**
   - Vivaldi-like heuristic PiP resolves to floating + sticky default.
   - Zen/Firefox transient-surface PiP resolves to floating + sticky default.
   - second Zen open (`context=create` vs `context=focused_admission`) yields the
     same effective sticky/floating behavior.
   - PiP defaulting does **not** resolve to Ignore.
5. **False-positive guards**
   - level-3 `AXDialog` and tiny helper/tag surfaces do not inherit PiP sticky default.
6. **Sticky lifecycle**
   - sticky window is not parked on workspace switch;
   - sticky window is re-anchored to the active workspace on its current monitor;
   - sticky floating frame does not snap back after cross-monitor drag.
7. **Workspace bar / commands / IPC**
   - workspace bar shows `Toggle Sticky` for eligible windows;
   - focused sticky command works through hotkey/command handler/IPC command router;
   - window query can report sticky state when requested.
8. **Ignore stays out of managed surfaces**
   - ignored windows do not appear in managed window queries or workspace-bar managed
     projections;
   - clearing the ignore rule allows ordinary admission again.
9. **Scratchpad interaction**
   - sticky and scratchpad remain coherent and non-contradictory.

## Recommendation

Ship this as:

- a **general sticky visibility effect with PiP defaulting**, and
- a separate advanced **Ignore / Unmanaged management action**.

Do **not** ship it as a PiP-only exception, and do **not** ship `unmanaged` as a
layout.

That is what both the current source and the capture support:

- source already has the internal no-parking / no-snap-back machinery,
- source already documents the missing single-display piece as a future
  user-declared sticky rule,
- source already models unmanaged as a management decision rather than a tracked
  placement mode,
- the capture shows PiP is too varied for browser-specific special casing,
- and the existing user-visible rule surfaces are broad enough that Sticky and
  Ignore should be threaded through them consistently rather than bolted onto one
  controller path.
