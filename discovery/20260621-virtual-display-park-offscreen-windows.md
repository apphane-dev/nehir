# Virtual display to park offscreen windows without bleed — Discovery

Idea (from the backlog fan-out): instead of parking hidden windows just past a real
monitor's edge (where macOS silently clamps them back and leaves a visible strip), create a
**virtual display** that has no physical screen and park hidden windows fully inside its
frame. Because the parked coordinates are then "on a display" rather than "off all
displays," the hope is that WindowServer's offscreen-position clamp never triggers, and the
window is guaranteed invisible — no edge strip, no corner, no cross-monitor bleed.

All code citations were verified against the main Nehir source tree at `56573ba2`
("Fix focus-follows-mouse blocked by click-through overlays (#64)"). Re-verify before
implementing; line numbers drift. No trace logs are referenced; every runtime claim is
either inlined as a quoted value or sourced from `docs/offscreen-clamp-fix.md`, which is a
durable repo document.

---

## TL;DR

- **The problem this attacks is real and currently unsolved.** Nehir does not truly hide
  external app windows; it **positionally parks** them just past a monitor edge, leaving a
  deliberate 1px reveal (`LayoutRefreshController.swift:108`
  `hiddenWindowEdgeRevealEpsilon: CGFloat = 1.0`). macOS silently rejects fully-offscreen
  positions: `AXUIElementSetAttributeValue(kAXPositionAttribute)` returns `.success` but
  clamps the window back so ~40px horizontally / ~34px vertically stays visible, detected
  downstream as `.verificationMismatch` (`AXWindow.swift:58`, `:430`). Nehir's own
  `docs/offscreen-clamp-fix.md` records **sixteen** attempted hide primitives — AX retries,
  resize-to-1×1, `kAXMinimizedAttribute`, `SLSSetWindowOpacity`, `SkyLight.orderWindow`,
  `y=-10000` vertical push, `SLSWindowSetShape`, `SLSTransactionOrderWindow`/`SLSOrderWindow`
  with `kCGSOrderOut`, `SLSSetWindowTransform`, explicit 1px edge parking — and concludes:
  *"The core problem remains: macOS clamps both axes and no tested API can order out
  external app windows. We are still looking for a working solution."*
- **A virtual display is a genuinely new (17th) direction, not in the failure table.** All
  sixteen failed approaches tried to move windows **out of** display space. A virtual
  display creates **new** display space to park windows **into**. The central hypothesis —
  untested — is that macOS only clamps windows that fall *outside the union of all display
  frames*; if the parked coordinates lie inside a (virtual) display's frame, the clamp's
  trigger condition is never met and the window can be parked fully, anywhere inside that
  frame, with arbitrary margin and zero bleed.
- **It is architecturally consistent with Nehir.** Nehir is **not sandboxed**
  (`Nehir.entitlements` contains only `com.apple.security.automation.apple-events`), targets
  **macOS 15** (`Package.swift`), and already `dlopen`s a private framework — SkyLight —
  with `fatalError` on missing symbols (`Sources/Nehir/Core/SkyLight/SkyLight.swift` init).
  `CGVirtualDisplay` is a private CoreGraphics class loaded the same way; no new
  distribution posture is required.
- **It does NOT replace the reconciliation work.** The documented bleed bugs are caused by
  Nehir *skipping or never issuing* the park (stale hidden-state bits, transition-gated
  reconciliation), not by the clamp. A virtual display changes **where** an accepted park
  lands, not **whether** a park is issued. The sibling reconciliation fixes
  (`discovery/20260616-workspace-inactive-stale-live-frame.md`,
  `discovery/20260616-stale-live-frame-on-stably-hidden-column.md`,
  `noop/20260616-omniwm-235-window-bleed-different-workspace.md`) are mandatory regardless.
- **Verdict: 🟡 Defer implementation; run a bounded feasibility spike first.** The spike is
  cheap and high-value because it tests whether the virtual-display concept defeats the
  documented root blocker (the clamp). If the spike confirms clamp avoidance, escalate to a
  full design; if the clamp still triggers (or a new clamp appears at virtual-display
  boundaries), drop it. Ship the reconciliation fixes independently and first.

---

## Relationship to prior work (do not duplicate)

This idea sits at the intersection of three existing discovery clusters. Each owns a
distinct slice; this doc owns only the **virtual-display park target** and must not absorb
their work:

- **The stale-live-frame / bleed family.**
  `discovery/20260616-workspace-inactive-stale-live-frame.md`,
  `discovery/20260616-stale-live-frame-on-stably-hidden-column.md`, and
  `noop/20260616-omniwm-235-window-bleed-different-workspace.md` own the **Nehir-internal**
  half of the bleed: a window whose metadata says `hidden` but whose live AX frame is still
  on-screen, because `hideWorkspace` (`LayoutRefreshController.swift:2238`) skips
  already-hidden windows and the live-AX reconciliation in `resolveHideOperation`
  (`LayoutRefreshController.swift:2549`) is `layoutTransient`-only. Those fixes are about
  *issuing* the park. The virtual display is about *where the park lands once issued* and
  *whether macOS accepts it fully*. Complementary, not overlapping.
- **The cross-monitor geometry half.** `noop/20260616-omniwm-349-hidden-window-bleeds-multi-monitor.md`
  and `noop/20260616-omniwm-364-clamp-visible-frames-monitor-bounds.md` establish that the
  *visible-tiled-frame* overhang is already prevented by
  `overflowEdgeIntersectingNeighboringMonitor` (`NiriLayout.swift:385`/`:413`) and that
  hidden windows are parked by the overlap-minimising `HiddenWindowPlacementResolver`
  (`Sources/Nehir/Core/Layout/SideHiding.swift:78`). Those mitigate *which real edge* a
  hidden window bleeds onto; they cannot make a parked window invisible because the clamp
  still leaves a strip. A virtual display removes the real-edge dependency entirely.
- **The clamp failure log.** `docs/offscreen-clamp-fix.md` (repo document, not a planning
  doc) is the authoritative record of the macOS clamp and the sixteen failed approaches.
  This doc treats it as ground truth and proposes the virtual display as approach #17.
- **Separate-Spaces topology.** `discovery/20260618-displays-separate-spaces-mode-detection.md`
  is directly relevant to a *risk*, not a dependency: under "Displays have separate Spaces"
  ON, a virtual display would acquire its own Space, which Nehir does not model today.

No prior planning doc proposes a virtual display; `ffgrep` for `virtual`, `CGVirtualDisplay`,
`phantom`, `dummyDisplay`, `fakeMonitor` across `discovery/ planned/ completed/ noop/` and
across `Sources/` returns nothing. This is a new proposal.

---

## What the idea means for Nehir

Nehir's entire window-hiding strategy is **positional**: a hidden window is never ordered
out or minimized; it is moved to coordinates just past a monitor edge so most of it hangs
offscreen. The mechanism is in `HiddenWindowPlacementResolver.physicalScreenEdgeOrigin`
(`Sources/Nehir/Core/Layout/SideHiding.swift:78`):

```swift
// SideHiding.swift:89-99
func origin(for side: HideSide, y: CGFloat) -> CGPoint {
    switch side {
    case .left:
        CGPoint(x: monitor.frame.minX - size.width + reveal, y: y)
    case .right:
        CGPoint(x: monitor.frame.maxX - reveal, y: y)
    }
}
```

For a `.right` park, the window's left edge lands at `monitor.frame.maxX - reveal` (≈1px
inside the right edge) and its body extends rightward into whatever global coordinates lie
beyond the monitor. On a single display that is offscreen; on a side-by-side multi-monitor
arrangement it lands on the neighbour — the #349 bleed, which the overlap-minimising
resolver (`SideHiding.swift` `overlapArea` / `verticalParkingCandidates`) tries to avoid by
picking the least-overlapping edge and vertical lane.

This strategy has a structural ceiling imposed by macOS: a window moved **fully** offscreen
(outside every display frame) is silently clamped back to leave a visible remnant. So Nehir
is forced to park *almost* offscreen with the 1px reveal, and even that is not reliable —
the `liveFrameHideOrigin` `.layoutTransient` branch carries this comment
(`LayoutRefreshController.swift`, the block beginning at `:2774`):

> *"Mitigation: explicit 1pt parking on the physical screen edge. This improves the common
> non-Dock-edge case, but it is not a complete WindowServer hide primitive and must not be
> described as universally reliable. Prior 1px parking through the normal placement path
> still produced stuck visible strips for wide windows."*

The virtual-display idea changes the park **target** from "just past a real edge" to "fully
inside a virtual display's frame." If macOS's clamp only fires when a window leaves the
union of all display frames, then parking inside a virtual display is immune to the clamp,
and Nehir gains a true positional hide: the window is on a known display (so the app and
WindowServer treat it as live and ordered-in — preserving AX observers and fast workspace
re-show) yet invisible (no physical screen renders it). The 1px reveal epsilon becomes
unnecessary; the parked window can sit at the centre of a large virtual frame with
thousands of pixels of margin on every side, so even large park-write drift is harmless.

---

## Current behavior (with source citations)

1. **Parking is positional, via AX position/size writes and SkyLight moves.**
   `AXWindowService.setFrame` writes `kAXPositionAttribute` / `kAXSizeAttribute`
   (`Sources/Nehir/Core/Ax/AXWindow.swift:328-329`, set at `:378`, attribute writes at
   `:408-420`); `SkyLight.batchMoveWindows` / `transactionMove` drive
   `SLSTransactionMoveWindowWithGroup` (`SkyLight.swift`). Both operate in **global screen
   coordinate space** — there is no per-window "displayId assignment" that constrains
   parking. A window's display is *derived* from where its frame lands
   (`ReconcileSnapshot.swift:85` `displayId`, `Monitor.swift`
   `CGPoint.monitorApproximation(in:)`).

2. **Hidden windows are NOT ordered out.** `grep` for `orderOut` / `kAXHiddenAttribute` /
   `kAXMinimizedAttribute` across `Sources/Nehir/Core/` shows `orderOut` only on Nehir's own
   windows (`DragGhostWindow.swift:71`, `NativeFullscreenPlaceholderManager.swift:209`/`:228`)
   — never on external app windows. `SkyLight.transactionHide` exists
   (`SkyLight.swift`, `transactionOrderWindow(transaction, wid, 0, 0)`) but is used for
   Nehir's own border/overlay windows. `docs/offscreen-clamp-fix.md` confirms why:
   `SLSTransactionOrderWindow`/`SLSOrderWindow` with `kCGSOrderOut` (mode 1) are *silently
   ignored* for windows owned by other processes (`isWindowOrderedIn` stays `true` after the
   call). External app windows cannot be ordered out by Nehir.

3. **The park leaves a deliberate 1px reveal.** `hiddenWindowEdgeRevealEpsilon = 1.0`
   (`LayoutRefreshController.swift:108`), used by `physicalScreenEdgeOrigin`
   (`SideHiding.swift:78`, reveal computed at `:81`) and by `liveFrameHideOrigin`
   (`LayoutRefreshController.swift:2720`, `:2774`). The workspace-inactive /
   scratchpad case resolves through `physicalScreenEdgeOrigin`
   (`LayoutRefreshController.swift:2728`).

4. **Fully-offscreen parks are silently clamped by macOS.** From
   `docs/offscreen-clamp-fix.md` (durable repo document, inlined verbatim):

   > *"macOS clamps both horizontal and vertical positions of a full-size window that would
   > be moved completely offscreen. Instead of accepting the target coordinate, WindowServer
   > parks the window so that approximately 40 pixels remain visible horizontally and ~34
   > pixels vertically at the display edge. This is invisible to the caller:
   > `AXUIElementSetAttributeValue(kAXPositionAttribute)` returns `.success`, but a
   > subsequent readback of `kAXPositionAttribute` reveals the clamped position."*

   Concrete inlined example from that doc: layout requested `target={{-1712.0, 8.0},
   {852.0, 1068.0}}` (fully offscreen left); WindowServer clamped to
   `observed={{-812.0, 8.0}, {852.0, 1068.0}}`, i.e. `-812 + 852 = 40px` visible. A
   right-edge target `x=3448` on a 1720-wide screen was clamped to `x=1688` (40px visible);
   a vertical target `y=-10000` was clamped to `y≈-1034` (34px visible). Nehir detects this
   as `.verificationMismatch` when the observed frame differs from the target beyond a 1.0pt
   tolerance (`AXWindow.swift:58`, `:430`). The doc's headline conclusion: *"Neither axis
   can be used to push a full-size window completely offscreen on macOS."*

5. **Display tracking is via `NSScreen.screens`.** `Monitor.current()`
   (`Sources/Nehir/Core/Monitor/Monitor.swift:27`) enumerates `NSScreen.screens` and reads
   each screen's `displayId` (`Monitor.swift:104`). Changes arrive as
   `NSApplication.didChangeScreenParametersNotification`, debounced 100ms in
   `DisplayConfigurationObserver` (`Sources/Nehir/Core/Monitor/DisplayConfigurationObserver.swift`,
   `debounceInterval = 100_000_000`). A virtual display would appear in `NSScreen.screens`
   and fire this notification on create/destroy — so Nehir's existing plumbing would *see*
   it, which is part of the risk (it must be excluded from layout/focus/mouse-warp).

---

## The core hypothesis (untested)

**Hypothesis H1:** macOS's offscreen-position clamp fires iff the target frame lies
**outside the union of all display frames** (i.e. the window would be "completely
offscreen" relative to *every* display, real or virtual). If a `CGVirtualDisplay` is
positioned adjacent to the real monitor arrangement so that its frame contains the park
coordinates, the clamp's trigger condition is not met and WindowServer accepts the full
offscreen-relative-to-real-monitors position.

If H1 holds, a virtual display of, say, 2560×1600 placed at global coordinates far from any
real monitor (e.g. `origin.x = realMaxX + 100`) would let Nehir park any hidden window at
the *centre* of that frame. The window would be:

- fully inside a display's frame → no clamp → no 1px reveal needed → no edge/corner strip;
- on a display with no physical screen → invisible to the user;
- still "ordered in" on a known display → AX observers, focus state, and fast workspace
  re-show all behave as they do today (the current positional park already relies on the
  window staying live).

If H1 is **false** — e.g. macOS also clamps windows whose only covering display is virtual,
or clamps at virtual-display boundaries, or treats `CGVirtualDisplay` frames differently
from real ones in the clamp path — then the idea fails for the same reason the sixteen
prior approaches did, and should be dropped.

H1 is the single gateable unknown. It cannot be settled by reading source or by a unit test
(`docs/offscreen-clamp-fix.md` is emphatic: *"Private WindowServer/SkyLight/AX behavior
cannot be proven by coordinate math or unit tests… Unconfirmed hypotheses are not fixes."*).
It requires a runtime spike.

---

## Where / how it would be implemented (if the spike confirms H1)

Sketch only — not a plan until the spike passes. Symbols and files are named so a future
implementer has anchors; none of this is proposed for the docs-only branch.

1. **Load `CGVirtualDisplay` the same way SkyLight is loaded.** A new
   `Sources/Nehir/Core/Monitor/VirtualParkDisplay.swift` would `dlopen`
   `/System/Library/PrivateFrameworks/CoreGraphics.framework/CoreGraphics` (or
   `ApplicationServices`) and `dlsym` the `CGVirtualDisplay` / `CGVirtualDisplaySettings` /
   `CGVirtualDisplayMode` Objective-C class symbols, mirroring the
   `resolveRequired`/`resolveOptional` + `unsafeBitCast` pattern in `SkyLight.swift`'s
   `init`. The header shape is documented in the CoreGraphics private headers
   (`@interface CGVirtualDisplay`, `CGVirtualDisplaySettings.hiDPI`, `CGVirtualDisplayMode`
   with width/height/refresh). Lifecycle: create on app launch (or lazily on first hide),
   retain for app lifetime, release on termination.

2. **Expose the virtual display's `CGDirectDisplayID` and global frame** to the layout/hide
   layer as a non-targetable "park display." Because `Monitor.current()` reads
   `NSScreen.screens` (`Monitor.swift:27`), the virtual display would show up there too;
   `WorkspaceManager.monitors` and every consumer (layout, mouse-warp, new-window
   placement) must **exclude it by identity**. Concretely: tag the virtual display's
   `Monitor.ID` as `isParkDisplay` and filter it wherever real monitors are enumerated for
   user-facing behaviour.

3. **Add a new park origin resolver path.** Extend `liveFrameHideOrigin`
   (`LayoutRefreshController.swift:2710`) and/or `HiddenWindowPlacementResolver`
   (`SideHiding.swift`) with a `.parkDisplay` variant that returns an origin centred (with
   margin) inside the virtual display's frame, instead of the screen-edge origin. Gate it
   behind a setting or a feature flag so the current edge-park remains the fallback if the
   virtual display is unavailable.

4. **Preserve verification.** The existing `.verificationMismatch` check
   (`AXWindow.swift:430`) and `hidePlan.verify` tracing
   (`LayoutRefreshController.swift:2497`) become the *proof* that the clamp is avoided:
   after parking on the virtual display, `observed` should equal `target` to within
   tolerance. A persistent `verificationMismatch` under the virtual-display park is direct
   evidence that H1 is false.

5. **Hard exclusion surfaces (safety).** Every path that could place, focus, or move the
   cursor to a display must reject the park display:
   - **New-window admission** — macOS may open new windows on the virtual display; Nehir's
     admission/reconciliation must relocate any window whose frame lands in the park
     display back to a real monitor.
   - **Focus / FFM / app switcher** — a hidden window that receives focus (notifications,
     `NSWorkspace.activate`, app switcher) must not leave the cursor stranded on an
     invisible display; `MouseWarpHandler` (`Sources/Nehir/Core/Controller/MouseWarpHandler.swift`)
     must never warp there.
   - **Restore / reveal** — `executeHiddenReveal` and `restoreWindowFromHiddenState`
     (`LayoutRefreshController.swift`) must move the window back to a real monitor before
     unhiding; the proportional-restore pitfalls in `docs/offscreen-clamp-fix.md` (§
     "Restore Path for Tiled Windows") apply.
   - **Diagnostics** — `DisplayEnvironmentDiagnostics`
     (`Sources/Nehir/Core/Monitor/DisplayEnvironmentDiagnostics.swift`) and the monitors
     dump must not report the park display as a user monitor.

---

## Risks and unknowns

1. **H1 is unverified (the dominant unknown).** If macOS clamps at virtual-display
   boundaries too, the idea is dead. This must be settled by a runtime spike before any
   design work. Per `docs/offscreen-clamp-fix.md`, a positive result requires live AX
   readback showing `observed == target` (no clamp) for both narrow and wide windows parked
   inside the virtual frame, plus visual confirmation of no strip on any real display.

2. **Phantom display is user-visible and system-visible.** A `CGVirtualDisplay` appears in
   System Settings → Displays and in every display-enumerating consumer: Mission Control,
   Stage Manager, Spaces, screen-recorder/screen-share apps, menu-bar tools, BetterDisplay.
   Users will see an extra display they did not add. This is a real UX cost and a support
   burden, independent of correctness.

3. **Spaces topology interaction.** Under "Displays have separate Spaces" ON
   (`discovery/20260618-displays-separate-spaces-mode-detection.md`), a virtual display
   gains its own Space. Nehir has **no per-window Space model** today; a park-display Space
   would be unmodelled state. Stage Manager / Mission Control may also surface it. The
   separate-spaces discovery's open work (Space topology) becomes a prerequisite, not a
   sibling, if this idea is pursued.

4. **Safety surface is large and easy to get wrong.** New-window placement, focus, cursor
   warp, and restore must all exclude the park display (see §5 above). A single miss leaves
   a window or the cursor stranded on an invisible display — arguably worse than the
   current 1px strip, because it is invisible to diagnose.

5. **Private-API stability.** `CGVirtualDisplay` is undocumented. It has been stable enough
   for BetterDisplay, DeskPad, and Chromium across many macOS releases, and Nehir already
   depends on private SkyLight symbols with `fatalError`, so this is consistent with the
   existing posture rather than a new class of risk — but every macOS major version is a
   re-verification point.

6. **Performance / power.** A virtual display has a backing store; whether it consumes GPU
   when idle (no client reading frames) is reported to be low by "dummy display" tools but
   is not proven for Nehir's always-on lifecycle. A minimal static mode (low refresh, no
   HiDPI) should be chosen and measured.

7. **It does not fix the reconciliation root causes.** The documented bleed
   (`workspace-inactive-stale-live-frame`, `stale-live-frame-on-stably-hidden-column`,
   OmniWM #235) happens when Nehir **skips or never issues** the park. A virtual display
   only changes where an *accepted* park lands. The reconciliation fixes in those sibling
   docs are mandatory and orthogonal; shipping a virtual display without them would still
   bleed (the window would stay on the real display because it was never moved).

8. **Multi-monitor arrangement guidance becomes moot — or conflicts.** `docs/offscreen-clamp-fix.md`
   currently recommends arranging monitors **vertically** to keep parking edges away from
   neighbours. If the park target is a virtual display, that workaround is unnecessary; but
   the virtual display's own global placement must avoid overlapping real monitors, and
   must track the real arrangement as it changes (`DisplayConfigurationObserver`).

---

## Open questions

1. **Does H1 hold?** Does macOS clamp a window whose only covering display is a
   `CGVirtualDisplay`, or only windows outside *all* display frames? (Settled only by
   spike.)
2. **Does the clamp behave the same for windows straddling a virtual/real boundary?**
   (i.e. is "fully inside the virtual display" the only safe region, or is "any part inside
   the virtual display" enough?)
3. **Does creating/destroying the virtual display disrupt the user's real arrangement?**
   Specifically, does it shift the primary display, reset Spaces, or trigger a visible
   reconfiguration flash?
4. **How do apps behave when their window is "on" a display with no physical screen?** Do
   any pause rendering, auto-minimize, or relocate themselves (which would defeat the
   park)? `docs/offscreen-clamp-fix.md` notes some apps reposition on resize; the same risk
   applies to display membership.
5. **Is `CGVirtualDisplay` permitted under Nehir's signing/notarization?** Nehir already
   ships private SkyLight usage via `dlsym`, which strongly suggests yes, but a notarized
   build smoke test is required before release (mirrors the open question in
   `discovery/20260618-displays-separate-spaces-mode-detection.md`).
6. **Should the park display be created eagerly at launch or lazily on first hide?** Lazy
   minimises the always-on UX/perf footprint; eager simplifies the layout path.

---

## Recommendation

**🟡 Defer full implementation; run a bounded feasibility spike; ship the reconciliation
fixes independently and first.**

Rationale, in priority order:

1. **The reconciliation fixes are cheaper, lower-risk, and mandatory regardless.** They
   close the documented bleed family directly by ensuring the park is actually *issued*
   (stop skipping already-hidden windows in `hideWorkspace` at `LayoutRefreshController.swift:2238`;
   generalise the `layoutTransient`-only reconciliation in `resolveHideOperation` at
   `:2549`). These must ship whether or not the virtual display ever lands. Do those first.

2. **The virtual display is the most promising untried direction for the *other* half of
   the problem — the macOS clamp ceiling** — but its central claim (H1) is unverified and
   unverifiable without a runtime test. A bounded spike is the right next step, not a full
   design. The spike:
   - `dlopen`/`dlsym` `CGVirtualDisplay` exactly as SkyLight is loaded.
   - Create one small virtual display placed adjacent to the real arrangement.
   - Park one test window (try both a narrow and a wide window) at the centre of the
     virtual frame via the existing `AXWindowService.setFrame` path.
   - Read back `kAXPositionAttribute` and assert `observed == target` to within the existing
     1.0pt tolerance (`AXWindow.swift:430`). No `verificationMismatch` ⇒ H1 holds. Any clamp
     ⇒ H1 is false; record it in `docs/offscreen-clamp-fix.md` as approach #17 and stop.
   - Visually confirm no strip on any real display (per the doc's "must confirm manually"
     rule).

3. **Escalate to a full design only if the spike passes.** If H1 holds, the design must
   treat the park display as a first-class, identity-tagged, hard-excluded display across
   new-window admission, focus/FFM, mouse-warp, restore, and diagnostics (see §
   "Where / how"). The Spaces-topology prerequisite
   (`20260618-displays-separate-spaces-mode-detection.md`) should be revisited at that
   point.

4. **Do not promote any positional-hide claim to "fixed"/"solved" without runtime
   confirmation**, per the explicit pitfall in `docs/offscreen-clamp-fix.md`. A unit test
   can prove Nehir *requested* a virtual-display coordinate; it cannot prove macOS
   *rendered* the window hidden.

---

## Suggested validation (spike only — no repo source changes on this branch)

A spike is by definition a throwaway runtime experiment, not a unit test, and cannot be run
on the docs-only branch. When the spike is run against the main source tree, its pass
criteria are:

1. **Clamp avoidance (H1).** For a narrow window (~852px) and a wide window (~1600px),
   after `AXWindowService.setFrame` to a target at the centre of the virtual display's
   frame, the live AX readback equals the target within 1.0pt (no `.verificationMismatch`).
   Inline the concrete `target=` / `observed=` pairs into the follow-up doc.
2. **No real-display strip.** Visual confirmation that no pixels of the parked window
   appear on any real monitor, including during slow gesture approach, snap, and idle
   settle (the four scenarios `docs/offscreen-clamp-fix.md` requires).
3. **App stays live.** The parked window remains ordered-in and its AX frame remains
   readable (confirming the virtual display preserves the "live window" property the
   current positional park relies on).
4. **Arrangement stability.** Creating/destroying the virtual display does not disturb the
   user's real monitor arrangement or primary display.

If all four pass, open a `planned/` design doc that specifies the exclusion surface (§
"Where / how") and sequences behind the reconciliation fixes. If any fail, record the
failure with inlined evidence in `docs/offscreen-clamp-fix.md` and close this idea.
