# Floating / sticky window "always on top" (topmost) — No-op

**Verdict: ⚪ No-op — not achievable for external windows without SIP disabled.**
Confirmed by runtime measurement on 2026-07-21 (see evidence below). A prototype
was built and runs, but the core mechanism does not work SIP-free, and the user
chose to document the limitation rather than ship a best-effort approximation.
Moved to `noop/` on 2026-07-21. Supersedes the former
`planned/20260721-floating-window-always-on-top.md`.

Source citations verified against `guria/nehir` main at `75c04df5`.

## Goal (restated)

Let the user pin a managed window so its WindowServer z-order stays **above other
managed windows**, persistently — a property orthogonal to `mode == .floating`
(don't tile) and `sticky` (visible across workspace switches).

## What was tried

A full prototype was implemented (command + state + apply mechanism + bar menu
item), built green, and exercised at runtime:

- `WorkspaceManager.alwaysOnTopWindowTokens` set + `isAlwaysOnTopWindow` /
  `setAlwaysOnTop` / `alwaysOnTopEntries`, with the managed-replacement token
  rekey and reset cleanup (mirrors `manualStickyWindowTokens`).
- `HotkeyCommand.toggleFocusedWindowAlwaysOnTop` wired through `ActionCatalog`,
  `CommandHandler`, `WMController.toggleWindowAlwaysOnTop(token:)`, IPC/CLI, and
  a "Toggle Always on Top" workspace-bar context-menu item.
- `AlwaysOnTopApplicator` applying a **single robust mechanism**: level-set to 3
  via a new `SkyLight.setWindowLevel(_:level:)` (thin wrapper around
  `SLSTransactionSetWindowLevel`) **plus** a re-raise (`orderWindow(..., .above)`)
  safety net, called from the layout apply chokepoint.

## Decisive evidence — foreign-window level-set is silently ignored

The applicator's own diagnostic trace, toggling always-on-top on a real external
window (pid 7861, WindowServer windowId 2335), recorded — across six apply passes
between `00:53:11Z` and `00:53:18Z`, verbatim:

```text
alwaysOnTop.apply path=levelSet+reraise token=WindowToken(pid: 7861, windowId: 2335) wid=2335 level=3 before=0 after=0
```

The critical values are **`level=3 before=0 after=0`**: Nehir called
`SLSTransactionSetWindowLevel(txn, 2335, 3)` on the window and committed the
transaction, but a re-read of the window's level via `SLSWindowIteratorGetLevel`
returned **0 both before and after** — the level write returned success and had
**no effect**. The window's z-order was unchanged; clicking another window buried
it, and nothing kept it on top.

This matches the pre-existing findings in `docs/offscreen-clamp-fix.md`: several
SLS **write** ops (`SLSTransactionOrderWindow` order-out, `SLSSetWindowShape`,
`SLSSetWindowTransform`, `SLSSetWindowOpacity`) are silently ignored for windows
owned by other processes — "only works on windows the caller created." Setting a
window level is in the same family: **the WindowServer does not honor a level
write to a window owned by another connection without the SIP-disabled scripting
addition.** This also matches the prior conclusion in
`discovery/20260617-omniwm-315-sticky-apps-across-workspaces.md` (and upstream
`BarutSRB/OmniWM` discussion #11): *"without SIP disabled, it's not possible to
keep the sticky window always on top."*

Note the asymmetry, since it bounds the alternatives below: order-**in / above**
on a foreign window *does* work (it is what Nehir's focus-raise uses), but a
persistent **level** write does not.

## Options considered

1. **Best-effort continuous re-raise (SIP-free) — declined.** Re-issue
   `orderWindow(..., .above)` for pinned windows on every focus / app-activation
   change (hooks exist near the AX focused-window-changed callbacks). This is only
   an approximation: the pinned window briefly drops behind a newly-clicked window
   then pops back over it (visible flicker), you interact with a window that is
   partly covered, and it still cannot sit above other apps' genuine high-level
   overlays. The user chose not to ship this.
2. **SIP-disabled scripting addition (yabai-style) — out of scope.** Would enable
   a real `SLSSetWindowLevel` via an elevated connection, but requires disabling
   SIP on the user's machine and carries security/setup burden. Not pursued.
3. **Shelve and document — chosen.** No user-facing feature ships.

## Re-open criteria

Revisit only if the project ever adopts a SIP-disabled scripting addition (or
Apple exposes a supported topmost API). At that point the prototype's structure
(command + `alwaysOnTopWindowTokens` state + `AlwaysOnTopApplicator`) is a valid
starting point; the only missing piece is a level write that the WindowServer
actually honors. Absent that, do **not** re-plan a level-based approach — the
measurement above already settles it.

## Disposition of the prototype code

The prototype was built on a scratch branch and is **not merged**. It builds
green but is intentionally not shipped. It may be kept as reference for the
re-open criteria above or discarded; nothing depends on it.
