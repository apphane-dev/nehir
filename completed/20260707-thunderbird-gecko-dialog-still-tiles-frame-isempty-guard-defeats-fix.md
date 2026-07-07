# Gecko-dialog fix is defeated by a `!windowServer.frame.isEmpty` guard that shipped in the fix itself

Status: **completed** — corrected on `main` in `d953d4d3` ("Float zero-frame Gecko transient dialogs that the first #142 fix still tiled"). Reopened
apphane-dev/nehir discussion #142 ("Popup window rule?") after the first fix
merged as `45d3767f` but **did not float the send-confirmation dialog it was
written for**. The corrective merge removed the frame guard, moved the Gecko
dialog rule after title-missing deferral so Firefox/Zen PiP still routes through
`browserPictureInPicture`, and added zero-frame plus non-zero-frame regression
coverage. A fresh reporter capture (Thunderbird, `nehir v0.6.0` build carrying
`45d3767f`, single monitor `ID(displayId: 4)` 5120×1440) showed the dialog still
tiling as a full-height column.

All runtime evidence is inlined below; the document does not depend on any
machine-local trace surviving. A durable copy of the capture is attached to
discussion #142.

---

## Symptom (unchanged from the original report)

After the Gecko-dialog built-in shipped, the reporter sent a mail and captured a
new trace. Thunderbird's "message sent" confirmation dialog **still opens as a
tiled column** instead of floating — the exact behavior the fix was supposed to
remove.

---

## Evidence — the dialog is admitted and tiled by the heuristic, not by the built-in

The send-confirmation dialog is `windowId 652` (`pid 1643`,
`bundleId=org.mozilla.thunderbird`). Its admission `window_decision` record
(captured `2026-07-06T23:51:…Z`):

```text
window_decision token=…windowId: 652 context=focused_admission existingMode=nil
  disposition=managed source=heuristic outcome=trackedTiling layout=fallbackLayout
  bundleId=org.mozilla.thunderbird titleLength=nil
  axRole=AXWindow axSubrole=AXStandardWindow
  hasCloseButton=true hasFullscreenButton=true fullscreenButtonEnabled=true
  hasZoomButton=true hasMinimizeButton=true
  axAttributeDiagnostics=multipleResult=0,valueCount=6,… ,fullscreenEnabled=bool:true
  wsLevel=0 wsTags=0x100000000 wsAttributes=0x0 wsParent=0
  wsFrame=(0.0,0.0,0.0,0.0)
```

Key facts:

- `source=heuristic outcome=trackedTiling` — the decision came from the tiling
  **heuristic**, *not* from `source=builtInRule(geckoTransientDialog)`. The new
  built-in never claimed the window.
- The window's signature is exactly the one the built-in targets:
  `wsTags=0x100000000` → document bit `0x1` **not set**, floating bit `0x2`
  **not set**; `wsParent=0`; `axRole=AXWindow`; `axSubrole=AXStandardWindow`;
  attribute fetch **succeeded** (`multipleResult=0, valueCount=6`, so
  `attributeFetchSucceeded == true`).
- The one field that differs from the built-in's assumptions:
  **`wsFrame=(0.0,0.0,0.0,0.0)`** — the WindowServer frame is `CGRect.zero` at
  the moment of admission.

The window then tiles as a full-height column. A later layout snapshot shows it
as column `c4`:

```text
c4[…]{w652{cur=3418,0,1685,1410,target=3418,0,1685,1410,…}}
```

i.e. a 1685×1410 column — full workspace height — precisely the "opens as a
column" complaint.

(A second, *genuinely* floating Thunderbird popup — `windowId 649`,
`wsLevel=101`, `ws_float=true ws_doc=false ws_frame=(3539,151 1557x164)` — appears
in the same capture but repeatedly hits `prepare_create_rejected
reason=missing_ax_ref`; it is a different surface and not the tiled dialog. It is
noted only so it is not mistaken for `w652`.)

---

## Root cause — the fix guards on a non-empty WindowServer frame, and the dialog's frame is empty

The shipped built-in
(`Sources/Nehir/Core/Rules/WindowRuleEngine.swift:746`) reads:

```swift
private func geckoTransientDialogDecision(…) -> WindowDecision? {
    guard let bundleId = facts.ax.bundleId?.lowercased(),
          Self.geckoBundleIds.contains(bundleId),
          facts.ax.attributeFetchSucceeded,
          facts.ax.role == kAXWindowRole as String,
          facts.ax.subrole == kAXStandardWindowSubrole as String,
          let windowServer = facts.windowServer,
          !windowServer.frame.isEmpty,          // ← line 757: defeats the fix
          windowServer.parentId == 0,
          !windowServer.hasDocumentTag,
          !windowServer.hasFloatingTag
    else {
        return nil
    }
    …
}
```

Evaluating each guard against `w652`:

| Guard | Value in capture | Result |
| --- | --- | --- |
| `bundleId ∈ geckoBundleIds` | `org.mozilla.thunderbird` | pass |
| `attributeFetchSucceeded` | `multipleResult=0, valueCount=6` | pass |
| `role == AXWindow` | `AXWindow` | pass |
| `subrole == AXStandardWindow` | `AXStandardWindow` | pass |
| `windowServer != nil` | present | pass |
| **`!windowServer.frame.isEmpty`** | `wsFrame=(0,0,0,0)` → `CGRect.zero` | **FAIL** |
| `parentId == 0` | `wsParent=0` | pass |
| `!hasDocumentTag` | `0x100000000 & 0x1 == 0` | pass |
| `!hasFloatingTag` | `0x100000000 & 0x2 == 0` | pass |

`WindowServerInfo.frame` is a `CGRect`
(`Sources/Nehir/Core/SkyLight/SkyLight.swift:907`) and `CGRect.zero.isEmpty` is
`true` in Core Graphics, so `!windowServer.frame.isEmpty` is **false** for the
dialog. The guard short-circuits the `guard` to `return nil`, the built-in
declines, and the window falls through to the tiling heuristic
(`AXWindowService.heuristicDisposition`, terminal `return .managed` at
`Sources/Nehir/Core/Ax/AXWindow.swift:814`) — exactly as it did before the fix.
Every *other* guard the built-in relies on passes. The frame guard is the sole
reason the dialog still tiles.

Tag decode for reference: `hasDocumentTag = tags & 0x1`,
`hasFloatingTag = tags & 0x2`
(`Sources/Nehir/Core/SkyLight/SkyLight.swift:913-930`).

### How this shipped despite review

The completed plan's own "Outcome" section
([[20260706-thunderbird-gecko-dialog-float-builtin]]) states that review **caught
and removed** this guard before merge — "the first pass added an unrequested
`!windowServer.frame.isEmpty` guard, which would have defeated the fix … The
guard was removed and the float test changed to a `.zero` frame (helper now
defaults `frame: .zero`)." **That removal did not land.** `git log -L` on the
line shows `+ !windowServer.frame.isEmpty,` was introduced by `45d3767f` (the fix
commit) and never subsequently deleted; it is present on `main` today at
`WindowRuleEngine.swift:757`.

### Why the regression test does not catch it

`Tests/NehirTests/WindowRuleEngineTests.swift` masks the bug. The float test
`geckoTaglessTopLevelStandardWindowFloatsAsTransientDialog`
(`WindowRuleEngineTests.swift:503`) builds its WindowServer record via
`makeGeckoDialogWindowServerInfo(…)`, whose helper hardcodes a **non-empty**
frame:

```swift
// WindowRuleEngineTests.swift:12
private func makeGeckoDialogWindowServerInfo(…) {
    …
    frame: CGRect(x: 100, y: 100, width: 520, height: 260)   // never .zero
}
```

Contrary to the plan's outcome note, the helper does **not** default `frame:
.zero`; it always supplies `520×260`. So `!windowServer.frame.isEmpty` is `true`
in the test and the built-in fires, turning the suite green while the real dialog
(`wsFrame=(0,0,0,0)`) is rejected in production.

---

## Outcome

Shipped on `main` in `d953d4d3` ("Float zero-frame Gecko transient dialogs that
the first #142 fix still tiled"):

1. **Removed the `!windowServer.frame.isEmpty` guard** from
   `geckoTransientDialogDecision`. The remaining guards (`bundleId`,
   `attributeFetchSucceeded`, `role`, `subrole`, `parentId == 0`,
   `!hasDocumentTag`, `!hasFloatingTag`) scope the rule to the Gecko
   transient-dialog signature without rejecting the captured zero-frame dialog.
2. **Moved the Gecko transient-dialog decision after title-missing deferral.**
   This preserves Firefox/Zen title-gated behavior: not-yet-formed PiP windows
   still defer until their title arrives and are then claimed by the
   `browserPictureInPicture` built-in rule rather than by the broader Gecko
   dialog rule.
3. **Updated regression coverage** in
   `Tests/NehirTests/WindowRuleEngineTests.swift`: the Gecko helper now defaults
   to `.zero`, the Thunderbird tagless dialog test covers the zero-frame case,
   a Firefox nil-title zero-frame test locks in title deferral, and a dedicated
   non-zero-frame Thunderbird case confirms ordinary non-empty frames still float.
4. **Changeset:** patch release note with reporter attribution (`etrigan63`).

Verification on the merge branch before landing: `swift test --filter
WindowRuleEngine` passed with 37 tests, and `mise run check` passed with 1424
tests.

---

## Separately reported, not in this capture: unlock re-layout bug

In the same discussion the reporter added: *"if you have windows vertically
stacked and the Mac goes to screen lock, when you unlock the screen it makes all
the columns cover the top ⅓ of the screen."* This capture does **not** cover it —
`lockScreenActive=false` for its entire 27 s and there is no lock/unlock
transition recorded. It needs its own capture that spans a lock→unlock cycle with
a stacked (multi-window) column present. Track it as a separate discovery; do not
fold it into the dialog fix.
