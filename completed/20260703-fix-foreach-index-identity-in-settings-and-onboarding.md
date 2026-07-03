# Fix ForEach index/offset identity in settings and onboarding views — Plan

**Status:** completed — shipped on `main` in commits `c3f1856d` ("Fix Resize
Presets ForEach identity to survive mid-list removal") and `6c3e65ce` ("Replace
offset-based ForEach identity in onboarding and diagnostics views"), merged
2026-07-03. Moved from `planned/` to `completed/`. Implementation replaced the
old `.id(count)` full-section-rebuild workaround with UUID-identified
`PresetRow` state; `WorkspaceBarAnimation` items got an `Identifiable` struct
with `symbol#occurrence` ids; static sites keyed on content. Full suite green
at merge (1387 tests / 115 suites). No automated regression test covers the
mid-edit removal scenario — validated manually per the validation section
below. Executed by a delegated agent (opus-4.8) in a worktree. Derived from
`discovery/20260703-swiftui-conformance-audit-foreach-identity-and-deprecated-apis.md`
(Findings 1 and 2).

Validated against the main Nehir source tree on 2026-07-03 at commit `8286c192`.

---

## Problem

`Sources/Nehir/UI/SettingsView.swift:667` renders the Resize Presets editor with
`ForEach(presets.indices, id: \.self)` over a mutable array
(`settings.niriColumnWidthPresets`) that the rows themselves mutate: a
destructive remove button (`SettingsView.swift:682-686`) and an Add Preset
button below. Each row hosts a `PercentTextField` with per-row view state
(`@State private var draft`, `@FocusState private var isFocused`,
`SettingsView.swift:522-523`), and the field deliberately does **not** resync
its draft from the bound value while focused
(`.onChange(of: value) { if !isFocused { restoreDraftFromValue() } }`,
`SettingsView.swift:539`).

With index identity, removing a middle preset makes SwiftUI keep the first
`n-1` row views and slide new values under them: a focused, mid-edit draft can
end up committed against a *different* preset than the one the user was
editing, and the removal animates as "last row vanished". This violates the
hard rule "ForEach identity must outlive the view and not be derived from
mutable content".

Secondary sites use `id: \.offset` on `enumerated()` content — harmless where
the data is static per presentation, but wrong-diffing where it animates:

- Animated (can visibly mis-animate when counts change):
  `Sources/Nehir/UI/Onboarding/Animations/WorkspaceBarAnimation.swift:261,359`
- Static (fragility cleanup only):
  `Sources/Nehir/UI/DisplayDiagnosticsSettingsTab.swift:849`,
  `Sources/Nehir/UI/Onboarding/WhatsNewView.swift:42,153`,
  `Sources/Nehir/UI/Onboarding/OnboardingStepControls.swift:232`,
  `Sources/Nehir/UI/Onboarding/ConfigRecoveryView.swift:48`

Not in scope (already stable identity): `MonitorSettingsTab.swift:131`,
`InteractiveMoveDemo.swift:664,702`, all `ForEach`es in
`WorkspaceBarView.swift`.

---

## Phase 1 — Resize Presets stable identity (the actual bug)

Preset values are plain `Double`s and may duplicate (two presets both 50%), so
`id: \.self` on values is not an option. Give rows durable identity local to
the editing session:

1. Introduce a tiny identified wrapper in `SettingsView.swift` near the
   presets section, e.g. `struct PresetRow: Identifiable { let id: UUID; var value: Double }`.
2. Hold `@State private var presetRows: [PresetRow]` seeded from
   `settings.niriColumnWidthPresets` on appear, and resynced (regenerating ids
   only when the count/values changed externally) via
   `.onChange(of: settings.niriColumnWidthPresets)`.
3. `ForEach(presetRows)` — commit/remove handlers operate by row `id`
   (`firstIndex(where:)` at commit time), then write the projected `[Double]`
   back to `settings.niriColumnWidthPresets` and call
   `controller.updateNiriConfig(columnWidthPresets:)` exactly as today.
4. Row labels ("Preset N") keep using the *position* (`presetRows.firstIndex`
   or an `enumerated()` over the identified rows) — position is presentation,
   not identity.

Alternative considered: keep `ForEach(indices)` and force full-list rebuild
with `.id(presets.count)` — rejected; it drops focus/draft on every add/remove
and papers over the identity model instead of fixing it.

## Phase 2 — offset-identity cleanup

Mechanical, no behavior-decision content:

- `WorkspaceBarAnimation.swift:261,359`: `displayedWindows(_:)` returns
  symbol/count items — key on the symbol (unique within a pill) or add an
  explicit id to the item struct it builds.
- The four static sites: derive identity from the content where unique
  (message/bullet strings) or add lightweight `Identifiable` structs where the
  source arrays are built in-file. Do not introduce new state.

---

## Validation

1. `swift build && swift test` (full suite; no existing tests cover the presets
   editor — add one if `SettingsView` model logic is extractable, otherwise
   manual).
2. Manual, Layout settings tab: create 4 presets, focus preset 2's text field,
   type a new value *without committing*, remove preset 3 with the mouse —
   the draft must stay attached to preset 2 and commit to preset 2. Then remove
   preset 2 mid-edit — no draft may leak into the row that takes its place.
3. Manual, onboarding: run the workspace-bar animation step and the What's New
   sheet; visuals unchanged.
