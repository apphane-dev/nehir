# Nehir #66 — Window Borders not rendered for undecorated / frameless apps (qutebrowser)

Source issue: https://github.com/Guria/nehir/issues/66 (open, no labels).
Reporter symptom, inlined (the issue attaches a screen recording and a trace
file; per branch rules neither is referenced here):

> Borders are not rendered for some specific applications, like qutebrowser
> (only problematic app observed so far). Edit: problem does not exist when
> decorations are NOT hidden, so maybe very qutebrowser-related. Borders ARE
> displayed when qutebrowser's `window.hide_decoration: global: false` (i.e.
> native macOS decorations ON). When decorations are hidden (`hide_decoration:
> global: true`, so qutebrowser draws its own frameless window with no macOS
> titlebar), Nehir's borders disappear.

Maintainer (@Guria, issue comment): the **Show Borders** feature is experimental
and known to be quirky; the symptom disappears when qutebrowser's window
decorations are enabled, "which points to an interaction between border
rendering and undecorated windows."

Scope of this doc: characterize, from source, **why** borders fail for
undecorated / frameless windows, identify the fix seam, and flag what still
needs runtime confirmation. All file/line refs were verified against the main
app worktree; line numbers drift — re-verify before implementing.

---

## TL;DR

- The border is its own transparent SkyLight window, drawn as a ring **outside**
  the target frame and ordered **below** the target at a **hard-coded window
  level of 3** (`Sources/Nehir/Core/Border/BorderWindow.swift:58`, `:201`).
- The border pipeline does **not** suppress frameless/floating windows on
  purpose: floating tracked windows do get borders
  (`noop/20260617-omniwm-223-floating-border-tracking.md` documents the floating
  frame-change → border refresh path).
- The one **provable** code-level difference between decorated and undecorated
  qutebrowser is the window-classification heuristic: a frameless window has no
  standard titlebar buttons, so `heuristicDisposition` returns `.floating`
  (`.missingFullscreenButton`) instead of `.managed`
  (`Sources/Nehir/Core/Ax/AXWindow.swift:521-596`, `:660-692`). Decorated
  qutebrowser has close/fullscreen/zoom buttons → `.managed`.
- `.floating` by itself should not hide the border, so the *disappearance* must
  be a **secondary geometry / ordering effect** specific to the frameless window.
  Leading hypothesis (H1): the border is ordered at a fixed level 3 below the
  target with **no awareness of the target's actual window level**; a frameless
  Qt window that sits at level ≥ 3 (or renders opaque content/shadow to its
  frame edge) covers the ring. Secondary hypotheses (frame divergence H2,
  corner-radius clip H3) below.
- **Fix seam:** make `BorderWindow` order the border relative to the target's
  *own* window level instead of the constant `3`, and prefer the WindowServer
  frame for border positioning when the AX-observed frame diverges.
- **Verdict:** 🟡 Discoverable / likely fixable from Nehir's side — but root
  cause still needs one runtime read of qutebrowser's window (level, subrole,
  AX frame vs CGS frame, button set). Open questions enumerated at the end; this
  is not yet a no-op.

---

## The border rendering pipeline (where frame + ordering come from)

### 1. Focus drives a single border target

`FocusBorderController.focusChanged(to:preferredFrame:...)` records the
`visualFocusTarget` and calls `refresh` → `render`
(`Sources/Nehir/Core/Border/FocusBorderController.swift:43-59`, `:69-90`).

The focus target is built by `WMController.keyboardFocusTarget(for:axRef:)`
(`Sources/Nehir/Core/Controller/WMController.swift:3945-3958`). Its `isManaged`
flag means **"tracked by Nehir"**, not "tiling":

```swift
// Sources/Nehir/Core/Controller/WMController.swift:3945
func keyboardFocusTarget(for token: WindowToken, axRef: AXWindowRef) -> KeyboardFocusTarget {
    if let entry = workspaceManager.entry(for: token) {
        return KeyboardFocusTarget(token: token, axRef: entry.axRef,
                                   workspaceId: entry.workspaceId, isManaged: true)
    }
    return KeyboardFocusTarget(token: token, axRef: axRef,
                               workspaceId: nil, isManaged: false)
}
```

Floating windows are tracked entries too (mode `.floating`), so a floating
qutebrowser window resolves with `isManaged: true`.

### 2. Eligibility: floating is NOT a reason to hide

`renderEligibility(for:)` only hides for: owned Nehir windows, untracked managed
targets, suppressed targets, pending native fullscreen, system-modal surfaces
(`kAXSheetRole` / dialog subroles), app fullscreen, or non-displayable entries
(`Sources/Nehir/Core/Border/FocusBorderController.swift:283-310`). A plain
floating window passes as `.update`. So nothing here explains the disappearance.

### 3. Frame resolution

`resolveFrame(for:preferredFrame:preferredFrameSource:)`
(`Sources/Nehir/Core/Border/FocusBorderController.swift:358-410`):

- tracked target → prefers `pendingFrameWrite`, then the preferred (layout)
  frame, then `lastAppliedFrame`, then `preferredKeyboardFocusFrame`, then the
  observed AX frame;
- untracked target (`isManaged == false`) → `observedFrame(for:)`, which reads
  `AXWindowService.framePreferFast` → `SkyLight.shared.getWindowBounds(...)`
  (`Sources/Nehir/Core/Ax/AXWindow.swift:316-320`,
  `Sources/Nehir/Core/SkyLight/SkyLight.swift:609-618`), falling back to the AX
  position+size.

`BorderManager.updateFocusedWindow` rejects only zero-size frames
(`Sources/Nehir/Core/Border/BorderManager.swift:48-53`); any non-zero frame is
passed through.

### 4. The border window: ring outside the target, ordered below at level 3

```swift
// Sources/Nehir/Core/Border/BorderWindow.swift:57-58
private let padding: CGFloat = 8.0
private let orderingLevel: Int32 = 3

// Sources/Nehir/Core/Border/BorderWindow.swift:88-100
let borderWidth = config.width
let scale = operations.backingScaleForFrame(targetFrame)
let resolvedCornerRadius = max(cornerRadius, 0)

let borderOffset = -borderWidth - padding               // expand outward
var frame = targetFrame.insetBy(dx: borderOffset, dy: borderOffset)
    .roundedToPhysicalPixels(scale: scale)
origin = ScreenCoordinateSpace.toWindowServer(rect: frame).origin
frame.origin = .zero
let drawingBounds = CGRect(x: -borderOffset, y: -borderOffset,
                           width: targetFrame.width, height: targetFrame.height)
```

The visible border is the **ring** between the outer (expanded) border window
rect and `drawingBounds` (the target size), produced by an even-odd clip between
`frame` and the inner rounded rect (`Sources/Nehir/Core/Border/BorderWindow.swift:166-196`).
The ring sits entirely **outside** the target frame by `borderWidth + padding`.

Ordering — this is the critical line:

```swift
// Sources/Nehir/Core/Border/BorderWindow.swift:197-202
private func move(relativeTo targetWid: UInt32, needsOrdering: Bool) {
    if needsOrdering {
        operations.transactionMoveAndOrder(wid, origin, orderingLevel, targetWid, .below)
        return
    }
    operations.transactionMove(wid, origin)
}
```

`transactionMoveAndOrder` sets the border window's level to the supplied
`level` (= 3) and orders it `.below` (= -1) the target
(`Sources/Nehir/Core/SkyLight/SkyLight.swift:723-742`):

```swift
// Sources/Nehir/Core/SkyLight/SkyLight.swift:723-742 (abridged)
func transactionMoveAndOrder(_ wid: UInt32, origin: CGPoint, level: Int32,
                             relativeTo targetWid: UInt32, order: SkyLightWindowOrder) {
    ...
    if let transactionSetWindowLevel {
        _ = transactionSetWindowLevel(transaction, wid, level)   // border level = 3
    }
    transactionOrderWindow(transaction, wid, order.rawValue, targetWid) // .below
    _ = transactionCommit(transaction, 0)
}
```

`orderingLevel` is a **constant**. The border never queries the target window's
own level (`SkyLight.queryWindowInfo(windowId).level` exists,
`Sources/Nehir/Core/SkyLight/SkyLight.swift:519-560`, but `BorderWindow` does
not call it). It also never reads the target's shape, alpha, or content extent.

The border's own corner radius comes from `SkyLight.cornerRadius(forWindowId:)`
with a fallback of `9.0` (`Sources/Nehir/Core/Border/BorderManager.swift:17,22,
132-141`), drawn into both inner and outer rounded paths
(`Sources/Nehir/Core/Border/BorderWindow.swift:121-127`, `:162-188`).

---

## Why "decorated vs undecorated" is the fork (provable from source)

The classification heuristic probes the standard titlebar buttons via a batched
AX attribute fetch:

```swift
// Sources/Nehir/Core/Ax/AXWindow.swift:528-535 (attributes probed)
kAXRoleAttribute, kAXSubroleAttribute,
kAXCloseButtonAttribute, kAXFullScreenButtonAttribute,
kAXZoomButtonAttribute, kAXMinimizeButtonAttribute
```

`hasFullscreenButton` / `hasCloseButton` / `hasZoomButton` / `hasMinimizeButton`
are each `hasResolvedAttribute(...)` — true only if the AX child exists and is
not an `NSError` (`Sources/Nehir/Core/Ax/AXWindow.swift:577-596`).

`heuristicDisposition` then decides managed vs floating
(`Sources/Nehir/Core/Ax/AXWindow.swift:631-692`):

```swift
// Sources/Nehir/Core/Ax/AXWindow.swift:648-692 (abridged)
let hasAnyButton = hasCloseButton || hasFullscreenButton || hasZoomButton || hasMinimizeButton
...
if !hasAnyButton, subrole != kAXStandardWindowSubrole {
    return .floating(reasons: [.noButtonsOnNonStandardSubrole])
}
if let subrole, subrole != kAXStandardWindowSubrole {
    return .floating(reasons: [.nonStandardSubrole])
}
if !hasFullscreenButton {
    return .floating(reasons: [.missingFullscreenButton])   // <-- undecorated hits this
}
if fullscreenButtonEnabled != true {
    return .floating(reasons: [.disabledFullscreenButton])
}
return .managed(reasons: [])
```

- **Decorated qutebrowser** (`hide_decoration=false`): the native macOS titlebar
  exposes close / fullscreen / zoom buttons → `hasFullscreenButton == true` →
  `.managed` (tiled). The window is positioned by Nehir and the border surrounds
  the layout frame.
- **Undecorated qutebrowser** (`hide_decoration=true`): qutebrowser draws a
  frameless window with no macOS titlebar, so none of the four button attributes
  resolve → `hasFullscreenButton == false` → `.floating`
  (`.missingFullscreenButton`, or `.noButtonsOnNonStandardSubrole` if the subrole
  is also non-standard).

This is exactly the "decorated vs undecorated" fork the maintainer suspected,
and it is the only first-order behavioral difference the source guarantees.
`recordWindowDecisionTrace` confirms these fields are already recorded for
non-standard / non-level-0 windows
(`Sources/Nehir/Core/Controller/WMController.swift:2143-2189`):
`disposition`, `source`, `admissionOutcome`, `layout`, `deferred`, `bundleId`,
`axRole`, `axSubrole`, `windowLevel`, `windowTags`, `parentWindowId`,
`windowFrame`.

---

## Why `.floating` alone does not explain the disappearance

Floating windows are tracked entries, so they take the managed branch of
`resolveFrame` and are not hidden by `renderEligibility`. Floating frame changes
actively refresh the focused border
(`Sources/Nehir/Core/Controller/AXEventHandler.swift:677-705`,
`:755-799`; `Sources/Nehir/Core/Border/FocusBorderController.swift:92-105`) —
see `noop/20260617-omniwm-223-floating-border-tracking.md`, which documents that
floating border tracking is already wired and tested. So a window becoming
`.floating` instead of `.managed` does not, by itself, turn the border off.

The *disappearance* must therefore come from a **secondary** property of the
frameless window interacting with the border window's fixed geometry/ordering.

---

## Root-cause hypotheses (ranked, grounded in the code above)

### H1 (leading): fixed level-3 ordering with no target-level awareness

The border is committed at `level = 3`, ordered immediately `.below` the target
(`BorderWindow.swift:58,197-202` → `SkyLight.swift:723-742`). For a normal app
window at level 0 the ring sits in empty space outside the frame and is visible.
But the ordering code never reads the target's actual level. If the frameless
qutebrowser window lives at level ≥ 3 (some Qt/toolkit frameless windows, or
windows using certain `NSWindow` styles, do not stay at level 0), the border
ring ends up at or below the target's z-layer and is covered by the target's
opaque content / shadow even though the ring is geometrically outside the AX
frame. Because `BorderWindow` does not consult
`SkyLight.queryWindowInfo(targetWid).level`, it cannot compensate. This matches
the symptom precisely: decorations ON → level-0 standard window → border ring
shows; decorations OFF → frameless window at a different level → ring covered.

### H2: AX-observed frame ≠ WindowServer frame for the frameless window

For the untracked-target fallback, the border is positioned from
`observedFrame` = AX position+size, but the SkyLight **ordering** is performed
against the target's WindowServer identity. Qt frameless windows can report a
position/size via AX that is offset from the real WindowServer frame (e.g. a
content rect vs. the full window rect, or a shadow-inclusive bounds). If the
border is positioned from one frame but z-ordered against a window whose drawn
pixels follow the other, the ring can land under the window or off-alignment and
look "not rendered". `resolveFrame`/`observedFrame`
(`FocusBorderController.swift:358-410`) and `AXWindow.framePreferFast`
(`AXWindow.swift:316-320`) are the relevant seams.

### H3: anomalous corner radius breaking the even-odd clip

`resolvedCornerRadius` is read from `SkyLight.cornerRadius(forWindowId:)` with a
`9.0` fallback (`BorderManager.swift:17,22,132-141`). A frameless window may
report no radius (→ 9.0 fallback) or an unusual value. A wrong radius would more
likely *distort* the ring than erase it, so H3 is the weakest of the three, but
it is on the same draw path (`BorderWindow.swift:162-188`) and cheap to rule
out.

### Not the cause (ruled out by code)

- Not a zero-frame guard: a non-zero AX frame passes `BorderManager.swift:48-53`.
- Not eligibility suppression of floating windows: `renderEligibility`
  (`FocusBorderController.swift:283-310`) does not hide floating targets.
- Not an app/bundle rule: there is no qutebrowser/Qt/frameless-specific rule in
  `Sources/Nehir` (search for `qutebrowser|frameless|undecorat|hideDecoration`
  returns nothing).

---

## Proposed fix seam

Primary (addresses H1): in `BorderWindow.move(relativeTo:needsOrdering:)`
(`Sources/Nehir/Core/Border/BorderWindow.swift:197-205`) and the
`transactionMoveAndOrder` operation (`BorderWindow.Operations`,
`BorderWindow.swift:11-31`), read the target's window level via
`SkyLight.queryWindowInfo(targetWid).level` and order the border directly below
the target **at the target's own level** (or `targetLevel`, ordering `.below`),
instead of the hard-coded `orderingLevel = 3`. This keeps the border's z-layer
locked to the target's regardless of whether the window is a standard level-0
window or a frameless window at another level. The `queryWindowInfo` API already
returns `level` (`Sources/Nehir/Core/SkyLight/SkyLight.swift:519-560`).

Secondary (addresses H2): in `FocusBorderController.resolveFrame` /
`observedFrame` (`Sources/Nehir/Core/Border/FocusBorderController.swift:358-410`,
`:402-410`), when the observed AX frame and the WindowServer frame diverge,
prefer the WindowServer frame (`SkyLight.getWindowBounds`) for border
positioning — it is the coordinate space the border is z-ordered against.

Tertiary (product decision, not just borders): if frameless standard windows
*should* tile, relax the `.missingFullscreenButton` /
`.noButtonsOnNonStandardSubrole` branches of `heuristicDisposition`
(`Sources/Nehir/Core/Ax/AXWindow.swift:648-682`). This changes layout scope
(many borderless utility windows would become tiling candidates), so it should
only follow an explicit product call, not be bundled into a border fix.

---

## Open questions / confirmation needed (no trace file referenced)

Root cause is *highly likely* H1 but not yet confirmed without one runtime read
of the live qutebrowser window. To close the gap, enable Developer Mode
(Diagnostics tab → Record Traces), focus undecorated qutebrowser, and capture a
short trace. The values that decide H1 vs H2 vs H3 — all of which the existing
trace already records or can be read from the focused window — are:

- **`windowLevel`** of the qutebrowser window (from the `windowDecision` trace
  entry, `WMController.swift:2160-2189`). If it is anything other than `0`, H1
  is confirmed.
- **`axSubrole`** and **`admissionOutcome`/`disposition`** for the window
  (`WMController.swift:2160-2189`): expect `.floating` with
  `.missingFullscreenButton` (or `.noButtonsOnNonStandardSubrole`).
- **AX frame vs WindowServer frame** for the focused window: compare
  `kAXPositionAttribute`+`kAXSizeAttribute` against
  `SkyLight.getWindowBounds(windowId)` (`AXWindow.swift:316-320`,
  `SkyLight.swift:609-618`). A non-trivial divergence implicates H2.
- Whether the border window is created at all: check
  `BorderManager.lastAppliedFocusedWindowIdForTests` /
  `lastAppliedFocusedFrameForTests` (`BorderManager.swift:101-107`) — i.e.
  whether a non-zero frame was applied. If a frame *is* applied but the border
  is invisible, the cause is ordering (H1) or frame mismatch (H2), not the
  pipeline suppressing it.

If runtime inspection shows the qutebrowser window reports a valid level-0
frame, a standard subrole, AND a correct AX/CGS frame, but borders still vanish,
then the cause is outside Nehir's observable state (e.g. the app composites over
the border) and the verdict drops to no-op / wontfix with that evidence. Until
then this is a fixable border-ordering bug.

---

## Related prior discovery (do not duplicate)

- `discovery/20260617-omniwm-150-screenshot-bordered-window-blank.md` — border
  is its own transparent SkyLight window; about screenshot capture, not
  frameless windows.
- `noop/20260617-omniwm-223-floating-border-tracking.md` — floating windows DO
  get borders; cited above to rule out "floating → no border".
- `noop/20260617-omniwm-362-border-corner-radius.md` — corner radius is already
  resolved per-window (relevant to H3, already handled for the radius value).
