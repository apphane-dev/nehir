# Upstream cleanup-sweep regroom — issues bulk-closed `not_planned` on 2026-05-05

On 2026-05-05 between 19:34:02Z and 19:36:04Z upstream bulk-closed **27 open
issues as `not planned`** in a triage cleanup — roughly one every two seconds,
with no per-issue investigation, reproduction, or discovery. (Three more issues
closed the same day — BarutSRB/OmniWM#294, BarutSRB/OmniWM#267,
BarutSRB/OmniWM#259 — were closed `completed` individually and are **not** part
of the sweep.)

This document regrooms the full sweep against Nehir: every swept issue is
listed, mapped to the Nehir planning doc that tracks it (16 were already
groomed in the June 16–21 rounds), and the 11 previously untracked ones get an
inline verdict here. Nehir-side evidence was verified against the main Nehir
source tree at `0b9a1560` on 2026-07-12.

Upstream issues are cited with the full cross-repo form
(`BarutSRB/OmniWM#150`), never bare `#150` — bare numbers refer to Nehir's own
tracker (see `AGENTS.md`).

**Verdict legend:** 🔴 open — owns an action · 🟡 verify / fold-in / decision ·
🟢 already present or solved in Nehir · ⚪ N/A for Nehir.

---

## Already-tracked issues (16)

| Upstream issue | Title | Tracking doc | Status |
| --- | --- | --- | --- |
| BarutSRB/OmniWM#255 | Vertical workspace bar | `discovery/20260621-nehir-93-vertical-workspace-bar.md` (nehir #93) | open feature |
| BarutSRB/OmniWM#253 | balance-sizes only distributes active column | `noop/20260617-omniwm-253-balance-sizes-dwindle-active-column.md` | noop |
| BarutSRB/OmniWM#246 | Windows overlapping | `noop/20260616-omniwm-246-focus-move-overlap.md` | ✅ solved in Nehir codebase |
| BarutSRB/OmniWM#244 | Native fullscreen still counted as a window | `noop/20260617-omniwm-244-native-fullscreen-counted-and-leak.md`; fullscreen behaviour continues in `planned/20260622-fullscreen-behaviour-roadmap.md` | noop + follow-up planned |
| BarutSRB/OmniWM#242 | Tab indicators overlap floating windows | `noop/20260617-omniwm-242-tab-indicators-overlap-floating-windows.md` | not reproduced in Nehir; most likely fixed upstream before the fork |
| BarutSRB/OmniWM#240 | Focus previous window across workspaces | `completed/20260616-omniwm-240-focus-previous-cross-workspace.md` | **✅ solved in Nehir** (`30faf8f3`; nehir #92, <https://github.com/apphane-dev/nehir/issues/92>) |
| BarutSRB/OmniWM#239 | Inconsistent mouse warping | `noop/20260617-omniwm-239-inconsistent-mouse-warping.md` | noop |
| BarutSRB/OmniWM#235 | Window bleeds into different workspace | `noop/20260616-omniwm-235-window-bleed-different-workspace.md` | ✅ solved in Nehir codebase |
| BarutSRB/OmniWM#233 | Center-on-overflow with two 50% windows | `noop/20260616-omniwm-233-center-on-overflow-two-fifty-columns.md` | ✅ solved in Nehir codebase |
| BarutSRB/OmniWM#226 | Hotkeys overridden by Chrome extension shortcuts | `discovery/20260616-omniwm-226-chrome-extension-hotkey-priority.md`, `planned/20260621-omniwm-226-chrome-extension-hotkey-priority.md`; related shipped work in `completed/20260619-nehir-48-command-palette-hotkey-conflict.md` | planned |
| BarutSRB/OmniWM#223 | Border does not follow moved floating window | `noop/20260617-omniwm-223-floating-border-tracking.md`; Nehir border work shipped via `completed/20260619-nehir-66-borders-undecorated-windows.md` | noop / solved-adjacent |
| BarutSRB/OmniWM#218 | Tab indicators misplaced after workspace change | `noop/20260617-omniwm-218-tab-indicators-misplaced-after-ws-change.md` | not reproduced; most likely fixed upstream before the fork |
| BarutSRB/OmniWM#216 | Niri right-scroll animation broken | `noop/20260617-omniwm-216-niri-right-scroll-animation.md` | most likely fixed upstream before the fork |
| BarutSRB/OmniWM#206 | Second monitor left/right sides inaccessible | `noop/20260617-omniwm-206-vertical-warp-axis-side-edges.md` | fixed upstream before the fork |
| BarutSRB/OmniWM#194 | Windows don't open on focused display | `noop/20260617-omniwm-194-windows-open-on-wrong-monitor.md` | noop |
| BarutSRB/OmniWM#150 | Screenshot of focused (bordered) window is blank | `completed/20260617-omniwm-150-screenshot-bordered-window-blank.md` | **✅ solved in Nehir** (`d88a5da2` — hide focus borders during macOS screenshot chords) |

## Previously untracked issues (11) — regroomed here

### BarutSRB/OmniWM#247 — Mouse glitching at monitor boundary — 🟡 verify

Reporter (secondary monitor left of primary, macOS 26.4): gliding the cursor
"on a certain level" makes the pointer "jump back and forth" at the display
boundary; also occurs at the bottom edge. No version pinned beyond "latest
build", no video, no warp-setting details — no reasonable reproduction.

Nehir side: this is the mouse-warp family already groomed as
`noop/20260617-omniwm-206-vertical-warp-axis-side-edges.md` and
`noop/20260617-omniwm-239-inconsistent-mouse-warping.md`. Nehir has an explicit
warp-axis policy (`Sources/Nehir/Core/Config/MouseWarpAxis.swift`) and
FFM cursor-warp suppression shipped in
`completed/20260619-m3-ffm-cursor-warp-suppression.md`. No Nehir report of
boundary ping-pong exists. **Verdict: no action without a Nehir repro; if one
arrives, treat as a warp-axis/FFM-suppression interaction at display seams.**

### BarutSRB/OmniWM#236 — Natural scrolling option in overview — 🟡 open feature candidate

Request: an option to invert scroll direction in the overview.

Nehir has an overview
(`Sources/Nehir/Core/Layout/Niri/NiriOverviewSnapshot.swift`), and grep for
`naturalScroll` / `scrollDirection` / `invertScroll` across `Sources/Nehir` is
empty — no such option exists. Small, well-bounded settings feature.
**Verdict: legitimate small feature candidate; open a Nehir ticket if overview
scroll-direction complaints arrive.**

### BarutSRB/OmniWM#225 — Workspace bar mispositioned after wake (multi-monitor) — 🟡 verify

Reporter (v0.4.7.3): after logging in from sleep, the secondary monitor's
workspace bar sometimes renders on the primary monitor; hide toggle stops
working for it; restart required.

Nehir's workspace bar has been substantially rewritten since
(`completed/20260623-workspace-bar-reactive-viewport-lens.md`), but
wake/display-reconfiguration repositioning has not been specifically
verified. **Verdict: unreproduced on Nehir; watch for a sleep/wake
multi-monitor bar-misplacement report before investing. If reproduced, start
from display-reconfiguration handling for bar surfaces.**

### BarutSRB/OmniWM#217 — Maximum width/height app rules — 🟡 fold-in candidate

Request: per-app **maximum** width/height rules (e.g. cap a music player at
25% width), complementing existing minimums.

Nehir has a lone-window max width (`loneWindowMaxWidth`,
`Sources/Nehir/Core/Config/CanonicalTOMLConfig.swift:113`) but no per-app
max-size rule (`Sources/Nehir/Core/Rules/WindowRuleEngine.swift` has only a
hard-coded Gecko dialog max width at `:343`). **Verdict: fold into the
per-app width-rule work already planned as
`planned/20260621-omniwm-283-per-app-initial-column-width.md` — a max-width
constraint is the natural second field of the same rule surface.**

### BarutSRB/OmniWM#214 — Hotkey cycling active workspace across monitors — 🟢 already tracked (nehir #62)

Request: a hotkey that moves the current workspace to the next monitor,
cycling through all monitors.

This is exactly `planned/20260619-nehir-62-move-workspace-to-monitor.md`
(nehir #62, `moveWorkspaceToMonitor(.next/.previous)` with wrap-around); the
plan now carries the upstream cross-reference. **Verdict: tracked; not yet
shipped (plan still in `planned/`).**

### BarutSRB/OmniWM#195 — Quake terminal opacity changes on new tab — ⚪ N/A

Upstream's embedded Ghostty/Quake terminal does not exist in Nehir (grep
`quake` across `Sources/Nehir` is empty; same conclusion as the 0.5.3 sweep in
`discovery/20260707-upstream-post-roadmap-candidates.md`). **Verdict: N/A.**

### BarutSRB/OmniWM#192 — Revisit shortcut defaults — 🟡 live decision item for Nehir

Reporter: default Option+Arrow / Option+Shift+Arrow bindings clash with
ubiquitous editor bindings (move/duplicate line, word-wise cursor
movement/selection) and Option+Enter in terminal agents.

**This one is live in Nehir.** The default catalog still ships Option+Arrow
focus bindings (`Sources/Nehir/Core/Input/ActionCatalog.swift:194-212` —
Option+Left/Down/Up/Right) and Option+Shift+Arrow moves (`:382`), exactly the
clashing set. Nehir already has advisory hotkey-conflict machinery
(`completed/20260619-nehir-48-command-palette-hotkey-conflict.md`,
`discovery/20260622-nehir-103-command-palette-advisory-symbolic-hotkey-gating.md`).
**Verdict: worth a real decision pass on default bindings — a defaults-revisit
discovery of its own, not a code bug.**

### BarutSRB/OmniWM#189 — [IPC/CLI] Issues Only — ⚪ N/A (meta-thread)

Not a defect: upstream's consolidation thread for feedback on their IPC/CLI
release. Nehir's IPC direction is already groomed separately
(`noop/20260617-omniwm-307-ipc-secret-file-swift-native.md`). **Verdict: N/A.**

### BarutSRB/OmniWM#181 — Inertial / momentum scrolling — 🟢 already present

Request: momentum scrolling so viewport motion doesn't stop dead when input
stops.

Nehir already consumes trackpad momentum phases
(`Sources/Nehir/Core/Controller/MouseEventHandler.swift:145-155`, `:418`,
`:547` — `momentumPhase` plumbed through gesture handling) and has an active
body of fling/overshoot tuning work
(`discovery/20260707-lone-column-fling-snaps-to-offscreen-overscroll-bound.md`,
`completed/20260701-fix-trackpad-recognition-debt-and-release-projection.md`).
**Verdict: capability present; remaining work is tuning, already tracked.**

### BarutSRB/OmniWM#180 — Remember window positions after restart — 🟢 largely present

Request (v0.4.4): window arrangement lost across restarts.

Nehir persists a durable window-restore catalog across restarts
(`Sources/Nehir/Core/Config/RuntimeStateStore.swift:12` —
`RuntimeState.windowRestoreCatalog: PersistedWindowRestoreCatalog?`, saved and
reloaded at `:44-82`) and has monitor-identity-agnostic restore shipped
(`completed/20260618-monitor-identity-agnostic-restore.md`) plus the restore
groundwork in `discovery/20260615-omniwm-390-workspace-restore-and-stale-selection.md`.
**Verdict: substantially solved in Nehir; only gaps found via real repro
should reopen it.**

### BarutSRB/OmniWM#131 — Menubar menu not keyboard-navigable — 🟢 N/A by construction

Upstream's status-item menu could not be driven by Tab/arrows/Space/Enter.

Nehir's status menu is a native AppKit `NSMenu` built from `NSMenuItem`s
(`Sources/Nehir/UI/StatusBar/StatusBarMenu.swift:50-57`,
`StatusBarController.swift:15`), which inherits macOS's standard menu keyboard
navigation (arrows, Return, Escape, type-select). **Verdict: not applicable —
the accessibility gap was in upstream's custom menu implementation. Re-check
only if custom hosted views are ever added to the menu.**

---

## Verdict tally (27 swept issues)

- **✅ solved in Nehir:** 5 — BarutSRB/OmniWM#150 (screenshot border,
  `d88a5da2`), BarutSRB/OmniWM#240 (focus previous cross-workspace, `30faf8f3`,
  nehir #92), and BarutSRB/OmniWM#246, BarutSRB/OmniWM#235,
  BarutSRB/OmniWM#233 (solved in the Nehir codebase).
- **Fixed upstream before the fork (not reproduced in Nehir):** 4 —
  BarutSRB/OmniWM#242, BarutSRB/OmniWM#218, BarutSRB/OmniWM#216,
  BarutSRB/OmniWM#206.
- 🟢 **present / tracked / N/A-by-construction (new verdicts):** 4 —
  BarutSRB/OmniWM#214 (nehir #62 planned), BarutSRB/OmniWM#181 momentum, BarutSRB/OmniWM#180 restore
  catalog, BarutSRB/OmniWM#131 native menu.
- 🟡 **verify / fold-in / decision (new verdicts):** 5 — BarutSRB/OmniWM#247,
  BarutSRB/OmniWM#236, BarutSRB/OmniWM#225, BarutSRB/OmniWM#217, BarutSRB/OmniWM#192. Of these, **BarutSRB/OmniWM#192 (shortcut defaults) is the only one
  with confirmed live exposure in Nehir source** and deserves its own
  follow-up discovery.
- ⚪ **N/A (new verdicts):** 2 — BarutSRB/OmniWM#195 (no Quake terminal),
  BarutSRB/OmniWM#189 (meta-thread).
- **Previously groomed (June rounds), still open or noop:** 8 remaining
  tracked issues per the table above (5 noop — BarutSRB/OmniWM#253,
  BarutSRB/OmniWM#244, BarutSRB/OmniWM#239, BarutSRB/OmniWM#223,
  BarutSRB/OmniWM#194 — plus BarutSRB/OmniWM#226 planned, BarutSRB/OmniWM#255
  open feature; BarutSRB/OmniWM#244 also has planned fullscreen follow-up).
