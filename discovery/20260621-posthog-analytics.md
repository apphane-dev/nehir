# Discovery — Posthog analytics (#5)

Groom 2026-07-07: still applicable — deferred; no analytics/crash-reporting SDK or `analyticsEnabled` setting has landed on main, and the recommendation is to build the shared consent/upload substrate with the in-flight **#6 Send reports** first (verified against main 7a025b78).

- **Status:** investigated
- **Recommendation:** **Defer** background product analytics; coordinate the
  shared consent + install-id + upload substrate with the sibling "Send reports"
  (#6) discovery before layering any event capture. If pursued, ship
  **opt-in-only, anonymous, event-minimal**, with autocapture/session-recording
  hard-disabled. See §Recommendation.
- **Source idea:** `planned/20260621-backlog-brainstorm.md` → *Integrations /
  packaging / ops* → **#5 Posthog analytics**.
- **Sibling investigation:** **#6 Send reports** (`discovery/20260621-send-reports.md`,
  in flight as of 2026-06-21). It shares the outbound-network + consent +
  install-identity substrate; the two should be designed together, not
  independently.
- **Source verified against:** main Nehir source tree, `main` @ `56573ba2`
  (2026-06-21).

---

## 1. What the idea means for Nehir

"Posthog analytics" = wire the app to [PostHog](https://posthog.com) so the
maintainer gets product/usage telemetry: which features are used, how often the
app crashes, what macOS/monitor topologies are in the wild, which settings are
popular. Today the maintainer has **near-zero usage signal** — the only feedback
loop is GitHub issues and traces that users *manually* attach. That is exactly
the gap this backlog is trying to triage (see `planned/20260621-backlog-brainstorm.md`),
so the motivation is real.

But Nehir is not a generic app. It is:

1. An **Accessibility-permissioned window manager** that observes every window's
   title, every running app's bundle id, and focus/monitor topology. Any
   analytics payload that echoes that raw data is a serious privacy incident.
2. A **pre-1.0, GPL-2.0, community OSS** macOS app (see `README.md`,
   `LICENSE`, `NOTICE.md`), distributed via Homebrew cask (`guria/tap`) and
   from-source. Its audience is tiling-WM power users — the most
   privacy-sensitive user segment there is.
3. An app whose **only existing "telemetry" is strictly local, opt-in, and
   user-curated** (the runtime trace system). Introducing remote, automatic
   analytics inverts that posture.

So the real question is not "can we add Posthog" (trivially yes) but
"**what is the minimal, consented, anonymous telemetry that is worth the
privacy/infrastructure cost for a project this size and audience?**"

---

## 2. Related prior work

- `planned/20260621-backlog-brainstorm.md` — the source list. #5 (this) and #6
  (Send reports) are both under *Integrations / packaging / ops*.
- **#6 Send reports** (`discovery/20260621-send-reports.md`, sibling, in flight) —
  almost certainly a *user-initiated* diagnostic/bug-report upload. That is
  categorically different from Posthog (background, automatic, product
  analytics), but the two share: outbound network, a consent gate, a stable
  install identity, and a "what exactly do we send?" disclosure. **Build the
  substrate once, share it.**
- Every other `analytics`/`telemetry`/`tracking` grep hit in `discovery/`,
  `completed/`, `planned/`, `noop/` is about **internal debug telemetry**
  (frame-write readbacks, layout traces, focus-tracking state) — i.e.
  engineering observability, not product analytics. Representative:
  - `discovery/20260614-ax-frame-write-verification-race.md` — discusses
    treating the racy AX readback "purely as telemetry" (local debug data).
  - `discovery/20260617-omniwm-releases-discovery-loop-log.md` — upstream
    roadmap note about a "private-framework bridge → **telemetry side-by-side**
    → switch" phased plan for raw multitouch. Again local-engineering telemetry.
  - None of these touch remote product analytics; there is **no prior discovery
    for Posthog or any remote analytics**. This is greenfield.

---

## 3. Current behavior (grounded in source)

### 3.1 Zero product analytics, zero crash reporting today

A repo-wide search for analytics/telemetry/tracking SDKs and identifiers is
empty:

- No `posthog`, `analytics`, `telemetry`, `trackEvent`, `captureEvent`,
  `distinctId`, `sentry`, `crashreport`, `MetricKit`, `bugsnag`, or
  `crashlytics` references anywhere under `Sources/`.
- No `installId`, `machineId`, `anonymousId`, or `IOPlatformUUID` usage — there
  is **no stable install identity** in the app today. (See §4.3 for where one
  would go.)
- The **only** network-shaped code is external-link opening (share buttons and
  repo/license URLs in `Sources/Nehir/UI/AboutSettingsTab.swift` and
  `Sources/Nehir/UI/Onboarding/OnboardingStepControls.swift`). There is no
  `URLSession` data task, no HTTP POST anywhere.

### 3.2 The only existing "telemetry" is local, opt-in, user-shared traces

Nehir already has a telemetry-shaped subsystem, and it is the right contrast for
this doc. It is **local files, manually started, manually shared**:

- Gated behind **Developer Mode** (`developerModeEnabled`), surfaced in the
  **Diagnostics** settings tab. Per `README.md` §*Debugging & Tracing*:
  > "Trace capture and the other debug commands are gated behind **Developer
  > Mode**. Enable it in the **Diagnostics** tab of Settings…"
- API on the controller:
  - `WMController.traceLaunchArgument = "--nehir-trace"`
    (`Sources/Nehir/Core/Controller/WMController.swift:3292`)
  - `WMController.toggleRuntimeTraceCapture(desiredState:)` and
    `RuntimeTraceCaptureStatus` (`WMController.swift:63, 3104, 3129, 3153`)
  - Started at bootstrap only when the launch arg is present:
    `AppDelegate.continueBootstrap` calls
    `controller.toggleRuntimeTraceCapture(desiredState: .active)` when
    `enableTracing` is true (`Sources/Nehir/App/AppDelegate.swift`).
- Output location is a **local path**, and the README explicitly warns users
  that the path is machine-local and to share the **file**, not the path:
  > "${XDG_STATE_HOME:-$HOME/.local/state}/nehir/traces/  …  Share the trace
  > **file**, not the path — a local path is only meaningful on your machine."

This is the existing posture: **opt-in, local, user-curated, no automatic
upload.** Posthog analytics inverts three of those four properties. That delta
is the core thing to justify.

### 3.3 Sensitive capabilities default OFF — the precedent to follow

`ipcEnabled` (the Unix-socket control surface) **defaults to `false`**:

- `Sources/Nehir/Core/Config/SettingsExport.swift:161` —
  `ipcEnabled: false,` inside `SettingsExport.defaults()`.
- Toggling it fires `onIPCEnabledChanged` and reconfigures the IPC server
  (`Sources/Nehir/Core/Config/SettingsStore.swift:259-266`, wired in
  `AppDelegate.continueBootstrap`).

This is the strongest in-repo precedent for how to treat a sensitive capability:
**default off, explicit user opt-in, side-effecting toggle.** An analytics
toggle should follow it exactly.

### 3.4 Settings plumbing — where an opt-in toggle would land

The settings system is a clean, well-trodden path. Adding one boolean is
mechanical and touches a known set of files:

- **`Sources/Nehir/Core/Config/SettingsExport.swift`** — the `Sendable`/`Equatable`
  export struct (field list starts ~line 19). Add `analyticsEnabled: Bool`.
- **`Sources/Nehir/Core/Config/SettingsStore.swift`** — `@MainActor @Observable`
  store. Each setting is a stored property with `didSet { scheduleSave() }`
  (e.g. `developerModeEnabled` at ~line 283). Add the property, thread it
  through `toExport()` (~line 410) and `applyExport(_:monitors:)` (~line 470).
- **`Sources/Nehir/Core/Config/CanonicalTOMLConfig.swift`** — the TOML codec.
  The `General` coding section already groups booleans:
  `case hotkeysEnabled, preventSleepEnabled, ipcEnabled, developerModeEnabled,
  ignoreMonitorIdentity` (`CanonicalTOMLConfig.swift:46`), with
  `decodeWithDefault` (~line 486) and explicit `encode` (~line 504). An
  `analyticsEnabled` key joins this group. Because unknown TOML keys are
  preserved (the `settingsTOMLUnknownFields` round-trip), an older build won't
  strip a new analytics key from a user's `settings.toml`.
- **`Sources/Nehir/Core/Config/BuiltInSettingsDefaults.swift`** — default value.

### 3.5 Runtime state — where a stable install identity would live

The right home for a Posthog `distinct_id` is **not** the shareable TOML config
(which users are encouraged to export/share — see `Sources/Nehir/UI/ConfigurationFilesSection.swift`
and `SettingsExport`). It is the private runtime state:

- **`Sources/Nehir/Core/Config/RuntimeStateStore.swift`** — a `@MainActor` JSON
  store. Its file is written with `0600` permissions:
  `applyPermissions(S_IRUSR | S_IWUSR, to: tempURL)` and the directory with
  `S_IRWXU`. The `RuntimeState` Codable struct currently holds
  `windowRestoreCatalog` and `commandPaletteLastMode`. A new
  `installId: String?` (lazily generated `UUID().uuidString`) belongs here —
  private on disk, never exported, never shared.
- Location: `${XDG_STATE_HOME:-$HOME/.local/state}/nehir/runtime-state.json`
  (resolved by `Sources/Nehir/Core/Config/NehirStoragePaths.swift`).
- This `installId` is the **anonymous** distinct id. **Do not** use
  `IOPlatformUUID` / hardware serials — those are re-identifiable and would be
  correctly read as device-fingerprinting.

### 3.6 Onboarding + Diagnostics — the two UI surfacing points

- **Onboarding** (`Sources/Nehir/Core/Config/OnboardingStateStore.swift`,
  `Sources/Nehir/UI/Onboarding/*`, driven from `AppDelegate.continueBootstrap`
  via `OnboardingWindowController.shared.show(...)`). The first-run wizard is
  the natural place for a one-time **consent prompt** ("Help improve Nehir —
  send anonymous usage and crash reports. You can change this any time in
  Settings."). `hasCompletedOnboarding` gates re-display.
- **Diagnostics tab** (`Sources/Nehir/UI/DisplayDiagnosticsSettingsTab.swift`,
  section `SettingsSection.diagnostics` per `Sources/Nehir/UI/SettingsSection.swift:9-54`).
  It already surfaces accessibility status, display environment, trace capture,
  recent traces, and unknown-key/migration issues. This is the natural home for
  an "Analytics" toggle plus a "What we collect" disclosure and the install-id.
  (Alternatively a dedicated **Privacy** section; `SettingsSection` is a simple
  `enum`, easy to extend.)

### 3.7 Network posture

- The app is **not sandboxed**: `Nehir.entitlements` contains only
  `com.apple.security.automation.apple-events`. It loads SkyLight via
  `-F/System/Library/PrivateFrameworks` (`Package.swift` linkerSettings), which a
  sandboxed app cannot do. So there is **no `com.apple.security.network.client`
  entitlement to add** — outbound HTTPS works by default. This removes one
  integration hurdle but also one natural checkpoint: nothing forces a
  privacy review at the entitlement layer.

---

## 4. What integration would look like (concrete)

### 4.1 SDK choice — `posthog-ios` vs hand-rolled

Two viable paths, both SPM-addable in `Package.swift` (currently the package has
exactly **one** dependency, `swift-toml`):

- **(A) Official `posthog-ios` SDK.** MIT-licensed
  (`PostHog/posthog-ios` → `LICENSE` is MIT), supports **macOS 10.15+**
  (Nehir needs 15+, fine), Swift 5.3+, SPM-supported, current release `3.48.x`.
  Brings **6 transitive package dependencies** with it. Provides event capture,
  feature flags, session recording, autocapture, person profiles.
  - ⚠️ **Autocapture (`$autocapture`) and session recording MUST be disabled.**
    PostHog's autocapture records UI-element interactions and session recording
    captures the screen. On an Accessibility-permissioned window manager that is
    a non-starter — it can capture window titles, app contents, and everything
    on the user's desktop. The integration must set `captureScreenViews=false`,
    disable autocapture, and never enable session replay.
- **(B) Hand-rolled `URLSession` capture.** PostHog's ingest is a plain HTTP
  `/capture` endpoint. A ~150-line client (queue, retry, batch, flush-on-quit)
  adds zero dependencies and gives full control over exactly what is sent. For
  the minimal event set this doc recommends, **(B) is the lower-risk default**;
  reach for (A) only if feature flags or PostHog's dashboard tooling are wanted.

### 4.2 The opt-in gate

- New setting `analyticsEnabled: Bool`, **default `false`**, wired per §3.4.
- Mirror the `ipcEnabled` toggle pattern (`SettingsStore.swift:259-266`): a
  `didSet` that calls an `onAnalyticsEnabledChanged` closure wired in
  `AppDelegate.continueBootstrap`, which constructs/tears-down the analytics
  client. No client object exists while disabled → zero network and zero
  in-memory event state when off.
- Consent captured once in onboarding (§3.6), re-editable in Diagnostics.

### 4.3 Install identity

- `installId: String?` on `RuntimeState`, stored via `RuntimeStateStore`
  (private `0600` JSON, §3.5). Lazily minted on first send. Used as Posthog
  `distinct_id`. Never logged, never exported, not derived from hardware.

### 4.4 Lifecycle wiring

- **Init:** in `AppDelegate.continueBootstrap`, after `settings` and
  `runtimeState` exist and after the onboarding decision, construct the
  analytics client **only if `settings.analyticsEnabled`**. Pass
  `runtimeState.installId`, app version (`Bundle.main.appVersion`, already used
  in the Diagnostics tab), and macOS version.
- **Capture points (minimal, anonymous set):**
  - `app_launched` (version, macOS major, display count, monitor-arrangement
    axis) — once per launch.
  - `feature_toggled` (setting key + new value) — adoption signal for the
    backlog. **Never** include window titles, app bundle ids, or hotkey
    payloads.
  - `ipc_enabled` / `crash` / `relaunch_with_trace` counters.
  - Optionally aggregate counts (workspace count, app-rule count) as integers.
- **Shutdown:** `AppDelegate.applicationWillTerminate` already flushes
  `settings`, `runtimeStateStore`, `onboardingStateStore`
  (`Sources/Nehir/App/AppDelegate.swift`). Add a final `flush()` for the
  analytics queue there.
- **Crash capture:** the highest-value signal for a pre-1.0 app. Either a
  `signal`/`exception` handler that enqueues a `crash` event for next-launch
  flush, or (path A) the SDK's crash reporting. **This is the strongest
  justification for the whole feature** and overlaps with #6 — coordinate.

### 4.5 Destination

PostHog Cloud (US/EU, hosted by PostHog Inc.) vs self-hosted PostHog. This is a
policy call: Cloud is one line of config; self-host keeps user data off
third-party servers but is real ops cost. For an OSS privacy-conscious app,
**self-host (or at minimum EU Cloud + documented sub-processor)** is the
defensible default. Flag in open questions.

---

## 5. Privacy, legal, community considerations

- **GPL-2.0 + MIT SDK:** license-compatible. MIT can be linked into a GPL-2.0
  app without issue. (`posthog-ios` is MIT; confirm on adoption — the repo also
  carries notice files that make GitHub's auto-detector say "Other".)
- **GDPR / ePrivacy (and UK/other equivalents):** the app reaches a global
  Homebrew audience. "Anonymous" usage analytics still needs a lawful basis;
  for a window manager the cleanest stance is **explicit opt-in** (consent),
  documented data list, no special-category data, and a working opt-out that
  also flushes/purges the local queue.
- **Accessibility-app sensitivity:** the app legitimately sees window titles and
  app identities to do its job. The analytics layer must be **deny-by-default
  for any payload field that could carry that** — enforce at the capture call
  sites, not just in a privacy policy. A generic `PostHog.capture(name, properties)`
  escape hatch is a footgun; prefer typed, allow-listed event helpers.
- **Audience:** tiling-WM users are disproportionately privacy-conscious and
  technically literate; they will read the network traffic. Any "phone home"
  that isn't loudly opt-in and auditable will cost trust and GitHub stars. The
  upside (maintainer signal) has to be framed as "anonymous, optional, helps
  prioritize the roadmap you can see in `planned/`."
- **Reproducibility/debug builds:** analytics must auto-disable for the dev
  `0.0.0` placeholder build (`AppDelegate.isReleaseVersion` already distinguishes
  dev vs release builds for What's-New gating — reuse that guard).

---

## 6. Risks & unknowns

- **Over-capture risk.** A single careless `properties` dict leaks a window
  title or bundle id. Mitigation: typed event API, allow-listed keys, a test
  that asserts no payload contains runtime model types.
- **Dependency footprint.** Path (A) takes the project from 1 → 7 SPM
  dependencies and adds Obj-C/transitive surface to a currently tiny, auditable
  dependency tree. Review whether that trade is worth the dashboard.
- **PostHog account/ops cost.** Someone has to own the project key, the
  Cloud/self-host decision, quota, and data retention. For a solo/small OSS
  project this is non-trivial ongoing work.
- **Crash-handler reliability.** Doing async I/O from a signal handler is
  unsafe; the robust pattern is "write a crash marker file, flush next launch."
  Not free to implement correctly.
- **Overlap with #6.** If "Send reports" (#6) ships a user-initiated
  diagnostics upload, the marginal value of *also* having background analytics
  drops (the highest-value signal — "it crashed, here's why" — is largely
  covered by reports). Behavioral feature-adoption analytics is the residual
  value and is the weakest justification on its own.

---

## 7. Open questions

1. **Cloud vs self-hosted PostHog?** Policy + cost decision; affects the trust
   story.
2. **SDK or hand-rolled?** Is the PostHog dashboard/feature-flags value worth
   6 transitive deps, or is a 150-line `/capture` client enough?
3. **Scope split with #6.** Does "Send reports" own the upload substrate + crash
   marker, leaving Posthog to do only anonymous feature-adoption events? (This
   author's suggestion: yes.)
4. **Distinct-id stability vs reset.** Should "Disable analytics" also rotate
   the `installId` so re-enabling can't be correlated? (Probably yes.)
5. **What is the actual decision the maintainer can't make today for lack of
   data?** If the answer is "which features to prioritize," lightweight
   feature-adoption counters may suffice without a full Posthog integration.

---

## 8. Recommendation

**Defer a full Posthog integration; build the shared substrate with #6 first.**

Rationale:

- The highest-value signal for a pre-1.0 Accessibility-permissioned window
  manager is **crash/exception reporting**, and that is almost certainly in
  scope for the sibling **#6 Send reports** discovery. Build the
  consent-gate + install-id + anonymous-upload + purge-on-disable substrate
  **once**, there, and reuse it here.
- Background **behavioral** analytics is the weaker justification: small user
  base, low event volume, privacy-hostile audience, and a non-trivial ongoing
  ops/policy cost (PostHog account, Cloud/self-host, retention). The benefit
  (feature-adoption counts to prioritize a visible roadmap) is real but modest,
  and can be approximated by lightweight, typed, allow-listed counters.
- The privacy risk of getting capture wrong in this app is **high** (window
  titles, app identities, desktop contents). That argues for extreme
  minimalism, not for pulling in a full SDK with autocapture/session-recording
  defaults that must be carefully disabled.

**Concrete path if/when pursued (minimal, safe order):**

1. Land `analyticsEnabled` (default `false`) + `installId` in
   `RuntimeStateStore`, following the `ipcEnabled` precedent (§3.3–3.5).
   No client yet — just the gate and the identity.
2. Add the consent step to onboarding and the toggle + "what we collect"
   disclosure to the Diagnostics tab (§3.6).
3. Share the crash-marker + upload pipeline with #6.
4. Only then, layer **typed, allow-listed** event capture (§4.4) — preferring a
   hand-rolled `URLSession` client (path B) unless feature flags justify the
   full SDK (path A).
5. Auto-disable for dev builds via the existing `isReleaseVersion` guard.

**One-line verdict:** worth doing eventually, low priority now, and only after
#6 establishes the consented upload substrate it should share.
