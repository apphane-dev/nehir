# Fix target window for commands like toggle floating / scratchpad, etc.

Source: handwritten backlog list captured 2026-06-21, idea **#8** — *"Fix target
window for commands like toggle floating / scratchpad, etc."* Triage doc for
that idea. See `planned/20260621-backlog-brainstorm.md` for the full raw list.

All source/line references were verified against the main Nehir source tree at
`56573ba2` ("Fix focus-follows-mouse blocked by click-through overlays (#64)")
on 2026-06-21. Re-verify before implementing; line numbers drift.

This is a discovery document. No source was modified.

---

## TL;DR

- Nehir does not have one "focused window"; it has **three independent target
  notions** that different command families read from, and they disagree
  whenever a floating window is focused. The split is intentional and is
  documented in `docs/ARCHITECTURE.md`, but the command layer is not consistent
  about which notion it consults.
- **Layout commands** (`move left/right/up/down`, `focusNeighbor`, `toggleFullscreen`,
  `cycleSize`, `setColumnWidth`, `consumeOrExpelWindow`, column moves…) resolve
  their target from the **Niri viewport selection** (`ViewportState.selectedNodeId`),
  which can only ever point at a **tiled** node — floating windows are not in the
  Niri tree. They never consult keyboard focus.
- **"Focused-window" commands** (`toggleFocusedWindowFloating`,
  `assignFocusedWindowToScratchpad`, native-fullscreen toggle, IPC
  `moveFocusedWindow`/`moveColumnToWorkspace`) resolve through
  `managedCommandTarget()`, a cascade that **prefers floating windows** over the
  viewport selection. This cascade was added on purpose by commit `e5188e42`
  ("Fix focused-window commands to prioritize floating windows over tiled
  windows", fixing #12) and is now test-locked.
- The user-visible symptom is an **asymmetry**: with a floating window focused,
  "toggle floating" acts on the floating window while "move left" / "set column
  width" silently act on the tiled window underneath. Worse, the cascade's
  frontmost-floating branch can resolve to a window that is not Nehir's confirmed
  managed focus, so a command named `…FocusedWindow…` can target a window the
  user does not perceive as focused.
- **Recommendation: pursue, but as a semantics clarification + targeted guards,
  not a resolver rewrite.** Define one `commandTarget()` policy, make the named
  "focused-window" commands respect it strictly, and document (or selectively
  fix) the layout-command exception. Do NOT silently make layout commands honor
  floating focus — that trades one surprise for another. Details and open
  decisions below.

---

## Prior work (do not duplicate)

Checked `discovery/`, `planned/`, `completed/`, `noop/`. Related, but **not**
this idea:

- `planned/20260621-backlog-brainstorm.md` **#8** — this idea (canonical
  source). **#7** (*"Multiple scratchpad window assignments"*) is a sibling that
  overlaps on scratchpad target semantics; the two should be co-triaged but are
  not the same bug (this one is about *which* window a command hits; #7 is about
  *how many* windows the scratchpad can hold).
- `discovery/20260621-workspace-number-modifier-click-move-window.md` —
  explicitly defers the "window-icon sub-buttons / target window" question to
  this idea (its "Scratchpad pill / window icons" risk note names backlog #8).
  Same command-target seam; different trigger surface.
- `discovery/20260613-codebase-review-findings.md` finding **#5** — the
  `WindowVisibility` enum refactor (done, PR #41). Relevant because
  `entry.mode` (`.tiling` / `.floating`) is what the target cascade branches on,
  and the visibility/mode model is now cleaner than when that note was written.
- Commit **`e5188e42`** "Fix focused-window commands to prioritize floating
  windows over tiled windows" (2026-06-08) + changeset
  `20260608185612-fix-focused-window-commands-targeting-tiled-wind.md`
  ("Fixes #12"). This is the change that introduced the floating-preference
  cascade in `managedCommandTarget()`. It also rerouted
  `moveFocusedWindow`/`moveColumnToWorkspace`/`moveColumnToAdjacentWorkspace`
  from raw `confirmedManagedFocusToken` onto `managedCommandTargetToken()` /
  `managedLayoutCommandTargetToken()`, and added the IPC-CLI note
  (`docs/IPC-CLI.md`): *"When a managed floating window has keyboard focus,
  focused-window commands target that floating window even if the Niri viewport
  selection still points at a tiled window underneath it."* Any fix here has to
  preserve or explicitly revise that contract.
- `discovery/20260621-command-palette-fallback-all-sources.md` — unrelated
  (palette source search); cited only because it mentions "float"/"scratchpad"
  as command names. Not a target-window issue.

Nothing in the repo today implements a single unified command-target policy that
both layout and focused-window commands consult — that gap is the substance of
this idea.

---

## What the idea means for Nehir

The user expectation is simple and reasonable: **a command that says it acts on
"the focused window" should act on the window Nehir is drawing the focus border
on.** Today that is not reliably true, because the focus border follows
`confirmedManagedFocusToken` (which can be a floating window) while large parts
of the command surface follow the Niri viewport selection (which can only be a
tiled window). The idea is to make the target window well-defined and consistent
across the command families a user thinks of together — toggling floating,
assigning/toggling scratchpad, moving, resizing, fullscreening.

Scope boundary: this is **not** "make floating windows participate in the Niri
column tree." Floating windows are free-form by design; `moveWindow(.left)` is
meaningful only for a tiled node. The honest framing is: *when the focused
window is floating, decide deliberately what each command does* (act on the
floating window, act on the tiled selection, or no-op with feedback), instead of
today's mix where some commands grab the floating window and others silently
fall through to the tiled selection underneath.

---

## Current behavior (with source citations)

### The three target notions

`docs/ARCHITECTURE.md` ("Focus management", ~line 566) documents the split
intentionally:

- **Command/border target** — `WMCommandTarget` and `currentBorderTarget()`.
- **Confirmed managed focus** — `confirmedManagedFocusToken`
  (`WorkspaceManager.swift:1059`, backed by `sessionState.focus.focusedToken`).
- **Interaction workspace/monitor** — `interactionWorkspace()`.

`WMCommandTarget.Source` (`Sources/Nehir/Core/Controller/WMCommandTarget.swift:9-13`)
enumerates exactly three origins:

```swift
enum Source: Equatable {
    case layoutSelection
    case confirmedManagedFocus
    case frontmostManagedFallback
}
```

### Resolver A — `managedCommandTarget()` (the "focused-window" cascade)

`Sources/Nehir/Core/Controller/WMController.swift:1735-1791`. The cascade, in
order:

1. If `confirmedManagedFocusToken` resolves and its entry is **`.floating`** →
   return it (`.confirmedManagedFocus`).
2. Else if the OS frontmost managed window (via
   `frontmostFocusedWindowTokenProvider` / `axEventHandler.focusedWindowToken`)
   is **`.floating`** → return it (`.frontmostManagedFallback`).
3. Else if `layoutSelectionCommandTarget()` yields a viewport-selected node →
   return it (`.layoutSelection`).
4. Else `confirmedManagedFocusToken` (any mode) → `.confirmedManagedFocus`.
5. Else frontmost managed window (any mode) → `.frontmostManagedFallback`.

Note that steps (1) and (2) consult **two independent signals** — Nehir's
confirmed managed focus vs. the OS frontmost window — and both prefer floating.
They usually agree, but they are not the same source and can diverge (see
"Concrete defect" below).

Callers of this resolver (via `managedCommandTargetToken()` at
`WMController.swift:1792`, or the private alias `focusedManagedTokenForCommand()`
at `WMController.swift:1800`):

- `toggleFocusedWindowFloating()` — `WMController.swift:3531`
- `assignFocusedWindowToScratchpad()` — `WMController.swift:3551`
- `toggleNativeFullscreenForFocused()` — `CommandHandler.swift:251`
- IPC `moveFocusedWindow(using:)` — `IPCCommandRouter.swift:311`
- IPC `moveColumnToWorkspace` / `moveColumnToAdjacentWorkspace` (these two were
  rerouted to `managedLayoutCommandTargetToken()` by `e5188e42`, which first
  tries `layoutSelectionCommandTarget()` then falls back to
  `managedCommandTargetToken()` — `WMController.swift:1796-1798`).

### Resolver B — the Niri viewport selection (the layout-command path)

`Sources/Nehir/Core/Controller/NiriLayoutHandler.swift`. Every layout command
goes through `withNiriWorkspaceContext` or `withNiriOperationContext`
(`NiriLayoutHandler.swift:2041`), both of which resolve the target node purely
from `state.selectedNodeId`:

```swift
// NiriLayoutHandler.swift:2041-2047
func withNiriOperationContext(...) {
    ...
    controller.workspaceManager.withNiriViewportState(for: wsId) { state in
        guard let currentId = state.selectedNodeId,
              let currentNode = engine.findNode(by: currentId),
              let windowNode = currentNode as? NiriWindow
        else { return }
        ...
```

Because floating windows are **not** Niri tree nodes, `selectedNodeId` can never
point at one. Commands resolved this way include: `focusNeighbor`
(`:1222`), `focusPrevious` (`:1336`), `moveWindow` (`:2085`), `moveColumn`
(`:2123`), `toggleFullscreen` (`:1557`), `cycleSize` (`:1572`), `setColumnWidth`
(`:1739`), `consumeOrExpelWindow`, `expelWindowFromColumn`, `consumeWindowIntoColumn`,
and all column/sizing variants. The `LayoutCoordinator` protocol
(`Sources/Nehir/Core/Controller/LayoutCoordinator.swift:21-69`) is the seam;
`extension NiriLayoutHandler: LayoutCoordinator {}` conforms for free.

### Resolver C — automation/IPC fallback

`focusedOrFrontmostWindowTokenForAutomation(preferFrontmostWhenNonManagedFocusActive:)`
(`WMController.swift:1699-1712`) — used by `WindowActionHandler` (e.g.
`:302`). Yet a third blend: confirmed focus unless non-managed focus is active
and the frontmost is preferred. Not directly in the toggle-floating/scratchpad
path, but it is a third place where "the focused window" is computed
differently.

### Scratchpad: two different target notions in one feature

- `assignFocusedWindowToScratchpad()` (`WMController.swift:3551`) resolves its
  target through **Resolver A** (`focusedManagedTokenForCommand()`).
- `toggleScratchpadWindow()` (`WMController.swift:3637`) resolves its target
  through **neither** — it reads `workspaceManager.scratchpadToken()`, the
  stored scratchpad window, entirely independent of focus
  (`WMController.swift:3639`). Showing/hiding then routes through
  `scratchpadTarget(on:)` (`WMController.swift:1868`), which picks a workspace
  + monitor from `monitorForInteraction()`, not from focus.

So "the scratchpad window" is a fourth, stored notion of target that does not
track focus at all. (This is the seam backlog #7 would also reshape.)

---

## Concrete defect (the asymmetry, inlined and reproducible)

This needs no captured log — it falls directly out of the resolvers above and is
asserted by an existing test.

**Topology / initial state**

- Single monitor, single workspace `"1"`, Niri layout enabled
  (`controller.enableNiriLayout()`).
- Two managed windows on workspace 1:
  - Tiled terminal `T` (`tiledToken`, added via `addLayoutPlanTestWindow`).
  - Floating notes window `F` (`floatingToken`), floated via
    `controller.transitionWindowMode(for: floatingToken, to: .floating, ...)`.
- `F` is given keyboard focus:
  `controller.workspaceManager.setManagedFocus(floatingToken, in: workspaceId, ...)`,
  so `confirmedManagedFocusToken == F`. The Niri viewport
  `selectedNodeId` still resolves to `T`'s node — floating windows are not
  Niri nodes, so the selection cannot point at `F`.

**Observed resolver outputs in this state**

- `managedCommandTarget()?.token == F` (source `.confirmedManagedFocus`).
  This is exactly the assertion in
  `Tests/NehirTests/IPCCommandRouterTests.swift:629-647`
  (`toggleFocusedWindowFloatingTargetsFocusedFloatingWindowOverNiriSelection`):

  ```swift
  _ = controller.workspaceManager.setManagedFocus(floatingToken, in: workspaceId, onMonitor: monitor.id)
  #expect(controller.managedCommandTarget()?.token == floatingToken)
  #expect(router.handle(.toggleFocusedWindowFloating) == .executed)
  #expect(controller.workspaceManager.entry(for: floatingToken)?.mode == .tiling) // F was un-floated
  #expect(controller.workspaceManager.entry(for: tiledToken)?.mode == .tiling)    // T untouched
  ```

- The layout-command path reads `state.selectedNodeId == T` (the only node),
  so `moveWindow(.left)`, `toggleFullscreen()`, `cycleSize`,
  `setColumnWidth(...)`, `consumeOrExpelWindow(...)` all operate on **T**.

**Consequence.** With `F` visually focused (border on `F`, keyboard in `F`):

- `toggle floating` → acts on `F` (un-floats it) — matches current intent.
- `move left` / `set column width` / `toggle fullscreen` → silently act on `T`
  underneath.

The same focused state yields different command targets depending on which key
the user presses. From the user's seat this reads as "toggle floating works on
the focused window, but move/resize/fullscreen work on some other window" —
i.e. the target window is broken for the latter group.

### Secondary structural risk (frontmost-floating ≠ confirmed focus)

Even within Resolver A, steps (1) and (2) are different signals. There exist
states where Nehir's `confirmedManagedFocusToken` is tiled `T` (border on `T`)
but the OS frontmost managed window is a floating `F` (e.g. a floating panel
that became AX-focused without Nehir confirming it, or focus bookkeeping lagging
behind an activation). In that state `managedCommandTarget()` returns `F` from
step (2), so `toggleFocusedWindowFloating` un-floats `F` even though the focus
border is on `T`. This is the literal "command named `…FocusedWindow…` targets a
window that is not the focused one" case. It is rarer than the asymmetry above
and harder to reproduce without a live trace, but it is a direct consequence of
the two-signal cascade and is worth closing as part of this work.

---

## Where / how it would be implemented

Primary site: **`Sources/Nehir/Core/Controller/WMController.swift`**, the
`managedCommandTarget()` / `managedCommandTargetToken()` /
`managedLayoutCommandTargetToken()` / `focusedManagedTokenForCommand()` cluster
(`:1735-1801`). These are the single chokepoint for the focused-window command
families; any policy change lands here.

Secondary sites, depending on the chosen semantics (see Open questions):

- `Sources/Nehir/Core/Controller/NiriLayoutHandler.swift` —
  `withNiriOperationContext` / `withNiriWorkspaceContext` (`:2041`, `:2260`,
  `:2283`) and the individual command methods (`focusNeighbor :1222`,
  `moveWindow :2085`, `toggleFullscreen :1557`, `cycleSize :1572`,
  `setColumnWidth :1739`, …). If layout commands are made focus-aware, this is
  where a "focused window is floating → no-op / feedback" guard would live, just
  before the `guard let currentId = state.selectedNodeId` reads.
- `Sources/Nehir/Core/Controller/CommandHandler.swift` — the toggle cases
  (`:188-192`) and `toggleNativeFullscreenForFocused` (`:248-251`). Today these
  reach for `managedCommandTargetToken()` directly; a unified policy would be
  invoked here.
- `Sources/Nehir/IPC/IPCCommandRouter.swift` — `moveFocusedWindow` (`:311`),
  `toggleFocusedWindowFloating` (`:368`), `assignFocusedWindowToScratchpad`
  (`:372`), `toggleScratchpad` (`:376`). These mostly delegate to
  `CommandHandler`, so they inherit any policy change for free; the
  `moveFocusedWindow` token capture (`:311`) is the one IPC-specific spot that
  reads the target directly.
- `Sources/Nehir/Core/Controller/WMCommandTarget.swift` — `Source` enum. Likely
  gains a documented policy doc-comment, and possibly a `.focusedFloating`
  distinction if the maintainer wants observability.

Tests to update / add: `Tests/NehirTests/IPCCommandRouterTests.swift`
(`toggleFocusedWindowFloatingTargetsFocusedFloatingWindowOverNiriSelection :629`,
`moveFocusedWindowTracksFrontmostFloatingCommandTarget :657`,
`toggleFocusedWindowFloatingReturnsControllerCommandResult :610`) and
`Tests/NehirTests/WMControllerFocusTests.swift`,
`Tests/NehirTests/WMControllerScratchpadTests.swift`. Any change to the cascade
ordering will require `toggleFocusedWindowFloatingTargetsFocusedFloatingWindowOverNiriSelection`
to be revised or paired with a new test asserting the new policy.

---

## Risks and unknowns

- **High blast radius.** `managedCommandTargetToken()` is the target resolver
  for native-fullscreen, IPC move-window/move-column, scratchpad assign, and
  toggle-floating. Changing its ordering affects all of them simultaneously.
  `e5188e42` was itself a fix for a real bug (#12); naively reverting the
  floating preference regresses that. Any change must keep the #12 scenario
  (focused floating window should be the target of move-to-workspace etc.)
  working, which means the policy must still prefer the confirmed floating
  focus — what changes is the *frontmost-floating* branch and the relationship
  to layout commands.
- **Layout commands genuinely cannot target a free-floating window.**
  `moveWindow(.left)`, `setColumnWidth`, `consumeOrExpelWindow` are column/tree
  operations. Making them "honor floating focus" cannot mean acting on the
  floating window; it can only mean (a) no-op + user feedback, or (b) redirect
  to the tiled viewport selection as today but *visibly*. The choice is a UX
  decision, not a mechanical one.
- **`selectedNodeId` is also the scroll/viewport anchor.** It doubles as the
  thing reveal/scroll logic keeps stable during gestures (ARCHITECTURE.md ~line
  526). Coupling layout-command target resolution more tightly to focus must
  not destabilize gesture-time selection pinning.
- **Scratchpad target is a fourth notion** (`scratchpadToken()`). Any "fix target
  window" story that touches scratchpad has to decide whether
  `toggleScratchpadWindow` should become focus-relative (it is not today) or stay
  stored-token. That overlaps with backlog #7 and should be decided together
  with #7 rather than unilaterally here.
- **FFM / focus-lease / non-managed-focus interactions.** When
  `isNonManagedFocusActive` is true (an unmanaged app has focus), Resolvers A
  and C already branch (`focusedOrFrontmostWindowTokenForAutomation` takes a
  `preferFrontmostWhenNonManagedFocusActive` flag). A unified policy must take a
  position on the non-managed-focus case for the toggle/scratchpad commands too;
  today they just return `.notFound` via the cascade's fallbacks, which is
  probably correct but should be made explicit.
- **Unknown: what did the reporter actually observe?** The backlog line is terse
  ("Fix target window for commands like toggle floating / scratchpad, etc.").
  The strongest defensible interpretation is the asymmetry above; the
  frontmost-floating divergence is a plausible secondary report. Confirm with
  the reporter before over-investing in the secondary case.

---

## Open questions for the maintainer

1. **Single policy or two documented ones?** Should there be one
   `commandTarget()` consulted by *all* command families (with layout commands
   then deciding "floating → no-op"), or should the split stay but be made
   consistent and documented? Recommend: one policy function, two documented
   behaviors — cleanest mental model and one place to audit.
2. **When focus is on a floating window, what should layout commands do?**
   Options: (a) no-op silently (status quo for the underlying mechanics, but
   make it intentional); (b) no-op with a visible affordance / border flash; (c)
   auto-redirect to the tiled viewport selection as today but only when the user
   explicitly focuses a tiled window. Recommend (a) + documentation; (b) if user
   feedback says silent no-op is confusing.
3. **Frontmost-floating branch.** Should `managedCommandTarget()` step (2)
   (frontmost-floating when confirmed focus is tiled) be dropped, so the command
   target always equals confirmed managed focus (falling back to layout
   selection / frontmost only when there is no confirmed managed focus)?
   Recommend yes — it removes the "named `…FocusedWindow…` targets a
   non-focused window" case and aligns the resolver with its name.
4. **Scratchpad toggle.** Should `toggleScratchpadWindow` remain stored-token
   (decoupled from focus) or become focus-aware? Decide jointly with backlog #7.
5. **Naming.** `focusedManagedTokenForCommand()` is a private alias for
   `managedCommandTargetToken()`. If the policy is unified, collapse the alias
   and rename to reflect the chosen semantics, so the code reads as one concept.

---

## Recommendation

**Pursue, scoped tightly.** This is a real, source-grounded consistency defect
(not a nice-to-have), but the fix is a policy clarification plus a couple of
guards, not a resolver rewrite.

Concrete plan, in order:

1. **Define one `commandTarget()` policy** in `WMController` that returns a
   `WMCommandTarget` with a documented source, and make
   `toggleFocusedWindowFloating`, `assignFocusedWindowToScratchpad`, and
   `toggleNativeFullscreenForFocused` consult it. Collapse
   `focusedManagedTokenForCommand()` into the public policy name.
2. **Drop the frontmost-floating branch** (step 2 of the current cascade) so the
   command target is always either confirmed managed focus or, when none, the
   layout selection / frontmost fallback. This removes the
   "targets-a-non-focused-window" case and is the single highest-value change.
   Pair it with a regression test that mirrors
   `toggleFocusedWindowFloatingTargetsFocusedFloatingWindowOverNiriSelection`
   but asserts the inverse (confirmed tiled focus + a different frontmost
   floating window → target is the tiled focus, not the floating one).
3. **Document the layout-command exception** (floating focused → those commands
   act on the tiled selection / no-op) in `docs/ARCHITECTURE.md` next to the
   existing focus-target section, and optionally add a guard in
   `withNiriOperationContext`/`withNiriWorkspaceContext` that makes the no-op
   intentional and observable rather than silent.
4. **Defer the scratchpad-toggle-focus question** to backlog #7; this idea
   should only ensure `assignFocusedWindowToScratchpad` uses the unified policy
   from step 1.

**Do not** pursue: making floating windows participate in the Niri tree, or
silently rerouting all layout commands onto floating focus. Both trade the
current asymmetry for a different surprise and are out of scope for "fix target
window."

**Effort / risk:** small to medium. The policy function and the branch removal
are ~50-100 lines plus tests; the risk is regression in the #12 scenario, which
is covered by an existing test and is easy to guard. The layout-command guard is
the part most likely to surface follow-up UX decisions, so timebox it.
