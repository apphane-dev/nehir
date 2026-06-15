# FFM: Suppress focus-follows-mouse when hovering unmanaged overlay windows

Status: **implemented** — see `.changeset/20260615135853-fixed-ffm-stealing-focus-behind-ghostty-quick-terminal.md`. Implementation notes appended below.
Owner path: `Sources/Nehir/Core/Controller/{MouseEventHandler,WMController}.swift`

## TL;DR

Focus-follows-mouse (FFM) keeps stealing focus to the niri tile **behind**
Ghostty's Quick terminal while the pointer is over it, which obstructs clicks
in the Quick terminal. Root cause: the unmanaged-window occlusion check that is
supposed to make FFM bail out only considers **layer-0** windows, but Ghostty's
Quick terminal runs at `NSWindow.Level.floating` (CGWindowLayer = 3) once
settled and `.popUpMenu` (= 101) during its slide-in animation — both are
non-zero, so the Quick terminal is invisible to FFM suppression.

Fix: broaden the occlusion check so any **on-screen, non-tracked, non-desktop**
window (any non-negative layer, sized ≥ 80×80) counts as "unmanaged window
covers pointer". This realises the user's rule verbatim:

> FFM should never have effect if the user is hovering a window that isn't part
> of the niri layout.

## How the bug manifests

1. User opens Ghostty Quick terminal → it slides in, becomes key window.
2. User moves the pointer over it.
3. `MouseEventHandler.handleMouseMovedFromTap` → `handleFocusFollowsMouse(at:)`
   (`MouseEventHandler.swift:1147`).
4. `resolveFocusFollowsMouseTarget(at:)` (`MouseEventHandler.swift:1216`) runs
   three occlusion guards:
   - `isFloatingWindowCoveringPointer` — only checks **Nehir-managed floating**
     entries; Ghostty is not managed.
   - `hasVisibleFloatingWindowOverNiriLayout` — same, managed only.
   - `controller.unmanagedWindowServerWindowCovers(point:)` — **this is the one
     that should catch Ghostty, but it returns `false`** because of the
     `layer == 0` filter (see below).
5. All three guards pass → `engine.hitTestFocusableWindow(point:in:)` finds the
   niri tile behind the Quick terminal → `activateFocusFollowsMouseTarget` →
   `niriLayoutHandler.activateNode(...)` changes AX focus to that tile on every
   mouse-move.
6. Focus is yanked away from the Quick terminal, so subsequent clicks land in
   the wrong place / the terminal loses key status. ⇒ "obstructs my clicks".

## Root cause (with citations)

`Sources/Nehir/Core/Controller/WMController.swift:2335`

```swift
static func visibleUnmanagedWindowServerFrames(
    trackedWindowIds: Set<Int> = []
) -> [CGRect] {
    guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) ...
    return windows.compactMap { info -> CGRect? in
        ...
        let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
        guard layer == 0 else { return nil }          // ← THE BUG (WMController.swift:2347)
        ...
        // width >= 80, height >= 80, isOnscreen
    }
}

func unmanagedWindowServerWindowCovers(point: CGPoint) -> Bool {
    let trackedWindowIds = Set(workspaceManager.trackedWindowIdsForDebug())
    return unmanagedWindowServerFramesProvider(trackedWindowIds).contains { $0.contains(point) }
}
```

`trackedWindowIds` are window-server IDs of **Nehir-managed** app windows
(`WorkspaceManager.trackedWindowIdsForDebug()` at `WorkspaceManager.swift:391`).
So this function means: "is there an on-screen, layer-0, ≥80px window under the
pointer that Nehir does not manage?"

The `layer == 0` restriction was introduced in `385f0e3` ("Fix mouse cursor
behavior with moveMouseToFocusedWindow enabled") with no recorded rationale.
It was almost certainly chosen to avoid counting the menu bar / dock / status
items / tooltips (which live at higher layers). It also happens to exclude
Ghostty's deliberate overlay levels.

### Confirmation: Ghostty's Quick terminal levels

From `ghostty/macos/Sources/Features/QuickTerminal/QuickTerminalController.swift`,
`animateWindowIn`:

```swift
// We need to set our window level to a high value. In testing, only
// popUpMenu and above do what we want. This gets it above the menu bar
// and lets us render off screen.
window.level = .popUpMenu          // CGWindowLayer == 101 (during slide-in)
// ...completionHandler, after animating in:
window.level = .floating           // CGWindowLayer == 3 (settled/visible)
```

`animateWindowOut` resets back to `.popUpMenu` while sliding out. So the Quick
terminal is **never at layer 0** while it is on screen. Nehir never sees it.

### Second call site (same bug)

`MouseEventHandler.markRecentFloatingPointerInteractionIfNeeded(at:)`
(`MouseEventHandler.swift:1284`) also calls `unmanagedWindowServerWindowCovers`
to set a 2-second FFM suppression window when the user interacts with an
unmanaged window. Because the Quick terminal is undetected, clicks on it do not
earn the 2 s suppression either — compounding the obstruction. Both call sites
are fixed by fixing the one function.

## Proposed change

**Primary fix (minimal, low-risk):** replace the hard `layer == 0` requirement
with "any non-desktop layer", i.e. `layer >= 0` (equivalently, drop the guard —
the desktop/wallpaper lives at `kCGDesktopWindowLevel`, a large **negative**
value, so it is already excluded; keeping `layer >= 0` makes the intent
explicit).

`WMController.swift:2347` (and the duplicated predicate at `:2383` in
`visibleUnmanagedWindowServerDebugDump`):

```swift
// was: guard layer == 0 else { return nil }
guard layer >= 0 else { return nil }   // include overlay levels (floating/popup/…)
```

Keep all existing filters: `isOnscreen`, `width >= 80`, `height >= 80`, and the
`!trackedWindowIds.contains(windowId)` carve-out.

### Why `layer >= 0` is safe (and an improvement)

Positive-layer on-screen windows that newly count as "unmanaged covers pointer":

| Window type | Layer | Effect of including |
|---|---|---|
| Ghostty Quick terminal | 3 / 101 | **the bug fix** |
| Other dropdown/overlay terminals & app "spotlight" panes | 3 / 25 / 101 | correct — FFM should not fire through them |
| Nehir's own status/workspace bars (`.popup`) | not in `trackedWindowIds` | harmless — pointer is already over Nehir UI; `shouldBlockOwnWindowInput` handles clicks there; suppressing FFM over the bar is desirable |
| Dock / menu bar / status items | 20 / 24 / 25 | harmless/desirable — FFM should not fire when aiming at them |
| Fullscreen app | guarded earlier | `handleFocusFollowsMouse` already bails via `isAppFullscreenActive` |
| Screen saver | 1000 | harmless — only on screen when locked, and `isInputSuppressed` handles lock screen |

There is no positive-layer, on-screen, ≥80px window under which we would *want*
FFM to fire through to the tile behind. So the broadening cannot introduce a
"FFM wrongly suppressed over a real tile" regression; it can only *add*
suppression in places it was already supposed to apply.

The one residual edge case (pre-existing, not new): a large, always-on-screen,
visually-transparent overlay at a positive layer that geometrically overlaps a
visible tile would suppress FFM across that region. CGWindowList cannot tell us
per-pixel opacity, and the same risk already exists for layer-0 transparent
windows today — so it is out of scope for this fix. See "Follow-up" below for
the more-correct z-order formulation that removes even this theoretical concern.

### Testability gap to close

The existing FFM tests bypass the layer logic entirely by overriding the whole
provider:

```swift
controller.unmanagedWindowServerWindowFramesProvider = { _ in [unmanagedFrame] }
// Tests/NehirTests/MouseEventHandlerTests.swift:2315  (and :102)
```

That keeps the "Ghostty is invisible" regression untested. To test the real
`layer` predicate we need to inject the window-list source (today
`CGWindowListCopyWindowInfo` is called directly inside the static function):

1. Introduce a provider closure, e.g.
   `var windowServerSnapshotProvider: @MainActor () -> [[String: Any]]`
   defaulting to `{ CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? [] }`.
2. Refactor `visibleUnmanagedWindowServerFrames(trackedWindowIds:)` (or a new
   `unmanagedFramesCovering(point:trackedWindowIds:)` helper) to consume that
   snapshot instead of calling the CG API directly. Keep the existing
   `unmanagedWindowServerWindowFramesProvider` indirection so current tests stay
   green, or migrate them to the snapshot form.
3. Add a regression test feeding a synthetic snapshot with a Ghostty-like entry
   (`kCGWindowLayer == 3`, not in `trackedWindowIds`, ≥80px, on-screen) covering
   the pointer and assert `unmanagedWindowServerWindowCovers(point:) == true`
   and that `focusFollowsMouse...` does not change focus.

## Tests to add / extend

In `Tests/NehirTests/MouseEventHandlerTests.swift`:

- **New** `focusFollowsMouseSuppressesOverUnmanagedOverlayWindow` — pointer over
  a non-tracked, layer-3 (and a second variant layer-101) window above a tile;
  assert `confirmedManagedFocusToken` stays on the previously-focused tile and
  `activeFocusRequestToken` stays nil. (Mirror of
  `focusFollowsMouseDoesNotActivateTiledWindowBehindUnmanagedWindow` at line
  2258, but driven through the real layer predicate via the injected snapshot.)
- **New** unit test on `WMController.unmanagedWindowServerWindowCovers` /
  helper: synthetic snapshot with layer ∈ {0, 3, 101, 25, 1000} all covering the
  point → all return `true`; desktop (negative layer) entry → ignored.

## Files touched

- `Sources/Nehir/Core/Controller/WMController.swift` — change `layer == 0` →
  `layer >= 0` in two spots (`:2347`, `:2383`); add injectable window-server
  snapshot provider; (optionally) extract `unmanagedFramesCovering(...)`
  helper.
- `Sources/Nehir/Core/Controller/MouseEventHandler.swift` — no logic change
  needed (both call sites already go through `unmanagedWindowServerWindowCovers`).
- `Tests/NehirTests/MouseEventHandlerTests.swift` — add overlay-layer FFM
  regression test + unit test of the layer predicate.
- `.changeset/<timestamp>-fixed-ffm-stealing-focus-behind-ghostty-quick-terminal.md`
  — `patch`, summarising the user-visible fix.

## Follow-up (optional, out of scope for this fix)

- **Z-order occlusion.** Rewrite `unmanagedWindowServerWindowCovers(point:)` to
  take the **topmost** on-screen window whose bounds contain the point (CGWindowList
  is returned front-to-back) and suppress only when that topmost window is not
  tracked. This is strictly more correct than "any unmanaged window covers the
  point" (handles transparent always-on-top helpers and avoids false
  suppression when a tracked tile is actually in front), and subsumes this fix.
  Tracked separately to keep this change small and reviewable.
- The `layer == 0` restriction also appears in `AXManager.swift:462` (app
  discovery) and `LayoutRefreshController` (`windowLevel` handling). Those are
  unrelated to FFM and should **not** be changed here; call out in review.

## Implementation notes (post-merge follow-on fixes)

After landing the original `layer >= 0` broadening, three issues surfaced in
real use and were fixed against the same occlusion predicate. Captured here so
the user-facing changeset can stay short.

### 1. Exclude Nehir's own pass-through surfaces (the focus border)

Broadening to `layer >= 0` made Nehir's own `BorderWindow` (layer 3, sized to
the focused tile + padding, registered as a `.border` / `.passthrough` surface)
count as an unmanaged occluder — suppressing FFM (and, later, gestures) over the
very tile the border decorates. Fix: surface-coordinator now exposes
`passthroughSurfaceWindowNumbers` (`SurfaceScene` → `SurfaceCoordinator` →
`OwnedWindowRegistry`), and `unmanagedWindowServerWindowCovers(point:)` unions
those numbers into the exclusion set alongside tracked window IDs. The debug
dump uses the same exclusion. Regression tests:
`focusFollowsMouseActivatesTileBehindOwnPassthroughBorder`,
`trackpadGestureStillCommitsOverOwnPassthroughBorder`.

Note (reviewed, deliberately not implemented): a proposal to make
`passthroughSurfaceWindowNumbers` fall back to the live `NSWindow.windowNumber`
when `node.windowNumber` is nil is unnecessary — the border is the only
`.passthrough` surface, is `NSWindow`-less (SkyLight-native, window-number
only), and its registration is gated on a resolved non-zero window number
(`BorderManager.syncSurfaceRegistration`). The fallback could never fire.

### 2. Suppress trackpad gestures over the same overlays

The trackpad column-navigation gesture (`handleGestureEvent`) observes the
system gesture tap, which is `.listenOnly` and always passes the event through —
the OS already routes the scroll/touch to the window under the cursor. Nehir's
own column-nav side effect should not fire against the tile *behind* an overlay,
for the same reason FFM shouldn't. Added a mirror of the FFM occlusion guard
right after the existing `shouldBlockOwnWindowInput` guard; it reuses
`unmanagedWindowServerWindowCovers`, so the pass-through-border exclusion comes
for free. Regression tests: `trackpadGestureSuppressesOverUnmanagedOverlayWindow`,
`trackpadGestureStillCommitsOverOwnPassthroughBorder`,
`trackpadGestureIgnoresSystemNotificationWindow`.

### 3. System chrome / Notification Center freeze (the real regression)

When a system notification (e.g. Telegram) appears, the Notification Center
window (`com.apple.notificationcenterui`, full-screen 2056×1329, layer 0,
`.accessory` activation policy) becomes on-screen and covers the entire
display. With the guard from #2 in place, it occluded the pointer everywhere →
every trackpad gesture frame was aborted → gestures froze completely while any
notification was visible. This was the bug behind the “I can’t move at all”
trace.

Fix: the occlusion predicate now only counts windows owned by `.regular`
activation-policy apps (real foreground overlays like Ghostty). System chrome —
Notification Center, Dock, Control Center, menu-bar/status items — runs at
`.accessory` / `.prohibited` policy and is a full-screen transparent event
surface, so it is excluded. The owner-policy resolver is injectable
(`windowOwnerActivationPolicyProvider`) for tests; an unresolvable owner
(synthetic snapshot without an owner PID) is treated as regular so the check
stays conservative. Regression tests:
`visibleUnmanagedWindowServerFramesExcludesSystemChrome`,
`trackpadGestureIgnoresSystemNotificationWindow`.

### 4. Test hardening

`visibleUnmanagedWindowServerFramesIncludesOverlayLayers` originally asserted
only `frames.count == 5` with all windows sharing one frame — a swapped window
ID would pass. Each accepted window now carries a distinct (id-derived) frame,
and the assertion pins both count and the exact surviving frame set
(`Set(frames) == expectedFrames`).

### Design note: occlusion cost on the hot path

Both the FFM evaluation (per mouse-move) and the gesture guard (per gesture
frame) now resolve `unmanagedWindowServerWindowCovers(point:)`, which calls the
snapshot provider (default: a synchronous `CGWindowListCopyWindowInfo`) and runs
the static predicate. Traces during heavy pointer activity showed notable
main-thread load (see `mouseMove.replay staleQueued` churn with
`moveMouseToFocusedWindow` enabled). If this proves expensive in practice, the
next step is to throttle/cache the snapshot (recompute ≤ ~100 ms) rather than
re-fetching per event. Not yet implemented — noted as a candidate follow-up.
