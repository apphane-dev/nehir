# Displays-have-separate-Spaces vs vertical monitor arrangement — Discovery

Discovery date: 2026-06-18.

Scope: clarify whether upstream's "Displays have separate Spaces" work addresses the same real-world artifact as nehir's vertical-monitor-arrangement recommendation, and what nehir should do by macOS Space mode.

Related:

- `docs/window-parking-and-offscreen-clamp.md`
- `docs/CONFIGURATION.md` display-arrangement recommendation
- upstream commits `de971b6`, `ee554c7`, `2dcab36`
- minor candidate M4 in `20260618-upstream-port-minor-candidates.md`

## TL;DR

- Nehir's current vertical-arrangement recommendation solves a **shared-desktop parking bleed** problem: when displays are side-by-side and macOS Spaces are shared, parked/clamped windows near one display's connected horizontal edge can render on the neighboring display.
- Maintainer manual test found a key distinction: with **Displays have separate Spaces ON**, horizontally arranged displays did **not** show the parked-window bleed on the second display while WM was disabled and parked windows still existed.
- Therefore the previous framing "Space topology is orthogonal to the vertical-arrangement recommendation" is incomplete. The rescan/eviction problem is still different, but Separate Spaces appears to also change the **rendering boundary** between displays, which can remove the visible bleed reason for the vertical-arrangement recommendation.
- Latest upstream OmniWM can manage windows on both displays in Separate Spaces mode. Nehir currently jumps/loops in that mode, likely because it has only partial read-only Spaces helpers and no runtime mode/topology model.
- Recommended product split:
  - **Separate Spaces OFF**: keep current vertical-arrangement diagnostic; allow nehir-controlled mouse warp.
  - **Separate Spaces ON**: recommend matching macOS arrangement to real physical layout; rely on system mouse movement/warp unless/until nehir is topology-aware; suppress or reword the vertical-arrangement warning.

## Current nehir behavior and evidence

### Vertical arrangement recommendation

`docs/CONFIGURATION.md:199` says:

> Arrange displays **vertically** in macOS System Settings (`Displays > Arrange`) instead of side-by-side horizontally. Nehir parks transient offscreen tiled windows near the horizontal screen edge. With side-by-side monitors, those parked windows can bleed into the neighboring display because macOS does not allow fully hiding external app windows by position alone. A vertical monitor arrangement keeps the horizontal parking edges away from adjacent displays and avoids the most visible bleed artifacts.

`docs/window-parking-and-offscreen-clamp.md` confirms the mechanism:

- macOS clamps horizontal and vertical offscreen positions for external app windows;
- workspace-inactive/transient parking is not true hiding;
- side-by-side displays put another display next to the horizontal parking edge;
- vertical arrangement avoids the most visible cross-monitor bleed.

### Nehir's Space support today

Nehir has a partial read-only managed-Spaces helper:

- `Sources/Nehir/Core/SkyLight/SkyLight.swift:365` — `displayId(forSpaceId:among:)` uses `copyManagedDisplaySpaces`.

Nehir does **not** currently have the runtime pieces introduced upstream:

- no `SLSGetSpaceManagementMode` / `displaysHaveSeparateSpaces` mode detection;
- no `SLSCopySpacesForWindows` per-window Space lookup;
- no `SpaceTopology` model;
- no `isWindowOnKnownInactiveSpace` eviction exemption.

Nehir's full rescan is visible/on-screen based:

- `Sources/Nehir/Core/Ax/AXManager.swift:450` uses `SkyLight.shared.queryAllVisibleWindows()`;
- `Sources/Nehir/Core/Ax/AXManager.swift:456-458` uses `CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], ...)`;
- `Sources/Nehir/Core/Controller/LayoutRefreshController.swift:1424` removes missing windows based on the resulting `seenKeys`.

This means nehir can still mis-handle windows hidden by inactive native Spaces, even if Separate Spaces fixes visible bleed.

## Two distinct mechanisms that interact

### 1. Parking bleed / geometry mechanism

This is the reason for nehir's current vertical-arrangement diagnostic.

```text
Shared desktop coordinate plane
+ side-by-side displays
+ nehir parks hidden window near connected horizontal edge
+ macOS clamps offscreen move
= visible strip can appear on neighbor display
```

Separate Spaces ON appears to isolate per-display rendering surfaces enough that this visible strip does not cross to the neighboring display in the maintainer's manual test.

### 2. Inactive native Space / lifecycle mechanism

This is upstream's topology/eviction hardening.

```text
Window belongs to native Space not visible on any display
+ rescan enumerates visible/on-screen windows only
+ window omitted from seenKeys
+ missing counter increments
= nehir may evict a still-valid window
```

Separate Spaces ON makes this mechanism relevant because displays have independent active Spaces. Vertical arrangement does not help with this lifecycle problem.

## Product-mode implications

### Separate Spaces OFF

This is the current nehir-friendly mode:

- shared desktop coordinate plane;
- vertical arrangement remains the practical workaround for parking bleed;
- nehir-controlled cross-monitor mouse warp can remain enabled/diagnosed as today;
- nehir does not need native Space topology for normal operation.

Recommended diagnostics:

- Keep warning for side-by-side horizontal display arrangement.
- Keep auto-hide Dock / fixed Dock clamp-strip warnings.
- Keep current mouse-warp recommendations.

### Separate Spaces ON

This is a different runtime mode:

- display surfaces appear isolated enough to avoid cross-display parking bleed in horizontal arrangement;
- macOS's real arrangement should match physical layout so system movement and focus make sense;
- nehir's current assumptions about visible/on-screen enumeration and monitor/focus routing may break;
- nehir-controlled mouse warp may fight or mispredict system behavior.

Recommended diagnostics until runtime support exists:

- Do **not** warn that horizontal arrangement is bad solely because of parked-window bleed.
- Instead warn that Separate Spaces support is experimental/incomplete in nehir.
- Recommend real physical arrangement.
- Recommend relying on system mouse movement/warp, or disable nehir's aggressive cross-monitor warp behavior by default in this mode.

## Upstream behavior to consider

Upstream `ee554c7` did more than detect the setting:

- it required Separate Spaces for runtime startup;
- it refreshed per-display active Space topology;
- it avoided managing windows hidden by inactive native Spaces.

Nehir does not need to copy the hard startup requirement immediately. A softer staged approach better fits current product uncertainty.

## Recommendation

### Stage 1 — Diagnostics/mode detection only

Add read-only mode detection:

```swift
enum DisplaySpacesMode {
    case enabled
    case disabled
    case unavailable
}
```

Use upstream's `SLSGetSpaceManagementMode` approach or equivalent.

Then branch diagnostics:

| Mode | Arrangement diagnostic | Mouse-warp diagnostic |
| --- | --- | --- |
| Separate Spaces OFF | preserve current vertical recommendation | allow current nehir mouse warp |
| Separate Spaces ON | recommend physical arrangement; no bleed-based vertical warning | recommend system movement/warp; flag nehir topology limitations |
| unavailable | keep current conservative warnings | keep current behavior |

### Stage 2 — Minimal topology hardening

If nehir wants to support Separate Spaces ON beyond diagnostics:

- add per-window Space lookup via `SLSCopySpacesForWindows`;
- add a small `SpaceTopology` equivalent;
- pass topology into missing-window detection;
- exempt windows on known-inactive Spaces from miss eviction.

This is the direct concept of upstream `2dcab36` but should be adapted to nehir's current `WindowModel.confirmedMissingKeys` / `WorkspaceManager.removeMissing` shape.

### Stage 3 — Runtime policy

Only after Stage 2 should nehir decide whether to:

- officially support Separate Spaces ON;
- hard-require it;
- or keep it supported-but-diagnostic.

Current evidence supports diagnostics first, not a startup gate.

## Subagent handoff: Separate Spaces diagnostics

Task:

> Implement Stage 1 from `discovery/20260618-separate-spaces-and-monitor-arrangement.md`: add read-only detection of macOS Displays-have-separate-Spaces mode, expose it in diagnostics, and adjust monitor-arrangement/mouse-warp guidance by mode. Do not add a startup requirement.

Acceptance:

- New code can report `.enabled`, `.disabled`, or `.unavailable`.
- Diagnostics distinguish Separate Spaces OFF vs ON.
- OFF preserves current vertical-arrangement recommendation.
- ON recommends physical arrangement and explains nehir Space-topology limitations; no bleed-based vertical warning.
- No behavior change to layout/eviction yet, unless explicitly behind a diagnostic/prototype flag.

## Subagent handoff: Minimal SpaceTopology hardening

Task:

> Prototype Stage 2 from `discovery/20260618-separate-spaces-and-monitor-arrangement.md`: add per-window Space lookup and a minimal topology object sufficient to exempt known-inactive-Space windows from miss eviction. Keep the implementation small and independent from upstream WorldStore.

Acceptance:

- Per-window Space candidates can be queried or return empty safely.
- Topology records known active/current Spaces and window Space membership.
- `confirmedMissingKeys` or its caller can reset miss counters for known-inactive-Space windows.
- Tests cover a window omitted from visible `seenKeys` but preserved because topology marks it inactive, and a truly missing window still evicted.
