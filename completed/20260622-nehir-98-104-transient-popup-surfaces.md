# Nehir issues #98 and #104 — transient popup surfaces — Completed

Completed in main source commit `da7192cb` (`Keep transient popup surfaces out of managed activation`).

Related issues:

- #98 — browser datalist / suggestion popups reposition the browser window.
- #104 — Dock and other native/contextual popup menus close immediately after opening.
- #96 — qutebrowser frameless-window focused-border work that originally motivated careful handling of nonstandard AX window shapes.

## Summary

Two symptoms shared the same underlying class of surface: short-lived native / WindowServer popup surfaces that are visible enough to be discovered as windows, but should not be treated like ordinary managed app windows.

The fix has two parts:

1. **Keep floating-tagged non-document WindowServer popup surfaces out of tiled layout decisions.**
   `Sources/Nehir/Core/Rules/WindowRuleEngine.swift` now detects AX-complete windows whose WindowServer tags include the floating bit and do not include the document bit. These surfaces receive a built-in fallback floating decision named `transientWindowServerSurface` before broad user rules can force them into tiling. User rule side effects such as workspace assignment and min-size effects are preserved on the decision.
2. **Do not activate transient floating creates.**
   `Sources/Nehir/Core/Controller/AXEventHandler.swift` now gates floating-create activation side effects through `shouldActivateFloatingCreate`. If `managedReplacementMetadata.transientWindowServerEvidence` is true, Nehir still tracks the entry for lifecycle bookkeeping, but skips the focus-policy lease, immediate floating frame application, and `raiseFloatingWindow` call.

A patch changeset was added for #98 and #104 with reporters `syepes` and `dagrlx` credited.

## Evidence that shaped the fix

### #98 browser suggestion popup

The raw user attachment from #98 showed Vivaldi datalist popup surfaces being admitted as tiled windows because a broad user rule matched the browser bundle. The relevant self-contained facts from the runtime evidence were:

- Bundle: `com.vivaldi.Vivaldi`.
- Create-time decision: `context=create`, `disposition=managed`, `source=userRule(C1F090E4-92D8-4BA6-A3E7-10DAF5382AAC)`, `outcome=trackedTiling`, `layout=explicitLayout`.
- AX shape: `axRole=AXWindow`, `axSubrole=AXUnknown`, `hasCloseButton=true`, `hasFullscreenButton=false`, `hasZoomButton=true`, `hasMinimizeButton=true`, with fullscreen-button fetch treated as missing.
- WindowServer shape: `wsLevel=101`, `wsTags=0x1000c2002`, `wsAttributes=0x3`, `wsParent=0`.
- Popup frames were small and suggestion-shaped, for example `(309.0,583.0,172.0,260.0)` and `(309.0,370.0,218.0,281.0)`.
- The create was immediately followed by `candidate_tracked` and `relayout_activated_window` for the popup token.
- Automatic reevaluation saw the same popup already in `existingMode=tiling` and still kept it tiled through the user rule.

The visible jump was explained by the popup entering the Niri tiled tree: a helper/suggestion surface becomes an additional tiled window, changing column/window counts and causing layout churn for the real browser window.

### #104 Dock and Telegram contextual/native menus

The Dock and Telegram runtime evidence showed popup/menu-like surfaces being classified as floating and then activated by Nehir at create time. The relevant facts were:

- Dock helper contextual menu surface:
  - Bundle: `com.apple.dock.helper`.
  - AX shape: `axRole=AXWindow`, `axSubrole=AXSystemDialog`.
  - Decision: `disposition=floating`, `outcome=trackedFloating`.
  - Follow-up create handling included tracking and focus/activation side effects.
- Telegram native popup surface:
  - Bundle: `ru.keepcoder.Telegram`.
  - AX shape: `axRole=AXWindow`, `axSubrole=AXDialog`.
  - Decision: `disposition=floating`, `outcome=trackedFloating`.
  - WindowServer evidence: `wsLevel=1000`, `wsTags=0x1000c2002`.
  - Follow-up create handling included `candidate_tracked` and `pending_focus_started`.

The important distinction from #98 is that these surfaces were not tiled; they were already floating. The bug was the activation path: forcing focus, raise, or immediate frame writes on native popup/menu surfaces can dismiss them as soon as they appear.

## Root-cause mechanics (#98)

This is the confirmed post-fix understanding of why the Vivaldi suggestion popup visibly moved the browser window. (Migrated from the original #98 discovery investigation.)

### Why the popup was admitted as tiled

The popup reported `axRole=AXWindow`, so it passed the top-level admission gate:

```swift
// Sources/Nehir/Core/Ax/AXWindow.swift
static func shouldTreatAsTopLevelWindow(role: String?, subrole: String?) -> Bool {
    role == kAXWindowRole as String || subrole == kAXStandardWindowSubrole as String
}
```

Once admitted, `WindowRuleEngine.decision` applied the broad user tile rule (`source=userRule(...)`) before any popup-specific suppression existed, so the popup landed in the tiled tree with `outcome=trackedTiling`. The fix inserts the `transientWindowServerSurface` floating branch ahead of that user-rule path so floating-tagged non-document WindowServer surfaces never reach tiling.

### Why the browser window visibly jumped (lone-window recenter loop)

`NiriNode.allWindows` is `columns.flatMap(\.(windowNodes))`, so a tracked popup counts as a real tiled window. The singleton-width path is explicit about clearing and re-seeding width overrides across a 1↔2 window transition:

```swift
// Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+Windows.swift
if root.allWindows.count == 1 {
    for column in root.columns where !column.hasManualSingleWindowWidthOverride {
        column.clearLoneWindowLayoutWidthOverride()
    }
}
```

```swift
// Sources/Nehir/Core/Layout/Niri/NiriLayout.swift — layoutSingleWindowWorkspace / prepareSingleWindowViewport
if context.container.hasManualSingleWindowWidthOverride {
    context.container.clearLoneWindowLayoutWidthOverride()
} else {
    context.container.loneWindowLayoutWidthOverride = geometry.rect.width
}
```

Reading these together: the suggestion popup appearing becomes a second tiled window (clearing the override) and disappearing returns the workspace to a single window (re-seeding the override). That is the re-center loop the issue describes — each suggestion cycle visibly moved the real browser window.

### Refresh coupling

Both create and destroy request a relayout pass:

```swift
// Sources/Nehir/Core/Controller/AXEventHandler.swift
controller.layoutRefreshController.requestRefresh(reason: .axWindowCreated, ...)
controller.layoutRefreshController.requestWindowRemoval(workspaceId:..., ...)
```

So a transient popup that was admitted as a tiled window perturbed the layout twice per suggestion cycle: once on appear, once on disappear.

## Relationship to #96 / qutebrowser frameless windows

The #96 plan/history showed that qutebrowser frameless top-level windows are legitimate app windows even though they can report unusual AX shapes such as `role=AXWindow`, `subrole=AXDialog`. That work argued against broad `AXDialog` rejection or broad dialog special-casing.

This fix deliberately avoids an AX-dialog-only rule. It uses WindowServer evidence instead:

- #98 suppression requires a floating WindowServer tag without the document tag and complete AX facts.
- #104 activation suppression uses persisted transient WindowServer evidence in `managedReplacementMetadata`.
- Degraded AX facts remain deferred instead of being prematurely classified from partial evidence.
- Parented but document-like or ordinary browser replacement surfaces remain covered by existing tests and behavior.

That means the qutebrowser lesson is preserved: nonstandard AX subroles alone are not enough to decide that a surface is disposable/transient.

## Code changes

- `Sources/Nehir/Core/Rules/WindowRuleEngine.swift`
  - Added `transientWindowServerSurfaceRuleName`.
  - Added a pre-user-explicit-layout branch for AX-complete, floating-tagged, non-document WindowServer surfaces.
  - Returns `.floating` as a fallback built-in decision while preserving matched user rule effects.

- `Sources/Nehir/Core/Controller/AXEventHandler.swift`
  - Added `shouldActivateFloatingCreate(_:trackedEntry:)`.
  - Uses that result to gate:
    - `focusPolicyEngine.beginLease(owner: .ruleCreatedFloatingWindow, ...)`
    - `scheduleFloatingCreateFrameApplication(...)`
    - `windowActionHandler.raiseFloatingWindow(...)`
  - Still records recent managed admission, captures floating geometry, schedules AX warmup, runs lifecycle verification when needed, and requests refresh as before.

- `.changeset/20260622095818-leave-dock-contextual-menus-unmanaged-so-right-c.md`
  - Patch release note covering #98 and #104.
  - Contributors: `syepes`, `dagrlx`.

## Tests added / adjusted after runtime confirmation

The user confirmed the runtime fix before regression tests were added.

- `Tests/NehirTests/WindowRuleEngineTests.swift`
  - Added `floatingTaggedPopupSurfaceOverridesBroadTileRule`.
  - Verifies a Vivaldi-like popup (`wsLevel=101`, `wsTags=0x1000c2002`, `AXUnknown`, missing fullscreen button) is kept floating despite a broad tile rule, while preserving workspace/min-size rule effects.

- `Tests/NehirTests/AXEventHandlerTests.swift`
  - Added `transientFloatingCreateDoesNotActivateOrApplyFrameImmediately`.
  - Verifies a transient floating create is tracked as floating, records transient evidence, does not start the rule-created-floating focus lease, and does not apply an immediate AX frame write.

- `Tests/NehirTests/MouseEventHandlerTests.swift`
  - Adjusted `focusFollowsMouseRefreshesAfterScrollAnimationSettles` to use a hit-testable non-focused Niri target instead of assuming the target center is inside the visible monitor frame. This fixed the full-suite failure seen after the runtime fix work.

## Validation

Commands run in the main source tree:

```bash
swift test --filter WindowRuleEngineTests
swift test --filter AXEventHandlerTests/transientFloatingCreateDoesNotActivateOrApplyFrameImmediately
swift test --filter MouseEventHandlerTests/focusFollowsMouseRefreshesAfterScrollAnimationSettles
mise run test
```

Final full-suite result:

- `1310 tests in 108 suites passed`.

## Related / sibling investigations

- `discovery/20260622-nehir-99-source-lone-window-recenter-after-move.md` — same lone-window machinery, inverse failure (still open at the time of writing).
- `completed/20260619-workspace-assignment-lone-window-width-and-reveal.md` — introduced the singleton-width override path this bug churned through.
- `completed/20260619-workspace-assignment-lone-window-width-cache-leak.md` — adjacent singleton-width cache behavior.

## Follow-up notes

- The #98 fix intentionally does not mark browser helper surfaces unmanaged. It keeps them floating and out of tiling; this preserves tracking/lifecycle behavior without perturbing the tiled layout.
- The #104 fix intentionally does not make a Dock-specific rule. Telegram demonstrated the same transient WindowServer surface class, so the generic activation suppression is safer and broader.
- Avoid future fixes that rely only on AX subrole names such as `AXDialog` or `AXSystemDialog`; those are too coarse and can include legitimate app windows.
- For runtime-bug work, wait for user confirmation of the real repro before adding or rewriting regression tests.
