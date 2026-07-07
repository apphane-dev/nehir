# Chromium-embedded PiP opens offscreen and is never seen created — Discovery

Groom 2026-07-07: still applicable — open, unreproduced investigation; the shipped PiP defaults (`9ef0ae82`) and `#108` visibility (`ade7cd07`) do not address this surface's missed `create_seen`/offscreen-open path. The reporter could not reproduce after the initial captures (verified against main 7a025b78).

Discovery (2026-06-28). When the user opens the Picture-in-Picture overlay in
**Vivaldi** (`com.vivaldi.Vivaldi`, a Chromium browser), the PiP surface opens
**offscreen, above the menu bar**, and Nehir **never receives a window-created
event for it.** The user cannot see the PiP at all. It only becomes managed
(ands then visible) later, when an interaction with it produces a focus event —
at which point Nehir synthesizes an admission "on focus."

The same browser's ordinary windows are managed normally. Small auxiliary
surfaces from *other* apps (e.g. Helium status strips) in the same session
**do** produce a window-created event and are admitted on creation. So the
create-notify path is working in general — it specifically does not fire for
this Chromium-embedded PiP.

This is a sibling of
[`20260628-stale-floating-entry-lingers-after-surface-destroyed.md`](20260628-stale-floating-entry-lingers-after-surface-destroyed.md):
the two together describe a broken end-to-end lifecycle for the same Vivaldi PiP
surface (late admission on open → no reclaim on close). They have distinct root
causes and fix surfaces and can be explored independently.

The reporter could not reproduce the offscreen-open at will after the initial
captures, so this doc records the evidence for a future investigation rather
than a confirmed fix path.

All code citations verified against the main Nehir source tree at `9ef0ae82` on
2026-06-26 (`git log -1 --format='%h %s' main` → `9ef0ae82 Add sticky PiP
defaults and ignore app rules`). Line numbers will drift.

---

## TL;DR

- **Symptom.** Opening Vivaldi's YouTube PiP produces no visible PiP. It is
  parked above the menu bar, offscreen.
- **What the surface is.** `WindowToken(pid: 13892, windowId: 2274)`,
  `bundleId=com.vivaldi.Vivaldi`, `windowLevel=3`, `wsParent=0`,
  `ws_float=true` — a top-level floating media surface (Chromium PiP).
- **Two independent problems, both observed:**
  1. **Never `create_seen`.** Across two captures, `create_seen window=2274`
     occurs **zero** times. The PiP never enters the CGS-window-created pipeline
     that Nehir listens to. Other apps' auxiliary surfaces in the same session
     *do* fire `create_seen` and are admitted on creation.
  2. **Opens offscreen.** When Nehir first observes the PiP (via a periodic
     rescan), its frame is `(924.0, -1063.0, 764.0, 430.0)` — top-left y = **-1063**,
     ~1063 pt above the top of the display. The display is
     `(0.0, 0.0, 2056.0, 1329.0)`.
- **Why it eventually appears.** Admission happens only when focus lands on it
  (`context=focused_admission`,
  `context_source=ax_focused_admission_synthesized`). A user click on the
  invisible PiP's region (or a system gesture that hits it) is what finally
  admits it. On admission the frame is corrected onto the screen.
- **Open questions.** Why does the CGS create notification not fire for this
  surface? Is the PiP placed offscreen by Vivaldi/Chromium, or moved there?
  Neither is answered by the captures; both are upstream-ish. Nehir-side, the
  actionable gaps are (a) no admission without a create/focus event, and (b) no
  clamp that pulls an offscreen-created floating surface onscreen.

---

## Topology / initial state

Single display, `ID(displayId: 1)`, notch, frame `(0.0, 0.0, 2056.0, 1329.0)`,
visible frame `(0.0, 0.0, 2056.0, 1290.0)`. `displaySpacesMode=enabled`,
`focusFollowsMouse=false`. Workspace bar enabled.

Active workspace `BC5D5EC7-3E7F-43AD-B643-F2CF47C69FB8`. Managed focus on the
**tiled** Vivaldi browser window `WindowToken(pid: 13892, windowId: 2249)`.

App: Vivaldi (`com.vivaldi.Vivaldi`, pid `13892`). Helium
(`net.imput.helium`, pid `13175`) also present with tiled windows and frequent
small auxiliary surfaces.

---

## What the evidence proves

### 1. The PiP is never `create_seen`

`create_seen` is emitted at the top of the CGS-window-created handler:

```swift
// Sources/Nehir/Core/Controller/AXEventHandler.swift:586-589
private func handleCGSWindowCreated(windowId: UInt32, spaceId: UInt64) {
    captureCreatePlacementContext(windowId: windowId, spaceId: spaceId)
    recordNiriCreateFocusTrace(.init(kind: .createSeen(windowId: windowId)))
    processCreatedWindow(windowId: windowId)
}
```

Across **two** captures that both span the PiP opening and its eventual
admission, a search for `create_seen window=2274` returns **zero** matches.

Meanwhile, Helium auxiliary surfaces in the *same* captures do fire
`create_seen` and proceed through the normal create pipeline, e.g.:

```text
create_seen window=3392
create_placement_resolved token=WindowToken(pid: 13175, windowId: 3392) workspace=BC5D5EC7-… context_source=cgs_created
candidate_tracked token=WindowToken(pid: 13175, windowId: 3392) workspace=BC5D5EC7-…
…
create_seen window=3393 … 3398   (same pattern, all candidate_tracked)
```

Those Helium surfaces are `ws_float=true`, `wsParent=<sibling>`, ~309×43 status
strips. So the create-notify path is alive and admitting real surfaces — it
specifically does not fire for the Vivaldi PiP (`2274`).

### 2. The PiP only surfaces via rescan, then via focus

Every `window_decision` for `2274` in capture 1 carries `context=full_refresh`
(the periodic rescan), never `context=create`:

```text
window_decision token=WindowToken(pid: 13892, windowId: 2274) context=full_refresh
  existingMode=nil → floating   source=heuristic  outcome=trackedFloating
  bundleId=com.vivaldi.Vivaldi  wsLevel=3  wsParent=0
  wsFrame=(924.0,-1063.0,764.0,430.0)
```

(×4, all `context=full_refresh`.) No `candidate_tracked`, no
`create_placement_resolved` for `2274` — i.e. the rescan noticed and classified
it but did not admit it (no creation event to drive admission).

In capture 2 (the reporter clicked where the invisible PiP was), admission
finally happens via the focus path:

```text
window_decision token=WindowToken(pid: 13892, windowId: 2274) context=focused_admission
  existingMode=nil → floating  source=heuristic  outcome=trackedFloating
  wsFrame=(924.0,-1063.0,764.0,430.0)

create_placement_resolved token=WindowToken(pid: 13892, windowId: 2274) workspace=BC5D5EC7-…
  native_monitor=nil  frame_monitor=Optional(ID(displayId: 1))
  context_source=ax_focused_admission_synthesized        ← admission synthesized from focus

candidate_tracked token=WindowToken(pid: 13892, windowId: 2274) workspace=BC5D5EC7-…
pending_focus_started request=15 token=…2274 …
focus_confirmed token=WindowToken(pid: 13892, windowId: 2274) … source=focusedWindowChanged
```

The focus-admission path is the `traceContext: "focused_admission"` site
(`Sources/Nehir/Core/Controller/AXEventHandler.swift:2227`) with the placement
context source `"ax_focused_admission_synthesized"`
(`Sources/Nehir/Core/Controller/AXEventHandler.swift:4357`). So Nehir's design
is: a window that was never `create_seen` can still be admitted when focus
lands on it. That is what rescued this PiP — but only because the user
interacted with the invisible window.

### 3. The PiP opens offscreen, above the menu bar

The first observed frame of `2274` is:

```text
wsFrame=(924.0, -1063.0, 764.0, 430.0)
```

With the display at `(0.0, 0.0, 2056.0, 1329.0)`, a top-left y of **-1063**
places the PiP entirely above the screen — above the menu bar. This is
consistent with the reporter's observation that a macOS three-finger-upward
system gesture "shows the PiP coming from the top": it is physically parked
just above the visible region.

Whether Vivaldi/Chromium placed it there, or something moved it, is not
determinable from the captures (Nehir only reads the frame; it does not log who
last wrote it for an unmanaged surface).

### 4. On focus-admission the frame is corrected onto the screen

The admission sequence shows the offscreen coordinate pass through a y-flip and
then settle onscreen:

```text
event=window_admitted token=…2274 mode=floating … rescue=true
event=floating_geometry_updated token=…2274 frame=(924.0, 1962.0, 764.0, 430.0) restore=true   ← y=1962: offscreen BELOW (1329 screen) — a y-flip artifact
event=floating_geometry_updated token=…2274 frame=(924.0, 860.0, 764.0, 430.0)  restore=true   ← corrected: onscreen
event=hidden_state_changed token=…2274 hidden=false
```

After this, the PiP rests at `(924.0, 860.0, 764.0, 430.0)` (bottom-right,
onscreen) and is visible. So Nehir *can* place it correctly once it admits it —
the problem is getting to admission, and the offscreen starting position.

---

## Why this is two separate upstream-ish questions

### Q1. Why is there no `create_seen` for the PiP?

Nehir learns about new windows from the CGS event that feeds
`handleCGSWindowCreated`. The captures prove that event fires for ordinary
windows and for other apps' floating auxiliary surfaces, but not for this
Chromium-embedded PiP. Plausible reasons (not confirmed by the captures):

- Chromium creates the PiP via a code path that does not emit the specific CGS
  creation event Nehir observes (e.g. it repurposes/reparents an existing
  surface rather than creating a fresh top-level window).
- The PiP is created with attributes/owner that Nehir's CGS observer filters
  out upstream of `create_seen` (the `CGSEventObserver` decodes/coalesces/drops
  events — the runtime state dump for the session showed
  `CGSEventObserver DebugCounters(decodedEvents: 1892, coalescedFrameEvents:
  435, malformedPayloadDrops: 111, drainedEvents: 1445)`; a drop here would
  explain the missing `create_seen`).
- The PiP window id was recycled and the create was deduped as an
  "existing entry" elsewhere.

A capture that instruments the CGS observer's drop/dedupe counters *while*
opening the PiP would distinguish these.

### Q2. Why is the PiP offscreen at y=-1063?

This is almost certainly the app's (Vivaldi/Chromium's) placement, not Nehir's:
Nehir does not write frames for surfaces it has not admitted, and `2274` was
unmanaged until the focus click. But it is worth confirming, because if Nehir
*were* moving it (e.g. a stray hide/relayout write touching an unmanaged
surface), that would be a Nehir bug. The captures do not show Nehir writing
`2274`'s frame before admission.

Independently of *who* placed it offscreen: a managed floating surface that is
created offscreen should be clamped onscreen at admission. Nehir did clamp it
to `(924, 860)` — but only at focus-admission, not at creation (there was no
creation). If admission were driven by creation instead of focus, the clamp
would run immediately and the PiP would never sit offscreen.

---

## Fix directions (no implementation in this pass)

### Direction A — Admit on rescan when a classified-but-unadmitted floating surface is observed

Today the periodic rescan (`context=full_refresh`) classifies `2274` as
`outcome=trackedFloating` but does not admit it (no creation event). A
direction is: when a full-refresh evaluation resolves a window to
`trackedFloating`/`trackedTiling` and there is **no** existing entry and **no**
pending create, admit it from the rescan rather than waiting for a focus event.

- Pro: the PiP becomes managed (and therefore onscreen-clamped) as soon as the
  rescan sees it, without requiring the user to click the invisible window.
- Con: rescans intentionally do not admit today (admission is create-driven to
  avoid spuriously grabbing surfaces); relaxing this needs care not to admit
  transient/parented surfaces that the create path correctly defers.

### Direction B — Investigate and close the missing-CGS-create gap

Instrument the `CGSEventObserver` decode/coalesce/drop path
(`malformedPayloadDrops`, dedupe) specifically for the PiP open moment, to find
why the creation event for `2274` never reaches `handleCGSWindowCreated`. This
is the root-cause fix for Q1 and would make Direction A unnecessary for this
class of surface.

### Direction C — Clamp newly admitted floating surfaces onscreen regardless of trigger

Even if admission stays focus-driven, the offscreen start position should not
survive admission. Ensure the admission path (both the create path and the
`focused_admission` synthesized path) runs the floating onscreen clamp before
the first frame is committed, so a surface that an app opened offscreen is
moved onscreen immediately. (The captures show the clamp *did* run on
focus-admission and produced `(924, 860)`; confirm it runs on the create path
too, and that there is no window where the offscreen frame is committed and
observed before the clamp.)

---

## What is still unknown

- **Why no `create_seen` for the PiP specifically.** The captures prove the
  absence; they do not explain it. Needs CGS-observer instrumentation at the
  PiP-open moment (Direction B).
- **Whether Nehir ever wrote `2274`'s frame before admission.** Not seen in the
  captures, but not positively ruled out for all moments. A frame-write trace
  scoped to unmanaged window ids during PiP open would settle Q2.
- **Reproducibility.** The reporter could not reproduce the offscreen-open at
  will after the initial captures, so the conditions that trigger it (specific
  Vivaldi/Chromium version, prior PiP state, fullscreen vs windowed video) are
  not pinned down.

---

## Relationship to other discoveries

- **Sibling:**
  [`20260628-stale-floating-entry-lingers-after-surface-destroyed.md`](20260628-stale-floating-entry-lingers-after-surface-destroyed.md).
  Same surface (`2274`), same session. That doc covers the *close* end of the
  lifecycle (the PiP is closed and the managed entry lingers as a phantom);
  this doc covers the *open* end (the PiP opens offscreen and is admitted
  late). Independent root causes; fix either without touching the other.
- **Adjacent:**
  [`20260622-rescued-floating-auxiliary-windows-leak-into-workspace-bar.md`](20260622-rescued-floating-auxiliary-windows-leak-into-workspace-bar.md).
  Both concern floating-surface admission policy, but that doc is about
  *over*-admission (tiny transient surfaces admitted with `rescue=true`),
  whereas this one is about *under*/late admission (a real PiP never admitted
  on creation). The admission gate proposed there (transience/size) and the
  rescan-admission proposed here (Direction A) pull in opposite directions and
  would need to be reconciled.
