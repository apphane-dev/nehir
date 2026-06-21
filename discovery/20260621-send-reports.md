# Send reports

**Status:** discovery — pursue (small, network-free first slice); defer any
first-party upload endpoint to its own plan
**Source:** `planned/20260621-backlog-brainstorm.md`, Integrations / packaging /
ops item **#6** ("Send reports"), adjacent to **#5** ("Posthog analytics").
**Investigated against:** main Nehir source tree, verified 2026-06-21.

## What this idea means for Nehir

Nehir already produces a rich "report" artifact — the **runtime trace capture** —
and the README documents a fully manual sharing workflow for it. "Send reports"
means adding an in-app mechanism that packages and transmits such a diagnostic
report (trace + environment metadata) to the maintainers, instead of the user
manually copying a file, opening GitHub, and drag-dropping it into an issue.

It is **not**:

- **Posthog analytics (#5)** — that is automatic aggregate product analytics
  (anonymous usage metrics). "Send reports" is *user-initiated*, *opt-in*,
  *content-rich*, and *per-incident*. The two share privacy/consent concerns but
  should not share an opt-in toggle (different trust profiles).
- **A crash reporter** — macOS crash logs for Nehir live under
  `~/Library/Logs/DiagnosticReports/` and the app never references them today
  (no `grep` hit for `DiagnosticReports`/`crash`/`exception` in `Sources/`).
  Auto-exception reporting would be a separate, larger effort.
- **The IPC rule validation report** — `IPCRuleValidationReport` in
  `Sources/NehirIPC/IPCRuleValidator.swift` is an in-process struct returned by
  rule validation, not a user-facing diagnostic.

So "Send reports" = collapse today's multi-step manual
"stop capture → copy file → open GitHub → attach → paste" flow into one
consent-gated, in-app action, while staying inside the app's current
network-free posture where possible.

## Prior work (checked, not duplicated)

Searched `discovery/`, `planned/`, `completed/`, `noop/` for report/trace/
telemetry/feedback. Existing docs touch the artifact but not the *send* path:

- `planned/20260621-backlog-brainstorm.md` — the source list; this doc is the
  triage for item **#6**. Notes **#5 Posthog analytics** as a sibling but does
  not analyze it.
- `discovery/20260621-better-record-trace-visual-feedback.md` — characterizes
  the trace-capture *UI feedback* surfaces (workspace bar button, Diagnostics
  tab, status item) in depth. It states that on stop the file path is copied to
  the pasteboard and there is "no on-screen confirmation of where the file
  went," and flags a non-modal export toast as deferred. "Send reports" is the
  natural next step after that export — what the user does with the file once
  they have it.
- `completed/20260610-settings-and-onboarding-redesign.md` and
  `discovery/20260621-nehir-93-vertical-workspace-bar.md` — decide *where the
  trace button lives* and that it is gated behind Developer Mode. About
  visibility/placement, not about sending.
- `discovery/20260614-control-center-widget.md` — a separate "control center"
  surface idea; does not cover report transmission.
- Every runtime-bug discovery doc (`discovery/20260616-*`, `20260617-*`, …)
  consumes trace captures as an investigation artifact; none discusses how the
  capture leaves the user's machine.

No duplicate. This doc is the first to characterize the *send/transmit* path.

## Current behavior (with source)

### The report artifact

The capture lifecycle lives in
`Sources/Nehir/Core/Controller/WMController.swift`. `stopRuntimeTraceCapture()`
assembles a multi-section body (runtime state at start/end, reconcile trace,
niri viewport/resize/insertion/create-focus traces, AX notification trace,
interaction-monitor writes, mouse focus trace), then writes it:

```swift
let filename = "runtime-trace-\(Int(startedAt.timeIntervalSince1970 * 1000))-\(Int(endedAt.timeIntervalSince1970 * 1000)).log"
return Self.traceCaptureDirectory.appendingPathComponent(filename, isDirectory: false)
```

(`WMController.swift:3261`, inside `runtimeTraceCaptureFileURL(startedAt:endedAt:)`.)
The directory is:

```swift
static let traceCaptureDirectory: URL = NehirStoragePaths.live.stateDirectory
    .appendingPathComponent("traces", isDirectory: true)
```

— i.e. `${XDG_STATE_HOME:-$HOME/.local/state}/nehir/traces/`, resolved by
`Sources/Nehir/Core/Config/NehirStoragePaths.swift`. After writing, the path
(not the file) is copied to the pasteboard via `copyDebugTextToPasteboard(...)`,
which calls `NSPasteboard.general.setString(...)`.

A second ready-made report body exists:
`WMController.runtimeStateDebugDump(...)` (`WMController.swift:2961`) — a dense,
sectioned text snapshot (WMController flags, focus targets, monitor topology,
managed windows, AX window state, niri viewports/layout decisions, AXEventHandler
counters, LayoutRefreshController counts, mouse/mouse-warp/CGS snapshots,
workspace-bar state, reconcile snapshot/trace). `dumpRuntimeState(traceLimit:)`
copies that to the pasteboard and logs it. So the app already knows how to
serialize "everything about this run" to text.

### The sharing UX today

There are exactly two user-facing affordances, both manual and pasteboard-based:

1. **Diagnostics tab → Recent Traces** in
   `Sources/Nehir/UI/DisplayDiagnosticsSettingsTab.swift`. `recentTracesSection`
   lists the last ten captures (`loadRecentTraces()`) and offers, per row,
   **Copy Path** (`pasteboard.setString(trace.url.path, ...)`) and
   **Copy File** (`pasteboard.writeObjects([trace.url as NSURL])`), plus a
   **Reveal Traces Folder** button
   (`NSWorkspace.shared.activateFileViewerSelecting([WMController.traceCaptureDirectory])`).
   This section is gated behind `settings.developerModeEnabled`.
2. **About tab → Issues** in `Sources/Nehir/UI/AboutSettingsTab.swift`: an
   `AboutLinkCard` titled "Issues", caption "Report bugs and track fixes", that
   opens `<repo>/issues`. The repository is
   `https://github.com/apphane-dev/nehir`
   (`Sources/Nehir/UI/Onboarding/ReleaseNotes.swift:15`,
   `repositoryURLString`). There is **no `issues/new` prefilled-URL** anywhere
   in `Sources/` — the link opens the plain issues list, not a templated new
   issue.

The README's *Debugging & Tracing* section codifies the manual flow: "Share the
trace **file**, not the path — … Use **Copy File** in the Recent Traces list, or
drag it out of the traces folder."

### Precedent: "generate a report-like text blob, hand it to the user"

`Sources/Nehir/Core/Config/ConfigAssistancePrompt.swift` already builds a
multi-section text summary (app version, affected file, details list, release
URL, releases page, backup path) for config-assistance flows, and the Diagnostics
tab copies it to the clipboard:

```swift
NSPasteboard.general.clearContents()
if NSPasteboard.general.setString(prompt, forType: .string) { ... }
```

This is the established in-app pattern for "produce a structured report body and
let the user paste it somewhere." A "Send reports" feature should model its body
builder on this.

### The app is network-free and unsandboxed

This is the single most important constraint for the design space:

- **No networking code.** A repo-wide search for `URLSession`,
  `NSSharingService`, `NSSharingServicePicker`, `NSURLSession`,
  `contents(of:`, and HTTP `URLComponents` in `Sources/` returns **zero**
  production hits (the only `fetch`/`upload` matches are unrelated — menu-item
  fetching in `MenuAnywhereFetcher.swift`, AX attribute fetching in `AXWindow.swift`).
  The only outbound mechanism is `NSWorkspace.shared.open(url)`, used to open
  System Settings panes and the GitHub links above.
- **Not sandboxed.** `Nehir.entitlements` contains only
  `com.apple.security.automation.apple-events` — no `app-sandbox`, no
  network-client entitlement. So adding `URLSession` is *not* blocked by the
  sandbox; it is blocked by posture, not by entitlements.
- **No telemetry/crash dependency.** `Package.swift` / `Package.resolved` have
  no Posthog / Sentry / Bugsnag / MetricKit-style package. `Info.plist` has no
  crash/exception/report keys.
- **No GitHub issue template.** `.github/` contains `FUNDING.yml`,
  `pull_request_template.md`, and `workflows/` only — no `ISSUE_TEMPLATE/`, so
  there is no structured bug-report template to prefill on the GitHub side.

So today: the report exists, the body-serialization exists, the file exists on
disk and is enumerated in the Diagnostics UI — but the moment of *transmission*
is entirely the user's problem, performed outside the app.

## Where / how it would be implemented

Three credible options, in increasing order of capability and risk. The data
inputs are already there for all three (trace `URL`s from `loadRecentTraces()`,
the runtime-state dump from `WMController`, display diagnostics from
`DisplayEnvironmentDiagnostics`, app version from `Bundle`).

### Option A — Prefilled GitHub issue via outbound URL (no network egress)

Build a short report body (app version, macOS version, display-arrangement
summary, reference to the most recent trace by *name and size only* — not its
contents) and open:

```
https://github.com/apphane-dev/nehir/issues/new?title=<title>&body=<body>
```

via `NSWorkspace.shared.open(url)`, percent-encoded with `URLComponents`/
`URLQueryItem` (the same safe encoding `SpreadTheWordSheet.shareURL(...)` already
uses in `AboutSettingsTab.swift`). This is a pure outbound-URL open — no
`URLSession`, no new entitlement, no privacy surface beyond the GitHub link the
About tab already opens. The trace file itself cannot ride in a query string
(GitHub issue bodies via URL are practically capped at a few KB; a capture is
often much larger), so the body carries a *summary* and the user still attaches
the `.log` via GitHub's web drag-and-drop.

- **Home:** add a **Send Report…** button next to **Copy File** in
  `DisplayDiagnosticsSettingsTab.swift`'s `recentTracesSection`, and/or a new
  `Debug: Send Report` entry in `Sources/Nehir/Core/Input/ActionCatalog.swift`
  (category `.debugging`, mirroring `debug.dumpRuntimeState` /
  `debug.toggleTraceCapture`), routed through `CommandHandler` and surfaced in
  `Sources/Nehir/IPC/IPCCommandRouter.swift` for `nehirctl`.
- **Reuse:** the body builder is a new helper modeled on `ConfigAssistancePrompt`.

### Option B — `NSSharingService` share sheet (no network egress, attaches files natively)

`NSSharingServicePicker` with the trace `URL` (and optionally the runtime-state
dump as a second item) lets the user pick a destination — macOS Mail
(`NSSharingService(named: .composeEmail)`) attaches files natively, AirDrop and
Notes work too. This stays inside the OS sharing infrastructure: the app hands
the OS a file and a body, the OS mediates the destination, and no first-party
HTTP is introduced. It directly removes the "drag the file out of the traces
folder" friction the README warns about.

- **Home:** same Diagnostics-tab button / same palette action as Option A; the
  difference is the *presentation* (system share sheet vs. `NSWorkspace.open`
  of a GitHub URL). The two are complementary and can share one entry point
  that offers "Open GitHub issue" and "Share via Mail/AirDrop…" side by side.
- **Cost:** first introduction of `NSSharingService` in the codebase; small,
  well-contained, AppKit-only.

### Option C — First-party HTTP upload (true one-click send; highest cost)

A `URLSession` upload of the trace (zipped) plus a JSON sidecar (version, OS,
display env, optional sanitized config excerpt) to a maintainer-operated
endpoint (e.g. a presigned-PUT object store or a small worker). This is the only
option that gives a real one-click send without the user leaving the app. It is
also the only option that introduces **outbound networking into an otherwise
network-free app**, which is a posture change.

- Requires: a maintained server with retention/abuse policy, transport security,
  rate limiting, and an **opt-in setting** in `SettingsStore` (precedent:
  `developerModeEnabled` / `workspaceBarShowTraceButton` are `@AppStorage`-style
  booleans in `Sources/Nehir/Core/Config/SettingsStore.swift`).
- Requires: a **preview/confirm sheet** showing the exact body and attached
  files before anything leaves the machine, and a redaction pass for the most
  identifiable fields (see Risks).
- Should be its own plan; do not bundle into the first slice.

## Risks and unknowns

- **Privacy / PII is the primary risk.** A trace and `runtimeStateDebugDump()`
  carry window titles (via AX), app bundle IDs, pids, display names and frames,
  workspace names, and hotkey bindings — effectively a transcript of what the
  user was doing during the capture. Any send path needs (a) explicit per-send
  consent, (b) a preview showing exactly what is about to leave, and (c) a
  warning that GitHub issues are **public**. There is no redaction helper in the
  codebase today; one would be net-new.
- **Trace size vs. transport.** Captures are multi-section `.log` files and can
  be large. Option A can carry a summary only; the file still has to be attached
  by hand on the GitHub side. Option B (Mail/AirDrop) handles large attachments
  natively. Option C would zip+upload. The Diagnostics tab already shows
  `formatFileSize(...)` per trace, so the UI can warn "this report is N MB"
  before send.
- **Network-free-by-design is a feature.** The app does zero networking today;
  "no phoning home" is a real, defensible property. Option C weakens it even if
  the code is opt-in. That trade-off should be a deliberate, separately-reviewed
  decision, not an incidental side effect of this feature.
- **Crash reports are out of scope today.** Nothing in `Sources/` reads
  `~/Library/Logs/DiagnosticReports/` or hooks `MetricKit`/exception handlers.
  If "Send reports" is meant to cover crashes, that is additional plumbing none
  of the current infrastructure provides.
- **Destination policy.** Public GitHub issues (Options A) vs. private email
  (Option B Mail) vs. private endpoint (Option C) have very different privacy
  implications. The UI must make the destination — and its public/private nature
  — explicit at send time.
- **Relationship to #5 Posthog.** Keep them separate (see "What this idea
  means"). They can share the *consent/preview scaffolding* but should not share
  an opt-in toggle.
- **IPC/palette exposure.** Adding `Debug: Send Report` to `ActionCatalog` and
  `IPCCommandRouter` is consistent with the existing `debug.*` surface, but a
  send action reachable over IPC could be triggered by automation without the
  GUI consent sheet. If Option C is ever added, its IPC form must require the
  opt-in setting to be already on (mirroring how Developer Mode gates the
  existing debug IPC endpoints).

## Open questions

- What is the intended destination: (a) a public GitHub issue, (b) maintainer
  email, or (c) a private first-party endpoint? This picks the option.
- Should the report always attach the most recent trace, or let the user pick
  from the Recent Traces list?
- Should it include a sanitized excerpt of `settings.toml` (app rules, hotkeys,
  workspace config)? Useful context, but it can carry app names and layouts.
- Where should the entry point live — Diagnostics tab only, or also the menu-bar
  status menu (`StatusBarMenu.swift`), the About tab, and/or the command
  palette?
- Does the maintainer want any *automatic* opt-in crash/exception reporting
  (distinct from manual reports)? That would be a separate effort.

## Recommendation

**Pursue**, scoped to **Options A + B** as the first slice; **defer Option C**.

1. **Now (small, high-value, network-free):** add a **Send Report…** affordance
   in `DisplayDiagnosticsSettingsTab.swift`'s `recentTracesSection` (and
   optionally a `Debug: Send Report` palette entry in `ActionCatalog.swift`).
   Back it with a single new "report body" builder modeled on
   `ConfigAssistancePrompt` (version, OS, display-env summary, trace name/size
   reference). Offer two destinations from one entry point: **Open GitHub issue**
   (Option A — `NSWorkspace.shared.open` of an `issues/new?...` URL built with
   the same `URLComponents`/`URLQueryItem` helper already used in
   `AboutSettingsTab.swift`) and **Share via Mail/AirDrop…** (Option B —
   `NSSharingServicePicker` with the trace `URL`). Wrap both in a preview/confirm
   sheet that lists the body and the attached file(s) and warns that GitHub is
   public. This collapses the README's manual multi-step flow into one in-app
   action without introducing any networking.
2. **Defer (separate plan):** Option C — a first-party HTTP upload endpoint.
   It is the only path that requires outbound networking, a maintained server,
   and a reviewed redaction pipeline. That is a posture decision worth its own
   plan, and it should reuse the body builder and preview sheet built in step 1.
3. **Keep separate from #5 Posthog analytics:** shared consent scaffolding is
   fine; a shared opt-in toggle is not.

**Drop nothing** — the idea is valid and directly removes friction from the
manual "copy file → open GitHub → drag in → paste" flow documented in the README.
The smallest slice is low-risk (no networking, reuses the trace `URL` and
`ConfigAssistancePrompt`-style body builder already in the tree) and immediately
improves the only debug-sharing path Nehir has.
