# Windows park off to the right for a few seconds while a fullscreen video exits — Discovery

> Scope: root-cause a reported visual transient. Source-backed where possible;
> **does not propose a fix.** Preliminary — leads with a hypothesis and lists what
> to confirm. Line references verified against main-repo HEAD `8a2e6db4`;
> re-verify before implementing (they drift), cite by symbol name.

## Symptom (as reported)

On one display hosting stacked Nehir workspaces, a video plays fullscreen and is
exited. Immediately after the exit, **some of the workspace's other windows are
misplaced off to the right edge of the screen for a few seconds**, then settle
back into their columns on their own. The active workspace is correct (this is a
separate issue from the workspace-jump bug fixed alongside it) — only the tiling
briefly looks wrong.

This reproduces **both with and without** the swipe/workspace-jump fix, so it is
independent of the focus-activation guard. Before that fix the user was thrown to
the wrong workspace on exit and never saw this settle; staying on the correct
workspace now makes the pre-existing transient visible.

---

## TL;DR

- On fullscreen exit macOS keeps reporting the video window at its **fullscreen
  size** (`live = 0,0,2056,1290` on a 2056-wide display) for a short period,
  while Nehir has already computed the window's **tiled slot**
  (`cur = 212,7,1632,1251`).
- While that oversized live frame is in effect, the layout's side-hiding parks
  the neighbouring columns to the **right** (`hidden:right`, their live frames
  pinned at the right edge `live = 2055,7,…`), and their `cur` positions are
  caught mid-slide (`cur = -274`, `743`, `1760`, … while each column's `target`
  differs).
- Once macOS finishes shrinking the window back to `1632` wide and the layout
  reconciles, the columns snap to their real positions. Total duration matches
  the "few seconds" report.

---

## Evidence (inlined; self-contained)

Single display, 2056 px wide (`x = 0 … 2055`), columns at `x = 0, 1017, 2034,
3051, 4068, 5085` (six-column workspace). All windows belong to one browser
process, pid 16913; the fullscreen video is `windowId 47748`.

**During the exit settle**, the video's tiled slot is already correct but its live
frame is still fullscreen-sized:

```
w47748:selected{cur=212,7,1632,1251,  target=212,7,1632,1251,  live=0,0,2056,1290}
```

At the same instant the other columns are parked at the right edge and hidden
there, their `cur` not yet equal to `target`:

```
c2 w52142  cur=-274,7,1011,1251  target=-1010,…  live=2055,7,1011,1251  hidden:right
c3 w42801  cur=743 ,7,1011,1251  target=-1010,…  live=2055,7,1011,1251  hidden:right
c4 w47139  cur=1760,7,1011,1251  target=14   ,…  live=2055,7,1011,1251  hidden:right
c5 w24203  cur=2055,7,1011,1251  target=1031 ,…  live=2055,7,1011,1251  hidden:right
```

The recorded viewport mutation at that moment is
`resetViewportForCenteredLoneWindow` (see below), i.e. the layout is treating the
still-fullscreen-sized video as a lone centred window and pushing the rest aside.

**After the settle**, the same columns report `cur == target` and the video is
back to `live = 212,…,1632,1251` — the misplacement is gone with no user action.

The count of `hidden:right` frames during the settle is roughly halved with the
workspace-jump fix applied (the fix removes the extra wrong-workspace activation
and its additional relayout pass), which is further evidence the transient is a
property of the exit-settle relayout, not of the focus path.

---

## Leading hypothesis (source-backed)

The misplacement is a **frame-lag race during fullscreen-exit restore**: Nehir
recomputes tiled geometry from a window whose *live* frame macOS has not yet
shrunk from fullscreen size, so for a few frames the layout is derived from a
window that appears to fill the whole display.

Relevant source:

- `NiriLayoutHandler.resetViewportForCenteredLoneWindow`
  (`Sources/Nehir/Core/Controller/NiriLayoutHandler.swift:1051`, called from
  `:819` and `:981`) is the mutation recorded during the transient. It centres a
  lone window and is the path that pushes siblings aside; it fires here while the
  video still measures full-width.
- Native/app-fullscreen restore marks the window for a one-shot frame apply via
  `markNativeFullscreenRestoredForFrameApply`
  (`Sources/Nehir/Core/Controller/LayoutRefreshController.swift:4027`, consumed by
  `consumeNativeFullscreenRestoredFrameApply` `:4031`), and
  `restoreManagedWindowFromNativeFullscreen`
  (`Sources/Nehir/Core/Controller/AXEventHandler.swift:4721`) requests the
  post-restore refresh. The question is whether that refresh runs (and parks
  siblings) **before** macOS reports the shrunk live frame.
- Side placement of the parked columns is `Sources/Nehir/Core/Layout/SideHiding.swift`
  (`HideSide.right`), which is what pins them at `x = 2055`.

So the chain is: fullscreen exit → restore requests a relayout → relayout reads
the video's still-fullscreen `live` frame → treats it as a full-width/lone window
and side-hides the neighbours to the right → macOS finishes resizing the video →
next reconcile corrects everyone.

---

## Open questions for the fix stage (not decided here)

1. **Should the post-restore relayout wait for the window's live frame to match
   its tiled target** (or clamp to the tiled `target`/`cached` width) instead of
   consuming the oversized live frame? Confirm where the relayout samples `live`
   vs `target` during restore.
2. **Is `resetViewportForCenteredLoneWindow` firing correctly** given the workspace
   here has six columns (not a lone window)? Establish why a multi-column
   workspace takes the centred-lone-window path during the settle — it may be
   mis-triggered by the transient full-width measurement.
3. **Does the one-shot `nativeFullscreenRestoredFrameApply` flag get consumed
   before or after the live frame settles?** If before, the corrective frame apply
   may be spent on the still-fullscreen frame.
4. Confirm the transient occurs for **app/HTML5 fullscreen** (no
   `NativeFullscreenRecord`) as well as native-Space fullscreen — the report and
   traces suggest both, but the restore path differs
   (`restoreNativeFullscreenReplacement*` vs plain relayout).

## Reproduction (topology-level, no log needed)

1. On one display, open a multi-column workspace of a single app (e.g. a browser
   with several windows tiled).
2. Put one window into fullscreen video (green-button native fullscreen, or the
   app's own/HTML5 fullscreen).
3. Exit fullscreen. Watch the other columns: for ~1–3 s they jump to / hide at the
   right edge, then settle back into place on their own.
