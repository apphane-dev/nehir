# Lessons Learned — Dock-Edge Parking & Shield

**Status: SHIPPED / MERGED (2026-07-05).** The experimental Dock Shield landed on `main`
("Add experimental Dock Shield for side fixed-Dock setups"). This file captures the
meta-lessons; the technical resolution lives in `docs/offscreen-clamp-fix.md` (RESOLUTION
(2026-07) section).

## What shipped

- Off-screen columns park 1pt inside the working (`visibleFrame`) edge; the reveal is
  clamped to **≥1 point** (not 1 physical pixel) so parks hold on non-Dock edges.
- An opt-in **Dock Shield** (off by default; Settings → Diagnostics → Dock Shield) masks the
  parked-column band behind a side (left/right) fixed Dock — user-set color, opt-in
  opacity, optional system-theme light/dark scheme, top/bottom aligned to the layout gaps.
- The Dock inset is a stable per-display property (survives quick-terminal Dock hiding),
  with an 8px hysteresis so AX bar-measurement jitter doesn't flap the working area/shield;
  a phantom side inset is reclaimed only when the Dock is genuinely on another display.
- Diagnostics: bottom Dock is fine; a side fixed Dock is a dismissable experimental notice
  offering the shield, and such notices don't drive the warning badge.

## Known remaining limits (NOT solved by the shield)

- **True hiding is still positional parking**, not a WindowServer order-out. The shield only
  *masks* the strip on the Dock edge.
- **App-specific clamp**: Chromium/Electron windows (VS Code Insiders, Helium browser) clamp
  a right park to `visibleFrame.maxX − ~40`, leaving a ~43px strip *inside* the workspace
  that the shield does not cover — EUI-off included, reverify loses. Native apps park fine.
  This is the Dock-edge "wall"; see the virtual-display and horizontal-arrangement discovery
  docs, still open for the true-hide case.
- **Side-by-side (horizontal) arrangement**: a column hidden toward a shared monitor edge
  flips to the far edge (overlap-avoidance) and appears to teleport/disappear. Deferred.

## Diagnosis discipline

- **Instrument into a channel that survives to capture time.** `AXManager.recordFrameApplyTrace`
  is a 200-entry ring buffer; a once-on-create log (e.g. the shield's) is evicted long before
  the trace is written, so its *absence proved nothing*. The fix that actually let us see state
  was adding a live `debugStateDump()` to the runtime **snapshot** (`-- Dock Edge Shield --`),
  which is rebuilt at capture time. When "is X even happening?" is the question, log into the
  snapshot, not the ring buffer.
- **Read the trace before theorizing; let numbers overturn your model.** Repeatedly, the trace
  contradicted a "confident" conclusion: EUI was blamed for the clamp until a trace showed it
  firing with `euiDisabled=true`; the "WindowServer re-clamps" story was really a missed park;
  the autohide flap was really a stale `CFPreferences` read. Every real fix came from a specific
  observed number (e.g. `1929 = visibleFrame.maxX − 40`, `cached=1011` vs corrected `968`).
- **Verify the hook actually runs.** Two separate bugs were dead code: the self-heal was placed
  in `applyLayoutForWorkspaces` (zero callers) and the shield only updated at two setup sites.
  Grep for callers before trusting that a hook fires.

## Don't churn what works

- The user repeatedly caught regressions where a "cleanup" or experiment broke a previously
  working, documented behavior (the `workingEdgePlacement` reveal=0 change; the physical-edge
  detour; the `extra`-inset double-count). When a subsystem is confirmed-working, prefer the
  smallest possible change and re-confirm at runtime. "It builds" is not confirmation.
- Trust the user's environmental clues — they are ground truth you can't see. "it got right
  after toggling quick terminal", "it happens if the quick terminal is active at start",
  "quick terminal temporarily hides the dock" each pointed straight at the mechanism.

## Design lessons specific to this surface

- **The real invariant beats the elaborate theory.** Months of "Dock edge is unbeatable /
  needs a virtual display" collapsed to: keep ≥1px inside `visibleFrame`. Look for the simple
  acceptance rule before building infrastructure.
- **Derive stable UI geometry from stable inputs.** Anything computed from the live
  `visibleFrame` flaps when the Dock hides/shows. Compute from the physical `frame` + a sticky
  inset instead. A cache key that includes a flaky field (`orientation` from `CFPreferences`,
  which returns nil intermittently) silently defeats stickiness.
- **`CFPreferencesCopyAppValue` for another app's domain is cached** — call
  `CFPreferencesAppSynchronize` first to read another process's write (e.g. Dock `autohide`).
- **An auto-hide Dock still exposes a queryable AX bar** and re-reveals on edge approach — you
  cannot distinguish it from a fixed Dock by geometry, and you cannot place a reliably-clickable
  surface under it. Design around this, don't fight it.
- **Automatic "smart" state detection with a timeout was rejected in favor of an explicit
  manual control.** The debounce that reclaimed the band after 5s of `autohide` also fired on a
  quick-terminal that stayed open, producing unwanted relayouts. The user preferred a permanent
  shield + a manual re-evaluate button. Prefer explicit user control over a heuristic that
  guesses intent from timing.
- **Niri column widths are cached absolute spans**, resolved from `.proportion` against the
  working width at layout time. Changing the working area requires
  `invalidateCachedLayoutSpans()`; a viewport-rect update alone won't reflow windows.

## Process

- Record durable findings in memory/docs as you go — this problem spanned ~20 iterations and
  reversed direction several times; the running log is what kept each round from repeating a
  disproven approach.
- Keep experiments env-gated or clearly reversible, and label them as experiments until a
  runtime trace + visual test confirm them (see the pitfalls in `docs/offscreen-clamp-fix.md`).
