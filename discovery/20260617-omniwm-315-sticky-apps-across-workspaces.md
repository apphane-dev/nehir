# BarutSRB/OmniWM#315 — "Sticky apps visible across all workspaces" — Discovery

Groom 2026-07-07: resolved — a sticky AppRule effect landed (AppRule + AppRuleFileStore codec + bar visibility; isStickyWindow/isGlobalStickyWindow across the runtime) (verified against main 7a025b78).

Source issue: https://github.com/BarutSRB/OmniWM/issues/315
Related discussion: https://github.com/BarutSRB/OmniWM/discussions/11 ("Sticky Windows —
size+pos across workspaces, no SIP")
Scope of this doc: determine whether/how nehir should add "sticky/pinned" apps that
stay visible across workspace switches, and propose an idiomatic design consistent
with nehir's existing app-rule/settings schema.

All file/line references were verified against the Nehir source tree
at `904df02` ("Add bunch of discoveries mapped to issues from OmniWM").
**Re-verify before implementing; line numbers drift.** Verdict is by code inspection
(no runtime trace). Upstream issue and discussion #11 were fetched live.

---

## TL;DR

- **nehir has no sticky/pin mechanism. Every tracked window is bound 1:1 to one
  `workspaceId` and is parked offscreen when that workspace goes inactive; the
  *only* precedent for "always visible" is nehir's own utility windows (Settings,
  App Rules), which never enter the window model at all. A `sticky` AppRule effect
  for tracked windows is implementable and idiomatic — but the headline use case
  (an Übersicht *overlay widget* staying on top across every macOS Space) is
  unreachable without SIP, exactly the constraint the maintainer named in
  discussion #11.**
- **Verdict:** 🟡 **Partial** — the feature is genuinely absent and worth adding in
  a *scoped* form (tracked-window visibility + size/position preserved across
  nehir workspace switches). The literal "overlay persists on all Spaces" goal is
  ⚪ Not-applicable via public API and must be delegated to the app's own
  all-Spaces config. Owns a new repo action.

## Provenance: is this nehir's code?

Yes — the entire workspace-association, hide, and rule model is nehir-local. There
is **no existing stickiness, pinning, or "show on all workspaces" concept** anywhere
in the sources (`fffind` for `sticky pin` returns only a Karabiner recipe and
unrelated hotkey/settings files). The relevant machinery:

- **1:1 window→workspace binding.** Every tracked window carries a single
  `var workspaceId: WorkspaceDescriptor.ID` on its model entry
  (`Sources/Nehir/Core/Workspace/WindowModel.swift:172`). `tokensByWorkspace` maps
  one workspace id → its windows (`WindowModel.swift:196`); there is no "all
  workspaces" membership.
- **Inactive-workspace hide.** `hideWorkspace(_ entries:monitor:preferredSide:…)`
  parks each entry offscreen with `reason: .workspaceInactive`
  (`Sources/Nehir/Core/Controller/LayoutRefreshController.swift:2142`, the park call
  at `:2164`). The `.workspaceInactive` reason is one of three hide reasons
  defined in `WindowModel.HiddenReason` (`WindowModel.swift:78-82`).
- **The one "always visible" precedent — nehir's own windows.** Settings / App
  Rules / Onboarding are registered through `OwnedWindowRegistry.register(_:)`,
  which defaults to `SurfacePolicy(kind: .utility, …,
  suppressesManagedFocusRecovery: true)` (`Sources/Nehir/App/OwnedWindowRegistry.swift:23-25`).
  They are explicitly excluded from management at admission
  (`WMController.swift:2461` `isOwnedWindowNumber` guard; `:2519`
  `if isOwnedWindowNumber(windowId) { continue }`). Because they never enter
  `WindowModel`, `hideWorkspace` never touches them — that is *why* the reporter
  saw them behaving "more like utility/sticky windows." There is no user-facing
  equivalent for external apps.
- **The rule pipeline that a sticky flag would extend.** `AppRule`
  (`Sources/Nehir/Core/Config/AppRule.swift:36-46` CodingKeys, fields at `:49-61`)
  → `ManagedWindowRuleEffects` (`Sources/Nehir/Core/Rules/WindowRuleEngine.swift:40-46`)
  built from the matched user rule at `WindowRuleEngine.swift:340-345` → stored on
  the model entry (`WindowModel.swift:181` `var ruleEffects`) → TOML
  serialize/parse in `Sources/Nehir/Core/Config/AppRuleFileStore.swift` (encode at
  `:57-59`, decode at `:147`) → IPC projection `Sources/Nehir/IPC/IPCRuleProjection.swift`
  / `Sources/NehirIPC/IPCModels.swift:1542` → UI `Sources/Nehir/UI/AppRulesView.swift`.

## The code in question

**1. How an external window vanishes on workspace switch** — the hide pass that a
sticky exemption would have to skip:

```swift
// Sources/Nehir/Core/Controller/LayoutRefreshController.swift:2142-2166
private func hideWorkspace(
    _ entries: [WindowModel.Entry], monitor: Monitor, preferredSide: HideSide,
    hiddenPlacementMonitors: [HiddenPlacementMonitorContext]? = nil
) {
    guard let controller else { return }
    for entry in entries {
        guard controller.workspaceManager.layoutReason(for: entry.token) != .nativeFullscreen else { continue }
        controller.axManager.markWindowInactive(entry.windowId)
        if let hiddenState = controller.workspaceManager.hiddenState(for: entry.token) {
            traceWorkspaceInactiveVisibleDriftIfNeeded( … trigger: "hideWorkspace.skipAlreadyHidden")
            continue
        }
        hideWindow(entry, monitor: monitor, side: preferredSide,
                   reason: .workspaceInactive,                                 // ← :2164
                   hiddenPlacementMonitors: hiddenPlacementMonitors)
    }
}
```

Note there is **no `.mode` filter** — tiling *and* floating windows on an inactive
workspace are parked (also documented by sibling discovery `20260616-omniwm-391-…`).

**2. How Übersicht (the reporter's example app) is classified today** — `.accessory`
policy + no close button → heuristic **floating**:

```swift
// Sources/Nehir/Core/Ax/AXWindow.swift:653-659
if facts.appPolicy == .accessory && !facts.hasCloseButton {
    return AXWindowHeuristicDisposition(disposition: .floating, reasons: [.accessoryWithoutClose])
}
```

So Übersicht's widget window, if nehir tracks it, is floated on whichever workspace
it appears on and then hidden by the pass above when that workspace goes inactive.
If nehir does *not* track it, macOS itself hides it on Space change — either way the
reporter sees it disappear, exactly as described.

**3. The AppRule schema a `sticky` flag would slot into** — `[effect]` block of the
TOML codec, mirroring `assignToWorkspace` line-for-line:

```swift
// Sources/Nehir/Core/Config/AppRuleFileStore.swift:55-61   (encode)
var effectLines: [String] = []
if let layout = rule.layout { effectLines.append("layout = \(quoted(layout.rawValue))") }
if let w = rule.minWidth { effectLines.append("minWidth = \(formatNumber(w))") }
if let h = rule.minHeight { effectLines.append("minHeight = \(formatNumber(h))") }
if let ws = rule.assignToWorkspace { effectLines.append("assignToWorkspace = \(quoted(ws))") }
// a future line: if rule.sticky == true { effectLines.append("sticky = true") }
```

```swift
// Sources/Nehir/Core/Config/AppRuleFileStore.swift:147   (decode, in AppRule(…))
assignToWorkspace: extractString(effectFields["assignToWorkspace"]),
// a future line: sticky: effectFields["sticky"] == "true"
```

**4. The rule-effects struct that carries the flag to the model**

```swift
// Sources/Nehir/Core/Rules/WindowRuleEngine.swift:40-46
struct ManagedWindowRuleEffects: Equatable, Sendable {
    var minWidth: Double?
    var minHeight: Double?
    var matchedRuleId: UUID?
    static let none = ManagedWindowRuleEffects()
}
```

```swift
// Sources/Nehir/Core/Rules/WindowRuleEngine.swift:340-345   (effects built from matched rule)
let workspaceName = userRule?.rule.assignToWorkspace
let effects = ManagedWindowRuleEffects(
    minWidth: userRule?.rule.minWidth,
    minHeight: userRule?.rule.minHeight,
    matchedRuleId: userRule?.rule.id
)
```

## Why it is Partial (two sub-problems with different reachability)

The request bundles two technically distinct goals. They must be separated, because
one is implementable and the other is not.

### (A) Tracked-window sticky — implementable, owns the new action

For a window nehir already tracks (a monitoring app, a media window, a utility with
a real close button), a `sticky` AppRule effect is feasible and idiomatic:

1. Add `var sticky: Bool?` to `AppRule` + `CodingKeys` + init
   (`Sources/Nehir/Core/Config/AppRule.swift`), matching `assignToWorkspace`.
2. Carry it through `ManagedWindowRuleEffects` (`WindowRuleEngine.swift:40-46`),
   populated at `:340-345`, stored on `WindowModel.Entry.ruleEffects`
   (`WindowModel.swift:181`).
3. Serialize/parse in `AppRuleFileStore` (`:55-61` / `:147`) and project through
   `IPCRuleDefinition` (`Sources/NehirIPC/IPCModels.swift:1542`) /
   `IPCRuleProjection`.
4. Render a `RuleBadge(text: "Sticky", …)` in `AppRulesView.swift:200-216`
   alongside the existing "WS"/"Size" badges.
5. **The behavior:** in `hideWorkspace` (`LayoutRefreshController.swift:2142`),
   skip any entry whose `ruleEffects.sticky == true` — do not park it. Optionally,
   re-affix it to the now-active workspace id (`updateWorkspace(for:workspace:)`
   `WindowModel.swift:455`) so the model stays coherent.

**Central design tension (must be solved, not hand-waved):** a window exempted from
`hideWorkspace` while its *own* workspace is inactive is, by definition, in the
exact state that four sibling discoveries treat as a **bug** — a live on-screen
frame whose logical workspace is not the active one:

- `noop/20260616-omniwm-235-window-bleed-different-workspace.md` —
  `hideWorkspace` parking failures leave tiled frames visible on the wrong workspace.
- `noop/20260616-omniwm-349-hidden-window-bleeds-multi-monitor.md` —
  edge-park misses bleed across monitors.
- `noop/20260616-omniwm-391-steam-tile-and-workspace-leak.md` —
  same `.workspaceInactive` park path leaks floating windows.
- `20260616-workspace-inactive-stale-live-frame.md` — the drift detector
  `workspaceInactiveVisibleDriftLine` (`LayoutRefreshController.swift:2255+`)
  *exists to flag* a visible frame while `hidden=workspaceInactive`.

So a naive sticky exemption would **turn bleed into a "feature"** and trip the
drift detector on every switch. The design must therefore (i) keep the sticky
window's `workspaceId` re-anchored to the active workspace each switch (so it is
never in an inactive-workspace-while-visible state), and (ii) exclude sticky-flagged
entries from the drift detector's accusation set. This is non-trivial but bounded.

The SIP caveat from discussion #11 also bounds *this* sub-problem: nehir **cannot
keep a sticky window always-on-top** if the user clicks an overlapping window —
that requires private/SIP-disabled APIs. The maintainer's stated compromise
("keep size+position across workspaces" + a hotkey to re-raise) is the realistic
target. So even (A) delivers "stays where it is across switches," not "always on
top."

### (B) The Übersicht overlay — Not applicable via public API

The reporter's *headline* use case (Übersicht widgets visible on every Space) is
not something nehir can deliver for an **untracked** external overlay:

- An app that stays on all macOS Spaces does so by setting
  `NSWindow.collectionBehavior = .canJoinAllSpaces` on *its own* window — a
  per-process, per-window property. nehir cannot set another app's collection
  behavior through any public API.
- Without SIP, nehir also cannot force another process's window level/Space
  association. Discussion #11 states this constraint verbatim: *"without SIP
  disabled, it's not possible to keep the sticky window always on top … I won't
  disable SIP just to make it work."*
- Übersicht in particular **already exposes** an all-Spaces setting of its own
  (`SHOW_ON` / `set_top_level` in Übersicht's widget config); the correct fix for
  the reporter is there, and nehir must additionally *not* try to manage/hide it
  (it is `.accessory`-heuristic-floated today per `AXWindow.swift:653`, so if nehir
  tracks it at all it would fight the all-Spaces behavior).

So (B) is ⚪ **Not applicable** — out of nehir's reach, and partly already solved by
the app itself. Porting any "force this window onto all Spaces" feature would
regress (it can't be implemented) and would mislead users.

## Recommendation

**Build the scoped (A) capability; explicitly disclaim (B).**

1. **Implement a `sticky` AppRule effect for tracked windows** along the pipeline
   above (schema → effects → `hideWorkspace` exemption → active-workspace
   re-anchoring → drift-detector exclusion → codec/UI/badges). Keep the documented
   contract as discussion #11's compromise: *the window keeps its frame across
   workspace switches; it is not guaranteed always-on-top.*
2. **Re-anchor, don't exempt-and-leave.** In `hideWorkspace`, a sticky entry should
   be reparented to the destination active workspace (`updateWorkspace` /
   `WindowModel.swift:455`) rather than left in an inactive-while-visible state —
   this is what prevents it from being classified as bleed by the detector and by
   the sibling-discovery invariants.
3. **Exclude sticky entries from `workspaceInactiveVisibleDriftLine`**
   (`LayoutRefreshController.swift:2255+`) so the detector doesn't false-fire on
   intentional persistence.
4. **Provide a re-raise hotkey** (the discussion #11 compromise): a command that
   brings the frontmost sticky window above overlapping windows, since always-on-top
   is impossible. Thread it through `ActionCatalog` / `HotkeyConfigMapping` like the
   existing `focusPrevious` (`CommandHandler.swift:237`).
5. **Document the Übersicht limitation** in the App Rules UI help text: for overlay
  widgets that should appear on every macOS Space, configure the app's own
  all-Spaces setting; nehir's `sticky` applies to windows nehir manages.
6. **Codec caution:** adding `sticky` to the `[effect]` block touches the same
   TOML codec flagged by sibling discovery `20260616-omniwm-410-settings-toml-unknown-keys-roundtrip-loss.md`
   — ensure the new key round-trips through encode/decode and the unknown-key path
   (BarutSRB/OmniWM#410's concern) still degrades gracefully.

## Suggested tests

- **Sticky window survives a workspace switch in place.** Seed a managed window on
  WS 1 with `ruleEffects.sticky = true`; switch active workspace to WS 2. Assert
  the window's live frame is unchanged (not parked to a screen edge) and its
  `workspaceId` is re-anchored to WS 2 (`workspace(for: token) == WS 2`), so the
  model is never in an inactive-while-visible state.
- **Non-sticky window on the same workspace is still parked.** Same setup but a
  second, non-sticky window on WS 1; after switching to WS 2 assert the non-sticky
  window is `hidden=workspaceInactive` and the sticky one is `visible`.
- **Drift detector does not accuse a sticky window.** With a sticky window visibly
  on-screen while its *original* workspace is inactive, assert
  `workspaceInactiveVisibleDriftLine(…)` returns `nil` for that token (it must be
  in the exclusion set), preventing a false bleed alert.
- **TOML round-trip of the new key.** Encode an `AppRule` with `sticky = true`,
  decode the produced TOML, assert `sticky` survives; assert a rule file *without*
  the key still decodes to `sticky == nil` (guards the unknown-key path per BarutSRB/OmniWM#410).
- **Overlay disclaimer is not silently managed.** A `.accessory`-policy window with
  no close button and no user rule remains heuristic-floated
  (`AXWindow.swift:653`) — i.e. nehir does *not* auto-promote Übersicht into
  "managed + sticky," confirming (B) is left to the app.
