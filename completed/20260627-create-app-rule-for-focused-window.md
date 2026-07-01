# Command to create an app rule for the focused window — Discovery

**Status:** completed — the feature this discovery scoped shipped on `main` as
`472f7185` ("Add focused-window app rule action across surfaces") on 2026-06-30. It
added a "Create App Rule for Focused Window…" action that resolves the focused
window, builds a pre-filled `AppRuleDraft`, and opens Settings on the App Rules
tab, surfaced in both the command palette and the workspace-bar window-icon
right-click menu (assignable hotkey, no default). Moved from `discovery/` to
`completed/` on 2026-07-01. Backlog item #26 in
[`../planned/20260621-backlog-brainstorm.md`](../planned/20260621-backlog-brainstorm.md)
is now shipped.

Source: backlog item **#26** ("Command to create an app rule for the focused
window"), captured in
[`planned/20260621-backlog-brainstorm.md`](../planned/20260621-backlog-brainstorm.md)
under *Command palette*.

There is no upstream OmniWM or Nehir tracker issue for this — it is a raw
handwritten idea from a screenshot, not a port. This doc investigates whether and
how Nehir could implement it, grounded in the current source.

Scope: a discovery / feasibility study. **No source is changed here.**

All source references verified against the main Nehir source tree at `9ef0ae82`
("Add sticky PiP defaults and ignore app rules") on 2026-06-27. Re-verify before
acting; line numbers drift.

---

## TL;DR

- **The feature is almost entirely already built.** The entire "focused window →
  pre-filled app-rule draft → editor" pipeline exists *inside the App Rules
  settings tab today*: Nehir can already resolve the focused window's bundle id
  (+ title, AX role/subrole), build a pre-filled `AppRuleDraft` from it, and open
  the add-rule editor on that draft. The one thing missing is a **command entry
  point** (palette command + optional hotkey) that drives that pipeline without
  making the user open Settings → App Rules by hand.
- **The seam is small and additive.** Every ingredient has a public, reused
  call site: `WMController.focusedWindowDecisionDebugSnapshot()`
  (`Sources/Nehir/Core/Controller/WMController.swift:2632`),
  `AppRuleDraft.guided(from:)`
  (`Sources/Nehir/UI/AppRuleDraft.swift:105`), and the editor's existing
  `presentNewRule(from:)` (`Sources/Nehir/UI/AppRulesView.swift:169`). The only
  genuinely new wiring is (a) one `HotkeyCommand` case + action spec, and (b) a
  way to tell `SettingsWindowController` to open the **App Rules** tab *with a
  pending draft* (it can already open a section, but carries no draft).
- **`openSettings` is the exact precedent.** A command that opens a settings
  sub-page already exists end-to-end (`HotkeyCommand.openSettings` →
  `CommandHandler` → `SettingsWindowController.shared.show(section:)`). The new
  command mirrors it and adds the seed.
- **Verdict:** 🟢 **Pursue (do).** Low-risk, high-reuse, additive. Recommended
  v1 = a palette command **"Create App Rule for Focused Window…"** that opens the
  App Rules editor with a draft pre-filled from the focused window, ready for the
  user to pick effects and save. Details and the one open seam below.

## Prior work (do not duplicate)

- [`planned/20260621-backlog-brainstorm.md`](../planned/20260621-backlog-brainstorm.md)
  — origin of this idea (#26), under *Command palette*. Sibling items in the
  same list: **#9** "Assign hotkey for an action from the command palette" and
  **#11** "Fuzzy search in the command palette" (palette UX, unrelated to rule
  authoring); **#29** "Command to collect all windows on the current workspace"
  (another focused-workspace command idea — shares the "command that targets the
  focused context" shape).
- **#18 "Right-click actions in the action bar"** (`completed/…right-click-context-menus-to-the-workspace-b…`,
  landed in commit `d0cf6368`) is the closest sibling: it added right-click
  context menus to workspace-bar pills. Those menus expose **Toggle Floating /
  Toggle Sticky / Assign to Scratchpad / Move to Workspace / Close / Windows…**
  (verified in `Sources/Nehir/UI/WorkspaceBar/WorkspaceBarView.swift`, the
  `.contextMenu` blocks) but **do not** include a "Create App Rule" entry. So
  #18 and #26 share the *token-parameterized / focused-window* seam but do not
  overlap; a future right-click "Create rule for this window" is an optional
  *second* surface for the same command, not a prerequisite or a duplicate.
- [`discovery/20260617-omniwm-311-exclude-apps-from-workspace-bar.md`](../discovery/20260617-omniwm-311-exclude-apps-from-workspace-bar.md)
  — the canonical AppRule-subsystem triage: maps the `AppRule` schema, the
  case-insensitive bundle-id matcher, `AppRuleFileStore` TOML persistence, and
  the `AppRuleDraft` editor. This doc builds on that map and does not re-derive
  the rule engine internals.
- Commit **`9ef0ae82`** ("Add sticky PiP defaults and ignore app rules") is the
  recently-landed work the brief points at. It extended `AppRule` with the
  `manage = ignore` effect (`WindowRuleManageAction.ignore`) and the `sticky`
  effect (`AppRule.sticky: Bool?`), added the `toggleFocusedWindowSticky`
  command, and **is also the commit that introduced the in-editor
  "New Rule from Focused Window" affordance** (see §Current behavior). It is
  HEAD at verification time, so everything below is current.

## What the idea means for Nehir

Today, authoring an app rule requires opening **Settings → App Rules** and typing
a bundle id by hand (or picking from the running-apps list in the add pane). The
idea asks for a command — reachable from the command palette and/or a hotkey —
that creates a rule **seeded from the currently focused window** (its bundle id,
and optionally its title/AX role/subrole), so the user only chooses the rule
*effects* and saves.

In Nehir terms this is a **command-surface / wiring** task, not a model or
engine task: the rule model, persistence, matcher, editor, and the focused-window
seed data all already exist. The work is bridging a palette command to the
existing editor-on-draft path.

## Current behavior (with source citations)

### 1. The focused window is already resolvable to a rule-seed snapshot

`WMController.focusedWindowDecisionDebugSnapshot()` returns a
`WindowDecisionDebugSnapshot` for the focused window, or `nil` if none:

```swift
// Sources/Nehir/Core/Controller/WMController.swift:2632-2635
func focusedWindowDecisionDebugSnapshot() -> WindowDecisionDebugSnapshot? {
    let token = focusedOrFrontmostWindowTokenForAutomation()
    guard let token else { return nil }
    return windowDecisionDebugSnapshot(for: token)
}
```

The token comes from `focusedOrFrontmostWindowTokenForAutomation()`, which
**prefers the confirmed managed-focus window and falls back to the frontmost
app's focused window**:

```swift
// Sources/Nehir/Core/Controller/WMController.swift:1855-1865
func focusedOrFrontmostWindowTokenForAutomation(
    preferFrontmostWhenNonManagedFocusActive: Bool = false
) -> WindowToken? {
    let focusedToken = workspaceManager.confirmedManagedFocusToken
    let frontmostPid = commandHandler.frontmostAppPidProvider?()
        ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
    let frontmostToken = commandHandler.frontmostFocusedWindowTokenProvider?()
        ?? frontmostPid.flatMap { axEventHandler.focusedWindowToken(for: $0) }
    ...
    return focusedToken ?? frontmostToken
}
```

The frontmost fallback matters: it means the seed works **even for an app Nehir
does not manage** (the common case — "I want a rule for *this* app" usually
targets something currently ignored/unmanaged). The snapshot itself carries
exactly the rule-seed fields:

```swift
// Sources/Nehir/Core/Rules/WindowRuleEngine.swift:253-272
struct WindowDecisionDebugSnapshot: Equatable, Sendable {
    let token: WindowToken?
    let appName: String?
    let bundleId: String?
    let title: String?
    let axRole: String?
    let axSubrole: String?
    ...
}
```

`bundleId` here is resolved through the same AX/`AppInfoCache` path the rule
engine uses for matching (`makeWindowDecisionDebugSnapshot(from:)` at
`Sources/Nehir/Core/Controller/WMController.swift:2598-2622` copies
`evaluation.facts.ax.bundleId`), so the seed value is consistent with what a
saved rule would match against.

### 2. A pre-filled draft can already be built from that snapshot

`AppRuleDraft.guided(from:)` is the exact pre-fill entry point — it seeds the
bundle id and, when present, the title (as a substring matcher) and the AX
role/subrole, returning `nil` if there is no bundle id:

```swift
// Sources/Nehir/UI/AppRuleDraft.swift:105-123
static func guided(from snapshot: WindowDecisionDebugSnapshot) -> AppRuleDraft? {
    guard let bundleId = snapshot.bundleId?.trimmedNonEmpty else { return nil }

    var draft = AppRuleDraft(bundleId: bundleId)
    if let title = snapshot.title?.trimmedNonEmpty {
        draft.titleMatcherMode = .substring
        draft.titleSubstring = title
    }
    if let axRole = snapshot.axRole?.trimmedNonEmpty {
        draft.axRoleEnabled = true
        draft.axRole = axRole
    }
    if let axSubrole = snapshot.axSubrole?.trimmedNonEmpty {
        draft.axSubroleEnabled = true
        draft.axSubrole = axSubrole
    }
    return draft
}
```

The default `AppRuleDraft` it starts from (`AppRuleDraft(bundleId:)`,
`Sources/Nehir/UI/AppRuleDraft.swift:42-71`) leaves every *effect* at its
neutral default: `manageAction = .auto`, `layoutAction = .auto`, sticky off,
no workspace, no min-size — i.e. the user still has to choose effects. This
matches the idea's intent ("the user only picks the rule effects and saves").

### 3. The editor can already open on a pre-filled draft (in-tab, today)

`AppRulesView` already drives `AppRuleAddPane` from a seed draft via a single
`@State var addDraft`:

```swift
// Sources/Nehir/UI/AppRulesView.swift:22
@State private var addDraft: AppRuleDraft?

// Sources/Nehir/UI/AppRulesView.swift:83-96 (the add pane is shown when addDraft != nil)
if let draft = addDraft {
    AppRuleAddPane(
        initialDraft: draft,
        ...
        onSave: { newRule in
            settings.appRules.append(newRule)
            controller.updateAppRules()   // ← rebuilds engine cache + requests relayout
            selectedRuleId = newRule.id
            addDraft = nil
        },
        ...
    )
}
```

And there is already a **"New Rule from Focused Window" button** in the App Rules
empty state, wired through `presentNewRule(from:)`:

```swift
// Sources/Nehir/UI/AppRulesView.swift:169-173
private func presentNewRule(from snapshot: WindowDecisionDebugSnapshot) {
    guard let draft = AppRuleDraft.guided(from: snapshot) else { return }
    addDraft = draft
    selectedRuleId = nil
}
```

```swift
// Sources/Nehir/UI/AppRulesView.swift:752-755  (FocusedWindowInspectorView)
Button("New Rule from Focused Window") {
    onCreateRuleFromSnapshot(snapshot)
}
.buttonStyle(.borderedProminent)
.disabled(AppRuleDraft.guided(from: snapshot) == nil)
```

That inspector pulls the snapshot on appear/refresh via
`controller.focusedWindowDecisionDebugSnapshot()`
(`Sources/Nehir/UI/AppRulesView.swift:779-781`). **So the full seed→draft→editor
flow already exists** — it is just reachable only from inside the App Rules tab,
after the user has opened Settings and landed on the empty state.

The "Add" button in that editor is gated by `AppRuleAddPane.isValid`, which
requires a non-empty bundle id and `draft.hasAnyRule`
(`Sources/Nehir/UI/AppRulesView.swift:639-645`). `hasAnyRule`
(`Sources/Nehir/Core/Config/AppRule.swift:134-141`) is true when any effect or
any advanced matcher is set. Consequence: a guided draft with only a bundle id
(no effect chosen) leaves Add disabled until the user picks an effect — which is
exactly the intended "pick effects and save" UX. (Note: today's `guided` also
seeds a title substring, which alone flips `hasAnyRule` true — see Open decision
B for whether to keep that.)

### 4. `openSettings` is the precedent for a command that opens a settings page

A command that opens a settings sub-page already exists, full stack:

```swift
// Sources/Nehir/Core/Input/HotkeyCommand.swift:86
case openSettings

// Sources/Nehir/Core/Input/ActionCatalog.swift:727-735
action(
    id: "openSettings",
    command: .openSettings,
    category: .focus,
    binding: .unassigned,
    keywords: ["settings", "preferences", "configure", "config"]
)

// Sources/Nehir/Core/Input/ActionCatalog.swift:942   (title)
case .openSettings: "Open Settings"

// Sources/Nehir/Core/Input/ActionCatalog.swift:1102-1103   (HotkeyCommand ↔ IPC name map)
case .openSettings:
    .openSettings
```

`CommandHandler` routes it straight to the settings controller:

```swift
// Sources/Nehir/Core/Controller/CommandHandler.swift:196-197
case .openSettings:
    SettingsWindowController.shared.show(settings: controller.settings, controller: controller)
```

And `SettingsWindowController.show` **already accepts a target section**:

```swift
// Sources/Nehir/UI/SettingsWindowController.swift:27-43
func show(
    settings: SettingsStore,
    controller: WMController,
    section: SettingsSection? = nil
) {
    if let section {
        navigation.selectedSection = section
    }
    ...
}
```

`.appRules` is one of those sections (`Sources/Nehir/UI/SettingsSection.swift:18`,
rendered to `AppRulesView` at `Sources/Nehir/UI/SettingsDetailView.swift:48`), so
`show(settings:controller:section:.appRules)` already lands the user on the App
Rules tab. The gap is purely that `show` carries **no draft** — the
`SettingsNavigationModel` (`Sources/Nehir/UI/SettingsView.swift:11-19`) holds
only `selectedSection`.

### 5. The command palette auto-surfaces any new action spec

The palette builds its command list from `ActionCatalog.allSpecs()`, mapping each
spec's `title`, `category`, and `searchTerms` into a palette item:

```swift
// Sources/Nehir/UI/CommandPalette/CommandPaletteController.swift:576-594
private func buildCommandItems(from wmController: WMController) -> [CommandPaletteCommandItem] {
    ...
    return ActionCatalog.allSpecs()
        .filter { !$0.requiresDeveloperMode || developerModeEnabled }
        .map { spec in
            ...
            return CommandPaletteCommandItem(
                id: spec.id,
                command: spec.command,
                title: spec.title,
                category: spec.category,
                bindingDisplay: bindingDisplay,
                searchTerms: spec.searchTerms
            )
        }
}
```

So **adding an action spec is sufficient to surface the command in the palette**
— no separate palette registration. `openSettings` (unassigned, category
`.focus`) already appears this way; the new command should mirror it. Existing
`HotkeyCategory` cases (`Sources/Nehir/Core/Input/HotkeyBinding.swift:337-345`)
are `workspace / focus / move / monitor / layout / column / debugging`; the
meta/UI commands `openSettings` and `openMenuAnywhere` live in `.focus`, which is
the natural home for this command too.

### 6. Rules can also be created via IPC/nehirctl today (reuse for scripting/tests)

For completeness on "can a rule be added via IPC": yes. `nehirctl` exposes
`rule add / replace / remove / move / apply`
(`Sources/NehirCtl/CLIParser.swift:324-349`), routed through
`IPCRuleRouter.handle(_:)` which materializes an `AppRule` via
`IPCRuleProjection.appRule(from:)` and persists it through
`controller.settings.appRules` + `controller.updateAppRules()`:

```swift
// Sources/Nehir/IPC/IPCRuleRouter.swift:20-30, 38-46
case let .add(rule):
    return add(rule)
...
private func add(_ definition: IPCRuleDefinition) -> ... {
    ...
    var rules = controller.settings.appRules
    rules.append(IPCRuleProjection.appRule(from: definition))
    controller.settings.appRules = rules
    controller.updateAppRules()
    ...
}
```

This is relevant as a **test seam** (the command's effect can be asserted through
the same `settings.appRules` + `updateAppRules()` path) and as an optional v1.1
surface (expose the new command over IPC like `open-settings` at
`Sources/NehirIPC/IPCAutomationManifest.swift:748`). It is **not** required for
v1: the in-editor draft still needs human confirmation of effects, so the command
should open the editor, not silently `rule add`.

## Where / how it would be implemented (seam points)

The v1 is five small touches, four of which are 1:1 mirrors of `openSettings`.

### Step 1 — Define the command

Add `case createAppRuleForFocusedWindow` to `HotkeyCommand`, next to
`.openSettings` (`Sources/Nehir/Core/Input/HotkeyCommand.swift:86`). No
associated value is needed: the focused window is resolved at dispatch time, not
capture time (consistent with `toggleFocusedWindowSticky` etc.).

### Step 2 — Register the action spec, title, and IPC name

In `Sources/Nehir/Core/Input/ActionCatalog.swift`, mirror the `openSettings`
spec (`:727-735`): unassigned binding, `category: .focus`, and searchable
keywords like `["app rule", "rule", "bundle", "focused window", "create rule"]`.
Add the title in the `title(for:)` switch (`:942`), e.g.
`"Create App Rule for Focused Window…"`. Add the IPC-name mapping in the
`ipcCommandName(for:)` switch (`:1102-1103`). This alone surfaces it in the
palette (§5). Leave `binding: .unassigned` for v1 (discoverable via palette); a
default hotkey is a separate decision (Open decision A).

### Step 3 — Resolve the seed and open the editor (the one substantive case)

In `Sources/Nehir/Core/Controller/CommandHandler.swift`, next to the
`.openSettings` case (`:196-197`), add the handler. It resolves the snapshot,
builds the guided draft, and — if a draft exists — opens Settings on App Rules
with that draft pending; otherwise it no-ops (or shows a brief message — see
Risks):

```swift
case .createAppRuleForFocusedWindow:
    let snapshot = controller.focusedWindowDecisionDebugSnapshot()       // WMController.swift:2632
    guard let draft = snapshot.flatMap(AppRuleDraft.guided(from:)) else { // AppRuleDraft.swift:105
        return .notFound            // no focused window / no bundle id
    }
    SettingsWindowController.shared.show(
        settings: controller.settings,
        controller: controller,
        section: .appRules,
        pendingAppRuleDraft: draft   // ← the one new plumbing arg (Step 4)
    )
```

Every line above reuses an existing public symbol; only `pendingAppRuleDraft:` is
new.

### Step 4 — Carry the pending draft into the editor (the one additive plumbing)

`SettingsNavigationModel` (`Sources/Nehir/UI/SettingsView.swift:11-19`) gains an
optional pending draft, and `SettingsWindowController.show` gains a matching
parameter that sets it before ordering the window front:

```swift
// Sources/Nehir/UI/SettingsView.swift:11  (extend the model)
final class SettingsNavigationModel {
    var selectedSection: SettingsSection
    var pendingAppRuleDraft: AppRuleDraft?     // ← additive; nil by default
    ...
}

// Sources/Nehir/UI/SettingsWindowController.swift:27  (extend show())
func show(settings: SettingsStore, controller: WMController,
          section: SettingsSection? = nil,
          pendingAppRuleDraft: AppRuleDraft? = nil) {
    if let section { navigation.selectedSection = section }
    navigation.pendingAppRuleDraft = pendingAppRuleDraft   // ← set before show
    ...
}
```

Then thread it into `AppRulesView` (via `SettingsView` → `SettingsDetailView`
→ `AppRulesView`, which already takes `controller`/`settings`). `AppRulesView`
consumes it exactly the way its existing `presentNewRule(from:)` does — seed
`addDraft` from the pending value on appear and clear it:

```swift
// Sources/Nehir/UI/AppRulesView.swift — consume alongside presentNewRule (:169)
.onAppear {
    if let pending = navigation.pendingAppRuleDraft {
        addDraft = pending
        selectedRuleId = nil
        navigation.pendingAppRuleDraft = nil
    }
}
```

This reuses the existing `addDraft` state (`AppRulesView.swift:22`) and the
existing `AppRuleAddPane(initialDraft:)` (`AppRulesView.swift:83-84`, struct at
`:435`, init at `:447`). **No editor redesign, no new view.**

### Step 5 — (Optional, defer) IPC surface

Mirror `open-settings` in the IPC manifest (`Sources/NehirIPC/IPCAutomationManifest.swift:748`)
and the router (`Sources/Nehir/IPC/IPCCommandRouter.swift:191-192`) so the
command is callable as e.g. `nehirctl create-app-rule-for-focused-window`. This
is pure reuse of the dispatch path and can ship after v1.

## Reuse vs. new code

| Concern | Status |
| --- | --- |
| Focused-window identity (bundle id / pid / token) | ✅ Reuse — `focusedWindowDecisionDebugSnapshot()` (`WMController.swift:2632`) |
| Pre-filled draft construction | ✅ Reuse — `AppRuleDraft.guided(from:)` (`AppRuleDraft.swift:105`) |
| Editor on a draft | ✅ Reuse — `addDraft` + `AppRuleAddPane(initialDraft:)` (`AppRulesView.swift:22,83`) |
| Opening a settings section from a command | ✅ Reuse — `SettingsWindowController.show(section:)` (`SettingsWindowController.swift:27`) |
| Palette surfacing | ✅ Reuse — `ActionCatalog.allSpecs()` → palette (`CommandPaletteController.swift:576`) |
| Rule schema / persistence / matching | ✅ Untouched — `AppRule`, `AppRuleFileStore`, `WindowRuleEngine` (incl. the `9ef0ae82` `ignore`/`sticky` effects) |
| **Carrying a pending draft into the editor** | 🆕 **New** — one optional field on `SettingsNavigationModel` + one param on `show()` + a 4-line `.onAppear` consumer |
| **The command case + spec + title + IPC map + handler** | 🆕 **New** — five small 1:1 mirrors of `openSettings` |

So the feature is ~90% reuse; the genuinely new code is one model field, one
method parameter, a handful of lines in `AppRulesView.onAppear`, and the command
registration mirroring `openSettings`. No existing `createAppRule`/`ruleForFocused`
symbol exists in tree (verified by search — net-new).

## Risks and unknowns

- **No focused window / no resolvable bundle id.** `focusedWindowDecisionDebugSnapshot()`
  returns `nil` when nothing is focused, and `AppRuleDraft.guided(from:)` returns
  `nil` when the snapshot has no bundle id. The command must decide what to do:
  silent no-op (matches how unbound hotkeys behave on empty selection today), or
  a brief non-modal toast/announcement ("No focused window to seed a rule from").
  Recommend a **non-silent** response here, because the user *explicitly* invoked
  the command from the palette (unlike a hotkey fired into the void) — a silent
  nothing is confusing. `ExternalCommandResult.notFound`
  (`Sources/Nehir/IPC/ExternalCommandResult.swift:9-19`) is the natural return;
  the palette/IPC layer can translate it.
- **Focused window is unmanaged / ignored.** This is the *expected* seed case
  ("make a rule for this app" usually targets an app Nehir currently ignores).
  `focusedOrFrontmostWindowTokenForAutomation()`'s frontmost fallback
  (`WMController.swift:1855-1865`) and `windowDecisionDebugSnapshot(for:)`'s
  direct AX evaluation (`WMController.swift:2624-2630`) handle it — the snapshot
  is produced for any window with an AX ref, managed or not. No special-casing
  needed; verified by reading both paths.
- **Bundle-id resolution timing.** The seed `bundleId` comes from
  `evaluation.facts.ax.bundleId`, the same source rules match against, so a rule
  saved from the seed will match the window it came from. (If AX attributes
  failed to fetch, `attributeFetchSucceeded` is false on the snapshot and
  `bundleId` may be nil → `guided` returns nil → the not-found path above. Safe.)
- **Multiple windows of the same app.** Rules match by bundle id (with optional
  advanced matchers), not by window identity, so seeding from any one window of
  an app yields a rule that covers all of them. `guided` additionally seeds the
  title substring, which may over-narrow — see Open decision B.
- **Opening the editor on a draft is proven for the in-tab path but not for the
  cross-window path.** `AppRuleAddPane(initialDraft:)` is already driven from a
  seed (`presentNewRule`, `AppRulesView.swift:169`), so opening the add pane on a
  draft is exercised. The only unproven step is the *command* opening the
  settings window with a pending draft that the view consumes on appear — this is
  Step 4 and is straightforward, but it should be tested (a settings window
  re-show while a draft is pending must not double-seed; the `.onAppear`
  consumer clears `pendingAppRuleDraft` after consuming it to guard that).
- **IPC stability (Step 5 only).** Adding an IPC command name is additive and
  non-breaking; no migration needed. Defer if not wanted in v1.

## Open decisions for the maintainer

- **A. Default hotkey?** v1 can ship palette-only (`binding: .unassigned`, like
  `openSettings`). If a default hotkey is wanted, pick one that does not collide
  with the existing meta/UI bindings (`openMenuAnywhere` is `Opt+Cmd+M`,
  `openCommandPalette` is its own case). Recommend **palette-only for v1**; add a
  hotkey only if users ask.
- **B. Should the seed include the title substring / AX matchers by default?**
  Today `AppRuleDraft.guided(from:)` seeds the title as a substring matcher and
  the AX role/subrole when present (`AppRuleDraft.swift:108-122`). For a "create
  an app rule" command, the user most often wants a **bundle-level** rule; a
  pre-seeded title matcher can silently over-narrow (a rule that only matches the
  *current* document's title). Recommend **two options**: (1) keep `guided` as-is
  and seed everything (matches the existing in-tab button, least surprise
  relative to current behavior); or (2) add a bundle-only variant for the command
  and leave the advanced matchers collapsed/empty. Recommend (1) for v1 to stay
  consistent with the existing "New Rule from Focused Window" button, and revisit
  if users report over-narrowing. Either way the user can edit before saving.
- **C. Re-show behavior.** If Settings is already open on another tab and the
  command fires, `show(section:.appRules)` switches the tab; the pending draft
  should still be consumed. If Settings is already on App Rules with an unsaved
  `addDraft` in flight, decide whether the new seed replaces it (recommend: yes,
  the explicit command wins) or is dropped. Recommend **replace** and clear the
  pending value after consume (as in Step 4) so it only fires once.
- **D. Right-click surface (#18 follow-on).** Optionally add a "Create App Rule
  for this Window" item to the workspace-bar right-click menu
  (`Sources/Nehir/UI/WorkspaceBar/WorkspaceBarView.swift` context menus, added by
  `d0cf6368`) targeting the *clicked* window's token rather than the focused one.
  This is a natural second surface for the same command and shares the seam, but
  is explicitly **out of scope for v1**.

## Non-goals

- Do **not** redesign the `AppRuleAddPane`/`AppRuleDetailView` editor — reuse it
  verbatim via `initialDraft:`.
- Do **not** auto-save / auto-apply the rule. The command opens the editor on a
  draft; the user must choose effects and press Add (this is enforced today by
  `AppRuleAddPane.isValid` requiring `hasAnyRule`).
- Do **not** add batch import / multi-window rule generation.
- Do **not** change the `AppRule` schema, `AppRuleFileStore` TOML format, or the
  `WindowRuleEngine` matcher.
- Do **not** add a right-click "create rule" menu item in v1 (Open decision D —
  deferred; it is a second surface, not part of the command).

## Suggested tests

- **Command handler, happy path.** With a managed window focused whose bundle id
  resolves (e.g. a stubbed `focusedWindowDecisionDebugSnapshot()` returning a
  snapshot with `bundleId = "com.example.App"`), invoking
  `.createAppRuleForFocusedWindow` opens `SettingsWindowController` on
  `.appRules` with `navigation.pendingAppRuleDraft` set to a draft whose
  `bundleId == "com.example.App"`, and (after the view consumes it)
  `pendingAppRuleDraft` is cleared.
- **Command handler, no focused window.** With `focusedWindowDecisionDebugSnapshot()`
  returning `nil`, the command returns `.notFound` and does **not** mutate
  `settings.appRules` or open the editor.
- **Command handler, no bundle id.** Snapshot present but `bundleId == nil`
  (`attributeFetchSucceeded == false`) → `AppRuleDraft.guided` returns `nil` →
  command returns `.notFound`, no editor opened.
- **Seed-from-unmanaged window.** When only the frontmost (unmanaged) app is
  available, the frontmost fallback in
  `focusedOrFrontmostWindowTokenForAutomation()` still yields a snapshot and the
  command seeds a draft (regression guard for the common "rule for an ignored
  app" case).
- **Palette surfacing.** `buildCommandItems` includes the new spec with the
  expected title and search terms, and it is findable by a keyword like "rule"
  (mirrors how `openSettings` is found by "settings").
- **Round-trip after save.** After the user saves the seeded draft, the new rule
  appears in `settings.appRules`, is persisted by `AppRuleFileStore`, and
  `controller.updateAppRules()` has rebuilt the engine cache (assert via the same
  path `IPCRuleRouter.add` exercises, `IPCRuleRouter.swift:38-46`).

## Reproduction / verification commands

Re-verify the seam before implementing:

```bash
# Focused-window → rule-seed snapshot (the seed data)
rg -n 'func focusedWindowDecisionDebugSnapshot|func focusedOrFrontmostWindowTokenForAutomation|struct WindowDecisionDebugSnapshot' \
   Sources/Nehir/Core/Controller/WMController.swift Sources/Nehir/Core/Rules/WindowRuleEngine.swift

# The pre-fill entry point + the existing in-tab "New Rule from Focused Window" wiring
rg -n 'static func guided|func presentNewRule|New Rule from Focused Window|onCreateRuleFromSnapshot' \
   Sources/Nehir/UI/AppRuleDraft.swift Sources/Nehir/UI/AppRulesView.swift

# The openSettings precedent end-to-end (command → handler → settings controller)
rg -n 'case openSettings|id: "openSettings"|case \.openSettings:|SettingsWindowController.shared.show' \
   Sources/Nehir/Core/Input/HotkeyCommand.swift Sources/Nehir/Core/Input/ActionCatalog.swift \
   Sources/Nehir/Core/Controller/CommandHandler.swift

# Settings opens to a section; App Rules is one; but the nav model carries no draft today
rg -n 'func show\(|selectedSection|pendingAppRuleDraft|case appRules|AppRulesView\(' \
   Sources/Nehir/UI/SettingsWindowController.swift Sources/Nehir/UI/SettingsView.swift \
   Sources/Nehir/UI/SettingsSection.swift Sources/Nehir/UI/SettingsDetailView.swift

# Palette auto-surfaces action specs
rg -n 'func buildCommandItems|ActionCatalog.allSpecs' \
   Sources/Nehir/UI/CommandPalette/CommandPaletteController.swift

# IPC/CLI can already create rules (test seam / optional v1.1 surface)
rg -n 'case "rule"|rule: \.add|case let \.add\(rule\)|IPCRuleProjection.appRule\(from' \
   Sources/NehirCtl/CLIParser.swift Sources/Nehir/IPC/IPCRuleRouter.swift
```

The defining evidence: `focusedWindowDecisionDebugSnapshot()`
(`WMController.swift:2632`), `AppRuleDraft.guided(from:)`
(`AppRuleDraft.swift:105`), and `presentNewRule(from:)` (`AppRulesView.swift:169`)
already exist and are already wired together inside the App Rules tab; and
`openSettings` (`HotkeyCommand.swift:86` → `CommandHandler.swift:196` →
`SettingsWindowController.show(section:)` at `:27`) is the end-to-end precedent
for a command that opens a settings page. The feature is the bridge between them
— one new command case plus one optional field to carry the pending draft — not
new logic.

## Recommendation

🟢 **Pursue (do).** It is small, surgical, and ~90% reuse: the focused-window
snapshot, the guided draft, the draft-driven editor, and the open-settings-page
command all already exist. The genuinely new code is one optional field on
`SettingsNavigationModel`, one parameter on `SettingsWindowController.show`, a
few lines in `AppRulesView.onAppear`, and a command case that mirrors
`openSettings` five ways (enum case, action spec, title, IPC-name map, handler).

Recommended **v1 scope**: a palette command **"Create App Rule for Focused
Window…"** (`binding: .unassigned`, `category: .focus`) that resolves
`focusedWindowDecisionDebugSnapshot()`, builds `AppRuleDraft.guided(from:)`, and
opens the App Rules editor on that draft via
`SettingsWindowController.show(section:.appRules, pendingAppRuleDraft:)`. The
user then picks effects and saves through the unchanged editor. Settle Open
decision B (seed matchers vs bundle-only) and the no-focused-window response
(recommend non-silent `.notFound`) before coding. Defer the IPC surface (Step 5)
and the right-click surface (Open decision D) to v1.1.
