# Better visual feedback on record traces

**Status:** superseded/discontinued, 2026-06-24
**Superseded by:** `completed/20260624-recent-trace-clip-buffer.md`
**Source discovery:** `discovery/20260621-better-record-trace-visual-feedback.md`
**Source list:** `planned/20260621-backlog-brainstorm.md`, UI/UX items **#1** and
**#1-related** ("Better visual feedback on record traces")

All source references were re-verified against the main Nehir source tree on
2026-06-22. Line numbers drift.

## Superseded outcome

This workspace-bar visual-feedback plan was intentionally not implemented as
written. The trace controls were moved out of the workspace bar entirely: the
workspace bar is now treated as a workspace-navigation surface, while trace
recording lives in the separate DebugBar shipped by
`completed/20260624-recent-trace-clip-buffer.md`.

Consequences:

- Do not add pulsing elapsed-time trace UI to `WorkspaceBarView`.
- Do not add a workspace-bar trace-capture button or preserve the old
  `showTraceCaptureButton` surface.
- Keep the useful lesson — trace recording needs visible feedback — but apply it
  to DebugBar / Diagnostics instead of the workspace bar.

The original plan remains below for provenance only.

## TL;DR

The Runtime Trace Capture button on the workspace bar is a **static** icon while
a capture is running: no motion, no elapsed time, and the start time is hidden
unless the user hovers. Yet the Diagnostics settings tab already computes a
live, ticking duration from the *same* `startedAt` that the bar snapshot already
carries. The two surfaces are inconsistent, and the always-visible one is the
weaker of the two.

This plan delivers the discovery's "Now" slice only: make
`TraceCaptureBarButton` in `Sources/Nehir/UI/WorkspaceBar/WorkspaceBarView.swift`
**pulse** (motion-reduce-aware) and show a **live elapsed-time badge** reusing
the `startedAt` already in the snapshot and the `TimelineView(.periodic(by: 1))`
pattern already in `DisplayDiagnosticsSettingsTab.swift`. It directly closes the
"static icon" and "no elapsed time on the bar" gaps. The menu-bar "REC"
indicator and a non-modal export toast are explicitly deferred (separate plans).

The data path needs **no** controller changes — `RuntimeTraceCaptureStatus` is
already produced by `WMController.runtimeTraceCaptureStatus`, already propagated
into the snapshot by `WorkspaceBarManager`, and the bar already rebuilds on
`workspaceBarManager.update()` at start/stop. This is pure presentation.

## Discovery corrections / decisions

The discovery recommendation is right; these are implementation refinements made
while porting it into worker-ready steps:

1. **Stronger accessibility precedent than the discovery states.** The discovery
   says "the bar already reads `accessibilityReduceTransparency`, so there is
   precedent for respecting accessibility preferences here." In fact
   `WorkspaceBarContentView` already reads *both*
   `@Environment(\.accessibilityReduceMotion)` **and**
   `@Environment(\.accessibilityReduceTransparency)`
   (`Sources/Nehir/UI/WorkspaceBar/WorkspaceBarView.swift:151`‑152) and already
   computes `effectiveAnimationsEnabled = animationsEnabled &&
   !accessibilityReduceMotion` (`:168`‑169). That flag is already threaded into
   the button's siblings (`WorkspaceItemView`, `ScratchpadPillView`) but **not**
   into `TraceCaptureBarButton`. So the cleanest port is to add an
   `animationsEnabled: Bool` parameter to `TraceCaptureBarButton` and pass
   `effectiveAnimationsEnabled` from the call site at `:221` — matching its
   siblings — rather than re-reading the env value inside the button.

2. **Share the duration formatter instead of copying it.** The discovery calls
   this "a single-file SwiftUI change." That is true for the pulse, but the
   duration formatter `formatDuration(_:)` is `private` to
   `DisplayDiagnosticsSettingsTab.swift` (`:479`‑484) and formats `M:SS` under an
   hour and `H:MM:SS` at/above an hour. Inlining a second copy in the bar button
   would create two formatters that can drift. Extract a tiny pure helper into a
   new file `Sources/Nehir/UI/TraceDurationFormatting.swift`
   (`TraceDuration.format(_ seconds: TimeInterval) -> String`) and have **both**
   the bar button and the Diagnostics tab call it. Net: one new small file, two
   edited files, all presentation-only. (If minimal diff is preferred, inlining
   the ~6-line formatter in the button is the fallback; the extracted helper is
   recommended to match the reusable-helper house style of
   `completed/20260619-m4s2-space-topology-eviction-exemption.md`.)

3. **No `@available` guards needed.** Deployment target is `.macOS(.v15)`
   (`Package.swift:16`), so `TimelineView(.periodic(by:))` (macOS 13+) and
   `.symbolEffect(.pulse, options: .repeating)` (macOS 14+) are unconditionally
   available. Confirmed; no version branching in the new code.

4. **Pulse mechanism: prefer `.symbolEffect` over a custom animator.** The
   discovery suggests "`symbolEffect`/opacity keyframes." Use
   `.symbolEffect(.pulse, options: .repeating, isActive: isActive &&
   animationsEnabled)` on the `Image`. It is system-managed (no continuous
   SwiftUI redraws driven from our code), cheap, and its `isActive` flag gives a
   single seam for the motion-reduce gate. The elapsed-time text (driven by
   `TimelineView`, 1 s tick) remains the **primary** glanceable signal so that
   under Reduce Motion (pulse disabled) the button still clearly reads as live.

5. **Accessibility: do not pump VoiceOver every second.** Keep
   `accessibilityLabel` static (e.g. "Debug: Stop Trace Capture, recording in
   progress"). Do **not** bind a per-tick `accessibilityValue` — a 1 s cadence
   would be spammy. Sighted users get the pulse + ticking text; VoiceOver users
   get a clear static label. The hover `helpText` already names the start time
   for precision.

## Scope

### Files to add/change

1. `Sources/Nehir/UI/TraceDurationFormatting.swift` **(new)**
   - Pure, `@MainActor`-agnostic helper:
     `enum TraceDuration { static func format(_ seconds: TimeInterval) -> String }`
   - Mirrors the current `DisplayDiagnosticsSettingsTab.formatDuration` logic:
     clamp negatives to 0, round to whole seconds, `M:SS` below one hour,
     `H:MM:SS` at/above one hour.
2. `Sources/Nehir/UI/DisplayDiagnosticsSettingsTab.swift`
   - Replace the `private func formatDuration(_:)` body (`:479`‑484) with a call
     to `TraceDuration.format(_:)`. Behavior identical; removes the duplicated
     logic so the bar and the Diagnostics tab can never disagree.
3. `Sources/Nehir/UI/WorkspaceBar/WorkspaceBarView.swift`
   - `TraceCaptureBarButton` (`:699`‑757):
     - Add parameter `animationsEnabled: Bool` (passed from the call site at
       `:221`‑226 as `effectiveAnimationsEnabled`, matching siblings).
     - When `isActive`, wrap the existing icon + a new elapsed-time `Text` in an
       `HStack` driven by
       `TimelineView(.periodic(from: startedAt, by: 1)) { context in ... }`,
       rendering `TraceDuration.format(context.date.timeIntervalSince(startedAt))`
       with `.font(.system(size: max(10, iconSize * 0.62),
       weight: .semibold).monospacedDigit())` (monospaced-digit precedent at
       `:681`; monospaced-design precedent at `:388`). When inactive, keep the
       current icon-only layout so bar density is unchanged at rest.
     - Add `.symbolEffect(.pulse, options: .repeating,
       isActive: isActive && animationsEnabled)` to the `Image`
       (`:731`‑733). Because `animationsEnabled` already folds in
       `accessibilityReduceMotion`, Reduce Motion disables the pulse while
       leaving the ticking elapsed text as the live signal.
     - Keep the existing `Color.red.opacity(0.16)` active background
       (`:743`‑747), `resolvedIconColor`/`symbolName` (`:710`‑716), hover
       `scaleEffect`, and `helpText` (`:722`‑727). Update `accessibilityText`
       (`:719`‑721) to "Debug: Stop Trace Capture, recording in progress" while
       active; leave the inactive label unchanged.
   - Pass `animationsEnabled: effectiveAnimationsEnabled` into the
     `TraceCaptureBarButton(...)` initializer at the call site (`:221`‑226).

### Non-goals

- Do **not** add a menu-bar / status-item "REC" indicator. That covers the
  bar-hidden / `--tracing`-launched case but touches `StatusBarController` /
  `StatusBarMenu` status-item lifecycle and is a separate plan (see Follow-ups).
- Do **not** add a non-modal export-confirmation toast/HUD on stop. There is no
  such overlay mechanism today; building one is net-new UI and a separate plan.
- Do **not** change the capture lifecycle, the `RuntimeTraceCaptureStatus`
  shape, `WMController`, or the pasteboard/log export path in
  `stopRuntimeTraceCapture()` — the data path is already sufficient.
- Do **not** alter the `--nehir-tracing` launch path or the Diagnostics-tab
  "recent captures" list / "Reveal in Finder" action.
- Do **not** change when the button is shown (`showTraceCaptureButton`:
  `showTraceButton && developerModeEnabled` at
  `Sources/Nehir/UI/WorkspaceBar/WorkspaceBarManager.swift:442`).
- Do **not** pump VoiceOver `accessibilityValue` on the 1 s tick.

## Exact implementation plan

### 1. Shared duration formatter (new file)

Create `Sources/Nehir/UI/TraceDurationFormatting.swift`:

```swift
import Foundation

/// Formats a trace-capture elapsed duration.
/// `M:SS` below one hour, `H:MM:SS` at and above one hour.
enum TraceDuration {
    static func format(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s >= 3600 {
            return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
        }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
```

This is a pure function with no SwiftUI / AppKit dependency, so it is trivially
unit-testable (see Tests).

### 2. Route the Diagnostics tab through the shared helper

In `Sources/Nehir/UI/DisplayDiagnosticsSettingsTab.swift`, delete the body of
`private func formatDuration(_ duration: TimeInterval) -> String` (`:479`‑484)
and make it forward:

```swift
private func formatDuration(_ duration: TimeInterval) -> String {
    TraceDuration.format(duration)
}
```

(Keeping the thin private wrapper avoids touching the existing call site at
`:257`; alternatively inline `TraceDuration.format` at `:257` and delete the
wrapper — either is fine, pick whichever reads cleaner.)

### 3. Animate + badge `TraceCaptureBarButton`

In `Sources/Nehir/UI/WorkspaceBar/WorkspaceBarView.swift`:

- At the call site (`:221`‑226), add `animationsEnabled: effectiveAnimationsEnabled`
  to the `TraceCaptureBarButton(...)` arguments so it receives the same
  motion-aware flag its siblings already take.

- In `TraceCaptureBarButton` (`:699`), add `let animationsEnabled: Bool` to the
  stored properties.

- Update `accessibilityText` (`:719`‑721):

```swift
private var accessibilityText: String {
    isActive ? "Debug: Stop Trace Capture, recording in progress"
             : "Debug: Start Trace Capture"
}
```

- Replace the `body`'s label content (currently a bare `Image` at `:731`‑735)
  with an active/inactive split. When inactive: the existing icon-only `Image`.
  When active: an `HStack(spacing: 3)` of the same `Image` plus the live
  elapsed-time `Text` inside a `TimelineView`:

```swift
@ViewBuilder
private var iconAndBadge: some View {
    Image(systemName: symbolName)
        .font(.system(size: max(10, iconSize * 0.7), weight: isActive ? .semibold : .medium))
        .foregroundStyle(resolvedIconColor)
        .symbolEffect(.pulse, options: .repeating, isActive: isActive && animationsEnabled)

    if isActive, let startedAt {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            Text(TraceDuration.format(context.date.timeIntervalSince(startedAt)))
                .font(.system(size: max(10, iconSize * 0.62), weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(resolvedIconColor)
                .accessibilityHidden(true)   // static label above is authoritative
        }
    }
}
```

Compose `iconAndBadge` inside the existing `Button { ... }` label in `body`,
keeping the current `.frame(width: itemHeight, height: itemHeight)` per-icon
sizing applied to the `Image`, and the existing `Color.red.opacity(0.16)` active
background (`:743`‑747), hover `scaleEffect`, `.onHover`, `.accessibilityLabel`,
and `.help(helpText)` modifiers unchanged. Ensure the `HStack` does not exceed
the bar's `itemHeight` — give the badge `lineLimit(1)` and `fixedSize()` so the
bar's measurement view (`WorkspaceBarMeasurementView`) accounts for the extra
width only while active.

Ordering: this is presentation-only; no controller or snapshot changes. The bar
already rebuilds when `startRuntimeTraceCapture()` and
`stopRuntimeTraceCapture()` call `workspaceBarManager.update()`
(`Sources/Nehir/Core/Controller/WMController.swift:3169` and `:3268`), so the
active/inactive switch and the `startedAt` value are already fresh at the
moment the button needs them. The 1 s `TimelineView` tick is self-driven and
needs no further `update()` calls.

## Tests

### `Tests/NehirTests/TraceDurationFormattingTests.swift` (new)

Pure-function tests for `TraceDuration.format(_:)` (the one piece of new logic
with no SwiftUI dependency):

1. `formatSubHourUsesMinutesColonSeconds` — `75` → `"1:15"`, `5` → `"0:05"`,
   `0` → `"0:00"`.
2. `formatAtAndAboveHourUsesHourMinuteSecond` — `3600` → `"1:00:00"`,
   `3661` → `"1:01:01"`.
3. `formatRoundsFractionalSecondsDown` — `59.9` → `"0:59"` (rounds to whole).
4. `formatClampsNegativeToZero` — `-10` → `"0:00"`.

### `Tests/NehirTests/WorkspaceBarManagerTests.swift` (existing — no-regression)

The button is a `private struct`, so the pulse/badge are not directly unit
testable. Add (or confirm already present) a no-regression assertion that the
snapshot still carries `traceCaptureStatus` and `showTraceCaptureButton`
unchanged through `WorkspaceBarManager`
(`Sources/Nehir/UI/WorkspaceBar/WorkspaceBarManager.swift:360`‑361, `:442`‑443)
when developer mode + `showTraceButton` are on. This guards against accidentally
changing the snapshot plumbing while editing `WorkspaceBarView.swift`.

### `Tests/NehirTests/DisplayEnvironmentDiagnosticsTests.swift` (existing — no-regression)

Keep green to confirm the Diagnostics tab's duration rendering is unchanged
after routing through `TraceDuration.format`. If it already asserts the
`"Recording for ..."` string, leave it; otherwise do not add view-level
assertions (the formatter tests above cover the logic).

### Manual validation (required — visual behavior)

1. Enable developer mode and `showTraceButton`; start a trace from the bar.
   Confirm the icon pulses slowly and an elapsed `M:SS` badge ticks once per
   second next to it.
2. Let it run past 60 s, then past 1 h on a long capture; confirm `M:SS` →
   `H:MM:SS` rollover matches the Diagnostics tab.
3. Enable **System Settings → Accessibility → Display → Reduce Motion**; confirm
   the pulse stops and the badge continues to tick (reduce-motion path).
4. Stop the trace; confirm the button returns to the static `record.circle` and
   the badge disappears, and the Diagnostics tab still shows the capture in its
   recent list.
5. Launch with `--nehir-tracing`
   (`WMController.traceLaunchArgument`, `Sources/Nehir/Core/Controller/WMController.swift:3323`;
   consumed in `Sources/Nehir/App/AppDelegate.swift:52` and `:104`‑105) with the
   bar visible; confirm the button is immediately pulsing + badged from boot
   (data path; this does **not** fix the bar-hidden case, which is a follow-up).

## Validation

```bash
swift build
swift test --filter TraceDurationFormatting
swift test --filter WorkspaceBarManagerTests
swift test --filter WorkspaceBarDataSourceTests
swift test --filter DisplayEnvironmentDiagnosticsTests
```

There are no repo-defined `mise run` tasks (`mise.toml` is intentionally empty)
and agents must not add any; `swift build` / `swift test` are the canonical
gates. Run the Manual validation steps above on a real host before marking
complete — the core change is SwiftUI presentation that automated tests cannot
observe directly.

Changeset (patch; developer-mode-only feature, no schema/API change): "Add a
pulsing elapsed-time badge to the workspace-bar trace-capture button."

## Risks and mitigations

- **Always-on redraw cost.** The workspace bar is continuously visible. The
  1 s `TimelineView` tick matches the safe precedent already running in the
  Diagnostics tab; `.symbolEffect(.pulse)` is system-managed (no per-frame
  SwiftUI body re-evaluation from our code). The badge is rendered only while
  `isActive`, so the cost is paid solely during a capture. If profiling during a
  long capture shows bar CPU regression, slow the tick to `.by: 2` or render the
  badge only (drop the pulse) — both are local, low-risk dials.
- **Bar width / measurement drift.** Adding a text badge while active widens the
  button. `WorkspaceBarMeasurementView` measures the snapshot; use `fixedSize()`
  + `lineLimit(1)` on the badge and verify the bar still fits in its panel at
  the smallest configured `barHeight`. The vertical-bar redesign
  (`discovery/20260621-nehir-93-vertical-workspace-bar.md`) may change available
  space; re-test layout if that lands first.
- **Two formatters drifting.** Mitigated by extracting `TraceDuration.format`
  and routing both surfaces through it; the formatter tests pin the shape.
- **Reduce Motion not respected.** Mitigated by gating the pulse on
  `animationsEnabled` (which already folds in `accessibilityReduceMotion`); the
  ticking badge remains as the non-animated live signal.
- **Scope creep onto dev-only value.** This is a developer-mode feature; the
  investment stays proportional by doing only the bar-button slice here. The
  menu-bar indicator and export toast are explicitly deferred.

## Follow-ups (out of scope)

- **Menu-bar "REC" indicator** in
  `Sources/Nehir/UI/StatusBar/StatusBarController.swift` /
  `StatusBarMenu.swift` (which today have **no** trace/record references): a red
  status-item badge or menu-item check while
  `controller.isRuntimeTraceCaptureActive` is true. This is the only surface
  that covers the bar-hidden / `--tracing`-launched case. Touches status-item
  lifecycle; warrants its own plan.
- **Non-modal export-confirmation toast/HUD.** `stopRuntimeTraceCapture()`
  writes the file, copies the path to the pasteboard, and logs
  `"Wrote runtime trace capture to <path>"
  (`Sources/Nehir/Core/Controller/WMController.swift:3251`‑252) with no on-screen
  confirmation; the only non-modal channel today is the pasteboard, and the only
  alert helper is modal (`presentInfoAlert` in `AppDelegate.swift:251` and
  `StatusBarMenu.swift:262`). A transient in-bar or Diagnostics-tab banner
  ("Trace exported — path copied") needs a new, small overlay mechanism; triage
  separately.
- **Re-evaluate bar-badge layout** once the vertical workspace bar
  (`discovery/20260621-nehir-93-vertical-workspace-bar.md`) lands, since
  available width/height for the badge may change.
