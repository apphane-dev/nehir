# Command Palette hotkey (Opt+Cmd+Space) also triggers a system action — Diagnostics for global-hotkey conflicts (issue #48)

Source issue: <https://github.com/Guria/nehir/issues/48> (labels: `question`,
`wontfix`).

> **Status — shipped 2026-06-20.** Implemented on branch
> `patch/nehir-48-command-palette-hotkey-conflict` (commit `009a2b73`, "Surface
> global-hotkey conflicts in Diagnostics (Nehir #48)"). Both prongs below landed
> as-proposed, with the as-built deltas noted in **Outcome (as-built)**. Full
> suite green (1264/1264); new `HotkeyConflictDiagnosticsTests` covers both
> prongs (11 tests). See that section for the durable record of what shipped.

All file/line references were verified against the main Nehir source tree at
`7b731a51` ("Move remainder to plans branch"). Re-verify be3fore implementing;
line numbers drift. As-built citations in the Outcome section are verified
against the shipped commit `009a2b73`.

---

## TL;DR

- The reporter's bug (`Opt+Cmd+Space` opens the Nehir command palette **and**
  also opens Finder every time) was a **system-level global-hotkey conflict**,
  not a Nehir code bug. Maintainer asked "could it be a conflict with your
  system hotkeys?"; reporter confirmed reassigning the system shortcut fixed
  it. The issue is tagged `wontfix` for the bug itself.
- The one Nehir-side, owner-accepted (low-priority) ask is the reporter's
  follow-up: *"add some sort of warning to warn about this possible behaviour
  so the user can change this."* Owner: *"we can try to add diagnostic for
  that, but priority is low."*
- Nehir **already detects Carbon-level registration collisions** but surfaces
  them **only as an inline hint on the specific Hotkey settings row** — never in
  the Diagnostics hub, with no badge. And critically, the **reported symptom
  does not even trigger that detection**, because a macOS System-Settings
  shortcut co-fires alongside a *successful* Carbon registration.
- **Verdict / scope:** small `planned/` doc. Add a Diagnostics entry that (a)
  mirrors live `registrationFailures` into the Diagnostics hub + badge (catches
  Carbon `eventHotKeyExistsErr` conflicts and internal `.duplicateBinding`
  collisions), and (b) ships a curated advisory for the command-palette default
  chord so the *reported* System-Settings co-fire is warned about even when
  Carbon registration succeeds. Remediation is "reassign this Nehir hotkey or
  clear the conflicting macOS shortcut."

## Why this is not a code fix (the "also opens Finder" symptom)

Nehir does not open Finder. The command-palette hotkey is bound by default to
`Option+Command+Space`:

```swift
// Sources/Nehir/Core/Input/ActionCatalog.swift:667
action(
    id: "openCommandPalette",
    command: .openCommandPalette,
    category: .focus,
    binding: KeyBinding(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey | cmdKey)),
    keywords: ["palette", "search", "commands", "menu"]
)
```

`kVK_Space` is Carbon `0x31`; `optionKey | cmdKey` are the Carbon modifier
constants. This maps to `[ui].commandPalette` in `hotkeys.toml`
(`Sources/Nehir/Core/Config/HotkeyConfigMapping.swift:112` →
`("ui", "commandPalette", "openCommandPalette")`).

macOS resolves the same chord system-wide: when the user also has
`Option+Command+Space` bound at the OS level (a common Input-Sources /
Spotlight-adjacent chord in some locales, or a launcher / Finder-triggering
shortcut the user set), both fire. Nehir's Carbon registration **succeeds** and
its palette opens; the OS-level handler **also** fires and opens Finder. There
is no Nehir code path that launches Finder here, so there is nothing to "fix" in
the palette dispatch. The user's remedy (which worked) is to reassign one of the
two conflicting shortcuts. The Nehir-side contribution is to **warn proactively**
so the next user does not have to diagnose it from a screenshot.

## What Nehir already detects (and where it falls short)

Registration is Carbon `RegisterEventHotKey`. The hotkey center records two
failure kinds:

```swift
// Sources/Nehir/Core/Input/Hotkeys.swift:24
enum HotkeyRegistrationFailureReason: Equatable {
    case duplicateBinding
    case systemReserved
}
```

`registerHotkeys()` plans registrations, then registers each chord:

```swift
// Sources/Nehir/Core/Input/Hotkeys.swift:116
private func registerHotkeys() {
    unregisterAll()
    let plan = Self.registrationPlan(for: configuration.bindings)
    registrationFailures = plan.failures
    var nextId: UInt32 = 1
    for registration in plan.registrations {
        guard registrationFailuresForAction(registration.action).isEmpty else { continue }
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4F4D_4E49), id: nextId)
        let status = RegisterEventHotKey(
            registration.binding.keyCode,
            registration.binding.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr, let ref {
            refs.append(ref)
            idToAction[nextId] = registration.action
        } else {
            markSystemReservedFailure(for: registration.action)   // Hotkeys.swift:140 / :153
        }
        nextId += 1
    }
}
```

`.duplicateBinding` is produced by `registrationPlan(for:)`
(`Hotkeys.swift:170`–end of the extension) when two Nehir commands claim the
same chord; `.systemReserved` is set when `RegisterEventHotKey` returns anything
other than `noErr` (`Hotkeys.swift:153`–`:157`, storing into
`registrationFailures[command] = .systemReserved` at `:156`).

This is exposed on the controller:

```swift
// Sources/Nehir/Core/Controller/WMController.swift:806
var hotkeyRegistrationFailures: [HotkeyCommand: HotkeyRegistrationFailureReason] {
    hotkeys.registrationFailures
}
```

…and rendered **inline** in the Hotkey settings tab, per binding row:

```swift
// Sources/Nehir/UI/HotkeySettingsView.swift:677  (HotkeyBindingRow.failureReason)
// Sources/Nehir/UI/HotkeySettingsView.swift:729
private func failureMessage(for reason: HotkeyRegistrationFailureReason) -> String {
    switch reason {
    // ...
    case .systemReserved:
        return "Failed to register: this key combination may be reserved by the system"
    }
}
```

(The inline UI is the orange triangle + caption in `HotkeyBindingRow.body`,
`HotkeySettingsView.swift:683`–`:715`.)

**Two gaps for issue #48:**

1. **Not in Diagnostics.** The Diagnostics issue model has no hotkey case:
   ```swift
   // Sources/Nehir/Core/Config/SettingsDiagnosticsIssue.swift:14
   enum SettingsDiagnosticsIssue: Identifiable, Equatable {
       case softMigration(PendingSettingsMigration)
       case unknownKeys(UnknownSettingsKeysIssue)
   }
   ```
   `SettingsDiagnosticsDetector.applicableIssues(configDirectory:)`
   (`SettingsDiagnosticsIssue.swift:29`–`:41`) is purely config-file-based — it
   reads migrations + `detectUnknownKeys` off `settings.toml` and has **no access
   to the live `HotkeyCenter`**. The Diagnostics tab
   (`Sources/Nehir/UI/DisplayDiagnosticsSettingsTab.swift:70`–`:92`, detector
   call at `:460`) and the sidebar badge therefore never reflect hotkey
   conflicts. A user who does not drill into the exact Hotkey settings row never
   sees the existing hint.

2. **The reported symptom is invisible to this detection.** Carbon
   `RegisterEventHotKey` returns an error (typically `eventHotKeyExistsErr`,
   `-9878`) **only** when another process registered the same chord through
   Carbon's Hot Key Manager. A macOS System-Settings shortcut (Input Sources,
   Spotlight, a launcher) is delivered through the system services layer, not
   Carbon's hotkey manager, so for `Option+Command+Space` co-firing with Finder
   the call returns `noErr`, `registrationFailures` stays empty, and even the
   inline hint never appears. Detection that only mirrors Carbon's return code
   will miss the exact case the reporter hit.

## Proposal

> Accepted as-proposed. See **Outcome (as-built)** below for what shipped and
> where it diverged (notably: the detector gained a second `hotkeyBindings:`
> parameter, and hotkey rows are non-postponable by design).

Small, two-pronged addition to Diagnostics. Both prongs are non-blocking rows in
the existing Diagnostics tab; neither rewrites any config.

## Outcome (as-built)

Shipped on branch `patch/nehir-48-command-palette-hotkey-conflict` @ `009a2b73`.
The two prongs map one-to-one to the proposal; the design notes below record the
as-built shape, the generic-vs-specific split, and the deltas from the proposal.

### What shipped

**New diagnostics model** (`Sources/Nehir/Core/Config/SettingsDiagnosticsIssue.swift`):

- `struct HotkeyConflictIssue` (`:23`) — live Carbon/internal failure row.
  Carries `actionID`, `command`, `chordDisplayString`, `reason`
  (`.systemReserved` / `.duplicateBinding`), and a `remediation` string per
  reason. Stable id `"hotkey-conflict:\(actionID)"`.
- `struct HotkeyAdvisoryIssue` (`:47`) — curated default-chord advisory row.
  Carries `actionID`, `command`, `chordDisplayString`, `advisoryText`. Stable id
  `"hotkey-advisory:\(actionID)"`.
- `SettingsDiagnosticsIssue` gains `.hotkeyConflict` / `.hotkeyAdvisory`
  (`:60`–`:61`); `id` switch is exhaustive.

**Detector** (`SettingsDiagnosticsIssue.swift`):

- `applicableIssues(configDirectory:hotkeyFailures:hotkeyBindings:)` (`:82`) and
  `pendingIssues(...)` (`:93`) gain the two new parameters, both defaulting to
  empty so all existing config-only callers are byte-identical (guarded by a
  regression test).
- Old config logic factored into private `configBasedIssues(configDirectory:)`
  (`:126`). Two new builders: `hotkeyConflictIssues(failures:bindings:)` (`:138`)
  and `hotkeyAdvisoryIssues(bindings:)` (`:171`).
- **Non-postponable by design.** Hotkey rows return a shared sentinel id
  `nonPostponableID = "hotkey:non-postponable"` (`:124`) from `postponeID(for:)`,
  which `SettingsMigrationStateStore` never records. They therefore always pass
  the postponement filter and clear naturally when the chord is fixed — they
  cannot be hidden the way migrations can.

**Curated catalog** (`Sources/Nehir/Core/Config/HotkeyAdvisoryCatalog.swift`,
new file):

- `CuratedHotkeyAdvisory` (`:18`) + `enum HotkeyAdvisoryCatalog` (`:24`) with
  `knownSystemConflicts: [CuratedHotkeyAdvisory]` (`:28`), seeded with exactly
  one entry — `actionID: "openCommandPalette"` (`:30`) — whose advisory text is
  the proposal copy verbatim.
- The advisory fires only while `current.binding == defaultBinding.binding`
  (both derived from `HotkeyBindingRegistry`, never hardcoded Carbon constants)
  and the chord is non-unassigned, so reassigning or unassigning suppresses it.

**UI surfacing:**

- `HotkeyConflictWarningView` (private, `DisplayDiagnosticsSettingsTab.swift:792`)
  renders both rows, advisory-only (no action buttons — remediation is manual).
- `DisplayDiagnosticsSettingsTab.refreshSettingsIssues()` (`:504`) feeds in
  `controller.hotkeyRegistrationFailures` + `settings.hotkeyBindings`.
- `SettingsSidebar` (`SettingsSidebar.swift:69`–`:72`) now takes `controller` +
  `@Bindable settings` and passes them to `pendingIssues(...)`, so the badge
  count includes hotkey rows. `SettingsView` threads them in.
- `WhatsNewView` (`:117`) and `StatusBarMenu` (`:215`) `switch` over
  `SettingsDiagnosticsIssue` is made exhaustive — `keyboard` icon +
  `"X hotkey conflict"` / `"X hotkey advisory"` labels.

**Tests** (`Tests/NehirTests/HotkeyConflictDiagnosticsTests.swift`, new file,
11 `@Test` functions):

- Prong 1: `.systemReserved` → one conflict row; `.duplicateBinding` across
  `.move(.left)`/`.move(.right)` → two rows; empty failures → no conflict row;
  a failing command absent from bindings falls back to a non-empty chord string
  (no crash).
- Prong 2: advisory fires for the command-palette default chord; disappears
  after reassign; suppressed when unassigned.
- Regression / policy: empty hotkey inputs equal the old config-only output
  (`applicableIssuesPreservesExistingConfigIssuesUnchanged`);
  `unknownKeys` + `hotkeyConflict` + `hotkeyAdvisory` coexist additively.
- Badge + postponement: `pendingIssues` count rises by the number of hotkey
  rows; conflict and advisory share the non-postponable sentinel id.

### Generic vs. command-palette-specific (the key design split)

- **Prong 1 is fully generic.** `HotkeyConflictIssue` is driven by
  `WMController.hotkeyRegistrationFailures` (`[HotkeyCommand:
  HotkeyRegistrationFailureReason]`), so every Nehir command that fails Carbon
  registration — not just Command Palette — surfaces in Diagnostics. The tests
  prove this with `.move(.left)`, `.move(.right)`, and `.toggleFullscreen`.
- **Prong 2 is generic infrastructure with a single seeded entry.** The
  detector iterates the whole catalog; adding coverage for another default is a
  one-line data change in `HotkeyAdvisoryCatalog.knownSystemConflicts`. The
  catalog exists precisely because Prong 1 cannot catch co-fire conflicts: when
  macOS resolves the chord system-wide *despite* a successful Carbon
  registration, there is no failure record to observe, so the only honest fix
  is a hand-curated list of known-bad defaults. Issue #48 happened to be the
  Command Palette default, so that is the single seed.

### Deltas from the proposal

- **Second detector parameter.** The proposal sketched
  `applicableIssues(configDirectory:hotkeyFailures:)`. The shipped signature adds
  `hotkeyBindings:` too, because Prong 2 must compare the current chord against
  the default chord (`HotkeyBindingRegistry.defaults()`) to stay
  default-scoped. This is the one material design refinement.
- **Non-postponable sentinel.** Not in the proposal; chosen during
  implementation so live hotkey rows always remain pending (they clear on fix,
  not on dismiss). Recorded as a deliberate policy decision.
- **Exhaustive switches in `WhatsNewView` / `StatusBarMenu`.** The proposal
  scoped UI to the Diagnostics tab + sidebar badge; making the two
  `SettingsDiagnosticsIssue` switches exhaustive was a required follow-on from
  adding enum cases, not extra scope.

### Validation

- `swift build` clean; `swift test` green (commit message records 1264/1264).
- `HotkeyConflictDiagnosticsTests` 11/11, covering both prongs, the regression
  guard, and the badge/postponement behavior.

### Post-ship refinement — PR #103 ("Refine hotkey diagnostics refresh")

Prong 2 was later refined by PR #103 (merge `671652c6`, "fixes #48, follow-up
to #97"). The advisory no longer fires on default-chord match alone; it now
additionally requires the overlapping macOS shortcut to be **currently
enabled**, read live from the `com.apple.symbolichotkeys` preference domain.
The conflicting shortcut is pinned precisely to symbolic-hotkey **ID 65
("Show Finder search window", default Option-Command-Space)** — the actual
mechanism behind the reporter's "also opens Finder" symptom, not the generic
"Input Sources" hedge in the original advisory text. Full findings, the
macOS preference-domain mechanism, the refresh wiring, and the precision
boundary (`enabled`-only, not chord-compared) are recorded in
`discovery/20260622-nehir-103-command-palette-advisory-symbolic-hotkey-gating.md`.

### Follow-ups (out of scope here)

- Extending `HotkeyAdvisoryCatalog` as new co-fire defaults are reported — a
  data change, not a code change. (PR #103 above was more than a data change:
  it added the symbolic-hotkey reader + enabled-conjunct gating + refresh
  triggers; see the discovery doc.)

### Prong 1 — Surface live registration failures in Diagnostics (+ badge)

Add a case to the Diagnostics issue model and feed it from the live runtime
state rather than from the config file:

```swift
// extend Sources/Nehir/Core/Config/SettingsDiagnosticsIssue.swift
case hotkeyConflict(HotkeyConflictIssue)
```

`HotkeyConflictIssue` carries the `HotkeyCommand` display name, the chord, and
the `HotkeyRegistrationFailureReason` (`.systemReserved` or
`.duplicateBinding`). The detector needs the live map: add an overload
`SettingsDiagnosticsDetector.applicableIssues(configDirectory:hotkeyFailures:)`
that takes `WMController.hotkeyRegistrationFailures`
(`WMController.swift:806`) and appends one row per failing command.
`DisplayDiagnosticsSettingsTab` (`:460`) calls the new overload, passing the
controller's failures; the sidebar badge count
(`Sources/Nehir/UI/SettingsSidebar.swift`, which already sums display issues)
counts these rows. Remediation copy: for `.systemReserved`, "Another app
registered this shortcut; reassign it in Hotkeys or quit the conflicting app";
for `.duplicateBinding`, "Two Nehir commands share this shortcut; assign a
unique chord." This catches Carbon-level conflicts and internal Nehir chord
collisions that today are hidden inside the Hotkey tab.

### Prong 2 — Curated advisory for the command-palette default (the reported case)

Because the reported symptom does not produce a Carbon failure, add a small,
hand-maintained advisory for defaults that are known to overlap common macOS
system shortcuts. Seed it with the command-palette default
`Option+Command+Space` (`ActionCatalog.swift:667`):

> "Your Command Palette shortcut (Option+Command+Space) can also be claimed by a
> macOS system shortcut (e.g. Input Sources) or another launcher, which will
> fire alongside Nehir. If pressing it also opens another app, reassign this
> Nehir hotkey in Hotkeys, or clear the conflicting shortcut in System Settings
> → Keyboard → Keyboard Shortcuts."

Keep the advisory **default-chord-scoped and data-driven** (a small list of
`(actionID, chord, advisoryText)` consulted by the detector), so it only fires
while the user is on the default binding and goes away the moment they reassign
— no false positives on custom chords. This is the lowest-effort way to make the
*reported* symptom self-diagnosing, and it directly answers the reporter's
"warn about this possible behaviour" request.

## Non-goals

- **Do not** replace Carbon hotkeys with a `CGEventTap` keyboard backend. That is
  the much larger BarutSRB/OmniWM#226 port (see
  `discovery/20260616-omniwm-226-chrome-extension-hotkey-priority.md`) and is
  unrelated to #48, which is a co-fire conflict, not a focused-app priority loss.
- **Do not** attempt active liveness probing (register, synthesize an event,
  check dispatch). Too invasive and unreliable; the curated advisory covers the
  known-defaults case far more cheaply.
- **Do not** warn on every custom chord — Prong 2 is scoped to a curated default
  list to avoid crying wolf.

## Why `planned/` and not `noop/`

The bug itself is `wontfix` (system conflict, user-side fix confirmed). But the
owner explicitly accepted the diagnostic ask ("we can try to add diagnostic for
that, but priority is low"), the reporter explicitly requested a warning, and
there is a concrete code gap: hotkey conflicts are invisible to the Diagnostics
hub + badge, and the exact reported case is invisible even to the existing
inline hint. That is a real, small, owner-sanctioned Nehir-side item — so it is
`planned/`, sized as low priority.

## Validation

- `swift build` clean, `swift test` green.
- New test: a `HotkeyConflictIssue` is produced from a non-empty
  `hotkeyRegistrationFailures` map for both `.systemReserved` and
  `.duplicateBinding`; an empty map yields no issue.
- New test: the curated advisory fires for the command-palette default chord
  (`kVK_Space` + `optionKey | cmdKey`) and does **not** fire once the chord is
  reassigned.
- New test: `SettingsDiagnosticsDetector.applicableIssues(...)` with the
  hotkey-failures overload still returns the existing `.softMigration` /
  `.unknownKeys` issues unchanged (no regression to the unified-diagnostics
  policy from `completed/20260616-unified-config-diagnostics-and-migration-policy.md`).
- Sidebar badge count increases when a hotkey conflict is present.

## Related

- Discovery: `discovery/20260616-omniwm-226-chrome-extension-hotkey-priority.md`
  — Carbon hotkey registration path and the (separate, larger) event-tap
  priority question. The Carbon plumbing facts cited above are re-verified here
  against `7b731a51`.
- Policy (shipped): `completed/20260616-unified-config-diagnostics-and-migration-policy.md`
  — the Diagnostics framework (`SettingsDiagnosticsIssue`,
  `SettingsDiagnosticsDetector`, `ConfigAssistancePrompt`, sidebar badge) this
  plan extends.
