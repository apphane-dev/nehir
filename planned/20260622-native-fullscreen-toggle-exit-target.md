# Fix native fullscreen toggle exit target

**Status:** planned
**Source discovery:** `discovery/20260617-nehir-69-fullscreen-restore-on-focus.md`
**Related:** `planned/20260621-niri-fullscreen-expectations-and-fix.md`,
`noop/20260617-omniwm-244-native-fullscreen-counted-and-leak.md`,
`planned/20260622-fullscreen-behaviour-roadmap.md`

All source references were last checked against the main Nehir source tree during
planning on 2026-06-22. Re-verify before editing; line numbers drift.

> Scope: native macOS fullscreen (`toggleNativeFullscreen`) only. This is separate
> from the tiling/layout fullscreen fix in
> `planned/20260621-niri-fullscreen-expectations-and-fix.md`.

## TL;DR

A focused native-fullscreen Space must make `toggleNativeFullscreen` an **exit**
command for the current native-fullscreen record. It must not enter native
fullscreen on another layout-selected or stale command-target window.

New repro evidence supplied during planning shows the failure clearly:

- The trace starts with no native records: `nativeFullscreen records=0`,
  `appFullscreen=false`.
- During one native-fullscreen toggle sequence, the event stream records multiple
  independent native enters: `active=true` for
  `WindowToken(pid: 57195, windowId: 4558)`, then `active=true` for
  `WindowToken(pid: 23546, windowId: 4635)`, then `active=true` for
  `WindowToken(pid: 57195, windowId: 6698)`, later rekeyed to
  `WindowToken(pid: 57195, windowId: 6966)` and exited once, and then another
  `active=true` for `WindowToken(pid: 57195, windowId: 537)`.
- The final runtime state has `nativeFullscreen records=3`, `appFullscreen=true`,
  `focus focused=nil`, and three managed tiled entries whose observed AX state is
  `fullscreen=true` / `layout=nativeFullscreen`:
  `WindowToken(pid: 23546, windowId: 4635)`,
  `WindowToken(pid: 57195, windowId: 4558)`, and
  `WindowToken(pid: 57195, windowId: 6698)`.
- This is not the same bug as the tiling `.fullscreen` no-op. It is a native
  command-target resolution bug: while app fullscreen is active, an enter path can
  still select another managed/layout target instead of exiting the active native
  record.

One isolated one-hotkey trace would be useful after implementation, but it is
**not blocking**. The current inline evidence is enough to plan and test the fix.

## Product / behavior decision

Native fullscreen is the macOS green-button path. It owns its Space and is heavier
than the tiling layout modes. The expected toggle contract is simple:

1. If the currently frontmost/focused native-fullscreen window belongs to Nehir's
   native-fullscreen records, toggle exits that window.
2. If exactly one native-fullscreen record is active/suspended/exit-requested and
   no frontmost token can be resolved, toggle exits that record.
3. Only when Nehir is **not** in app fullscreen and no native transition is pending
   may the command enter native fullscreen for the normal managed command target.
4. Never enter native fullscreen for a second managed window while an active native
   fullscreen record exists.

## Source landmarks

- `Sources/Nehir/Core/Controller/CommandHandler.swift` —
  `toggleNativeFullscreenForFocused()` currently checks `managedCommandTargetToken()`
  first, so a stale layout selection can win before the native exit-target branch.
- `Sources/Nehir/Core/Workspace/WorkspaceManager.swift` —
  `requestNativeFullscreenEnter`, `requestNativeFullscreenExit`,
  `markNativeFullscreenSuspended`, `restoreNativeFullscreenRecord`, and
  `nativeFullscreenCommandTarget(frontmostToken:)`.
- `Sources/Nehir/Core/Reconcile/WMEvent.swift` — native transition event shape.
- `Sources/Nehir/Core/Controller/AXEventHandler.swift` — native-fullscreen
  detection and transition admission.
- `Sources/Nehir/Core/Controller/LayoutRefreshController.swift` and
  `Sources/Nehir/Core/Border/FocusBorderController.swift` — existing consumers of
  `WorkspaceManager.hasPendingNativeFullscreenTransition`; keep respecting those
  guards.

## Implementation plan

### N1. Make native exit-target resolution run before managed enter-target resolution

In `CommandHandler.toggleNativeFullscreenForFocused()`:

1. Compute the frontmost pid/token as today, but do it before the managed-target
   enter branch.
2. If `workspaceManager.isAppFullscreenActive` or
   `workspaceManager.hasPendingNativeFullscreenTransition`, ask
   `nativeFullscreenCommandTarget(frontmostToken:)` for an exit token first.
3. If an exit token resolves and its entry exists:
   - call `requestNativeFullscreenExit(token, initiatedByCommand: true)`;
   - call `setFullscreen(entry.axRef, false)`;
   - on failure, call `markNativeFullscreenSuspended(token)` as today;
   - return.
4. Only after that branch returns nil should the code consider
   `managedCommandTargetToken()` for a new enter.
5. Add a compact runtime trace line / event for the command decision:
   `nativeFullscreenCommand target=<token> decision=exit|enter source=<frontmost|singleRecord|managedCommandTarget|none>`.

### N2. Broaden `nativeFullscreenCommandTarget(frontmostToken:)`

The helper currently prefers records in `.suspended` or `.exitRequested`. Extend it
so it can resolve the active/native-fullscreen record that should receive an exit:

- If `frontmostToken` maps to a native-fullscreen record and the record's
  `currentToken` matches either the frontmost token or its current rekeyed token,
  return `record.currentToken`.
- Else, if exactly one native-fullscreen record exists in an exit-capable state
  (`enterRequested`, `suspended`, or `exitRequested`, plus any active state used by
  the reducer), return that record's `currentToken`.
- Else return nil and log why (`noRecord`, `ambiguousRecords`, or
  `frontmostNotRecorded`).

Keep the `hasPendingNativeFullscreenTransition` guard semantics intact. Do not
remove the suspension/counting protections documented in
`noop/20260617-omniwm-244-native-fullscreen-counted-and-leak.md`.

### N3. Add invariants around native record cardinality

Add a small invariant/helper in `WorkspaceManager` or in tests:

- While app fullscreen is active, invoking native toggle must not increase the
  number of native fullscreen records.
- A successful command-driven exit should drive the chosen record toward removal
  or a non-native layout state, not create an enter record for another window.

Do not enforce a hard runtime assertion in production until tests prove all
rekey/temporarily-unavailable transitions obey it; start with tests and trace.

## Tests

Add or update tests in the existing `CommandHandler` / `WorkspaceManager` test
areas (locate exact files during implementation):

1. **`nativeToggleExitsFrontmostNativeRecordBeforeManagedTarget`**
   - native record exists for token A;
   - layout/managed command target is token B;
   - app fullscreen is active;
   - command toggles A to `false`; B is never toggled to `true`.
2. **`nativeToggleExitsSingleRecordWithoutFrontmostToken`**
   - one native record exists;
   - no frontmost token is available;
   - command exits the single record.
3. **`nativeToggleDoesNotEnterSecondWindowWhileAppFullscreenActive`**
   - record A exists and managed command target B exists;
   - command must not call `setFullscreen(B, true)`.
4. **`nativeFullscreenCommandTargetRejectsAmbiguousRecords`**
   - two records exist and no frontmost token identifies one;
   - helper returns nil and logs/records ambiguity.
5. Keep the existing enter behavior green:
   - no app fullscreen, no pending native transition, managed command target A;
   - command calls `setFullscreen(A, true)` and records enter.

## Validation

```bash
swift build
swift test --filter CommandHandler
swift test --filter NativeFullscreen
swift test --filter WorkspaceManager
swift test
```

Manual validation after the fix:

1. Start with one managed window focused in a normal workspace.
2. Trigger `toggleNativeFullscreen`; the app enters macOS native fullscreen.
3. Without focusing another Nehir-managed window, trigger `toggleNativeFullscreen`
   again.
4. Expected: the same native-fullscreen window exits. No additional managed window
   enters native fullscreen. Runtime state returns to zero native records once the
   OS transition completes.
5. Repeat with one additional managed window in the original workspace selected by
   layout state; the selected/layout window must still not enter fullscreen while
   the native Space is active.

## Trace needs

No more traces are required before implementation. The current inline evidence is
sufficient.

One optional post-fix trace is useful as acceptance evidence: a minimal one-window
native enter/exit capture showing one `active=true`, one matching `active=false`,
and final `nativeFullscreen records=0`. Keep the evidence inlined in the closing
comment or follow-up doc; do not rely on local trace filenames.

## Non-goals

- Do not change layout/tiling `.fullscreen`; that is handled by
  `planned/20260621-niri-fullscreen-expectations-and-fix.md`.
- Do not change `toggleColumnFullWidth`; it is a column-width layout operation and
  behaved as the control trace expected.
- Do not drive `AXFullScreen` from the tiling maximize path.
- Do not remove existing native suspension / transition guards from the #244 fix.
