# OmniWM issue #394 — "redundant `allEntries()` call in full rescan" — Discovery

Groom 2026-07-07: still applicable — analysis; verdict is the two allEntries() calls straddle removeMissing() and the upstream reuse-the-snapshot fix would regress per-entry teardown; do NOT port (verified against main 7a025b78).

Source issue: <https://github.com/BarutSRB/OmniWM/issues/394>
Scope of this doc: determine whether the issue applies to nehir, and whether
the suggested fix is safe to port.

All file/line references were verified against the Nehir source tree at `92ab0c8` ("Fix status bar Show Workspace
toggle"). Re-verify before implementing; line numbers drift.

---

## TL;DR

- **The code the issue describes exists in nehir, verbatim, in the same
  method.** `LayoutRefreshController.buildFullRefreshExecutionPlan()` calls
  `controller.workspaceManager.allEntries()` twice — at
  `LayoutRefreshController.swift:1382` (`trackedEntries`) and again at
  `:1412` (`remainingTokens`). This matches the issue's "lines 1371 and 1401"
  up to a small line-number offset.
- **The issue's diagnosis is incorrect for this code.** The two calls are
  **not** redundant: they straddle a mutating call,
  `workspaceManager.removeMissing(...)` at `:1411`. The first snapshot is
  taken *before* removal, the second *after*.
- **The issue's suggested fix is a regression, not an optimization.** Reusing
  `trackedEntries` for `remainingTokens` (`Set(trackedEntries.map(\.token))`)
  would make the downstream cleanup loop at `:1413` a no-op for every removed
  window, leaking per-entry resources (native-fullscreen placeholder, AX
  window-state cache, keyboard-focus target) on every full rescan that evicts
  any window.
- **Verdict:** relevant (same code), but **do not apply the suggested fix.**
  The only legitimate, much smaller optimization available is skipping the
  intermediate `Array` allocation on line 1412 by asking `WorkspaceManager`
  for a token `Set` directly — and even that is optional micro-optimization,
  not the "1000+ unnecessary lookups" the issue claims.

---

## Provenance: is this nehir's code?

Yes. `LayoutRefreshController.swift` is present
in nehir and contains the exact method and call pattern described.

Relevant files in nehir:

```
Sources/Nehir/Core/Controller/LayoutRefreshController.swift   <- the method
Sources/Nehir/Core/Workspace/WorkspaceManager.swift          <- allEntries(), removeMissing()
Sources/Nehir/Core/Workspace/WindowModel.swift               <- backing store
```

---

## The code in question

Method declaration:

```swift
// LayoutRefreshController.swift:1132
private func buildFullRefreshExecutionPlan() async throws -> RefreshExecutionPlan {
```

The two calls and what sits between them
(`LayoutRefreshController.swift:1382–1416`):

```swift
let trackedEntries = controller.workspaceManager.allEntries()          // :1382  PRE-remove
if shouldPreserveMissingWindows {
    // ... fills seenKeys from trackedEntries ...
} else {
    // ... fills seenKeys from trackedEntries (hidden apps, native fullscreen,
    //     failed PIDs, scratchpad-hidden preservation) ...
}

let scratchpadTokenBeforeRemove = controller.workspaceManager.scratchpadToken()
controller.workspaceManager.removeMissing(                             // :1411  MUTATES state
    keys: seenKeys,
    requiredConsecutiveMisses: 1
)
let remainingTokens = Set(controller.workspaceManager.allEntries().map(\.token))  // :1412  POST-remove
for entry in trackedEntries where !remainingTokens.contains(entry.token) {        // :1413  set difference
    controller.nativeFullscreenPlaceholderManager.remove(entry.token)
    controller.axManager.removeWindowState(pid: entry.pid, windowId: entry.windowId)
    controller.clearKeyboardFocusTarget(matching: entry.token)
}
```

The loop at `:1413` is the whole reason both snapshots exist: it computes
**trackedEntries \ remainingTokens** — i.e. the entries that were present
before `removeMissing` and are gone after it — and tears down their
per-entry resources.

---

## Why the two calls are not redundant (verification)

### 1. `allEntries()` returns a fresh snapshot, not a live view

```swift
// WindowModel.swift:562
func allEntries() -> [Entry] {
    Array(entries.values)   // brand-new Array, copied out of the dict
}

// WorkspaceManager.swift:2596
func allEntries() -> [WindowModel.Entry] {
    windows.allEntries()    // forwards to WindowModel
}
```

Each call materializes a new `Array` over the **current** contents of
`entries`. It is a fresh membership snapshot (an array of `Entry` references),
not a live view.

### 2. `removeMissing(...)` mutates that backing store in place

```swift
// WorkspaceManager.swift:2829
func removeMissing(keys activeKeys: Set<WindowModel.WindowKey>, requiredConsecutiveMisses: Int = 1) {
    let confirmedMissingKeys = windows.confirmedMissingKeys(
        keys: activeKeys,
        requiredConsecutiveMisses: requiredConsecutiveMisses
    )
    var removedAny = false
    for key in confirmedMissingKeys {
        guard let entry = windows.entry(for: key) else { continue }
        _ = removeTrackedWindow(entry)        // <- mutates
        removedAny = true
    }
    if removedAny {
        schedulePersistedWindowRestoreCatalogSave()
    }
}
```

`removeTrackedWindow(_:)` (private, `WorkspaceManager.swift:2871`) in turn
calls `windows.removeWindow(key: entry.token)` and
`invalidateWorkspaceProjection(reason: "windowRemoved")`, so the `entries`
dictionary actually loses keys.

### 3. Therefore the two snapshots differ by exactly the removed set

- `trackedEntries`  (`:1382`) = entries present **before** removal.
- line-`:1412` snapshot = entries present **after** removal.
- Difference = the windows `removeMissing` just evicted.

The loop at `:1413` walks the **pre**-removal list and keeps only those whose
token is **absent** from the **post**-removal set. That is a set-difference
designed to find "what did we just drop?" — it cannot be expressed with a
single snapshot.

---

## What the issue's suggested fix would break

The issue proposes:

```swift
let remainingTokens = Set(trackedEntries.map(\.token))   // reuse cached result
```

If applied here, `remainingTokens` would be the **pre**-removal token set, so
for every `entry` in `trackedEntries`, `remainingTokens.contains(entry.token)`
would be `true`, and the `where` clause
`!remainingTokens.contains(entry.token)` would be `false` for **all** entries.

Consequence: the cleanup loop body **never executes**, so on every full
rescan that evicts at least one window, nehir would fail to:

1. `controller.nativeFullscreenPlaceholderManager.remove(entry.token)` —
   leaked native-fullscreen placeholder slots.
2. `controller.axManager.removeWindowState(pid:windowId:)` — stale AX
   window-state cache entries for dead windows.
3. `controller.clearKeyboardFocusTarget(matching: entry.token)` — stale
   keyboard-focus targets pointing at removed windows.

This is a correctness regression, not a latency win. The issue's
"clear correctness (same data source, same function scope)" justification is
the incorrect premise: the two reads are the same *call* but observe
*different state* because of the mutation between them.

---

## What (if anything) is actually worth optimizing

The only genuine inefficiency on line 1412 is the transient `Array` work from
`allEntries().map(\.token)` before it is fed to `Set(_:)` when we only ever
need the token set:

```swift
// current
let remainingTokens = Set(controller.workspaceManager.allEntries().map(\.token))
//                  = Set( Array(entries.values).map(\.token) )   // 2 allocations
```

A `WorkspaceManager.remainingTokenSet()` (or `allTokens() -> Set<WindowToken>`)
that built the `Set` directly from `entries.keys`-equivalent storage would
drop the transient entry/map arrays and the `map` pass. This is:

- Optional, not blocking.
- A micro-optimization (full rescan is not a per-frame hot path; it runs on
  workspace switches, monitor reconnect, etc.).
- Strictly **not** what issue #394 describes or fixes.

The "500+ managed windows → 1000+ unnecessary lookups" framing in the issue
over-counts: there is exactly **one** extra `allEntries()` traversal (the
post-removal one), not redundant work proportional to window count beyond
that single pass.

---

## Recommendation

1. **Do not port the issue's suggested fix.** It is unsound for this code.
2. If a cleanup is desired, open a separate, scoped change that adds a
   token-set accessor to `WorkspaceManager` and uses it on line 1412 only.
   Leave line 1382 (`trackedEntries`) exactly as-is — it must remain a
   pre-removal snapshot.
3. Optionally reply on the upstream issue noting that the two calls straddle
   `removeMissing` and are intentionally distinct; the proposed reuse would
   skip per-entry teardown. (so this is a courtesy, not an obligation.)

---

## Reproduction / verification commands

Re-verify the claim before any code change:

```bash
# Confirm the two-call pattern and the mutation between them
rg -n 'allEntries\(\)|removeMissing' Sources/Nehir/Core/Controller/LayoutRefreshController.swift

# Confirm allEntries() is a fresh snapshot
rg -n 'func allEntries' Sources/Nehir/Core/Workspace/

# Confirm removeMissing mutates in place
rg -n 'func removeMissing|removeTrackedWindow|removeWindow\(key:' Sources/Nehir/Core/Workspace/
```

The defining evidence: `removeMissing` → `removeTrackedWindow` →
`windows.removeWindow(key:)` mutates the same `entries` dictionary that
`allEntries()` snapshots. As long as that holds, the two calls cannot be
collapsed.
