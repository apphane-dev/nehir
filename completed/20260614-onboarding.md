# Onboarding — Phase 4

Onboarding, version-upgrade What's New, and config-mismatch handling for Nehir.
Three flows share one window controller (`OnboardingWindowController`, singleton, `@MainActor`):

1. **First-run wizard** — 5-step wizard shown on first launch; teaches the tiling concept +
   accessibility, the Focus & Move interaction, the workspace bar, and experimental features.
2. **What's New screen** — single-screen summary shown on version upgrade; content is
   developer-written and bundled. Also reachable from the onboarding final screen and the
   status bar menu.
3. **Config Update screen** — shown when `settings.toml` contains keys the current schema
   doesn't recognize. Backs up + cleans the file before activation and offers an AI prompt
   that points at the release notes.

## Completed

- [x] `OnboardingStateStore` — single-fact plain-text persistence (`onboarding-version`)
- [x] `ConfigMismatchDetector` — schema-round-trip mismatch detection (no manifest)
- [x] Pre-bootstrap config gate in `AppDelegate` (backup + clean + show screen before activation)
- [x] `OnboardingWindowController` — shared window controller for all three flows
- [x] 5-step wizard (`welcome`, `navigation`, `workspaceBar`, `experimental`, `done`)
- [x] Interactive 3-finger Focus & Move demo (`InteractiveMoveDemo`)
- [x] Onboarding suppression of layout engine + hotkeys + workspace bar (`WMController.onboardingActive`)
- [x] Settings → General "Re-run Setup Wizard" entry
- [x] Status-bar "What's New" menu row
- [x] What's New screen + bundled content
- [x] What's New version gating redesigned to semver (no hardcoded version constant) — see Decision log
- [x] `Window Borders` default flipped to off (existing values unaffected)
- [x] `dev:onboarding` mise task (clear onboarding state + relaunch)
- [x] Build with zero errors

## Decision log

### 20260614 — What's New version gating redesigned (Option C)

**Problem.** The original gate was `Bundle.main.appVersion == WhatsNewContent.version`, compared
against a hardcoded `version` constant in `WhatsNewContent`. If that constant drifted from the
version the release workflow stamps into `Info.plist`, What's New silently failed to show — a
whole-release silent miss with no signal.

We considered **Option 1 (semver gate) + a release-time CI guardrail that validates baked-in
content against the calculated version** (skipped on prereleases). That was rejected as
internally inconsistent: a guardrail that validates "content vs version" *requires* a version
field to validate against, which reintroduces exactly the drift surface Option 1 is meant to
remove. With the field deleted, the guardrail degrades to "file was touched," which a leftover
bullet list passes. It would provide the illusion of coverage, not coverage. Skipping the check
on prereleases also optimized the wrong direction (drift introduced during the RC cycle would go
uncaught until stable promotion — the moment of least tolerance for a release failure).

**Resolution (Option C).** Decouple the gate from any constant:

- `WhatsNewContent` is **bullets-only** — no `version` field, no per-version entry list.
- Auto-show fires when the running build is a **release version** (`isReleaseVersion`: rejects
  the `0.0.0` dev placeholder and prerelease tags like `0.5.0-rc.1`) **and** `WhatsNewContent.bullets`
  is non-empty **and** the running version is **semver-newer than** the recorded last-seen
  version (`isVersion(_:newerThan:)`, numeric `MAJOR.MINOR.PATCH`, prerelease suffixes stripped).
- The screen's title/version comes from `Bundle.main.appVersion` — no duplicated constant.
- Junk recorded on disk parses as `(-1, -1, -1)` so it can never block a real upgrade showing.
- Empty `bullets` **disables** the screen: auto-show is skipped and the on-demand entry points
  (`showWhatsNewForCurrentVersion`, `showWhatsNewReplacingOnboarding`) no-op. Stale/missing
  content **fails closed** (user sees nothing) rather than wrong (last release's highlights).

**Trade-off accepted.** There is no machine check that `bullets` match the release being cut —
content freshness is a review/release-prep concern, like a commit message. Bullets must be
refreshed as part of release prep.

**Testing implication.** Auto-show is deliberately not exercisable in a plain dev build
(`0.0.0` is rejected). On-demand entries (status-bar menu, wizard Done step) work in dev. To
test the auto-show gate locally, spoof a release version in `Info.plist` for one run and write
an older version into `onboarding-version` (see Manual verification).

## Persistence

Onboarding completion is a single plain-text file: `onboarding-version` in the state directory.

- **File existence** = onboarding completed. A missing file re-presents the wizard.
- **File content** = the last-seen version string (written on wizard finish *and* on What's New
  acknowledgment), compared against the running version to decide whether to auto-show What's New.

One fact, not two. This collapses the previous design's separate "completed" and "presented"
fields, which also removes a quirk where a freshly-onboarded user at vX would be re-shown
What's New for vX on the next launch. `OnboardingStateStore` exposes:

- `hasCompletedOnboarding: Bool` — file exists
- `lastSeenVersion: String?` — file content
- `record(version:)` — writes the version (deferred + flushed on terminate)

Atomic write via temp file + `rename(2)`, private permissions (`S_IRUSR | S_IWUSR`), same
pattern as `RuntimeStateStore`. No migration from any prior format — nothing was released.

## Config Update (config-mismatch) handling

**No migration manifest is maintained.** The valid config key set is derived from the schema
itself via a round trip in `ConfigMismatchDetector`:

- Parse the raw file → every key present (original case, file order, de-duplicated).
- Decode into `CanonicalTOMLConfig`, then re-encode via `SettingsTOMLCodec` → the keys that
  survived (Codable silently drops unknown keys).
- **Mismatch** = present in the raw file but absent from the re-encoded output.

When the schema changes (keys added or removed), the round trip reflects it automatically —
nothing to update here, ever. Detection is structural (TOML decode + recursive key walk), so it
ignores comments and substring matches naturally.

The screen is a **true pre-bootstrap gate**: it runs before `SettingsStore`, `WMController`,
status bar, IPC, hotkeys, tiling, onboarding, or What's New decisions are created/activated.
On mismatch:

1. Create a timestamped backup immediately: `settings-YYYYMMDD-HHMMSS.toml.backup` (numeric
   suffix if a same-second name exists).
2. If the backup succeeded, write a clean recognized-schema `settings.toml` (decode → re-encode
   → overwrite) before activation, so the app runs on a valid file immediately. If the backup
   failed, the cleanup is skipped for safety and the original file is left untouched.
3. Show the Config Update screen (`MigrationView`), reporting the backup + cleanup status.

The screen's primary action is **Copy AI Prompt**: copies a prompt that lists the unknown keys,
names the running version + the GitHub release URL for that version (and the releases index),
and tells the AI to inspect older release notes on its own if the rename happened in a prior
release. Breaking config changes must be documented in the changeset that introduces them so
the AI can find the old→new mapping from the release notes — not from code.

Dismiss just continues startup (with the cleaned file if cleanup ran, or the original if it
didn't). No version gating — detection runs every launch (it's cheap) and naturally stops
triggering once the keys are removed.

## What's New

`WhatsNewContent` is a single curated `bullets: [String]` for the current release — **no
version constant** (see Decision log). The full per-release changelog lives on GitHub Releases;
`ReleaseNotes` centralizes the repository URL and `releases/tag/v<version>` convention.

Auto-show at launch fires from `AppDelegate.continueBootstrap` (the `else` branch after the
onboarding check) when:

1. `Bundle.main.appVersion` is a release version (`isReleaseVersion`: not `0.0.0`, no prerelease tag), and
2. `WhatsNewContent.bullets` is non-empty, and
3. `onboardingStore.lastSeenVersion` exists and is semver-older than the running version.

So dev builds (`0.0.0`) and prereleases (`0.5.0-rc.1`) never auto-show, and each release shows
at most once per user. Finishing onboarding at vX records vX, so that user is not re-shown
What's New for vX on the next launch.

What's New is also reachable on demand (always works, including in dev, gated only on non-empty
bullets):

- **Status bar menu** — explicit "What's New" row (sparkles icon) after Settings.
- **Onboarding final screen** — "See What's New" link.

Both call `OnboardingWindowController.showWhatsNewForCurrentVersion()`, which sources the
display version from `Bundle.main.appVersion` and no-ops when `bullets` is empty.

## First-run wizard

`OnboardingStep` enum (5 cases): `welcome`, `navigation` ("Focus & Move"), `workspaceBar`,
`experimental`, `done`. Accessibility is folded into the `welcome` step
(`AccessibilityStepControl` renders there) rather than being a separate step. Each step renders
via `OnboardingStepView`: a hero title (`.system(size: 28, weight: .bold)`, tight tracking), body
copy, an animation/control slot, progress dots, and Back + Continue nav (Skip removed; nav is
Back + Continue only). The wizard window is 480×640.

### Suppression during onboarding

The layout engine and global hotkeys never run while the wizard is on screen:

- `WMController.onboardingActive` + `setOnboardingActive(_:)`; `setEnabled` starts services only
  when `!onboardingActive`; `reconcileEnabledAndHotkeysState` requires `!onboardingActive`;
  `ServiceLifecycleManager.start()`'s guards also check `!controller.onboardingActive`.
- `LayoutRefreshController.requestRefresh` returns early when `controller.onboardingActive`,
  so no layout passes run until onboarding completes.
- `WMController.isWorkspaceBarVisible(...)` returns `false` when `onboardingActive`, and
  `setOnboardingActive(true)` calls `workspaceBarManager.setEnabled(false)`, so the real
  workspace bar never renders during the wizard.

AppDelegate sets the flag active *before* `applyPersistedSettings` on first launch;
`OnboardingWindowController.show()` sets it active (covers re-run); the wizard window's
`willClose` sets it inactive → (re)activates the engine.

### Interactive Focus & Move demo

`InteractiveMoveDemo` replaces the static shortcut list on the navigation step. It's a small
in-memory column model (`MoveDemoModel`) modeling Niri's **consume-or-expel** move semantics:
moving a window that shares a column **expels** it into its own column; a **solo** window
**collocates** into the neighbour column (stacking) and its empty source column collapses.

Input is the **real 3-finger trackpad path**, mirroring how Nehir itself reads gestures:
`ThreeFingerGestureTapController` — a listen-only `.cghidEventTap` for `.gesture` events,
converted to `NSEvent(cgEvent:)?`, inspecting `allTouches()`, requiring **exactly three** active
touches, with a deadzone (`0.00025`) and multiplier (`1000`).

**No fallback gesture paths.** `.scrollWheel` local monitors, `NSPanGestureRecognizer`, generic
pan bridges, and plain `DragGesture` viewport scrolling are all intentionally absent — those
reintroduce 2-finger scrolling and bypass the intended 3-finger path. Click-to-focus uses
`SpatialTapGesture` via `.simultaneousGesture` with 2D hit-testing so stacked windows are
individually selectable. Keyboard is a local `NSEvent` key monitor mirroring the real
`Opt+←→` focus / `Opt+Shift+←→` move / `⌃⌥⌘←→` workspace / `⌘⌥Space` palette bindings.

The viewport is a fixed schematic (`viewportWidth = 150`) with a dashed "Visible Area" indicator.
The track is **not clipped** — off-screen columns stay visible; the dashed rectangle is just an
indicator of the scrollable viewport, not a clip mask. `maxScroll = contentWidth - viewportWidth`.

**All focus/move/scroll changes go through one animation transaction**
(`animateFocusIfNeeded` → `withAnimation(.easeInOut(duration: 0.28))`) so the column highlight
and the viewport track move in lockstep. The competing implicit `.animation(value: isFocused)`
was removed. Live 3-finger drags bypass animation via `isLiveDragging`.

The navigation shortcut legend below the demo is **derived, not hardcoded**: `NavigationStepControl`
looks up bindings by ID from `ActionCatalog.defaultHotkeyBindings()` and renders
`KeyBinding.displayString`, so it can't drift from the real defaults.

### Other steps

- **Welcome** — name origin from `README.md` (Turkish for "river") + tiling concept
  (`NehirLogo` loads `Logo.png`), with the **Accessibility** status row folded in (lock/checkmark
  + "Open System Settings"), live-updating via `AccessibilityPermissionMonitor`. Accessibility is
  skippable; a non-grant is reminded on the Done step.
- **Workspace Bar** — `WorkspaceBarAnimation` is a faithful miniature of the real bar (pills +
  scratchpad capsule, focus cycling), not an SF Symbol.
- **Experimental** — three features (Focus Follows Mouse, Move Cursor to Focused Window, Window
  Borders) each with a description and `ExperimentalBadge`, plus a Developer Mode row with
  `DeveloperBadge`. Body warns features may be unstable or change between releases.
- **Done** — `DoneStepControl` shows the Accessibility reminder when permission is missing
  (non-blocking) and a "See What's New" link. Continue reads "Start Using Nehir" and records
  the version.

### Settings re-entry

Settings → General has a "Re-run Setup Wizard" action calling `OnboardingWindowController.rerun()`
(the controller caches the stores via `configure()` so Settings needs no `onboardingStore`
reference). Re-run always starts from step 1.

## Window controller notes

`OnboardingWindowController` supports all three flows via a shared
`present(existing:rootView:title:size:assign:onClose:)` helper. `observerTokens` is a dictionary
keyed by `ObjectIdentifier(window)`, marked `nonisolated(unsafe)`, with deinit cleanup — supports
wizard/what's-new/config-update windows concurrently. `OwnedWindowRegistry` registration +
`willCloseNotification` observers mirror the `SettingsWindowController` pattern.

## Files

- `Sources/Nehir/Core/Config/OnboardingStateStore.swift` — plain-text version store
- `Sources/Nehir/Core/Config/ConfigMismatchDetector.swift` — schema-round-trip mismatch detection
- `Sources/Nehir/App/AppDelegate.swift` — pre-bootstrap config gate + wizard/what's-new hooks + semver gate helpers
- `Sources/Nehir/UI/Onboarding/OnboardingWindowController.swift` — shared window controller
- `Sources/Nehir/UI/Onboarding/OnboardingView.swift` — wizard root
- `Sources/Nehir/UI/Onboarding/OnboardingSteps.swift` — step enum + copy
- `Sources/Nehir/UI/Onboarding/OnboardingStepView.swift` — step shell
- `Sources/Nehir/UI/Onboarding/OnboardingStepControls.swift` — per-step controls
- `Sources/Nehir/UI/Onboarding/InteractiveMoveDemo.swift` — model + view + 3-finger tap controller
- `Sources/Nehir/UI/Onboarding/MigrationView.swift` — Config Update screen
- `Sources/Nehir/UI/Onboarding/ReleaseNotes.swift` — centralized repository/release URLs
- `Sources/Nehir/UI/Onboarding/WhatsNewContent.swift` — bundled bullets (no version constant)
- `Sources/Nehir/UI/Onboarding/WhatsNewView.swift` — What's New screen
- `Sources/Nehir/UI/Onboarding/NehirLogo.swift` + `Resources/Logo.png`
- `Sources/Nehir/UI/Onboarding/Animations/` — `WelcomeAnimation`, `WorkspaceBarAnimation`,
  `StaticStepIcon`
- `Sources/Nehir/UI/StatusBar/StatusBarMenu.swift` — "What's New" menu row

## Manual verification

Run with `mise run dev:onboarding` (kills Nehir, clears `onboarding-version`, relaunches).

- [ ] Clean launch (no `onboarding-version`): wizard appears, all 5 steps navigate, Done records
      version and closes; engine/hotkeys/workspace bar activate only after close
- [ ] Re-run from Settings → General: wizard reopens from step 1
- [ ] Focus & Move demo: 3-finger swipe scrolls; click focuses (incl. stacked windows);
      `Opt+←→` / `Opt+Shift+←→` move/focus; highlight + scroll move in lockstep; 2-finger scroll
      does nothing
- [ ] Config mismatch: unknown key in `settings.toml` → Config Update screen appears *before*
      activation; timestamped backup created; clean file written; Copy AI Prompt copies a prompt
      naming the version + release URL; dismiss continues startup; relaunch shows no screen
- [ ] What's New on demand: reachable from status bar menu and from the Done screen; closes cleanly
- [ ] What's New auto-show gate: spoof a release version in `Info.plist` (`PlistBuddy … "0.5.0"`),
      write an older version into `onboarding-version`, launch → screen auto-shows; equal versions
      → no auto-show; restore `Info.plist` (`git checkout Info.plist`) after
- [x] Build with zero errors and zero warnings introduced by this feature
