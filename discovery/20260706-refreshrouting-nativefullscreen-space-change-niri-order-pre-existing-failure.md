# Pre-existing test failure: RefreshRoutingTests native-fullscreen space-change niri order

Groom 2026-07-07: still applicable — the failing test `RefreshRoutingTests.nativeFullscreenSpaceChangeRetainsMultiColumnNiriOrderWithSameWindowId` is still present in `Tests/NehirTests/RefreshRoutingTests.swift` and no fix or quarantine has landed, so `mise run check` remains red on this test; re-run against current main to confirm and either fix or quarantine (verified against main 7a025b78).

Status: discovery (unresolved, needs investigation). Observed against `main` on
2026-07-06 (`nehir v0.6.0`).

## Symptom

`swift test` (and therefore `mise run check`) is **red on a clean `main`
checkout** due to a single failing test:

```
✘ Test nativeFullscreenSpaceChangeRetainsMultiColumnNiriOrderWithSameWindowId()
  recorded an issue at RefreshRoutingTests…
```

Test: `RefreshRoutingTests.nativeFullscreenSpaceChangeRetainsMultiColumnNiriOrderWithSameWindowId`.

## Provenance

Surfaced while merging [[20260706-thunderbird-gecko-dialog-float-builtin]]. The
delegated worker reported `mise run check` not green and blamed this test as
unrelated. Confirmed independently: checked out clean `main` (no gecko changes)
and ran the single test in isolation —

```
swift test --filter RefreshRoutingTests.nativeFullscreenSpaceChangeRetainsMultiColumnNiriOrderWithSameWindowId
```

— it fails there too. The gecko change touches only `WindowRuleEngine.swift` +
its tests and cannot affect refresh routing, so this failure is pre-existing and
independent.

## Why it matters

It masks the green state of any branch that runs the full gate, forcing reviewers
to reason about "is my failure or the ambient one?" on every merge. It should be
either fixed or explicitly quarantined so `mise run check` is a trustworthy gate
again.

## Next steps (not yet done)

- Determine whether it is a genuine regression or a flaky/environment-sensitive
  test (name suggests native-fullscreen + macOS Space change + niri multi-column
  ordering with a reused windowId — timing/space-observation sensitive).
- `git bisect` on `main` to find where it started failing, or check CI history to
  see whether CI is also red (if CI is green, it is environment/machine-specific
  and the discovery should note the divergence).
- Source entry points to inspect: `RefreshRoutingTests.swift` (the failing case)
  and the refresh-routing path it exercises under a native-fullscreen space
  change. Cite file + line once located.

Left as a standalone discovery rather than a plan until root cause is known.
