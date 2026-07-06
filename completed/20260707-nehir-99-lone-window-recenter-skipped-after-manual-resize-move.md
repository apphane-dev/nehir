# Nehir issue #99 — Lone survivor does not re-center after moving a window away, when the surviving window was manually resized — Discovery

**Status:** ✅ shipped — fixed on `main` in `4f9e5682` (2026-07-07). See "Resolution" below.
**Source issue:** https://github.com/apphane-dev/nehir/issues/99 (label `bug`)
**Reporter env:** nehir 0.6.0-rc.29, macOS (dual monitor)
**Verified against:** `main` on 2026-07-07 (source citations below).
**Original raw capture (pointer only; all evidence inlined below):**
https://github.com/user-attachments/files/29717973/runtime-trace-1783367666731-1783367695313.log

## Why the prior "fixed on main" verdict was incomplete

`noop/20260622-nehir-99-source-lone-window-recenter-after-move.md` closed #99 as fixed,
because on `main` the relayout pass re-centers a lone survivor after a move. That is true —
**but only when the survivor's resolved width changes.** The reporter re-hit the bug on rc.29
and pinned the trigger precisely: it happens *"as soon as I put a second window on the
external monitor and adjust the size of the windows (e.g. to have two windows having a 50 / 50
split)"* before moving one away. Manually resizing is exactly the case the existing recenter
gate misses. The 2026-06-22 "flaky / sometimes works" framing was really: *works when the
survivor was never manually resized, fails when it was.*

## Root cause (one sentence)

When a window is **moved** to another workspace and the **surviving lone window was manually
resized** (`hasManualSingleWindowWidthOverride == true`), none of the three arming conditions
of the lone-window recenter gate fire, so the survivor keeps its old two-column scroll offset
and its manual width instead of re-centering under the centered lone-window policy.

## The three-way gate that all evaluates false

Source-side re-centering after a move is delegated entirely to the relayout pass
`Sources/Nehir/Core/Controller/NiriLayoutHandler.swift:795`:

```swift
let usesCenteredLoneWindow = pass.engine.singleWindowLayoutContext(in: pass.wsId) != nil   // TRUE
let didRemoveWindow = !removal.removalResult.removedTokens.isEmpty                          // FALSE (see A)
...
let previousSingleWindowWidth = pass.engine.singleWindowLayoutContext(in: pass.wsId)?
    .container.cachedWidth ?? 0                                                             // 940 (> 0)
let geometry = pass.engine.prepareSingleWindowViewport(...)
let widthChanged = abs((geometry.map { $0.rect.width } ?? 0) - previousSingleWindowWidth) > 1 // FALSE (see B)
let shouldResetSingleWindowViewport = previousSingleWindowWidth <= 0   // FALSE
    || !removal.removalResult.removedTokens.isEmpty                    // FALSE (A)
    || widthChanged                                                   // FALSE (B)
if shouldResetSingleWindowViewport { resetViewportForCenteredLoneWindow(...) }  // never runs
```

`usesCenteredLoneWindow` is still true — `singleWindowLayoutContext`
(`Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine.swift:279`) only requires one column, one
window, not tabbed, `sizingMode == .normal`; it does **not** inspect the manual flag. So the
block is entered, but `shouldResetSingleWindowViewport` is false because:

### A. A cross-workspace *move* leaves `removedTokens` empty on the source

`removedTokens` is computed in `processWindowRemovals`
(`Sources/Nehir/Core/Controller/NiriLayoutHandler.swift:642`):

```swift
let existingHandleIds = pass.engine.root(for: pass.wsId)?.windowIdSet ?? []
let removedHandleIds = existingHandleIds.subtracting(Set(windowTokens))
```

This only catches windows that vanished from the incoming snapshot *while still present in the
engine root* — i.e. **closed / destroyed** windows. A move restructures the tree eagerly:
`moveWindowToWorkspace` (`Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+WorkspaceOps.swift:19`)
calls `window.detach()` and `cleanupEmptyColumn(...)` on the source *before* the relayout pass
runs, so the moved window is already gone from `root(for: source)`. `existingHandleIds` no
longer contains it, the subtraction is empty, and `didRemoveWindow == false`. (Contrast: a
*closed* survivor does populate `removedTokens`, which is why the close-to-one case re-centers
and the move-to-one case does not.)

### B. A manually-resized survivor has no width change to detect

`prepareSingleWindowViewport` (`Sources/Nehir/Core/Layout/Niri/NiriLayout.swift:817`) returns a
`geometry` whose width comes from `resolvedSingleWindowWidth`
(`Sources/Nehir/Core/Layout/Niri/NiriLayout.swift:707`):

```swift
guard context.container.hasManualSingleWindowWidthOverride else {
    return workingFrame.width * CGFloat(context.maxWidthFraction...)   // centered 60%
}
return max(0, context.container.cachedWidth)                           // manual width (940)
```

Because the survivor is manual, `geometry.rect.width == cachedWidth == previousSingleWindowWidth
== 940`, so `widthChanged == false`. (For a **non**-manual survivor the resolved width jumps
from the two-column proportional width to the centered 60% width — that mismatch is the only
reason the previously-"fixed" non-manual case re-centers.)

### C. The move op never reseeds the *source* survivor

`moveWindowToWorkspace` reseeds only the **target**
(`NiriLayoutEngine+WorkspaceOps.swift:51-55`). Its source-side work
(`NiriLayoutEngine+WorkspaceOps.swift:57-59`) is only `cleanupEmptyColumn` + selection fixup —
no `prepareSingleWindowViewport`, no `resetViewportForCenteredLoneWindow`, and it never clears
the survivor's `hasManualSingleWindowWidthOverride`. `moveColumnToWorkspace`
(`NiriLayoutEngine+WorkspaceOps.swift:70`) has the same source-side gap.

## Why the reporter's workaround fixes it (confirms the diagnosis)

Reporter: *"move this one window to another workspace (e.g. 7) and back to the previous one
(6), it centers again correctly."* Moving into an **empty** workspace goes through the
target/admission path, which calls `initializeNewColumnWidth`
(`Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine.swift:244`):

```swift
column.cachedWidth = 0
column.hasManualSingleWindowWidthOverride = false
```

That clears the manual override and zeroes `cachedWidth`. On the trip back, the recenter gate
now sees `previousSingleWindowWidth <= 0` → `shouldResetSingleWindowViewport == true` → the
survivor re-centers at the centered 60% policy. The asymmetry is the whole bug: the
target/insertion path resets manual width, the source-cleanup path does not.

## Runtime evidence (inlined; from the rc.29 capture)

Topology: display 2 `C49RG9x` 5120×1440 (main, ultrawide); display 1 `DELL U2414H`
frame `(-1842, 1440, 1920, 1080)` (external). Workspace 6 (`FF81A128-1880-47FA-9034-D5FF7B473A5C`)
lives on the external display. Lone-window policy is centered (~60%).

Sequence on workspace 6:

- Window `w73` (pid 675) inserted into empty workspace 6 (`reference=empty_workspace`) → lone,
  centered.
- Window `w1839` (pid 637) inserted → workspace 6 now has 2 columns (`c0=w73`, `c1=w1839`).
- Preset-cycle resize applied to **both** columns up to the 50% preset — the resize trace shows
  `kind=toggleColumnWidth(forward) source=presetCycle ... newSpec=proportion(0.5000) presetIdx=1
  targetWidth=940.0`, after which `manual` flips to `true` on both columns.
- `w1839` moved from workspace 6 → workspace 1 (main display). Workspace 1 goes to 3 columns;
  workspace 6 immediately drops to 1 column.

Surviving lone window on workspace 6 immediately after the move, and unchanged at capture end:

```
workspace=6 c0[cached=940.0, override=nil, spec=prop:0.5000, preset=1, manual=true]{w73:selected cur=-878,1448,940,1064}
columns=1  currentOffset=-956.0  currentViewStart=-8.0   (identical to the pre-move 2-column offset)
```

`currentViewStart` stayed at `-8.0` (its two-column value) across the entire 2→1 transition —
the viewport never re-centered. Geometry check: the window is `940` wide at `x=-878` on the
1920-wide external display (origin `-1842`); left margin `964`, right margin `16` — jammed
against the right edge, **not** centered. A centered 940-wide window would sit at
`x ≈ -1352` (`-1842 + (1920-940)/2`). No `resetViewportForCenteredLoneWindow` mutation occurs
anywhere in the capture.

## Exact steps to reproduce

Precondition: lone-window layout policy set to **centered** (e.g. 60%), and a second monitor.
The bug reproduces on the external monitor's workspace in the capture; it is a source-side
move/manual-width interaction, so it should reproduce on either display.

1. On an empty workspace (e.g. workspace 6 on the second monitor), open one window. It centers
   at the configured lone-window width (~60%). ✔ correct.
2. Open a second window on the same workspace. It enters tiling/scrolling mode (2 columns).
3. **Manually resize the columns** — e.g. cycle widths to a 50/50 split (this sets
   `manual=true` / `hasManualSingleWindowWidthOverride=true` on both columns). This step is
   essential; skipping it lets the existing width-change path recenter.
4. Move one of the two windows to a workspace on the other monitor
   (`move-window-to-workspace`).
5. **Bug:** the remaining lone window on workspace 6 does **not** re-center — it keeps its old
   two-column scroll offset and its manual 50% width, sitting off-center (edge-jammed).

Expected: the lone survivor returns to the centered lone-window layout (centered, ~60% width),
as it does on first insertion.

Workaround that confirms the cause: move the survivor to another empty workspace and back — it
re-centers correctly (target path clears the manual override; source path does not).

## Resolution (shipped `4f9e5682`, 2026-07-07)

Fixed with the localized move-path approach (the operation that actually orphaned the survivor,
reusing the already-correct admission-path semantics — no new per-relayout heuristics, and the
recenter gate's conservative side-snap/park preservation is left untouched).

`Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+WorkspaceOps.swift` gains a helper called from
both `moveWindowToWorkspace` and `moveColumnToWorkspace` source cleanup:

```swift
private func resetManualLoneWindowWidthOverrideIfNeeded(in workspaceId: WorkspaceDescriptor.ID) {
    guard let column = singleWindowLayoutContext(in: workspaceId)?.container,
          column.hasManualSingleWindowWidthOverride
    else { return }

    column.hasManualSingleWindowWidthOverride = false
    column.cachedWidth = 0
}
```

Gated on `singleWindowLayoutContext` it fires only when the source is left with a genuine lone
window (one column / one window / not tabbed / normal sizing). Clearing the manual override and
zeroing `cachedWidth` arms the existing recenter gate via its `previousSingleWindowWidth <= 0`
path, so the lone-window centered policy re-resolves — the same end state the empty-workspace
admission path (`initializeNewColumnWidth`) already produced. No-op for a non-manual survivor
(that case already re-centered via `widthChanged`).

Shipped with a `patch` changeset crediting reporter `flschulz`, and 86 lines of regression
tests in `Tests/NehirTests/NiriLayoutEngineTests.swift` covering the manual-resize move for both
`moveWindowToWorkspace` and `moveColumnToWorkspace`.

## Second, separate symptom in the same report (NOT source-confirmed here — needs its own ticket)

The reporter also describes, new in rc.29: *"As soon as I move something from a workspace from
my second monitor back to a workspace on my first monitor, this window is suddenly not
accessible anymore. I can see it behind the managed window on that workspace, but I can't
select it anymore. I first have to activate it via the dock ... and then it suddenly is in a
managed state again."*

This is a distinct focus/admission bug (moved window lands behind the managed window in a
non-selectable state until re-activated), not the recenter bug above. In the capture the moved
`w1839` arrives on workspace 1 in `mode=tiling phase=replacing` with `observedFrame=nil`, and
the end-state interaction focus is `nonManaged=true` on display 1 — consistent with the
symptom but not yet traced to a specific gate. **Recommend filing/tracking this separately;**
it should get its own discovery rather than being bundled into #99, whose scope is the
lone-window recenter.

## Related discoveries

- `noop/20260622-nehir-99-source-lone-window-recenter-after-move.md` (superseded by this doc)
- `completed/20260619-workspace-assignment-lone-window-width-and-reveal.md`
- `completed/20260619-workspace-assignment-lone-window-width-cache-leak.md`
