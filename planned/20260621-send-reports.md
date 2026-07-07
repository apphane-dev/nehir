# Send reports (manual report upload, network-free first slice)

Re-verified against main 7a025b78 on 2026-07-07.

**Status:** planned
**Source discovery:** `discovery/20260621-send-reports.md`
**Upstream reference:** `planned/20260621-backlog-brainstorm.md` → *Integrations /
packaging / ops* → **#6 Send reports** (sibling to **#5 Posthog analytics**,
`discovery/20260621-posthog-analytics.md`, kept deliberately separate)

Source references re-verified against main `7a025b78` on 2026-07-07; the runtime trace capture implementation now lives in `Sources/Nehir/Core/Controller/RuntimeDiagnosticsCoordinator.swift`, not `WMController.swift`.

## TL;DR

Nehir already produces a rich diagnostic "report" — the runtime trace capture
(`RuntimeDiagnosticsCoordinator.stopRuntimeTraceCapture()` assembles a multi-section `.log` body and writes it via `RuntimeDiagnosticsCoordinator.traceCaptureDirectory` / `runtimeTraceCaptureFileURL(startedAt:endedAt:)`, currently `Sources/Nehir/Core/Controller/RuntimeDiagnosticsCoordinator.swift:1026` and `:1155-1160`) — and the README codifies a fully manual
sharing flow for it ("Share the trace **file**, not the path — … Use **Copy
File** in the Recent Traces list, or drag it out of the traces folder."). The
*moment of transmission* is entirely the user's problem: copy file → open GitHub
→ drag in → paste context. This plan collapses that into one consent-gated,
in-app action **without introducing any networking**.

The first slice implements the discovery's **Options A + B** recommendation:

- **Option A — Prefilled GitHub issue via outbound URL.** Build a small report
  body (app version, macOS version, display-arrangement summary, the trace
  referenced by **name + size only**, never contents) and open
  `https://github.com/apphane-dev/nehir/issues/new?title=…&body=…` through
  `NSWorkspace.shared.open(url)`, percent-encoded with the same
  `URLComponents`/`URLQueryItem` approach already used by
  `SpreadTheWordSheet.shareURL(...)` (`AboutSettingsTab.swift:324`). No
  `URLSession`, no new entitlement. The `.log` file itself still has to be
  attached by hand on GitHub (query-string bodies cap at a few KB); the body
  carries the *summary* and the sheet tells the user to attach the file.
- **Option B — `NSSharingService` share sheet.** An `NSSharingServicePicker`
  seeded with the trace `URL` lets the user pick Mail/AirDrop/Notes, which
  attach files natively. Stays inside the OS sharing infrastructure; the app
  never makes an HTTP call.

Both destinations are reached from a single **preview/confirm sheet** that lists
the exact body and the attached file(s) and warns that GitHub issues are
**public**. The sheet is the one consent seam for all entry points (Diagnostics
tab, command palette, IPC).

**Deferred (separate plan): Option C** — a first-party `URLSession` HTTP upload.
It is the only path that introduces outbound networking into an otherwise
network-free app and that needs a maintained server + redaction pipeline; that
posture change deserves its own plan. It should reuse the body builder and
preview sheet built here. **No new settings toggle is added in this slice** —
there is no networking to gate; per-send consent via the preview sheet is
sufficient. A toggle only becomes load-bearing for Option C (see Follow-ups).

## Discovery corrections / decisions

The discovery recommendation stands; the following corrections/decisions were
made while porting it (re-verified against main `7a025b78` on 2026-07-07):

1. **Diagnostics refactor moved the trace-capture citations.** The discovery's
   `WMController` line references are stale after the diagnostics extraction.
   Current locations are in `Sources/Nehir/Core/Controller/RuntimeDiagnosticsCoordinator.swift`:
   `stopRuntimeTraceCapture()` at `:1026`, `runtimeTraceCaptureFileURL(startedAt:endedAt:)`
   at `:1158`, `traceCaptureDirectory` at `:1155`, `copyDebugTextToPasteboard(_:)`
   at `:1136`, `runtimeStateDebugDump(...)` at `:687`, and
   `dumpRuntimeState(traceLimit:)` at `:778`. This plan uses those source symbols
   rather than durable-doc-hostile trace filename examples.
2. **`ConfigAssistancePrompt` is the body-builder precedent, not the pasteboard
   precedent.** The discovery implies `ConfigAssistancePrompt` both builds the
   body *and* copies to the pasteboard. It only builds the string
   (`ConfigAssistancePrompt.swift:26`, `prompt(kind:appVersion:affectedFile:details:backupURL:)`).
   The actual pasteboard write for that flow lives in the Diagnostics tab at
   `DisplayDiagnosticsSettingsTab.swift:798`
   (`NSPasteboard.general.setString(prompt, forType: .string)`). The new report
   body builder is modeled on `ConfigAssistancePrompt.prompt(...)`; the new UI's
   pasteboard behavior is modeled on the in-tab `copyTracePath`/`copyTraceFile`
   helpers (`:515`/`:526`) and the `traceCopyStatus` label (`:450`).
3. **`SpreadTheWordSheet.shareURL(...)` is `private`; do not call it directly.**
   It is a `private static func` inside the `SpreadTheWordSheet` view struct
   (`AboutSettingsTab.swift:324`, using `URLComponents`+`URLQueryItem` at
   `:328-330`). The new `issues/new` URL builder must implement its own
   equivalent percent-encoding (identical pattern), or `shareURL` should be
   promoted to a shared helper in a follow-up. This plan chooses the former
   (self-contained builder) to avoid widening the diff.
4. **No new `SettingsStore`/`SettingsExport`/`CanonicalTOML` fields in this
   slice.** The discovery's "opt-in setting in `SettingsStore`" applies to
   Option C. Options A+B do no networking and are already gated two ways: the
   per-row button lives inside the `developerModeEnabled`-gated
   `recentTracesSection` (`DisplayDiagnosticsSettingsTab.swift:209`/`:327`), and
   the command-palette entry uses `requiresDeveloperMode: true`
   (`ActionCatalog.swift`, the `debug.*` block at `:728`-`:754`). Adding an
   `analyticsEnabled`/`reportUploadEnabled` toggle now would be dead config
   until Option C lands. Defer it.
5. **IPC `debug-send-report` must not bypass the consent sheet.** Per the
   discovery's own risk note ("a send action reachable over IPC could be
   triggered by automation without the GUI consent sheet"), the IPC/palette
   action **opens the preview sheet**; it never opens the `issues/new` URL or
   the share sheet directly. Transmission is always an explicit button click
   inside the sheet. If the UI is unavailable (headless/IPC-only), the command
   returns an error instead of transmitting. This keeps one consent seam for all
   three entry points (see *Exact implementation plan*, phase 4).
6. **`issues/new` body carries a summary, never the trace.** GitHub caps
   query-string issue bodies at a few KB; a trace capture is frequently much
   larger. The Option A body is a *summary* (version, OS, displays, trace name +
   size), and the sheet instructs the user to attach the `.log` via GitHub web
   drag-and-drop. The full trace rides out-of-band (manual attach for A; native
   attachment for B). This is already the discovery's design; restated because
   it is load-bearing for the URL builder's size contract.

## Scope

### Files to add/change

1. `Sources/Nehir/Core/Config/DiagnosticReportBuilder.swift` **(new)** — pure,
   testable report-body + `issues/new` URL builder, modeled on
   `ConfigAssistancePrompt.prompt(...)`. Sibling to
   `Sources/Nehir/Core/Config/ConfigAssistancePrompt.swift`.
2. `Sources/Nehir/UI/DisplayDiagnosticsSettingsTab.swift` — primary entry point:
   add a per-row **Send Report…** button next to **Copy File**
   (`recentTracesSection`, `:351`-`:358`), and a new preview/confirm sheet view
   that offers the two destinations and shows the exact body + attachments.
3. `Sources/Nehir/Core/Input/ActionCatalog.swift` — add a `debug.sendReport`
   action (`category: .debugging`, `requiresDeveloperMode: true`,
   `binding: .unassigned`), mirroring the existing `debug.*` block (`:728`-`:754`).
4. `Sources/Nehir/Core/Input/HotkeyCommand.swift` — add
   `case debugSendReport` next to the existing debug cases (`:87`-`:90`).
5. `Sources/Nehir/Core/Controller/CommandHandler.swift` — dispatch
   `.debugSendReport` in `performCommand(_:)` (`:47`, debug block `:196`-`:202`)
   to open the preview sheet against the most recent trace.
6. `Sources/Nehir/IPC/IPCCommandRouter.swift` — add the `debugSendReport` case to
   the debug dispatch block (`:191`-`:202`), GUI-gated per decision 5.
7. `Sources/NehirIPC/IPCModels.swift` — add `debugSendReport` to
   `IPCCommandName` (`:215`, raw value `debug-send-report`, near `:287`-`:290`)
   and to `IPCCommandRequest` (`:350`, near `:422`-`:425`).
8. `Sources/NehirIPC/IPCAutomationManifest.swift` — register the new command in
   the automation manifest near the existing debug entries (`:745`, `:760`,
   `:765`).
9. Tests under `Tests/NehirTests/`.

### Non-goals

- Do **not** introduce `URLSession` / any first-party HTTP upload (Option C —
  separate plan).
- Do **not** add a Posthog / analytics integration (#5 — separate; see
  `discovery/20260621-posthog-analytics.md`).
- Do **not** add crash reporting (no `~/Library/Logs/DiagnosticReports/` read,
  no `MetricKit`, no exception/signal handlers). Nothing in `Sources/` does this
  today and it is out of scope.
- Do **not** build a general payload-redaction pipeline. A+B send a fixed
  summary body plus the trace file attached as-is; the preview sheet *is* the
  consent. A redaction helper is net-new and belongs with Option C.
- Do **not** add a new global non-modal toast/HUD (that is the sibling
  `discovery/20260621-better-record-trace-visual-feedback.md` plan's territory).
- Do **not** change the existing **Copy Path** / **Copy File** / **Reveal Traces
  Folder** buttons or the `traceCopyStatus` label.
- Do **not** add a status-bar / menu-bar entry in this slice (follow-up; see
  `Sources/Nehir/UI/StatusBar/StatusBarMenu.swift`, which currently has no trace
  surface at all).
- Do **not** add a `Settings.toml`/`SettingsExport` opt-in toggle for reports
  (defer to Option C, per decision 4).

## Exact implementation plan

### Phase 1 — `DiagnosticReportBuilder` (new, pure)

Create `Sources/Nehir/Core/Config/DiagnosticReportBuilder.swift`. No UI, no
AppKit, fully unit-testable. Shape:

```swift
import Foundation

enum DiagnosticReportBuilder {
    struct TraceReference: Equatable {
        let filename: String      // runtime trace log filename, as produced by RuntimeDiagnosticsCoordinator
        let sizeBytes: Int64
    }

    struct Inputs: Equatable {
        let appVersion: String                      // Bundle.main.appVersion ?? "dev"
        let macOSVersion: String                    // ProcessInfo.processInfo.operatingSystemVersion formatted
        let displaySummary: String                  // e.g. "3 displays: D1 @origin(0,0) 2560x1440, …; separateSpaces=enabled"
        let trace: TraceReference?
        let userNote: String?
    }

    /// Structured, human-readable body for the report. Mirrors the sectioned
    /// style of ConfigAssistancePrompt.prompt(...). Summary only — never the
    /// trace contents.
    static func body(for inputs: Inputs) -> String

    /// Prefilled-new-issue URL for Option A. Percent-encodes via
    /// URLComponents/URLQueryItem (the same safe encoding
    /// SpreadTheWordSheet.shareURL uses in AboutSettingsTab.swift:324-330).
    /// Returns nil if the body cannot be represented as a query item.
    static func newIssueURL(title: String, body: String) -> URL?
}
```

Implementation notes:

- `body(for:)` sections: a header line ("Nehir diagnostic report"), **Nehir
  version** (`appVersion`), **macOS version** (`macOSVersion`), **Displays**
  (`displaySummary`), **Trace** (when present: `filename` + a human-readable
  size, e.g. "runtime trace log (412 KB)"; when absent: "no trace
  attached"), optional **Note** (`userNote`), and a footer line instructing the
  user to **attach the `.log` file** on GitHub (query bodies cap at a few KB).
  Reuse `ConfigAssistancePrompt`'s `lines: [String]` + `lines.joined(separator:
  "\n")` idiom.
- `newIssueURL(title:body:)`:
  ```swift
  var components = URLComponents(string: "https://github.com/apphane-dev/nehir/issues/new")!
  components.queryItems = [
      URLQueryItem(name: "title", value: title),
      URLQueryItem(name: "body", value: body),
  ]
  return components.url
  ```
  The base host must come from `ReleaseNotes.repositoryURLString`
  (`Sources/Nehir/UI/Onboarding/ReleaseNotes.swift:15`) rather than being
  hard-coded a second time — expose the base as
  `\(ReleaseNotes.repositoryURLString)/issues/new`.
- `displaySummary` is **built by the caller** (the Diagnostics tab already has
  `monitors` (`:16`), `displaySpacesMode` (`:15`), and
  `DisplayEnvironmentDiagnostics.evaluate(...)` (`:494`) in scope). The builder
  itself takes the already-rendered string so it stays free of `Monitor`/
  `SkyLight` dependencies and trivially testable. A small
  `DiagnosticReportBuilder.displaySummary(monitors:spacesMode:)` helper may be
  added if the formatting is non-trivial, but prefer passing the string in.

### Phase 2 — Preview/confirm sheet in the Diagnostics tab

In `Sources/Nehir/UI/DisplayDiagnosticsSettingsTab.swift`:

- Add a new SwiftUI sheet, e.g. `SendReportSheet`, presented from a per-row
  **Send Report…** button placed next to **Copy File** in `recentTracesSection`
  (current row layout: `:351` Copy Path, `:355` Copy File). The button uses the
  same `.borderless` button style as its siblings.
- The sheet takes the selected `TraceFile` (`:599`) and the in-scope state the
  tab already holds: `appVersion` (`:41`), `monitors` (`:16`),
  `displaySpacesMode` (`:15`). It builds `DiagnosticReportBuilder.Inputs` and
  renders:
  1. The full report body in a scrollable, monospaced read-only text view
     (so the user sees exactly what would be sent).
  2. The attached file list — the trace filename + `formatFileSize(trace.size)`
     (`:487`) — making the size obvious before send.
  3. A privacy warning: **"GitHub issues are public. Mail/AirDrop are
     private."**
  4. Two destination buttons and a Cancel:
     - **Open GitHub issue (public)** → Option A (Phase 3a).
     - **Share via Mail / AirDrop…** → Option B (Phase 3b).
- Reuse the existing `traceCopyStatus`/`traceCopyFailed` label convention
  (`:374`/`:399`) for any in-sheet status ("Opened GitHub in your browser —
  remember to attach the .log file").
- The sheet must be the **only** place that triggers `NSWorkspace.open` /
  `NSSharingServicePicker`. Nothing opens a URL or share sheet without an
  explicit button click here.

### Phase 3a — Option A: open the prefilled `issues/new` URL

Triggered by the **Open GitHub issue** button in the sheet:

```swift
if let url = DiagnosticReportBuilder.newIssueURL(title: title, body: body) {
    NSWorkspace.shared.open(url)
}
```

- `NSWorkspace.shared.open(url)` is the only outbound mechanism the app already
  uses (it opens System Settings panes and the GitHub links at
  `AboutSettingsTab.swift:12`/`:130`). No new mechanism, no new entitlement.
- After opening, the sheet shows a reminder to **attach the `.log` file** on
  GitHub (the query body could not carry it). Optionally also run
  `copyTraceFile(trace)` (`:439`) up front so the file is on the clipboard ready
  to paste into the GitHub drag-drop.

### Phase 3b — Option B: `NSSharingServicePicker` (first `NSSharingService` use)

Triggered by the **Share via Mail / AirDrop…** button in the sheet:

- Present `NSSharingServicePicker` seeded with the trace `URL` (and optionally
  the report body string as a second item so Mail pre-fills it). Mail/AirDrop
  attach files natively, removing the "drag the file out of the traces folder"
  friction the README warns about.
- This is the first `NSSharingService` use in the codebase (verified: a
  repo-wide search for `NSSharingService`/`NSSharingServicePicker` returns zero
  hits). It is AppKit; bridge from SwiftUI with a small `NSViewRepresentable`
  that calls
  `picker.show(relativeTo:of:preferredEdge:)` (or
  `show(relativeTo:of:)`) anchored to the button's view. Keep the bridge in this
  file or a tiny sibling helper; do not generalize.
- Stays inside OS sharing infrastructure — the app hands the OS a file + body,
  the OS mediates the destination, and **no first-party HTTP is introduced**.

### Phase 4 — Command palette + IPC plumbing (`debug.sendReport`)

Make the same affordance reachable from the palette and `nehirctl`, both
GUI-gated.

- `HotkeyCommand.swift` (`:9` enum, debug cases `:87`-`:90`): add
  `case debugSendReport`.
- `ActionCatalog.swift` (debug block `:728`-`:754`): add
  ```swift
  action(
      id: "debug.sendReport",
      command: .debugSendReport,
      category: .debugging,
      binding: .unassigned,
      keywords: ["debug", "report", "send", "share", "issue", "trace", "diagnostic"],
      requiresDeveloperMode: true
  )
  ```
- `CommandHandler.performCommand(_:)` (`:47`, debug dispatch `:196`-`:202`): add
  `case .debugSendReport:` that resolves the most recent trace from
  `WMController.traceCaptureDirectory` (same enumeration
  `loadRecentTraces()` uses, `:450`) and **presents the preview sheet** (Phase
  2). If no trace exists, surface the sheet anyway with a "no trace attached"
  note (the body still carries version/OS/display context).
- `IPCCommandRouter.swift` (debug dispatch `:191`-`:202`): add the
  `debugSendReport` case routing to the same handler. **GUI guard (decision 5):**
  if the app's UI is unavailable (no Settings/window host), return an error
  result such as
  `"Send Report requires the Nehir UI; open Settings → Diagnostics → Send Report."`
  and do **not** open a URL or share sheet. When the UI is available, the
  command opens the preview sheet and waits for the user to click a destination —
  it never transmits on its own.
- `IPCModels.swift`: add `case debugSendReport = "debug-send-report"` to
  `IPCCommandName` (`:215`, near `:287`-`:290`) and `case debugSendReport` to
  `IPCCommandRequest` (`:350`, near `:422`-`:425`). No arguments (the trace is
  "most recent" by design; an optional explicit `traceFilename` argument is a
  follow-up).
- `IPCAutomationManifest.swift`: register the command near `:745`/`:760`/`:765`
  with no parameters, noting the GUI-required constraint in its description.

### Phase 5 — README

Update the README *Debugging & Tracing* section (the "Share the trace **file**,
not the path … Use **Copy File** … or drag it out of the traces folder" passage)
to mention the new **Send Report…** button as the one-action alternative. Keep
the manual Copy File/drag instructions as the fallback. (Docs change only; lives
in the main repo, not this branch.)

## Tests

### `Tests/NehirTests/DiagnosticReportBuilderTests.swift` (new)

Pure unit tests, no UI, no SkyLight:

1. `bodyContainsVersionAndOS` — given `Inputs(appVersion: "0.4.10", macOSVersion:
   "macOS 15.3", …)`, `body(for:)` contains `"0.4.10"` and `"macOS 15.3"`.
2. `bodyReferencesTraceByNameAndSizeNotContents` — given a `TraceReference`
   whose runtime trace log filename and size
   `421_888`, the body contains the filename and a human-readable size and does
   **not** contain any hypothetical trace contents string passed via a control
   field (assert the builder has no "contents" input at all).
3. `bodyOmitsTraceSectionWhenNoneAttached` — `trace: nil` produces a body with
   "no trace attached" and no filename.
4. `bodyIncludesAttachInstructionFooter` — the footer tells the user to attach
   the `.log` file on GitHub.
5. `newIssueURLEncodesTitleAndBody` — `newIssueURL(title:"Bug: foo & bar",
   body:"line1\nline2")` returns a URL whose scheme/host/path is
   `https://github.com/apphane-dev/nehir/issues/new` and whose decoded query
   items round-trip to the original `title`/`body` (use
   `URLComponents(url:resolvingAgainstBaseURL:)` → `queryItems`).
6. `newIssueURLUsesRepositoryBase` — host is derived from
   `ReleaseNotes.repositoryURLString`, not a second hard-coded constant (assert
   equality with `URL(string: "\(ReleaseNotes.repositoryURLString)/issues/new")`'s
   host).
7. `newIssueURLIsSummarySized` — a large body (e.g. 64 KB string) still produces
   a URL; the builder does not attempt to inline trace contents. (Documents the
   size contract; GitHub may truncate, which is why the sheet instructs manual
   attachment.)

### `DisplayEnvironmentDiagnostics` / display-summary coverage

If a `DiagnosticReportBuilder.displaySummary(monitors:spacesMode:)` helper is
added (optional, Phase 1), add 1–2 cases mirroring
`Tests/NehirTests/DisplayEnvironmentDiagnosticsTests.swift`: synthetic
`[Monitor]` + a `DisplaySpacesMode` → summary mentions the count and the mode.
Otherwise the display summary is asserted at the call site.

### IPC round-trip

Extend the existing IPC command round-trip suite (the
`IPCCommandRequest`/`IPCCommandName` codec tests) for `debugSend-report`:
encode/decode `IPCCommandRequest.debugSendReport`, assert
`IPCCommandName` raw value is `debug-send-report`, and assert it appears in
`IPCCommandName.allCases`. Add a router-level test that `debugSendReport` with
no UI host returns an error result and does **not** call `NSWorkspace.open` /
`NSSharingServicePicker` (inject a test host / spy).

### Command catalog

Add a test that `ActionCatalog` exposes exactly one action with id
`debug.sendReport`, that its `category` is `.debugging`, and that
`requiresDeveloperMode == true` (mirroring the assertion style used for the
existing `debug.*` actions).

## Validation

```bash
swift build
swift test --filter DiagnosticReportBuilder
swift test --filter DisplayEnvironmentDiagnostics
swift test --filter ActionCatalog          # or the catalog/registry suite that asserts debug.* entries
swift test --filter IPCCommand             # IPCCommandName/IPCCommandRequest codec + router suite
```

Manual validation (Developer Mode on):

1. Start a trace capture, reproduce something, stop it (a `.log` appears under
   the app state trace directory).
2. Settings → Diagnostics → Recent Traces → click **Send Report…** on that row.
3. In the sheet, confirm the body shows version, macOS version, display summary,
   and the trace filename + size (not contents); confirm the "attach the .log on
   GitHub" footer; confirm the public/private warning.
4. **Open GitHub issue** opens `…/issues/new?title=…&body=…` in the default
   browser with title/body pre-filled; the `.log` is not in the URL. Attach the
   file by hand on GitHub and confirm it uploads.
5. **Share via Mail / AirDrop…** opens the system share sheet with the `.log`
   attached; pick Mail and confirm the file is an attachment.
6. Command palette → *Debug: Send Report* (Developer Mode on) opens the same
   sheet against the most recent trace.
7. `nehirctl command debug send-report` opens the sheet when the UI is up, and
   returns the GUI-required error when run with no UI host — without opening a
   URL or share sheet in either case until a button is clicked.
8. Confirm **no new outbound HTTP**: the app still makes zero `URLSession`
   requests (the only new egress is `NSWorkspace.shared.open` of the
   `issues/new` URL and the OS share sheet).

Changeset (minor; confirm release policy): "Add an in-app Send Report action
(prefilled GitHub issue + system share sheet) for runtime trace captures."

## Risks and mitigations

- **Privacy / PII is the primary risk.** The trace and `runtimeStateDebugDump`
  carry window titles (via AX), bundle ids, pids, display names/frames,
  workspace names, hotkey bindings — effectively a transcript of the capture.
  Mitigations for A+B: (a) the **preview sheet shows the exact body and attached
  file(s)** before anything leaves the machine; (b) the Option A body is a
  *summary* (version/OS/displays/trace name+size), never trace contents; (c) the
  sheet warns that GitHub issues are **public** and that Mail/AirDrop are
  private; (d) the per-row button and palette entry are gated behind Developer
  Mode. The trace file itself still goes out as-is via GitHub drag-drop (A) or
  Mail/AirDrop (B) — the sheet warns about that, and a real redaction pass is
  deferred to Option C.
- **Trace size vs. transport.** Captures can be large. Option A carries a
  summary only and the file is attached by hand on GitHub; Option B (Mail/
  AirDrop) handles large attachments natively. The sheet surfaces
  `formatFileSize(trace.size)` (`DisplayDiagnosticsSettingsTab.swift:487`) so the
  user sees the size before choosing.
- **IPC bypassing the consent sheet.** Decision 5 makes the IPC/palette action
  open the sheet only; it never transmits. Add the router test that asserts no
  URL/share open occurs from the IPC path without a button click, and the
  no-UI-host error case.
- **`NSSharingServicePicker` from SwiftUI.** This is the first share-sheet use
  in the codebase. Keep the AppKit bridge tiny and local; anchor it to the
  button view. If the bridge proves fiddly in practice, fall back to presenting
  the picker from an `NSViewRepresentable` wrapper. Do not generalize into a
  reusable component yet.
- **URL percent-encoding correctness.** Reuse the exact
  `URLComponents`+`URLQueryItem` pattern from `SpreadTheWordSheet.shareURL`
  (`AboutSettingsTab.swift:324-330`); add the round-trip test (Tests #5) so a
  body containing `&`, `=`, newlines, and unicode survives encode→decode.
- **Duplicate base URL constant.** Derive the `issues/new` host from
  `ReleaseNotes.repositoryURLString` (`ReleaseNotes.swift:15`), not a second
  literal; assert in Tests #6.
- **Network-free-by-design is a feature.** This slice preserves it: the only new
  egress is `NSWorkspace.shared.open` (already used) and the OS share sheet.
  Option C is the one that would weaken the property and is deliberately
  deferred.
- **Scope creep into Posthog (#5) / crash reporting.** Both explicitly out of
  scope; the sibling Posthog discovery recommends building the shared consent
  substrate *with* this work only when Option C is pursued, not now.

## Follow-ups (out of scope)

- **Option C — first-party `URLSession` HTTP upload** (zipped trace + JSON
  sidecar to a maintainer endpoint). The only path requiring outbound
  networking, a maintained server with retention/abuse policy, transport
  security, rate limiting, a reviewed redaction pass, and an explicit opt-in
  `SettingsStore` toggle (`ipcEnabled` at `SettingsStore.swift:259-262` is the
  precedent for a side-effecting capability toggle). Its own plan; should reuse
  the `DiagnosticReportBuilder` and the preview sheet built here.
- **Posthog analytics (#5)** — share the consent/preview scaffolding with Option
  C, but keep a separate opt-in toggle. See
  `discovery/20260621-posthog-analytics.md`.
- **Automatic crash/exception reporting** — `~/Library/Logs/DiagnosticReports/`
  + a `MetricKit`/signal-handler marker flushed next launch. Distinct plumbing;
  coordinate with Option C.
- **Status-bar / menu-bar "Send Report" entry** — `StatusBarMenu.swift` has no
  trace surface today; add one so reports are reachable when the workspace bar
  and Settings window are closed.
- **Redaction helper** — a typed, allow-listed pass that strips/summarizes
  window titles, bundle ids, and hotkey payloads from a report body. Net-new;
  pairs with Option C.
- **Explicit `--trace <filename>` IPC argument** — let `nehirctl command debug
  send-report` target a specific capture rather than the most recent one.
- **Promote `SpreadTheWorldSheet.shareURL`** to a shared `URLComponents` helper
  so the report builder and the share sheet share one percent-encoder.
