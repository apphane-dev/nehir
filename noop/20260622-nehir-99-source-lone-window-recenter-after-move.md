# Nehir issue #99 — Center window doesn't work reliable when changing windows in workspace — Discovery

**Status:** noop — already fixed on `main`
**Source issue:** https://github.com/apphane-dev/nehir/issues/99 (label `bug`)
**Reporter env:** nehir 0.6.0-rc.9, macOS 26.5.1

## Verdict (2026-07-05): fixed, cannot reproduce on current `main`

The original 2026-06-22 conclusion below ("source-side move/close never re-seeds the lone
survivor") is **wrong as of current `main`**. It was reasoned from the engine op call sites
(`move*ToWorkspace` / `removeWindow`) in isolation and missed that the controller relayout
pass already re-resolves the lone-window viewport. Runtime traces on `main` at `e68349f8`
(2026-07-05) show the survivor re-centers deterministically.

### The fix that already landed

The lone-window viewport is re-resolved inside the relayout pass, not at the move/close call
sites — `Sources/Nehir/Core/Controller/NiriLayoutHandler.swift` (the
`usesCenteredLoneWindow` / `shouldResolveLoneWindowViewport` block):

```swift
let usesCenteredLoneWindow = pass.engine.singleWindowLayoutContext(in: pass.wsId) != nil
let didRemoveWindow = !removal.removalResult.removedTokens.isEmpty
let shouldResolveLoneWindowViewport = !isGestureOrAnimation || didRemoveWindow
if usesCenteredLoneWindow, shouldResolveLoneWindowViewport {
    let previousSingleWindowWidth = pass.engine.singleWindowLayoutContext(in: pass.wsId)?
        .container.cachedWidth ?? 0
    let geometry = pass.engine.prepareSingleWindowViewport(...)
    let widthChanged = abs((geometry.map { $0.rect.width } ?? 0) - previousSingleWindowWidth) > 1
    let shouldResetSingleWindowViewport = previousSingleWindowWidth <= 0
        || !removal.removalResult.removedTokens.isEmpty   // fires on the source 2→1
        || widthChanged
    if shouldResetSingleWindowViewport {
        resetViewportForCenteredLoneWindow(geometry: geometry, state: &state)
    }
}
```

Any relayout of a workspace that (a) has exactly one window under a centered policy and
(b) just had a window removed re-prepares the single-window viewport (sets
`loneWindowLayoutWidthOverride`) and re-centers. This covers the 2→1 source transition and
the close-to-one case without patching each engine op. Introduced in
`d5a884a3` "Reset lone-window viewport after column removal" (2026-06-17), refined since
(`06baf50d`, `e87bade3`).

The 2026-06-22 discovery was verified at `4ae5fc96` (2026-06-22), i.e. *after* `d5a884a3`
already existed, but only inspected `NiriLayoutEngine+WorkspaceOps.swift` /
`NiriLayoutEngine+Windows.swift` and concluded the reseed was missing. It never checked the
controller relayout layer, which is where the reseed actually happens.

### Runtime evidence

Original captured traces (pointers only; evidence inlined below):

- Reproduces on rc.9: https://github.com/user-attachments/files/29182694/runtime-trace-1782068633957-1782068647756.log
- Does not reproduce on `main` `e68349f8` (2026-07-05, two captures confirming the fix).

**rc.9 (bug present).** Two-column workspace (survivor `w22` + `w78`), then `w78` moved to
another workspace. Survivor end state:

```
workspace c0[cached=940.0, override=nil, spec=prop:0.5000, preset=1, manual=true]{w22:selected cur=-878,1448,940,1064}
viewport: currentOffset=-956  currentViewStart=-8   (unchanged from the 2-column state)
```

`override=nil`, old two-column width `940`, old scroll offset — not centered.

**`main` `e68349f8` (fixed).** A workspace holds `w2038` (lone, centered) then `w2048`
(2 columns; `w2038` correctly drops to `override=nil`), then `w2048` is moved away. On the
relayout right after the move, the survivor `w2038` re-centers:

```
before: currentOffset=-1023  activeColumnIndex=1  w2038 override=nil width=1011
after : currentOffset=-408   activeColumnIndex=0  w2038 override=1224 cur=416,7,1224,1251
lastViewportMutation=resetViewportForCenteredLoneWindow (NiriLayoutHandler) ageMs=11
```

`override` goes `nil → 1224` (≈60% of the 2040-wide working area), window centered at
`x=416` = `(2040-1224)/2`. Same deterministic re-center holds for windows moved *into* an
empty workspace (target/admission side), which was never the broken half.

## Original discovery (2026-06-22) — superseded, kept for provenance

> Verified against the main Nehir source tree at `4ae5fc96` on 2026-06-22.
> **This analysis is incorrect for current `main`; see the verdict above.**

- Framed #99 as the reverse half of the 2026-06-19 lone-window work: the transient
  lone-window override exists, but the source-side 2→1 transition after a move/close was
  thought not to re-enter the lone-window seed path.
- `moveWindowToWorkspace` / `moveColumnToWorkspace` clear the **target** workspace's transient
  override when it becomes multi-column, but the **source** side only cleans up empty columns
  and selection — so the conclusion was that it never re-seeds the surviving lone window.
- The close path was thought to have the same hole.
- Proposed fix: after any move/close leaving exactly one tiled window, explicitly re-run the
  lone-window seed for that workspace.

Why the analysis was wrong: it stopped at the engine op layer. The controller relayout pass
(`shouldResolveLoneWindowViewport`, gated on `didRemoveWindow`) already does the reseed for
every affected workspace, so no engine-op change was needed. The "flaky" framing (later
incidental relayout recovers it) also doesn't hold — the reseed is on the same relayout the
move triggers, not a later incidental one.

## Sibling / related discoveries

- `completed/20260619-workspace-assignment-lone-window-width-and-reveal.md`
- `completed/20260619-workspace-assignment-lone-window-width-cache-leak.md`
