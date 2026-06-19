# #67 — 'centered width' GUI element overcorrecting input — already fixed

**GitHub issue:** https://github.com/Guria/nehir/issues/67 (open, no labels)
**Verdict:** **already-fixed** → **noop / already-shipped**. No plan needed.
**Fixed in:** commit `79c14578` "Fix settings number field editing" (2026-06-18),
shipped in **`v0.5.2-rc.1`** (the exact release the maintainer asked the reporter to
test in the issue comments). Also contained in `v0.5.2-rc.2` and `v0.6.0-rc.1`.

All claims below are grounded in current source at the main worktree
`/Users/Aleksei_Gurianov/ghq/github.com/guria/nehir`. Line numbers are re-verified
against the working tree on 2026-06-19; they drift over time, re-check before acting.

This document is self-contained — it does not depend on any trace log or local file.

---

## TL;DR

The "Centered Width" percent field (lone-window max-width) used a SwiftUI
`TextField(label, value: <Binding>, format: .number)`. A **value-bound** text
field commits its binding on **every keystroke**, and that binding's setter ran a
live clamp `min(95, max(10, percent))` plus a load-time validator capped at
`0.95`. The combination produced every symptom in the report: 100% → 95% snap,
mid-typing "7" → 10 snap, and 100% being unreachable.

Commit `79c14578` replaced all such percent/stepper fields with draft-based
`PercentTextField` / `DraftNumberTextField` views that keep a `@State` string
draft, commit **only on Enter or focus-loss**, and widened the upper bound from
95% to 100% in both the UI setter and the config validator. All four reported
symptoms are resolved by the current code.

---

## What the reporter saw (issue body, inlined)

- Set value to 1 in the config file, open settings → shows 100%.
- Click the field saying '100' → jumps to 95%.
- Manually set back to 100 in the UI → does not let me; always jumps back to 95%.
- Double-click to select-all and type 75% → assumes 7 is too low, auto-sets to 10.
  Fewer problems when NOT double-clicking and using backspace.
- "In general it's hard to work with this field; the GUI is too intelligent."

This is the "Centered Width" / lone-window max-width control (percent), shown when
lone-window mode is `.centered`.

## Maintainer trail (issue comments, inlined)

- OWNER @Guria: "From your description, it does sound like the control may be
  overcorrecting user input and making manual adjustments harder than they should be."
- OWNER @Guria (later): "@stefanpinterBE Please test
  https://github.com/Guria/nehir/releases/tag/v0.5.2-rc.1"

The release pointed at contains the fix (verified below). The `.changeset` note
attached to the fix commit reads, in full:

> Fix numeric settings fields so typing no longer auto-corrects mid-entry,
> including centered width percentages and workspace bar offset steppers;
> centered width now preserves 100% values.
> — `.changeset/20260618232952-fix-centered-width-settings-fields-so-typing-no-.md`
> contributors: [stefanpinterBE]

The credited contributor `stefanpinterBE` is the reporter of issue #67, confirming
the commit targets this report.

---

## Root cause (pre-fix, reconstructed from the fix diff)

Before `79c14578`, the field was a SwiftUI **value-bound** text field:

```swift
// GlobalNiriSettingsSection, pre-fix (from git show 79c14578)
let loneWindowMaxWidthPercent = Binding(
    get: { Int((settings.niriLoneWindowMaxWidth ?? 0.6) * 100) },
    set: { newPercent in
        settings.niriLoneWindowMaxWidth = Double(min(95, max(10, newPercent))) / 100.0
        // ...
    }
)
// ...
TextField("Centered Width", value: loneWindowMaxWidthPercent, format: .number)
```

Two compounding problems:

1. **Value-bound `TextField(... value:format:)` writes the binding on every
   keystroke.** So typing "75" first writes `7`, then `75`. The setter clamped each
   intermediate: `7` → `max(10, 7)` = `10`, and the field then re-rendered from the
   clamped `10`, fighting the user. This is exactly "assumes 7 is too low, auto-sets
   to 10" and "the GUI is too intelligent". (Same shape for the "Width" /
   `defaultColumnWidthPercent` field and for the workspace-bar offset steppers.)
2. **The setter and the load validator both capped at 95%.** Setter:
   `min(95, max(10, newPercent))`; validator
   `SettingsStore.validatedLoneWindowMaxWidth` returned `min(0.95, max(0.10, width))`.
   So any focus/commit of "100" snapped to 95, and a config value of `1.0` was
   silently reduced to `0.95` on load → "100% → jumps to 95%" and "can't set 100".

---

## The fix (commit `79c14578`, current code) — all four symptoms resolved

### A. Draft + commit-on-focus-loss/Enter (no more mid-keystroke clamping)

New `PercentTextField` in `Sources/Nehir/UI/SettingsView.swift:312`:

```swift
private struct PercentTextField: View {
    let title: String
    let value: Int
    let range: ClosedRange<Int>
    let onCommit: (Int) -> Void

    @State private var draft = ""
    @FocusState private var isFocused: Bool

    private var clampedValue: Int { value.clamped(to: range) }

    var body: some View {
        HStack {
            TextField(title, text: $draft)           // text-bound, NOT value-bound
                // ...
                .focused($isFocused)
                .onSubmit(commitDraft)               // commit on Enter
                .onAppear { restoreDraftFromValue() }
                .onChange(of: value) { _, _ in
                    if !isFocused { restoreDraftFromValue() }
                }
                .onChange(of: isFocused) { _, focused in
                    if focused {
                        restoreDraftFromValue()
                    } else {
                        commitDraft()                // commit ONLY on focus loss
                    }
                }
            // ...
        }
    }

    private func restoreDraftFromValue() { draft = String(clampedValue) }

    private func commitDraft() {
        let parsed = Int(draft.trimmingCharacters(in: .whitespacesAndNewlines)) ?? clampedValue
        let committed = parsed.clamped(to: range)    // clamp once, at commit
        draft = String(committed)
        onCommit(committed)
    }
}
```

Because the field is now **text-bound** (`text: $draft`) and `onCommit` is invoked
**only** from `onSubmit` (Enter) and `onChange(of: isFocused)` (blur), intermediate
keystrokes like "7" no longer round-trip through the clamping setter. Typing "75"
stays "75" in the draft until commit. This kills symptom 4 ("7 → 10").

The same pattern is applied to the generic stepper fields via
`DraftNumberTextField` in `Sources/Nehir/UI/OverridableControls.swift:104`, used by
both `SettingsNumberStepperRow` (`OverridableControls.swift:167`) and
`OverridableStepper` (`OverridableControls.swift:432`). The old
`private var boundedValue: Binding<Double>` helpers that wrapped the value-bound
`TextField(... value:format: .number)` were deleted in both structs, so the
per-keystroke clamp path no longer exists for these controls.

### B. Upper bound widened 95% → 100% in the UI setter

`Sources/Nehir/UI/SettingsView.swift:393` (global centered-width):

```swift
let loneWindowMaxWidthPercent = Binding(
    get: { Int((settings.niriLoneWindowMaxWidth ?? 0.6) * 100) },
    set: { newPercent in
        settings.niriLoneWindowMaxWidth = Double(newPercent.clamped(to: 10 ... 100)) / 100.0
        // was: Double(min(95, max(10, newPercent))) / 100.0
        controller.updateNiriConfig(loneWindowPolicy: settings.loneWindowPolicy)
    }
)
```

Range `10 ... 100` (was `10 ... 95`). 100 is now a valid committed value → kills
symptoms 2 and 3 ("jumps back to 95%"). The per-monitor override path uses the same
widened range: `Sources/Nehir/UI/SettingsView.swift:573` sets
`Double(newPercent.clamped(to: 10 ... 100)) / 100.0`, rendered via a
`PercentTextField(... range: 10 ... 100, ...)` at `SettingsView.swift:616`.

The plain "Width" (`defaultColumnWidthPercent`) field was fixed the same way with
`range: 5 ... 100` (`SettingsView.swift:422`).

### C. Upper bound widened 0.95 → 1.0 in the config validator

`Sources/Nehir/Core/Config/SettingsStore.swift:977`:

```swift
static func validatedLoneWindowMaxWidth(_ width: Double?) -> Double? {
    guard let width else { return nil }
    return min(1.0, max(0.10, width))   // was: min(0.95, max(0.10, width))
}
```

A config-file value of `1.0` is now preserved on load instead of being reduced to
`0.95`, so symptom 1 ("set 1 in config → ... shows 100%", then collapsing to 95)
no longer collapses. `validatedLoneWindowMaxWidth` is the single funnel used at
declarative default (`SettingsStore.swift:101`), on-set validation
(`SettingsStore.swift:105`), and import (`SettingsStore.swift:482`), so the widened
bound applies everywhere the value is normalized.

---

## Symptom-by-symptom resolution

| Report                                                                 | Pre-fix cause                                                | Current code resolves it via                                                       |
| ---------------------------------------------------------------------- | ----------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| Config `1` shows 100% then collapses to 95%                            | validator cap `0.95` reduced `1.0`→`0.95` on load          | `SettingsStore.swift:977` cap raised to `1.0`; setter range `10 ... 100`          |
| Click "100" → jumps to 95%                                             | value-bound field re-committed on focus; setter cap `95`    | `PercentTextField` (`SettingsView.swift:312`): text draft, commit only on blur/Enter |
| Can't set 100, always reverts to 95                                    | setter `min(95, max(10, …))`                                | setter `clamped(to: 10 ... 100)` (`SettingsView.swift:396`, `:573`)                |
| Type 75% (double-click) → "7" auto-becomes 10                          | value-bound field wrote `7` per keystroke, clamped to `10` | draft not clamped mid-entry; `commitDraft()` parses "75" then clamps once          |
| "Width" field same overcorrection                                      | same value-bound `TextField` + `boundedValue`               | `PercentTextField` range `5 ... 100` (`SettingsView.swift:422`)                    |
| Workspace-bar offset steppers hard to edit                             | `SettingsNumberStepperRow`/`OverridableStepper` value-bound | `DraftNumberTextField` (`OverridableControls.swift:104`, `:167`, `:432`)           |

---

## Verification of release containment

```
git merge-base --is-ancestor 79c14578 v0.5.2-rc.1   → YES (in v0.5.2-rc.1)
git merge-base --is-ancestor 79c14578 v0.5.2-rc.2   → YES
git merge-base --is-ancestor 79c14578 v0.6.0-rc.1   → YES
```

So the fix is present in every release from `v0.5.2-rc.1` onward, i.e. the release
the maintainer explicitly asked the reporter to test. `git show 79c14578 --stat`
confirms it touches exactly the relevant files:
`Sources/Nehir/Core/Config/SettingsStore.swift`,
`Sources/Nehir/UI/OverridableControls.swift`,
`Sources/Nehir/UI/SettingsView.swift`, plus the `.changeset` note above.

## Residual notes (non-blocking, not part of #67)

- The draft-based fields commit on **focus loss** as well as Enter. If a future
  user reports "I typed a value and tabbed away and it changed", that is now the
  expected single-point clamp at commit — but it is worth keeping the `range`
  labels visible so users know valid bounds (10–100 for centered width).
- `validatedLoneWindowMaxWidth` lower bound is still `0.10`; UI range is `10 ... 100`.
  These agree (0.10 = 10%), so there is no validation/UI mismatch.

## Verdict

**No further work.** Close as already-fixed. The reporter has not yet confirmed in
the issue thread, but the code change is complete, targeted, contained in the
release they were asked to test, and directly addresses all four reported symptoms.
