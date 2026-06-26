# M4 Stage 2 — Minimal Space topology eviction exemption

**Status:** completed — shipped on `main` in `4ae5fc96` ("Exempt managed windows on inactive native Spaces from full-rescan eviction"). Adds the per-rescan `SpaceTopology` value consulted only in the full-rescan eviction path so a managed window parked on an inactive native Space resets its miss counter instead of being evicted by `WorkspaceManager.removeMissing`; guarded by Separate-Spaces mode (no-op when disabled/unavailable); a compact last-topology summary is surfaced via the runtime debug dump. The deliberately-omitted max-exemption counter is an accepted residual risk and follow-up (see "Risks and mitigations" / "Follow-ups (out of scope)"). Moved from `planned/` to `completed/` on 2026-06-26.
**Source discovery:** `discovery/20260618-space-topology-eviction-exemption.md`
**Prerequisite:** `completed/20260619-m4s1-displays-separate-spaces-detection.md` (`main` includes `DisplaySpacesMode`)
**Upstream reference:** `BarutSRB/OmniWM@2dcab36` plus the v0.4.9.9 `SpaceTopology`/`SkyLight.spacesForWindow` shape

All source references were re-verified against the main Nehir source tree on
2026-06-19. Re-verify before editing; line numbers drift.

## TL;DR

Full rescans only enumerate visible/on-screen windows. With macOS **Displays have
separate Spaces** enabled, a managed window parked on a native Space that is not
current on any display disappears from both the AX visible-window feed and the
on-screen `CGWindowList` fallback. Today that window is treated as missing and is
removed by `WorkspaceManager.removeMissing(... requiredConsecutiveMisses: 2)`.

Implement a small per-rescan `SpaceTopology` value and consult it only in the
full-rescan eviction path. If Separate Spaces is disabled/unavailable, or if
SkyLight cannot prove a tracked window's native Space membership, behavior is
unchanged. If a tracked window has a non-empty native Space list and all known
candidate Spaces are inactive, insert its token into `seenKeys` before
`removeMissing` so its miss counter resets instead of evicting it.

This is **not** upstream's full `SpaceTracker`; no event-driven topology cache,
no native-fullscreen reconciliation, and no startup requirement.

## Discovery corrections / decisions

The discovery recommendation remains right at the product level, but make these
implementation corrections while porting:

1. Use the upstream-observed `SLSCopySpacesForWindows` signature:
   `@convention(c) (Int32, Int32, CFArray) -> CFArray?`, with an all-Spaces mask
   (`0x7`). The earlier `(Int32, CFArray, UInt32)` sketch should be treated as
   tentative.
2. `SLSCopySpacesForWindows` returns Space ids for the supplied windows without a
   stable window-id association in the result shape used upstream. For the minimal
   safe port, query per tracked window when Separate Spaces is enabled rather than
   pretending a batch result can be mapped back to windows. Keep this behind the
   mode guard; optimize later only if manual profiling shows it matters.
3. `SpaceTopology.current` must receive the tracked window ids. The useful
   signature is `current(monitors:windowIds:)`, not `current(monitors:)`.
4. Keep the exemption in `LayoutRefreshController` by adding entries to
   `seenKeys`. Do **not** change `WindowModel.confirmedMissingKeys` for this
   port; Nehir's existing controller-level exemption seam is clearer and resets
   the miss counter naturally.

## Scope

### Files to add/change

1. `Sources/Nehir/Core/SkyLight/SkyLight.swift`
   - Resolve optional `SLSCopySpacesForWindows` / `CGSCopySpacesForWindows`.
   - Add read-only helpers for current managed Spaces and per-window Space ids.
2. `Sources/Nehir/Core/SkyLight/SpaceTopology.swift` (new)
   - Small value type: active Spaces by display, known Space ids, per-window Space
     candidates, mode, summary helpers, inactive-Space predicate.
3. `Sources/Nehir/Core/Controller/LayoutRefreshController.swift`
   - Build topology during full rescan from the tracked window ids.
   - Exempt tracked entries on known inactive native Spaces by inserting them into
     `seenKeys` before `removeMissing`.
   - Add a test-only topology provider and a compact last-topology debug summary.
4. `Sources/Nehir/Core/Controller/WMController.swift`
   - Add a `-- SpaceTopology --` block to `runtimeStateDebugDump` using the
     compact summary stored by `LayoutRefreshController`.
5. Tests under `Tests/NehirTests/`.

### Non-goals

- Do **not** implement upstream `SpaceTracker` or event-driven Space refresh.
- Do **not** model Space names/history/transitions.
- Do **not** use Space topology to change mouse warp, focus routing, or monitor
  navigation.
- Do **not** change Stage 1 diagnostics/product copy.
- Do **not** exempt windows when mode is `.disabled`/`.unavailable`, when the
  Space lookup symbol is missing, or when a window has no parseable Space ids.

## Exact implementation plan

### 1. SkyLight: Space lookup helpers

In `SkyLight.swift`:

- Add typealias + optional storage near the existing managed-Spaces/mode symbols:

```swift
private typealias CopySpacesForWindowsFunc = @convention(c) (Int32, Int32, CFArray) -> CFArray?
private static let allSpacesMask: Int32 = 0x7
private let copySpacesForWindows: CopySpacesForWindowsFunc?
@MainActor static var spacesForWindowOverrideForTests: ((UInt32) -> [UInt64])?
```

- Resolve it in `init` after `copyManagedDisplaySpaces`:

```swift
copySpacesForWindows = resolveOptional("SLSCopySpacesForWindows", as: CopySpacesForWindowsFunc.self)
    ?? resolveOptional("CGSCopySpacesForWindows", as: CopySpacesForWindowsFunc.self)
```

- Add `spacesForWindow(_:) -> [UInt64]`:

```swift
func spacesForWindow(_ windowId: UInt32) -> [UInt64] {
    if let override = Self.spacesForWindowOverrideForTests { return override(windowId) }
    guard let copySpacesForWindows else { return [] }
    let cid = getMainConnectionID()
    guard cid != 0 else { return [] }
    var widValue = Int32(bitPattern: windowId)
    guard let widNumber = CFNumberCreate(nil, .sInt32Type, &widValue) else { return [] }
    defer { cfRelease(widNumber) }
    guard let result = copySpacesForWindows(cid, Self.allSpacesMask, [widNumber] as CFArray) else { return [] }
    defer { cfRelease(result) }
    guard let values = result as? [Any] else { return [] }
    return values.compactMap(Self.numericUInt64).filter { $0 != 0 }
}
```

- Add a managed-space snapshot helper used by `SpaceTopology.current`:

```swift
struct ManagedDisplaySpacesSnapshot: Sendable, Equatable {
    let displayId: CGDirectDisplayID
    let spaceIds: [UInt64]
    let currentSpaceId: UInt64
}

func managedDisplaySpaces(monitors: [Monitor]) -> [ManagedDisplaySpacesSnapshot]
```

Implementation notes:
- Reuse `copyManagedDisplaySpaces`, `managedDisplayIdentifierMap(for:)`, and the
  existing `numericUInt64` helper.
- Add `private static func spaceId(_ space: [String: Any]) -> UInt64?` returning
  `id64 ?? ManagedSpaceID ?? id`.
- Parse `"Spaces"` for all known ids and `"Current Space"` for the active id.
- If any symbol/result is missing or unparseable, return an empty array.

### 2. New `SpaceTopology` value type

Create `Sources/Nehir/Core/SkyLight/SpaceTopology.swift`:

```swift
import CoreGraphics
import Foundation

struct SpaceTopology: Equatable, Sendable {
    let mode: DisplaySpacesMode
    let activeSpaceIdsByDisplayId: [CGDirectDisplayID: UInt64]
    let knownSpaceIds: Set<UInt64>
    let spaceIdsByWindowId: [UInt32: [UInt64]]

    static let empty = SpaceTopology(mode: .unavailable)

    init(
        mode: DisplaySpacesMode,
        activeSpaceIdsByDisplayId: [CGDirectDisplayID: UInt64] = [:],
        knownSpaceIds: Set<UInt64> = [],
        spaceIdsByWindowId: [UInt32: [UInt64]] = [:]
    ) { ... }

    var isEnabledAndPopulated: Bool {
        mode == .enabled && !activeSpaceIdsByDisplayId.isEmpty && !knownSpaceIds.isEmpty
    }

    func isWindowOnKnownInactiveSpace(windowId: UInt32) -> Bool { ... }

    static func current(monitors: [Monitor], windowIds: [UInt32]) -> SpaceTopology { ... }

    var debugSummary: String { ... }
}
```

Predicate semantics:

```swift
func isWindowOnKnownInactiveSpace(windowId: UInt32) -> Bool {
    guard isEnabledAndPopulated,
          let candidates = spaceIdsByWindowId[windowId],
          !candidates.isEmpty
    else { return false }

    let activeIds = Set(activeSpaceIdsByDisplayId.values)
    if candidates.contains(where: activeIds.contains) { return false }

    let knownCandidates = candidates.filter(knownSpaceIds.contains)
    return !knownCandidates.isEmpty
}
```

`current(monitors:windowIds:)`:

1. `let mode = SkyLight.shared.displaySpacesMode(monitors: monitors)`.
2. If `mode != .enabled`, return `SpaceTopology(mode: mode)`.
3. Read `managedDisplaySpaces(monitors:)`; build:
   - `activeSpaceIdsByDisplayId` from non-zero `currentSpaceId`.
   - `knownSpaceIds` from every `spaceIds` plus every non-zero current id.
4. If active/known sets are empty, return a non-exempting topology with the mode
   preserved.
5. For each distinct, positive tracked window id, call `spacesForWindow(_:)` and
   store only non-empty results.

### 3. Full-rescan eviction exemption

In `LayoutRefreshController.swift`, add a provider seam near the debug hooks:

```swift
var spaceTopologyProviderForTests: (([Monitor], [UInt32]) -> SpaceTopology)?
private var lastSpaceTopologyDebugSummary = "notCaptured"

private func currentSpaceTopology(monitors: [Monitor], trackedEntries: [WindowModel.Entry]) -> SpaceTopology {
    let windowIds = trackedEntries.compactMap { UInt32(exactly: $0.windowId) }
    if let provider = spaceTopologyProviderForTests { return provider(monitors, windowIds) }
    return SpaceTopology.current(monitors: monitors, windowIds: windowIds)
}

func spaceTopologyDebugDump() -> String {
    lastSpaceTopologyDebugSummary
}
```

In the full-rescan path around the existing `trackedEntries` / exemption block
(verified current flow: collect `trackedEntries`, preserve native-fullscreen and
hidden-app entries, preserve failed-PID entries, preserve scratchpad, then
`removeMissing`):

```swift
let trackedEntries = controller.workspaceManager.allEntries()
let spaceTopology = currentSpaceTopology(
    monitors: controller.workspaceManager.monitors,
    trackedEntries: trackedEntries
)
lastSpaceTopologyDebugSummary = spaceTopology.debugSummary
```

Then, in the non-native-fullscreen-preservation branch before `removeMissing`:

```swift
var inactiveSpaceExemptions = 0
for entry in trackedEntries {
    guard let windowId = UInt32(exactly: entry.windowId),
          spaceTopology.isWindowOnKnownInactiveSpace(windowId: windowId)
    else { continue }
    seenKeys.insert(.init(pid: entry.handle.pid, windowId: entry.windowId))
    inactiveSpaceExemptions += 1
    controller.recordRuntimeInsertionTrace(
        "spaceTopology.exempt windowId=\(entry.windowId) pid=\(entry.handle.pid) mode=\(spaceTopology.mode.rawValue)"
    )
}
if inactiveSpaceExemptions > 0 {
    lastSpaceTopologyDebugSummary += " exempted=\(inactiveSpaceExemptions)"
}
```

Ordering: run this alongside the existing hidden-app/native-fullscreen/failed-PID
and scratchpad exemptions before `removeMissing`. It is okay if the same token is
inserted more than once into `seenKeys`; the set deduplicates.

### 4. Runtime dump

In `WMController.runtimeStateDebugDump`, add a compact block after Monitor
Topology or before WorkspaceManager:

```swift
"-- SpaceTopology --",
layoutRefreshController.spaceTopologyDebugDump(),
```

The block must be compact and durable, for example:

```text
mode=enabled activeSpaces=2 knownSpaces=6 windowRecords=4 exempted=1
```

Do not dump the full per-window map by default.

## Tests

### `Tests/NehirTests/SpaceTopologyTests.swift` (new)

Use synthetic values only; no live SkyLight dependency.

1. `emptyTopologyNeverExempts` — `.disabled`, `.unavailable`, and empty `.enabled`
   topologies return `false`.
2. `inactiveKnownSpaceExempts` — active `{display: 10}`, known `{10, 20}`, window
   `100 -> [20]` returns `true`.
3. `activeCandidateDoesNotExempt` — window `101 -> [10]` returns `false`.
4. `mixedActiveAndInactiveDoesNotExempt` — window `102 -> [10, 20]` returns
   `false` (a window visible on any active Space must not be preserved by this
   exemption).
5. `unknownCandidateDoesNotExempt` — known `{10}`, window `103 -> [999]` returns
   `false`.
6. `debugSummaryIsCompact` — summary includes mode/counts and not raw window ids.

### `RefreshRoutingTests` / `LayoutRefreshController` coverage

Add tests near the existing full-rescan miss/exemption tests:

1. `fullRescanPreservesWindowOnKnownInactiveNativeSpace`
   - Full-rescan enumeration returns no windows.
   - Add a tracked window.
   - `spaceTopologyProviderForTests` returns `.enabled`, active `{main: 10}`,
     known `{10, 20}`, window map `[tracked: [20]]`.
   - Run two full rescans.
   - Expect the entry still exists (miss counter reset on each rescan).

2. `fullRescanStillEvictsMissingWindowWithoutSpaceRecord`
   - Same empty enumeration.
   - Topology has no record for the tracked window.
   - Run two full rescans.
   - Expect the entry is removed (P1 hysteresis still works).

3. `fullRescanDoesNotExemptWhenSeparateSpacesDisabled`
   - Provider returns `SpaceTopology(mode: .disabled, activeSpaceIdsByDisplayId: ..., knownSpaceIds: ..., spaceIdsByWindowId: ...)`.
   - Run two full rescans.
   - Expect removal.

4. `fullRescanDoesNotExemptWindowOnActiveSpace`
   - Provider returns window map `[tracked: [activeSpaceId]]`.
   - Run two full rescans.
   - Expect removal.

5. Optional runtime-dump check after one rescan:
   - Assert `runtimeStateDebugDump()` contains `-- SpaceTopology --` and a compact
     summary line.

Test hygiene:
- Reset `spaceTopologyProviderForTests` in `defer` or `cleanupRefreshTestController`.
- Reset `SkyLight.spacesForWindowOverrideForTests` if any test exercises
  `SpaceTopology.current` directly.
- Keep existing `WorkspaceManagerTests.removeMissing...` unchanged; the
  controller-level `seenKeys` exemption should not require changing
  `WindowModel` tests.

## Validation

```bash
swift build
swift test --filter SpaceTopology
swift test --filter RefreshRoutingTests
swift test --filter WorkspaceManagerTests
swift test --filter OptimizationCompletionTests
```

Manual validation on a host with Displays-have-separate-Spaces enabled:

1. Place a managed Nehir window on a native Space that is not current on any
   display.
2. Trigger a full rescan.
3. Confirm the managed entry/layout survives after repeated rescans.
4. Switch to that native Space and confirm the window still belongs to its Nehir
   workspace/layout.
5. Capture a runtime dump and confirm the compact `-- SpaceTopology --` block
   shows enabled mode plus non-zero active/known/window counts; with runtime trace
   capture active, confirm a `spaceTopology.exempt windowId=...` event appears.

Changeset (minor or patch; confirm release policy): "Preserve managed windows
hidden on inactive native Spaces during full rescans."

## Risks and mitigations

- **Private API shape drift:** `SLSCopySpacesForWindows` may be missing or return
  a different result shape on some macOS versions. Treat failures as no Space
  record, which means no exemption and current behavior.
- **False-positive retention:** Only exempt if the window has at least one known
  native Space id and no active Space id. Unknown ids do not exempt.
- **Performance:** Per-window SkyLight lookup runs only when Separate Spaces is
  `.enabled` and only during full rescans. If profiling shows cost, investigate a
  batchable result shape later.
- **Stale windows retained forever:** The current minimal port intentionally has
  no max-exemption counter. If manual testing finds stale retention, add a
  follow-up cap (for example, consecutive topology exemptions before allowing
  normal miss eviction).
- **Mode guard is load-bearing:** Add explicit disabled/unavailable tests. The
  common Separate-Spaces-OFF path must remain a true no-op.
- **Debug dump side effects:** Runtime dumps should report the last observed
  topology summary, not perform fresh private-SkyLight queries.

## Follow-ups (out of scope)

- Event-driven `SpaceTracker` driven by Space/window events.
- Native-fullscreen reconciliation using Space topology.
- Mouse-warp/topology integration.
- A stale-retention safety cap if field testing shows windows can remain after
  genuine destruction while carrying an inactive-Space record.
