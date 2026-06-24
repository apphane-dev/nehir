# Always-on background trace buffer for dev mode

**Status:** in progress
**Source:** maintainer request, 2026-06-24 — unknown repro bugs are often noticed
only after the manual runtime trace was not enabled.

All source paths below refer to the main Nehir repository. Re-verify before
editing; line numbers in older trace/report plans are expected to drift.

## Key learnings from diagnostics tab work (2026-06-24)

While implementing the diagnostics tab controls for the background trace buffer,
several UX and architectural decisions were validated and revised:

1. **Diagnostics tab grouping matters.** Trace actions and runtime-state actions
   belong together under a single "Debug Actions" section with internal labels
   ("Trace capture", "Runtime state"). The trace file list should sit immediately
   after actions so the user can see exported results right where they triggered
   them. A `Divider()` between sub-sections creates an unwanted empty row in a
   SwiftUI `Form` and was removed.

2. **Disable conditions must be honest.** "Capture Recent Trace" was initially
   disabled when the buffer was enabled but had zero retained events. That is
   misleading because the user cannot see the event count in real time. The only
   real gating condition is whether the background buffer toggle is on (and
   Developer Mode is on). Zero-events is a transient state, not a configuration
   problem.

3. **Status labels should distinguish success from failure.** A single generic
   "runtime action status" conflated trace and runtime-state feedback and always
   used a green check. A dedicated `ActionStatusLabel` that detects failure
   prefixes ("Couldn't", "Failed") and shows red is clearer.

4. **"red REC session" is poor explanatory text.** Users do not know what "red
   REC" means. Use plain language: "Start recording before a known repro. Stop
   exports one .log file and copies its path."

5. **No separate background trace action.** The background buffer should not have
   its own independent capture action. The user starts trace capture explicitly
   (toggle trace). The background buffer is a passive retention layer that always
   records when enabled; the user only decides *when to save a clip* from it.
   This simplifies the mental model: one trace recording mode, one retention
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

## Revised direction

The plan below is updated to reflect these learnings. The core architecture
(background buffer + draft + export) remains the same, but the UI surface, default
values, and action model have changed.

## TL;DR

Add a **developer-mode-only, opt-in background trace buffer** that continuously
keeps the last N minutes / M bytes of runtime trace events in a bounded local
ring. It is **not** an always-growing trace file and it is **not** an automatic
upload. While enabled, Nehir records the same diagnostic event families that the
manual Runtime Trace Capture already exports, but into a rolling buffer that
forgets old data automatically.

When the user notices a subtle bug, they click **Capture Recent Clip** (from
the DebugBar, Diagnostics tab, command palette, or IPC). Nehir immediately
freezes the current retained window as a temporary draft, then opens a trim sheet
where the user chooses:

- when the bug likely happened: **now**, **30s ago**, **2m ago**, or a custom
  marker inside the retained timeline;
- how much history to include before that marker: **30s / 2m / 5m / 15m / full
  retained buffer**;
- whether to include a short tail after the marker / after the click, e.g.
  **0s / 10s / 30s**;
- optional note and category hint.

The sheet previews the exact time window, event count, estimated file size, and
retention limit before export. The final output is an ordinary `.log` in the
existing traces directory, suitable for the existing Copy File / Send Report
flows.

Uncontrolled growth is avoided by design: bounded in-memory rings, a configurable
retention duration, a hard byte cap, capped draft snapshots, and a small cleanup
policy for abandoned drafts. Default remains **off**.

## Goals

1. **Recover the recent past without pre-planning.** If a focus/layout/workspace
   bug is noticed after the fact, the user should still be able to export the
   recent causal sequence.
2. **Keep the current explicit trace capture.** Manual Start / Stop and Export
   remains useful for known repro attempts and should not be replaced.
3. **Make sizing user-controlled at capture time.** Users should not have to send
   a 30-minute trace when the interesting part is the last 45 seconds.
4. **Bound privacy and resource cost.** The mode is developer-only, opt-in,
   local-only, bounded, and visibly enabled.
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

### Settings: enable and bound the buffer

Add a Diagnostics / Developer Mode section:

- **Background trace buffer**: off by default; only editable while Developer Mode
  is enabled.
- **Retain recent events for**: presets `Unlimited`, `30 sec`, `1 min`, `2 min`,
  `5 min`, `15 min`; default `Unlimited` (0 seconds). Unlimited means the buffer
  retains everything until the byte cap is reached.
- **Maximum buffer size**: presets such as `16 MB`, `64 MB`, `128 MB`; default
  `64 MB`.
- Helper text: "Keeps a local rolling debug buffer only while Nehir is running.
  Old events are discarded automatically based on the retention window and size
  limit. A trace file is only written when you manually save a clip."

If Developer Mode is turned off, the buffer should stop and clear immediately.
The setting may remain in config, but runtime behavior is disabled until
Developer Mode is re-enabled.

### DebugBar surface

Introduce a **DebugBar** — a separate, developer-mode-only surface for trace
controls. Do not reuse the workspace bar for debug affordances; the workspace bar
is a workspace-navigation surface and debug controls are orthogonal.

The DebugBar should appear only when Developer Mode is enabled and contain:

- trace recording toggle (start/stop manual trace capture);
- capture recent clip button (exports a clip from the background buffer);
- reset buffer button (clears retained events, effective even during active
  recording);
- retention window cycle button (cycles through presets);
- buffer status indicator (enabled/disabled, retained count/bytes).

The DebugBar is a lightweight overlay, not a full workspace bar replacement.
It should be unobtrusive and easy to ignore when not needed.

### Always-visible affordance

When the background buffer is enabled, show its state in the DebugBar and the
Diagnostics tab, distinct from active manual recording:

- manual recording: visible recording indicator (red `REC` or equivalent), active
  timer, current planned visual feedback;
- background buffer: neutral "buffering" state, e.g. `clock.arrow.circlepath` or
  "BG 4:12 retained" in the DebugBar and Diagnostics, not red recording.

The UI must not imply that a trace file is growing. It is only a rolling buffer.

### Actions model

There is one trace recording mode: the user starts it explicitly with a toggle.
The background buffer runs passively whenever it is enabled — it does not have a
separate capture action. The user only decides *when to save a clip* from the
buffer.

Actions available in the DebugBar and Diagnostics tab:

- **Toggle trace capture** — starts/stops manual trace recording. Starts a
  recording session; stops and exports one `.log` file.
- **Capture recent clip** — exports a clip from the background buffer. Does not
  affect manual recording state. Only available when the buffer is enabled.
- **Reset buffer** — clears retained background events and pending drafts. Is
  effective even while manual trace capture is running; the recording continues
  to append to the new empty buffer.
- **Cycle retention** — cycles the retention window through presets.

No separate "background trace action." The buffer is always-on when enabled;
the user only triggers explicit actions on top of it.

### Capturing after a bug is noticed

Add **Capture Recent Clip** entry points:

1. DebugBar button — primary entry point when Developer Mode is active.
2. Diagnostics tab button near the existing Runtime Trace Capture controls.
3. Command palette action `debug.captureRecentTrace` requiring Developer Mode.
4. IPC command `debug-capture-recent-trace` for scripted repros; by default it
   exports with preset arguments and never opens a GUI sheet unless requested.

The first click should immediately create a bounded **draft snapshot** from the
currently retained buffer before opening UI. That prevents the relevant seconds
from being evicted while the user decides how to trim.

### Trim / export sheet

The sheet should present:

- retained range, e.g. `14:03:10–14:08:10 (unlimited retained)`;
- marker control: `Bug noticed now`, `30 seconds ago`, `2 minutes ago`, custom
  slider across the retained range;
- history control: `30s`, `2m`, `5m`, `15m`, `Full available`;
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

### Separate the concepts: session capture vs background buffer

Today the manual Runtime Trace Capture starts a session, clears/re-arms trace
rings, and writes one `.log` on stop. Do not make that session permanently
active. Instead add a separate background recorder:

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

The trace event producers should fan out to two consumers:

1. existing manual capture/session rings;
2. new background rolling buffer, only when enabled and Developer Mode is active.

Manual capture should still produce full known-repro traces. Background capture
should not be cleared when manual capture starts, because the past context is the
main value.

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

- `backgroundTraceBufferEnabled: Bool` default `false`;
- `backgroundTraceRetentionSeconds: TimeInterval` default `0` (unlimited).
  Positive values enable automatic time-based eviction; `0` means retain
  everything until the byte cap is reached.
- `backgroundTraceMaxBytes: Int` default `64 * 1024 * 1024`.

Likely files:

- `Sources/Nehir/Core/Config/SettingsExport.swift`;
- `Sources/Nehir/Core/Config/SettingsStore.swift`;
- `Sources/Nehir/Core/Config/CanonicalTOMLConfig.swift`;
- `Sources/Nehir/Core/Config/BuiltInSettingsDefaults.swift`.

Runtime rule: effective enabled = `developerModeEnabled && backgroundTraceBufferEnabled`.

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

- Diagnostics tab: settings controls, buffer status, Capture Recent Clip sheet.
- DebugBar: trace recording toggle, capture recent clip button, reset buffer
  button, retention cycle button, buffer status indicator. Appears only in
  Developer Mode.
- Command palette: `debug.captureRecentTrace`, Developer Mode required.
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

1. defaults are off; retention default is 0 (unlimited);
2. TOML decode missing keys uses safe defaults;
3. TOML round-trip preserves configured retention/cap;
4. effective runtime enabled is false when Developer Mode is false.

UI-level/manual validation:

1. Enable Developer Mode + Background Trace Buffer, wait 30 seconds, export last
   10 seconds; file contains only selected recent events and a header stating the
   selected range.
2. Generate a burst of events; verify buffer status caps at configured bytes and
   export warns if older data was evicted.
3. Open Capture Recent Clip sheet, wait longer than retention, then export;
   draft still contains the original snapshot.
4. Turn Developer Mode off; buffer clears, Capture Recent Clip becomes disabled,
   no new events are retained.
5. Reset buffer while manual trace capture is running; buffer clears but
   recording continues to append.
6. DebugBar appears only in Developer Mode; workspace bar has no debug controls.

## Open questions

1. Should the first slice support only in-memory retention, or is crash-surviving
   rolling disk spool worth the additional privacy and disk-churn review?
   Recommendation: start in-memory only.
2. What retention presets are acceptable on real hardware? Recommendation:
   default unlimited (0) / 64 MB, allow up to 30 min / 128 MB initially.
3. Should category filters be part of v1 export? Recommendation: no; show counts
   by category but export all selected events to avoid accidentally omitting the
   cause.
4. Should manual Runtime Trace Capture include the background pre-roll when it is
   stopped? Recommendation: not by default; add a separate "Include background
   pre-roll" checkbox later if users ask.
5. What should the DebugBar look like? Recommendation: a compact, minimal overlay
   similar in spirit to the workspace bar but with fewer elements. Start simple
   and iterate based on developer feedback.
