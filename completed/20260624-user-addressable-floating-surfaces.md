# User-addressable floating surfaces: stop transient helpers from blinking in the workspace bar — Plan

**Status:** completed — merged to `main` as `54d5dd7e` ("Hide app-managed transient and parented floating surfaces from the workspace bar") on 2026-06-25. The first implementation slice shipped: parented WindowServer child surfaces auto-float and inherit their parent's workspace (niri model); app-managed transient helper/PIP surfaces that lack standard-window AX affordances are no longer user-addressable — they are hidden from the workspace bar, excluded from the toggle-floating command, and bound to their owning app's primary workspace so they can no longer leak focus onto the viewed workspace. The size-threshold predicate proposed in this plan was replaced by an AX-affordance classifier (`isStandardAXWindowSurface`: standard window role/subrole + close button + enabled fullscreen button) plus `globalSticky`, so no `minimumUserAddressableFloatingDimension` heuristic shipped. Explicit `FloatingIntent` persistence (Phase 3), rescue/restore cleanup (Phase 4), and the optional stability gate (Phase 5) remain deferred follow-ups, as the plan's own "Recommended first implementation slice" recommended. Moved from `planned/` to `completed/` on 2026-06-25.

Plan date: 2026-06-24. Source paths and implementation notes were verified
against the main Nehir source tree at `ade7cd07` (`Keep PiP visible across
workspace switches (#108)`). Line numbers may drift.

## Problem statement

Nehir currently has one broad answer for non-tiled windows: track them as
`.floating`. That was the right direction for qutebrowser frameless windows,
browser PiP, and transient WindowServer popup surfaces, but it now conflates
several separate policies:

1. do not tile the surface;
2. track lifecycle for cleanup / replacement correlation;
3. activate or raise the window on create;
4. show it as a floating-window icon in the workspace bar;
5. mark it rescue-eligible / restoreable;
6. treat it as workspace occupancy.

The recent Helium and Zoom runtime evidence shows that this coupling is too
broad. Tiny app-emitted helper surfaces are tracked as floating, then appear and
disappear in the workspace bar, making the floating group blink even though the
user has no intentional floating window.

This plan keeps the hard-won qutebrowser/PiP behavior — **we still track weird
but legitimate floating surfaces** — while adding a second, generic notion of
whether a tracked floating surface is **user-addressable**. Only
user-addressable floating windows should be bar-visible, rescue-eligible by
default, and restored as durable floating windows.

## Runtime evidence to preserve in the plan

Do not rely on reopening trace files. The relevant observations are:

### Helium helper surface

The visible workspace had a real tiled Helium window:

```text
WindowToken(pid: 57195, windowId: 537)
bundleId=net.imput.helium
mode=tiling
liveAXFrame={{1032.0, 0.0}, {1008.0, 1282.0}}
```

The blinking floating entry was a separate tiny Helium surface:

```text
WindowToken(pid: 57195, windowId: 17365)
bundleId=net.imput.helium
mode=floating
observedFrame={{1034.0, 2.0}, {38.0, 43.0}}
desiredFloating={{1034.0, 2.0}, {38.0, 43.0}}
rescue=true
```

The workspace-bar frame toggled between a narrower and wider width as the
floating group appeared/disappeared, e.g. roughly `572 pt` vs `627 pt`, matching
the visible blink.

### Zoom hover helper surfaces

The real Zoom call window was tiled:

```text
WindowToken(pid: 96260, windowId: 17166)
bundleId=us.zoom.xos
mode=tiling
liveAXFrame={{67.0, 0.0}, {1922.0, 1282.0}}
```

Hovering the Zoom call emitted short-lived floating helper surfaces:

```text
14:30:42  window 17492 admitted as floating
14:30:42  floating_geometry_updated frame=(77.0, 68.0, 56.0, 56.0) restore=true
14:30:43  window 17492 destroyed

14:30:44  window 17493 admitted as floating
14:30:44  floating_geometry_updated frame=(77.0, 68.0, 56.0, 56.0) restore=true
14:30:45  window 17493 destroyed
```

Both helpers were only `56×56` and were created/destroyed while the user was
hovering, so they should not be represented as durable floating windows in the
bar.

## Relevant existing work

### qutebrowser / frameless windows (#66)

`completed/20260619-nehir-66-borders-undecorated-windows.md` established the
key constraint: **unusual AX shape is not sufficient evidence that a surface is
disposable.** qutebrowser's undecorated top-level window can report
`role=AXWindow`, `subrole=AXDialog`, no normal titlebar controls, and malformed
fullscreen-button AX values, yet WindowServer shows a normal top-level app
surface (`level=0`, `parentId=0`, regular app, normal-sized frame). The fix
there correctly avoided broad `AXDialog` rejection and instead used a narrow
border compatibility path.

Implementation touchpoints:

- `Sources/Nehir/Core/Ax/AXWindow.swift` treats a malformed fullscreen-button
  value as a missing fullscreen button when the rest of the AX facts are usable.
- `Sources/Nehir/Core/Border/FocusBorderController.swift` has a narrow
  qutebrowser top-level border exemption, not a general `AXDialog` relaxation.

This plan must not regress qutebrowser by globally hiding all non-standard AX
surfaces.

### Transient popup surfaces (#98/#104)

`completed/20260622-nehir-98-104-transient-popup-surfaces.md` added the generic
`transientWindowServerSurface` path:

- `Sources/Nehir/Core/Rules/WindowRuleEngine.swift` classifies AX-complete,
  floating-tagged, non-document WindowServer surfaces as `.floating`, before a
  broad user tiling rule can put them into the tiled tree.
- `Sources/Nehir/Core/Controller/AXEventHandler.swift` skips create-time
  activation/raise/frame writes when `managedReplacementMetadata.transientWindowServerEvidence`
  is true.

That fixed layout churn and popup dismissal. It intentionally still tracks
transient surfaces for lifecycle bookkeeping. The missing piece is downstream:
transient tracked floating entries should not automatically be bar-visible or
rescue-eligible.

### Workspace-bar floating filter (BarutSRB/OmniWM#323 discovery)

`discovery/20260616-omniwm-323-floating-panel-bar-filter.md` already identified
that `WorkspaceManager.barVisibleFloatingEntries` is too permissive. The current
filter excludes only scratchpads:

```swift
private func barVisibleFloatingEntries(in workspace: WorkspaceDescriptor.ID) -> [WindowModel.Entry] {
    floatingEntries(in: workspace).filter {
        !isScratchpadToken($0.token) && hiddenState(for: $0.token)?.isScratchpad != true
    }
}
```

The OmniWM-style `layoutReason == .standard` filter is useful but insufficient
for this bug: the Helium/Zoom helpers are standard-layout floating entries.

### PiP / global sticky windows (#108)

The current main source has `SpaceTopology.isWindowOnAllKnownSpaces` and global
sticky window handling in `LayoutRefreshController`. That is a good model for
this plan: use durable system evidence (native Space membership) rather than
browser/app bundle hardcodes.

PiP-like global/all-Spaces windows may be floating, persistent, and useful in the
bar. The plan must not hide those just because they are non-tiled or above-normal
level.

## Non-goals

- Do **not** add Helium or Zoom bundle-id hardcodes.
- Do **not** undo qutebrowser frameless-window compatibility.
- Do **not** globally reject `AXDialog`, `AXSystemDialog`, no-button, or
  non-standard-subrole windows.
- Do **not** blanket-ignore all `level > 0` WindowServer windows; PiP and some
  legitimate floating surfaces live above normal level.
- Do **not** stop tracking transient surfaces entirely in the first slice. The
  immediate visible bug is bar projection and rescue semantics, not lifecycle
  observation.

## Design: split tracked-floating from user-addressable-floating

Introduce a generic surface-traits decision for tracked floating entries. The
naming can vary, but the model should be explicit:

```swift
enum FloatingSurfacePresentation: Equatable, Sendable {
    case userAddressable
    case transientAuxiliary
}
```

or equivalent metadata booleans:

```swift
struct FloatingSurfaceTraits: Equatable, Sendable {
    var isUserAddressable: Bool
    var isBarVisible: Bool
    var isRescueEligibleByDefault: Bool
    var shouldActivateOnCreate: Bool
}
```

The crucial rule:

> `.floating` means “tracked and not tiled.” It does **not** automatically mean
> “show in the bar,” “rescue/restore forever,” or “activate on create.”

### Generic evidence for transient auxiliary surfaces

Use evidence already present in `WindowRuleFacts`, `ManagedReplacementMetadata`,
and `WindowModel.Entry`:

- `managedReplacementMetadata.transientWindowServerEvidence == true`
- WindowServer parent evidence: `parentWindowId != nil && parentWindowId != 0`
- WindowServer modal/floating-non-document evidence:
  - `hasModalTag`
  - `hasFloatingTag && !hasDocumentTag`
- very small observed/floating frame, e.g. either dimension below a configurable
  internal threshold such as `80 pt`
- short-lived create/destroy churn, once a stability mechanism exists
- no explicit user rule/manual override/scratchpad assignment

The initial implementation can use size + existing transient evidence. Add
stability/lifetime classification later if needed.

### Generic evidence for user-addressable floating surfaces

A floating entry should remain bar-visible / rescue-eligible when there is real
user or system evidence:

- explicit user rule `layout = "float"`
- manual float override / explicit toggle-to-floating command
- scratchpad assignment (rendered through the scratchpad path, not the floating group)
- persisted restore catalog entry with rescue intent
- global/all-Spaces SpaceTopology evidence (PiP-like sticky windows)
- normal-size top-level WindowServer surface (`parentId == 0`, intersects a
  monitor visible frame, not tiny)
- durable survival past a future stability threshold

## Implementation plan

### Phase 1 — Trace and diagnostics first

Add enough trace output so future captures explain the decision without reopening
local logs.

1. Extend create/admission trace output for tracked floating candidates.
   - Source: `Sources/Nehir/Core/Controller/AXEventHandler.swift`.
   - Include:
     - token, bundle id, mode
     - role/subrole/title length
     - WindowServer level/tags/attributes/parent/frame
     - `transientWindowServerEvidence`
     - `degradedWindowServerChildEvidence`
     - floating surface presentation, once implemented
2. Add workspace-bar projection diagnostics behind existing runtime-trace hooks.
   - Source: `Sources/Nehir/UI/WorkspaceBar/WorkspaceBarDataSource.swift` or
     `Sources/Nehir/Core/Workspace/WorkspaceManager.swift`.
   - For each floating candidate, record accepted/rejected and reason:
     - `scratchpad`
     - `layoutReason`
     - `tinyTransientSurface`
     - `transientWindowServerSurface`
     - `userAddressable`
     - `globalSticky`
3. Add debug dump fields to runtime state if the traits are stored in metadata.

Acceptance: a new trace should identify a `56×56` Zoom helper as a rejected
floating-bar candidate without needing external log context.

### Phase 2 — Bar projection predicate

Add a dedicated predicate in `WorkspaceManager`:

```swift
private func isBarVisibleFloatingEntry(_ entry: WindowModel.Entry) -> Bool
```

Then make `barVisibleFloatingEntries` use it.

Suggested initial rules:

1. Exclude scratchpad windows exactly as today.
2. Exclude non-standard layout reasons except cases explicitly known to be safe.
   This ports the useful part of BarutSRB/OmniWM#323.
3. Exclude transient/tiny helper surfaces:
   - if `entry.managedReplacementMetadata?.transientWindowServerEvidence == true`
     and the resolved/observed frame is below the internal minimum user-window
     size, reject;
   - if `parentWindowId != nil && frame is tiny`, reject;
   - if no frame is available but transient evidence is true, default to hidden
     from the bar until proven stable/user-addressable.
4. Allow explicit user-addressable cases:
   - manual/user-rule floating intent once that intent is stored;
   - global sticky windows from `WorkspaceManager.isGlobalStickyWindow(_:)`;
   - normal-size floating windows.

Frame source order:

1. `resolvedFloatingFrame(for:)`
2. `entry.desiredState.floatingFrame`
3. `entry.observedState.frame`
4. `entry.managedReplacementMetadata?.frame`

Internal threshold:

- Start with a named private constant, e.g. `minimumUserAddressableFloatingDimension = 80.0`.
- Keep it internal and documented as a bar-projection heuristic, not a layout
  classifier.
- Do not expose a user setting in the first slice.

Tests:

- `Tests/NehirTests/WorkspaceBarDataSourceTests.swift`
  - Zoom-like `56×56` transient floating helper is not in `floatingWindows`.
  - Helium-like `38×43` transient/top-edge helper is not in `floatingWindows`.
  - ordinary `500×320` floating window still appears.
  - floating-only workspace with only rejected helper remains hidden when
    `hideEmptyWorkspaces=true`.
  - scratchpad projection remains unchanged.
  - global sticky floating entry still appears if normal/PiP-sized.

### Phase 3 — Store explicit floating intent

The bar predicate needs a durable way to distinguish user-intended floating from
heuristic/transient floating. Add a small source/intent field rather than
inferring forever from bundle ids or AX shape.

Candidate locations:

- `WindowModel.Entry`
- `ManagedReplacementMetadata`
- `WindowModel.FloatingState`
- or a new `FloatingSurfaceTraits` stored on the entry and copied into metadata
  for replacements/restores.

Suggested shape:

```swift
enum FloatingIntent: String, Codable, Sendable {
    case heuristic
    case transientWindowServer
    case userRule
    case manualOverride
    case scratchpad
    case restored
    case globalSticky
}
```

Set it at these sources:

- `WindowRuleEngine.decision` / `AXEventHandler.prepareCreateCandidate`
  - user explicit float rule => `.userRule`
  - `transientWindowServerSurface` => `.transientWindowServer`
  - heuristic fallback floating => `.heuristic`
- manual toggle-to-floating command => `.manualOverride`
- scratchpad assignment => `.scratchpad`
- restore hydration => `.restored`
- SpaceTopology global sticky update => `.globalSticky` or a separate trait

Use this field only for downstream presentation/rescue decisions; do not make it
another app-specific rule path.

Tests:

- explicit user float rule on a small utility window remains bar-visible.
- heuristic tiny transient window is not bar-visible.
- manual-floated window remains rescue-eligible.

### Phase 4 — Rescue / restore semantics cleanup

Current code defaults floating geometry to rescue intent:

```swift
func updateFloatingGeometry(..., restoreToFloating: Bool = true)
```

and reconcile restore intent also treats floating as rescue-worthy:

```swift
restoreToFloating: floatingState?.restoreToFloating ?? (entry.mode == .floating)
rescueEligible: entry.desiredState.rescueEligible || floatingState?.restoreToFloating == true
```

This is why a `56×56` Zoom hover helper gets `rescue=true`.

Change the contract so `restoreToFloating` means actual user/durable intent:

1. Audit every call to `updateFloatingGeometry`.
2. Pass `restoreToFloating: false` for transient/helper creates unless the
   candidate has explicit user/restored/global intent.
3. Keep `restoreToFloating: true` for:
   - manual floating commands,
   - explicit user float rules if desired,
   - persisted restore hydration,
   - scratchpad,
   - global/all-Spaces PiP-like surfaces where restore is intended.
4. Update `StateReducer.restoreIntent` so `entry.mode == .floating` alone does
   not imply durable rescue intent for transient/helper entries.

Tests:

- Zoom-like helper can be tracked floating but has `rescueEligible == false`.
- manual-floated normal window keeps `rescueEligible == true`.
- PiP/global sticky restore behavior from #108 remains intact.
- qutebrowser tracked floating behavior remains intact; if manually tiled/floated,
  user intent wins.

### Phase 5 — Optional stability gate

If bar filtering and rescue cleanup are not enough, add a stability layer:

a floating surface must survive a short interval or repeated observations before
becoming user-addressable. This should be a later slice because it touches
admission timing and can delay legitimate floating dialogs.

Possible design:

- track first-seen timestamp/window id in `AXEventHandler`;
- classify as provisional transient until either:
  - frame stays stable for `N` observations or `T` milliseconds; or
  - explicit user/global/restored evidence appears;
- provisional entries are tracked for lifecycle but hidden from the bar and not
  rescue-eligible.

Tests:

- create/destroy within the stability window never becomes bar-visible.
- stable normal floating panel becomes bar-visible after the threshold.

## Suggested test matrix

### WindowRuleEngine tests

- Existing `transientWindowServerSurface` rule remains `.floating`, preserving
  user workspace/min-size effects.
- Existing qutebrowser malformed fullscreen-button test remains valid.
- Above-normal/PiP classification remains `.floating`, not `.unmanaged`.
- User explicit float rule records user/durable intent.

### AXEventHandler tests

- Transient floating create still does not activate/raise/apply immediate frame.
- Transient tiny helper is tracked but not rescue-eligible after Phase 4.
- Explicit user-float create remains rescue-eligible.
- Post-create lifecycle verification still removes helpers that disappear.

### WorkspaceBarDataSource / WorkspaceManager tests

- Tiny transient floating helpers are excluded from `floatingWindows`.
- Normal floating windows still appear.
- Scratchpad projection unchanged.
- Floating-only workspace with only rejected helpers is treated as empty when
  `hideEmptyWorkspaces=true`.
- Floating-only workspace with a normal user-addressable floating window is shown.
- Deduplication remains separated by mode for accepted floating windows.

### LayoutRefresh / SpaceTopology tests

- Global sticky PiP-like windows remain visible and not parked.
- Global sticky floating entries can remain bar-visible even if classified via
  transient/floating WindowServer tags, provided they are user-addressable by
  size/global evidence.
- Native-inactive windows remain exempt from offscreen parking.

### FocusBorder tests

- qutebrowser top-level `AXWindow`/`AXDialog` still allows focused border.
- non-qutebrowser `AXDialog` still suppresses focused border.
- The new surface traits do not change border eligibility unless explicitly wired.

## Acceptance criteria

1. Reproducing the Zoom hover case no longer makes the workspace bar width blink
   from a transient `56×56` floating helper.
2. Reproducing the Helium case no longer shows a `38×43` top-edge helper as a
   floating window icon.
3. Normal user floating windows still appear in the workspace bar when
   `showFloatingWindows=true`.
4. qutebrowser frameless windows remain trackable and keep their border behavior.
5. Browser PiP/global sticky behavior from #108 remains intact.
6. No new app bundle hardcodes are added for Helium, Zoom, or browsers.
7. Runtime traces explain the bar projection decision inline.

## Risks and mitigations

- **Risk: hiding legitimate small floating utilities.**
  Mitigation: user/manual/explicit-float intent overrides the tiny/transient
  filter. Keep the size gate scoped to bar projection first.

- **Risk: PiP disappears from the bar.**
  Mitigation: allow global sticky/all-Spaces windows and normal-size persistent
  floating frames through the bar predicate.

- **Risk: qutebrowser regresses.**
  Mitigation: do not use AX subrole alone as a transient signal. Keep the
  qutebrowser regression tests and require top-level WindowServer evidence.

- **Risk: rescue semantics changes break restore.**
  Mitigation: split Phase 4 from the initial bar fix, add focused restore tests,
  and preserve explicit/manual/persisted rescue paths.

## Recommended first implementation slice

For the first PR, keep scope intentionally small:

1. Add trace/debug output for floating-bar projection decisions.
2. Add `WorkspaceManager.isBarVisibleFloatingEntry`.
3. Exclude tiny transient/helper floating entries from the bar using generic
   metadata/frame evidence.
4. Add `WorkspaceBarDataSourceTests` coverage for Helium-like and Zoom-like
   surfaces.

Leave explicit floating intent persistence and rescue cleanup for follow-up PRs
unless the first slice exposes unavoidable model gaps.
