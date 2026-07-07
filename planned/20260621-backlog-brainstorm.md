# Backlog brainstorm — 2026-06-21

Re-verified against main 7a025b78 on 2026-07-07.

Source: a handwritten idea list captured from a screenshot on 2026-06-21. This
document is the canonical store of that raw list. Each idea is being triaged by
a dedicated discovery agent (one idea per agent, max 3 in parallel, run as
interactive `pi` tabs in the `plans-only` herdr workspace). Discovery output for
each idea lands in `discovery/20260621-<slug>.md`.

## UI / UX

- **#1** Better visual feedback on record traces *(shipped — commit `f160254d` added the trace clip buffer and DebugBar overlay; see `completed/20260624-recent-trace-clip-buffer.md` and `completed/20260621-better-record-trace-visual-feedback-superseded.md`.)*
- **#15** Drawers? *(open question — what is a "drawer" in Nehir?)*
- **#18** Right-click actions in the action bar *(shipped — commit `d0cf6368` implements workspace-bar right-click context menus; see `completed/20260621-right-click-actions-action-bar.md`.)*
- **#19** Challenge window width vs column width (and other column-vs-window semantics)
- **#27** Separate scrolling layer for floating windows
- **#28** Per-window floating action panel
- **#1-related** Better visual feedback on record traces

## Command palette

- **#4** Command palette: fallback to all sources if no results, or use all sources by default *(shipped Variant A — fallback on empty — commit `1aa518bc`; see `completed/20260621-command-palette-fallback-all-sources.md`. Variant B unified `.all` tab still deferred.)*
- **#9** Assign hotkey for an action from the command palette *(related: `discovery/20260619-nehir-48-command-palette-hotkey-conflict.md`, planned `planned/20260621-assign-hotkey-from-command-palette.md`)*
- **#11** Fuzzy search in the command palette
- **#26** Command to create an app rule for the focused window *(shipped — commit `472f7185`; palette command + workspace-bar right-click action, assignable hotkey; see `completed/20260627-create-app-rule-for-focused-window.md`.)*
- **#29** Command to collect all windows on the current workspace

## Workspaces / window management

- **#2** Modifier + click on a workspace number to move the active window/column *(window variant shipped — commit `f4adb75f` adds shift+click on a workspace pill; column variant deferred; see `completed/20260621-workspace-number-modifier-click-move-window.md`.)*
- **#7** Multiple scratchpad window assignments
- **#8** Fix target window for commands like toggle floating / scratchpad, etc.
- **#16** Move workspace between displays *(related: `planned/20260619-nehir-62-move-workspace-to-monitor.md`, `discovery/20260619-nehir-62-move-workspace-to-next-monitor.md`)*
- **#20** Define expectations and fix niri fullscreen *(related: `discovery/20260617-nehir-69-fullscreen-restore-on-focus.md`)*
- **#21** Start-gesture-from-unsnapped-position bug
- **#23** Fix "show workspace" toggle

## Shortcuts / input

- **#22** Make all numbered hotkeys use `{N}` template
- **#24** Learn niri's Design Principles and check for mismatches
- **#25** Shortcut presets

## Display / layout

- **#3** Try implementing a virtual display to park offscreen windows without bleed *(related: `noop/20260616-omniwm-349-hidden-window-bleeds-multi-monitor.md`, `noop/20260616-omniwm-235-window-bleed-different-workspace.md`)*
- **#17** Mission Control quirks

## Config / rules / automation

- **#10** Limit float precision in config values
- **#13** Scriptable rules
- **#14** Safe mode

## Integrations / packaging / ops

- **#5** Posthog analytics
- **#6** Send reports
- **#12** Official Homebrew tap

## Notes

- "Related" links above are hints, not blockers — each discovery agent re-checks
  `discovery/`, `planned/`, `completed/`, `noop/` for prior work before writing,
  and references it rather than duplicating.
- All discovery docs follow `AGENTS.md`: repo-relative source paths, no trace-log
  filenames, no machine-specific paths, evidence inlined.
