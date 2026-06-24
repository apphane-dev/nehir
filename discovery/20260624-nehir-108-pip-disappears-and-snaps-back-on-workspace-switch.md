# Nehir issue #108 — Picture-in-Picture window disappears on workspace switch and snaps back to its origin workspace — Discovery

Source issue: https://github.com/apphane-dev/nehir/issues/108
Reporter browser: Vivaldi (also reproduced with Firefox).
Scope of this doc: determine why a tracked Picture-in-Picture (PiP) mini-window
disappears when switching Nehir workspaces and snaps back to the workspace/monitor
where it was opened when dragged to another monitor, and propose a fix direction
consistent with the recent `transientWindowServerSurface` work (#98/#104).

All code citations were verified against the main Nehir source tree at `1aa518bc`
on 2026-06-24 (`git log -1 --format='%h %s'` → `1aa518bc Add command palette
fallback to other sources on empty results`). Line numbers drift — re-verify before
implementing. The runtime evidence below is inlined from the reporter's capture; no
trace-log filename or local path is referenced. A durable pointer to the original
capture is provided at the end for completeness only — the document stands without it.

---

## TL;DR

- **Symptom.** A browser PiP window (1) vanishes when the user switches Nehir
  workspaces and (2) cannot be moved to a different monitor — it snaps back to the
  workspace/monitor where the browser lives.
- **Root cause.** A PiP is admitted as a **tracked floating window bound 1:1 to the
  browser's workspace**. The workspace-switch hide path, `hideWorkspace`, parks
  **every** tracked entry on an inactive workspace (tiling *and* floating; only
  `nativeFullscreen` is exempt) and never consults whether macOS considers the
  window globally visible. So a PiP — which the owning app intends to float above
  all Spaces via `collectionBehavior = .canJoinAllSpaces` — gets parked offscreen
  exactly like any other window, and its stored floating frame is anchored to the
  browser workspace's monitor, so a drag to another monitor is overridden on the
  next refresh. This is the same 1:1 binding + offscreen-park machinery described
  by `discovery/20260617-omniwm-315-sticky-apps-across-workspaces.md`.
- **Direct link to #98/#104 (the "qutebrowser fix").** The capture contains a
  **Firefox** PiP whose admission decision is literally
  `source=builtInRule(transientWindowServerSurface)` — the rule added by the #98/#104
  fix. That fix made PiP-class surfaces **consistently floating and tracked** and
  gated their *create-time activation* (`shouldActivateFloatingCreate`), but it
  deliberately left them tracked for lifecycle bookkeeping and did **not** gate the
  workspace-switch **parking** path (`hideWorkspace`) or the floating-frame
  **restore** path. #108 is the visible side effect of that gap: a transient/global
  surface is no longer tiled or dismissed-on-open, but it now reliably vanishes and
  snaps back on workspace switch.
- **Verdict:** 🟡 **Partial — owns a follow-up.** The bug is real and reproducible
  across classification sources (user rule, built-in title rule, and the
  `transientWindowServerSurface` rule all land here). Nehir already has the missing
  primitive — `SkyLight.spacesForWindow` / `SpaceTopology` macOS-Space membership —
  but uses it only to *prevent removal* during rescan, never to *prevent parking*.
  The fix is to exempt a window macOS reports as **global** (present on every known
  Space, i.e. `canJoinAllSpaces`) from `hideWorkspace` and from reference-monitor
  force-restore, and to re-anchor its workspace so the model stays coherent. Note the
  hard limit exposed by a single-display capture: Space-count can only distinguish a
  global PiP from a normal window when `knownSpaces > 1` (multi-display separate
  Spaces, the reporter's setup); single-display needs a different signal. The
  SIP-bounded "always on top" caveat from OmniWM discussion #11 still applies and is
  out of scope here.

### Implementation status

The current Nehir source tree now includes that fix direction: CGS create events
record native Space membership per window, windows present on all known Spaces are
marked sticky/global, and native-inactive windows are exempted from workspace-parking
and related restore logic.

Runtime confirmation from the user is still pending.

---

## Provenance: is this Nehir's code?

Yes. Every path in the causal chain is Nehir-local and was inspected in the source
tree cited above:

- **Floating admission (the "qutebrowser fix" path).**
  `Sources/Nehir/Core/Rules/WindowRuleEngine.swift:207` defines
  `transientWindowServerSurfaceRuleName`; the pre-user-rule branch that returns
  `.floating` for AX-complete, floating-tagged, non-document WindowServer surfaces
  sits around `WindowRuleEngine.swift:362`-`369` (the `hasFloatingTag` test is at
  `:364`). The WindowServer evidence it keys on is
  `WindowServerInfo.hasTransientSurfaceEvidence`
  (`Sources/Nehir/Core/SkyLight/SkyLight.swift:941`), defined as
  `hasParentWindow || (hasFloatingTag && !hasDocumentTag)`.
- **Create-time activation gating (also from #98/#104).**
  `Sources/Nehir/Core/Controller/AXEventHandler.swift:1179` calls
  `shouldActivateFloatingCreate`, defined at `AXEventHandler.swift:1242`, which
  returns `false` when `replacementMetadata.transientWindowServerEvidence` is true.
  The tracked entry is still added at `AXEventHandler.swift:1168`
  (`addWindow(... mode: candidate.mode ...)`).
- **Workspace-switch parking.**
  `Sources/Nehir/Core/Controller/LayoutRefreshController.swift:2273` `hideWorkspace`
  iterates entries and parks each one with `reason: .workspaceInactive`
  (`LayoutRefreshController.swift:2302`). The only `continue` guard is
  `layoutReason != .nativeFullscreen` (`LayoutRefreshController.swift:2280`).
  `hideWindow` (`LayoutRefreshController.swift:2715`) resolves a physical screen-edge
  origin via `liveFrameHideOrigin` (`LayoutRefreshController.swift:2736`) and applies
  it.
- **Floating-frame restore / snap-back.**
  `Sources/Nehir/Core/Workspace/WorkspaceManager.swift:2808`
  `updateFloatingGeometry` stores `lastFrame`, a normalized origin, and a
  `referenceMonitorId` (resolved from the frame's monitor or the entry's workspace
  monitor, `WorkspaceManager.swift:2816`). `resolvedFloatingFrame`
  (`WorkspaceManager.swift:2846`) rebuilds the frame on that reference monitor.
- **macOS-Space membership primitive (the unused lever).**
  `Sources/Nehir/Core/SkyLight/SkyLight.swift:367` `spacesForWindow(_:)` calls the
  private `copySpacesForWindows` with `allSpacesMask = 0x7`
  (`SkyLight.swift:155`). `Sources/Nehir/Core/SkyLight/SpaceTopology.swift` builds a
  window→Spaces map (`SpaceTopology.swift:70`/`:74`) and exposes
  `isWindowOnKnownInactiveSpace(windowId:)` (`SpaceTopology.swift:34`). Today this is
  consumed **only** to keep a window from being removed as "missing" during the full
  rescan (`LayoutRefreshController.swift:1468`-`1480`, the `spaceTopology.exempt`
  loop) — never to keep it from being parked.

---

## Topology / initial state (from the reporter's capture)

Two displays, "Displays have separate Spaces" ON:

- `ID(displayId: 2)` "LG FHD" — external, main, `frame=(0.0, 0.0, 1920.0, 1080.0)`,
  `visibleFrame=(0.0, 0.0, 1920.0, 1049.0)`.
- `ID(displayId: 1)` "Built-in Retina Display" — MacBook,
  `frame=(1866.0, 1080.0, 1440.0, 900.0)`.

`displaySpacesMode=enabled`. `SpaceTopology mode=enabled activeSpaces=2
knownSpaces=2 windowRecords=6` (start of capture). Seven Nehir workspaces; workspace
2 (`654B4369-…`) and workspace 3 (`F5625259-…`) both live on the external monitor
(displayId 2). The capture (≈57 s) contains **two** PiP windows, which is ideal
because they are classified by *different* rules and still fail identically.

---

## What the evidence proves

### 1. A Vivaldi PiP tracked as floating on the external monitor's workspace

Vivaldi PiP: `WindowToken(pid: 1776, windowId: 983)`, `bundleId=com.vivaldi.Vivaldi`,
`mode=floating`, bound to workspace `654B4369-…` (workspace 2, on displayId 2).

Admission decision (from the create-focus trace):

```text
window_decision token=WindowToken(pid: 1776, windowId: 983) context=focused_admission
  existingMode=nil disposition=floating source=userRule(4E5928BF-72D7-4744-8664-5C4A3782CE1E)
  outcome=trackedFloating layout=fallbackLayout bundleId=com.vivaldi.Vivaldi
  axRole=AXWindow axSubrole=AXStandardWindow hasCloseButton=true hasFullscreenButton=false
  hasZoomButton=true hasMinimizeButton=true
  wsLevel=3 wsTags=0x100082c01 wsAttributes=0x3 wsParent=0
```

`wsTags=0x100082c01` has the **document** bit (0x1) set and **no floating** bit (0x2),
so `hasTransientSurfaceEvidence` is false; this PiP is floated by the **user's own
rule** (`source=userRule(4E5928BF-…)`) — exactly the rule the reporter mentions having
created ("I tried creating a rule that would detect the name of the picture-in-picture
window"). The rule *did* match and *did* float the window; it "didn't change anything"
because floating + workspace-bound + park-on-switch is the same broken end state.

### 2. A Firefox PiP tracked as floating via the #98/#104 `transientWindowServerSurface` rule

Firefox PiP: `WindowToken(pid: 19291, windowId: 1394)`, `bundleId=org.mozilla.firefox`,
`title="Picture-in-Picture"` (titleLength=18), `mode=floating`, bound to workspace
`F5625259-…` (workspace 3, on displayId 2).

```text
window_decision token=WindowToken(pid: 19291, windowId: 1394) context=focused_admission
  existingMode=nil disposition=floating source=builtInRule(transientWindowServerSurface)
  outcome=trackedFloating layout=fallbackLayout bundleId=org.mozilla.firefox titleLength=18
  axRole=AXWindow axSubrole=AXStandardWindow hasCloseButton=true hasFullscreenButton=true
  fullscreenButtonEnabled=true hasZoomButton=true hasMinimizeButton=true
  wsLevel=3 wsTags=0x3000001004c2802 wsAttributes=0x3 wsParent=0
```

`wsTags=0x3000001004c2802` has the **floating** bit (0x2) set and **no document** bit
(0x1), `wsParent=0`, so `hasTransientSurfaceEvidence=true` and the decision is
`source=builtInRule(transientWindowServerSurface)`. This is the qutebrowser-fix rule
firing on a real PiP — a direct, in-capture link between #108 and the #98/#104 work.
(Its title would also match the built-in `browserPictureInPicture` `^Picture-in-Picture$`
rule, but the transient branch wins ordering; both yield `.floating`.)

### 3. Both PiPs were dragged onto the MacBook, then snapped back to the external monitor

The user dragged each PiP from the external monitor (displayId 2) onto the MacBook
(displayId 1, x ≥ 1866). The floating-geometry events record the MacBook coordinates
while the interaction monitor is the MacBook:

```text
# floating_geometry_updated token=…983 frame=(2489.0, 1235.0, 704.0, 396.0)
  interaction=ID(displayId: 1)/prev=ID(displayId: 2)   ← Vivaldi PiP on MacBook
# floating_geometry_updated token=…1394 frame=(2480.0, 1298.0, 640.0, 360.0)
  interaction=ID(displayId: 1)/prev=ID(displayId: 2)   ← Firefox PiP on MacBook
```

But the entry's bound monitor never follows the drag — it stays the external monitor:

```text
managed_replacement_metadata_changed token=…983 monitor=Optional(ID(displayId: 2))   ← still external
```

On the next workspace transition, `hideWorkspace` parks each PiP offscreen at the
**external** monitor's right edge (`x=1920`), pulling it back off the MacBook:

```text
hideOrigin.resolve reason=workspaceInactive side=right result=(1920,650) frame=(1216,650 704x396)
hidePlan.apply id=983 requestedOrigin=(1920,650)            ← Vivaldi PiP parked at external right edge
…
hideOrigin.resolve reason=workspaceInactive side=right result=(1920,689) frame=(1919,689 640x360)
hidePlan.apply id=1394 requestedOrigin=(1920,689)           ← Firefox PiP parked at external right edge
hidePlan.axFallback id=1394 … failureReason: Optional(verificationMismatch)   ← macOS clamped it back
```

When workspace 2 is active again, the Vivaldi PiP is restored to its **stored external**
frame, not the MacBook frame the user chose:

```text
confirmed id=983 target={{1216.0, 650.0}, {704.0, 396.0}} observed={{1216.0, 650.0}, {704.0, 396.0}}
```

`1216` is inside the external monitor's x-range (0–1920), not the MacBook's. That is
the snap-back. End-of-capture state for the Firefox PiP confirms the same:

```text
WindowToken(pid: 19291, windowId: 1394) workspace=F5625259-… mode=floating phase=hidden
  hidden=workspaceInactive observedFrame={{1919.0, 689.0}, {640.0, 360.0}}
  desiredFloating={{1919.0, 689.0}, {640.0, 360.0}} monitor=ID(displayId: 2)
```

### 4. Floating windows are parked exactly like tiled windows

A non-PiP floating window in the same capture (KeePassXC, `windowId: 53`,
`bundleId=org.keepassxc.keepassxc`) shows the rule applies to *any* tracked floating
window, not just PiP:

```text
WindowToken(pid: 1080, windowId: 53) workspace=F7ACE144-… mode=floating phase=hidden
  hidden=workspaceInactive observedFrame={{1919.0, 264.0}, {800.0, 632.0}}
  desiredFloating={{1919.0, 264.0}, {800.0, 632.0}} rescue=true
```

`phase=hidden`, `hidden=workspaceInactive`, parked at the right edge. There is no
"this is a global/all-Spaces window, leave it alone" branch anywhere on the park path.

---

## Root cause

Two independent omissions combine into #108. Both are visible in the code and
confirmed by the capture.

### (A) `hideWorkspace` parks every tracked entry and never asks whether macOS wants the window globally visible

`hideWorkspace` (`LayoutRefreshController.swift:2273`) only exempts
`nativeFullscreen`; it then calls `hideWindow(... reason: .workspaceInactive ...)`
for every other entry. It does **not** consult:

- `managedReplacementMetadata.transientWindowServerEvidence` (the #98/#104 flag), or
- `SpaceTopology` macOS-Space membership (the primitive that would say "this window
  is on the active macOS Space, macOS is showing it on purpose").

So a PiP that the owning browser keeps on every Space is parked offscreen the moment
its Nehir workspace goes inactive. **This is the "disappears" symptom.**

### (B) The floating frame is anchored to the workspace's monitor, so a cross-monitor drag is reverted

`updateFloatingGeometry` (`WorkspaceManager.swift:2808`) resolves a
`referenceMonitor` from the frame, the workspace monitor, or an approximation, and
`resolvedFloatingFrame` (`WorkspaceManager.swift:2846`) rebuilds the frame on that
reference monitor. A floating window's `workspaceId` is fixed at admission and is not
re-anchored when the window is dragged onto another monitor, so the refresh after a
workspace transition restores the window to its **stored** frame on its **original**
monitor — overriding the drag. **This is the "snaps back" symptom.**

### Why the #98/#104 fix made this more visible, not less

Before #98/#104, a PiP from a non-enumerated browser could be **tiled** (per
`discovery/20260617-omniwm-113-above-normal-level-pip-tiling.md`), producing a
different bad symptom (layout churn). The #98/#104 fix correctly moved PiP-class
surfaces to **floating + tracked + not-activated-on-create** — solving the
tiling/dismissal symptoms of #98 and #104. But "floating + tracked" still flows into
(A) and (B). So the fix changed the *failure mode* from "PiP breaks the layout" to
"PiP disappears and snaps back on workspace switch". The Firefox PiP in the capture,
classified `source=builtInRule(transientWindowServerSurface)`, is the qutebrowser-fix
rule producing exactly this outcome.

---

## The missing lever already exists: `SpaceTopology` macOS-Space membership

Nehir can already ask "which macOS Spaces does this window belong to?":

- `SkyLight.spacesForWindow(_:)` (`SkyLight.swift:367`) returns the Space IDs a window
  belongs to. An all-Spaces window (PiP with `.canJoinAllSpaces`) reports every Space;
  a normal window reports exactly one.
- `SpaceTopology.current(monitors:windowIds:)` (`SpaceTopology.swift:51`) builds
  `spaceIdsByWindowId` (`SpaceTopology.swift:70`/`74`), `activeSpaceIdsByDisplayId`,
  and `knownSpaceIds`.
- `isWindowOnKnownInactiveSpace(windowId:)` (`SpaceTopology.swift:34`) is the existing
  helper, but it is the **wrong** predicate for this fix (see Lever 1): because Nehir
  never moves a window onto an inactive macOS Space, it returns `false` for both
  normal and global windows. The needed helper is "window appears on all known Spaces"
  (a count comparison over `spaceIdsByWindowId` / `knownSpaceIds`), which does not
  exist yet.

Today this is used in exactly one place: the full-rescan "don't delete as missing"
loop (`LayoutRefreshController.swift:1466`-`1481`, the `spaceTopology.exempt` branch).
It is **not** wired into `hideWorkspace` or the floating-restore path. That is the gap.

`displaySpacesMode` is resolved on two paths (`SkyLight.swift:319`): a **primary**
`SLSGetSpaceManagementMode` check (`SkyLight.swift:325`, non-zero ⇒ `.enabled`, works
on **any** monitor count) and a **fallback** `displaySpacesModeFromManagedDisplaySpaces`
(`SkyLight.swift:329`/`:383`, whose `guard monitors.count > 1` at `:387` returns
`.unavailable` only when the primary symbol is missing/renamed). A separate
single-display capture (MacBook, notch, `ID(displayId: 1)` only) confirms the primary
path is taken there too: `displaySpacesMode=enabled`, `SpaceTopology mode=enabled
activeSpaces=1 knownSpaces=1 windowRecords=7`. So `SpaceTopology` is populated on a
single display on modern macOS; the `>1 monitor` gate is only the degraded fallback.
`SpaceTopology.current` still early-returns empty unless `mode == .enabled`
(`SpaceTopology.swift:53`) and unless spaces are known (`:66`).

---

## Fix directions (no implementation in this pass)

The two symptoms map to two levers; both should reuse the existing `SpaceTopology`
primitive so the decision is "macOS says this window is on the active Space", not a
new PiP-specific heuristic.

### Lever 1 — Don't park a window macOS reports as global (appears on every Space)

The naive reading — "skip parking when `isWindowOnKnownInactiveSpace(windowId:) ==
false`" — is **wrong**, and the single-display capture is what proves it. Nehir's
virtual workspaces do **not** map 1:1 to macOS Spaces: both captures show 7 Nehir
workspaces against `knownSpaces=2` (multi-display) and `knownSpaces=1`
(single-display). Nehir simulates workspaces *within* macOS Spaces by parking windows;
it never moves a window onto an inactive macOS Space. So a normal app window and a
global PiP both report only active macOS Spaces, and `isWindowOnKnownInactiveSpace`
returns `false` for **both** — exempting on that predicate would stop parking every
window (catastrophic regression).

The correct discriminator is **how many known Spaces the window belongs to**. A normal
workspace-bound window appears on exactly one macOS Space (its home display's); an
all-Spaces PiP (`collectionBehavior = .canJoinAllSpaces`) appears on **every** known
Space. So the exemption must key off "window's `spacesForWindow` count ≥ known Spaces
count" (i.e. it is present on all of them), not off `isWindowOnKnownInactiveSpace`.
This needs a small new helper on `SpaceTopology` (e.g. `isWindowOnAllKnownSpaces`);
`spaceIdsByWindowId` (`SpaceTopology.swift:70`/`74`) and `knownSpaceIds` already hold
the raw data.

- Pro: uses existing `spacesForWindow` data; keys off macOS's own "this window joins
  all Spaces" statement, not a window-class guess; fixes the "disappears" symptom for
  every global/all-Spaces window.
- Con / hard limit: this discriminates **only when `knownSpaceIds.count > 1`**, i.e.
  multi-display "Displays have separate Spaces." On a single display `knownSpaces=1`,
  so a PiP reports `[space1]` and a normal window also reports `[space1]` —
  indistinguishable (see "Unknowns"). It also does not apply when `mode != .enabled`
  (topology empty) or under Spaces-OFF.

### Lever 2 — Don't force-restore a global window to a stale reference monitor

For an entry that Lever 1 leaves visible across a switch, `resolvedFloatingFrame`
(`WorkspaceManager.swift:2846`) must not yank it back to the original monitor. Either
re-anchor the entry's `workspaceId` to the now-active workspace on the monitor the
window is actually on (`updateWorkspace`, `WindowModel.swift` `workspaceId`), or skip
the reference-monitor clamp for windows the SpaceTopology reports as global. This is
the same "re-anchor, don't exempt-and-leave" design the sticky-apps discovery
mandates to avoid tripping the bleed/drift invariants.

### Coherence requirement (must be solved, not hand-waved)

A window left visible while its *original* Nehir workspace is inactive is in exactly
the state that four sibling discoveries treat as a **bug** (a live frame whose
logical workspace is not the active one):

- `noop/20260616-omniwm-235-window-bleed-different-workspace.md`
- `noop/20260616-omniwm-391-steam-tile-and-workspace-leak.md`
- `discovery/20260616-workspace-inactive-stale-live-frame.md`
  (the `workspaceInactiveVisibleDriftLine` detector,
  `LayoutRefreshController.swift:2371`)

So Lever 1/2 must (i) re-anchor the sticky window's `workspaceId` to the active
workspace each switch so it is never logically inactive-while-visible, and (ii)
exclude such entries from `workspaceInactiveVisibleDriftLine`'s accusation set.
(The capture's `-- Workspace-Inactive Visible Drift Scan -- none` line shows the
drift detector did *not* fire here only because the PiP *was* parked — once we stop
parking it, the exclusion becomes mandatory.) This mirrors recommendation #2/#3 of
`discovery/20260617-omniwm-315-sticky-apps-across-workspaces.md` for an explicit
`sticky` effect; #108 is that same capability, but **auto-detected** from macOS Space
membership rather than user-declared.

### Why not "just don't track PiP at all"

Tempting, and apparently what makes OmniWM not exhibit the bug (per the reporter), but
it regresses the deliberate design choices behind #98/#104 and
`discovery/20260617-omniwm-113-above-normal-level-pip-tiling.md`: Nehir tracks
floating-level windows so it can surface them in the workspace bar and keep lifecycle
bookkeeping, and it avoids AX-subrole-only rejection so qutebrowser-style frameless
app windows are not dropped. The right move is to keep tracking but stop fighting
macOS on switch/restore — Levers 1+2 — not to exclude PiP from the model.

---

## What is still unknown

- **Single-display cannot be solved by macOS-Space membership.** A single-display
  capture (MacBook, notch) confirms `displaySpacesMode=enabled` / `SpaceTopology
  mode=enabled` there via the primary `SLSGetSpaceManagementMode` path
  (`SkyLight.swift:325`), so topology *is* populated — but with `knownSpaces=1`.
  Because Nehir runs many virtual workspaces inside that one macOS Space, both a
  global PiP and a normal window report `[space1]`; the Space-count discriminator
  (Lever 1) cannot tell them apart. So on a single display the fix needs a different
  signal — most likely the user-declared `sticky` effect from
  `discovery/20260617-omniwm-315-sticky-apps-across-workspaces.md`, or accepting the
  limitation. The reporter's #108 repro is multi-display (`knownSpaces=2`), so Lever 1
  covers the reported case; single-display PiP-stickiness remains open and is not
  fixed by Space membership alone.
- **Drift detector fires during transitions (confirmed).** The same single-display
  capture shows `workspaceInactiveVisibleDrift trigger=hideWorkspace.skipAlreadyHidden`
  firing for windows whose `hidden=workspaceInactive` bit is set before their live AX
  frame reaches the park origin — e.g. a floating entry with `live=(1767,26
  459x258) expectedPark=(2056,26) dx=288.5`, and a tiled entry `live=(841,0 …)
  expectedPark=(2056,0) dx=1214.5`. This is live proof that the
  `workspaceInactiveVisibleDriftLine` detector (`LayoutRefreshController.swift:2371`)
  treats any hidden-but-on-screen frame as bleed. Lever 1's coherence requirement
  (exclude exempted global windows from the detector, and re-anchor their workspace)
  is therefore mandatory, not theoretical: without it, a PiP left visible across a
  switch would trip the detector every time.
- **Does OmniWM genuinely not track floating-level windows, or does it exempt them
  from parking?** The reporter observes OmniWM does not exhibit the bug. This doc
  treats that as a user-reported data point, not a verified code fact — confirming it
  against OmniWM's source would sharpen the recommendation (exclude vs. exempt).
- **Exact PiP lifecycle during rescan.** The discovery enumerator
  `queryAllVisibleWindows` (`SkyLight.swift:637`) filters with
  `guard hasDocumentTag || (hasFloatingTag && hasModalTag)`, so a floating-only
  PiP (like the Firefox one) is **skipped** during full rescan, while the create-time
  `queryWindowInfo` (`SkyLight.swift:675`) has no such filter. The capture shows the
  PiPs being repeatedly `window_removed`/`window_admitted` and re-decided, which is
  consistent with that asymmetry. Whether this churn independently harms the PiP
  (beyond the park/snap-back) is not settled by this trace and is worth a follow-up.
- **Should the built-in `browserPictureInPicture` title rule still take precedence
  over `transientWindowServerSurface`?** The Firefox PiP was decided
  `transientWindowServerSurface`, not `browserPictureInPicture`, even though its
  title matched. Both yield floating so it does not change #108, but the ordering may
  matter for the title-fetch retry timing the title rule exists for
  (`AXEventHandler` `createdPictureInPictureWindowRetriesWhenTitleIsInitiallyMissing`).

---

## Suggested validation (when implemented against the main source tree)

These are the runtime assertions a fix should satisfy; none can be proven by a unit
test alone (private WindowServer/SkyLight behavior — see
`docs/offscreen-clamp-fix.md`'s "must confirm manually" rule cited by
`discovery/20260621-virtual-display-park-offscreen-windows.md`).

1. **PiP survives a workspace switch in place.** With a browser PiP open on the
   external monitor, switch Nehir workspaces on that monitor. Assert the PiP's live
   AX frame is unchanged (not parked to `x=1920`) and `hidden != workspaceInactive`.
   Inline the `hideOrigin.resolve`/`hidePlan.apply` (absence) and the unchanged frame.
2. **PiP drag to another monitor sticks.** Drag the PiP to the MacBook, then switch
   workspaces on the external monitor. Assert the PiP stays at the MacBook frame
   (e.g. `frame=(…, 12xx, …)` with `interaction=ID(displayId: 1)`) and is not restored
   to its old external frame.
3. **Normal app window is still parked.** Same setup with an ordinary (non-global)
   floating window; after the switch assert it is `hidden=workspaceInactive` and
   parked, proving the exemption is Space-membership-scoped, not blanket.
4. **Drift detector does not accuse the exempted PiP.** With the PiP visibly on-screen
   while its original workspace is inactive, assert
   `workspaceInactiveVisibleDriftLine(…)` returns `nil` for that token.
5. **Re-anchoring keeps the model coherent.** Assert the exempted PiP's `workspaceId`
   tracks the active workspace so it is never in an inactive-while-visible state
   (guard against regressing the bleed family).

---

## Relationship to other discoveries

- **`completed/20260622-nehir-98-104-transient-popup-surfaces.md`** — the qutebrowser
  fix. This doc is its direct follow-up: #98/#104 added `transientWindowServerSurface`
  classification and `shouldActivateFloatingCreate` activation gating but did not gate
  `hideWorkspace` parking or floating-frame restore; #108 is the gap that exposes.
- **`discovery/20260617-omniwm-113-above-normal-level-pip-tiling.md`** — recommended a
  level/floating-tag classifier so PiP is floated app-agnostically (now implemented via
  `transientWindowServerSurface`). Its recommendation #4 ("prefer `.floating` over
  `.unmanaged` so the window remains visible rather than vanishing") did not
  anticipate that floating+tracked still vanishes on workspace switch; #108 shows the
  classification step is necessary but not sufficient.
- **`discovery/20260617-omniwm-315-sticky-apps-across-workspaces.md`** — the sticky/
  pin design. #108 is the same capability auto-detected from macOS Space membership:
  the hide-exemption, active-workspace re-anchoring, and drift-detector exclusion
  steps are identical; #108 just derives "this window is sticky" from
  `spacesForWindow` instead of a user `sticky` flag.
- **`discovery/20260622-rescued-floating-auxiliary-windows-leak-into-workspace-bar.md`**
  — adjacent floating-admission concern (rescued auxiliary surfaces). Same
  `restoreToFloating`/tracked-floating pipeline; orthogonal symptom (bar leak / focus
  churn), not the switch-park/snap-back.
- **`discovery/20260621-virtual-display-park-offscreen-windows.md`** and
  `discovery/20260616-workspace-inactive-stale-live-frame.md` — the positional-park
  and bleed/drift machinery this fix must stay consistent with. Lever 1 must not
  regress the bleed family; the `verificationMismatch` seen on the Firefox PiP's park
  (`hidePlan.axFallback id=1394`) is the same macOS clamp documented there.

---

## Pointer to the original capture (for completeness only)

The reporter's runtime capture is attached to the issue as a GitHub user-attachment.
Everything needed to follow this document is inlined above; the attachment is only
the full raw capture:

https://github.com/user-attachments/files/29216958/runtime-trace-1782150592713-1782150649861.log
