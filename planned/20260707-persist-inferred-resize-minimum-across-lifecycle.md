# Plan: keep the learned resize-minimum across identity-preserving lifecycle events

Re-verified against main 7a025b78 on 2026-07-07.

Source discovery:
`discovery/20260707-inferred-resize-minimum-cleared-causes-refusal-thrash-recurrence.md`.
Read it first. All source references verified against `main` @ `7a025b78` on
2026-07-07; the planned clearing sites remain `Sources/Nehir/Core/Workspace/WindowModel.swift:457`, `:597`, and `:729`.

## Problem (one line)

A learned physical resize-minimum (e.g. Helium `740`) is cleared by AX-ref
self-rekey, float/unfloat, and native-fullscreen transitions — none of which
change the app's physical minimum — so min-width windows re-fight and re-thrash
(refusal `verificationMismatch` bursts) on the next animated proportional resize.

## Fix

The inferred resize-minimum is a physical app/window invariant. Stop discarding it
on lifecycle events that preserve window identity. Keep re-reading the
time-sensitive `cachedConstraints` as today.

### Files to touch

- `Sources/Nehir/Core/Workspace/WindowModel.swift` — remove the
  `entry.inferredResizeMinimumSize = nil` assignment at exactly these three
  identity-preserving sites, leaving the surrounding `cachedConstraints` /
  `constraintsCacheTime` resets untouched:
  1. `rekeyWindow(...)` **self-rekey branch** (`oldToken == newToken`) — the
     assignment currently at `:457`. Same window id + same pid + same app; only
     the AX handle changed.
  2. `setMode(...)` non-tiling branch — the assignment currently at `:597`. A
     window that floats keeps its physical minimum for when it returns to tiling.
  3. `setLayoutReason(...)` non-standard branch — the assignment currently at
     `:729`. Exiting native fullscreen returns the same window at the same
     physical minimum.

### Explicitly do NOT touch

- `:481` (cross-token `rekeyWindow`) and `:420` (`registerWindow` on
  `ruleEffects` change): leave the `inferredResizeMinimumSize = nil` in place for
  this change. Cross-token rekey is a genuine identity change and ruleEffects
  changes can legitimately alter constraints; revisiting these is a separate,
  larger behavioural decision (see discovery Risks).
- `setInferredResizeMinimumSize` (`:809-824`), the learner
  (`LayoutRefreshController.swift:3954-3986`), the solver clamp
  (`NiriNode` / `clampColumnWidthToBounds`), and the counter
  (`WorkspaceManager.swift:381`). Behaviour there is correct; do not add a TTL in
  this change.
- Anything under the Summon Right / cross-display reveal path — that is a
  separate discovery
  (`discovery/20260706-summon-right-cross-display-size-dance.md`) owned by other
  work. Do not touch `WindowActionHandler` / `WorkspaceNavigationHandler` /
  `LayoutRefreshController` reveal transactions here.

## Gate

- Fast gate between steps and once at the end: `mise run check` (or the repo's
  configured `hk check` fast gate — use whatever `AGENTS.md` / `mise tasks`
  expose). Build must stay green.
- **Do not add or modify tests in this change.** Per `AGENTS.md`, wait for the
  user to confirm the fix on their real repro before touching tests. After
  confirmation, a follow-up may add learner-persistence coverage (this dovetails
  with M1 Gap B, the still-open "zero tests cover the learner" deliverable in
  `discovery/20260618-refused-frame-feedback-characterization.md`).

## Runtime validation (acceptance signal — do this, not tests)

Reuse the trace-capture flow. With a known min-width app (Helium, or any app that
refuses to shrink below a fixed width) tiled in a proportional multi-column
workspace so it is assigned a column narrower than its minimum:

1. Trigger the animated relayout once → expect a single `resizeMin.learn id=…
   minimum=…` and `inferredResizeMinimums` to become `>= 1`.
2. Float then unfloat the window; toggle native fullscreen on and off; cause an
   AX-ref refresh (e.g. move it across the differently sized displays).
3. Re-trigger the animated shrink → **pass** = `inferredResizeMinimums` stayed
   `>= 1` throughout, and this second shrink produces **no** new `resizeMin.learn`
   and **no** `verificationMismatch` refusal burst (the column is clamped to the
   remembered minimum immediately). **Fail** = a second learn / refusal thrash
   reappears.

## Changeset

User-visible (removes a visible window "dance"):

```bash
mise run changeset patch "Stop min-width windows from re-fighting their minimum size after floating, fullscreen, or moving between displays"
```

## Commit message shape

Plain-English subject, no Conventional-Commits prefix, nehir-only ticket refs.
E.g.:

```
Keep learned window minimum size across float, fullscreen, and rekey

<body: physical minimum is an app invariant; clearing it on identity-preserving
lifecycle events forced a re-learn and a visible refusal-thrash on the next
animated resize. Reference the discovery.>

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
```
