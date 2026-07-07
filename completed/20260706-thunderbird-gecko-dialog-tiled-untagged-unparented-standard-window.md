# Thunderbird send-confirmation dialog tiles as a column (un-parented, un-tagged AXStandardWindow)

Status: **completed with later follow-ups**. The first built-in merged as
`45d3767f` via plan [[20260706-thunderbird-gecko-dialog-float-builtin]], but a
`!windowServer.frame.isEmpty` guard rejected the real zero-frame dialog. The
zero-frame fix landed as `d953d4d3`. Later Thunderbird reproductions showed that
Gecko can also project a floated dialog as user-addressable content and can
create compact document-tagged send dialogs, so the final validated fix landed as
`579f124d` ("Keep Gecko transient dialogs floating #142"). See
[[20260707-thunderbird-gecko-dialog-still-tiles-frame-isempty-guard-defeats-fix]],
[[20260707-thunderbird-gecko-dialog-floats-then-tiles-projection]], and
[[20260707-thunderbird-gecko-dialog-durable-transient-metadata]]. The root-cause
analysis below remains correct for the tagless/zero-frame path. Source:
apphane-dev/nehir discussion #142 ("Popup window rule?").

Thunderbird's "message sent" confirmation dialog (and its compose window) open as
a tiled column instead of floating. The user asked for a window rule to exempt
the dialog, tried a `titleSubstring = "Write:"` rule, and it never matched — the
AX title is `nil`. This document explains why **no user rule can currently select
that dialog**, why the default heuristic tiles it, and what the only durable
discriminating signal is.

All runtime evidence below is inlined; the document does not depend on any
machine-local trace surviving. A durable copy of the two captures is attached to
discussion #142.

---

## Symptom

- Composing a new message opens a new column — the user considers this fine.
- Sending the message pops a confirmation dialog that **also** opens as a column
  rather than floating.
- Every Thunderbird window (main, compose, dialog) reports
  `role=AXWindow subrole=AXStandardWindow` in the AX dump, and the title reads as
  `nil` despite a visible title bar. A `titleSubstring`/`titleRegex` rule cannot
  fire.

Environment: Thunderbird (`bundleId=org.mozilla.thunderbird`), single monitor
`ID(displayId: 7)` 5120×1440, workspace `4F94ECA9-…`, `nehir v0.6.0`.

---

## Evidence — the decision the engine actually made

The runtime `window_decision` records for the transient windows (captured
`2026-07-05T17:07:38Z`–`17:07:56Z`) are the ground truth. Two distinct kinds of
Thunderbird surface appear, both admitted via `context=focused_admission`:

Compose window (`windowId 2906`, later `2920`):

```text
window_decision token=…windowId: 2906 context=focused_admission
  disposition=managed source=heuristic outcome=trackedTiling layout=fallbackLayout
  bundleId=org.mozilla.thunderbird titleLength=nil
  axRole=AXWindow axSubrole=AXStandardWindow
  hasCloseButton=true hasFullscreenButton=true fullscreenButtonEnabled=true
  hasZoomButton=true hasMinimizeButton=true
  wsLevel=0 wsTags=0x300000100482001 wsAttributes=0x2 wsParent=0
  wsFrame=(3419.0,30.0,1685.0,1410.0)
```

Send-confirmation dialog (`windowId 2912`, later `2925`):

```text
window_decision token=…windowId: 2912 context=focused_admission
  disposition=managed source=heuristic outcome=trackedTiling layout=fallbackLayout
  bundleId=org.mozilla.thunderbird titleLength=nil
  axRole=AXWindow axSubrole=AXStandardWindow
  hasCloseButton=true hasFullscreenButton=true fullscreenButtonEnabled=true
  hasZoomButton=true hasMinimizeButton=true
  wsLevel=0 wsTags=0x100000000 wsAttributes=0x0 wsParent=0
  wsFrame=(0.0,0.0,0.0,0.0)
```

Both are classified `disposition=managed source=heuristic` → tiled. Note the
dialog's AX attribute fetch fully **succeeded** (`hasCloseButton=true …
fullscreenButtonEnabled=true`, six values returned) at admission time; a later
reevaluation of `2925` shows the AX side going flaky
(`multipleResult=-25202 fetchFailure=multiple_attribute_fetch_failed`,
`axRole=nil`), but by then the window is already tracked as tiling.

---

## Root cause

At `focused_admission` the dialog reaches
`WindowRuleEngine.decision(...)` → `AXWindowService.heuristicDisposition(...)`
(`Sources/Nehir/Core/Ax/AXWindow.swift:755`). The heuristic returns `.managed`
for any window that is an `AXStandardWindow` with an **enabled fullscreen
button** — see the terminal `return .managed` at
`Sources/Nehir/Core/Ax/AXWindow.swift:814`. Thunderbird's dialog satisfies every
gate (`subrole == kAXStandardWindowSubrole`, `hasFullscreenButton`,
`fullscreenButtonEnabled == true`), so it tiles. Its AX facts are **identical**
to a genuine document window.

Every earlier float/unmanage branch in
`Sources/Nehir/Core/Rules/WindowRuleEngine.swift` misses it:

- `transientSystemDialogSurfaceDecision` (`:678`) requires
  `subrole == kAXSystemDialogSubrole`. The dialog is `AXStandardWindow`, not
  `AXSystemDialog`.
- `parentedWindowServerSurfaceDecision` (`:656`) requires
  `windowServer.parentId != 0`. The dialog has `wsParent=0` — Gecko does **not**
  register a WindowServer parent relationship for its dialog (unlike Cocoa apps,
  whose child dialogs get a nonzero `parentId` and are floated by this branch).
- The floating-tag branch (`:503`, "keep floating-tagged non-document surfaces
  out of the tiled tree") requires `windowServer.hasFloatingTag`
  (`tags & 0x2`). The dialog's `wsTags=0x100000000` has neither the floating bit
  (`0x2`) nor the document bit (`0x1`) → `hasTransientSurfaceEvidence == false`
  (`Sources/Nehir/Core/SkyLight/SkyLight.swift:941`).
- No user or built-in `AppRule` matches: the only matchers are `bundleId`,
  `appNameSubstring`, `titleSubstring`, `titleRegex`, `axRole`, `axSubrole`
  (`Sources/Nehir/Core/Rules/WindowRuleEngine.swift:358`,
  `Sources/Nehir/Core/Config/AppRule.swift:61`).

So this is a **Gecko top-level-window limitation**: the send-confirmation dialog
is an **un-parented, un-tagged, title-less `AXStandardWindow`** that is
indistinguishable at the AX layer from Thunderbird's real windows.

### Why the user's rule can never work today

The user needs to float the dialog **but not** the compose window (which they
want tiled). The two are separable only by signals no matcher exposes:

| Signal                | Main window        | Compose (2906/2920) | Send dialog (2912/2925) |
| --------------------- | ------------------ | ------------------- | ----------------------- |
| `axRole`              | AXWindow           | AXWindow            | AXWindow                |
| `axSubrole`           | AXStandardWindow   | AXStandardWindow    | AXStandardWindow        |
| AX title              | (visible)          | nil                 | nil                     |
| `wsTags`              | 0x300000100482001  | 0x300000100482001   | **0x100000000**         |
| document tag (`0x1`)  | set                | set                 | **not set**             |
| `wsAttributes`        | 0x2 (visible)      | 0x2 (visible)       | **0x0**                 |
| `wsParent`            | 0                  | 0                   | 0                       |

- `titleSubstring`/`titleRegex` → dead: title is `nil` for both transient
  windows (`titleLength=nil`).
- `axSubrole = "AXStandardWindow"` → matches, but also floats the compose window
  the user wants tiled (and the main window).

**The only durable discriminator between the compose window and the send dialog
is the WindowServer document tag**: compose carries `0x1` (document) with
`attributes=0x2` (visible); the send dialog carries neither the document nor the
floating tag and `attributes=0x0`. Nehir does not currently consult
"document-tag absent" as a float signal, and does not expose it to `AppRule`.

---

## Assessment / recommended direction

No safe *global* auto-fix exists: treating "AXStandardWindow without a document
tag" as floating everywhere would over-float legitimate windows in many apps, so
it cannot go in `heuristicDisposition`. The realistic options, in order of
increasing blast radius:

1. **Scoped built-in rule for Gecko dialogs (lowest risk, recommended).** Add a
   built-in decision, gated on `bundleId` in the Gecko/Mozilla family
   (`org.mozilla.thunderbird`, likely also `firefox`/`seamonkey`), that floats a
   top-level (`parentId == 0`) `AXStandardWindow` whose WindowServer record has
   **no document tag and no floating tag** (`tags & 0x1 == 0 && tags & 0x2 == 0`).
   This is the exact signature that separates the send dialog from the compose
   and main windows in the table above. Model it on the existing narrow built-ins
   (`cleanShotRecordingOverlayDecision` `:698`, `ghosttyQuickTerminalOverlayDecision`
   `:722`). Risk: needs confirmation that Gecko's *compose* window keeps the
   document tag across versions (it does in `v0.6.0`), otherwise the compose
   window would start floating too.

2. **New `AppRule` matcher dimension (more general, more work).** Expose a
   "transient / non-document surface" match key (or a `documentTag: bool`
   matcher) so users can write rules for title-less Gecko windows that title and
   subrole cannot address. This generalizes beyond Thunderbird but touches the
   rule schema, the TOML file store (`AppRuleFileStore.swift`), and the settings
   UI (`AppRulesView.swift`).

Because the fix requires a maintainer product decision (built-in Gecko special-
case vs. a new user-facing matcher) and a cross-version check of Gecko's
document-tag behavior, this stays a **discovery** rather than a ready-to-delegate
plan. Recommend confirming option 1's tag stability on Thunderbird 0.6.x + a
Firefox dialog before promoting to `planned/`.

### Non-actionable framing to avoid

The discussion frames this as "add a title-based popup rule." That path is a dead
end for any Gecko app: the AX title is `nil` at (and after) admission, so no
title matcher can ever fire. Any answer on the thread should say so and point at
the document-tag discriminator instead.

---

## Prior art — how other macOS tiling WMs handle this

Checked yabai and AeroSpace (the two most-used macOS tilers) to see whether this
class of window is solved elsewhere. Conclusion: **nobody solves title-less Gecko
dialogs with a generic AX heuristic; both fall back to per-app special-casing.**
This validates option 1 above as the industry-standard approach.

### yabai — subrole-only, no generic solution

yabai's management eligibility keys almost entirely on AX subrole: a window is
"real" (tileable) when `AXRole == AXWindow` and `AXSubrole` is one of
`AXStandardWindow` / `AXDialog` / `AXFloatingWindow`, and only `AXStandardWindow`
tiles by default; `AXDialog`/`AXFloatingWindow` float (koekeishiya/yabai #2046,
#152). Because Gecko reports its dialog as `AXStandardWindow` — not `AXDialog` —
yabai tiles it exactly like Nehir does. The documented user workaround is a manual
per-app / per-title `manage=off` rule (koekeishiya/yabai #384, #109), which runs
into the same wall this document describes: title is unavailable and the subrole
does not separate the dialog from the compose window.

### AeroSpace — generic "no fullscreen button" heuristic **plus a hardcoded Firefox branch**

AeroSpace's `isDialogHeuristic`
(`Sources/AppBundle/model/AxUiElementWindowType.swift`) is the closest analog to
Nehir's `heuristicDisposition`. Two things stand out:

1. Its generic rule is the mirror of Nehir's: *float any window whose fullscreen
   button is absent or disabled* ("such windows are not designed to be big").
   **This would NOT catch the Thunderbird send dialog either** — our capture shows
   the dialog with `hasFullscreenButton=true fullscreenButtonEnabled=true`, so
   AeroSpace's generic heuristic classifies it as a real window, same as Nehir.

2. AeroSpace therefore carries an **explicit hardcoded Firefox special-case**,
   keyed on a different AX signal — the minimize button:

   ```swift
   // Firefox: Picture in Picture window doesn't have minimize button.
   // todo. bug: when firefox shows non-native fullscreen, minimize button is
   // disabled for all other non-fullscreen windows
   if id?.isFirefox == true && get(Ax.minimizeButtonAttr)?.get(Ax.enabledAttr) != true {
       return true // treat as dialog → float
   }
   ```

   The file is full of similar per-bundle hacks (`ghostty`, `gimp`, `chrome`,
   `alacritty`, `steam`, `1password`, `iphonesimulator`, `qutebrowser`, `emacs`,
   vscode…). The maintainer's stated stance is that hardcoding popular apps is an
   acceptable way to fix heuristic misses.

### Takeaways for Nehir

- **Option 1 (scoped Gecko built-in rule) is the mainstream fix.** AeroSpace
  literally hardcodes Firefox for this exact problem; yabai users hardcode via
  rules. A narrow `org.mozilla.*` built-in in `WindowRuleEngine` is consistent
  with both prior art and Nehir's own existing per-app built-ins.
- **There is a second candidate discriminator worth capturing:** the *minimize
  button enabled* state, which AeroSpace uses for Firefox. Nehir's capture records
  `hasMinimizeButton=true` for the dialog but does **not** record its enabled
  state, so we can't yet confirm the dialog's minimize button is disabled the way
  AeroSpace relies on. Before choosing between the document-tag signal (found
  here) and the minimize-button signal (AeroSpace's), a follow-up capture should
  record `minimizeButtonEnabled` for both the compose window and the send dialog.
  Note AeroSpace itself flags the minimize-button signal as buggy under Firefox
  non-native fullscreen — the WindowServer document-tag signal has no such caveat
  in our data, so it is the preferred primary discriminator.
- **No WM offers a title-based path here** — confirming the thread's suggested fix
  is a dead end across the ecosystem, not just in Nehir.
