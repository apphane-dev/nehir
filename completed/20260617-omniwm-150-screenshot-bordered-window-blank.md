# OmniWM issue #150 — "Screenshot of bordered window is blank" — Discovery

**Status: ✅ RESOLVED — shipped on `main` as `d88a5da2` ("Hide focus borders
during macOS screenshots").** Verified against the main Nehir source tree on
2026-07-11. The fix hides focus borders while a macOS screenshot shortcut /
picker is active, so "Capture Selected Window" captures the app window. This is
the approach this discovery recommended.

History:
- 2026-06-17: filed from OmniWM #150; verdict 🟡 partial — nehir's own capture
  exclusion protected overview thumbnails, but the native macOS screenshot
  window-picker case was unguarded.
- 2026-07-07 groom: still applicable — partial (verified against main
  `7a025b78`).
- 2026-07-11: investigated further, several window-property fixes falsified at
  runtime (see "Approaches ruled out"), landed the screenshot-shortcut
  suppression fix.

Source issue: https://github.com/BarutSRB/OmniWM/issues/150 (closed, **not
planned**; cleanup close, not a code fix).

---

## TL;DR

- The focus border is a **separate transparent SkyLight window larger than the
  target** (default `.outside` placement inflates the target frame by
  `borderWidth + padding`; canvas cleared transparent except the ring). When the
  native screenshot window-picker hit-tests the topmost window over the target,
  it selects the border window and captures its near-blank canvas — only the
  ring on a transparent/blank field.
- **Root cause (corrected):** on macOS 15+, "Capture Selected Window" enumerates
  selectable windows via `SCShareableContent` and captures the **compositor
  framebuffer**. `CGWindowListCreateImage` (which honored `sharingType` /
  window tags) is obsoleted. **No per-window property — sharing state, window
  tags, window level, or window shape — can hide a composited window from the
  modern picker/capture.** nehir's existing `capturePolicy: .excluded` only
  guards nehir's *own* ScreenCaptureKit overview thumbnails, not the system
  picker.
- **Fix that shipped:** detect the standard macOS screenshot **keyboard
  shortcuts** (⌘⇧3/4/5) via the existing event tap — this fires *before* the
  system picker enumerates windows — hide all focus borders for the duration,
  and restore them when the interaction ends.

## Resolution (as shipped in `d88a5da2`)

Four files, ~188 lines, no test changes (per the project rule to let the user
confirm the real repro before adding regression tests).

1. **Entry signal — intercept the screenshot chord.**
   `MouseEventHandler`'s CGEventTap now also taps `.keyDown`
   (`Sources/Nehir/Core/Controller/MouseEventHandler.swift:2399`). On a
   ⌘⇧ chord with key code 20/21/23 (the `3`/`4`/`5` keys) it calls
   `ServiceLifecycleManager.handleSystemScreenshotShortcut(keyCode:)`
   (`:2407`). Because this is the same chord macOS uses, suppression begins
   *before* the picker opens and enumerates windows — there is no
   border-visible-at-enumeration race. The tap does **not** consume the event
   (returns `false`); macOS still gets the shortcut.

2. **Suppression state on the border controller.**
   `FocusBorderController.setScreenshotCaptureSuppressed(_:)`
   (`Sources/Nehir/Core/Border/FocusBorderController.swift:193`) sets
   `isScreenshotCaptureSuppressed` and hides the border; `refresh(...)`
   early-returns while suppressed (`:75`) so no focus change re-shows a border
   mid-capture. Clearing suppression reapplies the border for the confirmed
   managed-focus token.

3. **Exit signal (the subtle part).**
   `ServiceLifecycleManager.handleSystemScreenshotShortcut`
   (`Sources/Nehir/Core/Controller/ServiceLifecycleManager.swift:276`):
   - Full-screen capture (⌘⇧3, key code 20) has no interactive picker → restore
     after a 750 ms timeout.
   - Interactive capture (⌘⇧4/5) → poll `isScreenshotPickerWindowVisible`
     (`:368`) every 100 ms: it looks for a `com.apple.screencaptureui`-owned
     window at **layer ≥ 1000** (the transient interactive controls; the
     persistent transparent backing window sits at layer 24). Once such a window
     has been observed and then disappears, restore. A 30 s safety timeout
     bounds it.
   - `Escape` key-down and `leftMouseUp` also call
     `handlePotentialScreenshotInteractionCompletion()` (`:327`, wired at
     `MouseEventHandler.swift:2409`, `:2463`) for a prompt 300 ms-debounced
     restore after capture/cancel.
   - A **generation counter** (`screenshotShortcutSuppressionGeneration`)
     invalidates stale async restore tasks when chords overlap; teardown cancels
     the visibility task and clears the flag.

## Approaches ruled out (falsified at runtime — do not retry)

These were tried on branch `border-screenshot-capture-fix` and each disproven
against the running app before landing the shortcut approach:

1. **Sharing-state exclusion** (`SLSSetWindowSharingState` → `sharing=0`): the
   border already showed `kCGWindowSharingState=0` in `CGWindowListCopyWindowInfo`
   yet the picker still selected it. The modern picker ignores sharing state.
2. **Hollow window shape** (`SLSSetWindowShape` fed a 4-strip ring region from
   `CGSNewRegionWithRectList`): region built and applied with `CGError=0` and
   geometrically-correct rects, but the border rendered **invisible**. Also
   would not help — the capture is compositor-level, not shape-hit-tested. (The
   attempt reused the full-rect path's `-9999,-9999` shape origin sentinel for a
   sub-region; unconfirmed whether that alone caused the invisibility.)
3. **Window-tag sweep**: a DEBUG `SCShareableContent` oracle swept tag bits
   34/37/38/55/58/62 and combinations; for every candidate the border stayed in
   `SCShareableContent.windows` while visible (`present=true onScreen=true
   alpha=1.0 layer=3`). No tag removes it.
4. **Window level**: pinned at 3 — must stay above the app window (layer 0) and
   below the menubar (layer 24); not a usable lever.

Note: nehir's border code mirrors **FelixKratz/JankyBorders** (identical window
tags `(1<<1)|(1<<9)`, same `SLSNewWindow`/level/shape plumbing). JankyBorders
has not solved system-screenshot exclusion either.

## Pitfalls / lessons

- **`com.apple.screencaptureui` stays resident between captures.** A first-cut
  design based on `NSWorkspace` launch/terminate notifications for that agent is
  unreliable: the process does not terminate when the picker closes. The shipped
  fix keys *entry* off the keyboard chord and *exit* off the picker's transient
  high-level (layer ≥ 1000) control window disappearing — not process lifecycle.
- **`CGWindowListCopyWindowInfo` querying the border:** `.optionIncludingWindow`
  alone returned no entry for the private SLS border window; enumerate with
  `.optionOnScreenOnly` and match `kCGWindowNumber == wid` instead.
- **Oracle validity:** an `SCShareableContent` sweep that starts before the
  border is ordered on-screen yields a false "no candidate" result — require a
  valid baseline (border present, on-screen, alpha > 0, layer 3) before trusting
  the sweep.
- **The 2026-07-11 root cause was initially over-attributed to the floating
  window level (3).** That is wrong: the level is merely how the border sits
  above the app; any on-top selectable window with a superset frame is picked
  regardless. The real, load-bearing cause is compositor-level capture on macOS
  15+, so exclusion had to move to hiding the border, not re-flagging the window.
- Env-var gating (`NEHIR_EXPERIMENT_*`) for the DEBUG sweep added friction in a
  dedicated worktree; automatic DEBUG-build behavior was preferable there.

## Provenance: is this nehir's code? (retained from original investigation)

Yes. The border pipeline is nehir's own:

- `FocusBorderController` updates the visual border on focus change and hands the
  focused window ID to `BorderManager`
  (`Sources/Nehir/Core/Border/FocusBorderController.swift`).
- `BorderManager` creates/registers a `BorderWindow` when borders are enabled
  (`Sources/Nehir/Core/Border/BorderManager.swift`).
- `BorderWindow` is a separate SkyLight window, expanded around the target,
  cleared transparent in the center, filled only in the ring outside the target
  (`Sources/Nehir/Core/Border/BorderWindow.swift`).

Borders ship disabled by default
(`Sources/Nehir/Core/Config/SettingsExport.swift`), so the symptom only affects
users who enable borders and use the native whole-window screenshot mode.

nehir's pre-existing mitigation — border surfaces registered as
`capturePolicy: .excluded` / `hitTestPolicy: .passthrough`
(`Sources/Nehir/Core/Border/BorderManager.swift`) — only protects nehir's own
overview capture, which filters `SCShareableContent` through
`ownedWindowRegistry.isCaptureEligible`
(`Sources/Nehir/Core/Overview/OverviewController.swift`). It never guarded the
system picker; that is what `d88a5da2` adds.

## Follow-ups

- No regression test shipped (project rule: user validates the runtime repro
  first). A durable check is awkward here — it depends on the live system
  screenshot UI. If revisited, a manual release-check case is the realistic
  option: enable borders, ⌘⇧4 then Space on a focused window, confirm the capture
  shows app content and the border returns after dismissal.
- The scripted `screencapture` CLI does **not** launch `screencaptureui`, so it
  is not covered by shortcut detection. Not the reported case; note it if a CLI
  report appears.
