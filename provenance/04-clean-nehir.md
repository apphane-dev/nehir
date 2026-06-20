# Clean-nehir files (category 5)

These 63 files are cleanly implemented in Nehir with no prior existence anywhere
in `BarutSRB/OmniWM`. Round 2 revalidated every one against an isolated
full-history clone of upstream, restricted to the `origin` remote (true
BarutSRB upstream; the `fork` and `nehir` remotes are Nehir-side and were
excluded). For each file, both a rename-aware basename search and a multi-token
content search (`git log origin/main -S <token>` and `git grep <token>
origin/main`) on the file's own distinctive type/method/string tokens returned
empty.

A "clean-nehir" verdict means the file's **own** code is absent from upstream.
Many of these files *consume* upstream infrastructure inherited via the fork
base (e.g. a Nehir-only test exercises an upstream production type; a Nehir-only
view references an upstream setting) — that is expected and does not make the
file upstream-derived. The file itself is new.

## Independent spot-check (2026-06-20)

For a sample of the most load-bearing claims, the file's own primary type name
was confirmed absent from `BarutSRB/OmniWM` `origin/main`:

| Nehir type / file | `origin/main` search result |
| --- | --- |
| `PureLayoutReducer` (`Core/PureLayout/PureLayoutReducer.swift`) | empty |
| `SettingsMigrationStateStore` (`Core/Config/SettingsMigrationStateStore.swift`) | empty |
| `OnboardingView` (`UI/Onboarding/OnboardingView.swift`) | empty |
| `WhatsNewContent` (`UI/Onboarding/WhatsNewContent.swift`) | empty |
| `InteractiveMoveDemo` (`UI/Onboarding/InteractiveMoveDemo.swift`) | empty |
| `RawAXNotificationRecorder` (`Core/Ax/RawAXNotificationTrace.swift`) | empty |
| `CLILegalNotice` (`NehirCtl/CLILegalNotice.swift`) | empty |
| `BuildVersion` (`Core/Support/BuildVersion.swift`) | empty |
| `DisplayEnvironmentDiagnostics` (`Core/Monitor/DisplayEnvironmentDiagnostics.swift`) | empty |
| `ProjectionInvalidation` (`Core/ProjectionInvalidation.swift`) | empty |

(Upstream has a mirrored `ReconcileTraceRecorder` type, which is distinct from
Nehir's `RawAXNotificationRecorder`.)

## Cross-check with the upstream-port roadmap

The PureLayout subsystem (category 5) is independently confirmed as
Nehir-original by the architecture spike plan
[`discovery/20260618-pure-niri-engine-extraction.md`](../discovery/20260618-pure-niri-engine-extraction.md)
(A1): pure models/reducer/invariants are to be "added under
`Sources/Nehir/Core/PureLayout/`" as new Nehir work, deliberately free of
upstream's Dwindle model.

The broader Nehir reconcile vocabulary (`RuntimeStore`, `ReconcileTxn`,
`Planner`, `StateReducer`, `InvariantChecks`, `FocusPolicyEngine`) is confirmed
Nehir-original by the roadmap's explicit decision **not** to port upstream's
`WorldStore`/`EventIntake`/`IntentLedger` cluster wholesale; see
`03-cross-check-upstream-port-roadmap.md`.

## Caveat on tests

Several category-5 test files exercise upstream production types
(`DisplaySpacesMode`, `NiriMonitor`, `SnapPoint`, `AXFrameApplyResult`,
`OutputId`). The production types are upstream; the **test files** are not —
they have no upstream counterpart and were written for Nehir. They are
classified 5 on the test-file's-own-code criterion, with the consumed production
type noted where relevant.

## The 63 files by area

### Config — split codecs, migration/diagnostics/onboarding stores (12)
- `Sources/Nehir/Core/Config/AppRuleFileStore.swift`
- `Sources/Nehir/Core/Config/ConfigAssistancePrompt.swift`
- `Sources/Nehir/Core/Config/ConfigMismatchDetector.swift`
- `Sources/Nehir/Core/Config/HotkeyConfigMapping.swift`
- `Sources/Nehir/Core/Config/HotkeysTOMLCodec.swift`
- `Sources/Nehir/Core/Config/MonitorOverrideFileStore.swift`
- `Sources/Nehir/Core/Config/OnboardingStateStore.swift`
- `Sources/Nehir/Core/Config/SettingsDiagnosticsIssue.swift`
- `Sources/Nehir/Core/Config/SettingsMigrationRegistry.swift`
- `Sources/Nehir/Core/Config/SettingsMigrationStateStore.swift`
- `Sources/Nehir/Core/Config/SettingsTOMLUnknownValue.swift`
- `Sources/Nehir/Core/Config/WorkspacesTOMLCodec.swift`

### PureLayout subsystem (4)
- `Sources/Nehir/Core/PureLayout/PureDirection.swift`
- `Sources/Nehir/Core/PureLayout/PureLayoutInvariants.swift`
- `Sources/Nehir/Core/PureLayout/PureLayoutModels.swift`
- `Sources/Nehir/Core/PureLayout/PureLayoutReducer.swift`

### Controller protocols (2)
- `Sources/Nehir/Core/Controller/LayoutTrace.swift`
- `Sources/Nehir/Core/Controller/WMCommandTarget.swift`

### Core misc (6)
- `Sources/Nehir/Core/Ax/RawAXNotificationTrace.swift`
- `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+PureLayoutBridge.swift`
- `Sources/Nehir/Core/Monitor/DisplayEnvironmentDiagnostics.swift`
- `Sources/Nehir/Core/ProjectionInvalidation.swift`
- `Sources/Nehir/Core/Support/BuildVersion.swift`
- `Sources/Nehir/Core/Workspace/InteractionMonitorWriteTrace.swift`

### Onboarding / WhatsNew UI (14)
- `Sources/Nehir/UI/Onboarding/Animations/StaticStepIcon.swift`
- `Sources/Nehir/UI/Onboarding/Animations/WelcomeAnimation.swift`
- `Sources/Nehir/UI/Onboarding/Animations/WorkspaceBarAnimation.swift`
- `Sources/Nehir/UI/Onboarding/ConfigRecoveryView.swift`
- `Sources/Nehir/UI/Onboarding/InteractiveMoveDemo.swift`
- `Sources/Nehir/UI/Onboarding/NehirLogo.swift`
- `Sources/Nehir/UI/Onboarding/OnboardingStepControls.swift`
- `Sources/Nehir/UI/Onboarding/OnboardingStepView.swift`
- `Sources/Nehir/UI/Onboarding/OnboardingSteps.swift`
- `Sources/Nehir/UI/Onboarding/OnboardingView.swift`
- `Sources/Nehir/UI/Onboarding/OnboardingWindowController.swift`
- `Sources/Nehir/UI/Onboarding/ReleaseNotes.swift`
- `Sources/Nehir/UI/Onboarding/WhatsNewContent.swift`
- `Sources/Nehir/UI/Onboarding/WhatsNewView.swift`

### UI — settings tabs, badges, helpers (9)
- `Sources/Nehir/UI/AboutSettingsTab.swift`
- `Sources/Nehir/UI/BehaviorSettingsTab.swift`
- `Sources/Nehir/UI/ConfigurationFilesSection.swift`
- `Sources/Nehir/UI/DestructiveConfirmationAlert.swift`
- `Sources/Nehir/UI/DeveloperBadge.swift`
- `Sources/Nehir/UI/DisplayDiagnosticsSettingsTab.swift`
- `Sources/Nehir/UI/ExperimentalBadge.swift`
- `Sources/Nehir/UI/LayoutSettingsTab.swift`
- `Sources/Nehir/UI/SettingInfo.swift`

### NehirCtl (1)
- `Sources/NehirCtl/CLILegalNotice.swift`

### Tests (15)
- `Tests/NehirTests/ConfigMismatchDetectorTests.swift`
- `Tests/NehirTests/DisplayEnvironmentDiagnosticsTests.swift`
- `Tests/NehirTests/DisplaySpacesModeTests.swift`
- `Tests/NehirTests/InteractiveMoveDemoModelTests.swift`
- `Tests/NehirTests/MonitorIdentityMatchingTests.swift`
- `Tests/NehirTests/NiriMonitorTests.swift`
- `Tests/NehirTests/PureLayoutAgreementTests.swift`
- `Tests/NehirTests/PureLayoutBoundaryTests.swift`
- `Tests/NehirTests/PureLayoutReducerTests.swift`
- `Tests/NehirTests/ResizeMinimumLearnerTests.swift`
- `Tests/NehirTests/SettingsMigrationStateStoreTests.swift`
- `Tests/NehirTests/ViewportSnapContextTests.swift`
- `Tests/NehirTests/WhatsNewAutoShowTests.swift`
- `Tests/NehirTests/WorkspaceNavigationHandlerTests.swift`
- `Tests/NehirTests/WorkspacesTOMLCodecTests.swift`

The full per-file evidence is in [`files.tsv`](files.tsv) (rows where
`final_cat == 5`).
