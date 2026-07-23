# #163: auto-hide bottom Dock reservation becomes sticky after display reconfiguration — Discovery

Verified against `main` on 2026-07-23 (HEAD `1d195a9b`). Re-verify source
line numbers before implementing; cite symbols where possible.

**Verdict:** confirmed, actionable root cause. Nehir can adopt a transient bottom
Dock reservation after a display disconnect/reconnect and deliberately keep it as
a sticky working-area inset even when the Dock is configured to auto-hide. Niri
then lays windows out inside that reduced working frame, producing the persistent
bottom gap reported in #163.

## Tracking and contributor attribution

- Nehir issue: [#163 — The window does not fully expand after reconnecting the external monitor](https://github.com/apphane-dev/nehir/issues/163)
- Reporter and future changeset contributor: [@dagrlx](https://github.com/dagrlx)
- Reporter-provided failing capture: <https://github.com/user-attachments/files/29926243/runtime-trace-1783781307208-1783781340557.log>
- A future user-visible fix should mention `Fixes #163` and pass
  `--contributors dagrlx` to `mise run changeset`.

The reporter observed the issue on macOS 27 Beta 3, but the same geometry failure
was reproduced on macOS Tahoe on 2026-07-23. The mechanism is therefore not
specific to the macOS 27 beta.

## Symptom

With the Dock configured to auto-hide, disconnecting or reconnecting an external
display can make Nehir leave a Dock-height band unused at the bottom of the Dock
host display. Restarting Nehir clears the gap. The repository's documented
recommended configuration is an auto-hide Dock (`docs/CONFIGURATION.md:199-204`),
so this is not an unsupported fixed-Dock setup.

## Evidence: the 2026-07-23 reproduction shows the issue

The capture starts with two displays. The built-in display has no bottom Dock
reservation; only the 39-point menu-bar/notch band is excluded at the top:

```text
display 1 Built-in Retina Display
frame=(0,0 2056x1329)
visibleFrame=(0,0 2056x1290)

display 3 DELL P2423D
frame=(-312,1329 2560x1440)
visibleFrame=(-312,1329 2560x1410)
```

At `11:01:22Z` the external display disconnects:

```text
event=topology_changed displays=1
plan=topology=2->1 visible_assignments=1
```

After that transition, the surviving built-in display has acquired a 78-point
bottom reservation while its physical frame is unchanged:

```text
display 1 Built-in Retina Display
frame=(0,0 2056x1329)
visibleFrame=(0,78 2056x1212)
```

The arithmetic isolates the two excluded bands:

- bottom: `visibleFrame.minY - frame.minY = 78`
- top: `frame.maxY - visibleFrame.maxY = 1329 - 1290 = 39`

This is not merely an AppKit diagnostic value that layout ignores. Nehir targets
and confirms the active windows inside the reduced frame:

```text
window 17717 target=(-647,85 1011x1173) observed=(-647,85 1011x1173)
window 188   target=( 370,85 1316x1173) observed=( 370,85 1316x1173)
```

The `y=85` target is the erroneous 78-point Dock reservation plus the configured
7-point bottom outer gap. The windows end at `y=1258`, leaving the configured
workspace-bar/top region below `visibleFrame.maxY=1290`. Nehir is therefore
actively producing the bottom gap from its reduced working area; this is not a
window refusing a correct full-height AX resize.

The Dock is configured persistently as auto-hide and bottom-oriented in the
reproduction environment:

```text
com.apple.dock autohide = 1
com.apple.dock orientation = bottom
```

## Evidence: reporter capture has the same signature

The issue capture begins healthy on the external main display:

```text
display 2 LG FHD
frame=(0,0 1920x1080)
visibleFrame=(0,0 1920x1049)

window 1542
cur=0,0,1920,1049
target=0,0,1920,1049
```

The topology then changes `2 -> 1 -> 2` as the displays disconnect and reconnect.
After reconnection, the external display has acquired a 64-point bottom
reservation while retaining the same 31-point top menu-bar band:

```text
display 2 LG FHD
frame=(0,0 1920x1080)
visibleFrame=(0,64 1920x985)
```

Nehir uses that exact reduced frame for the reported Ghostty window:

```text
window 1542
cur=0,64,1920,985
target=0,64,1920,985
last=0,64,1920,985
live=0,64,1920,985
```

Again, this is a direct match: the 64-point gap is in the monitor working area and
the Niri target, not introduced later by AX or the application. The reporter's
second attempt did not reproduce, which is consistent with whether the
reconfiguration samples a positive Dock reservation or readable Dock AX bar at
the moment the monitor snapshot is rebuilt.

## Evidence: direct probe of a bottom auto-hide Dock (single machine, 2026-07-23)

To settle which macOS value the sticky 64/78-point inset actually comes from, the
candidate Dock-geometry sources were probed directly on a single built-in display
with the Dock configured **bottom + auto-hide**. The probe measured the raw
`NSScreen.visibleFrame` (pre-`DockReservation`), the Dock `AXList` bar geometry,
and the persistent `com.apple.dock` preferences, sampling the Dock both hidden and
fully revealed (reveal forced by warping the cursor to the bottom edge, then
restored). This is a **single-machine** measurement; the multi-display
disconnect/reconnect transition and the reporter's `64` variant were not
reproduced by the probe.

Persistent preferences, read after `CFPreferencesAppSynchronize`:

```text
com.apple.dock autohide = 1        orientation = bottom
com.apple.dock tilesize = 48       largesize = 16      magnification = 0
```

Raw display geometry (built-in, scale 2.0):

```text
frame        = (0,0 2056x1329)
visibleFrame = (0,0 2056x1290)     # RAW, pre-DockReservation
insets: bottom = 0.0   top = 39.0
safeAreaInsets: top = 38.0   bottom = 0.0   # menu-bar/notch only, never the Dock
```

The Dock `AXList` bar across the reveal animation:

| Dock state           | AXList `size.height` | bar top-edge (`appKitBar.maxY`) | raw `visibleFrame` bottom inset |
| -------------------- | -------------------- | ------------------------------- | ------------------------------- |
| hidden (parked)      | **68.0**             | 0.0                             | **0.0**                         |
| revealing (t≈0.35 s) | **68.0**             | 71.0                            | **0.0**                         |
| fully revealed       | **68.0**             | **78.0**                        | **0.0**                         |

Three facts fall out of this, and they redirect the root cause below:

1. **The raw `visibleFrame` bottom inset is `0` even while the Dock is fully
   revealed.** For an auto-hide Dock, `NSScreen.visibleFrame` reserves nothing on
   the Dock axis, ever. So any positive bottom inset Nehir applies is manufactured,
   not observed — and the live `currentInset` fallback (which reads exactly this
   `visibleFrame.minY - frame.minY`) can never bootstrap a positive bottom value
   under auto-hide.
2. **The AXList bar's `size.height` is a stable 68.0** — identical hidden and
   revealed, and queryable even while the Dock is parked offscreen. This is the
   Dock's real physical bar thickness. It is *not* what the current code learns.
3. **The value the current code learns animates.** `axDerivedInset`'s bottom case
   returns `appKitBar.maxY - frame.minY`, the bar's *top-edge screen position*,
   which sweeps `0 → 71 → 78` as the Dock reveals. The fully-revealed `78`
   decomposes as `78 = 68 (bar height) + 10 (floating gap below the bar)` and
   matches the local-repro sticky reservation exactly; a different machine's
   `tilesize`/scale yields the reporter's `64`.

Distinguish two heights that are easy to conflate:

- the **stable physical bar height** — `AXList.size.height` = 68, reveal-independent;
- the **fixed-Dock reservation height** — the band a *fixed* Dock excludes from
  `visibleFrame` (= bar height + floating gap = 78 here). An **auto-hide** Dock
  reserves *none* of it.

`tilesize = 48` is the **icon size**, not the outer band height (`68 − 48 = 20`
with magnification off, from a single sample — not a formula). The authoritative
classifier for "does this Dock reserve a permanent band?" is
`com.apple.dock autohide`: `autohide = 1` ⇒ nobody reserves the band permanently,
so Nehir can safely reclaim it.

### Live proof that the 78-point inset is manufactured

At the moment of this probe the running Nehir instance — which had earlier learned
the 78-point bottom inset during the local `2 -> 1` transition — still carried
`Monitor.visibleFrame` with a bottom origin of `y = 78` in its process-static
sticky cache, while the OS simultaneously reported the raw `visibleFrame` bottom
inset as `0`. The kept `78` therefore does not correspond to anything macOS
reserves; it is a stale learned value that outlives the transient reveal that
produced it.

## Root cause: `DockReservation` intentionally applies fixed-Dock stickiness to auto-hide

### 1. Every monitor snapshot passes through the sticky Dock filter

`Monitor.current()` reads each `NSScreen`, but does not retain
`screen.visibleFrame` directly. It calls
`DockReservation.stableVisibleFrame(frame:visibleFrame:displayId:)` and stores the
result as `Monitor.visibleFrame` (`Sources/Nehir/Core/Monitor/Monitor.swift:25-40`).

The helper's declaration describes fixed-Dock stabilization, saying that the
cached inset should be retained while `autohide == false`
(`Monitor.swift:134-149`). The implementation does not enforce that condition.
Instead it explicitly states:

```swift
// an auto-hide Dock hides/reveals it constantly). This keeps the shield and the
// working area rock-stable — no re-tile when the Dock hides. We intentionally do
// NOT try to detect auto-hide and reclaim the band.
```

(`Monitor.swift:183-187`.) The function reads only the Dock `orientation`
preference (`:192`); it never reads `com.apple.dock autohide`.

That behavior conflicts with both the helper's fixed-Dock contract and Nehir's
configuration guidance that recommends an auto-hide Dock.

### 2. The animating AX bar top-edge is what becomes sticky

`stableVisibleFrame` has two learn branches for a bottom Dock, neither gated on
the persistent `autohide` setting:

- the **AX branch** (`Monitor.swift:322-337`) adopts a positive `axDerivedInset`;
- the **live fallback** (`Monitor.swift:338-345`) adopts the live `currentInset`
  (`visibleFrame.minY - frame.minY`, `Monitor.swift:285`) when no sticky value
  exists yet.

The direct probe above shows only the AX branch can fire under a bottom auto-hide
Dock. The raw `visibleFrame` bottom inset stays `0` even when the Dock is fully
revealed, so `currentInset` is always `0` and the live fallback never bootstraps a
positive bottom value. The positive inset comes exclusively from `axDerivedInset`,
whose bottom case returns

```swift
default:
    return appKitBar.maxY - frame.minY
```

(`Monitor.swift:409-434`, bottom case at `:432`) — the Dock `AXList` bar's *top-edge
screen position*, which animates `0 → 71 → 78` as the Dock reveals. Sampling it
while the bar is mid-reveal (an edge approach or the reveal that accompanies a
topology animation) learns the transient `64`/`78` as the sticky inset. The stable
`AXList.size.height` (68) is never consulted; the code learns the animating
position instead of the reveal-independent height.

This corrects the earlier uncertainty about which branch supplies the first
positive value: it is the AX top-edge branch, and the same missing auto-hide gate
that leaves it active also leaves the (here-inert) live fallback ungated.

### 3. The learned inset is deliberately reapplied against the physical frame

Once learned, the bottom case sets the corrected origin to
`frame.minY + inset` and reduces the height to the previous top edge
(`Monitor.swift:368-385`). A later full-height live `visibleFrame` does not reclaim
the space because stickiness is the feature's purpose.

The cache is process-static and keyed by display ID (`Monitor.swift:150-164`). A
`2 -> 1` disconnect can therefore learn 78 points for the unchanged built-in
display ID; a `1 -> 2` reconnect can learn 64 points for the external display
when the Dock moves back there. The recent frame-change guard only invalidates a
sticky value when that display's own physical `frame` changes (`:200-210`), so it
does not help when topology changes but the Dock host's frame is unchanged.

Restarting Nehir clears the process-static dictionary, explaining the reported
workaround. Whether the gap returns depends on which live/AX Dock geometry is
sampled by subsequent startup-settle or display-parameter refreshes.

### 4. Display-change handling faithfully propagates the bad monitor frame

`ServiceLifecycleManager` observes
`NSApplication.didChangeScreenParametersNotification`, coalesces the event, and
rebuilds monitors with `Monitor.current()`
(`Sources/Nehir/Core/Controller/ServiceLifecycleManager.swift:153-205`). It then:

1. applies the monitors to `WorkspaceManager` (`:219`),
2. synchronizes them into Niri (`:224`), and
3. requests a full monitor-configuration refresh (`:230-238`).

`NiriLayoutEngine.updateMonitors` copies the new monitor geometry and invalidates
cached layout spans when the visible width or height changes
(`Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+Monitors.swift:31-53`).
`NiriMonitor.updateOutputSize` stores `monitor.visibleFrame` unchanged
(`Sources/Nehir/Core/Layout/Niri/NiriMonitor.swift:53-62`).

`WMController.insetWorkingFrame(for:)` starts from that
`monitor.visibleFrame`, then adds workspace-bar and user outer-gap struts
(`Sources/Nehir/Core/Controller/WMController.swift:936-975`). The Niri layout uses
the resulting working-frame origin and height for every horizontal container
(`Sources/Nehir/Core/Layout/Niri/NiriLayout.swift:162-164,313-328`).

The monitor-refresh and Niri paths are therefore behaving correctly given their
input. The defect is upstream in the Dock working-area policy, not in display
reassignment, AX frame application, or Niri sizing.

## Why it is intermittent and tied to reconnects

A configured auto-hide Dock does not reserve the band continuously — the probe
above confirms its raw `visibleFrame` inset is `0` even fully revealed. What
fluctuates is the Dock `AXList` bar's *top-edge position*: `0` while parked,
sweeping up to `78` during a reveal. A monitor transition both moves the Dock
between displays and animates it into view, so the `AXList` bar is transiently
positioned on-screen at that moment. The display-parameter notification
immediately rebuilds `Monitor.current()`. If that rebuild's AX probe samples the
bar mid-reveal (top-edge > 0), `DockReservation` learns the position as a sticky
inset and makes it permanent; if it samples the bar still parked (top-edge = 0),
`axDerivedInset` yields `0`, nothing is learned, and the attempt appears healthy.

### Deterministic trigger: reveal the Dock, then disconnect while it is revealed

The timing luck can be removed entirely. Holding the cursor at the Dock edge pins
the `AXList` bar **fully revealed** (top-edge at its maximum, `78`/`64`), and then
disconnecting the cable while it stays revealed makes the `topology_changed`
rebuild sample that maximal top-edge every time. This is a **100% reproduction**:
the surviving display keeps the Dock-height band reserved for Nehir until restart.
It is the same single mechanism as the intermittent case — the only difference is
that forcing the bar on-screen guarantees the AX probe reads a positive top-edge at
the moment `Monitor.current()` rebuilds, instead of relying on the reveal animation
happening to coincide with the sample. It also excludes the live-`visibleFrame`
route: even fully revealed, the raw bottom inset stays `0` (probe above), so the
learned `78`/`64` can only be the AX top-edge.

This explains all observed variants with one mechanism:

- local `2 -> 1`: the Dock moves to the surviving built-in display and 78 points
  become sticky;
- reporter `1 -> 2`: the Dock returns to the external main display and 64 points
  become sticky;
- reporter's second attempt: no positive reservation was learned during the
  transition;
- restart: the process-static sticky cache is reset.

## Fix boundary for a follow-up plan

The fix belongs in `DockReservation.stableVisibleFrame`, before any sticky inset
is learned or applied:

1. Read the persistent `com.apple.dock autohide` preference. Existing project
   investigation notes that another process's Dock preferences should be
   synchronized with `CFPreferencesAppSynchronize` before reading
   (`completed/20260704-dock-edge-shield-and-parking-lessons.md:69-72`).
2. When auto-hide is confirmed enabled, clear any sticky value for the display
   and reclaim the Dock-orientation axis from the live `visibleFrame`, while
   preserving the orthogonal menu-bar/notch edge. For a bottom Dock that means
   restoring `origin.y = frame.minY` and keeping the live top edge.
3. Only fixed Docks (`autohide == false`) should use the current AX/live learn,
   hysteresis, and sticky reapplication behavior. A quick terminal that
   transiently suppresses a fixed Dock does not change the persistent Dock
   preference, so the fixed-Dock stabilization use case remains intact.
4. Preserve the recent frame-straddle guards and side-Dock host checks; #163 is a
   policy bug (auto-hide treated as fixed), not the scaled-resolution AX-straddle
   bug fixed by `3baf74d7`.

The gate alone fixes #163: it is sufficient to reject the learn under
`autohide == 1`. Note separately that the value the bottom AX branch learns is the
bar's *animating top-edge position* (`appKitBar.maxY - frame.minY`), not the
reveal-independent `AXList.size.height`. This plan does not need to change what a
*fixed* Dock learns — a fixed Dock's own `visibleFrame` genuinely reserves the
band — but if a future change ever wants the Dock's real thickness independent of
reveal state, `AXList.size.height` is the trustworthy source, not the top-edge
position.

No monitor-event, Niri, Dock Shield, or AX resize changes are indicated by the
captured evidence. Those components already react to a corrected
`Monitor.visibleFrame`.

## Validation target for implementation

Do not edit tests before real-repro confirmation, per `docs/TESTING.md`.
Implementation should first be validated in the reported runtime sequence:

1. Configure a bottom auto-hide Dock.
2. Start with built-in + external displays and full-height Nehir windows.
3. Disconnect and reconnect the external display in both directions.
4. Confirm every auto-hide Dock host keeps the full Dock-axis working area (only
   menu-bar/workspace-bar/user gaps remain), and that the Niri target frames no
   longer acquire the 64/78-point bottom offset.
5. Separately confirm a fixed Dock still retains its stable reservation when a
   quick terminal transiently hides it.

After the user confirms the fix in the real repro, add a small per-behavior
regression test rather than modifying a frozen monolith.
