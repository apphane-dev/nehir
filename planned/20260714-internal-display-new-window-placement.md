# Plan: preserve explicit workspace intent during multi-monitor new-window admission

**Discovery:** [`../discovery/20260714-internal-display-new-window-placement.md`](../discovery/20260714-internal-display-new-window-placement.md).

**Status:** implementation plan only. The available post-WIP capture does not reproduce the reported external landing, so runtime evidence and explicit user confirmation are mandatory. Do not claim the fix works before the user confirms the real internal-display repro.

## Goal

Give a recent, explicit user workspace activation a narrow new-window placement affinity so an AX-first admission cannot reinterpret that intent using stale same-pid focus, cursor, or initial-frame signals. Preserve stronger affinities and avoid making the cursor win ordinary keyboard-created windows.

## Files to touch

- `Sources/Nehir/Core/Controller/WorkspaceNavigationHandler.swift` — record explicit user workspace activation at the user-action boundary.
- `Sources/Nehir/Core/Controller/WMController.swift` — own the short-lived activation affinity, apply its authority ordering, and emit placement winner/rejection diagnostics.
- `Sources/Nehir/Core/Controller/AXEventHandler.swift` — snapshot affinity/provenance into `WindowCreatePlacementContext` for both CGS-first and AX-first admission; extend create-focus tracing.

### Hard do-not-touch fences

- **Do not add, change, move, or delete anything under `Tests/`.** The user has not confirmed a working fix. Tests are explicitly out of scope.
- Do not edit `Sources/Nehir/Core/Monitor/Monitor.swift`; strict cursor containment from `3056bee8` remains unchanged.
- Do not edit changesets in this runtime-validation spike. Add one only after user confirmation, in a follow-up.
- Do not bypass or weaken explicit move/rule assignment, tracked-parent inheritance, a confirmed structural replacement, active managed focus request, or native-Space placement.
- Do not revive `ccb50dc4`'s `hasNonManagedFocusContext` + `staleManagedFocusCursorPlacementTarget` predicate. In particular, do not override `structuralReplacementWorkspaceId` from cursor/non-managed-focus disagreement.
- Do not make `cursorMonitorId` globally authoritative or move the existing cursor fallback ahead of managed focus/native Space. The successful external-display sequence proves that display-2 managed focus must beat a display-1 cursor.
- Do not fold unrelated quick-terminal close/reveal or replacement-correlation work into this change.

## Authority contract

The implementation must document and trace this order for a new window:

1. existing managed entry;
2. explicit move target and explicit configured workspace rule;
3. tracked parent;
4. **confirmed real structural replacement**;
5. active managed focus request;
6. native Space;
7. recent explicit workspace activation (new affinity), only while still valid;
8. confirmed managed focus / recent-pid fallback;
9. contained on-screen frame, interaction, cursor, and ordinary fallbacks under the existing `3056bee8` policy.

If preserving the exact existing structural-before-parent order is required for compatibility, retain it; both stay above the new affinity. The key invariant is that the new affinity is never allowed to displace items 1-6 or an explicit rule.

“Recent explicit workspace activation” means an event emitted by a user-facing Nehir workspace navigation action, not every internal call to `WorkspaceManager.setActiveWorkspace`. Reconciliation, restore, topology repair, focus-follow activation, and `activeWorkspaceOrFirst` must not arm it.

## Step 1 — add decision-complete observability before changing behavior

### `WorkspaceNavigationHandler.swift`

At each user-facing workspace switch after `WorkspaceManager.setActiveWorkspace(...)` succeeds and before the transition commit, call one WMController API such as:

```swift
recordExplicitWorkspacePlacementIntent(
    workspaceId: targetWorkspaceId,
    monitorId: targetMonitor.id,
    source: <stable action name>
)
```

Cover direct workspace activation/switching entry points, including empty workspaces. Do not call it from focus-follow helpers that merely reveal a window on another workspace. Keep the source enum/string stable enough for runtime comparison (`workspaceBar`, numbered workspace command, adjacent navigation, back-and-forth, or equivalent existing action names).

### `WMController.swift`

Add a small state record containing:

- workspace id;
- monitor id;
- source;
- monotonic generation/sequence;
- recorded monotonic time;
- consumed/invalidated reason if applicable.

Expose a read-only snapshot method for `AXEventHandler`. Use monotonic time for age decisions; wall-clock time may be included only for display.

Before choosing a TTL or single-use policy, instrument invalidation candidates:

- a later explicit workspace activation replaces the prior record;
- an explicit move/rule target does not consume it because that stronger target owns the window;
- active focus request/native Space should be logged as stronger and should not be overridden;
- monitor topology removal invalidates a record whose workspace/monitor no longer resolves;
- record whether the candidate was consumed by a new managed standard window or expired unused.

Add a single placement-decision trace with:

```text
placement_affinity_decision token=<pid:window>
winner=<explicit_move|workspace_rule|tracked_parent|structural_replacement|active_focus_request|native_space|explicit_workspace_activation|confirmed_focus|recent_pid|frame|interaction|cursor|fallback>
workspace=<uuid> monitor=<id>
explicit_activation_workspace=<uuid-or-nil>
explicit_activation_monitor=<id-or-nil>
explicit_activation_source=<source-or-nil>
explicit_activation_age_ms=<n-or-nil>
explicit_activation_generation=<n-or-nil>
explicit_activation_valid=<bool>
explicit_activation_rejection=<stronger_affinity|expired|superseded|workspace_inactive|monitor_mismatch|already_consumed|none>
context_source=<cgs_created|ax_focused_admission_synthesized>
```

The trace must identify the actual winner rather than requiring equality inference from raw fields.

### `AXEventHandler.swift`

Extend `WindowCreatePlacementContext` and `makeCreatePlacementContext` with the explicit-activation snapshot. Both `captureCreatePlacementContext` (`cgs_created`) and `ensureCreatePlacementContextForFocusedAdmission` (`ax_focused_admission_synthesized`) already funnel through this builder; preserve that shared path.

Also trace raw cursor evidence sufficient to resolve the current contradiction:

- `NSEvent.mouseLocation` AppKit coordinates;
- containing `NSScreen.displayId`;
- mapped `Monitor.ID`;
- current monitor topology frames;
- placement frame and whether strict containment succeeded (separate from nearest approximation).

Do not persist machine-specific data. Runtime logs may contain live values; planning docs must inline only values needed later.

### Fast gate

```bash
mise run format
mise run build
```

Then run the app and capture the exact user sequence. Do not proceed to Step 2 until one capture contains:

1. explicit activation of the internal workspace with source/generation;
2. quick-terminal admission/ignore record;
3. the new ordinary window's placement affinity decision;
4. initial resolved workspace/monitor;
5. post-layout live and WindowServer frames;
6. raw cursor point/screen mapping at the same admission.

### Step-1 stop criteria

Stop and revise this plan rather than changing placement if:

- the visible window is initially resolved to the internal workspace and only later moves to external geometry (the bug is then downstream layout/frame ownership);
- no explicit user activation record precedes the failing create;
- cursor mapping still names the external display while independently captured physical evidence says internal (fix/instrument coordinate/screen mapping first);
- a stronger affinity legitimately wins (explicit rule/move, tracked parent, real replacement, active request, native Space).

## Step 2 — add the narrow explicit-activation affinity only if Step 1 confirms it is missing

### `WMController.swift`

Implement the new affinity as a placement candidate, not a global interaction-monitor rewrite.

Eligibility:

- new managed standard/document window;
- recent explicit activation record still points to the currently active workspace on that monitor;
- admission occurs after that activation generation;
- no stronger authority from the contract is present;
- no explicit configured workspace assignment applies;
- no tracked parent or confirmed structural replacement applies;
- no active focus request or native Space applies.

Place this check after configured workspace-rule handling and the stronger structural/parent/request/native decisions, but before confirmed/recent-pid/frame/interaction/cursor fallbacks. If the current function split makes that ordering obscure, extract a small `WorkspacePlacementAffinity` enum and one resolver that returns both target and winner; do not duplicate predicates in `resolveWorkspacePlacement` and `createPlacementTarget`.

Use the smallest evidence-supported lifetime:

- Prefer a single-use generation consumed by the first eligible ordinary window created after activation.
- Permit a short timeout only to prevent stale records surviving indefinitely; choose its value from observed activation-to-create latency plus a conservative margin, and emit the age.
- Do not refresh the lifetime on quick-terminal focus churn, app activation, recent-pid updates, or unrelated creates.

This avoids a cursor-always-wins regression: cursor remains a lower fallback, and an old explicit activation cannot route a later ordinary keyboard-created window after focus/user intent has changed.

### `AXEventHandler.swift`

Ensure the same affinity snapshot survives AX-before-CGS ordering. The first synthesized context stored in `createPlacementContextsByWindowId` must remain stable when `create_seen` arrives; do not recalculate and silently change the winner on the CGS retry.

When the candidate is ineligible, emit the exact rejection and continue through existing placement. Never silently fall back from an invalid explicit-activation record.

### Runtime gate

```bash
mise run format
mise run build
```

Capture at minimum:

1. **Real internal-display repro:** explicitly activate the internal empty workspace, invoke the internal quick terminal, create an ordinary Ghostty window. Expected diagnostic shape: `winner=explicit_workspace_activation`, target internal workspace/monitor, followed by internal live/WindowServer geometry.
2. **External-display regression:** reproduce the sequence previously fixed by `3056bee8`. Strong display-2 managed focus/interaction must still beat a display-1 cursor; winner must not be the new affinity unless the user explicitly activated that same display/workspace immediately beforehand.
3. **Ordinary keyboard create:** focus an existing managed window, leave the cursor on the other display, create a new ordinary window by keyboard. Confirm managed focus/native/on-screen authority remains the winner; cursor and stale explicit activation must not steal it.
4. **Explicit rule/move:** a rule-assigned or explicitly moved new window must retain its specified workspace.
5. **Tracked parent:** a dialog/sheet with a tracked parent must stay with the parent.
6. **Real structural replacement:** a correlated destroy/create replacement must preserve the replaced workspace.
7. **Native Space / active request:** each remains above the new affinity when present.

## Step 3 — acceptance, rollback, and follow-up

### Acceptance gate

All of the following are required:

- `mise run format` is clean.
- `mise run build` succeeds.
- Static source review confirms the authority contract and fences.
- Runtime records show one unambiguous winner and complete provenance for every tested create.
- The user explicitly confirms that the original real-world internal-display reproduction now behaves correctly.

**Until the last bullet occurs, describe the change only as a candidate or instrumentation build. Never say it fixes, solves, works, passes the repro, or is validated.**

After user confirmation, create a separate follow-up plan/commit for any changeset and curated regression tests. This plan still prohibits all `Tests/` edits.

### Rollback/failure criteria

Revert the behavior portion (retain useful diagnostics separately if desired) if:

- the user still sees external placement;
- initial placement is correct but a later frame/layout operation moves the window;
- ordinary keyboard-created windows start following the cursor or stale workspace activation;
- a rule/move, tracked parent, structural replacement, active request, or native Space loses precedence;
- the affinity can be armed by restore/reconciliation/focus-follow rather than explicit user navigation;
- one activation routes multiple unrelated later windows without fresh intent;
- runtime winner/provenance is ambiguous.

## Final static gate

Because tests are fenced out, do not run or prescribe test edits. Run the repository's non-test checks explicitly:

```bash
mise run format
mise run lint
mise run build
```

If `mise run check` necessarily runs the full suite, it may be run once as an unchanged-suite verification after the user confirms the runtime behavior, but it does not authorize modifying tests and it does not replace user confirmation.

## Implementation commit message shape (after user confirmation only)

Plain English, no Conventional Commit prefix. Suggested subject:

```text
Preserve explicit workspace intent for new windows
```

Before confirmation, any instrumentation-only spike should use a subject that says it adds placement-affinity diagnostics and must not claim a fix.
