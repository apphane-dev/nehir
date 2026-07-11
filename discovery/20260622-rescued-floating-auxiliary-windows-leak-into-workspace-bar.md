# Tiny transient auxiliary surfaces get "rescued" to floating and leak into the workspace bar — Discovery

Groom 2026-07-07: resolved — app-managed transient/parented floating surfaces are now hidden from the workspace bar (`54d5dd7e`, "Hide app-managed transient and parented floating surfaces from the workspace bar", via the `layoutReason == .standard` bar filter); see also `completed/20260624-user-addressable-floating-surfaces.md`. (Left in `discovery/` — referenced by sibling completed docs.)

Discovery (2026-06-22). When an app (here: Helium, `net.imput.helium`, pid `57195`)
creates small auxiliary surfaces — a transient 43 px-tall status strip at the
top edge, or a small 220×275 PiP/panel — Nehir **admits them as managed floating
windows** (with `rescue=true` / `restoreToFloating=true`) and **shows them as
floating window icons in the workspace bar.** The reporter sees "1 or 2 floating
windows for Helium" on a workspace whose bar should show a single tiled Helium
window, and cannot tell what they are because the surfaces are effectively
invisible on screen (one is 38×43 at the top edge; the other is a transient
PiP-shaped panel).

The "1 or 2" count is **not** random — it tracks the lifecycle of a specific
transient surface that Helium creates, resizes, and destroys every few seconds.
A 14.55 s capture shows the workspace's floating count go from **2 → 1** as that
surface is created, churned, and removed mid-capture.

This is **independent of the gesture-path workspace-bar freeze** documented in
[`20260622-workspace-bar-freezes-on-gesture-with-non-managed-focus.md`](20260622-workspace-bar-freezes-on-gesture-with-non-managed-focus.md):
that bug is about *when* the bar re-projects (a missing refresh signal); this
one is about *what* the bar shows (an over-permissive admission + filter). They
share only the visible surface (the workspace bar). It is, however, **adjacent
to** [`20260616-omniwm-323-floating-panel-bar-filter.md`](20260616-omniwm-323-floating-panel-bar-filter.md),
which already flagged that `barVisibleFloatingEntries` is too permissive — but
this case is *stricter* than BarutSRB/OmniWM#323's proposed filter would catch (see "Why BarutSRB/OmniWM#323's
fix does not cover this").

All code citations were verified against the main Nehir source tree at
`aff8a9a2` on 2026-06-22 (`git log -1 --format='%h %s'` → `aff8a9a2 Keep
transient popup surfaces out of managed activation`). Line numbers will drift.

---

## TL;DR

- **Symptom.** Workspace bar for a workspace shows spurious floating-window icons
  for an app that the user sees as a single tiled window. The count fluctuates
  between 1 and 2.
- **What they are.** Two Helium auxiliary surfaces admitted as managed floating:
  - `windowId 6218` — a 220×275 panel at `(1435, 977)` (bottom-right),
    `rescue=true`, persists through the whole capture.
  - `windowId 6248` — a 321×43 → 38×43 strip at `(526, 2)` (top edge, in the
    menu-bar zone), `rescue=true`, created at `15:09:52` and destroyed at
    `15:09:56` (~4 s lifespan).
- **Why the count varies.** `6248` is a transient surface Helium creates, resizes,
  and destroys repeatedly; while it exists, the bar shows 2 floating icons, when
  it is gone the bar shows 1. The capture literally captures the transition:
  `floating=2` at start → `floating=1` at end.
- **Root cause.** (1) A window classified `mode=floating` by the rule heuristic
  is admitted as managed with no minimum-size or transience gate; `addWindow`
  + `updateFloatingGeometry` stamp it `restoreToFloating=true` →
  `rescueEligible=true`. (2) `barVisibleFloatingEntries` filters only
  scratchpads, so the rescued floating surface reaches the bar.
- **Side effect.** The same misclassification generates dead focus churn — the
  capture shows repeated `managed_focus_requested` for `6218`/`6248` that never
  reach `managed_focus_confirmed` (they stay `pending`, then get cancelled /
  superseded).
- **Not fixed by OmniWM PR BarutSRB/OmniWM#323's proposed `layoutReason == .standard` filter.**
  Both surfaces carry `layout=standard`; BarutSRB/OmniWM#323's filter would still admit them.
  This needs a size/transience/rescue-eligibility gate, not a layout-reason gate.

---

## Topology / initial state

Single display (`ID(displayId: 1)`, notch, frame `(0.0, 0.0, 2056.0, 1329.0)`,
visible frame `(0.0, 0.0, 2056.0, 1290.0)`). `displaySpacesMode=enabled`,
`focusFollowsMouse=false`. Workspace bar enabled.

Visible workspace `B8C55829-F478-4242-8778-8716066A23EE`. Managed focus is on
the **tiled** Helium main window `WindowToken(pid: 57195, windowId: 537)` —
`observedManagedFocus=WindowToken(pid: 57195, windowId: 537)`, `nonManaged=false`.

App: Helium (`net.imput.helium`, pid `57195`). The user perceives Helium as one
tiled window on this workspace.

---

## What the evidence proves

### 1. Two floating Helium windows are admitted on the workspace

From the `-- Managed Windows --` snapshot at capture start (after
`windows total=11 tiled=9 floating=2 hidden=8`):

```text
WindowToken(pid: 57195, windowId: 537)  workspace=B8C55829-…
  mode=tiling phase=tiled hidden=nil layout=standard
  liveAXFrame={{16.0, 0.0}, {1008.0, 1282.0}}      ← the real, tiled Helium window
  bundleId=net.imput.helium

WindowToken(pid: 57195, windowId: 6218) workspace=B8C55829-…
  mode=floating phase=floating hidden=nil layout=standard
  observedFrame={{1435.0, 977.0}, {220.0, 275.0}} ← small bottom-right panel
  desiredFloating={{1435.0, 977.0}, {220.0, 275.0}}
  bundleId=net.imput.helium

WindowToken(pid: 57195, windowId: 6248) workspace=B8C55829-…
  mode=floating phase=floating hidden=nil layout=standard
  observedFrame={{18.0, 2.0}, {38.0, 43.0}}       ← tiny top-edge strip
  desiredFloating={{18.0, 2.0}, {38.0, 43.0}}
  bundleId=net.imput.helium
```

Both floating entries carry `layout=standard` (not `nativeFullscreen` or any
other special layout reason) — this matters for the BarutSRB/OmniWM#323 analysis below.

The reconcile snapshot records both as `rescue=true`:

```text
WindowToken(pid: 57195, windowId: 6218) mode=floating …
  floatingFrame={{1435.0, 977.0}, {220.0, 275.0}}, rescue=true
WindowToken(pid: 57195, windowId: 6248) mode=floating …
  floatingFrame={{18.0, 2.0}, {38.0, 43.0}}, rescue=true
```

### 2. The "1 or 2" count tracks the transient surface's lifecycle

The capture's start and end `-- WorkspaceManager --` summaries differ:

```text
start (15:09:49): windows total=11 tiled=9 floating=2 hidden=8
end   (15:10:03): windows total=10 tiled=9 floating=1 hidden=7
```

The `## Tracing logs` section shows exactly which window comes and goes —
`6248`, the tiny top-edge strip:

```text
#3  15:09:52  event=floating_geometry_updated token=…6248 frame=(526.0, 2.0, 321.0, 43.0) restore=true … rescue=true
#5  15:09:53  event=floating_geometry_updated token=…6248 frame=(526.0, 2.0, 38.0, 43.0) restore=true … rescue=true   ← shrank to 38 px wide
#4/#6/#8      event=managed_focus_requested token=…6248 (×3)   pending=…6248, never confirmed
#9  15:09:56  event=managed_focus_cancelled token=…6248
#10 15:09:56  event=window_removed token=…6248 plan=phase=destroyed
```

So `6248` exists for ~4 seconds (15:09:52 → 15:09:56), during which the bar
shows 2 floating Helium icons; after it is destroyed the bar shows 1 (the
persistent `6218` panel). When Helium re-creates this surface (as it evidently
does periodically), the count ticks back to 2. That is the "sometimes 1 or 2"
the reporter sees.

### 3. Why the user can't see them

- `6248`: 38×43 points is below any plausible document/window size, and its
  origin `(526, 2)` puts it flush against the top of the display (y=2), in the
  menu-bar zone — on screen it reads as a couple of pixels of chrome, if
  anything.
- `6218`: 220×275 at `(1435, 977)` — bottom-right; likely a PiP / mini-player /
  popover that Helium shows transiently. The user perceives it (if at all) as an
  app UI element, not "a window."

Neither is something the user would think of as "a window I opened," which is
why the bar icons are mysterious.

### 4. The bar filter admits them

The workspace bar consumes `barVisibleEntries`, which appends
`barVisibleFloatingEntries` when `showFloatingWindows` is on:

```swift
// Sources/Nehir/Core/Workspace/WorkspaceManager.swift:2582-2591
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
```

```swift
// Sources/Nehir/Core/Workspace/WorkspaceManager.swift:2608-2612
private func barVisibleFloatingEntries(in workspace: WorkspaceDescriptor.ID) -> [WindowModel.Entry] {
    floatingEntries(in: workspace).filter {
        !isScratchpadToken($0.token) && hiddenState(for: $0.token)?.isScratchpad != true
    }
}
```

The only exclusions are scratchpad tokens. There is **no** minimum-size gate,
**no** transience/stability gate, and **no** `rescueEligible`/`restoreToFloating`
gate. So `6218` and `6248` both pass the filter and reach `WorkspaceBarDataSource`
(`Sources/Nehir/UI/WorkspaceBar/WorkspaceBarDataSource.swift:77`, which calls
`barVisibleEntries`), which renders them as floating window icons.

---

## Root cause surface

### How a floating window is admitted with `rescue=true`

`trackPreparedCreate` admits a prepared create candidate with whatever mode the
rule engine decided:

```swift
// Sources/Nehir/Core/Controller/AXEventHandler.swift:1156-1164
let trackedToken = controller.workspaceManager.addWindow(
    candidate.axRef,
    pid: candidate.token.pid,
    windowId: candidate.token.windowId,
    to: candidate.workspaceId,
    mode: candidate.mode,                       // ← .floating comes from rule heuristic
    ruleEffects: candidate.ruleEffects,
    managedReplacementMetadata: candidate.replacementMetadata
)
```

`candidate.mode = .floating` originates in the rule engine's heuristic
disposition — a non-`AXStandardWindow` subrole classifies as floating:

```swift
// Sources/Nehir/Core/Ax/AXWindow.swift:667-674
if let subrole = facts.subrole,
   subrole != (kAXStandardWindowSubrole as String)
{
    return AXWindowHeuristicDisposition(
        disposition: .floating,
        reasons: [.nonStandardSubrole]
    )
}
```

Once the entry exists as floating, `updateFloatingGeometry` is called (e.g. at
`AXEventHandler.swift:1200`) and stamps `restoreToFloating = true` by default:

```swift
// Sources/Nehir/Core/Workspace/WorkspaceManager.swift:2808-2814
func updateFloatingGeometry(
    frame: CGRect,
    for token: WindowToken,
    referenceMonitor: Monitor? = nil,
    restoreToFloating: Bool = true               // ← default-rescued
) {
    guard let entry = entry(for: token) else { return }
    …
```

That writes a floating state whose `restoreToFloating` is then propagated as
`rescueEligible` through the reconcile reducer:

```swift
// Sources/Nehir/Core/Reconcile/StateReducer.swift:93-112
case let .floatingGeometryUpdated(_, workspaceId, referenceMonitorId, frame, restoreToFloating, _):
    plan.lifecyclePhase = .floating
    …
    var desiredState = baseDesiredState(… mode: .floating)
    desiredState.floatingFrame = frame
    desiredState.rescueEligible = restoreToFloating
    plan.desiredState = desiredState
```

So the chain is: **non-standard subrole → heuristic `.floating` → admitted as
floating → `updateFloatingGeometry` → `restoreToFloating=true` →
`rescueEligible=true`** — with no step asking "is this a real, user-visible
window?" There is no minimum frame size, no minimum lifespan, and no
"was this user-initiated vs app-emitted" check anywhere on the path.

### What "rescue" was meant for, and why it over-fires

`restoreToFloating` / `rescueEligible` exists to **re-float** a window that was
floating before it got temporarily tiled or hidden (so a user's deliberate
floating window survives a workspace transition or a relayout). Defaulting it to
`true` for *every* geometry update on an already-floating entry means
app-emitted auxiliary surfaces inherit the "this is a deliberate floating window
the user wants kept" marker without any user intent ever being established.

---

## Why OmniWM PR BarutSRB/OmniWM#323's proposed fix does not cover this

`discovery/20260616-omniwm-323-floating-panel-bar-filter.md` already identified
that `barVisibleFloatingEntries` is too permissive and recommended adding a
`layoutReason(for: token) == .standard` filter (matching upstream PR BarutSRB/OmniWM#323). That
fix targets floating entries with **non-standard layout reasons**
(`nativeFullscreen`, etc.).

This case is stricter: both `6218` and `6248` carry `layout=standard`. They are
genuinely standard-layout floating windows — they just happen to be tiny and/or
transient. BarutSRB/OmniWM#323's `layoutReason == .standard` filter would **still admit them**.
So this bug needs a different gate (size / transience / rescue-origin), not the
layout-reason gate BarutSRB/OmniWM#323 proposes. The two discoveries are complementary, not
overlapping.

---

## Side effect: focus churn from the same misclassification

The capture shows the same two surfaces generating dead focus traffic —
`managed_focus_requested` for `6218`/`6248` that never confirms (each stays
`pending`, then is cancelled or superseded):

```text
#2  15:09:52  managed_focus_requested token=…6218 pending=…6218
#4  15:09:53  managed_focus_requested token=…6248 pending=…6248
#6  15:09:54  managed_focus_requested token=…6248 pending=…6248
#7  15:09:55  managed_focus_requested token=…6218 pending=…6218
#8  15:09:56  managed_focus_requested token=…6248 pending=…6248
#9  15:09:56  managed_focus_cancelled     token=…6248
…
#25–30        managed_focus_requested token=…6218 (×~5, via a native_app_switch lease) — never confirmed
```

None of these reach `managed_focus_confirmed`; confirmed focus stays on the
tiled `537` (or, later, VSCode `4635`). This is the same root misclassification
(too-eager floating admission) spilling into the focus layer. Mild in this
capture (no visible focus glitch), but it is wasted work and a latent source of
focus surprises if one of these ever did confirm.

---

## Fix directions (no implementation in this pass)

Three independent levers; they can be combined. All preserve BarutSRB/OmniWM#323's separate
layout-reason filter as an additional guard.

### Option A — Minimum-size gate at bar projection (cheapest, most targeted)

In `barVisibleFloatingEntries`, drop floating entries whose frame is below a
plausible window size (e.g. width or height under ~80–100 pt):

```swift
private func barVisibleFloatingEntries(in workspace: WorkspaceDescriptor.ID) -> [WindowModel.Entry] {
    floatingEntries(in: workspace).filter { entry in
        guard !isScratchpadToken(entry.token),
              hiddenState(for: entry.token)?.isScratchpad != true
        else { return false }
        let f = resolvedFloatingFrame(for: entry.token) ?? entry.observedState.frame ?? .zero
        return f.width >= minimumBarFloatingSize && f.height >= minimumBarFloatingSize
    }
}
```

- Pro: fixes the visible symptom (`6248` at 38×43, `6218` at 220×275 is the
  borderline case to decide on); no admission/layout change; low risk.
- Con: doesn't stop the surface from being *admitted* (so it still churns focus
  and still occupies a managed slot); size threshold is a heuristic and needs a
  chosen constant. `6218` (220×275) is large enough that it may be a legitimate
  PiP the user *does* want shown — confirm the intended semantics before
  hiding it.

### Option B — Transience / stability gate at admission

Refuse to admit (or defer admission of) a floating surface until it has survived
some short stability window (e.g. ≥N frames or ≥T ms unchanged and on screen),
so a 4-second create→resize→destroy strip like `6248` never becomes a managed
window at all.

- Pro: fixes both the bar leak *and* the focus churn at the source; aligns with
  how tooltips/popovers are already suppressed via
  `transientWindowServerEvidence` (`AXEventHandler.swift:1248-1251`).
- Con: larger change; needs a deferred-admission queue and careful handling of
  legit fast-opening floating windows (PiP, dialogs). Risks delaying real
  windows if the threshold is wrong.

### Option C — Don't default `restoreToFloating` to `true`; gate rescue on user intent

In `updateFloatingGeometry`, stop defaulting `restoreToFloating: Bool = true`.
Only mark a floating entry rescue-eligible when there is evidence the user
deliberately floated it (manual float command, persisted restore catalog entry,
or survival past a stability threshold). Then have the bar filter hide
non-rescue-eligible floating entries.

- Pro: semantically cleanest — "rescue" returns to meaning "user wanted this
  floating." Fixes the whole family (bar + focus + restore) consistently.
- Con: largest scope; touches the admission/restore contract; needs an audit of
  every `updateFloatingGeometry` call site (`AXEventHandler.swift:928`, `:1200`)
  and the persisted-restore hydration path (`WorkspaceManager.swift:828-833`)
  to pass an explicit intent rather than relying on the default.

### Recommendation

If the goal is just "make the mystery icons go away," Option A is the smallest,
safest change — pick a minimum size and filter at projection. If the focus churn
matters too (it's latent), Option B is the right structural fix. Option C is the
proper long-term cleanup of the `restoreToFloating` semantics but is the biggest
change. A pragmatic sequencing: A now (visible symptom), B as the follow-up
(source of truth), C as part of a broader rescue/restore audit.

---

## What is still unknown

- **Is `6218` (220×275) a surface the user wants in the bar?** It could be a
  deliberate PiP/mini-player. Before hiding by size, confirm whether Helium's
  PiP should appear as a floating icon. A follow-up trace with the user
  intentionally toggling Helium's PiP would separate "wanted PiP" from
  "unwanted auxiliary surface."
- **What is `6248` (38×43, top edge)?** Almost certainly an app chrome element
  (status strip / tray / popover anchor), but its exact AX role/subrole was not
  captured in this trace's snapshot. A trace that includes the create event's
  `ManagedReplacementMetadata` (role, subrole, parentId) for `6248` would let
  the classifier target it precisely (e.g. by subrole or by `parentId != 0`)
  rather than by size alone.
- **Does the same happen with other apps?** The mechanism is app-independent
  (any app emitting a small non-standard-subrole surface will hit it). A survey
  trace across PiP-capable apps (Safari, QuickTime, Telegram media popouts)
  would show how broad the leak is and help size the minimum-size threshold.

---

## Relationship to other discoveries

- **Not** the gesture bar-freeze
  ([`20260622-workspace-bar-freezes-on-gesture-with-non-managed-focus.md`](20260622-workspace-bar-freezes-on-gesture-with-non-managed-focus.md)).
  That is a refresh-signal bug (bar fails to re-project); this is a
  classification/filter bug (bar shows the wrong things). The freeze's
  reproduction capture had `windows total=9 tiled=9 floating=0` — zero floating
  windows — proving the two are independent.
- **Adjacent to, but stricter than**
  [`20260616-omniwm-323-floating-panel-bar-filter.md`](20260616-omniwm-323-floating-panel-bar-filter.md).
  BarutSRB/OmniWM#323's proposed `layoutReason == .standard` filter targets non-standard-layout
  floating entries; these surfaces are `layout=standard`, so BarutSRB/OmniWM#323 alone does not
  fix them. The two filters are complementary: BarutSRB/OmniWM#323's layout-reason gate + this
  doc's size/transience gate together cover the full space of spurious floating
  icons.
