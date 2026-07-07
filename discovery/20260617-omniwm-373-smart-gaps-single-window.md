# OmniWM issue #373 — "Smart gaps (remove gaps with single window)" — Discovery

Groom 2026-07-07: in flight — a plan exists (planned/20260621-omniwm-373-smart-gaps-single-window.md); no smart-gaps/single-window outer-gap removal yet (verified against main 7a025b78).

Source issue: <https://github.com/BarutSRB/OmniWM/issues/373>
Scope of this doc: determine whether nehir already removes gaps for a
single-window workspace ("smart gaps"), and if not, scope the action nehir would
own to implement it.

All file/line references were verified against the Nehir source tree
at `904df02` ("Add bunch of discoveries mapped to issues from OmniWM"). Re-verify
before implementing; line numbers drift.

---

## TL;DR

- **nehir does not implement smart gaps.** A single window already has no
  *inner* gaps (those are between windows), but the **outer** gaps remain: the
  lone-window layout fills the gap-insetted working frame, not the screen
  edge-to-edge. There is no `smartGaps` / `gaps_when_only` setting.
- **Verdict:** 🔴 **Open — owns a new action.** Add a toggle that drops outer
  gaps (and optionally the focus border) when a workspace has exactly one normal
  tiled window, restoring them when a second appears. The existing
  `singleWindowLayoutContext` is the natural gate; the change is localized to
  working-frame + outer-gap resolution on the single-window layout path.

## Issue context

- **State:** open (feature request, triaged High-meaningfulness, "clearly
  specified with concrete config shape").
- **Requested behavior (verbatim):**
  - "When workspace has a single visible window: remove inner and outer gaps,
    window fills working area"
  - "When a second window is added: restore configured gap values"
  - "Configurable per-workspace or global toggle in settings.toml"
  - Optional: smooth animation; optionally hide the border with a single window.
- **Prior art cited:** Hyprland `gaps_when_only = 0` (per-workspace), i3
  `smart_gaps on`, MangoWM, yabai (manual signals).

## Provenance: is this nehir's code?

Yes. The relevant machinery all exists; only the gap-suppression rule is missing:

- **Single-window detection already exists.**
  `NiriLayoutEngine.singleWindowLayoutContext(in:)`
  (`Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine.swift:258`) returns a context
  iff the workspace has exactly one non-tabbed column with exactly one
  `.normal`-sized window. This is precisely the "single visible window"
  predicate #373 needs.
- **A lone-window policy already exists — but it is about width, not gaps.**
  `loneWindowPolicy: LoneWindowPolicy = .fill`
  (`NiriLayoutEngine.swift:148`), resolved per workspace
  (`effectiveLoneWindowPolicy(in:)`, `NiriLayoutEngine+Monitors.swift:89`):
  `.fill` (maxWidthFraction 1.0) or `.centered(maxWidthFraction)`. `.fill` makes
  the lone window span the full *column* width — within the already-gapped
  working frame — so outer gaps still surround it.
- **Outer gaps are applied at working-frame construction.**
  `WMController.insetWorkingFrame(from:scale:reservedTopInset:outerGaps:)`
  (`Sources/Nehir/Core/Controller/WMController.swift:761`) builds the working
  area by turning outer gaps into `Struts` (`WMController.swift:764`); the
  per-monitor entry `insetWorkingFrame(for:)` (`WMController.swift:747`) feeds
  `outerGaps(for: monitor)`. Passing `outerGaps: .zero` removes them while
  keeping the workspace-bar top inset.
- **The single-window layout path consumes that gapped frame.**
  `layoutSingleWindowWorkspace(...)`
  (`Sources/Nehir/Core/Layout/Niri/NiriLayout.swift:862`) calls
  `singleWindowViewportGeometry(for:in:workingFrame:containingFrame:scale:gaps:)`
  (`NiriLayout.swift:871`) — i.e. the lone window is sized *inside* `workingFrame`
  and the per-window horizontal gap, so outer gaps are honored, not removed.
- **Settings + gap-change plumbing exist.** `LayoutGaps`
  (`Sources/Nehir/Core/Layout/Niri/InteractiveResize.swift:105`), per-monitor
  `MonitorGapSettings.outerGaps` (`Sources/Nehir/Core/Config/MonitorGapSettings.swift:47`),
  `WorkspaceManager.setOuterGaps(...)`/`setGaps(to:)`
  (`Sources/Nehir/Core/Workspace/WorkspaceManager.swift:2397`/`:2390`), and
  `ServiceLifecycleManager.handleGapsChanged()` (`:207`). New booleans land
  alongside the existing gap fields in `SettingsExport`/`SettingsStore`/
  `CanonicalTOMLConfig` (where `mouseWarpAxis`, `focusFollowsMouse`, etc. live).

## The code in question

**Single-window detection (the gate to reuse):**

```swift
// Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine.swift:258
func singleWindowLayoutContext(in workspaceId: WorkspaceDescriptor.ID) -> SingleWindowLayoutContext? {
    let maxWidthFraction: Double = switch effectiveLoneWindowPolicy(in: workspaceId) {
    case .fill: 1.0
    case let .centered(maxWidthFraction): maxWidthFraction
    }
    let workspaceColumns = columns(in: workspaceId)
    guard workspaceColumns.count == 1,
          let column = workspaceColumns.first,
          !column.isTabbed
    else { return nil }
    let windows = column.windowNodes
    guard windows.count == 1,
          let window = windows.first,
          window.sizingMode == .normal
    else { return nil }
    return SingleWindowLayoutContext(container: column, window: window, maxWidthFraction: maxWidthFraction)
}
```

**Where the layout plan is built for a pass (the site to override outer gaps +
working frame):**

```swift
// Sources/Nehir/Core/Controller/NiriLayoutHandler.swift:296  (buildOnDemandLayoutPlan)
let gaps = LayoutGaps(
    horizontal: snapshot.gap,
    vertical: snapshot.gap,
    outer: snapshot.outerGaps                 // ← outer gaps for the pass
)
let area = WorkingAreaContext(
    workingFrame: snapshot.monitor.workingFrame,   // ← already gapped (see insetWorkingFrame)
    ...
)
```

**Where outer gaps become screen insets:**

```swift
// Sources/Nehir/Core/Controller/WMController.swift:761
func insetWorkingFrame(from frame: CGRect, scale: CGFloat = 2.0,
                       reservedTopInset: CGFloat = 0,
                       outerGaps: LayoutGaps.OuterGaps? = nil) -> CGRect {
    let outer = outerGaps ?? workspaceManager.outerGaps
    let struts = Struts(left: outer.left, right: outer.right,
                        top: outer.top + reservedTopInset, bottom: outer.bottom)
    return computeWorkingArea(parentArea: frame, scale: scale, struts: struts)
}
```

## Why this is Open (and the action is well-scoped)

1. **The feature is genuinely absent.** No `smartGaps` / `gaps_when_only` /
   `smart_gaps` symbol exists anywhere in `Sources/`. The lone-window `.fill`
   policy controls column *width fraction*, not gap removal; the working frame
   is always inset by the configured outer gaps before the single window is
   placed (`NiriLayout.swift:871` consumes `workingFrame`).
2. **Inner gaps already behave correctly.** With one window there are no
   between-window gaps, so #373's "remove inner gaps" half is already satisfied
   by construction. Only the **outer** gap removal is new work.
3. **The implementation is localized and low-risk.** Reuse
   `singleWindowLayoutContext(in:)` as the predicate. On the single-window layout
   path, when the new toggle is on, resolve the working frame with
   `outerGaps: .zero` (keeping the bar top inset — pass `.zero` explicitly so the
   struts leave only `reservedTopInset`) and pass `outer: .zero` into the pass's
   `LayoutGaps`. Concretely, gate at `buildOnDemandLayoutPlan`
   (`NiriLayoutHandler.swift:296`) and/or at `insetWorkingFrame(for:)`
   (`WMController.swift:747`) using the engine's single-window predicate for that
   workspace. Adding the second window naturally restores the normal
   (multi-window) layout path with full gaps — no extra restore logic needed.
4. **It composes with the existing lone-window policy.** Smart gaps (outer-gap
   removal) is orthogonal to `.fill` vs `.centered`; a centered lone window could
   still optionally drop outer gaps, though the common case is `.fill` + smart
   gaps = edge-to-edge.

## Recommendation

**Implement smart gaps as a new, owned action.** Suggested shape (mirrors the
existing gap config style):

- Add a boolean, e.g. `removeOuterGapsOnSingleWindow: Bool` (default `false`),
  to `SettingsExport` / `SettingsStore` / `CanonicalTOMLConfig` (global first;
  the per-monitor `MonitorGapSettings`/per-workspace layering can follow if
  requested). Expose it in `LayoutSettingsTab`
  (`Sources/Nehir/UI/LayoutSettingsTab.swift`).
- In the layout pass, when the toggle is on **and**
  `engine.singleWindowLayoutContext(in: wsId) != nil`, resolve the working frame
  with `outerGaps: .zero` and feed `LayoutGaps(outer: .zero)`; otherwise behave
  exactly as today. Because the working frame is currently pre-computed per
  monitor (`snapshot.monitor.workingFrame`), the cleanest hook is to recompute it
  on demand for the single-window case at `buildOnDemandLayoutPlan`
  (`NiriLayoutHandler.swift:296`) rather than mutating the cached monitor frame.
- Route through `handleGapsChanged()` / the existing relayout path so the
  add-a-second-window transition relayouts with full gaps automatically (it
  already will, since the predicate flips to nil).
- Optional follow-ups (separate toggles, not blockers): hide the focus border on
  a lone smart-gaps window (`FocusBorderController`), and animate the
  gapped↔gapless transition (the viewport-offset animation infra already exists).

## Suggested tests

- One `.normal` window in a workspace, `removeOuterGapsOnSingleWindow = true`,
  non-zero outer gaps configured: assert the lone window's frame equals the
  monitor working area inset by **only** the bar top inset (outer gaps == 0 on
  left/right/bottom), i.e. edge-to-edge horizontally.
- Same workspace, add a second window: assert both windows are laid out with the
  configured outer **and** inner gaps restored (predicate nil → normal path).
- Toggle off mid-session with one window: assert outer gaps reappear on the next
  relayout without a restart (settings change → relayout).
- `loneWindowPolicy = .centered(0.8)` + smart gaps on: assert centering is
  preserved and outer gaps are removed (the two features compose, not collide).
