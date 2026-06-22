# Nehir PR #103 — Command Palette advisory gated on the live macOS symbolic-hotkey state — Discovery

Source PR: <https://github.com/apphane-dev/nehir/pull/103> ("Refine hotkey
diagnostics refresh", merged as `671652c6`; changeset reads
"fixes #48, follow-up to #97"). It refines **Prong 2** of the shipped #48 work
(`completed/20260619-nehir-48-command-palette-hotkey-conflict.md`).

All symbol/file references were verified against the PR #103 diff (merge commit
`671652c6`) on 2026-06-22, against the completed #48 doc, and against the public
`com.apple.symbolichotkeys` ID mapping. Re-verify before acting; line numbers
drift, and the source tree itself is not checked out on this planning branch.

---

## TL;DR

- PR #103 makes the Command Palette co-fire advisory **conditional on the
  conflicting macOS shortcut actually being enabled**, read live from the
  `com.apple.symbolichotkeys` preference domain. Previously (Prong 2 as shipped
  in #97 / the completed #48 doc) the advisory fired on **default-chord match
  alone**, which produced a false positive for any user who had already cleared
  the macOS shortcut.
- **New durable finding:** the conflicting macOS shortcut is not a vague "Input
  Sources or another launcher" — it is specifically symbolic-hotkey **ID 65,
  "Show Finder search window" (Spotlight), whose macOS default chord is
  Option-Command-Space** — i.e. *exactly* Nehir's command-palette default. That
  is the precise mechanism behind issue #48's "also opens Finder every time":
  ID 65 enabled at its default co-fires with Nehir's successful Carbon
  registration.
- **New reusable mechanism:** macOS exposes every enabled symbolic hotkey via
  `UserDefaults(suiteName: "com.apple.symbolichotkeys")` → key
  `AppleSymbolicHotKeys`, a dict keyed by numeric ID (as strings) whose entries
  carry `enabled: Bool` and a `value` dict (`parameters: [ascii|0xFFFF, keycode,
  modifierFlags]`, `type: "standard"`). Any app can read this cross-process
  preference domain with **no entitlement and no event synthesis** — a third
  option the completed #48 doc's Non-goals did not contemplate (it framed the
  choice as curated-defaults-only vs. invasive `CGEventTap` probing).
- **Precision boundary (recorded for future work):** the shipped reader checks
  `enabled` only; it does **not** parse `value.parameters` to compare chords. So
  it is exact for "is the historically-conflicting shortcut on at all" but
  imprecise for "is it currently bound to the conflicting chord". See
  **Limitations**.

## Where #103 sits in the lineage

- **#97** shipped the #48 work (Prong 1: mirror Carbon `registrationFailures`
  into Diagnostics + badge; Prong 2: curated command-palette advisory). The
  completed #48 doc records this as commit `009a2b73`.
- **#103 ("Refine hotkey diagnostics refresh")** is the follow-up. It changes
  *only* Prong 2's gating predicate — Prong 1 is untouched. Scope: 5 files, no
  new issues, no new remediation actions (rows stay advisory-only).

## The macOS mechanism that makes this possible

`com.apple.symbolichotkeys` is a cross-process `UserDefaults` suite. Its
`AppleSymbolicHotKeys` entry is a dictionary keyed by the symbolic-hotkey ID
(as a string). Each value looks like:

```
"65" = {
    enabled = 1;
    value = {
        parameters = ( 65535, 49, 1572864 );
        type = "standard";
    };
};
```

`parameters` is `(ascii-or-0xFFFF, macOS keycode, modifierFlags)`. For ID 65:
`49` is `kVK_Space`; `1572864 = 0x180000 = NX_ALTERNATEMASK (0x80000) |
NX_COMMANDMASK (0x100000)` — i.e. **Option-Command-Space**, the macOS default
for "Show Finder search window". (Mapping cross-checked against the public
`AppleSymbolicHotKeys` reference; `1048576` = Command alone is ID 64 "Show
Spotlight search" = Cmd-Space, and `262144` = Control alone is ID 60 "Select the
previous input source" = Ctrl-Space.)

PR #103 reads exactly the `enabled` flag from this dict:

```swift
// Sources/Nehir/Core/Config/SettingsDiagnosticsIssue.swift  (PR #103)
private static func enabledAppleSymbolicHotkeyIDs() -> Set<Int> {
    guard let symbolicHotkeys = UserDefaults(suiteName: "com.apple.symbolichotkeys")?
        .dictionary(forKey: "AppleSymbolicHotKeys")
    else { return [] }

    return Set(symbolicHotkeys.compactMap { key, value in
        guard let id = Int(key),
              let entry = value as? [String: Any],
              (entry["enabled"] as? Bool) == true
        else { return nil }
        return id
    })
}
```

The catalog entry now declares which system shortcut it overlaps, as a set of
symbolic IDs (OR semantics — fire if **any** member is enabled):

```swift
// Sources/Nehir/Core/Config/HotkeyAdvisoryCatalog.swift  (PR #103)
struct CuratedHotkeyAdvisory: Equatable {
    let actionID: String
    let command: HotkeyCommand
    let symbolicHotkeyIDs: Set<Int>   // NEW
    let advisoryText: String
}
// ...
CuratedHotkeyAdvisory(
    actionID: "openCommandPalette",
    command: .openCommandPalette,
    symbolicHotkeyIDs: [65],          // NEW — "Show Finder search window"
    advisoryText: "Your Command Palette shortcut overlaps the enabled macOS "
        + "Spotlight → Show Finder search window shortcut, which can fire "
        + "alongside Nehir. Reassign this Nehir hotkey in Hotkeys, or clear "
        + "the conflicting shortcut in System Settings → Keyboard → Keyboard "
        + "Shortcuts."
)
```

And the gating predicate becomes a conjunction: default-chord match **and** the
declared system shortcut is currently enabled:

```swift
// Sources/Nehir/Core/Config/SettingsDiagnosticsIssue.swift — hotkeyAdvisoryIssues (PR #103)
guard !advisory.symbolicHotkeyIDs.isDisjoint(with: enabledSystemHotkeyIDs),
      let current = currentByID[advisory.actionID],
      let defaultBinding = defaultsByID[advisory.actionID],
      current.binding == defaultBinding.binding,
      case let .chord(chord) = current.binding,
      !chord.isUnassigned
else { return nil }
```

The new `enabledSystemHotkeyIDs` parameter defaults to
`Self.enabledAppleSymbolicHotkeyIDs()` on both `applicableIssues(...)` and
`pendingIssues(...)`, so it is re-evaluated on **every** detector call rather
than cached.

## Why this is the right fix for the reported symptom

The completed #48 doc established that Carbon `RegisterEventHotKey` returns
`noErr` for Option-Command-Space because macOS delivers the Spotlight shortcut
through the system services layer, not Carbon's Hot Key Manager — so
`registrationFailures` stays empty and Prong 1 can never see this conflict.
#103 does **not** change Carbon registration. Instead it gives the detector an
**independent second signal** (the symbolic-hotkey preference) that observes the
co-fire *without* relying on Carbon's return code and *without* synthesizing
events. That closes the Carbon blind spot for the known-default case using a
read-only preference read — the "third option" the completed doc's Non-goals
binary framing (curated-defaults-only vs. invasive `CGEventTap`) missed.

It also pins the symptom precisely. The original Prong 2 advisory text hedged
with "(e.g. Input Sources) or another launcher". The real culprit for "also
opens Finder" is ID 65 — "Show Finder search window" — whose default chord is
Option-Command-Space. A user with ID 65 on (the macOS default) and Nehir on its
default chord gets both: Nehir's palette *and* a Finder-scoped Spotlight window.
#103's advisory names that shortcut exactly, and only shows when it is on.

## What changed in the refresh wiring

Because `com.apple.symbolichotkeys` is a system preference domain Nehir does not
own, the process receives **no notification** when it changes. The user flips the
shortcut in System Settings, which is a separate app. PR #103 therefore adds two
refresh triggers in the Diagnostics tab so the advisory re-evaluates after the
user returns:

```swift
// Sources/Nehir/UI/DisplayDiagnosticsSettingsTab.swift  (PR #103)
.onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
    refreshSettingsIssues()
}
.onChange(of: settings.hotkeyBindings) { _, _ in
    refreshSettingsIssues()
}
```

`didBecomeActive` covers "user changed the macOS shortcut in System Settings and
came back"; `onChange(settings.hotkeyBindings)` covers "user reassigned the Nehir
chord" (the default-chord-scope predicate needs re-evaluation then too). Because
`enabledSystemHotkeyIDs` defaults to a fresh `enabledAppleSymbolicHotkeyIDs()`
call, each refresh re-reads the live preference.

## Limitations / precision boundary (for future work)

1. **`enabled`-only, not chord-compared.** The reader extracts the `enabled`
   bool but ignores `value.parameters`. It is therefore exact for "is the
   historically-conflicting system shortcut on at all" but imprecise for "is it
   currently bound to the conflicting chord". Residual false positive: the user
   keeps ID 65 enabled but rebinds it away from Option-Command-Space → Nehir
   still shows the advisory (because ID 65 is enabled and Nehir is still on its
   default chord), even though the co-fire no longer occurs. The data to do this
   exactly is already in the plist: `parameters.1` (keycode) and
   `parameters.2` (modifier flags, same `NX_*MASK` bit layout Nehir uses —
   `optionKey|cmdKey == 1572864`). A future refinement could OR-in a
   chord comparison and drop the false positive.
2. **Curated-list-only, still.** Only ID 65 is seeded. A *different* system
   shortcut rebound onto Option-Command-Space, or any other default chord that
   co-fires, is invisible unless `HotkeyAdvisoryCatalog.knownSystemConflicts` is
   extended. This is unchanged from the completed #48 doc's design; #103 makes
   each entry more accurate, not the catalog broader.
3. **Fail-closed on unreadable prefs.** `hotkeyAdvisoryIssues` short-circuits on
   `enabledSystemHotkeyIDs.isEmpty` (which is also what
   `enabledAppleSymbolicHotkeyIDs()` returns if the suite/key is absent). If the
   preference domain is ever unreadable, **no advisory is shown** — silent
   rather than crying wolf. A deliberate policy choice worth recording: the
   advisory is opt-in on being able to read system state.

## Correction to the completed #48 record

The completed #48 doc's **Outcome (as-built)** describes Prong 2 as gating on
"default-chord-scoped and data-driven … it only fires while the user is on the
default binding". That was accurate as shipped in #97 but is now **incomplete**:
#103 adds the second conjunct (the system shortcut must be enabled). Its
**Non-goals** ("do not attempt active liveness probing … too invasive and
unreliable; the curated advisory covers the known-defaults case far more
cheaply") framed the choice as binary; #103 introduces the read-only
preference-read middle ground that sentence did not anticipate. Neither is
contradicted in spirit (no `CGEventTap`, no event synthesis), but both should be
read together with this discovery. Its **Follow-ups** bullet ("extending the
catalog … a data change, not a code change") also under-describes #103, which
added code (the reader + gating + refresh), not just a catalog row.

## Non-goals (unchanged by #103)

- No replacement of Carbon hotkeys with a `CGEventTap` keyboard backend — still
  the separate OmniWM #226 scope (`planned/20260621-omniwm-226-chrome-extension-hotkey-priority.md`,
  `discovery/20260616-omniwm-226-chrome-extension-hotkey-priority.md`).
- No active liveness probing via event synthesis.
- No advisory on arbitrary custom chords — still default-scoped to a curated list.

## Related

- `completed/20260619-nehir-48-command-palette-hotkey-conflict.md` — the shipped
  Prong 1 + Prong 2 work (#97) that #103 refines. Read its Outcome and
  Non-goals together with the **Correction** section above.
- PR #97 — shipped the #48 diagnostics (Carbon-failure mirroring + the curated
  command-palette advisory).
- PR #103 — this follow-up; adds `symbolicHotkeyIDs`, the
  `com.apple.symbolichotkeys` reader, the enabled-conjunct gating, and the
  `didBecomeActive` / `hotkeyBindings` refresh triggers.
- `discovery/20260616-omniwm-226-chrome-extension-hotkey-priority.md` — the
  Carbon hotkey registration path and the (separate, larger) event-tap priority
  question; the Carbon blind spot #103 sidesteps is characterized there.
