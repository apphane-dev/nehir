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

## Files (fix)

- `Sources/Nehir/Core/Controller/MouseEventHandler.swift` — add the
  `.occlusion` grace-arm in `handleFocusFollowsMouse` and the
  `ffmOcclusionGrace` constant. No `WMController` change needed.
- `.changeset/<ts>-stop-ffm-stealing-focus-at-context-menu-edges.md` — `patch`.
- Regression tests: deferred until user-confirmed (see above), then extend
  `Tests/NehirTests/MouseEventHandlerTests.swift`.
