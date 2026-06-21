# Nehir #66 — Undecorated qutebrowser is treated as non-managed and border-hidden

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

Runtime confirmation changes the original hypothesis materially:

- Undecorated qutebrowser is **not currently tracked** by Nehir. The runtime
  state shows only three tracked tiled windows and `floating=0`; qutebrowser is
  listed under **Visible Unmanaged WindowServer Windows**.
- The focused qutebrowser window is still detected as a keyboard-focus target,
  but as **non-managed**: `borderTarget=WindowToken(pid: 96135, windowId: 723)`
  and `nonManaged=true`.
- The qutebrowser main window is unusual but not elevated: WindowServer/CG data
  shows `windowId=723`, `pid=96135`, owner `qutebrowser`, bundle
  `org.qutebrowser.qutebrowser`, title `settings - qutebrowser`, frame
  `{{1032.0, 97.0}, {1008.0, 1232.0}}`, activation policy `regular` (`0`),
  CG layer `0`, alpha `1`, onscreen `true`.
- Accessibility reports the same window as `role=AXWindow`,
  **`subrole=AXDialog`**, with no close/fullscreen/zoom/minimize button
  attributes (`AXUIElementCopyAttributeValue` returned `-25212` for each), and
  AX position/size `(1032.0, 97.0)` / `(1008.0, 1232.0)`.
- The border is not merely behind the qutebrowser window. Nehir explicitly hides
  borders for any target whose AX subrole is `AXDialog` via
  `FocusBorderController.renderEligibility` → `isSystemModalSurface`
  (`Sources/Nehir/Core/Border/FocusBorderController.swift:293-327`). Since
  qutebrowser's undecorated *main* window reports `AXDialog`, this suppression
  hides the border before frame/order rendering matters.
- The management side is separate: Nehir's heuristic would classify a no-buttons
  non-standard AX window as `.floating`, and `.floating` is a tracked mode
  (`Sources/Nehir/Core/Ax/AXWindow.swift:654-679`,
  `Sources/Nehir/Core/Rules/WindowRuleEngine.swift:67-75`). In this runtime,
  however, focused admission fell through to `non_managed_fallback_entered`, and
  the window remained visible-unmanaged. The exact rejection point needs one
  extra trace/debug field, but the likely path is the focused-admission / stale
  existing-surface guard in `AXEventHandler` rather than the border subsystem.
- **Do not fix this by globally treating `AXDialog` or “no titlebar buttons” as
  tiling-managed.** That would be a high-regression heuristic change. A narrow
  qutebrowser/frameless compatibility path or explicit user rule is reasonable;
  a broad heuristic relaxation is not.

Verdict: 🟡 real Nehir-side compatibility bug, but the safe fix is narrow. The
root cause is not “border window level” for the captured runtime; it is
(1) qutebrowser's frameless main window reporting `AXDialog`, (2) Nehir hiding
borders for `AXDialog`, and (3) admission leaving the window non-managed.

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

## Proposed implementation direction

### 1. Add diagnostics before policy changes

Add trace/debug output for qutebrowser-like admission failures:

- `prepareCreateCandidate` nil reason: owned window, missing token, existing
  entry, failed AX ref, decision untracked/undecided, stabilization retry, etc.
- decision facts for focused admission: bundle id, role/subrole, button facts,
  activation policy, WindowServer level/layer, parent id, tags, frame.
- whether `shouldSuppressUnrequestedAdmissionDuringNonManagedFocus` suppressed a
  prepared candidate and why.

This closes the only remaining gap: why the runtime ended as visible-unmanaged
instead of tracked-floating.

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

This should make borders show even if the window remains non-managed, because
non-managed focus targets already flow through `resolveFrame` and
`BorderManager.updateFocusedWindow` once eligibility allows them.

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

## Suggested tests

- Border eligibility: an `AXWindow` with `subrole=AXDialog` normally hides the
  border; the qutebrowser-compatible predicate allows border update only for a
  regular top-level layer-0 app window.
- Heuristic/admission: no-buttons `AXDialog` still defaults to floating, not
  tiling; explicit user override can force tiling.
- Non-managed fallback: a focused qutebrowser-compatible existing window is not
  silently pulled into tracking unless the compatibility rule or explicit user
  rule allows it.
- Regression fixtures: sheets/system dialogs remain border-hidden and untracked;
  Ghostty quick terminal / overlays remain ignored; ordinary decorated windows
  remain tiled as before.

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
