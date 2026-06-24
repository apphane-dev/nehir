# Recent trace clip buffer for dev mode

**Status:** completed, 2026-06-24
**Source:** maintainer request, 2026-06-24 — improve the existing explicit
Runtime Trace Capture flow with a bounded recent-clip buffer, without adding a
second background-recording mode.

All source paths below refer to the main Nehir repository. Line numbers in older
trace/report plans are expected to drift.

## Actual implementation shipped

The completed slice differs from the early always-on wording: there is **no**
separate background-recording mode and no separate background-buffer enable
toggle. The retained recent buffer is scoped to the existing explicit Trace
Capture session.

Implemented behavior:

- `WMController` owns a session-scoped `BackgroundTraceBuffer` and draft store.
  Trace producers fan out to the normal full-session trace arrays and the recent
  buffer only while Trace Capture is active.
- Starting Trace Capture clears and arms the recent buffer. Stopping Trace
  Capture exports the full trace, copies either the path or file according to the
  DebugBar copy-mode setting, and clears the retained buffer/drafts.
- Reset Buffer clears retained events and drafts without stopping an active trace
  capture; recording continues into a fresh empty buffer.
- `BackgroundTraceBuffer` supports byte and time eviction, unlimited retention
  with `0`, draft snapshots, range selection, category counts, and truncated event
  markers.
- Retention presets shipped as `Unlimited`, `30 sec`, `1 min`, and `2 min`.
  Longer 5/15 minute presets were removed from the initial UI.
- Diagnostics keeps trace/debug configuration and recent-trace listing, refreshes
  while open, omits redundant subheaders, and links to Hotkeys with a Back to
  Diagnostics affordance.
- The workspace-bar trace button was removed. Debug controls moved to a separate
  draggable DebugBar surface controlled by a status-menu toggle.
- The DebugBar is a separate `NSPanel`, not a `WorkspaceBarPanel`; it uses a
  normal AppKit container around `NSHostingView` to avoid SwiftUI/window sizing
  feedback loops.
- DebugBar position is stored in runtime state and restored/clamped on launch.
  Its panel can be dragged into the menu-bar region.
- DebugBar shows action buttons for Record/Stop and Reset, lighter inline
  controls for retention and copy mode (`Path` / `File`), and no low-signal
  buffer byte/event count.
- IPC keeps `debug-capture-recent-trace` for scripted workflows, but recent-clip
  export is not exposed as a default hotkey/command-palette action in this slice.
- Tests were updated after implementation: the full test suite passed with 1321
  tests in 108 suites.

Primary source files:

- `Sources/Nehir/Core/Diagnostics/BackgroundTraceBuffer.swift`
- `Sources/Nehir/Core/Controller/WMController.swift`
- `Sources/Nehir/UI/DebugBar/DebugBarManager.swift`
- `Sources/Nehir/UI/DisplayDiagnosticsSettingsTab.swift`
- `Sources/Nehir/UI/StatusBar/StatusBarMenu.swift`
- `Sources/Nehir/Core/Config/RuntimeStateStore.swift`
- `Sources/Nehir/Core/Config/SettingsExport.swift`
- `Sources/Nehir/Core/Config/SettingsStore.swift`
- `Sources/Nehir/Core/Config/CanonicalTOMLConfig.swift`
- `Sources/NehirIPC/IPCModels.swift`
- `Sources/NehirIPC/IPCAutomationManifest.swift`

## Key learnings from diagnostics tab work (2026-06-24)

While implementing the diagnostics tab controls for the background trace buffer,
several UX and architectural decisions were validated and revised:

1. **Diagnostics tab grouping matters, but avoid extra labels.** Trace actions
   and runtime-state actions belong together under a single "Debug Actions"
   section, but intermediate labels such as "Trace capture" / "Runtime state"
   should be omitted when the rows are already self-explanatory. The trace file
   list should sit immediately after actions so the user can see exported results
   right where they triggered them. A `Divider()` between sub-sections creates an
   unwanted empty row in a SwiftUI `Form` and was removed.

2. **Disable conditions must be honest.** "Capture Recent Trace" and "Reset
   Buffer" should not appear as unexplained disabled Settings buttons while trace
   capture is idle. The real gating condition is a running Trace Capture session
   with a retained session buffer. Zero-events is a transient state, not a
   configuration problem; either hide contextual actions until useful or explain
   the active trace requirement beside them.

3. **Status labels should distinguish success from failure.** A single generic
   "runtime action status" conflated trace and runtime-state feedback and always
   used a green check. A dedicated `ActionStatusLabel` that detects failure
   prefixes ("Couldn't", "Failed") and shows red is clearer.

4. **"red REC session" is poor explanatory text.** Users do not know what "red
   REC" means. Use plain language: "Start recording before a known repro. Stop
   exports one .log file and copies its path."

5. **No separate background trace action.** The recent buffer should not have
   its own independent enable/record action. The user starts trace capture
   explicitly with the existing toggle. The buffer is a passive retention layer
   inside that running session; the user only decides *when to save a clip* from
   it. This simplifies the mental model: one trace recording mode, one retention
   layer, one export action.

6. **Reset buffer should be effective even during active trace capture.** If the
   user resets the buffer while a trace is recording, the reset should clear the
   buffer without stopping the recording. The recording continues to append to
   the new empty buffer. This avoids the confusing state where reset is disabled
   during recording.

7. **Separate DebugBar surface, not workspace bar reuse.** The workspace bar is
   a workspace-navigation surface. Debug trace controls are orthogonal. Introduce
   a separate DebugBar (or debug overlay) surface that appears only in Developer
   Mode. This keeps the workspace bar clean and gives debug affordances their own
   dedicated space. Workspace bar trace toggle buttons are removed in favor of
   the DebugBar.

8. **Retention window default should be unlimited (0).** The default retention
   window of 5 minutes in the plan was too restrictive for a developer debugging
   tool. Default to 0 (unlimited, bounded only by the byte cap) so the buffer
   retains everything until memory pressure or the byte cap kicks in. Users who
   want automatic pruning can set a positive retention window.

9. **Do not expose a separate background-recording control.** The buffer is not
   independently enabled or recorded. It is an implementation detail of the
   existing explicit Trace Capture session. When the user starts Trace Capture,
   Nehir also retains a bounded recent window for clip export; when that session
   ends or Developer Mode turns off, the retained window is cleared.

10. **Avoid dead controls in Diagnostics.** Disabled buttons such as "Capture
    Recent Clip" and "Reset Buffer" in Settings are confusing when trace capture
    is idle: the user cannot act on them and they read like missing setup. The
    Diagnostics tab should keep persistent configuration and status there, but
    contextual actions should be hidden until useful or shown with an explicit
    active trace status. The DebugBar is the primary always-nearby action surface.

11. **Avoid unnecessary intermediate labels.** In the Diagnostics "Debug Actions"
    section, labels such as "Trace capture" and "Runtime state" are only useful
    if they disambiguate multiple adjacent rows. If each row already has a clear
    title and button, omit the extra labels to reduce vertical noise.

12. **Diagnostics must stay in sync with DebugBar actions.** If Trace Capture is
    stopped from the DebugBar while Settings is open, Diagnostics must refresh its
    active/idle state and recent trace list without requiring tab/window reload.
    A lightweight periodic refresh or explicit notification from the controller is
    acceptable.

13. **Hotkey deep links need a way back.** The Diagnostics "Assign in Hotkeys"
    shortcut should seed the Hotkeys search to debug commands and show a clear
    "Back to Diagnostics" affordance. Debug-only actions that are primarily
    DebugBar buttons, such as recent-clip export, should not clutter hotkey
    assignment unless there is a strong standalone shortcut use case.

## Revised direction

The plan below is updated to reflect these learnings. The core architecture
(bounded recent buffer + draft + export) remains the same, but the buffer is now
scoped to the existing explicit trace-capture session rather than being a
separately enabled background recorder.

## TL;DR

Add a **developer-mode-only recent trace clip buffer** to the existing explicit
Runtime Trace Capture flow. When the user starts Trace Capture, Nehir records the
same diagnostic event families as today and also retains the recent N minutes / M
bytes in a bounded local ring for clip export. It is **not** an always-growing
trace file, **not** an automatic upload, and **not** a separate recording mode.

When the user needs a recent clip, the controller can freeze the currently
retained session window as a temporary draft and export a selected range. The UI
slice kept this out of the default DebugBar/hotkey flow; scripted workflows can
still use IPC.

The planned trim sheet shape was:

- when the bug likely happened: **now**, **30s ago**, **2m ago**, or a custom
  marker inside the retained timeline;
- how much history to include before that marker: **30s / 2m / full retained
  buffer**;
- whether to include a short tail after the marker / after the click, e.g.
  **0s / 10s / 30s**;
- optional note and category hint.

The sheet previews the exact time window, event count, estimated file size, and
retention limit before export. The final output is an ordinary `.log` in the
existing traces directory, suitable for the existing Copy File / Send Report
flows.

Uncontrolled growth is avoided by design: bounded in-memory rings scoped to the
active trace capture session, a configurable retention duration, a hard byte cap,
capped draft snapshots, and a small cleanup policy for abandoned drafts.

## Goals

1. **Recover the recent past inside an active trace capture.** If a
   focus/layout/workspace bug is noticed during a developer trace session, the
   user should be able to export just the recent causal sequence without stopping
   the full recording.
2. **Keep the current explicit trace capture.** Manual Start / Stop and Export
   remains the only recording mode and should not be replaced.
3. **Make sizing user-controlled at capture time.** Users should not have to send
   a 30-minute trace when the interesting part is the last 45 seconds.
4. **Bound privacy and resource cost.** The buffer is developer-only,
   session-scoped, local-only, bounded, and visibly tied to trace capture.
5. **Produce self-contained reports.** Exported clips include enough header
   metadata to explain their selected time window and retention truncation.

## Non-goals

- No remote telemetry, PostHog, crash reporting, or automatic upload.
- No automatic trace export on every bug-like heuristic. The user still decides
  when to save a clip.
- No unbounded disk spool in the first slice. If persistent rolling trace across
  app crashes is needed later, design it as a separate privacy/storage plan.
- No source-window title redaction change in this slice; exported clips have the
  same sensitivity posture as today's manual runtime traces and require the same
  user consent before sharing.

## User experience

### Settings: bound the trace-session buffer

Add a Diagnostics / Developer Mode section for configuration, not for a separate
recording mode:

- **Retain recent events for**: presets `Unlimited`, `30 sec`, `1 min`, `2 min`,
  `5 min`, `15 min`; default `Unlimited` (0 seconds). Unlimited means the buffer
  retains everything until the byte cap is reached.
- **Maximum buffer size**: presets such as `16 MB`, `64 MB`, `128 MB`; default
  `64 MB`.
- **Show DebugBar**: a menu/status-bar control toggle may show or hide the
  developer DebugBar surface while Developer Mode is enabled. This controls the
  UI surface only, not trace recording.
- Helper text: "Start Trace Capture before a known repro. While recording,
  Nehir keeps a bounded local recent-event buffer. Old events are discarded
  automatically based on the retention window and size limit. A clip file is only
  written when you manually save one."

If Developer Mode is turned off, any active trace capture and retained buffer
should stop and clear immediately.

### DebugBar surface

Introduce a **DebugBar** — a separate, developer-mode-only surface for trace
controls. Do not reuse the workspace bar for debug affordances; the workspace bar
is a workspace-navigation surface and debug controls are orthogonal.

The DebugBar should appear only when Developer Mode is enabled and the DebugBar
menu toggle is on. It should contain:

- trace recording toggle (start/stop manual trace capture);
- capture recent clip button (exports a clip from the active trace-session
  buffer; disabled/hidden when trace capture is idle);
- reset buffer button (clears retained events, effective even during active
  recording; disabled/hidden when trace capture is idle);
- retention window cycle button (cycles through presets);
- buffer status indicator (idle/recording, retained count/bytes).

The DebugBar is a lightweight overlay, not a full workspace bar replacement.
It should be unobtrusive and easy to ignore when not needed.

### Always-visible affordance

When trace capture is active, show both the recording state and retained-buffer
state in the DebugBar and Diagnostics tab:

- manual recording: visible recording indicator (red `REC` or equivalent), active
  timer, current planned visual feedback;
- recent buffer: neutral retained-window state, e.g. `clock.arrow.circlepath` or
  "4:12 retained" in the DebugBar and Diagnostics, not a separate red recording.

The UI must not imply that a second trace recorder is running. It is one explicit
trace-capture session with an additional bounded recent-event buffer.

### Actions model

There is one trace recording mode: the user starts it explicitly with the
existing Trace Capture toggle. The recent buffer runs passively inside that
session; it does not have a separate enable/record action. The user only decides
*when to save a clip* from the retained session buffer.

Actions available in the DebugBar:

- **Toggle trace capture** — starts/stops trace recording. Starts one recording
  session and its bounded recent buffer; stops and exports one full `.log` file,
  then clears the retained buffer.
- **Capture recent clip** — exports a clip from the active session buffer. Does
  not affect manual recording state. Only available while trace capture is
  active and retained events exist.
- **Reset buffer** — clears retained events and pending drafts. Is effective even
  while trace capture is running; recording continues to append to the new empty
  buffer.
- **Cycle retention** — cycles the retention window through presets.

Diagnostics should expose the same actions only when they are useful. Do not show
idle disabled buttons like "Capture Recent Clip" / "Reset Buffer" as permanent
rows in Settings; hide them until trace capture is active, or place them under an
active recording status with explanatory text.

No separate "background trace action." The buffer is session-scoped; the user
only triggers explicit actions on top of a running Trace Capture session.

### Capturing after a bug is noticed

Add **Capture Recent Clip** capability without making it a primary visible
button in the first slice:

1. IPC command `debug-capture-recent-trace` for scripted repros; by default it
   exports with preset arguments and never opens a GUI sheet unless requested.
2. Controller APIs for making a bounded draft and exporting a selected clip.

Do not add `debug.captureRecentTrace` to default hotkey assignment, command
palette, or DebugBar surfaces in this slice; an extra assignable/visible action
reads as redundant next to the existing Trace Capture toggle.

When a clip export is requested, immediately create a bounded **draft snapshot**
from the currently retained session buffer before any trimming/export work. That
prevents the relevant seconds from being evicted while a caller decides what
range to export.

### Trim / export sheet

The sheet should present:

- retained range, e.g. `14:03:10–14:08:10 (unlimited retained)`;
- marker control: `Bug noticed now`, `30 seconds ago`, `2 minutes ago`, custom
  slider across the retained range;
- history control: `30s`, `2m`, `Full available`;
- tail control: `none`, `10s`, `30s`, `keep recording tail until Export`;
- preview: selected start/end, event count by category, estimated file size;
- warning if the requested range was truncated by retention or byte cap, e.g.
  "Only 5:00 of background history was available; older events were already discarded.";
- optional note field copied into the exported trace header.

Recommended defaults:

- marker: now;
- history: 2 minutes;
- tail: 10 seconds if the sheet is opened immediately after a bug, otherwise
  none;
- export filename suffix: `recent-trace-<start>-<end>.log` or reuse the existing
  runtime trace naming convention with a `background` / `clip` marker.

## Data model and lifecycle

### Separate the concepts: full session export vs recent clip buffer

Today Runtime Trace Capture starts a session, clears/re-arms trace rings, and
writes one `.log` on stop. Keep that explicit session model. Add a bounded recent
clip buffer owned by the active session, not a permanently active background
recorder:

```swift
struct BackgroundTraceBufferStatus: Equatable, Sendable {
    var isEnabled: Bool
    var retainedStart: Date?
    var retainedEnd: Date?
    var eventCount: Int
    var estimatedBytes: Int
    var maxBytes: Int
    var retentionSeconds: TimeInterval
}
```

The trace event producers should fan out to two consumers while Trace Capture is
active:

1. existing session rings used for the full stop/export file;
2. new rolling recent-buffer used for clip export.

The full stop/export capture should still produce known-repro traces. The recent
buffer is cleared when Trace Capture starts, when Trace Capture stops, when the
user resets the buffer, and when Developer Mode turns off.

### Event representation

Use a small structured envelope before formatting to text:

```swift
struct BackgroundTraceEvent: Sendable {
    let timestamp: Date
    let monotonicNanos: UInt64
    let category: TraceCategory
    let estimatedBytes: Int
    let render: @Sendable () -> String
}
```

If existing trace rings already store renderable strings, wrap them rather than
rewriting every trace site in the first slice. The important requirement is that
the buffer can:

- evict oldest events by time and bytes;
- select events by timestamp range;
- count events by category for the preview;
- render selected events into the same multi-section `.log` style as current
  runtime traces.

### Bounded ring policy

Evict whenever either limit is exceeded:

1. `event.timestamp < now - retentionSeconds`;
2. `estimatedBytes > maxBytes`.

Use **both** limits. Time retention gives a user-understandable promise; byte cap
handles bursty event storms.

If an individual event is larger than the remaining cap, keep it only if it fits
under a per-event maximum; otherwise truncate the rendered payload with an
explicit marker such as `[background trace event truncated: 38 KB > 16 KB]`.

### Draft snapshots

When the user clicks **Capture Recent Trace…**:

1. copy the currently retained event references / rendered strings into a draft
   bounded by the same byte cap;
2. record `draftCreatedAt`, retained start/end, and initial marker;
3. trim/export from the draft, not the live buffer.

Draft cleanup:

- keep at most 2 abandoned drafts;
- expire drafts after 30 minutes;
- count draft bytes against a separate small cap, e.g. `2 * backgroundMaxBytes`;
- delete all drafts when Developer Mode is disabled or app exits.

This avoids the UX failure where the user opens the sheet, thinks for a minute,
and loses the oldest events before exporting.

## Export format

The exported clip should be a normal trace file with extra header fields:

```text
# Nehir runtime trace clip
captureKind=background-clip
backgroundBufferEnabled=true
retainedRange=2026-06-24T14:03:10Z..2026-06-24T14:08:10Z
selectedRange=2026-06-24T14:06:00Z..2026-06-24T14:08:10Z
bugMarker=2026-06-24T14:08:00Z
requestedLookback=120s
requestedTail=10s
truncatedByTimeRetention=false
truncatedByByteCap=false
backgroundRetentionSeconds=300
backgroundMaxBytes=67108864
userNote=...
```

Then append the same runtime state dump and trace sections as current manual
captures. If the selected window starts at the oldest retained event, explicitly
say whether older events may have been discarded.

## Implementation plan

### Phase 1 — settings plumbing

Add config fields:

- `debugBarEnabled: Bool` default `true`. This controls only the DebugBar surface
  while Developer Mode is enabled.
- `backgroundTraceRetentionSeconds: TimeInterval` default `0` (unlimited).
  Positive values enable automatic time-based eviction; `0` means retain
  everything until the byte cap is reached.
- `backgroundTraceMaxBytes: Int` default `64 * 1024 * 1024`.

Likely files:

- `Sources/Nehir/Core/Config/SettingsExport.swift`;
- `Sources/Nehir/Core/Config/SettingsStore.swift`;
- `Sources/Nehir/Core/Config/CanonicalTOMLConfig.swift`;
- `Sources/Nehir/Core/Config/BuiltInSettingsDefaults.swift`.

Runtime rule: effective buffer enabled = `developerModeEnabled && runtimeTraceCaptureActive`. DebugBar visibility = `developerModeEnabled && debugBarEnabled`.

### Phase 2 — background buffer core

Add a small core type, e.g.
`Sources/Nehir/Core/Diagnostics/BackgroundTraceBuffer.swift`, with unit tests for:

- evict by time;
- evict by byte cap;
- preserve newest events during bursts;
- select range by marker/lookback/tail;
- report truncation flags;
- no growth after repeated append/evict cycles.

Thread it through `WMController` as the owner, because `WMController` already owns
runtime trace capture state, trace export, and the Diagnostics snapshot.

### Phase 3 — trace fan-out

Introduce one internal trace sink API so existing trace producers can append once
and have the event reach manual capture and/or the background buffer.

Important guardrails:

- background append must be cheap and non-blocking on the main interaction path;
- formatting should be lazy or lightweight where possible;
- no file I/O on every event in the first slice;
- if the buffer is disabled, overhead should be close to the current state.

### Phase 4 — capture recent clip

Add controller API:

```swift
func makeBackgroundTraceDraft(marker: Date) -> BackgroundTraceDraft?
func exportBackgroundTraceClip(
    draftID: BackgroundTraceDraft.ID,
    marker: Date,
    lookback: TimeInterval,
    tail: TimeInterval,
    note: String?
) throws -> URL
```

The export path should reuse the existing traces directory and recent-traces list
so Copy File / Reveal / Send Report work without special cases.

### Phase 5 — UI and commands

- Diagnostics tab: retention/max-size settings, active trace/buffer status, and
  Capture Recent Clip sheet only when trace capture is active. Avoid permanent
  disabled action buttons when idle.
- DebugBar: trace recording toggle, capture recent clip button, reset buffer
  button, retention cycle button, buffer status indicator. Appears only when
  Developer Mode is enabled and the menu/status-bar DebugBar toggle is on.
- Hotkeys: Diagnostics "Assign in Hotkeys" deep-links to debug hotkeys and shows
  a route back to Diagnostics. Do not list recent-clip export as its own
  assignable hotkey by default.
- IPC: `debug-capture-recent-trace --lookback 120 --tail 10 --marker now` for
  power users and scripted repro attempts.

### Phase 6 — visual safety indicators

If the planned trace visual feedback work has landed, integrate with it:

- manual recording remains red and time-elapsed;
- background buffering is neutral and shows retained duration / cap;
- export confirmation should say "Recent trace saved" and expose Copy File.

## Tests

Core tests:

1. `BackgroundTraceBufferEvictsByTime`.
2. `BackgroundTraceBufferEvictsByByteCap`.
3. `BackgroundTraceBufferNeverExceedsConfiguredCapAfterBurst`.
4. `BackgroundTraceBufferWithUnlimitedRetentionRetainsAllEventsUntilByteCap`.
5. `SelectingRangeReportsTimeTruncation`.
6. `SelectingRangeReportsByteTruncation`.
7. `DraftSnapshotIsStableAfterLiveBufferEvicts`.
8. `ExportHeaderContainsRangeMarkerRetentionAndTruncationFields`.

Settings tests:

1. retention default is 0 (unlimited), max bytes default is 64 MB, and DebugBar
   visibility defaults on for Developer Mode;
2. TOML decode missing keys uses safe defaults;
3. TOML round-trip preserves configured retention/cap and DebugBar visibility;
4. effective buffer enabled is false when Developer Mode is false or trace
   capture is idle.

UI-level/manual validation:

1. Enable Developer Mode, start Trace Capture, wait 30 seconds, export last
   10 seconds; file contains only selected recent events and a header stating the
   selected range.
2. Generate a burst of events during Trace Capture; verify buffer status caps at
   configured bytes and export warns if older data was evicted.
3. Open Capture Recent Clip sheet during Trace Capture, wait longer than
   retention, then export; draft still contains the original snapshot.
4. Stop Trace Capture or turn Developer Mode off; buffer clears and Capture
   Recent Clip is unavailable until a new trace capture starts.
5. Reset buffer while trace capture is running; buffer clears but recording
   continues to append.
6. DebugBar appears only when Developer Mode and the DebugBar menu toggle are on;
   workspace bar has no debug controls.
7. Diagnostics idle state does not show unexplained disabled "Capture Recent
   Clip" / "Reset Buffer" buttons; contextual actions appear only when trace
   capture is active.
8. Stop Trace Capture from the DebugBar while Diagnostics is open; Diagnostics
   updates from active to idle and the recent trace list refreshes.
9. Use Diagnostics → Assign in Hotkeys; the Hotkeys page filters to debug actions
   and includes a Back to Diagnostics affordance.

## Open questions

1. Should the first slice support only in-memory retention, or is crash-surviving
   rolling disk spool worth the additional privacy and disk-churn review?
   Recommendation: start in-memory only.
2. What retention presets are acceptable on real hardware? Recommendation:
   default unlimited (0) / 64 MB, allow up to 30 min / 128 MB initially.
3. Should category filters be part of v1 export? Recommendation: no; show counts
   by category but export all selected events to avoid accidentally omitting the
   cause.
4. Should full Runtime Trace Capture stop/export include any additional clip
   metadata from the recent buffer? Recommendation: not by default; the full
   session export already contains the known-repro trace.
5. What should the DebugBar look like? Recommendation: a compact, minimal overlay
   similar in spirit to the workspace bar but with fewer elements. Start simple
   and iterate based on developer feedback.
