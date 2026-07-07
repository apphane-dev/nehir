# Plan: keep Thunderbird Gecko transient dialogs floating across all observed creation paths

Status: **completed** — implemented on `main` in `579f124d` ("Keep Gecko
transient dialogs floating #142"). The original planned metadata fix was
necessary but not sufficient by itself; final user validation required adding a
second compact-dialog built-in for document-tagged Thunderbird send dialogs. The
merged change includes both the durable metadata fix and the compact-dialog rule,
plus regression tests and a patch changeset.

Root cause:
`completed/20260707-thunderbird-gecko-dialog-floats-then-tiles-projection.md`.

## Goal

Fix the remaining Thunderbird send-confirmation dialog bug after the earlier
Gecko tagless/zero-frame fixes. The final implementation must cover all observed
Thunderbird paths:

1. tagless/unparented Gecko standard windows, including zero-frame admission;
2. tagless dialogs that later gain a real frame and otherwise look
   user-addressable to projection code;
3. compact document-tagged send dialogs born with normal AX/WindowServer
   credentials and no transient precursor.

## Final implemented design

### 1. Keep the existing tagless Gecko transient rule

`Sources/Nehir/Core/Rules/WindowRuleEngine.swift` now exposes the tagless
predicate as `WindowRuleEngine.isGeckoTransientDialog(facts:)` and uses it in the
existing `geckoTransientDialog` built-in. This preserves the earlier fixes for
windows with:

- Gecko/Mozilla bundle id;
- successful AX facts;
- `AXWindow` + `AXStandardWindow`;
- top-level WindowServer parent (`parentId == 0`);
- no WindowServer document tag;
- no WindowServer floating tag.

This rule remains necessary because compact-dialog classification intentionally
requires a non-empty frame, while the original Thunderbird failure often begins
with `wsFrame=(0,0,0,0)`.

### 2. Add compact Gecko transient classification

The final validated path was a Thunderbird send dialog born as a normal-looking,
document-tagged, level-0 standard window. No managed-replacement pair existed, so
admission needed a direct classifier. The merged fix added
`geckoCompactTransientDialog`:

```text
Gecko bundle + AXWindow + AXStandardWindow + non-empty frame <= 480x240
```

This covers observed Thunderbird send dialogs around `389x131` and `402x176`.
The threshold was intentionally tightened to `480x240` after review: a wider
`640x320` gate could catch stacked tiled real windows, while normal Thunderbird
toplevel windows in the captures were about `1011x1251`.

The rule is placed after the title-missing deferral and after the tagless Gecko
rule, but before the generic heuristic. It does not require title to be nil,
because the same dialog may later receive a title such as `"Sending Message"` and
must remain floating during reevaluation.

### 3. Make Gecko transient metadata durable

`Sources/Nehir/Core/Controller/AXEventHandler.swift` now treats both Gecko
predicates as durable transient evidence when constructing
`ManagedReplacementMetadata`:

```swift
let hasGeckoTransientDialogEvidence = WindowRuleEngine.isGeckoTransientDialog(facts: facts)
    || WindowRuleEngine.isGeckoCompactTransientDialog(facts: facts)

transientWindowServerEvidence: hasGeckoTransientDialogEvidence
    || (facts.windowServer?.hasTransientSurfaceEvidence ?? false),
userAddressableTransientWindowServerSurface: hasGeckoTransientDialogEvidence
    ? false
    : facts.userAddressableTransientWindowServerSurface
```

This prevents downstream projection and close/recovery code from treating a
Gecko transient dialog as a normal user-addressable floating window after it
receives a real frame.

### 4. Do not keep managed-replacement matcher relaxation

A temporary implementation tried to match a floated transient destroy with a
newly created real-looking Gecko dialog by relaxing managed-replacement frame and
window-level matching. Review rejected that layer before merge:

- direct compact-dialog classification covers the observed recreations at
  admission, before matching is needed;
- hypothetical large real-looking recreations have no trace evidence and are
  safer to leave tiled;
- relaxing replacement matching carried residual mis-pairing risk.

The merged fix therefore does **not** rely on matcher relaxation.

## Files touched by the shipped fix

- `Sources/Nehir/Core/Rules/WindowRuleEngine.swift`
  - `isGeckoBundle(_:)`
  - `isGeckoTransientDialog(facts:)`
  - `isGeckoCompactTransientDialog(facts:)`
  - `geckoCompactTransientDialog` built-in and rule placement before heuristic.
- `Sources/Nehir/Core/Controller/AXEventHandler.swift`
  - durable metadata flags for both Gecko transient predicates.
- `Tests/NehirTests/WindowRuleEngineTests.swift`
  - regression coverage for tagless, zero-frame/non-zero-frame, compact
    document-tagged, title-arrival, stacked-tile-sized, and non-Gecko cases.
- `.changeset/20260707232424-keep-thunderbird-gecko-transient-dialogs-out-of-.md`
  - patch release note: “Keep Thunderbird Gecko transient dialogs out of tiled
    layout projection. Fixes #142.”

## Validation

Runtime validation came first, per repo policy: the user confirmed the real
Thunderbird reproduction finally stayed floating after the compact-dialog rule.
Only after that were tests added.

Final gates run for the merged change:

```bash
mise run format:check
swift build
mise run test
```

The full test run passed with 1428 tests.

## Revert decision

Do not revert the earlier Gecko fixes:

- the tagless/zero-frame rule still handles empty-frame and tagless transient
  dialogs that compact classification deliberately ignores;
- durable metadata is needed by projection and close/recovery paths;
- compact document-tagged classification handles the final observed path where
  Gecko creates the dialog with normal-looking WindowServer document evidence.

The only attempted layer intentionally not kept was managed-replacement matcher
relaxation.

## Commit message shipped

```text
Keep Gecko transient dialogs floating #142
```
