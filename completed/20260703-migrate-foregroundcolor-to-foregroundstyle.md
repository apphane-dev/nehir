# Migrate remaining `.foregroundColor` to `.foregroundStyle` — Plan

**Status:** completed — shipped on `main` in commit `ea013f2c` ("Migrate
remaining foregroundColor call sites to foregroundStyle"), merged 2026-07-03.
Moved from `planned/` to `completed/`. Pure 1:1 substitution, 53 sites across
the 5 files below; `grep '\.foregroundColor(' Sources` returns nothing on
`main`; format/lint/build green at merge. Executed by a delegated agent
(zai/glm-5.2) in a worktree. Derived from
`discovery/20260703-swiftui-conformance-audit-foreach-identity-and-deprecated-apis.md`
(Finding 3). Purely mechanical; good candidate for a bulk/cheap agent.

Validated against the main Nehir source tree on 2026-07-03 at commit `8286c192`.

---

## Problem

`.foregroundColor(_:)` is soft-deprecated in favor of `.foregroundStyle(_:)`,
which is fully available at the project's macOS 15 deployment target
(`Package.swift:16`). The codebase is mid-migration: most files already use
`.foregroundStyle`, but 53 `.foregroundColor` call sites remain in 5 files:

- `Sources/Nehir/UI/AppRulesView.swift` — 21 sites
- `Sources/Nehir/UI/CommandPalette/CommandPaletteController.swift` — 15 sites
- `Sources/Nehir/UI/WorkspacesSettingsTab.swift` — 8 sites
- `Sources/Nehir/UI/WorkspaceBar/WorkspaceBarView.swift` — 8 sites
- `Sources/NehirApp/SettingsSceneRedirectView.swift` — 1 site

## Change

In those files only, replace `.foregroundColor(X)` with `.foregroundStyle(X)`.
Notes:

- All current arguments are `Color` values (`.secondary`, `.primary`, `.red`,
  `.accentColor`, computed `Color` locals) — `Color` conforms to `ShapeStyle`,
  so the substitution is 1:1. `.foregroundColor(nil)` (no occurrences today)
  would be the only non-mechanical case; if one appears after rebase, replace
  with removing the modifier or an explicit inherited style, and call it out.
- Do not touch anything else in the files (no drive-by refactors); one commit,
  message shaped like `Migrate remaining foregroundColor call sites to foregroundStyle`.

## Validation

1. `grep -rn '\.foregroundColor(' Sources` returns nothing.
2. `swift build && swift test`.
3. Spot-check visuals: workspace bar (focused vs unfocused pill text), command
   palette (secondary icons, selected-row tint), App Rules list
   (selected-row accent, destructive red).
