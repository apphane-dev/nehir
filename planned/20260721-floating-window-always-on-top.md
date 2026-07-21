# Floating / sticky window "always on top" (topmost) — Plan

**Status:** planned — 2026-07-21. Source citations verified against `guria/nehir`
main at `75c04df5` ("Add some extra tracing"). Line numbers drift; re-verify
before implementing.

**One-line goal:** let the user pin a managed window so its WindowServer
z-order stays **above other managed (tiled) windows**, persistently, until
toggled off — a new property orthogonal to `mode == .floating` (don't tile) and
`sticky` (visible across workspace switches).

---

## Feasibility verdict (confirm-first, per the request)

**Verdict: 🟡 feasible with a caveat that must be settled by a runtime spike
before the real implementation lands.** The plan's Phase 1 is that spike; the
rest of the plan branches on its result. Do not skip Phase 1 — static analysis
cannot decide it, and there is concrete local evidence pulling both ways.

### What is already proven in-tree (the machinery exists)

1. **A window-level *write* API is already resolved and called.**
   `SLSTransactionSetWindowLevel` is `dlsym`-resolved in
   `Sources/Nehir/Core/SkyLight/SkyLight.swift:292` and invoked from
   `transactionMoveAndOrder(_:origin:level:relativeTo:order:)`
   (`SkyLight.swift:862`):

   ```swift
   if let transactionSetWindowLevel {
       _ = transactionSetWindowLevel(transaction, wid, level)   // SkyLight.swift:877
   }
   transactionOrderWindow(transaction, wid, order.rawValue, targetWid)
   ```

   **But today it is only ever fed Nehir's own border overlay** — a window Nehir
   *created* via `SLSNewWindow` (`SkyLight.createBorderWindow`, `SkyLight.swift:780`),
   driven by `Sources/Nehir/Core/Border/BorderWindow.swift:245` with the constant
   `orderingLevel: Int32 = 3` (`BorderWindow.swift:70`). No code path sets a level
   on an **external app** window.

2. **Reordering external app windows *does* work.** Nehir already raises
   foreign app windows to the front with
   `SkyLight.shared.orderWindow(wid, relativeTo: 0, order: .above)`
   (`SkyLight.swift:448`) at `WMController.swift:49` (focus raise),
   `LayoutRefreshController.swift:4590` and `:4704` (reveal), and
   `CommandPaletteController.swift:1036`. So *ordering* a foreign window above the
   desktop is a solved, shipped primitive.

### The caveat (why a spike is required)

`SLSTransactionSetWindowLevel` being *callable* does not prove it *takes effect*
on a window owned by another process. `docs/offscreen-clamp-fix.md` records a
systematic set of runtime experiments and found that several SLS **write** ops
are **silently ignored for windows owned by other processes** — the API returns
`.success` but nothing changes:

- `SLSTransactionOrderWindow` / `SLSOrderWindow` with order-**out** mode
  (`kCGSOrderOut`): "silently ignored for windows owned by other processes …
  only works on windows the caller created."
- `SLSSetWindowShape`: "only affects windows created through `SLSNewWindow`."
- `SLSSetWindowTransform`, `SLSSetWindowOpacity`: no reliable effect on external
  app pixels.

Note the asymmetry that matters here: order-**in / above** on a foreign window
works (proven by the focus-raise paths), but order-**out** does not. Level-set
sits in the same "does the WindowServer honor a write to a window I don't own?"
family, and its cross-process behavior is **not** established anywhere in-tree.

A prior investigation reached the pessimistic conclusion directly:
`discovery/20260617-omniwm-315-sticky-apps-across-workspaces.md` states that
keeping a window always-on-top for an external app "requires private/SIP-disabled
APIs," quoting the upstream maintainer (BarutSRB/OmniWM discussion #11): *"without
SIP disabled, it's not possible to keep the sticky window always on top."* That
claim was reasoned, not measured against `SLSTransactionSetWindowLevel` on
Nehir's already-live main SkyLight connection — which is exactly the gap Phase 1
closes.

### The always-safe fallback

Independent of the spike, a **continuous re-raise** approach is guaranteed to
work because it reuses only the proven `orderWindow(..., .above)` primitive:
re-issue `.above` for the topmost-flagged window on the events that would let
another window cover it (app activation, focus change, managed-window raise,
layout refresh). This yields *pseudo* always-on-top — imperfect (a brief moment
below a newly-raised window, then re-raised; two topmost windows fight; it does
not beat other apps' genuine high-level overlays) but reachable with zero new
private-API risk. Phase 1 decides whether we ship the real level-set (crisp) or
this fallback (robust-but-approximate).

### The one hard in-tree constraint on level choice

`SkyLight.queryAllVisibleWindows()` hard-filters Nehir's own window discovery to
levels **0, 3, 8**:

```swift
// Sources/Nehir/Core/SkyLight/SkyLight.swift (queryAllVisibleWindows enumerator)
let level = windowIteratorGetLevel(iterator)
guard level == 0 || level == 3 || level == 8 else { continue }
```

If we raise a managed app window to a level **outside** this allow-list, the
window **drops out of Nehir's own tracking/visibility queries** — the WM would
lose the window it just pinned. So a real level-set must either (a) reuse an
allowed level whose z-order is still above normal windows (level `3`, the
`kCGFloatingWindowLevel` slot Nehir already treats as floating), or (b) widen the
allow-list to include the chosen topmost level everywhere it is applied. Prefer
(a) unless the spike shows level `3` does not visually sit above tiled level-`0`
windows reliably.

---

## Concept & naming

Nehir already has two independent per-window properties; "always on top" is a
**third**, and must not be conflated with either:

| property | meaning | where |
|---|---|---|
| `mode == .floating` | do not tile; keep a free frame | `WindowModel.TrackedWindowMode` (`WindowModel.swift:10`) |
| sticky | visible across workspace switches (not parked) | `WorkspaceManager.hasStickyWindowSource` (`WorkspaceManager.swift:3039`) |
| **always-on-top (new)** | **z-order above other managed windows** | **this plan** |

Call it **`alwaysOnTop`** (a.k.a. "topmost") throughout. A window can be tiling
or floating, sticky or not, and independently topmost or not. Typical use is a
*floating* window (PiP, a reference panel) the user wants kept above the tiled
grid — but do not *require* floating; a tiling window can also be flagged
topmost.

**Manual toggle is the first-class entry point** (mirrors manual sticky). A
persistent per-app rule flag is a deferred follow-up (see Phase 5), matching how
`sticky` shipped (manual toggle + `ruleEffects.sticky`).

---

## Model the toggle on the existing `sticky` toggle

`toggleFocusedWindowSticky` is the closest analog and should be copied
structurally. The full chain to replicate for `alwaysOnTop`
(cited from the current tree):

- **State store:** `manualStickyWindowTokens: Set<WindowToken>` in
  `WorkspaceManager` (`WorkspaceManager.swift:225`), with the token-rekey handoff
  on managed replacement (`WorkspaceManager.swift:2632`), the `insert`/`remove`
  toggles (`WorkspaceManager.swift:3074`/`:3078`), a `reset` clear
  (`WorkspaceManager.swift:521`), and an `is…Window(_:)` query
  (`WorkspaceManager.swift:3044`). The new feature adds a sibling
  `alwaysOnTopWindowTokens` set with the *same* lifecycle handling — the rekey at
  `:2632` and the reset at `:521` are easy to forget and are covered by tests below.
- **Command enum:** `HotkeyCommand.toggleFocusedWindowSticky` (`HotkeyCommand.swift:82`).
- **Action catalog:** the `action(...)` spec block at `ActionCatalog.swift:699`,
  plus `displayName` (~`:952`) and `ipcCommandName` (~`:1110`).
- **Dispatch:** `CommandHandler.swift:190` (`case .toggleFocusedWindowSticky: …`).
- **Controller impl:** `WMController.toggleFocusedWindowSticky()`
  (`WMController.swift:3523`) → `toggleWindowSticky(token:)` (`WMController.swift:3467`).
  This is the template: it flips the WorkspaceManager flag, optionally promotes
  tiling→floating, and requests a layout refresh.
- **IPC / CLI:** `IPCCommandRouter.swift:185`,
  `NehirIPC/IPCAutomationManifest.swift:743`, config mapping
  `HotkeyConfigMapping.swift:123`, `NehirCtl/CLIParser.swift`.
- **Bar affordance (optional, later):** the workspace-bar window context menu
  already exposes toggle-floating (`WorkspaceBarView.swift:1111`,
  `onToggleFloating`); an "Always on top" item slots in beside it.

---

## Implementation plan

### Phase 1 — Feasibility spike (blocking gate) — **do this first**

**Goal:** empirically decide whether `SLSTransactionSetWindowLevel` changes the
effective z-order of a *foreign* app window on Nehir's main SkyLight connection,
without SIP changes.

1. Add a thin, self-contained probe (behind an internal debug command or a
   one-off `NEHIR_EXPERIMENT_*` env-gated code path, mirroring existing
   `NEHIR_EXPERIMENT_*` experiments) that, for the focused managed window's
   WindowServer id `wid`:
   - reads the current level via the existing `windowIteratorGetLevel`
     read path (`SkyLight.swift:255`) and logs it;
   - calls `transactionMoveAndOrder(wid, origin: currentOrigin, level: 3,
     relativeTo: 0, order: .above)` (i.e. exercises `SLSTransactionSetWindowLevel`
     on a foreign wid);
   - re-reads the level and logs before/after;
   - logs whether `isWindowOrderedIn(wid)` still returns true.
2. **Manual runtime confirmation** (per `docs/offscreen-clamp-fix.md`'s hard rule:
   an API returning `.success` is *not* proof — a human must visually confirm):
   - open a normal app window, place another app window overlapping it, run the
     probe on the first, and confirm **visually** that it now sits above the
     other and **stays** above when the other app is clicked/activated;
   - confirm the probed window still appears in Nehir's own tracking (it must not
     vanish from `queryAllVisibleWindows`, given the 0/3/8 level filter).
3. Record the concrete before/after level values and the visual outcome **inline**
   in this document (no trace-file references), then pick the branch:
   - **Spike passes** (level-set visibly re-orders a foreign window and it sticks):
     implement **Phase 2A (real level-set)**.
   - **Spike fails / silently ignored** (matches the order-out finding): implement
     **Phase 2B (continuous re-raise fallback)** and record that the real level-set
     is SIP-gated, updating the pessimistic note in
     `discovery/20260617-omniwm-315-sticky-apps-across-workspaces.md` with the
     measured evidence.

**Acceptance:** this document contains a definitive, measured yes/no for
foreign-window level-set, with the numeric level readback and the visual result
stated in prose.

> Everything below is the same regardless of branch **except** the "apply the
> topmost effect" step, which is 2A **or** 2B.

### Phase 2 — State + toggle command (branch-independent)

1. Add `alwaysOnTopWindowTokens: Set<WindowToken>` to `WorkspaceManager`
   (sibling of `manualStickyWindowTokens`, `WorkspaceManager.swift:225`), with:
   - `is AlwaysOnTopWindow(_ token:) -> Bool` query (sibling of
     `isManualStickyWindow`, `:3044`);
   - `setAlwaysOnTop(_:for:)` insert/remove (sibling of `:3074`/`:3078`) that
     calls `invalidateWorkspaceProjection(reason: "alwaysOnTopChanged")`;
   - the managed-replacement token rekey (sibling of `:2632`) so the flag follows
     a window across app-managed window replacement;
   - the reset clear in the `reset()`/`removeAll()` block (`:521`).
2. Add `HotkeyCommand.toggleFocusedWindowAlwaysOnTop` (`HotkeyCommand.swift`).
3. Add the `ActionCatalog` entry (`:699`+), `displayName` (~`:952`,
   e.g. "Toggle Always on Top"), `ipcCommandName` (~`:1110`,
   e.g. `toggle-focused-window-always-on-top`), keywords
   `["always on top", "topmost", "pin above", "raise"]`.
4. Dispatch in `CommandHandler.swift:190` block.
5. `WMController.toggleFocusedWindowAlwaysOnTop()` →
   `toggleWindowAlwaysOnTop(token:)`, modeled on `WMController.swift:3467`:
   flip the flag, then request a layout refresh so the apply step runs.
6. IPC/CLI wiring: `IPCCommandRouter.swift:185`,
   `IPCAutomationManifest.swift:743`, `HotkeyConfigMapping.swift:123`,
   `NehirCtl/CLIParser.swift`.

**Default binding:** `.unassigned` (same as the float/sticky toggles) — the user
assigns a hotkey; the command is discoverable in the command palette.

### Phase 2A — Apply via real level-set (only if Phase 1 passes)

- Add a thin `SkyLight.setWindowLevel(_ wid: UInt32, level: Int32)` wrapper around
  `transactionSetWindowLevel` (or reuse `transactionMoveAndOrder` with the current
  origin) — keep it symmetric with the existing `orderWindow`.
- In the layout-refresh apply path where managed windows are ordered
  (`LayoutRefreshController.swift:4590`/`:4704` region and the focus-raise at
  `WMController.swift:49`), for a token in `alwaysOnTopWindowTokens`, set the
  chosen topmost level (default `3`, an allow-listed level); for a token toggled
  **off**, restore level `0` and re-order normally.
- **Guard the level filter:** if the chosen topmost level is not in `{0,3,8}`,
  widen the `queryAllVisibleWindows` allow-list (`SkyLight.swift` enumerator) to
  include it, or the pinned window disappears from tracking. Prefer level `3` to
  avoid touching the filter at all.

### Phase 2B — Apply via continuous re-raise (only if Phase 1 fails)

- On each event that can bury a pinned window, re-issue `.above` for every token
  in `alwaysOnTopWindowTokens`:
  - end of layout refresh (`LayoutRefreshController` reveal path, near
    `:4590`/`:4704`);
  - focus change / managed-window raise (`WMController.swift:49` region);
  - app activation notifications already observed by the controller.
- Re-raise ordering: pinned windows are raised **last** (so they end on top),
  and if multiple are pinned, raise in a stable order (e.g. by workspace bar
  order) to avoid thrash.
- Explicitly document the known limitations in the command's help text /
  changeset: brief flicker when another window is raised; cannot sit above other
  apps' genuine high-level overlays; two pinned windows will contend.

### Phase 3 — Interaction with existing floating / sticky / niri semantics

- **Do not force floating.** Unlike a PiP auto-float, `alwaysOnTop` is orthogonal;
  a tiling window may be topmost. But raising a *tiling* window above its
  neighbours visually breaks the tiled grid illusion, so surface it as an
  intentional user choice (no auto-mode-change). If UX wants parity with sticky's
  auto-promotion, make it a **separate, explicit** decision, not a silent one.
- **Sticky composition:** a topmost + sticky window stays visible across
  workspaces *and* above others — the two effects simply both apply; no special
  case needed beyond both flags being independently checked.
- **Focus border ordering:** `FocusBorderController.borderOrdering(for:)`
  (`FocusBorderController.swift:354`) decides `.above`/`.below` for the border
  overlay relative to the focused window. Verify the border still renders
  correctly relative to a topmost window (the border overlay is level `3` too);
  if a topmost app window and the border collide at the same level, the border's
  relative ordering (`relativeTo` the window id) must still place it correctly.
  Add a border test (below).

### Phase 4 — Diagnostics

Add trace output at the apply site: token, wid, chosen level, before/after
`windowIteratorGetLevel`, and whether re-raise or level-set was used. Keep it
inline-evidence-friendly (values, not file refs) per the discovery-doc rule.

### Phase 5 — Deferred: persistent per-app rule flag

Mirror `sticky`'s rule path so a window can be *born* topmost:
`AppRule.alwaysOnTop: Bool?` (`AppRule.swift`, beside `sticky` at `:72`) →
`ManagedWindowRuleEffects.alwaysOnTop` (`WindowRuleEngine.swift:50` region) →
TOML codec (`AppRuleFileStore` / `CanonicalTOMLConfig.swift`) → IPC projection →
`AppRuleDraft.swift` UI + a "Topmost" badge in `AppRulesView`. Defer until the
manual toggle ships and the mechanism (2A vs 2B) is settled — same slicing as the
sticky rollout.

---

## Non-goals

- **No SIP-disabled scripting addition.** If Phase 1 shows real level-set needs
  SIP, ship 2B, do not add an injection payload.
- **No forcing another app's `collectionBehavior`/Space membership** — that is
  the (B) sub-problem correctly ruled out in
  `discovery/20260617-omniwm-315-sticky-apps-across-workspaces.md`; out of scope.
- **No auto-topmost heuristic** by level/subrole. Topmost is an explicit user act
  (or, later, an explicit rule). Do not reuse the PiP `level > 0 → floating`
  classifier direction from
  `discovery/20260617-omniwm-113-above-normal-level-pip-tiling.md` to *set* topmost.
- **No change to the 0/3/8 discovery level filter** unless Phase 2A picks a level
  outside it (prefer staying inside it).

---

## Tests

State/command (pure, no OS):

- Toggling `alwaysOnTop` on a token flips `isAlwaysOnTopWindow` and invalidates
  the workspace projection.
- Managed replacement rekeys the flag from old to new token (mirror the sticky
  rekey test around `WorkspaceManager.swift:2632`).
- `reset()` clears `alwaysOnTopWindowTokens`.
- Command dispatch: `.toggleFocusedWindowAlwaysOnTop` routes to
  `WMController.toggleFocusedWindowAlwaysOnTop()`.
- IPC/CLI: the command name resolves and round-trips through the automation
  manifest and CLI parser.

Apply path (fake the SkyLight boundary — observe, do not let the test decide the
Nehir algorithm, per `docs/TESTING.md`):

- **2A:** a token in `alwaysOnTopWindowTokens` causes a `setWindowLevel`/
  `transactionMoveAndOrder` call with the chosen level and `.above`; toggling off
  restores level `0`. Assert against a fake `Operations`/SkyLight seam like
  `BorderWindowTests` does (`Tests/NehirTests/BorderWindowTests.swift`).
- **2B:** re-raise re-issues `.above` for the pinned token on refresh/focus/
  activation events; a non-pinned token does not.
- Level-filter guard: if a non-`{0,3,8}` level is chosen, a test asserts the
  allow-list includes it (prevents the "pinned window vanishes from tracking"
  regression).

Border interaction:

- Focus border still orders correctly relative to a topmost focused window
  (extend the existing `BorderWindowTests` ordering assertions).

New tests go into **small per-behavior files** (e.g.
`Tests/NehirTests/AlwaysOnTopToggleTests.swift`,
`Tests/NehirTests/AlwaysOnTopApplyTests.swift`) — never appended to the frozen
monoliths, per `docs/TESTING.md`.

---

## Acceptance criteria

1. Phase 1 records a measured, visual yes/no for foreign-window level-set inline
   in this doc.
2. A user can bind a hotkey (and use the command palette) to toggle "Always on
   top" for the focused window; the flag persists until toggled off or the
   window closes, and follows the window across managed replacement.
3. On the shipped mechanism, a pinned floating window visibly stays above tiled
   windows: crisply (2A) or via re-raise on activation/focus (2B).
4. Pinning does not remove the window from Nehir's tracking (level-filter safe).
5. Topmost composes with sticky and with floating/tiling without special-casing.
6. No SIP dependency; no new app-bundle hardcodes; the 2B limitations (if shipped)
   are documented in the changeset and command help text.

---

## Risks & mitigations

- **Real level-set silently ignored on foreign windows** → Phase 1 gate; 2B
  fallback guarantees a shippable feature either way.
- **Pinned window vanishes from tracking** (level outside 0/3/8) → prefer level
  `3`; otherwise widen the allow-list with a guard test.
- **Border overlay z-fights the topmost window** (both level 3) → border uses
  relative-to-window ordering; add a border ordering test.
- **Two pinned windows contend** → stable raise order; document as expected.
- **Tiling window raised above the grid looks broken** → surface as an explicit
  user choice, no silent auto-float.

## Changeset

On ship: `mise run changeset minor "Add a command to keep the focused window
always on top (topmost)"` — note the mechanism and, for 2B, the approximate
nature in the summary.
