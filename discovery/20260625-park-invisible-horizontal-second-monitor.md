# Parked-window invisibility on a horizontally-arranged 2nd monitor — Discovery

Discovery (2026-06-25). The maintainer's open interest, stated plainly, is:
**"placing windows parked so it isn't visible on 2nd monitor arranged horizontally."**
i.e. when two monitors sit **side-by-side** in macOS System Settings, Nehir's
hidden/"parked" windows bleed onto the neighbour monitor instead of disappearing.
This doc is the authoritative, sequenced picture of how to make a parked window
truly invisible in the horizontal-arrangement case, and what to do next.

All source references were verified against the main Nehir source tree at
`8887adcb` ("Fixup changeset reporter contribution mention") on 2026-06-25
(`git log -1 --format='%h %s'` → `8887adcb`). Line numbers drift; function names
are included so the code stays findable. No trace-log filenames are referenced;
every runtime claim is either inlined as a quoted value or sourced from the
durable repo document `docs/window-parking-and-offscreen-clamp.md`.

This doc is **strategy**, not a source change. It sits at the intersection of
three existing clusters and owns only the **horizontal-arrangement math + the
critical-path sequencing against in-flight work + the far-edge / Separate-Spaces
cheaper-alternative analysis + a concretely runnable virtual-display spike**.
It cross-links (does not copy) the prior work.

---

## TL;DR

- **Horizontal arrangement is the worst case because of a split in Nehir's own
  hide paths, not just the macOS clamp.** Nehir has two positional-hide paths.
  The **workspace-inactive / scratchpad** path (`physicalScreenEdgeOrigin`) runs
  an overlap-minimising resolver that, on a side-by-side layout, already picks
  the **outer** edge (no neighbour) — so it bleeds at most a small clamp strip
  onto its *own* monitor, not onto the 2nd monitor. The **layout-transient** path
  (`liveFrameHideOrigin` → the `physicalEdge1pt` override) parks on the
  **requested** edge and **ignores the overlap-minimising resolver** — so a
  column hidden towards the neighbour parks *onto* the neighbour, where it is
  fully visible (no clamp fires, because the coordinates are "on a display").
  **That transient-onto-neighbour park is the maintainer's visible-on-2nd-monitor
  symptom in its purest form.** (Worked math in §A.)

- **The reconciliation fixes were mandatory and mostly NOT about the clamp — and
  they have now shipped.** Current `main` contains the three prerequisite
  Nehir-internal fixes: inactive-workspace frame writes no longer defeat the
  inactive guard (`70ed2619`), inactive `.show` reveal and multi-monitor drift
  gaps are closed (`196dee9a`), and stale hidden-window live frames are
  reconciled for both workspace-inactive and stably-hidden `layoutTransient`
  cases (`07ce4168`). These fix the **Nehir-internal** half ("is the park issued
  and not undone?"). They do **not** defeat the macOS clamp, and they do **not**
  stop the transient path from parking onto the neighbour. So on a horizontal
  layout a correctly-issued edge-park can still leave a strip / a whole window on
  the 2nd monitor even after they land.

- **There is exactly one zero-cost mitigation that targets the horizontal case
  directly: arrange monitors vertically (the existing `docs/window-parking-and-offscreen-clamp.md`
  recommendation).** It converts "whole window on neighbour" into "~40px strip on
  own monitor." Two further cheap options are re-evaluated here for the
  horizontal case specifically (§D): **(a) force transient parks onto the outer
  edge** (kills neighbour bleed, leaves a ~15–40px clamp strip + a fly-across UX
  cost), and **(b) enable "Displays have separate Spaces"** — a free macOS toggle
  that, per a maintainer manual test recorded in
  `discovery/20260618-separate-spaces-and-monitor-arrangement.md`, isolated
  per-display rendering enough that parked windows did *not* appear on the 2nd
  monitor in horizontal arrangement. (b) is the most promising zero-code option
  but depends on Nehir's Separate-Spaces runtime support, which has matured
  (`SpaceTopology` is now landed) but is still runtime-unconfirmed for the
  transient-park case.

- **The only known path to *zero* bleed — including the transient-onto-neighbour
  case and the residual clamp strip — is the virtual display (approach #17).** It
  is gated on one unverified hypothesis (H1: macOS only clamps windows outside the
  *union of all display frames*; a window parked inside a virtual display's frame
  is immune). H1 cannot be settled by reading source; it needs a runtime spike.
  The maintainer **has a real horizontal 2-monitor host**, so the spike can
  actually be executed. §C turns it into a precise, minimal, throwaway recipe.

- **Verdict / sequencing:** ship the reconciliation fixes first and
  independently (in-flight + the two open ones); in parallel, (i) confirm the
  Separate-Spaces-ON behaviour at runtime (cheap, free toggle) and (ii) run the
  bounded virtual-display spike. Escalate to a full `planned/` design **only if
  H1 passes**. Until H1 passes (or Separate-Spaces-ON is runtime-confirmed for
  the transient case), **no doc may claim the horizontal-bleed is "fixed"** —
  per the explicit pitfall in `docs/window-parking-and-offscreen-clamp.md`.

---

## A. Why horizontal arrangements are the worst case for edge-parking

Nehir does not truly hide external app windows; it **positionally parks** them
just past a monitor edge. Two resolver paths compute that park origin, and they
disagree about *which edge* on a side-by-side layout.

### A.1 The shared epsilon and the macOS clamp ceiling

Both paths share `hiddenWindowEdgeRevealEpsilon`:

```swift
// Sources/Nehir/Core/Controller/LayoutRefreshController.swift:108
static let hiddenWindowEdgeRevealEpsilon: CGFloat = 1.0
```

and both are bounded above by the macOS offscreen-position clamp, inlined
verbatim from `docs/window-parking-and-offscreen-clamp.md`:

> macOS clamps both horizontal and vertical positions of a full-size window that
> would be moved completely offscreen. `AXUIElementSetAttributeValue(kAXPositionAttribute)`
> returns `.success`, but a subsequent readback reveals the clamped position.
> Concrete: a left-edge target `{{-1712.0, 8.0}, {852.0, 1068.0}}` was clamped to
> `{{-812.0, 8.0}, {852.0, 1068.0}}` → `-812 + 852 = 40px` visible. A right-edge
> target `x=3448` on a 1720-wide screen clamped to `x=1688` (40px). A vertical
> target `y=-10000` clamped to `y≈-1034` (34px).

Nehir detects this as `.verificationMismatch`
(`Sources/Nehir/Core/Ax/AXWindow.swift:58`, the check at `:459`:
`observedFrame.approximatelyEqual(to: frame, tolerance: 1.0) ? nil : .verificationMismatch`).
The clamp fires only when the window would be **completely offscreen** (outside
every display frame). This detail is the key to the horizontal case: a window
that lands *on* the neighbour monitor is never "offscreen," so the clamp never
fires — it simply sits there, fully visible.

### A.2 Path 1 — workspace-inactive / scratchpad: already picks the outer edge

The workspace-inactive and scratchpad reasons route through
`HiddenWindowPlacementResolver.physicalScreenEdgeOrigin`
(`Sources/Nehir/Core/Layout/SideHiding.swift:78`), via `liveFrameHideOrigin`
(`LayoutRefreshController.swift:2936`). The per-edge origin formula is:

```swift
// Sources/Nehir/Core/Layout/SideHiding.swift:89-99  (origin(for:y:) inside physicalScreenEdgeOrigin)
case .left:
    CGPoint(x: monitor.frame.minX - size.width + reveal, y: y)   // outer-left when monitor is leftmost
case .right:
    CGPoint(x: monitor.frame.maxX - reveal, y: y)                // outer-right when monitor is rightmost
```

Crucially, this resolver does **not** trust the requested side. It tries **both**
sides × several vertical lanes and commits the origin that minimises
`overlapArea` against every **other** monitor (`SideHiding.swift:266`,
`verticalParkingCandidates` at `:239`):

```swift
// physicalScreenEdgeOrigin body (SideHiding.swift:106-145, abridged)
for (sideIndex, side) in sides.enumerated() {            // sides = [requestedSide, alternateSide]
    for y in yCandidates {
        let candidateOrigin = origin(for: side, y: y)
        let overlap = overlapArea(for: CGRect(origin: candidateOrigin, size: size),
                                  monitor: monitor, monitors: monitors)
        // ...minimise overlap, then lane-penalty, then distance, then prefer requested side
    }
}
```

`overlapArea` (`SideHiding.swift:266`) sums the intersection area with every
`other.id != monitor.id`. So on a side-by-side layout, parking towards the
neighbour yields a large overlap and parking towards the **outer** edge (no
neighbour) yields zero overlap — the resolver picks the outer edge. **Workspace-
inactive windows therefore do not bleed onto the neighbour monitor on a
horizontal layout; they bleed, at worst, a clamp strip onto their *own* monitor.**

### A.3 Path 2 — layout-transient: parks on the *requested* edge, ignores the resolver

The transient path (columns scrolled offscreen within the **active** workspace)
is different. `liveFrameHideOrigin` for `.layoutTransient`
(`LayoutRefreshController.swift:2962`) computes the overlap-minimising
`placement` via `HiddenWindowPlacementResolver.placement` (`SideHiding.swift:156`)
… and then **overrides it** with the `physicalEdge1pt` result, which parks on the
**requested** edge, not `placement.resolvedEdge`:

```swift
// Sources/Nehir/Core/Controller/LayoutRefreshController.swift:2965-3000  (abridged)
let requestedEdge = AxisHideEdge(encodedHideSide: side)
let placement = HiddenWindowPlacementResolver.placement(   // overlap-minimised — COMPUTED
    ..., requestedEdge: requestedEdge, ...                  //   ...but its .resolvedEdge is NOT used below
)
// Mitigation: explicit 1pt parking on the physical screen edge. ...not a complete
// WindowServer hide primitive and must not be described as universally reliable.
let reveal: CGFloat = Self.hiddenWindowEdgeRevealEpsilon
let result: CGPoint = switch orientation {
case .horizontal:
    switch requestedEdge {                                  // ← requestedEdge, not placement.resolvedEdge
    case .minimum:  CGPoint(x: monitor.frame.minX - frame.width + reveal, y: orthogonalOrigin)
    case .maximum:  CGPoint(x: monitor.frame.maxX - reveal,                y: orthogonalOrigin)
    }
...
}
```

The override is deliberate: parking a column on the *opposite* edge from the side
it scrolled off causes a visible fly-across (this is exactly why approach #13 in
`docs/window-parking-and-offscreen-clamp.md` — "push all hidden windows to one edge" — was
rejected: "left-hidden windows visibly fly across the screen to get there"). The
`placement` value is computed and traced (`hideOrigin.resolve experiment=physicalEdge1pt
… placement=…`) but its `.resolvedEdge` is dead for the result. **The cost of that
choice is the horizontal-arrangement bleed:** on a side-by-side layout, a column
hidden towards the neighbour is parked *onto* the neighbour.

### A.4 Worked example — 2 monitors side-by-side, transient `.right` park

Topology: monitor A `frame = [0, 2056]` (left), monitor B `frame = [2056, 4112]`
(right), touching at `x = 2056`. A hidden 1008px-wide column on A's active
workspace overflows towards B, so the layout classifier
(`overflowEdgeIntersectingNeighboringMonitor`, `NiriLayout.swift:378`) hides it
`.right` (`.maximum`). The transient resolver then parks it:

- `result.x = monitor.frame.maxX - reveal = 2056 - 1.0 = 2055`
- window frame `= {2055, y, 1008, h}` → spans global `x ∈ [2055, 3063]`.
- monitor A owns `x ∈ [0, 2056]`; monitor B owns `x ∈ [2056, 4112]`.
- Intersection with B: `x ∈ [2056, 3063]` → **1007px of the 1008px-wide window
  renders on monitor B**; exactly 1px (`x = 2055..2056`) sits on A.
- Because `[2055, 3063]` is *on* monitor B, the window is **not offscreen**, so
  **the macOS clamp does not fire** — `setFrame` readback equals target, no
  `.verificationMismatch`. The window is simply, fully, visible on the wrong
  monitor. This is the maintainer's symptom in its purest form.

Contrast the **same** window hidden via the **workspace-inactive** path on the
same topology. `physicalScreenEdgeOrigin` scores both sides:

- `.right` on A (requested): `origin.x = 2055`, overlap with B `= 1007 × h` (large).
- `.left` on A (alternate): `origin.x = 0 - 1008 + 1 = -1007`, window `x ∈ [-1007, 1]`,
  overlap with B `= 0`.
- Resolver commits `.left` (overlap 0 < 1007×h). Window's right edge at `x = 1`
  → 1px on A, body hangs off into no-monitor space to the left.
- Now the window **is** effectively offscreen, so the clamp *may* fire and leave
  ~15–40px on A (approach #16 variance: "after the window is classified
  hidden/parked, a visible strip can remain stuck on screen (~15px or more)").
- **Nothing renders on monitor B.** Workspace-inactive bleeds onto its *own*
  monitor, not the neighbour.

So the two paths differ by ~1007px of bleed on a horizontal layout: workspace-
inactive leaves a small strip on its own monitor; transient leaves the whole
window on the neighbour.

### A.5 Why the vertical-arrangement workaround works (and horizontal doesn't)

`docs/window-parking-and-offscreen-clamp.md` recommends arranging monitors **vertically**. With
A and B stacked (B below A, same `x`-range), the transient `.right` park on A at
`x = 2055` extends into `x > 2056`, which is **offscreen** — no monitor owns that
horizontal band. The window is now fully offscreen → the clamp fires → a ~40px
strip remains on A; **nothing renders on B** (B is at a different `y`-range). The
vertical arrangement converts the transient "whole window on neighbour" into the
same "~40px strip on own monitor" as the workspace-inactive case. That is the
entire mechanism behind the existing recommendation. Horizontal arrangement
defeats it because the neighbour sits exactly where the transient park target
lands.

---

## B. The critical path — what to do, in order

Two independent halves. Both must happen; only the second can reach true zero.

### B.1 Reconciliation fixes (mandatory, regardless of approach; ship FIRST)

A window Nehir never moved, or whose park it undid, is visible on **any**
arrangement. These close the Nehir-internal half — "is the park actually issued
and not undone?" They are sequenced first because they are cheaper, lower-risk,
and required no matter which clamp-defeat direction wins.

| Item | Status on current `main` | What it fixes | Source anchor (verified) |
|---|---|---|---|
| `completed/20260625-inactive-workspace-frame-writes-leak.md` | **✅ shipped** in `70ed2619` and `196dee9a` | Diff executor must not mark inactive-workspace ordinary frame jobs active or unsuppress their frame writes; inactive-plan `.show` entries must not become visible-frame reveal work unless the workspace is active. | `LayoutDiffExecutor.execute` computes `isPlanWorkspaceActive`, blocks inactive-plan `.show` reveal work, preserves inactive suppression for ordinary frame writes, and leaves `hideInactiveWorkspaces` responsible for parking. |
| `discovery/20260616-workspace-inactive-stale-live-frame.md` | **✅ shipped** in `196dee9a` and `07ce4168` | Already-hidden workspace-inactive windows whose live AX frame drifted back onscreen are re-checked and re-parked; the stale-cached live-AX guard is no longer `layoutTransient`-only. | `hideWorkspace` uses `isWorkspaceInactiveWindowVisiblyDrifting` to repair drift, and `resolveHideOperation` records `hidePlan.staleCachedAlreadyHidden ... reason=workspaceInactive` before returning a live-frame-derived park plan. |
| `discovery/20260616-stale-live-frame-on-stably-hidden-column.md` | **✅ shipped** in `07ce4168` | A stably-hidden `layoutTransient` column whose live AX drifted is re-checked even when no new `.hide` transition is emitted. | `LayoutDiffExecutor.execute` calls `reconcileStablyHiddenLayoutTransientColumns`; the helper is throttled per workspace and returns reconciled tokens so ordinary frame writes skip them in the same pass. |

What these fixes **do not** do: defeat the macOS clamp, or stop the transient
path (§A.3) from parking onto the neighbour. So even with all three landed, a
horizontal layout still shows (a) a ~15–40px clamp strip for workspace-inactive
windows on their own monitor, and (b) the full transient-onto-neighbour window.
They are necessary, not sufficient, for the maintainer's goal.

### B.2 The clamp ceiling — the only thing that gives TRUE invisibility on a horizontal layout

Sixteen position/visibility primitives are logged as failed in
`docs/window-parking-and-offscreen-clamp.md` (AX retry, resize-to-1×1, `kAXMinimizedAttribute`,
`SLSSetWindowOpacity`, `SkyLight.orderWindow`, `y=-10000`, `SLSWindowSetShape`,
`SLSTransactionOrderWindow`/`SLSOrderWindow` with `kCGSOrderOut`,
`SLSSetWindowTransform`, explicit 1px edge parking, …). The recurring reason:
every one tries to move a window **out of** display space, and macOS clamps it
back. The virtual display (approach #17, proposed in
`discovery/20260621-virtual-display-park-offscreen-windows.md`) is the single
untried direction that instead creates **new** display space to park windows
**into**. It is gated on one unverified hypothesis:

> **H1:** macOS's offscreen-position clamp fires iff the target frame lies
> **outside the union of all display frames**. A window parked fully *inside* a
> (virtual) display's frame — a display with no physical screen — is immune to
> the clamp, is invisible (no screen renders it), and stays "ordered in" on a
> known display (so AX observers, focus state, and fast workspace re-show behave
> as today).

H1 cannot be settled by reading source or by a unit test
(`docs/window-parking-and-offscreen-clamp.md`: *"Private WindowServer/SkyLight/AX behavior
cannot be proven by coordinate math or unit tests… Unconfirmed hypotheses are not
fixes."*). It requires a runtime spike — see §C.

---

## C. The virtual-display spike — concretely runnable

The maintainer has a real horizontal 2-monitor host, so this spike can be
**executed**, not just designed. It is a throwaway runtime experiment against the
main source tree, not a unit test, and cannot run on the docs-only branch. It
mirrors `discovery/20260621-virtual-display-park-offscreen-windows.md`
§"Suggested validation" with the exact symbol-resolution and pass/fail detail.

### C.1 Resolve the `CGVirtualDisplay` symbols exactly as SkyLight is loaded

Nehir already `dlopen`s a private framework and `fatalError`s on missing
*required* symbols while tolerating missing *optional* ones. Mirror that pattern
exactly (`Sources/Nehir/Core/SkyLight/SkyLight.swift:170`–`194`):

```swift
// SkyLight.swift:170-194 — the pattern to copy for a VirtualParkDisplay
private init() {
    guard let lib = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else {
        fatalError("Failed to load SkyLight framework")
    }
    func resolveOptional<T>(_ symbol: String, as _: T.Type) -> T? {
        guard let ptr = dlsym(lib, symbol) else { return nil }
        return unsafeBitCast(ptr, to: T.self)
    }
    var missingRequiredSymbols: [String] = []
    func resolveRequired<T>(_ symbol: String, as type: T.Type) -> T? {
        let resolved: T? = resolveOptional(symbol, as: type)
        if resolved == nil { missingRequiredSymbols.append(symbol) }
        return resolved
    }
    // ...required symbols resolved here, fatalError if missingRequiredSymbols non-empty
}
```

For the spike, `dlopen` CoreGraphics instead
(`/System/Library/PrivateFrameworks/CoreGraphics.framework/CoreGraphics` or
`ApplicationServices`) and `dlsym` the Objective-C class symbols
`CGVirtualDisplay`, `CGVirtualDisplaySettings`, `CGVirtualDisplayMode` (header
shape: `CGVirtualDisplaySettings.hiDPI`, `CGVirtualDisplayMode` with
`width`/`height`/`refresh`). Treat them as **optional** for the spike (no
`fatalError` — fail soft into "H1 unverifiable on this OS" if absent). Nehir is
**not sandboxed** (`Nehir.entitlements` carries only
`com.apple.security.automation.apple-events`) and targets **macOS 15**
(`Package.swift`), so no new distribution posture is required — consistent with
the existing SkyLight dependency.

### C.2 Place the virtual frame relative to the real horizontal arrangement

Position one small virtual display (e.g. `2560×1600`, low refresh, no HiDPI) at a
global origin that does **not** overlap any real monitor and stays clear as the
arrangement changes. For the §A.4 topology (A `[0,2056]`, B `[2056,4112]`), place
it well above or below the real `y`-band, e.g. `origin = (0, realMinY - 4000)`,
so it never intersects A or B. On create/destroy it will appear in
`NSScreen.screens` and fire
`NSApplication.didChangeScreenParametersNotification` (debounced 100 ms in
`DisplayConfigurationObserver`); for the spike, ignore Nehir's reaction and read
the virtual `CGDirectDisplayID` + frame directly from the created object. (The
full design — not the spike — must exclude it from `Monitor.current()` /
`WorkspaceManager.monitors` by an `isParkDisplay` tag; see C.5.)

### C.3 The exact pass/fail test (H1)

Via the existing `AXWindowService.setFrame` path
(`Sources/Nehir/Core/Ax/AXWindow.swift` `setFrame`, attribute writes at the
`kAXPositionAttribute`/`kAXSizeAttribute` calls inside `setFrame`), park a test
window at the **centre** of the virtual frame, with large margin on every side
(e.g. target `origin = virtualFrame.origin + (500, 500)`). Run **two** widths:

- **narrow (~852px)** and **wide (~1600px)** — wide windows have different clamp
  behaviour (`docs/window-parking-and-offscreen-clamp.md`: a 1626px window pushed to `x=1728`
  clamped to `x=1688`, 40px visible; a narrow 852px window at `x=1728` was
  allowed at `x=1727`, 1px). Both must pass.

Read back `kAXPositionAttribute` (the same readback `setFrame` performs) and
assert `observed == target` within the existing **1.0pt** tolerance
(`AXWindow.swift:459`,
`observedFrame.approximatelyEqual(to: frame, tolerance: 1.0) ? nil : .verificationMismatch`).

Inline the concrete pairs into the follow-up doc — expect, on success:

```text
narrow: target={(vx+500, vy+500), 852×1068}  observed={(vx+500, vy+500), 852×1068}  mismatch=no
wide:   target={(vx+500, vy+500), 1600×1068} observed={(vx+500, vy+500), 1600×1068} mismatch=no
```

- **No `.verificationMismatch` for both widths ⇒ H1 holds ⇒ escalate to full
  design.**
- **Any clamp (e.g. `observed.x` pulled back so ~40px would sit at a virtual/real
  boundary, or any `verificationMismatch`) ⇒ H1 is false ⇒ record as approach
  #17 failure in `docs/window-parking-and-offscreen-clamp.md` with the inlined `target=` /
  `observed=` pairs, and stop.**

### C.4 Visual confirmation (the clamp doc's four-scenario rule)

Per `docs/window-parking-and-offscreen-clamp.md`'s "must confirm manually" rule, observe during:
(1) slow gesture approach, (2) snap/keyboard navigation, (3) focus change, (4)
settled idle state — that **no pixels of the parked window appear on either real
monitor**, for both the narrow and the wide window. Also confirm the parked
window remains ordered-in and its AX frame stays readable (the "live window"
property the current positional park relies on), and that creating/destroying
the virtual display does not disturb the real arrangement or primary display.

### C.5 Hard-exclusion surface the FULL design would need (list only — do not design now)

If H1 passes, the escalation doc must treat the park display as a first-class,
identity-tagged, hard-excluded display across (concise list, mirroring
`discovery/20260621-virtual-display-park-offscreen-windows.md` §"Where / how"):

- **New-window admission / reconciliation** — macOS may open windows on the
  virtual display; relocate any window whose frame lands there back to a real
  monitor.
- **Focus / FFM / app switcher** — a hidden window that receives focus must not
  strand the cursor on an invisible display; `MouseWarpHandler` must never warp
  there.
- **Restore / reveal** — `executeHiddenReveal` / `restoreWindowFromHiddenState`
  must move the window back to a real monitor before unhiding (the proportional-
  restore pitfall in `docs/window-parking-and-offscreen-clamp.md` §"Restore Path for Tiled
  Windows" applies).
- **Diagnostics** — `DisplayEnvironmentDiagnostics` and the monitors dump must
  not report it as a user monitor.
- **Separate-Spaces interaction** — under "Displays have separate Spaces" ON, the
  virtual display gains its own Space; revisit the Space-topology prerequisite
  (`completed/20260619-m4s2-space-topology-eviction-exemption.md`) at that point.

---

## D. Cheaper alternatives — rule them in or out for the horizontal case

`docs/window-parking-and-offscreen-clamp.md` already ruled out 16 approaches. Re-checked here
**for the horizontal case specifically**:

### D.1 Far-edge park (force transient parks onto the outer edge) — partial win, real cost

On a 2-monitor horizontal setup, each monitor has exactly one neighbour and one
**outer** edge with no neighbour (A's left edge, B's right edge). The overlap-
minimising `placement` resolver (`SideHiding.swift:156`) already returns the
outer edge for an inner-requested park — its logic is `alternateOverlap <
primaryOverlap` ⇒ `resolvedEdge = alternateEdge` (verified at
`SideHiding.swift:214`–`230`). The transient path simply does not *use* it
(§A.3). Switching the transient result from `requestedEdge` to
`placement.resolvedEdge` would move every transient park to the outer edge.

- **What it wins:** kills the **neighbour** bleed (the maintainer's literal
  symptom) — the parked window no longer renders on the 2nd monitor.
- **What it costs:** (1) **fly-across** — a column hidden towards the neighbour
  flies across the full screen to the opposite outer edge (the exact reason
  approach #13 was rejected and the `physicalEdge1pt` override chose
  `requestedEdge`). `preParkMargin = 16` pre-parking softens but does not remove
  a full-width cross-screen jump. (2) **Residual clamp strip ~15–40px on the
  outer monitor** — approach #16's variance ("a visible strip can remain stuck
  on screen (~15px or more observed)"; "one window parked at `-851`/`1727`,
  while another stale/cached-hidden window remained live-clamped at `-812`").
- **Verdict:** 🟡 a real, cheap *reduction* (neighbour → own-monitor strip), not
  zero. Worth offering as a degraded-mode option for horizontal layouts, but it
  does not satisfy "isn't visible."

### D.2 "Displays have separate Spaces" ON — the most promising zero-code option

`discovery/20260618-separate-spaces-and-monitor-arrangement.md` records a
maintainer manual-test finding: with **Displays have separate Spaces ON**, two
horizontally-arranged displays did **not** show the parked-window bleed on the
2nd display (tested with WM disabled and parked windows still present). The
mechanism is per-display **Space rendering isolation**: a window that belongs to
monitor A's active Space, parked at global coordinates that fall on monitor B's
display, does not render on B because B is showing a different Space. This is a
**free macOS toggle** — no code.

- **Why it could matter here:** it attacks the *rendering boundary*, not the
  coordinates. Unlike the clamp, it can hide a window that is geometrically "on"
  the neighbour's display. Unlike the far-edge park, it has no fly-across and no
  residual strip.
- **Caveats (do not claim fixed without runtime confirmation, per the clamp-doc
  pitfall):** (1) the maintainer test was with WM disabled and observed
  previously-parked (workspace-inactive-style) windows — the **transient** case
  within an active workspace is not separately confirmed. (2) Nehir's
  Separate-Spaces runtime support has matured since that 2026-06-18 discovery
  (`Sources/Nehir/Core/SkyLight/SpaceTopology.swift` is now landed;
  `WorkspaceManager.isNativeInactiveWindow` / `nativeInactiveWindowTokens` are
  wired at `WorkspaceManager.swift:2865`–`2869`, consumed by the `hideWorkspace`
  native-inactive guard), but the 2026-06-18 "jumps/loops in that mode" caveat is
  runtime-unconfirmed as resolved. (3) It does not help global-sticky windows
  (e.g. browser PiP), which render on all displays/Spaces.
- **Verdict:** 🟡 high-value, zero-cost, but **runtime-unconfirmed for the
  transient-park case**. Cheapest thing to validate next on the maintainer's real
  host: toggle Separate Spaces ON, reproduce a transient scroll that parks a
  column towards the neighbour, and observe whether it still bleeds. If it does
  not, the horizontal-bleed may be largely resolved without any virtual display.

### D.3 `SLSSetWindowOpacity` / `SLSSetWindowTransform` / ordering out — reconfirmed dead

- **`SLSSetWindowOpacity`** — approach #4, "no visible effect on the clamped
  strip." In source it is wired only via `configureWindow`
  (`SkyLight.swift:824`–`828`, `_ = setWindowOpacity?(cid, wid, opaque ? 1 : 0)`)
  for **Nehir's own** border/overlay windows. Reconfirmed: not applied to
  external app windows, and already proven not to hide the strip.
- **`SLSSetWindowTransform` / `CGSSetWindowTransform`** — approaches #14/#15
  (raw near-zero scale) were reverted; `grep -rn "SetWindowTransform\|WindowTransform"
  Sources/Nehir/Core/` returns **nothing** today. The primitive is not even in
  the tree; reconfirmed dead.
- **`orderWindow(.out)` / `transactionHide`** — approaches #10/#11. `transactionHide`
  exists (`SkyLight.swift:883`, `transactionOrderWindow(transaction, wid, 0, 0)`)
  but is used only on Nehir's own windows; for windows owned by other processes
  both `SLSTransactionOrderWindow` and `SLSOrderWindow` with `kCGSOrderOut`
  (raw `0`) are **silently ignored** (`isWindowOrderedIn` stays `true`). Dead.

**Net for §D:** the only zero-cost options are the vertical-arrangement
workaround (existing), the far-edge park (neighbour→strip, with fly-across), and
Separate-Spaces ON (free toggle, runtime-unconfirmed for the transient case).
**None of them reaches zero on its own. The virtual display remains the only
known path to *zero* bleed.**

---

## Recommendation — what to do next

1. **Reconciliation prerequisite complete** (B.1): the inactive-workspace frame
   leak fix, workspace-inactive stale-live repair, and stably-hidden
   `layoutTransient` reconciliation are all on current `main`. They are mandatory
   on every arrangement and unblock honest evaluation of the rest, but they are
   not the horizontal invisibility fix.
2. **Next, validate the two cheap horizontal options on the maintainer's
   real host (no design work):**
   - Toggle **Displays have separate Spaces ON** and reproduce a transient park
     towards the neighbour (D.2). If the bleed disappears, that may be the
     practical answer for most users at zero code cost; document the result and
     the PiP/global-sticky exception.
   - If Separate Spaces is unsatisfactory, quantify the **far-edge park**
     trade-off (D.1) as a degraded horizontal-layout mode.
3. **Run the bounded virtual-display spike (§C)** to settle H1. It is cheap,
   high-value, and the maintainer can actually execute it on the horizontal host.
4. **Escalate to a full `planned/` design ONLY if H1 passes** (or if Separate-
   Spaces-ON proves insufficient and true zero is required). The design must own
   the hard-exclusion surface (C.5) and sequence behind the reconciliation fixes.
5. **Until H1 passes or Separate-Spaces-ON is runtime-confirmed for the
   transient case, no doc may claim the horizontal-bleed is "fixed"/"solved"** —
   per `docs/window-parking-and-offscreen-clamp.md`'s explicit pitfall. A unit test can prove
   Nehir *requested* a coordinate; it cannot prove macOS *rendered* the window
   hidden.

---

## Cross-links (do not duplicate)

- `docs/window-parking-and-offscreen-clamp.md` (repo document) — authoritative clamp record +
  16 failed approaches; treat as ground truth.
- `discovery/20260621-virtual-display-park-offscreen-windows.md` — the
  virtual-display proposal (approach #17); §C makes its "Suggested validation"
  runnable and adds the horizontal-arrangement critical-path context.
- `completed/20260625-inactive-workspace-frame-writes-leak.md` — the shipped
  inactive-workspace frame-write reconciliation fix (B.1, row 1).
- `discovery/20260616-workspace-inactive-stale-live-frame.md` and
  `discovery/20260616-stale-live-frame-on-stably-hidden-column.md` — resolved
  stale-live-frame discoveries whose fixes shipped in current `main` (B.1, rows
  2–3).
- `noop/20260616-omniwm-349-hidden-window-bleeds-multi-monitor.md` and
  `noop/20260616-omniwm-364-clamp-visible-frames-monitor-bounds.md` — the
  cross-monitor geometry half (already mitigated for *visible* tiled frames;
  explains why it does not help hidden windows reach zero).
- `discovery/20260618-separate-spaces-and-monitor-arrangement.md` and
  `completed/20260619-m4s2-space-topology-eviction-exemption.md` — Separate-Spaces
  topology context (D.2; a risk for the virtual display under separate spaces,
  not a dependency).
