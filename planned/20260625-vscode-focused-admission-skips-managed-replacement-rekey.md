# Focused-admission path skips the structural managed-replacement rekey — Plan

Re-groomed against main `d3ef41ee` on 2026-07-10.

**Status:** planned; its observability prerequisite has shipped, but its behavioral fix has not. `0f785212` added focused-admission diagnostics: `admitFocusedWindowBeforeNonManagedFallback` now records the structural-workspace-match signal (`Sources/Nehir/Core/Controller/AXEventHandler.swift:3981-4030`, `:4114-4130`) and `trackPreparedCreate` emits `track_prepared_create` (`:1747-1759`). The focused path still calls `trackPreparedCreate` (`:4030`), which proceeds to `addWindow` after only the native-fullscreen restore (`:1761-1787`); it still does not call the proactive rekey gate at `:1359-1395`. `WMController.reevaluateWindowRules` remains the only route that invokes that gate (`Sources/Nehir/Core/Controller/WMController.swift:3210-3225`).

An Electron app (here: VS Code Insiders, `com.microsoft.VSCodeInsiders`, pid `49947`)
re-creates its editor window under a **new** accessibility window id. Nehir keeps
tracking the **stale** id as an offscreen managed window and never adopts the new
id, so the live editor sits **outside** the tiling — listed under "Visible
Unmanaged WindowServer Windows" — until the user clicks it. The click routes
through Nehir's **focused-admission** path, which admits the window as a
**brand-new** managed entry (a fresh column) instead of re-keying the stale
entry onto it. The result is duplicate managed entries for one physical editor.

The focused-admission result was revalidated against `main` at `d3ef41ee` on 2026-07-10. It still tracks the prepared create directly without running the structural-replacement rekey helper first (see the status note above).

The raw finding (symptom + evidence) is captured in the companion discovery doc
[`../discovery/20260625-vscode-editor-unmanaged-until-clicked.md`](../discovery/20260625-vscode-editor-unmanaged-until-clicked.md).

---

## TL;DR

- **Symptom.** A VS Code window is on screen but not in the tiling until the user
  clicks it. After the click it tiles — but as a new column, alongside the stale
  entry that should have become it.
- **Root cause.** Nehir has two managed-window admission routes. The proactive
  route (`WMController.reevaluateWindowRules`) runs a **structural
  managed-replacement rekey** before admitting, so an identity change is folded
  onto the existing entry. The **focused-admission** route
  (`admitFocusedWindowBeforeNonManagedFallback` → `trackPreparedCreate`) does
  **not** — it runs only the native-fullscreen-restore rekey, then falls straight
  through to `addWindow`. So when focus is the trigger (as it is for an Electron
  re-key discovered by AX focus), the rekey is skipped.
- **Fix direction.** Run the same structural-rekey gate on the focused-admission
  path before `addWindow`, factored so both admission routes share one
  correlation step instead of duplicating it.
- **Why Nehir already had the answer.** The stale entry's
  `replacementFrame` matched the live window's frame exactly, and
  `windowRuntime replacementCorrelation=1` shows a correlation was in flight —
  the data to rekey was present, just not consulted on this path.

---

## Problem statement

A tiled windowing manager must fold an app's identity churn (same logical
window, new window id) onto the existing managed entry. Nehir has machinery for
exactly this: `ManagedReplacementMetadata` per entry, a
`replacementCorrelation`, and a `structuralReplacementMatch` rekey gate.

That gate is wired into **one** of the two admission entry points but not the
other. When the missing-create / re-discovered window is surfaced by an AX
**focus** event (rather than a CGS `.created` event that reaches
`reevaluateWindowRules`), the rekey never runs and a duplicate managed entry is
created. The user sees a window that refuses to tile until clicked, and
afterwards the workspace carries a stale ghost entry alongside the real one.

---

## Runtime evidence to preserve

Inlined from the 14.8 s capture so this plan stands without any log file.

### Topology / initial state

Single display `ID(displayId: 1)` (notch, frame `(0.0, 0.0, 2056.0, 1329.0)`,
visible frame `(0.0, 0.0, 2056.0, 1290.0)`), `displaySpacesMode=enabled`,
`focusFollowsMouse=false`. Interaction / visible workspace
`0C427DFB-1B09-4FF9-9162-E99198223FC4`.

`AXManager`: `rekeyedWindowIds=1` — one identity had **already** been re-keyed
earlier (so the mechanism works in principle; this is a second, unreconciled
one).

`windowRuntime replacementMetadata=4 replacementCorrelation=1` — a replacement
correlation was in flight but not completed.

### At capture start: the live editor is unmanaged

Managed VS Code entries (two, both offscreen):

```text
WindowToken(pid: 49947, windowId: 18847) workspace=0C427DFB… mode=tiling phase=offscreen
  hidden=layoutTransient(right)  liveAXFrame={{2055.0, 8.0}, {1008.0, 1282.0}}  observedVisible=false
  replacementFrame={{899.0, 39.0}, {1008.0, 1290.0}}   bundleId=com.microsoft.VSCodeInsiders
WindowToken(pid: 49947, windowId: 19319) workspace=0C427DFB… mode=tiling phase=offscreen
  hidden=layoutTransient(right)  liveAXFrame={{2055.0, 0.0}, {426.0, 1290.0}}  observedVisible=false
  replacementFrame={{442.0, 39.0}, {426.0, 1290.0}}    bundleId=com.microsoft.VSCodeInsiders
```

The on-screen editor appears only under **"Visible Unmanaged WindowServer
Windows"**:

```text
windowId=19872 pid=49947 owner=Code - Insiders bundleId=com.microsoft.VSCodeInsiders
  title=WorkspaceBarAnimation.swift (9ba4c47) ↔ WorkspaceBarAnimation.swift (08af6a7)…
  frame={{899.0, 39.0}, {1008.0, 1282.0}}  axContainsWindow=true
```

The layout had **4 columns** — `c0=w20101, c1=w18417, c2=w19319, c3=w18847` —
with **no `19872`**, confirming the live editor was outside the tiling.

**The smoking gun.** Stale entry `18847.replacementFrame={{899.0, 39.0},
{1008.0, 1290.0}}` matches the live window `19872` frame `{{899.0, 39.0},
{1008.0, 1282.0}}` exactly in origin and width; the heights differ by 8 pt
(1290 vs 1282), well inside the rekey frame tolerance (±64, see "Matcher
frame tolerance" below). Nehir had the data to correlate `18847 → 19872` but
did not act on it.

### The click admits it as a brand-new column (08:24:31)

```text
ax=AXFocusedWindowChanged pid=49947 window=nil          ← AX could not resolve focus to any known window

window_decision token=WindowToken(pid: 49947, windowId: 19872)
  context=focused_admission  existingMode=nil            ← treated as a new window, not a replacement
  disposition=managed  outcome=trackedTiling  wsFrame=(899.0,39.0,1008.0,1282.0)
create_placement_resolved token=…19872 … context_source=ax_focused_admission_synthesized
  focused_workspace_source=confirmed_focus
event=window_admitted token=…19872 … phase=tiled
```

Column insertion went **4 → 5**, not a rekey:

```text
workspace=0C427DFB… token=…19872  beforeColumns=4
  selectedTokenBefore=WindowToken(pid: 49947, windowId: 18847)   focusedTokenBefore=…19872
  reference=selected_node  referenceColumn=3  landedColumn=4
```

### At capture end: three managed entries for one editor

```text
(pid: 49947, 18847) phase=tiled  observedVisible=true  liveAXFrame={{16.0,0.0},…}     ← stale, now "visible"
(pid: 49947, 19319) phase=tiled  hidden=layoutTransient(left)  observedVisible=false
(pid: 49947, 19872) phase=tiled  observedVisible=true  liveAXFrame={{1032.0,0.0},…}   ← newly admitted
```

"Visible Unmanaged WindowServer Windows": `none` (the real window is now
managed). So the workspace ends with **three** managed VS Code entries
(`18847`, `19319`, `19872`) for one on-screen editor, instead of folding
`19872` onto `18847`.

---

## Root cause

Two managed-window admission routes; only one runs the structural rekey.

### Route A — proactive (rule re-evaluation): runs the rekey

`WMController.reevaluateWindowRules` (Sources/Nehir/Core/Controller/WMController.swift:3581) is the rule
re-evaluation entry (reached from CGS-create handling and IPC/rule-reeval
scheduling). For each candidate with no existing entry, it calls the structural
rekey **before** `addWindow`:

```swift
// Sources/Nehir/Core/Controller/WMController.swift:3714-3724
if existingEntry == nil,
   let windowId = UInt32(exactly: token.windowId),
   axEventHandler.rekeyStructuralManagedReplacementIfNeeded(
       token: token, windowId: windowId, axRef: axRef,
       bundleId: …, mode: effectiveTrackedMode, facts: evaluation.facts
   )
{
    affectedWorkspaceIds.insert(workspaceId)
    relayoutNeeded = true
    continue        // ← skips addWindow; the stale entry was re-keyed in place
}
_ = workspaceManager.addWindow(…)   // Sources/Nehir/Core/Controller/Sources/Nehir/Core/Controller/WMController.swift:3732
```

`rekeyStructuralManagedReplacementIfNeeded`
(Sources/Nehir/Core/Controller/Sources/Nehir/Core/Controller/AXEventHandler.swift:827) finds a match via
`structuralReplacementMatch` (Sources/Nehir/Core/Controller/AXEventHandler.swift:3624) and, if one exists,
re-keys the old token onto the new one via `rekeyManagedWindowIdentity`
(Sources/Nehir/Core/Controller/AXEventHandler.swift:2786) — no new entry, no new column.

### Route B — focused admission: does NOT run the rekey

When an AX focus event surfaces a window Nehir does not manage,
`admitFocusedWindowBeforeNonManagedFallback`
(Sources/Nehir/Core/Controller/Sources/Nehir/Core/Controller/AXEventHandler.swift:2148) builds a candidate and
hands it to `trackPreparedCreate`. Inside `trackPreparedCreate`, the **only**
replacement handling before `addWindow` is the native-fullscreen restore — a
different, narrower rekey — and then a bare admission:

```swift
// Sources/Nehir/Core/Controller/Sources/Nehir/Core/Controller/AXEventHandler.swift:1137-1167
private func trackPreparedCreate(_ candidate: PreparedCreate) {
    …
    let nativeFullscreenRestore = restoreNativeFullscreenReplacement(…) // :1151 — fullscreen-only
    if nativeFullscreenRestore.restored { …; return }
    let trackedToken = controller.workspaceManager.addWindow(        // :1167 — NO structural rekey
        candidate.axRef, …, managedReplacementMetadata: candidate.replacementMetadata
    )
    …
}
```

`rekeyStructuralManagedReplacementIfNeeded` / `structuralReplacementMatch` are
never called on this path. So when focus is the trigger, an identity change is
admitted as a new window (`existingMode=nil`, fresh column) rather than folded
onto the stale entry — exactly what the capture shows.

### Why the focused path's omission bites Electron apps specifically

Electron/VS Code re-create windows under new ids without always emitting a CGS
`.created` that flows through `reevaluateWindowRules`. The window is then
"discovered" only when it takes focus, which routes through Route B. Apps that
always emit a clean `.created` (most native apps) hit Route A and get rekeyed
correctly — which is why `rekeyedWindowIds=1` shows one earlier rekey succeeded
and this bug is intermittent and app-specific.

### Matcher frame tolerance (relevant to the fix)

`framesAreCloseForManagedReplacement`
(Sources/Nehir/Core/Controller/Sources/Nehir/Core/Controller/AXEventHandler.swift:3875) requires
`|ΔmidX| ≤ 96`, `|ΔmidY| ≤ 96`, `|Δwidth| ≤ 64`, `|Δheight| ≤ 64`. For
`18847 ↔ 19872`: `ΔmidX=0`, `ΔmidY=0`, `Δwidth=0`, `Δheight=8` — passes. So a
wired-up rekey on Route B **would** have matched in this case.

`managedReplacementCorrelationPolicy` (Sources/Nehir/Core/Controller/AXEventHandler.swift:3764) additionally
requires the stale entry's metadata to have non-nil `role` **and** `subrole`,
plus a structural anchor (`parentWindowId != nil || frame != nil`). The frame
anchor is satisfied; the role/subrole requirement is the one residual unknown
(see "Unknowns").

---

## Design: share the structural-rekey gate across both admission routes

The proactive path already has the correct, tested gate. The fix is to make the
focused-admission path consult the same gate before falling through to
`addWindow`, rather than duplicating the logic.

### Preferred: a single shared admission-resolution step

Extract the "does this candidate rekey an existing entry? if so, do it and stop"
decision into one helper (e.g. `attemptStructuralRekey(for candidate) -> Bool`
on `AXEventHandler`, wrapping the existing
`rekeyStructuralManagedReplacementIfNeeded` + `discardCreatePlacementContext`),
and call it from both:

- `WMController.reevaluateWindowRules` (replacing the inline block at :3714),
- and `trackPreparedCreate` (or `admitFocusedWindowBeforeNonManagedFallback`,
  immediately before `trackPreparedCreate`).

On success, the focused path discards the create-placement context, requests a
relayout (so the re-keyed entry is re-laid into its column rather than
appending one), and returns without calling `addWindow`. This keeps the two
routes behaviourally identical for identity churn and removes the divergence
that caused the bug.

### Why not "just call rekey inline in trackPreparedCreate"

That also works and is the smallest diff, but it duplicates the guard already at
`WMController.3714`. Two copies of "when does admission rekey vs add" is exactly
how this bug happened. Prefer the shared helper; fall back to the inline call
only if extraction turns out to ripple into the rule-effects/metadata assembly
below `addWindow` in `reevaluateWindowRules`.

### Behaviour the fix must preserve

- A genuinely **new** window (no matching stale entry) is still admitted as a new
  managed window — `structuralReplacementMatch` returning `nil` must still fall
  through to `addWindow` unchanged.
- The non-managed-focus suppression gate
  (`shouldSuppressUnrequestedAdmissionDuringNonManagedFocus`,
  Sources/Nehir/Core/Controller/AXEventHandler.swift:711) still runs before any admission; the rekey attempt
  must slot in after that suppression check, not before it.
- The managed-replacement **burst** correlation path
  (`rekeyManagedWindowIdentity` at Sources/Nehir/Core/Controller/AXEventHandler.swift:2646 and Sources/Nehir/Core/Controller/AXEventHandler.swift:3510) is a
  separate, complementary mechanism (destroy+create pair correlation) and is out
  of scope here; it should continue to work independently.

---

## Implementation plan

### Phase 1 — Trace and diagnostics (shipped; use to validate)

`0f785212` shipped focused-admission diagnostics. Before changing behavior, reproduce the Electron-style rekey and confirm the capture contains the `focused_admission_guard` and `track_prepared_create` records, including `structuralWorkspaceMatch` and the metadata summary. These records establish whether Route B saw a viable structural match before it admitted a new entry.

The shipped diagnostics report decision inputs, not a structural-rekey outcome; Route B still reaches `addWindow`. Phase 2 must add the behavioral decision record (`rekeyed`, `no_match`, or `ambiguous`) when it wires in the gate.

### Phase 2 — Shared rekey helper

Extract the structural-rekey gate into one helper and route both admission
entries through it (see "Design"). Keep `reevaluateWindowRules`'s post-rekey
`affectedWorkspaceIds.insert` / `relayoutNeeded = true` semantics; mirror them
on the focused path (discard placement context, request relayout).

### Phase 3 — Ambiguity handling for multi-window apps

`structuralReplacementMatch` returns `nil` (no rekey) when **two** stale entries
match the new window — the `recordMatch` closure treats a second match as
ambiguous (Sources/Nehir/Core/Controller/AXEventHandler.swift:3655-3661). In this capture only `18847`
matched (`19319`'s frame `{{442,39},{426,1290}}` is nowhere near `19872`'s
`{{899,39},{1008,1282}}`), so the fix works unaided here. But VS Code commonly
has several same-shape editor windows; once Route B rekeys, the ambiguity case
becomes reachable from focus. Decide and document the policy: rekey onto the
**closest-frame** match (breaking ties deterministically) rather than refusing,
or keep refuse-and-admit as the safe default. Either is defensible; pick one and
test it.

### Phase 4 — Stale-entry cleanup (related, lower priority)

Independent of the rekey: after admission, the workspace still carried stale
offscreen entries (`18847`, `19319` parked at `x≈2055`). Even with a correct
rekey, entries whose AX window has genuinely gone away should be reaped. This is
a separate lifecycle bug; do not bundle it, but link it as a follow-up.

---

## Tests

### AXEventHandler / WMController rekey tests

- **Focused admission rekeys a stale entry.** Seed a managed entry with
  `managedReplacementMetadata` (role/subrole/anchor/frame) for a pid; surface a
  new window id for the same pid at a frame within tolerance via the
  focused-admission path. Assert the stale entry's token is re-keyed to the new
  id, no new entry is created, and the column count is unchanged.
- **Focused admission without a match still adds.** Same setup but new window
  frame far outside tolerance → assert a new managed entry is added (regression
  guard for the shared helper).
- **Proactive path unchanged.** The existing `reevaluateWindowRules` rekey
  behaviour is preserved after extraction (re-use its current tests).
- **Suppression gate still precedes rekey.** With non-managed focus active and a
  stale-unrequested surface, admission is still suppressed before any rekey is
  attempted.

### Matcher tests (`structuralReplacementMatch`)

- **Ambiguity policy** (Phase 3): two stale entries both within tolerance of the
  new window → assert the chosen policy (closest-frame rekey, or refuse-and-add)
  and that it is deterministic.

### Integration / capture-replay

- A scripted Electron-style re-key (destroy old id, create new id at the same
  frame, emit `AXFocusedWindowChanged window=nil`) admitted via Route B rekeys
  instead of appending a column. The end state has one managed entry, not two.

---

## Acceptance criteria

- After the fix, surfacing a re-keyed VS Code window via focus (no clean CGS
  `.created`) results in the stale entry being re-keyed onto the new id — column
  count unchanged, no duplicate managed entry.
- The focused-admission path emits a trace record of the rekey decision
  (attempted + outcome).
- Existing proactive-path rekey behaviour and the non-managed-focus suppression
  gate are unchanged (covered by existing tests).
- Reproducing the original scenario leaves the workspace with one managed entry
  for the editor, not three.

---

## Risks and mitigations

- **Over-rekeying on focus.** Wiring rekey into Route B means any focused,
  unmanaged window that happens to frame-match a stale entry could be folded onto
  it. Mitigation: the existing `managedReplacementMetadataMatches` preconditions
  (bundle id, role, subrole, window level, frame tolerance, structural anchor)
  already gate this tightly; rely on them and add the ambiguity test (Phase 3).
- **Ambiguity on multi-window apps.** Several same-shape editor windows can match.
  Mitigation: Phase 3 picks and tests a deterministic tie-break; safe default is
  refuse-and-add (current behaviour) so a wrong guess never destroys an entry.
- **Metadata missing role/subrole.** If the stale entry's metadata lacks role or
  subrole, `managedReplacementCorrelationPolicy` returns `nil` and even a wired
  rekey will not match until AX facts are refreshed (see Unknowns). Mitigation:
  have the helper refresh live AX facts for the stale entry when role/subrole are
  nil (there is already `managedReplacementNeedsLiveAXFacts` for exactly this).

---

## Unknowns

- **Were the stale entries' role/subrole populated?** The matcher requires
  non-nil role and subrole on the old metadata. The frame anchor was satisfied,
  but the capture's snapshot does not dump the stale entries'
  `ManagedReplacementMetadata.role/subrole` (only `replacementFrame`). If they
  were nil, the fix must also refresh live AX facts for the stale entry before
  matching — otherwise the rekey gate runs but still returns no match. A
  follow-up capture that includes the create event's full replacement metadata
  for `18847`/`19319` would settle this; until then, include the
  live-AX-facts-refresh branch in the implementation defensively.
- **Why did the proactive rekey not fire before the click?** The create that
  produced `19872` either did not emit a CGS `.created` reaching
  `reevaluateWindowRules`, or was deferred/suppressed. Phase 1's trace should
  also record whether Route A was ever attempted for `19872`, to confirm the fix
  closes the gap rather than just papering over a missing create signal.

---

## Relationship to other work

- **Companion discovery:** [`../discovery/20260625-vscode-editor-unmanaged-until-clicked.md`](../discovery/20260625-vscode-editor-unmanaged-until-clicked.md) — the raw symptom and inlined evidence, no fix proposal.
- **Managed-replacement burst correlation** (`rekeyManagedWindowIdentity` at
  Sources/Nehir/Core/Controller/AXEventHandler.swift:2646, Sources/Nehir/Core/Controller/AXEventHandler.swift:3510) is the sibling mechanism for destroy+create
  pairs. This plan does not touch it; both should continue to coexist.
- **Stale-entry reaping** (Phase 4 follow-up) is the separate lifecycle bug that
  leaves `18847`/`19319` parked offscreen even after a correct rekey.
