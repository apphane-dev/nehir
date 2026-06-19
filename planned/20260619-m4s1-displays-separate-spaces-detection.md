# M4 Stage 1 — Displays-have-separate-Spaces mode detection + diagnostics

**Status:** planned
**Source discovery:** `discovery/20260618-displays-separate-spaces-mode-detection.md`
**Upstream commits:** `de971b6`, `ee554c7`

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

## Implementation drift accepted during review

The shipped Stage 1 scope intentionally diverged from the original diagnostics
plan after product review found that a standalone Separate-Spaces warning did not
provide a real solution.

- Keep `DisplaySpacesMode` detection and the runtime dump field.
- Show Separate-Spaces state in Diagnostics as informational state only
  (`Enabled` / `Disabled` / `Unavailable`). Do **not** emit a warning issue,
  enforce the setting, suppress horizontal-overlap warnings, or recommend
  Separate Spaces as a fix.
- Keep the supported-arrangement warning anchored to what Nehir supports today:
  an auto-hide Dock and display arrangements with no horizontal overlap
  (vertical or diagonal layouts). A diagonal arrangement is recommended when the
  user wants to avoid macOS native cross-display edge warping and rely only on
  Nehir Mouse Warp.
- Add a user-facing Mouse Warp enable toggle (`[mouseWarp].enabled`) so users can
  disable Nehir's warp entirely. When disabled, axis/margin controls are hidden
  but their values are preserved.
- Show a soft warning in Mouse Warp settings when Mouse Warp is disabled and the
  current display layout has no full vertical side overlap: macOS native cursor
  movement may only work through the overlapping segment or may not cross between
  diagonally arranged displays.

## Tests

- **New** `Tests/NehirTests/DisplaySpacesModeTests.swift`: `overrideForTests`
  round-trips; Separate-Spaces mode does not suppress the supported-arrangement
  warning; single-monitor setups have no arrangement warning in any mode; display
  mode labels are user-readable.
- `DisplayEnvironmentDiagnosticsTests` continues to cover fixed Dock,
  horizontal-overlap, vertical, mirrored-display, and stable-id behavior.
- Settings/TOML coverage validates the new `[mouseWarp].enabled` field and the
  canonical fixture.
- `displaySpacesModeOverrideForTests` is static — restore to `nil` in `defer`
  (mirror `orderedStateProviderForTests` discipline).

## Validation

```bash
swift build
swift test --filter DisplaySpacesMode
swift test --filter DisplayEnvironmentDiagnostics
swift test --filter StatusBarMenuTests
swift test --filter SettingsViewTests
swift test --filter SettingsTOMLCodecTests
swift test --filter SettingsStoreTests
swift test --filter ConfigMismatchDetectorTests
```

Changeset (minor): "Detect macOS Displays have separate Spaces, clarify
supported vertical/diagonal display arrangements, and add a Mouse Warp enable
toggle with disabled-state guidance."

## Risks

- **Private-symbol availability** — `SLSGetSpaceManagementMode` may be
  missing/renamed on some macOS versions; the `copyManagedDisplaySpaces` fallback
  must default to `.unavailable` (conservative = current behavior) on ambiguity.
- **Fallback ambiguity** — single "Main" entry with only one display attached is
  indeterminate ⇒ `.unavailable`, not `.disabled`.
- **No caching across app lifetime** — re-read on every `current()`/`evaluate`
  (cheap) and on `didChangeScreenParametersNotification`.
