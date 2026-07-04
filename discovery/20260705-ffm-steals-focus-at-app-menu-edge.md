# FFM steals focus at the edge of an open app context menu (menu-tracking session not respected)

Discovery (2026-07-05). With `focusFollowsMouse=true`, opening an app **context
menu** (here a Chromium/Helium menu) and navigating into its **second-level
submenu** — which floats over a *different* tiled window — makes FFM **steal
focus to the tile beneath the menu** the instant the pointer crosses the menu's
edge. That focus change dismisses the menu, so multi-level menus become unusable
under FFM.

This is the **menu-tracking** sibling of the unmanaged-overlay focus-steal
family:

- [[20260615-ffm-suppress-over-unmanaged-overlay-windows]] — FFM stole focus
  behind Ghostty's Quick terminal (fixed via the `mouseEventWindowUnderMousePointer`
  fast-path + broadened snapshot probe).
- [[20260616-ffm-steals-focus-behind-overlay-on-stale-queued-mouse-moves]] —
  the coalesced/stale-move variant of the same.

Both of those close the case where the pointer is **over** the overlay. This
discovery is the case where the pointer briefly leaves the overlay's bounds
**while the menu is still tracking** — which both prior docs explicitly scoped
*out* ("when it is over a tile the overlay does not cover, FFM correctly fires").
For a menu-tracking session that scoping-out is wrong: focus must stay frozen for
the whole session, not per-pixel.

Code line numbers verified against the main Nehir source tree on 2026-07-05
(`MouseEventHandler.swift` is unchanged by the #112 branch). Re-verify before
editing; line numbers drift.

## Not caused by the #112 fixed-Dock fix

This surfaced while validating the #112 change
([[20260705-nehir-112-ffm-fixed-dock-occlusion-regression]], commit that adds a
Dock/system-chrome occlusion exemption). It is **independent and pre-existing**:

- The steal fires at a pointer location where **no** window covers the pointer,
  so occlusion is `false` regardless of any exemption.
- The #112 change only ever makes occlusion return `false` in *more* cases (the
  Dock), and only near the Dock band (screen right edge). The steal here is mid-
  screen, nowhere near the Dock.

So #112 neither introduced nor worsened this. It is shippable as-is.

## Reproduction evidence (inlined)

Topology: two monitors; interaction on monitor 1 (Built-in Retina, `2056×1329`).
Managed tiles on the active workspace:

- Helium (Chromium) tiled window, token `pid 28651 / windowId 215`, at
  `liveAXFrame≈{504,7 974×1251}` (screen left/center column).
- Finder tiled window, token `pid 5533 / windowId 318`, at
  `liveAXFrame≈{1484,7 974×1251}` (right column).

The context menu belongs to Helium. Chromium renders its menus as **ordinary
layer-0 popup windows**, not native `NSMenu`: the trace shows two Helium menu
popups admitted as *unstable* managed-floating windows —
`token pid 28651 / windowId 522` and `528`, each `wsFrame≈(1228,165,220,100)` /
`(1228,1064,220,100)`, `wsLevel=0`, repeatedly re-admitted with `rescue=true` and
`window_decision … outcome=deferred deferred=attributeFetchFailed` (they expose
no AX attributes, no close/zoom/minimize buttons). A second-level submenu extends
these to the right, over the Finder tile.

FFM decision trace as the pointer navigates the submenu (mouse-focus records):

```
… 52× ffm.skip reason=noTarget sub=occlusion loc=(1672.3,1044.1 … 1699.6,1049.2) windowUnderPointer=nil confirmed=(pid 28651, windowId 215) pending=nil
   ffm.activate reason=hoverTarget loc=(1700.1,1049.2) target=(pid 5533, windowId 318) confirmed=(pid 28651, windowId 215) lastToken=(pid 28651, windowId 215)
```

- For 52 consecutive evaluations, while the pointer is **over** the submenu
  (x≈1672→1699.6, y≈1044), FFM correctly bails with `sub=occlusion`; confirmed
  focus stays on Helium `215` (the menu owner).
- At `loc=(1700.1,1049.2)` — a **~0.5 px step past the submenu's right edge** —
  FFM `activate`s on Finder `318`, the tile beneath. Focus is stolen; the menu
  dismisses.

`windowUnderPointer=nil` throughout (coalesced/continuous motion → snapshot
path), so occlusion is decided purely by geometry: the submenu window covers the
point up to x≈1699.6 and not at x≈1700.1.

## Root cause

FFM's only protection against focusing "through" an open menu is **per-pixel
geometric occlusion** of the menu window. There is **no notion of an active
menu-tracking session** during which focus should be frozen.

Flow: `handleMouseMovedFromTap` → `shouldHandleFocusFollowsMouse`
(`MouseEventHandler.swift:913`) → `handleFocusFollowsMouse` (`:1273`) →
`resolveFocusFollowsMouse` (`:1347`). The occlusion guard (`:1357`) returns
`.occlusion` only while a covering window is found; the moment the pointer leaves
the menu's bounds, it returns a `.target` (the tile beneath) and
`handleFocusFollowsMouse` activates it (`:1344`).

The existing short-suppression mechanism does not help here:
`state.suppressFocusFollowsMouseUntil` (`:235`, honored at
`shouldHandleFocusFollowsMouse` `:915`) is armed to `now + 2s` only by
`markRecentFloatingPointerInteractionIfNeeded` (`:1421`), which runs on
mouse-**down**/drag/up — never on passive hover over a menu. So navigating a menu
with the pointer (no click) earns no suppression grace at all.

Why native-menu detection won't fix it: the offending menus are Chromium popups
at `wsLevel=0` with no AX surface, indistinguishable by level or role from an
ordinary window. A fix keyed on `NSMenu` tracking or `kCGPopUpMenuWindowLevel`
would miss them.

## Recommended fix — occlusion hysteresis (grace period)

When FFM resolves `.occlusion` (pointer over an unmanaged/overlay/menu window),
arm a short suppression grace so a brief excursion off the overlay's edge does
not immediately steal focus:

In `handleFocusFollowsMouse` (`MouseEventHandler.swift:1303`), in the
`guard case let .target = resolution else { … }` branch, when `resolution` is
`.occlusion`, set:

```swift
state.suppressFocusFollowsMouseUntil = now.addingTimeInterval(ffmOcclusionGrace)
```

with `ffmOcclusionGrace` ≈ `0.3–0.4s` (a new private constant near
`focusFollowsMouseDebounce`). `shouldHandleFocusFollowsMouse` (`:915`) already
gates on `Date() >= state.suppressFocusFollowsMouseUntil`, so:

- While the pointer stays on the menu, occlusion re-arms the grace every move —
  suppression persists for the whole tracking session.
- A sub-300 ms excursion across the submenu's edge (submenu navigation, the seam
  between menu levels) stays suppressed — no steal.
- ~0.3 s after the pointer genuinely leaves the menu (menu closed / user moved to
  a tile), FFM resumes normally — negligible perceived latency.

This reuses existing machinery, needs no menu/level detection, and generalizes to
every occluding overlay (Ghostty Quick terminal, etc.), not just Chromium menus.

### Why not the alternatives

- **Native menu-tracking detection** (freeze FFM while any `NSMenu` tracks):
  correct in spirit but misses Chromium/Electron menus, which are the reported
  case (layer-0 popups, no AX). Could complement the grace period but cannot
  replace it.
- **Widen the occlusion frame** (treat a margin around the menu as covered):
  brittle; a fixed margin is wrong for arbitrary submenu geometry and re-opens
  false suppression over real tiles.

## Verification (before/after)

Re-capture with a runtime trace while navigating a two-level Chromium context
menu that overhangs another tile:

- **Before:** the `ffm.skip … sub=occlusion` run ends in an `ffm.activate
  target=<tile beneath>` at the menu edge (as above).
- **After:** no `ffm.activate` fires during menu navigation; `confirmed` focus
  stays on the menu owner until ~0.3 s after the menu closes.

Ask the user to confirm on their real repro before adding regression tests
(per repo `AGENTS.md`: no test edits until the runtime fix is user-confirmed).

## Update 2026-07-05 (after the grace-period fix): still reproduces — occlusion does not even fire

The occlusion-hysteresis fix above was implemented (arm
`suppressFocusFollowsMouseUntil = now + 0.35s` when `resolveFocusFollowsMouse`
returns `.occlusion`). It cut the steals dramatically (a later capture shows a
single `ffm.activate` instead of the earlier 16) but **did not eliminate them**,
because there is a *second mode* of this bug where **occlusion never fires**, so
the grace period is never armed.

Evidence (later capture, two Helium tiles: `215` left `{14,7 1011×1251}`,
`244` right `{1031,7 1011×1251}`; a Helium context menu open):

```
… ffm.skip reason=noTarget sub=noHitTest …            ← sub=noHitTest, NOT sub=occlusion
tap.mouseMoved direct=0 canHandle=0 resolved=nil loc=(1258.9,1075.8)
ffm.activate reason=hoverTarget loc=(1258.9,1075.8) target=(pid 28651, windowId 244) confirmed=(pid 28651, windowId 215)
```

The skips are `sub=noHitTest`, not `sub=occlusion` — occlusion returned `false`,
so the `.occlusion` grace-arm branch is never taken. The runtime state confirms
why: `windows total=3 tiled=3 floating=0` — the menu popup is **not** a managed
floating window. It is a **tracked candidate in limbo**: the rule engine logs
`candidate_tracked token=(28651,645)` with
`window_decision … disposition=undecided outcome=deferred deferred=attributeFetchFailed`
(a Chromium menu popup, `wsLevel=0`, `220×80`, no AX attributes, no
close/zoom/minimize buttons, re-admitted repeatedly with `rescue=true`).

That limbo state defeats **both** occlusion gates:

- **Unmanaged-overlay gate** (`unmanagedInteractiveWindowServerWindowCovers`):
  excludes any window in `trackedWindowIds` / owned surfaces. While the popup is
  a tracked candidate it is treated as "one of ours" and does not occlude.
- **Floating gate** (`isFloatingWindowCoveringPointer` /
  `hasVisibleFloatingWindowOverNiriLayout`): only counts *managed floating
  entries* that are `observedState.isVisible && visibility == .visible`. The
  popup is never promoted to a stable floating entry (`floating=0`), and
  `hasVisibleFloatingWindowOverNiriLayout` also early-returns `false` when the
  focused window is a tiling window (it is, `215`).

So the menu popup falls through both gates → `resolveFocusFollowsMouse` reaches
the tile hit-test → returns `.target(tile 244)` → FFM steals. Note the preceding
`tap.mouseMoved direct=0 canHandle=0 resolved=nil`: the CGEvent reports **no
window under the pointer that can handle the event**, the signature of hovering a
transient menu popup that does not participate in normal hit-testing — yet FFM
still fell back to a geometric tile hit-test.

Admission is racy, which is why the earlier capture caught the popup as an
unmanaged occluder (`sub=occlusion`, 52×) while this one does not: whether the
popup is momentarily in `trackedWindowIds` decides which gate it slips through.
Per-pixel occlusion of a flapping transient popup is therefore the wrong
foundation.

### Pinned fix (2026-07-05) — classify the AX-less menu popup as `.unmanaged` (dimension-free, PiP-safe)

Located the exact admission seam. In `WindowRuleEngine.decision(for:)`, the menu
popup misses every existing menu/popup rule and falls to the AX-fetch-failed
branch:

- `transientSystemDialogSurfaceDecision` (`WindowRuleEngine.swift:661`) and the
  "floating-tagged non-document popup" rule (`:502`) both require
  `facts.ax.attributeFetchSucceeded` — the popup's AX fetch **failed**
  (`axRole=nil axSubrole=nil`, `fetchFailure=multiple_attribute_fetch_failed`).
- `parentedWindowServerSurfaceDecision` (`:639`) requires `windowServer.parentId
  != 0`, but the `window_decision` was taken with `wsParent=0` (the parent
  `215` is only resolved later, on the layout-rejection path). So it misfired.
- Result: control reaches `if !facts.ax.attributeFetchSucceeded` (`:578`), which
  returns `.undecided / deferredReason=.attributeFetchFailed`. That is what gets
  **rescue-admitted** as a flapping tracked-floating candidate (`rescue=true`,
  re-admitted repeatedly), i.e. the tracked-limbo that escapes both FFM
  occlusion gates.

The engine already has the right **dimension-free** signal for "AX-less native
transient surface": `WindowRuleFacts.degradedWindowServerChildEvidence` (`:119`)
= `!attributeFetchSucceeded` AND (`windowServer.hasModalTag` OR
(`hasFloatingTag && !hasDocumentTag`)), **with a PiP carve-out already built in**
(`windowServer.parentId == 0 && isTopLevelResizableMediaLikeSurface` returns
early). The popup also carries `windowServer.hasTransientSurfaceEvidence`
(`transientWindowServerEvidence=true` in the trace).

**Fix:** in the `!facts.ax.attributeFetchSucceeded` branch (`:578`), before the
`.undecided/deferred` fallback, classify the window as **`.unmanaged`** (a native
menu/popup surface; new `builtInRule` source, mirroring
`transientSystemDialogSurface` which is also `.unmanaged`) when the WindowServer
facts show transient-menu evidence — i.e. `degradedWindowServerChildEvidence`
(and/or `windowServer.hasTransientSurfaceEvidence`) — and it is **not** a
PiP-like top-level resizable media surface. Being `.unmanaged`, the popup leaves
`trackedWindowIds` and the layout tree, so:

1. The **unmanaged-overlay FFM gate** (`unmanagedInteractiveWindowServerWindowCovers`)
   now sees it and returns `.occlusion` → the shipped **grace period**
   (95fe0725) holds focus through edge/gap crossings → no steal.
2. The flapping `rescue=true` re-admission stops (a bonus; cf.
   [[20260622-rescued-floating-auxiliary-windows-leak-into-workspace-bar]],
   [[20260628-stale-floating-entry-lingers-after-surface-destroyed]]).

**Why PiP is safe** (per the user's steer — *dimension is a bad signal*): the fix
keys on AX-less + WindowServer transient-menu evidence, never on size. PiP is a
real AX window: `pipDefaultStickyCandidate` (`:146`) and all PiP handling require
`attributeFetchSucceeded`, so PiP never reaches this AX-less branch; and
`degradedWindowServerChildEvidence` already excludes `isTopLevelResizableMediaLikeSurface`
(PiP's shape). See [[20260617-omniwm-113-above-normal-level-pip-tiling]],
[[20260626-pip-common-defaults-no-special-mode]].

**Guard against over-classifying** (`AGENTS.md` admission caution): a *real*
window can transiently fail AX fetch while opening — that is exactly why this
branch currently **defers** rather than decides. So gate the new `.unmanaged`
decision on the positive WindowServer transient-menu evidence
(`degradedWindowServerChildEvidence` / `hasTransientSurfaceEvidence`); keep the
existing `.undecided/deferred` fallback for AX-less windows *without* that
evidence, so a briefly-AX-less real window still gets retried, not ignored.

**Residual:** the unmanaged-occlusion snapshot still filters `width>=80 &&
height>=80`, so a very thin submenu strip could momentarily not occlude — the
0.35 s grace period bridges those brief crossings. Widening/removing that size
filter for transient-evidence surfaces is a possible follow-up, out of scope
here.

### (superseded framing) session-level suppression, not per-pixel occlusion

FFM should be frozen for the **duration of an app menu-tracking session**, not
decided per pixel. Since these Chromium/Electron menus are AX-less layer-0
popups (native `NSMenu` / `kCGPopUpMenuWindowLevel` detection misses them), the
robust proxy is the **presence of a transient popup owned by the focused/
frontmost app** — exactly the `attributeFetchFailed` / `transientWindowServerEvidence`
candidates the reconcile loop already enumerates. Recommended:

- **Primary:** while any transient menu-like popup (AX-less deferred candidate /
  `transientWindowServerEvidence`) owned by the focused app is present, suppress
  FFM entirely (e.g. keep re-arming `suppressFocusFollowsMouseUntil`, or add an
  explicit `isMenuTrackingActive` guard in `shouldHandleFocusFollowsMouse`).
  This holds regardless of pointer geometry, the admission race, or which gate
  the popup slips through.
- **Keep** the `.occlusion` grace period (95fe0725) as a complementary net for
  the case where the popup *is* caught as an occluder and the pointer leaves its
  edge.
- **Consider** classifying these popups as `disposition=.unmanaged` via a
  built-in rule (cf. `builtInRule("transientSystemDialogSurface")`,
  `WMController.swift:2331`) so they never enter `trackedWindowIds` — that alone
  would route them back through the unmanaged-overlay gate + grace period, and
  also stops the flapping `rescue=true` re-admission.

Trade-off to weigh: the suppression predicate must be tight enough not to freeze
FFM whenever any app merely has a transient child window. Scope it to popups
owned by the currently focused app and present *now*, and release as soon as the
popup set empties.

## Files (fix)

- `Sources/Nehir/Core/Controller/MouseEventHandler.swift` — add the
  `.occlusion` grace-arm in `handleFocusFollowsMouse` and the
  `ffmOcclusionGrace` constant. No `WMController` change needed.
- `.changeset/<ts>-stop-ffm-stealing-focus-at-context-menu-edges.md` — `patch`.
- Regression tests: deferred until user-confirmed (see above), then extend
  `Tests/NehirTests/MouseEventHandlerTests.swift`.
