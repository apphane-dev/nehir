# M4 Stage 1 — Displays-have-separate-Spaces mode detection + diagnostics

**Status:** planned
**Source discovery:** `discovery/20260618-displays-separate-spaces-mode-detection.md`
**Upstream commits:** `de971b6`, `ee554c7`

All file/line references re-verified against
`/Users/Aleksei_Gurianov/ghq/github.com/guria/nehir` on 2026-06-19. Re-verify
before editing; line numbers drift.

## TL;DR

Nehir cannot tell whether macOS "Displays have separate Spaces" is on. With it
**ON**, nehir's side-by-side vertical-arrangement warning is misleading (display
surfaces are isolated). Deliver **mode detection + mode-aware diagnostics +
runtime-dump field**. **Diagnostics-only** — no layout/eviction/startup change,
no auto-disable of mouse warp (roadmap decision #3: advisory copy only, deferred
to a follow-up doc/UI task).

## Scope (core Stage 1)

1. `Sources/Nehir/Core/SkyLight/SkyLight.swift` — resolve the optional private
   symbol `SLSGetSpaceManagementMode` (`@convention(c) (Int32) -> Int32`) via
   `dlsym`; store `private let getSpaceManagementMode: …?`. **Do NOT** add it to
   `missingRequiredSymbols` (optional; must not gate startup). Mirror the existing
   `copyManagedDisplaySpaces` / `orderedStateProviderForTests` loader pattern.
2. **New** `Sources/Nehir/Core/SkyLight/DisplaySpacesMode.swift`:
   - `enum DisplaySpacesMode: String, Sendable, Equatable { case enabled, disabled, unavailable }`.
   - `SkyLight.shared.displaySpacesMode()` — primary: `getSpaceManagementMode`
     present ⇒ `.enabled` if `!= 0`, `.disabled` if `== 0`. Fallback (symbol nil):
     inspect `copyManagedDisplaySpaces` shape — single `"Main"` entry + >1 display
     ⇒ `.disabled`; one entry per display identifier ⇒ `.enabled`; indeterminate
     ⇒ `.unavailable`. Factor the display-identifier mapping from the existing
     `displayId(forSpaceId:among:)` helper.
   - `@MainActor static var displaySpacesModeOverrideForTests: (() -> DisplaySpacesMode)?`
     mirroring `orderedStateProviderForTests`.
3. `Sources/Nehir/Core/Monitor/DisplayEnvironmentDiagnostics.swift` — add issue
   kind `separateSpacesExperimental` (single global issue, stable id). Add
   `evaluate(monitors:spacesMode:)` (`spacesMode: DisplaySpacesMode = .unavailable`
   default for source compat). `.disabled`/`.unavailable` ⇒ preserve current
   side-by-side logic verbatim; `.enabled` ⇒ return `[]` for the horizontal issue
   and emit exactly one `.separateSpacesExperimental` (only when
   `monitors.count > 1`). Update `current()` to read + forward the mode.
4. `Sources/Nehir/Core/Controller/WMController.swift` — append
   `displaySpacesMode=\(…)` to `runtimeStateDebugDump` (~`:2783`, near the existing
   `focusFollowsMouse=…` line).

### Non-goals (explicitly deferred)

- Do **NOT** auto-disable `MouseWarpHandler`/change `shouldUseMouseWarp`
  (decision #3). Advisory caption copy in `MonitorSettingsTab` + the
  `docs/CONFIGURATION.md` paragraph are a **follow-up** — note as residual.
- Do **NOT** gate startup on Separate Spaces.
- Do **NOT** implement Stage 2 (per-window Space topology / eviction exemption).

## Tests

- **New** `Tests/NehirTests/DisplaySpacesModeTests.swift`: `overrideForTests`
  round-trips; `.disabled` reproduces today's side-by-side issue (regression);
  `.enabled` suppresses horizontal + emits one experimental issue; single-monitor
  `.enabled` emits none; `.unavailable` matches `.disabled`.
- Extend `DisplayEnvironmentDiagnosticsTests` for the mode-aware `evaluate`.
- `displaySpacesModeOverrideForTests` is static — restore to `nil` in `defer`
  (mirror `orderedStateProviderForTests` discipline).

## Validation

```bash
swift build
swift test --filter DisplaySpacesMode
swift test --filter DisplayEnvironmentDiagnostics
swift test --filter StatusBarMenuTests
swift test --filter SettingsViewTests
```

Changeset (minor): "Detect macOS Displays have separate Spaces and adjust
display-arrangement diagnostics accordingly."

## Risks

- **Private-symbol availability** — `SLSGetSpaceManagementMode` may be
  missing/renamed on some macOS versions; the `copyManagedDisplaySpaces` fallback
  must default to `.unavailable` (conservative = current behavior) on ambiguity.
- **Fallback ambiguity** — single "Main" entry with only one display attached is
  indeterminate ⇒ `.unavailable`, not `.disabled`.
- **No caching across app lifetime** — re-read on every `current()`/`evaluate`
  (cheap) and on `didChangeScreenParametersNotification`.
