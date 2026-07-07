# Discovery: Multiple scratchpad window assignments

Groom 2026-07-07: in flight — see `planned/20260621-multiple-scratchpad-assignments.md` (verified against main 7a025b78).

- **Idea (backlog #7):** Allow more than one window to be assigned to the
  scratchpad at the same time.
- **Source of idea:** `planned/20260621-backlog-brainstorm.md` (item #7,
  "Multiple scratchpad window assignments").
- **Branch:** docs-only `plans-only`. No source changes — this is investigation
  only. All citations are repo-relative and verified against the main Nehir
  source tree on 2026-06-21. Line numbers drift; re-verify before implementing.

## TL;DR / recommendation

**Pursue — but sequence it.** Today Nehir models the scratchpad as exactly one
window. The *visibility/hiding* layer is already per-window and would happily
hide several scratchpad windows; what makes it single-window is a thin set of
explicit guards: one optional token in session state, an assignment gate that
rejects a second assignment, and an arity-0 toggle/bar/IPC/hotkey chain that
has no notion of "which" scratchpad. Lifting the limit is mostly mechanical in
the data and assignment layers, but the command chain (hotkey → command → IPC →
bar) is currently index-free, so adding "which slot" threads an index through
~6 layers and forces a real product decision on toggle semantics (numbered
slots vs. a cyclable stack). Recommend implementing **after** backlog #8 ("Fix
target window for commands like toggle floating / scratchpad") and #22 ("Make
all numbered hotkeys use `{N}`"), because both clean up paths this feature
depends on. Details and a concrete sequencing plan below.

## What the idea means for Nehir

The scratchpad is Nehir's "park a window off-screen and pop it back on a
hotkey" slot — a transient, floating, hidden window that survives workspace
switches and is recalled with `toggle scratchpad`. The idea is to let the user
keep **several** such windows (e.g. a terminal, a mail client, and a calculator)
and address each one individually rather than having the second assignment
evict or be rejected.

Upstream context worth knowing before designing this: **niri itself has no
built-in scratchpad** (see niri-wm/niri discussion #329, "Scratchpads for quick
access to often used windows" — *"there's no scratchpad in niri atm"*). The
concept is supplied entirely by third-party tools in the niri ecosystem, which
have converged on two patterns:

- **Static scratchpads** — matched by `app-id`/`title`; if multiple windows
  match, all are toggled together (e.g. `argosnothing/niri-scratchpad-rs`,
  `gvolpe/niri-scratchpad`).
- **Dynamic indexed scratchpads** — the focused window is assigned to a
  **numbered register**, and each register is toggled by its own keybind
  (e.g. `Vizkid04/niri-scratchpad`, `b0o/niri-tools`).

Nehir's current scratchpad is neither; it is the simplest possible model — a
single anonymous slot. "Multiple scratchpad assignments" most naturally means
moving Nehir toward the **dynamic indexed** model (numbered slots), which is
the only one of the three that preserves the existing "assign the focused
window" UX while removing the one-window ceiling.

## Current behavior (single-token model)

The whole feature keys off **one optional token** stored in session state:

- `Sources/Nehir/Core/Workspace/WorkspaceManager.swift:177` —
  `var scratchpadToken: WindowToken?` inside `SessionState`.
- The public surface around it is entirely singular
  (`Sources/Nehir/Core/Workspace/WorkspaceManager.swift:1095-1110`):
  `scratchpadToken() -> WindowToken?`, `setScratchpadToken(_:)`,
  `clearScratchpadIfMatches(_:)`, `isScratchpadToken(_:) -> Bool`. Private
  mutators `updateScratchpadToken`/`clearScratchpadToken` at `:2061-2076`.

Assignment is gated to enforce exactly-one:

- `Sources/Nehir/Core/Controller/WMController.swift:3551-3592`
  (`assignFocusedWindowToScratchpad()`). The singularity guard is at `:3568-3576`:
  if there is an existing `scratchpadToken()` whose entry still exists, the
  function returns `.notFound` and does nothing. (If the old token's entry is
  gone it cleans up and proceeds.) The happy path force-floats the window,
  captures its geometry (`prepareWindowForScratchpadAssignment`, `:1831-1870`),
  calls `setScratchpadToken(token)`, then `hideScratchpadWindow` (`:1953-1978`).
- This single-assignment contract is **encoded directly in tests**:
  `Tests/NehirTests/WMControllerScratchpadTests.swift`,
  `assignFocusedWindowToScratchpadHidesTiledWindowAndRejectsSecondAssignment`
  asserts that a second assignment returns `.notFound` and leaves the second
  window tiled. Any multi-assignment change must rewrite this test.

Toggle, bar activation, and cleanup are all arity-0 / single-token:

- `Sources/Nehir/Core/Controller/WMController.swift:3637-3677`
  (`toggleScratchpadWindow()`) — toggles *the* scratchpad; takes no index.
- `Sources/Nehir/Core/Controller/WMController.swift:734-769`
  (`activateScratchpadFromBar(on:)`) — bar pill click; resolves the one token.
- `Sources/Nehir/Core/Controller/WMController.swift:1929-1952`
  (`cleanupScratchpadWindowResources(for:)` / `…IfNeeded`,
  `rekeyScratchpadWindowResources(from:to:)`) — keyed by token, so already
  per-window, but driven from the single-token assumption at call sites.
- `Sources/Nehir/Core/Controller/WMController.swift:1980-2017`
  (`showScratchpadWindow`) — reassigns to the target workspace and restores.

Command / IPC / hotkey chain (all index-free today):

- `Sources/Nehir/Core/Input/HotkeyCommand.swift:81-82` —
  `case assignFocusedWindowToScratchpad`, `case toggleScratchpadWindow`.
- `Sources/Nehir/Core/Input/ActionCatalog.swift:700-711, 931-932, 1086-1089` —
  catalog entries, display names, and glyph mapping for the two commands.
- `Sources/Nehir/Core/Config/HotkeyConfigMapping.swift:122-123` —
  `[layout] assignScratchpad` and `[layout] toggleScratchpad` config keys, both
  arity-0. **No scratchpad count/slot config exists anywhere in
  `Sources/Nehir/Core/Config/`.**
- `Sources/NehirIPC/IPCModels.swift` — command enum cases `scratchpadAssign` /
  `scratchpadToggle` (`:283-284`, `:418-419`, plus bridging at `:569-572`,
  `:839-844`, `:1084-1087`, `:1262-1264`) carry no slot argument;
  `IPCWorkspaceBarScratchpad` (`:2047-2056`) is a single struct;
  `WindowCounts.scratchpad: Int` (`:205-211`) is computed to be 0 or 1.
- `Sources/Nehir/IPC/IPCCommandRouter.swift:183-186, 372-377` and
  `Sources/Nehir/IPC/IPCQueryRouter.swift:56, 327-384, 474, 697-698` — routing
  and query projection; `scratchpadCount = entries.filter { isScratchpadToken($0.token) }.count`
  (`IPCQueryRouter.swift:379`) is structurally 0-or-1 today.
- `Sources/Nehir/IPC/IPCAutomationManifest.swift:16, 37, 295, 355, 736-740` —
  CLI/shell-completion manifest: `scratchpad assign` / `scratchpad toggle` and
  the `--scratchpad`/`is-scratchpad` selector. No slot flag.

UI:

- `Sources/Nehir/UI/WorkspaceBar/WorkspaceBarDataSource.swift:136-162`
  (`scratchpadItem`) returns a single optional `WorkspaceBarScratchpadItem?`.
- `Sources/Nehir/UI/WorkspaceBar/WorkspaceBarView.swift:452-510`
  (`ScratchpadPillView`) renders that one pill; `WorkspaceBarProjection.scratchpad`
  is a single optional (`WorkspaceBarView.swift:83-84`).

Persistence:

- **Scratchpad assignment is not persisted across restart.** `scratchpadToken`
  appears nowhere in `RestorePlanner` persistence, `RuntimeStore`, or boot
  restore. The only `RestorePlanner` reference is
  `Sources/Nehir/Core/Reconcile/RestorePlanner.swift:78, 339`, where
  `isScratchpadHidden` is used to *skip* scratchpad-hidden windows from the
  floating-rescue plan. So scratchpad state is transient by design — a behavior
  to preserve (or explicitly revisit) under multi-assignment.

Docs describe the singular model as intentional:

- `docs/ARCHITECTURE.md:463` (`scratchpadToken: WindowToken?` in the session
  diagram), `:779` ("Tracks the transient scratchpad window via
  `scratchpadToken()`"), and `:1031` — *"Scratchpad — A special slot for a
  single transient window that can be toggled in/out of view."*
- `docs/IPC-CLI.md:343-344, 420` — singular command/selector docs.

## Key insight: the hiding layer is already multi-capable

The single-token storage is *not* what hides the window. Visibility is a
**per-window** `HiddenReason.scratchpad` stored in the `WindowModel`, and that
layer already iterates over *all* scratchpad-hidden entries, not just the one
token:

- `Sources/Nehir/Core/Workspace/WindowModel.swift:57` (`case scratchpad` in
  `HiddenReason`) and `:64-86, 110-120` (`WindowVisibility.hiddenScratchpad`).
  This is the per-window visibility enum introduced by codebase-review finding
  #5 (PR #41); see `discovery/20260613-codebase-review-findings.md`. It has no
  "only one may be scratchpad-hidden" invariant.
- `Sources/Nehir/Core/Controller/LayoutRefreshController.swift:1529-1560`
  (`preserveScratchpadHiddenWindowsDuringFullRescan`) loops
  `for entry in entries where hiddenState(for: entry.token)?.isScratchpad == true`
  and preserves **each** one across a full rescan. This already does the right
  thing for N scratchpad windows.
- Eviction and bar-visibility checks key off the per-window hidden state, not
  the single token:
  `Sources/Nehir/Core/Workspace/WorkspaceManager.swift:2587`
  (`!isScratchpadToken($0.token) && hiddenState(for: $0.token)?.isScratchpad != true`)
  and `:2974` (`!hiddenState.isScratchpad`).
- Reveal/cancel machinery is per-token:
  `Sources/Nehir/Core/Controller/LayoutRefreshController.swift:2821-2835`
  (`restoreScratchpadWindow`) and `:2984-2992` (`cancelPendingScratchpadReveal(for:)`).
- Rekey and lifecycle are per-token at the call sites:
  `Sources/Nehir/Core/Controller/AXEventHandler.swift:2598-2599, 2667, 2722`
  and the `WMController` `rekey/cleanup` helpers above.

**Implication:** the hard part is *not* hiding multiple windows. It is (a) the
token-storage + assignment gate, and (b) the index-free toggle/bar/IPC/hotkey
chain that currently has no way to say "which" scratchpad. The hiding,
rescan-preservation, eviction-exemption, rekey, and reveal paths are already
written against per-window state and need little to no change.

## Where / how it would be implemented

Grouped by layer, smallest first:

1. **Core storage + API** (`Sources/Nehir/Core/Workspace/WorkspaceManager.swift`).
   Replace `var scratchpadToken: WindowToken?` (`:177`) with an ordered
   collection plus a "current" pointer, e.g. `var scratchpadSlots:
   [WindowToken]` (or `[Int: WindowToken]` for indexed slots) and re-skin the
   accessors at `:1095-1110` / `:2061-2076`. Keep `isScratchpadToken(_:)`
   (now "is in the set"). Add `scratchpadToken(at:)`, `scratchpadSlotCount`,
   etc. The rekey path at `:2535-2543` becomes "remap any slot equal to
   oldToken"; the clear-on-window-removal at `:1861` becomes "remove from set".

2. **Assignment gate + semantics**
   (`Sources/Nehir/Core/Controller/WMController.swift:3551-3592`). Drop the
   "reject if existing entry" branch at `:3568-3576`. Decide what
   `assignFocusedWindowToScratchpad` does with N slots — append to a new slot,
   reuse a freed slot, or require an explicit slot index. The force-float +
   geometry-capture + hide helpers (`:1831-1870`, `:1953-1978`) are reusable
   unchanged.

3. **Toggle/select command chain** — the invasive part because it is currently
   arity-0 end to end. `toggleScratchpadWindow` (`:3637-3677`) and
   `activateScratchpadFromBar` (`:734-769`) need a slot/index parameter
   (or a "cycle to next" behavior). That index must propagate through
   `HotkeyCommand` (`HotkeyCommand.swift:81-82`), `ActionCatalog`
   (`:700-711, 931-932, 1086-1089`), `HotkeyConfigMapping` (`:122-123`),
   `CommandHandler` (`:188-191`), the IPC command enum and routers
   (`IPCModels.swift:283-284/418-419`, `IPCCommandRouter.swift:183-186`),
   the CLI manifest (`IPCAutomationManifest.swift:736-740`), and the bar
   projection (`WorkspaceBarDataSource.swift:136-162`,
   `IPCQueryRouter.swift:56, 327-384`). This is where backlog #22 (`{N}`
   template hotkeys) is a direct enabler — numbered slots want numbered
   bindings.

4. **UI** (`Sources/Nehir/UI/WorkspaceBar/`). `WorkspaceBarProjection.scratchpad`
   becomes an array; render N pills (or a stacked pill with a count).
   `ScratchpadPillView` (`WorkspaceBarView.swift:452-510`) and
   `scratchpadItem` (`WorkspaceBarDataSource.swift:136-162`) change shape.
   `IPCWorkspaceBarScratchpad` (`IPCModels.swift:2047-2056`) and the query
   projection (`IPCQueryRouter.swift:327-344`) become arrays.
   `WindowCounts.scratchpad` (`IPCModels.swift:205`) already counts, so it
   generalizes from {0,1} to N for free.

5. **Tests** (`Tests/NehirTests/WMControllerScratchpadTests.swift`).
   Rewrite `…RejectsSecondAssignment` to assert the new multi behavior; add
   cases for slot addressing, toggle-by-slot, and rekey/eviction with multiple
   scratchpad windows. The other tests in the suite (toggle recaptures frame,
   visibility refreshes the bar, app-termination unpins the AX element) are
   per-window already and port directly.

## Central design decision: toggle semantics

Before any code, pick one (this is a product call, not an implementation
detail):

- **(A) Dynamic indexed slots** (niri ecosystem's "dynamic" pattern; matches
  backlog #22). `assign` puts the focused window in the next free numbered
  slot; `toggle <N>` shows/hides slot N. Clean addressing, clean IPC, needs
  the `{N}` hotkey template. Most expressive; most plumbing.
- **(B) Single cyclable stack** (i3-style). `assign` pushes onto a stack;
  `toggle` shows the most-recent and a second `toggle` (or a `cycle` command)
  rotates. Least plumbing (commands stay arity-0), but you can't address a
  specific window directly and the bar pill becomes ambiguous.
- **(C) Static/app-rule scratchpads** (niri ecosystem's "static" pattern).
  Config-driven by `bundle-id`/`title`; out of scope for "assign the focused
  window" but worth noting as a future layer on top of (A).

Recommendation inside the recommendation: **(A)**, because it composes with the
existing "assign focused window" UX and with backlog #22, and because the
hiding layer already supports it. (B) is a cheaper fallback if #22 slips.

## Risks and unknowns

- **Arity-0 command chain is the cost center.** Every layer from hotkey to bar
  assumes one scratchpad. Threading an index (or a "cycle" verb) is the bulk of
  the work and the bulk of the IPC/CLI compatibility surface (manifest,
  shell completions, docs `docs/IPC-CLI.md:343-344, 420`).
- **Subtle single-token dependencies to audit** when moving to a set:
  `shouldSpeculativelyPreserveNativeFullscreenDestroy`
  (`AXEventHandler.swift:2722`, `scratchpadToken() != token`) and the native
  fullscreen rekey path (`WorkspaceManager.swift:2535-2543`) both key off "the"
  token. These become "token ∈ scratchpad set" / "remap any matching slot" —
  small but easy to miss.
- **Toggle-vs-show ambiguity.** With N windows, "toggle scratchpad" is no
  longer well-defined without an index; the current bar pill and hotkey both
  assume there is exactly one. Picking semantics (B) avoids the index but
  introduces "which window pops" ambiguity that doesn't exist today.
- **Persistence policy.** Scratchpad assignment is transient today (see above).
  Multi-assignment should probably stay transient, but with more windows parked
  users may expect them to survive restart — an open product question, not a
  code risk.
- **Interaction with backlog #8.** #8 ("Fix target window for commands like
  toggle floating / scratchpad") touches the same toggle/assignment target
  selection. Doing #8 first de-risks the target-selection path this feature
  also needs; doing them in the opposite order risks rework.
- **Bar clutter.** One pill today; N pills (or a count) changes the workspace
  bar layout and the `WorkspaceBarProjection` equality/refresh path
  (`WorkspaceBarDataSource.swift`, `WorkspaceBarManager.swift:435`).

## Open questions

1. Indexed slots (A) vs. cyclable stack (B) vs. both? (Drives the whole IPC
   and hotkey shape.)
2. Does `assign` when all slots are full evict the oldest, reject, or prompt?
3. Should scratchpad assignments persist across restart (currently transient)?
4. How are slots numbered/exposed in config — fixed pool (1..N) or dynamic?
5. Does the `--scratchpad` / `is-scratchpad` IPC selector
   (`IPCApplicationBridge.swift:289`, `IPCQueryRouter.swift:474`) gain a
   `--scratchpad-slot N` companion, and is the per-window `is-scratchpad`
   field (`IPCModels.swift:2217-2248`) extended with a slot index?

## Related prior work (not duplicated here)

- `planned/20260621-backlog-brainstorm.md` — this is item #7; items **#8**
  (fix target window for toggle floating / scratchpad) and **#22** (`{N}`
  template hotkeys) are the recommended sequencing predecessors.
- `discovery/20260613-codebase-review-findings.md` finding #5 (done, PR #41) —
  the per-window `WindowVisibility.hiddenScratchpad` enum is what makes the
  hiding layer already multi-capable.
- `completed/20260619-workspace-assignment-lone-window-width-and-reveal.md`
  and `completed/20260619-workspace-assignment-lone-window-width-cache-leak.md`
  — scratchpad reveal shares the pending-reveal transaction machinery that any
  multi-scratchpad change must keep consistent.
- `discovery/20260616-omniwm-323-floating-panel-bar-filter.md` — workspace-bar
  floating filtering interacts with the scratchpad exclusion that the bar
  projection change above would touch.
- `discovery/20260618-pure-niri-engine-extraction.md` and
  `discovery/20260618-upstream-port-roadmap.md` — note that scratchpad is a
  Nehir/OmniWM-derived feature (niri proper has none) and was intentionally
  kept out of the extracted *pure* engine; this idea concerns the shipping
  product, not the pure engine.

## Recommendation

**Pursue, as dynamic indexed slots (design option A), sequenced after #8 and
#22.** Rationale: the expensive layer (per-window hiding/rescan/reveal/rekey)
already supports multiple windows, so the feature is genuinely scoped to the
storage, assignment gate, and the index-free command chain — well-understood,
mechanical work once toggle semantics are chosen. Sequencing after backlog #8
avoids reworking the toggle/assignment target path, and after #22 so numbered
slots get numbered hotkeys for free. Defer the stack-vs-indexed decision and
the persistence question to a follow-up planning doc; do **not** start
implementation on the hotkey/IPC chain until that decision is locked, because
it determines the shape of every enum case and CLI flag.
