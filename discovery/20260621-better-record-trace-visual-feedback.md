# Better visual feedback on record traces

Groom 2026-07-07: superseded — the in-workspace-bar trace-feedback plan was discontinued; trace recording moved out of the workspace bar into the separate DebugBar (see `completed/20260624-recent-trace-clip-buffer.md` and `completed/20260621-better-record-trace-visual-feedback-superseded.md`).

**Status:** discovery — pursue (small, well-scoped slice; defer larger pieces)
**Source:** `planned/20260621-backlog-brainstorm.md`, UI/UX items **#1** and
**#1-related** ("Better visual feedback on record traces").
**Investigated against:** main Nehir source tree, verified 2026-06-21.

## What this idea means for Nehir

"Record traces" is the **Runtime Trace Capture** debug feature: a developer-mode
"record" button (SF Symbol `record.circle`) that, while active, accumulates
in-memory trace rings (reconcile, viewport, resize, insertion, mouse,
raw-AX-notification, interaction-monitor) and on stop writes a multi-section
`.log` dump into the app state directory under `traces/` and copies that file
path to the pasteboard. It is the maintainer's primary diagnostic capture tool —
nearly every runtime discovery doc in this branch is grounded in a capture it
produced.

It is **not**:

- Key/hotkey recording — that is `Sources/Nehir/UI/KeyRecorderView.swift`, a
  separate `NSView`-backed binding recorder with its own
  `recordingAccessibilityLabel = "Recording hotkey"`.
- Macro recording — no such feature exists in `Sources/`.

So "better visual feedback on record traces" = make it more obvious, while a
capture is running (and when it finishes), that recording is active and for how
long. Today the always-visible indicator is a single static icon.

## Prior work (checked, not duplicated)

Searched `discovery/`, `planned/`, `completed/`, `noop/` for trace-capture UI.
Existing docs touch the feature only incidentally — none covers *in-progress
visual feedback*:

- `completed/20260610-settings-and-onboarding-redesign.md` — decides the trace
  button is **gated behind developer mode** and placed in the workspace bar
  (`showTraceButton` setting). About visibility/placement, not recording state.
- `discovery/20260621-nehir-93-vertical-workspace-bar.md` — lists the trace
  button as one of the workspace-bar trailing items to preserve in a vertical
  layout. About layout, not feedback.
- `completed/20260615-quick-terminal-close-switches-workspace.md` and others —
  consume trace captures as an investigation artifact; they do not discuss the
  capture UI.

No duplicate. This doc is the first to characterize the recording-state feedback.

## Current behavior (with source)

The capture lifecycle lives in `Sources/Nehir/Core/Controller/WMController.swift`:
`RuntimeTraceCaptureSession { startedAt; startRuntimeStateDump }` and
`RuntimeTraceCaptureStatus { isActive; startedAt }` (struct definitions near the
top of `WMController`); `toggleRuntimeTraceCapture(desiredState:)` dispatches to
`startRuntimeTraceCapture()` / `stopRuntimeTraceCapture()`. Start clears and
re-arms the trace rings and sets `runtimeTraceCaptureSession`; stop assembles the
dump body, writes it to `runtimeTraceCaptureFileURL(startedAt:endedAt:)`, calls
`copyDebugTextToPasteboard(fileURL.path)`, clears the session, and calls
`workspaceBarManager.update()`. Capture can also be auto-started at launch via
the `WMController.traceLaunchArgument` flag (checked in
`Sources/Nehir/App/AppDelegate.swift`, which calls
`controller.toggleRuntimeTraceCapture(desiredState: .active)` when
`enableTracing` is true).

There are exactly **three** user-visible feedback surfaces today:

### 1. Workspace bar button (always visible while the bar is shown)

`TraceCaptureBarButton` in `Sources/Nehir/UI/WorkspaceBar/WorkspaceBarView.swift`.
Its active/inactive rendering is:

```swift
private var resolvedIconColor: Color { isActive ? .red : (textColor ?? .secondary) }
private var symbolName: String { isActive ? "record.circle.fill" : "record.circle" }
```

When active it additionally paints `Color.red.opacity(0.16)` behind the icon and
swaps the icon weight to `.semibold`. The only time-sensitive signal is a
hover-only tooltip:

```swift
private var helpText: String {
    guard isActive else { return "Debug: Start Trace Capture" }
    guard let startedAt else { return "Debug: Stop Trace Capture" }
    let time = DateFormatter.localizedString(from: startedAt, dateStyle: .none, timeStyle: .medium)
    return "Debug: Stop Trace Capture (started at \(time))"
}
```

So on the bar: **no animation, no elapsed time, no "REC" glyph or text**, and the
start time is hidden unless the user hovers. Gated by developer mode **and**
`showTraceButton`: `WorkspaceBarManager.swift` resolves
`showTraceCaptureButton: resolved.showTraceButton && (controller?.settings.developerModeEnabled ?? false)`
and feeds `traceCaptureStatus: controller?.runtimeTraceCaptureStatus` into the
bar snapshot. (A `grep` for `phaseAnimator|KeyframeAnimator|withAnimation|TimelineView`
in `WorkspaceBarView.swift` returns nothing — the bar has no animation APIs at
all today.)

### 2. Diagnostics settings tab (rich, but buried)

`Sources/Nehir/UI/DisplayDiagnosticsSettingsTab.swift` already shows a live,
ticking duration while active:

```swift
if traceCaptureStatus.isActive, let startedAt = traceCaptureStatus.startedAt {
    Image(systemName: "record.circle.fill").foregroundStyle(.red)
    Text("Trace capture in progress").font(.headline)
    TimelineView(.periodic(from: startedAt, by: 1)) { context in
        Text("Recording for \(formatDuration(context.date.timeIntervalSince(startedAt)))")
    }
}
```

The same view toggles the button label between `"Start"` and
`"Stop and Export"`, and lists the ten most recent captures from
`WMController.traceCaptureDirectory` with a "Reveal in Finder" action. This is
good feedback — but it requires opening Settings → Diagnostics, so it is not
glanceable and gives no signal at all when the workspace bar is hidden.

### 3. Status bar / menu bar

`Sources/Nehir/UI/StatusBar/StatusBarController.swift` and
`StatusBarMenu.swift`: a case-insensitive search for `trace|record` returns
**no matches**. The menu-bar status item does not reflect capture state at all.

### On export

`stopRuntimeTraceCapture()` writes the file, copies the path to the pasteboard,
and logs `"Wrote runtime trace capture to <path>"` via
`runtimeDebugLogger` (subsystem `com.nehir`). There is **no on-screen
confirmation** of where the file went; the only non-modal affirmation mechanism
in the app is the pasteboard. The existing alert helper is modal only:
`presentInfoAlert(title:message:)` in `AppDelegate.swift` and `StatusBarMenu.swift`.

## The gap (what "better" would change)

1. **Static icon on the always-visible surface.** A "REC" indicator that does
   not move is easy to lose, especially for long captures. The capture rings are
   bounded but the session is unbounded in wall-clock time; a forgotten active
   capture silently keeps recording.
2. **No elapsed time on the bar.** The Diagnostics tab already computes it from
   the same `startedAt`; the bar does not, even though `startedAt` is already in
   the bar snapshot. The two surfaces are inconsistent.
3. **No signal when the bar is hidden / not in dev mode.** With the workspace bar
   off (or `showTraceButton` off, or developer mode off but a capture was started
   by hotkey/IPC/`--tracing`), a capture can run with **zero** visible
   indication. The `--tracing` launch path is the sharpest case: it starts a
   capture silently at boot.
4. **No export confirmation.** On stop, the file path goes to the pasteboard and
   the log, with no toast/badge. A user who stops a capture and then copies
   something else has lost the path.

## Where / how it would be implemented

The data path already exists end-to-end — `RuntimeTraceCaptureStatus`
(`isActive`, `startedAt`) is produced by `WMController.runtimeTraceCaptureStatus`,
propagated through the bar snapshot by `WorkspaceBarManager`, and the bar already
rebuilds on `workspaceBarManager.update()` at start/stop. So most of the work is
pure presentation:

- **Primary — animate + add elapsed time to `TraceCaptureBarButton`** in
  `Sources/Nehir/UI/WorkspaceBar/WorkspaceBarView.swift`. Reuse the exact pattern
  the Diagnostics tab already uses — `TimelineView(.periodic(from: startedAt, by: 1))`
  — to render `"REC 0:42"` or similar from the `startedAt` already passed into
  the button. Add a slow pulse on the icon (e.g. `symbolEffect`/opacity
  keyframes) gated on `accessibilityReduceMotion` (the bar already reads
  `accessibilityReduceTransparency`, so there is precedent for respecting
  accessibility preferences here).
- **Optional — menu-bar indicator** in
  `Sources/Nehir/UI/StatusBar/StatusBarController.swift` / `StatusBarMenu.swift`:
  a red "REC" status-item badge or menu-item check while
  `controller.isRuntimeTraceCaptureActive` is true. This is the only surface
  that covers the `--tracing`-launched / bar-hidden case.
- **Optional — export confirmation**. There is no non-modal toast/HUD today, so
  this is net-new UI. A minimal, low-risk version is a transient banner inside
  the workspace bar or Diagnostics tab ("Trace exported — path copied") rather
  than a new global overlay system. A modal `presentInfoAlert` is the wrong fit
  (interrupts the debug workflow).

## Risks and unknowns

- **Always-on redraw cost.** The workspace bar is continuously visible; a
  sub-second pulse drives continuous view rebuilds. The Diagnostics tab already
  settles on a 1 s `TimelineView` tick, which is the safe precedent. A pulse
  should be slow (≈1–1.5 s period) and must be disabled under
  `accessibilityReduceMotion`.
- **Scope creep vs. dev-only value.** This is a developer-mode feature; the
  investment should stay proportional. The bar-button slice is small and
  self-contained; the menu-bar indicator and export toast are larger and touch
  surfaces (status item lifecycle, new overlay mechanism) that warrant their own
  plans.
- **`startedAt` correctness while auto-started.** The `--tracing` launch path
  goes through the same `startRuntimeTraceCapture()`, so `startedAt` is set
  correctly; the feedback gap there is purely that the bar may be hidden, not a
  data bug.

## Open questions

- Should the bar show elapsed time as text, or keep the icon minimal and only
  pulse (text competes for space in a dense bar)? The vertical-bar redesign in
  `discovery/20260621-nehir-93-vertical-workspace-bar.md` may change available
  space.
- Is a menu-bar "REC" indicator wanted given Nehir already runs a status item,
  or is the workspace bar considered the canonical surface even when the user
  has to enable it?
- Is an export toast worth a new transient-overlay mechanism, or is
  pasteboard + the Diagnostics "recent captures" list sufficient?

## Recommendation

**Pursue**, phased:

1. **Now (small, high-value):** make `TraceCaptureBarButton` pulse
   (motion-reduced-aware) and show a live elapsed-time badge, reusing the
   `startedAt` already in the snapshot and the `TimelineView(.periodic(by: 1))`
   pattern already in `DisplayDiagnosticsSettingsTab.swift`. This is a
   single-file SwiftUI change in `Sources/Nehir/UI/WorkspaceBar/WorkspaceBarView.swift`
   and directly closes the "static icon" and "no elapsed time on the bar" gaps.
2. **Defer (separate plans):** the menu-bar "REC" indicator (covers the
   bar-hidden / `--tracing` case) and a non-modal export confirmation toast.
   Both are larger, touch other subsystems, and should be triaged on their own.

**Drop nothing** — the idea is valid and the maintainer listed it twice (#1 and
#1-related). The smallest slice is low-risk and immediately improves the
always-visible surface.
