# Borrowed-later files (category 4)

These four Nehir files are **absent at the fork base `ee9b4f0`** but originate
from a later upstream commit on `BarutSRB/OmniWM` `origin/main`. Each is
confirmed by: (a) the cited commit is reachable from `origin/main`, (b) newer
than the fork base, and (c) authored by Barut. The decisive evidence — the
actual diff between the upstream version at that commit and the Nehir file — is
inlined below so this document stands without re-opening any working tree.

All commits referenced were verified against `BarutSRB/OmniWM` `origin/main`
on 2026-06-20.

Fork base: `ee9b4f0707668d43f73e4af8c9a4f3581b8c11ce`.

## Summary

| Nehir file | Upstream commit | Author | Relationship |
| --- | --- | --- | --- |
| `Sources/Nehir/Core/Multitouch/MultitouchBinding.swift` | `06eb42d` "Fix stuck trackpad workspace gestures" | Barut | near-verbatim vendor (2 lines changed) |
| `Sources/Nehir/Core/Multitouch/MultitouchGestureSource.swift` | `06eb42d` | Barut | near-verbatim vendor + Nehir concurrency/modifier plumbing |
| `Sources/Nehir/Core/SkyLight/DisplaySpacesMode.swift` | `ee554c7` "Support Displays have separate Spaces" | Barut | upstream enum extracted from `SkyLight.swift` + Nehir extensions |
| `Sources/Nehir/Core/Config/MonitorGapSettings.swift` | `dacccb8` "Fix multi-monitor gap resolution" | Barut | upstream struct + Nehir anchor/gapSize extensions; manual Codable dropped |

---

## 1. `MultitouchBinding.swift` ← upstream `06eb42d`

Upstream file: `Sources/OmniWM/Core/Multitouch/MultitouchBinding.swift` at
`06eb42d`.

Diff of upstream `06eb42d` vs Nehir (excluding the generated SPDX header block
Nehir adds to every file):

```diff
+import Darwin
-        let message = "OmniWM: trackpad gestures unavailable — MultitouchSupport \(reason)\n"
+        let message = "Nehir: trackpad gestures unavailable — MultitouchSupport \(reason)\n"
```

That is the entire non-header change: one added import and one rebranded error
string. The file is otherwise byte-identical to upstream `06eb42d`.

## 2. `MultitouchGestureSource.swift` ← upstream `06eb42d`

Upstream file: `Sources/OmniWM/Core/Multitouch/MultitouchGestureSource.swift`
at `06eb42d`.

Nehir's non-header additions over upstream `06eb42d`:

```swift
// Reverse-engineered byte offsets into the private MultitouchSupport framework's
// per-touch ("Finger") record. … re-derive these offsets … when the layout shifts.
    @MainActor weak static var shared: MultitouchGestureSource?   // was: nonisolated(unsafe) static weak var
        let localFrame = RawFrame(touches: frame.touches, timestamp: CACurrentMediaTime())
            frame: localFrame,
            modifiers: MouseEventHandler.cgEventFlags(from: NSEvent.modifierFlags),
        modifiers: CGEventFlags = [],
                modifiers: modifiers,   // threaded into the ended-path snapshot
            modifiers: modifiers,   // threaded into the active-path snapshot
```

The upstream body is intact. Nehir's deltas are: a documentation comment about
the private-framework byte offsets, a Swift 6 concurrency annotation change
(`nonisolated(unsafe) static weak var` → `@MainActor weak static var`), and
plumbing a `modifiers` field plus a `CACurrentMediaTime()`-stamped local frame
through the gesture snapshot. The constant `multitouchTouchStride = 96` and all
private-framework offset constants are upstream's.

### Documentation nuance (worth flagging)

The Nehir discovery doc `discovery/20260618-raw-multitouch-gesture-source.md`
(predating the landing of M5) states:

> Upstream `06eb42d` is not vendored anywhere in the tree … any prototype must
> be designed from documented intent, not ported line-for-line.

The *landed* M5 code contradicts that premise: Nehir vendored `06eb42d`
near-verbatim and made only the small Swift-6/branding deltas shown above. The
discovery doc reflects the pre-landing *intent* (re-implement); the landed code
is a near-verbatim vendor. The category-4 classification follows the landed
code, which is what ships and what carries the GPL obligations.

## 3. `DisplaySpacesMode.swift` ← upstream `ee554c7`

Upstream introduced the `DisplaySpacesMode` enum **inside**
`Sources/OmniWM/Core/SkyLight/SkyLight.swift` at `ee554c7`:

```swift
enum DisplaySpacesMode: Equatable, Sendable {
    case enabled
    case disabled
    case unavailable
}
```

Nehir extracts that enum into its own file
`Sources/Nehir/Core/SkyLight/DisplaySpacesMode.swift`, keeps the three cases
verbatim, and extends it with Nehir-specific presentation helpers
(`: String` raw value, `displayName`, `systemImage`) plus a doc comment
referencing the M4 Stage-1 plan. The enum and its three cases are upstream
origin; the file extraction and the presentation helpers are Nehir.

This matches the maintainer's own plan: `discovery/20260618-displays-separate-spaces-mode-detection.md`
(M4 Stage 1, task 2) calls for "New `Sources/Nehir/Core/SkyLight/DisplaySpacesMode.swift`"
built on the upstream `ee554c7`/`de971b6` Spaces work.

## 4. `MonitorGapSettings.swift` ← upstream `dacccb8`

Upstream file: `Sources/OmniWM/Core/Config/MonitorGapSettings.swift` at
`dacccb8`.

Nehir's non-header additions over upstream `dacccb8`:

```swift
    var monitorAnchorPoint: CGPoint?
    var gapSize: Double?
    var hasOverrides: Bool {
        gapSize != nil || outerGapLeft != nil || outerGapRight != nil || outerGapTop != nil || outerGapBottom != nil
    }
        monitorAnchorPoint: CGPoint? = nil,
        gapSize: Double? = nil,
        self.monitorAnchorPoint = monitorAnchorPoint
        self.gapSize = gapSize
    let outerGapLeft: Double        // (CGFloat -> Double across the gap fields)
    …
    var outerGaps: LayoutGaps.OuterGaps { LayoutGaps.OuterGaps(left:right:top:bottom:) }
```

Nehir also **removes** upstream's hand-written `Codable`
(`CodingKeys`/`init(from:)`/`encode(to:)`), consistent with Nehir's broader move
to a synthesized/split TOML codec. The base struct and its outer-gap fields are
upstream's; the anchor-point/gap-size overrides and the `LayoutGaps.OuterGaps`
projection are Nehir's.

Unlike the three files above, `MonitorGapSettings` has no dedicated entry in
the upstream-port roadmap; it appears to have entered Nehir as part of monitor
arrangement/gap work rather than as a named port item. The commit evidence
(`dacccb8`, Barut, reachable from `origin/main`, newer than the fork base) is
unambiguous and is what the classification rests on.

---

## Attribution implication (implemented)

These four files contain near-verbatim or structurally-derived upstream code
written after the fork base, so they are the clearest case for preserving
upstream copyright explicitly. The header policy has been implemented to do
exactly that, driven by `.provenance.json` overrides on `main`.

The default header for upstream-derived files now carries upstream copyright
**in addition to** Nehir's. Exact upstream commit hashes are intentionally kept
out of rendered file headers; they live in `.provenance.json`'s non-rendering
`upstreamCommits` map and in this audit. The landed header for the multitouch
files is therefore the same stable legal header as other upstream-derived files:

```text
// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only
```

The exact commits remain recorded here: `06eb42d` for the multitouch files,
`ee554c7` for `DisplaySpacesMode`, and `dacccb8` for `MonitorGapSettings`.

Design notes for the header policy this audit informed:

- The default marker is `upstream-derived` (not the old ambiguous
  `project-derived`), because Nehir is a GPL-2.0-only fork and most files
  originate upstream. Upstream copyright is preserved **in addition to**
  Nehir's, never instead of it.
- `nehir-original` is reserved for files written from scratch in Nehir (no
  prior existence in OmniWM); those carry Nehir-only copyright.
- The four CAT-4 files are upstream-derived like other derived files; their
  exact commit hashes are audit metadata rather than rendered header text.
- The `BarutSRB` copyright line mirrors upstream's own notice
  (`Copyright (C) 2026 BarutSRB`). Nehir's source tree had shipped without
  per-file attribution; introducing these structured headers is the direct
  remedy for the attribution concern.

See `NOTICE.md` on `main` for the full policy and the meaning of the
`SPDX-FileComment` keys.
