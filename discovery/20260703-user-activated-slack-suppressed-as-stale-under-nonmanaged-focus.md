# Discovery: unmanaged-focused window can never be admitted — non-managed focus suppresses its own admission

Status: resolved — runtime evidence and source mechanism both fully confirmed
across five captures; the admission pipeline is working exactly as coded. The
fix has one design decision (which user-intent signal should exempt the
admission), captured under "Fix options" below. **Fix option A landed** on
branch `fix/nonmanaged-admission-exemption` in commit `fc4d11aa` (plus the
trace fix from C); see
`completed/20260703-fix-unrequested-admission-guard-user-activation-exemption.md`.

Validated against the main Nehir source tree on 2026-07-03 at commit `8286c192`
("Show other displays in the workspace bar"), the build that produced the
capture.

## Summary

A runtime trace captured on 2026-07-03 between `11:14:37Z` and `11:14:43Z`
shows the user activating Slack (via the SuperCmd launcher) while the runtime
was in **non-managed focus**. Nehir *decided* to manage the Slack window —
`window_decision … disposition=managed source=heuristic outcome=trackedTiling`
— and even resolved its placement to the active workspace, but then the
unrequested-admission guard vetoed tracking:

```text
unrequested_admission_nonmanaged_focus_decision token=WindowToken(pid: 8662, windowId: 8983)
  suppressed=true reason=stale_unrequested_nonmanaged_focus
  context_source=ax_focused_admission_synthesized recent_pid_workspace=nil
  explicit_workspace_assignment=false active_managed_request_token=nil
```

The window was never inserted into the niri layout (the insertion trace is
empty for the whole capture) and at capture end Slack sits in
**"Visible Unmanaged WindowServer Windows"**, floating at its old frame
`(102, 78, 847, 1251)` on top of the tiled column layout. From the user's point
of view: "I opened Slack but it wasn't put into the layout".

The root cause is that the guard treats a *user-initiated app activation of a
pre-existing window* the same as a *random stale surface discovered during
non-managed focus*. The user-intent signal is present in the event stream
(`activation_source_observed pid=8662 source=workspaceDidActivateApplication`
arrives moments earlier) but nothing records it in a form the suppression
predicate can consult.

Worse, the state is **self-perpetuating**: once the untracked window has
focus, every activation of it enters `non_managed_fallback_entered pid=8662`,
which keeps `isNonManagedFocusActive` true, which suppresses the window's own
admission on the next attempt. Follow-up captures on the same day confirm the
window can never escape, regardless of how it is activated:

- Slack via SuperCmd → 2 × `focused_admission` decisions, 2 × suppressed
  (`stale_unrequested_nonmanaged_focus`), not tiled.
- Slack via Raycast → 5 × decisions, 5 × suppressed, not tiled.
- Slack via the Dock → 8 × decisions, 8 × suppressed, not tiled.
- In the same period, opening an *already-managed* Telegram window worked
  normally (it takes the restored-entry activation path, which does not go
  through the unrequested-admission guard), and brand-new Helium windows were
  tracked via their CGS create events — so "usually activation from a launcher
  has no issue" is exactly what the guard's exemptions predict.
- Quit Slack, relaunch via SuperCmd → the new instance (pid 33189,
  windowId 25368) was admitted (`candidate_tracked`, `window_admitted …
  mode=tiling context=focused_admission`) and tiled as a new column.

An independent capture from 2026-07-02 (two-monitor topology: built-in
display 1 plus external display 3) shows the same trap with **Microsoft Teams**
(bundleId `com.microsoft.teams2`, pid 42984, windowId 19419). Teams starts the
capture listed under Visible Unmanaged WindowServer Windows while non-managed
focus is active (held by a floating Ghostty window and its sheet). Activating
Teams produced the identical pair of records twice —
`window_decision … disposition=managed outcome=trackedTiling` followed by
`unrequested_admission_nonmanaged_focus_decision suppressed=true
reason=stale_unrequested_nonmanaged_focus
context_source=ax_focused_admission_synthesized recent_pid_workspace=nil` —
and Teams stayed floating. The user then **dragged the window to the external
display**, which made the window server re-report the window on its new native
space: the trace shows `create_seen window=19419` with a real
`context_source=cgs_created` placement
(`native_monitor=Optional(Nehir.Monitor.ID(displayId: 3))`), which qualifies
for the guard's `cgs_created_context` exemption → `candidate_tracked … 
workspace=98192F7C-4EF5-4033-B9EB-DFDABBE114E2`, `window_admitted …
mode=tiling context=window_create`, and `focus_confirmed` on the Teams token.
So "move it to the other display" works for the same reason quit-and-relaunch
works: both manufacture a CGS create event, the one intent signal the guard
already accepts. Same bug, third app-independent confirmation, and a second
known workaround.

The relaunch capture pins the differentiator precisely: the new window was
admitted through the **same** `focused_admission` path with the **same**
`context_source=ax_focused_admission_synthesized` and the same
`recent_pid_workspace=nil` that were suppressed before. The only changed input
is that quitting Slack let focus fall back to a managed window first
(`focus_confirmed token=WindowToken(pid: 94498, windowId: 22998)
source=workspaceDidActivateApplication` — Telegram — appears immediately
before the new Slack decision), so `isNonManagedFocusActive` was false and the
guard never ran. It is not launcher-specific, not a CGS-create effect, and not
window-specific — it is purely the sticky non-managed-focus state.

## Topology and startup state

- Single monitor: Built-in Retina Display, frame `(0, 0, 2056, 1329)`, notch.
- One visible workspace `68B2A8F3-4FE0-4588-BBBB-E1E7D14BB9AD` with three
  managed tiled windows: Helium (windowId 23176), VS Code Insiders (24553),
  Telegram (22998). `windows total=3 tiled=3 floating=0`.
- Focus at capture start is already non-managed: `nonManaged=true`,
  `observedManagedFocus=nil`. Two non-managed overlays are flapping focus
  throughout the capture:
  - the Ghostty quick-terminal overlay (pid 34712, windowId 23369,
    `disposition=unmanaged source=builtInRule(ghosttyQuickTerminalOverlay)
    outcome=ignored`), repeatedly re-evaluated while sliding in/out
    (wsFrame y animating from −864 toward 0), and
  - the SuperCmd launcher palette (pid 5925, windowId 24780, wsLevel=3,
    `disposition=floating source=builtInRule(transientWindowServerSurface)
    outcome=trackedFloating`).
- Slack (pid 8662, bundleId `com.tinyspeck.slackmacgap`) is running with one
  pre-existing standard window (windowId 8983) that is **not managed** — it is
  not among the three managed windows and has no CGS create event in the
  capture (the window predates it).

## Evidence: the activation sequence (11:14:38Z)

Event order for the Slack activation (values quoted from the create-focus
trace):

1. `activation_source_observed pid=8662 source=workspaceDidActivateApplication`
   — the user-level app switch (SuperCmd launched/activated Slack). It is
   immediately followed by `non_managed_fallback_entered pid=8662` — no
   admission was attempted from this event.
2. `activation_source_observed pid=5925 source=focusedWindowChanged` — the
   SuperCmd palette briefly re-takes AX focus (it is still on screen), gets its
   usual `trackedFloating` decision, and its own admission is suppressed with
   the same `stale_unrequested_nonmanaged_focus` reason. Non-managed focus
   therefore remains active.
3. `activation_source_observed pid=8662 source=focusedWindowChanged` →
   `non_managed_fallback_entered pid=8662` — a second Slack activation event
   that also did not admit (candidate preparation did not complete on this
   pass).
4. `activation_source_observed pid=8662 source=focusedWindowChanged` — third
   event; this time the focused-admission path runs to completion:

```text
window_decision token=WindowToken(pid: 8662, windowId: 8983) context=focused_admission
  existingMode=nil disposition=managed source=heuristic outcome=trackedTiling
  layout=fallbackLayout bundleId=com.tinyspeck.slackmacgap axRole=AXWindow
  axSubrole=AXStandardWindow wsLevel=0 wsFrame=(102.0,78.0,847.0,1251.0)
create_placement_resolved token=WindowToken(pid: 8662, windowId: 8983)
  workspace=68B2A8F3-4FE0-4588-BBBB-E1E7D14BB9AD
  context_source=ax_focused_admission_synthesized focused_workspace_source=nil
  recent_pid_workspace=nil
unrequested_admission_nonmanaged_focus_decision token=WindowToken(pid: 8662, windowId: 8983)
  suppressed=true reason=stale_unrequested_nonmanaged_focus
  context_source=ax_focused_admission_synthesized recent_pid_workspace=nil
  explicit_workspace_assignment=false active_managed_request_token=nil
```

5. The AX notification trace then shows the SuperCmd palette closing —
   `AXUIElementDestroyed pid=5925 window=24780` at `11:14:39Z` — consistent
   with a launcher that dismisses itself right after launching the target app.

No further admission attempt for windowId 8983 occurs. The capture's niri
insertion trace is empty (`insertion trace empty`,
`insertionTraceRecords=0` in both runtime-state snapshots).

## Evidence: end state

At capture end the managed set is unchanged (Helium, VS Code, Telegram — same
three tokens, same workspace) and Slack is explicitly reported as unmanaged:

```text
-- Visible Unmanaged WindowServer Windows --
windowId=8983 pid=8662 owner=Slack bundleId=com.tinyspeck.slackmacgap
  title=rcs-horizon-notifications (Channel) - Workhuman - Slack
  frame={{102.0, 78.0}, {847.0, 1251.0}} axWindowsCount=1 axContainsWindow=true
```

So the window is healthy and fully AX-resolvable — it was simply never
tracked.

## Source mechanism (all cites against `8286c192`)

1. **Admission attempt.** The activation path calls
   `admitFocusedWindowBeforeNonManagedFallback`
   (`Sources/Nehir/Core/Controller/AXEventHandler.swift:2132`, body at
   `:2207`). `prepareCreateCandidate(… traceContext: "focused_admission")`
   succeeds and produces the `trackedTiling` decision seen in the trace.

2. **Synthesized placement context.** Because there was no CGS create event
   (pre-existing window), `ensureCreatePlacementContextForFocusedAdmission`
   (`AXEventHandler.swift:4374`) synthesizes a context with
   `source="ax_focused_admission_synthesized"` and
   `recentPidWorkspaceId = recentManagedWorkspaceId(for: pid)`
   (`AXEventHandler.swift:3914`). That lookup is nil here: Slack had never
   been managed in this session, and the map is TTL-pruned
   (`recentManagedAdmissionTTL`) anyway.

3. **The veto.** `shouldSuppressUnrequestedAdmissionDuringNonManagedFocus`
   (`AXEventHandler.swift:721`) suppresses when **all** of these hold, which
   they did:
   - `workspaceManager.isNonManagedFocusActive` — true, because the SuperCmd
     palette / quick-terminal overlays had just re-entered non-managed focus;
   - no explicit workspace assignment (window rule) for the window;
   - the token does not match an active managed focus request;
   - `createPlacementContext.source != "cgs_created"`;
   - `createPlacementContext.recentPidWorkspaceId == nil`.

   On suppression the caller discards the placement context and returns
   *before* `trackPreparedCreate(candidate, admissionContext: .focusedAdmission)`
   (`AXEventHandler.swift:2264`) — the window is never tracked, never inserted,
   and no retry is scheduled.

4. **The missing signal.** The guard's own comment
   (`AXEventHandler.swift:756-762`) says a real CGS create or a recent managed
   workspace for the pid marks intent, and that admitting other surfaces
   "pulls random apps into the active workspace". But a third intent signal —
   the `workspaceDidActivateApplication` event observed for the *same pid*
   one second earlier (`activation_source_observed`, emitted at
   `AXEventHandler.swift:207`) — is only traced, never stored. The predicate
   cannot distinguish "user just switched to this app" from "background app's
   window surfaced while an overlay had focus", so a deliberate app switch to
   any never-yet-managed app is dropped whenever a launcher/overlay holds
   non-managed focus — which is precisely when app switches via launchers
   happen.

5. **The trap closes.** After suppression the untracked window keeps AX focus,
   so the caller falls through to `enterNonManagedFocus` on subsequent events
   (`non_managed_fallback_entered`). The window's own focus is now what keeps
   `isNonManagedFocusActive` true, so condition (3) holds forever for that
   window: 15 consecutive suppressions across three activation routes in the
   follow-up captures, zero admissions. The state only clears when focus
   returns to a managed window (in the captures: quitting Slack handed focus
   back to Telegram), after which even the same synthesized-context admission
   path succeeds.

5. **Trace inconsistency (secondary).** `window_decision` logs
   `outcome=trackedTiling` even when tracking is subsequently vetoed; the only
   hint is the separate suppression record. Any tooling that reads decisions
   alone will believe the window was tiled.

## How the trap state arises (reproduction)

The trap needs two ingredients at the same moment:

1. **an existing window with no workspace entry** (so activation goes through
   the unrequested-admission guard instead of the restored-entry path), and
2. **`isNonManagedFocusActive == true`** (so the guard is armed).

Ingredient 2 is entered when the *focused* window is unmanaged or untracked:
the Ghostty quick-terminal overlay while it has keyboard focus
(`disposition=unmanaged outcome=ignored` → `non_managed_fallback_entered`),
or, once trapped, the stuck window itself. Note the asymmetry confirmed by a
2026-07-03 control run: the SuperCmd palette can *perpetuate* the armed state
(its own admission is suppressed with the same reason whenever non-managed
focus is already active) but cannot *start* it — from a clean
managed-focus state the palette is simply tracked floating and managed focus
stays confirmed. An open-but-unfocused overlay contributes nothing; the
overlay must hold focus at the moment the target window's
`focused_admission` runs.

Ingredient 1 — how a long-lived window ends up untracked — is constrained by
the captures: the Slack window kept the **same CGWindow id (8983) across both
days**, so the OS window was never destroyed; and it was *managed* in the
2026-07-02 capture but *unmanaged* from the first moment of the 2026-07-03
captures, whose runtime state shows a fresh Nehir session (different workspace
UUIDs, different monitor topology). So the entry was lost across a Nehir
restart: the new session's startup full rescan (`performFullRescan`,
`Sources/Nehir/Core/Controller/LayoutRefreshController.swift:1219`) enumerates
windows via `axManager.fullRescanEnumerationSnapshot()`, and a window that is
not AX-enumerable at that instant — minimized, app hidden (Cmd-H), Electron
window "closed" into its hidden state (Slack/Teams keep the window alive), or
sitting on an inactive native Space — is simply never admitted. It stays a
healthy visible-later window with no entry.

Reproduction steps for the current codebase — **confirmed working on
2026-07-03**: a run following exactly these steps produced the full signature
(`non_managed_fallback_entered` for the Ghostty pid ×3, two
`suppressed=true reason=stale_unrequested_nonmanaged_focus` records for the
Slack token, zero `candidate_tracked`, window listed under Visible Unmanaged
WindowServer Windows at capture end):

1. Ghostty setup (both parts matter): keep a **regular Ghostty terminal
   window open and tiled** — per-app AX contexts are created lazily
   (`Sources/Nehir/Core/Ax/AppAXContext.swift:187`), and the quick terminal
   is a non-activating overlay whose focus is invisible until the app has a
   context. Set `quick-terminal-autohide = false` for the run, so summoning
   another app does not destroy the QT surface — the destroy triggers
   window-close focus recovery, which focuses a managed window and disarms
   the guard mid-sequence.
2. Have the target app (Slack or any Electron app that hides its window on
   close) managed and tiled; Cmd-H it.
3. Restart Nehir so the startup rescan runs while the window is invisible —
   the new session has no entry for it.
4. Click the managed Ghostty tile once (guarantees the AX context in this
   session), then summon the quick terminal and type a character in it.
   **Checkpoint:** the trace must now show `activation_source_observed` +
   `non_managed_fallback_entered` for the Ghostty pid — if absent, the guard
   never armed and the run is invalid.
5. With the quick terminal still on screen, activate the target app from the
   Dock, touching nothing else in between.

Failed-run diagnostics (each variant was hit while deriving this recipe):
revealing while a managed window has confirmed focus tiles fine (guard
unarmed by design); revealing via the SuperCmd palette from a clean
managed-focus state never reproduces (the palette gets tracked floating and
cannot arm the guard); a run without a regular Ghostty window produces zero
Ghostty trace events (no AX context, QT focus invisible); and with QT
autohide on, `pending_focus_started`/`focus_confirmed` on a managed token
between the checkpoint and the target's decision means QT-close recovery
disarmed the guard.

Expected (buggy) result: `window_decision … outcome=trackedTiling` +
`unrequested_admission_nonmanaged_focus_decision suppressed=true
reason=stale_unrequested_nonmanaged_focus`, the window floats unmanaged, and
all further activations from any route keep failing until quit+relaunch, a
cross-display drag, or focusing a managed window before re-activating.

Ingredient 1 was confirmed experimentally on 2026-07-03: with Slack Cmd-H
hidden across a Nehir restart, the startup rescan admitted only the four
visible windows (`window_admitted … context=startup_full_rescan` for VS Code,
Helium, Telegram, and agterm) and skipped Slack entirely — the hidden window
entered the session untracked. In that control run the reveal happened while a
managed window held confirmed focus (`create_placement_resolved …
focused_workspace_source=confirmed_focus`), so the guard was unarmed and Slack
was admitted normally (`window_admitted … context=focused_admission`, no
`unrequested_admission…` record at all). That run demonstrates both that the
rescan gap is real and that ingredient 2 — non-managed focus at reveal time —
is the sole discriminator between "tiles fine" and "trapped forever".

Non-cause, ruled out: persisted state under `~/.local/state/nehir/`.
`runtime-state.json` holds only the window-restore catalog (per-bundle niri
placement intents for restore); the suppression predicate never reads it, and
in the captures it was healthy (it contains the relaunched Slack window that
tiled fine). The trap state is entirely in-memory
(`WorkspaceManager.isNonManagedFocusActive` plus the missing entry) and does
not survive a Nehir restart — which is consistent with restart being one of
the workarounds.

## Why this is not the same as prior findings

- `discovery/20260702-quick-terminal-close-reveals-managed-ghostty-column.md`
  concerns reveal behavior of *already managed* windows around the same
  quick-terminal overlay; this finding is about a window that never became
  managed at all.
- The suppression guard itself is intentional (its exemptions show it was
  designed to still admit real creates); this is a false positive of that
  guard for launcher-driven app switches, not a regression of it.

## Fix options

**A. Record app-activation intent and exempt it (recommended).**
When `activation_source_observed` fires with
`source=workspaceDidActivateApplication` for pid P, record `(pid, uptime)` in
a small TTL map (a few seconds, mirroring `recentManagedWorkspaceByPid`
mechanics at `AXEventHandler.swift:3906-3930`). In
`shouldSuppressUnrequestedAdmissionDuringNonManagedFocus`, add an exemption
before the final suppression: if the token's pid was recently user-activated,
return false with a new traced reason (e.g. `recent_app_activation`). This
admits exactly the launcher/cmd-tab/Dock switch case while still suppressing
surfaces of apps the user did not just activate. Risk: NSWorkspace also emits
`didActivateApplication` for programmatic activations; the short TTL plus the
existing other conditions (still requires an actual AX-focused standard window
that the heuristic wants to manage) keep the widened window narrow.

**B. Pair the exemption more strictly.**
Same as A, but only exempt when the suppressed admission's own event source is
`focusedWindowChanged` for that pid *and* a `workspaceDidActivateApplication`
for the same pid was observed since non-managed focus was last entered. This
is the tightest match for "user switched apps while an overlay had focus" but
adds ordering state; likely over-fit given the guard's other conditions.

**C. Make the trace non-contradicting (do regardless of A/B).**
When suppression vetoes a `trackedTiling` decision, reflect it in the decision
stream — either emit the `window_decision` with a `deferred=`/`suppressed=`
marker or emit a follow-up record keyed to the same token. Also consider
scheduling a re-evaluation when non-managed focus ends, so a suppressed
admission gets a second chance once a managed window regains focus. Note this
alone does **not** fix the sticky case: while the suppressed window itself
holds focus, non-managed focus never ends, so the re-evaluation would only
fire after the user manually switches away.

**Recommendation:** A (plus the trace fix from C). A directly breaks the
self-perpetuating loop in all four failing captures — every one of them starts
with a `workspaceDidActivateApplication` for the Slack pid moments before the
suppressed `focused_admission`. B and the re-evaluation half of C are
refinements that can ride along or be dropped.

## Validation sketch

1. Three tiled windows on one workspace; Slack (or any never-managed app with
   an existing standard window) running but untracked.
2. Open a non-managed overlay (SuperCmd palette or Ghostty quick terminal) so
   `isNonManagedFocusActive` is true, then activate the app through it.
3. Capture a runtime trace:
   - Before fix: `window_decision … outcome=trackedTiling` followed by
     `unrequested_admission_nonmanaged_focus_decision suppressed=true
     reason=stale_unrequested_nonmanaged_focus`, empty insertion trace, window
     listed under Visible Unmanaged WindowServer Windows at end.
   - After fix: suppression record shows the new exempt reason (or a
     re-admission fires when the overlay closes), the insertion trace shows
     the window entering a column, and the end-state Managed Windows list
     contains the token.
4. Repeat step 2 via Raycast and via the Dock — before the fix all three
   routes fail identically (the suppressed window's own focus keeps the guard
   armed); after the fix all three must admit.
5. Control: quit and relaunch the app — this already works today (focus falls
   back to a managed window before the fresh admission, so the guard is
   inactive) and must keep working.
6. Regression: while an overlay holds focus, a background app spawning a
   window *without* user activation must still be suppressed with
   `stale_unrequested_nonmanaged_focus`.
