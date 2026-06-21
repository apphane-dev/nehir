# Nehir #66 — Undecorated qutebrowser tracking and focus-border compatibility

Source issue: https://github.com/Guria/nehir/issues/66 (open, no labels).
Reporter symptom, inlined (the issue attaches a screen recording and trace file;
per branch rules neither is referenced here):

> Borders are not rendered for some specific applications, like qutebrowser
> (only problematic app observed so far). The problem disappears when
> qutebrowser's `window.hide_decoration: global: false` (native macOS titlebar
> ON). With `hide_decoration: global: true`, qutebrowser draws an undecorated /
> frameless window and Nehir's borders disappear.

Maintainer (@Guria, issue comment): **Show Borders** is experimental and known
to be quirky; decorated vs undecorated points at an interaction with frameless
windows.

Scope of this doc: characterize the current runtime behavior for undecorated
qutebrowser, identify why both tracking and borders fail, and spell out safe vs
risky fix shapes. File/line refs point at the main Nehir source tree and were
re-verified on 2026-06-21; line numbers may drift.

---

## TL;DR

Runtime confirmation changed the original hypothesis materially and led to a
three-part narrow fix:

- Undecorated qutebrowser's top-level app window is unusual but not elevated:
  WindowServer/CG data showed owner `qutebrowser`, bundle
  `org.qutebrowser.qutebrowser`, activation policy `regular` (`0`), CG layer
  `0`, alpha `1`, and onscreen `true`.
- Accessibility reports that same top-level app window as `role=AXWindow` and
  **`subrole=AXDialog`**. That must not cause broad `AXDialog` relaxation,
  because real sheets/dialogs still need suppression.
- The first blocker was admission: focused admission reached
  `prepareCreateCandidate`, evaluated qutebrowser as `disposition=undecided` /
  `outcome=deferred` because a malformed fullscreen-button AX value poisoned the
  aggregate facts as `attributeFetchFailed`, then rejected the candidate as
  `reason=untracked_decision`. The fix treats that malformed fullscreen-button
  value as a missing fullscreen button when the core facts are otherwise usable,
  so the existing non-standard-subrole heuristic tracks qutebrowser as floating.
- The second blocker was border eligibility: qutebrowser's top-level `AXDialog`
  continued to hit `system_modal_surface`. The fix adds a narrow exemption only
  for `AXWindow` + `AXDialog` + qutebrowser bundle id + top-level WindowServer
  facts (`level=0`, `parentId=0`, with live SkyLight fallback when metadata is
  incomplete/stale). Non-qutebrowser `AXDialog` surfaces remain suppressed.
- The third blocker was border ordering: qutebrowser needed an inside border
  ordered above the app surface, but Nehir's `SkyLightWindowOrder.above` raw
  value was `0`, which is `kCGSOrderOut` (hide). The fix changes `.above` to raw
  value `1` (`kCGSOrderAbove`) and adds a regression for the constants.
- **Do not add a built-in qutebrowser force-tiling rule.** Default tracking as
  floating is the safe compatibility fix; users can still tile qutebrowser via
  manual override or explicit rules.

Verdict: ✅ fixed by a narrow Nehir-side compatibility path plus a corrected
SkyLight ordering constant, without globally relaxing `AXDialog` handling or
adding a built-in qutebrowser tiling rule.

---

## Runtime evidence, inlined

Additional maintainer context from the original OmniWM setup: this exact class of
qutebrowser issue had been worked around with a **user app rule**, not a broad
built-in heuristic change:

```toml
id = "B32D878A-3977-48D1-A163-C0798E16886E"
order = 3

[match]
bundleId = "org.qutebrowser.qutebrowser"
titleSubstring = "qutebrowser"

[effect]
layout = "tile"
minWidth = 500
minHeight = 375
```

That context supports keeping tiling opt-in/user-rule based. It also matches the
similar upstream ecosystem report the maintainer remembered:
`nikitabobko/AeroSpace#166`.

A 2026-06-21 runtime capture and live AX/CG probe showed:

```text
-- Focus Targets --
borderTarget=WindowToken(pid: 96135, windowId: 723) nonManaged=true

-- WorkspaceManager --
windows total=3 tiled=3 floating=0
focus focused=nil pending=nil
interaction ... nonManaged=true lease=true

-- Visible Unmanaged WindowServer Windows --
windowId=723 pid=96135 owner=qutebrowser
bundleId=org.qutebrowser.qutebrowser
title=settings - qutebrowser
frame={{1032.0, 97.0}, {1008.0, 1232.0}}
activationPolicy=NSApplicationActivationPolicy(rawValue: 0)
axWindowsCount=1 axContainsWindow=true
```

During the focus transition into qutebrowser, Nehir recorded:

```text
activation_source_observed pid=96135 source=workspaceDidActivateApplication
non_managed_fallback_entered pid=96135 source=workspaceDidActivateApplication
```

A direct live probe of the same process/window reported:

```text
CG window:
  kCGWindowNumber: 723
  kCGWindowOwnerPID: 96135
  kCGWindowOwnerName: qutebrowser
  kCGWindowName: settings - qutebrowser
  kCGWindowLayer: 0
  kCGWindowAlpha: 1
  kCGWindowBounds: { X = 1032; Y = 97; Width = 1008; Height = 1232; }
  kCGWindowIsOnscreen: 1

AX window:
  wid=723
  role=AXWindow
  subrole=AXDialog
  title=settings - qutebrowser
  position=(1032.0, 97.0)
  size=(1008.0, 1232.0)
  close button: result=-25212, absent
  fullscreen button: result=-25212, absent
  zoom button: result=-25212, absent
  minimize button: result=-25212, absent
```

So the problem window is a normal onscreen layer-0 app window from WindowServer's
perspective, but an `AXDialog` with no native titlebar controls from AX's
perspective.

---

## Why the border disappears

`FocusBorderController.renderEligibility(for:)` hides before attempting frame
resolution or `BorderManager.updateFocusedWindow`:

```swift
// Sources/Nehir/Core/Border/FocusBorderController.swift:293-295
if isSystemModalSurface(target.axRef) {
    return .hide
}
```

`isSystemModalSurface` treats three AX surfaces as modal/system surfaces:

```swift
// Sources/Nehir/Core/Border/FocusBorderController.swift:319-327
return attributes.role == kAXSheetRole as String
    || attributes.subrole == kAXDialogSubrole as String
    || attributes.subrole == kAXSystemDialogSubrole as String
```

Because undecorated qutebrowser's main window reports `subrole=AXDialog`, Nehir
hides the focused border intentionally. This explains why the symptom follows
`hide_decoration=true`: the frameless Qt/qutebrowser window loses standard
macOS titlebar controls and exposes itself through AX as a dialog-like surface.

This also means the previous “border ordered below a higher-level frameless
window” hypothesis is not the leading explanation for the captured runtime:
qutebrowser's CG layer is `0`, AX/CG frames agree, and the code path hides the
border before ordering is decisive.

---

## Why it is not tracked as a managed/floating window

There are two meanings of “managed” in this codebase:

1. **Tracked by Nehir**: `WindowDecision.trackedMode` maps `.managed` to
   `.tiling` and `.floating` to `.floating`; both are tracked
   (`Sources/Nehir/Core/Rules/WindowRuleEngine.swift:67-75`).
2. **Tiling-managed**: the heuristic disposition `.managed` specifically means
   the window is a tiling candidate.

For the captured qutebrowser facts, the generic heuristic would not make it a
tiling window. It would classify it as floating because it has no native buttons
and a non-standard subrole:

```swift
// Sources/Nehir/Core/Ax/AXWindow.swift:654-679 (abridged)
let hasAnyButton = facts.hasCloseButton
    || facts.hasFullscreenButton
    || facts.hasZoomButton
    || facts.hasMinimizeButton

if !hasAnyButton && facts.subrole != kAXStandardWindowSubrole as String {
    return .floating(reasons: [.noButtonsOnNonStandardSubrole])
}

if let subrole = facts.subrole,
   subrole != (kAXStandardWindowSubrole as String)
{
    return .floating(reasons: [.nonStandardSubrole])
}
```

That floating disposition should still be tracked if the create/admission path
accepts the window. In the runtime, it did not: the final state shows
`floating=0`, qutebrowser under visible unmanaged windows, and
`non_managed_fallback_entered` when qutebrowser was activated.

The relevant admission path is focused-window admission before non-managed
fallback (`Sources/Nehir/Core/Controller/AXEventHandler.swift:2003-2047`). If
`prepareCreateCandidate` returns `nil`, the code schedules retry/reevaluation
and returns false; the caller then enters non-managed fallback and updates the
border target as non-managed. Once non-managed focus is active, the stale
existing-surface guard can suppress later unrequested admission unless the
context came from a real CGS create event or recent managed pid workspace:

```swift
// Sources/Nehir/Core/Controller/AXEventHandler.swift:640-659 (abridged)
guard controller.workspaceManager.isNonManagedFocusActive,
      !hasExplicitWorkspaceAssignment,
      controller.focusBridge.activeManagedRequest?.token != token
else { return false }

return createPlacementContext?.source != "cgs_created"
    && createPlacementContext?.recentPidWorkspaceId == nil
```

The captured end state retained a create placement context for window `723` with
`source=ax_focused_admission_synthesized`, no active focus-request workspace,
and no recent pid workspace. That is consistent with “focused admission saw an
existing surface, did not admit it immediately, then non-managed fallback became
anchored.” It does not yet prove the exact `prepareCreateCandidate` failure
reason; add a trace at each `nil` return / suppression branch before changing
admission policy.

---

## Is fixing this reasonable?

Yes, **if the fix is narrow**. No, if the fix is “all `AXDialog` or no-buttons
windows should tile.”

Reasonable goals:

- Show a focus border around qutebrowser's undecorated main window.
- Preserve/support the already-proven workaround shape: qutebrowser users can
  opt into tiling via an explicit app rule matching
  `bundleId = "org.qutebrowser.qutebrowser"` and `titleSubstring = "qutebrowser"`,
  with `layout = "tile"` and suitable minimum size hints.
- If code needs a built-in exception, make it a narrowly-scoped **border or
  diagnostics compatibility** path for qutebrowser's frameless top-level window,
  not a general layout rule and not a precedent that every app-specific quirk
  becomes force-tiled.

Nehir already has built-in per-app/per-surface policy, but most of it is used to
**exclude overlays or float known special surfaces**, not to admit suspicious
AX dialogs into tiling. Current built-in categories in
`Sources/Nehir/Core/Rules/WindowRuleEngine.swift` and
`Sources/Nehir/Core/Ax/DefaultFloatingApps.swift` are:

- `defaultFloatingApp`: 8 bundle ids, floated by default.
- `browserPictureInPicture`: Firefox and Zen Browser PiP title rules, floated.
- `systemTextInputPanel`: 4 Apple text/input panel bundle ids, unmanaged.
- `cleanShotRecordingOverlay`: CleanShot level-103 recording overlay, floating.
- `ghosttyQuickTerminalOverlay`: Ghostty non-level-0 quick-terminal overlay,
  unmanaged.

So a qutebrowser fix should not be described as “just add another app override”
without qualification. `ghosttyQuickTerminalOverlay` is an exclusion for a known
overlay; qutebrowser would be an inclusion/compatibility exception for a real
main window that AX mislabels as `AXDialog`, which is inherently riskier.

Not reasonable as a default/global change:

- Treat every `AXDialog` as a tileable main window.
- Treat every no-buttons non-standard AX window as tileable.
- Remove dialog/sheet border suppression for all apps.
- Disable the stale non-managed admission guard globally.

---

## Regression risks by fix shape

### High risk: globally tile `AXDialog` / no-buttons windows

Likely regressions:

- Native app dialogs, preference windows, save/open panels, auth prompts, color
  pickers, find panels, transient Qt/Electron dialogs, and palette-like windows
  can become tiled columns.
- Nehir may resize/move surfaces whose semantics are modal or transient,
  breaking app workflows or causing AX frame-write failures.
- Focus activation can pull dialog/helper windows into the active workspace,
  changing workspace selection and stealing focus from the intended managed
  window.
- Floating/utility windows that intentionally lack titlebar buttons become
  indistinguishable from real main windows.

### Medium/high risk: globally allow borders on `AXDialog`

Likely regressions:

- Borders appear around sheets, modal dialogs, alert panels, and system dialogs
  where Nehir currently suppresses them to avoid visual noise/confusion.
- If a dialog is attached to a parent window, the focus border can imply the
  dialog is a normal workspace target even though Nehir should not manage it.

### Medium/high risk: weakening non-managed focused admission globally

Likely regressions:

- Existing onscreen surfaces discovered during app switch / Space changes can be
  admitted into the active workspace without a real create signal.
- Picture-in-picture overlays, helper panels, menu-like windows, and stale app
  surfaces can be pulled into Nehir tracking because they happened to become AX
  focused.
- Workspace placement becomes nondeterministic: admission uses current focus or
  interaction context instead of the window's original creation context.

### Lower risk: narrow compatibility or explicit rule

Safer predicates for qutebrowser/frameless compatibility:

- Prefer the explicit user-rule workaround for layout changes; this was already
  used successfully in the OmniWM era for qutebrowser.
- If a built-in compatibility path is added, scope it to
  `bundleId == org.qutebrowser.qutebrowser` first rather than a generic
  “frameless AXDialog” class, and prefer border/diagnostic compatibility over
  automatic tiling.
- `role == AXWindow`, `subrole == AXDialog`, no native titlebar buttons.
- Activation policy is regular (`0`).
- WindowServer/CG layer is `0`, alpha `1`, onscreen true.
- Parent window id is absent/zero if available.
- Frame is normal-sized and intersects a monitor visible frame.
- Prefer a real CGS create event for automatic admission; for existing windows,
  require explicit user rule or a very narrow bundle compatibility path.

---

## Follow-up focused-admission diagnostic evidence

A later run with focused-admission diagnostics in place captured two focus
attempts into the same qutebrowser window. In both attempts, the trace sequence
was:

```text
activation_source_observed pid=96135 source=workspaceDidActivateApplication
window_decision token=WindowToken(pid: 96135, windowId: 723) context=focused_admission existingMode=nil disposition=undecided source=heuristic outcome=deferred layout=fallbackLayout deferred=attributeFetchFailed bundleId=org.qutebrowser.qutebrowser titleLength=nil axRole=AXWindow axSubrole=AXDialog hasCloseButton=true hasFullscreenButton=false fullscreenButtonEnabled=nil hasZoomButton=true hasMinimizeButton=true appPolicy=NSApplicationActivationPolicy(rawValue: 0) wsLevel=0 wsTags=0x100082001 wsAttributes=0x3 wsParent=0 wsFrame=(1035.0,839.0,1005.0,490.0)
prepare_create_rejected window=723 token=Optional(Nehir.WindowToken(pid: 96135, windowId: 723)) context=focused_admission reason=untracked_decision has_window_info=true window_info_pid=96135 fallback_token=Optional(Nehir.WindowToken(pid: 96135, windowId: 723)) has_fallback_ax_ref=true create_context_source=ax_focused_admission_synthesized
non_managed_fallback_entered pid=96135 source=workspaceDidActivateApplication
```

The visible-unmanaged snapshot for the same window was:

```text
windowId=723 pid=96135 owner=qutebrowser bundleId=org.qutebrowser.qutebrowser title=DuckDuckGo Private Search Engine - qutebrowser frame={{1035.0, 839.0}, {1005.0, 490.0}} activationPolicy=NSApplicationActivationPolicy(rawValue: 0) axWindowsCount=1 axContainsWindow=true
```

The synthesized focused-admission placement context remained attached to the
window:

```text
window=723 native_monitor=nil active_focus_request_workspace=nil active_focus_request_monitor=nil focused_workspace=B0C1D521-6D47-4FB9-8FF8-73A456CA9533 focused_monitor=display 1 interaction_monitor=display 1 source=ax_focused_admission_synthesized focused_workspace_source=confirmed_focus recent_pid_workspace=nil
```

This narrows the tracking failure:

- The immediate blocker is **not**
  `shouldSuppressUnrequestedAdmissionDuringNonManagedFocus`; no
  `unrequested_admission_nonmanaged_focus_decision` event was emitted for
  qutebrowser because `prepareCreateCandidate` never produced a candidate.
- The blocker is `AXWindowService.heuristicDisposition` returning `.undecided`
  when `AXWindowFacts.attributeFetchSucceeded == false`
  (`Sources/Nehir/Core/Ax/AXWindow.swift:647-651` at the time of discovery).
- The facts are partially usable despite the failed aggregate flag: role,
  subrole, close/zoom/minimize button presence, app activation policy, and
  WindowServer metadata were all present. The fullscreen button was absent or
  malformed (`hasFullscreenButton=false`, `fullscreenButtonEnabled=nil`).
- This differs from the earlier direct AX probe, which saw all four native
  button attributes absent. The discrepancy may come from direct single-attribute
  probes versus `AXUIElementCopyMultipleAttributeValues`, or from qutebrowser's
  surface state changing. The next diagnostic must record per-attribute result
  codes/types from the multi-attribute fetch instead of only the aggregate
  `attributeFetchSucceeded` boolean.

## Proposed implementation direction

### 1. Add diagnostics before policy changes

Current diagnostics already identify the focused-admission rejection branch and
high-level facts:

- `prepareCreateCandidate` nil reason: owned window, missing token, existing
  entry, failed AX ref, decision untracked/undecided, etc.
- decision facts for focused admission: bundle id, role/subrole, button facts,
  activation policy, WindowServer level, attributes/tags, parent id, frame.
- whether `shouldSuppressUnrequestedAdmissionDuringNonManagedFocus` suppresses a
  prepared candidate and why.

The remaining diagnostic gap is more granular: record why
`AXWindowFacts.attributeFetchSucceeded` is false by capturing per-attribute
`AXUIElementCopyMultipleAttributeValues` values/results and fullscreen-button
`AXEnabled` fetch result/type. This should show whether qutebrowser is deferred
because the fullscreen button attribute is an AX error, `NSNull`, wrong CF type,
or because another required attribute failed.

Implementation status on 2026-06-21: the diagnostics branch adds an
`axAttributeDiagnostics=...` field to `window_decision` trace output. It reports
`multipleResult`, returned value count, per-attribute value classes for
`role/subrole/title/buttons`, `fullscreenEnabledResult` when queried, and a
`fetchFailure` label such as `invalid_fullscreen_button_type`.

A follow-up runtime capture with those diagnostics closed the gap. The same
qutebrowser window produced:

```text
window_decision token=WindowToken(pid: 96135, windowId: 723) context=focused_admission existingMode=nil disposition=undecided source=heuristic outcome=deferred layout=fallbackLayout deferred=attributeFetchFailed bundleId=org.qutebrowser.qutebrowser titleLength=nil axRole=AXWindow axSubrole=AXDialog hasCloseButton=true hasFullscreenButton=false fullscreenButtonEnabled=nil hasZoomButton=true hasMinimizeButton=true appPolicy=NSApplicationActivationPolicy(rawValue: 0) axAttributeDiagnostics=multipleResult=0,valueCount=6,role=string(len:8),subrole=string(len:8),closeButton=type:__NSCFType,fullscreenButton=type:__NSCFType,zoomButton=type:__NSCFType,minimizeButton=type:__NSCFType,fetchFailure=invalid_fullscreen_button_type wsLevel=0 wsTags=0x100082001 wsAttributes=0x3 wsParent=0 wsFrame=(1035.0,839.0,1005.0,490.0)
prepare_create_rejected window=723 token=Optional(Nehir.WindowToken(pid: 96135, windowId: 723)) context=focused_admission reason=untracked_decision has_window_info=true window_info_pid=96135 fallback_token=Optional(Nehir.WindowToken(pid: 96135, windowId: 723)) has_fallback_ax_ref=true create_context_source=ax_focused_admission_synthesized
non_managed_fallback_entered pid=96135 source=workspaceDidActivateApplication
```

Interpretation:

- `AXUIElementCopyMultipleAttributeValues` succeeded (`multipleResult=0`) and
  returned all six requested values (`valueCount=6`).
- Role and subrole were usable strings: `AXWindow` / `AXDialog`.
- The fullscreen button slot returned a non-AX `__NSCFType`, so
  `collectWindowFacts` labeled the whole facts object as failed via
  `fetchFailure=invalid_fullscreen_button_type`.
- Because `attributeFetchSucceeded=false`, `heuristicDisposition` returned
  `.undecided` before it could reach the existing non-standard-subrole floating
  branch. That is why focused admission rejected the window as
  `reason=untracked_decision`.

Recommended tracking fix:

- Treat an invalid/malformed fullscreen-button value as **missing fullscreen
  button**, not as a fatal aggregate AX facts failure, when the core window facts
  are otherwise available.
- Do not change `AXDialog` tiling policy. With the existing heuristic, once the
  malformed fullscreen button no longer forces `.undecided`, qutebrowser's
  `AXDialog` subrole should classify as tracked `.floating`, not tiled.
- Keep explicit user rules as the path for qutebrowser tiling.

Implementation status on 2026-06-21: the source branch treats a non-AX value in
the fullscreen-button slot as an absent fullscreen button and keeps the rest of
the facts usable. The diagnostic label changes to
`invalid_fullscreen_button_type_treated_as_missing`. Runtime confirmation showed
this lets the existing non-standard-subrole heuristic classify qutebrowser as
tracked floating; manual override can then tile it when desired.

### 2. Border-only compatibility fix

Do not remove `AXDialog` suppression globally. Instead, add a predicate that can
recognize qutebrowser's top-level regular app window misreported as `AXDialog`,
or make the behavior opt-in through an explicit compatibility/user rule. For
that predicate only, allow `renderEligibility` to continue to `.update`.

This is the only app-specific built-in exception that currently looks worth
considering, and it should be framed like the existing overlay rules: a targeted
compatibility shim for a known misreported surface. It should not force tiling.
It should also be tested alongside `ghosttyQuickTerminalOverlay` so Ghostty
quick terminal remains `unmanaged` and outside the niri layout.

Implementation status on 2026-06-21: after runtime confirmation that the
tracking fix works but borders remain hidden, the source branch adds a narrow
border compatibility path for tracked qutebrowser windows with `role=AXWindow`,
`subrole=AXDialog`, `bundleId=org.qutebrowser.qutebrowser`, WindowServer level
`0`, and parent id `0`. A subsequent trace showed `border_reapplied` was emitted
for qutebrowser but the border still was not visible, which means eligibility was
no longer the blocker. Ordering the normal outside border above the qutebrowser
surface still was not enough, likely because the outside ring can be offscreen or
covered by neighboring windows when qutebrowser is full-height or tiled at a
screen edge. The compatibility path now draws this qutebrowser border as an
**inside overlay** and orders it above the qutebrowser surface only. General
`AXDialog` and system dialog suppression remains unchanged, and regression
coverage verifies a non-qutebrowser `AXDialog` still does not apply a border.

Temporary border-surface diagnostics compared Nehir's border window against a
working JankyBorders border. That comparison showed the immediate blocker was not
WindowServer z-ordering: when qutebrowser was the `borderTarget`
(`WindowToken(pid: 96135, windowId: 723)`) and `visualFocusTarget`, Nehir's
border surface was explicitly hidden: `visible=false`, `targetWid=nil`,
`lastAppliedWindowId=nil`, `lastAppliedFrame=nil`, with CG reporting
`onscreen=nil` for Nehir window `1291`. In the same state, JankyBorders owned
four visible `borders` windows at `layer=0`, `alpha=1.0`, `onscreen=true`,
including a qutebrowser-aligned bounds rectangle `(510.0,56.0,1036.0,1287.0)`.
Nehir's hidden border surface still had a higher `level=3`/`layer=3`.

Follow-up diagnostics identified the render reason as `system_modal_surface`
while qutebrowser was the `visualFocusTarget` and `borderTarget`. That means the
qutebrowser top-level `AXDialog` exemption did not match during render, so the
generic modal-surface suppression hid the border. The source fix keeps
suppression narrow by requiring `AXWindow` + `AXDialog` + qutebrowser bundle id +
top-level WindowServer facts, but now falls back to a live SkyLight lookup for
`level=0` and `parentId=0` when the metadata snapshot is incomplete or stale.

A subsequent trace showed that this modal-suppression fix worked: qutebrowser
updated with `lastAppliedWindowId=723`, `lastAppliedOrder=above`,
`lastAppliedPlacement=inside`, and `didUpdate=true`. However, WindowServer still
reported Nehir's border as not onscreen (`attributes=0x0`, CG `onscreen=nil`).
The remaining cause was the SkyLight ordering constant: Nehir used `0` for
`.above`, but CGS ordering mode `0` is `kCGSOrderOut` (hide), while
`kCGSOrderAbove` is `1`. The source branch now corrects `.above` to raw value
`1` and adds a regression asserting the ordering constants.

### 3. Tracking/tiling fix as a separate product decision

- For default behavior, admitting undecorated qutebrowser as **tracked floating**
  is safer than tiling it, but even that should wait for the diagnostics above.
- If users want tiling, prefer the explicit user rule / manual override already
  proven in OmniWM for `org.qutebrowser.qutebrowser` + title substring
  `qutebrowser`, with min-size hints (`500x375` in the known rule).
- Do **not** add a built-in qutebrowser force-tiling rule as the first fix. If a
  built-in qutebrowser rule is ever added, it should be opt-in or narrowly
  scoped and tested against qutebrowser dialogs/settings/download prompts so it
  does not tile real transient surfaces.

---

## Regression coverage

- Border eligibility: a qutebrowser top-level `AXWindow`/`AXDialog` with regular
  WindowServer facts can render a focused border.
- Border suppression: a non-qutebrowser `AXDialog` still suppresses the focused
  border.
- Border mechanics: changing order reorders without redraw, changing placement
  redraws the same target frame, and `SkyLightWindowOrder.above.rawValue == 1` /
  `.below.rawValue == -1`.
- AX facts/admission: malformed fullscreen-button values are treated as missing
  fullscreen buttons when the rest of the window facts are valid.

---

## Related prior discovery

- `discovery/20260617-omniwm-150-screenshot-bordered-window-blank.md` — border
  is its own transparent SkyLight window; about screenshot capture, not this
  AXDialog suppression.
- `noop/20260617-omniwm-223-floating-border-tracking.md` — floating tracked
  windows do get borders; useful to separate “tracked floating” from the current
  visible-unmanaged state.
- `noop/20260617-omniwm-362-border-corner-radius.md` — corner radius is already
  resolved per-window; not the leading cause here.
