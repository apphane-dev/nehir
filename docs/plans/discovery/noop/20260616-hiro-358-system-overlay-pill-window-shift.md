# Hiro issue #358 — "Overlaying Mac OS pills makes window moving by itself" — Discovery

Source issue: https://github.com/BarutSRB/Hiro/issues/358
Filed against: `BarutSRB/Hiro` (upstream of nehir — see `NOTICE.md`;
nehir is a fork of `BarutSRB/OmniWM`, renamed to Hiro).
Scope of this doc: determine whether a transient macOS on-screen "pill"
(input-source switcher indicator, screen-recording indicator — system-level
overlays) can shift/resize a managed (tiled) window in nehir, and whether the
upstream suggested fix (Hiro PR #385, "Suppress input during screenshot
selection", **closed without merge**) is safe to port.

All file/line references were verified against `worktree-calm-meadow-6229` at
`7f61cb3` ("docs: update four-finger gesture discovery with non-repro trace").
Re-verify before implementing; line numbers drift.

> **Filed under discovery/noop/** — nehir already prevents this at stricter,
> earlier layers than the upstream item names, so the item owns **no new repo
> action**. The input-source pill specifically is refused admission by a named
> built-in rule; the recording-indicator / screencapture surfaces are excluded
> by activation-policy and AX-resolution gates; and any non-tracked overlay's
> frame event is short-circuited before it can relayout. Porting the upstream
> diff (PR #385) would *regress* (a narrower screencapture suppression that
> nehir's existing activation-policy occlusion already covers). The one related
> *app-owned* overlay → viewport-reveal bug is a separate trigger owned by the
> sibling discovery `docs/plans/discovery/20260615-viewport-reveal-from-unmanaged-overlay-activation.md`.

---

## TL;DR

- **nehir does not reproduce #358.** The input-source indicator pill (the issue's
  primary reproduction) is **explicitly classified `.unmanaged` by bundle id** and
  never admitted, so it can never perturb a tiled window. Recording/screencapture
  system chrome is excluded by activation policy and never resolves as a standard
  AX window. And every non-tracked surface's `frameChanged` event returns before
  any relayout via the tracked-entry guard.
- **Verdict:** 🟢 **Fixed / ⚪ Won't-port** — nehir's defenses are earlier and
  stricter than the two mechanisms the upstream issue's analysis proposes; the
  upstream PR was closed-unmerged and would not improve nehir.

## Provenance: is this nehir's code?

Yes. The two mechanisms the upstream comment names both map onto nehir symbols:

| Upstream concept (Hiro) | nehir equivalent | Location |
|---|---|---|
| `getDisplayWindows()` (filters to levels 0, 3, 8) | `queryAllVisibleWindows()` | `SkyLight.swift:484` |
| `SkyLight.queryWindowInfo()` (no level filtering) | `queryWindowInfo(_:)` | `SkyLight.swift:519` |
| `handleFrameChanged` → `resolveWindowInfo` → relayout | `handleFrameChanged(windowId:)` | `AXEventHandler.swift:677` |
| `handleAppActivation` → `handleMissingFocusedWindow` → `enterNonManagedFocus` | same names | `AXEventHandler.swift:1428` / `:3691`; `WorkspaceManager.swift:1802` |

`queryWindowInfo` (`SkyLight.swift:519`) does indeed take any window id and apply
**no** level filter — matching the upstream concern exactly. The difference is
what nehir does with the result (next sections).

## The code in question

### 1. The frame-event path (upstream "Theory 2")

```swift
// Sources/Nehir/Core/Controller/AXEventHandler.swift:677
private func handleFrameChanged(windowId: UInt32) {
    guard let controller else { return }
    guard !controller.isOwnedWindow(windowNumber: Int(windowId)) else { return }
    let windowServerToken = resolveWindowToken(windowId)
    let resolvedToken = resolveTrackedToken(windowId, resolvedWindowToken: windowServerToken)
    …
    guard let token = resolvedToken else { return }
    guard let entry = controller.workspaceManager.entry(for: token) else { return }   // :690  ← the gate
    …
    controller.layoutRefreshController.requestRefresh(reason: .axWindowChanged, …)   // only reached if tracked
}
```

`resolveWindowToken` / `resolveTrackedToken` (`AXEventHandler.swift:3989`,
`:3996`) call `queryWindowInfo` (no level filter), so a pill's window id *does*
resolve to a `WindowServerInfo`. But that token is **not** a tracked workspace
entry, so `workspaceManager.entry(for:)` at `AXEventHandler.swift:690` returns
`nil` and the function returns before any `requestRefresh`. Level filtering is
irrelevant here because the tracked-entry membership check is stricter and runs
first.

### 2. The admission path — input pill refused by name

```swift
// Sources/Nehir/Core/Rules/WindowRuleEngine.swift:199
static let systemTextInputPanelRuleName = "systemTextInputPanel"
private static let systemTextInputPanelBundleIds: Set<String> = [
    "com.apple.characterpaletteim",
    "com.apple.emojifunctionrowitem-container",
    "com.apple.textinputmenuagent",     // ← the Caps-Lock input-source indicator process
    "com.apple.textinputswitcher"       // ← the input-source switcher
]

// Sources/Nehir/Core/Rules/WindowRuleEngine.swift:301  (first thing decision() does)
func decision(for facts: WindowRuleFacts, token: WindowToken?, appFullscreen: Bool) -> WindowDecision {
    if let bundleId = facts.ax.bundleId?.lowercased(),
       Self.systemTextInputPanelBundleIds.contains(bundleId)
    {
        return WindowDecision(
            disposition: .unmanaged,
            source: .builtInRule(Self.systemTextInputPanelRuleName),
            …
        )   // trackedMode is nil here
    }
    …
}
```

A `.unmanaged` decision with `trackedMode == nil` makes
`trackedModeForLifecycle(decision:existingEntry:)` (`WMController.swift:1907`)
return `nil`, which makes `prepareCreateCandidate` (`AXEventHandler.swift:2561`)
return `nil`, so the window is **never admitted**. Once not admitted it has no
entry, and `handleFrameChanged`'s `:690` guard stops its frame events too.

This is locked by a regression test:

```swift
// Tests/NehirTests/WindowRuleEngineTests.swift:483  systemTextInputPanelBundlesAreUnmanagedBeforeFloatingHeuristics
let bundleIds = [ "com.apple.CharacterPaletteIM",
                  "com.apple.EmojiFunctionRowItem-Container",
                  "com.apple.TextInputMenuAgent",
                  "com.apple.TextInputSwitcher" ]
for bundleId in bundleIds {
    let decision = engine.decision(for: makeWindowRuleFacts(bundleId: bundleId, …,
                              appPolicy: .accessory, windowServer: …(level: 3)…), …)
    #expect(decision.disposition == .unmanaged)
    #expect(decision.trackedMode == nil)
    #expect(decision.admissionOutcome == .ignored)
    #expect(… name == WindowRuleEngine.systemTextInputPanelRuleName)
}
```

### 3. The focus-churn path (upstream "Theory 1")

When a system overlay process briefly becomes frontmost,
`handleAppActivation(pid:)` (`AXEventHandler.swift:1428`) resolves its focused AX
window. System UI agents (`TextInputMenuAgent`, `coreaudiod`, Control Center,
screencaptureui) present **no AX standard window** for their pid, so
`resolveFocusedAXWindowRef` returns `nil` → `handleMissingFocusedWindow`
(`AXEventHandler.swift:3691`) → `enterNonManagedFocus` (`WorkspaceManager.swift:1802`).
That path only mutates **focus** session state and clears the focus border; it
**does not move, resize, or relayout** any window. There is no managed sibling to
reveal, so the `scrollToReveal` viewport path (see sibling doc, below) is never
entered for these system processes.

## Why nehir doesn't reproduce

**Input-source pill (issue's primary reproduction):** refused admission by the
`systemTextInputPanel` built-in rule (`WindowRuleEngine.swift:301`) for
`com.apple.textinputmenuagent` / `com.apple.textinputswitcher`. Cannot be tracked,
cannot relayout. Pinned by `WindowRuleEngineTests.swift:483`.

**Screen-recording indicator / screencapture pill:** these are system surfaces
rendered at the SkyLight level with no AX standard-window representation. They
fail the `resolveAXWindowRef` admission gate in `prepareCreateCandidate`
(`AXEventHandler.swift:2587`), so they are not admitted. They are additionally
excluded from the unmanaged-window occlusion set because nehir's occlusion
predicate drops any owner whose activation policy is not `.regular`
(`WMController.swift:2524`):

```swift
// Sources/Nehir/Core/Controller/WMController.swift:2520
if pid > 0,
   let activationPolicy = ownerActivationPolicyProvider(pid),
   activationPolicy != .regular
{
    continue   // system chrome (accessory/prohibited) is invisible to occlusion
}
```

(The `queryAllVisibleWindows` enumerator also restricts itself to
`level == 0 || level == 3 || level == 8` at `SkyLight.swift:484`, so level-103+
system pills never enter the regular discovery/refresh enumeration that the
upstream `getDisplayWindows` analog was also meant to feed.)

**Defense-in-depth on the frame path:** even a hypothetical overlay that slipped
past admission could not relayout a tiled window, because `handleFrameChanged`
requires a tracked entry (`AXEventHandler.swift:690`) before it ever calls
`requestRefresh`. This is the layer the upstream "Theory 2" was worried about,
and nehir already has the stronger, earlier guard there.

**Third-party recording overlays are handled too:** the CleanShot X recording
overlay at level 103 is matched by `cleanShotRecordingOverlayDecision`
(`WindowRuleEngine.swift:455`) and made `.floating` (never `.managed`), so even
when admitted it does not perturb the niri column layout.

### Relationship to the sibling viewport-reveal discovery

The one real "unmanaged overlay perturbs the layout" bug in nehir is the
**viewport-reveal-on-app-activation** path, documented in
`docs/plans/discovery/20260615-viewport-reveal-from-unmanaged-overlay-activation.md`.
That sibling is a *structurally different* trigger from #358:

| | #358 (this item) | viewport-reveal sibling |
|---|---|---|
| Overlay owner | **system process** (TextInputMenuAgent / screencapture) | **app-owned** overlay (Ghostty Quick Terminal) |
| Same pid as a managed window? | **no** | **yes** — resolves to a managed sibling |
| Hits `scrollToReveal`? | no — system pid has no AX focused window → `enterNonManagedFocus` (benign) | yes — the managed sibling's column is revealed |
| Owned by this item? | no | owned by the sibling |

#358's system-pill trigger cannot reach the reveal path, because a system process
has no focused AX window and no managed sibling. The reveal bug is already owned
by the sibling; #358 adds nothing to it.

## Why the upstream fix is unsafe / unnecessary to port

Hiro PR #385 ("Suppress input during screenshot selection") was **closed without
merge**. It detects `com.apple.screencaptureui` / `com.apple.Screenshot` as
frontmost and suppresses mouse handling + layout refresh via the lock-screen-style
`isInputSuppressed` pattern. Porting it would be a regression risk for nehir with
no upside:

- nehir already has the `isInputSuppressed` mechanism it would lean on
  (`MouseEventHandler.swift:563`, gated on the lock screen).
- nehir's occlusion predicate already excludes non-`.regular` system chrome
  (`WMController.swift:2524`), which covers the screencapture UI, so a
  per-frontmost-process suppression is redundant.
- The issue's *input-source pill* reproduction is already handled by the
  `systemTextInputPanel` rule, which PR #385 does not address at all (it targets
  the screencaptureui process, not TextInputMenuAgent).
- A broad "suppress all layout refresh while a system overlay is frontmost" guard
  is exactly the kind of over-broad suppression that the completed FFM plan
  (`docs/plans/completed/20260615-ffm-suppress-over-unmanaged-overlay-windows.md`)
  found causes hot-path freezes (the Notification Center regression). nehir chose
  the narrower, activation-policy-scoped approach deliberately.

## Recommendation

**Do nothing for #358 specifically.** No new action is owned here. If the
viewport-reveal behavior for *app-owned* overlays (Quick Terminal etc.) is later
fixed, follow the sibling doc instead — #358's system-pill case is already
covered and is not part of that fix's scope. Optionally, if a future system
overlay bundle is ever observed being admitted, extend the
`systemTextInputPanelBundleIds` set (`WindowRuleEngine.swift:199`) — but no such
bundle is implicated by this issue.

## Suggested tests

None required — the existing test
`systemTextInputPanelBundlesAreUnmanagedBeforeFloatingHeuristics`
(`WindowRuleEngineTests.swift:483`) already pins the input-pill case that drives
this issue, and the frame-event tracked-entry guard is exercised by the broader
`handleFrameChanged` test suite. A no-op regression test would add maintenance
cost without locking in new behavior.
