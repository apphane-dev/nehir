# Plan: stop learning a sticky Dock reservation under an auto-hide Dock (#163)

Source-backed against `main` at HEAD `1d195a9b` on 2026-07-23. Re-verify the
cited symbols and line numbers before editing — treat line numbers as hints and
anchor on the symbol names.

Companion discovery:
`completed/20260723-nehir-163-autohide-bottom-dock-reservation-after-display-reconfiguration.md`.

## Completion (shipped 2026-07-23)

This plan is **completed**. It was implemented, reviewed, user-confirmed in the
real reconnect repro, and merged to `main` via PR #180 on 2026-07-23; issue
#163 is closed as completed. The merge commit `fe0596b6` is tagged
`v0.6.0-rc.39`.

**Shipped commits:**

- `fe48986d` — "Gate Dock reservation stickiness on the persistent auto-hide
  preference", `Fixes #163`. The implementation stayed within the planned
  boundary: `Sources/Nehir/Core/Monitor/Monitor.swift` plus the changeset
  fragment generated via `mise run changeset`
  (`.changeset/20260723163118-fix-external-monitor-reconnect-leaving-a-dock-he.md`,
  contributor `dagrlx`).
- `fe0596b6` — "Add regression tests for the #163 auto-hide Dock gate". The
  deferred test gate was satisfied after the user confirmed the fix worked in
  the real repro, per `docs/TESTING.md`.

**Deviations from this pre-implementation plan** (post-review, in `fe0596b6`):

- Two internal pure seams were extracted in `Monitor.swift` so the policy is
  unit-testable without touching the CFPreferences or Dock-AX boundaries:
  `resolveAutohideMemo` (the TTL / last-value-fallback rule, to which
  `dockAutohideEnabled()` now delegates) and `reclaimedDockAxis` (the Dock-axis
  reclaim geometry, to which the nested reclaim helper delegates). Both are
  behavior-preserving refactors of the code this plan specified.
- The new small per-behavior test file
  `Tests/NehirTests/DockAutohideReservationTests.swift` covers the memo policy
  (fresh read reused within the TTL, re-probe after expiry, transient-nil
  preserving the last authoritative value without overwriting the memo,
  cold-start nil, first-value seeding) and the reclaim geometry (bottom band
  reclaimed to `origin.y = frame.minY` at full height with the menu-bar edge
  preserved, idempotence when no band is present, side-Dock horizontal reclaim).
- Otherwise the implementation stayed within `Monitor.swift` plus the generated
  changeset, as planned.

**Final file set:** `Sources/Nehir/Core/Monitor/Monitor.swift`,
`Tests/NehirTests/DockAutohideReservationTests.swift`, and
`.changeset/20260723163118-fix-external-monitor-reconnect-leaving-a-dock-he.md`.

**Verification status:**

- Review: CodeRabbit's final pass reported no actionable comments.
- CI on `fe0596b6`: the Swift test job and the release build job succeeded; the
  SwiftLint + SwiftFormat job failed because `format:check` reported "would
  update: Tests/NehirTests/DockAutohideReservationTests.swift". That formatting
  cleanup is an open follow-up on `main`; not all gates were green at merge.

The plan below is preserved as the historical implementation spec. Its steps,
gates, and completion token are historical — nothing below remains pending.

## Problem in one paragraph

`DockReservation.stableVisibleFrame` treats a Dock inset as a stable property and
keeps applying it, deliberately not detecting auto-hide. For a bottom auto-hide
Dock the raw `NSScreen.visibleFrame` reserves nothing (bottom inset `0` even fully
revealed), but the AX learn branch adopts `axDerivedInset`'s bottom value
`appKitBar.maxY - frame.minY` — the `AXList` bar's *animating top-edge position*,
which sweeps `0 → 78` during a reveal. A display reconfiguration animates the Dock
into view exactly as `Monitor.current()` is rebuilt, so a mid-reveal sample is
learned as a permanent `64`/`78`-point sticky inset. Niri then lays out inside the
reduced working frame, leaving the persistent bottom gap in #163.

## Fix strategy (minimal, behavior-preserving)

Gate the learn/apply on the authoritative persistent preference
`com.apple.dock autohide`:

- **Auto-hide is authoritatively true** → the Dock reserves no permanent band.
  Drop any stale sticky inset for this display and reclaim the Dock-orientation
  axis from the live frame, preserving the orthogonal menu-bar/notch edge. Return
  before any learn.
- **Auto-hide is false, nil, or unreadable** → treat conservatively as a fixed
  Dock and fall through to the existing AX/live learn, hysteresis, host-display,
  and frame-straddle logic unchanged. A quick terminal that transiently suppresses
  a fixed Dock does not flip the persistent `autohide` preference, so fixed-Dock
  stabilization stays intact.

The gate alone is sufficient for #163. Do **not** change what a fixed Dock learns:
a fixed Dock's own `visibleFrame` genuinely reserves the band, and its stickiness
is the intended feature.

## Files to touch

- `Sources/Nehir/Core/Monitor/Monitor.swift` — the only source file changed.
- One Changesets fragment, created via `mise run changeset` (see below). Do not
  hand-author the fragment file.

*(Historical: this described the implementation commit's scope, which held. The
post-confirmation test follow-up later added
`Tests/NehirTests/DockAutohideReservationTests.swift`; see Completion above.)*

## Do-not-touch fences

Do not modify any of the following — the discovery shows they already react
correctly to a corrected `Monitor.visibleFrame`, and they are owned by unrelated
behavior:

- Niri layout/engine: `Sources/Nehir/Core/Layout/Niri/**`
  (`NiriLayoutEngine+Monitors.swift`, `NiriMonitor.swift`, `NiriLayout.swift`).
- Monitor-event scheduling / display-change coalescing:
  `Sources/Nehir/Core/Controller/ServiceLifecycleManager.swift`.
- Working-frame strut composition:
  `WMController.insetWorkingFrame(for:)` in
  `Sources/Nehir/Core/Controller/WMController.swift`.
- Dock Shield geometry, AX window-resize logic, and any topology/host-display
  reassignment behavior beyond the auto-hide gate described here.
- The scaled-resolution frame-straddle guards and side-Dock host checks already in
  `stableVisibleFrame` (`lastFrame`/`frameChanged`, `dockIsOnAnotherDisplay`,
  `reclaimUnconfirmedSideReservation`, the `edgeFlushTolerance` guards in
  `axDerivedInset`). #163 is a policy bug (auto-hide treated as fixed), not the
  scaled-resolution AX-straddle bug fixed by `3baf74d7`; leave those guards as-is.
- Tests: do **not** add, modify, move, or delete any file under
  `Tests/NehirTests/**` (see the test-gate section).

## Implementation steps

All edits are inside `enum DockReservation` in
`Sources/Nehir/Core/Monitor/Monitor.swift`.

### Step 1 — add a memoized, fallback-hardened persistent-autohide reader

Add a private static helper that reads the Dock's persistent `autohide`
preference. `CFPreferencesCopyAppValue` for another app's domain is cached, so it
must be preceded by `CFPreferencesAppSynchronize` to see the Dock process's own
writes (see `completed/20260704-dock-edge-shield-and-parking-lessons.md:69-72`).
`autohide` is a **global** Dock preference (not per-display), so the memo is a
single global slot, not keyed by `displayId`.

Two properties this reader must have, driven by how it is called:

- **Burst-cheap.** `Monitor.current()` calls `stableVisibleFrame` once per screen
  in a coalesced burst; without a memo, `CFPreferencesAppSynchronize` would run
  once per display on every rebuild. Gate the sync+read behind a short
  monotonic-time TTL keyed on `ProcessInfo.processInfo.systemUptime` (monotonic;
  no wall-clock dependency). Use **`ttl = 1.0` s** — long enough that a
  reconnect-window burst of rebuilds shares one read, short enough to pick up a
  genuine Dock setting change on the next event.
- **Nil-resilient after a first success.** The very first unreadable read returns
  `nil` (→ conservatively fixed, correct cold-start behavior). But once an
  authoritative value has been read, a *later* transient `nil` (which can occur
  during reconnect churn, exactly the #163 window) must fall back to the
  last-known value, so the sticky learn cannot briefly re-arm and let #163 slip
  through. A successful read always refreshes the value and re-times the memo.

Add a global memo field alongside the other `nonisolated(unsafe)` statics:

```swift
// Global (not per-display) memo of the persistent Dock autohide preference:
// (monotonic uptime of the last authoritative read, that value). Only successful
// reads are stored; a transient-nil read leaves the last authoritative value in
// place so reconnect churn cannot momentarily re-arm the fixed-Dock learn (#163).
private nonisolated(unsafe) static var lastAutohideProbe: (uptime: TimeInterval, value: Bool)?
```

```swift
/// The persistent `com.apple.dock autohide` preference, or nil when it has never
/// been readable. Returns true only when auto-hide is authoritatively enabled;
/// callers treat nil (and false) conservatively as a fixed Dock.
///
/// Memoized for `ttl` seconds against a monotonic clock so a burst of
/// `Monitor.current()` rebuilds triggers at most one `CFPreferencesAppSynchronize`.
/// After a first authoritative read, a transient unreadable read returns the last
/// known value rather than nil, so reconnect churn cannot momentarily re-arm the
/// fixed-Dock learn. Never holds `DockReservation.lock` across the CFPreferences
/// calls (those can block); the lock only guards the tiny memo read and write.
private static func dockAutohideEnabled() -> Bool? {
    let ttl: TimeInterval = 1.0
    let now = ProcessInfo.processInfo.systemUptime

    // 1. Fast path: return a fresh memoized value without syncing. Read the memo
    //    under the lock, then release it before any CFPreferences call.
    lock.lock()
    let cached = lastAutohideProbe
    lock.unlock()
    if let cached, now - cached.uptime < ttl {
        return cached.value
    }

    // 2. TTL expired (or nothing cached yet): synchronize + read OUTSIDE the lock.
    let dockDomain = "com.apple.dock" as CFString
    CFPreferencesAppSynchronize(dockDomain)
    let raw = CFPreferencesCopyAppValue("autohide" as CFString, dockDomain)
    let fresh: Bool? =
        if let flag = raw as? Bool { flag }
        else if let number = raw as? NSNumber { number.boolValue }
        else { nil }

    // 3. Update the memo (or fall back) under the lock, no CFPreferences call held.
    lock.lock()
    defer { lock.unlock() }
    if let fresh {
        lastAutohideProbe = (now, fresh)
        return fresh
    }
    // Transient unreadable: keep the last authoritative value if we ever had one;
    // otherwise nil → conservatively fixed. Do not overwrite the memo on nil.
    return lastAutohideProbe?.value
}
```

**Stale-toggle bound.** A genuine flip of the Dock's `autohide` setting is observed
at most `ttl` (1.0 s) late for a burst that already read within the window; the
next rebuild after TTL expiry — and every display-parameter event, which forces a
fresh rebuild — re-reads. The last-value fallback only extends staleness *while
reads transiently fail*; the first successful read snaps the classification back to
current. Because #163 is a sub-second reconnect-churn window, a 1 s TTL fully
covers a burst while staying responsive to a real setting change on the next event.

**Manual re-evaluate must read fresh.** `forgetStickyInsets()`
(`Monitor.swift:170-175`) is the "re-evaluate like on app start" the Dock Shield's
manual button uses. It currently clears `stickyInset` and `lastAXProbe`; add
`lastAutohideProbe = nil` there too (under the existing lock — no CFPreferences
call), so a user-requested re-evaluation re-reads the live autohide state instead
of serving a stale memo:

```swift
static func forgetStickyInsets() {
    lock.lock()
    defer { lock.unlock() }
    stickyInset.removeAll()
    lastAXProbe = nil
    lastAutohideProbe = nil   // #163: re-read live autohide on manual re-evaluate.
}
```

### Step 2 — extract a tiny Dock-axis reclaim helper (YAGNI-justified)

The auto-hide branch and the existing `dockIsOnAnotherDisplay` branch both need the
identical "reclaim the Dock-orientation axis, keep the orthogonal edge" switch that
currently lives inline in `stableVisibleFrame` (the `switch orientation { … }` at
`Monitor.swift:267-276`). Two concrete call sites with byte-identical logic justify
one nested helper — this is deduplication of existing code, not speculation. Keep
it a nested `func` capturing `frame`, exactly like the adjacent
`reclaimUnconfirmedSideReservation` closure (`Monitor.swift:234-244`), so no new
parameter plumbing is introduced.

Add, next to `reclaimUnconfirmedSideReservation` inside `stableVisibleFrame`:

```swift
// Reclaim the Dock-orientation axis back to the physical frame edge, preserving
// the orthogonal (menu-bar/notch) edge carried by `rect`. Shared by the
// dock-on-another-display reclaim and the #163 auto-hide reclaim.
func reclaimDockAxis(from rect: CGRect, orientation: String) -> CGRect {
    var corrected = rect
    switch orientation {
    case "left":
        corrected.size.width = corrected.maxX - frame.minX
        corrected.origin.x = frame.minX
    case "right":
        corrected.size.width = frame.maxX - corrected.origin.x
    default:
        corrected.size.height = corrected.maxY - frame.minY
        corrected.origin.y = frame.minY
    }
    return corrected
}
```

Then replace the inline `switch orientation { … }` inside the
`dockIsOnAnotherDisplay(than: frame)` branch (`Monitor.swift:266-277`) with:

```swift
let corrected = reclaimDockAxis(from: visibleFrame, orientation: orientation)
return reclaimUnconfirmedSideReservation(from: corrected)
```

This is a pure refactor of that branch — same result, no behavior change. Verify
the diff produces identical geometry for each orientation case.

### Step 3 — add the auto-hide gate before any learn

Insert the gate after `effectiveOrientation` is resolved and after the two nested
reclaim helpers are defined — i.e. immediately before the
`if dockIsOnAnotherDisplay(than: frame)` check (around `Monitor.swift:262`). Using
`effectiveOrientation` (which trusts an AX-confirmed side bar over a possibly-nil
`orientation` pref) picks the correct axis for a side auto-hide Dock too.

```swift
// #163: An auto-hide Dock reserves no permanent band. Its AXList bar top-edge only
// animates on-screen during a reveal, and a display reconfiguration animates it in
// exactly as Monitor.current() rebuilds — sampling it mid-reveal otherwise learns a
// sticky 64/78-pt inset that outlives the reveal forever. When the persistent Dock
// preference is authoritatively auto-hide, drop any learned inset for this display
// and reclaim the Dock-orientation axis from the live frame, keeping the orthogonal
// menu-bar edge. A nil/unreadable preference is treated conservatively as fixed, so
// fixed Docks and quick-terminal suppression keep the existing stabilization.
if dockAutohideEnabled() == true {
    lock.lock()
    stickyInset[displayId] = nil
    lock.unlock()
    let corrected = reclaimDockAxis(from: visibleFrame, orientation: effectiveOrientation)
    return reclaimUnconfirmedSideReservation(from: corrected)
}
```

**Why the second `reclaimUnconfirmedSideReservation` wrapper is intentional and
safe.** It is not redundant with `reclaimDockAxis`, and it never re-adds an inset:

- For a **bottom** Dock, `reclaimDockAxis` touches only the y-axis (restores
  `origin.y = frame.minY`, extends height). The wrapper touches only the x-axis:
  it strips any phantom left/right inset macOS bakes into `visibleFrame` on an
  offset secondary display (the same phantom the `dockIsOnAnotherDisplay` branch
  clears). The two act on orthogonal axes, so the bottom reclaim is preserved and
  any orthogonal side phantom is cleared.
- For a **side** Dock, `reclaimDockAxis` already reclaims that same x-axis to the
  physical frame edge; the wrapper then re-clamps the identical axis from the
  original `liveLeftInset`/`liveRightInset` (closure-captured from the pre-reclaim
  `visibleFrame`) to the *same* physical edge — an idempotent no-op producing the
  same rect, plus it clears a phantom on the opposite side if present.
- In all cases the orthogonal menu-bar/notch edge carried by `visibleFrame` is
  untouched by both functions, so it is preserved.

This mirrors exactly what the existing `dockIsOnAnotherDisplay` branch does
(`reclaimUnconfirmedSideReservation(from: corrected)` after its axis switch), so
the auto-hide path stays consistent with established behavior.

### Step 4 — correct the now-stale comments (exact replacement text)

Two comments assert the opposite of the new behavior. Replace them verbatim with
the text below; edit comment text only, do not restructure surrounding code.

**(a)** Replace the block comment at `Monitor.swift:183-187`, currently:

```swift
// The Dock inset is treated as a stable property: once learned it is applied
// permanently, regardless of the live reservation flapping (a quick-terminal or
// an auto-hide Dock hides/reveals it constantly). This keeps the shield and the
// working area rock-stable — no re-tile when the Dock hides. We intentionally do
// NOT try to detect auto-hide and reclaim the band.
```

with:

```swift
// A fixed Dock's inset is treated as a stable property: once learned it is applied
// permanently, regardless of the live reservation flapping (a quick-terminal that
// suppresses the Dock via presentationOptions hides/reveals it constantly). This
// keeps the shield and the working area rock-stable — no re-tile when the Dock
// hides. An auto-hide Dock is different: it reserves no permanent band, so it is
// detected via the persistent com.apple.dock autohide preference (see the gate
// above) and has its band reclaimed rather than learned (#163).
```

**(b)** Replace the `enum DockReservation` doc comment at `Monitor.swift:134-149`,
currently:

```swift
/// Keeps the working area stable against transient loss of the Dock's reserved space.
///
/// `NSScreen.visibleFrame` reflects the *current* Dock reservation, which vanishes
/// globally whenever the active application suppresses the Dock via
/// `NSApplication.presentationOptions` (drop-down terminals commonly set
/// `.autoHideDock`). With a fixed Dock that makes the reported working area flap
/// between Dock-inset and full width as focus moves, retiling the workspace and
/// re-parking hidden windows each time. This helper remembers the last non-zero
/// Dock inset per display + Dock orientation + screen frame and keeps applying it
/// while the Dock is configured as fixed (`autohide == false`), so Nehir's working
/// area stays Dock-inset even when the instantaneous reservation is suppressed.
///
/// Known limitation: if a fixed Dock is relocated to another display without an
/// orientation or screen-frame change (bottom Dock dragged across displays with
/// separate Spaces), the previous display keeps its cached inset until the Dock
/// settings or display configuration change.
```

with:

```swift
/// Keeps a fixed Dock's working area stable against transient loss of its reserved
/// space, and reclaims the band for an auto-hide Dock.
///
/// `NSScreen.visibleFrame` reflects the *current* Dock reservation, which vanishes
/// globally whenever the active application suppresses the Dock via
/// `NSApplication.presentationOptions` (drop-down terminals commonly set
/// `.autoHideDock`). With a fixed Dock that makes the reported working area flap
/// between Dock-inset and full width as focus moves, retiling the workspace and
/// re-parking hidden windows each time. This helper remembers the last non-zero
/// Dock inset per display + Dock orientation + screen frame and keeps applying it,
/// so Nehir's working area stays Dock-inset even when the instantaneous reservation
/// is suppressed.
///
/// This stabilization is only correct for a fixed Dock. An auto-hide Dock reserves
/// no permanent band — its AX bar only animates on-screen during a reveal — so when
/// the persistent `com.apple.dock autohide` preference is authoritatively enabled,
/// the learned inset is dropped and the Dock-orientation axis reclaimed (#163). A
/// nil/unreadable preference is treated conservatively as fixed.
///
/// Known limitation: if a fixed Dock is relocated to another display without an
/// orientation or screen-frame change (bottom Dock dragged across displays with
/// separate Spaces), the previous display keeps its cached inset until the Dock
/// settings or display configuration change.
```

## Runtime acceptance criteria

Validate in the real runtime before any test work. Two behaviors must both hold.

### A. Auto-hide reconnect (the #163 repro) is fixed

1. Configure a **bottom auto-hide** Dock (`com.apple.dock autohide = 1`).
2. Start with built-in + external displays and full-height Nehir windows.
3. **Deterministic known-failing repro (required, before/after):** move the cursor
   to the Dock edge so the Dock is **fully revealed**, and — while it stays
   revealed under the cursor — disconnect the external cable. This pins the
   `AXList` bar's top-edge at its maximum at the instant the topology-change rebuild
   runs, so the surviving display learns the `78`/`64`-point band **100% of the
   time**. Confirm the band is present pre-fix and **gone post-fix**. This
   reveal-then-disconnect before/after is the primary acceptance signal; it is
   preferred over a casual reconnect precisely because it is deterministic (a
   casual reconnect only reproduces when the sample happens to land mid-reveal).
4. **Reverse direction (non-regression only):** exercise the opposite transition
   too and confirm it stays clean after the fix. Inability to make the reverse
   direction reproduce the gap *before* the fix is **not** a validation failure —
   the bug is intermittent and topology-dependent, so a reverse direction that
   never shows the gap is an acceptable non-regression pass, not a blocker.
5. Every auto-hide Dock host keeps the full Dock-axis working area — only the
   menu-bar/workspace-bar/user-gap struts remain; no `64`/`78`-point bottom band.
6. Niri target frames for the affected windows no longer carry the bottom offset
   (e.g. no `y=85`/`y=64` origin manufactured from the Dock band).
7. Restarting Nehir is no longer required to clear the gap.

### A′. The autohide read stays true across the reconnect window

The gate only fixes #163 if `dockAutohideEnabled()` reports `true` throughout the
reconnect churn (including any transient-nil read served by the last-value
fallback). Confirm it directly, without editing tests:

- Temporarily add a `LayoutTrace.log(...)` line at the auto-hide gate recording
  the resolved value (and whether it came from a fresh read or the fallback) each
  time `stableVisibleFrame` runs during the repro; **or** inspect an existing
  runtime trace across the disconnect/reconnect window.
- Acceptance: across the entire reconnect window the resolved autohide value stays
  `true` for the auto-hide Dock — no rebuild classifies the display as fixed and
  re-arms the sticky learn. If a transient `nil` occurs mid-window, verify the
  fallback returned the prior `true` rather than `nil`.
- **This instrumentation is temporary.** Any added `LayoutTrace.log` line must be
  removed before commit. It is a log line, not a test — it does not touch
  `Tests/NehirTests/**` and does not violate the no-test-edits gate.

### B. Fixed-Dock quick-terminal behavior is preserved

1. Configure a **fixed** Dock (`com.apple.dock autohide = 0`).
2. Open a quick terminal that transiently suppresses the Dock via
   `presentationOptions`.
3. The learned Dock reservation stays stable — the working area does not flap to
   full width and back, and the Dock Shield does not disappear/reappear on toggle
   (the persistent `autohide` preference is still `0`, so the gate does not fire).

## Fast gate and full suite (this repo's mise tasks)

Run from the main Nehir checkout.

- **Fast gate between steps:** `mise run build` (debug build; must print
  `Build complete`). No tests here.
- **Full gate once at the end:** `mise run check` (SwiftFormat check + SwiftLint +
  build + test). This runs the **existing** suite as a regression check; it does
  not authorize adding or editing tests (see below). `mise run check` requires
  Xcode, not just CommandLineTools.
- If a fast pre-test signal is wanted before the full gate: `mise run format:check`
  and `mise run lint`.

## Test gate (overrides any generic template) — historical; satisfied

*(Historical note: this gate was honored. The user confirmed the fix in the
real reconnect repro, after which the deferred regression tests landed as
`Tests/NehirTests/DockAutohideReservationTests.swift` in `fe0596b6`.)*

Per `docs/TESTING.md`, **do not add, modify, move, or delete any test until the
user confirms the fix works in their real reconnect repro.** This overrides any
generic "write a regression test" planning step; there is no implementation
checkbox in this plan that authorizes test changes.

Deferred, post-confirmation only (do **not** do as part of this changeset): after
the user confirms criterion A and B in the real runtime, a small, targeted
Swift Testing regression test for `DockReservation.stableVisibleFrame` may be
added — asserting that with `autohide == 1` a positive live/AX bottom inset is
reclaimed to `origin.y = frame.minY` and full height, while `autohide == 0`
preserves the learned inset. Adding that test is a separate follow-up gated on
confirmation, not part of this plan's implementation.

## Required changeset

After the code change, create the release-note fragment via the mise task (it
writes the fragment file; do not author it by hand):

```bash
mise run changeset -- --contributors dagrlx patch \
  "Fix external-monitor reconnect leaving a Dock-height gap at the bottom when the Dock is set to auto-hide"
```

The changeset summary and the PR/commit must carry `Fixes #163` (bare `#163` is a
Nehir issue, which is correct here). Contributor: `dagrlx`.

## Commit message shape (plain English)

A single commit on a topic branch off `main`. Subject and body in plain English,
for example:

```
Gate Dock reservation stickiness on the persistent auto-hide preference

DockReservation kept applying a learned Dock inset even when the Dock is set to
auto-hide. During an external-display disconnect/reconnect the Dock's AX bar
animates into view just as monitors are rebuilt, so a mid-reveal top-edge sample
was learned as a permanent 64/78-point bottom reservation and Niri laid windows
out inside the reduced working area, leaving a gap only a restart cleared.

Read the persistent com.apple.dock autohide preference (synchronized first). When
auto-hide is authoritatively enabled, drop any learned inset for the display and
reclaim the Dock-orientation axis from the live frame, keeping the menu-bar edge.
A nil/unreadable preference is treated conservatively as fixed, so fixed Docks and
quick-terminal suppression keep the existing stabilization.

Fixes #163

Co-Authored-By: ...
```

Keep the body factual and present-tense about current behavior; no references to
prior sessions or drafts.

## Worker completion token

Print the token only when **all** of the following hold:

- `mise run build` is green and `mise run check` passes (existing suite, no test
  edits).
- Criterion **A** demonstrated: the known-failing direction reproduced the gap
  before the fix and no longer does after; the reverse direction is a clean
  non-regression pass.
- Criterion **A′** demonstrated: the autohide read stayed `true` across the
  reconnect window (fresh reads or last-value fallback), evidenced by a temporary
  log line or trace inspection.
- Criterion **B** demonstrated: a fixed Dock keeps its stable reservation under
  quick-terminal suppression.
- Any temporary instrumentation added for A′ has been **removed**; the final diff
  touches only `Sources/Nehir/Core/Monitor/Monitor.swift` plus the generated
  changeset fragment, and no file under `Tests/NehirTests/**`.
- The changeset was created via `mise run changeset` with `--contributors dagrlx`.

Then print exactly:

`NEHIR-163-AUTOHIDE-DOCK-GATE-COMPLETE-b7c1e4`
