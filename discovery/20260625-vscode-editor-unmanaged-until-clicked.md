# VS Code editor sits outside the tiling until clicked (focused admission does not rekey a stale identity) — Discovery

Groom 2026-07-07: in flight — see `planned/20260625-vscode-focused-admission-skips-managed-replacement-rekey.md`; the focused-admission stale-identity rekey has not landed on main (verified against main 7a025b78).

Discovery (2026-06-25). A VS Code Insiders editor window
(`com.microsoft.VSCodeInsiders`, pid `49947`) is visibly on screen but **not**
part of Nehir's tiling layout — it is tracked as an unmanaged WindowServer
window — until the user clicks it. The click makes it tile, but as a **new
column** rather than folding onto the stale managed entry it should have become.
After the click the workspace holds **three** managed VS Code entries
(`18847`, `19319`, `19872`) for one on-screen editor.

All code citations were verified against the main Nehir source tree at
`8887adcb` on 2026-06-25 (`git log -1 --format='%h %s'` → `8887adcb Fixup
changeset reporter contribution mention`). Line numbers will drift.

The fix proposal, implementation plan, and tests are in
[`../planned/20260625-vscode-focused-admission-skips-managed-replacement-rekey.md`](../planned/20260625-vscode-focused-admission-skips-managed-replacement-rekey.md).

---

## TL;DR

- Electron re-created the editor under a new window id (`19872`). Nehir kept two
  **stale** managed entries for that pid (`18847`, `19319`), both parked
  offscreen, and never adopted `19872`.
- The live editor appeared only under "Visible Unmanaged WindowServer Windows",
  so it was outside the tiling.
- Clicking it emitted `AXFocusedWindowChanged pid=49947 window=nil` and admitted
  `19872` via the **focused-admission** path with `existingMode=nil` — i.e. as a
  brand-new window, not a replacement. Column count went **4 → 5**.
- The stale entry `18847` already had `replacementFrame={{899.0, 39.0},
{1008.0, 1290.0}}` matching the live `19872` frame `{{899.0, 39.0},
{1008.0, 1282.0}}` (Δheight 8), and `windowRuntime replacementCorrelation=1`
shows a correlation was in flight — Nehir had the data to fold `19872` onto
`18847` but did not.

---

## Topology / initial state

Single display `ID(displayId: 1)` (notch, frame `(0.0, 0.0, 2056.0, 1329.0)`,
visible frame `(0.0, 0.0, 2056.0, 1290.0)`), `displaySpacesMode=enabled`,
`focusFollowsMouse=false`. Interaction / visible workspace
`0C427DFB-1B09-4FF9-9162-E99198223FC4`.

`AXManager`: `rekeyedWindowIds=1` (one earlier rekey had succeeded — the
mechanism works, this is a second unreconciled one).
`windowRuntime replacementMetadata=4 replacementCorrelation=1` (a correlation in
flight, not completed).

---

## What the evidence proves

### 1. The live editor was unmanaged at capture start

Managed VS Code entries (two, both offscreen):

```text
WindowToken(pid: 49947, windowId: 18847) workspace=0C427DFB… mode=tiling phase=offscreen
  hidden=layoutTransient(right)  liveAXFrame={{2055.0, 8.0}, {1008.0, 1282.0}}  observedVisible=false
  replacementFrame={{899.0, 39.0}, {1008.0, 1290.0}}   bundleId=com.microsoft.VSCodeInsiders
WindowToken(pid: 49947, windowId: 19319) workspace=0C427DFB… mode=tiling phase=offscreen
  hidden=layoutTransient(right)  liveAXFrame={{2055.0, 0.0}, {426.0, 1290.0}}  observedVisible=false
  replacementFrame={{442.0, 39.0}, {426.0, 1290.0}}    bundleId=com.microsoft.VSCodeInsiders
```

The on-screen editor was only under "Visible Unmanaged WindowServer Windows":

```text
windowId=19872 pid=49947 owner=Code - Insiders bundleId=com.microsoft.VSCodeInsiders
  title=WorkspaceBarAnimation.swift (9ba4c47) ↔ WorkspaceBarAnimation.swift (08af6a7)…
  frame={{899.0, 39.0}, {1008.0, 1282.0}}  axContainsWindow=true
```

The layout had 4 columns — `c0=w20101, c1=w18417, c2=w19319, c3=w18847` — no
`19872`. So the editor was genuinely outside the tiling.

### 2. The click admitted it as a new column, not a rekey (08:24:31)

```text
ax=AXFocusedWindowChanged pid=49947 window=nil

window_decision token=WindowToken(pid: 49947, windowId: 19872)
  context=focused_admission  existingMode=nil            ← treated as new, not a replacement
  disposition=managed  outcome=trackedTiling  wsFrame=(899.0,39.0,1008.0,1282.0)
create_placement_resolved token=…19872 … context_source=ax_focused_admission_synthesized
  focused_workspace_source=confirmed_focus
event=window_admitted token=…19872 … phase=tiled
```

Column insertion 4 → 5:

```text
workspace=0C427DFB… token=…19872  beforeColumns=4
  selectedTokenBefore=WindowToken(pid: 49947, windowId: 18847)   focusedTokenBefore=…19872
  reference=selected_node  referenceColumn=3  landedColumn=4
```

### 3. Nehir already had the correlation data

Stale `18847.replacementFrame={{899.0, 39.0}, {1008.0, 1290.0}}` vs live `19872`
frame `{{899.0, 39.0}, {1008.0, 1282.0}}`: identical origin and width, height
differs by 8 pt — inside the rekey tolerance (`|Δheight| ≤ 64`,
`framesAreCloseForManagedReplacement`, Sources/Nehir/Core/Controller/AXEventHandler.swift:3875). Combined with
`replacementCorrelation=1`, the data to fold `19872` onto `18847` was present.

### 4. At capture end: three managed entries for one editor

```text
(pid: 49947, 18847) phase=tiled  observedVisible=true  liveAXFrame={{16.0,0.0},…}
(pid: 49947, 19319) phase=tiled  hidden=layoutTransient(left)  observedVisible=false
(pid: 49947, 19872) phase=tiled  observedVisible=true  liveAXFrame={{1032.0,0.0},…}
```

"Visible Unmanaged WindowServer Windows": `none`.

---

## Root cause surface

Two managed-window admission routes; only one runs the structural rekey.

- **Proactive** — `WMController.reevaluateWindowRules` (Sources/Nehir/Core/Controller/WMController.swift:3581)
  calls `rekeyStructuralManagedReplacementIfNeeded` (Sources/Nehir/Core/Controller/AXEventHandler.swift:827,
  via `structuralReplacementMatch` at :3624) **before** `addWindow`
  (Sources/Nehir/Core/Controller/WMController.swift:3732). A matching stale entry is re-keyed in place.
- **Focused admission** — `admitFocusedWindowBeforeNonManagedFallback`
  (Sources/Nehir/Core/Controller/AXEventHandler.swift:2148) → `trackPreparedCreate` (Sources/Nehir/Core/Controller/AXEventHandler.swift:1137)
  runs only `restoreNativeFullscreenReplacement` (:1151) before `addWindow`
  (:1167). The structural rekey is **not** consulted, so an identity change
  surfaced by AX focus is admitted as a new window with `existingMode=nil`.

The capture shows the focused path fired (`context=focused_admission`,
`context_source=ax_focused_admission_synthesized`), so the rekey was skipped and
`19872` became a fifth column.

---

## What is still unknown

- Whether the stale entries' `ManagedReplacementMetadata.role/subrole` were
  populated. The matcher (`managedReplacementCorrelationPolicy`,
  Sources/Nehir/Core/Controller/AXEventHandler.swift:3764) requires non-nil role and subrole on the old
  metadata; the snapshot only exposes `replacementFrame`. If they were nil, even
  a wired-up rekey would need to refresh live AX facts first (there is already
  `managedReplacementNeedsLiveAXFacts` for this).
- Why the proactive rekey did not fire on the original create (no CGS `.created`
  reaching `reevaluateWindowRules`, or deferred/suppressed). A capture that
  records whether Route A was ever attempted for `19872` would settle it.

---

## Relationship to other work

- Fix proposal and plan:
  [`../planned/20260625-vscode-focused-admission-skips-managed-replacement-rekey.md`](../planned/20260625-vscode-focused-admission-skips-managed-replacement-rekey.md).
- Adjacent mechanism (not the cause here): the managed-replacement **burst**
  correlation (`rekeyManagedWindowIdentity` at Sources/Nehir/Core/Controller/AXEventHandler.swift:2646, Sources/Nehir/Core/Controller/AXEventHandler.swift:3510)
  handles destroy+create pairs and is independent of this focused-admission gap.
