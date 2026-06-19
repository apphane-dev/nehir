# M4 Stage 1 — Displays-have-separate-Spaces mode detection & diagnostics — Discovery

Source upstream commits: [`de971b6`](https://github.com/BarutSRB/OmniWM/commit/de971b6) (read-only Spaces queries to SkyLight), [`ee554c7`](https://github.com/BarutSRB/OmniWM/commit/ee554c7) (support/require Displays have separate Spaces).
Context: [`20260618-separate-spaces-and-monitor-arrangement.md`](20260618-separate-spaces-and-monitor-arrangement.md) (analysis + maintainer manual-test findings + the OFF/ON product split).
Stage 2 companion: [`20260618-space-topology-eviction-exemption.md`](20260618-space-topology-eviction-exemption.md).

Scope: **diagnostics and mode detection only — no layout/eviction behavior change, no startup requirement.** Determine whether nehir can detect the macOS setting and adjust guidance by mode.

---

## TL;DR

- **Nehir cannot today tell whether "Displays have separate Spaces" is on.** It has a partial read-only managed-Spaces helper (`SkyLight.displayId(forSpaceId:among:)` at `:365`, using `copyManagedDisplaySpaces`) but **no** `SLSGetSpaceManagementMode`/mode detection, no per-window Space lookup, no topology model.
- **Why it matters (from the maintainer manual test):** with Separate Spaces **OFF**, side-by-side displays exhibit parked-window bleed at the connected edge (the reason for nehir's vertical-arrangement recommendation). With Separate Spaces **ON**, display surfaces appear isolated and that bleed did **not** occur in horizontal arrangement — so the vertical warning is misleading in that mode. But nehir currently loops/jumps under Separate Spaces ON because it has no topology/runtime mode awareness.
- **Verdict:** 🟡 Open / Applies. Deliver **mode detection + mode-aware diagnostics + advisory mouse-warp copy**. Do **not** auto-disable mouse warp or gate startup in Stage 1. Behavior change is diagnostics-only.

## Provenance: is this nehir's code?

Yes. The diagnostics surface, the SkyLight loader, and the mouse-warp policy all exist:

- `Sources/Nehir/Core/Monitor/DisplayEnvironmentDiagnostics.swift` — emits `.fixedDock` and `.horizontalDisplayArrangement` issues (enum `Kind` at `:6`); mode-agnostic `evaluate(monitors:)` (`:84`) and `current()` (`:80`). Consumers: `DisplayDiagnosticsSettingsTab.swift`, `SettingsSidebar.swift:59` (badge), `StatusBarMenu.swift:145`, `WorkspaceBarManager.swift:438`.
- `Sources/Nehir/Core/SkyLight/SkyLight.swift` — resolves `copyManagedDisplaySpaces`/`CGSCopyManagedDisplaySpaces` and parses `Display Identifier`/`Current Space`/`Spaces[id64|ManagedSpaceID|id]`. **No** `SLSGetSpaceManagementMode`, **no** `SLSCopySpacesForWindows`. Has a `orderedStateProviderForTests` injection hook.
- Mouse-warp policy: `WMController.shouldUseMouseWarp` (`:722-749`) only checks `monitors.count > 1`; `MouseWarpHandler.swift` is the active tap.

## The product-mode split (from the maintainer manual test)

| Mode | Arrangement diagnostic | Mouse-warp guidance |
| --- | --- | --- |
| Separate Spaces **OFF** | preserve current side-by-side vertical-arrangement warning | allow current nehir mouse warp |
| Separate Spaces **ON** | suppress the bleed-based warning; recommend matching physical arrangement; warn nehir's Space support is experimental | advisory: rely on system cursor movement; flag nehir's warp as not Space-aware |
| unavailable | keep current conservative warnings | keep current behavior |

This is documented and motivated in `20260618-separate-spaces-and-monitor-arrangement.md`.

## Recommendation

1. **Resolve `SLSGetSpaceManagementMode` in SkyLight** (`SkyLight.swift`): add `SpaceManagementModeFunc = @convention(c) (Int32) -> Int32`; `resolveOptional` in `init` (not required for startup — do **not** add to `missingRequiredSymbols`); store `private let getSpaceManagementMode: SpaceManagementModeFunc?`.
2. **New `Sources/Nehir/Core/SkyLight/DisplaySpacesMode.swift`:**
   - `enum DisplaySpacesMode: String, Sendable, Equatable { case enabled, disabled, unavailable }`.
   - `SkyLight.shared.displaySpacesMode()` — primary: `getSpaceManagementMode` present ⇒ `.enabled` if result `!= 0`, `.disabled` if `== 0`. Fallback (symbol nil): inspect `copyManagedDisplaySpaces` shape — single `"Main"` entry + >1 display ⇒ `.disabled`; one entry per display identifier ⇒ `.enabled`; indeterminate ⇒ `.unavailable`. Factor the existing display-identifier mapping helper from `displayId(forSpaceId:among:)`.
   - `@MainActor static var displaySpacesModeOverrideForTests: (() -> DisplaySpacesMode)?` mirroring `orderedStateProviderForTests`.
3. **Make `DisplayEnvironmentDiagnostics` mode-aware:** add a new issue kind `separateSpacesExperimental` (single global issue, stable id). Add `evaluate(monitors:spacesMode:)` (default `spacesMode: .unavailable` for source compatibility). `.disabled`/`.unavailable` ⇒ preserve side-by-side logic verbatim; `.enabled` ⇒ return `[]` for horizontal and emit exactly one `.separateSpacesExperimental` (when `monitors.count > 1`). Update `current()` to read and forward the mode.
4. **Surface the mode in runtime diagnostics dump:** append `displaySpacesMode=\(…)` to `WMController.runtimeStateDebugDump` (near `:2783`).
5. **Advisory mouse-warp copy by mode** in `MonitorSettingsTab.swift`: `.enabled` ⇒ caption explaining nehir's warp is not Space-aware; rely on system cursor movement or disable Mouse Warp. **Do not** change `shouldUseMouseWarp`/`syncMouseWarpPolicy` in Stage 1.
6. **Docs:** add a Separate-Spaces paragraph to `docs/CONFIGURATION.md` (near `:199`).
7. **Tests** (`Tests/NehirTests/DisplaySpacesModeTests.swift` + extend `DisplayEnvironmentDiagnosticsTests`): `.disabled` reproduces today's side-by-side issue (regression); `.enabled` suppresses it and emits one experimental issue; single-monitor `.enabled` emits none; `.unavailable` matches `.disabled`; override hook round-trips.

## User-facing copy points

- New issue title: "Displays have separate Spaces is enabled".
- Message: "macOS isolates each display's Spaces, which removes the side-by-side parked-window bleed. Nehir does not yet model per-window Space membership, so windows hidden on inactive native Spaces may be removed during a full rescan."
- Recommendation: "Arrange displays to match your physical setup. Avoid relying on Nehir's cross-monitor mouse warp until Space topology support is finalized."
- Mouse Warp caption (`.enabled`): "Displays have separate Spaces is on. Nehir's cross-monitor mouse warp is not Space-aware; if the pointer jumps unexpectedly, rely on macOS system cursor movement or disable Mouse Warp above."

## Suggested validation

```bash
swift build
swift test --filter DisplayEnvironmentDiagnostics
swift test --filter DisplaySpacesMode
swift test --filter StatusBarMenuTests
swift test --filter SettingsViewTests
swift test --filter WorkspaceBarManagerTests
# Manual: on a Separate-Spaces-ON host (toggle requires logout/login), relaunch Nehir,
# confirm the side-by-side warning is gone and the experimental card is present.
```

Add a changeset: "Detect macOS Displays have separate Spaces and adjust display-arrangement and mouse-warp guidance accordingly." (minor or patch — confirm with release flow.)

## Risks

- **Private-symbol availability** — `SLSGetSpaceManagementMode` may be missing/renamed on some macOS versions; the `copyManagedDisplaySpaces` fallback must be robust and default to `.unavailable` (conservative = current behavior) on ambiguity.
- **Fallback ambiguity** — single "Main" entry with only one display attached is indeterminate; treat as `.unavailable`, not `.disabled`.
- **Cache/staleness** — the setting changes only after logout/login, but `Monitors` change at runtime. Re-read the mode on every `current()`/`evaluate` (cheap) and on `didChangeScreenParametersNotification`. Do not cache across app lifetime.
- **Silent suppression** — suppressing the side-by-side warning under `.enabled` could hide a real regression if the manual test was incomplete. Mitigation: the `.separateSpacesExperimental` issue still surfaces a yellow card, so the Diagnostics badge stays > 0.
- **Test isolation** — `displaySpacesModeOverrideForTests` is static; restore to `nil` in a `defer` (mirror `orderedStateProviderForTests` discipline).

## Open questions

1. **Mouse-warp policy action** — should Stage 1 also auto-disable `MouseWarpHandler` when `.enabled`? Recommendation: advisory only; revisit after Stage 2 makes nehir Space-aware.
2. **Issue dismissibility** — should `.separateSpacesExperimental` be postponable? Recommendation: no; keep it always-on until Stage 2 lands; it is informational, not blocking.
3. **Entitlements** — both Stage 1 and Stage 2 read private-framework symbols via `dlsym`, consistent with the existing SkyLight loader. Confirm `Nehir.entitlements` allows these reads in signed/notarized builds; the existing `SLSCopyManagedDisplaySpaces` path suggests yes, but a notarized build smoke test is worthwhile before release.

## Relationship to other clusters

- **Stage 2** (`20260618-space-topology-eviction-exemption.md`) depends on Stage 1 task 2 (`DisplaySpacesMode`) and Stage 1 task 1. Do not start Stage 2 until Stage 1 is reviewed and manual mode detection works on a real host.
- **P1** (rescan eviction hysteresis) composes with Stage 2's topology exemption; both feed `confirmedMissingKeys`.
