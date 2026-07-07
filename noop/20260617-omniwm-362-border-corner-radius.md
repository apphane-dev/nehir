# OmniWM PR #362 — "Border corner radius matches real window radius (≈ #341)" — Discovery

Source PR: https://github.com/BarutSRB/OmniWM/pull/362
Merge state: **closed without merge** (per task triage/upstream state) —
evaluate the concept, not a verbatim patch.
Scope of this doc: determine whether nehir still hard-codes the focus-border
corner radius, and whether PR #362's proposed wiring should be ported.

All file/line references were verified against the Nehir source tree
at `904df02` ("Add bunch of discoveries mapped to issues from OmniWM"). Line
numbers drift — re-verify before implementing.

> **Filed under `discovery/noop/`** — nehir already implements the PR's root fix:
> the border manager queries `SkyLight.shared.cornerRadius(forWindowId:)`, passes
> that resolved value into `BorderWindow`, and redraws when the radius changes.
> Porting #362's `BorderWindow.Operations.cornerRadiusForWindow` hook would be a
> redundant architecture move, not a new repo action.

---

## TL;DR

- **The hard-coded-border-radius bug is already fixed in nehir.** Production
  focus-border updates resolve the target window's SkyLight corner radius before
  drawing; `BorderWindow` no longer has to invent the radius from its own hard
  coded constant.
- **Verdict:** 🟢 **Fixed.** The exact PR diff is absent, but nehir has the same
  root fix one layer earlier, plus tests for radius-change redraw and same-frame
  target switches.

## PR context (merge state + what the diff does)

- **State:** closed without merge (task triage says closed-without-merge).
- **Claim/symptom:** the focus border used a hard-coded `9.0` corner radius, so
  the border could visibly disagree with the real macOS window corner radius.
- **PR diff:** two files. In upstream `Sources/OmniWM/Core/Border/BorderWindow.swift`,
  the patch adds `Operations.cornerRadiusForWindow`, wires the live operation to
  `SkyLight.shared.cornerRadius(forWindowId:)`, stores a `resolvedCornerRadius`,
  redraws when it changes, and uses that value for the inner/outer rounded paths.
  In `Tests/OmniWMTests/BorderWindowTests.swift`, existing test operations are
  updated to provide `cornerRadiusForWindow: { _ in nil }`. The PR also changes
  the fallback from `9.0` to `10.0` when the SkyLight query is unavailable.

## Provenance: is this nehir's code?

Yes. The relevant border and SkyLight symbols exist in nehir:

- `BorderManager` owns the live corner-radius provider and caches the resolved
  value per target window (`Sources/Nehir/Core/Border/BorderManager.swift:14`,
  `Sources/Nehir/Core/Border/BorderManager.swift:22`,
  `Sources/Nehir/Core/Border/BorderManager.swift:132`).
- `BorderWindow.update(...)` accepts the resolved radius and draws both rounded
  paths from it (`Sources/Nehir/Core/Border/BorderWindow.swift:81`,
  `Sources/Nehir/Core/Border/BorderWindow.swift:163`).
- `SkyLight.cornerRadius(forWindowId:)` exists and queries WindowServer corner
  radii (`Sources/Nehir/Core/SkyLight/SkyLight.swift:287`).

## The code in question

### nehir queries the real window radius before updating the border

```swift
// Sources/Nehir/Core/Border/BorderManager.swift:19
init(
    config: BorderConfig = BorderConfig(),
    borderWindowOperations: BorderWindow.Operations = .live,
    cornerRadiusProvider: @escaping @MainActor (Int) -> CGFloat? = { SkyLight.shared.cornerRadius(forWindowId: $0) }
) {
    self.config = config
    self.borderWindowOperations = borderWindowOperations
    self.cornerRadiusProvider = cornerRadiusProvider
}

// Sources/Nehir/Core/Border/BorderManager.swift:70
let targetWid = UInt32(windowId)
let cornerRadius = resolvedCornerRadius(for: windowId)
...
guard borderWindow?.update(
    frame: frame,
    targetWid: targetWid,
    cornerRadius: cornerRadius,
    forceOrdering: forceOrdering
) == true else {
```

### The resolver uses SkyLight when available, then falls back

```swift
// Sources/Nehir/Core/Border/BorderManager.swift:132
private func resolvedCornerRadius(for windowId: Int) -> CGFloat {
    if cachedCornerRadiusWindowId == windowId, let cachedCornerRadius {
        return cachedCornerRadius
    }

    let cornerRadius = max(cornerRadiusProvider(windowId) ?? defaultCornerRadius, 0)
    cachedCornerRadiusWindowId = windowId
    cachedCornerRadius = cornerRadius
    return cornerRadius
}
```

The only material difference from PR #362 is fallback value: nehir's
`defaultCornerRadius` is still `9.0` (`Sources/Nehir/Core/Border/BorderManager.swift:17`),
while the PR chose `10.0` when the SkyLight query returns `nil`.

### BorderWindow redraws and draws from the supplied radius

```swift
// Sources/Nehir/Core/Border/BorderWindow.swift:77
@discardableResult
func update(
    frame targetFrame: CGRect,
    targetWid: UInt32,
    cornerRadius: CGFloat = 9.0,
    forceOrdering: Bool = false
) -> Bool {
    let borderWidth = config.width
    let scale = operations.backingScaleForFrame(targetFrame)
    let resolvedCornerRadius = max(cornerRadius, 0)
    ...
    if currentCornerRadius != resolvedCornerRadius {
        needsRedraw = true
    }
    ...
    currentCornerRadius = resolvedCornerRadius

// Sources/Nehir/Core/Border/BorderWindow.swift:162
let borderWidth = config.width
let cornerRadius = currentCornerRadius
let outerRadius = cornerRadius + borderWidth
...
let innerPath = CGPath(
    roundedRect: innerRect,
    cornerWidth: cornerRadius,
    cornerHeight: cornerRadius,
    transform: nil
)
...
let outerPath = CGPath(
    roundedRect: drawingBounds,
    cornerWidth: outerRadius,
    cornerHeight: outerRadius,
    transform: nil
)
```

### SkyLight already exposes the PR's intended API

```swift
// Sources/Nehir/Core/SkyLight/SkyLight.swift:287
func cornerRadius(forWindowId wid: Int) -> CGFloat? {
    guard let windowIteratorGetCornerRadii else { return nil }
    let cid = getMainConnectionID()
    guard cid != 0 else { return nil }
    ...
    guard windowIteratorGetCount(iterator) > 0,
          windowIteratorAdvance(iterator),
          let radii = windowIteratorGetCornerRadii(iterator),
          CFArrayGetCount(radii) > 0
    else {
        return nil
    }
    ...
    guard radius >= 0 else { return nil }
    return CGFloat(radius)
}
```

## Why this is already fixed in nehir

1. **The production path is not hard-coded.** `BorderManager.updateFocusedWindow`
   resolves a per-window radius at `BorderManager.swift:71` and passes it into
   `BorderWindow.update` at `BorderManager.swift:88`-`BorderManager.swift:92`.
   That is the same root concept as #362, just owned by the manager instead of
   by `BorderWindow.Operations`.
2. **The drawing code consumes that resolved value.** `BorderWindow` marks the
   border dirty when `currentCornerRadius` changes (`BorderWindow.swift:121`-
   `BorderWindow.swift:127`) and uses it for both inner and outer rounded paths
   (`BorderWindow.swift:162`-`BorderWindow.swift:188`).
3. **The WindowServer query exists and is wired into the live default.** The live
   provider calls `SkyLight.shared.cornerRadius(forWindowId:)` at
   `BorderManager.swift:22`, and the SkyLight implementation returns the first
   non-negative WindowServer corner radius at `SkyLight.swift:287`-`SkyLight.swift:318`.
4. **Tests cover the behavior #362 needs.** `radiusChangeRedrawsWithoutReshape`
   proves changing the supplied radius redraws without reshaping
   (`Tests/NehirTests/BorderWindowTests.swift:104`-`Tests/NehirTests/BorderWindowTests.swift:135`),
   and `sameFrameDifferentTargetWithDifferentRadiusRedraws` proves manager-level
   same-frame target switches query distinct radii and redraw when they differ
   (`Tests/NehirTests/BorderWindowTests.swift:224`-`Tests/NehirTests/BorderWindowTests.swift:269`).

The remaining mismatch is only the nil-query fallback (`9.0` in nehir vs `10.0`
in #362). That is not the reported root bug when SkyLight returns a radius, and
changing it is a cosmetic policy choice rather than a unique port action for this
closed PR.

## Recommendation

Do **not** port PR #362. Keep nehir's manager-owned provider/caching design. If a
future runtime report proves `SkyLight.cornerRadius(forWindowId:)` returns `nil`
on supported macOS versions and the one-point fallback is visible, handle that as
a separate small policy cleanup (likely changing `BorderManager.defaultCornerRadius`
and `BorderWindow`'s test-only defaults together), not as a #362 port.
