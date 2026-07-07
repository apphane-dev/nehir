# Discovery: SwiftUI conformance audit — ForEach identity bugs, soft-deprecated APIs, tap-gesture buttons

Groom 2026-07-07: resolved (Findings 1–3) — the ForEach identity fixes (`6c3e65ce`, `c3f1856d`) and the `foregroundColor` → `foregroundStyle` migration (`ea013f2c`) shipped; see `completed/20260703-fix-foreach-index-identity-in-settings-and-onboarding.md` and `completed/20260703-migrate-foregroundcolor-to-foregroundstyle.md`. Finding 4 remains open in the split-out `discovery/20260703-command-palette-tap-gesture-accessibility-and-observable-migration.md`.

Status: discovery — static audit, no runtime capture involved. Both follow-up
plans executed and shipped on `main` 2026-07-03 (`c3f1856d` + `6c3e65ce`, and
`ea013f2c`):
`completed/20260703-fix-foreach-index-identity-in-settings-and-onboarding.md` (correctness),
`completed/20260703-migrate-foregroundcolor-to-foregroundstyle.md` (mechanical sweep).
Finding 4 (tap-gesture buttons, `@Observable` migration) split into its own
discovery
`discovery/20260703-command-palette-tap-gesture-accessibility-and-observable-migration.md`;
still open (no plan), gated on a product decision — revisit if command-palette
work comes up.

Audited against the main Nehir source tree on 2026-07-03 at commit `8286c192`
("Show other displays in the workspace bar"), using the SwiftUI Agent Skill
(swiftui-expert-skill, github.com/AvdLee/SwiftUI-Agent-Skill) correctness
checklist and deprecated-API reference. Deployment target is macOS 15
(`Package.swift:16`), so every "modern" replacement named below is available
unconditionally — no `#available` gating needed.

## What is already clean

The bulk of the checklist passes with zero findings:

- All `@State` and `@FocusState` properties are `private`.
- Every `.animation(...)` call includes the `value:` parameter.
- All `.onChange(of:)` uses are the modern two-parameter form (no deprecated
  single-value closures).
- `@StateObject` is used only for view-owned models
  (`Sources/Nehir/UI/Onboarding/InteractiveMoveDemo.swift:531`), `@ObservedObject`
  only for injected ones (`Sources/Nehir/UI/CommandPalette/CommandPaletteController.swift:1213`).
- The hot-path view `Sources/Nehir/UI/WorkspaceBar/WorkspaceBarView.swift` uses
  stable identity in all seven of its `ForEach`es (`id: \.id` or `Identifiable`).
- No closures stored in custom Environment/FocusedValue keys (no custom keys at
  all); no unstable `@Entry` defaults (no `@Entry` usage).
- The `.accentColor(_:)` *modifier* (deprecated) does not appear;
  `Color.accentColor` reads (fine) do.

## Finding 1 (bug): index-identified ForEach over a mutable array with removal

`Sources/Nehir/UI/SettingsView.swift:667` — the Resize Presets editor:

```swift
ForEach(presets.indices, id: \.self) { index in
    ...
    PercentTextField(value: Int(presets[index] * 100), onCommit: { ... current[index] = ... })
    Button(role: .destructive) { presets.remove(at: index) ... }
```

`presets` is `settings.niriColumnWidthPresets`, mutable from inside the rows
(remove button at `SettingsView.swift:682-686`, plus an Add Preset button below).
Identity is the array index, and `PercentTextField` keeps per-row view state
(`@State private var draft`, `@FocusState`, `SettingsView.swift:522-523`). When
a middle preset is removed, SwiftUI keeps the views for indices `0..<n-1` and
reflows the *values* under them, so:

- a row's in-progress `draft` / focus can end up attached to a different
  preset than the one the user was editing (the `onChange(of: value)` resync at
  `SettingsView.swift:539` is deliberately skipped while the field `isFocused`);
- removal animates as "last row disappears" rather than the removed row.

This is the one hard-rule violation in the audit ("ForEach uses stable
identity; id outlives the view and isn't derived from mutable content" — index
identity fails both). Preset values are plain `Double`s and can duplicate, so
the fix needs an identity wrapper, not `id: \.self` on values.

## Finding 2 (minor): `\.offset` identity on static/animated content

`id: \.offset` / `id: \.self`-on-`enumerated()` appears in content that is
either fully static per presentation or rebuilt wholesale:

- `Sources/Nehir/UI/DisplayDiagnosticsSettingsTab.swift:849` (issue messages)
- `Sources/Nehir/UI/Onboarding/WhatsNewView.swift:42,153` (sections/bullets)
- `Sources/Nehir/UI/Onboarding/OnboardingStepControls.swift:232` (rows)
- `Sources/Nehir/UI/Onboarding/ConfigRecoveryView.swift:48` (details)
- `Sources/Nehir/UI/Onboarding/Animations/WorkspaceBarAnimation.swift:261,359`
  (mock window icons — this one *animates*, so offset identity produces
  insert/remove diffs at the wrong position when the displayed window count
  changes mid-animation)

Static cases are harmless today but fragile; the two `WorkspaceBarAnimation`
sites can visibly mis-animate. `Sources/Nehir/UI/MonitorSettingsTab.swift:131`
and `Sources/Nehir/UI/Onboarding/InteractiveMoveDemo.swift:664,702` use
`enumerated()` but key on `\.element.id` — stable identity, no issue.

## Finding 3 (mechanical): 53 soft-deprecated `.foregroundColor(_:)` sites

`.foregroundColor(_:)` is soft-deprecated in favor of `.foregroundStyle(_:)`
(available everywhere at a macOS 15 target). 53 call sites across 5 files:
`Sources/Nehir/UI/AppRulesView.swift` (21),
`Sources/Nehir/UI/CommandPalette/CommandPaletteController.swift` (15),
`Sources/Nehir/UI/WorkspacesSettingsTab.swift` (8),
`Sources/Nehir/UI/WorkspaceBar/WorkspaceBarView.swift` (8),
`Sources/NehirApp/SettingsSceneRedirectView.swift` (1). The rest of the
codebase already uses `.foregroundStyle` — this is a half-finished migration.
Per the skill's soft-deprecation guidance this should be a dedicated mechanical
sweep, not folded into feature edits.

## Finding 4 (accessibility/modernization candidates, no plan yet)

Split into its own document 2026-07-03 with concrete evidence and options:
`discovery/20260703-command-palette-tap-gesture-accessibility-and-observable-migration.md`.
Summary retained below; that doc supersedes it and carries the design/risk
decisions.


- **Tap gestures instead of buttons.** Nine `.onTapGesture` sites act as
  activation on row/list content — six in the command palette
  (`CommandPaletteController.swift:1289,1301,1313,1404,1416,1428`), plus
  `AppRulesView.swift:629` (expander), `WorkspaceBarView.swift:603`,
  `InteractiveMoveDemo.swift:695`. Plain tap gestures are invisible to
  VoiceOver/keyboard; `Button` with a custom style is the conforming form. The
  workspace bar and onboarding demo are mouse-only surfaces by design, so the
  command palette rows and the AppRules expander are the meaningful candidates.
- **`ObservableObject` → `@Observable`.** `CommandPaletteController`
  (`CommandPaletteController.swift:165-195`, 8+ `@Published` properties) drives
  the whole palette through one `@ObservedObject`, so every keystroke
  (`searchText`) invalidates the entire palette body including the results
  list. `@Observable` would scope invalidation per-property-read. `MoveDemoModel`
  (`InteractiveMoveDemo.swift:16`) is a smaller candidate. Worth a plan only if
  palette typing latency is ever observed to matter; recorded here so the next
  palette feature doesn't add more `@Published` surface.
- **No previews anywhere.** Not a violation (checklist only constrains previews
  that exist), noted for completeness.
