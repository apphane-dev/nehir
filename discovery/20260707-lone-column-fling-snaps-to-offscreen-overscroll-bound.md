# Discovery: fling-scrolling a lone column snaps it off the display edge

Groom 2026-07-07: in flight — see `planned/20260707-lone-column-fling-snaps-offscreen-overscroll-bound.md`; the bad-snap-target defect (bound endpoints promoted to snap targets when the strip does not fill the viewport) has not been fixed on main (verified against main 7a025b78).

Status: discovery only — root-caused and source-confirmed. A three-finger
horizontal fling on a workspace whose **only column is narrower than the
viewport** can snap the viewport to an overscroll *bound* that parks that sole
column almost entirely off the display, so the window appears to "disappear off
the side" even though there is nothing to reveal and empty viewport space to
spare. This is a viewport-geometry defect (bad snap targets), distinct from the
momentum-overshoot-to-a-neighbor case in
`20260627-trackpad-fling-snap-overshoot-to-neighbor-column.md` — here there is
no neighbor column at all.

Verified against the main Nehir source tree on 2026-07-07 (source line numbers
below are durable code citations).

Cross-link cluster: [`VR-1` in `20260708-cross-discovery-relevance-clusters.md`](20260708-cross-discovery-relevance-clusters.md#vr-1--automatic-revealrecentersnap-movement-bypasses-user-intent-or-visibility-checks) groups this with the other high-confidence viewport movement bugs. This one is the snap-target-generation variant, not a reveal-policy variant.

## Summary

`viewportStartBounds` allows "intentional edge overscroll": at the extreme scroll
positions only a ~5% sliver of the edge column need remain visible. That idiom is
correct for a **filled** strip (you overscroll to peek the next column). But the
bounds are computed unconditionally, and `computeSnapGrid` promotes **both**
bound endpoints to first-class snap *targets*. When the strip does **not** fill
the viewport (one narrow column, or a few narrow columns totalling less than the
viewport width), those two bound-snaps sit far outside the range where the column
is on-screen. A momentum fling toward the empty side projects onto the bound-snap
and the gesture-end spring parks the sole window ~90%+ off the display.

The move is fully attributed to the normal gesture-end path (`endGesture.spring`);
it is not a silent write.

## Topology / repro

- Two displays. Display 2 (secondary, `DELL P2423D`)
  `frame=(2056, -111, 2560, 1440)`, working viewport width ≈ `2466`, viewport
  left edge at screen x ≈ `2064`.
- Workspace 6 on display 2 holds a **single tiled column** — one window
  (Helium browser, the only window in that workspace),
  `effectiveViewportWidth = 1480`, `gap = 6`. `1480 < 2466`, so the column fits
  entirely inside the viewport with ~986 pt to spare.
- Column resting position before the gesture: **center snap**,
  `currentViewStart = -493` → window at screen x `2064 - (-493) = 2557`, i.e.
  centered on display 2 (`[2557, 4037]`, display-2 span `[2056, 4616]`).
- Action: a fast three-finger horizontal trackpad flick **toward the other
  display** (leftward, i.e. increasing `viewStart`), released mid-flick.

## Evidence (inlined from the capture)

### The five snap points for a lone 1480-wide column

With `columns=[1480]`, `gap=6`, `viewportWidth=2466`, the grid (see Root cause
for the formulas) evaluates to exactly five points, matching the capture's
`snapPointCount=5`:

| offset (`viewStart`) | kind | window screen-x | on display 2? |
| --- | --- | --- | --- |
| `-2386` | rightEdge **bound** (lower) | `4450` → `[4450, 5930]` | ~166 pt sliver at far right — mostly OFF |
| `-980`  | column rightEdge | `3044` → `[3044, 4524]` | fully visible |
| `-493`  | center | `2557` → `[2557, 4037]` | fully visible (home) |
| `-6`    | column leftEdge | `2070` → `[2070, 3550]` | fully visible |
| `1400`  | leftEdge **bound** (upper) | `664` → `[664, 2144]` | ~88 pt sliver at far left — mostly OFF |

The two sane far-park positions are `-980` (right-aligned, fully visible) and
`-6` (left-aligned, fully visible). The two *bound* endpoints `-2386` and `1400`
push the sole column off-screen — and both are live snap targets.

### Gesture end — the fling projects onto the off-screen bound `1400`

The end-candidate decision record (leftward fling, high release velocity):

```text
reason=touch_scroll_gesture_end_candidate snap=true
  activeColumnIndex=0
  currentOffset=331.675  currentViewStart=331.675
  projectedOffset=1147.006  projectedViewStart=1147.006
  velocity=2449.672
  snapPointCount=5
  closestSnap=1400.000  closestSnapColumn=0  closestSnapKind=leftEdge
  closestSnapDistance=252.994
  targetOffset=1400.000
  wouldClamp=false  clampScreens=1.000
```

- Momentum projects the landing to `projectedViewStart = 1147.0`.
- The globally nearest snap is the **upper bound** `1400.0` (distance `253`),
  not the fully-visible left edge `-6` (distance `1153`).
- Trackpad projection clamp did not engage (`wouldClamp=false`, projection was
  within one screen of the current position).

### The spring drives the window off display 2

Gesture-end spring animates `currentViewStart` from `~357` up to `1400`, sliding
the window left across and then off the display:

```text
reason=scroll_animation_start  currentViewStart=356.1  targetViewStart=1400.0  animating=true
  layout=...{w10428: cur=1708,-104,1480,1371  target=664,-104,1480,1371 ...}
reason=spring_frame_classification  windowId=10428  bucket=crossing
  currentFrame={{1511.0,-104.0},{1480.0,1371.0}}  viewport={{2064.0,-104.0},{2466.0,1371.0}}
  currentViewStart=662.7  targetViewStart=1400.0
reason=scroll_animation_stop  currentViewStart=1400.0 (settled)
```

At the target, the window rect is `[664, 2144]`; only `[2056, 2144]` (≈88 pt)
overlaps display 2. The remainder lies over display 1's region, where workspace 6
is not the visible workspace — so it is not shown. Net: the window is ~94% gone.
"Scrolled toward the other display and just disappeared."

### Secondary, coincidental: the Helium window reloaded mid-fling

While the off-screen spring was running, the Helium window (`windowId=10428`)
was destroyed and re-created (a browser reload — a same-app close/replace):

```text
reason=close_recovery_stable_target  observedToken=WindowToken(pid: 28651, windowId: 10428)  targetToken=nil  reason=fallback
reason=ax_focus_confirm_before_activate ... recentSameAppClosePin=true
reason=window_removal_seed_check  windowModelStillTracks=false  currentViewStart=1394.2  preferredFocus=nil
reason=scroll_animation_stop  columns=0  layout=no-columns
# ~6 s later:
reason=readmit_pending_removal  token=WindowToken(pid: 28651, windowId: 10428)
reason=relayout.viewportOffsetChanged  currentViewStart=-493.0   # fresh node, re-centered
```

This is **not** the root cause of the reported symptom. The off-screen snap
target `1400` was chosen at `touch_scroll_gesture_end_candidate` from the fling
projection alone — before any close/`recentSameAppClosePin` signal appeared — and
would have parked the window off display 2 regardless of the reload. The reload
merely explains why the window did not spring back on its own (it came back
re-centered at `viewStart=-493` when the new AX window was re-admitted).

## Root cause (source)

All in `Sources/Nehir/Core/Layout/Niri/ViewportState+Geometry.swift`.

1. **Overscroll bounds are computed unconditionally** —
   `viewportStartBounds(...)` at `ViewportState+Geometry.swift:600`:
   ```swift
   let lower = firstWidth * fraction + gap - viewportWidth      // fraction = 0.05
   let upper = total - lastWidth * fraction - gap
   return min(lower, upper) ... max(lower, upper)
   ```
   For `total=1480`, `lastWidth=1480`, `gap=6`, `fraction=0.05`:
   `upper = 1480 - 74 - 6 = 1400` and `lower = 74 + 6 - 2466 = -2386` — exactly
   the two off-screen endpoints in the capture. The comment (`:613`) explains the
   sliver is *intentional edge overscroll*, which is meaningful only when there
   is content beyond the edge to reveal. Nothing here checks whether the strip
   actually fills the viewport (`total >= viewportWidth`); when it does not, both
   endpoints move the sole/edge column off-screen into empty space.

2. **Both bound endpoints are promoted to snap targets** —
   `computeSnapGrid(...)` at `ViewportState+Geometry.swift:715`:
   ```swift
   let bounds = viewportStartBounds(columns: columns, gap: gap, viewportWidth: viewportWidth)
   points.append(SnapPoint(offset: bounds.lowerBound, columnIndex: 0, kind: .rightEdge))
   points.append(SnapPoint(offset: bounds.upperBound, columnIndex: columns.count - 1, kind: .leftEdge))
   ```
   So `1400` and `-2386` are not just clamp limits a spring transiently passes —
   they are resting positions the nearest-snap picker can select. (Note the
   per-column edge/center snaps at `:697-710` *are* guarded by
   `columnApproximatelyFillsViewport`, but that guard only skips ±gap edge snaps
   for a near-viewport-width column; it does nothing for the narrow-column case,
   and it does not touch the bound-snaps.)

3. **Gesture end selects the globally nearest snap** — `endGesture(...)` at
   `Sources/Nehir/Core/Layout/Niri/ViewportState+Gestures.swift:153`:
   ```swift
   let context = snapContext(columns: columns, gap: gap, viewportWidth: areas.span(of: areas.working))
   guard let targetSnap = context.closest(to: CGFloat(projectedViewPos)) else { ... }
   ```
   `snapContext` is built with the default `intentionallyDoesNotFillViewport=false`
   (`ViewportState+Geometry.swift:647`), and even when that flag is `true` it only
   gates the auto-fill recenter in `fillingSpan` (`:170`) — it does **not** feed
   into `viewportStartBounds` or `computeSnapGrid`. So the fling projection
   (`projectedViewPos=1147`) picks the upper-bound snap `1400`, and the spring
   (`endGesture.spring`, `ViewportState+Gestures.swift:179-187`) drives the window
   off the display.

Summary: for a strip narrower than the viewport there is nothing to overscroll
toward, yet `viewportStartBounds` still returns off-screen endpoints and
`computeSnapGrid` makes them snap targets. A leftward (or rightward) fling then
parks the only column ~90%+ off-screen.

## Why it is not the neighbor-overshoot bug

- There is no neighbor column — the workspace has a single column. The
  overshoot in `20260627-...` lands on a *different column's* edge; here it lands
  on a *viewport bound* that no column occupies.
- The move is a single attributed `endGesture.spring`; the pre-end gesture
  updates track the finger. Not a silent/unrecorded mutation.

## Candidate fix directions (behavior change — needs its own plan)

1. **Gate the overscroll term on strip fill.** In `viewportStartBounds`, when
   `total <= viewportWidth` (nothing beyond either edge to reveal), collapse the
   bounds to the fully-visible range — e.g. lower = left-aligned (`-gap`), upper =
   right-aligned (`total + gap - viewportWidth`), or simply the span between the
   outermost column left/right-edge snaps — so no bound can park a column
   off-screen. Keep the 5% overscroll only when `total > viewportWidth`.
2. **Do not promote bound endpoints to snap targets when they are off-content.**
   In `computeSnapGrid`, append `bounds.lowerBound` / `bounds.upperBound` as snaps
   only when the strip fills the viewport; otherwise the per-column
   leftEdge/rightEdge/center snaps already cover every sane resting position.
3. **Route the narrower-than-viewport case through
   `intentionallyDoesNotFillViewport`,** and have that flag actually constrain
   `viewportStartBounds` / `computeSnapGrid` (today it only gates `fillingSpan`).

Any of these needs regression coverage in `ViewportGeometryTests` — add a lone
narrow-column-in-a-wide-viewport case asserting that no snap point (and no
`viewportStartBounds` endpoint) leaves the column less than fully on-screen, and
that a high-velocity fling settles on a fully-visible snap (`-6`, `-980`, or
center), never on a bound.

## References

- `Sources/Nehir/Core/Layout/Niri/ViewportState+Geometry.swift:600`
  (`viewportStartBounds`, overscroll `lower`/`upper`), `:668` (`computeSnapGrid`),
  `:695-703` (`columnApproximatelyFillsViewport` guard — narrow case unguarded),
  `:715-717` (bound endpoints appended as snap targets), `:647-666`
  (`snapContext`, default `intentionallyDoesNotFillViewport=false`), `:165-203`
  (`fillingSpan`, the only consumer of the flag).
- `Sources/Nehir/Core/Layout/Niri/ViewportState+Gestures.swift:132-158`
  (momentum projection + nearest-snap selection), `:179-187` (gesture-end spring).
- Related: `discovery/20260627-trackpad-fling-snap-overshoot-to-neighbor-column.md`
  (momentum overshoot to a *neighbor* column — different mechanism).
