# M4 Stage 2 — Minimal Space topology eviction exemption — Discovery

Source upstream commit: [`2dcab36`](https://github.com/BarutSRB/OmniWM/commit/2dcab36) — "Exempt windows on known-inactive Spaces from miss-eviction" (0.4.9.9 line, behind "stops trying to manage windows that are hidden away on an inactive native Space").
Prerequisite: [`20260618-displays-separate-spaces-mode-detection.md`](20260618-displays-separate-spaces-mode-detection.md) (Stage 1).
Context: [`20260618-separate-spaces-and-monitor-arrangement.md`](20260618-separate-spaces-and-monitor-arrangement.md).

Scope: a minimal `SpaceTopology` value type + per-window Space lookup that exempts windows on known-inactive native Spaces from miss-eviction, concept-ported from upstream `2dcab36` but adapted to nehir's `confirmedMissingKeys`/`removeMissing` shape. Do **not** build upstream's full SpaceTracker/topology runtime.

---

## TL;DR

- **Nehir's full rescan enumerates visible/on-screen windows only** (`AXManager.fullRescanEnumerationSnapshot` at `:441` → `queryAllVisibleWindows()` + `CGWindowListCopyWindowInfo([.optionOnScreenOnly, ...])`). Under "Displays have separate Spaces" **ON**, a window on a native Space not frontmost on any display is in **neither** feed ⇒ never lands in `seenKeys` ⇒ `removeMissing` (`LayoutRefreshController.swift:1424`) marks it missing ⇒ evicted. When the user switches to that Space, the tiled layout is gone.
- **Verdict:** 🟡 Open / Applies (only under Separate Spaces ON). Land **after Stage 1** mode detection. Small, value-type topology consulted by the eviction path; a true no-op when mode is OFF/unavailable.
- **Product gate:** this only pays off if nehir intends to support macOS-Spaces coexistence. Under nehir's intended usage (one macOS Space per display, nehir workspaces), there are no inactive native Spaces, so this is robustness/UX-completeness, not a fix for a common repro. See the arrangement doc's product-mode discussion.

## Provenance: is this nehir's code?

Yes. The eviction path and its exemption seam exist:

- Eviction: `LayoutRefreshController.swift:1388-1440` builds `seenKeys` from the enumeration snapshot, exempts `nativeFullscreen`/`macosHiddenApp`/`failedPIDs`/scratchpad, then `WorkspaceManager.removeMissing` (`:2844`).
- Per-token miss counter: `WindowModel.confirmedMissingKeys` (`:737`) — already exempts `.nativeFullscreen` layoutReason; accepts `requiredConsecutiveMisses`.
- Rescan enumeration: `AXManager.swift:441` (on-screen-only) — the root cause.
- Partial Space helper exists: `SkyLight.displayId(forSpaceId:among:)` (`:365`). Missing: per-window Space lookup, topology model, inactive-Space exemption.

## The code in question

### The eviction decision

```swift
// Sources/Nehir/Core/Workspace/WindowModel.swift:737
func confirmedMissingKeys(keys activeKeys: Set<WindowKey>, requiredConsecutiveMisses: Int = 1) -> [WindowKey] {
    let threshold = max(1, requiredConsecutiveMisses)
    ...
    let misses = (missingDetectionCountByToken[token] ?? 0) + 1
    if misses >= threshold { confirmedMissing.append(token) }
```

Upstream `2dcab36` adds a `spaceTopology` parameter here and resets the miss counter for windows `isWindowOnKnownInactiveSpace(windowId)`. Nehir's equivalent is to thread a topology value into this function (or its caller) and skip the increment for inactive-Space windows.

## Recommendation

1. **Resolve `SLSCopySpacesForWindows` in SkyLight** (`SkyLight.swift`): `CopySpacesForWindowsFunc = @convention(c) (Int32, CFArray, UInt32) -> CFArray?`; `resolveOptional` in `init`. Add `func spaceIds(forWindowIds:) -> [UInt32: [UInt64]]` (per window id, the list of Spaces it belongs to — a window can be on multiple; return `[:]` when the symbol is missing/connection invalid/empty). Reuse the existing `space(_:hasId:)`/`numericUInt64` helpers. Add `func currentSpaceIdsByDisplayId(monitors:) -> [CGDirectDisplayID: UInt64]`. Test hook `@MainActor static var copySpacesForWindowsOverrideForTests`.

2. **New `Sources/Nehir/Core/SkyLight/SpaceTopology.swift`:**
```swift
struct SpaceTopology: Equatable, Sendable {
    let activeSpaceIdsByDisplayId: [CGDirectDisplayID: UInt64]
    let spaceIdsByWindowId: [UInt32: [UInt64]]
    let mode: DisplaySpacesMode
    var isEmpty: Bool { mode != .enabled || activeSpaceIdsByDisplayId.isEmpty }
    func isWindowOnKnownInactiveSpace(windowId: UInt32) -> Bool
    static func current(monitors: [Monitor]) -> SpaceTopology
    static let empty: SpaceTopology
}
```
   `isWindowOnKnownInactiveSpace` returns `false` when `isEmpty`; otherwise `true` iff the window has ≥1 recorded Space **and none** of them appear in `activeSpaceIdsByDisplayId.values`. Not a long-lived cached object — build per full-rescan, pass by value. Do not model Space names/history/transitions.

3. **Plumb topology into the eviction exemption** (`LayoutRefreshController.swift` ~`:1396-1428`): compute `let topology = topologyProvider(controller.workspaceManager.monitors)` (`topologyProvider` defaults to `SpaceTopology.current(monitors:)`, overridable for tests). Add a loop that inserts inactive-Space tracked entries into `seenKeys`:
```swift
for entry in trackedEntries where topology.isWindowOnKnownInactiveSpace(windowId: UInt32(entry.windowId)) {
    seenKeys.insert(.init(pid: entry.handle.pid, windowId: entry.windowId))
}
```
   Emit a `spaceTopology.exempt windowId=…` trace.

4. **Guard with Stage 1 mode:** `SpaceTopology.current(monitors:)` returns `.empty` when `displaySpacesMode() != .enabled`. Stage 2 is a **true no-op** in the common (Separate Spaces OFF) case — the load-bearing guard.

5. **Expose in runtime dump:** a compact `-- SpaceTopology --` block (mode, active-space count, recorded-window count) in `WMController.runtimeStateDebugDump`; do not dump the full window map.

## Suggested tests

- `Tests/NehirTests/SpaceTopologyTests.swift` — `isWindowOnKnownInactiveSpace`: `false` for `.empty` and no-recorded-spaces; `true` for a window whose only space is inactive; `false` when ≥1 space is active.
- `Tests/NehirTests/SpaceTopologyEvictionTests.swift` (or extend `LayoutRefreshControllerTests`) — using `fullRescanEnumerationOverrideForTests` + `topologyProviderForTests`: a tracked window absent from enumeration but present in topology as inactive-Space survives `removeMissing`; a tracked window absent from both is evicted (regression). Mode-guard test: with `displaySpacesModeOverrideForTests = { .disabled }`, topology is empty and no exemption applies.
- Existing eviction tests (`OptimizationCompletionTests`, `WorkspaceManagerTests`) stay green unchanged — the OFF path is a no-op.

## Suggested validation

```bash
swift build
swift test --filter SpaceTopology
swift test --filter LayoutRefreshController
swift test --filter WorkspaceManagerTests
swift test --filter OptimizationCompletionTests
# Manual: on a Separate-Spaces-ON host with two displays, park a managed window on a
# non-active Space (Mission Control), trigger a full rescan, confirm it is not evicted;
# check the runtime dump shows the topology block and the spaceTopology.exempt trace.
```

## Risks

- **`SLSCopySpacesForWindows` result shape** varies by macOS version. Parse defensively; treat any unparseable entry as "no spaces recorded" (i.e. **not** exempt), preserving safe current behavior.
- **False-positive exemptions** (a genuinely-gone window retained forever). Mitigation: only mark inactive when the window has a **non-empty** recorded Space list; if the lookup returns nothing for a window id, do **not** exempt. Consider a max-consecutive-exemption counter as a follow-up safety net (defer).
- **Performance** — `SLSCopySpacesForWindows` per tracked window per rescan could be expensive. Mitigation: **batch** the call (single call with the full window-id array) and only when `mode == .enabled`; skip entirely otherwise.
- **Interaction with existing exemptions** — the new loop runs alongside `nativeFullscreen`/`macosHiddenApp`/`failedPIDs`/scratchpad; ensure no double-counting/trace spam; document ordering.
- **Separate Spaces OFF never hits this path** — the mode guard is load-bearing; add an explicit regression test asserting no exemption under `.disabled`.

## Open questions

1. **Where to compute topology** — inside `AXManager.fullRescanEnumerationSnapshot` (travels with the snapshot) or as a separate call in `LayoutRefreshController`? Recommendation: separate call in `LayoutRefreshController` (it already has `workspaceManager.monitors` and the tracked-window list; keeps `AXManager` focused on AX enumeration).
2. **Consecutive-miss safety net** — cap how many rescans a window can be exempted for? Recommendation: ship without a cap; add only if manual testing shows stale retention. (Composes with P1's `2`-miss threshold.)
3. **Per-window Space refresh cadence** — per-full-rescan, or event-driven on `CGSEventType.spaceWindowCreated`/`spaceWindowDestroyed`? Recommendation: per-full-rescan for Stage 2; event-driven refresh is Stage 3.
4. **Cross-monitor mouse warp** — once topology exists, should `shouldUseMouseWarp` consult it (Stage 3 precursor)? Out of scope for Stage 2; flag for follow-up.

## Relationship to other clusters

- Depends on **Stage 1** mode detection (the load-bearing OFF no-op guard).
- Composes with **P1** (two-miss hysteresis): both reduce spurious eviction from different angles.
- This is the **only** piece of upstream's Spaces work that has value under nehir's "one macOS Space per display" intended usage **if** nehir also wants to tolerate macOS-Spaces coexistence; otherwise it is a robustness nice-to-have.
