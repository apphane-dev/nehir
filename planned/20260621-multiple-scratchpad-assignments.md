# Multiple scratchpad window assignments

**Status:** planned
**Source discovery:** `discovery/20260621-multiple-scratchpad-assignments.md`
**Prerequisite (sequencing):** backlog **#8** ("Fix target window for commands like toggle floating /
scratchpad") and **#22** ("Make all numbered hotkeys use `{N}` template") — both still in
`planned/20260621-backlog-brainstorm.md`, neither yet planned/completed. Phase 4 of this plan is
hard-gated on both plus an explicit option-A confirmation (see stop-rule).

All source references were re-verified against the main Nehir source tree on
2026-06-22. Re-verify before editing; line numbers drift. The discovery's line
numbers had drifted by ~6-30 lines across `WorkspaceManager`/`WMController`/
`AXEventHandler` and one module path was wrong; corrections are listed under
"Discovery corrections / decisions" and the citations below use the corrected
(current) line numbers.

## TL;DR

Today Nehir models the scratchpad as **exactly one** window: a single optional
`scratchpadToken: WindowToken?` in session state, an assignment gate that
rejects a second assignment, and an arity-0 toggle/bar/IPC/hotkey chain with no
notion of "which" scratchpad. Lifting the limit is mostly mechanical because
the **per-window hiding/rescan/reveal/rekey layer is already multi-capable** —
visibility is a `HiddenReason.scratchpad` stored on each `WindowModel`, and the
rescan-preservation loop already iterates *all* scratchpad-hidden entries.

Following the discovery's verdict, this plan commits to **design option A —
dynamic indexed slots** (assign focused window → next free numbered slot;
`toggle <N>` shows/hides slot N), sequenced **after** backlog #8 and #22. The
work splits into four phases: (1) multi-slot storage + accessor re-skin +
call-site audit, (2) relax the assignment gate and define transitional
toggle/bar behavior, (3) render N scratchpad pills in the bar + array IPC
projection, and (4) — **gated** — thread a slot index through the hotkey →
command → IPC → CLI chain. Phases 1-3 are option-agnostic (identical for A and
B) and safe to land immediately; Phase 4 must not start until #8, #22, and the
option-A decision are locked, because it determines the shape of every enum
case and CLI flag.

## Discovery corrections / decisions

1. **Line-number drift (cosmetic; citations below already corrected).** Verified
   current locations differ from the discovery:
   - `WorkspaceManager.scratchpadToken` decl: `:183` (discovery said `:177`).
   - Public accessors `scratchpadToken()` / `setScratchpadToken` /
     `clearScratchpadIfMatches` / `isScratchpadToken`: `:1101-1116` (discovery
     `:1095-1110`).
   - Private mutators `updateScratchpadToken` / `clearScratchpadToken`:
     `:2083` / `:2095` (discovery `:2061-2076`).
   - Rekey remap `sessionState.scratchpadToken == oldToken`: `:2559-2561`
     (discovery `:2535-2543`).
   - Clear-on-window-removal `clearScratchpadToken(matching:)` inside
     `handleWindowRemoved`: `:1884` (discovery `:1861`).
   - Eviction filter `!isScratchpadToken($0.token) && …isScratchpad != true`:
     `:2610` (discovery `:2587`); `!hiddenState.isScratchpad`: `:2997`
     (discovery `:2974`).
   - `WMController.assignFocusedWindowToScratchpad`: `:3582-3636`, singularity
     guard at `:3599-3604` (discovery `:3551-3592` / `:3568-3576`).
   - `prepareWindowForScratchpadAssignment` `:1837`; `hideScratchpadWindow`
     `:1959`; `showScratchpadWindow` `:1986`; `cleanupScratchpadWindowResources`
     /`…IfNeeded` `:1935`/`:1944`; `rekeyScratchpadWindowResources` `:1953`;
     `toggleScratchpadWindow` `:3668-3715`; `activateScratchpadFromBar`
     `:734-769` (discovery ranges were ~6 lines low throughout).
   - `AXEventHandler.shouldSpeculativelyPreserveNativeFullscreenDestroy` with
     `scratchpadToken() != token`: func at `:2860`, check at `:2865` (discovery
     `:2722`). The rekey call `rekeyScratchpadWindowResources(from:to:)` is at
     `:2810`; the `isScratchpadToken`/`hiddenState…isScratchpad` filter is at
     `:2741-2742` (discovery `:2598-2599, 2667`).

2. **Wrong module path.** The CLI/shell-completion manifest is at
   `Sources/NehirIPC/IPCAutomationManifest.swift`, **not**
   `Sources/Nehir/IPC/IPCAutomationManifest.swift` as the discovery wrote. The
   line citations (`:16, 37, 295, 355, 736-740`) are otherwise accurate.

3. **Decision: commit to option A (dynamic indexed slots).** The discovery
   offered A (indexed), B (cyclable stack), C (static app-rules) and recommended
   A. This plan locks A so the work is worker-ready. The slot model is an
   **ordered array** of tokens `scratchpadSlots: [WindowToken]` (slot index =
   array position, 1-based externally) rather than `[Int: WindowToken]`, because
   it composes directly with backlog #22's `{N}` template and keeps "next free
   slot" = append. Phases 1-3 are deliberately identical under A or B; only
   Phase 4 (index plumbing) is A-specific, and its stop-rule protects against a
   late switch to B.

4. **Decision: transitional toggle/bar semantics for Phases 1-3.** Until Phase 4
   lands the slot index, `toggleScratchpadWindow` and `activateScratchpadFromBar`
   remain arity-0 and operate on the **most-recently-assigned** slot (last element
   of `scratchpadSlots`). This is a defined, tested behavior, not a bug, and is
   replaced by explicit `toggle <N>` in Phase 4. Documented here so a worker
   does not mistake it for an oversight.

5. **Decision: keep scratchpad assignment transient (no restart persistence).**
   The discovery confirmed `scratchpadToken` appears nowhere in `RestorePlanner`
   persistence — only `isScratchpadHidden` is referenced, to *skip* such windows
   from floating rescue (`Sources/Nehir/Core/Reconcile/RestorePlanner.swift:78,
   339`). Multi-assignment stays transient for this plan; persistence is an open
   product question deferred to follow-ups.

6. **Discovery framing confirmed accurate (no correction needed):** the hiding
   layer is already multi-capable. `LayoutRefreshController.preserveScratchpadHiddenWindowsDuringFullRescan`
   (`Sources/Nehir/Core/Controller/LayoutRefreshController.swift:1529-1560`)
   already loops `for entry in entries where hiddenState(for:)?.isScratchpad ==
   true` and preserves **each** one; `restoreScratchpadWindow` (`:2821`) and
   `cancelPendingScratchpadReveal` (`:2984`) are per-token; the eviction filter
   at `WorkspaceManager.swift:2610` and `:2997` keys off per-window hidden state.
   These need no structural change for N windows.

## Scope

### Files to add/change

1. `Sources/Nehir/Core/Workspace/WorkspaceManager.swift`
   - Replace `var scratchpadToken: WindowToken?` (`:183`) with
     `var scratchpadSlots: [WindowToken] = []` inside `SessionState`.
   - Re-skin the public accessors (`:1101-1116`): keep
     `isScratchpadToken(_:) -> Bool` (now "is in the set"); add
     `scratchpadSlotCount -> Int`, `scratchpadToken(at index: Int) -> WindowToken?`,
     `currentScratchpadToken() -> WindowToken?` (last element, for the
     transitional arity-0 toggle), `allScratchpadTokens() -> [WindowToken]`.
     Keep `setScratchpadToken(_:)` / `clearScratchpadIfMatches(_:)` as
     thin wrappers in Phase 1 (assign = append-if-absent; clear = remove) so the
     existing call sites compile; Phase 4 may rename them.
   - Re-skin the private mutators (`updateScratchpadToken` `:2083` /
     `clearScratchpadToken` `:2095`) to mutate the array and keep firing
     `invalidateWorkspaceProjection(reason: "scratchpadTokenChanged")`.
   - Rekey path (`:2559-2561`): replace
     `if sessionState.scratchpadToken == oldToken { = newToken }` with
     "remap any slot equal to oldToken to newToken" (index-preserving).
   - Clear-on-removal in `handleWindowRemoved` (`:1884`): remove the token from
     `scratchpadSlots` instead of clearing the single optional.
   - Debug-dump line (`:364`) and reset line (`:471`): dump/reset the array.
2. `Sources/Nehir/Core/Controller/WMController.swift`
   - `assignFocusedWindowToScratchpad` (`:3582-3636`): **drop the singularity
     guard** at `:3599-3604` (the `if let existingScratchpadToken … else { return
     .notFound }` branch that rejects a second assignment). The
     "unassign-if-already-assigned-and-visible" branch at `:3589-3597` stays
     (it toggles off the focused window if it is already the scratchpad). The
     happy path (`prepareWindowForScratchpadAssignment` `:1837` →
     `setScratchpadToken` → `hideScratchpadWindow` `:1959`) is reusable
     unchanged; `setScratchpadToken` now appends.
   - `toggleScratchpadWindow` (`:3668-3715`) and `activateScratchpadFromBar`
     (`:734-769`): in Phases 1-3 resolve `currentScratchpadToken()` (most-recent
     slot) instead of `scratchpadToken()`. Phase 4 adds an `Int?` slot parameter.
   - `cleanupScratchpadWindowResources` / `…IfNeeded` (`:1935`/`:1944`) and
     `rekeyScratchpadWindowResources` (`:1953`): already per-token; no change.
3. `Sources/Nehir/Core/Controller/AXEventHandler.swift`
   - `shouldSpeculativelyPreserveNativeFullscreenDestroy` (`:2860-2870`): change
     `scratchpadToken() != token` (`:2865`) to `!isScratchpadToken(token)` (i.e.
     "token ∉ scratchpad set"). Audit the `isScratchpadToken`/`hiddenState…isScratchpad`
     filter at `:2741-2742` and the rekey call at `:2810` — already per-token, no
     change expected.
4. `Sources/Nehir/UI/WorkspaceBar/WorkspaceBarDataSource.swift`
   - `scratchpadItem` (`:136-162`): return `[WorkspaceBarScratchpadItem]`
     (array) instead of `WorkspaceBarScratchpadItem?`. Build one item per slot.
5. `Sources/Nehir/UI/WorkspaceBar/WorkspaceBarView.swift`
   - `WorkspaceBarProjection.scratchpad` (`:83-84`): becomes
     `[WorkspaceBarScratchpadItem]`. `ScratchpadPillView` (`:452-510`) renders
     once per item; the body at `:208-216` iterates. `WorkspaceBarScratchpadItem`
     (`:56`) gains a slot index field for Phase 4 addressing.
6. `Sources/NehirIPC/IPCModels.swift`
   - `IPCWorkspaceBarScratchpad` (`:2047-2056`): add an optional `slot: Int?`
     field; the projection field at `:2090` becomes an array.
   - `WindowCounts.scratchpad` (`:205-211`): already an `Int` computed via
     `.count` — generalizes from {0,1} to N for free (see
     `IPCQueryRouter.swift:379`).
   - Per-window `isScratchpad` (`:2217-2248`): add optional `scratchpadSlot: Int?`
     (Phase 4).
7. `Sources/Nehir/IPC/IPCQueryRouter.swift`
   - `workspaceBarScratchpad(from:)` (`:327-344`): project an array.
     `scratchpadCount` (`:379`) already counts via
     `entries.filter { isScratchpadToken($0.token) }.count` — no change.
   - `--scratchpad`/`is-scratchpad` selector handling (`:474`, `:697-698`):
     unchanged for Phase 1-3 (matches any scratchpad window); Phase 4 may add a
     `--scratchpad-slot N` companion.
8. **Phase 4 (gated) — indexed command chain.** Thread `Int?` slot through:
   `HotkeyCommand` (`Sources/Nehir/Core/Input/HotkeyCommand.swift:81-82`),
   `ActionCatalog` (`:700-711, 931-932, 1086-1089`),
   `HotkeyConfigMapping` (`Sources/Nehir/Core/Config/HotkeyConfigMapping.swift:122-123`),
   `CommandHandler` (`Sources/Nehir/Core/Controller/CommandHandler.swift:188-191`),
   IPC command enum `scratchpadAssign`/`scratchpadToggle`
   (`Sources/NehirIPC/IPCModels.swift:283-284, 418-419` and bridging `:569-572,
   839-844, 1084-1087, 1262-1264`), `IPCCommandRouter`
   (`Sources/Nehir/IPC/IPCCommandRouter.swift:183-186, 372-377`), and the CLI
   manifest (`Sources/NehirIPC/IPCAutomationManifest.swift:736-740`). Add
   `toggleScratchpadWindow(slot:)` / `activateScratchpadFromBar(slot:on:)`.
9. Docs: `docs/ARCHITECTURE.md` (`:463, 779, 1031`) and `docs/IPC-CLI.md`
   (`:343-344, 420`) — update the singular "single transient window" wording and
   the command/selector docs to the multi-slot shape (Phase 4).

### Non-goals

- Do **not** change the per-window hiding/rescan/reveal/rekey machinery — it
  already supports N scratchpad windows (see correction #6). Only its call sites
  that read "the" token change.
- Do **not** persist scratchpad assignments across restart in this plan
  (transient by design; deferred).
- Do **not** implement static/app-rule scratchpads (discovery option C).
- Do **not** start Phase 4 (index plumbing) until backlog #8, #22, and the
  option-A confirmation are all locked (stop-rule below).
- Do **not** change `WindowCounts.scratchpad` semantics (already `Int`/`.count`).
- Do **not** change the eviction-exemption predicate shape at
  `WorkspaceManager.swift:2610` / `:2997` beyond swapping the single-token test
  for a set-membership test.
- Do **not** alter the pure niri engine extraction
  (`completed/20260619-pure-niri-engine-extraction-a1.md`) — scratchpad is a
  Nehir/OmniWM-derived feature intentionally kept out of the pure engine.

## Exact implementation plan

### Phase 1 — Multi-slot storage model (option-agnostic, lands first)

1. In `WorkspaceManager.SessionState` (`:183`), replace
   `var scratchpadToken: WindowToken?` with `var scratchpadSlots: [WindowToken]
   = []`.
2. Re-skin accessors (`:1101-1116`) and private mutators (`:2083`/`:2095`):
   - `func scratchpadToken(at index: Int) -> WindowToken?` → bounds-checked
     `scratchpadSlots[index]`.
   - `var scratchpadSlotCount: Int { scratchpadSlots.count }`.
   - `func currentScratchpadToken() -> WindowToken? { scratchpadSlots.last }`
     (transitional, for arity-0 toggle).
   - `func allScratchpadTokens() -> [WindowToken] { scratchpadSlots }`.
   - `func isScratchpadToken(_ token: WindowToken) -> Bool {
     scratchpadSlots.contains(token) }`.
   - `setScratchpadToken(_ token:)` → append if absent (idempotent); keep the
     `@discardableResult` + `invalidateWorkspaceProjection(reason:
     "scratchpadTokenChanged")` side effects.
   - `clearScratchpadIfMatches(_ token:)` → remove `token` from the array.
3. Rekey path (`:2559-2561`): iterate `scratchpadSlots` and replace any element
   `== oldToken` with `newToken` (preserve order/count).
4. `handleWindowRemoved` (`:1884`): the existing
   `clearScratchpadToken(matching: token, notify: false)` call now removes from
   the array — no call-site change beyond the underlying semantics.
5. Debug dump (`:364`) and reset (`:471`): print/clear the array.
6. Audit every `scratchpadToken()` / `isScratchpadToken` call site for
   single-token assumptions:
   - `AXEventHandler.shouldSpeculativelyPreserveNativeFullscreenDestroy`
     (`:2865`): `scratchpadToken() != token` → `!isScratchpadToken(token)`.
   - `LayoutRefreshController` rescan preservation (`:1529-1560`), restore
     (`:2821`), cancel-reveal (`:2984`): already iterate/are per-token — verify,
     expect no change.
   - `WMController` cleanup/rekey/show/hide (`:1935-2017`): per-token — verify.

### Phase 2 — Relax the assignment gate (option-agnostic)

1. In `WMController.assignFocusedWindowToScratchpad` (`:3582-3636`), delete the
   singularity guard at `:3599-3604`:
   ```swift
   // REMOVE:
   if let existingScratchpadToken = workspaceManager.scratchpadToken() {
       if workspaceManager.entry(for: existingScratchpadToken) == nil {
           cleanupScratchpadWindowResources(for: existingScratchpadToken)
       } else {
           return .notFound
       }
   }
   ```
   Keep the "already-assigned-and-visible → unassign" branch at `:3589-3597`.
2. Add a cleanup sweep: before appending, drop any stale slot whose `entry(for:)`
   is nil (generalizes the old "clean up if the old token's entry is gone"
   behavior to the whole set).
3. `toggleScratchpadWindow` (`:3668`) and `activateScratchpadFromBar` (`:734`):
   resolve `currentScratchpadToken()` (most-recent slot) where they today read
   `scratchpadToken()`. No arity change in this phase.

### Phase 3 — Bar/UI multi-pill projection + IPC array (option-agnostic)

1. `WorkspaceBarDataSource.scratchpadItem` (`:136-162`) → build
   `[WorkspaceBarScratchpadItem]`, one per slot, each carrying its 1-based slot
   index.
2. `WorkspaceBarProjection.scratchpad` (`:83-84`) → `[WorkspaceBarScratchpadItem]`;
   the view body (`:208-216`) iterates and renders one `ScratchpadPillView`
   (`:452-510`) per item.
3. `IPCWorkspaceBarScratchpad` (`:2047-2056`): add `slot: Int?`; the containing
   projection field (`:2090`) becomes `[IPCWorkspaceBarScratchpad]?` (or
   `[IPCWorkspaceBarScratchpad]`).
4. `IPCQueryRouter.workspaceBarScratchpad(from:)` (`:327-344`): project the
   array. `scratchpadCount` (`:379`) already generalizes to N.
5. Sanity-check the `--scratchpad` selector (`:474`) and `is-scratchpad` window
   field (`IPCModels.swift:2217-2248`) still work for N windows (they test set
   membership, not equality with a lone token).

### Phase 4 — Indexed command chain (GATED — do not start before the stop-rule)

**Stop-rule.** Do not begin Phase 4 until **all three** hold:
(a) backlog #8 ("Fix target window for commands like toggle floating /
scratchpad") has landed — it cleans up the toggle/assignment target path this
phase extends; (b) backlog #22 ("`{N}` template hotkeys") has landed — numbered
slots want numbered bindings and determines the `HotkeyCommand` associated-value
shape; (c) the product owner has re-confirmed option A. If B (cyclable stack) is
chosen instead, replace this phase with a "cycle scratchpad" verb and skip the
index plumbing.

When unlocked:
1. `HotkeyCommand` (`:81-82`): `case assignFocusedWindowToScratchpad` (unchanged
   — assigns to next free slot) and `case toggleScratchpadWindow(Int)` (slot
   index associated value, 1-based).
2. `ActionCatalog` (`:700-711, 931-932, 1086-1089`): add per-slot catalog entries
   driven by the #22 `{N}` template; update display names and the IPC mapping.
3. `HotkeyConfigMapping` (`:122-123`): add `toggleScratchpadN` as a numbered
   group (consumes the #22 template); verify load→export round-trip.
4. `CommandHandler` (`:188-191`): dispatch `toggleScratchpadWindow(slot)`.
5. `WMController.toggleScratchpadWindow(slot:)` / `activateScratchpadFromBar(slot:on:)`:
   resolve `scratchpadToken(at: slot - 1)`.
6. IPC: extend `scratchpadAssign`/`scratchpadToggle`
   (`IPCModels.swift:283-284/418-419` and bridging) with an optional slot
   argument; `IPCCommandRouter` (`:183-186, 372-377`) forwards it; CLI manifest
   (`Sources/NehirIPC/IPCAutomationManifest.swift:736-740`) gains a `--slot N`
   flag for `scratchpad toggle`; optionally add `--scratchpad-slot N` selector
   (`IPCQueryRouter.swift:474`, `IPCApplicationBridge.swift:289`) and a
   `scratchpadSlot` window field (`IPCModels.swift:2217-2248`).
7. Docs: update `docs/ARCHITECTURE.md:463, 779, 1031` and `docs/IPC-CLI.md:343-344,
   420` to the multi-slot model.

## Tests

`Tests/NehirTests/WMControllerScratchpadTests.swift` (existing suite; current
tests at `:69, 109, 139, 173, 201, 242, 271, 303, 339, 438`):

- **Rewrite** `assignFocusedWindowToScratchpadHidesTiledWindowAndRejectsSecondAssignment`
  (`:69`) → `…AcceptsSecondAssignmentIntoSecondSlot`: a second assignment now
  returns `.executed` and both windows are scratchpad-hidden. This test encodes
  the old single-assignment contract and **must** change.
- **Keep** the per-window tests that port directly:
  `failedScratchpadAssignmentDoesNotLeaveManualFloatOverride` (`:109`),
  `toggleScratchpadWindowRestoresAndRecapturesFloatingFrame` (`:139`),
  `scratchpadVisibilityChangesRequestWorkspaceBarRefresh` (`:173`),
  `appTerminationUnpinsHiddenScratchpadAXElement` (`:201`),
  `assignFocusedWindowToScratchpadClearsVisibleScratchpadSlotWhenRepeated`
  (`:242`),
  `assignFocusedWindowToScratchpadUnassignsVisibleFloatingWindowBackToTiling`
  (`:271`),
  `toggleScratchpadWindowSummonsToCurrentWorkspaceAndMonitor` (`:303`),
  `toggleScratchpadWindowFrontsWindowOnlyAfterAsyncRevealSucceeds` (`:339`),
  `toggleScratchpadWindowFailedHiddenRevealKeepsScratchpadStateAndSkipsFocus`
  (`:438`).
- **Add** Phase 1-2 cases:
  - `scratchpadSlotCountReflectsAssignmentsAndClears` — assign two windows,
    assert `scratchpadSlotCount == 2` and `allScratchpadTokens()` order;
    remove one window, assert count drops and the other survives.
  - `assignFocusedWindowToScratchpadIsIdempotentPerWindow` — assigning the same
    focused window twice does not duplicate the slot.
  - `toggleScratchpadWindowTargetsMostRecentSlotDuringTransition` — with two
    slots, arity-0 toggle reveals the most-recently-assigned (Phase 2
    transitional behavior).
  - `rekeyRemapsScratchpadSlotInPlace` — rekey a token that is in a slot;
    assert the slot order/count is preserved and the new token is found.
- **Add** Phase 3 cases:
  - `workspaceBarProjectsMultipleScratchpadItems` — two assignments produce two
    `IPCWorkspaceBarScratchpad` items with distinct slot indices.
- **Add** Phase 4 cases (only when Phase 4 is unlocked):
  - `toggleScratchpadWindowBySlotShowsOnlyThatSlot` — `toggle <N>` reveals slot
    N and leaves other scratchpad windows hidden.
  - `ipcScratchpadToggleCarriesSlotArgument` — round-trip the IPC enum with a
    slot value.

## Validation

```bash
swift build
swift test --filter WMControllerScratchpadTests
swift test --filter WorkspaceManagerTests
swift test --filter IPCQueryRouterTests
swift test --filter IPCCommandRouterTests
mise run format:check
mise run lint
```

Phase 4 additionally:
```bash
swift test --filter HotkeyConfigMapping      # config round-trip with numbered group
swift test --filter ActionCatalog
swift test --filter IPCAutomationManifest    # if a manifest round-trip test exists
```

Manual validation (Phases 1-3): assign two windows to the scratchpad; confirm
both hide, the bar shows two pills (or a count), an arity-0 toggle reveals the
most-recent, and switching workspaces keeps both hidden. Confirm a full rescan
does not evict either (`LayoutRefreshController.preserveScratchpadHiddenWindowsDuringFullRescan`).

Manual validation (Phase 4): bind `toggle scratchpad <N>` via the #22 `{N}`
template; confirm each slot is individually addressable; confirm
`nehirctl command scratchpad toggle --slot 2` works and shell completions
offer `--slot`.

Changeset (minor): "Allow multiple windows to be assigned to the scratchpad
(indexed slots)."

## Risks and mitigations

- **Arity-0 command chain is the cost center.** Every layer from hotkey to bar
  assumes one scratchpad. Phase 4 threads an index through ~6 layers and is the
  bulk of the IPC/CLI compatibility surface (manifest, shell completions, docs).
  **Mitigation:** the Phase 4 stop-rule defers all of it until #8/#22/option-A
  are locked, so no enum shape is churned twice. Phases 1-3 deliver value
  without it.
- **Transitional toggle ambiguity.** With N windows and no index (Phases 1-3),
  "toggle scratchpad" resolves to the most-recent slot — a behavior that does
  not exist today. **Mitigation:** documented as a decision (#4) and covered by
  an explicit test; replaced by `toggle <N>` in Phase 4.
- **Subtle single-token dependencies to audit** when moving to a set:
  `shouldSpeculativelyPreserveNativeFullscreenDestroy`
  (`AXEventHandler.swift:2865`) and the native-fullscreen rekey path
  (`WorkspaceManager.swift:2559-2561`) both key off "the" token. **Mitigation:**
  Phase 1 step 6 is an explicit audit; both become set-membership / index-
  preserving remap. Add the `rekeyRemapsScratchpadSlotInPlace` test.
- **Interaction with backlog #8.** #8 touches the same toggle/assignment target
  selection. Doing #8 first de-risks the path this feature needs; the Phase 4
  stop-rule enforces that ordering. **Mitigation:** Phases 1-3 are independent
  of #8 and can proceed.
- **Bar clutter.** N pills change the workspace-bar layout and the
  `WorkspaceBarProjection` equality/refresh path. **Mitigation:** Phase 3 keeps
  projection `Equatable`; add the multi-pill projection test; consider a stacked
  pill + count fallback if layout breaks (follow-up).
- **Persistence expectation drift.** With more windows parked, users may expect
  them to survive restart even though the feature is transient by design.
  **Mitigation:** decision #5 keeps it transient for this plan; revisit as a
  follow-up product question, not a code risk.

## Follow-ups (out of scope)

- **Backlog #8** and **#22** — the sequencing predecessors; tracked separately
  in `planned/20260621-backlog-brainstorm.md`.
- **Persistence policy** for scratchpad assignments across restart (currently
  transient — `RestorePlanner` only references `isScratchpadHidden` to skip
  rescue, `:78, 339`).
- **Slot-count cap / overflow behavior** — what `assign` does when a fixed pool
  is full (evict oldest, reject, prompt). This plan uses an unbounded array;
  a cap is a later product decision.
- **Static/app-rule scratchpads** (discovery option C) as a future layer on top
  of option A — config-driven by `app-id`/`title`.
- **Per-window `scratchpadSlot` IPC field + `--scratchpad-slot N` selector**
  (open question #5 in the discovery) — fold into Phase 4 or a follow-up.
