# Multi-window app's visible-but-unmanaged windows get admitted as new columns late — Discovery

Discovery (2026-06-30). The reporter has **3 Helium windows** (`net.imput.helium`).
At the moment captured, Nehir manages only **1** of them as a column, so the
workspace shows a single Helium column and a single Helium icon in the workspace
bar. The other two Helium windows exist and are visible in the WindowServer
(Nehir can see them — they are listed under "Visible Unmanaged WindowServer
Windows" and AX confirms they belong to the app), but they are **not managed**.
Then, when Helium creates a small auxiliary surface, the resulting relayout
admits the two previously-unmanaged windows as **two brand-new columns**, so the
workspace jumps from 1 Helium column/icon to 3. To the user this looks like "2
more existing windows suddenly reappear."

So the symptom has two halves:

1. **Under-management at steady state.** Real app windows that are visible and
   AX-owned are left unmanaged (no column, no workspace-bar icon).
2. **Batched late admission.** A single auxiliary-window creation triggers a
   relayout that admits several of those unmanaged windows at once, producing a
   sudden columns/icons pop-in.

The capture **proves the symptom and the net mechanism conclusively**, but it
is **not sufficient to determine the root cause** of why the two windows were
unmanaged in the first place, because neither the create pipeline nor the
reconcile admission path records an admission *context/history* for these two
window ids. That gap, and the tracing additions needed to close it, are
documented below.

All code citations verified against the main Nehir source tree at `472f7185` on
2026-06-30 (`git log -1 --format='%h %s' main` → `472f7185 Add focused-window
app rule action across surfaces`). The capture's own version header is
`nehir v472f71`. Line numbers will drift.

---

## TL;DR

- **Symptom.** 3 Helium windows; only 1 managed column/icon; then 2 more pop in
  as new columns at once.
- **App.** Helium, `net.imput.helium`, pid `22641` — an Electron-style app that
  recycles window ids aggressively.
- **What is managed at capture start.** Only `WindowToken(pid: 22641, windowId:
  1199)` (a Helium window, offscreen, `hidden=layoutTransient(left)`). The other
  Helium windows `windowId: 3416` and `windowId: 6537` are visible in the
  WindowServer at `(2055.0, 71.0, 972.0, 1226.0)` with `axWindowsCount=3,
  axContainsWindow=true` — i.e. AX lists all three as the app's windows, but only
  `1199` is a managed entry.
- **The pop-in.** The Niri insertion trace records the two windows becoming
  columns in quick succession: `token=…6537 beforeColumns=7 → landedColumn=1`
  (8 columns), then `token=…3416 beforeColumns=8 → landedColumn=2` (9 columns).
  After this, 3 Helium windows are managed (`1199`, `6537`, `3416`).
- **The trigger.** The same instant, Helium created a small auxiliary surface
  `windowId: 6814` (`create_seen window=6814`,
  `create_placement_resolved … context_source=cgs_created`), admitted as a
  `220×173` floating rescue window that was destroyed ~1 s later. That creation
  fired the relayout that admitted `3416`/`6537`.
- **Extra churn.** Helium recycles ids, so Nehir's managed-replacement
  correlation rekeys `3416 → 6537` (`window_rekeyed … reason=managedReplacement`)
  and re-admits the same ids several times during the burst.
- **Verdict on evidence.** Sufficient to prove the symptom + net mechanism.
  Insufficient to root-cause *why* `3416`/`6537` were unmanaged: there is no
  `create_seen`/`create_placement_resolved` for either id, and the
  `window_admitted` reconcile event does not record an admission *context*
  (create vs focused-admission vs rescan). See "Tracing gaps."

---

## Topology / initial state

Single display, `ID(displayId: 1)`, notch, frame `(0.0, 0.0, 2056.0, 1329.0)`,
visible frame `(0.0, 0.0, 2056.0, 1290.0)`. `displaySpacesMode=enabled`,
`focusFollowsMouse=false`. Workspace bar enabled, single row.

Active workspace `0E54DE8B-5D1B-4D76-928E-68BC8C952FC2` (workspace 1), the only
visible workspace. Managed focus on the tiled Microsoft Teams window
`WindowToken(pid: 7724, windowId: 554)`.

Managed windows in the workspace (7 total), with the Helium one highlighted:

```text
WindowToken(pid: 7724,  windowId: 554)  teams    tiled   visible
WindowToken(pid: 8764,  windowId: 4691) safari   tiled   visible
WindowToken(pid: 22641, windowId: 1199) helium   offscreen hidden=layoutTransient(left)   ← only managed Helium
WindowToken(pid: 24295, windowId: 215)  slack    offscreen hidden=layoutTransient(right)
WindowToken(pid: 36079, windowId: 3583) vscode   offscreen hidden=layoutTransient(left)
WindowToken(pid: 54505, windowId: 2194) vscode   offscreen hidden=layoutTransient(right)
WindowToken(pid: 54505, windowId: 5960) vscode   offscreen hidden=layoutTransient(left)
```

The Niri layout at start has 7 columns (`c0..c6`); the Helium window `1199` is
column 0 but hidden offscreen, and the two on-screen columns are Teams (`554`,
column 3, selected) and Safari (`4691`, column 4).

The two unmanaged Helium windows are visible in the WindowServer and AX-confirmed
as belonging to the app:

```text
-- Visible Unmanaged WindowServer Windows --
windowId=3416 pid=22641 owner=Helium bundleId=net.imput.helium
  title="Microfrontend Registry Docum… Homepage Surge - Workhuman"
  frame={{2055.0, 71.0}, {972.0, 1226.0}}
  activationPolicy=NSApplicationActivationPolicy(rawValue: 0)
  axWindowsResult=0 axWindowsCount=3 axContainsWindow=true
windowId=6537 pid=22641 owner=Helium bundleId=net.imput.helium
  title="ГДЕ ИСКАТЬ КОРАБЛИ ДРУГИХ …Владимир Сурдин - YouTube"
  frame={{2055.0, 71.0}, {972.0, 1226.0}}
  activationPolicy=NSApplicationActivationPolicy(rawValue: 0)
  axWindowsResult=0 axWindowsCount=3 axContainsWindow=true
```

`axWindowsCount=3` and `axContainsWindow=true` for both mean: AX reports exactly
three windows for pid `22641` (`1199`, `3416`, `6537`) and each of `3416`/`6537`
is in that AX list. So these are not phantoms — they are real, AX-owned,
full-size (`972×1226`) standard windows. Nehir simply has no managed entry for
them. This is the "only 1 column / only 1 Helium icon" state.

---

## What the evidence proves

### 1. The two unmanaged windows become two new columns (the pop-in)

The Niri insertion trace records each column insertion with the column count
before and the landed column index (`Sources/Nehir/Core/Controller/NiriLayoutHandler.swift:507`,
`beforeColumns` at `:510`):

```text
## Niri insertion trace
2026-06-30T21:17:05Z workspace=0E54DE8B… token=WindowToken(pid: 22641, windowId: 6537)
  beforeColumns=7 selectedTokenBefore=…1199 selectedColumnBefore=0
  focusedTokenBefore=…1199 focusedColumnBefore=0 reference=focused_token
  referenceColumn=0 landedColumn=1 landedColumnTokens=…6537
2026-06-30T21:17:06Z workspace=0E54DE8B… token=WindowToken(pid: 22641, windowId: 3416)
  beforeColumns=8 selectedTokenBefore=…6537 selectedColumnBefore=1
  focusedTokenBefore=…6537 focusedColumnBefore=1 reference=focused_token
  referenceColumn=1 landedColumn=2 landedColumnTokens=…3416
```

So the workspace goes 7 → 8 → 9 columns, with `6537` landing at column 1 and
`3416` at column 2. After the burst the settled 9-column layout is
`c0=w1199(hidden:left) | c1=w6537 | c2=w3416:selected | c3=w3583 | c4=w5960 |
c5=w554 | c6=w4691 | c7=w215 | c8=w2194`, i.e. three Helium windows are now
managed. This is exactly "2 more existing windows reappear."

### 2. Admission happens via reconcile `window_admitted`, in a churning burst

The reconcile trace (`## Tracing logs`) shows the lifecycle events. The
Helium-only subset, in order:

```text
#9  21:17:05 window_admitted token=…6814 mode=floating            plan=phase=floating desired=…mode=floating,rescue=true
#15 21:17:05 window_admitted token=…1199 mode=tiling
#17 21:17:05 window_admitted token=…3416 mode=tiling              ← 3416 first admission
#19 21:17:05 window_rekeyed from=…3416 to=…6537 reason=managedReplacement   ← id recycled, rekeyed
#23 21:17:05 managed_focus_requested token=…6537
#24 21:17:05 managed_focus_confirmed token=…6537
#35 21:17:06 window_removed token=…6814
#36 21:17:06 window_admitted token=…1199 mode=tiling
#37 21:17:06 window_admitted token=…3416 mode=tiling              ← 3416 admitted AGAIN
#39 21:17:06 window_admitted token=…6537 mode=tiling              ← 6537 admitted
#41 21:17:06 hidden_state_changed token=…3416 hidden=true
#43 21:17:06 managed_focus_confirmed token=…3416
#44 21:17:06 hidden_state_changed token=…3416 hidden=false
#45 21:17:06 hidden_state_changed token=…1199 hidden=true
```

Two things are visible here:

- The two windows are admitted through the normal reconcile `windowAdmitted`
  path (`Sources/Nehir/Core/Workspace/WorkspaceManager.swift:2581` records
  `.windowAdmitted` from `trackWindow`).
- Helium recycles window ids, so Nehir's managed-replacement correlation rekeys
  `3416 → 6537` (`reason=managedReplacement`,
  `Sources/Nehir/Core/Workspace/WorkspaceManager.swift:2647`) and re-admits the
  same ids repeatedly within the ~1 s burst. The correlation runs on a 150 ms
  grace window (`managedReplacementGraceDelay`,
  `Sources/Nehir/Core/Controller/AXEventHandler.swift:432`). The churn itself is
  not the user-visible bug (the net effect is still "2 new columns"), but it
  shows the app's surface identity is unstable, which is what makes admission
  timing matter.

### 3. The trigger is an auxiliary Helium surface being created (CGS)

The create-focus trace shows a brand-new Helium surface `6814` created via the
CGS path right at the start of the burst:

```text
## Niri create focus trace
create_seen window=6814
create_placement_resolved token=WindowToken(pid: 22641, windowId: 6814)
  workspace=0E54DE8B… context_source=cgs_created   focused_workspace_source=confirmed_focus
candidate_tracked token=WindowToken(pid: 22641, windowId: 6814) workspace=0E54DE8B…
relayout_activated_window token=WindowToken(pid: 22641, windowId: 6537) workspace=0E54DE8B…
relayout_activated_window token=WindowToken(pid: 22641, windowId: 3416) workspace=0E54DE8B…
```

`context_source=cgs_created`
(`Sources/Nehir/Core/Controller/AXEventHandler.swift:4338`) confirms `6814` came
in through the window-created pipeline. `6814` is a tiny `220×173` floating
rescue window (events `#9`–`#14`, `floating_geometry_updated … frame=(762,863,220,173)
restore=true`), and it is destroyed about a second later (`ax=AXUIElementDestroyed
pid=22641 window=6814`; reconcile `#35 window_removed token=…6814`). It behaves
like a transient Helium overlay/notification.

The `relayout_activated_window` entries that follow
(`Sources/Nehir/Core/Controller/LayoutRefreshController.swift:668`) are recorded
only for windows that are *already managed* (`workspaceManager.workspace(for:
token)` is non-nil), so they confirm `6537`/`3416` were admitted *before* this
relayout pass — i.e. the relayout kicked off by `6814`'s creation is what swept
them in. (The relayout-driven admission itself is not logged with a context; see
the gap below.)

### 4. Net effect matches the report

Start: 1 managed Helium column (`1199`, hidden) + 2 unmanaged visible Helium
windows (`3416`, `6537`) → 1 Helium icon. End: `1199`, `6537`, `3416` all
managed → 3 Helium columns/icons. The transition is driven by the `6814`
auxiliary-create relayout. This is a faithful, source-backed account of "only 1
column / 1 icon, then 2 more existing windows reappear."

---

## Is the evidence sufficient? (tracing gaps)

**Sufficient for:** proving the symptom, the net column/icon change, and the
triggering event (auxiliary `6814` create → relayout → admit).

**Not sufficient for:** root-causing *why* `3416` and `6537` were unmanaged at
steady state in the first place. Three candidate explanations are all consistent
with the capture and cannot be distinguished from it:

1. **Their CGS create was never seen.** The create-focus trace ringbuffer
   contains `create_seen window=6802`, `6803`, `6814` — but **no** `create_seen`
   for `3416` or `6537`. The `CGSEventObserver` for the session reported
   `decodedEvents: 587, coalescedFrameEvents: 34, malformedPayloadDrops: 42,
   drainedEvents: 553`; a drop here would explain a missing create, but the
   capture does not attribute any drop to these specific ids.
2. **Their create was seen but rejected as unmanaged**, and they were never
   re-evaluated until the `6814` relayout forced a full rescan.
3. **They predate the 128-event create-focus ringbuffer**, so their original
   create/admission decision is simply gone from the capture.

The reason the capture cannot tell these apart is a pair of tracing gaps:

### Gap A — `window_admitted` carries no admission context

The reconcile `windowAdmitted` event only carries token/workspace/mode and a
coarse `WMEventSource` (`ax`/`workspaceManager`/`command`/…):

```swift
// Sources/Nehir/Core/Reconcile/WMEvent.swift:20-26
case windowAdmitted(
    token: WindowToken,
    workspaceId: WorkspaceDescriptor.ID,
    monitorId: Monitor.ID?,
    mode: TrackedWindowMode,
    source: WMEventSource
)
```

…and its trace summary prints only those fields
(`Sources/Nehir/Core/Reconcile/WMEvent.swift:172-173`,
rendered via `Sources/Nehir/Core/Reconcile/DebugDump.swift:58`). There is **no**
fine admission context on this event — nothing like the create pipeline's
`context_source` (`cgs_created` / `ax_focused_admission_synthesized`,
`Sources/Nehir/Core/Controller/AXEventHandler.swift:4338` and `:4357`). So when
`3416`/`6537` show up as `window_admitted`, the trace does not say whether they
were admitted by a belatedly-honored CGS create, a focus admission, or the
relayout/rescan.

### Gap B — rescan/relayout admissions have no `create_placement_resolved`

The create-focus trace records `create_placement_resolved … context_source=…`
(`Sources/Nehir/Core/Controller/AXEventHandler.swift:199`) only for windows that
go through the create-placement pipeline. `6814` does; `3416` and `6537` do not —
they go straight to `window_admitted`. So a window admitted by a full-refresh /
relayout rescan leaves **no** placement-context record at all. The only signal
that the relayout touched them is `relayout_activated_window`, which (per Gap A
and the `LayoutRefreshController.swift:668` guard) only fires for already-managed
windows — i.e. after admission, not at the admission decision.

### Gap C — the unmanaged-window dump has no admission history

The "Visible Unmanaged WindowServer Windows" dump
(`Sources/Nehir/Core/Controller/WMController.swift:3391`, with the
`axContainsWindow`/`axWindowsCount` fields at `:3352-3354`) proves the windows
exist and are AX-owned, but records nothing about *why* they are unmanaged —
whether they were ever `create_seen`, ever rejected (and with what reason), or
never observed. So seeing `3416`/`6537` listed there cannot, by itself,
distinguish Gap-A candidate (1) from (2) from (3).

---

## Tracing improvements needed

To root-cause the steady-state under-management (and to make future captures of
this class self-contained), add:

1. **Admission context on `window_admitted`.** Thread the admission trigger
   (`cgs_created` / `ax_focused_admission_synthesized` / `full_refresh`-rescan /
   `managedReplacement`-followup) into the reconcile `windowAdmitted` event and
   its trace summary, so every admission records *why* it happened. This closes
   Gap A and makes the `3416`/`6537` admission attributable.
2. **A placement-context record for rescan/relayout admissions.** When a
   full-refresh or relayout admits a window that had no prior
   `create_placement_resolved` (the path that swept in `3416`/`6537`), emit a
   `create_placement_resolved`-equivalent with a rescan context source. This
   closes Gap B.
3. **Admission history in the unmanaged-window dump.** For each entry in the
   "Visible Unmanaged WindowServer Windows" dump, record whether it was ever
   `create_seen`, ever rejected (with the rejection reason), and how long it has
   been visible-but-unmanaged. This closes Gap C and lets a single capture state
   whether such a window is "create missed" vs "create rejected."

With (1)–(3), a future capture of this scenario would directly show whether
`3416`/`6537` were never created-seen (candidate 1 / observer drop), seen and
rejected (candidate 2), or simply stale (candidate 3) — which is the decision
the current capture cannot make.

---

## What is still unknown

- **Why `3416`/`6537` were unmanaged at steady state.** Proven absent from the
  managed set and present in AX; not proven whether their create was missed,
  rejected, or aged out of the ringbuffer. Needs the tracing additions above.
- **Whether Helium's id-recycling is the cause or a confound.** The
  `3416 → 6537` rekey and the repeated re-admissions show the app's surface
  identity is unstable, which plausibly contributes to admission being delayed
  until a relayout forces a rescan. Not separable from the gaps above with this
  capture.
- **Whether the auxiliary `6814` surface is necessary to trigger admission, or
  merely one of several triggers.** The capture only shows the
  `6814`-create-triggered admission; other triggers (focus, a later manual
  rescan) may also work. Not exercised here.

---

## Relationship to other discoveries

- **Adjacent:**
  [`20260628-chromium-pip-opens-offscreen-never-create-seen.md`](20260628-chromium-pip-opens-offscreen-never-create-seen.md).
  Both are about the create/admit pipeline missing or delaying admission for a
  Chromium-embedded app's surfaces, and both hinge on the absence of a
  `create_seen` / admission-context record. That doc is about a single PiP that
  is *never* admitted on creation (under/late admission via focus); this one is
  about multiple full-size windows that are *batch*-admitted late on an
  auxiliary-create relayout. The shared fix surface is "record admission context
  for every admission" (its Direction B and this doc's tracing item 1 overlap).
- **Adjacent:**
  [`20260622-rescued-floating-auxiliary-windows-leak-into-workspace-bar.md`](20260622-rescued-floating-auxiliary-windows-leak-into-workspace-bar.md).
  Both touch admission policy for auxiliary/rescue surfaces and workspace-bar
  projection, but that doc is about *over*-admission of tiny transient surfaces
  (`rescue=true`), whereas this one is about *under*-admission of real windows.
  The `6814` rescue window here is an example of the over-admission side; the
  `3416`/`6537` full windows are the under-admission side.
