# BarutSRB/OmniWM#216 — "Niri animation when scrolling to the right is somehow broken" — Discovery

Source issue: <https://github.com/BarutSRB/OmniWM/issues/216>
Scope of this doc: determine whether the reported Niri right-scroll animation
bug applies to nehir, and whether the closed upstream item owns any repo action.

All file/line references were verified against the Nehir source tree
at `904df02` ("Add bunch of discoveries mapped to issues from OmniWM").
Re-verify before implementing; line numbers drift.

---

> **Filed under `discovery/noop/`** — nehir already renders right-edge partial
> reveals from the same animated viewport offset as every other column. Upstream
> closed BarutSRB/OmniWM#216 as `not_planned` during the v0.4.8 cleanup and did not merge or
> propose a code fix to port. This item therefore owns **no new repo action**;
> porting a separate right-edge special case would regress nehir's single
> animated-viewport invariant.

## TL;DR

- **The BarutSRB/OmniWM#216 symptom is structurally prevented in nehir: the rightmost partially
  visible column is not pre-positioned independently; every column is transformed
  by the same sampled `viewOffsetPixels.value(at:)`.**
- The keyboard focus path named by the issue (`focusUpOrRight` / right focus)
  reaches `ensureSelectionVisible`, preserves the absolute viewport while changing
  active columns, then calls `scrollToReveal`; `scrollToReveal` animates one
  viewport offset with `animateToOffset`.
- Existing layout tests lock in the important edge behavior: an open right-edge
  partial reveal remains visible (`partialRevealRemainsVisibleWhenViewportEdgeHasNoNeighboringMonitor`),
  and a render-offset reveal is not kept at its final position while animating.
- **Verdict:** 🟢 **Fixed / not present.** This validates the catalog's
  `validate?` note as a no-op result: nehir's current Niri viewport model already
  avoids the reported right-scroll animation split, and BarutSRB/OmniWM#216 has no upstream diff
  or distinct invariant to port.

## Provenance: is this nehir's code?

Yes. The Niri focus, viewport, animation, and render symbols
that BarutSRB/OmniWM#216 depends on all exist in nehir:

- Keyboard right-focus entry point: `focusUpOrRight` —
  `Sources/Nehir/Core/Layout/Niri/NiriNavigation.swift:340`.
- Focus visibility repair: `ensureSelectionVisible` —
  `Sources/Nehir/Core/Layout/Niri/NiriNavigation.swift:174`.
- Viewport reveal/scroll commands: `scrollViewport` and `scrollToReveal` —
  `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+ViewportCommands.swift:5` and
  `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+ViewportCommands.swift:62`.
- Animated viewport storage: `ViewOffset.spring` / `ViewOffset.value(at:)` —
  `Sources/Nehir/Core/Layout/Niri/ViewportState.swift:56-80`.
- Niri layout sampling of the animated offset: `calculateLayoutInto` —
  `Sources/Nehir/Core/Layout/Niri/NiriLayout.swift:241-264`.

## Upstream issue summary

Filed 2026-04-09 by `flschulz` against OmniWM/OmniWM 0.4.7.2. The report says
that when using Niri keyboard focus shortcuts to scroll right, columns that are
fully visible after the animation move correctly, but the rightmost column that
is only partially visible at the end looks as if it were already at its final
position: the window to its left moves away from it instead of the right-edge
partial sliding in. Reproduction: open 5+ windows on a screen that can show three
full 33%-width windows plus part of the next one, then scroll slowly right.

There was no suggested fix in the issue. The GitHub page records
`state: CLOSED`, `stateReason: NOT_PLANNED`, and BarutSRB's 2026-05-05 cleanup
comment: closing because the conversation predates v0.4.8, with a request to
comment if it still reproduces on v0.4.8 or newer.

## The code in question

### 1. Keyboard right focus reaches one viewport animation

```swift
// Sources/Nehir/Core/Layout/Niri/NiriNavigation.swift:340-357
func focusUpOrRight(
    currentSelection: NiriNode,
    in workspaceId: WorkspaceDescriptor.ID,
    motion: MotionSnapshot,
    state: inout ViewportState,
    workingFrame: CGRect,
    gaps: CGFloat
) -> NiriNode? {
    focusCombined(
        verticalDirection: .up,
        horizontalDirection: .right,
        currentSelection: currentSelection,
        in: workspaceId,
        motion: motion,
        state: &state,
        workingFrame: workingFrame,
        gaps: gaps
    )
}
```

`ensureSelectionVisible` changes the active column but preserves the absolute
viewport position by offsetting the view offset by `oldActivePos - newActivePos`,
then asks `scrollToReveal` for the target snap:

```swift
// Sources/Nehir/Core/Layout/Niri/NiriNavigation.swift:199-224
let oldActivePos = previousActiveContainerPosition
    ?? state.containerPosition(at: state.activeColumnIndex, containers: containers,
                               gap: gaps, sizeKeyPath: sizeKeyPath)
let newActivePos = state.containerPosition(at: targetIdx, containers: containers,
                                           gap: gaps, sizeKeyPath: sizeKeyPath)
let offsetDelta = oldActivePos - newActivePos
state.viewOffsetPixels.offset(delta: Double(offsetDelta))

state.activeColumnIndex = targetIdx
...
scrollToReveal(columnIndex: targetIdx, isFFM: false, state: &state, ...)
```

```swift
// Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+ViewportCommands.swift:117-123
guard let targetSnap else { return false }
let targetOffset = context.targetOffset(for: targetSnap, in: state)
let pixel = 1.0 / max(scale, 1.0)
guard abs(targetOffset - state.viewOffsetPixels.target()) > pixel else { return false }

state.animateToOffset(targetOffset, motion: motion, config: animationConfig, scale: scale)
return true
```

### 2. The animation is one spring value, not per-edge placement

```swift
// Sources/Nehir/Core/Layout/Niri/ViewportState+Animation.swift:79-90
let currentOffset = viewOffsetPixels.current()
let velocity = viewOffsetPixels.currentVelocity()

let animation = SpringAnimation(
    from: Double(currentOffset),
    to: Double(offset),
    initialVelocity: velocity,
    startTime: now,
    config: config ?? springConfig,
    displayRefreshRate: displayRefreshRate
)
viewOffsetPixels = .spring(animation)
```

```swift
// Sources/Nehir/Core/Layout/Niri/ViewportState.swift:72-80
func value(at time: TimeInterval) -> CGFloat {
    switch self {
    case let .static(offset): offset
    case let .gesture(g): CGFloat(g.value(at: time))
    case let .spring(anim): CGFloat(anim.value(at: time))
    }
}
```

### 3. Layout applies that sampled viewport to every container

```swift
// Sources/Nehir/Core/Layout/Niri/NiriLayout.swift:241-264
let viewOffset = state.viewOffsetPixels.value(at: time)
let activeIdx = state.activeColumnIndex.clamped(to: 0 ... max(0, containers.count - 1))
let activePos = containers.isEmpty ? 0 : containerPositions[activeIdx]
let viewPos = activePos + viewOffset

for idx in 0 ..< containers.count {
    let containerPos = containerPositions[idx]
    let containerSpan = containerSpans[idx]
    let renderOffset = containerRenderOffsets[idx]
    let canonicalContainerRect = canonicalContainerRect(...)
    let visibilityRect = visibleRenderedContainerRect(
        canonicalRect: canonicalContainerRect,
        viewPosition: viewPos,
        workspaceOffset: workspaceOffset,
        renderOffset: renderOffset,
        scale: effectiveScale,
        orientation: orientation
    )
```

For horizontal Niri, the visible rect is just the canonical rect translated by
`-viewPosition` (plus any independent column render offset used by column-add /
remove animations):

```swift
// Sources/Nehir/Core/Layout/Niri/NiriLayout.swift:333-354
private func visibleRenderedContainerRect(...) -> CGRect {
    let translation: CGPoint = switch orientation {
    case .horizontal:
        CGPoint(x: -viewPosition + workspaceOffset + renderOffset.x,
                y: renderOffset.y)
    case .vertical:
        CGPoint(x: workspaceOffset + renderOffset.x,
                y: -viewPosition + renderOffset.y)
    }
    return canonicalRect.offsetBy(dx: translation.x, dy: translation.y)
        .roundedToPhysicalPixels(scale: scale)
}
```

### 4. The open-edge partial reveal is already covered

A non-intersecting right-edge column is parked offscreen with only a pixel
sliver (`hiddenColumnRect`), but once it intersects the viewport it is rendered
from the same `visibilityRect` above, not from its final snap target:

```swift
// Sources/Nehir/Core/Layout/Niri/NiriLayout.swift:371-387
if !containerIntersectsViewport(renderedRect, viewportFrame: viewportFrame, orientation: orientation) {
    return .hidden(defaultHideEdge)
}
...
return .visible
```

```swift
// Sources/Nehir/Core/Layout/Niri/NiriLayout.swift:1208-1217
let edgeReveal = 1.0 / max(1.0, scale)
let x: CGFloat
switch edge {
case .minimum: x = edgeFrame.minX - width + edgeReveal
case .maximum: x = edgeFrame.maxX - edgeReveal
}
return CGRect(origin: CGPoint(x: x, y: screenY), size: CGSize(width: width, height: height))
```

The open desktop edge behavior is tested directly:

```swift
// Tests/NehirTests/NiriLayoutEngineTests.swift:6195-6212
var partialRevealState = hiddenState
partialRevealState.viewOffsetPixels = .static(40)
let partialRevealLayout = engine.calculateCombinedLayoutUsingPools(...)
...
#expect(partialRevealLayout.hiddenHandles[revealedWindow.token] == nil)
#expect(partialFrame.minX < monitor.visibleFrame.maxX)
#expect(partialFrame.maxX > monitor.visibleFrame.maxX)
```

And column render-offset animation is likewise tested to become a real partial
frame on the open right edge while still mid-animation:

```swift
// Tests/NehirTests/NiriLayoutEngineTests.swift:6269-6296
revealedColumn.animateMoveFrom(displacement: CGPoint(x: -40, y: 0), ...)
...
#expect(revealedColumn.renderOffset(at: animatedTime).x < -8)
#expect(animatedLayout.hiddenHandles[revealedWindow.token] == nil)
#expect(partialFrame.minX < monitor.visibleFrame.maxX)
#expect(partialFrame.maxX > monitor.visibleFrame.maxX)
```

## Why this doesn't apply

BarutSRB/OmniWM#216 requires the entering right-edge partial column to be rendered from a
position different from the rest of the strip — effectively at its final end
position while the fully visible columns still animate. nehir's current Niri
layout has no such separate target for the rightmost partial: `scrollToReveal`
sets one target offset (`NiriLayoutEngine+ViewportCommands.swift:117-123`),
`animateToOffset` stores one spring (`ViewportState+Animation.swift:79-90`), and
layout samples that spring once per frame before applying the same `viewPos` to
every container (`NiriLayout.swift:241-264`, `NiriLayout.swift:333-354`).

The only right-edge special case is offscreen parking for containers that do not
intersect the viewport yet (`NiriLayout.swift:371-387`, `NiriLayout.swift:1208-1217`).
That is not the BarutSRB/OmniWM#216 failure mode: on an open desktop edge, nehir has tests that
prove a partially revealed right-edge column is a normal visible frame, not a
hidden handle or final-position placeholder (`NiriLayoutEngineTests.swift:6195-6212`,
`NiriLayoutEngineTests.swift:6269-6296`). Neighboring-monitor cases intentionally
keep partial overflow hidden until fully contained to prevent cross-monitor bleed;
that is a separate hidden-placement policy, not a right-scroll animation bug.

## Recommendation

Do not port anything for BarutSRB/OmniWM#216. The upstream issue was closed as `not_planned`
without a fix, and nehir already has the relevant invariant: one animated
viewport offset drives every column, including the rightmost partial reveal.
If the symptom is ever reported against nehir with a concrete monitor topology,
treat it as a new runtime bug and capture a focused regression test; BarutSRB/OmniWM#216 itself
owns no new action.
