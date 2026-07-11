# BarutSRB/OmniWM#254 — "Cmd+Shift+4 screenshot makes window shift" — Discovery

Source issue: <https://github.com/BarutSRB/OmniWM/issues/254>
Scope of this doc: determine whether the symptom reproduces in nehir — taking a
Cmd+Shift+4 selection screenshot causes tiled windows to shift/resize.

All file/line references were verified against the Nehir source tree
at `904df02` ("Add bunch of discoveries mapped to issues from OmniWM"). Re-verify
before implementing; line numbers drift.

> **Filed under `discovery/noop/` — duplicate.** This issue is the exact bug that
> upstream PR BarutSRB/OmniWM#385 targeted, and its root cause is already fully analyzed (and
> resolved as not-applicable to nehir) in the sibling discovery
> [`noop/20260616-omniwm-385-screenshot-selection-suppression.md`](./20260616-omniwm-385-screenshot-selection-suppression.md).
> nehir owns **no new action** for BarutSRB/OmniWM#254 beyond what that doc already records.

---

## TL;DR

- **Already covered by the BarutSRB/OmniWM#385 sibling discovery.** A Cmd+Shift+4 left-drag
  screenshot selection cannot start nehir's move/resize paths, and untracked
  screencapture overlay surfaces cannot relayout tracked tiled windows.
- **Verdict:** ⚪ **Won't port / Not applicable** (duplicate of BarutSRB/OmniWM#385's result).

## Why this is a duplicate

PR BarutSRB/OmniWM#385 (`https://github.com/BarutSRB/OmniWM/pull/385`) was authored to fix **this
issue (BarutSRB/OmniWM#254)**. The sibling doc
`noop/20260616-omniwm-385-screenshot-selection-suppression.md` already establishes,
against the nehir codebase, that the symptom is not reachable:

- A Cmd+Shift+4 selection drag is a left-button drag. nehir's left-button
  interactive **move** requires Option (`.maskAlternate`,
  `MouseEventHandler.swift:878`), and interactive **resize** is right-button-only
  with the configured resize modifier (`MouseEventHandler.swift:927`). A
  Command+Shift screenshot gesture satisfies neither begin-gate.
- If neither `state.isMoving` nor `state.isResizing` is entered, subsequent drag
  callbacks are inert for layout (`MouseEventHandler.swift:999`, `:1039`).
- CGS frame events from an untracked screencapture overlay are stopped by
  tracked-entry membership before any relayout (`AXEventHandler.swift:690`), and
  ordinary SkyLight visible-window enumeration ignores non-0/3/8 window levels
  (`SkyLight.swift:486`), excluding high-level system capture chrome.

## Recommendation

**Do nothing.** No new action is owned here. If a future nehir runtime
reproduction shows Cmd+Shift+4 actually starting an interaction or relayout,
follow the path described in the BarutSRB/OmniWM#385 sibling doc's Recommendation (a first-class
`isFrontmostAppScreenCapture` abstraction with tests proving both suppression
during capture and immediate resumption afterward).
