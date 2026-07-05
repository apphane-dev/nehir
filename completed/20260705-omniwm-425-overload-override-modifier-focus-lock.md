# OmniWM #425 — Overload the Mouse Resize modifier into a "Manual Override" modifier (add hold-to-lock-focus)

**Status:** shipped — landed on `main` as `dc1f5fac` ("Add Manual Override focus lock from OmniWM") on 2026-07-05. Implemented as planned: `mouseResizeModifierKey` → `overrideModifier` rename (config/enum/UI), `mouse-resize-modifier-to-override-modifier` settings migration (introduced phase), and hold-to-lock-focus via live-flag read in `MouseEventHandler`. Tests + `docs/SETTINGS_MIGRATIONS.md` + `docs/ARCHITECTURE.md` updated in the same commit.
**Upstream reference (idea + partial code):** <https://github.com/BarutSRB/OmniWM/issues/425> and commit <https://github.com/BarutSRB/OmniWM/commit/79067d451668dcd333bafbcf6e09acf1761fa892> (Focus Lock Modifier).
**Attribution requirement:** the focus-lock *idea* is upstream (OmniWM, BarutSRB). The modifier enum this plan renames is already upstream-derived (`MouseResizeModifierKey.swift` carries the `Provenance=upstream-derived; Upstream-Project=OmniWM` SPDX header). Preserve that header on rename and add an SPDX/NOTICE note that the focus-lock behavior is derived from OmniWM #425. Do **not** copy OmniWM's `FocusLockModifier.swift` enum or its per-event `modifiersRawValue` threading verbatim — this plan reuses Nehir's existing modifier enum and reads live flags instead (see Design decision #2), so the code is independently implemented; attribute the idea, not the code.

All file/line references were verified against the main Nehir source tree on 2026-07-05 (worktree `/Users/Aleksei_Gurianov/ghq/github.com/guria/nehir`, `main` @ `83c2234b`). Re-verify before editing; line numbers drift. Paths refer to the main repo, not this plans branch.

## Decision (from the requester)

Overload the single existing modifier rather than adding a separate `focusLockModifier` setting. Rename the option to reflect the unified "manual override" concept, migrate the existing config value under the settings-migration lifecycle, drop the old key name (no dual-purpose keep), and revisit a *separate* focus-lock modifier only if a real user request appears. This plan implements exactly that.

## TL;DR

`mouseResizeModifierKey` (UI: section **"Mouse Resize"**, label **"Mouse Modifier"**) is already overloaded with two effects and the label/section are misleading:

1. **Right-drag resize** — `MouseEventHandler.swift:1005-1006`: hold the modifier + right-mouse-drag → interactive resize of the tiled window under the cursor.
2. **Bypass snap** — `MouseEventHandler.swift:1678-1682` (arm) and `:1737-1748` (upgrade mid-gesture): hold the modifier during a trackpad scroll gesture → viewport scrolls freely instead of snapping to columns (`bypassSnap == true` → `snapToColumn = false` at `:2040`).

Neither "Mouse Resize" nor "Mouse Modifier" describes effect #2, and the caption at `BehaviorSettingsTab.swift:105-107` crams both into one sentence.

Add a **third** effect from OmniWM #425 — **hold-to-lock-focus**: while the modifier is physically held, suppress focus-follows-mouse so the pointer can cross other windows (to read/scroll/inspect) without stealing focus. All three effects share one coherent concept: *hold the modifier to take manual control and suppress the automatic/tiling behavior* (manual size vs auto-tile; free scroll vs auto-snap; held focus vs auto-follow).

So: **rename** the option to a "Manual Override" modifier, **relabel** section/caption to enumerate all three effects, **add** the focus-lock effect at the one focus-follows-mouse gate (`MouseEventHandler.swift:914-924`), and **migrate** the `[gestures].mouseResizeModifierKey` → `[gestures].overrideModifier` config key under the existing soft-migration lifecycle (`docs/SETTINGS_MIGRATIONS.md`).

## Current behavior (verified)

- Config key lives in `[gestures]`: `CanonicalTOMLConfig.Gestures.mouseResizeModifierKey` (`CanonicalTOMLConfig.swift:233`, `CodingKeys` `:239`), decoded at `:883-887` (`decodeWithDefault`), encoded at `:902`, mapped to/from `SettingsExport` at `:364` and `:455`.
- Runtime store: `SettingsStore.mouseResizeModifierKey` (`SettingsStore.swift:341-345`), export map at `:516`, import at `:612`.
- Export DTO: `SettingsExport.mouseResizeModifierKey` (`SettingsExport.swift:83`), default `.option` (`:187`).
- Enum: `MouseResizeModifierKey` (`MouseResizeModifierKey.swift:7-43`) — `String, CaseIterable, Codable`, 15 cases, `displayName`, and a `cgEventFlag` computed elsewhere (used at the three match sites). **This file already carries the OmniWM upstream-derived SPDX header** (`:1-5`).
- UI: `BehaviorSettingsTab.swift:98-108` — `Section("Mouse Resize")`, `Picker("Mouse Modifier", …)`, caption at `:105-107`.
- Match sites (all via `Self.modifierFlagsMatch(_, required: …cgEventFlag)`, exact match against `mouseRelevantModifierFlags`, `MouseEventHandler.swift:2531-2533`): resize `:1006`; bypass-snap arm `:1678`; bypass-snap mid-gesture upgrade `:1738`.
- Focus-follows-mouse gate: `handleMouseMovedFromTap` (`:893-912`) calls `handleFocusFollowsMouse` only when `controller.focusFollowsMouseEnabled && shouldHandleFocusFollowsMouse(at:)`. `shouldHandleFocusFollowsMouse` (`:914-924`) already returns `false` during resize / viewport gesture / suppression window — this is the natural insertion point for the focus-lock guard.

## Design decisions

1. **Overload one modifier, one setting.** No new `focusLockModifier`. The rename makes the shared setting's name honest. A separate modifier is an explicit non-goal (revisit on real user demand).

2. **Read live modifier flags for focus-lock; do not thread `modifiers` through the mouseMoved queue.** OmniWM threaded `modifiersRawValue` through every mouse-move event. Nehir's mouse-move path is coalesced and replayed (`enqueuePendingMouseMoved` `:684`, `replayQueuedMouseMoved` `:794`, `handleMouseMovedFromTap` `:893`) and currently carries **no** modifiers on the move payload (`State.PointerPayload` is `{location, windowUnderPointer}`, `:136-139`) — only mouse-*down* threads `modifiers`. Rather than widen `PointerPayload` and every enqueue/replay/dispatch signature, read the **live** keyboard flags at the focus decision via `CGEventSource.flagsState(.combinedSessionState)` (the same session-state source already used in `MouseWarpHandler.swift:68`). This is:
   - **Smaller** — one guard in `shouldHandleFocusFollowsMouse`, zero queue-plumbing edits.
   - **Self-healing** — a missed key-up cannot strand focus, because the flag is re-read on every move (matches OmniWM's own "self-healing" property, achieved differently).
   - **Correct timing** — focus is applied at replay/refresh time, and live flags reflect the modifier state at that instant, not a stale queued value.

3. **Focus-lock is inherently gated on focus-follows-mouse being enabled** — the guard lives inside the `controller.focusFollowsMouseEnabled` branch (`:906`), so it is inert when FFM is off. No extra setting/toggle.

4. **Exact-match semantics are reused unchanged.** `modifierFlagsMatch` compares `modifiers.intersection(mouseRelevantModifierFlags) == required`. Focus-lock uses the same helper, so holding *exactly* the configured combo locks focus; holding a superset does not. This matches the resize/bypass-snap behavior for consistency.

5. **Rename, don't alias.** New canonical key `[gestures].overrideModifier`. The old `[gestures].mouseResizeModifierKey` is decoded only as a **compatibility fallback** (introduced-phase migration) so existing values are not lost; fresh saves emit only `overrideModifier`; Diagnostics offers **Migrate** + **Postpone**. This follows `docs/SETTINGS_MIGRATIONS.md` exactly (mirrors `reveal-partial-to-reveal-style`, which is the closest precedent — a single settings.toml key rename with value carry-over).

## Naming

| Thing | Old | New |
|---|---|---|
| TOML key (`[gestures]`) | `mouseResizeModifierKey` | `overrideModifier` |
| Enum type + file | `MouseResizeModifierKey` / `MouseResizeModifierKey.swift` | `OverrideModifierKey` / `OverrideModifierKey.swift` |
| `SettingsStore` property | `mouseResizeModifierKey` | `overrideModifier` |
| `SettingsExport` field | `mouseResizeModifierKey` | `overrideModifier` |
| `Gestures` struct field + CodingKey | `mouseResizeModifierKey` | `overrideModifier` |
| UI section | `"Mouse Resize"` | `"Manual Override"` |
| UI picker label | `"Mouse Modifier"` | `"Modifier"` |
| Migration id | — | `mouse-resize-modifier-to-override-modifier` |

Enum cases/`displayName`/`cgEventFlag` are unchanged (only the type name and file name change).

**Proposed caption** (replaces `BehaviorSettingsTab.swift:106`):

> "Hold this modifier to take manual control: resize the tiled window under the pointer with a right-mouse drag, scroll the viewport freely past column snapping, and — while Focus Follows Mouse is on — keep focus on the current window as the pointer passes over others."

## Scope

### Files to change

**Enum (rename, keep provenance header)**

1. `Sources/Nehir/Core/Config/MouseResizeModifierKey.swift` → rename file to `OverrideModifierKey.swift`; rename `enum MouseResizeModifierKey` → `OverrideModifierKey`. Keep the SPDX header (`:1-5`) verbatim and append a `SPDX-FileComment` note that the focus-lock behavior is derived from OmniWM #425. Cases, `displayName`, and the `cgEventFlag` extension are unchanged. Update the `cgEventFlag` extension's type name if it is declared as `extension MouseResizeModifierKey` (grep: it is referenced at the three match sites and in `SettingsStore`).

**Config model + migration decode**

2. `Sources/Nehir/Core/Config/CanonicalTOMLConfig.swift`
   - `Gestures` (`:229-242`): rename field `mouseResizeModifierKey` → `overrideModifier`; update `CodingKeys` (`:239`).
   - Decode (`:883-887`): decode the **new** key `overrideModifier` with `decodeWithDefault`, defaulting to the legacy value when the new key is absent — i.e. read a legacy `mouseResizeModifierKey` out of the decoded container/unknown fields first and use it as the default so an old file's value survives in-memory:
     ```swift
     let legacyOverride = try container.decodeIfPresent(String.self, forKey: .mouseResizeModifierKeyLegacy)
     overrideModifier = try container.decodeWithDefault(
         String.self, forKey: .overrideModifier,
         default: legacyOverride ?? d.overrideModifier
     )
     ```
     Add a legacy-only `CodingKey` (`case mouseResizeModifierKeyLegacy = "mouseResizeModifierKey"`) used **only** for this fallback read; do not add it to the encode path. (If the codec routes unknown keys into `unknownFields` instead, read the legacy value from `unknownFields["mouseResizeModifierKey"]` — verify which path the decoder takes for a known-section/unknown-field before implementing.)
   - Encode (`:902`): emit `overrideModifier` only. Never emit `mouseResizeModifierKey`.
   - Mapping to/from `SettingsExport` (`:364`, `:455`): rename to `overrideModifier`.

3. `Sources/Nehir/Core/Config/SettingsExport.swift`
   - Field (`:83`) `mouseResizeModifierKey` → `overrideModifier`.
   - Default (`:187`) `mouseResizeModifierKey: MouseResizeModifierKey.option.rawValue` → `overrideModifier: OverrideModifierKey.option.rawValue`.

4. `Sources/Nehir/Core/Config/SettingsStore.swift`
   - Property (`:341-345`) rename; `MouseResizeModifierKey(...)` → `OverrideModifierKey(...)`.
   - Export map (`:516`) and import (`:612`) rename.

**Migration registry + detector + migrator**

5. `Sources/Nehir/Core/Config/SettingsMigrationRegistry.swift`
   - Add `enum OverrideModifierMigrationKeys { legacyKey = "mouseResizeModifierKey"; newKey = "overrideModifier"; section = "gestures" }`.
   - Add a `SettingsMigrationDescriptor` `mouseResizeModifierToOverrideModifier` (id `mouse-resize-modifier-to-override-modifier`, `fileName: SettingsFilePersistence.fileName`, title e.g. "Update mouse modifier setting", old/new summaries `[gestures].mouseResizeModifierKey` / `[gestures].overrideModifier`, warning + enforcement body). Add it to `.all` (`:53-56`).
   - Add a `MouseResizeModifierSettingsMigration` enum mirroring `RevealPartialSettingsMigration` (`:131-232`) but for the `[gestures]` section: `needsMigration` returns true when a `[gestures].mouseResizeModifierKey` line is present; `migrate` backs up, decodes, moves the value into `overrideModifier` when the new key is absent, strips the legacy key from `settingsTOMLUnknownFields["gestures"]`, re-encodes. Reuse the `sectionValue(for:in:section:)` scanning helper generalized from `niriValue` (or add a parameterized variant) — the reveal migrator's `niriValue` (`:180-200`) hardcodes `[niri]`; generalize it to take a section name and share it.
   - Wire detection in `SettingsMigrationDetector.applicableMigrations` (`:69-87`): add the settings.toml check for `MouseResizeModifierSettingsMigration.needsMigration`.

6. `docs/SETTINGS_MIGRATIONS.md`
   - Add a `### mouse-resize-modifier-to-override-modifier` registry entry (introduced phase; TBD introduced/deprecated/enforced releases), old/new format examples under `[gestures]`, mapping (identity — same rawValue), Diagnostics copy (title/body/actions) mirroring the reveal-partial section.

**UI**

7. `Sources/Nehir/UI/BehaviorSettingsTab.swift`
   - `:98` `Section("Mouse Resize")` → `Section("Manual Override")`.
   - `:99` `Picker("Mouse Modifier", selection: $settings.mouseResizeModifierKey)` → `Picker("Modifier", selection: $settings.overrideModifier)`; `MouseResizeModifierKey.allCases` → `OverrideModifierKey.allCases` (`:100`).
   - `:105-107` caption → the proposed three-effect caption above.

**Focus-lock behavior (the new effect)**

8. `Sources/Nehir/Core/Controller/MouseEventHandler.swift`
   - In `shouldHandleFocusFollowsMouse(at:)` (`:914-924`), after the existing early-return guards and before the monitor/animation check, add:
     ```swift
     // OmniWM #425: hold the override modifier to keep focus on the current
     // window while the pointer crosses others. Live flags are re-read every
     // move, so a missed key-up cannot strand focus (self-healing).
     let live = CGEventSource.flagsState(.combinedSessionState)
     if Self.modifierFlagsMatch(live, required: controller.settings.overrideModifier.cgEventFlag) {
         return false
     }
     ```
     Note `controller` is already unwrapped at `:917`. Confirm `CGEventSource.flagsState(_:)` is the correct static signature on the deployment target; if the instance form is preferred for parity with `MouseWarpHandler.swift:68`, use `CGEventSource(stateID: .combinedSessionState)?.flagsState` equivalently — but `flagsState(_:)` static is the standard read.
   - Guard against a "no modifier configured" degenerate case: every `OverrideModifierKey` case includes at least one modifier, so `cgEventFlag` is never empty and an empty live-flags state never matches — no explicit empty-check needed. Verify `cgEventFlag` has no `.none`/empty case before relying on this.
   - The resize (`:1006`) and bypass-snap (`:1678`, `:1738`) sites only change by the property rename (`settings.mouseResizeModifierKey` → `settings.overrideModifier`).

### Non-goals

- Do **not** add a separate `focusLockModifier` setting or a per-effect enable toggle (explicit requester decision; revisit only on real demand).
- Do **not** thread `modifiers` through the mouseMoved queue / `PointerPayload` (Design decision #2).
- Do **not** keep `mouseResizeModifierKey` as a live alias — it exists only as a compatibility decode + migration, never re-encoded.
- Do **not** change the exact-match modifier semantics, the resize edge logic, or the bypass-snap gesture machinery.
- Do **not** change focus-follows-mouse behavior when the override modifier is *not* held, or when FFM is disabled.

## Phased implementation

### Phase 1 — Enum rename
1. Rename file + type (Scope #1). `grep -rn "MouseResizeModifierKey" Sources/` and update every reference (three match sites, `SettingsStore`, `SettingsExport` default, `Gestures` mapping, any tests). `swift build`.

### Phase 2 — Config model rename + compatibility decode
2. Edit `CanonicalTOMLConfig.swift`, `SettingsExport.swift`, `SettingsStore.swift` (Scope #2-4). `swift build`.
3. Confirm: a settings.toml with the **new** key round-trips; a settings.toml with the **old** key decodes the value into `overrideModifier` in-memory (no loss) and, on save, emits only the new key.

### Phase 3 — Migration registry + Diagnostics
4. Add registry descriptor, keys enum, migrator, detector wiring (Scope #5); generalize the section scanner. `swift build`.
5. Update `docs/SETTINGS_MIGRATIONS.md` (Scope #6).

### Phase 4 — UI relabel
6. Edit `BehaviorSettingsTab.swift` (Scope #7). `swift build`.

### Phase 5 — Focus-lock behavior
7. Add the guard in `shouldHandleFocusFollowsMouse` (Scope #8). `swift build`.

### Phase 6 — Tests + validation
8. Tests (below) + full gate.

## Tests

**Config round-trip / migration** (`Tests/NehirTests/` — alongside existing settings/codec tests; find the reveal-partial migration test file, e.g. `RevealPartialSettingsMigrationTests.swift` / `CanonicalTOMLConfigTests.swift`, and mirror it):

1. `overrideModifierRoundTripsThroughToml` — encode a `SettingsExport` with `overrideModifier = "controlOption"`, decode, assert survival; assert the emitted TOML contains `overrideModifier` and **not** `mouseResizeModifierKey`.
2. `legacyMouseResizeModifierKeyDecodesIntoOverrideModifier` — decode a settings.toml containing `[gestures]\nmouseResizeModifierKey = "command"` (and no `overrideModifier`); assert `overrideModifier == "command"` in the decoded export (value not lost).
3. `newKeyWinsWhenBothPresent` — a file with both keys keeps `overrideModifier` and ignores the legacy value (mirrors reveal-partial "if both present" rule).
4. `mouseResizeModifierMigrationNeedsMigrationDetectsLegacyKey` — `MouseResizeModifierSettingsMigration.needsMigration(data:)` true for a `[gestures].mouseResizeModifierKey` file, false for an `overrideModifier`-only file, false for an unrelated file.
5. `mouseResizeModifierMigrationRewritesToNewKey` — run `migrate(fileURL:)` on a temp copy; assert a backup is created, the rewritten file has `overrideModifier` with the carried value and no `mouseResizeModifierKey`, and re-decoding matches.
6. `migrationRegistryIncludesOverrideModifierEntry` — `SettingsMigrationRegistry.all` contains the new descriptor with the expected id.

**Focus-lock behavior** (`Tests/NehirTests/` — find the MouseEventHandler focus-follows-mouse test harness; there is existing coverage around `handleFocusFollowsMouse` / `shouldHandleFocusFollowsMouse` and `resetFocusFollowsMouseTimeForTesting`):

7. `focusFollowsMouseSuppressedWhileOverrideModifierHeld` — with FFM enabled and `overrideModifier = .option`, drive a mouse-move while the live-flags provider reports Option held; assert focus is **not** changed (no `handleFocusFollowsMouse` effect). This requires the live-flags read to be injectable — **if `CGEventSource.flagsState` is not injectable in the test harness, add a small `var liveModifierFlagsProvider: () -> CGEventFlags` seam on `MouseEventHandler` (defaulting to `{ CGEventSource.flagsState(.combinedSessionState) }`) and read through it**, so tests can stub the held modifier. Add this seam in Scope #8 if needed.
8. `focusFollowsMouseAppliesWhenOverrideModifierNotHeld` — same setup, live flags empty; assert focus follows as before (regression guard).
9. `focusFollowsMouseUnaffectedWhenModifierHeldButFfmDisabled` — FFM off; assert the guard is never consulted (no behavior change).
10. `overrideModifierSupersetDoesNotLockFocus` — live flags = Option+Shift while `overrideModifier = .option`; exact-match means focus still follows (locks in the exact-match semantic).

**UI** — no snapshot infra assumed; the picker/label change is covered by build + manual validation.

## Validation

```bash
swift build
swift test --filter CanonicalTOMLConfig
swift test --filter SettingsMigration
swift test --filter MouseResizeModifier   # new migration tests
swift test --filter FocusFollowsMouse      # or the MouseEventHandler focus test target
mise run check                             # format + lint + build + full test
```

Manual validation on a host:
1. Existing user path: start with a `~/.config/nehir/settings.toml` containing `[gestures] mouseResizeModifierKey = "controlOption"`. Launch Nehir → Settings → Manual Override shows **Control+Option** (value migrated in-memory). Diagnostics shows the migration entry with **Migrate** + **Postpone**. Click **Migrate**; confirm a `.backup` is written and the file now has `overrideModifier = "controlOption"`, no `mouseResizeModifierKey`.
2. Resize still works: hold the modifier + right-drag a tiled window → resizes.
3. Bypass snap still works: hold the modifier during a trackpad scroll → viewport scrolls without column snapping.
4. New focus-lock: enable Focus Follows Mouse. Move the pointer over an unfocused window → focus follows. Now hold the modifier and move over the same window → focus stays on the original window; release → focus follows again. Toggle FFM off → holding the modifier has no focus effect.
5. Fresh install: no settings.toml → defaults to `overrideModifier = "option"`, saved file uses only the new key.

Changeset (minor): "Rename the Mouse Resize modifier to a Manual Override modifier and add hold-to-lock-focus (OmniWM #425)."

## Risks and mitigations

- **Behavior change for existing default users (MED).** Default modifier is `.option`; with FFM enabled, holding Option during a move now locks focus where before it did nothing. This is the intended feature, but it changes muscle memory for anyone who habitually holds Option. Mitigation: document in the changelog/What's-New; the effect is discoverable via the rewritten caption; it only applies when FFM is on and only for the exact configured combo.
- **Live-flags read testability (MED).** `CGEventSource.flagsState` is a global read. Mitigation: inject via a `liveModifierFlagsProvider` seam (Scope #8 / test #7) so behavior is unit-testable without real key state.
- **Legacy value carry-over depends on decoder unknown-key routing (MED).** Whether a legacy `mouseResizeModifierKey` lands in the typed container vs `unknownFields` determines how the compatibility read is written. Mitigation: verify the decode path (Phase 2 step 3) with test #2 before finalizing; the reveal-partial precedent (which reads from `settingsTOMLUnknownFields`) shows the unknown-field route is the likely one for a removed key.
- **Section scanner generalization (LOW).** Generalizing `niriValue` to arbitrary sections could regress the reveal-partial migrator. Mitigation: keep the reveal-partial call passing `section: "niri"` and add a test that the generalized helper still detects `[niri].revealPartial`.
- **Exact-match surprise (LOW).** Users holding a superset of the combo won't lock focus. Mitigation: consistent with resize/bypass-snap; documented; test #10 locks it in.

## Follow-ups (out of scope)

- **Separate `focusLockModifier` setting.** Revisit only on a real user request for an independent focus-lock key (the requester's explicit deferral). If added, it would live under the Focus section next to `focusFollowsMouse`, matching OmniWM's own `[focus]` placement.
- **Deprecate → enforce the migration.** Fill in the `deprecated`/`enforced` release fields in the registry once the introduced phase has shipped one release.
- **Right-variant / "either" modifiers.** OmniWM #425's enum distinguishes left/right and "either" variants. Nehir's `OverrideModifierKey` does not model side. Out of scope; add only if requested.
