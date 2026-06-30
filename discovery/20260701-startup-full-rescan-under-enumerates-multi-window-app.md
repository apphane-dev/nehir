# Startup full-rescan under-enumerates a multi-window app's AX windows — Discovery

Discovery (2026-07-01). At cold start, a single per-app AX windows query made
during the startup full rescan returned **1 of 3** windows for a multi-window
Electron app (VS Code Insiders, `com.microsoft.VSCodeInsiders`, pid `54505`).
The other two windows were real, on-screen, AX-owned windows — confirmed by
`axWindowsCount=3 axContainsWindow=true` for each — but were listed under
"Visible Unmanaged WindowServer Windows" for the first ~7 seconds of the
session, while the workspace's Niri layout opened with one column fewer than
it should have. They were only admitted later, one at a time, as separate
`AXFocusedWindowChanged` events for each window individually reached the
**focused-admission** path — not via a second full rescan.

This is the same failure class as
[`20260630-visible-unmanaged-windows-admitted-late-as-columns.md`](20260630-visible-unmanaged-windows-admitted-late-as-columns.md)
(a Helium/Electron app with 2 of 3 windows unmanaged until an unrelated create
event triggered a pid-wide re-enumeration that swept both in at once). See
"Relationship to the Helium discovery" below for why these are very likely one
root cause with two different recovery triggers, not two different bugs.

All code citations verified against the main Nehir source tree at `472f7185`
on 2026-07-01 (`git log -1 --format='%h %s' main` → `472f7185 Add
focused-window app rule action across surfaces`). Line numbers will drift;
functions are named so they remain findable.

---

## TL;DR

- **Symptom.** Cold start with several apps already running. The Niri layout's
  very first build (from an empty workspace) seats 6 windows — Helium
  (`1199`), Slack (`215`), Safari (`4691`), Teams (`554`), one VS Code Insiders
  window (`5960`), and a second VS Code Insiders window (`3583`, a different
  pid). Two more VS Code Insiders windows for the **same pid** as `5960`
  (`3922`, `2194`) are visible on screen and AX-confirmed (`axWindowsCount=3
  axContainsWindow=true` for both) but are listed under "Visible Unmanaged
  WindowServer Windows" instead of being seated alongside `5960`.
- **Recovery.** ~7 seconds later, an unrelated app activation
  (`focus_lease_changed owner=native_app_switch
  reason=workspaceDidActivateApplication`) leads to `AXFocusedWindowChanged`
  notifications for `3922` and then `2194` individually. Each is admitted
  through the **focused-admission** path
  (`window_decision … context=focused_admission`,
  `create_placement_resolved … context_source=ax_focused_admission_synthesized`),
  landing as new columns one after another: the workspace goes 6 → 7 (`3922`
  admitted) → 8 (`2194` admitted) columns, two separate Niri insertions ~1s
  apart, not one batched insertion.
- **No second full rescan ran.** Across the whole ~8.4s capture, exactly one
  full-rescan execution is recorded (`fullRescan=0` at capture start →
  `fullRescan=1` at capture end) — the startup rescan itself. So `3922`/`2194`
  were never picked up by a routine re-scan; they were only recovered because
  each one individually happened to take AX focus.
- **Root cause (most likely).** The startup full rescan's per-app AX windows
  query for pid `54505` — `AppAXContext.getWindowsAsync()` reading
  `kAXWindowsAttribute` — returned only `5960` out of that pid's three windows
  at the moment it ran. This is the same query used everywhere else in Nehir
  (`AXManager.fullRescanEnumerationSnapshot()` for full rescans,
  `WMController.reevaluateWindowRules`'s `.pid` branch for targeted
  re-evaluation), so an incomplete result from it is silently treated as "that
  is the app's complete window list" — there is no follow-up query to confirm
  the list is stable once the per-app AX context settles.
- **Why this is plausible at cold start specifically.** `AppAXContext.getOrCreate`
  (`Sources/Nehir/Core/Ax/AppAXContext.swift:145`) spins up a **dedicated
  background thread per pid** to create the `AXUIElement`/`AXObserver` pair,
  with up to a 2-second creation budget
  (`Sources/Nehir/Core/Ax/AppAXContext.swift:184`,
  `try? await Task.sleep(for: .seconds(2))`). The full rescan additionally
  wraps each per-app `getWindowsAsync()` call in a 0.5s timeout
  (`perAppTimeout`, `Sources/Nehir/Core/Ax/AXManager.swift:12`,
  used at `Sources/Nehir/Core/Ax/AXManager.swift:495`). At cold start, several
  apps' AX contexts are being created concurrently, competing for the AX
  subsystem; an Electron app whose own internal window/renderer bookkeeping is
  still settling right after launch is a believable case for
  `kAXWindowsAttribute` returning a partial list on the very first query — and
  Nehir has no mechanism to notice the list was partial and re-check.

---

## Topology / initial state

Single display, `ID(displayId: 1)`, notch, frame `(0.0, 0.0, 2056.0, 1329.0)`,
visible frame `(0.0, 0.0, 2056.0, 1290.0)`. `displaySpacesMode=enabled`,
`focusFollowsMouse=false`. The capture starts at the very beginning of the
session: `startedServices=false`, `windows total=0`, and "Managed Windows" is
empty — i.e. the capture spans the startup full rescan itself.

At the moment the capture's window dump is taken (immediately after the
startup rescan completes), the unmanaged-window list shows:

```text
-- Visible Unmanaged WindowServer Windows --
windowId=5960 pid=54505 owner=Code - Insiders bundleId=com.microsoft.VSCodeInsiders
  title="LayoutProcess.swift — swift-client" frame={{2055.0, 71.0}, {972.0, 1226.0}}
  axWindowsCount=3 axContainsWindow=true
windowId=3922 pid=54505 owner=Code - Insiders bundleId=com.microsoft.VSCodeInsiders
  title="Model.swift (Working Tree) (Model.swift) — kaynak" frame={{1967.0, 71.0}, {972.0, 1226.0}}
  axWindowsCount=3 axContainsWindow=true
windowId=2194 pid=54505 owner=Code - Insiders bundleId=com.microsoft.VSCodeInsiders
  title="http.d.mts — modern-stack" frame={{2055.0, 71.0}, {972.0, 1226.0}}
  axWindowsCount=3 axContainsWindow=true
```

Note `axWindowsCount=3` on **all three** lines: AX consistently reports the
app has exactly three windows by the time this dump is taken, and all three
ids are in that list (`axContainsWindow=true`). So by the time the debug dump
ran, AX itself already knew about all three windows — the question is what
the *startup rescan's own* query saw a moment earlier.

The Niri insertion trace shows the startup rescan seating six windows from an
empty workspace, with VS Code's `5960` among them but `3922`/`2194` absent:

```text
token=…1199 beforeColumns=0 reference=empty_workspace landedColumn=0
token=…215  beforeColumns=0 reference=empty_workspace landedColumn=5
token=…4691 beforeColumns=0 reference=empty_workspace landedColumn=4
token=…554  beforeColumns=0 reference=empty_workspace landedColumn=3
token=…5960 beforeColumns=0 reference=empty_workspace landedColumn=2
token=…3583 beforeColumns=0 reference=empty_workspace landedColumn=1
```

Six columns, six windows, all `beforeColumns=0` (same admission batch). `3922`
and `2194` (same pid as `5960`) are not in this batch.

---

## What the evidence proves

### 1. `3922` and `2194` are admitted individually, ~7s later, via focused admission — not via a second rescan

```text
event=focus_lease_changed owner=native_app_switch reason=workspaceDidActivateApplication
window_decision token=WindowToken(pid: 54505, windowId: 3922) context=focused_admission
  existingMode=nil disposition=managed source=heuristic outcome=trackedTiling
create_placement_resolved token=WindowToken(pid: 54505, windowId: 3922) …
  context_source=ax_focused_admission_synthesized focused_workspace_source=confirmed_focus
event=window_admitted token=WindowToken(pid: 54505, windowId: 3922) mode=tiling
event=window_admitted token=WindowToken(pid: 54505, windowId: 2194) mode=tiling
```

The Niri insertion trace confirms two **separate** insertions, ~1s apart, not
one batched insertion:

```text
token=…3922 beforeColumns=6 reference=selected_node landedColumn=6   ← 6 → 7 columns
token=…2194 beforeColumns=7 reference=focused_token  landedColumn=7   ← 7 → 8 columns
```

`context=focused_admission` and `context_source=ax_focused_admission_synthesized`
are emitted by `admitFocusedWindowBeforeNonManagedFallback`
(`Sources/Nehir/Core/Controller/AXEventHandler.swift:2199`) and
`ensureCreatePlacementContextForFocusedAdmission`
(`Sources/Nehir/Core/Controller/AXEventHandler.swift:4343`) — the same
per-window, focus-triggered admission path documented in
[`20260625-vscode-focused-admission-skips-managed-replacement-rekey.md`](20260625-vscode-focused-admission-skips-managed-replacement-rekey.md).
Each window only becomes visible to Nehir when *that specific window* takes
AX focus; there is no batched recovery here because nothing re-queried
`kAXWindowsAttribute` for the whole pid in between.

### 2. Exactly one full-rescan execution happened in the whole capture

The refresh-execution counters at the start and end of the capture:

```text
fullRescan=0 relayout=0 immediateRelayout=0   visibility=0 windowRemoval=0   (at capture start)
fullRescan=1 relayout=2 immediateRelayout=103 visibility=0 windowRemoval=1   (at capture end)
```

One full rescan ran — the startup one (`RefreshReason.startup` routes to
`.fullRescan`, `Sources/Nehir/Core/Controller/RefreshReason.swift:81`, fired
from `ServiceLifecycleManager.performStartupRefresh()`,
`Sources/Nehir/Core/Controller/ServiceLifecycleManager.swift:226-227`). No
second full rescan ran during the ~7s window in which `3922`/`2194` sat
unmanaged. So whatever picked them up later was not "the rescan eventually
ran again and caught them" — it was the focused-admission path reacting to
unrelated focus events.

### 3. The startup rescan's per-app AX query is the one shared code path that could produce this

`AXManager.fullRescanEnumerationSnapshot()`
(`Sources/Nehir/Core/Ax/AXManager.swift:451`) is what the startup rescan calls
(via `LayoutRefreshController.buildFullRefreshExecutionPlan`,
`Sources/Nehir/Core/Controller/LayoutRefreshController.swift:1219`). For each
app it discovers via SkyLight/CGWindowList, it does:

```swift
// Sources/Nehir/Core/Ax/AXManager.swift:485-509 (paraphrased)
for app in apps {
    group.addTask {
        guard let context = try await AppAXContext.getOrCreate(app) else { … }
        let appWindows = try await self.withTimeoutOrNil(seconds: perAppTimeout) {
            try await context.getWindowsAsync()
        }
        …
    }
}
```

`perAppTimeout` is `0.5` seconds
(`Sources/Nehir/Core/Ax/AXManager.swift:12`). `AppAXContext.getOrCreate`
(`Sources/Nehir/Core/Ax/AppAXContext.swift:145`) creates a **brand-new
dedicated thread** per pid that calls `AXUIElementCreateApplication` and sets
up an `AXObserver`, with up to a **2-second** creation timeout
(`Sources/Nehir/Core/Ax/AppAXContext.swift:184`). `getWindowsAsync()`
(`Sources/Nehir/Core/Ax/AppAXContext.swift:378`) then queries
`kAXWindowsAttribute` once and returns whatever AX hands back at that instant.

There is no retry, no second query, and no comparison against
`CGWindowListCopyWindowInfo`'s on-screen window count for the same pid to
detect "this app has more windows than AX just reported." If
`kAXWindowsAttribute` returns a partial list — plausible for an Electron app
whose own window bookkeeping is still settling moments after a context switch
or relaunch, especially while several other apps' AX contexts are being
created concurrently at cold start — that partial list becomes the seed of the
startup admission, and Nehir has no mechanism to revisit it absent some other
event (here, focus) touching the missing windows individually.

### 4. `failedPIDs` does not cover this case

`buildFullRefreshExecutionPlan`
(`Sources/Nehir/Core/Controller/LayoutRefreshController.swift:1215`) does
track `enumerationSnapshot.failedPIDs` — pids whose `getWindowsAsync()` call
threw or timed out entirely — and uses that set to **preserve already-tracked
entries** from being removed
(`Sources/Nehir/Core/Controller/LayoutRefreshController.swift:1519-1523`). But
pid `54505`'s call did not fail outright; it *succeeded* and returned one
window. `failedPIDs` has nothing to say about a query that succeeded but
returned an incomplete list — there is no signal at all that distinguishes
"this app genuinely has one window" from "this app has three windows and AX
only reported one."

---

## Relationship to the Helium discovery (same root cause, different recovery trigger)

[`20260630-visible-unmanaged-windows-admitted-late-as-columns.md`](20260630-visible-unmanaged-windows-admitted-late-as-columns.md)
documents Helium (`net.imput.helium`, pid `22641`) with 2 of 3 AX-owned windows
unmanaged, recovered **together, in one batch**, when an unrelated auxiliary
surface (`6814`) was created and the resulting relayout swept both unmanaged
windows in as new columns at once.

This discovery and that one are best read as **one underlying defect with two
different recovery triggers**, not two separate bugs:

- **Shared mechanism.** Both are "a multi-window Electron-style app has fewer
  managed windows than AX-owned windows," and in both cases the unmanaged
  windows are real, full-size, `axContainsWindow=true` windows sitting in
  "Visible Unmanaged WindowServer Windows" for an extended period with no
  record of ever being rejected or even seen by the create pipeline. Neither
  capture shows a `create_seen` for the unmanaged ids — consistent with the
  same failure mode this discovery names: the per-app `kAXWindowsAttribute`
  query that should have listed them simply didn't, at the time it ran.
- **Why the recovery shape differs.** What differs between the two captures is
  *what touches the pid next*:
  - Here (VS Code), each missing window happens to take **AX focus**
    individually (driven by an unrelated app-switch), so each is recovered
    one at a time through `admitFocusedWindowBeforeNonManagedFallback` — a
    per-*window* path. Two missing windows → two separate column insertions,
    ~1s apart.
  - In the Helium capture, an **unrelated CGS `.created` event for the same
    pid** (`6814`, a transient auxiliary surface) is the kind of event that
    plausibly triggers `scheduleWindowRuleReevaluationIfNeeded(targets:
    [.pid(pid)])` (called from several sites in
    `Sources/Nehir/Core/Controller/AXEventHandler.swift`, e.g. line 628, 1252,
    1480, 2234, 3494, 3496) →
    `WMController.reevaluateWindowRules`'s `.pid` branch
    (`Sources/Nehir/Core/Controller/WMController.swift:3883-3908`), which
    calls `axManager.windowsForApp(app)` — a **fresh, full per-app window
    query for that pid**, the same `getWindowsAsync()` call as the startup
    rescan uses, just scoped to one pid. If *that* query succeeds and now
    returns all three windows (AX context has since settled), both
    previously-missing windows surface in the same pass → one batched
    insertion of two columns.
- **Both bottom out in the same query.** `AXManager.fullRescanEnumerationSnapshot()`
  (startup/full-rescan path) and `WMController.reevaluateWindowRules`'s `.pid`
  branch (targeted re-evaluation path) both ultimately call
  `AppAXContext.getWindowsAsync()` for the pid in question. Neither capture
  shows any other plausible point where windows could be silently dropped and
  then later recovered in exactly this shape (no removal event for the
  "missing" ids in either capture, no rejection trace, no `create_seen` for
  the missing ids — they simply weren't reported by whichever
  `getWindowsAsync()` call ran first).

**Working conclusion: same root cause.** Treat the two discoveries as one
defect — *the per-app AX windows query can return an incomplete list for a
multi-window app, and Nehir has no mechanism to detect or correct that short
of an incidental, unrelated event eventually touching the missing
windows* — with the difference in user-visible shape (staggered single-column
pop-in vs. batched multi-column pop-in) fully explained by which incidental
event happens to fire first (per-window focus vs. per-pid reevaluation). A fix
that makes Nehir re-confirm a pid's window list after admission (rather than
trusting the first successful query as final) should resolve both.

---

## What would make this conclusive (not yet proven)

- **Whether the very first per-app query for pid `54505` actually returned 1
  window, vs. 3 windows that were filtered out downstream.** This discovery
  infers the query returned 1 window because: (a) no other code path between
  `fullRescanEnumerationSnapshot` and `addWindow` is visible in the trace for
  `3922`/`2194` (no `window_decision`/rejection record at startup time for
  either id), and (b) the eventual admission of both goes through the
  *create-candidate* pipeline (`ensureCreatePlacementContextForFocusedAdmission`
  → `prepareCreateCandidate`), which is the same pipeline used for windows AX
  has never told Nehir about before — not a "previously rejected, now
  reconsidered" pipeline. But the capture does not log the raw
  `kAXWindowsAttribute` result count at the moment the startup rescan's query
  ran, so this is the strongest available inference, not a direct
  observation.
- **Whether this reproduces reliably at cold start, or is a rare race.** One
  capture is not enough to know the hit rate. A repeat capture across several
  cold starts, ideally with several Electron-style multi-window apps already
  open, would establish whether this is common (worth fixing urgently) or
  rare (lower priority).
- **Whether `AppAXContext.getOrCreate`'s context-creation latency for pid
  `54505` specifically was the proximate cause**, vs. some other AX-subsystem
  contention at cold start. The capture does not log how long context creation
  took for this pid.

---

## Tracing improvements that would close the gap

Same shape as the three gaps already named in the Helium discovery — both
discoveries would benefit from the same additions:

1. **Log the raw per-app AX windows-attribute result** (count + ids) at the
   point `AppAXContext.getWindowsAsync()` returns, for every call — not just
   the ids that make it into `fullRescanEnumerationSnapshot`'s result. This
   would directly show whether the startup query for `54505` returned 1 or 3
   windows.
2. **Cross-check AX-reported window count against CGWindowList's on-screen
   count for the same pid** during full-rescan enumeration, and trace a
   mismatch explicitly (e.g. `ax_window_count_mismatch pid=54505 ax=1
   windowServer=3`). This is the single most direct signal that would have
   confirmed or refuted this discovery's central hypothesis.
3. **Record admission context on `window_admitted`** (already proposed in the
   Helium discovery) so a future capture can distinguish "admitted via
   startup full rescan" / "admitted via focused admission" /
   "admitted via pid reevaluation" without inferring it from surrounding
   events as this discovery had to.

---

## What is still unknown

- Whether the partial AX result is a one-shot cold-start race (AX context
  still settling) or can recur for an already-running app later in a session.
- Whether other multi-window Electron/Chromium apps (Helium, Slack, Chromium
  embedders) hit this at the same rate, or whether VS Code Insiders'
  multi-window/multi-workspace-folder architecture makes it more prone to a
  slow-to-settle `kAXWindowsAttribute` list.
- Whether a fix should re-query proactively (e.g. a short delayed
  confirmation pass after any full rescan or pid reevaluation, scoped to pids
  whose AX context was newly created during that very pass) or reactively
  (compare AX count vs. WindowServer count and re-query only on mismatch). Both
  are consistent with the evidence; neither is implemented today.

---

## Relationship to other discoveries

- **Same root cause (see above):**
  [`20260630-visible-unmanaged-windows-admitted-late-as-columns.md`](20260630-visible-unmanaged-windows-admitted-late-as-columns.md) —
  Helium, batched recovery via pid reevaluation instead of per-window focused
  admission.
- **Adjacent, different layer:**
  [`20260625-vscode-focused-admission-skips-managed-replacement-rekey.md`](20260625-vscode-focused-admission-skips-managed-replacement-rekey.md) —
  about the focused-admission path's *rekey* behavior once a window is
  surfaced via focus. This discovery is about why the window needed
  focused-admission to be surfaced *at all* (it was missing from the prior
  full rescan). The two are compatible: a window that reaches
  focused-admission because of this discovery's root cause could *also* hit
  that plan's rekey gap if it happens to be an identity-churned replacement —
  though in this capture both `3922` and `2194` are genuinely new admissions
  (`existingMode=nil`), not replacements.
- **Adjacent, different layer:**
  [`20260628-chromium-pip-opens-offscreen-never-create-seen.md`](20260628-chromium-pip-opens-offscreen-never-create-seen.md) —
  another "no `create_seen` for a real AX-owned window" case for a
  Chromium-embedded surface; that one is about a PiP window that is *never*
  admitted absent a click, this one is about full-size windows admitted late.
  Both point at the same broader gap: Nehir's admission pipeline has no
  fallback for "AX/CGS never told me about this window through the normal
  channel."
