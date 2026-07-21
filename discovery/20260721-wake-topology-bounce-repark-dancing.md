# Wake topology bounce re-parks windows repeatedly (the "dancing") — Discovery

> Scope: the still-open Finding 2 split out of
> `completed/20260721-wake-scaled-resolution-phantom-dock-inset-shield-and-relayout-runaway.md`
> after Findings 1 (phantom shield) and 3 (relayout runaway) landed in `3baf74d7`.
> Source-backed; **does not propose a fix**. Symbols verified against `main` at
> `3baf74d7`; re-verify before implementing (they drift).

## Symptom

On opening the laptop lid from sleep, windows visibly "dance" for several
seconds — jump, re-park offscreen, re-reveal — as the display configuration
settles. Distinct from the phantom Dock shield (Finding 1, fixed) and the
invisible relayout runaway (Finding 3, fixed); this is the *visible* churn.

## Evidence (inlined; self-contained)

Over a ~2.5-minute wake settle the display topology bounced five times:

```
06:54:41  topology_changed  2->1   interaction 1→3
06:56:58  topology_changed  1->2
06:56:58  topology_changed  2->2
06:57:00  topology_changed  2->1   disconnected_cache=1
06:57:04  topology_changed  1->2   (final: 2 displays)
```

The built-in display's physical frame was read as **both** `2056×1329` and
`1728×1117` within this window (a scaled-mode switch mid-settle). During the
06:54:41 transition the same managed windows flip
`hidden(offscreen) → tiled → hidden(offscreen)` several times inside a single
second, as repeated `window_admitted context=startup_full_rescan` batches re-run.
That repeated park/reveal is the dance. Interaction-monitor writes corroborate the
bounce: `applyTopologyTransition` fires at 06:54:41, 06:56:58 (×2), 06:57:00, and
06:57:04.

## Mechanism (partly source-backed)

Each `topology_changed` / `monitorConfigurationChanged` is inherently a
full-rescan trigger, and each rescan re-parks and re-reveals managed windows.
The pathology is the **number of transitions** during the settle, not any single
rescan. A contributing driver is refresh pre-emption: when a higher-priority
refresh arrives mid-flight, `cancelActiveRefreshForIncoming`
(`LayoutRefreshController.swift`, added in `3baf74d7`) cancels the in-flight
refresh, which returns `didComplete == false` and is re-armed by
`preserveCancelledRefreshState` — so during a bounce the rescan restarts
repeatedly, re-parking each time.

Diagnostics landed in `3baf74d7` to characterise this precisely:
- `refresh.cancel active=<kind>/<reason> incoming=<kind>/<reason>` — which reason
  keeps pre-empting the rescan.
- `refresh.finish kind=… reason=… didComplete=… noProgressReexec=… pendingKind=…`
  — how many no-progress re-executions accumulate and whether a follow-on rescan
  is already queued.

The Finding 3 fix (`maxConsecutiveNoProgressReexecutions = 8`) bounds the
*execution count* of a no-progress spin, but does **not** debounce genuine
topology transitions — five real bounces still drive five real re-park passes.

## Still to confirm before a plan

- **Which reason(s) pre-empt the rescan** during the bounce (read the new
  `refresh.cancel` diagnostics from a fresh wake capture).
- **Whether the fix belongs at the topology layer** (coalesce/debounce
  consecutive `monitorConfigurationChanged` transitions until the configuration
  is stable for N ms — note a 50 ms coalesce already exists at
  `ServiceLifecycleManager.handleMonitorConfigurationChanged`; the wake bounces
  span seconds, so a longer settle window or a stability check is likely needed),
  **or** at the park/reveal layer (suppress visible re-park while topology is
  known-unsettled).
- **Interaction with the scaled-mode frame flip** — the built-in frame flips
  `2056×1329 ↔ 1728×1117` mid-settle; a debounce must key on a *stable* frame,
  not just display count, or it will release too early.

## Where a fix would live (not prescribed here)

- Topology/`monitorConfigurationChanged` rescan scheduling in
  `LayoutRefreshController` / `ServiceLifecycleManager` — debounce or gate visible
  re-parks on a settled configuration.
